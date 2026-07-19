-- cm.terr3 — the .terr asset (EDITOR3D.md §3, D137): the cm.map of 3D.
-- A CTER chunk container holding a 3D map's parts — the per-vertex
-- heightfield (cm.terr's exact grid shape: the doc IS a valid cm.terr
-- object, so T.sample/hget/hset work on it directly), an ordered
-- material list with per-vertex weight planes, a painted shade plane,
-- the water level, walk-grid knobs + hand overrides, prop placements
-- (any project asset; 2D images default to billboards at draw time),
-- and markers (points/radii + route polylines + kind/label/extras).
-- Codec is pure and canonical (encode(decode(b)) == b); cm.chunk gives
-- skip-tolerance.
--
--   HEAD v1: <i4 w> <i4 h> <f tile> <s4 name>
--            <fff sun dir> <fff sun col> <fff ambient>
--            <I1 fog on> <ff fog start,end> <fff fog col>
--            <I1 water on> <f water y> <fff water col> <f water alpha>
--            <f walk max slope> <f walk wade depth>
--            <fff spawn x,z,yaw> <I4 bake stamp>
--   MATS v1: <I1 n> n * ( <s4 name> <fff col> <s4 tex path ("" = flat) )
--            — the ordered material list (cap 8, editor-enforced)
--   HGTS v1: (w+1)*(h+1) raw <f> heights, row-major (cm.terr layout)
--   WGTS v1: <I1 mat index 1-based> + (w+1)*(h+1) raw u8 weights.
--            One chunk per material; an ALL-ZERO plane is not written
--            (canonical: absent = zeros). A vertex whose weights sum to
--            zero wears material 1 (so a fresh map is mat-1 ground).
--   SHDE v1: (w+1)*(h+1) raw u8 painted shade (255 = 1.0). Written only
--            when any byte differs from 255 (canonical: absent = flat).
--   PROP v1: <s4 path> <s4 name> <s4 anim> <ff x z> <f y> <f yaw>
--            <f scale> <I4 flags bit0 y-absolute, bit1 caster,
--            bit2 walk-blocker> <I1 colmode 0 none | 1 auto | 2 box>
--            [colmode 2: <ffffff x0 y0 z0 x1 y1 z1> local box]
--            <I2 nex> nex * (<s4 k> <s4 v>)
--            — one per placement, file order = draw order. y is an
--            offset above the sampled ground unless y-absolute.
--   MRKR v1: <s4 kind> <s4 label> <s4 note> <ff x z> <f r>
--            <I2 npts> npts * <ff x z>   (a route polyline; 0 = point)
--            <I2 nex> nex * (<s4 k> <s4 v>)
--   WOVR v1: <I4 n> n * (<i4 cx> <i4 cz> <I1 v 0 block | 1 walk>)
--            — hand overrides on the derived walk grid (GAT cells)
--   TAIL v1: empty
--
-- Sim/render split (ARCHITECTURE iron rules): heights, walk grid,
-- prop colliders, markers, and placement transforms are captured state
-- — M.use publishes canonical CTER runtime bytes into <name>.t3state
-- (the cm.map CMRT pattern verbatim) so traces replay map hot-reloads
-- and rewind shows the old ground with its matching props. Emission
-- (emit_terrain/emit_water) is render-class; the editor viewport and
-- the game share these emitters, so what the window shows IS the game.
--
-- The procedural door (EDITOR3D.md §3.3): encode/decode/save are
-- public — a generator script writes the same asset the editor edits.

local m = cm.require("cm.math")
local chunk = cm.require("cm.chunk")
local terr = cm.require("cm.terr")
local state = cm.require("cm.state")

local M = select(2, ...) or {}

M._slots = M._slots or {}

local pack, unpack = string.pack, string.unpack
local MAGIC = "CTER"
M.MAX_MATS = 8

-- ---- doc construction ----------------------------------------------------

local function plane_size(doc) return (doc.w + 1) * (doc.h + 1) end
M.plane_size = plane_size

-- a fresh map: flat ground, one grass material, sane light/walk knobs
-- (the editor's unbound-window create door; EDITOR3D.md §4)
function M.fresh(name, w, h, tile)
  local doc = {
    name = name or "", w = w or 48, h = h or 48, tile = tile or 2.0,
    sun = { -0.45, -0.78, -0.42 }, suncol = { 0.9, 0.87, 0.8 },
    amb = { 0.42, 0.44, 0.5 },
    fog = { on = false, s = 60, e = 140, col = { 0.62, 0.72, 0.85 } },
    water = { on = false, y = 0, col = { 0.25, 0.45, 0.62 }, alpha = 150 },
    walk = { slope = 0.9, wade = 0.45 },
    spawn = { x = 0, z = 0, yaw = 0 }, -- centered below
    stamp = 0,
    mats = { { name = "grass", col = { 0.36, 0.55, 0.28 }, tex = "" } },
    hts = {}, wts = {}, shade = nil,
    props = {}, markers = {}, wovr = {},
  }
  doc.spawn.x = doc.w * doc.tile * 0.5
  doc.spawn.z = doc.h * doc.tile * 0.5
  for i = 1, plane_size(doc) do doc.hts[i] = 0 end
  return doc
end

-- ---- codec ---------------------------------------------------------------

function M.encode(doc)
  local w = chunk.writer(MAGIC)
  local fog, wat, wk, sp = doc.fog, doc.water, doc.walk, doc.spawn
  w.chunk("HEAD", 1, pack("<i4i4fs4fffffffffI1fffffI1ffffffffffI4",
    doc.w, doc.h, doc.tile, doc.name or "",
    doc.sun[1], doc.sun[2], doc.sun[3],
    doc.suncol[1], doc.suncol[2], doc.suncol[3],
    doc.amb[1], doc.amb[2], doc.amb[3],
    fog.on and 1 or 0, fog.s, fog.e, fog.col[1], fog.col[2], fog.col[3],
    wat.on and 1 or 0, wat.y, wat.col[1], wat.col[2], wat.col[3], wat.alpha,
    wk.slope, wk.wade, sp.x, sp.z, sp.yaw, doc.stamp or 0))
  local mp = { pack("<I1", #doc.mats) }
  for _, mt in ipairs(doc.mats) do
    mp[#mp + 1] = pack("<s4fffs4", mt.name or "", mt.col[1], mt.col[2],
                       mt.col[3], mt.tex or "")
  end
  w.chunk("MATS", 1, table.concat(mp))
  local n = plane_size(doc)
  local hp = {}
  for i = 1, n do hp[i] = pack("<f", doc.hts[i]) end
  w.chunk("HGTS", 1, table.concat(hp))
  for mi = 1, #doc.mats do
    local pl = doc.wts[mi]
    if pl then
      local any = false
      for i = 1, n do if pl[i] ~= 0 then any = true break end end
      if any then
        local bp = { pack("<I1", mi) }
        for i = 1, n do bp[#bp + 1] = string.char(pl[i]) end
        w.chunk("WGTS", 1, table.concat(bp))
      end
    end
  end
  if doc.shade then
    local any = false
    for i = 1, n do if doc.shade[i] ~= 255 then any = true break end end
    if any then
      local bp = {}
      for i = 1, n do bp[i] = string.char(doc.shade[i]) end
      w.chunk("SHDE", 1, table.concat(bp))
    end
  end
  for _, p in ipairs(doc.props) do
    local flags = (p.abs and 1 or 0) | (p.caster and 2 or 0)
                | (p.blocker and 4 or 0)
    local colmode = p.col and (p.col.mode == "auto" and 1
                    or p.col.mode == "box" and 2 or 0) or 0
    local parts = { pack("<s4s4s4fffffI4I1", p.path, p.name or "",
                         p.anim or "", p.x, p.z, p.y or 0, p.yaw or 0,
                         p.scale or 1, flags, colmode) }
    if colmode == 2 then
      local b = p.col.box
      parts[#parts + 1] = pack("<ffffff", b[1], b[2], b[3], b[4], b[5], b[6])
    end
    parts[#parts + 1] = pack("<I2", #(p.extras or {}))
    for _, e in ipairs(p.extras or {}) do
      parts[#parts + 1] = pack("<s4s4", e.k, e.v)
    end
    w.chunk("PROP", 1, table.concat(parts))
  end
  for _, mk in ipairs(doc.markers) do
    local parts = { pack("<s4s4s4fff", mk.kind, mk.label or "",
                         mk.note or "", mk.x, mk.z, mk.r or 0) }
    local pts = mk.points or {}
    parts[#parts + 1] = pack("<I2", #pts // 2)
    for i = 1, #pts do parts[#parts + 1] = pack("<f", pts[i]) end
    parts[#parts + 1] = pack("<I2", #(mk.extras or {}))
    for _, e in ipairs(mk.extras or {}) do
      parts[#parts + 1] = pack("<s4s4", e.k, e.v)
    end
    w.chunk("MRKR", 1, table.concat(parts))
  end
  if #doc.wovr > 0 then
    local parts = { pack("<I4", #doc.wovr) }
    for _, o in ipairs(doc.wovr) do
      parts[#parts + 1] = pack("<i4i4I1", o.cx, o.cz, o.v)
    end
    w.chunk("WOVR", 1, table.concat(parts))
  end
  w.chunk("TAIL", 1, "")
  return w.result()
end

function M.decode(bytes)
  local doc = { mats = {}, hts = {}, wts = {}, props = {}, markers = {},
                wovr = {} }
  local seen_head, seen_tail
  for _, c in ipairs(chunk.read(bytes, MAGIC)) do
    if c.tag == "HEAD" and c.version == 1 then
      local sx, sy, sz, scr, scg, scb, ar, ag, ab, fon, fs, fe, fr, fg, fb
      local won, wy, wr, wg, wb, wa, slope, wade, spx, spz, spyaw, stamp
      doc.w, doc.h, doc.tile, doc.name,
      sx, sy, sz, scr, scg, scb, ar, ag, ab,
      fon, fs, fe, fr, fg, fb,
      won, wy, wr, wg, wb, wa,
      slope, wade, spx, spz, spyaw, stamp =
        unpack("<i4i4fs4fffffffffI1fffffI1ffffffffffI4", c.payload)
      doc.sun = { sx, sy, sz }
      doc.suncol = { scr, scg, scb }
      doc.amb = { ar, ag, ab }
      doc.fog = { on = fon ~= 0, s = fs, e = fe, col = { fr, fg, fb } }
      doc.water = { on = won ~= 0, y = wy, col = { wr, wg, wb }, alpha = wa }
      doc.walk = { slope = slope, wade = wade }
      doc.spawn = { x = spx, z = spz, yaw = spyaw }
      doc.stamp = stamp
      seen_head = true
    elseif c.tag == "MATS" and c.version == 1 then
      local nm, pos = unpack("<I1", c.payload, 1)
      for _ = 1, nm do
        local name, r, g, b, tex
        name, r, g, b, tex, pos = unpack("<s4fffs4", c.payload, pos)
        doc.mats[#doc.mats + 1] = { name = name, col = { r, g, b }, tex = tex }
      end
    elseif c.tag == "HGTS" and c.version == 1 then
      local pos = 1
      for i = 1, #c.payload // 4 do
        doc.hts[i], pos = unpack("<f", c.payload, pos)
      end
    elseif c.tag == "WGTS" and c.version == 1 then
      local mi = unpack("<I1", c.payload, 1)
      local pl = {}
      for i = 1, #c.payload - 1 do pl[i] = c.payload:byte(1 + i) end
      doc.wts[mi] = pl
    elseif c.tag == "SHDE" and c.version == 1 then
      local pl = {}
      for i = 1, #c.payload do pl[i] = c.payload:byte(i) end
      doc.shade = pl
    elseif c.tag == "PROP" and c.version == 1 then
      local p, pos = {}, 1
      local flags, colmode
      p.path, p.name, p.anim, p.x, p.z, p.y, p.yaw, p.scale, flags,
      colmode, pos = unpack("<s4s4s4fffffI4I1", c.payload, pos)
      p.abs = flags & 1 ~= 0 or nil
      p.caster = flags & 2 ~= 0 or nil
      p.blocker = flags & 4 ~= 0 or nil
      if p.name == "" then p.name = nil end
      if p.anim == "" then p.anim = nil end
      if colmode == 1 then p.col = { mode = "auto" }
      elseif colmode == 2 then
        local x0, y0, z0, x1, y1, z1
        x0, y0, z0, x1, y1, z1, pos = unpack("<ffffff", c.payload, pos)
        p.col = { mode = "box", box = { x0, y0, z0, x1, y1, z1 } }
      end
      local nex
      nex, pos = unpack("<I2", c.payload, pos)
      if nex > 0 then
        p.extras = {}
        for _ = 1, nex do
          local k, v
          k, v, pos = unpack("<s4s4", c.payload, pos)
          p.extras[#p.extras + 1] = { k = k, v = v }
        end
      end
      doc.props[#doc.props + 1] = p
    elseif c.tag == "MRKR" and c.version == 1 then
      local mk, pos = {}, 1
      mk.kind, mk.label, mk.note, mk.x, mk.z, mk.r, pos =
        unpack("<s4s4s4fff", c.payload, pos)
      if mk.label == "" then mk.label = nil end
      if mk.note == "" then mk.note = nil end
      if mk.r == 0 then mk.r = nil end
      local npts
      npts, pos = unpack("<I2", c.payload, pos)
      if npts > 0 then
        mk.points = {}
        for i = 1, npts * 2 do
          mk.points[i], pos = unpack("<f", c.payload, pos)
        end
      end
      local nex
      nex, pos = unpack("<I2", c.payload, pos)
      if nex > 0 then
        mk.extras = {}
        for _ = 1, nex do
          local k, v
          k, v, pos = unpack("<s4s4", c.payload, pos)
          mk.extras[#mk.extras + 1] = { k = k, v = v }
        end
      end
      doc.markers[#doc.markers + 1] = mk
    elseif c.tag == "WOVR" and c.version == 1 then
      local nn, pos = unpack("<I4", c.payload, 1)
      for _ = 1, nn do
        local cx, cz, v
        cx, cz, v, pos = unpack("<i4i4I1", c.payload, pos)
        doc.wovr[#doc.wovr + 1] = { cx = cx, cz = cz, v = v }
      end
    elseif c.tag == "TAIL" then
      seen_tail = true
    end
  end
  if not seen_head then error("terr: missing HEAD", 0) end
  if not seen_tail then error("terr: missing TAIL (truncated?)", 0) end
  local n = plane_size(doc)
  if #doc.hts ~= n then
    error(("terr: HTS size %d != %d"):format(#doc.hts, n), 0)
  end
  for mi, pl in pairs(doc.wts) do
    if mi < 1 or mi > #doc.mats then error("terr: WTS bad material " .. mi, 0) end
    if #pl ~= n then error("terr: WTS plane size", 0) end
  end
  if doc.shade and #doc.shade ~= n then error("terr: SHDE plane size", 0) end
  return doc
end

function M.save(doc, path, fail)
  local ok, err = pal.write_file_atomic(path, M.encode(doc), fail)
  if not ok then return nil, "write terr failed: " .. tostring(err) end
  return true
end

-- ---- readers (sim-legal: pure IEEE arithmetic over doc data) -------------

-- the doc IS a cm.terr grid; triangle-exact ground height
function M.ground(doc, wx, wz)
  return terr.sample(doc, wx, wz)
end

-- a prop's resolved world y (ground + offset unless absolute)
function M.prop_y(doc, p)
  if p.abs then return p.y or 0 end
  return terr.sample(doc, p.x, p.z) + (p.y or 0)
end

-- normalized material weights at a vertex index (mat 1 wins a zero sum)
function M.weights_at(doc, vi)
  local out, sum = {}, 0
  for mi = 1, #doc.mats do
    local w = doc.wts[mi] and doc.wts[mi][vi] or 0
    out[mi] = w
    sum = sum + w
  end
  if sum == 0 then
    for mi = 1, #doc.mats do out[mi] = mi == 1 and 1 or 0 end
    return out
  end
  for mi = 1, #doc.mats do out[mi] = out[mi] / sum end
  return out
end

-- ---- the walk grid (GAT 2x subdivision; derived + hand overrides) --------

function M.walk_dims(doc) return doc.w * 2, doc.h * 2 end

-- a prop's walk footprint as a world AABB on x/z (nil = none). Box
-- colliders use their local box scaled (yaw deliberately ignored — the
-- walk stamp is axis-aligned; a diagonal fence wants override cells);
-- auto = a half-unit square scaled by the prop.
local function footprint(doc, p)
  if not p.blocker then return nil end
  local s = p.scale or 1
  if p.col and p.col.mode == "box" then
    local b = p.col.box
    return p.x + b[1] * s, p.z + b[3] * s, p.x + b[4] * s, p.z + b[6] * s
  end
  local half = 0.5 * s
  return p.x - half, p.z - half, p.x + half, p.z + half
end

-- derived walkability of one GAT cell (before overrides)
local function derived_walkable(doc, cx, cz)
  local cell = doc.tile * 0.5
  local x0, z0 = cx * cell, cz * cell
  local h00 = terr.sample(doc, x0, z0)
  local h10 = terr.sample(doc, x0 + cell, z0)
  local h01 = terr.sample(doc, x0, z0 + cell)
  local h11 = terr.sample(doc, x0 + cell, z0 + cell)
  local hmax = m.max(m.max(h00, h10), m.max(h01, h11))
  local hmin = m.min(m.min(h00, h10), m.min(h01, h11))
  if hmax - hmin > doc.walk.slope then return false end
  if doc.water.on and doc.water.y - hmin > doc.walk.wade then return false end
  local mx, mz = x0 + cell * 0.5, z0 + cell * 0.5
  for _, p in ipairs(doc.props) do
    local fx0, fz0, fx1, fz1 = footprint(doc, p)
    if fx0 and mx >= fx0 and mx <= fx1 and mz >= fz0 and mz <= fz1 then
      return false
    end
  end
  return true
end

-- the full grid as a string of 0/1 bytes (row-major, gw*gh) — build once
-- per doc generation and hand to cm.walk's ok predicate
function M.walk_grid(doc)
  local gw, gh = M.walk_dims(doc)
  local ovr = {}
  for _, o in ipairs(doc.wovr) do ovr[o.cz * gw + o.cx] = o.v end
  local rows = {}
  for cz = 0, gh - 1 do
    local row = {}
    for cx = 0, gw - 1 do
      local v = ovr[cz * gw + cx]
      if v == nil then v = derived_walkable(doc, cx, cz) and 1 or 0 end
      row[cx + 1] = string.char(v)
    end
    rows[cz + 1] = table.concat(row)
  end
  return table.concat(rows), gw, gh
end

-- ---- prop colliders (world AABBs for the movement kernels) ---------------

-- every prop with a collider mode, as {x0,y0,z0,x1,y1,z1} world boxes.
-- Yaw is deliberately ignored (axis-aligned boxes are the kin contract);
-- auto boxes are a half-unit square x 1.6 tall, scaled.
function M.boxes(doc)
  local out = {}
  for _, p in ipairs(doc.props) do
    local mode = p.col and p.col.mode
    if mode == "auto" or mode == "box" then
      local s = p.scale or 1
      local py = M.prop_y(doc, p)
      if mode == "box" then
        local b = p.col.box
        out[#out + 1] = { p.x + b[1] * s, py + b[2] * s, p.z + b[3] * s,
                          p.x + b[4] * s, py + b[5] * s, p.z + b[6] * s }
      else
        local half = 0.5 * s
        out[#out + 1] = { p.x - half, py, p.z - half,
                          p.x + half, py + 1.6 * s, p.z + half }
      end
    end
  end
  return out
end

-- markers by kind (nil = all); route points are world x/z pairs
function M.markers(doc, kind)
  local out = {}
  for _, mk in ipairs(doc.markers) do
    if not kind or mk.kind == kind then out[#out + 1] = mk end
  end
  return out
end

-- ---- emission (render-class; the editor viewport and the game share it) --

local vpack = string.pack

local function lit(col, shade, nx, ny, nz, sun, suncol, amb)
  local d = m.max(0, -(nx * sun[1] + ny * sun[2] + nz * sun[3]))
  local r = m.clamp(col[1] * shade * (amb[1] + suncol[1] * d), 0, 1)
  local g = m.clamp(col[2] * shade * (amb[2] + suncol[2] * d), 0, 1)
  local b = m.clamp(col[3] * shade * (amb[3] + suncol[3] * d), 0, 1)
  return r, g, b
end

-- per-vertex blended material color x painted shade (+ a subtle
-- deterministic brightness jitter so flat fields read organic)
local function vcol(doc, vx, vz)
  local vi = vz * (doc.w + 1) + vx + 1
  local wts = M.weights_at(doc, vi)
  local r, g, b = 0, 0, 0
  for mi = 1, #doc.mats do
    local c = doc.mats[mi].col
    r = r + c[1] * wts[mi]
    g = g + c[2] * wts[mi]
    b = b + c[3] * wts[mi]
  end
  local j = 1 + (terr.hash(31, vx, vz) - 0.5) * 0.10
  local shade = (doc.shade and doc.shade[vi] or 255) / 255
  return { r * j, g * j, b * j }, shade
end

-- emit the terrain grid pre-lit into out[]; opts.ox/oz = lattice offset
-- (the cm.terr chunk contract). Returns tris.
--
-- opts.atlas = true emits the ATLAS UV mode instead (draw the segment
-- with the baked atlas texture, x_tris flags 2 = nearest): uvs span the
-- whole atlas (map-normalized), vertex colors carry LIGHTING + jitter
-- only (white base — the material mix and painted shade live in the
-- baked texels; texture x vertex color lands within a hair of the
-- vertex mode's read).
function M.emit_terrain(out, doc, opts)
  opts = opts or {}
  local s = doc.tile
  local ox, oz = opts.ox or 0, opts.oz or 0
  local flat = opts.flat_y or 2.0
  local sun, suncol, amb = doc.sun, doc.suncol, doc.amb
  local x0t, z0t = opts.x0 or 0, opts.z0 or 0
  local x1t, z1t = opts.x1 or doc.w - 1, opts.z1 or doc.h - 1
  local atlas = opts.atlas or false
  local WHITE = { 1, 1, 1 }
  local ntris = 0
  for z = z0t, z1t do
    for x = x0t, x1t do
      local h00 = terr.hget(doc, x, z)
      local h10 = terr.hget(doc, x + 1, z)
      local h01 = terr.hget(doc, x, z + 1)
      local h11 = terr.hget(doc, x + 1, z + 1)
      local nx = (h00 + h01 - h10 - h11) / (2 * s)
      local nz = (h00 + h10 - h01 - h11) / (2 * s)
      local nl = m.sqrt(nx * nx + flat * flat + nz * nz)
      nx, nz = nx / nl, nz / nl
      local ny = flat / nl
      local wx, wz = ox + x, oz + z
      local function V(vx, vz, hh)
        local r, g, b, uu, vv
        if atlas then
          local j = 1 + (terr.hash(31, vx - ox, vz - oz) - 0.5) * 0.10
          r, g, b = lit(WHITE, j, nx, ny, nz, sun, suncol, amb)
          uu, vv = (vx - ox) / doc.w, (vz - oz) / doc.h
        else
          local c, sh = vcol(doc, vx - ox, vz - oz)
          r, g, b = lit(c, sh, nx, ny, nz, sun, suncol, amb)
          uu, vv = vx, vz
        end
        return vpack("<fffffBBBB", vx * s, hh, vz * s, uu, vv,
                     (r * 255) // 1, (g * 255) // 1, (b * 255) // 1, 255)
      end
      local A = V(wx, wz, h00)
      local B = V(wx + 1, wz, h10)
      local C = V(wx + 1, wz + 1, h11)
      local D = V(wx, wz + 1, h01)
      out[#out + 1] = A .. B .. C .. A .. C .. D -- NW->SE: T.sample's split
      ntris = ntris + 2
    end
  end
  return ntris
end

-- ---- the terrain texture atlas (the §4.5 bake, nearest-atlas v1) ----
--
-- A material may carry `tex` — an ordinary project image (draw it in
-- the sprite editor) that REPEATS ONCE PER TILE. The bake renders the
-- whole ground into one nearest-sampled texture (ts texels per tile):
-- per texel, the bilinear-blended material weights mix flat colors and
-- sampled texels, times the painted shade. The stamp (M.mat_hash over
-- the PAINT inputs — heights deliberately excluded, sculpting doesn't
-- recolor) marks the atlas fresh; any paint edit makes it stale and
-- consumers fall back to the live vertex mode until the next bake.

-- the atlas image path beside its map: maps/vale.terr -> maps/vale-atlas.png
function M.atlas_path(path)
  return (path:gsub("%.terr$", "") .. "-atlas.png")
end

-- FNV-1a (integer math, bit-stable) over the color inputs
function M.mat_hash(doc)
  local h = 2166136261
  local function feed(s2)
    for i = 1, #s2 do
      h = ((h ~ s2:byte(i)) * 16777619) & 0xFFFFFFFF
    end
  end
  feed(pack("<I4I4", doc.w, doc.h))
  for _, mt in ipairs(doc.mats) do
    feed(mt.name or "")
    feed(pack("<fff", mt.col[1], mt.col[2], mt.col[3]))
    feed(mt.tex or "")
  end
  local n = plane_size(doc)
  for mi = 1, #doc.mats do
    local pl = doc.wts[mi]
    if pl and #pl > 0 then
      feed(pack("<I1", mi))
      for i = 1, n do
        h = ((h ~ (pl[i] or 0)) * 16777619) & 0xFFFFFFFF
      end
    end
  end
  if doc.shade then
    feed("S")
    for i = 1, n do
      h = ((h ~ (doc.shade[i] or 255)) * 16777619) & 0xFFFFFFFF
    end
  end
  if h == 0 then h = 1 end -- 0 means "no atlas"
  return h
end

-- bake a texel RECT [px0..px1]x[py0..py1] (inclusive, atlas px) into an
-- RGBA8 pal.buf laid out doc.w*ts wide — the editor's budgeted live
-- bake (a few rows per frame, no hitch on big maps) and its per-stroke
-- patches both call this; bake_pixels below wraps it for the whole
-- image. samplers[mi] = function(u, v in [0,1) within one tile) ->
-- r,g,b (0..1) for textured materials; absent = the flat color.
function M.bake_into(doc, samplers, ts, buf, px0, py0, px1, py1)
  ts = ts or 16
  local W = doc.w * ts
  local nmat = #doc.mats
  local stride = doc.w + 1
  local wcache = {}
  local function wof(vx, vz)
    local vi = vz * stride + vx + 1
    local wv = wcache[vi]
    if not wv then
      wv = M.weights_at(doc, vi)
      wcache[vi] = wv
    end
    return wv
  end
  local shade = doc.shade
  local function shof(vx, vz)
    if not shade then return 1 end
    return (shade[vz * stride + vx + 1] or 255) / 255
  end
  local char = string.char
  for pz = py0, py1 do
    local tzv = pz // ts
    local fv = (pz % ts + 0.5) / ts
    local row = {}
    for px = px0, px1 do
      local tx = px // ts
      local fu = (px % ts + 0.5) / ts
      local w00, w10 = wof(tx, tzv), wof(tx + 1, tzv)
      local w01, w11 = wof(tx, tzv + 1), wof(tx + 1, tzv + 1)
      local r, g, b = 0, 0, 0
      for mi = 1, nmat do
        local wgt = ((w00[mi] or 0) * (1 - fu) + (w10[mi] or 0) * fu)
                    * (1 - fv)
                  + ((w01[mi] or 0) * (1 - fu) + (w11[mi] or 0) * fu) * fv
        if wgt > 0 then
          local cr, cg, cb
          local sam = samplers and samplers[mi]
          if sam then cr, cg, cb = sam(fu, fv) end
          if not cr then
            local c = doc.mats[mi].col
            cr, cg, cb = c[1], c[2], c[3]
          end
          r = r + cr * wgt
          g = g + cg * wgt
          b = b + cb * wgt
        end
      end
      local sh = (shof(tx, tzv) * (1 - fu) + shof(tx + 1, tzv) * fu)
                 * (1 - fv)
               + (shof(tx, tzv + 1) * (1 - fu) + shof(tx + 1, tzv + 1) * fu)
                 * fv
      row[#row + 1] = char(
        m.clamp((r * sh * 255) // 1, 0, 255),
        m.clamp((g * sh * 255) // 1, 0, 255),
        m.clamp((b * sh * 255) // 1, 0, 255), 255)
    end
    buf:setstr((pz * W + px0) * 4, table.concat(row))
  end
end

-- bake the whole ground: ts texels per tile, RGBA8 string (+ w, h in
-- px) — the save-time atlas publish and the KATs use this form.
function M.bake_pixels(doc, samplers, ts)
  ts = ts or 16
  local W, H = doc.w * ts, doc.h * ts
  local buf = pal.buf(nil, W * H * 4)
  M.bake_into(doc, samplers, ts, buf, 0, 0, W - 1, H - 1)
  return buf:str(0, W * H * 4), W, H
end

-- the water plane (blend segment, drawn after opaque); nil-safe when off
function M.emit_water(out, doc, opts)
  if not doc.water.on then return 0 end
  local wcol = doc.water.col
  return terr.emit_water(out, doc, doc.water.y,
                         { wcol[1], wcol[2], wcol[3] }, doc.water.alpha,
                         opts and opts.step or 8,
                         opts and opts.ox or 0, opts and opts.oz or 0)
end

-- ---- sprite brush stamps (render/dev: the 3d map window's custom
-- brushes — an image dropped on an active brush tool becomes the brush
-- shape; pure math here so the window stays gesture plumbing) ----------

-- build a brush mask from RGBA8 pixel bytes: weight = alpha x luminance
-- (a white shape on transparency is a 1.0 brush; darker paints lighter)
function M.stamp_mask(pix, w, h)
  local mk = { w = w, h = h }
  for i = 0, w * h - 1 do
    local r, g, b, a = pix:byte(i * 4 + 1, i * 4 + 4)
    mk[i + 1] = (a / 255) * (0.299 * r + 0.587 * g + 0.114 * b) / 255
  end
  return mk
end

-- sample a mask for a brush of radius r: the image fits ASPECT-TRUE
-- inside the 2r x 2r brush square centered on the hit, nearest texel,
-- 0 outside. dx/dz = world offset from the brush center.
function M.stamp_at(mk, dx, dz, r)
  local aspect = mk.w / mk.h
  local hw, hh = r, r
  if aspect > 1 then hh = r / aspect else hw = r * aspect end
  local u = (dx + hw) / (2 * hw)
  local v = (dz + hh) / (2 * hh)
  if u < 0 or u >= 1 or v < 0 or v >= 1 then return 0 end
  return mk[math.floor(v * mk.h) * mk.w + math.floor(u * mk.w) + 1] or 0
end

-- ---- placements: rendering + picking (render-class) ----------------------

-- is this path a billboard-able image kind? (.spr draws its baked .png
-- sibling — the map-window rule; EDITOR3D.md §3.1: 2D assets DEFAULT to
-- billboards in a 3D map)
function M.is_image(path)
  local l = path:lower()
  return l:find("%.png$") ~= nil or l:find("%.spr$") ~= nil
end

local function is_mesh(path) return path:lower():find("%.msh$") ~= nil end
local function is_fig(path) return path:lower():find("%.fig$") ~= nil end

-- a deterministic placeholder tint from the path (unresolved meshes/
-- figures render as a recognizable stand-in box, not nothing)
function M.path_col(path)
  local h1 = terr.hash(101, #path, path:byte(1) or 0)
  local h2 = terr.hash(211, path:byte(-1) or 0, #path)
  local h3 = terr.hash(311, path:byte(1) or 0, path:byte(-1) or 0)
  return 0.35 + 0.5 * h1, 0.35 + 0.5 * h2, 0.35 + 0.5 * h3
end

-- the world-space visual size of a prop: billboards are `scale` world
-- units tall, width from the image aspect (dims(path) -> px w, px h;
-- nil = square); everything else is a `scale`-sized stand-in/mesh.
function M.prop_size(p, dims)
  local s = p.scale or 1
  if M.is_image(p.path) then
    local pw, ph = nil, nil
    if dims then pw, ph = dims(p.path) end
    local aspect = (pw and ph and ph > 0) and pw / ph or 1
    return s * aspect, s
  end
  return s, s
end

-- pick/selection volume as a world AABB {x0,y0,z0,x1,y1,z1}
function M.prop_aabb(doc, p, dims)
  local py = M.prop_y(doc, p)
  local s = p.scale or 1
  if p.col and p.col.mode == "box" then
    local b = p.col.box
    return { p.x + b[1] * s, py + b[2] * s, p.z + b[3] * s,
             p.x + b[4] * s, py + b[5] * s, p.z + b[6] * s }
  end
  if M.is_image(p.path) then
    local w, hgt = M.prop_size(p, dims)
    local hw = m.max(w * 0.5, 0.25)
    return { p.x - hw, py, p.z - hw, p.x + hw, py + hgt, p.z + hw }
  end
  local half = m.max(0.35 * s, 0.25)
  return { p.x - half, py, p.z - half, p.x + half, py + 1.0 * s, p.z + half }
end

-- ray {ox,oy,oz,dx,dy,dz} vs AABB slab test -> tmin | nil
function M.ray_aabb(ray, b)
  local t0, t1 = 0, 1e30
  local o = { ray.ox, ray.oy, ray.oz }
  local d = { ray.dx, ray.dy, ray.dz }
  for ax = 1, 3 do
    local lo, hi = b[ax], b[ax + 3]
    if d[ax] == 0 then
      if o[ax] < lo or o[ax] > hi then return nil end
    else
      local ta = (lo - o[ax]) / d[ax]
      local tb = (hi - o[ax]) / d[ax]
      if ta > tb then ta, tb = tb, ta end
      if ta > t0 then t0 = ta end
      if tb < t1 then t1 = tb end
      if t0 > t1 then return nil end
    end
  end
  return t0
end

-- nearest prop under a ray -> index, t | nil
function M.pick_prop(doc, ray, dims)
  local best, bestt
  for i, p in ipairs(doc.props) do
    local t = M.ray_aabb(ray, M.prop_aabb(doc, p, dims))
    if t and (not bestt or t < bestt) then best, bestt = i, t end
  end
  return best, bestt
end

-- emit every placement as draw segments, file order preserved inside
-- each batch: returns { {tex=, flags=, bytes=, ntris=}, ... }.
--   opts.tex(path)  -> texid | nil     (image resolver; nil = stand-in)
--   opts.dims(path) -> px w, px h      (image aspect)
--   opts.mesh(path) -> { doc=, groups= } | nil  (.msh resolver: the
--                     decoded mesh + cm.mesh.bake_groups; nil = stand-in)
--   opts.cam_yaw    = camera yaw (billboards Y-face it)
-- Billboards: upright, feet-anchored, nearest+alphatest (the sprite
-- rule); meshes: pre-lit under the MAP's sun/ambient through the gb
-- baked path (the x_figverts fast lane); stand-ins: a lit box in the
-- path's tint.
function M.emit_props(doc, opts)
  opts = opts or {}
  local segs = {}
  local function seg(tex, flags)
    local s = segs[#segs]
    if not (s and s.tex == tex and s.flags == flags) then
      s = { tex = tex, flags = flags, parts = {}, ntris = 0 }
      segs[#segs + 1] = s
    end
    return s
  end
  local cy = opts.cam_yaw or 0
  local rx, rz = -m.sin(cy), m.cos(cy) -- camera-right on the ground
  local gbm, meshm, m4m, osun, oamb
  if opts.mesh then -- the map's light drives placed meshes (set/restore)
    gbm = cm.require("cm.gb")
    meshm = cm.require("cm.mesh")
    m4m = cm.require("cm.m4")
    osun, oamb = gbm.sun, gbm.ambient
    gbm.sun, gbm.ambient = doc.sun, doc.amb
  end
  for _, p in ipairs(doc.props) do
    local py = M.prop_y(doc, p)
    local texid = M.is_image(p.path) and opts.tex and opts.tex(p.path)
    local mrec = (not texid) and is_mesh(p.path) and opts.mesh
                 and opts.mesh(p.path)
    if mrec then
      local s = p.scale or 1
      local xf = m4m.mul(m4m.translate(p.x, py, p.z),
                         m4m.mul(m4m.roty(p.yaw or 0), m4m.scale(s, s, s)))
      local nxf = m4m.roty(p.yaw or 0)
      local sg = seg(0, 0)
      local tmp = {}
      local nt = meshm.emit(tmp, xf, nxf, mrec.doc, { groups = mrec.groups })
      sg.parts[#sg.parts + 1] = table.concat(tmp)
      sg.ntris = sg.ntris + nt
    elseif texid then
      local w, hgt = M.prop_size(p, opts.dims)
      local hw = w * 0.5
      local x0, z0 = p.x - rx * hw, p.z - rz * hw
      local x1, z1 = p.x + rx * hw, p.z + rz * hw
      local A = vpack("<fffffBBBB", x0, py + hgt, z0, 0, 0, 255, 255, 255, 255)
      local B = vpack("<fffffBBBB", x1, py + hgt, z1, 1, 0, 255, 255, 255, 255)
      local C = vpack("<fffffBBBB", x1, py, z1, 1, 1, 255, 255, 255, 255)
      local D = vpack("<fffffBBBB", x0, py, z0, 0, 1, 255, 255, 255, 255)
      local s = seg(texid, 3) -- ALPHATEST | NEAREST: the sprite rule
      s.parts[#s.parts + 1] = A .. B .. C .. A .. C .. D
      s.ntris = s.ntris + 2
    elseif M.is_image(p.path) or is_mesh(p.path) or is_fig(p.path) then
      -- unresolved image / mesh / figure: the stand-in box
      local r, g, b = M.path_col(p.path)
      local s = p.scale or 1
      local half, top = m.max(0.35 * s, 0.25), 1.0 * s
      local sg = seg(0, 0)
      -- 4 lit walls + roof, simple two-tone shading
      local function face(ax, ay, az, bx, by, bz, cx2, cz2, dxx, dzz, lum)
        local rr = (r * lum * 255) // 1
        local gg = (g * lum * 255) // 1
        local bb = (b * lum * 255) // 1
        local A = vpack("<fffffBBBB", ax, ay, az, 0, 0, rr, gg, bb, 255)
        local B = vpack("<fffffBBBB", bx, by, bz, 1, 0, rr, gg, bb, 255)
        local C = vpack("<fffffBBBB", cx2, by, cz2, 1, 1, rr, gg, bb, 255)
        local D = vpack("<fffffBBBB", dxx, ay, dzz, 0, 1, rr, gg, bb, 255)
        sg.parts[#sg.parts + 1] = A .. B .. C .. A .. C .. D
        sg.ntris = sg.ntris + 2
      end
      local x0, x1 = p.x - half, p.x + half
      local z0, z1 = p.z - half, p.z + half
      local y0, y1 = py, py + top
      face(x0, y0, z0, x0, y1, z0, x1, z0, x1, z0, 0.95) -- north wall
      face(x1, y0, z1, x1, y1, z1, x0, z1, x0, z1, 0.72) -- south wall
      face(x0, y0, z1, x0, y1, z1, x0, z0, x0, z0, 0.60) -- west wall
      face(x1, y0, z0, x1, y1, z0, x1, z1, x1, z1, 0.85) -- east wall
      -- roof
      local rr = (r * 255) // 1
      local gg = (g * 255) // 1
      local bb = (b * 255) // 1
      local A = vpack("<fffffBBBB", x0, y1, z0, 0, 0, rr, gg, bb, 255)
      local B = vpack("<fffffBBBB", x1, y1, z0, 1, 0, rr, gg, bb, 255)
      local C = vpack("<fffffBBBB", x1, y1, z1, 1, 1, rr, gg, bb, 255)
      local D = vpack("<fffffBBBB", x0, y1, z1, 0, 1, rr, gg, bb, 255)
      sg.parts[#sg.parts + 1] = A .. B .. C .. A .. C .. D
      sg.ntris = sg.ntris + 2
    end
    -- non-visual kinds: named refs — no geometry (the editor overlays
    -- a tag; game code fetches by name)
  end
  if gbm then gbm.sun, gbm.ambient = osun, oamb end
  for _, s in ipairs(segs) do
    s.bytes = table.concat(s.parts)
    s.parts = nil
  end
  return segs
end

-- ---- the captured runtime (the cm.map CMRT pattern, verbatim shape) ------

local RT_MAGIC, CUR_MAGIC = "CT3R", "CT3C"
local CUR_BUF = "cm.terr3.current"

local function buf_bytes(name)
  for _, b in ipairs(pal.buf_list()) do
    if b.name == name then return pal.buf(name, b.size):str(0, b.size) end
  end
end

local function put_buf(name, bytes)
  local size
  for _, b in ipairs(pal.buf_list()) do
    if b.name == name then size = b.size break end
  end
  if size and size ~= #bytes then pal.buf_free(name) end
  pal.buf(name, #bytes):setstr(0, bytes)
end

local function runtime_name(name) return name .. ".t3state" end

local function runtime_pack(path, raw)
  return RT_MAGIC .. pack("<I4s4s4", 1, path, raw)
end

local function runtime_unpack(blob)
  if not blob or blob:sub(1, 4) ~= RT_MAGIC then
    error("terr3 runtime: bad CT3R magic", 0)
  end
  local version, path, raw, pos = unpack("<I4s4s4", blob, 5)
  if version ~= 1 then
    error("terr3 runtime: unsupported version " .. version, 0)
  end
  if pos ~= #blob + 1 then error("terr3 runtime: trailing bytes", 0) end
  return path, raw
end

local function current_write(name)
  put_buf(CUR_BUF, CUR_MAGIC .. pack("<I4s4", 1, name))
end

local function current_read()
  local blob = buf_bytes(CUR_BUF)
  if not blob then return nil end
  if blob:sub(1, 4) ~= CUR_MAGIC then error("terr3 current: bad magic", 0) end
  local version, name, pos = unpack("<I4s4", blob, 5)
  if version ~= 1 then
    error("terr3 current: unsupported version " .. version, 0)
  end
  if pos ~= #blob + 1 then error("terr3 current: trailing bytes", 0) end
  return name
end

local function by_names(doc)
  local out = {}
  for _, p in ipairs(doc.props) do
    if p.name and not out[p.name] then out[p.name] = p end
  end
  return out
end

local function set_doc(inst, doc, path, blob)
  inst.doc, inst.path, inst.active = doc, path, true
  inst.by_name = by_names(doc)
  inst._runtime_blob = blob
  inst._restore_rev = state.restore_rev
  inst._doc_hash = state.value_hash(doc)
  inst._dirty = nil
  inst.rev = (inst.rev or 0) + 1
  inst._walk = nil -- derived caches rebuild lazily per generation
  inst._boxes = nil
end

local function runtime_adopt(inst, force)
  local blob = buf_bytes(inst.state_name)
  if not blob then
    inst.active = false
    inst._restore_rev = state.restore_rev
    return nil
  end
  if force or blob ~= inst._runtime_blob then
    local path, raw = runtime_unpack(blob)
    set_doc(inst, M.decode(raw), path, blob)
  end
  return inst
end

local function ensure_slot(name)
  local inst = M._slots[name]
  if not inst then
    inst = { name = name, state_name = runtime_name(name), active = false }
    M._slots[name] = inst
  end
  return inst
end

local function refresh_doc(inst)
  if not inst or not inst.active then return nil end
  local h = state.value_hash(inst.doc)
  if h ~= inst._doc_hash then
    inst._doc_hash = h
    inst._dirty = true
    inst.by_name = by_names(inst.doc)
    inst.rev = (inst.rev or 0) + 1
    inst._walk, inst._boxes = nil, nil
  end
  return inst
end

function M.sync(inst)
  inst = inst or M.cur
  if not inst then return nil end
  if inst._restore_rev ~= state.restore_rev
     and not runtime_adopt(inst, true) then return nil end
  if not inst.active then return nil end
  return refresh_doc(inst)
end

local function capture_inst(inst)
  if not refresh_doc(inst) or not inst._dirty then return end
  local blob = runtime_pack(inst.path, M.encode(inst.doc))
  if blob ~= inst._runtime_blob then put_buf(inst.state_name, blob) end
  inst._runtime_blob, inst._dirty = blob, nil
end

local function capture_all()
  local names = {}
  for name in pairs(M._slots) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do capture_inst(M._slots[name]) end
  if M.cur and M.cur.active then current_write(M.cur.name) end
end

local function restore_all()
  local names, seen = {}, {}
  for name in pairs(M._slots) do
    names[#names + 1], seen[name] = name, true
  end
  for _, b in ipairs(pal.buf_list()) do
    local name = b.name:match("^(.*)%.t3state$")
    if name and name ~= "" and not seen[name] and b.size >= 4
       and pal.buf(b.name, b.size):str(0, 4) == RT_MAGIC then
      ensure_slot(name)
      names[#names + 1], seen[name] = name, true
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do runtime_adopt(M._slots[name], true) end
  local cur = current_read()
  M.cur = cur and M._slots[cur] or nil
  if cur and not M.cur then
    error("terr3 current: captured slot is missing: " .. cur, 0)
  end
end

state.participate("cm.terr3", { capture = capture_all, restore = restore_all })

-- use{ path=, name= [, fresh=true] } — instance a 3D map into a stable
-- named slot; captured state for the same path adopts (snapshot/rewind/
-- reload idempotence), fresh=true resets to disk.
function M.use(o)
  local name = o.name or error("terr3.use: name", 2)
  if name == CUR_BUF or name:sub(-8) == ".t3state" then
    error("terr3.use: reserved slot name " .. name, 2)
  end
  local inst = ensure_slot(name)
  local captured = buf_bytes(inst.state_name)
  if captured and not o.fresh then
    local path = runtime_unpack(captured)
    if path == o.path then
      runtime_adopt(inst, false)
      M.cur = inst
      current_write(name)
      return inst
    end
  end
  local bytes = pal.read_file(o.path)
  if not bytes then error("terr3.use: no file " .. tostring(o.path), 2) end
  local doc = M.decode(bytes)
  local blob = runtime_pack(o.path, M.encode(doc))
  put_buf(inst.state_name, blob)
  set_doc(inst, doc, o.path, blob)
  M.cur = inst
  current_write(name)
  return inst
end

function M.current() return M.sync(M.cur) end

-- the editor's hot-reload door (recorded EVAL, the cm.map.reload twin):
-- every active slot on this path re-reads disk and republishes
function M.reload(path)
  local names = {}
  for name in pairs(M._slots) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local inst = M._slots[name]
    if inst.active and inst.path == path then
      M.use{ path = path, name = name, fresh = true }
    end
  end
end

-- instance-level readers (cached per doc generation)
function M.inst_walk(inst)
  inst = M.sync(inst)
  if not inst then return nil end
  if not inst._walk then
    local grid, gw, gh = M.walk_grid(inst.doc)
    inst._walk = { grid = grid, gw = gw, gh = gh }
  end
  return inst._walk
end

function M.walkable(inst, cx, cz)
  local wg = M.inst_walk(inst)
  if not wg then return false end
  if cx < 0 or cz < 0 or cx >= wg.gw or cz >= wg.gh then return false end
  return wg.grid:byte(cz * wg.gw + cx + 1) == 1
end

function M.inst_boxes(inst)
  inst = M.sync(inst)
  if not inst then return {} end
  if not inst._boxes then inst._boxes = M.boxes(inst.doc) end
  return inst._boxes
end

-- the named-prop handle (cm.map.get's twin): the placement table itself;
-- cm.state flushes direct mutations at every capture boundary
function M.get(name)
  local inst = M.sync(M.cur)
  if not inst then return nil end
  return inst.by_name[name]
end

function M.release(which)
  local inst = type(which) == "table" and which or M._slots[which]
  if not inst or M._slots[inst.name] ~= inst then return false end
  M._slots[inst.name] = nil
  inst.active = false
  pal.buf_free(inst.state_name)
  if M.cur == inst then
    M.cur = nil
    pal.buf_free(CUR_BUF)
  end
  return true
end

return M
