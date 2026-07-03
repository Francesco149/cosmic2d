-- procart.pnoise — tileable / world-space noise primitives for procedural
-- pixel art. Pure functions of (seed, x, y [, period]) built on prng.hash2.
--
-- The one idea that makes everything tile cleanly: noise is sampled at WORLD
-- pixel coordinates through a stateless hash, so two adjacent regions agree at
-- their border BY CONSTRUCTION — bake any rectangle of a material and it butts
-- seamlessly against any other rectangle of the same field. For a single tile
-- that must repeat against ITSELF, pass `period` (in lattice cells) and the
-- lattice wraps (classic periodic noise). Dev/render class, float math fine.

local prng = cm.require("prng")

local M = {}

local floor = math.floor
local hash2f = prng.hash2f

local function smooth(t) return t * t * (3 - 2 * t) end

-- value noise at (x, y) in LATTICE units (1.0 = one cell). Periodic in px/py
-- lattice cells when given (nil = infinite / world-space).
function M.value2(seed, x, y, px, py)
  local x0, y0 = floor(x), floor(y)
  local fx, fy = x - x0, y - y0
  local x1, y1 = x0 + 1, y0 + 1
  if px then x0, x1 = x0 % px, x1 % px end
  if py then y0, y1 = y0 % py, y1 % py end
  local a = hash2f(seed, x0, y0)
  local b = hash2f(seed, x1, y0)
  local c = hash2f(seed, x0, y1)
  local d = hash2f(seed, x1, y1)
  local ux, uy = smooth(fx), smooth(fy)
  local top = a + (b - a) * ux
  local bot = c + (d - c) * ux
  return top + (bot - top) * uy
end

-- fractal Brownian motion: `oct` octaves of value2, frequency doubling and
-- amplitude halving per octave (lac/gain override). x,y in PIXELS; freq is
-- cells-per-pixel of the base octave (e.g. 1/12 = ~12px features). Periodic
-- when px/py (in PIXELS, must be divisible by 1/freq for exact wrap... in
-- practice pass power-of-two tile sizes and freqs like 1/8, 1/16). Output
-- roughly [0,1], recentered so the mean sits near 0.5.
function M.fbm(seed, x, y, freq, oct, px, py)
  oct = oct or 3
  local sum, amp, norm = 0, 1, 0
  local f = freq
  for o = 1, oct do
    local lpx = px and floor(px * f + 0.5) or nil
    local lpy = py and floor(py * f + 0.5) or nil
    if lpx and lpx < 1 then lpx = 1 end
    if lpy and lpy < 1 then lpy = 1 end
    sum = sum + amp * M.value2(seed + o * 131, x * f, y * f, lpx, lpy)
    norm = norm + amp
    amp = amp * 0.5
    f = f * 2
  end
  return sum / norm
end

-- Worley / cellular noise: one feature point per lattice cell. Returns
-- F1 (distance to nearest point, in cells), F2 (second nearest), and the
-- nearest point's cell id hash (stable u64 — hash it further for per-facet
-- attributes). x,y in lattice units; periodic in px/py cells when given.
function M.worley(seed, x, y, px, py)
  local cx, cy = floor(x), floor(y)
  local f1, f2 = 1e9, 1e9
  local id = 0
  for j = -1, 1 do
    for i = -1, 1 do
      local gx, gy = cx + i, cy + j
      local hx, hy = gx, gy
      if px then hx = gx % px end
      if py then hy = gy % py end
      local h = prng.hash2(seed, hx, hy)
      -- feature point inside the cell from two independent halves of the hash
      local fx = gx + ((h >> 11) & 0xfffff) / 0x100000
      local fy = gy + ((h >> 33) & 0xfffff) / 0x100000
      local dx, dy = fx - x, fy - y
      local d = dx * dx + dy * dy
      if d < f1 then
        f2 = f1
        f1, id = d, h
      elseif d < f2 then
        f2 = d
      end
    end
  end
  return math.sqrt(f1), math.sqrt(f2), id
end

return M
