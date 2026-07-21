-- the generator behind waterwall's committed assets (the garage
-- precedent — procedural stays a door, the file is the source):
-- art/rock.spr (64x64, one frame: a 2x2 sheet of 32x32 stone tiles —
-- two dry variants on top, their WET twins below: same stones off the
-- same noise seed, darker + blue with sparse sheen specks),
-- art/water.spr (64x64, 8 frames + the "flow" clip: one y-periodic
-- streak pattern, frame i scrolled down i*8px — playing the strip IS
-- the flow), art/wall.msh (5x3 stone blocks, front faces UV-mapped
-- onto the rock tiles, the center column recessed + wet) and
-- art/water.msh (the unlit overlay: fall sheet, side trickle, foam
-- pool — each a hair proud of the surface it wets). Console door:
-- `game.gen()` regenerates all four; the committed files remain the
-- assets of record and hand edits in the sprite/mesh windows are
-- first-class.

local sprite = cm.require("cm.sprite")
local paint = cm.require("cm.paint")
local mesh = cm.require("cm.mesh")

local M = select(2, ...) or {}

-- deterministic integer hash -> 0..1 (paint's phash recipe; local there)
local function h01(seed, ix, iy)
  local s = (seed ~ (ix * 374761393) ~ (iy * 668265263)) & 0xffffffff
  s = (s ~ (s << 13)) & 0xffffffff
  s = s ~ (s >> 17)
  s = (s ~ (s << 5)) & 0xffffffff
  return (s & 0xffff) / 65535.0
end

-- ---- rock.spr: the 2x2 stone sheet ----

local T_DRY_A = { 0, 0, 32, 32 }
local T_DRY_B = { 32, 0, 64, 32 }
local T_WET_A = { 0, 32, 32, 64 }
local T_WET_B = { 32, 32, 64, 64 }

local DRY = { { 52, 50, 56 }, { 78, 76, 80 },
              { 102, 100, 106 }, { 126, 124, 130 } }
local WET = { { 24, 30, 42 }, { 36, 46, 60 },
              { 50, 64, 80 }, { 66, 84, 100 } }

local function paint_stone_tile(cell, tx, ty, seed, wet)
  local P = paint
  local mortar = wet and P.pack(14, 18, 28, 255) or P.pack(30, 29, 34, 255)
  local sheen = P.pack(150, 196, 218, 255)
  local ramp = wet and WET or DRY
  for y = 0, 31 do
    for x = 0, 31 do
      local row = y // 8
      local off = (row % 2) * 8
      local px
      if y % 8 == 0 or (x + off) % 16 == 0 then
        px = mortar
      else
        local bx = (x + off) // 16
        local t = P.proc_t({ type = "fbm", seed = seed, scale = 5,
                             oct = 3 }, x, y)
        t = t + h01(seed + 31, bx, row) * 0.3 - 0.15
        local i = 1 + ((t * 4) // 1)
        if i < 1 then i = 1 elseif i > 4 then i = 4 end
        local c = ramp[i]
        px = P.pack(c[1], c[2], c[3], 255)
        if wet and h01(seed + 9, tx + x, ty + y) > 0.965 then
          px = sheen -- the sparse specular glints that read "wet"
        end
      end
      P.set(cell, tx + x, ty + y, px)
    end
  end
end

local function gen_rock()
  local sdoc = sprite.new(64, 64, { name = "rock" })
  local cell = sprite.cell(sdoc, 1, 1)
  paint_stone_tile(cell, 0, 0, 11, false)
  paint_stone_tile(cell, 32, 0, 23, false)
  paint_stone_tile(cell, 0, 32, 11, true) -- the wet twins: same seeds,
  paint_stone_tile(cell, 32, 32, 23, true) -- same stones, darker
  assert(sprite.save(sdoc, cm.main.args.project .. "/art/rock.spr"))
  pal.log("[gen] wrote rock.spr (+ png/meta siblings)")
end

-- ---- water.spr: the scrolling streak strip ----

local NFR = 8

-- value noise with the y lattice wrapped, so the pattern tiles at
-- period*cell px vertically — the scroll can loop seamlessly
local function wnoise(seed, x, y, period)
  local gx, gy = x // 1, y // 1
  local fx, fy = x - gx, y - gy
  local function at(ix, iy) return h01(seed, ix, iy % period) end
  local a, b = at(gx, gy), at(gx + 1, gy)
  local c, d = at(gx, gy + 1), at(gx + 1, gy + 1)
  local u = fx * fx * (3 - 2 * fx)
  local v = fy * fy * (3 - 2 * fy)
  return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
end

-- the base pattern (y-periodic at 64): tall cells stretch the noise
-- into vertical streaks; a pure column term groups them into runnels
local function wbase(x, y)
  local t = 0.65 * wnoise(7, x / 8, y / 16, 4)
          + 0.35 * wnoise(77, x / 4, y / 8, 8)
  local c = wnoise(13, x / 9, 0.5, 1)
  t = t * (0.72 + 0.56 * c)
  local ex = x < 63 - x and x or 63 - x
  if ex < 6 then t = t - (6 - ex) * 0.05 end -- ragged sheet edges
  return t
end

local function gen_water()
  local sdoc = sprite.new(64, 64, { name = "water" })
  for _ = 2, NFR do sprite.add_frame(sdoc) end
  local P = paint
  local A = P.pack(110, 160, 205, 100)
  local B = P.pack(150, 200, 232, 150)
  local FOAM = P.pack(224, 244, 252, 205)
  for i = 0, NFR - 1 do
    local cell = sprite.cell(sdoc, 1, i + 1)
    for y = 0, 63 do
      for x = 0, 63 do
        local t = wbase(x, (y - i * 8) % 64)
        if t >= 0.47 then
          local px = t < 0.66 and A or t < 0.80 and B or FOAM
          P.set(cell, x, y, px)
        end
      end
    end
  end
  local fr = {}
  for i = 0, NFR - 1 do fr[i + 1] = { frame = i, dur = 3 } end
  sdoc.clips = { { name = "flow", loop = "loop", frames = fr } }
  assert(sprite.save(sdoc, cm.main.args.project .. "/art/water.spr"))
  pal.log("[gen] wrote water.spr (+ png/anim/meta siblings)")
end

-- ---- the meshes ----

-- axis-aligned box, add_prim's winding (outward normals); returns the
-- first face index: +0 back z- / +1 front z+ / +2 right x+ / +3 left x-
-- / +4 top y+ / +5 bottom y-
local function boxmm(doc, x0, y0, z0, x1, y1, z1)
  local base = #doc.verts // 3
  local function V(x, y, z)
    local t = doc.verts
    t[#t + 1], t[#t + 2], t[#t + 3] = x, y, z
  end
  V(x0, y0, z0) V(x1, y0, z0) V(x1, y1, z0) V(x0, y1, z0)
  V(x0, y0, z1) V(x1, y0, z1) V(x1, y1, z1) V(x0, y1, z1)
  local f0 = #doc.faces + 1
  local function F(a, b, c, d)
    doc.faces[#doc.faces + 1] = { v = { base + a, base + b, base + c,
                                        base + d },
                                  col = { 0.5, 0.5, 0.5 } }
  end
  F(1, 4, 3, 2) F(5, 6, 7, 8) F(2, 3, 7, 6) F(1, 5, 8, 4)
  F(4, 8, 7, 3) F(1, 2, 6, 5)
  return f0, base
end

-- planar-project face fi and stretch it onto sheet region r (1-texel
-- inset guards bleed from the neighboring region)
local function map_rect(doc, fi, r)
  local plan = mesh.plan_uv(doc, fi)
  local mnu, mxu, mnv, mxv = 1e30, -1e30, 1e30, -1e30
  for k = 1, #plan // 2 do
    local u, v = plan[k * 2 - 1], plan[k * 2]
    if u < mnu then mnu = u end
    if u > mxu then mxu = u end
    if v < mnv then mnv = v end
    if v > mxv then mxv = v end
  end
  local x0, y0, x1, y1 = r[1] + 1, r[2] + 1, r[3] - 1, r[4] - 1
  local du = math.max(mxu - mnu, 1e-9)
  local dv = math.max(mxv - mnv, 1e-9)
  local f = doc.faces[fi]
  f.uv = {}
  for k = 1, #plan // 2 do
    local u = (plan[k * 2 - 1] - mnu) / du
    local v = (plan[k * 2] - mnv) / dv
    f.uv[k * 2 - 1] = math.floor(x0 + u * (x1 - x0) + 0.5)
    f.uv[k * 2] = math.floor(y0 + v * (y1 - y0) + 0.5)
  end
  f.chk = nil
end

local PITCH, BW, PITCHY, BH = 0.82, 0.80, 0.64, 0.62

local function gen_wall()
  local doc = { name = "wall", tex = "art/rock.spr", tw = 64, th = 64,
                verts = {}, faces = {} }
  local GREY = { 0.30, 0.30, 0.33 }
  local DK = { 0.10, 0.10, 0.13 }
  for row = 0, 2 do
    for col = -2, 2 do
      local wet = col == 0
      local x0 = col * PITCH - BW / 2
      local y0 = row * PITCHY + 0.01
      -- the wet channel sits recessed and even; dry blocks jitter
      local front = wet and -0.045
                    or -(0.02 + 0.10 * h01(41, col, row))
      local f0 = boxmm(doc, x0, y0, -0.34, x0 + BW, y0 + BH, front)
      local v = h01(51, col, row)
      local tile = wet and (v < 0.5 and T_WET_A or T_WET_B)
                   or (v < 0.5 and T_DRY_A or T_DRY_B)
      map_rect(doc, f0 + 1, tile)
      doc.faces[f0 + 0].col = DK
      doc.faces[f0 + 2].col = GREY
      doc.faces[f0 + 3].col = GREY
      doc.faces[f0 + 4].col = DK
      doc.faces[f0 + 5].col = DK
    end
  end
  assert(mesh.save(doc, cm.main.args.project .. "/art/wall.msh"))
  pal.log(("[gen] wrote wall.msh (%d verts, %d faces)"):format(
    #doc.verts // 3, #doc.faces))
end

local WATERCOL = { 0.55, 0.75, 0.90 } -- the texture-blind flat fallback

local function gen_water_mesh()
  local doc = { name = "water", tex = "art/water.spr", tw = 64, th = 64,
                verts = {}, faces = {} }
  local function V(x, y, z)
    local t = doc.verts
    t[#t + 1], t[#t + 2], t[#t + 3] = x, y, z
  end
  local function face(vs, uv)
    doc.faces[#doc.faces + 1] = { v = vs, uv = uv, unlit = true,
                                  col = WATERCOL }
  end
  -- vertical sheet facing +z: bl br tr tl; image v grows downward
  local function sheet(x0, y0, x1, y1, z, u0, v0, u1, v1)
    local b = #doc.verts // 3
    V(x0, y0, z) V(x1, y0, z) V(x1, y1, z) V(x0, y1, z)
    face({ b + 1, b + 2, b + 3, b + 4 },
         { u0, v1, u1, v1, u1, v0, u0, v0 })
  end
  sheet(-0.38, 0.00, 0.38, 1.90, 0.045, 1, 1, 63, 63) -- the fall
  sheet(0.98, 0.50, 1.16, 1.90, 0.038, 24, 2, 40, 62) -- the trickle
  -- foam pool: horizontal, facing +y; flow runs off the wall (+z)
  do
    local x0, x1, y, z0, z1 = -0.55, 0.55, 0.015, 0.05, 0.60
    local b = #doc.verts // 3
    V(x0, y, z1) V(x1, y, z1) V(x1, y, z0) V(x0, y, z0)
    face({ b + 1, b + 2, b + 3, b + 4 },
         { 2, 62, 62, 62, 62, 34, 2, 34 })
  end
  assert(mesh.save(doc, cm.main.args.project .. "/art/water.msh"))
  pal.log(("[gen] wrote water.msh (%d verts, %d faces)"):format(
    #doc.verts // 3, #doc.faces))
end

function M.run()
  gen_rock()
  gen_water()
  gen_wall()
  gen_water_mesh()
  cm.asset_epoch = (cm.asset_epoch or 0) + 1
  pal.log("[gen] done")
end

return M
