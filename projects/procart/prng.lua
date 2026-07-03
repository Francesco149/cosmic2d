-- procart.prng — a LOCAL, pure PRNG (splitmix64) + stateless coordinate hashes.
--
-- Deliberately NOT cm.rand: that streams from the "cm.sim" named buffer, and
-- art generation must never touch the sim stream. A generated sprite/tile is a
-- pure function of (seed, knobs) — same seed, same pixels, forever, on every
-- platform (Lua 5.4 integer ops are exact). Dev/render class (D040): these
-- pixels are render-only assets, never sim state.

local M = {}

-- the splitmix64 finalizer: one avalanche round, the workhorse for both the
-- sequential stream and the coordinate hashes.
local function mix(z)
  z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
  z = (z ~ (z >> 27)) * 0x94d049bb133111eb
  return z ~ (z >> 31)
end
M.mix = mix

local GOLD = 0x9e3779b97f4a7c15

-- ---- sequential stream ----

local rng = {}
rng.__index = rng

function M.new(seed)
  return setmetatable({ s = mix(seed or 0) }, rng)
end

function rng:u64()
  self.s = self.s + GOLD
  return mix(self.s)
end

-- uniform f64 in [0,1)
function rng:float()
  return (self:u64() >> 11) * 0x1p-53
end

-- uniform integer in [m,n] inclusive; range(n) = [1,n]
function rng:range(m, n)
  if n == nil then m, n = 1, m end
  return m + self:u64() % (n - m + 1) -- modulo bias is irrelevant for art
end

function rng:pick(t)
  return t[self:range(#t)]
end

function rng:chance(p)
  return self:float() < p
end

-- uniform float in [a,b]
function rng:uniform(a, b)
  return a + (b - a) * self:float()
end

-- ---- stateless coordinate hashes (the lattice fabric for noise) ----

-- hash a 2D integer coordinate under a seed → u64. Multiply by two different
-- odd constants first so x and y avalanche independently (no diagonal artifacts).
function M.hash2(seed, x, y)
  return mix(seed ~ mix(x * 0x9e3779b97f4a7c15 ~ mix(y * 0xc2b2ae3d27d4eb4f)))
end

-- hash → uniform f64 in [0,1)
function M.hash2f(seed, x, y)
  return (M.hash2(seed, x, y) >> 11) * 0x1p-53
end

return M
