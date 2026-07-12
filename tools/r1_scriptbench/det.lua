-- determinism audit, Lua side
print("== integer semantics ==")
print("2^53+1 exact:", 9007199254740993 == 9007199254740992 and "COLLAPSES" or "EXACT",
      9007199254740993)
print("64-bit wrap: 0x7fffffffffffffff+1 =", string.format("%016x", 0x7fffffffffffffff + 1))
print("wrap mul: 0xbf58476d1ce4e5b9*3 =", string.format("%016x", 0xbf58476d1ce4e5b9 * 3))
print("floor div: -7 // 3 =", -7 // 3, "  mod: -7 % 3 =", -7 % 3)
print("int/float distinct:", math.type(3), math.type(3.0), 3 == 3.0)
print("tostring: int 3 ->", tostring(3), "  float 3.0 ->", tostring(3.0))

print("== iteration order ==")
local t = {}
t.zebra = 1; t.alpha = 2; t[2] = 3; t[1] = 4; t.mid = 5
local order = {}
for k in pairs(t) do order[#order + 1] = tostring(k) end
print("pairs order:", table.concat(order, ","), "(insertion was zebra,alpha,2,1,mid)")

print("== NaN / float bits ==")
local nan = 0/0
print("NaN ~= NaN:", nan ~= nan)
-- bit pattern through pack (the canon path errors on NaN by design)
print("NaN bits via pack:", ("%016x"):format(string.unpack("<i8", string.pack("<d", nan))))
print("0.1+0.2 bits:", ("%016x"):format(string.unpack("<i8", string.pack("<d", 0.1 + 0.2))))
print("1e16+1 bits:", ("%016x"):format(string.unpack("<i8", string.pack("<d", 1e16 + 1))))
-- a chain of arithmetic, bit pattern (cross-VM check against det.js)
local x = 0.1
for i = 1, 100 do x = x * 1.0000001 + 0.001 end
print("chain bits:", ("%016x"):format(string.unpack("<i8", string.pack("<d", x))))
local s = math.sqrt(2)
print("sqrt(2) bits:", ("%016x"):format(string.unpack("<i8", string.pack("<d", s))))

print("== GC observability ==")
-- allocation-heavy loop with identical results regardless of GC timing
local acc = 0
for i = 1, 100000 do
  local tt = { i, i * 2 }
  acc = acc + tt[1] + tt[2]
  if i == 50000 then collectgarbage("collect") end
end
print("alloc loop acc (GC forced mid-way):", acc)
