local io = io
local byte, find, gsub, format = string.byte, string.find, string.gsub, string.format
local concat = table.concat
local floor = math.floor
local type = type

local M = {}

local function pr (tab, _name, _indent, options)
    local tableList = {}
    local table_r
    table_r = function (t, name, indent, full)
        local id = not full and name or type(name)~="number" and tostring(name) or '['..name..']'
        local tag = indent .. id .. ' = '
        local out = {}  -- result
        if type(t) == "table" then
            if tableList[t] ~= nil then
                table.insert(out, tag .. '{} -- ' .. tableList[t] .. ' (self reference)')
            else
                tableList[t]= full and (full .. '.' .. id) or id
                if next(t) then -- Table not empty
                    table.insert(out, tag .. '{')
                    for key,value in pairs(t) do
                        table.insert(out,table_r(value,key,indent .. '|  ',tableList[t]))
                    end
                    table.insert(out,indent .. '}')
                else table.insert(out,tag .. '{}') end
            end
        else
            if type(t)=='string' then
                if options.conv then
                    t = options.conv(t)
                end
                if options.limit and #t > options.limit  then
                    t = t:sub(1, options.limit/2)..
                        '...('..(#t-options.limit) ..')...'..
                        t:sub(-options.limit/2,-1)
                end
                table.insert(out, tag .. t)
            else
                table.insert(out, tag .. tostring(t))
            end
        end
        return table.concat(out, '\n')
    end
    return table_r(tab,_name or 'Value',_indent or '')
end

function M.print_r (t, name, options)
    options = options or {}
    print(pr(t,name, nil, options))
end

return M
