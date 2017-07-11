local lpeg = require "lpeg"
local error = error
local ipairs = ipairs
local next = next
local pairs = pairs
local rawset = rawset
local tostring = tostring

local upper  = string.upper
local concat = table.concat
local insert = table.insert
local remove = table.remove

local P, S, V, R = lpeg.P, lpeg.S, lpeg.V, lpeg.R
local C, Cb, Cg, Cf, Ct, Cp, Cmt = lpeg.C, lpeg.Cb, lpeg.Cg, lpeg.Cf, lpeg.Ct, lpeg.Cp, lpeg.Cmt
local match = lpeg.match
------------------------------------------------------------------------------

--basic rules
local alnum = R("az", "AZ", "09")
local leading_whitespace = Cg(S " \t"^0, "space")
local inline_whitespace = S " \t"
local eol = P "\n" + P("\r\n") + P("\r")
local empty_line = Cg(P "", "empty_line")
local multiline_modifier = Cg(P "|", "multiline_modifier")
local unparsed = Cg((1 - eol - multiline_modifier)^1, "unparsed")
local default_tag = "div"
local singlequoted_string = P("'" * ((1 - S "'\r\n\f\\") + (P '\\' * 1))^0 * "'")
local doublequoted_string = P('"' * ((1 - S '"\r\n\f\\') + (P '\\' * 1))^0 * '"')
local quoted_string = singlequoted_string + doublequoted_string

--prefix of rules
local tag = P "%"
local escape = P "\\"
local filter = P ":"
local header = P "!!!"
local script = P "="
local silent_script = P "-"
local markup_comment = P "/"
local silent_comment = P "-#" + "--"
local escaped_script = P "&="
local unescaped_script = P "!="
local preserved_script = P "~"
local conditional_comment = P "/["

-- (X)HTML Doctype or XML prolog
local prolog = Cg(P "XML" + P "xml" / upper, "prolog")
local charset = Cg((R("az", "AZ", "09") + S "-")^1, "charset")
local version = Cg(P "1.1" + "1.0", "version")
local doctype = Cg((R("az", "AZ")^1 + "5") / upper, "doctype")
local prolog_and_charset = (prolog * (inline_whitespace^1 * charset^1)^0)
local doctype_or_version = doctype + version

------------------------------------------------------------------------------
--- Flattens a table of tables.
local function flatten (...)
  local out = {}
  local argv = {
    ...
  }
  for _, attr in ipairs(argv) do
    for k, v in pairs(attr) do
      out[k] = v
    end
  end
  return out
end

-- Markup attributes
local function parse_html_style_attributes (a)
  local name = C((alnum + S ".-:_")^1)
  local value = C(quoted_string + name)
  local sep = (P " " + eol)^1
  local assign = P '='
  local pair = Cg(name * (assign * value)^-1) * sep^-1
  local list = S "(" * Cf(Ct "" * pair^0, function(t,k,v) return rawset(t, k, v or true) end) * S ")"
  return match(list, a) or error(("Could not parse attributes '%s'"):format(a))
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
  return match(list, a) or error(("Could not parse attributes '%s'"):format(a))
end

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

---
local function psplit(s, sep, index)
  sep = lpeg.P(sep)
  local elem = lpeg.C((1 - sep)^0)
  local p = lpeg.Ct(elem * (sep * elem)^0)
  return lpeg.match(p, s, index)
end

local nested_content = Cg(
  (Cmt(
    Cb "space",
    function (subject, index, spaces)
      local buffer = {}
      local num_spaces = tostring(spaces or ""):len()
      for _, line in ipairs(psplit(subject, "\n", index)) do
        if match(P" "^(num_spaces + 1), line) then
          insert(buffer, line)
        elseif line == "" then
          insert(buffer, line)
        else
          break
        end
      end
      buffer = concat(buffer, "\n")
      return index + buffer:len(), buffer
    end)
  ),
  "content"
)

------------------------------------------------------------------------------
local syntax = {
  'init',

  --operator
  tag                 = Cg(tag                 / function () return 'tag'                 end, "operator"),
  escape              = Cg(escape              / function () return 'escape'              end, "operator"),
  filter              = Cg(filter              / function () return 'filter'              end, "operator"),
  header              = Cg(header              / function () return 'header'              end, "operator"),
  script              = Cg(script              / function () return 'script'              end, "operator"),
  silent_script       = Cg(silent_script       / function () return 'silent_script'       end, "operator"),
  markup_comment      = Cg(markup_comment      / function () return 'markup_comment'      end, "operator"),
  silent_comment      = Cg(silent_comment      / function () return 'silent_comment'      end, "operator"),
  escaped_script      = Cg(escaped_script      / function () return 'escaped_script'      end, "operator"),
  unescaped_script    = Cg(unescaped_script    / function () return 'unescaped_script'    end, "operator"),
  preserved_script    = Cg(preserved_script    / function () return 'preserved_script'    end, "operator"),
  conditional_comment = Cg(conditional_comment / function () return 'conditional_comment' end, "operator"),

  script_operator     = P(V'silent_script' + V'script' + V'escaped_script' + V'unescaped_script' + V'preserved_script'),

  -- Modifiers that follow Haml markup tags
  self_closing        = Cg(P "/", "self_closing_modifier"),
  inner_whitespace    = Cg(P "<", "inner_whitespace_modifier"),
  outer_whitespace    = Cg(P ">", "outer_whitespace_modifier"),
  tag_modifiers       = (V'self_closing' + (V'inner_whitespace' + V'outer_whitespace')),

  --attributes
  html_style_attributes = P { "(" * ((quoted_string + (P(1) - S "()")) + V(1))^0 * ")" } / parse_html_style_attributes,
  ruby_style_attributes = P { "{" * ((quoted_string + (P(1) - S "{}")) + V(1))^0 * "}" } / parse_ruby_style_attributes,
  any_attributes        = V'html_style_attributes' + V'ruby_style_attributes',
  attributes            = Cg(Ct((V'any_attributes' * V'any_attributes'^0)) / flatten, "attributes"),

  --inline
  inline_code         = V'script' * inline_whitespace^0 * Cg(unparsed^0 * -multiline_modifier /
                        function (a)
                          return a:gsub("\\", "\\\\")
                        end, "inline_code"),
  multiline_code      = V'script' * inline_whitespace^0 * Cg(((1 - multiline_modifier)^1 * multiline_modifier)^0 /
                        function (a)
                          return a:gsub("%s*|%s*", " ")
                        end, "inline_code"),
  inline_content      = inline_whitespace^0 * Cg(unparsed, "inline_content"),

-- css and tag
  css                 = P{
                        'init',
                        css_name = S "-_" + alnum^1,
                        class    = P "." * Ct(Cg(V'css_name'^1, "class")),
                        id       = P "#" * Ct(Cg(V'css_name'^1, "id")),
                        init     = (V'class' + V'id') * V('init')^0
                      },
  html_name           = R("az", "AZ", "09") + S ":-_",
  explicit_tag        = "%" * Cg(V'html_name'^1, "tag"),
  implict_tag         = Cg(-S(1) * #V'css' /
                        function ()
                          return default_tag
                        end, "tag"
                      ),
  haml_tag            = (V'explicit_tag' + V'implict_tag') * Cg(Ct(V'css') / flatten_ids_and_classes, "css")^0,


  --haml
  haml_header         = V'header' * (inline_whitespace * (prolog_and_charset + doctype_or_version))^0,
  haml_element        = Ct(Cg(Cp(),"pos") * leading_whitespace * (
    -- Haml markup
    (V'haml_tag' * V'attributes'^0 * V'tag_modifiers'^0 * (V'inline_code' + V'multiline_code' + V'inline_content')^0) +
    -- Doctype or prolog
    V'haml_header' +
    -- Silent comment
    V'silent_comment' * (inline_whitespace^0 * Cg(unparsed^0, "comment") * nested_content) +
    -- Script
    V'script_operator' * inline_whitespace^1 * Cg(unparsed^0, "code") +
    -- IE conditional comments
    (V'conditional_comment' * Cg((P(1) - "]")^1, "condition")) * "]" +
    -- Markup comment
    (V'markup_comment' * inline_whitespace^0 * unparsed^0) +
    -- Filtered block
    (V'filter' * Cg((P(1) - eol)^0, "filter") * nested_content) +
    -- Escaped
    (V'escape' * unparsed^0) +
    -- Unparsed content
    unparsed +
    -- Last resort
    empty_line
  )),
  --return array of all haml_element captured
  init = Ct(V'haml_element' * (eol^1 * V'haml_element')^0)
}

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
        print('#v.space',#v.space)
        print('#ctx.space',#ctx.space)
        assert(nil, string.format('Error at %d, %d and %d mismatch',v.pos,#v.space,#ctx.space))
      end
    end
  until i > #t

  return #root == 1 and root[1] or root
end

local function parser (input)
  local _, gram = xpcall(function()
      --syntax = require'pegdebug'.trace(syntax)
      local _ = match(syntax,input)
      _ = tidy(_)
      return _
    end,
    function() print(debug.traceback("parse haml error",2)) end
  )
  if _ then
    return gram
  else
    return ''
  end
end

return parser
