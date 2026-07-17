-- inputproof — the A4 exit-proof fixture. One sim that consumes EVERY
-- recorded input domain at once: keyboard action bits (with pad-button and
-- pad-axis bindings ORed into the same bits, D084), the v1 mouse fields
-- (x/y, buttons, wheel), the PAD extension (quantized axes, button edges,
-- hot-plug), and the D086 save doors (write as a pure output on an action
-- edge, the recorded eval-channel load). tests/traces/inputproof_a4exit.ctrace
-- replays a real windowed session over this sim — including a scrub
-- rewind/resume taken mid-session — on every platform.
--
-- Everything the sim touches lives in state.doc; pad readers run every
-- frame so the PAD extension latches on (the real gamepad-game shape).
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local save = cm.require("cm.save")
local text = cm.require("cm.text")

local W, H = pal.gfx_size()
local DOT = 8

local game = {}

function game.init()
  input.map({
    { "left", input.key.left, "pad:dpleft", "pad:lx-" },
    { "right", input.key.right, "pad:dpright", "pad:lx+" },
    { "up", input.key.up, "pad:dpup" },
    { "down", input.key.down, "pad:dpdown" },
    { "save", input.key.s, "pad:west" },
    { "load", input.key.l, "pad:east" },
  })
  save.schema(1)
  save.on_load(function(data)
    -- applied at frame start via the recorded EVAL (D086): the payload
    -- bytes travel in the trace, never re-read from this machine's disk
    local d = state.doc
    d.level = data.level
    d.x, d.y = data.x, data.y
    d.loads = d.loads + 1
  end)
  local d = state.doc
  if d.x == nil then
    d.x, d.y = W / 2, H / 2
    d.level = 1
    d.mx, d.my = 0, 0 -- last sampled mouse
    d.msum = 0        -- |mouse delta| accumulator (exact ints)
    d.clicks, d.rclicks = 0, 0
    d.wheelsum = 0
    d.taps = 0        -- "up" press edges (the sub-frame key tap lands here)
    d.presses, d.releases, d.plugs = 0, 0, 0 -- pad south edges + connects
    d.axsum = 0       -- running |quantized lx| sum (exact integer)
    d.was_conn = false
    d.saveop, d.loadop, d.loads = 0, 0, 0
  end
end

function game.step()
  local d = state.doc

  -- pad axes drive the dot like padtest: quantized -127..127 over 32 px/s
  -- at 60 Hz, exact per-frame float math
  local lx, ly = input.pad_axis(1, "lx"), input.pad_axis(1, "ly")
  d.x = d.x + lx * (32 / 127 / 60)
  d.y = d.y + ly * (32 / 127 / 60)

  -- action bits: keys, pad buttons, and threshold-crossing axes all land
  -- in the same recorded v1 word (D084)
  if input.down("left") then d.x = d.x - 1 end
  if input.down("right") then d.x = d.x + 1 end
  if input.down("up") then d.y = d.y - 1 end
  if input.down("down") then d.y = d.y + 1 end
  if d.x < 0 then d.x = 0 elseif d.x > W - DOT then d.x = W - DOT end
  if d.y < 0 then d.y = 0 elseif d.y > H - DOT then d.y = H - DOT end
  if input.pressed("up") then d.taps = d.taps + 1 end

  -- the v1 mouse fields feed the sim
  local mx, my = input.mouse()
  local dx, dy = mx - d.mx, my - d.my
  d.msum = d.msum + (dx < 0 and -dx or dx) + (dy < 0 and -dy or dy)
  d.mx, d.my = mx, my
  if input.button_pressed(1) then d.clicks = d.clicks + 1 end
  if input.button_pressed(3) then d.rclicks = d.rclicks + 1 end
  local w = input.wheel()
  d.wheelsum = d.wheelsum + w
  d.level = d.level + w -- the wheel tunes the level the save round-trips

  -- PAD extension edges + hot-plug, padtest-style
  if input.pad_pressed(1, "south") then d.presses = d.presses + 1 end
  if input.pad_released(1, "south") then d.releases = d.releases + 1 end
  local conn = input.pad_connected(1)
  if conn and not d.was_conn then d.plugs = d.plugs + 1 end
  d.was_conn = conn
  d.axsum = d.axsum + (lx < 0 and -lx or lx)

  -- the save doors (D086). The write is a pure output: its result is
  -- deliberately ignored — on verify the store is disabled and this is a
  -- named no-op, so branching the sim on it would be a determinism bug.
  if input.pressed("save") then
    d.saveop = d.saveop + 1
    save.write(1, { level = d.level, x = d.x, y = d.y })
  end
  if input.pressed("load") then
    d.loadop = d.loadop + 1
    -- reads NOW live-side, then queues the exact bytes through the
    -- recorded eval channel; on verify the EVAL replays the payload
    save.load(1)
  end
end

-- ---------------------------------------------------------------------
-- The exit-proof driver (render/dev side). Armed by a recorded eval —
--   bin/cosmic projects/inputproof --record ... is NOT how the golden was
--   cut; the session runs windowed (so the D086 store binds) with
--   --eval 'game.arm_drive("<out>.ctrace")'
-- and the driver exports the ring at the end ("save what just happened"),
-- so the committed trace spans a scrub rewind/resume seam. draw() never
-- runs under --verify, so the re-executed arming eval is inert there: the
-- recorded input records and EVAL payloads stay the single source of
-- truth. Synthetic key/mouse events enter through cm.input.feed — the
-- exact door PAL events use — and the gamepad is a REAL virtual SDL
-- device riding the physical event path (D083).
local drv -- coroutine while armed; module-local dev state, never sim state

local function key(sc, down)
  input.feed({ { type = "key", scancode = sc, down = down } })
end
local function motion(x, y)
  input.feed({ { type = "motion", x = x, y = y } })
end
local function button(n, down, x, y)
  input.feed({ { type = "button", button = n, down = down, x = x, y = y } })
end
local function wheel(dy)
  input.feed({ { type = "wheel", dy = dy } })
end
local function pump() pal.x_events_pump() end
local function vbtn(vid, name, down)
  pal.x_pad_virtual_button(vid, input.pad_btn[name], down)
end
local function vaxis(vid, name, raw)
  pal.x_pad_virtual_axis(vid, input.pad_ax[name], raw)
end

local function drive_body(out)
  local scrub = cm.require("cm.scrub")
  local trace = cm.require("cm.trace")
  local function wait_frame(f)
    while state.frame() < f do coroutine.yield() end
  end
  local function pause() coroutine.yield() end

  save.wipe() -- reproducible live runs: start from an empty namespace

  -- phase 1: keyboard + mouse (frames ~5..65)
  wait_frame(5)
  key(input.key.right, true)
  wait_frame(25)
  key(input.key.right, false)
  key(input.key.down, true)
  wait_frame(40)
  key(input.key.down, false)
  key(input.key.up, true) -- sub-frame tap: down+up between two samples
  key(input.key.up, false)
  wait_frame(45)
  motion(100, 80)
  pause()
  motion(140, 90)
  pause()
  motion(180, 120)
  wait_frame(50)
  button(1, true, 180, 120)
  pause()
  button(1, false, 180, 120)
  wait_frame(55)
  button(3, true, 200, 140)
  pause()
  button(3, false, 200, 140)
  wait_frame(60)
  wheel(1)
  pause()
  wheel(1)
  wait_frame(65)
  wheel(-1)

  -- phase 2: the virtual pad (frames ~70..145)
  wait_frame(70)
  local vid = pal.x_pad_virtual()
  if not vid then
    error("virtual gamepads unavailable - cannot record the exit proof")
  end
  pump()
  wait_frame(80)
  vaxis(vid, "lx", -12000) -- partial: past the deadzone, under the
  pump()                   -- action threshold ("left" stays off)
  wait_frame(95)
  vaxis(vid, "lx", -32768) -- full deflection: "pad:lx-" fires "left"
  pump()
  wait_frame(105)
  vaxis(vid, "lx", 0)
  pump()
  wait_frame(110)
  vbtn(vid, "south", true)
  pump()
  wait_frame(115)
  vbtn(vid, "south", false)
  pump()
  vbtn(vid, "south", true) -- sub-frame pad tap (pump between down and up:
  pump()                   -- the D083 SDL quirk)
  vbtn(vid, "south", false)
  pump()
  wait_frame(120)
  vbtn(vid, "west", true) -- pad button -> the "save" ACTION bit (D084)
  pump()
  wait_frame(123)
  vbtn(vid, "west", false)
  pump()
  wait_frame(130)
  pal.x_pad_virtual_remove(vid) -- hot-unplug mid-recording
  pump()
  wait_frame(140)
  vid = pal.x_pad_virtual() -- replug: a second connect transition
  pump()

  -- save/load round trip through the keyboard bindings (~150..175)
  wait_frame(150)
  key(input.key.s, true)
  wait_frame(153)
  key(input.key.s, false)
  wait_frame(160)
  wheel(1)
  pause()
  wheel(1)
  wait_frame(170)
  key(input.key.l, true)
  wait_frame(173)
  key(input.key.l, false)

  -- scrub rewind/resume mid-session: open freezes the sim, the playhead
  -- walks back, rewind-here truncates the future and play resumes. The
  -- ring keeps one gapless timeline across the seam.
  wait_frame(200)
  scrub.open()
  pause()
  scrub.seek(185)
  pause()
  scrub.rewind_here()
  pause()

  -- phase 3, post-rewind: all three domains in the same frames
  key(input.key.right, true)
  vaxis(vid, "ly", 20000)
  pump()
  motion(60, 60)
  wait_frame(205)
  wheel(-1)
  vbtn(vid, "south", true)
  pump()
  wait_frame(215)
  vbtn(vid, "south", false)
  pump()
  key(input.key.right, false)
  wait_frame(220)
  vaxis(vid, "ly", 0)
  pump()
  -- a second save/load round trip across the rewind seam
  wait_frame(230)
  key(input.key.s, true)
  wait_frame(233)
  key(input.key.s, false)
  wait_frame(238)
  wheel(1)
  wait_frame(244)
  key(input.key.l, true)
  wait_frame(247)
  key(input.key.l, false)

  wait_frame(258)
  local ok, frames = trace.ring_export(out)
  if not ok then error("ring export failed: " .. tostring(out)) end
  pal.log(("[inputproof] exported %d frames to %s"):format(frames, out))
  cm.require("cm.main").request_quit()
end

-- the arming door (called through the recorded eval channel). Recording
-- sessions only: under --verify / --frames / --headless the driver must
-- never run — the recorded bytes are the authority.
function game.arm_drive(out)
  local args = cm.main and cm.main.args or {}
  if args.verify or args.frames or args.headless then return end
  drv = coroutine.create(function() drive_body(out) end)
  pal.log("[inputproof] drive armed -> " .. tostring(out))
end

local function drv_tick()
  if not drv then return end
  local co = drv
  local ok, err = coroutine.resume(co)
  if not ok then
    drv = nil
    error("[inputproof] driver failed: " .. tostring(err))
  end
  if coroutine.status(co) == "dead" and drv == co then drv = nil end
end

function game.draw()
  pal.begin_frame(0.08, 0.09, 0.12, 1)
  local d = state.doc
  pal.quad(d.x, d.y, DOT, DOT, 0.55, 0.85, 0.95, 1)
  text.draw(6, 6, ("lvl:%d clicks:%d/%d wheel:%d msum:%d taps:%d")
            :format(d.level, d.clicks, d.rclicks, d.wheelsum, d.msum, d.taps),
            { r = 0.95, g = 0.92, b = 0.8, a = 0.9 })
  text.draw(6, 16, ("pads:%s press:%d rel:%d plugs:%d axsum:%d sv:%d ld:%d/%d")
            :format(input.pad_connected(1) and "1" or "-", d.presses,
                    d.releases, d.plugs, d.axsum, d.saveop, d.loadop, d.loads),
            { r = 0.8, g = 0.9, b = 0.95, a = 0.9 })
  drv_tick()
end

return game
