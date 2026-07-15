-- cm.main — engine entry: flags, project lifecycle, the tick loop.
-- Keeps its state on M (survives its own hot reload via the prev-table
-- convention; see boot.lua header).
--
-- Flags: [project_dir] --headless --frames N --shot PATH --no-vsync
--        --record PATH --verify PATH --eval CODE --edit
--   --edit            boot the editor shell (R3, cm.ed/EDITOR.md): the
--                     infinite canvas, maximized window. The sim runs with
--                     all input swallowed; live + --win capture only (a
--                     no-op under --verify / plain headless per the D049
--                     ig absence contract).
--   --headless        no window; tick = exactly one sim step (lockstep).
--                     Without --frames it paces to ~60Hz with hot reload +
--                     parachute: a full live session minus the window (D013)
--   --frames N        quit after N ticks; free-runs, reload polling off,
--                     errors exit(1) (deterministic captures / CI)
--   --shot PATH       write a PNG of the internal target before quitting
--   --record PATH     record a trace (D014) until quit / frame cap
--   --verify PATH     golden runner: replay the trace's inputs against its
--                     starting snapshot (bundle code) and byte-compare every
--                     frame; exit 0 on byte-exact, 1 + first divergence not
--   --eval CODE       queue a console command for the first sim frame
--                     (repeatable, runs in order). Same path as typing it
--                     into the console: drains at frame start, recorded as
--                     an EVAL record (D022) — so headless recordings can
--                     flip doc switches (e.g. game.demo(1)) replayably
--
-- Error containment (D023): in live sessions (everything except --frames /
-- --verify), game errors never kill the session. A failing require / init /
-- step / draw pauses the sim, logs the traceback, and opens the console;
-- the REPL drains immediately while paused (poke at the wreckage). Any
-- successful reload — or, for boot failures, the entry finally loading —
-- clears the error, re-runs init (reload-idempotent by contract) and
-- resumes. The C parachute stays underneath for engine bugs. A recording
-- is stopped at the error so the trace stays valid up to the last good
-- frame.

local M = select(2, ...) or {}

local SIM_DT = math.tointeger(1e9 // 60)

local function parse_args()
  local a = {} -- no default project: bare `cosmic` boots the picker (D052)
  local argv = pal.argv
  local i = 1
  while i <= #argv do
    local arg = argv[i]
    if arg == "--headless" then a.headless = true
    elseif arg == "--no-vsync" then a.no_vsync = true
    elseif arg == "--frames" then
      i = i + 1
      a.frames = math.tointeger(argv[i]) or error("--frames needs a number")
    elseif arg == "--shot" then
      i = i + 1
      a.shot = argv[i] or error("--shot needs a path")
    elseif arg == "--win" then -- headless capture: composite at WxH (dev/debug)
      i = i + 1
      local s = argv[i] or error("--win needs WxH")
      a.win_w, a.win_h = s:match("^(%d+)x(%d+)$")
      a.win_w = math.tointeger(a.win_w) or error("--win wants WxH, got " .. s)
      a.win_h = math.tointeger(a.win_h)
    elseif arg == "--record" then
      i = i + 1
      a.record = argv[i] or error("--record needs a path")
    elseif arg == "--verify" then
      i = i + 1
      a.verify = argv[i] or error("--verify needs a path")
    elseif arg == "--eval" then
      i = i + 1
      a.evals = a.evals or {}
      a.evals[#a.evals + 1] = argv[i] or error("--eval needs code")
    elseif arg == "--edit" then a.edit = true
    elseif arg:sub(1, 2) ~= "--" then a.project = arg
    else error("unknown flag: " .. arg) end
    i = i + 1
  end
  return a
end

local function load_project(dir)
  local path = dir .. "/project.lua"
  local src, err = pal.read_file(path)
  if not src then error("can't read " .. path .. ": " .. tostring(err), 0) end
  cm.register_special("@project", path, src)
  local chunk, lerr = load(src, "@" .. path)
  if not chunk then error(lerr, 0) end
  local proj = chunk()
  if type(proj) ~= "table" then error(path .. " did not return a table", 0) end
  return proj
end

-- ---- error containment (D023) ----

local function enter_error(traceback)
  pal.log("=== game error ===\n" .. tostring(traceback))
  M.game_err = tostring(traceback):match("[^\n]*") or "error"
  if M.trace and M.trace.recording() then
    M.trace.record_stop() -- trace stays valid up to the last good frame
    pal.log("[trace] recording stopped by the error")
  end
  M.console.notify_error(M.game_err)
end

-- run a game callback; in contained sessions an error pauses the sim
-- instead of propagating. Returns true when fn completed.
local function guarded(fn, ...)
  if not M.contain then
    fn(...)
    return true
  end
  local ok, err = xpcall(fn, debug.traceback, ...)
  if not ok then enter_error(err) end
  return ok
end

-- restart the game IN PLACE (the game window's restart button, D056):
-- free every game named buffer (the ed.* editor domain and cm.sim stay),
-- clear the doc, re-seed rand like boot, re-run game.init — boot state
-- at the CURRENT frame. The frame counter is deliberately kept: it IS
-- the rewind timeline (D055); a restart is just a big recorded delta,
-- so the past stream survives and the restart itself rewinds. This
-- mutates sim state — callers must route it through the recorded EVAL
-- path (cm.repl.submit) so recordings replay it.
function M.reset_game()
  for _, b in ipairs(pal.buf_list()) do
    if b.name ~= "cm.sim" and not b.name:find("^ed%.") then
      pal.buf_free(b.name)
    end
  end
  local doc = M.state.doc
  for k in pairs(doc) do doc[k] = nil end
  local sim = pal.buf("cm.sim", 64)
  local f = sim:i64(0)
  for off = 8, 56, 8 do sim:i64(off, 0) end -- rand + reserved reset
  cm.require("cm.rand").ensure_seeded(M.proj.seed or 0x70657474616e3264)
  -- snd.bank was just freed above; drop the sequencer's derived cache so the
  -- restarted game re-uploads its song's track patches into the fresh bank
  -- (else the music plays silent voices — the restart-goes-quiet bug).
  cm.require("cm.snd").seq.reset()
  if M.game then guarded(M.game.init) end
  pal.log(("[main] game restarted (frame %d)"):format(f))
end

-- a quit request from any in-app source (the window close button, the
-- options-menu "quit" button). A game may intercept it to run a save/confirm
-- hook (on_quit); otherwise we quit. Single path so every quit affordance
-- behaves the same — notably the only in-app exit in borderless fullscreen,
-- which has no window chrome (Esc opens the options menu, not quits).
-- the D052 launcher lockdown: proj.editor == false disables every dev
-- surface (console/perf/scrub/the editor shell). Lived on cm.editor
-- until the F1 editor died at R8e.
function M.dev_locked()
  return (M.proj ~= nil and M.proj.editor == false) and true or false
end

function M.request_quit()
  if M.game and M.game.on_quit and not M.game_err then
    guarded(M.game.on_quit)
  else
    pal.quit()
  end
end

-- resolve the project when the command line names none (D052):
--  1. the picker's `boot.next` carrier buffer (survives the x_reboot
--     cycle by the named-buffer contract) — a true project SWITCH, so
--     every named buffer is swept first (the old project's sim state
--     must not leak into the new session's snapshots/traces);
--  2. launcher exe-name magic: a renamed cosmic.exe boots the project
--     named like itself, LOCKED (editor/console dead, --edit ignored);
--  3. the picker cartridge — the engine's front door.
local function resolve_project(args)
  if args.project then return end
  for _, b in ipairs(pal.buf_list()) do
    if b.name == "boot.next" then
      local payload = pal.buf("boot.next", b.size):str(0, b.size)
      local path, mode = payload:match("^([^\n]+)\n?(.*)$")
      for _, ob in ipairs(pal.buf_list()) do pal.buf_free(ob.name) end
      args.project = path
      if mode == "edit" then args.edit = true end
      pal.log("[boot] picker switch -> " .. path
              .. (args.edit and " (editor)" or ""))
      return
    end
  end
  local exe = (pal.exe or ""):gsub("\\", "/"):match("([^/]+)$") or "cosmic"
  exe = exe:gsub("%.exe$", ""):lower()
  if exe ~= "cosmic" and exe ~= "" then
    for _, dir in ipairs({ exe, "projects/" .. exe }) do
      if pal.read_file(dir .. "/project.lua") then
        args.project = dir
        args.locked = true -- the shipped-game shape (D052)
        args.edit = nil
        pal.log("[boot] launcher: " .. exe .. " -> " .. dir .. " (locked)")
        return
      end
    end
    pal.log("[boot] launcher: no project for exe '" .. exe .. "'; picker")
  end
  args.project = "projects/picker"
  args.picker = true
  args.edit = nil -- the picker IS a front door; --edit applies to what it opens
end

-- remember successfully booted projects (most recent first, deduped,
-- cap 12) in the engine-root .recent.dat — the picker's memory; how
-- sibling-repo projects (../cosmic2d-game/cosmic) get tiles
local function note_recent(path)
  local lines = {}
  local seen = { [path] = true }
  lines[1] = path
  local old = pal.read_file(".recent.dat")
  if old then
    for line in old:gmatch("[^\n]+") do
      if not seen[line] and #lines < 12 then
        seen[line] = true
        lines[#lines + 1] = line
      end
    end
  end
  pal.write_file(".recent.dat", table.concat(lines, "\n"))
end

function M.boot()
  local args = parse_args()
  resolve_project(args)
  M.args = args
  M.contain = not (args.frames or args.verify)
  if args.frames or args.verify then pal.exit_on_error(true) end
  if args.verify then args.headless = true end -- verify never pops a window
  if args.win_w then args.headless = true end -- composite capture is headless

  local proj = load_project(args.project)
  if args.locked then proj.editor = false end -- launcher lockdown (D052)
  M.proj = proj
  cm.set_project_root(args.project)
  -- the picker's memory: live real-project boots only (never headless
  -- runs, never the picker itself — and never a locked shipped game)
  if not args.headless and not args.picker and not args.locked then
    note_recent(args.project)
  end

  pal.gfx_init {
    w = proj.internal_w or 480, h = proj.internal_h or 270,
    scale = proj.window_scale or 2,
    title = proj.name or "cosmic2d",
    headless = args.headless,
    vsync = not args.no_vsync,
    -- editor-session shape (D049): the window opens maximized. Policy lives
    -- here (project.lua opts in; --edit forces it); the PAL just honors the
    -- flag when windowed.
    maximized = proj.maximized or args.edit or false,
  }
  -- headless composite capture (--win WxH): present into an offscreen target at
  -- that window size so a --shot shows the editor-around-game layout (dev/debug)
  if args.win_w then pal.x_capture(args.win_w, args.win_h) end

  -- the audio device (R9b, AUDIO.md §2): live windowed sessions only —
  -- headless/verify/capture runs never open one (goldens can't hear by
  -- construction; the PAL refuses under G.headless anyway)
  if not args.headless then pal.x_snd_start() end
  -- clear any editor monitor mute carried over the reboot (PAL device state
  -- outlives the VM); the game window re-applies it per frame in the editor,
  -- so a shipped/play boot always starts audible.
  if pal.x_snd_mute then pal.x_snd_mute(false, false) end

  M.state = cm.require("cm.state")
  M.input = cm.require("cm.input")
  M.ui = cm.require("cm.ui")
  M.repl = cm.require("cm.repl")
  M.console = cm.require("cm.console")
  M.perf = cm.require("cm.perf")
  M.scrub = cm.require("cm.scrub")
  M.view = cm.require("cm.view")
  M.options = cm.require("cm.options")
  M.ed = cm.require("cm.ed") -- the editor shell (R3/R4, D050/D051; the F2
  -- studio died here at R4 — sprite ed is a canvas window, D046 Q4)
  -- the ladder's reference = the project's design res (D054/R7): the cap
  -- is load-bearing (render must never exceed what the sim planned), and
  -- that plan is per-project now, not the classic 480x270
  M.view.cfg.ref_w = proj.internal_w or 480
  M.view.cfg.ref_h = proj.internal_h or 270
  M.view.cfg.base_scale = proj.window_scale or 2
  -- the resize ladder runs only live: headless/verify keep the fixed project
  -- FOV so goldens + determinism never see a window-derived size (D036). The
  -- --win capture is the one headless exception (it wants the live layout).
  M.view.set_enabled(not args.headless or args.win_w ~= nil)
  -- adopt the persisted video options (M8.6) before the first frame. Interactive
  -- windowed sessions only: headless / capped captures (--frames) / --verify keep
  -- the project's fixed FOV, so goldens + captures stay byte-stable (render-only,
  -- D036). cm.view writes video.dat back on any options-menu change.
  if not args.headless and not args.frames then M.view.load_video() end
  cm.require("cm.rand").ensure_seeded(proj.seed or 0x70657474616e3264)

  -- R6.5 (D055): a live session CONTINUES the project's past stream —
  -- seed the sim frame counter one past the retained on-disk history so
  -- the timeline never resets across restarts (ring_start then adopts
  -- the chain, contiguous by construction). Live windowed sessions only,
  -- matching the spill gate below: headless/verify/captures start at 0
  -- and never touch history, so goldens stay byte-identical.
  if not args.headless then
    local last = cm.require("cm.trace").hist_peek(args.project)
    if last then
      pal.buf("cm.sim", 64):i64(0, last)
      pal.log(("[trace] continuing the past stream at frame %d"):format(last + 1))
    end
  end

  -- the console is the engine's output surface: print joins the log stream
  print = function(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring(select(i, ...)) end
    pal.log(table.concat(parts, "  "))
  end

  M.entry = (proj.entry or "main.lua"):gsub("%.lua$", ""):gsub("/", ".")
  if M.contain then
    local ok, game = xpcall(cm.require, debug.traceback, M.entry)
    if ok then
      M.game = game
      guarded(M.game.init)
    else
      M.game = nil
      enter_error(game)
    end
  else
    M.game = cm.require(M.entry)
    M.game.init()
  end

  M.acc, M.last, M.ticks = 0, nil, 0
  M.reload_at = 0
  local w, h = pal.gfx_size()
  pal.log(("booted %s (%dx%d) on pal %d/api%d %s"):format(
    args.project, w, h, pal.version.major, pal.version.api, pal.platform))

  if args.verify then
    M.trace = cm.require("cm.trace")
    local ok = M.trace.verify(args.verify, M.game)
    pal.quit(ok and 0 or 1)
    return
  end
  -- the ring trace is always on in live sessions (D032); --record pins it.
  -- Real windowed sessions stream history to disk (R6b/REWIND.md §3);
  -- headless/CI never write a byte.
  M.trace = cm.require("cm.trace")
  M.trace.ring.spill = not args.headless
  M.trace.ring_start({ project = args.project })
  -- the editor resumes where the stream left off (D056): when the
  -- adopted history reaches the present, restore its last frame so the
  -- sim continues exactly where the previous session quit (the code
  -- stays current — adopted segments carry no bundle, D055). Editor
  -- sessions only; play/headless boots stay fresh.
  if args.edit and not args.headless then
    local _, hi = M.trace.ring_range()
    if hi and hi > 0 and hi == M.state.frame() then
      local ok, err = pcall(M.trace.rewind, hi)
      if ok then
        guarded(M.game.init)
        pal.log(("[main] resumed the session at frame %d"):format(hi))
      else
        pal.log("[main] resume failed (" .. tostring(err) .. "); fresh boot")
      end
    end
  end
  if args.record then
    M.trace.record_start(args.record, { project = args.project })
  end
  if args.evals then -- after record_start: the drain lands in frame 1
    for _, code in ipairs(args.evals) do M.repl.submit(code) end
  end
  -- --edit: the editor shell (live/capture; under plain headless the shell
  -- loads but its ig frame is a no-op)
  if args.edit then M.ed.launch(args.project) end
end

local function poll_reload(now)
  if now < M.reload_at then return end
  M.reload_at = now + 250 * 1000000

  -- boot-time failure: the entry never loaded; keep retrying the require
  -- (covers fixes to the entry or anything in its require chain)
  if M.game_err and not M.game then
    local ok, game = xpcall(cm.require, debug.traceback, M.entry)
    if ok then
      M.game = game
      M.game_err = nil
      M.console.clear_error()
      pal.log("[resume] entry loaded")
      guarded(M.game.init)
    else
      local first = tostring(game):match("[^\n]*")
      if first ~= M.last_boot_err then -- don't spam the ring at 4 Hz
        M.last_boot_err = first
        pal.log("[retry] " .. first)
      end
    end
    return
  end

  local changed = cm.reload()
  if #changed == 0 then return end
  if M.trace then M.trace.on_code_change(changed) end
  if M.game_err then
    M.game_err = nil
    M.console.clear_error()
    pal.log("[resume] code reloaded; resuming sim")
    guarded(M.game.init) -- reload-idempotent by contract
  else
    for _, name in ipairs(changed) do
      if name == M.entry then
        guarded(M.game.init) -- must be reload-idempotent: buffers persist
      end
    end
  end
end

-- one sim frame: drain queued console evals (recorded — D022), then sample
-- (or accept) an input record, apply, step, count; state is recorded
-- post-step pre-draw, so a draw that mutates sim state shows up as a
-- verify divergence on the next frame
local function sim_step()
  local evals = M.repl.drain()
  local rec = M.input.sample()
  M.input.apply(rec)
  M.game.step()
  cm.require("cm.snd").step() -- the music sequencer (R9d): doc.snd-
                              -- driven, a no-op when no song is set
  pal.snd_render() -- one frame of PCM from snd.bank (R9b, AUDIO.md §2:
                   -- a true no-op until the first cm.snd call creates
                   -- the bank — pre-R9 traces/goldens byte-identical);
                   -- inside the step so the recorder sees bank deltas
  M.state.advance_frame()
  if M.trace then M.trace.record_frame(rec, evals) end
  return rec
end

-- after an engine-driven restore (scrubber rewind): clear any error pause
-- and re-run init — the same restore contract every other flow follows
function M.after_restore()
  if M.game_err then
    M.game_err = nil
    M.console.clear_error()
    pal.log("[resume] rewound out of the error")
  end
  if M.game then guarded(M.game.init) end
end

local function step_guarded()
  if not M.contain then
    sim_step()
    return true
  end
  local ok, err = xpcall(sim_step, debug.traceback)
  if not ok then enter_error(err) end
  return ok
end

function M.tick()
  local t0 = pal.time_ns()
  local events = pal.poll_events()
  for _, e in ipairs(events) do
    if e.type == "quit" then M.request_quit() end
  end
  -- engine UI sees raw events; the game sees what the UI didn't capture
  events = M.ui.frame(events)
  -- editor shell on: the game sees nothing — unless a game window is
  -- focused (= playing): keys pass, mouse remaps through the window's
  -- image rect to FOV px (EDITOR.md §12.3; recorded, replayable input)
  if M.ed and M.ed.on then events = M.ed.filter_events(events) end
  -- ingest into live input state EVERY tick, decoupled from sim stepping, so a
  -- render loop faster than the 60 Hz sim never drops a press/release (the
  -- windowed key-stick bug); sim_step then samples the live state per step
  M.input.feed(events)

  local now = pal.time_ns()
  -- reload polling off in capped runs (deterministic captures)
  if not M.args.frames then poll_reload(now) end

  local sim_t0 = pal.time_ns()
  if M.game_err then
    -- paused on the autopsy table: no stepping, repl runs immediately
    M.repl.drain()
    M.acc, M.last = 0, nil -- no catch-up pileup across the pause
  elseif M.scrub.paused() then
    -- time machine open: sim frozen, queued evals wait
    M.acc, M.last = 0, nil
  elseif M.args.headless then
    step_guarded()
  else
    M.acc = M.acc + (M.last and now - M.last or SIM_DT)
    M.last = now
    if M.acc > 4 * SIM_DT then M.acc = 4 * SIM_DT end -- stall clamp
    while M.acc >= SIM_DT do
      if not step_guarded() then break end
      M.acc = M.acc - SIM_DT
    end
  end
  -- render-only: adapt the FOV to the live window size before drawing (no-op
  -- headless / when unchanged). Runs in every live state (play, error, scrub).
  M.view.update()
  local draw_t0 = pal.time_ns()

  if M.game_err or not guarded(M.game.draw) then
    -- no game frame to show: dark backdrop (also resets a half-built batch)
    pal.begin_frame(0.09, 0.03, 0.07, 1)
  end
  M.ed.frame() -- the editor shell canvas (R3): ig layer, native res; also
  -- consumes the legacy panel toggle keys while on (EDITOR.md §8; the F1
  -- cm.editor died at R8e — the map/tilemap windows are the map tools now)
  -- the dev panels (scrub/perf/console/options) draw on the ui canvas at
  -- ui_scale. The editor already routed there when it's open; in play mode it
  -- returned early, so switch here (no-op headless / when the canvas is off).
  if M.view.ui_active then pal.x_target("ui") end
  M.scrub.frame() -- the time machine rides above the editor
  M.perf.frame()
  M.console.frame() -- after perf: console drops over everything
  M.options.frame() -- the video menu (Esc) rides on top of all of it
  M.ui.frame_end()
  local present_t0 = pal.time_ns()
  pal.present()
  M.perf.note((pal.time_ns() - t0) / 1e6, (draw_t0 - sim_t0) / 1e6,
              (present_t0 - draw_t0) / 1e6)

  M.ticks = M.ticks + 1
  if M.args.frames and M.ticks >= M.args.frames then
    if M.args.shot then
      local s, w, h
      if M.args.win_w then -- the full composite (editor + game), window-sized
        s, w, h = pal.x_capture_read()
      else -- the game internal target (the golden/screenshot default)
        s, w, h = pal.read_pixels(), pal.gfx_size()
      end
      pal.png_write(M.args.shot, s, w, h)
      pal.log("shot: " .. M.args.shot)
    end
    pal.quit()
  elseif M.args.headless and not M.args.frames then
    pal.sleep_ms(16) -- interactive headless session: do not spin the CPU
  end -- capped headless runs free-run (D013)

  -- flush the recording on ANY quit path (event, frame cap, game-initiated)
  if M.trace and pal.quitting() then
    M.trace.record_stop()
    M.trace.ring_flush() -- the open segment joins the cross-session
                         -- stream (R6.5); no-op when spill is off
  end
  -- same guarantee for the editor session + journals (unsaved-persists)
  if M.ed and M.ed.on and pal.quitting() then M.ed.quit_flush() end
end

return M
