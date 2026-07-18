-- cm.ed.win.console — the console as a canvas citizen (R4, EDITOR.md
-- §12.4). The scrollback is the same C-side pal.log ring the legacy
-- overlay reads (via cm.console.sb, whose incremental poll runs every
-- tick); Enter on the input line submits to cm.repl — the recorded EVAL
-- path — so a console window drives the sim exactly like the overlay
-- did. The legacy overlay keeps serving non-editor sessions; in editor
-- mode grave spawns/focuses one of these instead (the D050 §8 skip-ig-
-- frame gate died with this file).
--
-- Captured (win fields): itext (the input line), filter, sy + stick
-- (scroll). Ephemeral: history cursor, refocus intent, and the log
-- drag-selection (module-local by win.id — the D112 discipline: selection
-- state never rides a captured window into session.dat).

local M = select(2, ...) or {}

-- log selection: { a = {li, ci}, b = {li, ci}, drag, moved, tag, copy_t }.
-- li indexes the FILTERED lines list, ci is a byte offset; `tag` remembers
-- the anchored line's text so a scrollback trim / filter change (indices
-- shift) drops the selection honestly instead of drifting.
local SEL = {}
function M.sel_of(win)
  local s = SEL[win.id]
  if not s then
    s = {}
    SEL[win.id] = s
  end
  return s
end

local COPY_DWELL = 1.2e9 -- ns the "copied" tag stays up

-- byte offset for a horizontal pixel in line s (utf8-safe prefix walk)
function M.pick_ci(s, dx, px, measure)
  if dx <= 0 then return 0 end
  local i = 1
  while i <= #s do
    local c = s:byte(i)
    local step = (c < 0x80 or c >= 0xf0) and (c >= 0xf0 and 4 or 1)
                 or (c >= 0xe0 and 3 or 2)
    local j = math.min(#s, i + step - 1)
    local w = measure(s:sub(1, j), px, 1)
    if w > dx then
      -- inside this glyph: snap to the nearer edge
      local wprev = i == 1 and 0 or measure(s:sub(1, i - 1), px, 1)
      if dx - wprev < w - dx then return i - 1 end
      return j
    end
    i = j + 1
  end
  return #s
end

local function sel_norm(a, b)
  if b.li < a.li or (b.li == a.li and b.ci < a.ci) then return b, a end
  return a, b
end

-- pure extraction (KAT-able): the selected span of `lines`, exactly as
-- shown (timestamps included), lines joined with \n
function M.sel_text(lines, a, b)
  a, b = sel_norm(a, b)
  local out = {}
  for li = a.li, math.min(b.li, #lines) do
    local s = lines[li]
    local i0 = li == a.li and a.ci + 1 or 1
    local i1 = li == b.li and b.ci or #s
    out[#out + 1] = s:sub(i0, i1)
  end
  return table.concat(out, "\n")
end

-- Ctrl+C (the shell's kind_call("copy"))
function M.copy(win)
  local sl = M.sel_of(win)
  if not sl.a or not sl.b or not sl.lines
     or (sl.a.li == sl.b.li and sl.a.ci == sl.b.ci) then return end
  pal.x_clipboard(M.sel_text(sl.lines, sl.a, sl.b))
  sl.copy_t = pal.time_ns()
end

-- Esc clears an active selection before the shell's own Esc ladder
function M.escape(win)
  local sl = M.sel_of(win)
  if sl.a then
    sl.a, sl.b, sl.drag = nil, nil, nil
    return true
  end
  return false
end

M.kind = "console"
M.menu = "console"
M.DEF_W, M.DEF_H = 560, 320
M.PX = 12.0

local COL = {
  bg = 0x16132266, text = 0xd8d2f2ff, dim = 0x8a84b0ff,
  echo = 0x7fd8a8ff, result = 0x8cf29aff, err = 0xf07a7aff,
  input_bg = 0x26223855, banner = 0xf07a7aff,
}

function M.defaults()
  return { itext = "", filter = "", stick = true }
end

function M.title(win)
  local state = cm.require("cm.state")
  local rec = cm.trace and cm.trace.recording and cm.trace.recording()
  return ("console — frame %d%s"):format(state.frame(), rec and "  REC" or "")
end

local function line_color(s)
  local body = s:sub(10) -- skip the timestamp column
  if body:find("^> ") then return COL.echo end
  if body:find("^= ") then return COL.result end
  if body:find("^! ") or body:find("ERROR") or body:find("FAIL")
     or body:find("error") then
    return COL.err
  end
  if body:find("^%[") then return COL.dim end -- [reload] [trace] tags
  return COL.text
end

local function filtered(win, sb)
  local f = (win.filter or ""):lower()
  if f == "" then return sb end
  local out = {}
  for _, s in ipairs(sb) do
    if s:lower():find(f, 1, true) then out[#out + 1] = s end
  end
  return out
end

-- content wheel (EDITOR.md §12.7): scroll the scrollback
function M.wheel(win, ed, dy)
  local con = cm.require("cm.console")
  local lines = filtered(win, con.sb)
  local rows = ed.g.conw and ed.g.conw[win.id] and ed.g.conw[win.id].rows or 10
  if dy > 0 then
    win.stick = false
    win.sy = math.max(1, (win.sy or math.max(1, #lines - rows + 1)) - dy * 3)
  else
    win.sy = (win.sy or 1) - dy * 3
    if win.sy >= #lines - rows + 1 then
      win.stick = true
      win.sy = nil
    end
  end
  ed.touch()
end

-- the filter lives in the header (kind.header contract, right-aligned)
function M.header(win, ctx)
  local z = ctx.z
  local fw = 130 * z
  if fw < 40 or ctx.alt then return 0 end
  local px = math.max(4, 10.5 * z)
  pal.x_ig_rect(ctx.hx - fw - 2, ctx.hy + 2 * z, fw + 4, px * 1.6 + 2 * z,
                0x4a437088, 1, 3 * z)
  if (win.filter or "") == "" then
    pal.x_ig_text(ctx.hx - fw + 4, ctx.hy + 3 * z + 2, px, 0x8a84b066,
                  "filter", 1)
  end
  local text, changed = pal.x_ig_edit {
    id = "conf" .. win.id, x = ctx.hx - fw, y = ctx.hy + 3 * z,
    w = fw, h = px * 1.6, text = win.filter or "", px = px, font = 1,
  }
  if changed then
    win.filter = text
    win.stick = true
    win.sy = nil
    ctx.ed.touch()
  end
  return fw
end

function M.draw(win, ctx)
  local ed = ctx.ed
  local con = cm.require("cm.console")
  local z = ctx.z
  local px = math.max(4, M.PX * z)
  local lh = px * 1.25
  local i = cm.require("cm.ui").inp

  local input_h = px * 1.9
  local log_h = ctx.ch - input_h - 4 * z
  local rows = math.max(1, math.floor(log_h / lh))
  ed.g.conw = ed.g.conw or {}
  ed.g.conw[win.id] = ed.g.conw[win.id] or {}
  ed.g.conw[win.id].rows = rows -- wheel() reads the live row count

  local lines = filtered(win, con.sb)
  local start
  if win.stick ~= false or not win.sy then
    start = math.max(1, #lines - rows + 1)
  else
    start = math.max(1, math.min(math.floor(win.sy), #lines))
  end

  -- error banner (a contained game error pauses the sim; cm.console holds
  -- the message — shared with the legacy overlay)
  local y = ctx.cy + 2 * z
  if con.error_msg then
    pal.x_ig_text(ctx.cx + 6 * z, y, px, COL.banner, con.error_msg, 1)
    y = y + lh
    pal.x_ig_text(ctx.cx + 6 * z, y, px * 0.9, COL.dim,
                  "sim paused — edit code to resume; repl runs immediately", 1)
    y = y + lh
  end

  -- ---- log drag-selection (D118's console half): glyph-precise pick
  -- against this frame's geometry; a scrollback trim or filter change
  -- shifts indices, so the anchored line's text is the validity tag ----
  local measure = pal.x_ig_text_size
  local sl = M.sel_of(win)
  local x0 = ctx.cx + 6 * z
  local y0 = y
  if sl.a and (not lines[sl.a.li] or lines[sl.a.li] ~= sl.tag) then
    sl.a, sl.b, sl.drag = nil, nil, nil -- the list shifted under it
  end
  if measure and not ctx.occluded then
    local function pick()
      local li = start + math.floor((i.wy - y0) / lh)
      li = math.max(1, math.min(li, #lines))
      local s = lines[li] or ""
      return { li = li, ci = M.pick_ci(s, i.wx - x0, px, measure) }
    end
    if ctx.hot and i.clicked[1] and #lines > 0
       and i.wx >= ctx.cx and i.wx < ctx.cx + ctx.cw
       and i.wy >= y0 and i.wy < ctx.cy + log_h then
      local p = pick()
      sl.a, sl.b, sl.drag, sl.moved = p, p, true, nil
      sl.tag = lines[p.li]
    elseif sl.drag and i.buttons[1] then
      -- autoscroll past the band edges (unsticks the tail-follow)
      if i.wy < y0 then
        win.stick = false
        win.sy = math.max(1, (win.sy or start) - 1)
      elseif i.wy > ctx.cy + log_h and start + rows <= #lines then
        win.stick = false
        win.sy = (win.sy or start) + 1
      end
      local p = pick()
      if p.li ~= sl.a.li or p.ci ~= sl.a.ci then sl.moved = true end
      sl.b = p
    elseif sl.drag then
      sl.drag = nil -- released: a no-move gesture was a plain click
      if not sl.moved then sl.a, sl.b = nil, nil end
    end
  end
  sl.lines = lines -- copy() extracts from what this frame showed

  pal.x_ig_clip_push(ctx.cx, ctx.cy, ctx.cw, log_h)
  local hla, hlb
  if sl.a and sl.b and not (sl.a.li == sl.b.li and sl.a.ci == sl.b.ci) then
    hla, hlb = sel_norm(sl.a, sl.b)
  end
  for li = start, math.min(#lines, start + rows) do
    if y > ctx.cy + log_h then break end
    local s = lines[li]
    if hla and li >= hla.li and li <= hlb.li then
      local xa = li == hla.li and x0 + measure(s:sub(1, hla.ci), px, 1) or x0
      local xb = li == hlb.li and x0 + measure(s:sub(1, hlb.ci), px, 1)
                 or x0 + measure(s, px, 1) + px * 0.4
      if xb > xa then
        pal.x_ig_rect_fill(xa, y - 1, xb - xa, lh, 0x6a5fa066, 0)
      end
    end
    pal.x_ig_text(x0, y, px, line_color(s), s, 1)
    y = y + lh
  end
  -- "copied" feedback rides the selection head briefly
  if sl.copy_t and pal.time_ns() - sl.copy_t < COPY_DWELL and hlb then
    local ty = y0 + (hlb.li - start) * lh
    if ty >= y0 and ty < ctx.cy + log_h then
      pal.x_ig_text(ctx.cx + ctx.cw - 52 * z, ty, px * 0.9, COL.echo,
                    "copied", 1)
    end
  elseif sl.copy_t and pal.time_ns() - sl.copy_t >= COPY_DWELL then
    sl.copy_t = nil
  end
  pal.x_ig_clip_pop()

  -- scroll position hint when unstuck
  if win.stick == false then
    pal.x_ig_text(ctx.cx + ctx.cw - 60 * z, ctx.cy + 2 * z, px * 0.85,
                  COL.dim, ("%d/%d"):format(start, #lines), 1)
  end

  -- the input line
  local iy = ctx.cy + ctx.ch - input_h
  pal.x_ig_rect_fill(ctx.cx, iy, ctx.cw, input_h, COL.input_bg, 4 * z)
  local p = ed.g.conw or {}
  ed.g.conw = p
  local pw = p[win.id] or {}
  p[win.id] = pw
  if ctx.occluded then
    pal.x_ig_text(ctx.cx + 8 * z + 4, iy + input_h * 0.5 - px * 0.5 + 1, px,
                  COL.text, win.itext or "", 1)
    return
  end
  local opts = {
    id = "coni" .. win.id, x = ctx.cx + 6 * z, y = iy + (input_h - px * 1.5) * 0.5,
    w = ctx.cw - 12 * z, h = px * 1.5, text = win.itext or "",
    px = px, font = 1, multiline = false, enter = true,
  }
  if pw.refocus then
    opts.focus = true
    pw.refocus = nil
  end
  if pw.set then
    opts.set = true
    pw.set = nil
  end
  local text, changed, active, st = pal.x_ig_edit(opts)
  if changed then
    win.itext = text
    ed.touch()
  end
  if active then
    -- up/down: repl history (the raw key list is visible regardless of
    -- imgui's capture; the widget doesn't use these keys single-line)
    local repl = cm.require("cm.repl")
    for _, e in ipairs(i.keys) do
      if e.down and (e.scancode == 82 or e.scancode == 81) then
        local h = repl.history
        if #h > 0 then
          local dir = e.scancode == 82 and -1 or 1
          local hp = pw.hist_pos
          if hp == nil then
            if dir < 0 then
              pw.stash = win.itext
              hp = #h
            end
          else
            hp = hp + dir
            if hp > #h then
              hp = nil
            elseif hp < 1 then
              hp = 1
            end
          end
          pw.hist_pos = hp
          win.itext = hp and h[hp] or (pw.stash or "")
          pw.set = true
          pw.refocus = true
          ed.touch()
        end
      end
    end
  end
  if st and st.submit and (win.itext or "") ~= "" then
    cm.require("cm.repl").submit(win.itext)
    win.itext = ""
    pw.hist_pos = nil
    pw.refocus = true
    win.stick = true
    win.sy = nil
    ed.touch()
  end
end

return M
