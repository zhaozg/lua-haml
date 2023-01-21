local haml = require "haml.init"

local n = 10000

local template = [=[
!!! html
%html
  %head
    %title Test
  %body
    %h1 simple markup
    %div#content
    %ul
      - for _, letter in ipairs({"a", "b", "c", "d", "e", "f", "g"}) do
        %li= letter
]=]

if arg[1] then
  local f = assert(io.open(arg[1]))
  template = f:read('*a')
  f:close()
end

if arg[2] then
  n = tonumber(arg[2]) or n
end

local start = os.clock()
for _ = 1, n do
  assert(haml.render(template))
end
local done = os.clock()

print "Compile and render:"
print(("%s seconds"):format(done - start))

local phrases  = haml.parse(template)
local compiled = haml.compile(phrases)

start = os.clock()
for _ = 1, n do
  haml.render(compiled)
end
done = os.clock()

print "Render:"
print(("%s seconds"):format(done - start))
