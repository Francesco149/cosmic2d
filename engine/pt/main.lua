-- pt.main — engine entry: flags, project lifecycle, the tick loop.
-- Keeps its state on M (survives its own hot reload via the prev-table
-- convention; see boot.lua header).
--
-- Flags: [project_dir] --headless --frames N --shot PATH --no-vsync
--   --headless        no window; tick = exactly one sim step (lockstep).
--                     Without --frames it paces to ~60Hz with hot reload +
--                     parachute: a full live session minus the window (D013)
--   --frames N        quit after N ticks; free-runs, reload polling off,
--                     errors exit(1) (deterministic captures / CI)
--   --shot PATH       write a PNG of the internal target before quitting

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
  pt.register_special("@project", path, src)
  local chunk, lerr = load(src, "@" .. path)
  if not chunk then error(lerr, 0) end
  local proj = chunk()
  if type(proj) ~= "table" then error(path .. " did not return a table", 0) end
  return proj
end

function M.boot()
  local args = parse_args()
  M.args = args
  if args.frames then pal.exit_on_error(true) end

  local proj = load_project(args.project)
  M.proj = proj
  pt.set_project_root(args.project)

  pal.gfx_init {
    w = proj.internal_w or 480, h = proj.internal_h or 270,
    scale = proj.window_scale or 2,
    title = proj.name or "pettan2d",
    headless = args.headless,
    vsync = not args.no_vsync,
  }

  M.state = pt.require("pt.state")
  pt.require("pt.rand").ensure_seeded(proj.seed or 0x70657474616e3264)

  M.entry = (proj.entry or "main.lua"):gsub("%.lua$", ""):gsub("/", ".")
  M.game = pt.require(M.entry)
  M.game.init()

  M.acc, M.last, M.ticks = 0, nil, 0
  M.reload_at = 0
  local w, h = pal.gfx_size()
  pal.log(("booted %s (%dx%d) on pal %d/api%d %s"):format(
    args.project, w, h, pal.version.major, pal.version.api, pal.platform))
end

local function poll_reload(now)
  if now < M.reload_at then return end
  M.reload_at = now + 250 * 1000000
  local changed = pt.reload()
  for _, name in ipairs(changed) do
    if name == M.entry then
      M.game.init() -- must be reload-idempotent: named buffers persist
    end
  end
end

function M.tick()
  local input = {}
  for _, e in ipairs(pal.poll_events()) do
    if e.type == "quit" then pal.quit() return end
    input[#input + 1] = e
  end

  local now = pal.time_ns()
  -- reload polling off in capped runs (deterministic captures)
  if not M.args.frames then poll_reload(now) end

  if M.args.headless then
    M.game.step(input)
    M.state.advance_frame()
  else
    M.acc = M.acc + (M.last and now - M.last or SIM_DT)
    M.last = now
    if M.acc > 4 * SIM_DT then M.acc = 4 * SIM_DT end -- stall clamp
    while M.acc >= SIM_DT do
      M.game.step(input)
      M.state.advance_frame()
      input = {}
      M.acc = M.acc - SIM_DT
    end
  end

  M.game.draw()
  pal.present()

  M.ticks = M.ticks + 1
  if M.args.frames and M.ticks >= M.args.frames then
    if M.args.shot then
      local w, h = pal.gfx_size()
      pal.png_write(M.args.shot, pal.read_pixels(), w, h)
      pal.log("shot: " .. M.args.shot)
    end
    pal.quit()
  elseif M.args.headless then
    pal.sleep_ms(16) -- interactive headless session: do not spin the CPU
  end
end

return M
