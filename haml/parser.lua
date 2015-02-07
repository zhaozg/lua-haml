local lpeg = require "lpeg"

local error = error
local ipairs = ipairs
local next = next
local pairs = pairs
local rawset = rawset
local tostring = tostring

local concat = table.concat
local insert = table.insert
local remove = table.remove
local upper = string.upper

local P, S, V, R = lpeg.P, lpeg.S, lpeg.V, lpeg.R
local C, Cb, Cg, Cf, Ct, Cmt = lpeg.C, lpeg.Cb, lpeg.Cg, lpeg.Cf, lpeg.Ct, lpeg.Cmt

--- util functions
local function psplit (s, sep)
  sep = lpeg.P(sep)
  local elem = lpeg.C((1 - sep)^0)
  local p = lpeg.Ct(elem * (sep * elem)^0)
  return lpeg.match(p, s)
end

--- Flattens a table of tables.
local function flatten (...)
  local out = {}
  local argv = {
    ...,

  }
  for _, attr in ipairs(argv) do
    for k, v in pairs(attr) do
      out[k] = v
    end
  end
  return out
end


local alnum = R("az", "AZ", "09")
local leading_whitespace = Cg(S " \t"^0, "space")
local inline_whitespace = S " \t"
local eol = P "\n" + "\r\n" + "\r"
local empty_line = Cg(P "", "empty_line")
local multiline_modifier = Cg(P "|", "multiline_modifier")
local unparsed = Cg((1 - eol - multiline_modifier)^1, "unparsed")
local default_tag = "div"
local singlequoted_string = P("'" * ((1 - S "'\r\n\f\\") + (P '\\' * 1))^0 * "'")
local doublequoted_string = P('"' * ((1 - S '"\r\n\f\\') + (P '\\' * 1))^0 * '"')
local quoted_string = singlequoted_string + doublequoted_string

local operator_symbols = {
  conditional_comment = P "/[",
  escape = P "\\",
  filter = P ":",
  header = P "!!!",
  markup_comment = P "/",
  script = P "=",
  silent_comment = P "-#" + "--",
  silent_script = P "-",
  tag = P "%",
  escaped_script = P "&=",
  unescaped_script = P "!=",
  preserved_script = P "~",

}

-- This builds a table of capture patterns that return the operator name rather
-- than the literal operator string.
local operators = {}
for k, v in pairs(operator_symbols) do
  operators[k] = Cg(v / function ()
      return k
    end, "operator")
end

local script_operator = P(operators.silent_script + operators.script + operators.escaped_script + operators.unescaped_script + operators.preserved_script)

-- (X)HTML Doctype or XML prolog
local prolog = Cg(P "XML" + P "xml" / upper, "prolog")
local charset = Cg((R("az", "AZ", "09") + S "-")^1, "charset")
local version = Cg(P "1.1" + "1.0", "version")
local doctype = Cg((R("az", "AZ")^1 + "5") / upper, "doctype")
local prolog_and_charset = (prolog * (inline_whitespace^1 * charset^1)^0)
local doctype_or_version = doctype + version
local header = operators.header * (inline_whitespace * (prolog_and_charset + doctype_or_version))^0

-- Modifiers that follow Haml markup tags
local modifiers = {
  self_closing = Cg(P "/", "self_closing_modifier"),
  inner_whitespace = Cg(P "<", "inner_whitespace_modifier"),
  outer_whitespace = Cg(P ">", "outer_whitespace_modifier"),
}

-- Markup attributes
local function parse_html_style_attributes (a)
  local name = C((alnum + S ".-:_")^1)
  local value = C(quoted_string + name)
  local sep = (P " " + eol)^1
  local assign = P '='
  local pair = Cg(name * assign * value) * sep^-1
  local list = S "(" * Cf(Ct "" * pair^0, rawset) * S ")"
  return lpeg.match(list, a) or error(("Could not parse attributes '%s'"):format(a))
end

local function parse_ruby_style_attributes (a)
  local name = (alnum + P "_")^1
  local key = (P ":" * C(name)) + (P ":"^-1 * C(quoted_string)) / function (s)
    s = s:gsub('[\'"]', "")
    return s
  end
  local value = C(quoted_string + name)
  local sep = inline_whitespace^0 * P "," * (P " " + eol)^0
  local assign = P '=>'
  local pair = Cg(key * inline_whitespace^0 * assign * inline_whitespace^0 * value) * sep^-1
  local list = S "{" * inline_whitespace^0 * Cf(Ct "" * pair^0, rawset) * inline_whitespace^0 * S "}"
  return lpeg.match(list, a) or error(("Could not parse attributes '%s'"):format(a))
end

local html_style_attributes = P {
  "(" * ((quoted_string + (P(1) - S "()")) + V(1))^0 * ")",

} / parse_html_style_attributes
local ruby_style_attributes = P {
  "{" * ((quoted_string + (P(1) - S "{}")) + V(1))^0 * "}",

} / parse_ruby_style_attributes
local any_attributes = html_style_attributes + ruby_style_attributes
local attributes = Cg(Ct((any_attributes * any_attributes^0)) / flatten, "attributes")

-- Haml HTML elements
-- Character sequences for CSS and XML/HTML elements. Note that many invalid
-- names are allowed because of Haml's flexibility.
local function flatten_ids_and_classes (t)
  local classes, ids = {}, {}
  for _, v in pairs(t) do
    if v.id then
      insert(ids, v.id)
    else
      insert(classes, v.class)
    end
  end
  local out = {}
  if next(ids) then
    out.id = ("'%s'"):format(remove(ids))
  end
  if next(classes) then
    out.class = ("'%s'"):format(concat(classes, " "))
  end
  return out
end

local nested_content = Cg((Cmt(Cb "space", function (subject, index, spaces)
      local buffer = {}
      local num_spaces = tostring(spaces or ""):len()
      local start = subject:sub(index)
      for _, line in ipairs(psplit(start, "\n")) do
        if lpeg.match(S " \t"^(num_spaces + 1), line) then
          insert(buffer, line)
        elseif line == "" then
          insert(buffer, line)
        else
          break
        end
      end
      local match = concat(buffer, "\n")
      return index + match:len(), match
    end)), "content")

local css_name = S "-_" + alnum^1
local class = P "." * Ct(Cg(css_name^1, "class"))
local id = P "#" * Ct(Cg(css_name^1, "id"))
local css = P {
  (class + id) * V(1)^0,

}
local html_name = R("az", "AZ", "09") + S ":-_"
local explicit_tag = "%" * Cg(html_name^1, "tag")
local implict_tag = Cg(-S(1) * #css / function ()
    return default_tag
  end, "tag")
local haml_tag = (explicit_tag + implict_tag) * Cg(Ct(css) / flatten_ids_and_classes, "css")^0
local inline_code = operators.script * inline_whitespace^0 * Cg(unparsed^0 * -multiline_modifier / function (a)
    return a:gsub("\\", "\\\\")
  end, "inline_code")
local multiline_code = operators.script * inline_whitespace^0 * Cg(((1 - multiline_modifier)^1 * multiline_modifier)^0 / function (a)
    return a:gsub("%s*|%s*", " ")
  end, "inline_code")
local inline_content = inline_whitespace^0 * Cg(unparsed, "inline_content")
local tag_modifiers = (modifiers.self_closing + (modifiers.inner_whitespace + modifiers.outer_whitespace))

-- Core Haml grammar
local haml_element = leading_whitespace * ( -- Haml markup
 (haml_tag * attributes^0 * tag_modifiers^0 * (inline_code + multiline_code + inline_content)^0) +  -- Doctype or prolog
 header +  -- Silent comment
 operators.silent_comment * inline_whitespace^0 * Cg(unparsed^0, "comment") * nested_content +  -- Script
 script_operator * inline_whitespace^1 * Cg(unparsed^0, "code") +  -- IE conditional comments
 (operators.conditional_comment * Cg((P(1) - "]")^1, "condition")) * "]" +  -- Markup comment
 (operators.markup_comment * inline_whitespace^0 * unparsed^0) +  -- Filtered block
 (operators.filter * Cg((P(1) - eol)^0, "filter") * eol * nested_content) +  -- Escaped
 (operators.escape * unparsed^0) +  -- Unparsed content
 unparsed +  -- Last resort
 empty_line)
local grammar = Ct(Ct(haml_element) * (eol^1 * Ct(haml_element))^0)

local function tidy (t)
  local root = {}
  local parent = {}

  local i, v, ctx, space
  i = 1
  repeat
    v = t[i]
    if v.space == '' then
      remove(t, i)
      root[#root + 1] = v

      parent[v] = root
      ctx = v
    else
      if space == nil then
        space = v.space
      end

      if #v.space == #ctx.space + #space then
        --new child node
        remove(t, i)
        ctx[#ctx + 1] = v

        parent[v] = ctx
        ctx = v
      elseif #v.space == #ctx.space then
        --same level node
        remove(t, i)
        ctx = parent[ctx]
        ctx[#ctx + 1] = v

        parent[v] = ctx
        ctx = v
      elseif #v.space < #ctx.space then
        --return to parent
        repeat
          ctx = parent[ctx]
        until #ctx.space == #v.space
        ctx = parent[ctx]
        ctx[#ctx + 1] = v
        remove(t, i)

        parent[v] = ctx
        ctx = v
      else
        assert(nil, 'never here')
      end
    end
  until i > #t

  return #root == 1 and root[1] or root
end

local function parser (input)
  local gram = lpeg.match(grammar, input)
  return tidy(gram)
end

return parser
