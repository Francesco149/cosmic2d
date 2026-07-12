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
-- (scroll). Ephemeral: history cursor, refocus intent.

local M = select(2, ...) or {}

M.kind = "console"
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

  pal.x_ig_clip_push(ctx.cx, ctx.cy, ctx.cw, log_h)
  for li = start, math.min(#lines, start + rows) do
    if y > ctx.cy + log_h then break end
    pal.x_ig_text(ctx.cx + 6 * z, y, px, line_color(lines[li]), lines[li], 1)
    y = y + lh
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
