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
local floor = math.floor
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

-- the map-editor hot-reload entry (MAPS.md §9): re-decode the saved file
-- into the LIVE instance in place — cur.doc replaced, the collider buffer
-- rebuilt through the same wrapper (held references stay live), by_name
-- and the fill cache refreshed. Runs as a recorded EVAL (Ctrl+S in the map
-- window submits it), so traces replay the change and rewind scrubs across
-- it. A path that isn't the live map no-ops with a log.
function M.reload(path)
  local cur = M.cur
  if not (cur and cur.path == path) then
    pal.log("[map] reload ignored (not the live map): " .. tostring(path))
    return false
  end
  local bytes = pal.read_file(path)
  if not bytes then
    pal.log("[map] reload FAILED (unreadable): " .. path)
    return false
  end
  local ok, doc = pcall(M.decode, bytes)
  if not ok then
    pal.log("[map] reload FAILED (bad CMAP): " .. tostring(doc))
    return false
  end
  local cols = {}
  for _, c in ipairs(doc.colliders) do to_world(c, 0, 0, cols) end
  for _, p in ipairs(doc.places) do
    for _, c in ipairs(p.cols or {}) do to_world(c, p.x, p.y, cols) end
  end
  collide.rebuild(cur.world, { name = cur.name, w = doc.w, h = doc.h,
                               colliders = cols })
  cur.doc = doc
  cur.by_name = {}
  for _, p in ipairs(doc.places) do
    if p.name and not cur.by_name[p.name] then cur.by_name[p.name] = p end
  end
  cur._fill = nil
  cur._ptex = nil
  cur._ptm = nil
  pal.log("[map] reloaded " .. path)
  return true
end

-- ---- the graybox fill (render-only; MAPS.md §5, D057b) ----
--
-- Draw the collider layer directly: closed solid chains (and quads) as
-- flat untextured polygons — per-column even-odd strips at x+0.5, merged
-- into runs where the column signature repeats, so flat terrain costs a
-- handful of quads and slopes step per pixel — one-ways as slim slabs,
-- open solid lines as 2 px strokes. This IS the graybox look until art
-- placements take over. Draw under gfx.layer(1) (world coords). Circles
-- are the game's to draw (hazard visuals are gameplay).

local FILL = { 0.36, 0.34, 0.32 }  -- flat solid gray
local LIP = { 0.46, 0.44, 0.41 }   -- 1px top lip
local ONEWAY = { 0.42, 0.78, 0.62 }-- the accent slab

-- the fill geometry of a decoded doc (pure — the map window draws the
-- same shapes): closed solids as loops, one-ways as slab segments, open
-- solids as stroke segments; attached colliders offset by their placement.
function M.geom(doc)
  local loops, slabs, lines = {}, {}, {}
  local function take(c, ox, oy)
    if c.kind == "circle" then return end
    local v
    if c.kind == "quad" then
      v = { c.x + ox, c.y + oy, c.x + c.w + ox, c.y + oy,
            c.x + c.w + ox, c.y + c.h + oy, c.x + ox, c.y + c.h + oy }
    else
      v = {}
      for i = 1, #c.verts, 2 do
        v[i], v[i + 1] = c.verts[i] + ox, c.verts[i + 1] + oy
      end
    end
    if c.oneway then
      for i = 1, #v - 3, 2 do
        slabs[#slabs + 1] = { v[i], v[i + 1], v[i + 2], v[i + 3] }
      end
    elseif (c.kind == "quad" or c.closed) and #v >= 6 then
      loops[#loops + 1] = v
    else
      for i = 1, #v - 3, 2 do
        lines[#lines + 1] = { v[i], v[i + 1], v[i + 2], v[i + 3] }
      end
    end
  end
  for _, c in ipairs(doc.colliders) do take(c, 0, 0) end
  for _, p in ipairs(doc.places) do
    for _, c in ipairs(p.cols or {}) do take(c, p.x, p.y) end
  end
  return { loops = loops, slabs = slabs, lines = lines }
end

local function fill_geom(inst) -- lazy per-instance cache (render plumbing)
  if not inst._fill then inst._fill = M.geom(inst.doc) end
  return inst._fill
end

-- column signature: even-odd intervals of all loops at cx, unioned
-- (exported: the map window's strip fill samples the same function)
function M.column_ivs(loops, cx, out)
  local n = 0
  for li = 1, #loops do
    local v = loops[li]
    local ys, m2 = {}, 0
    local nv = #v // 2
    local jx, jy = v[nv * 2 - 1], v[nv * 2]
    for i = 1, nv do
      local ix, iy = v[i * 2 - 1], v[i * 2]
      if (ix > cx) ~= (jx > cx) then
        m2 = m2 + 1
        ys[m2] = iy + (jy - iy) * ((cx - ix) / (jx - ix))
      end
      jx, jy = ix, iy
    end
    if m2 > 1 then
      table.sort(ys)
      for i = 1, m2 - 1, 2 do
        n = n + 1
        out[n * 2 - 1], out[n * 2] = ys[i], ys[i + 1]
      end
    end
  end
  -- union (few intervals: insertion-merge)
  local ivs = {}
  for i = 1, n do
    local a, b = out[i * 2 - 1], out[i * 2]
    local merged = false
    for j = 1, #ivs, 2 do
      if a <= ivs[j + 1] and b >= ivs[j] then
        if a < ivs[j] then ivs[j] = a end
        if b > ivs[j + 1] then ivs[j + 1] = b end
        merged = true
        break
      end
    end
    if not merged then
      ivs[#ivs + 1], ivs[#ivs + 2] = a, b
    end
  end
  return ivs
end

-- draw the fill for the visible range (call with gfx.layer(1) active).
-- Everything culls to the camera window like TM:draw did — quads never
-- leave the viewport (the capture path drops negative-origin quads).
function M.draw_fill(inst, camx, camy)
  local geom = fill_geom(inst)
  local vw, vh = pal.gfx_size()
  local X0 = floor(camx)
  local X1 = math.ceil(camx + vw)
  if X0 < 0 then X0 = 0 end
  if X1 > inst.doc.w then X1 = inst.doc.w end
  local Y0 = floor(camy)
  local Y1 = math.ceil(camy + vh)

  -- solids: column strips, run-merged on the interval signature
  local scratch = {}
  local run_x, run_sig, run_ivs
  local function flush(xe)
    if not run_ivs then return end
    for j = 1, #run_ivs, 2 do
      local a, b = floor(run_ivs[j]), floor(run_ivs[j + 1] + 0.5)
      local a2 = a > Y0 and a or Y0
      local b2 = b < Y1 and b or Y1
      if b2 > a2 then
        pal.quad(run_x, a2, xe - run_x, b2 - a2, FILL[1], FILL[2], FILL[3], 1)
        if a2 == a then -- the 1px top lip, only when the top is in view
          pal.quad(run_x, a, xe - run_x, 1, LIP[1], LIP[2], LIP[3], 1)
        end
      end
    end
  end
  for cx = X0, X1 - 1 do
    local ivs = M.column_ivs(geom.loops, cx + 0.5, scratch)
    local sig = table.concat(ivs, ",")
    if sig ~= run_sig then
      flush(cx)
      run_x, run_sig, run_ivs = cx, sig, ivs
    end
  end
  flush(X1)

  -- one-way slabs: 3px under the line, run-merged per segment
  for _, sgm in ipairs(geom.slabs) do
    local ax, ay, bx, by = sgm[1], sgm[2], sgm[3], sgm[4]
    if ax > bx then ax, ay, bx, by = bx, by, ax, ay end
    local x0 = ax > X0 and ax or X0
    local x1 = bx < X1 and bx or X1
    if x0 < x1 then
      local function slab(sx, sy2, sw)
        if sy2 + 3 > Y0 and sy2 < Y1 then
          pal.quad(sx, sy2, sw, 3, ONEWAY[1], ONEWAY[2], ONEWAY[3], 1)
        end
      end
      if ay == by then
        slab(x0, ay, x1 - x0)
      else
        local rx, ry
        for cx = x0, x1 - 1 do
          local yy = floor(ay + (by - ay) * ((cx + 0.5 - ax) / (bx - ax)))
          if yy ~= ry then
            if rx then slab(rx, ry, cx - rx) end
            rx, ry = cx, yy
          end
        end
        if rx then slab(rx, ry, x1 - rx) end
      end
    end
  end

  -- open solid lines: 2px strokes along the dominant axis
  for _, sgm in ipairs(geom.lines) do
    local ax, ay, bx, by = sgm[1], sgm[2], sgm[3], sgm[4]
    local adx = bx > ax and bx - ax or ax - bx
    local ady = by > ay and by - ay or ay - by
    if adx >= ady then
      if ax > bx then ax, ay, bx, by = bx, by, ax, ay end
      local x0 = ax > X0 and ax or X0
      local x1 = bx < X1 and bx or X1
      for cx = x0, x1 - 1 do
        local yy = floor(ay + (by - ay) * ((cx + 0.5 - ax) / (bx - ax)))
        if yy + 2 > Y0 and yy < Y1 then
          pal.quad(cx, yy, 1, 2, FILL[1], FILL[2], FILL[3], 1)
        end
      end
    else
      if ay > by then ax, ay, bx, by = bx, by, ax, ay end
      local y0 = ay > Y0 and ay or Y0
      local y1 = by < Y1 and by or Y1
      for cy = y0, y1 - 1 do
        local xx = floor(ax + (bx - ax) * ((cy + 0.5 - ay) / (by - ay)))
        if xx + 2 > X0 and xx < X1 then
          pal.quad(xx, cy, 2, 1, FILL[1], FILL[2], FILL[3], 1)
        end
      end
    end
  end
end

-- ---- placements (render-only; MAPS.md §5) ----

-- the render size + image of a placement (nil image = nothing to draw).
-- .png draws directly; .spr draws its baked .png sibling; .tm draws its
-- cell grid from the tileset strip (R8d, below). Textures memoize in
-- cm.gfx keyed by full path; a missing or unreadable file logs once per
-- instance and skips.
local function place_tex(inst, p)
  inst._ptex = inst._ptex or {}
  local hit = inst._ptex[p.path]
  if hit ~= nil then return hit or nil end
  local target
  if p.path:lower():find("%.png$") then target = p.path
  elseif p.path:lower():find("%.spr$") then
    target = p.path:gsub("%.spr$", ".png")
  end
  local t = false
  if target then
    local root = (cm.main and cm.main.args and cm.main.args.project) or "."
    local ok, tex = pcall(cm.require("cm.gfx").texture, root .. "/" .. target)
    if ok then t = tex
    else pal.log("[map] placement image unreadable: " .. p.path) end
  end
  inst._ptex[p.path] = t
  return t or nil
end

-- a .tm placement's decoded doc + tileset strip texture (render plumbing,
-- keyed by path; cm.asset_epoch invalidates — a tilemap-window save shows
-- live, the sprite-save convention). false caches a failure (log once).
local function place_tm(inst, p)
  inst._ptm = inst._ptm or {}
  local ep = cm.asset_epoch or 0
  local rec = inst._ptm[p.path]
  if rec ~= nil and (rec == false or rec.ep == ep) then
    return rec or nil
  end
  local root = (cm.main and cm.main.args and cm.main.args.project) or "."
  local bytes = pal.read_file(root .. "/" .. p.path)
  local ok, doc = false, nil
  if bytes then
    ok, doc = pcall(cm.require("cm.tmap").decode, bytes)
  end
  local tex
  if ok and doc.tileset ~= "" then
    local png = doc.tileset:gsub("%.spr$", ".png")
    local okt, t = pcall(cm.require("cm.gfx").texture, root .. "/" .. png,
                         rec and true or nil)
    if okt then tex = t end
  end
  if not (ok and tex) then
    pal.log("[map] .tm placement unrenderable: " .. p.path)
    inst._ptm[p.path] = false
    return nil
  end
  rec = { ep = ep, doc = doc, tex = tex }
  inst._ptm[p.path] = rec
  return rec
end

-- draw the placements in file order (= z order) with gfx.layer(1) active,
-- camera-culled; flip_x mirrors via swapped u. Art stacks on top of the
-- collider fill until a per-map flag turns the fill off (§5).
function M.draw_places(inst, camx, camy)
  local vw, vh = pal.gfx_size()
  local tmap
  for _, p in ipairs(inst.doc.places) do
    if not p.hidden then
      if p.path:lower():find("%.tm$") then
        local rec = place_tm(inst, p)
        if rec then -- tmap.draw culls per cell; flip is a no-op for grids
          tmap = tmap or cm.require("cm.tmap")
          tmap.draw(rec.doc, rec.tex, p.x, p.y, camx, camy)
        end
      else
        local t = place_tex(inst, p)
        if t then
          if p.x < camx + vw and p.x + t.w > camx
             and p.y < camy + vh and p.y + t.h > camy then
            local u0, u1 = 0, 1
            if p.flip then u0, u1 = 1, 0 end
            pal.quad(p.x, p.y, t.w, t.h, 1, 1, 1, 1, t.id, u0, 0, u1, 1)
          end
        end
      end
    end
  end
end

return M
