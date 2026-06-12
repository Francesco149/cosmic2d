-- pt.scrub — the time machine (M5, D032): scrub the always-on ring trace,
-- step or play through the past, rewind & resume from any frame, export
-- the ring ("save what just happened").
--
-- Dev chrome (D021): all state lives on this module, never in sim state;
-- the panel is immediate-mode pt.ui. F4 toggles (locked down with the
-- editor via project `editor = false`). While open the sim is FROZEN
-- (pt.main gates stepping on M.paused()) and the ring is dormant, so the
-- timeline is stable; moving the playhead writes the decoded ring state
-- straight into the live buffers/doc (state.restore_tables — no game code
-- runs, the game's draw simply renders the past, and the inspector reads
-- it). Closing restores the newest frame and play continues as if nothing
-- happened. "rewind here" makes the playhead the new present: trace.rewind
-- truncates the future and pt.main.after_restore re-runs init (the restore
-- contract) and clears an error pause — the marquee flow is crash, F4,
-- scrub back, watch it coming, rewind, try something else.
--
-- Replay mode: open_replay(path) loads a shared .ptrace INTO the ring
-- (trace.ring_load — state+code restore to its SNAP) and auto-plays it,
-- state-per-frame, no re-sim. The same panel scrubs it; "play from here"
-- /"finish" adopt the trace's timeline at the playhead/end and hand the
-- controls back to live play (which records onward from there).

local M = select(2, ...) or {}
local ui = pt.require("pt.ui")
local trace = pt.require("pt.trace")
local state = pt.require("pt.state")
local input = pt.require("pt.input")

local KEY_F4 = 61
local KEY_RIGHT, KEY_LEFT = 79, 80

function M.paused()
  return M.on == true
end

-- write frame f's state into the live buffers/doc (idempotent per frame)
local function apply(f)
  if f == M.shown then return end
  local st = trace.ring_state_at(f)
  state.restore_tables(st.bufs, st.doct)
  M.shown = f
  M.irec = st.input
end

function M.open()
  if M.on or pt.require("pt.editor").locked() then return end
  local lo, hi = trace.ring_range()
  if not lo then return end
  M.on = true
  M.lo, M.hi = lo, hi
  M.at, M.shown = hi, hi -- the present is already in the buffers
  M.play = false
  M.irec = trace.ring_state_at(hi).input
end

-- back to the present, timeline intact (recording resumes seamlessly);
-- in replay mode there is no other present — adopt the trace's end
function M.close()
  if not M.on then return end
  if M.replay then
    M.at = M.hi
    return M.rewind_here()
  end
  apply(M.hi)
  M.on, M.play = false, false
end

-- the playhead becomes the new present; the future is discarded (for a
-- replay: adopt its timeline here and keep playing live)
function M.rewind_here()
  if not M.on then return end
  trace.rewind(M.at)
  M.shown = M.at
  M.on, M.play, M.replay = false, false, false
  if pt.main and pt.main.after_restore then pt.main.after_restore() end
end

-- replay playback of a .ptrace (M5): queue the load; it happens in the
-- chrome phase (never mid-sim-frame, so the console eval that triggered
-- it can't poison the timeline it replaces — in a verify re-sim this is
-- a recorded no-op, the replay's effects live in the deltas)
function M.open_replay(path)
  M.pending = path
end

local function do_load(path)
  if pt.require("pt.editor").locked() then return end
  local ok, lo = pcall(trace.ring_load, path)
  if not ok then
    pal.log("[scrub] replay load failed: " .. tostring(lo))
    return
  end
  if pt.main and pt.main.after_restore then pt.main.after_restore() end
  local rlo, rhi = trace.ring_range()
  M.on, M.replay = true, true
  M.lo, M.hi = rlo, rhi
  M.at, M.shown = rlo, rlo
  M.play = rhi > rlo -- it's a showcase: roll it
  M.irec = nil
end

function M.export()
  local proj = (pt.main and pt.main.args and pt.main.args.project) or "."
  return trace.ring_export(("%s/ring-f%d.ptrace"):format(proj, M.hi))
end

local function held_actions(irec)
  if not irec or #irec < 4 then return "-" end
  local bits = string.unpack("<I4", irec)
  if bits == 0 then return "-" end
  local out = {}
  for i, name in ipairs(input.actions()) do
    if bits & (1 << (i - 1)) ~= 0 then out[#out + 1] = name end
  end
  return table.concat(out, " ")
end

local function seek(f)
  M.play = false
  M.at = math.min(math.max(f, M.lo), M.hi)
end

-- ---- the per-tick frame (pt.main: after editor, before perf/console) ----

function M.frame()
  if M.pending then
    local path = M.pending
    M.pending = nil
    do_load(path)
  end
  for _, k in ipairs(ui.inp.keys) do
    if k.down and not k.rep and k.scancode == KEY_F4 then
      if M.on then M.close() else M.open() end
    elseif M.on and k.down and k.scancode == KEY_LEFT then
      seek(M.at - 1)
    elseif M.on and k.down and k.scancode == KEY_RIGHT then
      seek(M.at + 1)
    end
  end
  if not M.on then return end

  if M.play then
    M.at = M.at + 1
    if M.at >= M.hi then M.at, M.play = M.hi, false end
  end
  apply(M.at)

  local W, H = pal.gfx_size()
  local st = ui.style
  local ph = st.pad * 2 + st.row_h * 3 + st.gap * 2
  ui.begin_panel("scrub", 2, H - ph - 2, W - 4, ph)

  ui.row({ 1.1, 2, 1.6 })
  ui.label(M.replay and "REPLAY" or "TIME MACHINE (F4)", { color = st.accent })
  ui.label(("frame %d / %d   t%+.2fs")
           :format(M.at, M.hi, (M.at - M.hi) / 60))
  ui.label("in: " .. held_actions(M.irec))

  local v = ui.slider("", M.at, M.lo, M.hi,
                      { id = "timeline", label_w = 0, fmt = "%d" })
  if v ~= M.at then seek(v) end

  ui.row({ 1, 1.2, 1, 1.2, 1.2, 1, 1.2, 2.2, 1.6, 1.4 })
  if ui.button("|<") then seek(M.lo) end
  if ui.button("-60") then seek(M.at - 60) end
  if ui.button("<") then seek(M.at - 1) end
  if ui.button(M.play and "stop" or "play") then
    if M.play then
      M.play = false
    else
      if M.at >= M.hi then M.at = M.lo end
      M.play = M.at < M.hi
    end
  end
  if ui.button(">") then seek(M.at + 1) end
  if ui.button("+60") then seek(M.at + 60) end
  if ui.button(">|") then seek(M.hi) end
  if ui.button(M.replay and "play from here" or "rewind here",
               { id = "rewind" }) then
    M.rewind_here()
    ui.end_panel()
    return
  end
  if ui.button("save .ptrace") then M.export() end
  if ui.button(M.replay and "finish" or "close", { id = "close" }) then
    M.close()
    ui.end_panel()
    return
  end

  ui.end_panel()
end

return M
