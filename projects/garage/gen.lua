-- the generator behind garage's committed assets (D155, the rovale
-- bake_atlas precedent — procedural stays a door, the file is the
-- source): art/truck.spr (64x64, 2 livery frames + the "flash" clip;
-- save bakes the 128x64 strip png + .anim + .meta siblings) and
-- art/truck.msh (the stylized truck, every visible face UV-mapped into
-- the 64x64 frame). Console door: `game.gen()` regenerates both; the
-- committed files remain the assets of record and hand edits in the
-- sprite/mesh windows are first-class.

local sprite = cm.require("cm.sprite")
local paint = cm.require("cm.paint")
local mesh = cm.require("cm.mesh")

local M = select(2, ...) or {}

-- ---- the sheet layout (texel edge coords in the 64x64 frame) ----
local BODY = { 0, 0, 32, 20 }
local HOOD = { 32, 0, 64, 20 }
local CAB = { 0, 20, 32, 40 }
local BED = { 32, 20, 64, 40 }
local WHEEL = { 0, 40, 24, 64 }
local GRILLE = { 24, 40, 44, 64 }
local ACC = { 44, 40, 64, 64 }

local function paint_frame(cell, body, shade, stripe)
  local P = paint
  local ink = P.pack(24, 22, 30, 255)
  local tire = P.pack(30, 28, 34, 255)
  local tire2 = P.pack(48, 45, 55, 255)
  local hub = P.pack(198, 198, 208, 255)
  local glass = P.pack(92, 132, 162, 255)
  local glass_hi = P.pack(142, 192, 222, 255)
  local metal = P.pack(152, 152, 162, 255)
  local metal_d = P.pack(92, 92, 102, 255)
  local bed = P.pack(72, 62, 54, 255)
  local bedl = P.pack(98, 86, 72, 255)
  local lamp = P.pack(255, 232, 142, 255)
  -- BODY side
  P.rect(cell, 0, 0, 32, 20, body, true)
  P.rect(cell, 0, 14, 32, 6, shade, true)
  P.rect(cell, 0, 6, 32, 3, stripe, true)
  P.rect(cell, 0, 0, 32, 20, ink, false)
  -- HOOD top (vents)
  P.rect(cell, 32, 0, 32, 20, body, true)
  P.rect(cell, 38, 5, 20, 2, shade, true)
  P.rect(cell, 38, 9, 20, 2, shade, true)
  P.rect(cell, 32, 0, 32, 20, ink, false)
  -- CAB / windshield
  P.rect(cell, 0, 20, 32, 20, body, true)
  P.rect(cell, 3, 23, 26, 14, glass, true)
  P.rect(cell, 5, 25, 10, 4, glass_hi, true)
  P.rect(cell, 0, 20, 32, 20, ink, false)
  -- BED planks
  P.rect(cell, 32, 20, 32, 20, bed, true)
  for k = 0, 3 do P.rect(cell, 33, 22 + k * 5, 30, 2, bedl, true) end
  P.rect(cell, 32, 20, 32, 20, ink, false)
  -- WHEEL tile (opaque: alphatest must never punch holes in the face)
  P.rect(cell, 0, 40, 24, 24, tire, true)
  P.ellipse(cell, 1, 41, 22, 62, tire2, true)
  P.ellipse(cell, 7, 47, 16, 56, hub, true)
  P.rect(cell, 10, 50, 4, 4, metal_d, true)
  -- GRILLE + headlights
  P.rect(cell, 24, 40, 20, 24, metal, true)
  for k = 0, 4 do P.rect(cell, 26, 45 + k * 4, 16, 2, metal_d, true) end
  P.rect(cell, 25, 41, 4, 3, lamp, true)
  P.rect(cell, 39, 41, 4, 3, lamp, true)
  P.rect(cell, 24, 40, 20, 24, ink, false)
  -- ACCENT / tailgate
  P.rect(cell, 44, 40, 20, 24, shade, true)
  P.rect(cell, 46, 46, 16, 10, body, true)
  P.rect(cell, 44, 40, 20, 24, ink, false)
end

local function gen_sprite()
  local sdoc = sprite.new(64, 64, { name = "truck" })
  sprite.add_frame(sdoc) -- frame 2
  local P = paint
  paint_frame(sprite.cell(sdoc, 1, 1),
              P.pack(202, 52, 44, 255), P.pack(150, 30, 26, 255),
              P.pack(246, 240, 228, 255))
  paint_frame(sprite.cell(sdoc, 1, 2),
              P.pack(52, 96, 202, 255), P.pack(30, 62, 150, 255),
              P.pack(246, 240, 228, 255))
  sdoc.clips = { { name = "flash", loop = "loop",
                   frames = { { frame = 0, dur = 3 },
                              { frame = 1, dur = 3 } } } }
  assert(sprite.save(sdoc, cm.main.args.project .. "/art/truck.spr"))
  pal.log("[gen] wrote truck.spr (+ png/anim/meta siblings)")
end

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

local function gen_mesh()
  local doc = { name = "truck", tex = "art/truck.spr", tw = 64, th = 64,
                verts = {}, faces = {} }
  local DK = { 0.10, 0.10, 0.12 }
  -- body / cab / hood (y up, +z = nose)
  local body = boxmm(doc, -0.5, 0.28, -1.1, 0.5, 0.66, 1.1)
  local cab, cbase = boxmm(doc, -0.44, 0.66, -0.55, 0.44, 1.18, 0.42)
  local hood = boxmm(doc, -0.44, 0.66, 0.42, 0.44, 0.88, 1.05)
  -- windshield slant: pull the cab's front-top edge back
  do
    local t = doc.verts
    for _, ci in ipairs({ 7, 8 }) do -- front-top corners
      t[(cbase + ci - 1) * 3 + 3] = 0.18
    end
  end
  -- wheels: stylized cubes; outer face carries the wheel tile
  local wh = {}
  for wi, w in ipairs({ { -0.62, 0.42 }, { 0.42, 0.42 },
                        { -0.62, -0.90 }, { 0.42, -0.90 } }) do
    local f0 = boxmm(doc, w[1], 0.0, w[2], w[1] + 0.2, 0.44, w[2] + 0.48)
    wh[wi] = { f0 = f0, left = w[1] < 0 }
  end
  -- texture assignment
  map_rect(doc, body + 2, BODY)   -- right side
  map_rect(doc, body + 3, BODY)   -- left side
  map_rect(doc, body + 1, GRILLE) -- bumper front
  map_rect(doc, body + 0, ACC)    -- tailgate
  map_rect(doc, body + 4, BED)    -- bed floor
  doc.faces[body + 5].col = DK    -- underside
  map_rect(doc, cab + 2, CAB)     -- side windows ride the cab art
  map_rect(doc, cab + 3, CAB)
  map_rect(doc, cab + 1, CAB)     -- windshield
  map_rect(doc, cab + 0, ACC)     -- rear window panel
  map_rect(doc, cab + 4, HOOD)    -- roof
  doc.faces[cab + 5].col = DK
  map_rect(doc, hood + 4, HOOD)   -- hood top
  map_rect(doc, hood + 1, GRILLE) -- grille + headlights
  map_rect(doc, hood + 2, BODY)
  map_rect(doc, hood + 3, BODY)
  map_rect(doc, hood + 0, BODY)
  doc.faces[hood + 5].col = DK
  for _, w in ipairs(wh) do
    map_rect(doc, w.f0 + (w.left and 3 or 2), WHEEL) -- outer cap
    for _, off in ipairs({ 0, 1, 4, 5, w.left and 2 or 3 }) do
      doc.faces[w.f0 + off].col = DK -- tire rubber
    end
  end
  assert(mesh.save(doc, cm.main.args.project .. "/art/truck.msh"))
  pal.log(("[gen] wrote truck.msh (%d verts, %d faces)"):format(
    #doc.verts // 3, #doc.faces))
end

function M.run()
  gen_sprite()
  gen_mesh()
  cm.asset_epoch = (cm.asset_epoch or 0) + 1
  pal.log("[gen] done")
end

return M
