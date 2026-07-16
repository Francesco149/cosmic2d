-- cm.ed.rewind -- the A7 rewind timeline tray (REWIND.md ss10-11).
--
-- This is editor chrome: its camera, open state, gestures, summary cache,
-- and notifications live in ed.g and never enter the captured editor doc.
-- The tray is a front-end over cm.scrub's park/restore machinery and
-- cm.trace's read-only timeline summaries. It never reconstructs state merely
-- to draw; only an explicit seek asks scrub to restore a frame.

local M = select(2, ...) or {}
local trace = cm.require("cm.trace")
local scrub = cm.require("cm.scrub")
local wm = cm.require("cm.ed.wm")

M.DEFAULT_SPAN = 10 * 60 * 60 -- ten minutes at the fixed 60 Hz
M.MIN_SPAN = 60               -- the near zoom shows individual frames
M.ZOOM_STEP = 1.18

local C = {
  panel = 0x191726fa, panel2 = 0x211e32ff, lane = 0x151321ff,
  edge = 0x4a4370ff, edge_hot = 0x6a60a0ff,
  text = 0xe8e4ffff, dim = 0x8a84b0ff, faint = 0x5e587cff,
  accent = 0x7fd8a8ff, accent_dim = 0x426e5aff,
  playhead = 0xf5efffff, live = 0x7fd8a8ff, retained = 0x8878d0ff,
  sim = 0x786bd8ff, editor = 0x62c9a2ff, files = 0xffb46eff,
  input = 0x73b9e6ff, code = 0xffb46eff, eval = 0xc68ce8ff,
  session = 0xf07f8fff, selection = 0x7fd8a826,
  selection_edge = 0x7fd8a8dd, button = 0x2a263dff,
  button_hot = 0x3a3560ff, button_off = 0x211e32ff,
  tooltip = 0x100f1bf4,
}

local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local function inside(i, x, y, w, h)
  return i.wx >= x and i.wx < x + w and i.wy >= y and i.wy < y + h
end

local function rect_has(r, i)
  return r and inside(i, r.x, r.y, r.w, r.h)
end

local function state(ed)
  local r = ed.g.rw
  if not r then
    r = {}
    ed.g.rw = r
  end
  return r
end

-- Pure camera helpers are public so the headless selftest can pin the exact
-- zoom-at-cursor and pan contract without an imgui surface.
function M.default_view(lo, hi)
  local total = math.max(1, hi - lo)
  local span = math.min(total, M.DEFAULT_SPAN)
  return { start = hi - span, span = span, follow = true, default = true }
end

function M.clamp_view(v, lo, hi)
  local total = math.max(1, hi - lo)
  local min_span = math.min(total, M.MIN_SPAN)
  v.span = clamp(v.span or total, min_span, total)
  v.start = clamp(v.start or (hi - v.span), lo, hi - v.span)
  if math.abs(v.start + v.span - hi) < 0.5 then
    v.start = hi - v.span
    v.follow = true
  end
  return v
end

function M.zoom_view(v, anchor, notches, lo, hi)
  M.clamp_view(v, lo, hi)
  anchor = clamp(anchor or 0.5, 0, 1)
  local fixed = v.start + v.span * anchor
  v.span = v.span / (M.ZOOM_STEP ^ notches)
  v.start = fixed - v.span * anchor
  v.follow, v.default = false, false
  M.clamp_view(v, lo, hi)
  return v
end

function M.pan_view(v, dx, width, lo, hi)
  M.clamp_view(v, lo, hi)
  if width and width > 0 then v.start = v.start - dx * v.span / width end
  v.follow, v.default = false, false
  M.clamp_view(v, lo, hi)
  return v
end

function M.frame_at(v, x, x0, width, lo, hi)
  local t = width > 0 and clamp((x - x0) / width, 0, 1) or 0
  return clamp(math.floor(v.start + t * v.span + 0.5), lo, hi)
end

local function x_at(v, f, x, w)
  return x + (f - v.start) / math.max(1, v.span) * w
end

local function fmt_duration(frames)
  local seconds = math.max(0, math.floor(frames / 60 + 0.5))
  local h, m, s = seconds // 3600, seconds % 3600 // 60, seconds % 60
  if h > 0 then return ("%dh %02dm"):format(h, m) end
  if m > 0 then return ("%dm %02ds"):format(m, s) end
  return ("%ds"):format(s)
end

local function fmt_offset(frames)
  local sign = frames < 0 and "-" or "+"
  local n = math.abs(frames)
  local sec = n // 60
  local ff = n % 60
  if sec >= 3600 then
    return ("%s%d:%02d:%02d.%02d"):format(sign, sec // 3600,
      sec % 3600 // 60, sec % 60, math.floor(ff * 100 / 60))
  end
  return ("%s%02d:%02d.%02d"):format(sign, sec // 60, sec % 60,
    math.floor(ff * 100 / 60))
end

local function fmt_bytes(n)
  n = math.max(0, n or 0)
  if n >= 1024 * 1024 * 1024 then return ("%.2f GB"):format(n / 2^30) end
  if n >= 1024 * 1024 then return ("%.1f MB"):format(n / 2^20) end
  if n >= 1024 then return ("%.1f KB"):format(n / 2^10) end
  return ("%d B"):format(n)
end

local function text(x, y, px, color, s)
  pal.x_ig_text(x, y, px, color, s, 0)
end

local function button(i, x, y, w, h, label, opts)
  opts = opts or {}
  local enabled = opts.enabled ~= false
  local hov = enabled and inside(i, x, y, w, h)
  pal.x_ig_rect_fill(x, y, w, h,
    not enabled and C.button_off or (hov and C.button_hot or C.button), 5)
  if opts.outline then
    pal.x_ig_rect(x, y, w, h, opts.outline, 1, 5)
  end
  local px = opts.px or 12
  local tw = pal.x_ig_text_size(label, px, 0)
  text(x + (w - tw) * 0.5, y + (h - px) * 0.46, px,
    not enabled and C.faint or (opts.accent and C.accent or
      (hov and C.text or C.dim)), label)
  return hov and i.clicked[1]
end

local function flash(r, msg)
  r.flash = { msg = msg, at = pal.time_ns() }
end

function M.opened(ed)
  return state(ed).open == true
end

function M.open(ed)
  local lo, hi = trace.ring_range()
  if not lo then return false end
  local r = state(ed)
  r.open = true
  r.view = M.default_view(lo, hi)
  r.summary = nil
  return true
end

function M.close(ed, force)
  local r = state(ed)
  if scrub.has_loop and scrub.has_loop() and not force then
    flash(r, "Esc clears the clip before rewind can close")
    return false
  end
  if scrub.paused() then scrub.close() end
  r.open, r.gesture, r.preview = nil, nil, nil
  r.summary = nil
  return true
end

function M.toggle(ed)
  local r = state(ed)
  if not r.open then return M.open(ed) end
  return M.close(ed, false)
end

-- Esc is deliberately layered: clip first, tray/past second.
function M.escape(ed)
  local r = state(ed)
  if scrub.has_loop and scrub.has_loop() then
    scrub.clear_loop()
    r.preview = nil
    flash(r, "clip cleared -- Esc again returns to live")
    return true
  end
  if r.open or scrub.paused() then
    M.close(ed, true)
    return true
  end
  return false
end

local function park_at(f)
  if not scrub.paused() then scrub.open() end
  if scrub.paused() then scrub.seek(f) end
end

function M.key(ed, scancode, shift)
  local r = state(ed)
  if not r.open then return false end
  local lo, hi = trace.ring_range()
  if not lo then return false end
  local at = scrub.paused() and scrub.at or hi
  if scancode == 80 or scancode == 79 then -- left / right
    park_at(clamp(at + (scancode == 80 and -(shift and 60 or 1)
                                      or (shift and 60 or 1)), lo, hi))
    return true
  elseif scancode == 44 then -- space
    if not scrub.paused() then
      park_at(clamp(math.floor(r.view.start + 0.5), lo, hi))
    end
    scrub.toggle_play()
    return true
  end
  return false
end

function M.owns_pointer(ed, i)
  local r = state(ed)
  return r.gesture ~= nil or rect_has(r.rect, i) or rect_has(r.pill, i)
end

local function nice_step(span, width)
  local want = span / math.max(1, width / 92)
  local steps = { 1, 5, 10, 30, 60, 5 * 60, 10 * 60, 30 * 60,
                  60 * 60, 5 * 60 * 60, 10 * 60 * 60,
                  30 * 60 * 60, 60 * 60 * 60 }
  for _, s in ipairs(steps) do if s >= want then return s end end
  return steps[#steps]
end

local function summary_for(r, v, aw, hi)
  local q0, q1 = math.floor(v.start), math.ceil(v.start + v.span)
  -- A few screen pixels per max-bin remain visually lossless at this tray
  -- size and keep the imgui drawlist compact. Near zoom never needs more
  -- bins than visible frames.
  local bins = math.max(24, math.min(256, math.floor(aw / 3),
                                     math.ceil(v.span) + 1))
  local old = r.summary
  local now = pal.time_ns()
  local drift = old and math.max(1, v.span / aw * 12) or 0
  local stale = not old or old.bins ~= bins
    or math.abs(q0 - old.q0) >= drift or math.abs(q1 - old.q1) >= drift
    or hi - old.hi >= 15
  if stale and (not old or now - (old.at or 0) >= 45e6) then
    local ok, got = pcall(trace.ring_timeline, q0, q1, bins)
    if ok then
      got.q0, got.q1, got.hi, got.at, got.bins = q0, q1, hi, now, bins
      r.summary = got
    else
      r.summary = { q0 = q0, q1 = q1, hi = hi, at = now, bins = bins,
                    error = tostring(got), data = {} }
    end
  end
  return r.summary
end

local function draw_ruler(v, ax, y, aw, h, hi)
  local step = nice_step(v.span, aw)
  local first = math.ceil(v.start / step) * step
  local minor = step >= 5 and step / 5 or nil
  if minor and minor >= 1 then
    local mf = math.ceil(v.start / minor) * minor
    while mf <= v.start + v.span do
      local x = x_at(v, mf, ax, aw)
      pal.x_ig_line(x, y, x, y + 5, C.faint, 1)
      mf = mf + minor
    end
  end
  while first <= v.start + v.span do
    local x = x_at(v, first, ax, aw)
    pal.x_ig_line(x, y, x, y + 10, C.dim, 1)
    local label = fmt_offset(first - hi)
    local tw = pal.x_ig_text_size(label, 10, 0)
    text(clamp(x - tw * 0.5, ax, ax + aw - tw), y + 12, 10, C.dim, label)
    first = first + step
  end
  pal.x_ig_line(ax, y, ax + aw, y, C.edge, 1)
end

local function draw_empty_previews(v, ax, y, aw, h, hi)
  -- Empty cards are explicit absence, not generated screenshots. Minute
  -- samples become real THMB media in the next A7 capture packet.
  local minute = 60 * 60
  local f = math.ceil(v.start / minute) * minute
  while f <= v.start + v.span do
    local x = x_at(v, f, ax, aw)
    pal.x_ig_line(x, y + 3, x, y + h - 3, 0x3a356066, 1)
    f = f + minute
  end
  local msg = "NO PRESENTED-FRAME PREVIEWS IN THIS HISTORY"
  local tw = pal.x_ig_text_size(msg, 10, 0)
  text(ax + (aw - tw) * 0.5, y + (h - 10) * 0.48, 10, C.faint, msg)
end

local function draw_activity(summary, v, ax, y, aw, h, i)
  if not summary or not summary.data or #summary.data == 0 then return end
  local max_stack = 0
  for _, b in ipairs(summary.data) do
    local n = math.log(1 + (b.sim or 0)) + math.log(1 + (b.editor or 0))
      + math.log(1 + (b.files or 0))
    if n > max_stack then max_stack = n end
  end
  max_stack = math.max(1, max_stack)
  local n = #summary.data
  local bw = aw / n
  local heights = {}
  for bi, b in ipairs(summary.data) do
    heights[bi] = {
      math.floor(math.log(1 + (b.sim or 0)) / max_stack * (h - 7) + 0.5),
      math.floor(math.log(1 + (b.editor or 0)) / max_stack * (h - 7) + 0.5),
      math.floor(math.log(1 + (b.files or 0)) / max_stack * (h - 7) + 0.5),
    }
  end
  -- Merge equal-height neighbors. Stable idle activity becomes one filled
  -- run rather than hundreds of tiny rectangles; one-bin spikes stay exact.
  local bottom = y + h - 3
  for layer, color in ipairs({ C.sim, C.editor, C.files }) do
    local run, run_y, run_h
    for bi = 1, n + 1 do
      local hs = heights[bi]
      local bh = hs and hs[layer] or -1
      local below = hs and ((layer >= 2 and hs[1] or 0)
                    + (layer >= 3 and hs[2] or 0)) or 0
      local by = bottom - below - math.max(0, bh)
      if run and (bh ~= run_h or by ~= run_y) then
        if run_h > 0 then
          local x0 = ax + (run - 1) * bw
          local x1 = ax + (bi - 1) * bw
          -- Thick lines are the filled-envelope primitive here: the current
          -- SDL-GPU imgui path corrupts earlier foreground commands when an
          -- AddRectFilled starts under a pushed foreground clip.
          pal.x_ig_line(x0, run_y + run_h * 0.5, x1,
                        run_y + run_h * 0.5, color, run_h)
        end
        run = nil
      end
      if not run and hs then run, run_y, run_h = bi, by, bh end
    end
  end

  if inside(i, ax, y, aw, h) then
    local bi = clamp(math.floor((i.wx - ax) / aw * n) + 1, 1, n)
    local b = summary.data[bi]
    if b then
      local f0 = math.floor(v.start + (bi - 1) / n * v.span)
      local f1 = math.floor(v.start + bi / n * v.span)
      local label = ("f%d%s  sim %s  editor %s  files %s"):format(
        f0, f1 > f0 and (".." .. f1) or "", fmt_bytes(b.sim),
        fmt_bytes(b.editor), fmt_bytes(b.files))
      local tw = pal.x_ig_text_size(label, 11, 0)
      local tx = clamp(i.wx + 12, ax, ax + aw - tw - 14)
      local ty = y - 25
      pal.x_ig_line(tx - 7, ty + 6.5, tx + tw + 7, ty + 6.5,
                    C.tooltip, 21)
      text(tx, ty, 11, C.text, label)
    end
  end
end

local function draw_events(summary, v, ax, y, aw, h)
  if not summary or not summary.data then return end
  local n = #summary.data
  if n == 0 then return end
  local bw = aw / n
  local E = trace.timeline_event or {}
  for bi, b in ipairs(summary.data) do
    local bits = b.events or 0
    if bits ~= 0 then
      local x = ax + (bi - 0.5) * bw
      if bits & (E.SESSION or 8) ~= 0 then
        pal.x_ig_line(x, y, x, y + h, C.session, 2)
      elseif bits & (E.CODE or 2) ~= 0 then
        pal.x_ig_line(x, y + 1, x, y + h, C.code, 2)
      elseif bits & (E.EVAL or 4) ~= 0 then
        pal.x_ig_line(x, y + 5, x, y + h, C.eval, 2)
      elseif bits & (E.INPUT or 1) ~= 0 then
        pal.x_ig_line(x, y + h - 7, x, y + h, C.input, 1)
      end
    end
  end
end

local function draw_range(a, b, v, ax, y, aw, h)
  if not a then return end
  local xa, xb = x_at(v, a, ax, aw), x_at(v, b, ax, aw)
  if xb < ax or xa > ax + aw then return end
  xa, xb = clamp(xa, ax, ax + aw), clamp(xb, ax, ax + aw)
  -- Same clipped-foreground rule as the activity envelope above.
  pal.x_ig_line(xa, y + h * 0.5, xb, y + h * 0.5, C.selection, h)
  pal.x_ig_line(xa, y, xa, y + h, C.selection_edge, 2)
  pal.x_ig_line(xb, y, xb, y + h, C.selection_edge, 2)
  local function tag(x, s)
    pal.x_ig_circle_fill(x, y + 10, 8, C.accent_dim)
    text(x - 4, y + 3, 11, C.accent, s)
  end
  tag(xa, "A")
  tag(xb, "B")
end

local function apply_gestures(r, i, v, lo, hi, ax, ay, aw, ah)
  local g = r.gesture
  if g then
    if g.kind == "pan" then
      if i.buttons[2] then
        v.start = g.start - (i.wx - g.sx) * v.span / aw
        v.follow, v.default = false, false
        M.clamp_view(v, lo, hi)
      else
        r.gesture = nil
        r.summary = nil
      end
      return
    end

    local f = M.frame_at(v, i.wx, ax, aw, lo, hi)
    if i.buttons[1] then
      local dx, dy = i.wx - g.sx, i.wy - g.sy
      if dx * dx + dy * dy > wm.DRAG_PX * wm.DRAG_PX then g.moved = true end
      if g.moved or g.handle then
        local a, b
        if g.handle == "a" then a, b = f, g.other
        elseif g.handle == "b" then a, b = g.other, f
        else a, b = g.frame, f end
        r.preview = { math.min(a, b), math.max(a, b) }
      end
    else
      if g.moved or g.handle then
        local p = r.preview or { g.frame, f }
        if not scrub.paused() then scrub.open() end
        if scrub.paused() then scrub.set_loop(p[1], p[2]) end
        r.view.follow, r.view.default = false, false
      else
        park_at(f)
      end
      r.preview, r.gesture = nil, nil
    end
    return
  end

  if not inside(i, ax, ay, aw, ah) then return end
  if i.wheel ~= 0 then
    M.zoom_view(v, (i.wx - ax) / aw, i.wheel, lo, hi)
    r.summary = nil
  end
  if i.clicked[2] then
    r.gesture = { kind = "pan", sx = i.wx, start = v.start }
  elseif i.clicked[1] then
    local f = M.frame_at(v, i.wx, ax, aw, lo, hi)
    local a, b = scrub.loop_range()
    local ha, hb
    if a then
      ha = math.abs(i.wx - x_at(v, a, ax, aw)) <= 7
      hb = math.abs(i.wx - x_at(v, b, ax, aw)) <= 7
    end
    if ha and (not hb or math.abs(f - a) <= math.abs(f - b)) then
      r.gesture = { kind = "left", sx = i.wx, sy = i.wy, frame = a,
                    handle = "a", other = b }
    elseif hb then
      r.gesture = { kind = "left", sx = i.wx, sy = i.wy, frame = b,
                    handle = "b", other = a }
    else
      r.gesture = { kind = "left", sx = i.wx, sy = i.wy, frame = f }
    end
  end
end

local function draw_legend(x, y)
  local function item(color, label)
    pal.x_ig_rect_fill(x, y + 3, 7, 7, color, 2)
    text(x + 11, y, 10, C.dim, label)
    x = x + 11 + pal.x_ig_text_size(label, 10, 0) + 12
  end
  item(C.sim, "sim")
  item(C.editor, "editor")
  item(C.files, "files")
end

function M.draw(ed, ig, i)
  local r = state(ed)
  local lo, hi = trace.ring_range()
  local parked = scrub.paused()
  if parked and lo and not r.open then
    r.open, r.view = true, M.default_view(lo, hi)
  end

  pal.x_ig_overlay(true)

  -- The collapsed entrance remains useful at all times: retained duration,
  -- a live recording dot, and a parked/clip state that reads at a glance.
  local pill_label
  if scrub.has_loop and scrub.has_loop() then pill_label = "A/B LOOP"
  elseif parked then pill_label = "PARKED"
  elseif lo then pill_label = fmt_duration(hi - lo)
  else pill_label = "NO HISTORY" end
  local px = 12
  local lw = pal.x_ig_text_size(pill_label, px, 0)
  local pw, ph = lw + 36, 26
  local pill = { x = ig.w - pw - 8, y = 8, w = pw, h = ph }
  r.pill = pill
  local pill_hov = rect_has(pill, i)
  pal.x_ig_rect_fill(pill.x, pill.y, pill.w, pill.h,
    r.open and 0x393456f5 or (pill_hov and C.button_hot or 0x262238ee), 8)
  pal.x_ig_circle_fill(pill.x + 11, pill.y + ph * 0.5, 3.5,
    parked and C.code or C.live)
  text(pill.x + 20, pill.y + 6, px,
    r.open and C.text or (parked and C.code or C.dim), pill_label)
  if pill_hov and i.clicked[1] and lo then M.toggle(ed) end

  if not r.open or not lo then
    r.rect = nil
    pal.x_ig_overlay(false)
    return
  end

  r.view = r.view or M.default_view(lo, hi)
  local v = r.view
  if v.default then
    v.span = math.min(math.max(1, hi - lo), M.DEFAULT_SPAN)
    v.start, v.follow = hi - v.span, true
  elseif v.follow then
    v.start = hi - v.span
  end
  M.clamp_view(v, lo, hi)

  local margin = 8
  local bh = math.min(248, math.max(176, ig.h - 70))
  local bx, by, bw = margin, ig.h - bh - margin, ig.w - margin * 2
  r.rect = { x = bx - 2, y = by - 2, w = bw + 4, h = bh + 4 }
  local over = rect_has(r.rect, i)
  local ui = cm.require("cm.ui")
  ui.force_keys = true
  if over or r.gesture then ui.force_mouse = true end

  pal.x_ig_rect_fill(bx, by, bw, bh, C.panel, 10)
  pal.x_ig_rect(bx, by, bw, bh, over and C.edge_hot or C.edge, 1, 10)

  local gutter, pad = 92, 12
  local ax, aw = bx + gutter, bw - gutter - pad
  local head_y, head_h = by, 31
  local film_y, film_h = by + 33, 58
  local act_y, act_h = film_y + film_h + 3, 48
  local event_y, event_h = act_y + act_h + 3, 22
  local ruler_y, ruler_h = event_y + event_h + 2, 31
  local foot_y, foot_h = by + bh - 34, 25
  local axis_h = ruler_y + ruler_h - film_y

  apply_gestures(r, i, v, lo, hi, ax, film_y, aw, axis_h)

  local stats = trace.ring_stats() or {}
  local used = math.max(stats.disk_bytes or 0,
    (stats.chunk_bytes or 0) + (stats.keyframe_bytes or 0))
  local budget = (trace.ring.budget_mb or 1024) * 1024 * 1024
  text(bx + 14, head_y + 9, 12, C.text, "REWIND")
  text(bx + 79, head_y + 9, 11, C.dim,
    parked and "LIVE HISTORY  /  PARKED" or "LIVE HISTORY  /  RECORDING")
  local storage = ("%s / %s   %d segments"):format(fmt_bytes(used),
    fmt_bytes(budget), stats.segs or 0)
  local stw = pal.x_ig_text_size(storage, 10, 0)
  text(bx + bw - stw - 45, head_y + 10, 10, C.dim, storage)
  if button(i, bx + bw - 33, head_y + 5, 23, 21, "x",
            { enabled = not scrub.has_loop() }) then
    M.close(ed, false)
    pal.x_ig_overlay(false)
    return
  end

  local function lane(y, h, label)
    pal.x_ig_rect_fill(bx + 8, y, bw - 16, h, C.lane, 4)
    text(bx + 17, y + 8, 10, C.faint, label)
  end
  lane(film_y, film_h, "PREVIEWS")
  lane(act_y, act_h, "ACTIVITY")
  lane(event_y, event_h, "EVENTS")
  lane(ruler_y, ruler_h, "TIME")
  draw_legend(bx + 260, head_y + 9)

  pal.x_ig_clip_push(ax, film_y, aw, axis_h)
  draw_empty_previews(v, ax, film_y, aw, film_h, hi)
  local summary = summary_for(r, v, aw, hi)
  draw_activity(summary, v, ax, act_y, aw, act_h, i)
  draw_events(summary, v, ax, event_y, aw, event_h)
  draw_ruler(v, ax, ruler_y, aw, ruler_h, hi)

  local a, b = scrub.loop_range()
  local rp = r.preview
  draw_range(rp and rp[1] or a, rp and rp[2] or b,
             v, ax, film_y, aw, axis_h)

  -- Retention edge, immutable live edge, and the currently shown frame share
  -- one axis. The playhead remains visible even while its camera is panned.
  local xr = x_at(v, lo, ax, aw)
  if xr >= ax and xr <= ax + aw then
    pal.x_ig_line(xr, film_y, xr, film_y + axis_h, C.retained, 2)
  end
  local xl = x_at(v, hi, ax, aw)
  if xl >= ax and xl <= ax + aw then
    pal.x_ig_line(xl, film_y, xl, film_y + axis_h, C.live, 2)
  end
  local at = parked and scrub.at or hi
  local xp = x_at(v, at, ax, aw)
  if xp >= ax and xp <= ax + aw then
    pal.x_ig_line(xp, film_y, xp, film_y + axis_h, C.playhead, 1.5)
    pal.x_ig_circle_fill(xp, ruler_y, 4.5, C.playhead)
  end
  pal.x_ig_clip_pop()

  -- Transport. Buttons are deliberately compact; the timeline itself is the
  -- primary control and remains the full-width hit target above.
  local x = bx + 12
  if button(i, x, foot_y, 30, foot_h, "|<") then park_at(lo) end
  x = x + 35
  if button(i, x, foot_y, 30, foot_h, "<") then
    park_at(clamp(at - 1, lo, hi))
  end
  x = x + 35
  if button(i, x, foot_y, 48, foot_h, scrub.play and "pause" or "play",
            { accent = scrub.play }) then
    if not parked then park_at(math.floor(v.start + 0.5)) end
    scrub.toggle_play()
  end
  x = x + 53
  if button(i, x, foot_y, 30, foot_h, ">") then
    park_at(clamp(at + 1, lo, hi))
  end
  x = x + 41
  local readout = ("frame %d / %d   %s"):format(at, hi, fmt_offset(at - hi))
  text(x, foot_y + 7, 11, parked and C.text or C.dim, readout)

  local right = bx + bw - 12
  local function place(w)
    right = right - w
    local rx = right
    right = right - 6
    return rx
  end
  if a then
    local ex = place(94)
    button(i, ex, foot_y, 94, foot_h, "export replay", { enabled = false })
  end
  if parked then
    local rx = place(92)
    if button(i, rx, foot_y, 92, foot_h, "resume here",
              { accent = true, enabled = not a }) then
      scrub.rewind_here()
      r.open = nil
      pal.x_ig_overlay(false)
      return
    end
    local fwin = wm.get(ed.doc, ed.doc.focus)
    local can_bring = fwin and fwin.path and fwin.path ~= "" and ed.doc.assets
      and ed.doc.assets[fwin.path]
    if can_bring then
      local bbx = place(83)
      if button(i, bbx, foot_y, 83, foot_h, "bring back",
                { accent = true }) then
        local got = ed.bring_back()
        if got then flash(r, "brought back: " .. got) end
      end
    end
  end
  if not v.follow or v.start + v.span < hi - 0.5 then
    local lx = place(86)
    if button(i, lx, foot_y, 86, foot_h, "back to live") then
      v.start, v.follow = hi - v.span, true
      M.clamp_view(v, lo, hi)
      r.summary = nil
    end
  end

  if a then
    local msg = ("CLIP  A %d  /  B %d  /  %s   --   Esc clears clip")
      :format(a, b, fmt_duration(b - a + 1))
    local mw = pal.x_ig_text_size(msg, 11, 0)
    pal.x_ig_rect_fill(ax + (aw - mw) * 0.5 - 10, film_y + 5,
      mw + 20, 22, 0x244237ee, 6)
    text(ax + (aw - mw) * 0.5, film_y + 10, 11, C.accent, msg)
  end

  if summary and summary.missing then
    text(ax + 8, act_y + 5, 9, C.faint,
      "OLDER LEGACY ACTIVITY HAS NO SUMMARY INDEX")
  end
  if r.flash and pal.time_ns() - r.flash.at < 2.4e9 then
    local msg = r.flash.msg
    local fw = pal.x_ig_text_size(msg, 11, 0)
    pal.x_ig_rect_fill(bx + (bw - fw) * 0.5 - 12, by - 29, fw + 24, 23,
      C.tooltip, 6)
    text(bx + (bw - fw) * 0.5, by - 24, 11, C.text, msg)
  end

  pal.x_ig_overlay(false)
end

return M
