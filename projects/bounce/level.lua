-- level.lua — the bounce playground: ONE set of shape lists is both the
-- visual scene (gb emitters into bounce.verts at init) and the collider set
-- (player AABB resolve). The primitive vocabulary (STATUS 2026-07-16):
-- BOXES stay the axis-aligned walk surfaces; PRISMS/LATHES/DECO add the
-- money-shot round structure (proto scene_graybox) — colliders stay AABB
-- (prisms: apothem box, corners overhang; rotated deco: world-bounds box,
-- corners slightly fat), only visuals rotate. Layout riffs on the graybox
-- money shot: stair run up to a keep slab, ascending float platforms, an
-- accent goal tower, round tower + dome, hex keep + cone roof.

local m = cm.require("cm.math")
local m4 = cm.require("cm.m4")
local gb = cm.require("gb")

local L = {}

-- graybox atmosphere (proto/main.c scene_graybox)
L.fog = { on = true, s = 28, e = 62, col = { 0.62, 0.70, 0.85 } }
L.sky_top = { 86 / 255, 154 / 255, 232 / 255 }
L.sky_bot = { 171 / 255, 213 / 255, 242 / 255 }

L.spawn = { x = 2, y = 0, z = 18 }

local GX0, GZ0, GX1, GZ1 = -15, -15, 35, 35 -- ground extent

-- { mat, sx, sy, sz, cx, cz, y0 } — box footprint center (cx,cz), base y0
local BOXES = {
  -- stair run (z 16..20), 4 rising steps, the last FLUSH against the keep
  -- face at x=13.5 — never leave a narrower-than-the-player pocket (cw 0.9)
  -- between colliders: un-fittable gaps are squeeze cases by construction
  { "stone", 1.7, 0.55, 4, 7.55, 18, 0 },
  { "stone", 1.7, 1.10, 4, 9.25, 18, 0 },
  { "stone", 1.7, 1.65, 4, 10.95, 18, 0 },
  { "stone", 1.7, 2.20, 4, 12.65, 18, 0 },
  -- the keep slab the stairs feed (walkable roof)
  { "stone", 8, 2.75, 8, 17.5, 18, 0 },
  -- ascending float platforms off the keep roof
  { "metal", 3, 0.6, 3, 17.5, 12.5, 3.4 },
  { "accent", 3, 0.6, 3, 14.5, 8.5, 4.3 },
  { "metal", 3, 0.6, 3, 18.5, 4.5, 5.2 },
  -- the goal tower
  { "accent", 3, 6.4, 3, 23.5, 4.5, 0 },
  -- deco: curtain wall, wood deck
  { "stone", 10, 2.6, 0.9, 0, 26, 0 },
  { "wood", 5, 1.1, 5, -7, 12, 0 },
}

-- { mat, n, r0, r1, h, cx, cz, y0, caps, deco } — vertical n-gon prisms
-- (base at y0). Collider = apothem AABB of the wider radius: facets read
-- flush, corners overhang the collider (visuals may overhang colliders,
-- never the reverse). deco=true skips the collider (roofs ride their
-- tower's box).
local PRISMS = {
  -- round tower + metal dome (LATHES), replacing the old metal pillar box
  { "stone", 12, 2.0, 1.8, 5.5, 30, 8, 0, 1 },
  -- hex keep + wood cone roof, the far-corner landmark
  { "stone", 6, 2.6, 2.3, 4.5, -10, 30, 0, 1 },
  { "wood", 6, 2.9, 0, 2.2, -10, 30, 4.5, 0, true },
  -- octagon pillar (was a metal box; apothem box leaves 1.31u > cw of
  -- clearance to the curtain wall)
  { "stone", 8, 0.8, 0.65, 4.5, -5, 28.5, 0, 1 },
}

-- { mat, prof, n, cx, cz, y0 } — lathe deco, no collider (the dome sits
-- inside its tower's footprint). prof pairs are proto's graybox dome * 0.8.
local LATHES = {
  { "metal", { 2.0, 0, 1.76, 0.8, 1.12, 1.44, 0, 1.76 }, 12, 30, 8, 5.5 },
}

-- { mat, sx, sy, sz, cx, cz, y0, yaw } — y-rotated slabs. Collider = the
-- world-bounds AABB: a touch fat at the corners, never thinner than the
-- visual. Placed clear of the play path (gap rule: > cw where faces oppose).
local DECO = {
  -- accent monoliths ringing the goal tower
  { "accent", 1.2, 2.6, 0.5, 26.9, 1.7, 0, 0.5 },
  { "accent", 1.2, 2.6, 0.5, 19.9, 8.3, 0, 1.2 },
}

L.tex = nil -- material name -> PAL texture id (gb.load_textures)
L.segs = nil -- { {tex,count,off}... } into bounce.verts
L.colliders = nil -- { {x0,y0,z0,x1,y1,z1}... }

-- highest collider top at (x,z) that is at or below y (blob shadow anchor,
-- ledge-aware). The ground plane guarantees a hit.
function L.ground_below(x, z, y)
  local best = 0
  for _, b in ipairs(L.colliders) do
    if x > b[1] and x < b[4] and z > b[3] and z < b[6]
       and b[5] <= y + 0.1 and b[5] > best then
      best = b[5]
    end
  end
  return best
end

function L.build()
  L.tex = gb.load_textures("bounce.texids")

  L.colliders = { { GX0, -1, GZ0, GX1, 0, GZ1 } }
  for _, bx in ipairs(BOXES) do
    local hx, hz = bx[2] / 2, bx[4] / 2
    L.colliders[#L.colliders + 1] =
      { bx[5] - hx, bx[7], bx[6] - hz, bx[5] + hx, bx[7] + bx[3], bx[6] + hz }
  end
  for _, p in ipairs(PRISMS) do
    if not p[10] then
      local a = m.max(p[3], p[4]) * m.cos(m.pi / p[2])
      L.colliders[#L.colliders + 1] =
        { p[6] - a, p[8], p[7] - a, p[6] + a, p[8] + p[5], p[7] + a }
    end
  end
  for _, dc in ipairs(DECO) do
    local c, s = m.abs(m.cos(dc[8])), m.abs(m.sin(dc[8]))
    local hx = (dc[2] * c + dc[4] * s) / 2
    local hz = (dc[2] * s + dc[4] * c) / 2
    L.colliders[#L.colliders + 1] =
      { dc[5] - hx, dc[7], dc[6] - hz, dc[5] + hx, dc[7] + dc[3], dc[6] + hz }
  end

  -- visuals grouped by material = one x_tris segment each
  local white = { 1, 1, 1 }
  local out, segs, off = {}, {}, 0
  local function flush(mat, ntris)
    segs[#segs + 1] = { tex = L.tex[mat], count = ntris, off = off }
    off = off + ntris * 72
  end

  -- ground: 5-unit grass tiles (subdivided so per-vertex fog behaves)
  local n = 0
  for gz = GZ0, GZ1 - 5, 5 do
    for gx = GX0, GX1 - 5, 5 do
      n = n + gb.quad(out, { gx, 0, gz, 0, 0 }, { gx + 5, 0, gz, 2.5, 0 },
                      { gx + 5, 0, gz + 5, 2.5, 2.5 }, { gx, 0, gz + 5, 0, 2.5 },
                      white, 0, 1, 0)
    end
  end
  flush("grass", n)

  for _, mat in ipairs({ "stone", "metal", "accent", "wood" }) do
    n = 0
    for _, bx in ipairs(BOXES) do
      if bx[1] == mat then
        n = n + gb.gbox(out, nil, { bx[2], bx[3], bx[4] },
                        { bx[5], bx[7] + bx[3] / 2, bx[6] }, white, 0.5)
      end
    end
    for _, p in ipairs(PRISMS) do
      if p[1] == mat then
        n = n + gb.prism(out, m4.translate(p[6], p[8], p[7]),
                         p[2], p[3], p[4], p[5], white, p[9])
      end
    end
    for _, lt in ipairs(LATHES) do
      if lt[1] == mat then
        n = n + gb.lathe(out, m4.translate(lt[4], lt[6], lt[5]),
                         lt[2], lt[3], white)
      end
    end
    for _, dc in ipairs(DECO) do
      if dc[1] == mat then
        local xf = m4.mul(m4.translate(dc[5], dc[7] + dc[3] / 2, dc[6]),
                          m4.roty(dc[8]))
        n = n + gb.gbox(out, xf, { dc[2], dc[3], dc[4] }, { 0, 0, 0 },
                        white, 0.5)
      end
    end
    flush(mat, n)
  end

  local bytes = table.concat(out)
  local ok, vbuf = pcall(pal.buf, "bounce.verts", #bytes)
  if not ok then -- level geometry changed size across a hot reload
    pal.buf_free("bounce.verts")
    vbuf = pal.buf("bounce.verts", #bytes)
  end
  vbuf:setstr(0, bytes)
  L.vbuf = vbuf
  L.segs = segs
end

return L
