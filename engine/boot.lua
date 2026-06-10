-- boot.lua — M0 minimal engine bootstrap.
-- Run from the repo root: bin/pettan [project_dir] [flags]
--   --headless        no window; tick = exactly one sim step (lockstep).
--                     without --frames it paces to ~60Hz and hot-reloads,
--                     i.e. a full live session minus the window
--   --frames N        quit after N ticks (headless testing; free-runs)
--   --shot PATH       write a PNG of the internal target before quitting
--   --no-vsync
-- The real module system, input map and state layer land in M1; this file
-- stays deliberately dumb until then.

local args = { project = "projects/sandbox" }
do
  local i = 1
  local argv = pal.argv
  while i <= #argv do
    local a = argv[i]
    if a == "--headless" then args.headless = true
    elseif a == "--no-vsync" then args.no_vsync = true
    elseif a == "--frames" then i = i + 1; args.frames = math.tointeger(argv[i]) or error("--frames needs a number")
    elseif a == "--shot" then i = i + 1; args.shot = argv[i] or error("--shot needs a path")
    elseif a:sub(1, 2) ~= "--" then args.project = a
    else error("unknown flag: " .. a) end
    i = i + 1
  end
end

local function loadchunk(path)
  local src, err = pal.read_file(path)
  if not src then error("can't read " .. path .. ": " .. tostring(err), 0) end
  local chunk, lerr = load(src, "@" .. path)
  if not chunk then error(lerr, 0) end
  return chunk()
end

local proj = loadchunk(args.project .. "/project.lua")
local W = proj.internal_w or 480
local H = proj.internal_h or 270

pal.gfx_init {
  w = W, h = H,
  scale = proj.window_scale or 2,
  title = proj.name or "pettan2d",
  headless = args.headless,
  vsync = not args.no_vsync,
}

local entry = args.project .. "/" .. (proj.entry or "main.lua")

-- crash parachute (see main.c): if a tick errors, the PAL reboots the VM
-- when any of these change
pal.watch_add("engine/boot.lua")
pal.watch_add(args.project .. "/project.lua")
pal.watch_add(entry)

local game = loadchunk(entry)
game.init()
pal.log(("booted %s (%dx%d) on pal %d/api%d %s"):format(args.project, W, H,
  pal.version.major, pal.version.api, pal.platform))

local SIM_DT = math.tointeger(1e9 // 60)
local acc, last = 0, nil
local ticks = 0
local entry_mtime = pal.mtime(entry)
local reload_check_at = 0

local function maybe_reload(now)
  if now < reload_check_at then return end
  reload_check_at = now + 250 * 1000000
  local mt = pal.mtime(entry)
  if mt == entry_mtime then return end
  entry_mtime = mt
  local ok, result = pcall(loadchunk, entry)
  if not ok then
    pal.log("[reload] FAILED, keeping old code: " .. tostring(result))
    return
  end
  game = result
  game.init() -- must be reload-idempotent: named buffers persist
  pal.log("[reload] " .. entry)
end

function pt_tick()
  local input = {}
  for _, e in ipairs(pal.poll_events()) do
    if e.type == "quit" then pal.quit(); return end
    input[#input + 1] = e
  end

  local now = pal.time_ns()
  -- skip reload polling only for capped runs (deterministic captures)
  if not args.frames then maybe_reload(now) end

  if args.headless then
    game.step(input)
  else
    acc = acc + (last and now - last or SIM_DT)
    last = now
    if acc > 4 * SIM_DT then acc = 4 * SIM_DT end -- stall clamp
    while acc >= SIM_DT do
      game.step(input)
      input = {}
      acc = acc - SIM_DT
    end
  end

  game.draw()
  pal.present()

  ticks = ticks + 1
  if args.frames and ticks >= args.frames then
    if args.shot then
      pal.png_write(args.shot, pal.read_pixels(), W, H)
      pal.log("shot: " .. args.shot)
    end
    pal.quit()
  elseif args.headless then
    pal.sleep_ms(16) -- interactive headless session: don't spin the CPU
  end
end
