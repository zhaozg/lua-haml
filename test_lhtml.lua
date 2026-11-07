--[==[
  test_lhtml.lua -- unit tests for lhtml.lua

  lhtml translates a string containing <% %> placeholders into Lua source,
  which the caller then loads and runs:

    plain text          ->  print([===[text]===])
    <%= expression %>   ->  print(tostring(expression))
    <% statement %>     ->  the statement, emitted verbatim
    <%! file %>         ->  include([[file]])
    <%@ name %>         ->  at([[name]])

  The instruction character must sit directly after "<%" -- with a space
  ("<% !file %>") it is treated as an ordinary statement block.

  Run with:  luajit test_lhtml.lua
  Exits non-zero when an assertion fails.
]==]

local compile = require "lhtml"

local type, tostring, select = type, tostring, select
local concat = table.concat
local setmetatable = setmetatable
local loadstring = loadstring or load
local setfenv = setfenv

------------------------------------------------------------------------------
--- Test harness
------------------------------------------------------------------------------

local passed, failed = 0, 0

local function fail (name, msg)
  failed = failed + 1
  print(string.format('Fail %s', name))
  print('  ' .. tostring(msg):gsub('\n', '\n  '))
end

local function ok (name)
  passed = passed + 1
  print('Ok   ' .. name)
end

--- Translate a string of Lua-flavoured HTML into Lua source.
local function translate (src)
  return concat(compile(src) or {}, '')
end

--- Run translated source in a sandbox and return what it printed.
-- lhtml emits one print() per fragment, so a template becomes several prints.
-- The downstream consumer (test.lua) collects every printed argument and joins
-- them with the empty string; this harness mirrors that exactly, so a value
-- spanning several fragments comes back as contiguous output.
-- @param src     translated Lua source (see translate)
-- @param sandbox extra names visible to the chunk (e.g. include, at)
local function run (src, sandbox)
  local out = {}
  local env = setmetatable({
    print = function (...)
      for i = 1, select('#', ...) do
        out[#out + 1] = tostring((select(i, ...)))
      end
    end,
  }, { __index = _G })

  for k, v in pairs(sandbox or {}) do env[k] = v end

  local chunk = assert(loadstring(src), 'loadstring failed for: ' .. src)
  if type(setfenv) == 'function' then
    setfenv(chunk, env)
    chunk()
  else
    -- Lua 5.2+ passes the environment as the sole upvalue.
    chunk(env)
  end
  return concat(out, '')
end

--- Convenience: translate then run.
local function render (src, sandbox)
  return run(translate(src), sandbox)
end

local function eq (name, actual, expected)
  if actual == expected then
    ok(name)
  else
    fail(name, string.format('expected: %q\nactual:   %q', expected, actual))
  end
end

local function contains (name, haystack, needle)
  if haystack:find(needle, 1, true) then
    ok(name)
  else
    fail(name, string.format('%q not found in\n%q', needle, haystack))
  end
end

local function lacks (name, haystack, needle)
  if haystack:find(needle, 1, true) then
    fail(name, string.format('unexpected %q in\n%q', needle, haystack))
  else
    ok(name)
  end
end

------------------------------------------------------------------------------
--- Translation: structure of the generated source
------------------------------------------------------------------------------

do
  local T = 'translation'

  eq(T .. ': empty input yields no code', translate(''), '')
  eq(T .. ': bare text is wrapped in print',
     translate('abc'), 'print([===[abc]===])')
  eq(T .. ': = expression becomes print(tostring(...))',
     translate('<%= 1 %>'), 'print(tostring( 1 ))')
  eq(T .. ': statement block is emitted verbatim',
     translate('<% local a = 1 %>'), ' local a = 1 ')
  eq(T .. ': ! block becomes include()',
     translate('<%! a.html %>'), 'include([[ a.html ]])')
  eq(T .. ': @ block becomes at()',
     translate('<%@foo%>'), 'at([[foo]])')
  eq(T .. ': empty block keeps its whitespace',
     translate('<% %>'), ' ')

  -- One placeholder per chunk, in source order.
  local pieces = compile('a<%=1%>b')
  eq(T .. ': text/code/text produces three chunks', #pieces, 3)
  eq(T .. ': chunks preserve order', concat(pieces, '|'),
     'print([===[a]===])|print(tostring(1))|print([===[b]===])')
end

------------------------------------------------------------------------------
--- Translation: instruction must be adjacent to the opening delimiter
------------------------------------------------------------------------------

do
  local T = 'instruction adjacency'

  -- A space after <% makes the instruction vanish, so the block is treated
  -- as ordinary statements rather than include() / at().
  eq(T .. ': "<% @foo %>" is a plain statement, not at()',
     translate('<% @foo %>'), ' @foo ')
  eq(T .. ': "<% !x %>" is a plain statement, not include()',
     translate('<% !x %>'), ' !x ')
  eq(T .. ': "<%@ foo%>" still becomes at()',
     translate('<%@ foo%>'), 'at([[ foo]])')
end

------------------------------------------------------------------------------
--- Execution: translated source actually runs
------------------------------------------------------------------------------

do
  local T = 'execution'

  eq(T .. ': plain text', render('abc'), 'abc')
  eq(T .. ': interpolation', render('<%= 1 + 1 %>'), '2')
  eq(T .. ': statement then interpolation', render('<% local a = 1 %>x<%= a %>'), 'x1')
  eq(T .. ': multiple blocks concatenate', render('a<%=1%>b'), 'a1b')
  eq(T .. ': interleaved text keeps order',
     render('<% local n = 0 %><%= n %><% n = n + 1 %><%= n %>'), '01')

  -- include / at are supplied by the caller, not by lhtml.
  local seen = {}
  render('<%! a.html %><%@b%>', {
    include = function (f) seen[#seen + 1] = 'include:' .. f end,
    at      = function (a) seen[#seen + 1] = 'at:' .. a end,
  })
  eq(T .. ': include and at are invoked', concat(seen, ','), 'include: a.html ,at:b')
end

------------------------------------------------------------------------------
--- Integration: the reference template
------------------------------------------------------------------------------

local TEMPLATE = [==[
<% local title = "Lua Haml: Currently Supported Language" %>
<?xml version='1.0' encoding='utf-8' ?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
  "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html lang="en" xml:lang="en" xmlns="http://www.w3.org/1999/xhtml">
  <head>
    <title><%= title %></title>
    <meta content="text/html; charset=utf-8" http-equiv="Content-Type" />
    <style type='text/css'>
    /*<![CDATA[*/
      body { background-color: #0ff }
      h1 { font-size: 25px; }
      textarea { font-family: monaco, fixed; font-size: 14px; }
    /*]]>*/
    </style>
  </head>
  <body>
    <h1><%= title %></h1>
    <p>
      This file demonstrates most of Lua Haml's features.
    </p>
    <p>
      If you're viewing the output and wondering what's so interesting, then
      you should probably be looking at the Haml source instead.
    </p>
    <div id='content'>
<% local greetings = {en = "hello world!", es = "?hola mundo!", pt = "olá mundo!"} %>
      <ul class='multilingual' id='greetings'>
<% for lang, greeting in pairs(greetings) do %>
          <li class='greeting lang'><%= greeting %></li>
<% end %>
      </ul>
    </div>
    <p>
      &lt;&#039;&quot;escaped &amp; escaped&quot;&#039;&gt;
      <'"NOT escaped & escaped"'>
<%= "<'\"MAYBE escaped & escaped\"'> (depending on runtime options)" %>
    </p>
    <div id='escaped_content'>
      #this content is escaped
    </div>
  </body>
</html>
]==]

do
  local T = 'template'
  local html = render(TEMPLATE)

  contains(T .. ': title is interpolated twice', html,
           '<title>Lua Haml: Currently Supported Language</title>')
  contains(T .. ': heading is interpolated', html,
           '<h1>Lua Haml: Currently Supported Language</h1>')

  -- pairs() order over the greetings table is unspecified, so assert on
  -- membership rather than exact ordering.
  contains(T .. ': english greeting present', html, 'hello world!')
  contains(T .. ': spanish greeting present', html, 'hola mundo!')
  contains(T .. ': portuguese greeting present', html, 'olá mundo!')
  eq(T .. ': one list item per greeting',
     select(2, html:gsub("<li class='greeting lang'>", '')), 3)

  -- lhtml performs no escaping of its own; entities pass through verbatim.
  contains(T .. ': entities are untouched', html,
           '&lt;&#039;&quot;escaped &amp; escaped&quot;&#039;&gt;')
  contains(T .. ': raw angle brackets survive', html, "<'\"NOT escaped & escaped\"'>")

  -- CDATA markers inside <style> must not confuse the long-bracket quoting.
  contains(T .. ': CDATA open survives', html, '/*<![CDATA[*/')
  contains(T .. ': CDATA close survives', html, '/*]]>*/')

  lacks(T .. ': no placeholder remains', html, '<%')
  contains(T .. ': doctype is emitted', html, 'XHTML 1.0 Transitional')
end

------------------------------------------------------------------------------
--- Integration: the original round-trip samples
------------------------------------------------------------------------------

do
  local T = 'round-trip'

  -- a, b and aa are assigned; abc is read back; a.html goes to include().
  local content = '<% a=1 b=1 abc="abc" %>B"B"B<%= abc %><h1>h1</h1><%! a.html %>cc'
  local included
  local out = render(content, {
    include = function (f) included = f end,
  })
  eq(T .. ': assignments and interpolation', out, 'B"B"Babc<h1>h1</h1>cc')
  eq(T .. ': include receives the argument verbatim', included, ' a.html ')

  -- Undefined names degrade to the string "nil" rather than raising, and a
  -- trailing empty block contributes nothing.
  local t1 = '<% a=1 b=1 aa=aaa %>B"B"B<%= abcd %><h1>h1</h1><%! a.html %>cc<% %>'
  local out1 = render(t1, { include = function () end })
  eq(T .. ': undefined identifier renders as nil', out1, 'B"B"Bnil<h1>h1</h1>cc')
end

------------------------------------------------------------------------------
--- Translation: hostile / malformed input
------------------------------------------------------------------------------

do
  local T = 'hardening'

  -- Text is wrapped at whatever level its own content requires, so a payload
  -- that used to close the long string is now just text.
  eq(T .. ': text raises the bracket level',
     translate(']===]'), 'print([====[]===]]====])')

  -- include()/at() arguments get the same treatment (the old code used level 0).
  eq(T .. ': include raises the bracket level',
     translate('<%! a ]=] b %>'), 'include([==[ a ]=] b ]==])')

  -- A "<%" without a closing "%>" used to stop the grammar and silently drop
  -- the rest of the document.  It is text now.
  eq(T .. ': unmatched <% is text',
     translate('a <% b'), 'print([===[a ]===])print([===[<% b]===])')
  eq(T .. ': unmatched <% is preserved when run', render('a <% b'), 'a <% b')
end

------------------------------------------------------------------------------
--- Summary
------------------------------------------------------------------------------

print('')
if failed == 0 then
  print(string.format('Test all passed (%d assertions)', passed))
else
  print(string.format('Test fail %d in %d, %02d%% passed',
    failed, passed + failed, (100 * passed / (passed + failed))))
  os.exit(1)
end
