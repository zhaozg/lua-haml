local pairs = pairs
local ipairs = ipairs
local setfenv = setfenv
local loadstring = loadstring
local sort = table.sort
local insert = table.insert
local concat = table.concat
local format = string.format
local tostring = tostring

local MAX_DEPTH = 200

local function should_auto_close(tag, self_closing_modifier, inline_content, options)
  return self_closing_modifier or options.closed[tag] and options.auto_close and not inline_content
end

local function handle_code(code, locals)
  local f = loadstring(code)
  if f then
    if locals then
      setfenv(f, locals)
    end
    local ok, v = pcall(f)
    if not ok then
      error("haml: embedded code failed: " .. tostring(v), 0)
    end
    if v ~= nil then
      return tostring(v)
    end
  end
end

local function try_code (code, locals, options)
  local f = loadstring(code)
  if not f then
    if options and options.strict_eval then
      error("haml: cannot compile embedded code: " .. tostring(code), 0)
    end
    return nil, false
  end
  if locals then
    setfenv(f, locals)
  end
  local ok, v = pcall(f)
  if not ok then
    if options and options.strict_eval then
      error("haml: embedded code failed: " .. tostring(v), 0)
    end
    return nil, false
  end
  return v, true
end

-- Building the character class is a measurable part of an escape-heavy
-- render (200 attributes: ~1.2us each).  Cache it per escapes table; the
-- default table is shared, so the common case builds it once per process.
local escape_patterns = setmetatable({}, { __mode = 'k' })
local function escape_html (str, escapes)
  local pattern = escape_patterns[escapes]
  if not pattern then
    local chars = {}
    for k in pairs(escapes) do
      chars[#chars + 1] = k
    end
    pattern = ('([%s])'):format(concat(chars, ""))
    escape_patterns[escapes] = pattern
  end
  return (str:gsub(pattern, escapes))
end

-- Data that came from `locals` must never be re-read as template syntax by
-- the rest of the pipeline:
--   * `<%` would be picked up by the lhtml stage as a code placeholder, so it
--     is encoded as HTML text permanently;
--   * `#{` and `\` would be consumed by the interpolation/unescape passes at
--     the bottom of render(), so they are parked behind a sentinel and put
--     back after those passes have run.
-- The sentinel is byte 1: it cannot appear in normal markup, and any existing
-- byte 1 in the data is doubled so the restore stays unambiguous in practice.
local function has_special (s)
  return s:find('<', 1, true) or s:find('#', 1, true)
      or s:find('\\', 1, true) or s:find('\1', 1, true)
end

local function protect_data (s)
  if not has_special(s) then return s end
  if s:find('<%', 1, true) then s = s:gsub('<%%', '&lt;%%') end
  if s:find('\1', 1, true) then s = s:gsub('\1', '\1\1') end
  if s:find('#{', 1, true) then s = s:gsub('#{', '\1H') end
  if s:find('\\', 1, true) then s = s:gsub('\\', '\1S') end
  return s
end

-- Values inserted by the `#{}` pass are not rescanned by that pass, so they
-- only need `<%` neutralised (for lhtml) and backslashes parked so the final
-- unescape cannot eat them.  Avoiding the `#{` marker keeps the common case
-- out of restore_data entirely.
local function protect_late (s)
  if not has_special(s) then return s end
  if s:find('<%', 1, true) then s = s:gsub('<%%', '&lt;%%') end
  if s:find('\1', 1, true) then s = s:gsub('\1', '\1\1') end
  if s:find('\\', 1, true) then s = s:gsub('\\', '\1S') end
  return s
end

-- Rewrite only the marker positions instead of running a gsub over the whole
-- document.  A gsub costs ~17us on a 3KB page even when it matches once; this
-- loop costs ~1us and the markers are rare by construction.
local function restore_data (s)
  local pos = s:find('\1', 1, true)
  if not pos then
    return s
  end
  local out, i = {}, 1
  while pos do
    out[#out + 1] = s:sub(i, pos - 1)
    local c = s:sub(pos + 1, pos + 1)
    if c == 'H' then
      out[#out + 1] = '#{'
      i = pos + 2
    elseif c == 'S' then
      out[#out + 1] = '\\'
      i = pos + 2
    elseif c == '\1' then
      out[#out + 1] = '\1'
      i = pos + 2
    else
      out[#out + 1] = '\1'
      i = pos + 1
    end
    pos = s:find('\1', i, true)
  end
  out[#out + 1] = s:sub(i)
  return table.concat(out)
end

local function data_value (value, options)
  value = tostring(value)
  if options.escape_html then
    value = escape_html(value, options.html_escapes)
  end
  return protect_data(value)
end

local function _recurse(node, options, locals, lvl, tight)
  lvl = lvl or 0
  if lvl > MAX_DEPTH then
    error(format('haml: template nested too deeply (limit %d)', MAX_DEPTH), 0)
  end
  if type(node) == 'string' or node == nil then
    return node
  end
  assert(type(node), 'table')
  -- Work on a shallow copy. The code below strips metadata keys (tag, space,
  -- operator, ...) so that the pairs() loop treats the rest as attributes;
  -- doing that on the caller's tree destroyed it, so a compiled template could
  -- only be rendered once and every render had to re-parse. Copying one table
  -- per node costs ~4% of a render and makes the tree reusable.
  do
    local copy = {}
    for k, v in pairs(node) do copy[k] = v end
    node = copy
  end
  local tag = node.tag
  local inner_ws = node.inner_whitespace_modifier
  tight = tight or inner_ws == '<'
  local pad = options.tidy and string.rep(options.indent, lvl) or ''
  local A, B, kT, vT = {}, {}, nil, nil
  local self_closing_modifier, inline_content = node.self_closing_modifier, node.inline_content
  node.space, node.tag, node.self_closing_modifier, node.inline_content = nil, nil, nil, nil
  node.inner_whitespace_modifier, node.outer_whitespace_modifier = nil, nil

  local two_phase = options.lhaml or options.lhtml
  local inline_op = node.operator
  if node.inline_code and inline_op then
    local code = node.inline_code
    node.inline_code = nil
    node.operator = nil
    if two_phase then
      inline_content = '<%= ' .. code .. ' %>'
    else
      local v, ok = try_code('return ' .. code, locals, options)
      if ok and v ~= nil then
        local out = tostring(v)
        if inline_op == 'escaped_script'
            or (inline_op == 'script' and options.escape_html) then
          out = escape_html(out, options.html_escapes)
        end
        inline_content = protect_data(out)
      elseif inline_op == 'script' then
        -- Not resolvable yet: keep the placeholder for the lhtml stage.
        inline_content = '<%= ' .. code .. ' %>'
      else
        inline_content = ''
      end
    end
  end
  if tag == '=' then
    if two_phase then
      return '<%= ' .. node.code .. ' %>'
    else
      local out = handle_code('return ' .. node.code, locals)
      node.code = nil
      if out and options.escape_html then
        out = escape_html(out, options.html_escapes)
      end
      return out and protect_data(out) or ''
    end
  end
  if tag == '-' then
    if #node == 0 then
      return '<% ' .. node.code .. ' %>'
    else
      insert(node, 1, '<% ' .. node.code .. ' %>')
      pad = ''
      tag = nil
    end

    node.operator = nil
    node.code = nil
  end
  for k, v in pairs(node) do
    kT, vT = type(k), type(v)
    if kT == 'number' then
      --child content
      if vT == 'string' then
        B[#B + 1] = options.preserve[tag] and v or pad .. v
      else
        B[#B + 1] = _recurse(v, options, locals, lvl + 1, tight)
      end
    else
      --attribute
      if vT == 'string' then
        if v == 'false' or v == 'nil' then
          -- boolean false/nil: omit the attribute entirely
        elseif v == 'true' then
          -- boolean true: attr='attr' for xhtml, bare attr otherwise
          A[#A + 1] = options.format == 'xhtml' and format("%s='%s'", k, k) or k
        elseif v:match '".-"' or v:match "'.-'" then
          A[#A + 1] = format('%s=%s', k, v)
        else
          local value = locals and locals[v]
          if value == true then
            A[#A + 1] = options.format == 'xhtml' and format("%s='%s'", k, k) or k
          elseif value == false then
            -- boolean false: omit the attribute entirely
          elseif value == nil then
            -- Template-side value: not data, no need for the data guard.
            A[#A + 1] = format("%s='%s'", k, v)
          else
            A[#A + 1] = format("%s='%s'", k, data_value(value, options))
          end
        end
      elseif vT == 'table' then
        local vals = {}
        for i, vv in ipairs(v) do
          if type(vv) == 'string' then
            if vv:match '^[^\'"]' then
              local value = locals and locals[vv]
              if value == nil then value = vv end
              vals[i] = format("'%s'", data_value(value, options))
            else
              vals[i] = vv
            end
          else
            if k == 'class' then
              vals[i] = concat(vv, ' ')
            else
              vals[i] = _recurse(vv, options, locals, lvl + 1, tight)
            end
          end
        end
        local joined
        if k == 'id' then
          joined = concat(vals, '_'):gsub("'_'", '_')
        else
          joined = concat(vals, ' '):gsub("' '", ' ')
        end
        A[#A + 1] = format('%s=%s', k, joined)
      elseif vT == 'boolean' then
        if v then
          A[#A + 1] = k
        end
      end
    end
  end

  if tag then
    if options.preserve[tag] or ((inner_ws == '<' or tight) and #B > 0) then
      B = {
        concat(B, options.newline),
      }
    end
    if (#B + #A) == 0 then
      if should_auto_close(tag, self_closing_modifier, inline_content, options) then
        return options.format == 'xhtml' and format('%s<%s />', pad, tag) or format('%s<%s>', pad, tag)
      else
        return format('%s<%s>%s</%s>', pad, tag, inline_content or '', tag)
      end
    elseif #B == 0 then
      sort(A)
      if should_auto_close(tag, self_closing_modifier, inline_content, options) then
        return options.format == 'xhtml'
            and format('%s<%s %s />', pad, tag, concat(A, ' '))
            or format('%s<%s %s>', pad, tag, concat(A, ' '))
      else
        return format('%s<%s %s>%s</%s>', pad, tag, concat(A, ' '), inline_content or '', tag)
      end
    elseif #A == 0 then
      if type(tag) == 'table' then
        local tag1 = type(tag) == 'string' and format('<%s>', tag) or tag[1]
        local tag2 = type(tag) == 'string' and format('</%s>', tag) or tag[2]
        insert(B, 1, format('%s%s', pad, tag1))
        insert(B, format('%s%s', pad, tag2))
      else
        insert(B, 1, format('%s<%s>', pad, tag))
        insert(B, format('%s</%s>', pad, tag))
      end
    else
      sort(A)
      insert(B, 1, format('%s<%s %s>', pad, tag, concat(A, ' ')))
      insert(B, format('%s</%s>', pad, tag))
    end
  end
  if inner_ws == '>'
      or inner_ws == '<'
      or tight
      or (tag and options.preserve[tag]) then
    return concat(B, '')
  else
    return concat(B, options.newline)
  end
end

-- The interpolation passes used to be two full-document gsubs. A gsub with a
-- function replacement costs ~100us on a 3KB page even when it matches once,
-- which made it the most expensive part of render (more than _recurse). The
-- manual scans below are exact equivalents (differentially fuzzed against the
-- old gsub version) and cost ~1us.
local function requote (s)
  local out, pos = {}, 1
  while true do
    local a = s:find('"#{', pos, true)
    if not a then break end
    local b = s:find('}"', a + 3, true)
    if not b then break end
    out[#out + 1] = s:sub(pos, a - 1)
    out[#out + 1] = "'" .. s:sub(a + 1, b) .. "'"
    pos = b + 2
  end
  out[#out + 1] = s:sub(pos)
  return table.concat(out)
end

-- A `#{...}` that is already inside an lhtml `<% ... %>` code span is
-- template code, not text interpolation.  An unmatched `<%` is treated as
-- text by lhtml (STRAY), so it must not open a code span here either.
-- Without this check, `%p= #{x}` becomes `<%= <%=x%> %>` and lhtml turns the
-- inner placeholder into invalid Lua (`unexpected symbol near '<'`).
local function inside_code (html, pos)
  local scan = 1
  while true do
    local open = html:find('<%', scan, true)
    if not open or open > pos then return false end
    local close = html:find('%>', open + 2, true)
    if not close then
      -- An unmatched '<%' is text to lhtml.  If we inserted an '<%=...%>'
      -- after it, that close would pair with it and turn the text into code.
      return true
    end
    if close > pos then return true end
    scan = close + 2
  end
end

local function interpolate (html, options, locals, two_phase)
  if html:find('"#{', 1, true) then
    html = requote(html)
  end

  local first = html:find('#{', 1, true)
  if first then
    local out, pos = {}, 1
    while first do
      local close = html:find('}', first + 2, true)
      if not close then break end

      local n, k = 0, first - 1
      while k >= pos and html:sub(k, k) == '\\' do
        n = n + 1
        k = k - 1
      end

      local match = html:sub(first + 2, close - 1)
      if n == 1 then
        out[#out + 1] = html:sub(pos, first - 2)
        out[#out + 1] = '#{' .. match .. '}'
      else
        out[#out + 1] = html:sub(pos, first - 1)
        local val
        if locals then val = locals[match] end
        if val == nil then val = match end
        if two_phase then
          -- In two-phase mode a text `#{}` must stay a placeholder for
          -- template code.  Inside an existing `<%= ... %>` we only splice
          -- the expression itself, never a `locals` value; wrapping it again
          -- would produce `<%= <%=x%> %>` and invalid Lua.
          if inside_code(html, first) then
            out[#out + 1] = match
          else
            out[#out + 1] = '<%=' .. match .. '%>'
          end
        else
          val = tostring(val)
          if options.escape_html then
            val = escape_html(val, options.html_escapes)
          end
          out[#out + 1] = protect_late(val)
        end
      end
      pos = close + 1
      first = html:find('#{', pos, true)
    end
    out[#out + 1] = html:sub(pos)
    html = table.concat(out)
  end

  local pair = html:find('\\\\', 1, true)
  if pair then
    local out, i = {}, 1
    while pair do
      out[#out + 1] = html:sub(i, pair - 1)
      out[#out + 1] = '\\'
      i = pair + 2
      pair = html:find('\\\\', i, true)
    end
    out[#out + 1] = html:sub(i)
    html = table.concat(out)
  end
  return html
end

local function render(dom, options, locals)
  local two_phase = options.lhaml or options.lhtml
  local html = _recurse(dom, options, locals, 0)
  html = interpolate(html, options, locals, two_phase)
  return restore_data(html)
end

return render
