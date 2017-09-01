local lpeg = require"lpeg"

local P,S = lpeg.P,lpeg.S
local    C,     Cb,     Cg,     Ct
  = lpeg.C,lpeg.Cb,lpeg.Cg,lpeg.Ct

--begin, end, instruction
local B,E,I = P("<%"),P("%>"),S("=!@")^-1
--not begin of code, not end of code
local NB, NE = (1 - B)^0, (1 - E)^0
--embed script
local CODE = B * Cg(I,'INS')*C(NE*Cb('INS')) * E
--full grammer
--local grammer = (NB * CODE)^0  * NB

--default process, all captured result as table
local function _totable(code,ins)
    if not ins then
        if #code>0 then
            return 'print([===['..code..']===])'
        end
    elseif ins=='!' then
        return 'include([['..code..']])'
    elseif ins=='@' then
        return 'at([['..code..']])'
    elseif ins=='=' then
        return 'print(tostring('..code..'))'
    elseif ins=='' then
        return code
    else
        error(string.format('handle %s failed for\n%s',ins,code))
    end
end

--compile and return captured table
local function compile(s, handle)
    handle = handle or _totable
    local NBH = NB/handle
    local CODEH = CODE/handle
    local grammer = Ct ( (NBH * CODEH)^0  * NBH)
    return grammer:match(s)
end

-------------test section-----------------------------------------------------
--[=[
local M = {}
local io = require 'enhance.io'
function M.totable(s)
    local _ = compile(s,_totable)
    local env = _G
    function env.include(...)
        print(...)
    end
    function env.at(...)
        print(...)
    end

    a = table.concat(_)
    f = loadstring(a)
    setfenv(f,env)
    f()
end
local t = [==[

<% local title = "Lua Haml: Currently Supported Language" %>
<?xml version='1.0' encoding='utf-8' ?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
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
<% local greetings = {en = "hello world!", es = "?hola mundo!", pt = "ol¨¢ mundo!"} %>
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
local function test()
	local content = '<% a=1 b=1 abc="abc" %>B"B"B<%= abc %><h1>h1</h1><%! a.html %>cc'
	print('after translate')
    M.totable(content)

	t1 = '<% a=1 b=1 aa=aaa %>B"B"B<%= abcd %><h1>h1</h1><%! a.html %>cc<% %>'
	print('after translate')
    M.totable(t1)
    M.totable(t)
end
test()
--]=]

return compile
