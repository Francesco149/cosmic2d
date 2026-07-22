-- cm.ed.win.map — the map window (R8b, MAPS.md §6): the .map asset as a
-- canvas citizen. Opens from the asset picker (double-click / drag-out),
-- the spawn menu (unbound — type a path to create), or kind.drop rebind.
--
-- The working state is the CMAP bytes — doc.assets[path].map — the §6
-- EDITOR.md three-layer model verbatim (the sprite ed's shape): dirty =
-- bytes ≠ disk, journal entries are full CMAP snapshots (cap 512), one
-- gesture = one entry, Ctrl+S/Z/Y, revert-as-edit, restart survival +
-- rewind (EDOC) for free. The decoded doc + fill geometry + textures are
-- ephemeral plumbing keyed by path.
--
-- R8b roster: view (wheel zoom at cursor, MMB pan, shift+1 fit; focused
-- = the view lock — own pan/zoom priority over the canvas, EDITOR.md
-- §12.7), the graybox fill + placements + marker rects + collider
-- gizmos (header chips giz/mk/fill), the SELECT tool end to end — click
-- / shift-click / marquee / drag-move / arrow nudge / del / [ ] z —
-- with the §7 CTRL snap for placements (vertices > edges/centers >
-- grid; guides drawn; ctrl+wheel dials the grid step), double-click a
-- placement → its editor, the inspector strip (x/y/name/flip), and
-- kind.drop — drag a .spr/.png/.tm from the picker and release over the
-- map to PLACE it (ghost preview + live snap during the carry). Save =
-- write the .map + submit the recorded cm.map.reload EVAL — the running
-- game hot-reloads (MAPS.md §9), so traces replay it and rewind scrubs
-- across it.
--
-- D061 (teidraw): FOUR modes, keyed. **move** (default, esc returns here) is
-- unified direct manipulation — click any collider vertex/edge, placement, or
-- marker selects + moves it, click-again DRILLS beneath (M.hit_stack +
-- M.drill_pick); empty click deselects. **sel** (v) is one-shot box-select —
-- marquee, then back to move. **col** (c) PLACES colliders only (never grabs):
-- the LINE grammar — drag = a 2-pt line, or click,click, then shift+click
-- APPENDS to the last line; quad/circle drag out; esc cancels the placement.
-- **mkr** (m) drags out a marker. The §7 point snap rides every draw. ATTACHED
-- colliders edit in move mode while their placement selects (+col auto-fit).
--
-- Sim/editor line: everything here touches working bytes only; the one
-- sim-facing op is the recorded repl.submit on save.

local M = select(2, ...) or {}
local map = cm.require("cm.map")
local tmap = cm.require("cm.tmap")
local wv = cm.require("cm.ed.winview")

M.kind = "map"
M.help = "win-map"
M.menu = "map"
M.exts = { "map" }
M.DEF_W, M.DEF_H = 560, 420
M.JCAP = 512
M.wants_keys = true -- del/arrows/brackets belong to the tool (§6); the
                    -- shell's plain-key hotkeys suspend while focused

local COL = {
  well = 0x141220ff, bounds = 0x4a4370ff,
  btn = 0x262238ff, btn_on = 0x4a4370ff, btn_hot = 0x3a3560ff,
  text = 0xd8d2f2ff, dim = 0x8a84b0ff, hot = 0xE8E4FFff,
  danger = 0xf07a7aff,
  solid = 0x8ad0ffff, oneway = 0x7fd8a8ff,  -- collider gizmos
  marker = 0xf0d070ff, sel = 0x7fd8a8ff,
  guide = 0xE8E4FFcc, ghost = 0x7fd8a866,
  ref_bg = 0x2a2540e0, ref_ic = 0x8fb8ffff, -- named-ref tag
  null1 = 0xE838E8ff, null2 = 0x241830ff,    -- null-ref checkerboard
  dis = 0x0a0812aa,                          -- disabled-layer dim overlay
  grp = 0x7a6cc0aa, grp_sel = 0xc7b6ffff,    -- group hulls (D061)
}

local KEY = { right = 79, left = 80, down = 81, up = 82, del = 76,
              backspace = 42, rbracket = 48, lbracket = 47, n1 = 30,
              n2 = 31, enter = 40, a = 4, c = 6, d = 7, g = 10, m = 16,
              v = 25, x = 27 }

local GRID_STEPS = { 1, 2, 4, 8, 16, 32, 64 }
local SNAP_PX = 6 -- snap threshold, screen px (§7: ~6 px-at-zoom)

-- The compact top-right view readout. Map tutorials name exact points just
-- like sprite tutorials name pixels, so the authored map coordinate under the
-- cursor must be visible rather than inferred from the snap grid. Kept pure so
-- the integer rounding and the off-view form stay KAT-pinned.
function M.view_status(mx, my, over, zoom, grid)
  local tail = ("%d%% · grid %d"):format(math.floor(zoom * 100 + 0.5), grid)
  if not over then return tail end
  return ("%d,%d · %s"):format(math.floor(mx + 0.5),
                                math.floor(my + 0.5), tail)
end

function M.defaults()
  return { path = "", tool = "move", giz = true, mk = true,
           ctype = "line", lpanel = true }
end

function M.title(win)
  return win.path:match("([^/]+)$") or "map"
end

function M.accepts(win, path) -- the rebind predicate: .map retargets
  return path:lower():find("%.map$") ~= nil
end

function M.rebind(win, ed, path)
  win.path = path
  win.zoom, win.px, win.py = nil, nil, nil
  ed.touch()
end

-- a visual asset draws its image; everything else places as a NAMED REF
-- (a labelled tag, addressable from code via cm.map.ref).
local function visual(path)
  local l = path:lower()
  return l:find("%.spr$") or l:find("%.png$") or l:find("%.tm$")
end

-- what kind.drop claims: ANY asset (MAPS.md §6). Visuals render; other
-- kinds attach as named refs. Reject only paths with no extension (dirs).
local function placeable(path)
  return path ~= "" and path:find("%.[%w]+$") ~= nil
end

-- the asset kind glyph for a named-ref tag ("bgm  .song")
local function asset_kind(path)
  return (path:match("%.([%w]+)$") or "?"):lower()
end

-- ---- layer ops (mutate doc.layers + remap placement indices) ----

local function layer_add(doc)
  doc.layers[#doc.layers + 1] =
    { name = "layer " .. (#doc.layers + 1), vis = true, on = true }
  return #doc.layers -- the new active layer
end

-- remove layer k: its placements fall to the layer below (never deleted —
-- less surprising than vanishing art); layers above renumber down.
local function layer_del(doc, k)
  if #doc.layers <= 1 then return false end
  table.remove(doc.layers, k)
  for _, pl in ipairs(doc.places) do
    if pl.layer == k then pl.layer = math.max(1, k - 1)
    elseif (pl.layer or 1) > k then pl.layer = pl.layer - 1 end
  end
  return true
end

-- swap layers a,b (reorder = change z); placements on either follow.
local function layer_swap(doc, a, b)
  if a < 1 or b < 1 or a > #doc.layers or b > #doc.layers or a == b then
    return false
  end
  doc.layers[a], doc.layers[b] = doc.layers[b], doc.layers[a]
  for _, pl in ipairs(doc.places) do
    local L = pl.layer or 1
    if L == a then pl.layer = b elseif L == b then pl.layer = a end
  end
  return true
end

-- ---- the asset citizen (cm.ed.kit, R9a) — plumbing on ed.g.mw[path],
-- working CMAP bytes in doc.assets[path].map, the §6 contract generated

local function decode_into(p, bytes)
  local ok, doc = pcall(map.decode, bytes)
  if ok then
    p.doc = doc
    p.err = nil
  else
    p.doc = nil
    p.err = tostring(doc)
  end
  p.geom = nil
  p.sel = {}
end

local function fresh_bytes(path)
  local iw, ih = 480, 270
  local proj = cm.main and cm.main.proj
  if proj and proj.internal_w and proj.internal_h then
    iw, ih = proj.internal_w, proj.internal_h
  end
  local name = path:match("([^/]+)%.map$") or "map"
  return map.encode{ name = name, w = iw, h = ih, grid = 8,
                     colliders = {}, places = {}, markers = {} }
end

local A = cm.require("cm.ed.kit").asset {
  gkey = "mw", field = "map", jcap = M.JCAP,
  fresh = function(ed, path) return fresh_bytes(path) end, -- a new map
  adopt = decode_into,
  encode = map.encode,
  post_encode = function(p) p.geom = nil end,
  write = function(ed, path, a, p)
    -- `_save_fail` exists only as the focused durability-test seam. Keeping
    -- it on ephemeral plumbing means it can never enter session state.
    return map.save(p.doc, ed.root .. "/" .. path, p._save_fail)
  end,
  after_save = function(ed, path)
    -- the recorded hot-reload (MAPS.md §9): the running game re-instances
    -- the saved map at the start of the next sim frame; traces replay it
    local full = ed.root .. "/" .. path
    cm.require("cm.repl").submit(('cm.require("cm.map").reload(%q)'):format(full))
    return "[ed] saved " .. path .. " (reload queued)"
  end,
}

local plumb, working, open_asset, commit =
  A.plumb, A.working, A.open_asset, A.commit

M.open_win = A.open_win -- spawn-time adoption (proof scripting too)

-- the §6 focused-window commands (shell kind_call dispatch)
M.dirty, M.save, M.undo, M.redo, M.revert =
  A.dirty, A.save, A.undo, A.redo, A.revert

-- Esc: cancel the live gesture, else clear the active tool's selection
-- (kind_escape); the shell's cascade unfocuses after that (the view lock)
function M.escape(win, ed)
  local p = ed.g.mw and ed.g.mw[win.path]
  if not p then return false end
  if p.g then
    if p.g.mutates then -- a doc-mutating drag: re-adopt committed bytes
      decode_into(p, working(ed, win.path).map)
    end
    p.g = nil
    p.guides = nil
    ed.touch()
    return true
  end
  if (win.tool or "move") ~= "move" then -- esc returns to unified manipulation
    win.tool = "move"
    ed.touch()
    return true
  end
  if p.csel or p.asel then
    p.csel, p.asel, p.drill = nil, nil, nil
    ed.touch()
    return true
  end
  if p.sel and #p.sel > 0 then
    p.sel = {}
    ed.touch()
    return true
  end
  return false
end

-- ---- the pure select-tool core (selftest drives these headless) ----
-- Selection items: { t = "place"|"marker", i = index }.

-- default dims: 16x16 (tests stub their own; the window passes tex_dims)
local function dim16() return 16, 16 end

-- a wall-clock 60 Hz playhead for the editor's animation PREVIEW (a live
-- clip auto-plays while you edit; the game uses the sim frame instead).
local function anim_clock()
  return math.floor((pal.time_ns and pal.time_ns() or 0) / 16666667)
end

function M.place_rect(doc, i, dims)
  local p = doc.places[i]
  if p.anim then -- an auto-playing .spr is one frame, not the whole strip
    local info = map.spr_info(p.path)
    if info then return p.x, p.y, info.w, info.h end
  end
  local w, h = (dims or dim16)(p.path)
  return p.x, p.y, w, h
end

local function item_rect(doc, it, dims)
  if it.t == "place" then return M.place_rect(doc, it.i, dims) end
  local mk = doc.markers[it.i]
  return mk.x, mk.y, mk.w, mk.h
end

-- can this placement be picked in the editor? Not on an editor-hidden
-- layer (vis=false — you can't click what isn't drawn); when `only` is
-- set (the lock toggle) only that layer's placements answer.
local function pickable(doc, p, only)
  local L = p.layer or 1
  if only and L ~= only then return false end
  local Lyr = doc.layers and doc.layers[L]
  return not (Lyr and Lyr.vis == false)
end
M.pickable = pickable

-- topmost item under a map point: markers first when shown (they overlay),
-- then placements in reverse Z order (top layer / latest = topmost, §2).
-- `only_layer` (the lock toggle) restricts placements to that layer.
function M.pick(doc, mx, my, dims, with_markers, only_layer)
  if with_markers then
    for i = #doc.markers, 1, -1 do
      local mk = doc.markers[i]
      if mx >= mk.x and mx < mk.x + mk.w and my >= mk.y and my < mk.y + mk.h then
        return { t = "marker", i = i }
      end
    end
  end
  local zo = map.z_order(doc)
  for k = #zo, 1, -1 do
    local i = zo[k]
    if pickable(doc, doc.places[i], only_layer) then
      local x, y, w, h = M.place_rect(doc, i, dims)
      if mx >= x and mx < x + w and my >= y and my < y + h then
        return { t = "place", i = i }
      end
    end
  end
end

function M.sel_has(sel, it)
  for n, s in ipairs(sel) do
    if s.t == it.t and s.i == it.i then return n end
  end
end

-- items intersecting a map rect (marquee)
function M.pick_rect(doc, x0, y0, x1, y1, dims, with_markers, only_layer)
  if x1 < x0 then x0, x1 = x1, x0 end
  if y1 < y0 then y0, y1 = y1, y0 end
  local out = {}
  for i = 1, #doc.places do
    if pickable(doc, doc.places[i], only_layer) then
      local x, y, w, h = M.place_rect(doc, i, dims)
      if x < x1 and x + w > x0 and y < y1 and y + h > y0 then
        out[#out + 1] = { t = "place", i = i }
      end
    end
  end
  if with_markers then
    for i = 1, #doc.markers do
      local mk = doc.markers[i]
      if mk.x < x1 and mk.x + mk.w > x0 and mk.y < y1 and mk.y + mk.h > y0 then
        out[#out + 1] = { t = "marker", i = i }
      end
    end
  end
  return out
end

function M.nudge(doc, sel, dx, dy)
  for _, it in ipairs(sel) do
    local o = it.t == "place" and doc.places[it.i] or doc.markers[it.i]
    o.x, o.y = o.x + dx, o.y + dy
  end
  return #sel > 0
end

-- delete the selection (indices removed high-to-low per array)
function M.del(doc, sel)
  local pl, mk = {}, {}
  for _, it in ipairs(sel) do
    if it.t == "place" then pl[#pl + 1] = it.i else mk[#mk + 1] = it.i end
  end
  table.sort(pl, function(a, b) return a > b end)
  table.sort(mk, function(a, b) return a > b end)
  for _, i in ipairs(pl) do table.remove(doc.places, i) end
  for _, i in ipairs(mk) do table.remove(doc.markers, i) end
  return #sel > 0
end

-- ---- the unified direct-manipulation core (teidraw, D061) ----
-- Everything under a map point, front→back, as a drill STACK: free-collider
-- vertices, then free-collider edges (both precise gizmos), then markers (if
-- shown), then placements (reverse Z = topmost first). Each click steps one
-- entry down the stack (M.drill_pick) — so click-on-a-collider-line, click
-- again, and you're on the sprite beneath it. Hit records:
--   { t="cvert", c, v, x, y }   a free-collider vertex / handle
--   { t="cedge", c, e, x, y }   a free-collider edge (x,y = projection)
--   { t="marker", i }
--   { t="place",  i }
-- `opts`: thr (map px), with_markers, only_layer (the lock filter).
function M.hit_stack(doc, mx, my, dims, opts)
  opts = opts or {}
  local thr = opts.thr or 4
  local out, verts, edges = {}, {}, {}
  for ci = 1, #doc.colliders do
    local h = M.col_pick({ doc.colliders[ci] }, mx, my, thr)
    if h then
      if h.v then verts[#verts + 1] = { t = "cvert", c = ci, v = h.v,
                                        x = h.x, y = h.y }
      else edges[#edges + 1] = { t = "cedge", c = ci, e = h.e,
                                 x = h.x, y = h.y } end
    end
  end
  for _, h in ipairs(verts) do out[#out + 1] = h end
  for _, h in ipairs(edges) do out[#out + 1] = h end
  if opts.with_markers then
    for i = #doc.markers, 1, -1 do
      local mk = doc.markers[i]
      if mx >= mk.x and mx < mk.x + mk.w and my >= mk.y
         and my < mk.y + mk.h then
        out[#out + 1] = { t = "marker", i = i }
      end
    end
  end
  local zo = map.z_order(doc)
  for k = #zo, 1, -1 do
    local i = zo[k]
    if pickable(doc, doc.places[i], opts.only_layer) then
      local x, y, w, h = M.place_rect(doc, i, dims)
      if mx >= x and mx < x + w and my >= y and my < y + h then
        out[#out + 1] = { t = "place", i = i }
      end
    end
  end
  return out
end

-- drill selection: repeated clicks at the ~same screen point step one entry
-- down the stack (wrapping). `prev` = the last press's { sx, sy, k } (nil =
-- a fresh point); `sx,sy` = this press in screen px; `thr` = the re-click
-- tolerance. Returns the 1-based stack index + the new drill record.
function M.drill_pick(stack, prev, sx, sy, thr)
  local n = #stack
  if n == 0 then return nil end
  local k = 1
  if prev and math.abs(sx - prev.sx) <= thr and math.abs(sy - prev.sy) <= thr
  then
    k = prev.k % n + 1
  end
  return k, { sx = sx, sy = sy, k = k }
end

-- ---- groups (teidraw, D061): a stable per-item `gid` tags membership ----
-- A group spans placements + markers (free colliders stay ungrouped in v1);
-- it is just "every item sharing a gid". Selecting a member selects the whole
-- group (move together); click-again drills into the individual member.

function M.item_gid(doc, it)
  if it.t == "place" then
    return doc.places[it.i] and doc.places[it.i].gid
  elseif it.t == "marker" then
    return doc.markers[it.i] and doc.markers[it.i].gid
  end
end

function M.group_members(doc, gid)
  local out = {}
  for i, pl in ipairs(doc.places) do
    if pl.gid == gid then out[#out + 1] = { t = "place", i = i } end
  end
  for i, mk in ipairs(doc.markers) do
    if mk.gid == gid then out[#out + 1] = { t = "marker", i = i } end
  end
  return out
end

function M.next_gid(doc)
  local mx = 0
  for _, pl in ipairs(doc.places) do
    if pl.gid and pl.gid > mx then mx = pl.gid end
  end
  for _, mk in ipairs(doc.markers) do
    if mk.gid and mk.gid > mx then mx = mk.gid end
  end
  return mx + 1
end

-- assign a fresh gid to every place/marker in `sel` (needs >= 2 to be useful);
-- returns the new gid, or nil if there was nothing to group
function M.group_sel(doc, sel)
  local n = 0
  for _, it in ipairs(sel) do
    if it.t == "place" or it.t == "marker" then n = n + 1 end
  end
  if n < 2 then return nil end
  local gid = M.next_gid(doc)
  for _, it in ipairs(sel) do
    local o = it.t == "place" and doc.places[it.i]
              or it.t == "marker" and doc.markers[it.i]
    if o then o.gid = gid end
  end
  return gid
end

-- clear the gid on every group `sel` touches; returns true if any cleared
function M.ungroup_sel(doc, sel)
  local gids, any = {}, false
  for _, it in ipairs(sel) do
    local gid = M.item_gid(doc, it)
    if gid then gids[gid] = true end
  end
  for _, pl in ipairs(doc.places) do
    if pl.gid and gids[pl.gid] then pl.gid = nil; any = true end
  end
  for _, mk in ipairs(doc.markers) do
    if mk.gid and gids[mk.gid] then mk.gid = nil; any = true end
  end
  return any
end

-- expand a hit stack into the DRILL CHAIN: a grouped place/marker gets a
-- { t="group", gid, members } entry inserted before its first member, so
-- clicks cycle group -> that member -> whatever's beneath (teidraw drill-in)
function M.drill_chain(doc, stack)
  local chain, seen = {}, {}
  for _, s in ipairs(stack) do
    if s.t == "place" or s.t == "marker" then
      local gid = M.item_gid(doc, s)
      if gid and not seen[gid] then
        seen[gid] = true
        chain[#chain + 1] = { t = "group", gid = gid,
                              members = M.group_members(doc, gid) }
      end
    end
    chain[#chain + 1] = s
  end
  return chain
end

-- z within the layer = order in doc.places (§6); dir +1 = forward one.
-- The whole selected placement set shifts one slot, order preserved
-- (markers in the selection are untouched — z lives in places). Single
-- selections return the new index (same index when clamped — the
-- original contract); multi returns true, or nil when clamped.
function M.zmove(doc, sel, dir)
  local idx = {}
  for _, it in ipairs(sel) do
    if it.t == "place" then idx[#idx + 1] = it.i end
  end
  if #idx == 0 then return nil end
  table.sort(idx)
  if (dir > 0 and idx[#idx] >= #doc.places)
     or (dir < 0 and idx[1] <= 1) then
    return #idx == 1 and idx[1] or nil -- clamped
  end
  local remap = {}
  for k = dir > 0 and #idx or 1, dir > 0 and 1 or #idx, dir > 0 and -1 or 1 do
    local i = idx[k]
    local pl = table.remove(doc.places, i)
    table.insert(doc.places, i + dir, pl)
    remap[i] = i + dir
  end
  for _, it in ipairs(sel) do
    if it.t == "place" then it.i = remap[it.i] or it.i end
  end
  return #idx == 1 and remap[idx[1]] or true
end

-- ---- clipboard ops (ctrl+c/x/v/d; the clip lives ephemeral on ed.g) ----

local function deep(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep(x) end
  return out
end

-- clipboard snapshot of the selection (deep copies, file order kept)
function M.copy_sel(doc, sel)
  local clip = { places = {}, markers = {} }
  local pl = {}
  for _, it in ipairs(sel) do
    if it.t == "place" then
      pl[#pl + 1] = it.i
    elseif doc.markers[it.i] then
      clip.markers[#clip.markers + 1] = deep(doc.markers[it.i])
    end
  end
  table.sort(pl)
  for _, i in ipairs(pl) do
    if doc.places[i] then
      clip.places[#clip.places + 1] = deep(doc.places[i])
    end
  end
  if #clip.places + #clip.markers == 0 then return nil end
  return clip
end

-- append the clip's items offset by (dx, dy); pasted placements drop
-- their name (names address uniquely from code). Returns the new
-- selection (the pasted set, on top in file order).
function M.paste(doc, clip, dx, dy)
  local sel = {}
  -- pasted items keep their internal grouping under fresh gids (a copied
  -- group stays a group); names drop (they address uniquely)
  local base, gmap, gc = M.next_gid(doc), {}, 0
  local function regid(old)
    if not old then return nil end
    if not gmap[old] then gc = gc + 1; gmap[old] = base + gc - 1 end
    return gmap[old]
  end
  for _, pl in ipairs(clip.places or {}) do
    local c = deep(pl)
    c.x, c.y, c.name, c.gid = c.x + dx, c.y + dy, nil, regid(pl.gid)
    doc.places[#doc.places + 1] = c
    sel[#sel + 1] = { t = "place", i = #doc.places }
  end
  for _, mk in ipairs(clip.markers or {}) do
    local c = deep(mk)
    c.x, c.y, c.gid = c.x + dx, c.y + dy, regid(mk.gid)
    doc.markers[#doc.markers + 1] = c
    sel[#sel + 1] = { t = "marker", i = #doc.markers }
  end
  return sel
end

-- selection bounds in map px (dims resolves placement sizes); nil when
-- the selection resolves to nothing
function M.sel_bounds(doc, sel, dims)
  local x0, y0, x1, y1
  local function acc(x, y, w, h)
    x0 = math.min(x0 or x, x)
    y0 = math.min(y0 or y, y)
    x1 = math.max(x1 or x + w, x + w)
    y1 = math.max(y1 or y + h, y + h)
  end
  for _, it in ipairs(sel) do
    if it.t == "place" then
      local o = doc.places[it.i]
      if o then
        local w, h = dims(o.path)
        acc(o.x, o.y, w or 16, h or 16)
      end
    else
      local o = doc.markers[it.i]
      if o then acc(o.x, o.y, o.w or 2, o.h or 2) end
    end
  end
  if x0 then return x0, y0, x1 - x0, y1 - y0 end
end

function M.clip_bounds(clip, dims)
  local doc2 = { places = clip.places or {}, markers = clip.markers or {} }
  local sel = {}
  for i = 1, #doc2.places do sel[#sel + 1] = { t = "place", i = i } end
  for i = 1, #doc2.markers do sel[#sel + 1] = { t = "marker", i = i } end
  return M.sel_bounds(doc2, sel, dims)
end

-- a free collider's bounds (fit-selection with the collider tool)
function M.col_bounds(c)
  if c.kind == "circle" then
    return c.cx - c.r, c.cy - c.r, 2 * c.r, 2 * c.r
  end
  if c.kind == "quad" then return c.x, c.y, c.w, c.h end
  local x0, y0, x1, y1
  for i = 1, #c.verts - 1, 2 do
    local x, y = c.verts[i], c.verts[i + 1]
    x0 = math.min(x0 or x, x)
    y0 = math.min(y0 or y, y)
    x1 = math.max(x1 or x, x)
    y1 = math.max(y1 or y, y)
  end
  if x0 then return x0, y0, x1 - x0, y1 - y0 end
end

-- every selectable item (ctrl+a)
function M.all_items(doc)
  local sel = {}
  for i = 1, #doc.places do sel[#sel + 1] = { t = "place", i = i } end
  for i = 1, #doc.markers do sel[#sel + 1] = { t = "marker", i = i } end
  return sel
end

-- ---- the §7 CTRL snap (placements; R8b subset) ----
-- rect = { x, y, w, h } at the RAW dragged position. Returns dx, dy to
-- add, plus guides to draw: { {t="dot",x,y} | {t="v",x} | {t="h",y} }.
-- Priority: vertices (2D) > edges/centers (per axis) > grid (per axis).
-- opts = { skip = fn(place_index)->bool (the dragged items), dims = fn,
--          grid = step, thr = map px }
function M.snap_rect(doc, rect, opts)
  local thr = opts.thr or 6
  local dims = opts.dims or dim16
  local skip = opts.skip
  -- feature points of the dragged rect: corners + center
  local fx = { rect.x, rect.x + rect.w, rect.x, rect.x + rect.w,
               rect.x + rect.w / 2 }
  local fy = { rect.y, rect.y, rect.y + rect.h, rect.y + rect.h,
               rect.y + rect.h / 2 }

  -- vertex targets: collider verts (free + attached at world coords) +
  -- other placements' corners
  local tmfn = opts.tm
  local best_d2, bdx, bdy, bgx, bgy
  local function try_vert(tx, ty)
    for k = 1, 5 do
      local ddx, ddy = tx - fx[k], ty - fy[k]
      if ddx >= -thr and ddx <= thr and ddy >= -thr and ddy <= thr then
        local d2 = ddx * ddx + ddy * ddy
        if not best_d2 or d2 < best_d2 then
          best_d2, bdx, bdy, bgx, bgy = d2, ddx, ddy, tx, ty
        end
      end
    end
  end
  local function col_verts(c, ox, oy)
    if c.kind == "circle" then return end
    if c.kind == "quad" then
      try_vert(c.x + ox, c.y + oy)
      try_vert(c.x + c.w + ox, c.y + oy)
      try_vert(c.x + ox, c.y + c.h + oy)
      try_vert(c.x + c.w + ox, c.y + c.h + oy)
    else
      for i = 1, #c.verts - 1, 2 do
        try_vert(c.verts[i] + ox, c.verts[i + 1] + oy)
      end
    end
  end
  for _, c in ipairs(doc.colliders) do col_verts(c, 0, 0) end
  for i, pl in ipairs(doc.places) do
    if not (skip and skip(i)) then
      for _, c in ipairs(pl.cols or {}) do col_verts(c, pl.x, pl.y) end
      local x, y, w, h = M.place_rect(doc, i, dims)
      try_vert(x, y)
      try_vert(x + w, y)
      try_vert(x, y + h)
      try_vert(x + w, y + h)
    end
  end
  if best_d2 then
    return bdx, bdy, { { t = "dot", x = bgx, y = bgy } }
  end

  -- per-axis: edges (other placements' edges + axis-aligned collider
  -- segments) and centers; unsnapped axes fall to the grid
  local ex, ey = {}, {} -- target x lines / y lines
  local cx, cy = {}, {} -- center lines
  local function col_edges(c, ox, oy)
    if c.kind == "circle" then return end
    if c.kind == "quad" then
      ex[#ex + 1] = c.x + ox
      ex[#ex + 1] = c.x + c.w + ox
      ey[#ey + 1] = c.y + oy
      ey[#ey + 1] = c.y + c.h + oy
    else
      for i = 1, #c.verts - 3, 2 do
        local ax, ay = c.verts[i] + ox, c.verts[i + 1] + oy
        local bx, by = c.verts[i + 2] + ox, c.verts[i + 3] + oy
        if ax == bx then ex[#ex + 1] = ax end
        if ay == by then ey[#ey + 1] = ay end
      end
    end
  end
  for _, c in ipairs(doc.colliders) do col_edges(c, 0, 0) end
  for i, pl in ipairs(doc.places) do
    if not (skip and skip(i)) then
      for _, c in ipairs(pl.cols or {}) do col_edges(c, pl.x, pl.y) end
      local x, y, w, h = M.place_rect(doc, i, dims)
      ex[#ex + 1] = x
      ex[#ex + 1] = x + w
      ey[#ey + 1] = y
      ey[#ey + 1] = y + h
      cx[#cx + 1] = x + w / 2
      cy[#cy + 1] = y + h / 2
      -- a placed .tm contributes its tile-edge lines (§7-R8d)
      local td = tmfn and tmfn(pl.path)
      if td then
        for j = 1, td.w - 1 do ex[#ex + 1] = x + j * td.tile end
        for k = 1, td.h - 1 do ey[#ey + 1] = y + k * td.tile end
      end
    end
  end
  local guides = {}
  local dx, dy
  local function axis_best(feats, lines, centers, cfeat)
    local bd, bt
    for _, t in ipairs(lines) do
      for _, f in ipairs(feats) do
        local d = t - f
        if d >= -thr and d <= thr and (not bd or d * d < bd * bd) then
          bd, bt = d, t
        end
      end
    end
    for _, t in ipairs(centers) do
      local d = t - cfeat
      if d >= -thr and d <= thr and (not bd or d * d < bd * bd) then
        bd, bt = d, t
      end
    end
    return bd, bt
  end
  local bxd, bxt = axis_best({ rect.x, rect.x + rect.w }, ex, cx,
                             rect.x + rect.w / 2)
  local byd, byt = axis_best({ rect.y, rect.y + rect.h }, ey, cy,
                             rect.y + rect.h / 2)
  if bxd then
    dx = bxd
    guides[#guides + 1] = { t = "v", x = bxt }
  end
  if byd then
    dy = byd
    guides[#guides + 1] = { t = "h", y = byt }
  end

  -- grid: the weakest — snaps the origin on any still-free axis
  local step = opts.grid or doc.grid or 8
  if step > 0 then
    if not dx then
      local gx = math.floor(rect.x / step + 0.5) * step
      dx = gx - rect.x
    end
    if not dy then
      local gy = math.floor(rect.y / step + 0.5) * step
      dy = gy - rect.y
    end
  end
  return dx or 0, dy or 0, guides
end

-- ---- the §7 point snap (collider authoring, R8c) ----
-- Vertex-level snapping for drawing/dragging collider points. Targets
-- are collected ONCE per gesture (the doc mutates live during a drag —
-- a per-frame walk would self-snap), points snap per frame.
--
-- snap_targets(doc, opts) -> { verts = {{x,y}...}, segs = {{x0,y0,x1,y1}...} }
--   opts.dims / opts.skip as snap_rect; opts.skipv = { o=, c=, v= } drops
--   the dragged vertex + its adjacent segments (v = nil drops the whole
--   collider — edge-drags move all of it). Owner o: 0 = free collider,
--   else the placement index; c = collider index within the owner.
--   opts.tm = fn(path) -> tmap doc|nil: placed .tm grids contribute
--   their tile-edge lines as segments (§7-R8d — line colliders click
--   onto tile boundaries).
function M.snap_targets(doc, opts)
  opts = opts or {}
  local dims = opts.dims or dim16
  local skip = opts.skip
  local sv = opts.skipv
  local tmfn = opts.tm
  local verts, segs = {}, {}
  local function excl(o, c, v)
    return sv and sv.o == o and sv.c == c and (sv.v == nil or sv.v == v)
  end
  local function excl_seg(o, c, v1, v2)
    return sv and sv.o == o and sv.c == c
           and (sv.v == nil or sv.v == v1 or sv.v == v2)
  end
  local function col(cobj, o, ci, ox, oy)
    if cobj.kind == "circle" then return end
    local v
    if cobj.kind == "quad" then
      v = { cobj.x, cobj.y, cobj.x + cobj.w, cobj.y,
            cobj.x + cobj.w, cobj.y + cobj.h, cobj.x, cobj.y + cobj.h }
    else
      v = cobj.verts
    end
    local n = #v // 2
    for i = 1, n do
      if not excl(o, ci, i) then
        verts[#verts + 1] = { v[i * 2 - 1] + ox, v[i * 2] + oy }
      end
    end
    local last = (cobj.kind == "quad" or cobj.closed) and n or n - 1
    for i = 1, last do
      local j = i % n + 1
      if not excl_seg(o, ci, i, j) then
        segs[#segs + 1] = { v[i * 2 - 1] + ox, v[i * 2] + oy,
                            v[j * 2 - 1] + ox, v[j * 2] + oy }
      end
    end
  end
  for ci, c in ipairs(doc.colliders) do col(c, 0, ci, 0, 0) end
  for pi, pl in ipairs(doc.places) do
    if not (skip and skip(pi)) then
      for aci, c in ipairs(pl.cols or {}) do col(c, pi, aci, pl.x, pl.y) end
      local x, y, w, h = M.place_rect(doc, pi, dims)
      verts[#verts + 1] = { x, y }
      verts[#verts + 1] = { x + w, y }
      verts[#verts + 1] = { x + w, y + h }
      verts[#verts + 1] = { x, y + h }
      segs[#segs + 1] = { x, y, x + w, y }
      segs[#segs + 1] = { x + w, y, x + w, y + h }
      segs[#segs + 1] = { x + w, y + h, x, y + h }
      segs[#segs + 1] = { x, y + h, x, y }
      -- a placed .tm contributes its interior tile-edge lines (§7-R8d;
      -- the bounds are already the placement's own edges above)
      local td = tmfn and tmfn(pl.path)
      if td then
        for j = 1, td.w - 1 do
          segs[#segs + 1] = { x + j * td.tile, y, x + j * td.tile, y + h }
        end
        for k = 1, td.h - 1 do
          segs[#segs + 1] = { x, y + k * td.tile, x + w, y + k * td.tile }
        end
      end
    end
  end
  return { verts = verts, segs = segs }
end

-- ---- the pure collider-op core (R8c; selftest drives these) ----

local function seg_d2(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local len2 = dx * dx + dy * dy
  local t = 0
  if len2 > 0 then
    t = ((px - ax) * dx + (py - ay) * dy) / len2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
  end
  local qx, qy = ax + dx * t, ay + dy * t
  local ddx, ddy = px - qx, py - qy
  return ddx * ddx + ddy * ddy, qx, qy
end

-- a quad's corners as a flat vert list (tl,tr,br,bl — snap_targets' order)
function M.quad_verts(c)
  return { c.x, c.y, c.x + c.w, c.y, c.x + c.w, c.y + c.h, c.x, c.y + c.h }
end

-- the nearest collider feature under a map point: vertices/handles outrank
-- edges (both within thr; nearest of each class wins). Returns
--   { c=, v=, x=, y= }  a vertex/handle (circle: v=1 = the radius ring)
--   { c=, e=, x=, y= }  an edge (x,y = the projection point; circle: e=1 =
--                       the interior, whole-move)
-- cols = the collider array (doc.colliders, or a placement's cols with
-- map coords pre-offset by the caller via ox/oy).
function M.col_pick(cols, mx, my, thr, ox, oy)
  ox, oy = ox or 0, oy or 0
  local t2 = thr * thr
  local bv, bvd, be, bed
  for ci, c in ipairs(cols) do
    if c.kind == "circle" then
      local dx, dy = mx - (c.cx + ox), my - (c.cy + oy)
      local d = (dx * dx + dy * dy) ^ 0.5
      local rd = d - c.r
      if rd < 0 then rd = -rd end
      if rd <= thr and (not bvd or rd * rd < bvd) then
        bv, bvd = { c = ci, v = 1, x = c.cx + ox, y = c.cy + oy }, rd * rd
      elseif d < c.r and (not bed or rd * rd < bed) then
        be, bed = { c = ci, e = 1, x = c.cx + ox, y = c.cy + oy }, rd * rd
      end
    else
      local v = c.kind == "quad" and M.quad_verts(c) or c.verts
      local n = #v // 2
      for i = 1, n do
        local dx, dy = mx - (v[i * 2 - 1] + ox), my - (v[i * 2] + oy)
        local d2 = dx * dx + dy * dy
        if d2 <= t2 and (not bvd or d2 < bvd) then
          bv, bvd = { c = ci, v = i, x = v[i * 2 - 1] + ox,
                      y = v[i * 2] + oy }, d2
        end
      end
      local last = (c.kind == "quad" or c.closed) and n or n - 1
      for i = 1, last do
        local j = i % n + 1
        local d2, qx, qy = seg_d2(mx, my, v[i * 2 - 1] + ox, v[i * 2] + oy,
                                  v[j * 2 - 1] + ox, v[j * 2] + oy)
        if d2 <= t2 and (not bed or d2 < bed) then
          be, bed = { c = ci, e = i, x = math.floor(qx + 0.5),
                      y = math.floor(qy + 0.5) }, d2
        end
      end
    end
  end
  return bv or be
end

-- insert a vertex on chain edge e (between verts e and e+1) at (x,y);
-- returns the new vertex index
function M.col_insert(c, e, x, y)
  table.insert(c.verts, e * 2 + 1, x)
  table.insert(c.verts, e * 2 + 2, y)
  return e + 1
end

-- del on the collider selection: a chain vertex when one is selected
-- (the whole collider when that would leave too few verts — open needs
-- 2, closed 3), else the whole collider. Returns "vert" | "col".
function M.col_del(cols, csel)
  local c = cols[csel.c]
  if not c then return nil end
  if csel.v and c.kind == "chain" then
    local n = #c.verts // 2
    if n - 1 >= (c.closed and 3 or 2) then
      table.remove(c.verts, csel.v * 2 - 1)
      table.remove(c.verts, csel.v * 2 - 1)
      return "vert"
    end
  end
  table.remove(cols, csel.c)
  return "col"
end

-- drag quad corner i (1..4 tl,tr,br,bl) to (nx,ny), anchored on the
-- opposite corner of the gesture-start rect r0 (normalizes on cross-over)
function M.quad_drag(c, r0, i, nx, ny)
  local ax = (i == 1 or i == 4) and r0.x + r0.w or r0.x
  local ay = (i == 1 or i == 2) and r0.y + r0.h or r0.y
  local x0, x1 = nx < ax and nx or ax, nx < ax and ax or nx
  local y0, y1 = ny < ay and ny or ay, ny < ay and ay or ny
  c.x, c.y, c.w, c.h = x0, y0, math.max(1, x1 - x0), math.max(1, y1 - y0)
end

-- offset a whole collider from its gesture-start shape orig
function M.col_offset(c, orig, dx, dy)
  if c.kind == "circle" then
    c.cx, c.cy = orig.cx + dx, orig.cy + dy
  elseif c.kind == "quad" then
    c.x, c.y = orig.x + dx, orig.y + dy
  else
    for i = 1, #orig.verts, 2 do
      c.verts[i] = orig.verts[i] + dx
      c.verts[i + 1] = orig.verts[i + 1] + dy
    end
  end
end

-- the +col auto-fit (§6, D057a): a new attached collider in RELATIVE
-- coords, fitted to the asset's w x h bounds. kind: "owline" = one-way
-- across the sprite's top at full width (THE platform case), "line" =
-- the same but solid, "quad" = the bounds, "circle" = inscribed.
function M.col_autofit(kind, w, h)
  if kind == "owline" or kind == "line" then
    return { kind = "chain", oneway = kind == "owline", closed = false,
             verts = { 0, 0, w, 0 } }
  elseif kind == "quad" then
    return { kind = "quad", x = 0, y = 0, w = w, h = h }
  end
  local r = math.max(1, math.min(w, h) // 2)
  return { kind = "circle", cx = w // 2, cy = h // 2, r = r }
end

-- arrow-nudge the collider selection (vertex when one is selected)
function M.col_nudge(cols, csel, dx, dy)
  local c = cols[csel.c]
  if not c then return false end
  if c.kind == "chain" and csel.v then
    c.verts[csel.v * 2 - 1] = c.verts[csel.v * 2 - 1] + dx
    c.verts[csel.v * 2] = c.verts[csel.v * 2] + dy
  elseif c.kind == "quad" and csel.v then
    local v = M.quad_verts(c)
    M.quad_drag(c, { x = c.x, y = c.y, w = c.w, h = c.h }, csel.v,
                v[csel.v * 2 - 1] + dx, v[csel.v * 2] + dy)
  elseif c.kind == "circle" then
    c.cx, c.cy = c.cx + dx, c.cy + dy
  elseif c.kind == "quad" then
    c.x, c.y = c.x + dx, c.y + dy
  else
    for i = 1, #c.verts, 2 do
      c.verts[i] = c.verts[i] + dx
      c.verts[i + 1] = c.verts[i + 1] + dy
    end
  end
  return true
end

local TAN22 = 0.41421356 -- tan(22.5 deg): the 8-sector boundary

-- snap_pt(targets, x, y, opts) -> sx, sy (integers), guides, how
--   §7 priority: vertices > edges (nearest point ON the segment — slopes
--   snap true) > the 45-degree lock vs opts.ax/ay (drawing/dragging with
--   a previous vertex; the anchor itself is never a vertex target) >
--   grid (only without an anchor — the lock owns the ray).
--   how = "vert"|"edge"|"45"|"grid".
function M.snap_pt(tg, x, y, opts)
  local thr = opts.thr or 6
  local ax, ay = opts.ax, opts.ay
  local bd2, bx, by
  for _, v in ipairs(tg.verts) do
    if not (ax and v[1] == ax and v[2] == ay) then
      local dx, dy = v[1] - x, v[2] - y
      if dx >= -thr and dx <= thr and dy >= -thr and dy <= thr then
        local d2 = dx * dx + dy * dy
        if not bd2 or d2 < bd2 then bd2, bx, by = d2, v[1], v[2] end
      end
    end
  end
  if bd2 then
    return bx, by, { { t = "dot", x = bx, y = by } }, "vert"
  end
  local ed2, ex, ey, eseg
  for _, s in ipairs(tg.segs) do
    local ddx, ddy = s[3] - s[1], s[4] - s[2]
    local len2 = ddx * ddx + ddy * ddy
    if len2 > 0 then
      local t = ((x - s[1]) * ddx + (y - s[2]) * ddy) / len2
      if t < 0 then t = 0 elseif t > 1 then t = 1 end
      local px2, py2 = s[1] + ddx * t, s[2] + ddy * t
      local dx, dy = px2 - x, py2 - y
      local d2 = dx * dx + dy * dy
      if d2 <= thr * thr and (not ed2 or d2 < ed2) then
        ed2, ex, ey, eseg = d2, px2, py2, s
      end
    end
  end
  if ed2 then
    ex, ey = math.floor(ex + 0.5), math.floor(ey + 0.5)
    return ex, ey,
           { { t = "seg", x0 = eseg[1], y0 = eseg[2],
               x1 = eseg[3], y1 = eseg[4] },
             { t = "dot", x = ex, y = ey } }, "edge"
  end
  if ax then
    local dx, dy = x - ax, y - ay
    local adx = dx < 0 and -dx or dx
    local ady = dy < 0 and -dy or dy
    local sx2, sy2
    if ady < adx * TAN22 then
      sx2, sy2 = math.floor(x + 0.5), ay
    elseif adx < ady * TAN22 then
      sx2, sy2 = ax, math.floor(y + 0.5)
    else
      local t = math.floor((adx + ady) / 2 + 0.5)
      sx2 = ax + (dx < 0 and -t or t)
      sy2 = ay + (dy < 0 and -t or t)
    end
    return sx2, sy2,
           { { t = "ray", x0 = ax, y0 = ay, x1 = sx2, y1 = sy2 } }, "45"
  end
  local step = opts.grid or 8
  return math.floor(x / step + 0.5) * step,
         math.floor(y / step + 0.5) * step, {}, "grid"
end

-- ---- header: tool radio (move/sel/col/mkr) + lyr / giz / mk chips ----
-- move = unified direct manipulation (default); sel = box-select (v, one-shot
-- → returns to move); col = place colliders (c); mkr = place markers (m).

local CHIPS = { { "lpanel", "lyr" }, { "giz", "giz" }, { "mk", "mk" } }
local TOOLS = { { "marker", "mkr" }, { "collider", "col" },
                { "sel", "sel" }, { "move", "move" } } -- right-to-left draw

function M.header(win, ctx)
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  local i = cm.require("cm.ui").inp
  local x = ctx.hx
  local used = 0
  local function chip(label, on)
    local w = pal.x_ig_text_size(label, px, 0) + 12 * z
    x = x - w - 3 * z
    used = used + w + 3 * z
    local hov = ctx.hot and i.wx >= x and i.wx < x + w
                and i.wy >= ctx.hy and i.wy < ctx.hy + ctx.hh
    pal.x_ig_rect_fill(x, ctx.hy + 3 * z, w, ctx.hh - 6 * z,
                       on and COL.btn_on or COL.btn, 4 * z)
    pal.x_ig_text(x + 6 * z, ctx.hy + (ctx.hh - px) * 0.45, px,
                  (hov or on) and COL.hot or COL.dim, label, 0)
    return hov and i.clicked[1]
  end
  for n = 1, #CHIPS do
    local key = CHIPS[#CHIPS + 1 - n][1]
    if chip(CHIPS[#CHIPS + 1 - n][2], win[key]) then
      win[key] = not win[key]
      ctx.ed.touch()
    end
  end
  if win.path ~= "" then
    x = x - 5 * z -- a breath between the toggle group and the tools
    used = used + 5 * z
    for _, t in ipairs(TOOLS) do
      if chip(t[2], (win.tool or "move") == t[1]) then
        win.tool = t[1]
        local p = ctx.ed.g.mw and ctx.ed.g.mw[win.path]
        if p then -- a tool switch drops the live gesture + selections
          if p.g and p.g.mutates then
            decode_into(p, working(ctx.ed, win.path).map)
          end
          p.g, p.guides, p.csel = nil, nil, nil
        end
        ctx.ed.touch()
      end
    end
  end
  return used
end

-- ---- view plumbing ----

-- focused = the view lock (the human's ask, §6, generalized —
-- kit.viewlock installs own_view/wheel/takes_middle): wheel +
-- middle-drag act on THIS window's camera from anywhere on the canvas;
-- any canvas action or Esc unfocuses. An unbound window has no view to
-- own. FOCUS IS THE ONE GATE (second round of the ask): an unfocused
-- map window's view is INERT — no hover fallback — so Esc visibly AND
-- actually lets go.
cm.require("cm.ed.kit").viewlock(M, { gkey = "mw", rect = "view" })

-- ctrl+wheel: the grid-step dial (§7; focused only, like the rest)
function M.ctrl_wheel(win, ed, notches)
  if ed.doc.focus ~= win.id then return false end
  local p = ed.g.mw and ed.g.mw[win.path]
  local cur = win.grid or (p and p.doc and p.doc.grid) or 8
  local at = 1
  for n, s in ipairs(GRID_STEPS) do
    if s <= cur then at = n end
  end
  at = math.max(1, math.min(#GRID_STEPS, at + (notches > 0 and 1 or -1)))
  win.grid = GRID_STEPS[at]
  ed.touch()
end

-- ---- drawing helpers ----

local function dashed(x0, y0, x1, y1, col, t)
  local dx, dy = x1 - x0, y1 - y0
  local len2 = dx * dx + dy * dy
  if len2 <= 0 then return end
  local n = math.max(1, math.floor(len2 ^ 0.5 / 8))
  for i = 0, n - 1 do
    local a, b = i / n, (i + 0.55) / n
    pal.x_ig_line(x0 + dx * a, y0 + dy * a, x0 + dx * b, y0 + dy * b, col, t)
  end
end

-- resolve an asset path to a readable disk path: the PROJECT root first
-- (ed.root), then the engine root / cwd — so `engine/stock/*` placements
-- render in the editor exactly the way the game resolves them (D061). nil
-- when neither exists.
local function res_path(ed, path)
  local a = ed.root .. "/" .. path
  if (pal.mtime(a) or 0) > 0 then return a end
  if (pal.mtime(path) or 0) > 0 then return path end
  return nil
end
M.res_path = res_path

-- placement image for the WINDOW draw (.spr shows its baked sibling; .tm
-- and missing files return nil = placeholder box)
local function win_tex(ed, path)
  local l = path:lower()
  local target
  if l:find("%.png$") then target = path
  elseif l:find("%.spr$") then target = path:gsub("%.spr$", ".png") end
  if not target then return nil end
  local rp = res_path(ed, target)
  if not rp then return nil end
  local ok, t = pcall(cm.require("cm.gfx").texture, rp)
  if ok then return t end
end

-- a placed .tm's decoded DISK doc (render plumbing keyed by path;
-- cm.asset_epoch invalidates, so a tilemap-window save shows on the
-- next frame). nil for unreadable/non-.tm paths.
local function tm_doc(ed, p, path)
  p.tm = p.tm or {}
  local ep = cm.asset_epoch or 0
  if p.tm_ep ~= ep then
    p.tm, p.tm_ep = {}, ep
  end
  local rec = p.tm[path]
  if rec == nil then
    rec = false
    if path:lower():find("%.tm$") then
      local rp = res_path(ed, path)
      local bytes = rp and pal.read_file(rp)
      if bytes then
        local ok, td = pcall(tmap.decode, bytes)
        if ok then rec = td end
      end
    end
    p.tm[path] = rec
  end
  return rec or nil
end

-- placement dims in map px (the window's `dims` for the pure core):
-- textures win; .tm reads its decoded doc; unknowns get 16x16. The
-- cache follows cm.asset_epoch (a save that resizes an asset moves it).
local function tex_dims(ed, p, path)
  local ep = cm.asset_epoch or 0
  if p.dims_ep ~= ep then
    p.dims, p.dims_ep = {}, ep
  end
  p.dims = p.dims or {}
  local hit = p.dims[path]
  if hit then return hit[1], hit[2] end
  local w, h = 16, 16
  local t = win_tex(ed, path)
  if t then
    w, h = t.w, t.h
  else
    local td = tm_doc(ed, p, path)
    if td then w, h = td.w * td.tile, td.h * td.tile end
  end
  p.dims[path] = { w, h }
  return w, h
end

-- the null-ref checkerboard (a dangling visual path): the classic missing-
-- texture magenta/black, cell-capped so a big placement stays cheap.
local function draw_checker(sx0, sy0, w, h, zoom)
  local sw, sh = w * zoom, h * zoom
  local cell = math.max(3, math.min(sw, sh) / 4)
  local nc = math.min(24, math.ceil(sw / cell))
  local nr = math.min(24, math.ceil(sh / cell))
  local cw, ch = sw / nc, sh / nr
  for r = 0, nr - 1 do
    for c = 0, nc - 1 do
      pal.x_ig_rect_fill(sx0 + c * cw, sy0 + r * ch, cw + 0.5, ch + 0.5,
                         (c + r) % 2 == 0 and COL.null1 or COL.null2)
    end
  end
end

-- a named-ref tag: a non-visual asset (or a novis visual) drawn as a
-- labelled chip at its position — "<name>  .kind". `missing` reddens it.
local function draw_reftag(sx0, sy0, z, pl, missing)
  local fpx = math.max(7, 9 * z)
  local nm = pl.name or (pl.path:match("([^/]+)%.[%w]+$")) or pl.path
  local kind = "." .. asset_kind(pl.path)
  local tw = pal.x_ig_text_size(nm, fpx, 0)
  local kw = pal.x_ig_text_size(kind, fpx * 0.85, 0)
  local pad = 4 * z
  local w = tw + kw + pad * 3
  local h = fpx + 3 * z
  pal.x_ig_rect_fill(sx0, sy0, w, h, missing and 0x5a2030e0 or COL.ref_bg,
                     3 * z)
  pal.x_ig_rect(sx0, sy0, w, h, missing and COL.danger or COL.ref_ic, 1,
                3 * z)
  pal.x_ig_text(sx0 + pad, sy0 + 1.5 * z, fpx,
                missing and COL.danger or COL.text, nm, 0)
  pal.x_ig_text(sx0 + pad * 2 + tw, sy0 + 1.5 * z, fpx * 0.85, COL.dim,
                kind, 0)
  return w, h
end

-- draw one placement into the window: a live visual image, a .tm cell
-- grid, a null-ref checkerboard, or a named-ref tag (non-visual / novis).
-- `disabled` dims it (its layer is off — invisible in-game). Warns once
-- per dangling path so a deleted asset is loud but not spammy.
local function draw_placement(ed, p, pl, sx0, sy0, w, h, zoom, z, disabled,
                              clip)
  local sw, sh = w * zoom, h * zoom
  local shown_image = false
  if pl.vis ~= false and visual(pl.path) then
    local t = win_tex(ed, pl.path)
    local td = not t and tm_doc(ed, p, pl.path)
    local ttex = td and cm.require("cm.ed.win.tmap")
                          .tileset_tex(ed, p, td.tileset)
    if t then
      local u0, u1 = 0, 1
      local fi, fw = map.place_frame(pl.path, pl.anim, anim_clock())
      if fi then u0, u1 = fi * fw / t.w, (fi + 1) * fw / t.w end
      if pl.flip then u0, u1 = u1, u0 end
      pal.x_ig_image(t.id, sx0, sy0, sw, sh, u0, 0, u1, 1)
      shown_image = true
    elseif td and ttex then
      cm.require("cm.ed.win.tmap").draw_cells(td, ttex,
        { zoom = zoom, ox = sx0, oy = sy0 }, clip[1], clip[2], clip[3], clip[4])
      shown_image = true
    else -- a visual whose file won't resolve: the null-ref placeholder
      p.warned = p.warned or {}
      if not p.warned[pl.path] then
        p.warned[pl.path] = true
        pal.log(("[map] null asset ref: %s%s — checkerboard placeholder")
                :format(pl.path, pl.name and (' (\"' .. pl.name .. '\")') or ""))
      end
      draw_checker(sx0, sy0, w, h, zoom)
      pal.x_ig_text(sx0 + 2 * z, sy0 + 1.5 * z, math.max(7, 9 * z),
                    0xffffffff, pl.name or pl.path:match("([^/]+)$"), 0)
      shown_image = true
    end
  end
  if not shown_image then -- non-visual asset OR a novis visual: a ref tag
    draw_reftag(sx0, sy0, z, pl, false)
  end
  if disabled then -- layer off: dim to signal "won't exist in-game"
    pal.x_ig_rect_fill(sx0, sy0, math.max(sw, 12 * z), math.max(sh, 10 * z),
                       COL.dis)
  end
end

-- the layer panel (right strip): the teidraw-style stack — front layer at
-- the TOP, each row a [e]ditor-visible + [g]ame-on toggle pair + name, the
-- active layer highlit. A footer adds / deletes / reorders / renames the
-- active layer. Layer edits commit (journaled); activating one only
-- touches the session. `active` = win.layer.
local function draw_layer_panel(win, ed, p, doc, x0, y0, pw, ph, z, fpx, ctx)
  local i = cm.require("cm.ui").inp
  pal.x_ig_rect_fill(x0, y0, pw, ph, 0x191627ff, 3 * z)
  local pad = 4 * z
  local rowh = math.max(12, fpx + 5 * z)
  local x, y = x0 + pad, y0 + pad
  local active = math.min(#doc.layers, math.max(1, win.layer or #doc.layers))

  -- header: "LAYERS" + the lock toggle
  pal.x_ig_text(x, y + 1.5 * z, fpx * 0.8, COL.dim, "LAYERS", 0)
  local lockw = pal.x_ig_text_size("lock", fpx * 0.8, 0) + 8 * z
  local lx = x0 + pw - pad - lockw
  local lockhot = ctx.hot and i.wx >= lx and i.wx < lx + lockw
                  and i.wy >= y and i.wy < y + rowh
  pal.x_ig_rect_fill(lx, y, lockw, rowh - z, win.lock and COL.btn_on or COL.btn,
                     3 * z)
  pal.x_ig_text(lx + 4 * z, y + 1.5 * z, fpx * 0.8,
                (lockhot or win.lock) and COL.hot or COL.dim, "lock", 0)
  if lockhot and i.clicked[1] then win.lock = not win.lock or nil; ctx.touch() end
  y = y + rowh + 2 * z

  -- a small square toggle button (returns clicked)
  local function tog(bx, by, bw, on, label, oncol)
    local hot = ctx.hot and i.wx >= bx and i.wx < bx + bw
                and i.wy >= by and i.wy < by + rowh - 2 * z
    pal.x_ig_rect_fill(bx, by, bw, rowh - 2 * z,
                       on and (oncol or COL.btn_on) or COL.btn, 2 * z)
    pal.x_ig_text(bx + (bw - pal.x_ig_text_size(label, fpx * 0.8, 0)) * 0.5,
                  by + 1 * z, fpx * 0.8, on and COL.hot or COL.dim, label, 0)
    return hot and i.clicked[1]
  end

  -- rows: front (highest index) at the top (two footer rows below:
  -- parallax, then the add/del/reorder/rename strip)
  local footer_y = y0 + ph - rowh - pad
  local par_y = footer_y - rowh - 2 * z
  for k = #doc.layers, 1, -1 do
    if y + rowh > par_y - 2 * z then
      pal.x_ig_text(x, y, fpx * 0.75, COL.dim, "…", 0)
      break
    end
    local L = doc.layers[k]
    if k == active then
      pal.x_ig_rect_fill(x0 + 2 * z, y - 1, pw - 4 * z, rowh, 0x322c50ff, 2 * z)
    end
    local bx, bw = x, 12 * z
    if tog(bx, y, bw, L.vis ~= false, "e") then -- toggle: visible <-> hidden
      if L.vis == false then L.vis = nil else L.vis = false end
      commit(ed, win.path)
    end
    bx = bx + bw + 2 * z
    if tog(bx, y, bw, L.on ~= false, "g", 0x3a7a52ff) then -- on <-> off
      if L.on == false then L.on = nil else L.on = false end
      commit(ed, win.path)
    end
    bx = bx + bw + 4 * z
    local nmw = x0 + pw - pad - bx
    local namehot = ctx.hot and i.wx >= bx and i.wx < bx + nmw
                    and i.wy >= y and i.wy < y + rowh
    pal.x_ig_clip_push(bx, y, nmw, rowh)
    pal.x_ig_text(bx, y + 1.5 * z, fpx * 0.85,
                  k == active and COL.hot
                  or (L.on == false and COL.dim or COL.text),
                  (L.name ~= "" and L.name) or ("layer " .. k), 0)
    pal.x_ig_clip_pop()
    if namehot and i.clicked[1] then win.layer = k; ctx.touch() end
    y = y + rowh + 1 * z
  end

  -- parallax row: the active layer's LAYR v2 factors (1 = world speed,
  -- 0.5 = half-speed backdrop, 0 = screen-fixed). Presentation-only —
  -- draw_places multiplies the play camera; the editor canvas always
  -- shows authored positions. Journaled like every other layer edit.
  if not ctx.occluded then
    local La = doc.layers[math.min(#doc.layers, active)]
    pal.x_ig_text(x, par_y + 1.5 * z, fpx * 0.8, COL.dim, "par", 0)
    local lw = pal.x_ig_text_size("par", fpx * 0.8, 0) + 4 * z
    local pfw = (pw - pad * 2 - lw - 2 * z) * 0.5
    for a, key in ipairs({ "par_x", "par_y" }) do
      local txt, _, _, st = pal.x_ig_edit {
        id = "maplyr" .. key .. win.id, x = x + lw + (a - 1) * (pfw + 2 * z),
        y = par_y + 1, w = pfw, h = rowh - 2,
        text = ("%g"):format(La[key] or 1), px = fpx * 0.8, font = 1,
        enter = true, multiline = false,
      }
      if st and st.submit and tonumber(txt) then
        local v = tonumber(txt)
        La[key] = v ~= 1 and v or nil
        commit(ed, win.path)
      end
    end
  end

  -- footer: + add · x del · ^ v reorder · rename(active)
  local fx = x0 + pad
  local function fbtn(label, w)
    local hot = ctx.hot and i.wx >= fx and i.wx < fx + w
                and i.wy >= footer_y and i.wy < footer_y + rowh
    pal.x_ig_rect_fill(fx, footer_y, w, rowh, COL.btn, 2 * z)
    pal.x_ig_text(fx + (w - pal.x_ig_text_size(label, fpx * 0.85, 0)) * 0.5,
                  footer_y + 1 * z, fpx * 0.85, hot and COL.hot or COL.dim,
                  label, 0)
    fx = fx + w + 2 * z
    return hot and i.clicked[1]
  end
  if fbtn("+", 13 * z) then win.layer = layer_add(doc); commit(ed, win.path) end
  if fbtn("x", 13 * z) and layer_del(doc, active) then
    win.layer = math.min(#doc.layers, active); commit(ed, win.path)
  end
  if fbtn("^", 12 * z) and layer_swap(doc, active, active + 1) then
    win.layer = active + 1; commit(ed, win.path)
  end
  if fbtn("v", 12 * z) and layer_swap(doc, active, active - 1) then
    win.layer = active - 1; commit(ed, win.path)
  end
  local rw = x0 + pw - pad - fx
  if rw > 20 * z and not ctx.occluded then
    local La = doc.layers[math.min(#doc.layers, active)]
    local txt, _, _, st = pal.x_ig_edit {
      id = "maplyrname" .. win.id, x = fx, y = footer_y + 1, w = rw,
      h = rowh - 2, text = La.name or "", px = fpx * 0.8, font = 1,
      enter = true, multiline = false,
    }
    if st and st.submit then La.name = txt; commit(ed, win.path) end
  end
end

local function draw_gizmos(p, view, sel, tool, csel, asel)
  local geom = p.geom
  local zoom, ox, oy = view.zoom, view.ox, view.oy
  local t = math.max(1, math.min(2.5, zoom))
  local doc = p.doc
  local function sx(x) return ox + x * zoom end
  local function sy(y) return oy + y * zoom end
  local function one(c, px0, py0, col_solid, col_ow)
    if c.kind == "circle" then
      pal.x_ig_circle(sx(c.cx + px0), sy(c.cy + py0), c.r * zoom, col_solid, t)
    elseif c.kind == "quad" then
      pal.x_ig_rect(sx(c.x + px0), sy(c.y + py0), c.w * zoom, c.h * zoom,
                    col_solid, t)
    else
      local v = c.verts
      local n = #v // 2
      local last = c.closed and n or n - 1
      for i = 1, last do
        local j = i % n + 1
        local ax, ay = sx(v[i * 2 - 1] + px0), sy(v[i * 2] + py0)
        local bx, by = sx(v[j * 2 - 1] + px0), sy(v[j * 2] + py0)
        if c.oneway then dashed(ax, ay, bx, by, col_ow, t)
        else pal.x_ig_line(ax, ay, bx, by, col_solid, t) end
      end
      for i = 1, n do -- vertex dots
        pal.x_ig_circle_fill(sx(v[i * 2 - 1] + px0), sy(v[i * 2] + py0),
                             math.max(1.5, t + 0.5),
                             c.oneway and col_ow or col_solid)
      end
    end
  end
  -- editing handles (the collider tool / a selected placement's attached):
  -- square knobs on every vertex, the selected one filled + grown; circles
  -- get a center knob + a radius knob on the ring's east point
  local function handles(c, px0, py0, selv)
    local r = math.max(2.5, t + 1.5)
    local function knob(kx, ky, on)
      if on then
        pal.x_ig_rect_fill(sx(kx) - r - 1, sy(ky) - r - 1,
                           2 * r + 2, 2 * r + 2, COL.hot)
      else
        pal.x_ig_rect_fill(sx(kx) - r, sy(ky) - r, 2 * r, 2 * r, COL.sel)
      end
    end
    if c.kind == "circle" then
      knob(c.cx + px0, c.cy + py0, false)
      knob(c.cx + c.r + px0, c.cy + py0, selv == 1)
    else
      local v = c.kind == "quad" and M.quad_verts(c) or c.verts
      for i = 1, #v // 2 do
        knob(v[i * 2 - 1] + px0, v[i * 2] + py0, selv == i)
      end
    end
  end
  for ci, c in ipairs(doc.colliders) do
    local on = csel and csel.c == ci
    one(c, 0, 0, on and COL.sel or COL.solid, on and COL.sel or COL.oneway)
    -- vertex handles: all colliders while drawing (col mode), else just the
    -- selected one (its grab points, move mode)
    if tool == "collider" or on then handles(c, 0, 0, on and csel.v or nil) end
  end
  for i, pl in ipairs(doc.places) do -- attached: dim until selected (§6)
    if pl.cols then
      local on = sel and M.sel_has(sel, { t = "place", i = i })
      local a = on and 0xff or 0x66
      for aci, c in ipairs(pl.cols) do
        local hot = on and asel and asel.c == aci
        one(c, pl.x, pl.y, hot and COL.sel or (COL.solid & ~0xff) | a,
            hot and COL.sel or (COL.oneway & ~0xff) | a)
        if on and tool == "move" then -- editable only while selected
          handles(c, pl.x, pl.y, hot and asel.v or nil)
        end
      end
    end
  end
end

-- marker extras <-> the one-line "k=v k2=v2" form (§6 inspector; pure)
function M.extras_fmt(extras)
  local out = {}
  for _, e in ipairs(extras or {}) do out[#out + 1] = e.k .. "=" .. e.v end
  return table.concat(out, " ")
end

function M.extras_parse(str)
  local out = {}
  for tok in str:gmatch("%S+") do
    local k, v = tok:match("^([^=]+)=(.*)$")
    if k then out[#out + 1] = { k = k, v = v } end
  end
  return #out > 0 and out or nil
end

-- the bg tint <-> "r g b" one-line form (map fields, R8e; pure). Tints
-- may exceed 1 (warm/HDR-ish multipliers); negatives make no sense.
function M.bg_fmt(bg)
  bg = bg or { 1, 1, 1 }
  return ("%.4g %.4g %.4g"):format(bg[1], bg[2], bg[3])
end

function M.bg_parse(str)
  local r, g, b = str:match("^%s*([%d.]+)%s+([%d.]+)%s+([%d.]+)%s*$")
  r, g, b = tonumber(r), tonumber(g), tonumber(b)
  if not (r and g and b) then return nil end
  return { r, g, b }
end

-- ---- content ----

function M.draw(win, ctx)
  local ed = ctx.ed
  local z = ctx.z
  local px = math.max(4, 11 * z)
  local i = cm.require("cm.ui").inp
  local g = ed.g

  -- unbound: the kit's new-file prompt (the field this generalized —
  -- forced .map, overwrite-aware; the spawn-menu path)
  if win.path == "" then
    A.pathfield(win, ed, ctx, {
      ext = "map", default = "maps/",
      label = "no map bound — drag a .map here, or type a path:",
    })
    return
  end

  local a, p = open_asset(ed, win.path)
  if p.err or not p.doc then
    pal.x_ig_text(ctx.cx + 8 * z, ctx.cy + 8 * z, px, COL.danger,
                  "unreadable .map: " .. tostring(p.err), 0)
    return
  end
  local doc = p.doc
  p.geom = p.geom or map.geom(doc)
  p.sel = p.sel or {}
  local dims = function(path) return tex_dims(ed, p, path) end
  local tmfn = function(path) return tm_doc(ed, p, path) end

  -- layout: canvas + the layer panel (right strip) + the inspector strip
  local INSP = math.max(10, 20 * z)
  local LPW = (win.lpanel ~= false) and math.max(78, 104 * z) or 0
  local cvx, cvy = ctx.cx, ctx.cy
  local cvh = ctx.ch - INSP - 2 * z
  local cvw = ctx.cw - (LPW > 0 and LPW + 4 * z or 0)
  if cvw < 60 or cvh < 60 then LPW, cvw = 0, ctx.cw end -- too small: no panel
  if cvw < 60 or cvh < 60 then return end

  -- view transform via cm.ed.winview — captured fields in WORLD units
  -- (win.zoom = world units per map px), so canvas zoom cancels out
  pal.x_ig_rect_fill(cvx, cvy, cvw, cvh, COL.well, 3 * z)
  local view = wv.view(win, z, cvx, cvy, cvw, cvh, doc.w, doc.h)
  local zoom, ox, oy = view.zoom, view.ox, view.oy
  p.view = view
  local function s2mx(sx2) return (sx2 - ox) / zoom end
  local function s2my(sy2) return (sy2 - oy) / zoom end

  pal.x_ig_clip_push(cvx, cvy, cvw, cvh)

  -- map bounds: bg tint well + border
  local bg = doc.bg or { 1, 1, 1 }
  local bgcol = (math.floor(bg[1] * 40) << 24) | (math.floor(bg[2] * 40) << 16)
                | (math.floor(bg[3] * 48) << 8) | 0xff
  pal.x_ig_rect_fill(ox, oy, doc.w * zoom, doc.h * zoom, bgcol)
  pal.x_ig_rect(ox - 1, oy - 1, doc.w * zoom + 2, doc.h * zoom + 2,
                COL.bounds, 1)

  -- colliders are collision-only: they show as GIZMOS (draw_gizmos, below),
  -- never as an auto graybox FILL (the human's call — map visuals are placed
  -- sprites/tilemaps; the fill was redundant with the gizmos + a perf sink).

  -- placements — layer z-order (bg behind foreground). A layer with
  -- vis=false is hidden in the EDITOR only (skip); a layer with on=false
  -- still shows here but dimmed (it won't exist in-game). Visual assets
  -- render their image, a dangling path a checkerboard, and every other
  -- kind (or a novis visual) a named-ref tag.
  local clip = { cvx, cvy, cvw, cvh }
  for _, n in ipairs(map.z_order(doc)) do
    local pl = doc.places[n]
    local Lyr = doc.layers[pl.layer or 1]
    if not (Lyr and Lyr.vis == false) then
      local x, y, w, h = M.place_rect(doc, n, dims)
      local sx0, sy0 = ox + x * zoom, oy + y * zoom
      if sx0 < cvx + cvw + 120 and sx0 + w * zoom > cvx - 120
         and sy0 < cvy + cvh + 40 and sy0 + h * zoom > cvy - 40 then
        draw_placement(ed, p, pl, sx0, sy0, w, h, zoom, z,
                       Lyr and Lyr.on == false, clip)
      end
    end
  end

  -- markers (the marker tool forces them visible; §6)
  local tool = win.tool or "move"
  if win.mk or tool == "marker" then
    for mi, mk in ipairs(doc.markers) do
      local sx0, sy0 = ox + mk.x * zoom, oy + mk.y * zoom
      pal.x_ig_rect(sx0, sy0, mk.w * zoom, mk.h * zoom, COL.marker,
                    math.max(1, 1.2 * z))
      pal.x_ig_text(sx0 + 2, sy0 + 1, math.max(4, 8.5 * z), COL.marker,
                    mk.kind, 0)
      if p.sel and #p.sel == 1 and p.sel[1].t == "marker"
         and p.sel[1].i == mi then -- resize knobs (move mode; any tool)
        local qv = M.quad_verts(mk) -- corner resize knobs
        local kr = math.max(2.5, math.min(2.5, zoom) + 1.5)
        for ki = 1, 4 do
          pal.x_ig_rect_fill(ox + qv[ki * 2 - 1] * zoom - kr,
                             oy + qv[ki * 2] * zoom - kr, 2 * kr, 2 * kr,
                             COL.marker)
        end
      end
    end
  end

  -- collider gizmos — always on by default (the human's call, §6);
  -- the collider tool adds editing handles + the selection accent.
  -- the attached selection is only alive while its single placement is
  -- (§6: editable only while the object is selected)
  local apl = #p.sel == 1 and p.sel[1].t == "place"
              and doc.places[p.sel[1].i] or nil
  if p.asel and not (tool == "move" and apl and apl.cols
                     and apl.cols[p.asel.c]) then
    p.asel = nil
  end
  if win.giz or tool == "collider" then
    draw_gizmos(p, view, p.sel, tool, p.csel, p.asel)
  end

  -- group hulls (teidraw, D061): a faint box around each group's bounds so
  -- "these move together" is legible; the selected group's hull brightens
  do
    local selgid = {}
    for _, it in ipairs(p.sel) do
      local gid = M.item_gid(doc, it)
      if gid then selgid[gid] = true end
    end
    local seen = {}
    local function hull(gid)
      if seen[gid] then return end
      seen[gid] = true
      local bx, by, bw, bh = M.sel_bounds(doc, M.group_members(doc, gid), dims)
      if bx then
        local on = selgid[gid]
        pal.x_ig_rect(ox + bx * zoom - 3, oy + by * zoom - 3,
                      bw * zoom + 6, bh * zoom + 6,
                      on and COL.grp_sel or COL.grp,
                      math.max(1, (on and 1.5 or 1) * z))
      end
    end
    for _, pl in ipairs(doc.places) do if pl.gid then hull(pl.gid) end end
    for _, mk in ipairs(doc.markers) do if mk.gid then hull(mk.gid) end end
  end

  -- selection outlines
  for _, it in ipairs(p.sel) do
    local x, y, w, h = item_rect(doc, it, dims)
    pal.x_ig_rect(ox + x * zoom - 1.5, oy + y * zoom - 1.5,
                  w * zoom + 3, h * zoom + 3, COL.sel,
                  math.max(1, 1.5 * z))
  end

  -- ---- interaction ----
  -- ctx.hot is the shell's one pointer gate (topmost banded hit, no
  -- shell gesture in flight); `over` adds "inside the VIEW rect" — the
  -- one gate every tool press-start uses, so header/inspector chips
  -- (which live outside the view) can never leak a press into a tool
  -- gesture (the col-chip bug, 2026-07-13)
  local over = ctx.hot and i.wx >= cvx and i.wx < cvx + cvw
               and i.wy >= cvy and i.wy < cvy + cvh
  local mx, my = s2mx(i.wx), s2my(i.wy)
  -- the active layer (new placements land here; teidraw auto-selects it
  -- from whatever you click) + the lock filter (interactions confined to
  -- the active layer when win.lock is on). Default = the topmost ENABLED
  -- layer, so a fresh drop lands somewhere it'll actually exist in-game.
  local nlayers = #doc.layers
  local active = win.layer
  if not active then
    active = nlayers
    for k = nlayers, 1, -1 do
      if doc.layers[k].on ~= false then active = k; break end
    end
  end
  active = math.min(nlayers, math.max(1, active))
  win.layer = active
  local lockL = win.lock and active or nil
  local snap_opts = function(skipset)
    return { dims = dims, tm = tmfn, thr = SNAP_PX / zoom,
             grid = win.grid or doc.grid or 8,
             skip = skipset and function(n) return skipset[n] end or nil }
  end
  -- point snap for the authoring tools (collider/marker): CTRL engages
  local function ptsnap(gx, gy, tg2, ax, ay)
    if not g.ctrl then
      p.guides = nil
      return math.floor(gx + 0.5), math.floor(gy + 0.5)
    end
    local sx2, sy2, gg = M.snap_pt(tg2, gx, gy,
      { thr = SNAP_PX / zoom, grid = win.grid or doc.grid or 8,
        ax = ax, ay = ay })
    p.guides = gg
    return sx2, sy2
  end

  -- middle-drag pans the view — focused only (focus is the one gate):
  -- the lock grabs from anywhere; an unfocused view is inert
  if ctx.focused and i.clicked[2] then
    p.pan = { mx = i.wx, my = i.wy, ox = ox, oy = oy }
  end
  if p.pan then
    if i.buttons[2] then
      wv.pan(win, view, p.pan.ox, p.pan.oy, i.wx - p.pan.mx,
             i.wy - p.pan.my)
      ctx.touch()
    else
      p.pan = nil
    end
  end

  -- the asset-carry ghost (drop preview + live snap during the carry)
  if g.adrag and g.adrag.moved and over and placeable(g.adrag.path) then
    local w, h = dims(g.adrag.path)
    local rx = math.floor(mx - w / 2 + 0.5)
    local ry = math.floor(my - h / 2 + 0.5)
    local guides
    if g.ctrl then
      local dx, dy, gg = M.snap_rect(doc, { x = rx, y = ry, w = w, h = h },
                                     snap_opts(nil))
      rx, ry, guides = rx + math.floor(dx + 0.5), ry + math.floor(dy + 0.5), gg
    end
    pal.x_ig_rect_fill(ox + rx * zoom, oy + ry * zoom, w * zoom, h * zoom,
                       COL.ghost)
    pal.x_ig_rect(ox + rx * zoom, oy + ry * zoom, w * zoom, h * zoom,
                  COL.sel, 1)
    p.drop_at = { x = rx, y = ry } -- kind.drop reuses the previewed spot
    if guides then p.guides = guides else p.guides = nil end
  elseif not p.g then
    p.drop_at = nil
  end

  -- ---- interaction: unified direct manipulation (teidraw, D061) ----
  -- One gesture-UPDATE block dispatched by gd.mode (tool-agnostic), a unified
  -- on-hit grab (grab_at — clicking ANY item selects + moves it, click-again
  -- drills to what's beneath), and a tool-specific EMPTY press (collider =
  -- draw, marker = new rect, select = marquee). Free-collider handles, the
  -- selected placement's attached handles, placements and markers all grab
  -- through the same path, so "click and drag it" is universal.
  local thr = 7 / zoom -- handle pick radius, map px
  local ct = win.ctype or "line"

  local click_used = false -- a click consumed by the line2 placement below

  -- the teidraw line grammar (D061): a 2-point line (drag-on-first-click OR
  -- click-then-click), then shift+click APPENDS points to the last line.
  local function new_line(x0, y0, x1, y1)
    doc.colliders[#doc.colliders + 1] = {
      kind = "chain", oneway = win.coneway or false, closed = false,
      verts = { x0, y0, x1, y1 } }
    p.csel = { c = #doc.colliders }
    p.lastcol = #doc.colliders
    commit(ed, win.path)
    ctx.touch()
  end
  local function append_pt(x, y)
    local c = p.lastcol and doc.colliders[p.lastcol]
    if not (c and c.kind == "chain") then return false end
    c.verts[#c.verts + 1] = x
    c.verts[#c.verts + 1] = y
    p.csel = { c = p.lastcol }
    commit(ed, win.path)
    ctx.touch()
    return true
  end

  -- the §7 edge-run (R8d): line tool + CTRL, idle — hovering a placed .tm's
  -- exposed tile edge proposes the WHOLE contiguous run; one click lays it.
  p.run = nil
  if tool == "collider" and not p.g and g.ctrl and over and ct == "line" then
    local vhit = M.col_pick(doc.colliders, mx, my, SNAP_PX / zoom)
    if not (vhit and vhit.v) then
      for n = #doc.places, 1, -1 do
        local pl = doc.places[n]
        local td = pl.vis ~= false and tmfn(pl.path)
        if td then
          local rx0, ry0, rx1, ry1 =
            tmap.edge_run(td, mx - pl.x, my - pl.y, SNAP_PX / zoom)
          if rx0 then
            p.run = { rx0 + pl.x, ry0 + pl.y, rx1 + pl.x, ry1 + pl.y }
            break
          end
        end
      end
    end
  end
  if p.run then
    local r = p.run
    local lt = math.max(1.5, math.min(2.5, zoom))
    pal.x_ig_line(ox + r[1] * zoom, oy + r[2] * zoom,
                  ox + r[3] * zoom, oy + r[4] * zoom, COL.guide, lt)
    pal.x_ig_circle_fill(ox + r[1] * zoom, oy + r[2] * zoom, 3.5, COL.guide)
    pal.x_ig_circle_fill(ox + r[3] * zoom, oy + r[4] * zoom, 3.5, COL.guide)
  end

  -- the line placement preview: "line2" waits for the 2nd click (rubber-band
  -- from point A); shift-over-empty previews the append from the last vertex
  if tool == "collider" and ct == "line" then
    local lt = math.max(1, math.min(2.5, zoom))
    if p.g and p.g.mode == "line2" then
      local gd = p.g
      gd.cx, gd.cy = ptsnap(mx, my, gd.tg, gd.x0, gd.y0)
      pal.x_ig_line(ox + gd.x0 * zoom, oy + gd.y0 * zoom,
                    ox + gd.cx * zoom, oy + gd.cy * zoom, COL.guide, lt)
      pal.x_ig_circle_fill(ox + gd.x0 * zoom, oy + gd.y0 * zoom,
                           math.max(2, lt + 1), COL.sel)
      if over and i.clicked[1] and not p.pan then
        p.g = nil
        click_used = true
        if gd.cx ~= gd.x0 or gd.cy ~= gd.y0 then
          new_line(gd.x0, gd.y0, gd.cx, gd.cy)
        end
      end
    elseif not p.g and g.shift and over and p.lastcol
           and doc.colliders[p.lastcol]
           and doc.colliders[p.lastcol].kind == "chain" then
      local c = doc.colliders[p.lastcol]
      local ax, ay = c.verts[#c.verts - 1], c.verts[#c.verts]
      local cx, cy = ptsnap(mx, my, M.snap_targets(doc,
                       { dims = dims, tm = tmfn }), ax, ay)
      pal.x_ig_line(ox + ax * zoom, oy + ay * zoom, ox + cx * zoom,
                    oy + cy * zoom, COL.guide, lt)
      pal.x_ig_circle_fill(ox + cx * zoom, oy + cy * zoom,
                           math.max(2, lt + 1), COL.ghost)
      p.append_at = { cx, cy } -- the press-start reuses this exact spot
    end
  end
  if not (tool == "collider" and g.shift) then p.append_at = nil end

  -- ---- idle affordances (the human's ask): in MOVE, highlight the item the
  -- cursor is over (= what a click grabs); in COL / MARKER, a cursor ghost so
  -- the placement mode is unmistakable ----
  if over and not p.g and not p.pan and not (g.adrag and g.adrag.moved) then
    local fcx, fcy = math.floor(mx + 0.5), math.floor(my + 0.5)
    local scx, scy = ox + fcx * zoom, oy + fcy * zoom
    if tool == "move" then
      local hit = M.hit_stack(doc, mx, my, dims,
        { thr = thr, with_markers = win.mk, only_layer = lockL })[1]
      if hit then
        local lt = math.max(1, 1.6 * z)
        if hit.t == "place" or hit.t == "marker" then
          local hx, hy, hw, hh = item_rect(doc, hit, dims)
          pal.x_ig_rect(ox + hx * zoom - 2, oy + hy * zoom - 2,
                        hw * zoom + 4, hh * zoom + 4, COL.hot, lt)
        elseif hit.t == "cvert" then
          pal.x_ig_circle(ox + hit.x * zoom, oy + hit.y * zoom,
                          math.max(4, 4.5 * z), COL.hot, lt)
        elseif hit.t == "cedge" then
          pal.x_ig_circle_fill(ox + hit.x * zoom, oy + hit.y * zoom,
                               math.max(3, 3.5 * z), COL.hot)
        end
      end
    elseif tool == "collider" and not p.run and not p.append_at then
      -- crosshair + landing dot: "click to place a collider here"
      local col = win.coneway and COL.oneway or COL.solid
      local r = math.max(5, 7 * z)
      pal.x_ig_line(scx - r, scy, scx + r, scy, col, 1)
      pal.x_ig_line(scx, scy - r, scx, scy + r, col, 1)
      pal.x_ig_circle_fill(scx, scy, math.max(2, 2.5 * z), col)
    elseif tool == "marker" then
      -- a ghost marker box: "drag from here to place a marker"
      local gsz = win.grid or doc.grid or 8
      pal.x_ig_rect_fill(scx, scy, gsz * zoom, gsz * zoom,
                         (COL.marker & ~0xff) | 0x22)
      pal.x_ig_rect(scx, scy, gsz * zoom, gsz * zoom, COL.marker, 1)
    end
  end

  -- ---- (1) live gesture UPDATE — dispatched by gd.mode, tool-agnostic ----
  if p.g and p.g.mode ~= "line2" then
    local gd = p.g
    if gd.mode == "press" then
      -- a grab was armed on press: drag past the threshold starts the move;
      -- a still release is a click (selection is already set; a double-click
      -- on a placement opens its editor)
      if math.abs(i.wx - gd.sx) > 4 or math.abs(i.wy - gd.sy) > 4 then
        gd.mode = gd.next
        gd.mutates = true
      elseif not i.buttons[1] then
        if gd.item and gd.item.t == "place" then
          local now = pal.time_ns()
          local dbl = p.click and p.click.it and p.click.it.t == "place"
                      and p.click.it.i == gd.item.i
                      and now - p.click.t < 320 * 1e6
          p.click = { t = now, it = gd.item }
          if dbl then
            local path = doc.places[gd.item.i].path
            if cm.require("cm.ed.win.assets").kind_for(path) then
              ed.open_asset_window(path, win.x + win.w + 20, win.y)
            end
          end
        end
        p.g = nil
        ctx.touch()
      end
    elseif gd.mode == "dpress" then
      -- collider quad/circle draw: threshold to start, still-click deselects
      if math.abs(i.wx - gd.sx) > 4 or math.abs(i.wy - gd.sy) > 4 then
        gd.mode = gd.drag
      elseif not i.buttons[1] then
        p.csel = nil
        p.g = nil
        ctx.touch()
      end
    elseif gd.mode == "linepress" then
      -- the teidraw line: drag past the threshold = drag-place a 2-pt line;
      -- a still-click = point A set, wait for the 2nd click (line2)
      if math.abs(i.wx - gd.sx) > 4 or math.abs(i.wy - gd.sy) > 4 then
        gd.mode = "lineseg"
      elseif not i.buttons[1] then
        gd.mode = "line2"
        gd.cx, gd.cy = gd.x0, gd.y0
      end
    elseif gd.mode == "lineseg" then
      -- drag-place: rubber-band a 2-point line from A to the snapped cursor
      local nx, ny = ptsnap(mx, my, gd.tg, gd.x0, gd.y0)
      gd.cx, gd.cy = nx, ny
      local lt = math.max(1, math.min(2.5, zoom))
      pal.x_ig_line(ox + gd.x0 * zoom, oy + gd.y0 * zoom,
                    ox + nx * zoom, oy + ny * zoom, COL.sel, lt)
      pal.x_ig_circle_fill(ox + gd.x0 * zoom, oy + gd.y0 * zoom,
                           math.max(2, lt + 1), COL.sel)
      if not i.buttons[1] then
        p.g, p.guides = nil, nil
        if nx ~= gd.x0 or ny ~= gd.y0 then new_line(gd.x0, gd.y0, nx, ny) end
        ctx.touch()
      end
    elseif gd.mode == "move" then
      if i.buttons[1] then
        local rdx, rdy = (i.wx - gd.sx) / zoom, (i.wy - gd.sy) / zoom
        local ax, ay = gd.ax0 + rdx, gd.ay0 + rdy
        p.guides = nil
        if g.ctrl then
          local dx, dy, gg = M.snap_rect(doc,
            { x = ax, y = ay, w = gd.aw, h = gd.ah }, snap_opts(gd.skipset))
          ax, ay, p.guides = ax + dx, ay + dy, gg
        end
        local idx = math.floor(ax - gd.ax0 + 0.5)
        local idy = math.floor(ay - gd.ay0 + 0.5)
        for _, it in ipairs(gd.items) do
          it.ref.x, it.ref.y = it.x0 + idx, it.y0 + idy
        end
        gd.moved = idx ~= 0 or idy ~= 0 or gd.moved
        ctx.touch()
      else
        if gd.moved then commit(ed, win.path) end
        p.guides, p.g = nil, nil
      end
    elseif gd.mode == "marquee" then
      gd.mx1, gd.my1 = mx, my
      pal.x_ig_rect_fill(ox + math.min(gd.mx0, gd.mx1) * zoom,
                         oy + math.min(gd.my0, gd.my1) * zoom,
                         math.abs(gd.mx1 - gd.mx0) * zoom,
                         math.abs(gd.my1 - gd.my0) * zoom, 0x7fd8a818)
      pal.x_ig_rect(ox + math.min(gd.mx0, gd.mx1) * zoom,
                    oy + math.min(gd.my0, gd.my1) * zoom,
                    math.abs(gd.mx1 - gd.mx0) * zoom,
                    math.abs(gd.my1 - gd.my0) * zoom, COL.sel, 1)
      if not i.buttons[1] then
        local still = math.abs(i.wx - gd.sx) <= 4 and math.abs(i.wy - gd.sy) <= 4
        p.sel = still and {}
                or M.pick_rect(doc, gd.mx0, gd.my0, gd.mx1, gd.my1, dims,
                               win.mk, lockL)
        p.csel, p.g = nil, nil
        if gd.ret then win.tool = gd.ret end -- box-select → back to move
        ctx.touch()
      end
    elseif gd.mode == "cvert" then
      if i.buttons[1] then
        local c = doc.colliders[gd.hit.c]
        local nx, ny = ptsnap(mx, my, gd.tg, gd.ax, gd.ay)
        if c.kind == "chain" then
          c.verts[gd.hit.v * 2 - 1], c.verts[gd.hit.v * 2] = nx, ny
        elseif c.kind == "quad" then
          M.quad_drag(c, gd.r0, gd.hit.v, nx, ny)
        else
          local dx, dy = nx - c.cx, ny - c.cy
          c.r = math.max(1, math.floor((dx * dx + dy * dy) ^ 0.5 + 0.5))
        end
        gd.moved = true
        ctx.touch()
      else
        if gd.moved then commit(ed, win.path) end
        p.g, p.guides = nil, nil
      end
    elseif gd.mode == "cwhole" then
      if i.buttons[1] then
        local c = doc.colliders[gd.hit.c]
        local nx, ny = ptsnap(gd.gx0 + (i.wx - gd.sx) / zoom,
                              gd.gy0 + (i.wy - gd.sy) / zoom, gd.tg)
        M.col_offset(c, gd.orig, nx - gd.gx0, ny - gd.gy0)
        gd.moved = true
        ctx.touch()
      else
        if gd.moved then commit(ed, win.path) end
        p.g, p.guides = nil, nil
      end
    elseif gd.mode == "avert" or gd.mode == "awhole" then
      if i.buttons[1] and apl then
        local c = apl.cols[gd.hit.c]
        local gx, gy = mx, my
        if gd.mode == "awhole" then
          gx = gd.gx0 + (i.wx - gd.sx) / zoom
          gy = gd.gy0 + (i.wy - gd.sy) / zoom
        end
        local nx, ny
        if g.ctrl then
          local gg
          nx, ny, gg = M.snap_pt(gd.tg, gx, gy,
            { thr = SNAP_PX / zoom, grid = win.grid or doc.grid or 8,
              ax = gd.ax, ay = gd.ay })
          p.guides = gg
        else
          p.guides = nil
          nx, ny = math.floor(gx + 0.5), math.floor(gy + 0.5)
        end
        if gd.mode == "awhole" then
          M.col_offset(c, gd.orig, nx - gd.gx0, ny - gd.gy0)
        elseif c.kind == "chain" then
          c.verts[gd.hit.v * 2 - 1] = nx - apl.x
          c.verts[gd.hit.v * 2] = ny - apl.y
        elseif c.kind == "quad" then
          M.quad_drag(c, gd.r0, gd.hit.v, nx - apl.x, ny - apl.y)
        else
          local dx, dy = nx - apl.x - c.cx, ny - apl.y - c.cy
          c.r = math.max(1, math.floor((dx * dx + dy * dy) ^ 0.5 + 0.5))
        end
        gd.moved = true
        ctx.touch()
      else
        if gd.moved then commit(ed, win.path) end
        p.g, p.guides = nil, nil
      end
    elseif gd.mode == "mmove" then
      if i.buttons[1] then
        local nx = gd.orig.x + (i.wx - gd.sx) / zoom
        local ny = gd.orig.y + (i.wy - gd.sy) / zoom
        p.guides = nil
        if g.ctrl then
          local dx, dy, gg = M.snap_rect(doc,
            { x = nx, y = ny, w = gd.orig.w, h = gd.orig.h }, snap_opts(nil))
          nx, ny, p.guides = nx + dx, ny + dy, gg
        end
        local mk2 = doc.markers[gd.item.i]
        mk2.x, mk2.y = math.floor(nx + 0.5), math.floor(ny + 0.5)
        gd.moved = true
        ctx.touch()
      else
        if gd.moved then commit(ed, win.path) end
        p.g, p.guides = nil, nil
      end
    elseif gd.mode == "mresz" then
      local smk = doc.markers[gd.item.i]
      if i.buttons[1] and smk then
        local nx, ny = ptsnap(mx, my, gd.tg)
        M.quad_drag(smk, gd.r0, gd.corner, nx, ny)
        gd.moved = true
        ctx.touch()
      else
        if gd.moved then commit(ed, win.path) end
        p.g, p.guides = nil, nil
      end
    elseif gd.mode == "mnew" then
      local nx, ny = ptsnap(mx, my, gd.tg)
      local x0, x1 = math.min(gd.x0, nx), math.max(gd.x0, nx)
      local y0, y1 = math.min(gd.y0, ny), math.max(gd.y0, ny)
      pal.x_ig_rect(ox + x0 * zoom, oy + y0 * zoom, (x1 - x0) * zoom,
                    (y1 - y0) * zoom, COL.marker, math.max(1, 1.2 * z))
      if not i.buttons[1] then
        p.g, p.guides = nil, nil
        if x1 - x0 >= 2 and y1 - y0 >= 2 then
          doc.markers[#doc.markers + 1] = { x = x0, y = y0, w = x1 - x0,
            h = y1 - y0, kind = "marker", label = "", note = "" }
          p.sel = { { t = "marker", i = #doc.markers } }
          commit(ed, win.path)
        end
        ctx.touch()
      end
    elseif gd.mode == "quadd" or gd.mode == "circd" then
      local nx, ny = ptsnap(mx, my, gd.tg)
      gd.cx, gd.cy = nx, ny
      local lt = math.max(1, math.min(2.5, zoom))
      if gd.mode == "quadd" then
        local x0, x1 = math.min(gd.x0, nx), math.max(gd.x0, nx)
        local y0, y1 = math.min(gd.y0, ny), math.max(gd.y0, ny)
        pal.x_ig_rect(ox + x0 * zoom, oy + y0 * zoom, (x1 - x0) * zoom,
                      (y1 - y0) * zoom, COL.sel, lt)
        if not i.buttons[1] then
          p.g, p.guides = nil, nil
          if x1 - x0 >= 1 and y1 - y0 >= 1 then
            doc.colliders[#doc.colliders + 1] = {
              kind = "quad", x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
            p.csel = { c = #doc.colliders }
            p.lastcol = #doc.colliders
            commit(ed, win.path)
          end
          ctx.touch()
        end
      else
        local dx, dy = nx - gd.x0, ny - gd.y0
        local r = math.floor((dx * dx + dy * dy) ^ 0.5 + 0.5)
        pal.x_ig_circle(ox + gd.x0 * zoom, oy + gd.y0 * zoom, r * zoom,
                        COL.sel, lt)
        if not i.buttons[1] then
          p.g, p.guides = nil, nil
          if r >= 1 then
            doc.colliders[#doc.colliders + 1] = {
              kind = "circle", cx = gd.x0, cy = gd.y0, r = r }
            p.csel = { c = #doc.colliders }
            p.lastcol = #doc.colliders
            commit(ed, win.path)
          end
          ctx.touch()
        end
      end
    end
  end

  -- ---- (2) the unified on-hit grab (drill + select + arm) ----
  -- returns true if it armed a grab on an existing item; false = empty point
  local function grab_at()
    -- the selected placement's attached handles rank on top (selected-only
    -- editing, §6) — they sit over the sprite
    local ahit = apl and apl.cols
                 and M.col_pick(apl.cols, mx, my, thr, apl.x, apl.y)
    if ahit and not g.shift then
      p.drill = nil
      local pi = p.sel[1].i
      local c = apl.cols[ahit.c]
      local gd = { mode = "press", sx = i.wx, sy = i.wy, hit = ahit }
      if ahit.v then
        gd.next = "avert"
        if c.kind == "chain" then
          gd.tg = M.snap_targets(doc, { dims = dims, tm = tmfn,
                    skipv = { o = pi, c = ahit.c, v = ahit.v } })
          local n = #c.verts // 2
          local pv = ahit.v > 1 and ahit.v - 1
                     or (c.closed and n or ahit.v + 1)
          if pv >= 1 and pv <= n and pv ~= ahit.v then
            gd.ax = c.verts[pv * 2 - 1] + apl.x
            gd.ay = c.verts[pv * 2] + apl.y
          end
        elseif c.kind == "quad" then
          gd.tg = M.snap_targets(doc, { dims = dims, tm = tmfn,
                    skipv = { o = pi, c = ahit.c } })
          gd.r0 = { x = c.x, y = c.y, w = c.w, h = c.h }
        else
          gd.tg = { verts = {}, segs = {} }
        end
      else
        gd.next = "awhole"
        gd.gx0, gd.gy0 = ahit.x, ahit.y
        gd.tg = M.snap_targets(doc, { dims = dims, tm = tmfn,
                  skipv = { o = pi, c = ahit.c } })
        if c.kind == "circle" then gd.orig = { cx = c.cx, cy = c.cy }
        elseif c.kind == "quad" then gd.orig = { x = c.x, y = c.y }
        else
          local vv = {}
          for k, val in ipairs(c.verts) do vv[k] = val end
          gd.orig = { verts = vv }
        end
      end
      p.g = gd
      ctx.touch()
      return true
    end

    local stack = M.hit_stack(doc, mx, my, dims,
      { thr = thr, with_markers = (win.mk or tool == "marker"),
        only_layer = lockL })
    if #stack == 0 then p.drill = nil; return false end
    -- expand into the drill CHAIN (group levels inserted) and step through it
    local chain = M.drill_chain(doc, stack)
    local k, drill = M.drill_pick(chain, p.drill, i.wx, i.wy, 5)
    p.drill = drill
    local it = chain[k]

    -- a GROUP level: select every member, arm the move over the whole set
    if it.t == "group" then
      p.csel, p.asel = nil, nil
      p.sel = it.members
      local items, skipset = {}, {}
      for _, s in ipairs(p.sel) do
        local o = s.t == "place" and doc.places[s.i] or doc.markers[s.i]
        items[#items + 1] = { ref = o, x0 = o.x, y0 = o.y }
        if s.t == "place" then skipset[s.i] = true end
      end
      local bx, by, bw, bh = M.sel_bounds(doc, p.sel, dims)
      p.g = { mode = "press", next = "move", item = it, items = items,
              skipset = skipset, sx = i.wx, sy = i.wy,
              ax0 = bx or 0, ay0 = by or 0, aw = bw or 0, ah = bh or 0 }
      ctx.touch()
      return true
    end

    -- a free collider: vertex = move that point, edge = move both/all points
    if it.t == "cvert" or it.t == "cedge" then
      p.sel, p.asel = {}, nil
      local c = doc.colliders[it.c]
      local gd = { mode = "press", sx = i.wx, sy = i.wy,
                   hit = { c = it.c, v = it.v, e = it.e, x = it.x, y = it.y } }
      if it.t == "cvert" then
        p.csel = { c = it.c, v = it.v }
        gd.next = "cvert"
        if c.kind == "chain" then
          gd.tg = M.snap_targets(doc, { dims = dims, tm = tmfn,
                    skipv = { o = 0, c = it.c, v = it.v } })
          local n = #c.verts // 2
          local pv = it.v > 1 and it.v - 1 or (c.closed and n or it.v + 1)
          if pv >= 1 and pv <= n and pv ~= it.v then
            gd.ax, gd.ay = c.verts[pv * 2 - 1], c.verts[pv * 2]
          end
        elseif c.kind == "quad" then
          gd.tg = M.snap_targets(doc, { dims = dims, tm = tmfn,
                    skipv = { o = 0, c = it.c } })
          gd.r0 = { x = c.x, y = c.y, w = c.w, h = c.h }
        else
          gd.tg = { verts = {}, segs = {} }
        end
      else
        p.csel = { c = it.c }
        gd.next = "cwhole"
        gd.gx0, gd.gy0 = it.x, it.y
        gd.tg = M.snap_targets(doc, { dims = dims, tm = tmfn,
                  skipv = { o = 0, c = it.c } })
        if c.kind == "circle" then gd.orig = { cx = c.cx, cy = c.cy }
        elseif c.kind == "quad" then gd.orig = { x = c.x, y = c.y }
        else
          local vv = {}
          for kk, val in ipairs(c.verts) do vv[kk] = val end
          gd.orig = { verts = vv }
        end
      end
      p.g = gd
      ctx.touch()
      return true
    end

    -- a placement or marker: select (shift toggles) + arm the move
    p.csel = nil
    if it.t == "place" then win.layer = doc.places[it.i].layer or active end
    -- a grouped member reached HERE = a drill-in past its group level: select
    -- just this member and move it alone (teidraw "click again to move within")
    if M.item_gid(doc, it) then
      p.sel = { it }
      local o = it.t == "place" and doc.places[it.i] or doc.markers[it.i]
      local ax, ay, aw, ah = item_rect(doc, it, dims)
      p.g = { mode = "press", next = "move", item = it,
              items = { { ref = o, x0 = o.x, y0 = o.y } },
              skipset = (it.t == "place") and { [it.i] = true } or {},
              sx = i.wx, sy = i.wy, ax0 = ax, ay0 = ay, aw = aw, ah = ah }
      ctx.touch()
      return true
    end
    if g.shift then
      local at = M.sel_has(p.sel, it)
      if at then table.remove(p.sel, at) else p.sel[#p.sel + 1] = it end
      ctx.touch()
      return true
    end
    local was = M.sel_has(p.sel, it) ~= nil
    if not was then p.sel = { it } end
    -- a re-grab of the selected marker's corner knob resizes it
    if it.t == "marker" and was and #p.sel == 1 then
      local mk = doc.markers[it.i]
      local qv = M.quad_verts(mk)
      local corner, cd2
      for ki = 1, 4 do
        local dx, dy = mx - qv[ki * 2 - 1], my - qv[ki * 2]
        local d2 = dx * dx + dy * dy
        if d2 <= thr * thr and (not cd2 or d2 < cd2) then corner, cd2 = ki, d2 end
      end
      if corner then
        p.g = { mode = "press", next = "mresz", corner = corner,
                sx = i.wx, sy = i.wy, item = it,
                tg = M.snap_targets(doc, { dims = dims, tm = tmfn }),
                r0 = { x = mk.x, y = mk.y, w = mk.w, h = mk.h } }
        ctx.touch()
        return true
      end
    end
    if it.t == "marker" and #p.sel == 1 then
      local mk = doc.markers[it.i]
      p.g = { mode = "press", next = "mmove", item = it, sx = i.wx, sy = i.wy,
              orig = { x = mk.x, y = mk.y, w = mk.w, h = mk.h } }
      ctx.touch()
      return true
    end
    -- arm the move over the whole (possibly multi) placement/marker selection
    local items, skipset = {}, {}
    for _, s in ipairs(p.sel) do
      local o = s.t == "place" and doc.places[s.i] or doc.markers[s.i]
      items[#items + 1] = { ref = o, x0 = o.x, y0 = o.y }
      if s.t == "place" then skipset[s.i] = true end
    end
    local ax, ay, aw, ah = item_rect(doc, it, dims)
    p.g = { mode = "press", next = "move", item = it,
            items = items, skipset = skipset, sx = i.wx, sy = i.wy,
            ax0 = ax, ay0 = ay, aw = aw, ah = ah }
    ctx.touch()
    return true
  end

  -- ---- (3) PRESS-START: grab an item, else the tool's empty-press ----
  if over and i.clicked[1] and not p.pan and not p.g and not click_used then
    if tool == "collider" then
      local lastc = ct == "line" and p.lastcol and doc.colliders[p.lastcol]
      if g.shift and lastc and lastc.kind == "chain" then
        -- shift+click EXTENDS the last line (teidraw): append a snapped point
        local cx, cy
        if p.append_at then cx, cy = p.append_at[1], p.append_at[2]
        else
          local ax, ay = lastc.verts[#lastc.verts - 1], lastc.verts[#lastc.verts]
          cx, cy = ptsnap(mx, my, M.snap_targets(doc, { dims = dims, tm = tmfn }),
                          ax, ay)
        end
        append_pt(cx, cy)
      elseif p.run then
        -- the edge-run: one click lays the whole segment (§7-R8d)
        new_line(p.run[1], p.run[2], p.run[3], p.run[4])
        p.run = nil
      else
        -- col mode PLACES only — it never grabs existing items; move/edit
        -- anything in the SELECT tool (the human's ask). Draw the strip type.
        p.csel = nil
        local tg = M.snap_targets(doc, { dims = dims, tm = tmfn })
        local x0, y0 = ptsnap(mx, my, tg)
        if ct == "line" then
          -- ambiguous press: a drag = drag-place a 2-pt line, a still-click
          -- = point A (then line2 waits for the 2nd click)
          p.g = { mode = "linepress", x0 = x0, y0 = y0, tg = tg,
                  sx = i.wx, sy = i.wy }
        else
          p.g = { mode = "dpress", drag = ct == "quad" and "quadd" or "circd",
                  sx = i.wx, sy = i.wy, tg = tg, x0 = x0, y0 = y0 }
        end
        ctx.touch()
      end
    elseif tool == "marker" then
      -- marker mode PLACES only (drag a new rect); move/resize in move mode
      local tg = M.snap_targets(doc, { dims = dims, tm = tmfn })
      local x0, y0 = ptsnap(mx, my, tg)
      p.sel = {}
      p.g = { mode = "mnew", x0 = x0, y0 = y0, tg = tg, sx = i.wx, sy = i.wy }
      ctx.touch()
    elseif tool == "sel" then
      -- box select (the human's ask): drag a marquee, then RETURN to move so
      -- you immediately manipulate what you selected. `ret` carries that.
      p.csel = nil
      p.g = { mode = "marquee", sx = i.wx, sy = i.wy, ret = "move",
              mx0 = mx, my0 = my, mx1 = mx, my1 = my }
      ctx.touch()
    else -- "move": unified direct manipulation — click grabs, empty deselects
      if not grab_at() then
        p.sel, p.csel, p.drill = {}, nil, nil
        ctx.touch()
      end
    end
  end

  -- snap guides
  if p.guides then
    for _, gl in ipairs(p.guides) do
      if gl.t == "dot" then
        pal.x_ig_circle_fill(ox + gl.x * zoom, oy + gl.y * zoom, 3.5, COL.guide)
      elseif gl.t == "v" then
        pal.x_ig_line(ox + gl.x * zoom, cvy, ox + gl.x * zoom, cvy + cvh,
                      COL.guide, 1)
      elseif gl.t == "seg" or gl.t == "ray" then -- the snapped edge / 45 ray
        pal.x_ig_line(ox + gl.x0 * zoom, oy + gl.y0 * zoom,
                      ox + gl.x1 * zoom, oy + gl.y1 * zoom, COL.guide, 1)
      else
        pal.x_ig_line(cvx, oy + gl.y * zoom, cvx + cvw, oy + gl.y * zoom,
                      COL.guide, 1)
      end
    end
  end

  -- keys (the tool's — the shell's plain hotkeys suspend via wants_keys)
  if ctx.focused and not ctx.ig.kb and not ctx.alt then
    for _, e in ipairs(i.keys) do
      -- D135: the nudge arrows and z-order brackets are stepping actions
      -- and repeat while held; everything else (modes, del, clipboard,
      -- fits) stays edge-triggered
      if e.down and (not e.rep
                     or (e.scancode >= KEY.right and e.scancode <= KEY.up)
                     or e.scancode == KEY.rbracket
                     or e.scancode == KEY.lbracket) then
        local sc = e.scancode
        if sc == KEY.n1 and g.shift then
          wv.reset(win)
          ctx.touch()
        elseif sc == KEY.n2 and g.shift then
          -- shift+2: fit the selection (select/marker sel, or the
          -- selected free collider)
          local bx, by, bw, bh
          if #p.sel > 0 then
            bx, by, bw, bh = M.sel_bounds(doc, p.sel, dims)
          elseif p.csel and doc.colliders[p.csel.c] then
            bx, by, bw, bh = M.col_bounds(doc.colliders[p.csel.c])
          end
          if bx then
            bw, bh = math.max(bw, 4), math.max(bh, 4)
            local s = math.min(cvw / (bw + 16), cvh / (bh + 16))
            s = math.max(0.05 * z, math.min(32 * z, s))
            win.zoom = s / z
            win.px = ((cvw - bw * s) * 0.5 - bx * s) / z
            win.py = ((cvh - bh * s) * 0.5 - by * s) / z
            ctx.touch()
          end
        elseif g.ctrl and sc == KEY.g and not p.g then
          -- ctrl+g groups the selection · ctrl+shift+g ungroups (teidraw)
          if g.shift then
            if M.ungroup_sel(doc, p.sel) then p.drill = nil
              commit(ed, win.path) end
          else
            if M.group_sel(doc, p.sel) then p.drill = nil
              commit(ed, win.path) end
          end
        elseif g.ctrl and sc == KEY.a and not p.g then
          p.sel = M.all_items(doc)
          p.csel, p.asel = nil, nil
          ctx.touch()
        elseif g.ctrl and sc == KEY.c and #p.sel > 0 then
          g.mapclip = M.copy_sel(doc, p.sel)
        elseif g.ctrl and sc == KEY.x and #p.sel > 0 and not p.g then
          g.mapclip = M.copy_sel(doc, p.sel)
          M.del(doc, p.sel)
          p.sel = {}
          commit(ed, win.path)
        elseif g.ctrl and (sc == KEY.v or sc == KEY.d) and not p.g then
          -- paste lands centered under the cursor when it's over the
          -- view; dup (and off-view paste) offsets by the grid step
          local clip = sc == KEY.d and #p.sel > 0 and M.copy_sel(doc, p.sel)
                       or sc == KEY.v and g.mapclip or nil
          if clip then
            local step = win.grid or doc.grid or 8
            local dx, dy = step, step
            if sc == KEY.v and over then
              local bx, by, bw, bh = M.clip_bounds(clip, dims)
              if bx then
                dx = math.floor(mx - bx - bw / 2 + 0.5)
                dy = math.floor(my - by - bh / 2 + 0.5)
              end
            end
            p.sel = M.paste(doc, clip, dx, dy)
            commit(ed, win.path)
          end
        elseif not g.ctrl and (sc == KEY.c or sc == KEY.v or sc == KEY.m) then
          -- mode keys (the human's ask): c = col · v = box-select · m = markers
          -- (esc → move). A switch drops the live gesture + collider selection.
          if p.g and p.g.mutates then decode_into(p, working(ed, win.path).map) end
          p.g, p.guides, p.csel = nil, nil, nil
          win.tool = sc == KEY.c and "collider" or sc == KEY.v and "sel"
                     or "marker"
          ctx.touch()
        elseif p.csel and not p.g then
          -- a selected free collider (any tool now — direct manipulation)
          if sc >= KEY.right and sc <= KEY.up then
            local d = g.shift and 8 or 1
            local dx = (sc == KEY.right and d) or (sc == KEY.left and -d) or 0
            local dy = (sc == KEY.down and d) or (sc == KEY.up and -d) or 0
            if M.col_nudge(doc.colliders, p.csel, dx, dy) then
              commit(ed, win.path)
            end
          elseif sc == KEY.del or sc == KEY.backspace then
            if M.col_del(doc.colliders, p.csel) then
              p.csel = nil
              commit(ed, win.path)
            end
          end
        elseif p.asel and apl and sc >= KEY.right and sc <= KEY.up then
          local d = g.shift and 8 or 1
          local dx = (sc == KEY.right and d) or (sc == KEY.left and -d) or 0
          local dy = (sc == KEY.down and d) or (sc == KEY.up and -d) or 0
          if M.col_nudge(apl.cols, p.asel, dx, dy) then
            commit(ed, win.path)
          end
        elseif p.asel and apl and (sc == KEY.del or sc == KEY.backspace)
               and not p.g then
          -- del with an attached handle selected removes the collider (§6)
          table.remove(apl.cols, p.asel.c)
          if #apl.cols == 0 then apl.cols = nil end
          p.asel = nil
          commit(ed, win.path)
        elseif sc >= KEY.right and sc <= KEY.up and #p.sel > 0 then
          local d = g.shift and 8 or 1
          local dx = (sc == KEY.right and d) or (sc == KEY.left and -d) or 0
          local dy = (sc == KEY.down and d) or (sc == KEY.up and -d) or 0
          M.nudge(doc, p.sel, dx, dy)
          commit(ed, win.path)
        elseif (sc == KEY.del or sc == KEY.backspace) and #p.sel > 0
               and not p.g then
          M.del(doc, p.sel)
          p.sel = {}
          commit(ed, win.path)
        elseif sc == KEY.rbracket and #p.sel > 0 then
          if M.zmove(doc, p.sel, 1) then commit(ed, win.path) end
        elseif sc == KEY.lbracket and #p.sel > 0 then
          if M.zmove(doc, p.sel, -1) then commit(ed, win.path) end
        end
      end
    end
  end

  -- authored coordinate + zoom + grid, canvas corner. The coordinate is the
  -- map pixel under the cursor (not a screen/canvas coordinate); ctrl+wheel's
  -- grid-dial grammar lives in the reference + hint strip so the bay stays
  -- compact enough for narrow map windows.
  local chip = M.view_status(mx, my, over, zoom, win.grid or doc.grid or 8)
  local cw2 = pal.x_ig_text_size(chip, px * 0.85, 0)
  pal.x_ig_text(cvx + cvw - cw2 - 6 * z, cvy + 4 * z, px * 0.85, COL.dim,
                chip, 0)

  -- the focus lock, unmissable (the PLAYING-chip idiom): while focused
  -- this view owns wheel + middle-drag everywhere — say so
  if ctx.focused then
    pal.x_ig_rect(cvx + 1, cvy + 1, cvw - 2, cvh - 2, COL.sel,
                  math.max(1, 1.5 * z), 3 * z)
    local fl = "EDITING — wheel/mmb here · esc out"
    local fpx = math.max(4, 10 * z)
    local fw2 = pal.x_ig_text_size(fl, fpx, 0)
    pal.x_ig_rect_fill(cvx + 4 * z, cvy + 4 * z, fw2 + 10 * z, fpx * 1.5,
                       0x7fd8a8cc, 4 * z)
    pal.x_ig_text(cvx + 9 * z, cvy + 4 * z + fpx * 0.22, fpx, 0x10241aff,
                  fl, 0)
  end

  pal.x_ig_clip_pop()

  -- ---- the layer panel (right strip) ----
  if LPW > 0 then
    draw_layer_panel(win, ed, p, doc, cvx + cvw + 4 * z, cvy, LPW, cvh,
                     z, px, ctx)
  end

  -- ---- the inspector strip ----
  local iy = cvy + cvh + 2 * z
  local function field(id, label, val, x, w)
    pal.x_ig_text(x, iy + (INSP - px) * 0.45, px * 0.9, COL.dim, label, 0)
    local lx = x + pal.x_ig_text_size(label, px * 0.9, 0) + 3 * z
    pal.x_ig_rect(lx, iy + 1, w, INSP - 2, 0x4a437088, 1, 2 * z)
    if ctx.occluded then
      pal.x_ig_text(lx + 2 * z, iy + (INSP - px) * 0.45, px * 0.9, COL.text,
                    val, 1)
      return nil, lx + w + 6 * z
    end
    local text, _, _, st = pal.x_ig_edit {
      id = id .. win.id, x = lx + 1, y = iy + 2, w = w - 2, h = INSP - 4,
      text = val, px = px * 0.9, font = 1, enter = true, multiline = false,
    }
    return (st and st.submit) and text or nil, lx + w + 6 * z
  end
  if tool == "collider" then
    -- type chips + flags: the draw type for new colliders; a selected
    -- chain's one-way/closed flags edit in place (journaled)
    local x = ctx.cx + 2 * z
    local function schip(label, on)
      local w = pal.x_ig_text_size(label, px * 0.9, 0) + 10 * z
      local hov = ctx.hot and i.wx >= x and i.wx < x + w
                  and i.wy >= iy and i.wy < iy + INSP
      pal.x_ig_rect_fill(x, iy + 1, w, INSP - 2,
                         on and COL.btn_on or COL.btn, 3 * z)
      pal.x_ig_text(x + 5 * z, iy + (INSP - px) * 0.45, px * 0.9,
                    (hov or on) and COL.hot or COL.dim, label, 0)
      x = x + w + 4 * z
      return hov and i.clicked[1]
    end
    for _, td in ipairs({ { "line", "line" }, { "quad", "quad" },
                          { "circle", "circle" } }) do
      if schip(td[2], (win.ctype or "line") == td[1]) then
        win.ctype = td[1]
        ctx.touch()
      end
    end
    x = x + 4 * z
    local selc = p.csel and doc.colliders[p.csel.c]
    if selc and not p.g then
      if selc.kind == "chain" then
        if schip("one-way", selc.oneway or false) then
          selc.oneway = not selc.oneway
          commit(ed, win.path)
        end
        if schip("closed", selc.closed or false) then
          selc.closed = not selc.closed
          commit(ed, win.path)
        end
      end
      if selc.kind == "circle" then
        -- exact fields for the circle (drag covers the rest)
        local got2
        got2, x = field("mapccx", "x", tostring(selc.cx), x, 34 * z)
        if got2 and tonumber(got2) then
          selc.cx = math.floor(tonumber(got2))
          commit(ed, win.path)
        end
        got2, x = field("mapccy", "y", tostring(selc.cy), x, 34 * z)
        if got2 and tonumber(got2) then
          selc.cy = math.floor(tonumber(got2))
          commit(ed, win.path)
        end
        got2, x = field("mapccr", "r", tostring(selc.r), x, 30 * z)
        if got2 and tonumber(got2) then
          selc.r = math.max(1, math.floor(tonumber(got2)))
          commit(ed, win.path)
        end
      end
      pal.x_ig_text(x + 2 * z, iy + (INSP - px) * 0.45, px * 0.9, COL.dim,
                    p.csel.v and "drag moves the vertex · del removes it"
                    or "drag moves whole collider · closed chip toggles · del removes",
                    0)
    else
      if schip("one-way", win.coneway or false) then
        win.coneway = not win.coneway
        ctx.touch()
      end
      local ct2 = win.ctype or "line"
      local hint
      if p.g and (p.g.mode == "line2" or p.g.mode == "linepress") then
        hint = "click the 2nd point to finish the line · esc cancels"
      elseif ct2 == "line" then
        hint = "drag = a line · click, click = a line · shift+click extends it"
      else
        hint = "drag out the " .. ct2 .. " · ctrl snaps · click picks"
      end
      pal.x_ig_text(x + 2 * z, iy + (INSP - px) * 0.45, px * 0.9, COL.dim,
                    hint, 0)
    end
  elseif #p.sel == 1 then
    local it = p.sel[1]
    local o = it.t == "place" and doc.places[it.i] or doc.markers[it.i]
    if not o then
      p.sel = {}
      return
    end
    local x = ctx.cx + 2 * z
    local got
    got, x = field("mapix", "x", tostring(o.x), x, 34 * z)
    if got and tonumber(got) then
      o.x = math.floor(tonumber(got))
      commit(ed, win.path)
    end
    got, x = field("mapiy", "y", tostring(o.y), x, 34 * z)
    if got and tonumber(got) then
      o.y = math.floor(tonumber(got))
      commit(ed, win.path)
    end
    if it.t == "place" then
      got, x = field("mapin", "name", o.name or "", x, 70 * z)
      if got then
        o.name = got ~= "" and got or nil
        commit(ed, win.path)
      end
      local nlayers = #(doc.layers or { 1 })
      got, x = field("mapily", "L", tostring(o.layer or 1), x, 22 * z)
      if got and tonumber(got) then
        o.layer = math.max(1, math.min(nlayers, math.floor(tonumber(got))))
        commit(ed, win.path)
      end
      -- +col / vis / flip chips
      local function pchip(label, on)
        local w2 = pal.x_ig_text_size(label, px * 0.9, 0) + 10 * z
        local hv = ctx.hot and i.wx >= x and i.wx < x + w2
                   and i.wy >= iy and i.wy < iy + INSP
        pal.x_ig_rect_fill(x, iy + 1, w2, INSP - 2,
                           on and COL.btn_on or COL.btn, 3 * z)
        pal.x_ig_text(x + 5 * z, iy + (INSP - px) * 0.45, px * 0.9,
                      (hv or on) and COL.hot or COL.dim, label, 0)
        x = x + w2 + 4 * z
        return hv and i.clicked[1]
      end
      -- vis: a visual asset can be set to a named ref (label-only). Flip
      -- only makes sense for a shown visual. Default visible = vis absent.
      if visual(o.path) then
        if pchip("vis", o.vis ~= false) then
          if o.vis == false then o.vis = nil else o.vis = false end
          commit(ed, win.path)
        end
        if o.vis ~= false and pchip("flip", o.flip or false) then
          o.flip = not o.flip or nil
          commit(ed, win.path)
        end
        -- anim: pick a clip to auto-play (the trivial "leave it looping"
        -- case — cycles nil -> clip1 -> ... -> nil through the .spr's clips)
        if asset_kind(o.path) == "spr" and o.vis ~= false then
          local info = map.spr_info(o.path)
          local clips = info and info.clips
          if clips and #clips > 0 then
            if pchip("anim:" .. (o.anim or "—"), o.anim ~= nil) then
              local idx = 0
              for n, c in ipairs(clips) do if c.name == o.anim then idx = n end end
              local nxt = clips[idx + 1]
              o.anim = nxt and nxt.name or nil
              commit(ed, win.path)
            end
          end
        end
      end
      if pchip("+col", p.colmenu or false) then
        p.colmenu = not p.colmenu or nil
        ctx.touch()
      end
      if p.colmenu then
        for _, cd in ipairs({ { "owline", "one-way" }, { "line", "line" },
                              { "quad", "quad" }, { "circle", "circle" } }) do
          if pchip(cd[2], false) then
            o.cols = o.cols or {}
            o.cols[#o.cols + 1] = M.col_autofit(cd[1], dims(o.path))
            p.asel = { c = #o.cols }
            p.colmenu = nil
            commit(ed, win.path)
          end
        end
      else
        pal.x_ig_clip_push(x, iy, math.max(0, ctx.cx + ctx.cw - x - 2 * z),
                           INSP)
        local Lyr = doc.layers[o.layer or 1]
        pal.x_ig_text(x, iy + (INSP - px) * 0.45, px * 0.9, COL.dim,
                      ("%s · %s"):format(Lyr and Lyr.name or "?", o.path), 0)
        pal.x_ig_clip_pop()
      end
    else
      -- marker fields (§6): kind / label / note / extras as one k=v line
      got, x = field("mapik", "kind", o.kind or "", x, 46 * z)
      if got and got ~= "" then
        o.kind = got
        commit(ed, win.path)
      end
      got, x = field("mapil", "label", o.label or "", x, 56 * z)
      if got then
        o.label = got
        commit(ed, win.path)
      end
      got, x = field("mapin2", "note", o.note or "", x, 64 * z)
      if got then
        o.note = got
        commit(ed, win.path)
      end
      local ew = math.max(40 * z, ctx.cx + ctx.cw - x - 40 * z)
      got, x = field("mapie", "k=v", M.extras_fmt(o.extras), x, ew)
      if got then
        o.extras = M.extras_parse(got)
        commit(ed, win.path)
      end
    end
  elseif #p.sel > 1 or tool == "marker" then
    local hint = #p.sel > 1
      and (#p.sel .. " selected · ctrl+c/x/d clip · [ ] z · shift+2 fit")
      or "drag = a new marker · move/resize it in move mode (esc)"
    pal.x_ig_text(ctx.cx + 4 * z, iy + (INSP - px) * 0.45, px * 0.9,
                  COL.dim, hint, 0)
  else
    -- nothing selected: the MAP's own fields (R8e — a fresh map must be
    -- sizeable/tintable in the editor; the tmap window's w/h precedent)
    local x = ctx.cx + 2 * z
    local got
    got, x = field("mapw", "w", tostring(doc.w), x, 40 * z)
    if got and tonumber(got) then
      doc.w = math.max(16, math.floor(tonumber(got)))
      commit(ed, win.path)
    end
    got, x = field("maph", "h", tostring(doc.h), x, 40 * z)
    if got and tonumber(got) then
      doc.h = math.max(16, math.floor(tonumber(got)))
      commit(ed, win.path)
    end
    got, x = field("mapg", "grid", tostring(doc.grid or 8), x, 30 * z)
    if got and tonumber(got) then
      doc.grid = math.min(256, math.max(1, math.floor(tonumber(got))))
      commit(ed, win.path)
    end
    got, x = field("mapb", "bg", M.bg_fmt(doc.bg), x, 64 * z)
    if got then
      local bg2 = M.bg_parse(got)
      if bg2 then
        doc.bg = bg2
        commit(ed, win.path)
      end
    end
    got, x = field("mapnm", "name", doc.name or "", x, 56 * z)
    if got then
      doc.name = got ~= "" and got or nil
      commit(ed, win.path)
    end
    -- the §5 switches: game fill on/off + the graybox generator
    local function mchip(label, on)
      local w2 = pal.x_ig_text_size(label, px * 0.9, 0) + 10 * z
      local hv = ctx.hot and i.wx >= x and i.wx < x + w2
                 and i.wy >= iy and i.wy < iy + INSP
      pal.x_ig_rect_fill(x, iy + 1, w2, INSP - 2,
                         on and COL.btn_on or COL.btn, 3 * z)
      pal.x_ig_text(x + 5 * z, iy + (INSP - px) * 0.45, px * 0.9,
                    (hv or on) and COL.hot or COL.dim, label, 0)
      x = x + w2 + 4 * z
      return hv and i.clicked[1]
    end
    if mchip("fill", not doc.nofill) then
      doc.nofill = not doc.nofill or nil
      commit(ed, win.path)
    end
    if mchip("graybox", false) then
      M.graybox_apply(win, ed)
    end
    pal.x_ig_clip_push(x, iy, math.max(0, ctx.cx + ctx.cw - x - 2 * z), INSP)
    pal.x_ig_text(x + 2 * z, iy + (INSP - px) * 0.45, px * 0.9, COL.dim,
                  ("c col · v box-select · m markers · esc back · %d placement%s")
                  :format(#doc.places, #doc.places == 1 and "" or "s"), 0)
    pal.x_ig_clip_pop()
  end
end

-- the graybox button (MAPS.md §5 end state): rasterize the colliders
-- into <map>_gb.tm over the stock tileset, place it at 0,0 as the
-- BOTTOM placement, and flip the map's fill off — one click takes a
-- collider blockout to "visuals are placements, colliders invisible".
-- Re-clicking regenerates the .tm from the current colliders.
function M.graybox_apply(win, ed)
  if ed.parked then
    pal.log("[ed] parked in the past — writes are walled")
    return false
  end
  local p = ed.g.mw and ed.g.mw[win.path]
  if not (p and p.doc) then return false end
  local doc = p.doc
  local tmap = cm.require("cm.tmap")
  local td = tmap.graybox(doc)
  local tmpath = win.path:gsub("%.[mM][aA][pP]$", "") .. "_gb.tm"
  -- A fresh map may live in a not-yet-existing folder and graybox is allowed
  -- before its first Ctrl+S (the tutorial's natural blockout order). Match the
  -- asset save door: create the project-relative parent before the atomic
  -- publish, otherwise maps/foo.map could create working bytes but its first
  -- graybox failed at the temporary-file open.
  local dir = tmpath:match("^(.*)/[^/]+$")
  if dir then pal.mkdir(ed.root .. "/" .. dir) end
  local ok, err = pal.write_file_atomic(ed.root .. "/" .. tmpath,
                                        tmap.encode(td), p._create_fail)
  if not ok then
    pal.log(("[ed] graybox write FAILED: %s (%s)")
            :format(tmpath, tostring(err)))
    if ed.summon_console then ed.summon_console() end
    return false
  end
  cm.asset_epoch = (cm.asset_epoch or 0) + 1 -- live .tm caches re-read
  cm.require("cm.ed.win.assets").invalidate(ed)
  local have
  for _, pl in ipairs(doc.places) do
    if pl.path == tmpath then have = true end
  end
  if not have then
    table.insert(doc.places, 1,
                 { path = tmpath, x = 0, y = 0, layer = 1, name = "graybox" })
    p.sel = {} -- indices shifted
  end
  doc.nofill = true
  commit(ed, win.path)
  pal.log(("[ed] grayboxed %s -> %s (%dx%d cells)")
          :format(win.path, tmpath, td.w, td.h))
  return true
end

-- ---- kind.drop: place a carried asset at the drop point (§6) ----

function M.drop(win, ed, path, wx, wy)
  if win.path == "" or not placeable(path) then return false end
  local p = ed.g.mw and ed.g.mw[win.path]
  local view = p and p.view
  if not (view and p.doc) then return false end
  if wx < view.cx or wx >= view.cx + view.w
     or wy < view.cy or wy >= view.cy + view.h then
    return false
  end
  local doc = p.doc
  local dims = function(pp) return tex_dims(ed, p, pp) end
  local tmfn = function(pp) return tm_doc(ed, p, pp) end
  local x, y
  if p.drop_at then -- the previewed (possibly snapped) ghost spot
    x, y = p.drop_at.x, p.drop_at.y
  else
    local w, h = dims(path)
    x = math.floor((wx - view.ox) / view.zoom - w / 2 + 0.5)
    y = math.floor((wy - view.oy) / view.zoom - h / 2 + 0.5)
    if ed.g.ctrl then
      local dx, dy = M.snap_rect(doc, { x = x, y = y, w = w, h = h },
        { dims = dims, tm = tmfn, thr = SNAP_PX / view.zoom,
          grid = win.grid or doc.grid or 8 })
      x, y = x + math.floor(dx + 0.5), y + math.floor(dy + 0.5)
    end
  end
  local layer = math.max(1, math.min(#doc.layers, win.layer or #doc.layers))
  doc.places[#doc.places + 1] = { path = path, x = x, y = y, layer = layer }
  p.sel = { { t = "place", i = #doc.places } }
  p.drop_at = nil
  commit(ed, win.path)
  pal.log(("[ed] placed %s at %d,%d (layer %s) in %s")
          :format(path, x, y, doc.layers[layer].name, win.path))
  return true
end

return M
