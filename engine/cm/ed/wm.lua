-- cm.ed.wm — the window model + the ALT interaction grammar (EDITOR.md §4/§5).
-- Pure over the editor doc: window list ops, hit-testing, and the gesture
-- state machine. No drawing, no pal calls — selftest drives this headless
-- with synthetic input frames.
--
-- Windows live in doc.wins (array; draw order = z order, last = topmost):
--   { id, kind, x, y, w, h, parent }  -- world coords; parent 0 = top level
--                                        (groups arrive post-R3; the walk is
--                                        already generic over parent links)
-- Selection: doc.sel = array of ids; doc.drill = group id or 0;
-- doc.focus = id or 0 (the window keyboard asset commands act on).
--
-- The grammar (the board's spec; thresholds are teidraw's): click = release
-- within DRAG_PX of press, drag = crossing DRAG_PX. A-click select (+ drill
-- on a selected group's child), A-drag move (selected-first priority),
-- A-rightclick close, A-drag-on-empty marquee. Plain drag on the EDGE_PX
-- band resizes; no auto-raise (z moves only via raise/to_front hotkeys).
--
-- update(doc, g, inp) advances one frame. g is the EPHEMERAL gesture table
-- (module-local to the shell, never captured — EDITOR.md §2). inp is a
-- plain snapshot the shell builds:
--   { wx, wy       = cursor in WORLD coords,
--     sx, sy       = cursor in SCREEN px (for the drag threshold),
--     band         = edge band in world units (EDGE_PX / zoom),
--     alt          = the ALT layer is held,
--     down1, down3 = left/right button held,
--     clicked1, clicked3, released1, released3 = edges this frame }
-- Returns true while wm owns the mouse (the shell then skips pan/menu).

local M = select(2, ...) or {}

M.DRAG_PX = 4 -- click vs drag (screen px)
M.EDGE_PX = 6 -- resize band (screen px)
M.MIN_W, M.MIN_H = 64, 48 -- world units

-- ---- doc shape ----

function M.init(doc)
  doc.wins = doc.wins or {}
  doc.sel = doc.sel or {}
  doc.drill = doc.drill or 0
  doc.focus = doc.focus or 0
  doc.next_id = doc.next_id or 1
  return doc
end

function M.get(doc, id)
  for _, w in ipairs(doc.wins) do
    if w.id == id then return w end
  end
end

function M.index_of(doc, id)
  for i, w in ipairs(doc.wins) do
    if w.id == id then return i end
  end
end

function M.spawn(doc, kind, x, y, w, h, extra)
  local win = { id = doc.next_id, kind = kind, parent = 0,
                x = x + 0.0, y = y + 0.0,
                w = math.max(w, M.MIN_W) + 0.0,
                h = math.max(h, M.MIN_H) + 0.0 }
  if extra then
    for k, v in pairs(extra) do win[k] = v end
  end
  doc.next_id = doc.next_id + 1
  doc.wins[#doc.wins + 1] = win
  doc.sel = { win.id }
  doc.focus = win.id
  return win
end

local function unselect(doc, id)
  local out = {}
  for _, s in ipairs(doc.sel) do
    if s ~= id then out[#out + 1] = s end
  end
  doc.sel = out
end

-- closing is non-destructive by construction (EDITOR.md §5): asset working
-- state is keyed by path in doc.assets, not by window, so no confirm needed
function M.close(doc, id)
  local i = M.index_of(doc, id)
  if not i then return false end
  table.remove(doc.wins, i)
  unselect(doc, id)
  if doc.focus == id then doc.focus = 0 end
  if doc.drill == id then doc.drill = 0 end
  return true
end

function M.selected(doc, id)
  for _, s in ipairs(doc.sel) do
    if s == id then return true end
  end
  return false
end

-- ---- z order (explicit only; interacting with content never raises) ----

local function splice_to(doc, id, to)
  local i = M.index_of(doc, id)
  if not i then return end
  local w = table.remove(doc.wins, i)
  if to < 1 then to = 1 elseif to > #doc.wins + 1 then to = #doc.wins + 1 end
  table.insert(doc.wins, to, w)
end

function M.raise(doc, id) -- ]: forward one
  local i = M.index_of(doc, id)
  if i then splice_to(doc, id, i + 1) end
end

function M.lower(doc, id) -- [: backward one
  local i = M.index_of(doc, id)
  if i then splice_to(doc, id, i - 1) end
end

function M.to_front(doc, id) splice_to(doc, id, #doc.wins + 1) end
function M.to_back(doc, id) splice_to(doc, id, 1) end

-- ---- hit testing (world coords; reverse scan = topmost first) ----

local function inside(w, x, y)
  return x >= w.x and x < w.x + w.w and y >= w.y and y < w.y + w.h
end

-- topmost window whose rect (grown by half the band, for the outer edge
-- half) contains the point; also reports the part:
--   "content", or an edge combo "n"/"s"/"e"/"w"/"ne"/"nw"/"se"/"sw"
function M.hit(doc, x, y, band)
  band = band or 0
  local ho = band * 0.5 -- half band outside, half inside: the band sits ON
  for i = #doc.wins, 1, -1 do -- the border (EDITOR.md §4)
    local w = doc.wins[i]
    if x >= w.x - ho and x < w.x + w.w + ho
       and y >= w.y - ho and y < w.y + w.h + ho then
      local part = ""
      if y < w.y + ho then part = "n"
      elseif y >= w.y + w.h - ho then part = "s" end
      if x < w.x + ho then part = part .. "w"
      elseif x >= w.x + w.w - ho then part = part .. "e" end
      return w.id, part == "" and "content" or part
    end
  end
end

-- every window containing the point, topmost first (move-priority input)
function M.hits(doc, x, y)
  local out = {}
  for i = #doc.wins, 1, -1 do
    local w = doc.wins[i]
    if inside(w, x, y) then out[#out + 1] = w.id end
  end
  return out
end

function M.intersecting(doc, x0, y0, x1, y1)
  if x1 < x0 then x0, x1 = x1, x0 end
  if y1 < y0 then y0, y1 = y1, y0 end
  local out = {}
  for _, w in ipairs(doc.wins) do
    if w.x < x1 and w.x + w.w > x0 and w.y < y1 and w.y + w.h > y0 then
      out[#out + 1] = w.id
    end
  end
  return out
end

-- teidraw's resolve_target over parent links: normally the outermost
-- ancestor; when drilled into group G, G's direct descendants resolve to
-- the child under the drill. R3 windows are all top-level leaves, so this
-- returns the leaf itself — the walk is here so groups don't rework the
-- grammar later.
function M.resolve_target(doc, id)
  local w = M.get(doc, id)
  if not w then return id end
  -- collect the ancestor chain leaf -> root
  local chain = { w }
  local cur = w
  while cur.parent ~= 0 do
    cur = M.get(doc, cur.parent)
    if not cur then break end
    chain[#chain + 1] = cur
  end
  if doc.drill ~= 0 then
    -- inside the drilled group: return the child one level under it
    for i = #chain, 1, -1 do
      if chain[i].id == doc.drill then
        return (chain[i - 1] or chain[i]).id
      end
    end
    doc.drill = 0 -- clicked outside the drilled group: pop
  end
  return chain[#chain].id
end

-- ---- geometry ops ----

function M.move(doc, id, dx, dy)
  local w = M.get(doc, id)
  if not w then return end
  w.x, w.y = w.x + dx, w.y + dy
end

function M.move_sel(doc, dx, dy)
  for _, id in ipairs(doc.sel) do M.move(doc, id, dx, dy) end
end

-- resize by dragging the part edges ("n"/"se"/...) by (dx,dy) from the
-- gesture-start rect r0; min size clamped, anchored on the opposite edge
function M.resize(doc, id, part, r0, dx, dy)
  local w = M.get(doc, id)
  if not w then return end
  local x, y, ww, wh = r0.x, r0.y, r0.w, r0.h
  if part:find("e") then ww = math.max(M.MIN_W, r0.w + dx) end
  if part:find("s") then wh = math.max(M.MIN_H, r0.h + dy) end
  if part:find("w") then
    ww = math.max(M.MIN_W, r0.w - dx)
    x = r0.x + r0.w - ww
  end
  if part:find("n") then
    wh = math.max(M.MIN_H, r0.h - dy)
    y = r0.y + r0.h - wh
  end
  w.x, w.y, w.w, w.h = x, y, ww, wh
end

-- selection bounds (fit-selection); nil when empty
function M.sel_bounds(doc)
  local x0, y0, x1, y1
  for _, id in ipairs(doc.sel) do
    local w = M.get(doc, id)
    if w then
      x0 = math.min(x0 or w.x, w.x)
      y0 = math.min(y0 or w.y, w.y)
      x1 = math.max(x1 or w.x + w.w, w.x + w.w)
      y1 = math.max(y1 or w.y + w.h, w.y + w.h)
    end
  end
  if x0 then return x0, y0, x1 - x0, y1 - y0 end
end

function M.all_bounds(doc)
  local save = doc.sel
  doc.sel = {}
  for _, w in ipairs(doc.wins) do doc.sel[#doc.sel + 1] = w.id end
  local x, y, w, h = M.sel_bounds(doc)
  doc.sel = save
  return x, y, w, h
end

-- ---- the gesture state machine ----

local function dist2(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return dx * dx + dy * dy
end

-- move-target priority (EDITOR.md §5): the topmost SELECTED window under
-- the point, else the topmost hit
local function move_target(doc, x, y)
  local hits = M.hits(doc, x, y)
  for _, id in ipairs(hits) do
    if M.selected(doc, id) then return id end
  end
  return hits[1]
end

function M.update(doc, g, inp)
  local st = g.state

  -- a gesture in progress always continues, whatever ALT does mid-drag
  if st == "alt_pend" then
    if dist2(inp.sx, inp.sy, g.px, g.py) > M.DRAG_PX * M.DRAG_PX then
      -- crossed the threshold: a move begins; select the target if it isn't
      if not M.selected(doc, g.target) then doc.sel = { g.target } end
      doc.focus = g.target
      g.state = "alt_move"
      g.lx, g.ly = inp.wx, inp.wy
    elseif not inp.down1 then
      -- still-click: select / drill (teidraw resolve_target)
      local id = M.resolve_target(doc, g.target)
      if M.selected(doc, id) and #doc.sel == 1 then
        -- second A-click on the selected item: drill into it when it's a
        -- group (R3 leaves: no-op by design)
        local w = M.get(doc, id)
        if w and w.kind == "group" then doc.drill = id end
      end
      doc.sel = { id }
      doc.focus = id
      g.state = nil
      g.changed = true
    end
    return true
  elseif st == "alt_move" then
    if inp.down1 then
      local dx, dy = inp.wx - g.lx, inp.wy - g.ly
      if dx ~= 0 or dy ~= 0 then
        M.move_sel(doc, dx, dy)
        g.lx, g.ly = inp.wx, inp.wy
        g.changed = true
      end
    else
      g.state = nil
    end
    return true
  elseif st == "alt_rpend" then
    if not inp.down3 then
      if dist2(inp.sx, inp.sy, g.px, g.py) <= M.DRAG_PX * M.DRAG_PX then
        M.close(doc, g.target) -- A-rightclick: close (fearless by §6)
        g.changed = true
      end
      g.state = nil
    end
    return true
  elseif st == "marquee" then
    g.mx1, g.my1 = inp.wx, inp.wy
    if not inp.down1 then
      doc.sel = M.intersecting(doc, g.mx0, g.my0, g.mx1, g.my1)
      doc.focus = doc.sel[#doc.sel] or 0
      g.state = nil
      g.changed = true
    end
    return true
  elseif st == "resize" then
    if inp.down1 then
      M.resize(doc, g.target, g.part, g.r0, inp.wx - g.wx0, inp.wy - g.wy0)
      g.changed = true
    else
      g.state = nil
    end
    return true
  end

  -- idle: do we begin a gesture this frame?
  if inp.alt and inp.clicked1 then
    local target = move_target(doc, inp.wx, inp.wy)
    if target then
      g.state = "alt_pend"
      g.target = target
      g.px, g.py = inp.sx, inp.sy
      return true
    end
    g.state = "marquee" -- A-drag on empty canvas
    g.mx0, g.my0, g.mx1, g.my1 = inp.wx, inp.wy, inp.wx, inp.wy
    return true
  end
  if inp.alt and inp.clicked3 then
    local id = M.hit(doc, inp.wx, inp.wy, 0)
    if id then
      g.state = "alt_rpend"
      g.target = id
      g.px, g.py = inp.sx, inp.sy
      return true
    end
    return false
  end
  if not inp.alt and inp.clicked1 then
    local id, part = M.hit(doc, inp.wx, inp.wy, inp.band)
    if id and part ~= "content" then
      local w = M.get(doc, id)
      g.state = "resize"
      g.target = id
      g.part = part
      g.r0 = { x = w.x, y = w.y, w = w.w, h = w.h }
      g.wx0, g.wy0 = inp.wx, inp.wy
      return true
    end
    if id then
      doc.focus = id -- content-click focuses (never raises)
      g.changed = true
      return false -- content owns the rest of the gesture
    end
  end
  return false
end

return M
