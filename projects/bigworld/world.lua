-- world — the STREAMING world (COSMIC3D.md §10, the §8e directive): a
-- 2048x2048u heightfield that is never resident. Ground height is a PURE
-- FUNCTION of world lattice coords (terr.sample_fn) — the sim can stand
-- anywhere with zero terrain state, so snapshots/traces carry nothing
-- terrain-ish and a golden trace crosses chunk boundaries by construction.
--
-- Chunks exist only render-class: 16x16-tile windows emitted into
-- rc.bw.c<id> named buffers around the camera under a per-frame gen
-- budget, evicted past the resident ring (churn measured free). Prop
-- placement (trees, boulders) is a per-chunk deterministic stream — a
-- chunk regenerates byte-identically on every visit — and the SIM derives
-- collider AABBs from the same pure streams on demand (boxes_near), so
-- solidity works whether or not the chunk is resident on screen.
--
-- The honesty proof: _G.BW_RES / _G.BW_BUDGET override the streaming
-- knobs render-side only; a recorded trace must verify byte-identical
-- under any override (the sim never sees chunks).

local m = cm.require("cm.math")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local terr = cm.require("cm.terr")

local W = select(2, ...) or {}

-- openworld's warm light + a slightly deeper fog for the long views
W.sun = (function()
  local l = m.sqrt(0.55 ^ 2 + 1.0 + 0.2 ^ 2)
  return { -0.55 / l, -1.0 / l, -0.2 / l }
end)()
W.ambient = { 0.42, 0.44, 0.50 }
W.fog = { on = true, s = 46, e = 118, col = { 0.72, 0.76, 0.88 } }
W.sky_top = { 96 / 255, 150 / 255, 216 / 255 }
W.sky_bot = { 184 / 255, 216 / 255, 238 / 255 }
W.water_y = 0
local WATER_C = { 0.30, 0.48, 0.62 }
local TRUNK_C = { 0.42, 0.30, 0.22 }
local CANOPY_C = { 0.22, 0.42, 0.26 }
local ROCK_C = { 0.56, 0.52, 0.49 }

local BANDS = { -- the openworld palette, snow reachable (mountains go ~30u)
  { 0.15, { 0.76, 0.70, 0.50 } }, -- sand
  { 2.2, { 0.36, 0.55, 0.28 } },  -- grass
  { 4.2, { 0.26, 0.43, 0.24 } },  -- dark grass
  { 7.5, { 0.47, 0.43, 0.41 } },  -- rock
  { 1e9, { 0.92, 0.93, 0.97 } },  -- snow
}

-- world geometry: 64x64 chunks of 16x16 tiles of 2u = 2048u square
local TILE = 2.0
local CH_T = 16   -- tiles per chunk side (32u)
local WCH = 64    -- chunks per side
local NT = WCH * CH_T -- 1024 tiles per side
W.TILE, W.CH_T, W.WCH = TILE, CH_T, WCH

-- ---- the pure height function -------------------------------------------
-- the openworld fbm shape in world coords + a continental octave: plains
-- where cont is small, ~30u mountain regions where it is large, lakes
-- where the base dips below water. NO stored grid anywhere.
local function hfn(vx, vz)
  local base = 0.55 * terr.vnoise(31, vx * 3, vz * 3, 64)
             + 0.30 * terr.vnoise(37, vx * 3, vz * 3, 32)
             + 0.15 * terr.vnoise(41, vx * 3, vz * 3, 16)
  local cont = terr.vnoise(53, vx, vz, 192)
  return base * base * (6.0 + 26.0 * cont * cont) - 1.4
end
W.hfn = hfn

function W.ground(x, z)
  x = m.clamp(x, 0, NT * TILE)
  z = m.clamp(z, 0, NT * TILE)
  return terr.sample_fn(hfn, TILE, x, z)
end

function W.size()
  return NT * TILE, NT * TILE
end

-- ---- spawn: grass nearest the world center (small deterministic search) --
W.spawn = { x = 0, y = 0, z = 0 }
local function find_spawn()
  local c = NT // 2
  local best = 1e18
  for z = c - 40, c + 40 do
    for x = c - 40, c + 40 do
      local wx, wz = (x + 0.5) * TILE, (z + 0.5) * TILE
      local h = W.ground(wx, wz)
      if h > 1.5 and h < 3.0 then
        local d = (wx - c * TILE) ^ 2 + (wz - c * TILE) ^ 2
        if d < best then
          best = d
          W.spawn.x, W.spawn.z = wx, wz
        end
      end
    end
  end
  W.spawn.y = W.ground(W.spawn.x, W.spawn.z)
end

-- ---- per-chunk props: pure streams, sim-shared ---------------------------
-- xs32 per chunk (draws BEFORE accepts, the D3D-022 stream-stability rule).
-- The sim needs the collider boxes wherever the player is; the renderer
-- needs the visuals wherever the camera looks — both read THIS, cached
-- (memoizing a pure function is sim-legal; the cache rebuilds identically
-- after any reload or restore).
local function xs32(st)
  local s = st[1]
  s = (s ~ (s << 13)) & 0xffffffff
  s = s ~ (s >> 17)
  s = (s ~ (s << 5)) & 0xffffffff
  st[1] = s
  return s
end

local prop_cache = {}
function W.props(cx, cz)
  local id = cz * WCH + cx
  local p = prop_cache[id]
  if p then return p end
  p = { trees = {}, boulders = {}, colliders = {} }
  local seed = ((cx * 374761393) ~ (cz * 668265263) ~ 0x9e3779b9) & 0xffffffff
  local st = { seed ~= 0 and seed or 1 }
  local ox, oz = cx * CH_T * TILE, cz * CH_T * TILE
  for _ = 1, 8 do -- trees on the grass bands
    local x = ox + (xs32(st) % (CH_T * 20)) / 10.0
    local z = oz + (xs32(st) % (CH_T * 20)) / 10.0
    local sc = 0.7 + (xs32(st) % 50) / 100.0
    local h = W.ground(x, z)
    if h >= 0.4 and h <= 3.8 then
      local dx, dz = x - W.spawn.x, z - W.spawn.z
      if dx * dx + dz * dz >= 36.0 then
        p.trees[#p.trees + 1] = { x = x, z = z, y = h, sc = sc }
        local r = 0.32 * sc
        p.colliders[#p.colliders + 1] =
          { x - r, h, z - r, x + r, h + 2.2 * sc, z + r }
      end
    end
  end
  for _ = 1, 3 do -- boulders on the dirt/rock band (the round-14 verdict)
    local x = ox + (xs32(st) % (CH_T * 20)) / 10.0
    local z = oz + (xs32(st) % (CH_T * 20)) / 10.0
    local r0 = 0.45 + (xs32(st) % 55) / 100.0
    local hh = 0.50 + (xs32(st) % 55) / 100.0
    local yaw = (xs32(st) % 628) / 100.0
    local ng = 5 + xs32(st) % 3
    local sh = 0.88 + (xs32(st) % 25) / 100.0
    local h = W.ground(x, z)
    if h >= 4.2 and h <= 8.0 then
      p.boulders[#p.boulders + 1] = { x = x, z = z, y = h - 0.18,
        n = ng, r0 = r0, r1 = r0 * 0.62, h = hh, yaw = yaw, sh = sh }
      p.colliders[#p.colliders + 1] =
        { x - r0, h - 0.18, z - r0, x + r0, h - 0.18 + hh, z + r0 }
    end
  end
  prop_cache[id] = p
  return p
end

-- collider AABBs near world (x,z): the 3x3 chunk window's props, cached
-- per center chunk. This is what player.step collides against — derived,
-- never stored, resident-independent.
local near_cache = {}
function W.boxes_near(x, z)
  local cx = m.clamp((x / (CH_T * TILE)) // 1, 0, WCH - 1)
  local cz = m.clamp((z / (CH_T * TILE)) // 1, 0, WCH - 1)
  local id = cz * WCH + cx
  local list = near_cache[id]
  if list then return list end
  list = {}
  for dz = -1, 1 do
    for dx = -1, 1 do
      local nx, nz = cx + dx, cz + dz
      if nx >= 0 and nx < WCH and nz >= 0 and nz < WCH then
        for _, b in ipairs(W.props(nx, nz).colliders) do
          list[#list + 1] = b
        end
      end
    end
  end
  near_cache[id] = list
  return list
end

-- ---- the render-class chunk pager ---------------------------------------
-- resident[id] = { buf, name, terr_n, prop_n, water_off, water_n }
local resident = {}
W.resident = resident
W.gen_count = 0 -- chunks generated since boot (HUD)

local function shade(c, s)
  return { c[1] * s, c[2] * s, c[3] * s }
end

local function gen_chunk(cx, cz)
  local id = cz * WCH + cx
  local t = terr.build{ w = CH_T, h = CH_T, tile = TILE }
  local ox, oz = cx * CH_T, cz * CH_T
  local minh = 1e9
  for z = 0, CH_T do
    for x = 0, CH_T do
      local h = hfn(ox + x, oz + z)
      terr.hset(t, x, z, h)
      if h < minh then minh = h end
    end
  end
  local out = {}
  local nt = terr.emit(out, t, {
    bands = BANDS, jitter = 0.35, seed = 9,
    sun = W.sun, amb = W.ambient, ox = ox, oz = oz,
  })
  local props = W.props(cx, cz)
  local np = 0
  for _, tr in ipairs(props.trees) do
    local sc = tr.sc
    np = np + gb.prism(out, m4.translate(tr.x, tr.y, tr.z),
                       5, 0.14 * sc, 0.14 * sc, 0.7 * sc, TRUNK_C, 0)
    np = np + gb.prism(out, m4.translate(tr.x, tr.y + 0.6 * sc, tr.z),
                       6, 0.85 * sc, 0, 2.2 * sc, CANOPY_C, 0)
  end
  for _, b in ipairs(props.boulders) do
    np = np + gb.prism(out, m4.mul(m4.translate(b.x, b.y, b.z),
                                   m4.roty(b.yaw)),
                       b.n, b.r0, b.r1, b.h, shade(ROCK_C, b.sh), 1)
  end
  local woff, nw = 0, 0
  if minh < W.water_y + 0.05 then -- the chunk dips underwater: one quad
    woff = (nt + np) * 72
    nw = terr.emit_water(out, t, W.water_y, WATER_C, 140, CH_T, ox, oz)
  end
  local bytes = table.concat(out)
  local name = "rc.bw.c" .. id
  local ok, vb = pcall(pal.buf, name, #bytes)
  if not ok then -- stale generation across a hot reload
    pal.buf_free(name)
    vb = pal.buf(name, #bytes)
  end
  vb:setstr(0, bytes)
  resident[id] = { buf = vb, name = name, terr_n = nt, prop_n = np,
                   water_off = woff, water_n = nw }
  W.gen_count = W.gen_count + 1
end

-- page around focus (fx,fz): generate up to `budget` missing chunks in
-- the resident ring (nearest first), evict everything outside ring+1.
-- Returns resident count (HUD). Render-class: called from draw only.
function W.page(fx, fz, res_r, budget)
  local cs = CH_T * TILE
  local fcx = m.clamp((fx / cs) // 1, 0, WCH - 1)
  local fcz = m.clamp((fz / cs) // 1, 0, WCH - 1)
  -- gen: collect missing in-window, nearest first
  local missing = {}
  for cz = m.max(0, fcz - res_r), m.min(WCH - 1, fcz + res_r) do
    for cx = m.max(0, fcx - res_r), m.min(WCH - 1, fcx + res_r) do
      if not resident[cz * WCH + cx] then
        local dx, dz = cx - fcx, cz - fcz
        missing[#missing + 1] = { d = dx * dx + dz * dz, cx = cx, cz = cz }
      end
    end
  end
  table.sort(missing, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    local ia = a.cz * WCH + a.cx
    local ib = b.cz * WCH + b.cx
    return ia < ib -- total order: ties break on id, sort stays deterministic
  end)
  for i = 1, m.min(budget, #missing) do
    gen_chunk(missing[i].cx, missing[i].cz)
  end
  -- evict outside the ring (+1 hysteresis so the border doesn't thrash)
  local ev = res_r + 1
  for id, c in pairs(resident) do
    local cx, cz = id % WCH, id // WCH
    if m.abs(cx - fcx) > ev or m.abs(cz - fcz) > ev then
      pal.buf_free(c.name)
      resident[id] = nil
    end
  end
  local n = 0
  for _ in pairs(resident) do n = n + 1 end
  return n
end

-- submit resident chunks within draw_d of (fx,fz): opaque segments now;
-- water offsets are collected for main.draw's blend pass (water draws
-- after ALL opaque, openworld's rule). Fixed cz/cx iteration order —
-- submission order is deterministic for the pixel goldens.
function W.submit(fx, fz, draw_d, water_out)
  local cs = CH_T * TILE
  local fcx = m.clamp((fx / cs) // 1, 0, WCH - 1)
  local fcz = m.clamp((fz / cs) // 1, 0, WCH - 1)
  local r = (draw_d / cs) // 1 + 1
  local d2max = draw_d * draw_d
  local tris = 0
  for cz = m.max(0, fcz - r), m.min(WCH - 1, fcz + r) do
    for cx = m.max(0, fcx - r), m.min(WCH - 1, fcx + r) do
      local c = resident[cz * WCH + cx]
      if c then
        local mx, mz = (cx + 0.5) * cs, (cz + 0.5) * cs
        local dx, dz = mx - fx, mz - fz
        if dx * dx + dz * dz <= d2max then
          pal.x_tris(W.detail, c.buf, c.terr_n, 0, 0)
          if c.prop_n > 0 then
            pal.x_tris(0, c.buf, c.prop_n, c.terr_n * 72, 0)
          end
          if c.water_n > 0 then
            water_out[#water_out + 1] = c
          end
          tris = tris + c.terr_n + c.prop_n
        end
      end
    end
  end
  return tris
end

W.tex = nil
W.detail = nil

function W.build()
  find_spawn()
  gb.sun, gb.ambient = W.sun, W.ambient
  W.tex = gb.load_textures("rc.bw.texids")
  W.detail = terr.load_detail("rc.bw.detail")
  -- hot reload: the pager's module-table state survives, but any resident
  -- chunk emitted by OLD code is stale — drop them all; they regenerate
  -- under the ordinary budget (and buffers rebind by name)
  for id, c in pairs(resident) do
    pal.buf_free(c.name)
    resident[id] = nil
  end
end

return W
