local lpeg = require"lpeg"
local util = require"haml/util"

local P,S = lpeg.P,lpeg.S
local    C,     Cb,     Cg,     Ct
  = lpeg.C,lpeg.Cb,lpeg.Cg,lpeg.Ct

--begin, end, instruction
local B,E,I = P("<%"),P("%>"),S("=!@")^-1
--not begin of code, not end of code
local NB, NE = (1 - B)^0, (1 - E)^0
--embed script
local CODE = B * Cg(I,'INS')*C(NE*Cb('INS')) * E
--A "<%" with no matching "%>" is text, not a code block.  Without this rule
--the grammar simply stopped at the first stray "<%" and silently dropped the
--rest of the document.
local STRAY = B * (1 - E)^0

local long_bracket_level = util.long_bracket_level
local eq_cache = {}
local function eqs (n)
    local e = eq_cache[n]
    if not e then e = string.rep('=', n); eq_cache[n] = e end
    return e
end

-- Wrap text so that no `]=*]` inside it can terminate the long string early.
local function wrap_text (code)
    local lvl = long_bracket_level(code)
    if lvl < 3 then lvl = 3 end
    local eq = eqs(lvl)
    return 'print([' .. eq .. '[' .. code .. ']' .. eq .. '])'
end

-- Wrap include()/at() arguments at the level the argument itself needs.
local function wrap_arg (code)
    local lvl = long_bracket_level(code)
    local eq = eqs(lvl)
    return '([' .. eq .. '[' .. code .. ']' .. eq .. '])'
end

--default process, all captured result as table
local function _totable(code,ins)
    if not ins then
        if #code>0 then
            return wrap_text(code)
        end
    elseif ins=='!' then
        return 'include'..wrap_arg(code)
    elseif ins=='@' then
        return 'at'..wrap_arg(code)
    elseif ins=='=' then
        return 'print(tostring('..code..'))'
    elseif ins=='' then
        return code
    else
        error(string.format('handle %s failed for\n%s',ins,code))
    end
end

--compile and return captured table
-- Building the grammar costs more than running it, so the default-handler
-- grammar is built once and reused. A caller-supplied handler still gets a
-- grammar of its own, since the handler is baked into the pattern.
local function build_grammar (handle)
    local TEXT = NB / handle
    local CODEH = CODE / handle
    local STRAYH = STRAY / handle
    return Ct ( (TEXT * CODEH)^0 * TEXT * STRAYH^0 )
end

local default_grammar
-- Translation is pure, and the two-phase pipeline renders the same
-- intermediate string once per request, so cache the last translation per
-- handler.  A weak key lets throw-away handler closures be collected; the
-- chunks are shared and must be treated as read-only.
local last_translation = setmetatable({}, { __mode = 'k' })
local function copy_chunks (t)
    local out, n = {}, #t
    for i = 1, n do out[i] = t[i] end
    return out
end
local function compile(s, handle)
    local h = handle or _totable
    local cached = last_translation[h]
    if cached and cached.source == s then
        return copy_chunks(cached.chunks)
    end

    local grammer
    if h == _totable then
        grammer = default_grammar
        if not grammer then
            grammer = build_grammar(_totable)
            default_grammar = grammer
        end
    else
        grammer = build_grammar(h)
    end

    local chunks = grammer:match(s)
    if chunks then
        -- Keep a private copy so mutating the returned table cannot poison
        -- the cache.
        last_translation[h] = { source = s, chunks = copy_chunks(chunks) }
    end
    return chunks
end

return compile
