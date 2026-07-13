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
-- R8c roster: the COLLIDER tool (header tool chips sel/col/mkr) — line
-- chains drawn click by click (enter/dblclick ends open, C closes, esc
-- cancels), quads/circles dragged out, vertex/edge/whole-collider drag
-- editing with insert-on-edge-click, the §7 point snap (vertices >
-- edges > 45 lock > grid), one-way/closed flag chips; ATTACHED
-- colliders on the select tool (+col auto-fit picker, editable only
-- while the placement selects, del removes); the MARKER tool (drag =
-- new rect, corner resize, kind/label/note/extras inspector fields).
--
-- Sim/editor line: everything here touches working bytes only; the one
-- sim-facing op is the recorded repl.submit on save.

local M = select(2, ...) or {}
local map = cm.require("cm.map")
local tmap = cm.require("cm.tmap")
local wv = cm.require("cm.ed.winview")

M.kind = "map"
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
  fill = 0x5c5852ff, lip = 0x767068ff,      -- the graybox strips
  solid = 0x8ad0ffff, oneway = 0x7fd8a8ff,  -- collider gizmos
  marker = 0xf0d070ff, sel = 0x7fd8a8ff,
  guide = 0xE8E4FFcc, ghost = 0x7fd8a866,
}

local KEY = { right = 79, left = 80, down = 81, up = 82, del = 76,
              backspace = 42, rbracket = 48, lbracket = 47, n1 = 30,
              n2 = 31, enter = 40, a = 4, c = 6, d = 7, v = 25, x = 27 }

local GRID_STEPS = { 1, 2, 4, 8, 16, 32, 64 }
local SNAP_PX = 6 -- snap threshold, screen px (§7: ~6 px-at-zoom)

function M.defaults()
  return { path = "", tool = "select", giz = true, mk = true, fill = true,
           ctype = "line" }
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

-- what kind.drop claims: placeable visuals (MAPS.md §6). .tm places and
-- moves fine today; it renders as a placeholder until R8d.
local function placeable(path)
  local l = path:lower()
  return l:find("%.spr$") or l:find("%.png$") or l:find("%.tm$")
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
  if p.csel or p.asel then
    p.csel, p.asel = nil, nil
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

function M.place_rect(doc, i, dims)
  local p = doc.places[i]
  local w, h = (dims or dim16)(p.path)
  return p.x, p.y, w, h
end

local function item_rect(doc, it, dims)
  if it.t == "place" then return M.place_rect(doc, it.i, dims) end
  local mk = doc.markers[it.i]
  return mk.x, mk.y, mk.w, mk.h
end

-- topmost item under a map point: markers first when shown (they overlay),
-- then placements in reverse file order (last = topmost, §2)
function M.pick(doc, mx, my, dims, with_markers)
  if with_markers then
    for i = #doc.markers, 1, -1 do
      local mk = doc.markers[i]
      if mx >= mk.x and mx < mk.x + mk.w and my >= mk.y and my < mk.y + mk.h then
        return { t = "marker", i = i }
      end
    end
  end
  for i = #doc.places, 1, -1 do
    local x, y, w, h = M.place_rect(doc, i, dims)
    if mx >= x and mx < x + w and my >= y and my < y + h then
      return { t = "place", i = i }
    end
  end
end

function M.sel_has(sel, it)
  for n, s in ipairs(sel) do
    if s.t == it.t and s.i == it.i then return n end
  end
end

-- items intersecting a map rect (marquee)
function M.pick_rect(doc, x0, y0, x1, y1, dims, with_markers)
  if x1 < x0 then x0, x1 = x1, x0 end
  if y1 < y0 then y0, y1 = y1, y0 end
  local out = {}
  for i = 1, #doc.places do
    local x, y, w, h = M.place_rect(doc, i, dims)
    if x < x1 and x + w > x0 and y < y1 and y + h > y0 then
      out[#out + 1] = { t = "place", i = i }
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
  for _, pl in ipairs(clip.places or {}) do
    local c = deep(pl)
    c.x, c.y, c.name = c.x + dx, c.y + dy, nil
    doc.places[#doc.places + 1] = c
    sel[#sel + 1] = { t = "place", i = #doc.places }
  end
  for _, mk in ipairs(clip.markers or {}) do
    local c = deep(mk)
    c.x, c.y = c.x + dx, c.y + dy
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

-- ---- header: tool radio (sel/col/mkr) + giz / mk / fill chips ----

local CHIPS = { { "giz", "giz" }, { "mk", "mk" }, { "fill", "fill" } }
local TOOLS = { { "marker", "mkr" }, { "collider", "col" },
                { "select", "sel" } } -- right-to-left draw order

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
      if chip(t[2], (win.tool or "select") == t[1]) then
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

-- placement image for the WINDOW draw (ed-root textures; .spr shows its
-- baked sibling; .tm and missing files return nil = placeholder box)
local function win_tex(ed, path)
  local l = path:lower()
  local target
  if l:find("%.png$") then target = path
  elseif l:find("%.spr$") then target = path:gsub("%.spr$", ".png") end
  if not target then return nil end
  local ok, t = pcall(cm.require("cm.gfx").texture, ed.root .. "/" .. target)
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
      local bytes = pal.read_file(ed.root .. "/" .. path)
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

-- the graybox strip fill inside the window (screen coords; the same
-- column/interval math as the game render — cm.map.geom + column_ivs)
local function draw_fill(p, view, X0, X1, Y0s, Y1s)
  local geom = p.geom
  local zoom, ox, oy = view.zoom, view.ox, view.oy
  local scratch = {}
  local run_x, run_sig, run_ivs
  local function flush(xe)
    if not run_ivs then return end
    for j = 1, #run_ivs, 2 do
      local a, b = run_ivs[j], run_ivs[j + 1]
      local sy0, sy1 = oy + a * zoom, oy + b * zoom
      if sy1 > Y0s and sy0 < Y1s then
        pal.x_ig_rect_fill(ox + run_x * zoom, sy0, (xe - run_x) * zoom,
                           sy1 - sy0, COL.fill)
        pal.x_ig_rect_fill(ox + run_x * zoom, sy0, (xe - run_x) * zoom,
                           math.max(1, zoom), COL.lip)
      end
    end
  end
  -- sample at most one column per screen px (zoomed out maps stay cheap)
  local step = math.max(1, math.floor(1 / zoom + 0.5))
  for cx = X0, X1 - 1, step do
    local ivs = map.column_ivs(geom.loops, cx + 0.5, scratch)
    local sig = table.concat(ivs, ",")
    if sig ~= run_sig then
      flush(cx)
      run_x, run_sig, run_ivs = cx, sig, ivs
    end
  end
  flush(X1)
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
    if tool == "collider" then handles(c, 0, 0, on and csel.v or nil) end
  end
  for i, pl in ipairs(doc.places) do -- attached: dim until selected (§6)
    if pl.cols then
      local on = sel and M.sel_has(sel, { t = "place", i = i })
      local a = on and 0xff or 0x66
      for aci, c in ipairs(pl.cols) do
        local hot = on and asel and asel.c == aci
        one(c, pl.x, pl.y, hot and COL.sel or (COL.solid & ~0xff) | a,
            hot and COL.sel or (COL.oneway & ~0xff) | a)
        if on and tool == "select" then -- editable only while selected
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

  -- layout: canvas + the inspector strip
  local INSP = math.max(10, 20 * z)
  local cvx, cvy = ctx.cx, ctx.cy
  local cvw, cvh = ctx.cw, ctx.ch - INSP - 2 * z
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

  -- visible map-px range
  local X0 = math.max(0, math.floor(s2mx(cvx)))
  local X1 = math.min(doc.w, math.ceil(s2mx(cvx + cvw)))
  if win.fill and X1 > X0 then
    draw_fill(p, view, X0, X1, cvy, cvy + cvh)
    -- one-way slabs + open solid strokes (screen-space lines read the same)
    for _, s in ipairs(p.geom.slabs) do
      pal.x_ig_line(ox + s[1] * zoom, oy + s[2] * zoom,
                    ox + s[3] * zoom, oy + s[4] * zoom, COL.oneway,
                    math.max(2, 3 * zoom * 0.5))
    end
    for _, s in ipairs(p.geom.lines) do
      pal.x_ig_line(ox + s[1] * zoom, oy + s[2] * zoom,
                    ox + s[3] * zoom, oy + s[4] * zoom, COL.fill,
                    math.max(1.5, 2 * zoom * 0.5))
    end
  end

  -- placements (file order = z)
  for n, pl in ipairs(doc.places) do
    local x, y, w, h = M.place_rect(doc, n, dims)
    local sx0, sy0 = ox + x * zoom, oy + y * zoom
    if sx0 < cvx + cvw and sx0 + w * zoom > cvx
       and sy0 < cvy + cvh and sy0 + h * zoom > cvy and not pl.hidden then
      local t = win_tex(ed, pl.path)
      local td = not t and tm_doc(ed, p, pl.path)
      local ttex = td and cm.require("cm.ed.win.tmap")
                            .tileset_tex(ed, p, td.tileset)
      if t then
        local u0, u1 = 0, 1
        if pl.flip then u0, u1 = 1, 0 end
        pal.x_ig_image(t.id, sx0, sy0, w * zoom, h * zoom, u0, 0, u1, 1)
      elseif td and ttex then -- a .tm placement: its cell grid (R8d)
        cm.require("cm.ed.win.tmap").draw_cells(td, ttex,
          { zoom = zoom, ox = sx0, oy = sy0 }, cvx, cvy, cvw, cvh)
      else -- placeholder (missing image / unreadable .tm / no tileset)
        pal.x_ig_rect(sx0, sy0, w * zoom, h * zoom, COL.dim, 1)
        pal.x_ig_text(sx0 + 3, sy0 + 2, math.max(4, 9 * z), COL.dim,
                      pl.path:match("([^/]+)$") or pl.path, 0)
      end
    end
  end

  -- markers (the marker tool forces them visible; §6)
  local tool = win.tool or "select"
  if win.mk or tool == "marker" then
    for mi, mk in ipairs(doc.markers) do
      local sx0, sy0 = ox + mk.x * zoom, oy + mk.y * zoom
      pal.x_ig_rect(sx0, sy0, mk.w * zoom, mk.h * zoom, COL.marker,
                    math.max(1, 1.2 * z))
      pal.x_ig_text(sx0 + 2, sy0 + 1, math.max(4, 8.5 * z), COL.marker,
                    mk.kind, 0)
      if tool == "marker" and p.sel and #p.sel == 1
         and p.sel[1].t == "marker" and p.sel[1].i == mi then
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
  if p.asel and not (tool == "select" and apl and apl.cols
                     and apl.cols[p.asel.c]) then
    p.asel = nil
  end
  if win.giz or tool == "collider" then
    draw_gizmos(p, view, p.sel, tool, p.csel, p.asel)
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

  -- ---- the collider tool (R8c, §6) ----
  if tool == "collider" then
    local thr = 7 / zoom -- handle pick radius, map px
    local function finish_chain(closed)
      local gd = p.g
      p.g, p.guides = nil, nil
      if gd and #gd.verts // 2 >= (closed and 3 or 2) then
        doc.colliders[#doc.colliders + 1] = {
          kind = "chain", oneway = win.coneway or false,
          closed = closed or false, verts = gd.verts }
        p.csel = { c = #doc.colliders }
        commit(ed, win.path)
      end
      ctx.touch()
    end
    p.finish_chain = finish_chain -- the keys block reaches it

    -- the §7 edge-run (R8d): line tool + CTRL, idle — hovering a placed
    -- .tm's exposed tile edge proposes the WHOLE contiguous run; one
    -- click lays the full segment. A collider vertex within the snap
    -- zone outranks it (§7 order); topmost .tm placement wins.
    p.run = nil
    if not p.g and g.ctrl and over
       and (win.ctype or "line") == "line" then
      local vhit = M.col_pick(doc.colliders, mx, my, SNAP_PX / zoom)
      if not (vhit and vhit.v) then
        for n = #doc.places, 1, -1 do
          local pl = doc.places[n]
          local td = not pl.hidden and tmfn(pl.path)
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
    if p.run then -- the preview: the full run + endpoint dots
      local r = p.run
      local lt = math.max(1.5, math.min(2.5, zoom))
      pal.x_ig_line(ox + r[1] * zoom, oy + r[2] * zoom,
                    ox + r[3] * zoom, oy + r[4] * zoom, COL.guide, lt)
      pal.x_ig_circle_fill(ox + r[1] * zoom, oy + r[2] * zoom, 3.5, COL.guide)
      pal.x_ig_circle_fill(ox + r[3] * zoom, oy + r[4] * zoom, 3.5, COL.guide)
    end

    if p.g and p.g.mode == "chain" then
      -- the modal chain draw: clicks append, enter/dbl ends open, C
      -- closes, esc cancels (kind_escape); CTRL snaps the live point
      local gd = p.g
      local ax, ay = gd.verts[#gd.verts - 1], gd.verts[#gd.verts]
      gd.cx, gd.cy = ptsnap(mx, my, gd.tg, ax, ay)
      local v = gd.verts
      local lt = math.max(1, math.min(2.5, zoom))
      for k = 1, #v - 3, 2 do
        pal.x_ig_line(ox + v[k] * zoom, oy + v[k + 1] * zoom,
                      ox + v[k + 2] * zoom, oy + v[k + 3] * zoom,
                      COL.sel, lt)
      end
      pal.x_ig_line(ox + ax * zoom, oy + ay * zoom, ox + gd.cx * zoom,
                    oy + gd.cy * zoom, COL.guide, lt)
      for k = 1, #v - 1, 2 do
        pal.x_ig_circle_fill(ox + v[k] * zoom, oy + v[k + 1] * zoom,
                             math.max(2, lt + 1), COL.sel)
      end
      if over and i.clicked[1] and not p.pan then
        local now = pal.time_ns()
        if gd.lt and now - gd.lt < 320 * 1e6
           and math.abs(i.wx - gd.lsx) <= 6
           and math.abs(i.wy - gd.lsy) <= 6 then
          finish_chain(false) -- double-click ends the open chain
        else
          if gd.cx ~= ax or gd.cy ~= ay then
            v[#v + 1], v[#v + 2] = gd.cx, gd.cy
          end
          gd.lt, gd.lsx, gd.lsy = now, i.wx, i.wy
          ctx.touch()
        end
      end
    elseif p.g then
      local gd = p.g
      if gd.mode == "cpress" then
        if math.abs(i.wx - gd.sx) > 4 or math.abs(i.wy - gd.sy) > 4 then
          gd.mode = gd.drag
          gd.mutates = gd.drag == "cvert" or gd.drag == "cwhole"
        elseif not i.buttons[1] then
          -- still-click: select; the SELECTED chain's edge inserts a
          -- vertex at the projection point (§6)
          local hit = gd.hit
          local c = doc.colliders[hit.c]
          if hit.e and c.kind == "chain" and p.csel
             and p.csel.c == hit.c then
            local nv = M.col_insert(c, hit.e, hit.x, hit.y)
            p.csel = { c = hit.c, v = nv }
            commit(ed, win.path)
          else
            p.csel = { c = hit.c, v = hit.v }
          end
          p.g = nil
          ctx.touch()
        end
      end
      if gd.mode == "cvert" then
        if i.buttons[1] then
          local c = doc.colliders[gd.hit.c]
          local nx, ny = ptsnap(mx, my, gd.tg, gd.ax, gd.ay)
          if c.kind == "chain" then
            c.verts[gd.hit.v * 2 - 1], c.verts[gd.hit.v * 2] = nx, ny
          elseif c.kind == "quad" then
            M.quad_drag(c, gd.r0, gd.hit.v, nx, ny)
          else -- the circle's radius ring
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
      elseif gd.mode == "dpress" then
        if math.abs(i.wx - gd.sx) > 4 or math.abs(i.wy - gd.sy) > 4 then
          gd.mode = gd.drag
        elseif not i.buttons[1] then
          p.csel = nil -- a still-click on empty deselects
          p.g = nil
          ctx.touch()
        end
      end
      if gd.mode == "quadd" or gd.mode == "circd" then
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
              commit(ed, win.path)
            end
            ctx.touch()
          end
        end
      end
    elseif over and i.clicked[1] and not p.pan and p.run then
      -- the edge-run click: one click lays the whole segment (§7-R8d)
      doc.colliders[#doc.colliders + 1] = {
        kind = "chain", oneway = win.coneway or false, closed = false,
        verts = { p.run[1], p.run[2], p.run[3], p.run[4] } }
      p.csel = { c = #doc.colliders }
      p.run = nil
      commit(ed, win.path)
      ctx.touch()
    elseif over and i.clicked[1] and not p.pan then
      -- a CTRL press ALWAYS draws (snap pulls the vertex onto existing
      -- geometry — drawing a slope FROM the ground line is the canonical
      -- case, and the pick radius would otherwise eat the snap zone);
      -- a plain press picks. CTRL mid-drag still snaps drags (§7).
      local hit = not g.ctrl and M.col_pick(doc.colliders, mx, my, thr)
      if hit then
        local c = doc.colliders[hit.c]
        local gd = { mode = "cpress", sx = i.wx, sy = i.wy, hit = hit }
        if hit.v then
          gd.drag = "cvert"
          if c.kind == "chain" then
            gd.tg = M.snap_targets(doc, { dims = dims, tm = tmfn,
                      skipv = { o = 0, c = hit.c, v = hit.v } })
            local n = #c.verts // 2
            local pv = hit.v > 1 and hit.v - 1
                       or (c.closed and n or hit.v + 1)
            if pv >= 1 and pv <= n and pv ~= hit.v then
              gd.ax, gd.ay = c.verts[pv * 2 - 1], c.verts[pv * 2]
            end
          elseif c.kind == "quad" then
            gd.tg = M.snap_targets(doc, { dims = dims, tm = tmfn,
                      skipv = { o = 0, c = hit.c } })
            gd.r0 = { x = c.x, y = c.y, w = c.w, h = c.h }
          else
            gd.tg = { verts = {}, segs = {} } -- radius = distance only
          end
        else
          gd.drag = "cwhole"
          gd.gx0, gd.gy0 = hit.x, hit.y -- grab the projection point
          gd.tg = M.snap_targets(doc, { dims = dims, tm = tmfn,
                    skipv = { o = 0, c = hit.c } })
          if c.kind == "circle" then
            gd.orig = { cx = c.cx, cy = c.cy }
          elseif c.kind == "quad" then
            gd.orig = { x = c.x, y = c.y }
          else
            local vv = {}
            for k, val in ipairs(c.verts) do vv[k] = val end
            gd.orig = { verts = vv }
          end
        end
        p.g = gd
        ctx.touch()
      else
        -- empty press: draw the strip's type (line = the modal chain;
        -- quad/circle = drag out); deselects as it starts
        p.csel = nil
        local tg = M.snap_targets(doc, { dims = dims, tm = tmfn })
        local x0, y0 = ptsnap(mx, my, tg)
        local ct = win.ctype or "line"
        if ct == "line" then
          p.g = { mode = "chain", verts = { x0, y0 }, tg = tg,
                  cx = x0, cy = y0, lt = pal.time_ns(),
                  lsx = i.wx, lsy = i.wy }
        else
          p.g = { mode = "dpress", drag = ct == "quad" and "quadd"
                  or "circd", sx = i.wx, sy = i.wy, tg = tg,
                  x0 = x0, y0 = y0 }
        end
        ctx.touch()
      end
    end

  -- ---- the marker tool (§6): drag = new rect; move/resize/select ----
  elseif tool == "marker" then
    local thr = 7 / zoom
    local smk = p.sel and #p.sel == 1 and p.sel[1].t == "marker"
                and doc.markers[p.sel[1].i] or nil
    if p.g then
      local gd = p.g
      if gd.mode == "mpress" then
        if math.abs(i.wx - gd.sx) > 4 or math.abs(i.wy - gd.sy) > 4 then
          gd.mode = gd.drag
          gd.mutates = gd.drag ~= "mnew"
        elseif not i.buttons[1] then
          if gd.drag == "mnew" then
            p.sel = {} -- a still-click on empty clears
          end
          p.g = nil
          ctx.touch()
        end
      end
      if gd.mode == "mmove" then
        if i.buttons[1] then
          local nx = gd.orig.x + (i.wx - gd.sx) / zoom
          local ny = gd.orig.y + (i.wy - gd.sy) / zoom
          p.guides = nil
          if g.ctrl then
            local dx, dy, gg = M.snap_rect(doc,
              { x = nx, y = ny, w = gd.orig.w, h = gd.orig.h },
              snap_opts(nil))
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
      end
    elseif over and i.clicked[1] and not p.pan then
      -- the selected marker's corner knobs resize; else pick/move; else new
      local corner, cd2
      if smk then
        local qv = M.quad_verts(smk)
        for ki = 1, 4 do
          local dx, dy = mx - qv[ki * 2 - 1], my - qv[ki * 2]
          local d2 = dx * dx + dy * dy
          if d2 <= thr * thr and (not cd2 or d2 < cd2) then
            corner, cd2 = ki, d2
          end
        end
      end
      if corner then
        p.g = { mode = "mpress", drag = "mresz", corner = corner,
                sx = i.wx, sy = i.wy,
                tg = M.snap_targets(doc, { dims = dims, tm = tmfn }),
                r0 = { x = smk.x, y = smk.y, w = smk.w, h = smk.h } }
      else
        local hit = M.pick(doc, mx, my, dims, true)
        if hit and hit.t == "marker" then
          p.sel = { hit }
          local mk2 = doc.markers[hit.i]
          p.g = { mode = "mpress", drag = "mmove", item = hit,
                  sx = i.wx, sy = i.wy,
                  orig = { x = mk2.x, y = mk2.y, w = mk2.w, h = mk2.h } }
          ctx.touch()
        elseif not hit then
          local tg = M.snap_targets(doc, { dims = dims, tm = tmfn })
          local x0, y0 = ptsnap(mx, my, tg)
          p.g = { mode = "mpress", drag = "mnew", sx = i.wx, sy = i.wy,
                  x0 = x0, y0 = y0, tg = tg }
        else
          p.sel = {} -- a placement under the marker tool: just deselect
          ctx.touch()
        end
      end
    end

  -- ---- the select tool ----
  elseif tool == "select" and p.g then
    local gd = p.g
    if gd.mode == "press" then
      if math.abs(i.wx - gd.sx) > 4 or math.abs(i.wy - gd.sy) > 4 then
        gd.mode = "move"
        gd.mutates = true -- Esc restores from the committed bytes
      elseif not i.buttons[1] then
        -- still-click: select just the item; double-click opens the editor
        local now = pal.time_ns()
        local dbl = gd.was_sel and p.click and p.click.t
                    and now - p.click.t < 320 * 1e6
                    and p.click.it and p.click.it.t == gd.item.t
                    and p.click.it.i == gd.item.i
        p.sel = { gd.item }
        p.click = { t = now, it = gd.item }
        if dbl and gd.item.t == "place" then
          local path = doc.places[gd.item.i].path
          if cm.require("cm.ed.win.assets").kind_for(path) then
            ed.open_asset_window(path, win.x + win.w + 20, win.y)
          end
        end
        p.g = nil
        ctx.touch()
      end
    end
    -- attached-collider gestures (§6: only while the placement selects)
    if gd.mode == "apress" then
      if math.abs(i.wx - gd.sx) > 4 or math.abs(i.wy - gd.sy) > 4 then
        gd.mode = gd.drag
        gd.mutates = true
      elseif not i.buttons[1] then
        local hit = gd.hit
        local c = apl and apl.cols[hit.c]
        if c and hit.e and c.kind == "chain" and p.asel
           and p.asel.c == hit.c then
          local nv = M.col_insert(c, hit.e, hit.x - apl.x, hit.y - apl.y)
          p.asel = { c = hit.c, v = nv }
          commit(ed, win.path)
        elseif c then
          p.asel = { c = hit.c, v = hit.v }
        end
        p.g = nil
        ctx.touch()
      end
    end
    if gd.mode == "avert" or gd.mode == "awhole" then
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
    end
    if gd.mode == "move" then
      if i.buttons[1] then
        local rdx = (i.wx - gd.sx) / zoom
        local rdy = (i.wy - gd.sy) / zoom
        -- snap the ANCHOR item's rect (§7), whole selection follows
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
        p.guides = nil
        p.g = nil
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
                               win.mk)
        p.g = nil
        ctx.touch()
      end
    end
  elseif tool == "select" and over and i.clicked[1] and not p.pan then
    -- the selected placement's attached handles outrank the item pick
    -- (they sit on top of the sprite; §6 — selected-only editing)
    local ahit = apl and apl.cols
                 and M.col_pick(apl.cols, mx, my, 7 / zoom, apl.x, apl.y)
    if ahit then
      local pi = p.sel[1].i
      local c = apl.cols[ahit.c]
      local gd = { mode = "apress", sx = i.wx, sy = i.wy, hit = ahit }
      if ahit.v then
        gd.drag = "avert"
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
        gd.drag = "awhole"
        gd.gx0, gd.gy0 = ahit.x, ahit.y
        gd.tg = M.snap_targets(doc, { dims = dims, tm = tmfn,
                  skipv = { o = pi, c = ahit.c } })
        if c.kind == "circle" then
          gd.orig = { cx = c.cx, cy = c.cy }
        elseif c.kind == "quad" then
          gd.orig = { x = c.x, y = c.y }
        else
          local vv = {}
          for k, val in ipairs(c.verts) do vv[k] = val end
          gd.orig = { verts = vv }
        end
      end
      p.g = gd
      ctx.touch()
    end
    local hit = not ahit and M.pick(doc, mx, my, dims, win.mk)
    if hit then
      if g.shift then
        local at = M.sel_has(p.sel, hit)
        if at then table.remove(p.sel, at) else p.sel[#p.sel + 1] = hit end
        ctx.touch()
      else
        local was = M.sel_has(p.sel, hit) ~= nil
        if not was then p.sel = { hit } end
        -- arm the move gesture over the (possibly new) selection
        local items, skipset = {}, {}
        for _, it in ipairs(p.sel) do
          local o = it.t == "place" and doc.places[it.i] or doc.markers[it.i]
          items[#items + 1] = { ref = o, x0 = o.x, y0 = o.y }
          if it.t == "place" then skipset[it.i] = true end
        end
        local ax, ay, aw, ah = item_rect(doc, hit, dims)
        p.g = { mode = "press", sx = i.wx, sy = i.wy, item = hit,
                was_sel = was, items = items, skipset = skipset,
                ax0 = ax, ay0 = ay, aw = aw, ah = ah }
        ctx.touch()
      end
    elseif not ahit then
      p.g = { mode = "marquee", sx = i.wx, sy = i.wy,
              mx0 = mx, my0 = my, mx1 = mx, my1 = my }
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
      if e.down and not e.rep then
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
        elseif tool == "collider" then
          if p.g and p.g.mode == "chain" then
            if sc == KEY.enter then p.finish_chain(false)
            elseif sc == KEY.c then p.finish_chain(true) end
          elseif p.csel and not p.g then
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

  -- zoom + grid chip, canvas corner
  local chip = ("%d%% · grid %d (ctrl+wheel)")
               :format(math.floor(zoom * 100 + 0.5),
                       win.grid or doc.grid or 8)
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
                    or "click an edge of the selected chain to insert · del deletes",
                    0)
    else
      if schip("one-way", win.coneway or false) then
        win.coneway = not win.coneway
        ctx.touch()
      end
      local hint = p.g and p.g.mode == "chain"
        and "click adds · enter/dblclick ends · c closes · esc cancels"
        or "press empty draws (ctrl: from anywhere, snapped) · plain press picks"
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
      got, x = field("mapily", "L", tostring(o.layer or 0), x, 22 * z)
      if got and tonumber(got) then
        o.layer = math.max(0, math.min(255, math.floor(tonumber(got))))
        commit(ed, win.path)
      end
      -- flip toggle
      local fw = pal.x_ig_text_size("flip", px * 0.9, 0) + 10 * z
      local hov = ctx.hot and i.wx >= x and i.wx < x + fw
                  and i.wy >= iy and i.wy < iy + INSP
      pal.x_ig_rect_fill(x, iy + 1, fw, INSP - 2,
                         o.flip and COL.btn_on or COL.btn, 3 * z)
      pal.x_ig_text(x + 5 * z, iy + (INSP - px) * 0.45, px * 0.9,
                    (hov or o.flip) and COL.hot or COL.dim, "flip", 0)
      if hov and i.clicked[1] then
        o.flip = not o.flip
        commit(ed, win.path)
      end
      x = x + fw + 6 * z
      -- +col: attach an auto-fit collider (§6) — the type picker inline
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
      if pchip("hide", o.hidden or false) then
        o.hidden = not o.hidden or nil
        commit(ed, win.path)
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
        pal.x_ig_text(x, iy + (INSP - px) * 0.45, px * 0.9, COL.dim,
                      ("L%d · %s"):format(o.layer or 0, o.path), 0)
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
      or "drag on empty = new marker · corners resize · del removes"
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
                  ("drag in to place · ctrl snaps · %d placement%s")
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
  if not pal.write_file(ed.root .. "/" .. tmpath, tmap.encode(td)) then
    pal.log("[ed] graybox write FAILED: " .. tmpath)
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
                 { path = tmpath, x = 0, y = 0, layer = 0, name = "graybox" })
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
  doc.places[#doc.places + 1] = { path = path, x = x, y = y, layer = 0 }
  p.sel = { { t = "place", i = #doc.places } }
  p.drop_at = nil
  commit(ed, win.path)
  pal.log(("[ed] placed %s at %d,%d in %s"):format(path, x, y, win.path))
  return true
end

return M
