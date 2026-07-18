-- cm.scrub — the time machine (M5, D032): scrub the always-on ring trace,
-- step or play through the past, rewind & resume from any frame, export
-- the ring ("save what just happened").
--
-- Dev chrome (D021): all state lives on this module, never in sim state;
-- the panel is immediate-mode cm.ui. F4 toggles (locked down with the
-- editor via project `editor = false`). While open the sim is FROZEN
-- (cm.main gates stepping on M.paused()) and the ring is dormant, so the
-- timeline is stable; moving the playhead writes the decoded ring state
-- straight into the live buffers/doc (state.restore_tables — no game code
-- runs, the game's draw simply renders the past, and the inspector reads
-- it). Closing restores the newest frame and play continues as if nothing
-- happened. "rewind here" makes the playhead the new present: trace.rewind
-- truncates the future and cm.main.after_restore re-runs init (the restore
-- contract) and clears an error pause — the marquee flow is crash, F4,
-- scrub back, watch it coming, rewind, try something else.
--
-- Replay mode: open_replay(path) loads a shared .ctrace INTO the ring
-- (trace.ring_load — state+code restore to its SNAP) and auto-plays it,
-- state-per-frame, no re-sim. The same panel scrubs it; "play from here"
-- /"finish" adopt the trace's timeline at the playhead/end and hand the
-- controls back to live play (which records onward from there).

local M = select(2, ...) or {}
local ui = cm.require("cm.ui")
local view = cm.require("cm.view")
local trace = cm.require("cm.trace")
local state = cm.require("cm.state")
local input = cm.require("cm.input")

local KEY_F4 = 61
local KEY_RIGHT, KEY_LEFT = 79, 80

M.SPEEDS = { 1, 2, 4, 8 }
M.FRAME_NS = 1e9 / 60

local function clock_ns()
  return M._clock_ns and M._clock_ns() or pal.time_ns()
end

local function reset_play_clock(now)
  M.play_clock = now or clock_ns()
  M.play_acc = 0
end

local function clear_play_clock()
  M.play_clock, M.play_acc = nil, nil
end

function M.set_speed(speed)
  for _, allowed in ipairs(M.SPEEDS) do
    if speed == allowed then
      M.speed = allowed
      reset_play_clock()
      return allowed
    end
  end
  return nil, "rewind speed must be 1x, 2x, 4x, or 8x"
end

function M.cycle_speed()
  local at = 1
  for i, speed in ipairs(M.SPEEDS) do
    if speed == (M.speed or 1) then at = i; break end
  end
  return M.set_speed(M.SPEEDS[at % #M.SPEEDS + 1])
end

function M.paused()
  return M.on == true
end

function M.has_loop()
  return M.loop_a ~= nil
end

-- A7 §13: a foreign clip opened non-destructively in an editor session (drag-in)
-- — the live ring/present are stashed, not adopted, so dismissal restores them.
function M.is_clip()
  return M.editor_clip == true
end

function M.loop_range()
  return M.loop_a, M.loop_b
end

-- write frame f's state into the live buffers/doc (idempotent per frame).
-- R6c: the editor parks alongside — the frame's EDOC becomes the shown
-- (fully interactive, fully ephemeral) editor doc; the present is
-- stashed by cm.ed until close/rewind decides its fate (REWIND.md §4)
local function apply(f)
  if f == M.shown then return end
  local st = trace.ring_state_at(f)
  state.restore_tables(st.bufs, st.doct)
  local ed = cm.require("cm.ed")
  if ed.on then ed.park(st.edoc) end
  M.shown = f
  M.irec = st.input
end

function M.open()
  if M.on or cm.main.dev_locked() then return end
  local lo, hi = trace.ring_range()
  if not lo then return end
  M.on = true
  M.lo, M.hi = lo, hi
  M.at, M.shown = hi, hi -- the present is already in the buffers
  M.play, M.speed = false, 1
  M.play_hold, M.loop_a, M.loop_b = nil, nil, nil
  clear_play_clock()
  M.irec = trace.ring_state_at(hi).input
end

-- Public transport primitives used by both the legacy panel and A7's editor
-- tray. A/B is ordered and inclusive. set_loop parks at A for one complete
-- display tick before walking A..B and wrapping; seeking stops playback but
-- deliberately keeps clip mode until Esc clears it.
function M.seek(f)
  if not M.on then return end
  M.play, M.play_hold = false, nil
  clear_play_clock()
  M.at = math.min(math.max(math.floor(f + 0.5), M.lo), M.hi)
end

function M.set_loop(a, b)
  if not M.on then return end
  a = math.min(math.max(math.floor(a + 0.5), M.lo), M.hi)
  b = math.min(math.max(math.floor(b + 0.5), M.lo), M.hi)
  if b < a then a, b = b, a end
  M.loop_a, M.loop_b = a, b
  M.at, M.play, M.play_hold = a, true, true
  reset_play_clock()
end

function M.clear_loop()
  M.loop_a, M.loop_b, M.play_hold = nil, nil, nil
  M.play = false
  clear_play_clock()
end

function M.toggle_play()
  if not M.on then return end
  if M.play then
    M.play, M.play_hold = false, nil
    clear_play_clock()
    return
  end
  if M.loop_a and (M.at < M.loop_a or M.at >= M.loop_b) then
    M.at, M.play_hold = M.loop_a, true
  elseif not M.loop_a and M.at >= M.hi then
    M.at, M.play_hold = M.lo, true
  end
  M.play = true
  reset_play_clock()
end

-- back to the present, timeline intact (recording resumes seamlessly);
-- in replay mode there is no other present — adopt the trace's end
function M.close()
  if not M.on then return end
  if M.editor_clip then return M.close_clip() end
  if M.replay then
    M.at = M.hi
    return M.rewind_here()
  end
  apply(M.hi)
  cm.require("cm.ed").unpark(false) -- the stashed present comes back
  M.on, M.play = false, false
  M.loop_a, M.loop_b, M.play_hold = nil, nil, nil
  clear_play_clock()
end

-- Dismiss an editor drag-in clip (A7 §13): restore the untouched live ring,
-- present state, editor doc, and real project root — deliberately NOT adopting
-- the replay's future. The order matters: unmount the clip's root, restore the
-- live present buffers/doc/code from the snapshot taken at open (no init — the
-- live game resumes stepping from exactly where it was), swap the live ring
-- back (dropping the ephemeral replay workspace), then unpark the stashed
-- editor doc.
function M.close_clip()
  if not M.on then return end
  local ed = cm.require("cm.ed")
  ed.unmount_replay()
  if M.live_snap then
    state.restore(M.live_snap)
    M.live_snap = nil
  end
  trace.restore_live()
  ed.unpark(false)
  M.on, M.play, M.replay, M.editor_clip = false, false, false, nil
  M.loop_a, M.loop_b, M.play_hold, M.shown = nil, nil, nil, nil
  clear_play_clock()
end

-- the playhead becomes the new present; the future is discarded (for a
-- replay: adopt its timeline here and keep playing live)
function M.rewind_here()
  if not M.on then return end
  trace.rewind(M.at)
  -- resume-from-frame adopts the SHOWN editor doc, pokes included
  -- (REWIND.md §4 — it's what you're looking at)
  cm.require("cm.ed").unpark(true)
  M.shown = M.at
  M.on, M.play, M.replay = false, false, false
  M.loop_a, M.loop_b, M.play_hold = nil, nil, nil
  clear_play_clock()
  if cm.main and cm.main.after_restore then cm.main.after_restore() end
end

-- replay playback of a .ctrace (M5): queue the load; it happens in the
-- chrome phase (never mid-sim-frame, so the console eval that triggered
-- it can't poison the timeline it replaces — in a verify re-sim this is
-- a recorded no-op, the replay's effects live in the deltas)
function M.open_replay(path)
  M.pending = path
end

-- A7 §13 drag-in: open a .ctrace as a NON-destructive editor clip. Same chrome-
-- phase queue as open_replay, but do_load stashes the live ring/present and
-- mounts the clip's project tree instead of adopting the trace's timeline.
function M.open_clip(path)
  M.pending_clip = path
end

local function do_load(path, editor_clip)
  if cm.main.dev_locked() then return end
  if editor_clip then
    -- §13: keep the live ring + present intact so dismissal restores them
    -- exactly (no adopt). Snapshot the live present state, then stash the live
    -- ring so the clip's destructive ring_load lands in a fresh one.
    M.live_snap = state.snapshot()
    local sok, swhy = trace.stash_live()
    if not sok then
      pal.log("[scrub] clip open refused: " .. tostring(swhy))
      M.live_snap = nil
      return
    end
  end
  local ok, lo = pcall(trace.ring_load, path)
  if not ok then
    pal.log("[scrub] replay load failed: " .. tostring(lo))
    if editor_clip then
      -- ring_load may have already replaced buffers/doc/code before it
      -- failed; heal with the SAME restore order the close path uses —
      -- present state first, then the live ring — so the session resumes
      -- exactly where it was (D118: the failure must not tear the live
      -- session down with it)
      if M.live_snap then
        state.restore(M.live_snap)
        if cm.main and cm.main.after_restore then cm.main.after_restore() end
        M.live_snap = nil
      end
      trace.restore_live()
    end
    return
  end
  if cm.main and cm.main.after_restore then cm.main.after_restore() end
  local rlo, rhi = trace.ring_range()
  M.on, M.replay = true, true
  M.editor_clip = editor_clip and true or nil
  M.lo, M.hi = rlo, rhi
  M.at, M.shown = rlo, rlo
  M.play, M.speed = rhi > rlo, 1 -- it's a showcase: roll it in real time
  M.play_hold, M.loop_a, M.loop_b = true, nil, nil
  -- §13 mount: point the editor root at the clip's materialized project tree so
  -- the asset windows browse its bundle, ephemerally (the parked write wall).
  if editor_clip then
    local ws = trace.replay_workspace and trace.replay_workspace()
    if ws then cm.require("cm.ed").mount_replay(ws) end
  end
  -- A standalone clip (A7 §14) records its A/B bounds; open on the same range
  -- and start the same loop (§14: loading reopens on the range without change).
  local loop = trace.replay_loop and trace.replay_loop()
  if loop then
    local la = math.min(math.max(loop.a, rlo), rhi)
    local lb = math.min(math.max(loop.b, rlo), rhi)
    if lb < la then la, lb = lb, la end
    M.loop_a, M.loop_b = la, lb
    M.at, M.shown = la, la
    M.play = lb > la
  end
  -- A mounted clip must park the editor immediately (the ephemeral write wall +
  -- the clip's own editor doc), so force the first apply to actually run even
  -- though at == the initial shown frame.
  if editor_clip then M.shown = nil end
  reset_play_clock()
  M.irec = nil
end

function M.export()
  local proj = (cm.main and cm.main.args and cm.main.args.project) or "."
  return trace.ring_export(("%s/ring-f%d.ctrace"):format(proj, M.hi))
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

-- ---- the per-tick frame (cm.main: after editor, before perf/console) ----

local function advance_playback(steps)
  if steps <= 0 then return end
  if M.loop_a then
    local n = M.loop_b - M.loop_a + 1
    M.at = M.loop_a + ((M.at - M.loop_a + steps) % n)
  else
    M.at = M.at + steps
    if M.at >= M.hi then
      M.at, M.play = M.hi, false
      clear_play_clock()
    end
  end
end

local function clock_playback()
  local now = clock_ns()
  if M.play_hold then
    -- A newly selected A/B range and an opened replay both show their first
    -- frame for one complete draw before the real-time clock starts.
    M.play_hold = nil
    reset_play_clock(now)
    return
  end
  if not M.play_clock then reset_play_clock(now); return end
  local elapsed = math.max(0, now - M.play_clock)
  M.play_clock = now
  local due = (M.play_acc or 0)
              + elapsed / M.FRAME_NS * (M.speed or 1)
  local steps = math.floor(due)
  M.play_acc = due - steps
  -- One restore per presented frame. If rendering fell behind, intermediate
  -- recorded frames are deliberately dropped so 1x remains real time.
  advance_playback(steps)
end

function M.frame()
  if M.pending then
    local path = M.pending
    M.pending = nil
    do_load(path)
  end
  if M.pending_clip then
    local path = M.pending_clip
    M.pending_clip = nil
    do_load(path, true)
  end
  local ed = cm.require("cm.ed")
  if not ed.on then
    for _, k in ipairs(ui.inp.keys) do
      if k.down and not k.rep and k.scancode == KEY_F4 then
        if M.on then M.close() else M.open() end
      elseif M.on and k.down and k.scancode == KEY_LEFT then
        M.seek(M.at - 1)
      elseif M.on and k.down and k.scancode == KEY_RIGHT then
        M.seek(M.at + 1)
      end
    end
  end
  if not M.on then return end

  if M.play then clock_playback() end
  apply(M.at)

  -- Editor sessions render the persistent A7 tray on the native imgui
  -- overlay. Keep the legacy game-space panel for play-mode sessions only.
  if ed.on then return end

  local W, H = view.surface_size() -- ui canvas when the editor owns it (D036)
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
  if v ~= M.at then M.seek(v) end

  ui.row({ 1, 1.2, 1, 1.2, 0.9, 1.2, 1, 1.2, 2.2, 1.6, 1.4 })
  if ui.button("|<") then M.seek(M.lo) end
  if ui.button("-60") then M.seek(M.at - 60) end
  if ui.button("<") then M.seek(M.at - 1) end
  if ui.button(M.play and "stop" or "play") then
    M.toggle_play()
  end
  if ui.button((M.speed or 1) .. "x", { id = "speed" }) then
    M.cycle_speed()
  end
  if ui.button(">") then M.seek(M.at + 1) end
  if ui.button("+60") then M.seek(M.at + 60) end
  if ui.button(">|") then M.seek(M.hi) end
  if ui.button(M.replay and "play from here" or "rewind here",
               { id = "rewind" }) then
    M.rewind_here()
    ui.end_panel()
    return
  end
  if ui.button("save .ctrace") then M.export() end
  if ui.button(M.replay and "finish" or "close", { id = "close" }) then
    M.close()
    ui.end_panel()
    return
  end

  ui.end_panel()
end

return M
