-- cm.map — the .map asset (MAPS.md §2, D057/a/b): a CMAP chunk container
-- holding the map's parts — free colliders (sim truth), freehand
-- placements (render-only; grouped onto named LAYERS; optional name for
-- code addressing; 0..n attached colliders riding the placement), and
-- markers (rects + kind/label/extras — spawn/portals/props). Codec is
-- pure and canonical (encode(decode(b)) == b); cm.chunk gives
-- skip-tolerance.
--
--   HEAD v1: <i4 w> <i4 h> <I4 grid px> <f f f bg tint> <s4 name>
--   FLGS v1 (optional, only when nonzero): <I4 bit0 nofill — the in-game
--            collider fill is off; art placements own the visuals (§5)>
--   LAYR v1: <I2 n> n * ( <I1 flags bit0 vis(editor), bit1 on(game)>
--            <s4 name> ) — the named layers, in z order (back → front).
--            Absent = one default layer {name="main", vis=on=true} that
--            all placements fall onto (old maps upgrade transparently).
--   COLL v1: one free collider (col_pack below) — layer-independent
--            (level geometry; attached colliders on placements follow
--            their placement's layer instead)
--   PLCE v2: <I1 layer 0-based idx into LAYR> <I4 flags bit0 flip_x,
--            bit1 novis (image suppressed → a named ref)> <i4 x> <i4 y>
--            <s4 path> <s4 name> <s4 anim (clip to auto-play, "" = none)>
--            <I2 ncols> ncols * col_pack
--   PLCE v1 (legacy read): ... same but no <s4 anim>, bit1 = hidden
--            (mapped to novis); layer treated as the single default.
--   MRKR v1: <i4 x y w h> <s4 kind> <s4 label> <s4 note> <I2 n> n*(s4 k, s4 v)
--   TAIL v1: empty
--
-- collider (col_pack): <I1 kind 0 chain | 1 quad | 2 circle>
--   <I1 flags bit0 oneway, bit1 closed> then chain <I2 n> n*(i4 x, i4 y) |
--   quad <i4 x y w h> | circle <i4 cx cy r>. Quads become closed 4-vert
--   chains at world build; circles stay overlap colliders (cm.collide).
--
-- Any asset kind can be placed. Visual kinds (.spr/.png/.tm) render their
-- image; every other kind (.ins/.song/.pal/...) — or a visual one with
-- novis set — is a NAMED REFERENCE: no image, a code-addressable handle
-- at a position (M.ref). A dangling path gracefully falls back to a
-- built-in placeholder (M.ref / the editor's checkerboard) with a warning.
--
-- Layers gate BOTH sides: layer.on=false makes the layer's placements act
-- as if they don't exist in-game (no draw, no attached colliders, no ref)
-- — prototype overlays toggle here; layer.vis is an editor-only render
-- toggle (declutter without changing the game).
--
-- M.use{ path=, name= } instances a decoded map into the live sim: the
-- collider buffer (free colliders + every ENABLED placement's attached
-- colliders offset by its position) via cm.collide.build, plus plain
-- render/logic tables. Placements are render-only state — M.get(name)
-- hands game code the placement table itself (move a door, blink a sign:
-- camera-class mutations); driving a collider-carrying placement is the
-- R7b dynamic-body slot, not this.

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

-- ---- layers ----

-- the default single layer an old / layerless map falls onto. Kept
-- canonical: a doc whose layers are exactly this one still writes a LAYR
-- chunk (the feature is first-class), but a decoded layerless map
-- synthesizes it so `doc.layers` is ALWAYS present + 1-based.
function M.default_layers()
  return { { name = "main", vis = true, on = true } }
end

-- clamp a placement's layer index into range (1-based); layerless / bad
-- indices collapse onto layer 1. Called after decode once layers settle.
local function clamp_layers(doc)
  if not doc.layers or #doc.layers == 0 then
    doc.layers = M.default_layers()
  end
  local n = #doc.layers
  for _, p in ipairs(doc.places or {}) do
    local L = p.layer or 1
    if L < 1 then L = 1 elseif L > n then L = n end
    p.layer = L
  end
end
M.clamp_layers = clamp_layers

-- is a placement's layer live in-game? (on=false = "doesn't exist"). A
-- missing layers table / index is treated as enabled (fail-open).
local function place_on(doc, p)
  local L = doc.layers and doc.layers[p.layer or 1]
  return not L or L.on ~= false
end
M.place_on = place_on

-- placement draw order: layers back-to-front, insertion order within a
-- layer. Returns original indices (the editor selection keys on them), so
-- both banks draw the same z without renumbering places. Deterministic: a
-- total order (index tiebreak), no hash dependence.
function M.z_order(doc)
  local idx = {}
  local places = doc.places or {}
  for i = 1, #places do idx[i] = i end
  table.sort(idx, function(a, b)
    local la, lb = places[a].layer or 1, places[b].layer or 1
    if la ~= lb then return la < lb end
    return a < b
  end)
  return idx
end

-- ---- codec ----

-- doc = { name=, w=, h=, grid=, bg = {r,g,b}, nofill=,
--         layers = { {name=, vis=bool, on=bool}, ... },  -- 1-based, z order
--         colliders = {c...},
--         places = { {path=, x=, y=, layer=idx, flip=, vis=bool,
--                     name=, anim=, cols={c...}} },
--         markers = { {x=,y=,w=,h=, kind=, label=, note=,
--                      extras = { {k=,v=}, ... }} } }
function M.encode(doc)
  local w = chunk.writer(MAGIC)
  local bg = doc.bg or { 1, 1, 1 }
  w.chunk("HEAD", 1, pack("<i4i4I4fffs4", doc.w, doc.h, doc.grid or 8,
                          bg[1], bg[2], bg[3], doc.name or ""))
  -- FLGS (optional, written only when set — canonical: absent == 0):
  -- bit0 nofill = the in-game collider fill is OFF for this map (§5's
  -- per-map switch: art placements have taken over the visuals)
  if doc.nofill then w.chunk("FLGS", 1, pack("<I4", 1)) end
  local layers = doc.layers or M.default_layers()
  local lp = { pack("<I2", #layers) }
  for _, L in ipairs(layers) do
    lp[#lp + 1] = pack("<I1s4",
      ((L.vis ~= false) and 1 or 0) | ((L.on ~= false) and 2 or 0),
      L.name or "")
  end
  w.chunk("LAYR", 1, table.concat(lp))
  for _, c in ipairs(doc.colliders or {}) do
    w.chunk("COLL", 1, col_pack(c))
  end
  for _, p in ipairs(doc.places or {}) do
    -- 1-based index -> disk 0-based, clamped into the layer range (a bad
    -- / legacy index can never overflow the u8 or dangle). v3 adds `gid`
    -- (0 = ungrouped) — a teidraw group tag (D061).
    local li = math.max(1, math.min(#layers, p.layer or 1)) - 1
    local parts = { pack("<I1I4i4i4s4s4s4I4I2", li,
                         (p.flip and 1 or 0) | ((p.vis == false) and 2 or 0),
                         p.x, p.y, p.path,
                         p.name or "", p.anim or "", p.gid or 0,
                         #(p.cols or {})) }
    for _, c in ipairs(p.cols or {}) do parts[#parts + 1] = col_pack(c) end
    w.chunk("PLCE", 3, table.concat(parts))
  end
  for _, mk in ipairs(doc.markers or {}) do
    -- v2 adds `gid` (0 = ungrouped) before the extras count
    local parts = { pack("<i4i4i4i4s4s4s4I4I2", mk.x, mk.y, mk.w, mk.h,
                         mk.kind, mk.label or "", mk.note or "",
                         mk.gid or 0, #(mk.extras or {})) }
    for _, e in ipairs(mk.extras or {}) do
      parts[#parts + 1] = pack("<s4s4", e.k, e.v)
    end
    w.chunk("MRKR", 2, table.concat(parts))
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
    elseif c.tag == "FLGS" and c.version == 1 then
      local fl = unpack("<I4", c.payload)
      doc.nofill = fl & 1 ~= 0 or nil
    elseif c.tag == "LAYR" and c.version == 1 then
      local n, pos = unpack("<I2", c.payload, 1)
      doc.layers = {}
      for _ = 1, n do
        local flags, name
        flags, name, pos = unpack("<I1s4", c.payload, pos)
        doc.layers[#doc.layers + 1] =
          { name = name, vis = flags & 1 ~= 0, on = flags & 2 ~= 0 }
      end
    elseif c.tag == "COLL" and c.version == 1 then
      doc.colliders[#doc.colliders + 1] = col_unpack(c.payload, 1)
    elseif c.tag == "PLCE" and c.version >= 1 and c.version <= 3 then
      local p, pos = {}, 1
      local layer, flags
      layer, flags, p.x, p.y, p.path, p.name, pos =
        unpack("<I1I4i4i4s4s4", c.payload, pos)
      if c.version >= 2 then p.anim, pos = unpack("<s4", c.payload, pos) end
      if c.version >= 3 then -- v3: the teidraw group tag (0 = ungrouped)
        local gid; gid, pos = unpack("<I4", c.payload, pos)
        p.gid = gid ~= 0 and gid or nil
      end
      p.layer = layer + 1 -- disk 0-based -> Lua 1-based (clamped below)
      p.flip = flags & 1 ~= 0
      p.vis = flags & 2 == 0 -- bit1 = novis (v1: hidden) -> vis=false
      if p.name == "" then p.name = nil end
      if p.anim == "" then p.anim = nil end
      local n
      n, pos = unpack("<I2", c.payload, pos)
      p.cols = {}
      for i = 1, n do p.cols[i], pos = col_unpack(c.payload, pos) end
      if #p.cols == 0 then p.cols = nil end
      doc.places[#doc.places + 1] = p
    elseif c.tag == "MRKR" and (c.version == 1 or c.version == 2) then
      local mk, pos = {}, 1
      local n
      mk.x, mk.y, mk.w, mk.h, mk.kind, mk.label, mk.note, pos =
        unpack("<i4i4i4i4s4s4s4", c.payload, pos)
      if c.version == 2 then -- v2: the teidraw group tag (0 = ungrouped)
        local gid; gid, pos = unpack("<I4", c.payload, pos)
        mk.gid = gid ~= 0 and gid or nil
      end
      n, pos = unpack("<I2", c.payload, pos)
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
  clamp_layers(doc) -- synthesize the default layer + clamp indices
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
    if place_on(doc, p) then
      for _, c in ipairs(p.cols or {}) do to_world(c, p.x, p.y, cols) end
    end
  end
  local world = collide.build{ name = o.name or error("map.use: name", 2),
                               w = doc.w, h = doc.h, colliders = cols }
  local by_name = {}
  for _, p in ipairs(doc.places) do
    if p.name and place_on(doc, p) and not by_name[p.name] then
      by_name[p.name] = p
    end
  end
  M.cur = { doc = doc, world = world, by_name = by_name, path = o.path,
            name = o.name }
  return M.cur
end

-- the named-placement handle (D057b): the placement table itself —
-- mutate x/y/vis freely, it is render-only state (like the camera).
function M.get(name)
  return M.cur and M.cur.by_name[name] or nil
end

-- built-in fallbacks for a dangling / missing named ref: graceful
-- degradation, loud but non-fatal. Paths resolve from the ENGINE ROOT
-- (cwd), like the stock instruments — a packaged game bundles engine/stock.
M.FALLBACK = {
  spr = "engine/stock/spr/tiles.spr", png = "engine/stock/spr/tiles.png",
  ins = "engine/stock/error.ins", song = "engine/stock/error.song",
  pal = "engine/stock/error.pal",
}

local function kind_of(path)
  return (path and path:match("%.([%w]+)$") or ""):lower()
end
M.kind_of = kind_of

local function is_visual(path)
  local k = kind_of(path)
  return k == "spr" or k == "png" or k == "tm"
end
M.is_visual = is_visual

-- cm.map.ref(name): resolve a named placement to a usable (cwd-relative)
-- asset path from the LIVE map. A missing name or an unreadable file is
-- NON-FATAL — it logs a warning + a traceback and returns the built-in
-- fallback for the kind (checkerboard sprite / error jingle / placeholder
-- palette), so a deleted asset degrades loudly instead of crashing.
-- Returns: path, kind, ok. `ok=false` means the fallback is in play.
function M.ref(name)
  local cur = M.cur
  local proj = (cm.main and cm.main.args and cm.main.args.project) or "."
  local p = cur and cur.by_name[name]
  if not p then
    pal.log(("[map] NULL REF: no placement named %q on map %q")
            :format(tostring(name), cur and cur.name or "<none>"))
    pal.log(debug.traceback("  at", 2))
    return nil, nil, false
  end
  local kind = kind_of(p.path)
  local full = proj .. "/" .. p.path
  if pal.read_file(full) then return full, kind, true end
  local fb = M.FALLBACK[kind]
  pal.log(("[map] NULL REF %q -> %s unreadable; falling back to %s")
          :format(name, p.path, fb or "(no fallback for ." .. kind .. ")"))
  pal.log(debug.traceback("  at", 2))
  return fb, kind, false
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
    if place_on(doc, p) then
      for _, c in ipairs(p.cols or {}) do to_world(c, p.x, p.y, cols) end
    end
  end
  collide.rebuild(cur.world, { name = cur.name, w = doc.w, h = doc.h,
                               colliders = cols })
  cur.doc = doc
  cur.by_name = {}
  for _, p in ipairs(doc.places) do
    if p.name and place_on(doc, p) and not cur.by_name[p.name] then
      cur.by_name[p.name] = p
    end
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
    if place_on(doc, p) then -- a disabled layer's colliders don't exist
      for _, c in ipairs(p.cols or {}) do take(c, p.x, p.y) end
    end
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
  -- the §5 per-map switch: once art placements own the visuals the
  -- colliders render NOTHING in the game (editor gizmos only)
  if inst.doc.nofill then return end
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

-- a placed .spr's animation info (frame count + per-frame size + the
-- .anim sidecar clips), cached by path + asset epoch. The baked strip is
-- `frames` frames of `w`x`h`; clips index into it. nil for non-.spr /
-- unreadable. Shared by both banks (game draw + the editor preview).
local spr_cache = {}
function M.spr_info(path)
  if kind_of(path) ~= "spr" then return nil end
  local ep = cm.asset_epoch or 0
  local rec = spr_cache[path]
  if rec and rec.ep == ep then return rec.info end
  local proj = (cm.main and cm.main.args and cm.main.args.project) or "."
  local info
  local sb = pal.read_file(proj .. "/" .. path)
  if sb then
    local ok, sdoc = pcall(cm.require("cm.sprite").decode, sb)
    if ok then
      info = { frames = math.max(1, sdoc.frames or 1), w = sdoc.w,
               h = sdoc.h,
               clips = cm.require("cm.anim").load(
                 proj .. "/" .. path:gsub("%.[sS][pP][rR]$", ".anim")) }
    end
  end
  spr_cache[path] = { ep = ep, info = info }
  return info
end

-- the current animation frame (0-based) + per-frame size for a placement,
-- or nil when it isn't an auto-playing .spr. `elapsed` is the playhead
-- (the sim frame in-game — render-only, deterministic; a wall clock in the
-- editor preview). Falls back to frame 0 if the named clip is gone.
function M.place_frame(path, anim_name, elapsed)
  if not anim_name then return nil end
  local info = M.spr_info(path)
  if not info then return nil end
  local clip = info.clips and cm.require("cm.anim").find(info.clips, anim_name)
  local fi = clip and cm.require("cm.anim").frame_at(clip, elapsed) or 0
  if fi < 0 then fi = 0 elseif fi >= info.frames then fi = info.frames - 1 end
  return fi, info.w, info.h, info.frames
end

-- draw the placements in file order (= z order) with gfx.layer(1) active,
-- camera-culled; flip_x mirrors via swapped u. Art stacks on top of the
-- collider fill until a per-map flag turns the fill off (§5).
function M.draw_places(inst, camx, camy)
  local vw, vh = pal.gfx_size()
  local doc = inst.doc
  local tmap
  for _, pi in ipairs(M.z_order(doc)) do
    local p = doc.places[pi]
    -- draw the image only for a live layer + a visible visual placement;
    -- off-layer / novis / non-visual placements are refs (no image)
    if place_on(doc, p) and p.vis ~= false then
      local rec = kind_of(p.path) == "tm" and place_tm(inst, p) or nil
      if rec then -- a .tm: tmap.draw culls per cell; flip is a no-op
        tmap = tmap or cm.require("cm.tmap")
        tmap.draw(rec.doc, rec.tex, p.x, p.y, camx, camy)
      else
        local t = kind_of(p.path) ~= "tm" and place_tex(inst, p) or nil
        if t then
          -- an auto-playing clip draws one frame; otherwise the whole image
          local fi, fw, fh = M.place_frame(p.path, p.anim,
            cm.require("cm.state").frame())
          local dw, dh = fi and fw or t.w, fi and fh or t.h
          if p.x < camx + vw and p.x + dw > camx
             and p.y < camy + vh and p.y + dh > camy then
            local su0, su1 = 0, 1
            if fi then su0, su1 = fi * fw / t.w, (fi + 1) * fw / t.w end
            if p.flip then su0, su1 = su1, su0 end
            pal.quad(p.x, p.y, dw, dh, 1, 1, 1, 1, t.id, su0, 0, su1, 1)
          end
        elseif is_visual(p.path) then
          -- a dangling visual (deleted/typo): the checkerboard, loudly
          M.draw_null(inst, p, camx, camy)
        end
      end
    end
  end
end

-- the in-game null-ref placeholder: a small magenta/black checkerboard at
-- the placement (matches the editor's) + a one-shot console warning. A
-- deleted asset stays obvious in the running game, never a silent gap.
function M.draw_null(inst, p, camx, camy)
  inst._warned = inst._warned or {}
  if not inst._warned[p.path] then
    inst._warned[p.path] = true
    pal.log(("[map] null asset ref: %s%s — checkerboard placeholder")
            :format(p.path, p.name and (' ("' .. p.name .. '")') or ""))
  end
  local S = 16 -- placeholder cell size in world px
  for r = 0, 1 do
    for c = 0, 1 do
      local col = (c + r) % 2 == 0 and 0xE8 or 0x24
      pal.quad(p.x + c * S, p.y + r * S, S, S,
               col / 255, (col == 0xE8 and 0x38 or 0x18) / 255,
               (col == 0xE8 and 0xE8 or 0x30) / 255, 1)
    end
  end
end

return M
