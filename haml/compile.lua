local pairs = pairs
local require = require
local type = type
local select = select
local error = error
local loadstring = loadstring
local tostring = tostring
local unpack = table.unpack or unpack
local insert = table.insert
local concat = table.concat
local format = string.format
local gsub = string.gsub

local filter = require 'haml.filter'

--- Merge two or more tables together.
-- Duplicate keys cause the value to be added as a table containing all the
-- values for the key in every table.
-- @return A table containing all the values of all the tables.
local function join_tables (...)
  local numargs = select('#', ...)
  local out = {}
  for i = 1, numargs do
    local t = select(i, ...)
    if type(t) == "table" then
      for k, v in pairs(t) do
        if out[k] then
          if type(out[k]) == "table" then
            insert(out[k], v)
          else
            out[k] = {
              out[k],
              v,

            }
          end
        else
          out[k] = v
        end
      end
    end
  end
  return out
end

--- header
--- The HTML4 doctypes; default is 4.01 Transitional.
local html_doctypes = {
  ["5"] = '<!DOCTYPE html>',
  STRICT = '<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">',
  FRAMESET = '<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Frameset//EN" "http://www.w3.org/TR/html4/frameset.dtd">',
  DEFAULT = '<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">',

}
--- The XHTML doctypes; default is 1.0 Transitional.
local xhtml_doctypes = {
  ["5"] = html_doctypes["5"],
  STRICT = '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">',
  FRAMESET = '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Frameset//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-frameset.dtd">',
  MOBILE = '<!DOCTYPE html PUBLIC "-//WAPFORUM//DTD XHTML Mobile 1.2//EN" "http://www.openmobilealliance.org/tech/DTD/xhtml-mobile12.dtd">',
  BASIC = '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML Basic 1.1//EN" "http://www.w3.org/TR/xhtml-basic/xhtml-basic11.dtd">',
  DEFAULT = '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">',

}

--- Returns an XML prolog for the precompiler state.
local function prolog_for (node, options)
  if options.format:match "^html" then
    return nil
  end
  local charset = node.charset or options.encoding
  return format("<?xml version='1.0' encoding='%s' ?>", charset)
end

--- Returns an (X)HTML doctype for the precompiler state.
local function doctype_for (node, options)
  if options.format == 'html5' then
    return html_doctypes["5"]
  elseif node.version == "1.1" then
    return '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">'
  elseif options.format == 'xhtml' then
    return xhtml_doctypes[node.doctype] or xhtml_doctypes.DEFAULT
  elseif options.format == 'html4' then
    return html_doctypes[node.doctype] or html_doctypes.DEFAULT
  else
    error('don\'t understand doctype "%s"', node.doctype)
  end
end

--- Returns an XML prolog or an X(HTML) doctype for the precompiler state.
local function header_for (node, options)
  if node.prolog then
    return prolog_for(node, options)
  else
    return doctype_for(node, options)
  end
end

--- comment_for
local function comment_for (node, options)
  if node.operator == "markup_comment" then
    if node.unparsed then
      return "<!-- " .. node.unparsed .. " -->"
    else
      local clone = {}
      for k, v in pairs(node) do
        clone[k] = v
        if type(k) == 'number' then
          node[k] = nil
        end
      end
      clone.space = node.space .. options.indent
      clone.operator = nil
      insert(node, '<!--')
      insert(node, clone)
      insert(node, '-->')
    end
  elseif node.operator == "conditional_comment" then
    local child = node[1]
    node[1] = format("<!--[%s]>", node.condition)
    node[2] = {
      child,
      space = node.space .. options.indent,

    }
    node[3] = "<![endif]-->"
    node.condition = nil
    node.operator = nil
  end
  return node
end

--- tag
-- Precompile an (X)HTML tag for the current precompiler state.
local function tag_for (node, parent, options)
  local ctx
  if node.outer_whitespace_modifier then
    if parent then
      parent.inner_whitespace_modifier = node.outer_whitespace_modifier
    end
    node.outer_whitespace_modifier = nil
  end

  if node.inline_content then
    ctx = node.inline_content
  elseif node.inner_whitespace_modifier then
    ctx = concat(node, options.newline)
  end

  if ctx then
    local T = join_tables({}, node.css, unpack(node.attributes or {}))
    local a = {}
    for k, v in pairs(T) do
      a[#a + 1] = type(v) == 'string' and format('%s=%s', k, v) or format('%s="%s"', k, concat(v, ' '))
    end
    node = #a > 0 and format('<%s %s>%s</%s>', node.tag, concat(a, ' '), ctx, node.tag) or format('<%s>%s</%s>', node.tag, ctx, node.tag)
  else
    node = join_tables(node, node.css, unpack(node.attributes or {}))
    node.css, node.attributes = nil, nil
  end

  return node
end

--- code_for
local function escape_newlines (a, b, c)
  return a .. gsub(b, "\n", "&#x000A;") .. c
end

local function preserve_html (str, options)
  for tag, _ in pairs(options.preserve) do
    str = str:gsub(format("(<%s>)(.*)(</%s>)", tag, tag), escape_newlines)
  end
  return str
end

--escape html
local function code_for (node, options)
  if node.operator == "silent_script" then
    node.operator = nil
    node.tag = '-'

  elseif node.operator == "script" then
    node.operator = nil
    node.tag = '='
  else
    local code = tostring(loadstring('return ' .. node.code)())
    if node.operator ~= "unescaped_script" and (node.operator == "escaped_script" or options.escape_html) then
      return filter.escape_html(code, options.html_escapes)
    elseif node.operator == "preserved_script" then
      return preserve_html(code, options)
    else
      return code
    end
  end
  return node
end

local function handle_node (node, options, parent)
  local operator = node.operator
  if operator == "header" then
    node = header_for(node, options) or ''
  elseif operator == "filter" then
    node = filter.filter_for(node, options)
  elseif operator == "silent_comment" then
    node = ''
  elseif operator == "markup_comment" or operator == "conditional_comment" then
    node = comment_for(node, options)
  elseif operator == "script" then
    if options.escape_html then
      node[1] = filter.escape_html(loadstring('return ' .. node.code)(), options.html_escapes)
      node.code = nil
      node.script = nil
      node.operator = nil
    end
  end
  if node then
    if node.tag then
      return tag_for(node, parent, options)
    elseif node.code then
      return code_for(node, options)
    elseif node.unparsed then
      return node.unparsed
    end
  end
  return node
end

local function match_block (code, sibling)
  if sibling then
    if code:match "%s*else%s*$" or code:match "%s*do%s*$" then
      if not sibling:match "%s*end%s*$" then
        return 'end'
      end
    end
    if code:match "^%s*if.*" or code:match "^%s*elseif.*" then
      if not (sibling:match "%s*end%s*$" or sibling:match "%s*else%s*" or sibling:match "^%s*elseif.*") then
        return 'end'
      end
    end
  else
    if code:match "^%s*else%s*" or code:match "%s*do%s*$" or code:match "^%s*if.*" or code:match "^%s*elseif.*" then
      return 'end'
    end
  end
  return nil
end

local function procompile (nodes)
  local index = 1
  repeat
    local node, sibling = nodes[index], nil
    if type(node) == 'table' and node.operator == "silent_script" then
      sibling = nodes[index + 1]
      sibling = (sibling and sibling.operator == "silent_script") and sibling.code or nil
      sibling = match_block(node.code, sibling)
      if sibling then
        sibling = {
          code = sibling,
          operator = "silent_script",
          space = node.space,

        }
        insert(nodes, index + 1, sibling)
      end
    end
    index = index + (sibling and 2 or 1)
  until index > #nodes
end

--- Precompile Haml into Lua code.
-- @param nodes A table of parsed nodes produced by the parser.
local function compile (nodes, options, parent, locals)
  procompile(nodes)
  local index = 1
  repeat
    local node = nodes[index]
    if type(node) == 'table' then
      if #node == 0 then
        node = handle_node(node, options, nodes, locals)
      else
        node = compile(node, options, nodes, locals)
        if node then
          node = handle_node(node, options, nodes, locals)
        end
      end
      nodes[index] = assert(node)
    end
    index = index + 1
  until nodes[index] == nil

  nodes = handle_node(nodes, options, parent, locals)
  return nodes
end

return compile
