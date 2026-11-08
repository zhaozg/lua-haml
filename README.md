# Lua Haml

Lua Haml is an implementation of the [Haml](https://haml.info) markup language
for Lua 5.1 / LuaJIT. It parses Haml into an AST, compiles that AST once, and
renders it to HTML. A second, optional stage (`lhtml`) turns `<% ... %>`
placeholders into a Lua chunk for templates that need to define local variables
with `-`.

Current release: **0.4.3**. The full language reference is
[REFERENCE.md](REFERENCE.md). The short version and the rules that matter in
production are below.

## Design

### One language, three phases

```
Haml source
  │  haml.parse        indentation → AST
  ▼
AST
  │  haml.compile      AST → compiled tree (one pass)
  ▼
compiled tree
  │  haml.render       tree → HTML (or lhtml placeholders)
  ▼
HTML / lhtml string
```

`haml.render` is a pure function of the compiled tree, the options and
`locals`. It does not mutate the tree, so the same compiled template can be
rendered any number of times (this was not true before 0.4.2).

### Why there are two stages

Most templates can be rendered in one call:

```lua
haml.render("%p Hello #{name}", nil, { name = "Ada" })
--> "<p>Hello Ada</p>"
```

But Haml also allows real Lua statements that define variables for later lines:

```haml
- local title = "Hi"
%h1= title
```

That `title` only exists inside the generated Lua chunk, so the first stage
cannot evaluate `%h1= title` on its own. It emits a placeholder instead:

```html
<% local title = "Hi" %>
<h1><%= title %></h1>
```

`lhtml` translates that intermediate string into Lua source
(`print([===[...]===])`, `print(tostring(title))`, ...), which the caller loads
and runs. This is the “two-stage pipeline”. The stages are independent: if a
template never defines its own locals, you do not need `lhtml` at all.

### Data is not code

Since 0.4.3, values that come from `locals` are treated as data, not template
syntax. A value rendered through `=`, `#{}` or an attribute is neutralised
before it reaches the output:

- `<%` becomes `&lt;%`, so the second stage cannot mistake it for a placeholder;
- `#{` and backslashes are parked behind a sentinel until the interpolation
  passes finish, then restored verbatim;
- `escape_html = true` additionally HTML-escapes the value.

This closes the short path from an untrusted value to Lua code execution. It
does **not** make Haml templates safe: the template itself is still code (see
[Security model](#security-model)).

One consequence: `#{}` inside a string passed to `=` is **not** interpolated.
`%p= "Hi #{name}"` produces the literal text `Hi #{name}` (in two-phase mode it
splices `name` into the Lua string literal, which is usually not what you want).
Write the interpolation in template text (`%p Hi #{name}`) or use concatenation
(`%p= "Hi " .. name`). In two-phase `=` code, `#{}` is an expression splice and
must sit in expression position, as in `%p= 'p-' .. #{x}`.

### Compile once, render many

`haml.compile` always returns a table, tagged with a metatable. `haml.render`
accepts strings and compiled tables, but rejects a bare `haml.parse` tree so a
“compiled” cache cannot silently become a re-parse. `haml.compile(compiled)` is
an error.

`lhtml` caches the last translation per handler: translating the same
two-stage intermediate string again costs about a microsecond instead of tens of
microseconds.

## Requirements

- Lua 5.1 or LuaJIT (the modules use `setfenv` / `loadstring`).
- [LPeg](http://www.inf.puc-rio.br/~roberto/lpeg/) 1.x.
- Optional: a `markdown` module if you use the `:markdown` filter.
- Tests use the bundled `json.lua`; no other runtime dependencies.

## Quick start

### CLI

```sh
luajit luahaml.lua sample.haml > sample.html
echo '%p hi' | luajit luahaml.lua -s
luajit luahaml.lua -i '%p hi'
luajit luahaml.lua -p -i '%p hi'     # print the AST
luajit luahaml.lua -c -i '%p hi'     # print the compiled tree
```

The CLI is a convenience wrapper, **not a sandbox**. Templates and the Lua
chunks generated from them run in the host process. Invalid templates exit
non-zero with an error on stderr.

### Single-stage library use

```lua
local haml = require "haml/init"

local html = haml.render("%ul\n  %li= 1 + 1\n  %li= 2 + 2", {}, {})
```

### Two-stage use (templates with `-` locals)

```lua
local haml  = require "haml/init"
local lhtml = require "lhtml"

local source = [[
- local title = "Hi"
%h1= title
]]

-- Compile once.  lhaml = true makes both `=` and `#{}` emit placeholders.
local compiled = haml.compile(haml.parse(source), { lhaml = true })

-- The intermediate string only depends on the template, not on locals.
local mid  = haml.render(compiled, { lhaml = true }, {})
local code = table.concat(lhtml(mid), "")   -- cached by lhtml

local printed = {}
local env = setmetatable({
  print = function (...) printed[#printed + 1] = tostring((...)) end,
}, { __index = _G })

local chunk = assert(loadstring(code))
setfenv(chunk, env)
chunk()

print(table.concat(printed, ""))   --> <h1>Hi</h1>
```

`env` is the second stage's global environment. Put `locals`, helper functions
and `print` there; do not assume the default `_G` is restricted.

## API contract

### `haml.parse(input[, options])`

Returns an AST table. Parse errors raise (`haml: parse error: ...`); they are no
longer printed to stdout and swallowed. `options` is accepted for compatibility
and currently unused by the parser.

### `haml.compile(input[, options[, locals]])`

- `input` is a Haml source string or an AST returned by `haml.parse`.
- Always returns a **table**, even for a single-node template such as
  `%p hi`. The table carries a private metatable marker that `haml.render`
  checks.
- Options that affect code generation (`format`, `escape_html` for
  `&=` / `!=` / `~`, `preserve`, `indent`, ...) are baked into the result.
  Render with the same options.
- The result is not JSON-serialisable in a useful way: the marker lives in the
  metatable and will be lost. Store the source, compile at startup.
- `haml.compile(compiled)` raises `haml: input is already compiled`.

### `haml.render(input[, options[, locals]])`

- `input` is Haml source or a table returned by `haml.compile`.
- Returns a string: HTML in the normal case, or an `lhtml` intermediate string
  when the template contains unresolved placeholders / `lhaml = true`.
- Rendering is repeatable and does not mutate the compiled tree.
- A bare `haml.parse` AST raises
  `haml: render expects Haml source or a compiled template (haml.compile)`.
- `locals` is a flat table used by `#{}`, `=` and attribute values. It is also
  used as the environment while trying to evaluate inline expressions, so
  values can shadow or extend globals for that evaluation.

### `haml.print_r(value)`

Debug printer for ASTs and compiled trees.

### `lhtml(input[, handler])`

Translates a string containing `<% ... %>` / `<%= ... %>` placeholders into an
array of Lua source chunks. `handler` is an optional function
`(code, instruction) -> lua_source`; the default produces `print(...)` calls.

- The input is parsed as **code**: any `<% ... %>` in it is a statement and any
  `<%= ... %>` is an expression. Never pass untrusted text to `lhtml`
  directly; `haml.render` has already neutralised data for you.
- The last translation is cached per handler. The cache returns a copy, so
  mutating the result cannot poison later calls. It holds one entry per handler;
  alternating many distinct inputs will miss.
- `luahaml.lua` supplies its own handler (it writes with `io.write` instead of
  `print`), so its grammar is rebuilt once per process.

### CLI options

| Flag | Meaning |
|---|---|
| `-s`, `--stdin` | read Haml from stdin |
| `-i`, `--inline` | read Haml from the next argument |
| `-p`, `--parse` | print the AST |
| `-c`, `--precompile` | print the compiled tree |
| `-h`, `-?`, `--help` | usage |
| `-v`, `--version` | version (read from `VERSION`) |

## Options

| Option | Default | Contract |
|---|---|---|
| `format` | `"xhtml"` | `"xhtml"`, `"html4"` or `"html5"`; affects doctype and void tags |
| `escape_html` | `false` | HTML-escape `=`, `#{}` and `locals`-substituted attribute values |
| `strict_eval` | `false` | raise when an expression cannot be evaluated against `locals` instead of leaving a placeholder for stage two |
| `lhaml` / `lhtml` | `nil` | two-phase mode: `=` and `#{}` emit `<%= ... %>` placeholders; the two names are aliases |
| `auto_close` | `true` | auto-close void elements from `closed` |
| `indent` | `"  "` | indentation step |
| `newline` | `"\n"` | newline used between nodes |
| `preserve` | `{ pre = true, textarea = true }` | tags whose content is preserved |
| `closed` | 10 void tags | `area base br col hr img input link meta param` |
| `html_escapes` | `' " & < >` | escape map; also used as the cache key for the compiled pattern |
| `encoding` | `"utf-8"` | written into the XML prolog only; no transcoding |
| `markdown` | `nil` | function used by the `:markdown` filter |

`suppress_eval` and `ugly` are accepted for compatibility but have no effect.
They are **not** security switches.

## Security model

### Templates are code

`haml.compile` can execute Lua embedded in a template:

- `!= expr`, `&= expr`, `~ expr` evaluate at compile time;
- `-` blocks and unresolved `=` expressions are emitted as placeholders and run
  by the second stage;
- `haml.render` of a compiled tree executes `=` expressions with `locals` as the
  environment.

Compile-time evaluation is wrapped in `pcall` and reports a readable error, but
that is error handling, not sandboxing. **Never compile a template supplied by
a user.** Template injection is remote code execution.

### What data neutralisation covers

For values from `locals`:

- `<%` is encoded, so the value cannot become an `lhtml` placeholder;
- `#{` and `\` are protected from the interpolation passes;
- `escape_html = true` escapes `< > & " '` in `=`, `#{}` and substituted
  attribute values.

What it does **not** cover:

- template text itself — `<% ... %>` written in the template is code;
- filter bodies (`:plain`, `:lua`, `:preserve`, `:markdown`);
- `!=`;
- quoted template-side attribute values (`title='#{u}'` keeps the quotes; the
  `#{}` part is still protected as data);
- `<script>` / `<style>` contexts — HTML entity escaping is not JavaScript or
  CSS escaping.

### Two-stage environments

The second stage runs in whatever environment the caller provides. `lhaml`
placeholders are `<%= expression %>`; if the environment exposes `os`, `io`,
`require`, `loadstring`, etc., the template can use them. The CLI uses `_G` and
documents itself as unsandboxed. If you need isolation, run in a separate
process or interpreter and pass only the names the template needs.

### `strict_eval`

By default an expression that cannot be evaluated against `locals` is left as a
placeholder for stage two. That keeps two-stage templates working, but it also
means tightening `locals` can push more code into the less restricted stage.
Set `strict_eval = true` when a template must not fall back:

```lua
haml.render("%p= error('boom')", { strict_eval = true }, {})
--> error: haml: embedded code failed: ...
```

It makes failures visible; it is not a sandbox.

### Limits

`compile` and `render` reject templates nested deeper than 200 levels with
`haml: template nested too deeply`. `parse` is LPeg-based and does not recurse,
so it is not affected.

### Direct `lhtml` use

`lhtml` itself does not know about `locals`. It treats any `<% ... %>` as code.
If you build the intermediate string yourself, escape or otherwise neutralise
untrusted values before calling it. The `#{}` protection described above is
implemented in `haml.render`, not in `lhtml`.

## Performance and caching

Measured on LuaJIT with `sample.haml` (2892 bytes):

```
parse                 ~300 µs
compile                ~80–110 µs
render (compiled)      ~75–85 µs
lhtml, first time      ~50–60 µs
lhtml, cached           ~0.5 µs
loadstring(code)       ~14 µs
```

`parse` dominates the full pipeline. Compile once and reuse the tree:

```lua
local compiled = haml.compile(haml.parse(source), options)
for _ = 1, n do
  local html = haml.render(compiled, options, locals)
end
```

For two-stage templates, cache the intermediate string and the generated code:

```lua
local mid  = haml.render(compiled, { lhaml = true }, {})
local code = table.concat(lhtml(mid), "")
-- per request: loadstring(code), setfenv, run
```

`loadstring` is not cached by the library because it depends on the per-request
environment. Cache the `code` string, not a `setfenv`-mutated function, unless
you are certain rendering is strictly sequential.

`lhtml`'s translation cache is one entry per handler. Alternating many distinct
intermediate strings will thrash it; in the normal two-stage pattern `mid` is
constant, so it is a hit every time.

## Best practices

1. **Treat templates as trusted code.** Do not accept template files or template
   fragments from users, and do not interpolate user input into a template
   before compiling it.
2. **Compile once per template and option set.** Cache the compiled table in a
   module; do not call `haml.render(source)` on every request.
3. **Use two stages only when you need them.** If all data arrives through
   `locals`, single-stage `haml.render` is simpler and avoids an execution
   environment to secure.
4. **Keep `locals` flat.** `#{g}` is a single-key lookup in normal mode; dot
   paths like `#{g.en}` are output literally.
5. **Enable `escape_html` for untrusted data**, and still escape per context:
   HTML text, attribute values, URLs, JavaScript and CSS need different
   escaping. Do not rely on HTML escaping inside `<script>` or `<style>`.
6. **Prefer `=` over `!=` and `~`** when the value can come from outside.
   `!=` deliberately skips escaping; `~` preserves raw newlines.
7. **Do not put untrusted data into `:plain` / `:lua` / `:preserve` /
   `:markdown` bodies.** Filter output is not escaped.
8. **Set `strict_eval = true` in request handlers** unless you rely on the
   fallback for `-`-defined locals. It turns silent placeholders into errors.
9. **Treat the second-stage environment as a capability list.** Expose `print`,
   the locals you intend, and nothing else. Never expose `_G` wholesale to
   templates you do not fully trust.
10. **Wrap render/loadstring in `pcall` at the application boundary** and turn
    failures into a 500, not a partial page. Parse errors, evaluation errors and
    the depth limit all raise.
11. **Do not serialize compiled templates.** The marker is a metatable; JSON or
    a plain Lua table dump loses it. Store source and compile at startup.
12. **Pin the version and run the test suites** after upgrading:
    `luajit test.lua`, `luajit test_lhtml.lua`, `luajit test_security.lua`.

## Compatibility with Ruby Haml

Lua Haml aims to be close to Ruby Haml, with these deliberate differences:

- script blocks are Lua, not Ruby;
- `:maruku`, `:ruby` and `:sass` filters are not implemented;
- no attribute methods, object references, or custom filter registration;
- no “ugly” mode;
- `#{}` is a `locals` lookup in normal mode, not a Ruby expression;
- nested `data-*` / `aria-*` attributes are not expanded; write the full name;
- `find_and_preserve` does not exist; use `~` or the `:preserve` filter.

See [REFERENCE.md](REFERENCE.md) for the full behaviour, including the known
limitations table.

## Development

```sh
luajit test.lua            # JSON suite (144 cases)
luajit test_lhtml.lua      # lhtml unit tests (41 assertions)
luajit test_security.lua   # error paths and contracts (17 assertions)
luajit luahaml.lua sample.haml
luajit bench.lua sample.haml 10000
```

`spec/tests_patch.json` holds this project's regression cases inside the
`spec/` submodule; changes there need a commit in the submodule first, then a
pointer update in this repository. `AGENT.md` documents the file map and the
traps for coding agents. Version bumps touch `VERSION`, `haml/init.lua`
(`lit-meta`) and `Changelog.md`.

## License

The MIT License

Copyright (c) 2009-2010 Norman Clarke

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
