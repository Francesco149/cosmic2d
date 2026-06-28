-- cm.main — engine entry: flags, project lifecycle, the tick loop.
-- Keeps its state on M (survives its own hot reload via the prev-table
-- convention; see boot.lua header).
--
-- Flags: [project_dir] --headless --frames N --shot PATH --no-vsync
--        --record PATH --verify PATH --eval CODE
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
  local a = { project = "projects/sandbox" }
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

function M.boot()
  local args = parse_args()
  M.args = args
  M.contain = not (args.frames or args.verify)
  if args.frames or args.verify then pal.exit_on_error(true) end
  if args.verify then args.headless = true end -- verify never pops a window

  local proj = load_project(args.project)
  M.proj = proj
  cm.set_project_root(args.project)

  pal.gfx_init {
    w = proj.internal_w or 480, h = proj.internal_h or 270,
    scale = proj.window_scale or 2,
    title = proj.name or "cosmic2d",
    headless = args.headless,
    vsync = not args.no_vsync,
  }

  M.state = cm.require("cm.state")
  M.input = cm.require("cm.input")
  M.ui = cm.require("cm.ui")
  M.repl = cm.require("cm.repl")
  M.console = cm.require("cm.console")
  M.perf = cm.require("cm.perf")
  M.editor = cm.require("cm.editor")
  M.scrub = cm.require("cm.scrub")
  M.view = cm.require("cm.view")
  -- the resize ladder runs only live: headless/verify keep the fixed project
  -- FOV so goldens + determinism never see a window-derived size (D036).
  M.view.set_enabled(not args.headless)
  cm.require("cm.rand").ensure_seeded(proj.seed or 0x70657474616e3264)

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
  -- the ring trace is always on in live sessions (D032); --record pins it
  M.trace = cm.require("cm.trace")
  M.trace.ring_start({ project = args.project })
  if args.record then
    M.trace.record_start(args.record, { project = args.project })
  end
  if args.evals then -- after record_start: the drain lands in frame 1
    for _, code in ipairs(args.evals) do M.repl.submit(code) end
  end
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
    if e.type == "quit" then
      -- game code may intercept (pause menus, save prompts); default quits
      if M.game and M.game.on_quit and not M.game_err then
        guarded(M.game.on_quit)
      else
        pal.quit()
      end
    end
  end
  -- engine UI sees raw events; the game sees what the UI didn't capture
  events = M.ui.frame(events)
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
    -- time machine open: sim frozen, queued evals wait for the resume
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
  M.editor.frame() -- editor chrome above the game, under perf/console
  M.scrub.frame() -- the time machine rides above the editor
  M.perf.frame()
  M.console.frame() -- after perf: console drops over everything
  M.ui.frame_end()
  local present_t0 = pal.time_ns()
  pal.present()
  M.perf.note((pal.time_ns() - t0) / 1e6, (draw_t0 - sim_t0) / 1e6,
              (present_t0 - draw_t0) / 1e6)

  M.ticks = M.ticks + 1
  if M.args.frames and M.ticks >= M.args.frames then
    if M.args.shot then
      local w, h = pal.gfx_size()
      pal.png_write(M.args.shot, pal.read_pixels(), w, h)
      pal.log("shot: " .. M.args.shot)
    end
    pal.quit()
  elseif M.args.headless and not M.args.frames then
    pal.sleep_ms(16) -- interactive headless session: do not spin the CPU
  end -- capped headless runs free-run (D013)

  -- flush the recording on ANY quit path (event, frame cap, game-initiated)
  if M.trace and pal.quitting() then M.trace.record_stop() end
end

return M
