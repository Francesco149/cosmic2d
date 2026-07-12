-- W4 PRNG: cm.rand's xoshiro256++ verbatim (state in locals for the pure-VM
-- measure; the engine adds 8 buf i64 calls per draw on top).
local floor = math.floor

local s0, s1, s2, s3

local function rotl(x, k)
  return (x << k) | (x >> (64 - k))
end

local function splitmix(z)
  z = z + 0x9e3779b97f4a7c15
  local r = z
  r = (r ~ (r >> 30)) * 0xbf58476d1ce4e5b9
  r = (r ~ (r >> 27)) * 0x94d049bb133111eb
  return z, r ~ (r >> 31)
end

local function seed(n)
  local out
  n, out = splitmix(n); s0 = out
  n, out = splitmix(n); s1 = out
  n, out = splitmix(n); s2 = out
  n, out = splitmix(n); s3 = out
end

local function u64()
  local result = rotl(s0 + s3, 23) + s0
  local t = s1 << 17
  s2 = s2 ~ s0
  s3 = s3 ~ s1
  s1 = s1 ~ s2
  s0 = s0 ~ s3
  s2 = s2 ~ t
  s3 = rotl(s3, 45)
  return result
end

-- correctness reference: first 4 draws from seed 12345
seed(12345)
local ref = {}
for i = 1, 4 do ref[i] = string.format("%016x", u64()) end
emit("w_prng ref: " .. table.concat(ref, " "))

-- perf: 2M draws + the float conversion the sim consumes
local N = 2000000
seed(12345)
local acc = 0
local t0 = now()
for i = 1, N do acc = acc ~ u64() end
local dt = now() - t0
emit(string.format("w_prng lua-int u64: %.1f ns/draw  (acc %016x)", dt / N, acc))

seed(12345)
local facc = 0.0
t0 = now()
for i = 1, N do facc = facc + (u64() >> 11) * 0x1p-53 end
dt = now() - t0
emit(string.format("w_prng lua-int float: %.1f ns/draw  (facc %.6f)", dt / N, facc / N))
