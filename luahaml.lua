#!/usr/bin/env lua
local haml = require "haml/init"
local util = require "haml/util"
local long_bracket_level = util.long_bracket_level

-- The CLI has no sandbox: templates (and any data a caller wires in) run in
-- the host process.  Read the version from the checkout instead of the stale
-- literal this file used to carry.
local function read_version ()
  local dir = (arg and arg[0] or ''):match('^(.*[/\\])') or ''
  local fh = io.open(dir .. 'VERSION', 'rb')
  if not fh then return "0.4.3" end
  local v = (fh:read('*l') or '0.4.3'):gsub('%s+$', '')
  fh:close()
  return v
end
local VERSION = read_version()

local banner = "LuaHaml %s, copyright Norman Clarke <norman@njclarke.com> 2009-2012"

local usage = [[

Usage: luahaml [options] [filename]

Description:
  Uses the Haml engine to process the specified input and prints
  the result to standard output.

Options:

  -s,     --stdin          Read from standard input, outputting processed Haml
  -i,     --inline         Like -s, but read input from command line
  -p,     --parse          Show the parser's output for debugging
  -c,     --precompile     Show the precompiler's output for debugging
  -v,     --version        Show the LuaHaml version
  -?,-h,  --help           Show this message

Examples:

  Render a template:
  # luahaml my_template.haml > my_template.haml

  Read input from the command line and render
  # luahaml -i '%p'

  Read input from the command line and show the parser info
  # luahaml -p -i '%p'

]]

local haml_options = { format = "xhtml" }

local function read_file()
  local file = arg[#arg]
  haml_options.file = file
  local fh = assert(io.open(file, "rb"))
  local input = fh:read '*a'
  fh:close()
  return input
end

local function read_stdin()
  return io.stdin:read('*a')
end

local function run_parser(haml_string)
  local phrases = haml.parse(haml_string)
  haml.print_r(phrases)
end

local function run_precompiler(haml_string)
  local compiled = haml.compile(haml.parse(haml_string), haml_options)
  haml.print_r(compiled)
end

local function render(haml_string)
  local output = haml.render(haml_string, haml_options)
  local r, lhtml = pcall(require, 'lhtml')
  if r then
    -- Choose the long-bracket level from the text itself.  The old code hard
    -- coded four '=' here and three in lhtml; any text containing the matching
    -- terminator escaped the string and became Lua code.
    local function interpolate_code (str, lvl)
      local eq = string.rep('=', lvl)
      local close = ']' .. eq .. ']) io.write('
      local open = ') io.write([' .. eq .. '['
      return str:gsub('([\\]*)#{(.-)}', function(slashes, match)
        if #slashes == 1 then
          return '#{' .. match .. '}'
        end
        return close .. slashes .. match .. open
      end)
    end

    local function wrap_write (code, lvl)
      local eq = string.rep('=', lvl)
      return string.format('io.write([%s[%s]%s])', eq, code, eq)
    end

    local function _totable(code, ins)
      if code then
        if not ins then
          if #code > 0 then
            local lvl = long_bracket_level(code)
            if lvl < 4 then lvl = 4 end
            code = wrap_write(interpolate_code(code, lvl), lvl)
          end
          return code
        elseif ins == '=' then
          if code:find('([\\]*)#{(.-)}') then
            local lvl = long_bracket_level(code)
            return wrap_write(interpolate_code(code, lvl), lvl)
          else
            return string.format('io.write(%s)', code)
          end
        elseif ins == '' then
          return code
        else
          error(string.format('handle %s failed for\n%s', ins, code))
        end
      end
    end

    local html = lhtml(output, _totable)
    html = table.concat(html, '')
    html = assert(loadstring(html))
    return html()
  end
  print(output)
end

local function show_banner()
  print(string.format(banner, VERSION))
end

local function show_usage()
  print(usage)
end

local exec_func = render
local input_func = read_file

if #arg == 0 then
  show_usage()
  os.exit()
end

for i, v in ipairs(arg) do
  if v == '-c' or v == '--precompile' then
    exec_func = run_precompiler
  elseif v == '-p' or v == '--parse' then
    exec_func = run_parser
  elseif v == '-s' or v == '--stdin' then
    input_func = read_stdin
  elseif v == '-i' or v == '--inline' then
    local input = arg[i + 1]
    input_func = function() return input end
  elseif v == '-h' or v == '--help' or v == '-?' then
    show_banner()
    show_usage()
    os.exit()
  elseif v == '-v' or v == '--version' then
    show_banner()
    os.exit()
  elseif string.match(v, "^-[a-z0-9%-]") then
    print(string.format('Invalid argument "%s"', v))
    show_usage()
    os.exit()
  end
end
-- Run without pretending to sandbox: the previous `_ENV` table was never
-- passed to haml.render and the generated chunk was never setfenv'd, so both
-- stages already had full access to _G.
local ok, err = pcall(function () return exec_func(input_func()) end)
if not ok then
  io.stderr:write(tostring(err), '\n')
  os.exit(1)
end
