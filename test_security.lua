--[==[
  test_security.lua -- error-path and hardening checks.

  These cases cannot be expressed in the JSON suite (which compares output),
  so they live here: strict_eval, the nesting limit, parse errors, and the
  guarantee that compile() no longer evaluates standalone `=` expressions.

  Run with:  luajit test_security.lua
  Exits non-zero when an assertion fails.
]==]

local haml = require "haml/init"

local passed, failed = 0, 0

local function ok (name, cond, extra)
  if cond then
    passed = passed + 1
    print('Ok   ' .. name)
  else
    failed = failed + 1
    print('Fail ' .. name)
    if extra then print('  ' .. tostring(extra)) end
  end
end

local function raises (name, f, needle)
  local okc, err = pcall(f)
  ok(name, not okc and (not needle or tostring(err):find(needle, 1, true)),
     okc and 'did not raise' or err)
end

--- Render a template through the full two-stage pipeline the way test.lua does.
local function render (tpl, options, locals)
  local lhtml = require "lhtml"
  local mid = haml.render(tpl, options, locals)
  local code = table.concat(assert(lhtml(mid)), '')
  local out = {}
  local env = setmetatable({
    print = function (...) out[#out + 1] = tostring((...)) end,
  }, { __index = _G })
  local chunk = assert(loadstring(code))
  setfenv(chunk, env)
  chunk()
  return table.concat(out, '')
end

------------------------------------------------------------------------------
--- strict_eval
------------------------------------------------------------------------------

do
  local tpl = "%p= os.execute('touch /tmp/lua-haml-review/strict')"

  ok('strict_eval leaves the fallback off by default',
     haml.render(tpl, {}, {}) == "<p><%= os.execute('touch /tmp/lua-haml-review/strict') %></p>")

  raises('strict_eval turns an unevaluable expression into an error',
     function () haml.render(tpl, { strict_eval = true }, {}) end, 'embedded code')

  raises('strict_eval reports the expression that failed',
     function () haml.render(tpl, { strict_eval = true }, {}) end, 'os.execute')
end

------------------------------------------------------------------------------
--- depth limit
------------------------------------------------------------------------------

do
  local function nested (n)
    local t = { '%div' }
    for i = 1, n do
      t[#t + 1] = string.rep('  ', i) .. '%div'
    end
    return table.concat(t, '\n')
  end

  ok('a 100-level template still renders',
     type(render(nested(100), {}, {})) == 'string')

  raises('render refuses a 250-level template',
     function () haml.render(nested(250), {}, {}) end, 'nested too deeply')

  raises('compile refuses a 250-level template',
     function () haml.compile(haml.parse(nested(250)), {}) end, 'nested too deeply')
end

------------------------------------------------------------------------------
--- parse errors are no longer swallowed
------------------------------------------------------------------------------

do
  raises('inconsistent indentation raises a parse error',
     function () haml.parse('%div\n     %p\n  %span') end, 'inconsistent indentation')

  raises('haml.render propagates parse errors',
     function () haml.render('%div\n     %p\n  %span', {}, {}) end, 'parse error')
end

------------------------------------------------------------------------------
--- compile() must not evaluate standalone `=`
------------------------------------------------------------------------------

do
  _G.__haml_compile_pwn = nil
  haml.compile(haml.parse("= (function() __haml_compile_pwn = 1 return '' end)()"),
    { escape_html = true }, {})
  ok('compile leaves = for render', _G.__haml_compile_pwn == nil)

  -- != / &= / ~ still evaluate at compile time, as documented.
  _G.__haml_bang_pwn = nil
  haml.compile(haml.parse("!= (function() __haml_bang_pwn = 1 return '' end)()"), {}, {})
  ok('compile still evaluates !=', _G.__haml_bang_pwn == 1)
  _G.__haml_bang_pwn = nil
end

------------------------------------------------------------------------------
--- small robustness checks
------------------------------------------------------------------------------

do
  ok('table values in #{} do not raise',
     haml.render('%p v=#{t}', {}, { t = { 1, 2 } }):find('table: ', 1, true) ~= nil)

  ok('% in a #{} value is not re-interpreted',
     haml.render('%p #{v}', {}, { v = '100%' }) == '<p>100%</p>')
end

print('')
if failed == 0 then
  print(string.format('Test all passed (%d assertions)', passed))
else
  print(string.format('Test fail %d in %d', failed, passed + failed))
  os.exit(1)
end
