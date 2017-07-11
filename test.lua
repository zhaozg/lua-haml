local haml      = require 'haml'
local json      = require 'json' or
                  require'dkjson' or
                  error('not found any json module')

--[[
### Test JSON format ###

    "test name" : {
      "haml"     : "haml input",
      "html"     : "expected html output",
      "result"   : "expected test result",
      "locals"   : "local vars",
      "config"   : "config params",
      "optional" : true|false
    }

* test name: This should be a *very* brief description of what's being tested. It can
  be used by the test runners to name test methods, or to exclude certain tests from being
  run.
* haml: The Haml code to be evaluated. Always required.
* html: The HTML output that should be generated. Required unless "result" is "error".
* result: Can be "pass" or "error". If it's absent, then "pass" is assumed. If it's "error",
  then the goal of the test is to make sure that malformed Haml code generates an error.
* locals: An object containing local variables needed for the test.
* config: An object containing configuration parameters used to run the test.
  The configuration parameters should be usable directly by Ruby's Haml with no
  modification.  If your implementation uses config parameters with different
  names, you may need to process them to make them match your implementation.
  If your implementation has options that do not exist in Ruby's Haml, then you
  should add tests for this in your implementation's test rather than here.
* optional: whether or not the test is optional
--]]
local path = arg[1] and arg[1] or 'spec/tests.json'
local abort = arg[2]

local f = assert(io.open(path,'rb'))
local ctx = f:read("*a")
f:close()

local j = json.decode(ctx)

local ha,ht
for k,test in pairs(j) do
  print('>   TESTING '..k)
  for K,T in pairs(test) do
    print('>>  '..K)
    ha, ht = T.haml, T.html
    --[[
      "haml"     : "haml input",
      "html"     : "expected html output",
      "result"   : "expected test result",
      "locals"   : "local vars",
      "config"   : "config params",
      "optional" : true|false
    --]]

    html = haml.render(T.haml,T.config or {}, T.locals)
    --[[
    local ret,html = pcall(haml.render,T.haml,T.config or {}, T.locals)
    if not ret then
      html = ''
    end
    --]]
    if (html~=T.html ) then
      print('HAML:'..T.haml)
      print(string.format('NEED(%d):%s',#T.html,T.html))
      print(string.format('BUT (%d):%s',#html,html))
      if abort then
        print('Fail')
        return
      end
    else
      print('OK')
    end
  end
end
