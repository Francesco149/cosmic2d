-- cm.mesh — the .msh asset (EDITOR3D.md §5, D137, textured per D155):
-- one low-poly mesh — verts + tri/quad faces with flat per-face colors,
-- optional per-face texture regions from ONE image (the picoCAD model:
-- MANUAL planar per-face UVs), or a stock colored checkerboard per face
-- (the pre-texture default). The refusal set stated up front: NO
-- skinning, NO modifiers, NO subdivision, NO n-gons beyond quads, NO
-- automatic UV unwrap — ever. Sufficient for era props and figure part
-- meshes; the wall against Blender creep.
--
--   HEAD v1: <s4 name> <s4 tex path ("" = untextured)> <I4 flags (0)>
--   HEAD v2: v1 + <I2 tw> <I2 th> — the UV reference FRAME size in
--            texels (the bound .spr's canvas; a baked strip holds
--            png_w // tw frames). v2 is written only when tw/th differ
--            from the 64x64 default, so pre-D155 docs stay
--            byte-canonical.
--   VERT v1: <I4 n> n * <fff x y z>
--   FACE v1: one per face, file order = draw order:
--            <I1 nv 3|4> nv * <I2 vert idx 0-based>
--            <BBB col> <I1 flags bit0 doublesided, bit1 unlit,
--            bit2 textured, bit3 checker (D155)>
--            [checker: <I1 idx 1..7>] [textured: nv * <HH u v texels>]
--            bit2 and bit3 are mutually exclusive (encode refuses).
--   TAIL v1: empty
--
-- Codec is pure and canonical (encode(decode(b)) == b), cm.chunk gives
-- skip-tolerance. Rendering rides cm.gb's baked path: faces group by
-- (texture source, color) into gb-shaped bakes (flat normal slots;
-- unlit faces get the zero-normal slot — the water rule), so placed
-- props and figure part meshes take the pal.x_figverts C fast path for
-- free and the Lua reference loop stays byte-identical (the three-path
-- gb guarantee). Textured faces light a WHITE base (texel x lighting);
-- the legacy single-buffer emit() keeps flat face colors so untextured
-- consumers (figure part meshes) are untouched — texture-aware callers
-- draw emit_segments() with per-group texture ids.
--
-- Texture ANIMATION reuses the sprite animation slots (D155): the .spr
-- bakes a horizontal frame strip; bake_groups{frame=n} maps the SAME
-- texel UVs into frame n's strip window — swap or animate textures by
-- rebaking groups per frame (cheap: O(faces)), never by touching UVs.
--
-- Editing ops (extrude / primitives / flips / welds / plan_uv) live
-- here as pure doc functions so the mesh window stays gesture plumbing
-- and the KATs drive the geometry headless.

local m = cm.require("cm.math")
local chunk = cm.require("cm.chunk")
local gb = cm.require("cm.gb")

local M = select(2, ...) or {}

local pack, unpack = string.pack, string.unpack
local MAGIC = "CMSH"

-- ---- construction --------------------------------------------------------

local DEFCOL = { 0.62, 0.60, 0.66 }

function M.fresh(name)
  local doc = { name = name or "", tex = "", verts = {}, faces = {} }
  M.add_prim(doc, "box", { size = 1 })
  return doc
end

-- ---- stock checkerboards (render-class; the pre-texture default) ---------

-- the 7 stock checker base colors (the dark check is 0.55x); indices are
-- the on-disk f.chk values — append-only, never reorder (saved meshes
-- point into this table)
M.CHK_COLS = {
  { 0.78, 0.78, 0.82 }, -- gray
  { 0.85, 0.35, 0.30 }, -- red
  { 0.88, 0.62, 0.25 }, -- orange
  { 0.84, 0.80, 0.32 }, -- yellow
  { 0.38, 0.68, 0.34 }, -- green
  { 0.34, 0.55, 0.80 }, -- blue
  { 0.66, 0.42, 0.76 }, -- purple
}

M.CHKW = 16 -- checker tile texels (4px checks; UVs tile per world unit)

-- lazily (re)create the 7 checker textures; ids persist in the rc.mesh.chk
-- named buffer so hot reloads / VM reboots free the previous generation
-- first (the rc.spr.tex pattern). Render-class only.
local chkids
function M.checker_tex(idx)
  if not chkids then
    local idbuf = pal.buf("rc.mesh.chk", 4 * (#M.CHK_COLS + 1))
    local nold = idbuf:u32(0)
    for i = 1, nold do pal.tex_free(idbuf:u32(4 * i)) end
    chkids = {}
    for k, c in ipairs(M.CHK_COLS) do
      local px = {}
      for y = 0, M.CHKW - 1 do
        for x = 0, M.CHKW - 1 do
          local mul = (((x // 4) ~ (y // 4)) & 1) == 0 and 1 or 0.55
          px[#px + 1] = string.char((c[1] * mul * 255) // 1,
                                    (c[2] * mul * 255) // 1,
                                    (c[3] * mul * 255) // 1, 255)
        end
      end
      chkids[k] = pal.tex_create(M.CHKW, M.CHKW, table.concat(px))
      idbuf:u32(4 * k, chkids[k])
    end
    idbuf:u32(0, #M.CHK_COLS)
  end
  return chkids[idx]
end

-- ---- codec ---------------------------------------------------------------

function M.encode(doc)
  local w = chunk.writer(MAGIC)
  local tw, th = doc.tw or 64, doc.th or 64
  if tw ~= 64 or th ~= 64 then
    w.chunk("HEAD", 2, pack("<s4s4I4I2I2", doc.name or "", doc.tex or "",
                            0, tw, th))
  else
    w.chunk("HEAD", 1, pack("<s4s4I4", doc.name or "", doc.tex or "", 0))
  end
  local nv = #doc.verts // 3
  local vp = { pack("<I4", nv) }
  for i = 1, nv * 3 do vp[#vp + 1] = pack("<f", doc.verts[i]) end
  w.chunk("VERT", 1, table.concat(vp))
  for _, f in ipairs(doc.faces) do
    local n = #f.v
    if n < 3 or n > 4 then error("mesh: face needs 3 or 4 verts", 0) end
    if f.uv and f.chk then
      error("mesh: face cannot be both image-textured and checker", 0)
    end
    if f.chk and (f.chk < 1 or f.chk > #M.CHK_COLS) then
      error("mesh: checker index out of range", 0)
    end
    local parts = { pack("<I1", n) }
    for _, vi in ipairs(f.v) do
      if vi < 1 or vi > nv then error("mesh: face vert out of range", 0) end
      parts[#parts + 1] = pack("<I2", vi - 1)
    end
    local col = f.col or DEFCOL
    local flags = (f.ds and 1 or 0) | (f.unlit and 2 or 0)
                | (f.uv and 4 or 0) | (f.chk and 8 or 0)
    parts[#parts + 1] = pack("<BBBI1", (col[1] * 255) // 1,
                             (col[2] * 255) // 1, (col[3] * 255) // 1, flags)
    if f.chk then parts[#parts + 1] = pack("<I1", f.chk) end
    if f.uv then
      for k = 1, n * 2 do parts[#parts + 1] = pack("<I2", f.uv[k]) end
    end
    w.chunk("FACE", 1, table.concat(parts))
  end
  w.chunk("TAIL", 1, "")
  return w.result()
end

function M.decode(bytes)
  local doc = { verts = {}, faces = {} }
  local seen_head, seen_tail
  for _, c in ipairs(chunk.read(bytes, MAGIC)) do
    if c.tag == "HEAD" and c.version == 1 then
      doc.name, doc.tex = unpack("<s4s4", c.payload)
      seen_head = true
    elseif c.tag == "HEAD" and c.version == 2 then
      local name, tex, _, tw, th = unpack("<s4s4I4I2I2", c.payload)
      doc.name, doc.tex = name, tex
      -- 64 is the default; storing only differences keeps encode
      -- canonical over everything encode itself produces
      if tw ~= 64 then doc.tw = tw end
      if th ~= 64 then doc.th = th end
      seen_head = true
    elseif c.tag == "VERT" and c.version == 1 then
      local n, pos = unpack("<I4", c.payload, 1)
      for i = 1, n * 3 do
        doc.verts[i], pos = unpack("<f", c.payload, pos)
      end
    elseif c.tag == "FACE" and c.version == 1 then
      local f, pos = { v = {} }, 1
      local n
      n, pos = unpack("<I1", c.payload, pos)
      for k = 1, n do
        local vi
        vi, pos = unpack("<I2", c.payload, pos)
        f.v[k] = vi + 1
      end
      local r, g, b, flags
      r, g, b, flags, pos = unpack("<BBBI1", c.payload, pos)
      f.col = { r / 255, g / 255, b / 255 }
      f.ds = flags & 1 ~= 0 or nil
      f.unlit = flags & 2 ~= 0 or nil
      if flags & 8 ~= 0 then
        f.chk, pos = unpack("<I1", c.payload, pos)
        if f.chk < 1 or f.chk > #M.CHK_COLS then
          error("mesh: checker index out of range", 0)
        end
      end
      if flags & 4 ~= 0 then
        if f.chk then
          error("mesh: face cannot be both image-textured and checker", 0)
        end
        f.uv = {}
        for k = 1, n * 2 do f.uv[k], pos = unpack("<I2", c.payload, pos) end
      end
      doc.faces[#doc.faces + 1] = f
    elseif c.tag == "TAIL" then
      seen_tail = true
    end
  end
  if not seen_head then error("mesh: missing HEAD", 0) end
  if not seen_tail then error("mesh: missing TAIL (truncated?)", 0) end
  local nv = #doc.verts // 3
  for _, f in ipairs(doc.faces) do
    for _, vi in ipairs(f.v) do
      if vi < 1 or vi > nv then error("mesh: face vert out of range", 0) end
    end
  end
  return doc
end

function M.save(doc, path, fail)
  local ok, err = pal.write_file_atomic(path, M.encode(doc), fail)
  if not ok then return nil, "write mesh failed: " .. tostring(err) end
  return true
end

-- ---- readers -------------------------------------------------------------

function M.bounds(doc)
  local nv = #doc.verts // 3
  if nv == 0 then return { 0, 0, 0, 0, 0, 0 } end
  local b = { 1e30, 1e30, 1e30, -1e30, -1e30, -1e30 }
  for i = 0, nv - 1 do
    local x, y, z = doc.verts[i * 3 + 1], doc.verts[i * 3 + 2],
                    doc.verts[i * 3 + 3]
    b[1], b[4] = m.min(b[1], x), m.max(b[4], x)
    b[2], b[5] = m.min(b[2], y), m.max(b[5], y)
    b[3], b[6] = m.min(b[3], z), m.max(b[6], z)
  end
  return b
end

local function vert3(doc, vi)
  return doc.verts[(vi - 1) * 3 + 1], doc.verts[(vi - 1) * 3 + 2],
         doc.verts[(vi - 1) * 3 + 3]
end
M.vert3 = vert3

-- flat face normal from the first three verts (zero for degenerate)
function M.face_normal(doc, fi)
  local f = doc.faces[fi]
  local ax, ay, az = vert3(doc, f.v[1])
  local bx, by, bz = vert3(doc, f.v[2])
  local cx, cy, cz = vert3(doc, f.v[3])
  local ux, uy, uz = bx - ax, by - ay, bz - az
  local vx, vy, vz = cx - ax, cy - ay, cz - az
  local nx = uy * vz - uz * vy
  local ny = uz * vx - ux * vz
  local nz = ux * vy - uy * vx
  local l = m.sqrt(nx * nx + ny * ny + nz * nz)
  if l < 1e-12 then return 0, 0, 0 end
  return nx / l, ny / l, nz / l
end

-- planar per-face projection (the picoCAD model — MANUAL, never an
-- unwrap): project the face's corners onto the axis plane most aligned
-- with its normal. Returns flat {u1,v1,u2,v2,...} in WORLD units — the
-- checker bake tiles it per unit; the window scales it to texels for
-- the default island placement when a face is dragged onto the image.
function M.plan_uv(doc, fi)
  local f = doc.faces[fi]
  local nx, ny, nz = M.face_normal(doc, fi)
  local ax, ay, az = m.abs(nx), m.abs(ny), m.abs(nz)
  local out = {}
  for k, vi in ipairs(f.v) do
    local x, y, z = vert3(doc, vi)
    local u, v
    if ay >= ax and ay >= az then u, v = x, z -- floor / ceiling
    elseif ax >= az then u, v = z, -y         -- x wall (upright)
    else u, v = x, -y end                     -- z wall (upright)
    out[k * 2 - 1], out[k * 2] = u, v
  end
  return out
end

-- ray (model space) vs the mesh: nearest face -> fi, t | nil. Möller-
-- Trumbore over the triangulated faces; doublesided faces hit from
-- either side, single-sided from the front only.
function M.pick_face(doc, ray)
  local best, bestt
  for fi, f in ipairs(doc.faces) do
    local ntri = #f.v - 2
    for k = 1, ntri do
      local a1, a2, a3 = f.v[1], f.v[k + 1], f.v[k + 2]
      local ax, ay, az = vert3(doc, a1)
      local bx, by, bz = vert3(doc, a2)
      local cx, cy, cz = vert3(doc, a3)
      local e1x, e1y, e1z = bx - ax, by - ay, bz - az
      local e2x, e2y, e2z = cx - ax, cy - ay, cz - az
      local px = ray.dy * e2z - ray.dz * e2y
      local py = ray.dz * e2x - ray.dx * e2z
      local pz = ray.dx * e2y - ray.dy * e2x
      local det = e1x * px + e1y * py + e1z * pz
      -- outward-CCW faces give det > 0 for a front-side ray; a
      -- doublesided face accepts either sign
      local hit = det > 1e-12 or (f.ds and det < -1e-12)
      if hit then
        local inv = 1 / det
        local tx, ty, tz = ray.ox - ax, ray.oy - ay, ray.oz - az
        local u = (tx * px + ty * py + tz * pz) * inv
        if u >= 0 and u <= 1 then
          local qx = ty * e1z - tz * e1y
          local qy = tz * e1x - tx * e1z
          local qz = tx * e1y - ty * e1x
          local v = (ray.dx * qx + ray.dy * qy + ray.dz * qz) * inv
          if v >= 0 and u + v <= 1 then
            local t = (e2x * qx + e2y * qy + e2z * qz) * inv
            if t > 1e-6 and (not bestt or t < bestt) then
              best, bestt = fi, t
            end
          end
        end
      end
    end
  end
  return best, bestt
end

-- ---- rendering (render-class; the gb baked path) -------------------------

-- group faces into gb-shaped bakes, one per distinct (texture source,
-- color) — few in practice: [{ col={r,g,b}, src, bk }] — unlit faces
-- take the zero-normal slot (the water rule: vert() skips lighting),
-- doublesided faces bake both windings. src tags the group's texture
-- source: nil (flat color), {kind="chk", idx} (a stock checker; UVs
-- tile per world unit via plan_uv), {kind="img"} (the doc's image; UV
-- texels map into frame opts.frame of the baked strip). gr.col is the
-- first member face's color — the flat FALLBACK the legacy emit()
-- draws, so texture-blind consumers degrade to the pre-texture look.
--   opts.tex   = {w,h} of the resolved strip texture (default: one
--                frame — tw x th — so plain consumers normalize per
--                frame exactly as pre-D155)
--   opts.frame = 0-based strip frame (default 0; clamped)
--   opts.tw/th = frame-size override — the editor passes the bound
--                .spr's LIVE canvas size here so a resized sprite never
--                leaves the doc's recorded size driving the math (the
--                "derived state must follow its sources" rule)
function M.bake_groups(doc, opts)
  local tw = (opts and opts.tw) or doc.tw or 64
  local th = (opts and opts.th) or doc.th or 64
  local sw = opts and opts.tex and opts.tex.w or tw
  local sh = opts and opts.tex and opts.tex.h or th
  if sw < 1 then sw = tw end
  if sh < 1 then sh = th end
  local frames = m.max(1, sw // tw)
  local frame = m.min(m.max(opts and opts.frame or 0, 0), frames - 1)
  local u0 = frame * tw
  local groups, index = {}, {}
  local function group_for(f)
    local key, src
    if f.chk then
      key = "k" .. f.chk
      src = { kind = "chk", idx = f.chk }
    elseif f.uv then
      key = "t"
      src = { kind = "img" }
    else
      local col = f.col or DEFCOL
      key = ("%d:%d:%d"):format((col[1] * 255) // 1, (col[2] * 255) // 1,
                                (col[3] * 255) // 1)
    end
    local gr = index[key]
    if not gr then
      local col = f.col or DEFCOL
      gr = { col = { col[1], col[2], col[3] }, src = src,
             bk = { nv = 0, ns = 0, pos = {}, uv = {}, ni = {}, nrm = {},
                    lit = {} } }
      index[key] = gr
      groups[#groups + 1] = gr
    end
    return gr
  end
  local function slot(bk, nx, ny, nz)
    local s = bk.ns
    bk.nrm[s * 3 + 1], bk.nrm[s * 3 + 2], bk.nrm[s * 3 + 3] = nx, ny, nz
    bk.ns = s + 1
    return s
  end
  local function bvert(bk, x, y, z, u, v, sl)
    local i = bk.nv
    bk.pos[i * 3 + 1], bk.pos[i * 3 + 2], bk.pos[i * 3 + 3] = x, y, z
    bk.uv[i * 2 + 1], bk.uv[i * 2 + 2] = u, v
    bk.ni[i + 1] = sl
    bk.nv = i + 1
  end
  for fi, f in ipairs(doc.faces) do
    local gr = group_for(f)
    local bk = gr.bk
    local nx, ny, nz = M.face_normal(doc, fi)
    local plan = f.chk and M.plan_uv(doc, fi)
    local function emit_side(flipn)
      local sl
      if f.unlit then sl = slot(bk, 0, 0, 0)
      elseif flipn then sl = slot(bk, -nx, -ny, -nz)
      else sl = slot(bk, nx, ny, nz) end
      local n = #f.v
      local function uvat(k)
        if plan then return plan[k * 2 - 1], plan[k * 2] end
        if f.uv then
          return (u0 + f.uv[k * 2 - 1]) / sw, f.uv[k * 2] / sh
        end
        return 0, 0
      end
      local order = flipn and { 1, 3, 2 } or { 1, 2, 3 }
      for k = 1, n - 2 do
        local tri = { 1, k + 1, k + 2 }
        for _, oi in ipairs(order) do
          local vi = tri[oi]
          local x, y, z = vert3(doc, f.v[vi])
          local u, v = uvat(vi)
          bvert(bk, x, y, z, u, v, sl)
        end
      end
    end
    emit_side(false)
    if f.ds then emit_side(true) end
  end
  return groups
end

-- emit the whole mesh pre-lit under xf/nxf (gb.emit_baked — the
-- x_figverts fast path when present). Lighting comes from gb.sun /
-- gb.ambient exactly like every gb shape; callers with scene lighting
-- set them (and restore) around the call. Returns tris.
function M.emit(out, xf, nxf, doc, opts)
  local groups = opts and opts.groups or M.bake_groups(doc, opts)
  local ntris = 0
  for _, gr in ipairs(groups) do
    ntris = ntris + gb.emit_baked(out, xf, nxf, gr.bk, gr.col,
                                  opts and opts.alpha)
  end
  return ntris
end

-- texture-aware emit (D155): one draw segment per group —
-- [{ tex, flags, bytes, ntris }] in group order. Checker groups bind
-- the stock tiles (NEAREST); image groups bind opts.tex_id with
-- ALPHATEST|NEAREST (the sprite rule) when resolved, else fall back to
-- their flat face colors (a missing .spr degrades to the pre-texture
-- look, never white). Textured groups light a WHITE base so the texel
-- carries the color. opts.groups/frame/tex/alpha as in bake_groups/emit.
local WHITE = { 1, 1, 1 }
function M.emit_segments(doc, xf, nxf, opts)
  local groups = opts and opts.groups or M.bake_groups(doc, opts)
  local segs = {}
  for _, gr in ipairs(groups) do
    local tex, flags, col = 0, 0, gr.col
    if gr.src and gr.src.kind == "chk" then
      tex, flags, col = M.checker_tex(gr.src.idx), 2, WHITE
    elseif gr.src and gr.src.kind == "img" then
      local id = opts and opts.tex_id
      if id and id ~= 0 then tex, flags, col = id, 3, WHITE end
    end
    local out = {}
    local nt = gb.emit_baked(out, xf, nxf, gr.bk, col,
                             opts and opts.alpha)
    segs[#segs + 1] = { tex = tex, flags = flags,
                        bytes = table.concat(out), ntris = nt }
  end
  return segs
end

-- ---- editing ops (pure; the window is gesture plumbing) ------------------

-- append a primitive's verts+faces; returns the new face index range
function M.add_prim(doc, kind, o)
  o = o or {}
  local base = #doc.verts // 3
  local f0 = #doc.faces + 1
  local col = o.col or DEFCOL
  local function V(x, y, z)
    local t = doc.verts
    t[#t + 1], t[#t + 2], t[#t + 3] = x, y, z
  end
  local function F(a, b, c, d)
    local f = { v = d and { base + a, base + b, base + c, base + d }
                or { base + a, base + b, base + c },
                col = { col[1], col[2], col[3] } }
    doc.faces[#doc.faces + 1] = f
  end
  if kind == "box" then
    local s = (o.size or 1) / 2
    local sy = (o.h or o.size or 1) / 2
    -- 8 corners; quads wound CCW seen from OUTSIDE (outward normals —
    -- the lighting and pick-front rule; KAT-pinned)
    V(-s, -sy, -s) V(s, -sy, -s) V(s, sy, -s) V(-s, sy, -s)
    V(-s, -sy, s) V(s, -sy, s) V(s, sy, s) V(-s, sy, s)
    F(1, 4, 3, 2) -- back  (z-)
    F(5, 6, 7, 8) -- front (z+)
    F(2, 3, 7, 6) -- right (x+)
    F(1, 5, 8, 4) -- left  (x-)
    F(4, 8, 7, 3) -- top   (y+)
    F(1, 2, 6, 5) -- bottom (y-)
  elseif kind == "plane" then
    local s = (o.size or 2) / 2
    V(-s, 0, -s) V(s, 0, -s) V(s, 0, s) V(-s, 0, s)
    F(1, 4, 3, 2) -- +y normal
    doc.faces[#doc.faces].ds = true
  elseif kind == "wedge" then
    local s = (o.size or 1) / 2
    V(-s, -s, -s) V(s, -s, -s) V(s, -s, s) V(-s, -s, s) -- base
    V(-s, s, -s) V(s, s, -s)                            -- ridge (z-)
    F(1, 2, 3, 4) -- bottom (y-)
    F(2, 1, 5, 6) -- back wall (z-)
    F(4, 3, 6, 5) -- slope (+y+z)
    F(3, 2, 6)    -- right tri (x+)
    F(1, 4, 5)    -- left tri (x-)
  elseif kind == "prism" then
    local n = o.n or 6
    local r = o.r or 0.5
    local h = o.h or 1
    for i = 0, n - 1 do
      local a = i * m.tau / n
      V(r * m.cos(a), 0, r * m.sin(a))
      V(r * m.cos(a), h, r * m.sin(a))
    end
    for i = 0, n - 1 do
      local j = (i + 1) % n
      F(i * 2 + 1, i * 2 + 2, j * 2 + 2, j * 2 + 1) -- side quad, outward
    end
    for i = 1, n - 2 do -- caps as fans
      F(1, i * 2 + 1, (i + 1) * 2 + 1)         -- bottom (y-)
      F(2, (i + 1) * 2, i * 2 + 2)             -- top (y+)
    end
  else
    error("mesh.add_prim: unknown kind " .. tostring(kind), 2)
  end
  return f0, #doc.faces
end

-- extrude a face along its normal by dist: the face's verts duplicate,
-- side quads stitch the rim, the face moves to the new verts. THE power
-- op (box -> anything). Returns the extruded face index (same fi).
function M.extrude(doc, fi, dist)
  local f = doc.faces[fi]
  if not f then return nil end
  local nx, ny, nz = M.face_normal(doc, fi)
  local n = #f.v
  local base = #doc.verts // 3
  for k = 1, n do
    local x, y, z = vert3(doc, f.v[k])
    local t = doc.verts
    t[#t + 1] = x + nx * dist
    t[#t + 1] = y + ny * dist
    t[#t + 1] = z + nz * dist
  end
  for k = 1, n do
    local k2 = k % n + 1
    doc.faces[#doc.faces + 1] = {
      v = { f.v[k], f.v[k2], base + k2, base + k },
      col = { f.col[1], f.col[2], f.col[3] },
      ds = f.ds, unlit = f.unlit, chk = f.chk,
    }
  end
  local nv2 = {}
  for k = 1, n do nv2[k] = base + k end
  f.v = nv2
  return fi
end

-- flip a face's winding
function M.flip(doc, fi)
  local f = doc.faces[fi]
  if not f then return end
  local r = {}
  for k = #f.v, 1, -1 do r[#r + 1] = f.v[k] end
  f.v = r
  if f.uv then
    local u = {}
    for k = #f.v, 1, -1 do
      u[#u + 1] = f.uv[k * 2 - 1]
      u[#u + 1] = f.uv[k * 2]
    end
    f.uv = u
  end
end

-- merge selected verts at their mean; faces re-point, degenerate faces
-- (fewer than 3 distinct verts) die. ids = array of 1-based vert ids.
function M.merge_verts(doc, ids)
  if #ids < 2 then return end
  local mx, my, mz = 0, 0, 0
  local keep = ids[1]
  local set = {}
  for _, vi in ipairs(ids) do
    set[vi] = true
    local x, y, z = vert3(doc, vi)
    mx, my, mz = mx + x, my + y, mz + z
  end
  local n = #ids
  doc.verts[(keep - 1) * 3 + 1] = mx / n
  doc.verts[(keep - 1) * 3 + 2] = my / n
  doc.verts[(keep - 1) * 3 + 3] = mz / n
  for _, f in ipairs(doc.faces) do
    for k, vi in ipairs(f.v) do
      if set[vi] then f.v[k] = keep end
    end
  end
  -- drop collapsed faces + now-unused verts
  M.compact(doc)
end

-- drop degenerate faces and unreferenced verts (stable order)
function M.compact(doc)
  local out = {}
  for _, f in ipairs(doc.faces) do
    local seen, uniq = {}, {}
    for _, vi in ipairs(f.v) do
      if not seen[vi] then
        seen[vi] = true
        uniq[#uniq + 1] = vi
      end
    end
    if #uniq >= 3 then
      f.v = uniq
      if f.uv and #f.uv ~= #uniq * 2 then f.uv = nil end
      out[#out + 1] = f
    end
  end
  doc.faces = out
  local used = {}
  for _, f in ipairs(doc.faces) do
    for _, vi in ipairs(f.v) do used[vi] = true end
  end
  local remap, nverts = {}, {}
  local nv = #doc.verts // 3
  for vi = 1, nv do
    if used[vi] then
      local x, y, z = vert3(doc, vi)
      nverts[#nverts + 1] = x
      nverts[#nverts + 1] = y
      nverts[#nverts + 1] = z
      remap[vi] = #nverts // 3
    end
  end
  doc.verts = nverts
  for _, f in ipairs(doc.faces) do
    for k, vi in ipairs(f.v) do f.v[k] = remap[vi] end
  end
end

-- delete faces by index set; then compact
function M.remove_faces(doc, set)
  local out = {}
  for fi, f in ipairs(doc.faces) do
    if not set[fi] then out[#out + 1] = f end
  end
  doc.faces = out
  M.compact(doc)
end

-- ---- topology + selection (pure; the window's universal mode) -----------

-- canonical undirected edge key (u16 vert ids: min*65536+max fits exactly)
function M.ekey(a, b)
  if a > b then a, b = b, a end
  return a * 65536 + b
end

function M.eunkey(key)
  return key // 65536, key % 65536
end

-- every edge in the mesh: array of { a, b, key, fs = {fi...} } (a < b,
-- first-seen order) plus the key -> record index map. fs is face
-- adjacency in face order — the loop walk's substrate.
function M.edges(doc)
  local list, index = {}, {}
  for fi, f in ipairs(doc.faces) do
    local n = #f.v
    for k = 1, n do
      local a, b = f.v[k], f.v[k % n + 1]
      local key = M.ekey(a, b)
      local e = index[key]
      if not e then
        e = { a = m.min(a, b), b = m.max(a, b), key = key, fs = {} }
        index[key] = e
        list[#list + 1] = e
      end
      e.fs[#e.fs + 1] = fi
    end
  end
  return list, index
end

-- every ray-face hit, nearest first: [{ fi, t }] — the drill ladder's
-- substrate (pick_face = hits[1]). Same front-side/doublesided rule.
function M.pick_hits(doc, ray)
  local hits = {}
  for fi, f in ipairs(doc.faces) do
    local ntri = #f.v - 2
    local bestt
    for k = 1, ntri do
      local a1, a2, a3 = f.v[1], f.v[k + 1], f.v[k + 2]
      local ax, ay, az = vert3(doc, a1)
      local bx, by, bz = vert3(doc, a2)
      local cx, cy, cz = vert3(doc, a3)
      local e1x, e1y, e1z = bx - ax, by - ay, bz - az
      local e2x, e2y, e2z = cx - ax, cy - ay, cz - az
      local px = ray.dy * e2z - ray.dz * e2y
      local py = ray.dz * e2x - ray.dx * e2z
      local pz = ray.dx * e2y - ray.dy * e2x
      local det = e1x * px + e1y * py + e1z * pz
      local hit = det > 1e-12 or (f.ds and det < -1e-12)
      if hit then
        local inv = 1 / det
        local tx, ty, tz = ray.ox - ax, ray.oy - ay, ray.oz - az
        local u = (tx * px + ty * py + tz * pz) * inv
        if u >= 0 and u <= 1 then
          local qx = ty * e1z - tz * e1y
          local qy = tz * e1x - tx * e1z
          local qz = tx * e1y - ty * e1x
          local v = (ray.dx * qx + ray.dy * qy + ray.dz * qz) * inv
          if v >= 0 and u + v <= 1 then
            local t = (e2x * qx + e2y * qy + e2z * qz) * inv
            if t > 1e-6 and (not bestt or t < bestt) then bestt = t end
          end
        end
      end
    end
    if bestt then hits[#hits + 1] = { fi = fi, t = bestt } end
  end
  table.sort(hits, function(x, y) return x.t < y.t end)
  return hits
end

-- is vert vi visible from origin o (no front-facing face closer along
-- the ray than the vert itself)? Backface-culled faces are see-through
-- in render, so front-only occlusion matches what the eye sees. The
-- 1e-3 slack keeps a vert's own faces (hit AT the vert) from hiding it.
function M.vert_visible(doc, ox, oy, oz, vi)
  local x, y, z = vert3(doc, vi)
  local dx, dy, dz = x - ox, y - oy, z - oz
  local dist = m.sqrt(dx * dx + dy * dy + dz * dz)
  if dist < 1e-9 then return true end
  local ray = { ox = ox, oy = oy, oz = oz,
                dx = dx / dist, dy = dy / dist, dz = dz / dist }
  local _, t = M.pick_face(doc, ray)
  return not t or t >= dist * (1 - 1e-3)
end

-- the edge loop through (a, b): the vertex walk — at each endpoint the
-- loop continues along the ONE edge that shares no face with the
-- current edge (the "straight ahead" of a quad grid; an extruded box's
-- waist ring walks itself closed). Where no such edge exists at either
-- end (a lone cube edge: every corner is valence 3), the loop falls
-- back to the boundary of an adjacent FACE — `prefer_face` (the face
-- under the cursor) picks which side; selecting a cube edge selects
-- that face's ring, the expected read. Returns the edge-key list and
-- the touched faces (the fallback returns exactly the one face).
function M.edge_loop(doc, a, b, prefer_face)
  local list, index = M.edges(doc)
  local start = M.ekey(a, b)
  local seed = index[start]
  if not seed then return { start }, {} end
  local at = {} -- vertex -> incident edge records
  for _, e in ipairs(list) do
    at[e.a] = at[e.a] or {}
    at[e.b] = at[e.b] or {}
    at[e.a][#at[e.a] + 1] = e
    at[e.b][#at[e.b] + 1] = e
  end
  local keys = { start }
  local seen = { [start] = true }
  local function walk(v, e)
    while true do
      local eset = {}
      for _, fi in ipairs(e.fs) do eset[fi] = true end
      local nxt, n = nil, 0
      for _, cand in ipairs(at[v] or {}) do
        if cand ~= e then
          local shares = false
          for _, fi in ipairs(cand.fs) do
            if eset[fi] then shares = true break end
          end
          if not shares then
            n = n + 1
            nxt = cand
          end
        end
      end
      if n ~= 1 or seen[nxt.key] then break end
      seen[nxt.key] = true
      keys[#keys + 1] = nxt.key
      v = (nxt.a == v) and nxt.b or nxt.a
      e = nxt
    end
  end
  walk(seed.b, seed)
  walk(seed.a, seed)

  if #keys == 1 then
    -- dead end both ways: the face-boundary fallback
    local fi = nil
    if prefer_face then
      for _, f2 in ipairs(seed.fs) do
        if f2 == prefer_face then fi = f2 break end
      end
    end
    fi = fi or seed.fs[1]
    local f = fi and doc.faces[fi]
    if f then
      keys = {}
      local n = #f.v
      for k = 1, n do
        keys[#keys + 1] = M.ekey(f.v[k], f.v[k % n + 1])
      end
      return keys, { fi }
    end
    return keys, {}
  end

  local fset, faces = {}, {}
  for _, key in ipairs(keys) do
    for _, fi in ipairs(index[key].fs) do
      if not fset[fi] then
        fset[fi] = true
        faces[#faces + 1] = fi
      end
    end
  end
  return keys, faces
end

-- the union of every vert a mixed selection touches (vsel ids + esel
-- endpoints + fsel corners), ascending — what a move gesture moves.
function M.sel_verts(doc, vsel, esel, fsel)
  local set = {}
  for _, vi in ipairs(vsel or {}) do set[vi] = true end
  for _, key in ipairs(esel or {}) do
    local a, b = M.eunkey(key)
    set[a], set[b] = true, true
  end
  for _, fi in ipairs(fsel or {}) do
    local f = doc.faces[fi]
    for _, vi in ipairs(f and f.v or {}) do set[vi] = true end
  end
  local out = {}
  for vi in pairs(set) do out[#out + 1] = vi end
  table.sort(out)
  return out
end

-- selection continuity across mode switches: the touched-vert union
-- re-expresses as the target mode's elements (verts / edges with both
-- endpoints touched / faces with every corner touched). "sel" keeps the
-- mixed selection as-is.
function M.convert_sel(doc, vsel, esel, fsel, to)
  if to == "sel" then return vsel, esel, fsel end
  local union = M.sel_verts(doc, vsel, esel, fsel)
  local set = {}
  for _, vi in ipairs(union) do set[vi] = true end
  if to == "vtx" then return union, {}, {} end
  if to == "edge" then
    local out = {}
    for _, e in ipairs(M.edges(doc)) do
      if set[e.a] and set[e.b] then out[#out + 1] = e.key end
    end
    return {}, out, {}
  end
  if to == "face" then
    local out = {}
    for fi, f in ipairs(doc.faces) do
      local all = #f.v > 0
      for _, vi in ipairs(f.v) do
        if not set[vi] then all = false break end
      end
      if all then out[#out + 1] = fi end
    end
    return {}, {}, out
  end
  return vsel, esel, fsel
end

-- the mirror-x partner of a vert (a vert at (-x, y, z) within eps),
-- for live mirrored editing. nil for center-line or unpaired verts.
function M.mirror_pair(doc, vi, eps)
  eps = eps or 1e-4
  local x, y, z = vert3(doc, vi)
  if m.abs(x) <= eps then return nil end
  local nv = #doc.verts // 3
  for k = 1, nv do
    if k ~= vi then
      local kx, ky, kz = vert3(doc, k)
      if m.abs(kx + x) <= eps and m.abs(ky - y) <= eps
         and m.abs(kz - z) <= eps then
        return k
      end
    end
  end
  return nil
end

return M
