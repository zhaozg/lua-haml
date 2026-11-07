local lpeg = require"lpeg"

local P,S = lpeg.P,lpeg.S
local    C,     Cb,     Cg,     Ct
  = lpeg.C,lpeg.Cb,lpeg.Cg,lpeg.Ct

--begin, end, instruction
local B,E,I = P("<%"),P("%>"),S("=!@")^-1
--not begin of code, not end of code
local NB, NE = (1 - B)^0, (1 - E)^0
--embed script
local CODE = B * Cg(I,'INS')*C(NE*Cb('INS')) * E
--full grammer
--local grammer = (NB * CODE)^0  * NB

--default process, all captured result as table
local function _totable(code,ins)
    if not ins then
        if #code>0 then
            return 'print([===['..code..']===])'
        end
    elseif ins=='!' then
        return 'include([['..code..']])'
    elseif ins=='@' then
        return 'at([['..code..']])'
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
local default_grammar
local function compile(s, handle)
    local grammer
    if handle == nil or handle == _totable then
        grammer = default_grammar
        if not grammer then
            local NBH = NB/_totable
            local CODEH = CODE/_totable
            grammer = Ct ( (NBH * CODEH)^0  * NBH)
            default_grammar = grammer
        end
    else
        local NBH = NB/handle
        local CODEH = CODE/handle
        grammer = Ct ( (NBH * CODEH)^0  * NBH)
    end
    return grammer:match(s)
end

return compile
