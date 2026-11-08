## 0.4.3

Security release. Every item below was reproduced before the fix; the audit
notes and the reproducers live in `FIXME.md` and `test_security.lua`.

* **Data is no longer executable template syntax.** A value rendered through
  `=`, `#{}` or an attribute used to reach the second stage verbatim, so a value
  containing `<%= os.execute(...) %>` became Lua code (`N1`), and a value
  containing `#{secret}` was interpolated a second time and could read other
  locals (`N2`). Values from `locals` now encode `<%` as `&lt;%`, park `#{` and
  backslashes behind a sentinel until the interpolation passes are done, and are
  restored verbatim afterwards. This also means a `#{...}` inside a string
  returned by `=` is no longer re-interpolated: write the interpolation in the
  template text (`%p #{x}`) instead of inside the expression's result.

* **Long-bracket levels are adaptive.** `lhtml` used a fixed `[===[` for text
  and `[[` for `include()` / `at()`; text containing the matching terminator
  escaped the string and ran as Lua (`S1`). The level is now computed from the
  content, `!`/`@` included, and `luahaml.lua` does the same for its `io.write`
  wrappers.

* **`lhtml` no longer truncates on a stray `<%`.** The grammar stopped at the
  first `<%` it could not parse and silently dropped the rest of the document
  (`N4`); an unmatched `<%` is text now.

* **`escape_html` covers `#{}` and attribute values.** It only escaped `=`
  before (`S3`, `S4`). Attribute values substituted from `locals` and `#{}`
  expansions now go through the same escaper. Quoted template-side attribute
  values are still left alone (they are template code, not data).

* **`#{}` in two-phase mode no longer splices values as Lua source.** The
  `lhtml` branch of the interpolation pass used `locals[match]` as the
  placeholder body, so a value could become code (`N3`). It now emits
  `<%= match %>`; `lhaml` and `lhtml` are accepted as aliases on every path.

* **`compile` stopped evaluating standalone `=`.** `= x` with
  `escape_html = true` used to be evaluated in `_G` at compile time, ignoring
  `locals`, and `= 1+1` crashed in `filter.escape_html` (`S5`). It is evaluated
  by `render` now, with `locals`, and escaped there. `!=` / `&=` / `~` still
  evaluate at compile time by design, but with `pcall` and a readable error
  instead of a bare `loadstring`.

* **`strict_eval`.** New opt-in option: an expression that cannot be evaluated
  against `locals` raises an error instead of leaving a placeholder for the
  second stage, which runs with full `_G` (`S2`).

* **Depth limit.** `compile` and `render` refuse templates nested deeper than
  200 levels instead of overflowing the Lua stack (`S6`).

* **Parser errors are visible.** `haml.parse` used to print a traceback to
  stdout and return an empty template; it raises now, and the CLI reports the
  error on stderr with a non-zero exit (`N6`).

* **CLI.** Removed the decorative `_ENV` (it was never passed to
  `haml.render`, and the generated chunk was never `setfenv`'d), the stale
  `0.2.0` version literal, and the `--copyright` branch that called an
  undefined function (`S7`). Errors are reported instead of escaping as a raw
  traceback.

* **Attributes.** Inline attributes now resolve `locals` like non-inline ones
  (`S9`), `#{}` values are `tostring`ed instead of raising on tables (`S8`),
  and `false` omits the attribute while `true` renders it as a boolean.

* **Interpolation is about 2x faster.** The `#{}` pass used a full-document
  `gsub` with a function replacement, which cost ~100us on a 3KB page even
  when it matched once -- more than `_recurse` itself. It is a manual scan now
  (differentially fuzzed against the old `gsub` version on 200k random
  strings), and `render` of `sample.haml` dropped from ~170us to ~80us.
  `escape_html` caches its character class per escapes table, and the
  long-bracket scan skips fragments with no `]`.

* **Compiled templates are consistently cacheable.** `haml.compile` returned a
  bare string for single-node templates (`%p hi` -> `"<p>hi</p>"`), and
  `haml.render` treated that string as Haml source and re-parsed it, so
  "compile once" silently did no such thing for small templates (and could
  re-interpret compiled markup as template text). It always returns a table
  now, tagged so `render` can reject a parsed-but-uncompiled AST instead of
  emitting malformed HTML; recompiling an already compiled tree is an error.
  `lhtml` caches its last translation per handler: repeated two-phase renders
  drop from ~50us to ~1us. A transcript of the audit is in the 0.4.3 notes.

Tests: 141 JSON cases, 41 `lhtml` assertions, and the new
`test_security.lua` (16 assertions).

## 0.4.2

* `haml.render` is now repeatable. `_recurse` used to strip the metadata keys
  (`tag`, `space`, `operator`, ...) off the tree it was handed, so a compiled
  template rendered correctly exactly once and returned a bare newline on every
  later call. It now works on a shallow copy per node. This also makes template
  caching viable: parse+compile cost 2.4x a render on `sample.haml`, and 10.9x
  on a small template, so compiling once and re-rendering is now the fast path.

* Parser: the html-style and ruby-style attribute grammars were rebuilt on
  every call to `parse_html_style_attributes` / `parse_ruby_style_attributes`.
  Building one cost about 15us, roughly sixteen times the cost of matching an
  attribute list, and it was paid once per tag carrying attributes. They are
  now built once at load time (~26% faster parse on `sample.haml`).

* Render: the three whole-output `gsub` passes at the end of `render` (quote
  conversion, `#{}` interpolation, backslash unescaping) ran unconditionally
  and cost more between them than the recursive walk did. Each now runs only
  when a plain `find` shows its literal is present -- about 30us saved on
  templates with no interpolation.

* `lhtml`: the LPeg grammar was rebuilt on every `compile()` call. The default
  handler's grammar is now built once (a caller-supplied handler still gets its
  own, since the handler is baked into the pattern). ~24% faster.

* `bench.lua`: it reused a single compiled template in its "Render" loop,
  which meant it was timing a tree that the first iteration had already
  destroyed. It now asserts that two renders agree before measuring, and
  reports per-operation timings.

## 0.4.1

* Render inline scripts instead of leaving placeholders. `%p= foo` now
  evaluates against `locals`; unresolvable expressions still fall back to a
  `<%= %>` placeholder so the two-stage lhtml pipeline keeps working.

* Support inline `&=` and `!=`. Previously `%p&= foo` was emitted as literal
  text `<p>&= foo</p>`.

* Fix crash on `%p= foo` when `escape_html` was enabled
  ("attempt to concatenate field 'code' (a nil value)").

* Boolean attributes: `false` and `nil` now omit the attribute, and `true`
  renders as `attr='attr'` in xhtml (bare `attr` otherwise). Previously they
  rendered as `attr='false'` / `attr='true'`. The `checked`-only special case
  was generalised.

* Multiline `|` continuation now works for standalone scripts (`=`, `-`),
  inline scripts (`%p=`) and plain text. Continued lines are joined with a
  single space; every continued line must end with `|`. A mid-line `|` is no
  longer treated as a terminator, so `%p a | b` keeps its text.

* Fix the inner whitespace modifier `<`: it used to raise
  "invalid value (table) at index 1 in table for 'concat'" whenever a child
  was a nested element (e.g. `%blockquote<` around `%div`). It now strips the
  newlines wrapping the tag and recurses into the subtree.

* Attribute output order is now deterministic: attributes are sorted by name
  in the precompiler as well, so the order no longer depends on which
  renders ran earlier in the same process.

* Add `tests_patch.json` (23 regression cases) and wire it into `test.lua`.
  It lives outside `spec/`, which is the shared `haml-spec` git submodule.

## 0.4.0 (In Process)

* Fixed only taken first return value of string.gsub

* split into small module

* misc and others

## 0.3.0 (NOT RELEASED YET)

* String interpolation now works with local variables.

* Fixed markup comment handling - previously LuaHaml didn't parse Haml inside
  comments, which was incorrect behavior.

* Fixed bug where when the last line of Haml was immediately preceded by a
  markup comment, then the line was not added to the buffer.

## 0.2.0 (2012-06-18)

* Added a __newindex function on to the metatable for Haml environments.
  (Thanks [Ross Andrews](https://github.com/randrews))

* Fix bug with mixed tabs and spaces
  (Thanks [Ross Andrews](https://github.com/randrews))

* Fix bug which prevented if/elseif/else from working properly

* Fall back to renderer's locals if no locals are passed to the `partial` function.

* Various small documentation fixes.


## 0.1.0 (2010-11-23)

First release.
