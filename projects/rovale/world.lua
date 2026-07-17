-- world — demo 3's RO vale (COSMIC3D.md §11, proto scene_ro2 verbatim-ish):
-- a 32x32-tile cm.terr heightfield with a domain-warped lobed pond, a dirt
-- path winding to a diagonal gazebo on a knoll, round trees + bushes, and
-- the demo's signature move: every tile gets a UNIQUE 34x34 baked texture
-- (32 + 1-texel gutter, the RO 258-slot trick) sampling materials in
-- continuous world space with feathered noisy weights and prop shadows
-- multiplied in — zero visible tile grid. The bake is RENDER-CLASS and
-- budgeted (W.bake in draw, tiles/frame knob): the sim reads only
-- T.sample heights, the walk grid, and the deck overrides — a trace
-- replays byte-identical under any bake budget (the §10 honesty shape).
--
-- Sim truth: W.ground (terrain + walkable deck slabs, the §4 walkable-prop
-- answer), W.walkable + cm.walk pathing on the 64x64 walk grid (1u, the GAT
-- scale: 2x the render tiles), W.shadow (the same pure function the bake
-- multiplies in tints sprites at their feet — recipe rule 0.7+0.3*sh).

local m = cm.require("cm.math")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local terr = cm.require("cm.terr")

local W = select(2, ...) or {}

-- ---- the ro2 scene constants (docs/research-3d/ro-render-recipe.md) ----
W.sun = (function()
  local l = m.sqrt(0.45 ^ 2 + 1.0 + 0.35 ^ 2)
  return { -0.45 / l, -1.0 / l, -0.35 / l }
end)()
W.ambient = { 0.55, 0.55, 0.58 }
W.fog = { on = true, s = 110, e = 190, col = { 0.74, 0.80, 0.88 } }
-- proto sky(0xffe0a866, 0xfff0d8b0) — ABGR, so this is a warm-blue sky
W.sky_top = { 102 / 255, 168 / 255, 224 / 255 }
W.sky_bot = { 176 / 255, 216 / 255, 240 / 255 }
W.water_y = -0.35
local WATER_C = { 0.42, 0.72, 0.66 } -- milky teal, unlit, alpha 144/255

local N, TILE = 32, 2.0 -- 64u square vale
W.N, W.TILE = N, TILE
local ATLAS = N * 34 -- 1088

-- the gazebo placement (diagonal on purpose — §8c)
local GX, GZ, GROT = 40.0, 22.0, 0.55
W.gazebo = { x = GX, z = GZ, rot = GROT }
local PLAZA_H = 1.6

-- the path curve: x as a function of z (world coords)
function W.path_x(wz)
  return 34.0 + 9.0 * m.sin(wz * 0.12)
end

local vn = terr.vnoise
local floor = math.floor

local function fbm(seed, x, y, c1, c2, c3)
  return 0.55 * vn(seed, x, y, c1) + 0.30 * vn(seed + 7, x, y, c2)
       + 0.15 * vn(seed + 13, x, y, c3)
end

local function sstep01(t)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return t * t * (3 - 2 * t)
end

-- ---- terrain data --------------------------------------------------------

W.terr = nil
W.props = {}     -- { {x, z, sc, bush}, ... } trees + bushes
W.casters = {}   -- shadow casters { {x, z, r}, ... } (bake + sprite tint)
W.fences = {}    -- { {x, z}, ... }
W.blockers = {}  -- walk blockers {x0,z0,x1,z1} (xz, pre-expanded)
W.spawn = { x = 0, z = 0 }

-- the two plaza deck slabs (crisp props the ground read flows around, §8c
-- v6): walkable ON TOP — W.ground returns the deck height inside them
-- (the §4 walkable-prop answer, first exercised here)
local DECKS = {
  { hx = 4.7, hz = 4.7, top = PLAZA_H + 0.22 }, -- outer slab
  { hx = 2.8, hz = 2.8, top = PLAZA_H + 0.50 }, -- inner slab
}

local function build_heights()
  local t = terr.build{ w = N, h = N, tile = TILE }
  for z = 0, N do
    for x = 0, N do
      local wx, wz = x * TILE, z * TILE
      local h = 2.6 * fbm(881, x * 5, z * 5, 64, 32, 16) - 0.9
      -- domain warp: wobble the sample point so basin edges meander
      local wxp = wx + 5.0 * (fbm(661, x * 6, z * 6, 48, 24, 12) - 0.5)
      local wzp = wz + 5.0 * (fbm(668, x * 6, z * 6, 48, 24, 12) - 0.5)
      -- three overlapping lobes -> a lake, not a circle
      local dip = 0
      local L = { { 14, 40, 10.5 }, { 24, 47, 7.5 }, { 9, 50, 6.5 } }
      for i = 1, 3 do
        local dx, dz = wxp - L[i][1], wzp - L[i][2]
        local d2 = (dx * dx + dz * dz) / (L[i][3] * L[i][3])
        if d2 < 1 then
          local k = (1 - d2) * (1 - d2) * 2.8
          if k > dip then dip = k end
        end
      end
      h = h - dip
      -- the ford: where the path crosses the pond arm, the bed rises to
      -- ankle depth (a wading crossing, not a swim — the path stays a path)
      local pd = m.abs(wx - W.path_x(wz))
      local ford = -0.45 - 2.0 * sstep01((pd - 1.8) / 1.2)
      if h < ford then h = ford end
      local gdx, gdz = wx - GX, wz - GZ -- gazebo knoll
      local gd2 = (gdx * gdx + gdz * gdz) / (9.0 * 9.0)
      if gd2 < 1 then h = h * gd2 + PLAZA_H * (1 - gd2) end
      terr.hset(t, x, z, h)
    end
  end
  -- flatten the plaza proper (rotated frame: the flat pad under the decks)
  local c, s = m.cos(-GROT), m.sin(-GROT)
  for z = 0, N do
    for x = 0, N do
      local dx, dz = x * TILE - GX, z * TILE - GZ
      local rx, rz = dx * c - dz * s, dx * s + dz * c
      if m.abs(rx) < 5.6 and m.abs(rz) < 5.6 then
        terr.hset(t, x, z, PLAZA_H)
      end
    end
  end
  W.terr = t
end

-- terrain height only (no decks): the bake + water classification.
-- Exact-bound clamp: T.sample handles wx==0 and wx==WS precisely, and
-- the apron's edge vertices must land EXACTLY on the mesh edge (a 0.01
-- inset left a hairline shimmer against the border row).
function W.terrain_h(x, z)
  return terr.sample(W.terr, m.clamp(x, 0, N * TILE),
                     m.clamp(z, 0, N * TILE))
end

-- point in a deck slab? (rotated gazebo frame) -> deck top or nil
local function deck_top(x, z)
  local c, s = m.cos(-GROT), m.sin(-GROT)
  local dx, dz = x - GX, z - GZ
  local rx, rz = dx * c - dz * s, dx * s + dz * c
  local top = nil
  for _, d in ipairs(DECKS) do
    if m.abs(rx) <= d.hx and m.abs(rz) <= d.hz then top = d.top end
  end
  return top
end

-- the sim's ground: terrain, or a deck top when standing on the plaza
-- slabs (walkable props — the sprite just steps up)
function W.ground(x, z)
  local h = W.terrain_h(x, z)
  local top = deck_top(x, z)
  if top and top > h then return top end
  return h
end

-- ---- prop scatter (render placement, but casters/blockers are sim) -------

local function xs32(st)
  local s = st[1]
  s = (s ~ (s << 13)) & 0xffffffff
  s = s ~ (s >> 17)
  s = (s ~ (s << 5)) & 0xffffffff
  st[1] = s
  return s
end

local function build_props()
  W.props, W.casters, W.fences, W.blockers = {}, {}, {}, {}
  local st = { 1234 }
  for _ = 1, 250 do
    if #W.props >= 90 then break end
    local x = 2 + (xs32(st) % 600) / 10.0
    local z = 2 + (xs32(st) % 600) / 10.0
    -- every draw BEFORE the accept test (the D3D-022 stream-stability rule)
    local bush = (xs32(st) & 3) ~= 0 -- mostly bushes: lush
    local sc = bush and (0.5 + (xs32(st) % 40) / 100.0)
                    or (1.2 + (xs32(st) % 70) / 100.0)
    local h = W.terrain_h(x, z)
    local ok = h >= -0.1                                -- not in the pond
    if m.abs(x - W.path_x(z)) < 2.6 then ok = false end -- not on the path
    local dx, dz = x - GX, z - GZ
    if dx * dx + dz * dz < 46.0 then ok = false end     -- not on the plaza
    if ok then
      W.props[#W.props + 1] = { x = x, z = z, sc = sc, bush = bush }
      W.casters[#W.casters + 1] = { x = x, z = z, r = bush and 1.2 * sc or 2.6 * sc }
      if not bush then -- tree trunks block the walk grid; bushes are soft
        local r = 0.55 * sc
        W.blockers[#W.blockers + 1] = { x - r, z - r, x + r, z + r }
      end
    end
  end
  W.casters[#W.casters + 1] = { x = GX, z = GZ, r = 4.6 } -- gazebo shade
  -- fence posts along the path's west side (diagonal run)
  for wz = 44, 57.5, 2.5 do
    local wx = W.path_x(wz) - 3.0
    W.fences[#W.fences + 1] = { x = wx, z = wz }
    W.blockers[#W.blockers + 1] = { wx - 0.45, wz - 0.45, wx + 0.45, wz + 0.45 }
  end
  -- gazebo posts (rotated positions)
  local c, s = m.cos(GROT), m.sin(GROT)
  for i = 0, 3 do
    local px = (i % 2 == 1) and 2.1 or -2.1
    local pz = (i >= 2) and 2.1 or -2.1
    local wx = GX + px * c + pz * s
    local wz = GZ - px * s + pz * c
    W.blockers[#W.blockers + 1] = { wx - 0.6, wz - 0.6, wx + 0.6, wz + 0.6 }
  end
  -- spawn: on the path, south stretch
  W.spawn.x, W.spawn.z = W.path_x(50.0), 50.0
end

-- the baked shadow field, sampled on the authentic 8x8-per-tile lightmap
-- lattice (4 texels per world unit at tile 2) — soft but slightly chunky.
-- Also the sprite tint source (0.7 + 0.3*sh at the feet).
function W.shadow(wx, wz)
  wx = floor(wx * 4.0) / 4.0 + 0.125
  wz = floor(wz * 4.0) / 4.0 + 0.125
  local s = 1.0
  for i = 1, #W.casters do
    local cst = W.casters[i]
    local dx, dz = wx - cst.x, wz - cst.z
    local d2, r2 = dx * dx + dz * dz, cst.r * cst.r
    if d2 < r2 then s = s * (1.0 - 0.58 * (1.0 - d2 / r2)) end
  end
  if s < 0.34 then s = 0.34 end
  return s
end

-- ---- the walk grid (GAT scale: 64x64 cells of 1u; A*/snap ride cm.walk) --

local GW = N * 2 -- 64
W.GW = GW
local walk = {} -- walk[i] = true if cell i walkable (i = cz*GW + cx)

local function build_walk()
  walk = {}
  for cz = 0, GW - 1 do
    for cx = 0, GW - 1 do
      local x, z = cx + 0.5, cz + 0.5
      local ok = true
      -- deep water blocks (shallow shorelines wade, the RO read)
      if W.terrain_h(x, z) < W.water_y - 0.55 then ok = false end
      -- steep cells block (corner spread on the walk lattice)
      local h00, h10 = W.ground(cx, cz), W.ground(cx + 1, cz)
      local h01, h11 = W.ground(cx, cz + 1), W.ground(cx + 1, cz + 1)
      local hmin = m.min(h00, m.min(h10, m.min(h01, h11)))
      local hmax = m.max(h00, m.max(h10, m.max(h01, h11)))
      if hmax - hmin > 0.9 then ok = false end
      if ok then
        for i = 1, #W.blockers do
          local b = W.blockers[i]
          if x > b[1] - 0.3 and x < b[3] + 0.3
             and z > b[2] - 0.3 and z < b[4] + 0.3 then
            ok = false
            break
          end
        end
      end
      walk[cz * GW + cx] = ok
    end
  end
end

function W.walkable(cx, cz)
  if cx < 0 or cx >= GW or cz < 0 or cz >= GW then return false end
  return walk[cz * GW + cx]
end

function W.cell(wx, wz) -- world -> cell
  return m.clamp(floor(wx), 0, GW - 1), m.clamp(floor(wz), 0, GW - 1)
end

-- ---- materials + the per-tile bake (render-class) ------------------------

local function ramp(ar, ag, ab, br, bg, bb, v, steps)
  v = m.clamp(v, 0, 1)
  local k = floor(v * (steps - 1) + 0.5) / (steps - 1)
  return ar + (br - ar) * k, ag + (bg - ag) * k, ab + (bb - ab) * k
end

local function fleck(px, pz, k1, k2)
  local s = ((px * k1) ~ (pz * k2)) & 0xffffffff
  s = (s ~ (s << 13)) & 0xffffffff
  s = s ~ (s >> 17)
  s = (s ~ (s << 5)) & 0xffffffff
  return s & 255
end

-- continuous world-space material samples (16 texels per world unit)
local function mat_grass(px, pz)
  local v = 0.6 * vn(901, px, pz, 48) + 0.4 * vn(902, px, pz, 12)
  local r, g, b = ramp(74, 122, 58, 138, 176, 86, v, 5)
  if fleck(px, pz, 73856093, 19349663) > 251 then return 170, 200, 108 end
  return r, g, b
end
local function mat_dirt(px, pz)
  local v = 0.6 * vn(903, px, pz, 32) + 0.4 * vn(904, px, pz, 8)
  local r, g, b = ramp(140, 106, 72, 190, 152, 108, v, 5)
  if fleck(px, pz, 83492791, 29349673) > 250 then return 206, 174, 130 end
  return r, g, b
end
local function mat_sand(px, pz)
  local v = 0.55 * vn(905, px, pz, 24) + 0.45 * vn(906, px, pz, 6)
  return ramp(188, 166, 112, 228, 206, 150, v, 4)
end

-- noisy feathered weights (§8c v5: gradients, not splotches).
-- Returns w_grass, w_dirt, w_sand.
local function weights(wx, wz, h)
  local n = fbm(555, wx * 8, wz * 8, 128, 64, 32) - 0.5
  local n2 = vn(556, wx * 24, wz * 24, 10) - 0.5
  local wn = n * 1.1 + n2 * 0.55
  local sand = sstep01(((0.30 + wn) - h) / 1.0 + 0.5)
  local pd = m.abs(wx - W.path_x(wz))
  local dirt = sstep01(((1.5 + wn * 1.2) - pd) / 1.6 + 0.5)
  -- around the gazebo: circular uneven trampled-dirt blend (the pavement
  -- itself is the crisp deck slab prop, not a bake — §8c v6)
  local gdx, gdz = wx - GX, wz - GZ
  local gd = m.sqrt(gdx * gdx + gdz * gdz)
  local around = sstep01(((6.4 + wn * 1.6) - gd) / 2.0 + 0.5)
  if around > dirt then dirt = around end
  local w1 = dirt
  local w2 = sand * (1 - w1)
  return 1.0 - w1 - w2, w1, w2
end

local char, concat = string.char, table.concat

-- bake ONE tile's 34x34 texels into the atlas buffer (gutter texels reach
-- into the neighbors so 3-point filtering never seams)
local function bake_tile(abuf, tx, tz)
  for py = 0, 33 do
    local row = {}
    for qx = 0, 33 do
      local wx = (tx + (qx - 1 + 0.5) / 32.0) * TILE
      local wz = (tz + (py - 1 + 0.5) / 32.0) * TILE
      local h = W.terrain_h(wx, wz)
      local w0, w1, w2 = weights(wx, wz, h)
      local px, pz = floor(wx * 16), floor(wz * 16)
      local r, g, b = 0, 0, 0
      if w0 > 0.004 then
        local mr, mg, mb = mat_grass(px, pz)
        r, g, b = r + w0 * mr, g + w0 * mg, b + w0 * mb
      end
      if w1 > 0.004 then
        local mr, mg, mb = mat_dirt(px, pz)
        r, g, b = r + w1 * mr, g + w1 * mg, b + w1 * mb
      end
      if w2 > 0.004 then
        local mr, mg, mb = mat_sand(px, pz)
        r, g, b = r + w2 * mr, g + w2 * mg, b + w2 * mb
      end
      local sh = W.shadow(wx, wz)
      if h < W.water_y then -- underwater ground darkens + cools
        sh = sh * 0.80
        b = b * 1.08
      end
      r, g, b = r * sh, g * sh, b * sh
      if r > 255 then r = 255 end
      if g > 255 then g = 255 end
      if b > 255 then b = 255 end
      row[qx + 1] = char(floor(r), floor(g), floor(b), 255)
    end
    abuf:setstr(((tz * 34 + py) * ATLAS + tx * 34) * 4, concat(row))
  end
end

-- bump when the bake math/inputs change: a mismatched stamp rebakes on
-- reload instead of showing a stale atlas
local BAKE_STAMP = 4

W.atlas_tex = nil
local abuf, bakest

-- run K tiles of bake budget; returns done fraction 0..1. Call from draw
-- ONLY (render-class). Uploads the atlas once on completion.
function W.bake(budget)
  local next_t = bakest:u32(0)
  local total = N * N
  if next_t >= total then return 1 end
  local stop = m.min(total, next_t + budget)
  while next_t < stop do
    bake_tile(abuf, next_t % N, next_t // N)
    next_t = next_t + 1
  end
  bakest:u32(0, next_t)
  if next_t >= total then
    pal.tex_update(W.atlas_tex, abuf, ATLAS, ATLAS)
  end
  return next_t / total
end

function W.bake_done()
  return bakest:u32(0) >= N * N
end

function W.rebake() -- console: after editing the bake math live
  bakest:u32(0, 0)
  bakest:u32(4, BAKE_STAMP)
end

-- ---- prop/deck textures (procedural, render-class) -----------------------

local function tx_pave() -- clean pavement aligned to the deck's own axes
  local px = {}
  for py = 0, 63 do
    for qx = 0, 63 do
      local bx, bz = qx % 32, py % 32
      local v = 0.5 * vn(907, qx, py, 16) + 0.25
      local r, g, b = ramp(126, 120, 122, 170, 162, 160, v, 4)
      if bx < 3 or bz < 3 then r, g, b = 94, 90, 94 end
      px[#px + 1] = char(floor(r), floor(g), floor(b), 255)
    end
  end
  return concat(px)
end

local function tx_shingle() -- warm red roof checkers
  local px = {}
  for py = 0, 63 do
    for qx = 0, 63 do
      local k = ((qx // 8) ~ (py // 8)) & 1
      local r, g, b
      if k == 1 then r, g, b = 152, 74, 58 else r, g, b = 118, 52, 44 end
      local v = (vn(88, qx, py, 16) - 0.5) * 0.35
      r = m.clamp(r * (1 + v), 0, 255) // 1
      g = m.clamp(g * (1 + v), 0, 255) // 1
      b = m.clamp(b * (1 + v), 0, 255) // 1
      if qx % 8 == 0 or py % 8 == 0 then
        r, g, b = r * 3 // 4, g * 3 // 4, b * 3 // 4
      end
      px[#px + 1] = char(r, g, b, 255)
    end
  end
  return concat(px)
end

local function tx_ring() -- the click marker: a crisp ring decal
  local px = {}
  for y = 0, 31 do
    for x = 0, 31 do
      local dx, dy = (x - 15.5) / 15.5, (y - 15.5) / 15.5
      local d = m.sqrt(dx * dx + dy * dy)
      local a = 0
      if d > 0.62 and d < 0.95 then
        a = 1 - m.abs(d - 0.785) / 0.165
        a = a * a * (3 - 2 * a)
      end
      px[#px + 1] = char(255, 246, 190, floor(a * 235))
    end
  end
  return concat(px)
end

-- ---- static geometry -> rc.ro.level --------------------------------------

W.tex = nil  -- gb material family (shadow blob)
W.vbuf = nil
W.segs = nil -- opaque segments { tex, count, off, flags }
W.water = nil

local pack = string.pack

-- terrain vertex: white base lit by the corner-smoothed normal (RO's
-- getSmoothNormal), uv into the tile's atlas interior
local function tvert(x, y, z, u, v, nx, ny, nz)
  local d = m.max(0, -(nx * W.sun[1] + ny * W.sun[2] + nz * W.sun[3]))
  local c = m.clamp(W.ambient[1] + d, 0, 1) -- gray light: r=g~=b, keep 3
  local c3 = m.clamp(W.ambient[3] + d, 0, 1)
  return pack("<fffffBBBB", x, y, z, u, v,
              (c * 255) // 1, (c * 255) // 1, (c3 * 255) // 1, 255)
end

local function smooth_nrm(t, vx, vz)
  local xm, xp = m.max(vx - 1, 0), m.min(vx + 1, N)
  local zm, zp = m.max(vz - 1, 0), m.min(vz + 1, N)
  local nx = (terr.hget(t, xm, vz) - terr.hget(t, xp, vz)) / ((xp - xm) * TILE)
  local nz = (terr.hget(t, vx, zm) - terr.hget(t, vx, zp)) / ((zp - zm) * TILE)
  local l = m.sqrt(nx * nx + 1 + nz * nz)
  return nx / l, 1 / l, nz / l
end

local function emit_terrain(out)
  local t = W.terr
  local e0, e1 = 1.0 / 34, 33.0 / 34
  local ntris = 0
  for tz = 0, N - 1 do
    for tx = 0, N - 1 do
      local x0, x1 = tx * TILE, (tx + 1) * TILE
      local z0, z1 = tz * TILE, (tz + 1) * TILE
      local u0, u1 = (tx + e0) / N, (tx + e1) / N
      local v0, v1 = (tz + e0) / N, (tz + e1) / N
      local h00, h10 = terr.hget(t, tx, tz), terr.hget(t, tx + 1, tz)
      local h01, h11 = terr.hget(t, tx, tz + 1), terr.hget(t, tx + 1, tz + 1)
      local ax, ay, az = smooth_nrm(t, tx, tz)
      local bx, by, bz = smooth_nrm(t, tx + 1, tz)
      local cx, cy, cz = smooth_nrm(t, tx + 1, tz + 1)
      local dx, dy, dz = smooth_nrm(t, tx, tz + 1)
      local A = tvert(x0, h00, z0, u0, v0, ax, ay, az)
      local B = tvert(x1, h10, z0, u1, v0, bx, by, bz)
      local C = tvert(x1, h11, z1, u1, v1, cx, cy, cz)
      local D = tvert(x0, h01, z1, u0, v1, dx, dy, dz)
      out[#out + 1] = A .. B .. C .. A .. C .. D -- NW->SE: T.sample agrees
      ntris = ntris + 2
    end
  end
  return ntris
end

local TRUNK_C = { 0.42, 0.30, 0.22 }
local WOOD_C = { 0.36, 0.26, 0.20 }
local FENCE_C = { 0.42, 0.30, 0.22 }

local function emit_props(out)
  local n = 0
  for _, p in ipairs(W.props) do
    local y = W.terrain_h(p.x, p.z)
    local b = m4.translate(p.x, y, p.z)
    if p.bush then
      local g1, g2 = { 0.24, 0.46, 0.24 }, { 0.32, 0.55, 0.28 }
      n = n + gb.ball(out,
        m4.mul(b, m4.mul(m4.translate(0, 0.35 * p.sc, 0), m4.scale(1.4, 0.8, 1.4))),
        0.9 * p.sc, 8, g1, nil, b)
      n = n + gb.ball(out,
        m4.mul(b, m4.mul(m4.translate(0.5 * p.sc, 0.30 * p.sc, 0.3 * p.sc),
                         m4.scale(1.2, 0.7, 1.2))),
        0.6 * p.sc, 7, g2, nil, b)
    else -- round-canopy tree (the ro2 species: trunk + stacked balls)
      local sc = p.sc
      n = n + gb.prism(out, b, 5, 0.20 * sc, 0.16 * sc, 1.3 * sc, TRUNK_C, 0)
      local c1, c2 = { 0.22, 0.44, 0.24 }, { 0.30, 0.53, 0.27 }
      n = n + gb.ball(out,
        m4.mul(b, m4.mul(m4.translate(0, 1.75 * sc, 0), m4.scale(1.25, 1.0, 1.25))),
        0.95 * sc, 9, c1, nil, b)
      n = n + gb.ball(out,
        m4.mul(b, m4.mul(m4.translate(0.35 * sc, 2.25 * sc, 0.2 * sc),
                         m4.scale(1.0, 0.8, 1.0))),
        0.62 * sc, 8, c2, nil, b)
    end
  end
  for _, f in ipairs(W.fences) do
    local y = W.terrain_h(f.x, f.z)
    n = n + gb.prism(out, m4.translate(f.x, y, f.z), 4, 0.16, 0.13, 1.2,
                     FENCE_C, 1)
  end
  return n
end

-- the gazebo: deck slabs (pave texture, own segment), wood posts, rotated
-- pyramid roof (shingle texture, own segment), ball finial
local function emit_gazebo_decks(out)
  local g = m4.mul(m4.translate(GX, PLAZA_H, GZ), m4.roty(GROT))
  local w = { 1, 1, 1 }
  local n = 0
  n = n + gb.gbox(out, g, { 9.4, 0.22, 9.4 }, { 0, 0.11, 0 }, w, 0.35)
  n = n + gb.gbox(out, g, { 5.6, 0.5, 5.6 }, { 0, 0.25, 0 }, w, 0.35)
  return n
end

local function emit_gazebo_wood(out)
  local g = m4.mul(m4.translate(GX, PLAZA_H, GZ), m4.roty(GROT))
  local n = 0
  for i = 0, 3 do
    local px = (i % 2 == 1) and 2.1 or -2.1
    local pz = (i >= 2) and 2.1 or -2.1
    n = n + gb.prism(out, m4.mul(g, m4.translate(px, 0.5, pz)),
                     6, 0.22, 0.18, 2.6, WOOD_C, 0)
  end
  n = n + gb.ball(out, m4.mul(g, m4.translate(0, 5.3, 0)), 0.28, 6, WOOD_C)
  return n
end

-- the border apron: the map edge extended outward in flat rings so the
-- RO camera never sees past the world into sky (fog takes the far edge).
-- NON-OVERLAPPING bands (human playtest 2026-07-17: the first draft's
-- corner strips overlapped coplanar and z-fought — a shimmering diagonal
-- west of the map): N/S bands span the full outer width including the
-- corners, W/E bands cover only 0..WS between them, and EVERY vertex
-- lattice is the same TILE step from the same origin, so ring seams and
-- the mesh edge share vertices exactly (no T-junction cracks).
local APRON_C = { 0.36, 0.48, 0.30 }
local function emit_apron(out)
  local WS = N * TILE
  local R = 34 -- apron reach beyond the edge
  local d = m.max(0, -(0 * W.sun[1] - 1 * W.sun[2] + 0 * W.sun[3]))
  local r = m.clamp(APRON_C[1] * (W.ambient[1] + d), 0, 1)
  local g = m.clamp(APRON_C[2] * (W.ambient[2] + d), 0, 1)
  local b = m.clamp(APRON_C[3] * (W.ambient[3] + d), 0, 1)
  local cr, cg, cb = (r * 255) // 1, (g * 255) // 1, (b * 255) // 1
  local function av(x, z) -- edge-clamped height: seams to the border row
    return pack("<fffffBBBB", x, W.terrain_h(x, z), z, 0, 0, cr, cg, cb, 255)
  end
  local ntris = 0
  local function band(x0, z0, x1, z1) -- quads on the TILE lattice
    for zz = z0, z1 - TILE, TILE do
      for xx = x0, x1 - TILE, TILE do
        out[#out + 1] = av(xx, zz) .. av(xx + TILE, zz)
                     .. av(xx + TILE, zz + TILE)
                     .. av(xx, zz) .. av(xx + TILE, zz + TILE)
                     .. av(xx, zz + TILE)
        ntris = ntris + 2
      end
    end
  end
  band(-R, -R, WS + R, 0)         -- north (with corners)
  band(-R, WS, WS + R, WS + R)    -- south (with corners)
  band(-R, 0, 0, WS)              -- west
  band(WS, 0, WS + R, WS)         -- east
  return ntris
end

local function emit_gazebo_roof(out)
  local g = m4.mul(m4.translate(GX, PLAZA_H, GZ), m4.roty(GROT))
  -- 4-gon corners at 0/90/180/270 — pre-rotate 45 deg so corners land
  -- over the posts (which sit on the diagonals)
  local roof = m4.mul(g, m4.mul(m4.translate(0, 3.1, 0), m4.roty(0.7853982)))
  return gb.prism(out, roof, 4, 3.6, 0.25, 2.0, { 1, 1, 1 }, 0)
end

function W.build()
  build_heights()
  build_props()
  build_walk()
  gb.sun, gb.ambient = W.sun, W.ambient -- props light like the terrain

  -- texture registry: [0]=count then ids (free the old generation on reload)
  local idbuf = pal.buf("rc.ro.texids", 4 * 8)
  local nold = idbuf:u32(0)
  for i = 1, nold do pal.tex_free(idbuf:u32(4 * i)) end
  W.tex = gb.load_textures("rc.ro.gbtex") -- shadow blob rides along
  W.atlas_tex = pal.tex_create(ATLAS, ATLAS, string.rep("\40\60\40\255", ATLAS * ATLAS))
  W.pave_tex = pal.tex_create(64, 64, tx_pave())
  W.shingle_tex = pal.tex_create(64, 64, tx_shingle())
  W.ring_tex = pal.tex_create(32, 32, tx_ring())
  idbuf:u32(0, 4)
  idbuf:u32(4, W.atlas_tex)
  idbuf:u32(8, W.pave_tex)
  idbuf:u32(12, W.shingle_tex)
  idbuf:u32(16, W.ring_tex)

  -- the atlas pixel buffer + bake progress (persist across hot reloads:
  -- a finished bake re-uploads instantly instead of rebaking)
  abuf = pal.buf("rc.ro.atlas", ATLAS * ATLAS * 4)
  bakest = pal.buf("rc.ro.bake", 8)
  if bakest:u32(4) ~= BAKE_STAMP then
    bakest:u32(0, 0)
    bakest:u32(4, BAKE_STAMP)
  elseif W.bake_done() then
    pal.tex_update(W.atlas_tex, abuf, ATLAS, ATLAS)
  end

  local out, sg, off = {}, {}, 0
  local function flush(tex, ntris, flags)
    sg[#sg + 1] = { tex = tex, count = ntris, off = off, flags = flags or 0 }
    off = off + ntris * 72
  end
  flush(W.atlas_tex, emit_terrain(out))
  flush(W.pave_tex, emit_gazebo_decks(out))
  flush(W.shingle_tex, emit_gazebo_roof(out))
  flush(0, emit_props(out) + emit_gazebo_wood(out) + emit_apron(out))
  local nw = terr.emit_water(out, W.terr, W.water_y, WATER_C, 144, 8)
  W.water = { off = off, count = nw }

  local bytes = concat(out)
  local ok, vb = pcall(pal.buf, "rc.ro.level", #bytes)
  if not ok then
    pal.buf_free("rc.ro.level")
    vb = pal.buf("rc.ro.level", #bytes)
  end
  vb:setstr(0, bytes)
  W.vbuf, W.segs = vb, sg
end

return W
