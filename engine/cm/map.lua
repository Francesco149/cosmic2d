-- cm.map — the .map asset (MAPS.md §2, D057/a/b): a CMAP chunk container
-- holding the three map layers — free colliders (sim truth), freehand
-- placements (render-only; file order = z; optional name for code
-- addressing; 0..n attached colliders riding the placement), and markers
-- (rects + kind/label/extras — spawn/portals/props). Codec is pure and
-- canonical (encode(decode(b)) == b); cm.chunk gives skip-tolerance.
--
--   HEAD v1: <i4 w> <i4 h> <I4 grid px> <f f f bg tint> <s4 name>
--   COLL v1: one free collider (col_pack below)
--   PLCE v1: <I1 layer> <I4 flags bit0 flip_x> <i4 x> <i4 y> <s4 path>
--            <s4 name> <I2 ncols> ncols * col_pack
--   MRKR v1: <i4 x y w h> <s4 kind> <s4 label> <s4 note> <I2 n> n*(s4 k, s4 v)
--   TAIL v1: empty
--
-- collider (col_pack): <I1 kind 0 chain | 1 quad | 2 circle>
--   <I1 flags bit0 oneway, bit1 closed> then chain <I2 n> n*(i4 x, i4 y) |
--   quad <i4 x y w h> | circle <i4 cx cy r>. Quads become closed 4-vert
--   chains at world build; circles stay overlap colliders (cm.collide).
--
-- M.use{ path=, name= } instances a decoded map into the live sim: the
-- collider buffer (free colliders + every placement's attached colliders
-- offset by its position) via cm.collide.build, plus plain render/logic
-- tables. Placements are render-only state — M.get(name) hands game code
-- the placement table itself (move a door, blink a sign: camera-class
-- mutations); driving a collider-carrying placement is the R7b dynamic-
-- body slot, not this.

local M = select(2, ...) or {}

local chunk = cm.require("cm.chunk")
local collide = cm.require("cm.collide")

local pack, unpack = string.pack, string.unpack
local MAGIC = "CMAP"

-- ---- collider pack/unpack (shared by COLL and PLCE) ----

local KIND = { chain = 0, quad = 1, circle = 2 }
local KIND_R = { [0] = "chain", "quad", "circle" }

local function col_pack(c)
  local k = KIND[c.kind] or error("map: bad collider kind " .. tostring(c.kind))
  local head = pack("<I1I1", k, (c.oneway and 1 or 0) | (c.closed and 2 or 0))
  if k == 0 then
    local n = #c.verts // 2
    local parts = { head, pack("<I2", n) }
    for i = 1, n * 2 do parts[#parts + 1] = pack("<i4", c.verts[i]) end
    return table.concat(parts)
  elseif k == 1 then
    return head .. pack("<i4i4i4i4", c.x, c.y, c.w, c.h)
  end
  return head .. pack("<i4i4i4", c.cx, c.cy, c.r)
end

local function col_unpack(b, pos)
  local k, flags
  k, flags, pos = unpack("<I1I1", b, pos)
  local c = { kind = KIND_R[k] or error("map: unknown collider kind " .. k),
              oneway = flags & 1 ~= 0, closed = flags & 2 ~= 0 }
  if k == 0 then
    local n
    n, pos = unpack("<I2", b, pos)
    c.verts = {}
    for i = 1, n * 2 do c.verts[i], pos = unpack("<i4", b, pos) end
  elseif k == 1 then
    c.x, c.y, c.w, c.h, pos = unpack("<i4i4i4i4", b, pos)
  else
    c.cx, c.cy, c.r, pos = unpack("<i4i4i4", b, pos)
  end
  return c, pos
end

-- ---- codec ----

-- doc = { name=, w=, h=, grid=, bg = {r,g,b}, colliders = {c...},
--         places = { {path=, x=, y=, layer=, flip=, name=, cols={c...}} },
--         markers = { {x=,y=,w=,h=, kind=, label=, note=,
--                      extras = { {k=,v=}, ... }} } }
function M.encode(doc)
  local w = chunk.writer(MAGIC)
  local bg = doc.bg or { 1, 1, 1 }
  w.chunk("HEAD", 1, pack("<i4i4I4fffs4", doc.w, doc.h, doc.grid or 8,
                          bg[1], bg[2], bg[3], doc.name or ""))
  for _, c in ipairs(doc.colliders or {}) do
    w.chunk("COLL", 1, col_pack(c))
  end
  for _, p in ipairs(doc.places or {}) do
    local parts = { pack("<I1I4i4i4s4s4I2", p.layer or 0,
                         p.flip and 1 or 0, p.x, p.y, p.path,
                         p.name or "", #(p.cols or {})) }
    for _, c in ipairs(p.cols or {}) do parts[#parts + 1] = col_pack(c) end
    w.chunk("PLCE", 1, table.concat(parts))
  end
  for _, mk in ipairs(doc.markers or {}) do
    local parts = { pack("<i4i4i4i4s4s4s4I2", mk.x, mk.y, mk.w, mk.h,
                         mk.kind, mk.label or "", mk.note or "",
                         #(mk.extras or {})) }
    for _, e in ipairs(mk.extras or {}) do
      parts[#parts + 1] = pack("<s4s4", e.k, e.v)
    end
    w.chunk("MRKR", 1, table.concat(parts))
  end
  w.chunk("TAIL", 1, "")
  return w.result()
end

function M.decode(bytes)
  local doc = { colliders = {}, places = {}, markers = {} }
  local seen_head, seen_tail
  for _, c in ipairs(chunk.read(bytes, MAGIC)) do
    if c.tag == "HEAD" and c.version == 1 then
      local r, g, b
      doc.w, doc.h, doc.grid, r, g, b, doc.name = unpack("<i4i4I4fffs4",
                                                         c.payload)
      doc.bg = { r, g, b }
      seen_head = true
    elseif c.tag == "COLL" and c.version == 1 then
      doc.colliders[#doc.colliders + 1] = col_unpack(c.payload, 1)
    elseif c.tag == "PLCE" and c.version == 1 then
      local p, pos = {}, 1
      local layer, flags
      layer, flags, p.x, p.y, p.path, p.name, pos =
        unpack("<I1I4i4i4s4s4", c.payload, pos)
      p.layer, p.flip = layer, flags & 1 ~= 0
      if p.name == "" then p.name = nil end
      local n
      n, pos = unpack("<I2", c.payload, pos)
      p.cols = {}
      for i = 1, n do p.cols[i], pos = col_unpack(c.payload, pos) end
      if #p.cols == 0 then p.cols = nil end
      doc.places[#doc.places + 1] = p
    elseif c.tag == "MRKR" and c.version == 1 then
      local mk, pos = {}, 1
      local n
      mk.x, mk.y, mk.w, mk.h, mk.kind, mk.label, mk.note, n, pos =
        unpack("<i4i4i4i4s4s4s4I2", c.payload, pos)
      mk.extras = {}
      for _ = 1, n do
        local k, v
        k, v, pos = unpack("<s4s4", c.payload, pos)
        mk.extras[#mk.extras + 1] = { k = k, v = v }
      end
      if #mk.extras == 0 then mk.extras = nil end
      doc.markers[#doc.markers + 1] = mk
    elseif c.tag == "TAIL" then
      seen_tail = true
    end -- unknown tags/versions skip (chunk contract)
  end
  if not seen_head then error("map: no HEAD chunk", 0) end
  if not seen_tail then error("map: no TAIL chunk (truncated?)", 0) end
  return doc
end

-- marker extras as a flat k->v table (last write wins, queries only)
function M.extras(mk)
  local t = {}
  for _, e in ipairs(mk.extras or {}) do t[e.k] = e.v end
  return t
end

-- ---- instancing (the level.lua successor's core) ----

local function to_world(c, ox, oy, out)
  if c.kind == "circle" then
    out[#out + 1] = { kind = "circle", cx = c.cx + ox, cy = c.cy + oy,
                      r = c.r }
  elseif c.kind == "quad" then
    local x, y = c.x + ox, c.y + oy
    out[#out + 1] = { kind = "chain", oneway = c.oneway, closed = true,
                      verts = { x, y, x + c.w, y, x + c.w, y + c.h,
                                x, y + c.h } }
  else
    local v = {}
    for i = 1, #c.verts, 2 do
      v[i], v[i + 1] = c.verts[i] + ox, c.verts[i + 1] + oy
    end
    out[#out + 1] = { kind = "chain", oneway = c.oneway, closed = c.closed,
                      verts = v }
  end
end

-- use{ path=, name= } — decode the file and instance it: the collider
-- buffer (named `name`, via cm.collide.build) + the doc. Returns
-- { doc=, world=, by_name= }. File reads are load-time content (like
-- sprites); live re-use rides the recorded hot-reload path (MAPS.md §9).
function M.use(o)
  local bytes = pal.read_file(o.path)
  if not bytes then error("map.use: no file " .. tostring(o.path), 2) end
  local doc = M.decode(bytes)
  local cols = {}
  for _, c in ipairs(doc.colliders) do to_world(c, 0, 0, cols) end
  for _, p in ipairs(doc.places) do
    for _, c in ipairs(p.cols or {}) do to_world(c, p.x, p.y, cols) end
  end
  local world = collide.build{ name = o.name or error("map.use: name", 2),
                               w = doc.w, h = doc.h, colliders = cols }
  local by_name = {}
  for _, p in ipairs(doc.places) do
    if p.name and not by_name[p.name] then by_name[p.name] = p end
  end
  M.cur = { doc = doc, world = world, by_name = by_name, path = o.path,
            name = o.name }
  return M.cur
end

-- the named-placement handle (D057b): the placement table itself —
-- mutate x/y/hidden freely, it is render-only state (like the camera).
function M.get(name)
  return M.cur and M.cur.by_name[name] or nil
end

return M
