-- spr — the figure->sprite bake goes live (COSMIC3D.md §11, the §5 loop):
-- render a cm.fig figure through a tiny deterministic Lua rasterizer into
-- an 8-direction x N-row sprite sheet at load time — model once, use as 3D
-- (demos 1/2) or billboard (this demo), zero external art, CC0 by
-- construction. proto bake_guy_sprite is the reference framing (3/4 view
-- camera, transparent target, nearest).
--
-- Everything here is RENDER-CLASS: sheets are textures + pixel caches in
-- rc. buffers (a hot reload re-uploads instead of re-rasterizing; a stamp
-- mismatch rebakes). The sim never reads sprites — it stores x/z/facing,
-- and draw picks a sheet cell from (facing - camera yaw).
--
-- Billboard rules (docs/research-3d/ro-render-recipe.md): upright quad
-- Y-faced to the camera, nearest + alpha-test always, unlit but tinted by
-- the ground shadow at the feet (0.7 + 0.3*sh, the Rebuild env formula).

local m = cm.require("cm.math")
local m4 = cm.require("cm.m4")
local fig = cm.require("cm.fig")

local S = select(2, ...) or {}

local CW, CH = 40, 52   -- cell pixels (proto bake_guy_sprite's target)
local DIRS = 8
S.CW, S.CH, S.DIRS = CW, CH, DIRS

-- bump when the bake camera/rasterizer/figure inputs change
local SPR_STAMP = 2

local unpackv = string.unpack
local floor = math.floor
local char, concat = string.char, table.concat

-- the bake camera (proto's, pulled back so the antenna star clears)
local function bake_mvp()
  local view = m4.lookat(0, 3.0, 7.8, 0, 1.15, 0, 0, 1, 0)
  local proj = m4.persp(24, CW / CH, 0.5, 30)
  return m4.mul(proj, view)
end

-- rasterize packed x_tris vertex bytes into the cell arrays (flat Lua
-- arrays indexed py*CW+px+1). Affine color interpolation, z-buffer,
-- both windings (closed figures; the z-buffer sorts).
local function raster(bytes, mvp, zb, cr, cg, cb, ca)
  local n = #bytes // 24
  local sx, sy, sz, sr, sg, sb = {}, {}, {}, {}, {}, {}
  local m1, m2, m3, m4_ = mvp[1], mvp[2], mvp[3], mvp[4]
  local m5, m6, m7, m8 = mvp[5], mvp[6], mvp[7], mvp[8]
  local m9, m10, m11, m12 = mvp[9], mvp[10], mvp[11], mvp[12]
  local m13, m14, m15, m16 = mvp[13], mvp[14], mvp[15], mvp[16]
  for i = 0, n - 1 do
    local x, y, z, _, _, r, g, b = unpackv("<fffffBBBB", bytes, i * 24 + 1)
    local cx = m1 * x + m5 * y + m9 * z + m13
    local cy = m2 * x + m6 * y + m10 * z + m14
    local cz = m3 * x + m7 * y + m11 * z + m15
    local cw = m4_ * x + m8 * y + m12 * z + m16
    if cw < 0.01 then cw = 0.01 end
    sx[i + 1] = (cx / cw * 0.5 + 0.5) * CW
    sy[i + 1] = (0.5 - cy / cw * 0.5) * CH
    sz[i + 1] = cz / cw
    sr[i + 1], sg[i + 1], sb[i + 1] = r, g, b
  end
  for t = 0, n // 3 - 1 do
    local i1, i2, i3 = t * 3 + 1, t * 3 + 2, t * 3 + 3
    local x1, y1, x2, y2, x3, y3 = sx[i1], sy[i1], sx[i2], sy[i2], sx[i3], sy[i3]
    local area = (x2 - x1) * (y3 - y1) - (x3 - x1) * (y2 - y1)
    if area < 0 then -- flip so edge tests are uniform
      i2, i3 = i3, i2
      x2, y2, x3, y3 = x3, y3, x2, y2
      area = -area
    end
    if area > 1e-6 then
      local lox = floor(m.max(0, m.min(x1, m.min(x2, x3))))
      local hix = floor(m.min(CW - 1, m.max(x1, m.max(x2, x3))))
      local loy = floor(m.max(0, m.min(y1, m.min(y2, y3))))
      local hiy = floor(m.min(CH - 1, m.max(y1, m.max(y2, y3))))
      local z1, z2, z3 = sz[i1], sz[i2], sz[i3]
      local r1, r2, r3 = sr[i1], sr[i2], sr[i3]
      local g1, g2, g3 = sg[i1], sg[i2], sg[i3]
      local b1, b2, b3 = sb[i1], sb[i2], sb[i3]
      for py = loy, hiy do
        local yy = py + 0.5
        for px = lox, hix do
          local xx = px + 0.5
          local w1 = (x2 - xx) * (y3 - yy) - (x3 - xx) * (y2 - yy)
          local w2 = (x3 - xx) * (y1 - yy) - (x1 - xx) * (y3 - yy)
          local w3 = (x1 - xx) * (y2 - yy) - (x2 - xx) * (y1 - yy)
          if w1 >= 0 and w2 >= 0 and w3 >= 0 then
            local k = py * CW + px + 1
            local z = (w1 * z1 + w2 * z2 + w3 * z3) / area
            if z < zb[k] then
              zb[k] = z
              cr[k] = (w1 * r1 + w2 * r2 + w3 * r3) / area
              cg[k] = (w1 * g1 + w2 * g2 + w3 * g3) / area
              cb[k] = (w1 * b1 + w2 * b2 + w3 * b3) / area
              ca[k] = 255
            end
          end
        end
      end
    end
  end
end

local meta_buf -- rc.ro.sprmeta: [0]stamp, per-variant [4+8i]fv_micro [8+8i]done

local function meta()
  if not meta_buf then
    meta_buf = pal.buf("rc.ro.sprmeta", 4 + 8 * 8)
    if meta_buf:u32(0) ~= SPR_STAMP then
      meta_buf:u32(0, SPR_STAMP)
      for i = 0, 7 do meta_buf:u32(8 + 8 * i, 0) end -- all dirty
    end
  end
  return meta_buf
end

-- sheet texture registry (free old generation across reloads)
local idbuf
local function reg_tex(slot, id)
  if not idbuf then
    idbuf = pal.buf("rc.ro.sprtex", 4 * 9)
    local nold = idbuf:u32(0)
    for i = 1, nold do pal.tex_free(idbuf:u32(4 * i)) end
    idbuf:u32(0, 0)
  end
  idbuf:u32(4 * (slot + 1), id)
  if slot + 1 > idbuf:u32(0) then idbuf:u32(0, slot + 1) end
end

-- bake one variant's sheet: 8 dirs (cols) x rows (list of {keys, t}).
-- slot = fixed variant index (cache identity). Returns
-- { tex, rows, fv } — fv = feet row fraction from the cell top.
function S.bake(slot, figure, rows)
  local mb = meta()
  local W_, H_ = DIRS * CW, #rows * CH
  local ok, pxbuf = pcall(pal.buf, "rc.ro.spx" .. slot, W_ * H_ * 4)
  if not ok then -- row count changed across a reload
    pal.buf_free("rc.ro.spx" .. slot)
    pxbuf = pal.buf("rc.ro.spx" .. slot, W_ * H_ * 4)
    mb:u32(8 + 8 * slot, 0)
  end
  local fv
  if mb:u32(8 + 8 * slot) == 1 then -- cached: pixels survive hot reloads
    fv = mb:u32(4 + 8 * slot) / 1e6
  else
    local t0 = os.clock()
    local mvp = bake_mvp()
    local feet = 0
    for ri, spec in ipairs(rows) do
      local pose = fig.cycle(spec[1], spec[2])
      for d = 0, DIRS - 1 do
        local zb, cr, cg, cb, ca = {}, {}, {}, {}, {}
        for k = 1, CW * CH do
          zb[k] = 1e18
          ca[k] = 0
          cr[k], cg[k], cb[k] = 0, 0, 0
        end
        local out = {}
        fig.emit(out, figure, m4.roty(d * (m.pi / 4)), pose)
        raster(concat(out), mvp, zb, cr, cg, cb, ca)
        -- write the cell into the sheet buffer row by row
        for py = 0, CH - 1 do
          local row = {}
          for px = 0, CW - 1 do
            local k = py * CW + px + 1
            row[px + 1] = char(floor(cr[k]), floor(cg[k]), floor(cb[k]), ca[k])
            if ca[k] > 0 and py > feet then feet = py end
          end
          pxbuf:setstr((((ri - 1) * CH + py) * W_ + d * CW) * 4, concat(row))
        end
      end
    end
    fv = (feet + 1) / CH
    mb:u32(4 + 8 * slot, floor(fv * 1e6))
    mb:u32(8 + 8 * slot, 1)
    pal.log(("[spr] baked sheet %d: %dx%d, %.2fs"):format(
      slot, W_, H_, os.clock() - t0))
  end
  local tex = pal.tex_create(W_, H_, string.rep("\0", W_ * H_ * 4))
  pal.tex_update(tex, pxbuf, W_, H_)
  reg_tex(slot, tex)
  return { tex = tex, rows = #rows, fv = fv }
end

-- sheet column for a world facing angle seen from camera yaw (both rad):
-- baked col b shows the figure at yaw b*45 deg from a camera at +z
function S.oct(face_ang, cam_yaw)
  local rel = (face_ang - cam_yaw) / (m.pi / 4)
  return floor(rel + 0.5) % 8
end

local pack = string.pack

-- upright billboard quad -> 2 tris (draw with flags 3: alphatest+nearest).
-- (x,y,z) = feet on the ground; h = cell height in world units (the feet
-- fraction fv anchors the sheet so baked feet land on y). tint 0..1.
function S.billboard(out, sh, x, y, z, h, col, row, tint, cam_yaw)
  local w = h * CW / CH
  local rx, rz = m.cos(cam_yaw), -m.sin(cam_yaw) -- camera right on xz
  local hw = w * 0.5
  local top = y + h * sh.fv
  local bot = top - h
  local u0, u1 = col / DIRS, (col + 1) / DIRS
  local v0, v1 = row / sh.rows, (row + 1) / sh.rows
  local t = (tint * 255) // 1
  local blx, blz = x - rx * hw, z - rz * hw
  local brx, brz = x + rx * hw, z + rz * hw
  local A = pack("<fffffBBBB", blx, top, blz, u0, v0, t, t, t, 255)
  local B = pack("<fffffBBBB", brx, top, brz, u1, v0, t, t, t, 255)
  local C = pack("<fffffBBBB", brx, bot, brz, u1, v1, t, t, t, 255)
  local D = pack("<fffffBBBB", blx, bot, blz, u0, v1, t, t, t, 255)
  out[#out + 1] = A .. B .. C .. A .. C .. D
  return 2
end

-- flat decal quad on the ground (blob shadow / click ring) -> 2 tris
-- (draw with flags 4: blend, no depth write)
function S.decal(out, x, y, z, r, rr, gg, bb, aa)
  local A = pack("<fffffBBBB", x - r, y, z - r, 0, 0, rr, gg, bb, aa)
  local B = pack("<fffffBBBB", x + r, y, z - r, 1, 0, rr, gg, bb, aa)
  local C = pack("<fffffBBBB", x + r, y, z + r, 1, 1, rr, gg, bb, aa)
  local D = pack("<fffffBBBB", x - r, y, z + r, 0, 1, rr, gg, bb, aa)
  out[#out + 1] = A .. B .. C .. A .. C .. D
  return 2
end

return S
