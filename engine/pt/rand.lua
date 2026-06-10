-- pt.rand — the engine PRNG: xoshiro256++ (Blackman/Vigna) ported to Lua 5.4
-- integer ops (wrapping arithmetic + logical shifts are exact, so this is
-- bit-identical to the reference C on every platform).
--
-- State lives in the "pt.sim" named buffer (see pt.state for the layout:
-- s0..s3 at bytes 8..39) — every draw reads and writes the buffer, so a
-- snapshot taken between any two calls captures the exact stream position,
-- and state survives VM reboots. math.random is banned in sim code; this
-- is what you use instead (ARCHITECTURE "Determinism").

local M = {}

local SIM_BUF, S0 = "pt.sim", 8
local sim -- view, re-acquired per VM lifetime

local function buf()
  if not sim then sim = pal.buf(SIM_BUF, 64) end
  return sim
end

local function rotl(x, k)
  return (x << k) | (x >> (64 - k))
end

-- splitmix64: stream-fills the state from a single integer seed, so any
-- seed (including 0) yields a healthy non-zero state
local function splitmix(z)
  z = z + 0x9e3779b97f4a7c15
  local r = z
  r = (r ~ (r >> 30)) * 0xbf58476d1ce4e5b9
  r = (r ~ (r >> 27)) * 0x94d049bb133111eb
  return z, r ~ (r >> 31)
end

function M.seed(n)
  n = math.tointeger(n) or error("pt.rand.seed: integer expected", 2)
  local b = buf()
  for i = 0, 3 do
    local out
    n, out = splitmix(n)
    b:i64(S0 + 8 * i, out)
  end
end

-- seed only if the state is virgin (all-zero would make xoshiro degenerate);
-- a restored snapshot or a persisting buffer keeps its stream position
function M.ensure_seeded(n)
  local b = buf()
  for i = 0, 3 do
    if b:i64(S0 + 8 * i) ~= 0 then return false end
  end
  M.seed(n)
  return true
end

-- next raw 64-bit draw (full-range signed integer in Lua terms)
function M.u64()
  local b = buf()
  local s0, s1 = b:i64(S0), b:i64(S0 + 8)
  local s2, s3 = b:i64(S0 + 16), b:i64(S0 + 24)
  local result = rotl(s0 + s3, 23) + s0
  local t = s1 << 17
  s2 = s2 ~ s0
  s3 = s3 ~ s1
  s1 = s1 ~ s2
  s0 = s0 ~ s3
  s2 = s2 ~ t
  s3 = rotl(s3, 45)
  b:i64(S0, s0)
  b:i64(S0 + 8, s1)
  b:i64(S0 + 16, s2)
  b:i64(S0 + 24, s3)
  return result
end

-- uniform f64 in [0, 1): top 53 bits / 2^53, both steps exact in IEEE
function M.float()
  return (M.u64() >> 11) * 0x1p-53
end

-- uniform integer in [m, n] inclusive; range(n) = [1, n].
-- masked rejection: unbiased, expected < 2 draws
function M.range(m, n)
  if n == nil then m, n = 1, m end
  m = math.tointeger(m) or error("pt.rand.range: integer expected", 2)
  n = math.tointeger(n) or error("pt.rand.range: integer expected", 2)
  local span = n - m + 1
  if span <= 0 then error("pt.rand.range: empty range", 2) end
  local mask = span - 1
  mask = mask | (mask >> 1)
  mask = mask | (mask >> 2)
  mask = mask | (mask >> 4)
  mask = mask | (mask >> 8)
  mask = mask | (mask >> 16)
  mask = mask | (mask >> 32)
  while true do
    local x = M.u64() & mask
    if x < span then return m + x end
  end
end

-- pick a uniform element of a non-empty array
function M.pick(t)
  return t[M.range(#t)]
end

return M
