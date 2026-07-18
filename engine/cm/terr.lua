-- cm.terr — the heightfield terrain: demo 2's Body-Harvest-style openworld
-- ground (proto scene_openworld is the look reference; COSMIC3D.md §9).
-- A terrain is a plain (w+1)x(h+1) per-VERTEX height grid — smooth hills,
-- no cliffs; the per-corner-tile GND model with auto cliff walls (D3D-006,
-- COSMIC3D.md §4) is the later editor-era asset, and RO-style sharp edges
-- will grow out of this module when demo 3 needs them.
--
-- Determinism: heights are plain Lua data built by the cartridge from
-- T.vnoise (integer-hash value noise — pure IEEE arithmetic, no libm), and
-- the SIM reads them through T.sample, which is TRIANGLE-EXACT: it splits
-- each tile on the same NW->SE diagonal the emitter draws, so the player's
-- feet track the rendered ground precisely (colliders-are-the-sim-truth).
-- Emission is render-class: height-banded jittered vertex colors (the
-- "painted" era look), one flattened normal per tile, a world-continuous
-- detail UV (the neutral mottle multiplies the palette — proto tx_detail).

local m = cm.require("cm.math")

local T = select(2, ...) or {}

-- ---- deterministic noise -------------------------------------------------

local function hash(seed, ix, iy)
  local s = (seed ~ (ix * 374761393) ~ (iy * 668265263)) & 0xffffffff
  s = (s ~ (s << 13)) & 0xffffffff
  s = s ~ (s >> 17)
  s = (s ~ (s << 5)) & 0xffffffff
  return (s & 0xffff) / 65535.0
end
T.hash = hash

-- unwrapped value noise on a lattice of spacing cell (x/y in lattice units,
-- typically small integers — proto feeds x*3). Smoothstep interpolation.
function T.vnoise(seed, x, y, cell)
  local gx, gy = x // cell, y // cell
  local fx, fy = (x % cell) / cell, (y % cell) / cell
  local a = hash(seed, gx, gy)
  local b = hash(seed, gx + 1, gy)
  local c = hash(seed, gx, gy + 1)
  local d = hash(seed, gx + 1, gy + 1)
  local u = fx * fx * (3 - 2 * fx)
  local v = fy * fy * (3 - 2 * fy)
  return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
end

-- ---- the terrain object --------------------------------------------------

-- (w x h tiles of size tile; heights live at the (w+1)x(h+1) vertices)
function T.build(o)
  local t = { w = o.w, h = o.h, tile = o.tile or 2.0, hts = {} }
  for i = 1, (o.w + 1) * (o.h + 1) do t.hts[i] = 0 end
  return t
end

function T.hget(t, vx, vz)
  vx = m.clamp(vx, 0, t.w)
  vz = m.clamp(vz, 0, t.h)
  return t.hts[vz * (t.w + 1) + vx + 1]
end

function T.hset(t, vx, vz, v)
  t.hts[vz * (t.w + 1) + vx + 1] = v
end

-- world-space size on x/z
function T.size(t)
  return t.w * t.tile, t.h * t.tile
end

-- height at world (wx, wz), triangle-exact against the rendered mesh: the
-- emitter splits every tile NW->SE (gb.quad's A-C diagonal), so fx >= fz
-- lies in tri(NW,NE,SE) and fx < fz in tri(NW,SE,SW). Edges clamp.
function T.sample(t, wx, wz)
  local s = t.tile
  local x = m.clamp((wx / s) // 1, 0, t.w - 1)
  local z = m.clamp((wz / s) // 1, 0, t.h - 1)
  local fx = m.clamp(wx / s - x, 0, 1)
  local fz = m.clamp(wz / s - z, 0, 1)
  local h00 = T.hget(t, x, z)
  local h11 = T.hget(t, x + 1, z + 1)
  if fx >= fz then
    local h10 = T.hget(t, x + 1, z)
    return h00 + (h10 - h00) * fx + (h11 - h10) * fz
  end
  local h01 = T.hget(t, x, z + 1)
  return h00 + (h01 - h00) * fz + (h11 - h01) * fx
end

-- height at world (wx, wz) from a PURE lattice-vertex height function
-- hfn(vx, vz) instead of a stored grid — the streaming-world model
-- (COSMIC3D.md §10): the sim can stand anywhere in a world of any size
-- with zero resident terrain state. Triangle-exact against T.emit's
-- NW->SE diagonal exactly like T.sample; the caller clamps wx/wz to its
-- world bounds (this function has no edge knowledge).
function T.sample_fn(hfn, tile, wx, wz)
  local x = (wx / tile) // 1
  local z = (wz / tile) // 1
  local fx = m.clamp(wx / tile - x, 0, 1)
  local fz = m.clamp(wz / tile - z, 0, 1)
  local h00 = hfn(x, z)
  local h11 = hfn(x + 1, z + 1)
  if fx >= fz then
    local h10 = hfn(x + 1, z)
    return h00 + (h10 - h00) * fx + (h11 - h10) * fz
  end
  local h01 = hfn(x, z + 1)
  return h00 + (h01 - h00) * fz + (h11 - h01) * fx
end

-- ---- emission (render-class) ---------------------------------------------

local pack = string.pack

-- one vertex, proto light_vertex rules: zero normal = unlit (water), else
-- col * (ambient + max(0, -N.sun)) clamped
local function vert(x, y, z, u, v, col, nx, ny, nz, sun, amb, alpha)
  local r, g, b = col[1], col[2], col[3]
  if nx ~= 0 or ny ~= 0 or nz ~= 0 then
    local d = m.max(0, -(nx * sun[1] + ny * sun[2] + nz * sun[3]))
    r = m.clamp(r * (amb[1] + d), 0, 1)
    g = m.clamp(g * (amb[2] + d), 0, 1)
    b = m.clamp(b * (amb[3] + d), 0, 1)
  end
  return pack("<fffffBBBB", x, y, z, u, v,
              (r * 255) // 1, (g * 255) // 1, (b * 255) // 1, alpha or 255)
end

-- band palette lookup: bands = ordered { {upper_h, {r,g,b}}, ... }; the
-- last entry catches everything above
local function band_col(bands, h)
  for i = 1, #bands do
    if h < bands[i][1] then return bands[i][2] end
  end
  return bands[#bands][2]
end

-- emit the whole grid into out[] (concat once, upload once — static level
-- geometry). opts:
--   bands  = ordered { {upper_h, {r,g,b}}, ... }  (required)
--   jitter = per-corner height jitter before banding (default 0.35: ragged
--            organic band borders, the proto look; 0 = hard contours)
--   seed   = jitter hash seed (default 9)
--   sun    = light dir (normalized), amb = ambient (gb's graybox values
--            are NOT defaulted here — the openworld look has its own light)
--   flat_y = normal-flattening divisor (default 2: softer than geometric,
--            the proto "painted" shading)
--   ox, oz = LATTICE offset of this grid's origin in a larger world
--            (default 0): vertex positions, jitter hashes, and the detail
--            UV all use world vertex coords (position (ox+x)*tile), so a
--            chunk emitted from a window of one big world lands in place
--            with no transform and agrees byte-exactly with its neighbors
--            along shared borders (COSMIC3D.md §10).
-- Returns tris emitted.
function T.emit(out, t, opts)
  local s = t.tile
  local bands, sun, amb = opts.bands, opts.sun, opts.amb
  local jit = opts.jitter or 0.35
  local seed = opts.seed or 9
  local flat = opts.flat_y or 2.0
  local ox, oz = opts.ox or 0, opts.oz or 0
  local ntris = 0
  for z = 0, t.h - 1 do
    for x = 0, t.w - 1 do
      local h00 = T.hget(t, x, z)
      local h10 = T.hget(t, x + 1, z)
      local h01 = T.hget(t, x, z + 1)
      local h11 = T.hget(t, x + 1, z + 1)
      -- per-tile normal from corner slopes, y-flattened (proto openworld)
      local nx = (h00 + h01 - h10 - h11) / (2 * s)
      local nz = (h00 + h10 - h01 - h11) / (2 * s)
      local nl = m.sqrt(nx * nx + flat * flat + nz * nz)
      nx, nz = nx / nl, nz / nl
      local ny = flat / nl
      -- per-corner banded color; jitter hashes the shared WORLD vertex so
      -- seams agree across tiles (and across chunk borders under ox/oz)
      local wx, wz = ox + x, oz + z
      local c00 = band_col(bands, h00 + (hash(seed, wx, wz) - 0.5) * jit)
      local c10 = band_col(bands, h10 + (hash(seed, wx + 1, wz) - 0.5) * jit)
      local c01 = band_col(bands, h01 + (hash(seed, wx, wz + 1) - 0.5) * jit)
      local c11 = band_col(bands, h11 + (hash(seed, wx + 1, wz + 1) - 0.5) * jit)
      local x0, x1, z0, z1 = wx * s, (wx + 1) * s, wz * s, (wz + 1) * s
      -- detail uv: one tile per tile, continuous in world space
      local A = vert(x0, h00, z0, wx, wz, c00, nx, ny, nz, sun, amb)
      local B = vert(x1, h10, z0, wx + 1, wz, c10, nx, ny, nz, sun, amb)
      local C = vert(x1, h11, z1, wx + 1, wz + 1, c11, nx, ny, nz, sun, amb)
      local D = vert(x0, h01, z1, wx, wz + 1, c01, nx, ny, nz, sun, amb)
      out[#out + 1] = A .. B .. C .. A .. C .. D -- NW->SE diagonal: T.sample
      ntris = ntris + 2
    end
  end
  return ntris
end

-- flat water plane at level y over the whole grid, unlit (zero normal, the
-- proto rule), alpha-blended — draw as a blend segment (flags 4) after all
-- opaque. Chunked so per-vertex fog stays honest. Returns tris.
function T.emit_water(out, t, y, col, alpha, step, ox, oz)
  step = step or 8
  ox, oz = ox or 0, oz or 0 -- lattice offset, same contract as T.emit
  local s = t.tile
  local ntris = 0
  for z = 0, t.h - 1, step do
    for x = 0, t.w - 1, step do
      local x1t = m.min(x + step, t.w)
      local z1t = m.min(z + step, t.h)
      local x0, x1 = (ox + x) * s, (ox + x1t) * s
      local z0, z1 = (oz + z) * s, (oz + z1t) * s
      local A = vert(x0, y, z0, 0, 0, col, 0, 0, 0, nil, nil, alpha)
      local B = vert(x1, y, z0, 0, 0, col, 0, 0, 0, nil, nil, alpha)
      local C = vert(x1, y, z1, 0, 0, col, 0, 0, 0, nil, nil, alpha)
      local D = vert(x0, y, z1, 0, 0, col, 0, 0, 0, nil, nil, alpha)
      out[#out + 1] = A .. B .. C .. A .. C .. D
      ntris = ntris + 2
    end
  end
  return ntris
end

-- ---- the neutral detail texture (proto tx_detail) -------------------------
-- near-white mottle multiplied over the vertex-color palette ("Body Harvest
-- keeps some texture on its terrain"). Tileable: wrapped fbm, so this uses
-- its own periodic noise (T.vnoise is unwrapped by design).

local function wnoise(seed, x, y, period, cell)
  local n = period // cell
  local gx, gy = (x // cell) % n, (y // cell) % n
  local fx, fy = (x % cell) / cell, (y % cell) / cell
  local a = hash(seed, gx, gy)
  local b = hash(seed, (gx + 1) % n, gy)
  local c = hash(seed, gx, (gy + 1) % n)
  local d = hash(seed, (gx + 1) % n, (gy + 1) % n)
  local u = fx * fx * (3 - 2 * fx)
  local v = fy * fy * (3 - 2 * fy)
  return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
end

local function wfbm(seed, x, y, period)
  return 0.55 * wnoise(seed, x, y, period, period // 4)
       + 0.30 * wnoise(seed * 7 + 1, x, y, period, period // 8)
       + 0.15 * wnoise(seed * 13 + 2, x, y, period, period // 16)
end

-- (re)create the detail texture; id persists in a named buffer so hot
-- reloads free the previous generation first (the gb.load_textures
-- pattern). Returns the texture id.
function T.load_detail(idbuf_name)
  local idbuf = pal.buf(idbuf_name, 8)
  if idbuf:u32(0) == 1 then pal.tex_free(idbuf:u32(4)) end
  local px = {}
  for y = 0, 63 do
    for x = 0, 63 do
      local v = 0.86 + 0.14 * wfbm(1201, x, y, 64)
      local s = ((x * 73856093) ~ (y * 19349663) ~ 777) & 0xffffffff
      s = (s ~ (s << 13)) & 0xffffffff
      s = s ~ (s >> 17)
      s = (s ~ (s << 5)) & 0xffffffff
      if (s & 255) > 249 then v = v * 0.82 end -- sparse dark flecks
      if (s & 255) < 3 then v = v * 1.10 end
      local g = m.min(255, (v * 255) // 1)
      px[#px + 1] = string.char(g, g, g, 255)
    end
  end
  local id = pal.tex_create(64, 64, table.concat(px))
  idbuf:u32(0, 1)
  idbuf:u32(4, id)
  return id
end

return T
