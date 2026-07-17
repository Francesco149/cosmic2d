-- world — demo 2's ground: a cm.terr heightfield in the proto scene_openworld
-- look (Body-Harvest vertex-color bands under a neutral detail mottle, a
-- water plane in the basins, cone trees on the grass), all generated
-- deterministically from cm.terr's integer-hash noise. ONE height grid is
-- both the visual mesh and the walk surface (T.sample is triangle-exact
-- against what T.emit draws — the level.lua one-box-list precedent); tree
-- trunks and high-band boulders contribute the AABB colliders, and the
-- grass clutter (pebbles/flowers, D3D-022) is walk-over deco.
--
-- Openworld lighting is its own (warm proto values, not the graybox sun);
-- main.draw re-applies it to cm.gb every frame so the mascot and the trees
-- sit in the same light as the terrain across hot reloads.

local m = cm.require("cm.math")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local terr = cm.require("cm.terr")

local W = select(2, ...) or {}

-- proto scene_openworld constants
W.sun = (function()
  local l = m.sqrt(0.55 ^ 2 + 1.0 + 0.2 ^ 2)
  return { -0.55 / l, -1.0 / l, -0.2 / l }
end)()
W.ambient = { 0.42, 0.44, 0.50 }
W.fog = { on = true, s = 40, e = 110, col = { 0.72, 0.76, 0.88 } }
-- proto sky(0xffd89660, 0xffeed8b8): the fb packs ABGR — that's a BLUE sky
W.sky_top = { 96 / 255, 150 / 255, 216 / 255 }
W.sky_bot = { 184 / 255, 216 / 255, 238 / 255 }
W.water_y = 0
local WATER_C = { 0.30, 0.48, 0.62 }
local TRUNK_C = { 0.42, 0.30, 0.22 }
local CANOPY_C = { 0.22, 0.42, 0.26 }
-- props (D3D-022)
local ROCK_C = { 0.56, 0.52, 0.49 }   -- the rock band's gray, a shade up
                                       -- (the first draft read charcoal)
local PEBBLE_C = { 0.40, 0.37, 0.35 }
local STEM_C = { 0.26, 0.46, 0.24 }
local PETALS = {                       -- per-flower head colors
  { 0.96, 0.95, 0.90 }, -- daisy white
  { 0.98, 0.84, 0.34 }, -- butter yellow
  { 0.94, 0.52, 0.44 }, -- coral
  { 0.60, 0.66, 0.94 }, -- periwinkle
}

local BANDS = { -- proto height palette (upper bound, color)
  { 0.15, { 0.76, 0.70, 0.50 } }, -- sand
  { 2.2, { 0.36, 0.55, 0.28 } },  -- grass
  { 4.2, { 0.26, 0.43, 0.24 } },  -- dark grass
  { 6.5, { 0.47, 0.43, 0.41 } },  -- rock
  { 1e9, { 0.92, 0.93, 0.97 } },  -- snow
}

local N, TILE = 72, 2.0

-- proto xs32 (the tree scatter PRNG — render-class placement, but the
-- boxes it yields are sim colliders, so it must stay deterministic)
local function xs32(st)
  local s = st[1]
  s = (s ~ (s << 13)) & 0xffffffff
  s = s ~ (s >> 17)
  s = (s ~ (s << 5)) & 0xffffffff
  st[1] = s
  return s
end

W.terr = nil
W.trees = {}     -- { {x, z, y, sc}, ... }
W.colliders = {} -- tree-trunk + boulder AABBs {x0,y0,z0,x1,y1,z1}
W.boulders = {}  -- { {x, z, y, n, r0, r1, h, yaw, sh}, ... }
W.pebbles = {}   -- { {x, z, y, r, h, yaw, sh}, ... }
W.flowers = {}   -- { {x, z, y, sh, hr, ci}, ... }
W.spawn = { x = 0, y = 0, z = 0 }

function W.ground(x, z)
  return terr.sample(W.terr, x, z)
end

function W.size()
  return terr.size(W.terr)
end

local function build_data()
  local t = terr.build{ w = N, h = N, tile = TILE }
  -- proto heights: 3-octave ridge-ish fbm, squared, 20u tall, basins < 0
  for z = 0, N do
    for x = 0, N do
      local base = 0.55 * terr.vnoise(31, x * 3, z * 3, 64)
                 + 0.30 * terr.vnoise(37, x * 3, z * 3, 32)
                 + 0.15 * terr.vnoise(41, x * 3, z * 3, 16)
      terr.hset(t, x, z, base * base * 20.0 - 1.0)
    end
  end
  -- the pond (D3D-019): the fbm floors at -1.0, so no basin is deeper
  -- than ankle water — scoop the noise's own deepest basin into a real
  -- pond so the swim regime has somewhere to live. Smooth radial bowl
  -- (quartic falloff), untouched outside PR; the tour route's nearest
  -- leg passes ~11u out.
  local PX, PZ, PR, PD = 42.0, 64.0, 9.0, 2.2
  for z = 0, N do
    for x = 0, N do
      local dx, dz = x * TILE - PX, z * TILE - PZ
      local q = 1.0 - (dx * dx + dz * dz) / (PR * PR)
      if q > 0 then
        terr.hset(t, x, z, terr.hget(t, x, z) - PD * q * q)
      end
    end
  end
  W.terr = t

  -- spawn: the grass-band spot nearest the world center (deterministic)
  local cx, cz = N * TILE / 2, N * TILE / 2
  local best = 1e18
  for z = 4, N - 4 do
    for x = 4, N - 4 do
      local wx, wz = (x + 0.5) * TILE, (z + 0.5) * TILE
      local h = terr.sample(t, wx, wz)
      if h > 1.5 and h < 3.0 then
        local d = (wx - cx) ^ 2 + (wz - cz) ^ 2
        if d < best then
          best = d
          W.spawn.x, W.spawn.z = wx, wz
        end
      end
    end
  end
  W.spawn.y = terr.sample(t, W.spawn.x, W.spawn.z)

  -- cone trees on the grass bands (proto scatter), clear of the spawn;
  -- trunks become the world's AABB colliders
  W.trees, W.colliders = {}, {}
  local st = { 99 }
  for _ = 1, 160 do
    local tx = (xs32(st) % (N * 20)) / 10.0
    local tz = (xs32(st) % (N * 20)) / 10.0
    local h = terr.sample(t, tx, tz)
    local sc = 0.7 + (xs32(st) % 50) / 100.0 -- draw BEFORE the accept test:
    -- the PRNG stream must not depend on which spots pass (replayable
    -- placement no matter how the accept rules evolve)
    if h >= 0.4 and h <= 3.8 then
      local dx, dz = tx - W.spawn.x, tz - W.spawn.z
      if dx * dx + dz * dz >= 36.0 then
        W.trees[#W.trees + 1] = { x = tx, z = tz, y = h, sc = sc }
        local r = 0.32 * sc
        W.colliders[#W.colliders + 1] =
          { tx - r, h, tz - r, tx + r, h + 2.2 * sc, tz + r }
      end
    end
  end

  -- props beyond trees (D3D-022). Each scatter runs its OWN xs32 stream:
  -- the tree stream above must stay byte-identical (its trunk boxes are
  -- the trace-locked collider list). Same lesson inside each loop: every
  -- draw happens BEFORE the accept test so placement survives rule edits.
  --
  -- Boulders keep to the high bands (h >= 3.8): every verified demo route
  -- leg stays h <= 3.3, so their colliders — world-bounds boxes per
  -- D3D-011, the visual rotates inside — cannot touch a golden trace.
  W.boulders, W.pebbles, W.flowers = {}, {}, {}
  local sb = { 517 }
  for _ = 1, 120 do
    local x = (xs32(sb) % (N * 20)) / 10.0
    local z = (xs32(sb) % (N * 20)) / 10.0
    local r0 = 0.45 + (xs32(sb) % 55) / 100.0
    local hh = 0.50 + (xs32(sb) % 55) / 100.0
    local yaw = (xs32(sb) % 628) / 100.0
    local ng = 5 + xs32(sb) % 3
    local sh = 0.88 + (xs32(sb) % 25) / 100.0 -- shade jitter
    local h = terr.sample(t, x, z)
    if h >= 3.8 and h <= 7.5 then
      W.boulders[#W.boulders + 1] = { x = x, z = z, y = h - 0.18,
        n = ng, r0 = r0, r1 = r0 * 0.62, h = hh, yaw = yaw, sh = sh }
      W.colliders[#W.colliders + 1] =
        { x - r0, h - 0.18, z - r0, x + r0, h - 0.18 + hh, z + r0 }
    end
  end
  -- pebbles: ankle clutter on the walkable bands, NO colliders
  local sp = { 733 }
  for _ = 1, 90 do
    local x = (xs32(sp) % (N * 20)) / 10.0
    local z = (xs32(sp) % (N * 20)) / 10.0
    local r = 0.12 + (xs32(sp) % 12) / 100.0
    local hh = 0.08 + (xs32(sp) % 8) / 100.0
    local yaw = (xs32(sp) % 628) / 100.0
    local sh = 0.85 + (xs32(sp) % 30) / 100.0
    local h = terr.sample(t, x, z)
    if h >= 0.4 and h <= 3.6 then
      local dx, dz = x - W.spawn.x, z - W.spawn.z
      if dx * dx + dz * dz >= 9.0 then
        W.pebbles[#W.pebbles + 1] =
          { x = x, z = z, y = h - 0.03, r = r, h = hh, yaw = yaw, sh = sh }
      end
    end
  end
  -- flowers: the bright grass band only, NO colliders (walk-over deco).
  -- They grow in PATCHES of 2-4 — lone flowers read as lollipops at
  -- 320x240; clumps read as a meadow. All four slot draws happen whether
  -- or not the patch (or slot) is accepted, same stream-stability lesson.
  local sf = { 271 }
  for _ = 1, 90 do
    local px = (xs32(sf) % (N * 20)) / 10.0
    local pz = (xs32(sf) % (N * 20)) / 10.0
    local count = 2 + xs32(sf) % 3
    local slot = {}
    for i = 1, 4 do
      slot[i] = {
        dx = ((xs32(sf) % 110) - 55) / 100.0, -- +-0.55u around the patch
        dz = ((xs32(sf) % 110) - 55) / 100.0,
        sh = 0.26 + (xs32(sf) % 14) / 100.0,
        hr = 0.09 + (xs32(sf) % 4) / 100.0,
        ci = 1 + xs32(sf) % #PETALS,
      }
    end
    if terr.sample(t, px, pz) >= 0.4 and terr.sample(t, px, pz) <= 2.15 then
      for i = 1, count do
        local s = slot[i]
        local x, z = px + s.dx, pz + s.dz
        local h = terr.sample(t, x, z)
        if h >= 0.4 and h <= 2.15 then -- a slot can straddle the band edge
          W.flowers[#W.flowers + 1] =
            { x = x, z = z, y = h, sh = s.sh, hr = s.hr, ci = s.ci }
        end
      end
    end
  end
end

-- static level geometry -> rc.ow.level; segments: terrain (detail-textured),
-- trees + props (untextured), water (blend, drawn LAST in main.draw)
W.tex = nil
W.vbuf = nil
W.segs = nil
W.water = nil -- { off, count }

function W.build()
  build_data()
  gb.sun, gb.ambient = W.sun, W.ambient -- trees light like the terrain
  W.tex = gb.load_textures("rc.ow.texids")
  W.detail = terr.load_detail("rc.ow.detail")

  local out, sg, off = {}, {}, 0
  local function flush(tex, ntris)
    sg[#sg + 1] = { tex = tex, count = ntris, off = off }
    off = off + ntris * 72
  end
  flush(W.detail, terr.emit(out, W.terr, {
    bands = BANDS, jitter = 0.35, seed = 9,
    sun = W.sun, amb = W.ambient,
  }))
  local n = 0
  for _, tr in ipairs(W.trees) do
    local sc = tr.sc
    n = n + gb.prism(out, m4.translate(tr.x, tr.y, tr.z),
                     5, 0.14 * sc, 0.14 * sc, 0.7 * sc, TRUNK_C, 0)
    n = n + gb.prism(out, m4.translate(tr.x, tr.y + 0.6 * sc, tr.z),
                     6, 0.85 * sc, 0, 2.2 * sc, CANOPY_C, 0)
  end
  local function shade(c, s)
    return { c[1] * s, c[2] * s, c[3] * s }
  end
  for _, b in ipairs(W.boulders) do
    n = n + gb.prism(out, m4.mul(m4.translate(b.x, b.y, b.z), m4.roty(b.yaw)),
                     b.n, b.r0, b.r1, b.h, shade(ROCK_C, b.sh), 1)
  end
  for _, p in ipairs(W.pebbles) do
    n = n + gb.prism(out, m4.mul(m4.translate(p.x, p.y, p.z), m4.roty(p.yaw)),
                     5, p.r, p.r * 0.6, p.h, shade(PEBBLE_C, p.sh), 1)
  end
  for _, f in ipairs(W.flowers) do
    n = n + gb.prism(out, m4.translate(f.x, f.y, f.z),
                     3, 0.025, 0.025, f.sh, STEM_C, 0)
    -- the head: a chunky 2-cone diamond (the bounce-gem species, tiny)
    n = n + gb.lathe(out, m4.translate(f.x, f.y + f.sh + f.hr * 0.7, f.z),
                     { 0, -f.hr, f.hr * 0.9, 0, 0, f.hr }, 5, PETALS[f.ci])
  end
  flush(0, n)
  local nw = terr.emit_water(out, W.terr, W.water_y, WATER_C, 140, 8)
  W.water = { off = off, count = nw }

  local bytes = table.concat(out)
  local ok, vb = pcall(pal.buf, "rc.ow.level", #bytes)
  if not ok then -- geometry changed size across a hot reload
    pal.buf_free("rc.ow.level")
    vb = pal.buf("rc.ow.level", #bytes)
  end
  vb:setstr(0, bytes)
  W.vbuf, W.segs = vb, sg
end

return W
