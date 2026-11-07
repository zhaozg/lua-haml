local haml = require "haml/init"

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

if arg[1] and arg[1] ~= "" then
  local f = assert(io.open(arg[1]))
  template = f:read('*a')
  f:close()
end

if arg[2] then
  n = tonumber(arg[2]) or n
end

local function time (label, iterations, fn)
  collectgarbage("collect")
  local start = os.clock()
  local last
  for _ = 1, iterations do
    last = fn()
  end
  local elapsed = os.clock() - start
  print(("%-24s %8.3f s   %8.1f us/op"):format(label, elapsed, elapsed / iterations * 1e6))
  return elapsed, last
end

--- Render must be repeatable.
-- _recurse used to strip metadata off the tree it was given, which meant a
-- compiled template produced correct output once and then degraded to a bare
-- newline. That made the "render only" loop below measure a destroyed tree,
-- and report a number far better than anything achievable. Check explicitly.
local compiled = haml.compile(haml.parse(template))
local first = haml.render(compiled)
local second = haml.render(compiled)
assert(first == second,
  "rendering a compiled template twice must give the same output")
assert(first == haml.render(template),
  "compiled and string entry points must agree")

print(("template: %d bytes, %d iterations"):format(#template, n))
print("")

local t_total = time("parse + compile + render", n, function () return haml.render(template) end)
local t_render = time("render only (cached)",    n, function () return haml.render(compiled) end)
local t_parse  = time("parse only",              n, function () return haml.parse(template) end)
local t_pc     = time("parse + compile",         n, function () return haml.compile(haml.parse(template), nil) end)
print("")
print(("%-24s %8.3f s   %8.1f us/op"):format("compile only", (t_pc - t_parse), (t_pc - t_parse) / n * 1e6))
print(("parse+compile is %.1fx the cost of render"):format((t_total - t_render) / t_render))
