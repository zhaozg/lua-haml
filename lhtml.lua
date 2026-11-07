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

-- Wrap text so that no `]=*]` inside it can terminate the long string early.
local function wrap_text (code)
    local lvl = long_bracket_level(code)
    if lvl < 3 then lvl = 3 end
    local eq = string.rep('=', lvl)
    return 'print([' .. eq .. '[' .. code .. ']' .. eq .. '])'
end

-- Wrap include()/at() arguments at the level the argument itself needs.
local function wrap_arg (code)
    local lvl = long_bracket_level(code)
    local eq = string.rep('=', lvl)
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
local function compile(s, handle)
    local grammer
    if handle == nil or handle == _totable then
        grammer = default_grammar
        if not grammer then
            grammer = build_grammar(_totable)
            default_grammar = grammer
        end
    else
        grammer = build_grammar(handle)
    end
    return grammer:match(s)
end

return compile
