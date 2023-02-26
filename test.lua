local haml = require "haml/init"
local json = require 'json' or
    require 'dkjson' or
    error('not found any json module')
assert(json)

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

local function test_suite(specs)

  local f = assert(io.open(specs, 'rb'))
  local ctx = f:read("*a")
  f:close()

  local j = json.decode(ctx)
  local count, fail = 0, 0

  for k, test in pairs(j) do
    print('>>   TESTING ' .. k)
    local html
    for K, T in pairs(test) do
      T.config = T.config or {}
      count = count + 1
      --[[
      "haml"     : "haml input",
      "html"     : "expected html output",
      "result"   : "expected test result",
      "locals"   : "local vars",
      "config"   : "config params",
      "optional" : true|false
      --]]

      T.config.sort = true

      html = haml.render(T.haml, T.config, T.locals)
      --[[
      local ret,html = pcall(haml.render,T.haml,cnf,T.locals)
      if not ret then
        html = ''
      end
      --]]
      if T.config then
        local lhtml_compile = require 'lhtml'
        html = assert(lhtml_compile(html))
        html = table.concat(html, '')
        html = assert(loadstring(html))
        local _ret = {}
        local _ENV = {
          print = function(...)
            table.insert(_ret, ...)
          end
        }
        setmetatable(_ENV, { __index = _G })
        if type(setfenv) == 'function' then
          setfenv(html, _ENV)
          html()
        else
          html(_ENV)
        end
        html = table.concat(_ret, '')
      end
      if (html ~= T.html) then
        print('HAML:' .. T.haml)
        print(string.format('NEED(%d):%s', #T.html, T.html))
        print(string.format('BUT (%d):%s', #html, html))
        fail = fail + 1
        print('Fail ' .. K);
      else
        print('Ok   ' .. K);
      end
    end
  end
  return count, fail
end

local function main()
  local suites = {
    'spec/tests.json',
    'spec/tests_ext.json',
    'spec/tests_lhtml.json',
  }
  local all, fail = {}, {}
  for i = 1, #suites do
    all[i], fail[i] = test_suite(suites[i])
  end

  local function count(ary)
    local ret = 0
    for i = 1, #ary do
      ret = ret + ary[i]
    end
    return ret
  end

  local iAll, iFail = count(all), count(fail)
  if iFail == 0 then
    print("Test all passed");
  else
    print(string.format("Test fail %d in %d, %02d%% passed", iFail, iAll, (100 * (iAll - iFail) / iAll)))
  end
end

main()
