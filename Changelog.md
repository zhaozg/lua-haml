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
