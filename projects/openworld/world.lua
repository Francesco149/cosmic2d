-- world — demo 2's ground: a cm.terr heightfield in the proto scene_openworld
-- look (Body-Harvest vertex-color bands under a neutral detail mottle, a
-- water plane in the basins, cone trees on the grass), all generated
-- deterministically from cm.terr's integer-hash noise. ONE height grid is
-- both the visual mesh and the walk surface (T.sample is triangle-exact
-- against what T.emit draws — the level.lua one-box-list precedent), and
-- the tree trunks contribute the only AABB colliders.
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
W.colliders = {} -- tree-trunk AABBs {x0,y0,z0,x1,y1,z1}
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
end

-- static level geometry -> rc.ow.level; segments: terrain (detail-textured),
-- trees (untextured), water (blend, drawn LAST in main.draw)
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
