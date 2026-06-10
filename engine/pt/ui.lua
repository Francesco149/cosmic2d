-- pt.ui — immediate-mode UI core (M2). Panels and widgets are plain function
-- calls made every frame; the only retained state is a per-id table (scroll
-- offsets, collapse flags, text cursors) keyed by a hierarchical id path.
--
-- Determinism class: dev/render only. pt.ui must never touch named buffers,
-- the doc tree or pt.rand — UI state lives on this module table (survives
-- hot reload, deliberately resets on VM reboot) and is never recorded in
-- snapshots or traces. Anything a widget *edits* (e.g. a knob in the doc
-- tree) is the caller's write, on the caller's head.
--
-- Frame protocol (pt.main drives this; cartridges just draw widgets):
--   1. ui.frame(events) at tick start ingests this tick's raw events and
--      returns the events the game may see, filtered by LAST tick's capture
--      flags (the classic one-frame imgui latency). Key-ups and button-ups
--      always pass so the game never sees a stuck key.
--   2. During the draw phase, panels/widgets run: begin_panel … end_panel.
--   3. ui.frame_end() resolves hover (topmost = last drawn), computes next
--      tick's capture flags, manages pal.text_input around focus.
--
-- Interaction model: `hot` is the widget under the mouse as resolved at the
-- END of the previous frame (so overlapping panels resolve by draw order:
-- later = on top); `active` is the widget owning a mouse drag; `focus` is
-- the widget owning the keyboard. Widgets only arm on click when hot.
--
-- Ids: push_id/pop_id scope a path stack; a widget's id is its label (or
-- explicit id) appended to the path, e.g. "console/input". Stable across
-- frames as long as the call structure is; pass explicit ids in loops.

local M = select(2, ...) or {}

local text = pt.require("pt.text")

-- ---- persistent module state (survives hot reload, not VM reboot) ----

M.s = M.s or {} -- id -> widget state table
M.style = M.style or {
  font = "5x8",
  gw = 5, gh = 8, -- glyph cell of style.font (kept in sync by ui.set_font)
  row_h = 11, pad = 4, gap = 2,
  scrollbar_w = 5, wheel_rows = 3,
  panel = { 0.09, 0.10, 0.14, 0.94 },
  panel_edge = { 0.30, 0.34, 0.46, 1.0 },
  title = { 0.13, 0.15, 0.22, 1.0 },
  widget = { 0.16, 0.18, 0.26, 1.0 },
  widget_hot = { 0.22, 0.25, 0.36, 1.0 },
  widget_active = { 0.28, 0.33, 0.48, 1.0 },
  accent = { 0.95, 0.75, 0.35, 1.0 },
  text = { 0.92, 0.94, 0.97, 1.0 },
  text_dim = { 0.55, 0.60, 0.70, 1.0 },
  error = { 1.0, 0.35, 0.35, 1.0 },
  track = { 0.12, 0.13, 0.19, 1.0 },
}

M.ticks = M.ticks or 0 -- render ticks, for cursor blink only (never sim)

-- per-tick input snapshot (rebuilt by ui.frame)
M.inp = M.inp or { mx = -1000, my = -1000, buttons = {}, clicked = {},
                   released = {}, wheel = 0, keys = {}, text = "" }

M.cap_mouse = M.cap_mouse or false -- filters applied to THIS tick's events
M.cap_keys = M.cap_keys or false

-- ---- internals (rebuilt every frame; plain locals are fine) ----

local lay_stack, clip_stack, id_stack, scroll_stack, panels = {}, {}, {}, {}, {}
local wheel_taken = false

-- ---- drawing helpers ----

function M.rect(x, y, w, h, c)
  pal.quad(x, y, w, h, c[1], c[2], c[3], c[4])
end

function M.frame_rect(x, y, w, h, c) -- 1px outline
  M.rect(x, y, w, 1, c)
  M.rect(x, y + h - 1, w, 1, c)
  M.rect(x, y + 1, 1, h - 2, c)
  M.rect(x + w - 1, y + 1, 1, h - 2, c)
end

function M.text(x, y, s, c, font)
  text.draw(x, y, s, { font = font or M.style.font,
                       r = c[1], g = c[2], b = c[3], a = c[4] })
end

local function text_w(s)
  return #s * M.style.gw
end

-- ---- ids ----

function M.push_id(seg)
  id_stack[#id_stack + 1] = tostring(seg)
end

function M.pop_id()
  id_stack[#id_stack] = nil
end

local function qid(local_id)
  if #id_stack == 0 then return local_id end
  return table.concat(id_stack, "/") .. "/" .. local_id
end

local function widget_state(id)
  local s = M.s[id]
  if not s then
    s = {}
    M.s[id] = s
  end
  return s
end

-- ---- input queries ----

local function mouse_in(x, y, w, h)
  local i = M.inp
  return i.mx >= x and i.mx < x + w and i.my >= y and i.my < y + h
end

local function clip_visible(x, y, w, h)
  local c = clip_stack[#clip_stack]
  if not c then return true end
  return x < c.x + c.w and x + w > c.x and y < c.y + c.h and y + h > c.y
end

-- hover candidate: topmost wins because later draws overwrite (panels draw
-- back to front). Mouse must also be inside the current clip (scrolled-out
-- widgets can't be hot).
local function hover(id, x, y, w, h)
  if mouse_in(x, y, w, h) and clip_visible(M.inp.mx, M.inp.my, 1, 1) then
    M.next_hot = id
    return true
  end
  return false
end

function M.is_hot(id) return M.hot == id end
function M.is_active(id) return M.active == id end
function M.capturing_mouse() return M.cap_mouse end
function M.capturing_keys() return M.cap_keys end

-- standard press/release arming for click-or-drag widgets. Returns
-- clicked (released while hot), held (active right now).
local function behave_button(id, x, y, w, h)
  hover(id, x, y, w, h)
  local clicked = false
  if M.active == id then
    if M.inp.released[1] then
      clicked = M.hot == id and mouse_in(x, y, w, h)
      M.active = nil
    end
  elseif M.hot == id and M.inp.clicked[1] and mouse_in(x, y, w, h) then
    M.active = id
  end
  return clicked, M.active == id
end

-- ---- frame lifecycle ----

-- ingest this tick's events; return what the game is allowed to see,
-- filtered by last tick's capture flags. Down-events are captured,
-- up-events always pass (no stuck keys/buttons in the game).
function M.frame(events)
  local i = M.inp
  i.clicked, i.released, i.keys = {}, {}, {}
  i.wheel = 0
  i.text = ""
  M.ticks = M.ticks + 1

  local out = {}
  for _, e in ipairs(events) do
    local pass = true
    if e.type == "key" then
      i.keys[#i.keys + 1] = e
      if e.down and M.cap_keys then pass = false end
    elseif e.type == "text" then
      i.text = i.text .. e.text
      pass = false -- text events are a UI-only stream
    elseif e.type == "motion" then
      i.mx, i.my = e.x, e.y
    elseif e.type == "button" then
      i.mx, i.my = e.x, e.y
      if e.down then
        i.buttons[e.button] = true
        i.clicked[e.button] = true
        if M.cap_mouse then pass = false end
      else
        i.buttons[e.button] = nil
        i.released[e.button] = true
      end
    elseif e.type == "wheel" then
      i.wheel = i.wheel + e.dy
      if M.cap_mouse then pass = false end
    end
    if pass then out[#out + 1] = e end
  end

  -- a new frame of widgets begins
  lay_stack, clip_stack, id_stack, scroll_stack, panels = {}, {}, {}, {}, {}
  M.next_hot = nil
  wheel_taken = false
  M.force_keys = false
  return out
end

-- panels/widgets ran; resolve hover + captures for next tick
function M.frame_end()
  M.hot = M.next_hot
  if M.active and not M.inp.buttons[1] then M.active = nil end -- lost release

  local over_panel = false
  for _, p in ipairs(panels) do
    if mouse_in(p.x, p.y, p.w, p.h) then over_panel = true break end
  end
  M.cap_mouse = over_panel or M.active ~= nil
  M.cap_keys = M.focus ~= nil or M.force_keys

  local want_text = M.focus ~= nil
  if want_text ~= M.text_on then
    pal.text_input(want_text)
    M.text_on = want_text
  end
end

-- engine overlays (console) call this each frame while they want the
-- keyboard even without a focused text widget
function M.capture_keys()
  M.force_keys = true
end

function M.blur()
  M.focus = nil
end

-- ---- layout ----

local function lay()
  return lay_stack[#lay_stack] or error("pt.ui: widget outside a panel", 3)
end

local function push_clip(x, y, w, h)
  local c = clip_stack[#clip_stack]
  if c then
    local x2 = math.min(x + w, c.x + c.w)
    local y2 = math.min(y + h, c.y + c.h)
    x, y = math.max(x, c.x), math.max(y, c.y)
    w, h = math.max(0, x2 - x), math.max(0, y2 - y)
  end
  local nc = { x = x, y = y, w = w, h = h }
  clip_stack[#clip_stack + 1] = nc
  pal.clip(nc.x, nc.y, nc.w, nc.h)
end

local function pop_clip()
  clip_stack[#clip_stack] = nil
  local c = clip_stack[#clip_stack]
  if c then pal.clip(c.x, c.y, c.w, c.h) else pal.clip() end
end

-- next widget rect: either the pending row column or a full-width strip
local function lay_next(h)
  local l = lay()
  h = h or M.style.row_h
  if l.row and l.row.i <= #l.row.cols then
    local col = l.row.cols[l.row.i]
    l.row.i = l.row.i + 1
    local r = { x = col.x, y = l.cy, w = col.w, h = l.row.h }
    if l.row.i > #l.row.cols then
      l.cy = l.cy + l.row.h + M.style.gap
      l.row = nil
    end
    return r
  end
  local r = { x = l.x + l.indent, y = l.cy, w = l.w - l.indent, h = h }
  l.cy = l.cy + h + M.style.gap
  return r
end

-- split the next strip into weighted columns; the following #weights
-- widgets fill them left to right
function M.row(weights, h)
  local l = lay()
  local total = 0
  for _, w in ipairs(weights) do total = total + w end
  local x = l.x + l.indent
  local avail = l.w - l.indent - M.style.gap * (#weights - 1)
  local cols = {}
  for i, wt in ipairs(weights) do
    local cw = i == #weights and (l.x + l.w - x) -- remainder, no rounding gap
               or math.floor(avail * wt / total)
    cols[i] = { x = x, w = cw }
    x = x + cw + M.style.gap
  end
  l.row = { cols = cols, i = 1, h = h or M.style.row_h }
end

function M.indent(px)
  local l = lay()
  l.indent = l.indent + (px or 10)
end

function M.unindent(px)
  local l = lay()
  l.indent = math.max(0, l.indent - (px or 10))
end

function M.space(px)
  local l = lay()
  l.cy = l.cy + (px or M.style.gap * 2)
end

function M.separator()
  local r = lay_next(3)
  M.rect(r.x, r.y + 1, r.w, 1, M.style.panel_edge)
end

-- y the next widget will land at (content measurement)
function M.cursor_y()
  return lay().cy
end

-- ---- panels ----

-- fixed-rect panel: bg, optional title band, content layout with padding.
-- Registers its rect for mouse capture.
function M.begin_panel(id, x, y, w, h, opts)
  opts = opts or {}
  pal.camera(0, 0) -- UI is screen-space; undo whatever the game left
  local st = M.style
  panels[#panels + 1] = { x = x, y = y, w = w, h = h }
  M.rect(x, y, w, h, opts.bg or st.panel)
  if opts.edge ~= false then M.frame_rect(x, y, w, h, st.panel_edge) end
  local cy = y + st.pad
  if opts.title then
    M.rect(x + 1, y + 1, w - 2, st.row_h + 1, st.title)
    M.text(x + st.pad, y + 3, opts.title, st.accent)
    cy = y + st.row_h + 2 + st.pad
  end
  M.push_id(id)
  lay_stack[#lay_stack + 1] = {
    x = x + st.pad, cy = cy, w = w - st.pad * 2, indent = 0,
    panel = true,
  }
  push_clip(x, y, w, h)
  return w - st.pad * 2
end

function M.end_panel()
  pop_clip()
  lay_stack[#lay_stack] = nil
  M.pop_id()
end

-- ---- scrolling ----

-- vertical scroll region of fixed height h inside the current layout.
-- Content height is measured as widgets advance the inner cursor; the
-- scrollbar appears when content overflows. Wheel scrolls when hovered
-- (innermost region wins).
function M.begin_scroll(id, h, opts)
  opts = opts or {}
  id = qid(id)
  local st = M.style
  local s = widget_state(id)
  s.scroll = s.scroll or 0
  local r = lay_next(h)
  if opts.bg then M.rect(r.x, r.y, r.w, r.h, opts.bg) end
  push_clip(r.x, r.y, r.w, r.h)
  local inner_w = r.w - st.scrollbar_w - 1
  lay_stack[#lay_stack + 1] = {
    x = r.x, cy = r.y - s.scroll, w = inner_w, indent = 0,
  }
  scroll_stack[#scroll_stack + 1] = { id = id, rect = r,
                                      start_cy = r.y - s.scroll }
  M.push_id(id)
  return inner_w
end

function M.end_scroll()
  local st = M.style
  local sc = scroll_stack[#scroll_stack]
  scroll_stack[#scroll_stack] = nil
  local l = lay_stack[#lay_stack]
  lay_stack[#lay_stack] = nil
  M.pop_id()
  pop_clip()

  local s = widget_state(sc.id)
  local r = sc.rect
  s.content_h = l.cy - sc.start_cy
  local max_scroll = math.max(0, s.content_h - r.h)
  if s.want_bottom then
    s.scroll = max_scroll
    s.want_bottom = nil
  end

  -- wheel: innermost hovered scroll region consumes it
  if not wheel_taken and M.inp.wheel ~= 0 and mouse_in(r.x, r.y, r.w, r.h)
     and clip_visible(M.inp.mx, M.inp.my, 1, 1) then
    s.scroll = s.scroll - M.inp.wheel * st.wheel_rows * st.row_h
    wheel_taken = true
  end

  -- scrollbar
  if max_scroll > 0 then
    local bx = r.x + r.w - st.scrollbar_w
    M.rect(bx, r.y, st.scrollbar_w, r.h, st.track)
    local th = math.max(8, r.h * r.h // s.content_h)
    local tid = sc.id .. "/thumb"
    local ty = r.y + (r.h - th) * (s.scroll / max_scroll)
    local _, held = behave_button(tid, bx - 1, r.y, st.scrollbar_w + 2, r.h)
    if held then
      local ws = widget_state(tid)
      if M.inp.clicked[1] or not ws.drag then
        -- grab: remember offset into the thumb (or jump if outside it)
        local dy = M.inp.my - ty
        ws.drag = (dy >= 0 and dy < th) and dy or th / 2
      end
      local want_ty = M.inp.my - ws.drag
      s.scroll = (want_ty - r.y) / math.max(1, r.h - th) * max_scroll
    else
      widget_state(tid).drag = nil
    end
    ty = r.y + (r.h - th) * (math.min(math.max(s.scroll, 0), max_scroll)
                             / max_scroll)
    M.rect(bx, ty, st.scrollbar_w,
           th, M.is_active(tid) and M.style.accent or M.style.widget_hot)
  end

  s.scroll = math.min(math.max(s.scroll, 0), max_scroll)
end

function M.scroll_get(id)
  local s = M.s[qid(id)]
  return s and s.scroll or 0
end

function M.scroll_set(id, v)
  widget_state(qid(id)).scroll = v -- clamped at next end_scroll
end

-- is the region scrolled to (within one row of) the bottom?
function M.scroll_at_bottom(id, h)
  local s = M.s[qid(id)]
  if not s or not s.content_h then return true end
  local max_scroll = math.max(0, s.content_h - h)
  return s.scroll >= max_scroll - M.style.row_h
end

function M.scroll_to_bottom(id)
  -- applied at the surrounding end_scroll, once content is measured
  widget_state(qid(id)).want_bottom = true
end

-- virtualized fixed-row-height list: draws only rows intersecting the clip.
-- draw_row(i, x, y, w, row_h) draws row i at the given rect; rows are laid
-- bottom of one to top of next with no extra gap.
function M.list(count, row_h, draw_row)
  local l = lay()
  local c = clip_stack[#clip_stack]
  local y0 = l.cy
  local first, last = 1, count
  if c and count > 0 then
    first = math.max(1, (c.y - y0) // row_h + 1)
    last = math.min(count, (c.y + c.h - y0 - 1) // row_h + 1)
  end
  local w = l.w - l.indent
  for i = first, last do
    draw_row(i, l.x + l.indent, y0 + (i - 1) * row_h, w, row_h)
  end
  l.cy = y0 + count * row_h
end

-- ---- widgets ----

function M.label(s, opts)
  opts = opts or {}
  local st = M.style
  local r = lay_next(opts.h)
  if clip_visible(r.x, r.y, r.w, r.h) then
    M.text(r.x, r.y + (r.h - st.gh) // 2, s, opts.color or st.text, opts.font)
  end
  return r
end

function M.button(label, opts)
  opts = opts or {}
  local st = M.style
  local id = qid(opts.id or label)
  local r = lay_next(opts.h)
  local clicked, held = behave_button(id, r.x, r.y, r.w, r.h)
  if clip_visible(r.x, r.y, r.w, r.h) then
    local bg = held and st.widget_active or
               (M.is_hot(id) and st.widget_hot or st.widget)
    M.rect(r.x, r.y, r.w, r.h, bg)
    M.frame_rect(r.x, r.y, r.w, r.h, st.panel_edge)
    local tw = text_w(label)
    M.text(r.x + (r.w - tw) // 2, r.y + (r.h - st.gh) // 2, label,
           opts.color or st.text)
  end
  return clicked
end

function M.checkbox(label, value, opts)
  opts = opts or {}
  local st = M.style
  local id = qid(opts.id or label)
  local r = lay_next()
  local clicked, held = behave_button(id, r.x, r.y, r.w, r.h)
  if clicked then value = not value end
  if clip_visible(r.x, r.y, r.w, r.h) then
    local box = r.h - 2
    local bg = held and st.widget_active or
               (M.is_hot(id) and st.widget_hot or st.widget)
    M.rect(r.x, r.y + 1, box, box, bg)
    M.frame_rect(r.x, r.y + 1, box, box, st.panel_edge)
    if value then
      M.rect(r.x + 2, r.y + 3, box - 4, box - 4, st.accent)
    end
    M.text(r.x + box + st.pad, r.y + (r.h - st.gh) // 2, label, st.text)
  end
  return value, clicked
end

local function fmt_num(v, fmt)
  if fmt then return fmt:format(v) end
  if math.type(v) == "integer" then return tostring(v) end
  return ("%.3g"):format(v)
end

-- label left, draggable track right. Returns value, changed.
function M.slider(label, value, min, max, opts)
  opts = opts or {}
  local st = M.style
  local id = qid(opts.id or label)
  local r = lay_next()
  local lw = opts.label_w or (r.w * 45 // 100)
  local tx, tw = r.x + lw, r.w - lw
  local _, held = behave_button(id, tx, r.y, tw, r.h)
  local changed = false
  if held and tw > 4 then
    local t = (M.inp.mx - tx - 2) / (tw - 4)
    t = math.min(math.max(t, 0.0), 1.0)
    local v = min + (max - min) * t
    if opts.step then v = min + math.floor((v - min) / opts.step + 0.5) * opts.step end
    if math.type(value) == "integer" then v = math.floor(v + 0.5) end
    if v ~= value then value, changed = v, true end
  end
  if clip_visible(r.x, r.y, r.w, r.h) then
    M.text(r.x, r.y + (r.h - st.gh) // 2, label, st.text_dim)
    M.rect(tx, r.y + 1, tw, r.h - 2, st.track)
    M.frame_rect(tx, r.y + 1, tw, r.h - 2, st.panel_edge)
    local t = max > min and (value - min) / (max - min) or 0
    t = math.min(math.max(t, 0.0), 1.0)
    M.rect(tx + 1, r.y + 2, math.max(0, (tw - 2) * t // 1), r.h - 4,
           held and st.accent or st.widget_active)
    local vs = fmt_num(value, opts.fmt)
    M.text(tx + tw - text_w(vs) - 2, r.y + (r.h - st.gh) // 2, vs, st.text)
  end
  return value, changed
end

-- horizontal drag-to-adjust number (unbounded unless min/max given)
function M.number(label, value, opts)
  opts = opts or {}
  local st = M.style
  local id = qid(opts.id or label)
  local r = lay_next()
  local lw = opts.label_w or (r.w * 45 // 100)
  local tx, tw = r.x + lw, r.w - lw
  local _, held = behave_button(id, tx, r.y, tw, r.h)
  local s = widget_state(id)
  local changed = false
  if held then
    if s.last_mx then
      local dv = (M.inp.mx - s.last_mx) * (opts.speed or 1.0)
      if dv ~= 0 then
        local v = value + dv
        if opts.min then v = math.max(v, opts.min) end
        if opts.max then v = math.min(v, opts.max) end
        if math.type(value) == "integer" then
          v = math.tointeger(v // 1) or value
        end
        if v ~= value then value, changed = v, true end
      end
    end
    s.last_mx = M.inp.mx
  else
    s.last_mx = nil
  end
  if clip_visible(r.x, r.y, r.w, r.h) then
    M.text(r.x, r.y + (r.h - st.gh) // 2, label, st.text_dim)
    local bg = held and st.widget_active or
               (M.is_hot(id) and st.widget_hot or st.widget)
    M.rect(tx, r.y + 1, tw, r.h - 2, bg)
    M.frame_rect(tx, r.y + 1, tw, r.h - 2, st.panel_edge)
    local vs = fmt_num(value, opts.fmt)
    M.text(tx + (tw - text_w(vs)) // 2, r.y + (r.h - st.gh) // 2, vs, st.text)
  end
  return value, changed
end

-- collapsing section header; persistent open state. Indents while open:
--   if ui.heading("Physics") then ... ui.heading_end() end
function M.heading(label, opts)
  opts = opts or {}
  local st = M.style
  local id = qid(opts.id or label)
  local s = widget_state(id)
  if s.open == nil then s.open = opts.default_open ~= false end
  local r = lay_next()
  local clicked = behave_button(id, r.x, r.y, r.w, r.h)
  if clicked then s.open = not s.open end
  if clip_visible(r.x, r.y, r.w, r.h) then
    M.rect(r.x, r.y, r.w, r.h, M.is_hot(id) and st.widget_hot or st.title)
    local ty = r.y + (r.h - st.gh) // 2
    M.text(r.x + 2, ty, s.open and "v" or ">", st.accent)
    M.text(r.x + 2 + st.gw + 3, ty, label, st.text)
  end
  if s.open then M.indent(opts.indent or 8) end
  return s.open
end

function M.heading_end(opts)
  M.unindent(opts and opts.indent or 8)
end

-- ---- text input ----

local function utf8_prev(s, i) -- byte index of the sequence start before i
  i = i - 1
  while i > 1 and s:byte(i) and s:byte(i) & 0xc0 == 0x80 do i = i - 1 end
  return math.max(i, 1)
end

local function utf8_next(s, i) -- byte index after the sequence starting at i
  i = i + 1
  while i <= #s and s:byte(i) & 0xc0 == 0x80 do i = i + 1 end
  return i
end

local SC = { ret = 40, esc = 41, backspace = 42, tab = 43,
             right = 79, left = 80, down = 81, up = 82,
             home = 74, kend = 77, delete = 76 }

-- single-line text field. Returns text, changed, submitted.
-- opts: hint (placeholder), keep_focus (stay focused after enter, for
-- consoles), id (when label-less), on_key(scancode) -> true to consume
-- (history navigation etc; called for non-editing keys while focused).
function M.text_input(id, txt, opts)
  opts = opts or {}
  txt = txt or ""
  local st = M.style
  id = qid(id)
  local r = lay_next()
  local s = widget_state(id)
  s.cursor = math.min(s.cursor or #txt + 1, #txt + 1)

  -- consoles etc: own the keyboard whenever nobody else does
  if opts.take_focus and M.focus == nil then
    M.focus = id
    s.cursor = #txt + 1
  end

  behave_button(id, r.x, r.y, r.w, r.h) -- registers hover
  -- focus on press (standard text-field feel), needs last-frame hover
  if M.hot == id and M.inp.clicked[1] and mouse_in(r.x, r.y, r.w, r.h) then
    M.focus = id
    -- place cursor from click x (byte-cell math: text.draw is per-byte)
    local rel = (M.inp.mx - (r.x + 3) + (s.sx or 0)) // st.gw
    s.cursor = math.min(math.max(rel + 1, 1), #txt + 1)
  end

  local focused = M.focus == id
  local changed, submitted = false, false

  if focused then
    -- text insertion
    if #M.inp.text > 0 then
      local ins = M.inp.text:gsub("[\r\n]", "")
      txt = txt:sub(1, s.cursor - 1) .. ins .. txt:sub(s.cursor)
      s.cursor = s.cursor + #ins
      changed = true
    end
    -- editing keys (with key repeat)
    for _, k in ipairs(M.inp.keys) do
      if k.down then
        local c = k.scancode
        if c == SC.backspace and s.cursor > 1 then
          local p = utf8_prev(txt, s.cursor)
          txt = txt:sub(1, p - 1) .. txt:sub(s.cursor)
          s.cursor, changed = p, true
        elseif c == SC.delete and s.cursor <= #txt then
          txt = txt:sub(1, s.cursor - 1) .. txt:sub(utf8_next(txt, s.cursor))
          changed = true
        elseif c == SC.left and s.cursor > 1 then
          s.cursor = utf8_prev(txt, s.cursor)
        elseif c == SC.right and s.cursor <= #txt then
          s.cursor = utf8_next(txt, s.cursor)
        elseif c == SC.home then
          s.cursor = 1
        elseif c == SC.kend then
          s.cursor = #txt + 1
        elseif c == SC.ret then
          submitted = true
          if not opts.keep_focus then M.focus = nil end
        elseif c == SC.esc then
          M.focus = nil
        elseif opts.on_key then
          opts.on_key(c)
        end
      end
    end
  end

  -- click elsewhere blurs (any click that didn't land on us)
  if focused and M.inp.clicked[1] and not mouse_in(r.x, r.y, r.w, r.h) then
    M.focus = nil
  end
  focused = M.focus == id

  -- horizontal scroll keeps the cursor visible
  s.sx = s.sx or 0
  local cur_px = (s.cursor - 1) * st.gw
  local vis_w = r.w - 6
  if cur_px - s.sx > vis_w - st.gw then s.sx = cur_px - vis_w + st.gw end
  if cur_px - s.sx < 0 then s.sx = cur_px end
  if #txt * st.gw <= vis_w then s.sx = 0 end

  if clip_visible(r.x, r.y, r.w, r.h) then
    M.rect(r.x, r.y, r.w, r.h, st.track)
    M.frame_rect(r.x, r.y, r.w, r.h,
                 focused and st.accent or st.panel_edge)
    push_clip(r.x + 2, r.y, r.w - 4, r.h)
    local ty = r.y + (r.h - st.gh) // 2
    if #txt == 0 and opts.hint and not focused then
      M.text(r.x + 3, ty, opts.hint, st.text_dim)
    else
      M.text(r.x + 3 - s.sx, ty, txt, st.text)
    end
    if focused and (M.ticks // 30) % 2 == 0 then
      M.rect(r.x + 3 + cur_px - s.sx, ty - 1, 1, st.gh + 2, st.accent)
    end
    pop_clip()
  end

  return txt, changed, submitted
end

-- place a text_input's cursor after changing its text externally (history
-- navigation etc). Call in the same id scope as the widget.
function M.text_cursor(id, pos)
  widget_state(qid(id)).cursor = pos
end

return M
