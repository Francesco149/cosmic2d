-- cm.spr — the figure->sprite baker (COSMIC3D.md §11's §5 loop: model a
-- cm.fig figure ONCE, use it as 3D or billboard — zero external art, CC0
-- by construction). Born in projects/rovale (D3D-026/027); promoted
-- engine-side as a §12 distillation slice, human-logged in D3D-026 ("any
-- cartridge, any figure"). D3D-029. Rasterizes any figure through a tiny
-- deterministic Lua rasterizer into an 8-direction x N-row sheet; proto
-- bake_guy_sprite is the reference framing (3/4 camera, transparent
-- target, nearest).
--
-- Sheets are ASSETS (the D3D-027 verdict): S.bake loads the committed
-- <project>/spr/sheet<slot>.spx (RLE, stamped) and only rasterizes +
-- best-effort rewrites on a miss — bake is a button, the result is a
-- file. Everything here is RENDER-CLASS: textures registered in the
-- rc.spr.tex buffer (freed generationally across reloads). The sim never
-- reads sprites — it stores x/z/facing; draw picks a sheet cell from
-- (facing - camera yaw) via S.oct.
--
-- Billboard rules (docs/research-3d/ro-render-recipe.md + D3D-027):
-- quads span camera right x camera up (feet-anchored — full size at any
-- pitch), nearest + alpha-test always, unlit but tinted by the ground
-- shadow at the feet (0.7 + 0.3*sh, the Rebuild env formula).
--
-- Deliberately NOT here (later cuts earn them from real pain): per-sheet
-- cell sizes / bake cameras (every user shares CW/CH/DIRS and the proto
-- framing — varying them needs a per-sheet stamp scheme), paper-doll
-- layers, palette dyes, row specs beyond {keys, t} lists.

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

-- ---- the .spx sheet asset (PERMANENT bake, human verdict 2026-07-17) ----
-- "CSPX" + <I4 stamp> <I4 w> <I4 h> <I4 rows> <I4 fv_micro> + RLE pixels
-- (runs of <I2 count><4B rgba> — sheets are mostly transparent, so this
-- cuts ~80%). Committed in projects/rovale/spr/; boot LOADS instead of
-- rasterizing. A stamp/shape mismatch re-rasterizes and rewrites (the
-- write is best-effort: the suite runs from a read-only store).

local packs, unpacks = string.pack, string.unpack

local function spx_path(slot)
  return cm.main.args.project .. "/spr/sheet" .. slot .. ".spx"
end

local function spx_encode(px, w, h, rows, fv)
  local out = { "CSPX", packs("<I4I4I4I4I4", SPR_STAMP, w, h, rows,
                              floor(fv * 1e6)) }
  local n = #px // 4
  local i = 1
  while i <= n do
    local p = px:sub(i * 4 - 3, i * 4)
    local run = 1
    while run < 65535 and i + run <= n
          and px:sub((i + run) * 4 - 3, (i + run) * 4) == p do
      run = run + 1
    end
    out[#out + 1] = packs("<I2", run) .. p
    i = i + run
  end
  return concat(out)
end

local function spx_decode(bytes, w, h, rows)
  if #bytes < 24 or bytes:sub(1, 4) ~= "CSPX" then return nil end
  local stamp, fw, fh, frows, fvm = unpacks("<I4I4I4I4I4", bytes, 5)
  if stamp ~= SPR_STAMP or fw ~= w or fh ~= h or frows ~= rows then
    return nil
  end
  local out, i = {}, 25
  while i + 5 <= #bytes + 1 do
    local run = unpacks("<I2", bytes, i)
    out[#out + 1] = bytes:sub(i + 2, i + 5):rep(run)
    i = i + 6
  end
  local px = concat(out)
  if #px ~= w * h * 4 then return nil end
  return px, fvm / 1e6
end

-- sheet texture registry (free old generation across reloads); 16 slots
local idbuf
local function reg_tex(slot, id)
  if not idbuf then
    idbuf = pal.buf("rc.spr.tex", 4 * 17)
    local nold = idbuf:u32(0)
    for i = 1, nold do pal.tex_free(idbuf:u32(4 * i)) end
    idbuf:u32(0, 0)
  end
  idbuf:u32(4 * (slot + 1), id)
  if slot + 1 > idbuf:u32(0) then idbuf:u32(0, slot + 1) end
end

-- rasterize one variant's sheet: 8 dirs (cols) x rows ({keys, t} list).
-- Returns pixels (RGBA string), fv (feet row fraction from the cell top).
local function rasterize_sheet(figure, rows)
  local W_ = DIRS * CW
  local mvp = bake_mvp()
  local feet = 0
  local sheet = {} -- one string per sheet pixel row
  for i = 1, #rows * CH do sheet[i] = false end
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
      for py = 0, CH - 1 do
        local row = {}
        for px = 0, CW - 1 do
          local k = py * CW + px + 1
          row[px + 1] = char(floor(cr[k]), floor(cg[k]), floor(cb[k]), ca[k])
          if ca[k] > 0 and py > feet then feet = py end
        end
        local sy = (ri - 1) * CH + py + 1
        sheet[sy] = (sheet[sy] or "") .. concat(row)
      end
    end
  end
  return concat(sheet), (feet + 1) / CH
end

-- public doors for the figure window's bake tab (E5): rasterize any
-- figure to sheet pixels, and encode them as .spx bytes for an
-- arbitrary path (S.bake below stays the slot-file game door)
S.rasterize_sheet = rasterize_sheet
S.spx_encode = spx_encode

-- the sheet for a variant: load the committed .spx asset, or rasterize
-- and (best-effort) write it. force = re-rasterize + rewrite (console).
-- Returns { tex, rows, fv }.
function S.bake(slot, figure, rows, force)
  local W_, H_ = DIRS * CW, #rows * CH
  local px, fv
  if not force then
    local bytes = pal.read_file(spx_path(slot))
    if bytes then px, fv = spx_decode(bytes, W_, H_, #rows) end
  end
  if not px then
    local t0 = os.clock()
    px, fv = rasterize_sheet(figure, rows)
    local wrote = pal.write_file(spx_path(slot), spx_encode(px, W_, H_,
                                                            #rows, fv))
    pal.log(("[spr] rasterized sheet %d: %dx%d, %.2fs%s"):format(
      slot, W_, H_, os.clock() - t0,
      wrote and ", wrote .spx" or " (read-only: not saved)"))
  end
  local tex = pal.tex_create(W_, H_, px)
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

-- billboard quad -> 2 tris (draw with flags 3: alphatest+nearest).
-- FULLY camera-facing (human playtest 2026-07-17: upright quads
-- foreshorten under the pitched RO camera — "they shrink"): the quad
-- spans camera right x camera up, so it never shrinks at any pitch.
-- (x,y,z) = feet on the ground, anchored via the sheet's feet fraction
-- fv; the top tips away from the eye like the classic RO lean-back.
function S.billboard(out, sh, x, y, z, h, col, row, tint, cam_yaw, cam_pitch)
  local w = h * CW / CH
  local sy, cy = m.sin(cam_yaw), m.cos(cam_yaw)
  local sp, cp = m.sin(cam_pitch), m.cos(cam_pitch)
  local rx, rz = cy, -sy            -- camera right on xz
  local ux, uy, uz = -sy * sp, cp, -cy * sp -- camera up
  local hw = w * 0.5
  local a0 = -h * (1 - sh.fv) -- feet -> bottom along up
  local a1 = h * sh.fv        -- feet -> top along up
  local u0, u1 = col / DIRS, (col + 1) / DIRS
  local v0, v1 = row / sh.rows, (row + 1) / sh.rows
  local t = (tint * 255) // 1
  local A = pack("<fffffBBBB", x - rx * hw + ux * a1, y + uy * a1,
                 z - rz * hw + uz * a1, u0, v0, t, t, t, 255)
  local B = pack("<fffffBBBB", x + rx * hw + ux * a1, y + uy * a1,
                 z + rz * hw + uz * a1, u1, v0, t, t, t, 255)
  local C = pack("<fffffBBBB", x + rx * hw + ux * a0, y + uy * a0,
                 z + rz * hw + uz * a0, u1, v1, t, t, t, 255)
  local D = pack("<fffffBBBB", x - rx * hw + ux * a0, y + uy * a0,
                 z - rz * hw + uz * a0, u0, v1, t, t, t, 255)
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
