-- bounce main.lua — demo 1's movement slice: the bouncy cube running and
-- jumping around an axis-aligned graybox playground, orbit-follow camera,
-- every feel value a live knob (the smoke KNOBS pattern, D028).
--
-- Controls: wasd move (camera-relative: w = away from camera) · space
-- jump · arrows = camera yaw/pitch · mouse drag = look · wheel = zoom ·
-- c recenter · ` console (game.demo(1) = autoplay, game.demo(2) = walk).
--
-- The camera is the FollowCamera model from the human's godot cosmic
-- project (F:\Documents\cosmic src/camera): explicit orbit yaw/pitch/dist,
-- a smoothed focus on the player, and three composing drives — yaw-follow
-- eases behind the velocity heading (holding a sideways run circles the
-- camera around), manual look (drag / z/x) pauses yaw-follow briefly so
-- they don't fight, and recenter snaps behind the facing. Drag-look uses
-- absolute cursor deltas from the frozen input record; true captured-mouse
-- look needs a PAL relative-mouse API (deferred — record v1 stays frozen).
--
-- Determinism: sim state in named buffers (bounce.player/bounce.cam) + doc
-- tree; cm.math trig; fixed dt. The follow camera is GAMEPLAY state (input
-- is camera-relative, so the sim must know it — the smoke cam precedent),
-- stepped in game.step; view/proj matrices stay render-class in draw.
-- Headless/autoplay runs see no mouse (zeroed record fields), so the demo
-- is driven purely by yaw-follow and stays deterministic (same trick as
-- the godot original's golden runs).

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m4 = cm.require("cm.m4")
local gb = cm.require("gb")
local level = cm.require("level")
local player = cm.require("player")
local pickups = cm.require("pickups")
local audio = cm.require("audio")

local W, H = pal.gfx_size()
local FOVY, ZN, ZF = 52, 0.3, 120

local game = {}
game.level = level -- console reach

-- feel knobs, all live (doc tree -> console, snapshots). Units: world units
-- (the cube is 1u tall), seconds, frames where named _t/frames.
local KNOBS = {
  move = {
    cw = 0.9, ch = 1.0, -- collider box (visual cube is 1x1x1)
    speed = 6.5, accel = 40, fric = 30, air_accel = 20, air_fric = 4,
    jump_h = 1.9, jump_apex_t = 22, fall_mul = 1.5, fall_max = 22,
    coyote = 6, buffer = 5, turn = 0.25,
    step_h = 0.6, -- mantle: blocked steps up to this lift are walked up
    kill_y = -12, -- fell off the world: respawn
  },
  cam = { -- the godot FollowCamera/CameraTuning knob set, per-frame units
    dist = 7.5, height = 3.2, look_h = 1.0,
    min_dist = 3.5, max_dist = 13, wheel_step = 0.8,
    pos_lerp = 0.10,             -- focus chase (PositionSharpness)
    yaw_follow = 0.16,           -- 0 = never auto-rotate, 1 = hard behind
    yaw_lerp = 0.04,             -- how fast yaw-follow catches up
    min_speed = 1.5,             -- below this hspeed the orbit holds still
    orbit = 0.045,               -- z/x yaw rate, rad/frame
    mouse_yaw = 0.012, mouse_pitch = 0.010, -- rad per internal pixel
    key_pitch = 0.025,                      -- up/down arrow pitch, rad/frame
    pitch_min = -0.6, pitch_max = 0.95,     -- rad around the ref elevation
    recenter_lerp = 0.25, hold_frames = 42, -- manual pause of yaw-follow
  },
  feel = {
    stretch = 0.32, squash = 0.42, vref = 12,
    squash_frames = 10, lean = 0.15,
  },
  goal = { -- the pickup loop (pickups.lua)
    r = 0.9,        -- gem pickup radius (the star scales it up)
    respawn = 300,  -- frames until the goal star returns (gems only on lap)
    pop = 12,       -- pickup ghost: expand-and-fade frames
    banner = 100,   -- CLEAR banner frames
    spin = 0.05,    -- gem spin, rad/frame (render-class)
    bob = 0.16, bob_f = 80, -- hover bob amplitude (u) / period (frames)
  },
}

local cam, dyn, skybuf

local function knob_file() return cm.main.args.project .. "/knobs.dat" end

local function load_knobs()
  local bytes = pal.read_file(knob_file())
  if not bytes then return nil end
  local ok, t = pcall(state.parse, bytes)
  if ok and type(t) == "table" then return t end
  pal.log("[knobs] knobs.dat unreadable; using defaults")
  return nil
end

function game.save_knobs()
  return pal.write_file(knob_file(), state.canon(state.doc.knobs))
end

local function build_sky()
  skybuf = pal.buf("rc.bounce.sky", 6 * 24)
  local function sv(x, y, c)
    return string.pack("<fffffBBBB", x, y, 0.9999, 0, 0,
                       (c[1] * 255) // 1, (c[2] * 255) // 1, (c[3] * 255) // 1, 255)
  end
  local t, b = level.sky_top, level.sky_bot
  local v0, v1 = sv(-1, 1, t), sv(1, 1, t)
  local v2, v3 = sv(1, -1, b), sv(-1, -1, b)
  skybuf:setstr(0, v0 .. v1 .. v2 .. v0 .. v2 .. v3)
end

function game.init()
  local d = state.doc
  d.knobs = d.knobs or load_knobs() or {}
  for group, defaults in pairs(KNOBS) do
    d.knobs[group] = d.knobs[group] or {}
    for key, v in pairs(defaults) do
      if d.knobs[group][key] == nil then d.knobs[group][key] = v end
    end
    for key in pairs(d.knobs[group]) do
      if defaults[key] == nil then d.knobs[group][key] = nil end
    end
  end
  if d.demo == nil then d.demo = 0 end
  if d.demo_t0 == nil then d.demo_t0 = 0 end
  d.score = d.score or 0   -- gems collected, all time
  d.laps = d.laps or 0     -- goal stars touched
  d.clear_t = d.clear_t or 0

  level.build()
  player.init()
  audio.init()
  pickups.init()
  build_sky()

  -- dyn: per-frame cube + shadow + pickup verts (render-class scratch,
  -- rebuilt in draw; a named buffer only so the PAL can read it)
  local dyn_size = (74 + pickups.max_tris()) * 72
  local ok, db = pcall(pal.buf, "rc.bounce.dyn", dyn_size)
  if not ok then -- worst case grew across a hot reload
    pal.buf_free("rc.bounce.dyn")
    db = pal.buf("rc.bounce.dyn", dyn_size)
  end
  dyn = db

  -- bounce.cam layout (f32): [0]yaw [4]pitch [8]dist [12/16/20]focus xyz
  -- [24]manual-hold frames [28/32]prev cursor [36]recentering flag
  local ok, cb = pcall(pal.buf, "bounce.cam", 40)
  if not ok then -- pre-orbit sessions had a 12B pull-cam buffer
    pal.buf_free("bounce.cam")
    cb = pal.buf("bounce.cam", 40)
  end
  cam = cb
  if cam:f32(0) == 0 and cam:f32(8) == 0 then -- virgin: behind the facing
    local px, py, pz = player.pos()
    cam:f32(0, player.yaw() + m.pi)
    cam:f32(8, state.doc.knobs.cam.dist)
    cam:f32(12, px); cam:f32(16, py); cam:f32(20, pz)
  end

  input.map({
    { "left", input.key.a }, { "right", input.key.d },
    { "up", input.key.w }, { "down", input.key.s },
    { "jump", input.key.space },
    { "cam_l", input.key.left }, { "cam_r", input.key.right },
    { "cam_u", input.key.up }, { "cam_d", input.key.down },
    { "recenter", input.key.c },
  })
end

-- console: game.demo(1) hands controls to the autoplay loop (run the stair
-- course, hop on a beat, arc left); any real press takes back
function game.demo(on)
  local d = state.doc
  if on and on ~= 0 then
    d.demo = on
    d.demo_t0 = state.frame()
  else
    d.demo = 0
  end
end

local ACTIONS = { "left", "right", "up", "down", "jump" }

-- camera-relative wish vector from held dirs: forward = cam->player on xz
local function build_ctl()
  local d = state.doc
  if d.demo ~= 0 then
    for _, a in ipairs(ACTIONS) do
      if input.pressed(a) then
        game.demo(0)
        break
      end
    end
  end
  local fwd, side, jump_pressed
  if d.demo == 2 then -- pure forward walk (collision soak tests)
    fwd, side, jump_pressed = 1, 0, false
  elseif d.demo ~= 0 then
    local rel = state.frame() - d.demo_t0
    fwd = 1
    side = (rel % 270 >= 90 and rel % 270 < 180) and -1 or 0
    jump_pressed = rel % 45 == 5
  else
    fwd = (input.down("up") and 1 or 0) + (input.down("down") and -1 or 0)
    side = (input.down("right") and 1 or 0) + (input.down("left") and -1 or 0)
    jump_pressed = input.pressed("jump")
  end
  local wishx, wishz = 0, 0
  if fwd ~= 0 or side ~= 0 then
    -- forward = the camera's view direction on xz, straight from orbit yaw
    -- (yaw 0 = camera on +z looking -z); right = cross(forward, up)
    local yaw = cam:f32(0)
    local fx, fz = -m.sin(yaw), -m.cos(yaw)
    wishx = fx * fwd + (-fz) * side
    wishz = fz * fwd + fx * side
    local wl = m.sqrt(wishx * wishx + wishz * wishz)
    if wl > 1e-4 then wishx, wishz = wishx / wl, wishz / wl
    else wishx, wishz = 0, 0 end
  end
  return { wishx = wishx, wishz = wishz, jump_pressed = jump_pressed }
end

local function angdiff(target, from) -- shortest arc, (-pi, pi]
  return m.atan2(m.sin(target - from), m.cos(target - from))
end

-- orbit-follow camera (the godot FollowCamera model): explicit yaw/pitch/
-- dist + a smoothed focus; drag-look and z/x steer the orbit directly and
-- pause yaw-follow (hold), yaw-follow eases behind the velocity heading,
-- c recenters behind the facing. Position derives in draw — only the
-- orbit/focus STATE lives here.
local function cam_step()
  local kc = state.doc.knobs.cam
  local px, py, pz = player.pos()
  local yaw, pitch, dist = cam:f32(0), cam:f32(4), cam:f32(8)
  local hold, rec = cam:f32(24), cam:f32(36)

  -- wheel zoom (record-backed, zero in headless runs)
  local w = input.wheel()
  if w ~= 0 then
    dist = m.clamp(dist - w * kc.wheel_step, kc.min_dist, kc.max_dist)
  end

  -- drag-look: cursor deltas while a mouse button is held steer the orbit
  local mx, my = input.mouse()
  local manual = false
  if input.button_down(1) or input.button_down(3) then
    local dx, dy = mx - cam:f32(28), my - cam:f32(32)
    if dx ~= 0 or dy ~= 0 then
      yaw = yaw - dx * kc.mouse_yaw
      pitch = m.clamp(pitch + dy * kc.mouse_pitch, kc.pitch_min, kc.pitch_max)
      manual = true
    end
  end
  cam:f32(28, mx); cam:f32(32, my)

  -- arrow keys as the right stick (godot HandleManualRotation signs:
  -- push right -> swing right = yaw -=, down -> camera lifts = pitch +=)
  local kyaw = (input.down("cam_l") and kc.orbit or 0)
             + (input.down("cam_r") and -kc.orbit or 0)
  local kpitch = (input.down("cam_u") and -kc.key_pitch or 0)
              + (input.down("cam_d") and kc.key_pitch or 0)
  if kyaw ~= 0 or kpitch ~= 0 then
    yaw = yaw + kyaw
    pitch = m.clamp(pitch + kpitch, kc.pitch_min, kc.pitch_max)
    manual = true
  end

  if manual then
    hold = kc.hold_frames
    rec = 0
  end

  if input.pressed("recenter") then rec = 1 end
  if rec == 1 then
    local target = player.yaw() + m.pi
    yaw = yaw + angdiff(target, yaw) * kc.recenter_lerp
    pitch = pitch * (1 - kc.recenter_lerp)
    if m.abs(angdiff(target, yaw)) < 0.01 and m.abs(pitch) < 0.01 then
      yaw, pitch, rec = target, 0, 0
    end
  end

  -- yaw-follow: ease behind the heading (the circling on a held sideways
  -- run) unless the player just steered or a recenter is in flight
  local vx, _, vz = player.vel()
  local hspeed = m.sqrt(vx * vx + vz * vz)
  if rec == 0 and hold <= 0 and kc.yaw_follow > 0 and hspeed > kc.min_speed then
    local behind = m.atan2(-vx, -vz)
    yaw = yaw + angdiff(behind, yaw) * kc.yaw_follow * kc.yaw_lerp
  end
  hold = m.max(0, hold - 1)

  -- the focus chases the player; the rigid orbit hangs off it in draw
  local fx = cam:f32(12) + (px - cam:f32(12)) * kc.pos_lerp
  local fy = cam:f32(16) + (py - cam:f32(16)) * kc.pos_lerp
  local fz = cam:f32(20) + (pz - cam:f32(20)) * kc.pos_lerp

  cam:f32(0, m.fmod(yaw, m.tau)); cam:f32(4, pitch); cam:f32(8, dist)
  cam:f32(12, fx); cam:f32(16, fy); cam:f32(20, fz)
  cam:f32(24, hold); cam:f32(36, rec)
end

function game.step()
  player.step(build_ctl())
  pickups.step()
  cam_step()
  -- collision/feel telemetry: --eval "_G.DBG=10" prints the track every N
  -- frames; reads + prints only (the smoke DEMO_DBG pattern)
  if DBG and state.frame() % (tonumber(DBG) or 10) == 0 then
    local px, py, pz = player.pos()
    local vx, vy, vz = player.vel()
    print(("DBG f=%d p=%.3f,%.3f,%.3f v=%.2f,%.2f,%.2f yaw=%.2f gems=%d laps=%d"):format(
      state.frame(), px, py, pz, vx, vy, vz, cam:f32(0),
      state.doc.score, state.doc.laps))
  end
end

function game.draw()
  pal.begin_frame(0, 0, 0, 1)

  -- sky: NDC passthrough gradient (fog off)
  pal.x_view3d()
  pal.x_tris(0, skybuf, 2, 0, 0)

  -- camera position derives from the orbit state: height scales with zoom
  -- so the reference elevation angle holds; pitch tilts around it on a
  -- constant radius (godot OrbitOffset + ScaleFramingWithDistance)
  local kc = state.doc.knobs.cam
  local yaw, pitch, dist = cam:f32(0), cam:f32(4), cam:f32(8)
  local fx, fy, fz = cam:f32(12), cam:f32(16), cam:f32(20)
  local h = kc.height * dist / kc.dist
  local e0 = m.atan2(h, dist)
  local R = m.sqrt(dist * dist + h * h)
  local elev = m.clamp(e0 + pitch, -1.4, 1.4)
  local hr = m.cos(elev) * R
  local view = m4.lookat(fx + m.sin(yaw) * hr, fy + m.sin(elev) * R,
                         fz + m.cos(yaw) * hr,
                         fx, fy + kc.look_h, fz, 0, 1, 0)
  local proj = m4.persp(FOVY, W / H, ZN, ZF)
  local fog = level.fog
  pal.x_view3d{
    mvp = m4.mul(proj, view),
    fog_start = fog.s, fog_end = fog.e, fog = fog.col, fog_on = fog.on,
  }

  for _, s in ipairs(level.segs) do
    pal.x_tris(s.tex, level.vbuf, s.count, s.off, 0)
  end

  -- the cube + pickups (opaque), then the blend pass: blob shadow +
  -- pickup pop ghosts (no depth write, after all opaque)
  local frame = state.frame()
  local out = {}
  local ncube = player.emit(out)
  local ngem = pickups.emit(out, frame)
  local nsh = player.emit_shadow(out)
  local nfx = pickups.emit_fx(out, frame)
  dyn:setstr(0, table.concat(out))
  local off = 0
  pal.x_tris(0, dyn, ncube, off, 0); off = off + ncube * 72
  if ngem > 0 then pal.x_tris(0, dyn, ngem, off, 0) end
  off = off + ngem * 72
  pal.x_tris(level.tex.shadow, dyn, nsh, off, 4); off = off + nsh * 72
  if nfx > 0 then pal.x_tris(0, dyn, nfx, off, 4) end

  local st = pal.frame_stats()
  text.draw(3, 3, ("bounce  %d tris  frame %d")
            :format(st.tris or 0, frame))
  local d = state.doc
  local hud = ("gems %d . laps %d"):format(d.score, d.laps)
  text.draw(W - text.measure(hud) - 3, 3, hud,
            { r = 1, g = 0.85, b = 0.45 })
  if d.clear_t > 0 then
    -- CLEAR banner: holds, then fades out over its last third
    local kb = d.knobs.goal.banner
    local a = m.min(1, 3 * d.clear_t / kb)
    local msg = "COURSE CLEAR!"
    text.draw((W - text.measure(msg, "8x16")) // 2, H // 3, msg,
              { font = "8x16", r = 1, g = 0.9, b = 0.5, a = a })
  end
  if d.demo ~= 0 then
    local msg = "AUTOPLAY * press any key"
    text.draw((W - text.measure(msg)) // 2, 14, msg,
              { r = 1, g = 0.92, b = 0.6, a = 0.95 })
  end
  text.draw(3, H - 11, "wasd move . space jump . arrows/drag camera . wheel zoom . c recenter")
end

return game
