-- pt.console — the drop-down log console + Lua REPL (M2). Engine-level:
-- available in every project, toggled with ` (grave; engine-reserved along
-- with F3 until play-mode lockdown lands in M4). All dev-side state; the
-- only sim-facing thing the console does is pt.repl.submit, which is the
-- recorded EVAL path (D022).
--
-- While open: every keydown is captured (game keeps seeing key-ups so held
-- keys release cleanly), the input line owns the keyboard, mouse over the
-- console is captured, mouse below it still reaches the game — tune knobs
-- with the sim running behind the glass. The sim does NOT pause for an
-- open console; it pauses only when a game error is contained (pt.main),
-- and then the console doubles as the wreckage inspector: the REPL drains
-- immediately while paused, so state can be poked mid-autopsy.
--
-- Scrollback is pulled incrementally from the C-side pal.log ring (so VM
-- reboots and boot errors are visible) and capped locally; the filter box
-- is a plain substring match (case-insensitive).

local M = select(2, ...) or {}

local ui = pt.require("pt.ui")
local repl = pt.require("pt.repl")
local state = pt.require("pt.state")
local ease = pt.require("pt.ease")

local SB_CAP = 2000

M.open = M.open or false
M.slide = M.slide or 0.0 -- 0 closed .. 1 open (render-side animation)
M.sb = M.sb or {} -- scrollback lines (log ring entries, split on \n)
M.last_seq = M.last_seq or 0
M.input_text = M.input_text or ""
M.filter = M.filter or ""
M.error_msg = M.error_msg or nil
M.paused = M.paused or false

local KEY = { grave = 53, esc = 41, up = 82, down = 81, pageup = 75,
              pagedown = 78 }

-- ---- scrollback ----

local function push_line(s)
  M.sb[#M.sb + 1] = s
  if #M.sb > SB_CAP + 256 then -- trim in blocks, not per line
    local keep = {}
    for i = #M.sb - SB_CAP + 1, #M.sb do keep[#keep + 1] = M.sb[i] end
    M.sb = keep
    M.filter_cache = nil
  end
end

local function poll_log()
  local lines = pal.log_lines(M.last_seq)
  if #lines == 0 then return end
  if lines[1].seq > M.last_seq + 1 and M.last_seq > 0 then
    push_line("(... log ring overflowed; lines lost ...)")
  end
  for _, l in ipairs(lines) do
    M.last_seq = l.seq
    local t = ("%8.3f "):format(l.t)
    local first = true
    for part in (l.text .. "\n"):gmatch("(.-)\n") do
      push_line(first and (t .. part) or ("         " .. part))
      first = false
    end
  end
  M.filter_cache = nil
  M.appended = true
end

local function visible_lines()
  if M.filter == "" then return M.sb end
  if M.filter_cache and M.filter_cache_key == M.filter .. "#" .. #M.sb then
    return M.filter_cache
  end
  local pat = M.filter:lower()
  local out = {}
  for _, s in ipairs(M.sb) do
    if s:lower():find(pat, 1, true) then out[#out + 1] = s end
  end
  M.filter_cache, M.filter_cache_key = out, M.filter .. "#" .. #M.sb
  return out
end

local function line_color(s)
  local st = ui.style
  local body = s:sub(10) -- skip the timestamp column
  if body:find("^> ") then return st.accent end
  if body:find("^= ") then return { 0.55, 0.95, 0.6, 1.0 } end
  if body:find("^! ") or body:find("ERROR") or body:find("FAIL")
     or body:find("error") then
    return st.error
  end
  if body:find("^%[") then return st.text_dim end -- [reload] [trace] tags
  return st.text
end

-- ---- error banner (pt.main drives these on contained game errors) ----

function M.notify_error(msg)
  M.error_msg = msg
  M.paused = true
  M.open = true
  M.want_bottom = true
end

function M.clear_error()
  M.error_msg = nil
  M.paused = false
end

function M.clear()
  M.sb = {}
  M.filter_cache = nil
end

function M.toggle(on)
  if on == nil then on = not M.open end
  M.open = on
  if M.open then
    M.want_bottom = true
  else
    ui.blur()
  end
end

-- ---- history navigation ----

local hist_pos -- nil = live line (module-local: resets on reload, harmless)

local function nav_history(dir)
  local h = repl.history
  if #h == 0 then return end
  if hist_pos == nil then
    if dir > 0 then return end
    M.stash = M.input_text
    hist_pos = #h
  else
    hist_pos = hist_pos + dir
    if hist_pos > #h then
      hist_pos = nil
      M.input_text = M.stash or ""
      ui.text_cursor("in", #M.input_text + 1)
      return
    end
    if hist_pos < 1 then hist_pos = 1 end
  end
  M.input_text = h[hist_pos]
  ui.text_cursor("in", #M.input_text + 1)
end

-- ---- the per-tick frame (pt.main calls this after the game draws) ----

function M.frame()
  local W, H = pal.gfx_size()
  poll_log()

  -- toggle keys work no matter who has the keyboard
  for _, k in ipairs(ui.inp.keys) do
    if k.down and not k.rep then
      if k.scancode == KEY.grave then
        M.toggle()
      elseif k.scancode == KEY.esc and M.open and not M.error_msg then
        M.toggle(false)
      end
    end
  end

  -- slide animation (render-side; ticks are ~60 Hz when a console is up)
  local target = M.open and 1.0 or 0.0
  if M.slide < target then M.slide = math.min(target, M.slide + 1 / 12) end
  if M.slide > target then M.slide = math.max(target, M.slide - 1 / 12) end
  if M.slide <= 0 then return end

  if M.open then ui.capture_keys() end

  local ch = H * 3 // 5
  local y0 = math.floor(-ch * (1.0 - ease.cubic_out(M.slide)))
  local st = ui.style

  ui.begin_panel("console", 0, y0, W, ch)

  -- title row: status left, filter box right
  ui.row({ 3, 1 })
  local rec = pt.trace and pt.trace.recording and pt.trace.recording()
  ui.label(("console  frame %d%s%s"):format(
    state.frame(), rec and "  [REC]" or "", M.paused and "  [PAUSED]" or ""),
    { color = st.accent })
  local f, fchanged = ui.text_input("filter", M.filter, { hint = "filter" })
  if fchanged then
    M.filter = f
    M.filter_cache = nil
    M.want_bottom = true
  end

  if M.error_msg then
    ui.label(M.error_msg, { color = st.error })
    ui.label("sim paused - edit code to resume; repl runs immediately",
             { color = st.text_dim })
  end

  -- log region fills everything above the input row
  local pad = st.pad
  local log_h = ch - (ui.cursor_y() - y0) - st.row_h - pad * 2
  local lines = visible_lines()
  ui.begin_scroll("log", log_h, { bg = st.track })
  if M.want_bottom then
    ui.scroll_to_bottom("log")
    M.want_bottom = nil
  elseif M.appended and ui.scroll_at_bottom("log", log_h) then
    ui.scroll_to_bottom("log")
  end
  ui.list(#lines, ui.style.gh + 1, function(i, x, y, w, rh)
    ui.text(x + 1, y, lines[i], line_color(lines[i]))
  end)
  ui.end_scroll()
  M.appended = false

  -- input line ("> " prompt drawn by hint when empty)
  local txt, _, submitted = ui.text_input("in", M.input_text, {
    hint = "lua (enter runs at next sim frame; up/down history)",
    keep_focus = true,
    take_focus = M.open,
    on_key = function(sc)
      if sc == KEY.up then nav_history(-1)
      elseif sc == KEY.down then nav_history(1)
      elseif sc == KEY.pageup then
        ui.scroll_set("log", ui.scroll_get("log") - (log_h - st.row_h))
      elseif sc == KEY.pagedown then
        ui.scroll_set("log", ui.scroll_get("log") + (log_h - st.row_h))
      end
    end,
  })
  -- the grave that closes the console must not linger as a typed char
  M.input_text = txt:gsub("`", "")
  if submitted and #M.input_text > 0 then
    repl.submit(M.input_text)
    M.input_text = ""
    hist_pos = nil
    M.want_bottom = true
  end

  ui.end_panel()
end

return M
