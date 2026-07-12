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
-- R8b roster: view (wheel zoom at cursor, MMB pan, shift+1 fit), the
-- graybox fill + placements + marker rects + collider gizmos (header
-- chips giz/mk/fill), the SELECT tool end to end — click / shift-click /
-- marquee / drag-move / arrow nudge / del / [ ] z — with the §7 CTRL
-- snap for placements (vertices > edges/centers > grid; guides drawn;
-- ctrl+wheel dials the grid step), double-click a placement → its
-- editor, the inspector strip (x/y/name/flip), and kind.drop — drag a
-- .spr/.png/.tm from the picker and release over the map to PLACE it
-- (ghost preview + live snap during the carry). Save = write the .map +
-- submit the recorded cm.map.reload EVAL — the running game hot-reloads
-- (MAPS.md §9), so traces replay it and rewind scrubs across it.
-- Collider/marker AUTHORING is R8c; unsnapped colliders still show as
-- gizmos and snap targets here.
--
-- Sim/editor line: everything here touches working bytes only; the one
-- sim-facing op is the recorded repl.submit on save.

local M = select(2, ...) or {}
local journal = cm.require("cm.ed.journal")
local map = cm.require("cm.map")
local wm = cm.require("cm.ed.wm")

M.kind = "map"
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
              backspace = 42, rbracket = 48, lbracket = 47, n1 = 30 }

local GRID_STEPS = { 1, 2, 4, 8, 16, 32, 64 }
local SNAP_PX = 6 -- snap threshold, screen px (§7: ~6 px-at-zoom)

function M.defaults()
  return { path = "", tool = "select", giz = true, mk = true, fill = true }
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

-- ---- plumbing (ephemeral, on ed.g.mw[path]) ----

local function plumb(ed, path)
  local g = ed.g
  g.mw = g.mw or {}
  local p = g.mw[path]
  if not p then
    p = {}
    g.mw[path] = p
  end
  return p
end

local function working(ed, path)
  ed.doc.assets = ed.doc.assets or {}
  return ed.doc.assets[path]
end

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

local function open_asset(ed, path)
  local a = working(ed, path)
  local p = plumb(ed, path)
  if p.j then return a, p end
  local disk = pal.read_file(ed.root .. "/" .. path)
  p.disk = disk or ""
  if not a then
    local bytes = p.disk
    if #bytes == 0 then bytes = fresh_bytes(path) end -- a new map
    a = { map = bytes, jpos = 0 }
    ed.doc.assets[path] = a
  end
  p.j = journal.open(ed.root, path, a.jpos > 0 and a.jpos or nil, M.JCAP)
  if not ed.parked then -- parked reopens must never write journals (R6c)
    if #p.j.entries == 0 and #p.disk > 0 then
      journal.push(p.j, p.disk, journal.SAVED, pal.time_ns() // 1000000)
    end
    local tip = journal.at(p.j)
    if tip and a.map ~= tip.bytes and p.j.pos == #p.j.entries then
      journal.push(p.j, a.map, 0, pal.time_ns() // 1000000)
    end
  end
  a.jpos = p.j.pos
  decode_into(p, a.map)
  ed.touch()
  return a, p
end

function M.open_win(win, ed) -- spawn-time adoption (proof scripting too)
  if win.path ~= "" then return open_asset(ed, win.path) end
end

-- one finished gesture: re-encode the doc into the working bytes + journal
local function commit(ed, path, flags)
  local a, p = open_asset(ed, path)
  if not p.doc then return end
  a.map = map.encode(p.doc)
  p.geom = nil
  if ed.parked then -- parked edits are ephemeral (REWIND.md §4)
    ed.touch()
    return
  end
  if journal.push(p.j, a.map, flags or 0, pal.time_ns() // 1000000) then
    a.jpos = p.j.pos
  end
  ed.touch()
end

-- ---- the focused-window commands (§6 contract) ----

function M.dirty(win, ed)
  if win.path == "" then return false end
  local a = working(ed, win.path)
  local p = ed.g.mw and ed.g.mw[win.path]
  return a and p and p.disk ~= nil and a.map ~= p.disk or false
end

function M.save(win, ed)
  if win.path == "" then return end
  if ed.parked then
    pal.log("[ed] parked in the past — writes are walled (bring-back is the door)")
    return
  end
  local a, p = open_asset(ed, win.path)
  if not p.doc then return end
  a.map = map.encode(p.doc)
  local dir = win.path:match("^(.*)/[^/]+$")
  if dir then pal.mkdir(ed.root .. "/" .. dir) end
  local full = ed.root .. "/" .. win.path
  if pal.write_file(full, a.map) then
    p.disk = a.map
    commit(ed, win.path, journal.SAVED)
    -- the recorded hot-reload (MAPS.md §9): the running game re-instances
    -- the saved map at the start of the next sim frame; traces replay it
    cm.require("cm.repl").submit(('cm.require("cm.map").reload(%q)'):format(full))
    pal.log("[ed] saved " .. win.path .. " (reload queued)")
  else
    pal.log("[ed] SAVE FAILED " .. win.path)
  end
end

function M.undo(win, ed)
  if win.path == "" then return end
  local a, p = open_asset(ed, win.path)
  local e = journal.undo(p.j)
  if e then
    a.map, a.jpos = e.bytes, p.j.pos
    decode_into(p, e.bytes)
    ed.touch()
  end
end

function M.redo(win, ed)
  if win.path == "" then return end
  local a, p = open_asset(ed, win.path)
  local e = journal.redo(p.j)
  if e then
    a.map, a.jpos = e.bytes, p.j.pos
    decode_into(p, e.bytes)
    ed.touch()
  end
end

function M.revert(win, ed)
  if win.path == "" then return end
  local a, p = open_asset(ed, win.path)
  a.map = p.disk or ""
  decode_into(p, a.map)
  commit(ed, win.path)
end

-- Esc: cancel the live gesture, else clear the selection (kind_escape)
function M.escape(win, ed)
  local p = ed.g.mw and ed.g.mw[win.path]
  if not p then return false end
  if p.g then
    if p.g.mode == "move" then -- put the moved items back
      for _, it in ipairs(p.g.items) do
        it.ref.x, it.ref.y = it.x0, it.y0
      end
      decode_into(p, working(ed, win.path).map) -- re-adopt committed bytes
    end
    p.g = nil
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
-- Returns the moved item's new index (single-place selections only).
function M.zmove(doc, sel, dir)
  if #sel ~= 1 or sel[1].t ~= "place" then return nil end
  local i = sel[1].i
  local to = i + dir
  if to < 1 or to > #doc.places then return i end
  local p = table.remove(doc.places, i)
  table.insert(doc.places, to, p)
  sel[1].i = to
  return to
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

-- ---- header: giz / mk / fill chips ----

local CHIPS = { { "giz", "giz" }, { "mk", "mk" }, { "fill", "fill" } }

function M.header(win, ctx)
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  local i = cm.require("cm.ui").inp
  local x = ctx.hx
  local used = 0
  for n = #CHIPS, 1, -1 do
    local key, label = CHIPS[n][1], CHIPS[n][2]
    local w = pal.x_ig_text_size(label, px, 0) + 12 * z
    x = x - w - 3 * z
    used = used + w + 3 * z
    local on = win[key]
    local hov = not ctx.alt and i.wx >= x and i.wx < x + w
                and i.wy >= ctx.hy and i.wy < ctx.hy + ctx.hh
    pal.x_ig_rect_fill(x, ctx.hy + 3 * z, w, ctx.hh - 6 * z,
                       on and COL.btn_on or COL.btn, 4 * z)
    pal.x_ig_text(x + 6 * z, ctx.hy + (ctx.hh - px) * 0.45, px,
                  (hov or on) and COL.hot or COL.dim, label, 0)
    if hov and i.clicked[1] then
      win[key] = not win[key]
      ctx.ed.touch()
    end
  end
  return used
end

-- ---- view plumbing ----

-- focused = the view lock (the human's ask, §6): wheel + middle-drag act
-- on THIS window's camera from anywhere on the canvas; any canvas action
-- or Esc unfocuses. An unbound window has no view to own.
function M.own_view(win)
  return win.path ~= ""
end

-- content wheel: zoom the map view at the cursor. Under the focus lock
-- the wheel arrives from anywhere — a cursor outside the view anchors at
-- the view center instead (zoom-at-cursor math would fling the pan).
function M.wheel(win, ed, dy)
  local p = ed.g.mw and ed.g.mw[win.path]
  local r = p and p.view
  if not (r and p.doc) then return false end
  local i = cm.require("cm.ui").inp
  local ax, ay = i.wx, i.wy
  if ax < r.cx or ax >= r.cx + r.w or ay < r.cy or ay >= r.cy + r.h then
    ax, ay = r.cx + r.w * 0.5, r.cy + r.h * 0.5
  end
  local oldz = win.zoom or r.fit
  local nz = math.max(0.05, math.min(32, oldz * (dy > 0 and 1.25 or 0.8)))
  local mx = (ax - r.ox) / oldz
  local my = (ay - r.oy) / oldz
  win.px = (ax - mx * nz - r.cx) / r.wz
  win.py = (ay - my * nz - r.cy) / r.wz
  win.zoom = nz
  ed.touch()
  return true
end

function M.takes_middle(win)
  return win.path ~= ""
end

-- ctrl+wheel: the grid-step dial (§7)
function M.ctrl_wheel(win, ed, notches)
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

-- placement dims in map px (the window's `dims` for the pure core):
-- textures win; .tm decodes its head; unknowns get 16x16
local function tex_dims(ed, p, path)
  p.dims = p.dims or {}
  local hit = p.dims[path]
  if hit then return hit[1], hit[2] end
  local w, h = 16, 16
  local t = win_tex(ed, path)
  if t then
    w, h = t.w, t.h
  elseif path:lower():find("%.tm$") then
    local bytes = pal.read_file(ed.root .. "/" .. path)
    if bytes then
      local ok, td = pcall(cm.require("cm.tmap").decode, bytes)
      if ok then w, h = td.w * td.tile, td.h * td.tile end
    end
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

local function draw_gizmos(p, view, sel)
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
      for i = 1, n do -- vertex dots (the future R8c handles)
        pal.x_ig_circle_fill(sx(v[i * 2 - 1] + px0), sy(v[i * 2] + py0),
                             math.max(1.5, t + 0.5),
                             c.oneway and col_ow or col_solid)
      end
    end
  end
  for _, c in ipairs(doc.colliders) do
    one(c, 0, 0, COL.solid, COL.oneway)
  end
  for i, pl in ipairs(doc.places) do -- attached: dim until selected (§6)
    if pl.cols then
      local on = sel and M.sel_has(sel, { t = "place", i = i })
      local a = on and 0xff or 0x66
      for _, c in ipairs(pl.cols) do
        one(c, pl.x, pl.y, (COL.solid & ~0xff) | a, (COL.oneway & ~0xff) | a)
      end
    end
  end
end

-- marker inspector line (R8c grows editing; read-only here)
local function mkline(mk)
  local ex = ""
  for _, e in ipairs(mk.extras or {}) do
    ex = ex .. " " .. e.k .. "=" .. e.v
  end
  return ("%s · %s%s"):format(mk.kind, mk.label ~= "" and mk.label or "—", ex)
end

-- ---- content ----

function M.draw(win, ctx)
  local ed = ctx.ed
  local z = ctx.z
  local px = math.max(4, 11 * z)
  local i = cm.require("cm.ui").inp
  local g = ed.g

  -- unbound: hint + a path field that creates/opens (the spawn-menu path)
  if win.path == "" then
    pal.x_ig_text(ctx.cx + 8 * z, ctx.cy + 8 * z, px, COL.dim,
                  "no map bound — drag a .map here, or type a path:", 0)
    local fy = ctx.cy + 8 * z + px * 1.8
    pal.x_ig_rect(ctx.cx + 8 * z, fy, math.min(240 * z, ctx.cw - 16 * z),
                  px * 1.7, 0x4a437088, 1, 3 * z)
    if not ctx.occluded then
      local p0 = plumb(ed, "@new" .. win.id)
      local text, _, _, st = pal.x_ig_edit {
        id = "mapnew" .. win.id, x = ctx.cx + 10 * z, y = fy + 1,
        w = math.min(236 * z, ctx.cw - 20 * z), h = px * 1.7 - 2,
        text = p0.newpath or "maps/", px = px, font = 1,
        enter = true, multiline = false,
      }
      p0.newpath = text
      if st and st.submit and text ~= "" and text ~= "maps/" then
        local path = text
        if not path:lower():find("%.map$") then path = path .. ".map" end
        win.path = path
        p0.newpath = nil
        ed.touch()
      end
    end
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

  -- layout: canvas + the inspector strip
  local INSP = math.max(10, 20 * z)
  local cvx, cvy = ctx.cx, ctx.cy
  local cvw, cvh = ctx.cw, ctx.ch - INSP - 2 * z
  if cvw < 60 or cvh < 60 then return end

  -- view transform (sprite-ed shape: zoom = screen px per map px;
  -- win.px/py = pan in world units)
  pal.x_ig_rect_fill(cvx, cvy, cvw, cvh, COL.well, 3 * z)
  local fit = math.min((cvw - 12 * z) / doc.w, (cvh - 12 * z) / doc.h)
  local zoom = win.zoom or fit
  local ox, oy
  if win.px then
    ox = cvx + win.px * z
    oy = cvy + win.py * z
  else
    ox = cvx + (cvw - doc.w * zoom) * 0.5
    oy = cvy + (cvh - doc.h * zoom) * 0.5
  end
  local view = { cx = cvx, cy = cvy, w = cvw, h = cvh, ox = ox, oy = oy,
                 zoom = zoom, fit = fit, wz = z }
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
      if t then
        local u0, u1 = 0, 1
        if pl.flip then u0, u1 = 1, 0 end
        pal.x_ig_image(t.id, sx0, sy0, w * zoom, h * zoom, u0, 0, u1, 1)
      else -- placeholder (.tm until R8d, or missing image)
        pal.x_ig_rect(sx0, sy0, w * zoom, h * zoom, COL.dim, 1)
        pal.x_ig_text(sx0 + 3, sy0 + 2, math.max(4, 9 * z), COL.dim,
                      pl.path:match("([^/]+)$") or pl.path, 0)
      end
    end
  end

  -- markers
  if win.mk then
    for _, mk in ipairs(doc.markers) do
      local sx0, sy0 = ox + mk.x * zoom, oy + mk.y * zoom
      pal.x_ig_rect(sx0, sy0, mk.w * zoom, mk.h * zoom, COL.marker,
                    math.max(1, 1.2 * z))
      pal.x_ig_text(sx0 + 2, sy0 + 1, math.max(4, 8.5 * z), COL.marker,
                    mk.kind, 0)
    end
  end

  -- collider gizmos — always on by default (the human's call, §6)
  if win.giz then draw_gizmos(p, view, p.sel) end

  -- selection outlines
  for _, it in ipairs(p.sel) do
    local x, y, w, h = item_rect(doc, it, dims)
    pal.x_ig_rect(ox + x * zoom - 1.5, oy + y * zoom - 1.5,
                  w * zoom + 3, h * zoom + 3, COL.sel,
                  math.max(1, 1.5 * z))
  end

  -- ---- interaction ----
  local over = not ctx.alt and i.wx >= cvx and i.wx < cvx + cvw
               and i.wy >= cvy and i.wy < cvy + cvh
  -- press starts only when this window is the top hit at the cursor
  local tophit = over and g.cursor
                 and wm.hit(ctx.doc, g.cursor.wx, g.cursor.wy, 0)
  local topmost = tophit == win.id
  local mx, my = s2mx(i.wx), s2my(i.wy)
  local snap_opts = function(skipset)
    return { dims = dims, thr = SNAP_PX / zoom,
             grid = win.grid or doc.grid or 8,
             skip = skipset and function(n) return skipset[n] end or nil }
  end

  -- middle-drag pans the view: the focus lock grabs from anywhere; an
  -- unfocused window grabs over its content only, and yields when some
  -- OTHER window holds the lock (priority is the lock's whole point)
  local grab = ctx.focused or (topmost and not ed.view_locked())
  if grab and i.clicked[2] then
    p.pan = { mx = i.wx, my = i.wy, ox = ox, oy = oy }
  end
  if p.pan then
    if i.buttons[2] then
      win.px = (p.pan.ox + (i.wx - p.pan.mx) - cvx) / z
      win.py = (p.pan.oy + (i.wy - p.pan.my) - cvy) / z
      win.zoom = zoom
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

  -- select-tool gestures
  if p.g then
    local gd = p.g
    if gd.mode == "press" then
      if math.abs(i.wx - gd.sx) > 4 or math.abs(i.wy - gd.sy) > 4 then
        gd.mode = "move"
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
  elseif topmost and i.clicked[1] and not p.pan then
    local hit = M.pick(doc, mx, my, dims, win.mk)
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
    else
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
        if sc >= KEY.right and sc <= KEY.up and #p.sel > 0 then
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
        elseif sc == KEY.n1 and g.shift then
          win.zoom, win.px, win.py = nil, nil, nil
          ctx.touch()
        end
      end
    end
  end

  -- zoom + grid chip, canvas corner
  local chip = ("%d%% · grid %d"):format(math.floor(zoom * 100 + 0.5),
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
  if #p.sel == 1 then
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
      -- flip toggle
      local fw = pal.x_ig_text_size("flip", px * 0.9, 0) + 10 * z
      local hov = not ctx.alt and i.wx >= x and i.wx < x + fw
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
      pal.x_ig_clip_push(x, iy, math.max(0, ctx.cx + ctx.cw - x - 2 * z), INSP)
      pal.x_ig_text(x, iy + (INSP - px) * 0.45, px * 0.9, COL.dim,
                    ("L%d · %s"):format(o.layer or 0, o.path), 0)
      pal.x_ig_clip_pop()
    else
      pal.x_ig_text(x, iy + (INSP - px) * 0.45, px * 0.9, COL.marker,
                    mkline(o), 0)
    end
  else
    local hint = #p.sel > 1 and (#p.sel .. " selected")
      or ("%dx%d · drag assets in to place · ctrl snaps · %d placement%s")
         :format(doc.w, doc.h, #doc.places, #doc.places == 1 and "" or "s")
    pal.x_ig_text(ctx.cx + 4 * z, iy + (INSP - px) * 0.45, px * 0.9,
                  COL.dim, hint, 0)
  end
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
  local x, y
  if p.drop_at then -- the previewed (possibly snapped) ghost spot
    x, y = p.drop_at.x, p.drop_at.y
  else
    local w, h = dims(path)
    x = math.floor((wx - view.ox) / view.zoom - w / 2 + 0.5)
    y = math.floor((wy - view.oy) / view.zoom - h / 2 + 0.5)
    if ed.g.ctrl then
      local dx, dy = M.snap_rect(doc, { x = x, y = y, w = w, h = h },
        { dims = dims, thr = SNAP_PX / view.zoom,
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
