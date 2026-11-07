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
local function compile(s, handle)
    handle = handle or _totable
    local NBH = NB/handle
    local CODEH = CODE/handle
    local grammer = Ct ( (NBH * CODEH)^0  * NBH)
    return grammer:match(s)
end

return compile
