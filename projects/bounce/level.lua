-- level.lua — the bounce playground: ONE box list is both the visual scene
-- (gb.gbox emission into bounce.verts at init) and the collider set (player
-- AABB resolve). Axis-aligned on purpose — the movement slice starts on the
-- simplest walk surfaces (STATUS 2026-07-16); rotated/prism/lathe structure
-- arrives with the primitive-vocabulary step. Layout riffs on the graybox
-- money shot: stair run up to a keep slab, ascending float platforms, an
-- accent goal tower, scattered deco.

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
  -- deco: curtain wall, wood deck, pillars
  { "stone", 10, 2.6, 0.9, 0, 26, 0 },
  { "wood", 5, 1.1, 5, -7, 12, 0 },
  { "metal", 1.6, 4.5, 1.6, -5, 28, 0 },
  { "metal", 2, 3, 2, 30, 8, 0 },
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
      gb.quad(out, { gx, 0, gz, 0, 0 }, { gx + 5, 0, gz, 2.5, 0 },
              { gx + 5, 0, gz + 5, 2.5, 2.5 }, { gx, 0, gz + 5, 0, 2.5 },
              white, 0, 1, 0)
      n = n + 2
    end
  end
  flush("grass", n)

  for _, mat in ipairs({ "stone", "metal", "accent", "wood" }) do
    n = 0
    for _, bx in ipairs(BOXES) do
      if bx[1] == mat then
        gb.gbox(out, nil, { bx[2], bx[3], bx[4] },
                { bx[5], bx[7] + bx[3] / 2, bx[6] }, white, 0.5)
        n = n + 12
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
