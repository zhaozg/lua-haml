local parser = require "haml.parser"
local render = require "haml.render"
local compile = require "haml.compile"
local util = require "haml.util"

local select = select
local type = type
local pairs = pairs

--- An implementation of the Haml markup language for Lua.
-- <p>
-- For more information on Haml, please see <a href="http://haml.info">The Haml website</a>
-- and the <a href="http://haml.info/docs/yardoc/file.HAML_REFERENCE.html">Haml language reference</a>.
-- </p>

--- Default Haml options.
-- @field format The output format. Can be xhtml, html4 or html5. Defaults to xhtml.
-- @field encoding The output encoding. Defaults to utf-8. Note that this is merely informative; no recoding is done.
-- @field newline The string value to use for newlines. Defaults to "\n".
-- @field space The string value to use for spaces. Defaults to " ".
local _options = {
  adapter = "lua",
  attribute_wrapper = "'",
  auto_close = true,
  escape_html = false,
  encoding = "utf-8",
  format = "xhtml",
  indent = '  ',
  newline = "\n",
  preserve = {
    pre = true,
    textarea = true,
  },
  suppress_eval = false,
  -- provided for compatiblity; does nothing
  ugly = false,
  html_escapes = {
    ["'"] = '&#039;',
    ['"'] = '&quot;',
    ['&'] = '&amp;',
    ['<'] = '&lt;',
    ['>'] = '&gt;',
  },
  closed = {
    area = true,
    base = true,
    br = true,
    col = true,
    hr = true,
    img = true,
    input = true,
    link = true,
    meta = true,
    param = true,
  },

  tidy = false,
}

--- Merge two or more tables together.
-- Duplicate keys are overridden left to right, so for example merge(t1, t2)
-- will use key values from t2.
-- @return A table containing all the values of all the tables.
local function merge_tables (...)
  local numargs = select('#', ...)
  local out = {}
  for i = 1, numargs do
    local t = select(i, ...)
    if type(t) == "table" then
      for k, v in pairs(t) do
        out[k] = v
      end
    end
  end
  return out
end

local M = {}

function M.parse (haml_string,options)
  return parser(haml_string:gsub('^' .. string.char(0xEF, 0xBB, 0xBF), ''),options)
end

function M.compile (input, options, locals)
  options = merge_tables(_options, options or {})
  if type(input) == 'string' then
    input = parser(input)
  end
  return compile(input, options, locals)
end

--- Render a Haml file.
-- @param haml_string The Haml file
-- @param options Options for the precompiler
-- @param locals Local variable values to set for the rendered template
function M.render (haml_string, options, locals)
  local compiled
  options = merge_tables(_options, options or {})
  if type(haml_string) == 'string' then
    local parsed = M.parse(haml_string)
    compiled = compile(parsed, options, locals)
  else
    compiled = haml_string
  end
  return render(compiled, options, locals)
end

M.print_r = util.print_r

return M
