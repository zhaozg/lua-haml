local pairs = pairs
local setfenv = setfenv
local loadstring = loadstring
local sort = table.sort
local insert = table.insert
local concat = table.concat
local format = string.format
local tostring = tostring

local function should_auto_close(tag, self_closing_modifier, inline_content, options)
  return self_closing_modifier or options.closed[tag] and options.auto_close and not inline_content
end

local function handle_code(code, locals)
  local f = loadstring(code)
  if f then
    if locals then
      setfenv(f, locals)
    end
    local v = f()
    if v ~= nil then
      return tostring(v)
    end
  end
end

local function try_code (code, locals)
  local f = loadstring(code)
  if not f then
    return nil, false
  end
  if locals then
    setfenv(f, locals)
  end
  local ok, v = pcall(f)
  if not ok then
    return nil, false
  end
  return v, true
end

local function escape_html (str, escapes)
  local chars = {}
  for k in pairs(escapes) do
    chars[#chars + 1] = k
  end
  local pattern = ('([%s])'):format(concat(chars, ""))
  return (str:gsub(pattern, escapes))
end

local function _recurse(node, options, locals, lvl, tight)
  lvl = lvl or 0
  if type(node) == 'string' or node == nil then
    return node
  end
  assert(type(node), 'table')
  local tag = node.tag
  local inner_ws = node.inner_whitespace_modifier
  tight = tight or inner_ws == '<'
  local pad = options.tidy and string.rep(options.indent, lvl) or ''
  local A, B, kT, vT = {}, {}, nil, nil
  local self_closing_modifier, inline_content = node.self_closing_modifier, node.inline_content
  node.space, node.tag, node.self_closing_modifier, node.inline_content = nil, nil, nil, nil
  node.inner_whitespace_modifier, node.outer_whitespace_modifier = nil, nil

  local inline_op = node.operator
  if node.inline_code and inline_op then
    local code = node.inline_code
    node.inline_code = nil
    node.operator = nil
    if options.lhaml then
      inline_content = '<%= ' .. code .. ' %>'
    else
      local v, ok = try_code('return ' .. code, locals)
      if ok and v ~= nil then
        local out = tostring(v)
        if inline_op == 'escaped_script'
            or (inline_op == 'script' and options.escape_html) then
          out = escape_html(out, options.html_escapes)
        end
        inline_content = out
      elseif inline_op == 'script' then
        -- Not resolvable yet: keep the placeholder for the lhtml stage.
        inline_content = '<%= ' .. code .. ' %>'
      else
        inline_content = ''
      end
    end
  end
  if tag == '=' then
    if options.lhaml then
      return '<%= ' .. node.code .. ' %>'
    else
      local out = handle_code('return ' .. node.code, locals)
      node.code = nil
      return out or ''
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
          local vv = format("'%s'", locals and locals[v] or v)
          A[#A + 1] = format('%s=%s', k, vv)
        end
      elseif vT == 'table' then
        for i, vv in pairs(v) do
          if type(vv) == 'string' then
            if vv:match '^[^\'"]' then
              v[i] = format("'%s'", locals and locals[vv] or vv)
            end
          else
            if k=='class' then
              v[i] = concat(vv, ' ')
            else
              v[i] = _recurse(vv, options, locals, lvl + 1)
            end
          end
        end
        if k == 'id' then
          v = concat(v, '_'):gsub("'_'", '_')
        else
          v = concat(v, ' '):gsub("' '", ' ')
        end
        A[#A + 1] = format('%s=%s', k, v)
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

local function render(dom, options, locals)
  local html = _recurse(dom, options, locals, 0)
  html = html:gsub('"#{(.-)}"', "'#{%1}'")
  local function interpolate_code(str)
    return str:gsub('([\\]*)#{(.-)}',
      function(slashes, match)
        if #slashes == 1 then
          return '#{' .. match .. '}'
        else
          local val = locals and locals[match] or match
          if options.lhtml then
            return '<%=' .. val .. '%>'
          end
          return slashes .. val
        end
      end)
  end

  html = interpolate_code(html)
  return html:gsub('\\\\', '\\')
end

return render
