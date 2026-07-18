-- bounce main.lua — demo 1's movement slice: the bouncy cube running and
-- jumping around an axis-aligned graybox playground, orbit-follow camera,
-- every feel value a live knob (the smoke KNOBS pattern, D028).
--
-- Controls: wasd move (camera-relative: w = away from camera) · space
-- jump · arrows = camera yaw/pitch · mouse drag = look · wheel = zoom ·
-- c recenter · ` console (game.demo(1) = autoplay loop, game.demo(2) =
-- walk, game.demo(3) = the full lap route: stairs -> keep -> platforms ->
-- goal star -> home, forever; game.demo(4) = the mover tour: tower lift ->
-- dome -> goal star -> keep roof -> wall ferry -> wall walk, forever).
--
-- The camera is the FollowCamera model from the human's godot cosmic
-- project (F:\Documents\cosmic src/camera): explicit orbit yaw/pitch/dist,
-- a smoothed focus on the player, and three composing drives — yaw-follow
-- eases behind the velocity heading (holding a sideways run circles the
-- camera around), manual look (drag / z/x) pauses yaw-follow briefly so
-- they don't fight, and recenter snaps behind the facing. Drag-look uses
-- absolute cursor deltas from the frozen input record; captured-mouse look
-- rides the recorded MREL deltas (v21) — game.init arms the capture wish
-- and the shell grants the OS capture while play owns the screen (D126).
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
local gb = cm.require("cm.gb")
local rig = cm.require("cm.rig")
local move = cm.require("cm.move")
local hud = cm.require("cm.hud")
local level = cm.require("level")
local movers = cm.require("movers")
local player = cm.require("player")
local pickups = cm.require("pickups")
local audio = cm.require("audio")

local W, H = pal.gfx_size()
local FOVY, ZN, ZF = 52, 0.3, 120

local game = select(2, ...) or {}
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
    back_cone = 0.35, -- heading within this of straight-INTO-the-camera
                      -- pauses yaw-follow (the vibration fix, D3D-018)
  },
  feel = {
    stretch = 0.32, squash = 0.42, vref = 12,
    squash_frames = 10, lean = 0.15,
  },
  look = { -- the N64 presentation (D3D-003, render-class: never read by sim)
    quant = 5, -- framebuffer grade: bits/channel + Bayer dither (0 = off)
    soft = 1,  -- VI-soft present blit: bilinear + smear (0 = sharp pixels)
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
  -- mouse look (D126): declare the capture WISH — the shell grants the
  -- actual OS capture only while play owns the screen (player mode with
  -- the Esc menu closed; in the editor while the game window is focused,
  -- Esc releases). The rig reads the recorded input.mouse_rel() deltas,
  -- so replay/verify never depend on live capture state.
  input.capture_mouse(true)
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
  if d.demo_wp == nil then d.demo_wp = 1 end
  if d.demo_hold == nil then d.demo_hold = 0 end
  d.score = d.score or 0   -- gems collected, all time
  d.laps = d.laps or 0     -- goal stars touched
  d.clear_t = d.clear_t or 0

  level.build()
  player.init()
  audio.init()
  pickups.init()
  build_sky()

  -- dyn: per-frame movers + cube + shadow + pickup verts (render-class
  -- scratch, rebuilt in draw; a named buffer only so the PAL can read it)
  local dyn_size = (74 + movers.max_tris() + pickups.max_tris()) * 72
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
    rig.reset(cam, state.doc.knobs.cam, px, py, pz, player.yaw())
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
    if on >= 3 then
      d.demo_wp = 1
      d.demo_hold = 0
    end
  else
    d.demo = 0
  end
end

local ACTIONS = { "left", "right", "up", "down", "jump" }

-- demo(3)/(4): scripted routes as waypoints { x, z, jump?, wait? } — steer
-- straight at the current one (world-space wish, no camera in the loop),
-- advance within 0.5u, press jump when LEAVING a jump-flagged point
-- (platform hops; air steering carries to the next point). wait = a pure
-- predicate: on reaching the point the demo STANDS (doc.demo_hold, so a
-- mover can carry it anywhere meanwhile) until it passes, then advances.
-- Indices/hold are sim state (doc.demo_wp/demo_hold) so snapshots/traces
-- replay exactly. Mantle walks the stairs; walk-offs fall home.
local ROUTE3 = {
  { 12.65, 18 },         -- up the stair run (mantle does the climbing)
  { 16.0, 17.0 },        -- onto the keep roof, angling for the edge
  { 17.5, 14.6, true },  -- roof edge: hop to platform 1
  { 17.5, 12.5 },        -- platform 1
  { 16.3, 11.3, true },  -- p1 corner: hop to platform 2
  { 14.5, 8.5 },         -- platform 2
  { 15.8, 7.2, true },   -- p2 corner: hop to platform 3
  { 18.5, 4.5 },         -- platform 3
  { 19.7, 4.5, true },   -- p3 edge: the gap to the goal tower
  { 23.5, 4.5 },         -- tower top: the star (lap!)
  { 26.5, 11 },          -- walk off the tower, fall home
  { 4, 18 },             -- the spawn plaza; wraps to 1
}

-- demo(4) wait predicates read the same mover positions the step collides
-- with (frame+1 = player.step's post-step boxes)
local function lift_docked()
  return movers.box(1, state.frame() + 1)[5] <= 0.6
end
local function lift_risen()
  return movers.box(1, state.frame() + 1)[5] >= 5.4
end
local function ferry_at_keep() -- flush with the keep north face (z 22)
  return movers.box(2, state.frame() + 1)[3] <= 22.06
end
local function ferry_at_wall() -- flush with the curtain wall (z 25.55)
  return movers.box(2, state.frame() + 1)[6] >= 25.49
end

-- demo(4): the mover tour — ride the tower lift to the dome, leap to the
-- goal star, then ferry from the keep roof to the curtain-wall walk
local ROUTE4 = {
  { 10, 12 },                          -- south of the stair run
  { 24, 12 },                          -- past the keep, toward the tower
  { 30, 13.8, wait = lift_docked },    -- shaft side: wait for the lift
  { 30.8, 11.25, true, wait = lift_risen }, -- board (mantle), edge toward
                                       -- the shaft gem, ride to the top
  { 30.6, 9.2 },                       -- flight guide: land on the shoulder
  { 28.6, 9.8 },                       -- west along the shoulder north rim
  { 28.2, 6.2, true },                 -- SW rim: the short leap to the tower
  { 23.5, 4.5 },                       -- the goal star (lap!)
  { 26.5, 11 },                        -- off the tower, fall home
  { 10, 12 },                          -- back along the keep's south side
  { 4, 18 },                           -- the spawn plaza, west of the stairs
  { 12.65, 18 },                       -- up the stairs (mantle)
  { 15, 20.8, wait = ferry_at_keep },  -- keep roof NW: wait for the ferry
  { 15, 23.2, wait = ferry_at_wall },  -- walk on (flush tops), ride across
  { 1.5, 26 },                         -- step off onto the wall top
  { -0.5, 26 },                        -- the wall-walk gem
  { -2, 24 },                          -- hop down off the wall
  { 2, 18 },                           -- home; wraps to 1
}

local function route_ctl(route)
  local d = state.doc
  local px, py, pz = player.pos()
  local wp = route[d.demo_wp]
  local dx, dz = wp[1] - px, wp[2] - pz
  local dist = m.sqrt(dx * dx + dz * dz)
  local jump = false
  -- reaching a wait waypoint holds (doc.demo_hold): stand — a mover may
  -- carry us anywhere meanwhile — until the predicate passes, then advance
  if d.demo_hold == 1 or dist < 0.5 then
    if wp.wait and not wp.wait(px, py, pz) then
      d.demo_hold = 1
      return { wishx = 0, wishz = 0, jump_pressed = false }
    end
    d.demo_hold = 0
    jump = wp[3] or false
    d.demo_wp = d.demo_wp % #route + 1
    wp = route[d.demo_wp]
    dx, dz = wp[1] - px, wp[2] - pz
    dist = m.sqrt(dx * dx + dz * dz)
  end
  if dist > 1e-4 then dx, dz = dx / dist, dz / dist else dx, dz = 0, 0 end
  return { wishx = dx, wishz = dz, jump_pressed = jump }
end

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
  if d.demo >= 3 then -- world-space waypoint routes, no camera
    return route_ctl(d.demo == 3 and ROUTE3 or ROUTE4)
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
    -- cm.move (D097): the left stick verbatim when deflected, else the
    -- digital keys — keys() is the same integer sums as the old block,
    -- so recorded traces (zero axes) replay bit-exact; a live pad now
    -- steers for free (rig.wish normalizes either)
    local sx, sy = move.stick(1)
    if sx ~= 0 or sy ~= 0 then
      fwd, side = -sy, sx
    else
      local ix, iy = move.keys()
      fwd, side = -iy, ix
    end
    jump_pressed = input.pressed("jump")
  end
  local wishx, wishz = rig.wish(cam, fwd, side)
  return { wishx = wishx, wishz = wishz, jump_pressed = jump_pressed }
end

function game.step()
  W, H = input.game_size()
  player.step(build_ctl())
  pickups.step()
  -- the orbit-follow rig (cm.rig, D3D-028): orbit/focus state in bounce.cam
  local px, py, pz = player.pos()
  local vx, _, vz = player.vel()
  rig.step(cam, state.doc.knobs.cam, px, py, pz, vx, vz, player.yaw())
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
  W, H = input.game_size()
  pal.begin_frame(0, 0, 0, 1)

  -- the N64 presentation: 5551+Bayer grade baked into the internal target
  -- (pixel goldens see it) + the VI-soft present blit (composite only).
  -- Both are per-frame opt-ins, so knob changes take effect live.
  local kl = state.doc.knobs.look
  if kl.quant > 0 then pal.x_grade{ quant = kl.quant } end
  if kl.soft > 0 then pal.x_soft(1) end

  -- sky: NDC passthrough gradient (fog off)
  pal.x_view3d()
  pal.x_tris(0, skybuf, 2, 0, 0)

  -- camera position derives from the orbit state (cm.rig.view: godot
  -- OrbitOffset + ScaleFramingWithDistance; render-class)
  local view = rig.view(cam, state.doc.knobs.cam)
  local proj = m4.persp(FOVY, W / H, ZN, ZF)
  local fog = level.fog
  pal.x_view3d{
    mvp = m4.mul(proj, view),
    fog_start = fog.s, fog_end = fog.e, fog = fog.col, fog_on = fog.on,
  }

  for _, s in ipairs(level.segs) do
    pal.x_tris(s.tex, level.vbuf, s.count, s.off, 0)
  end

  -- movers + the cube + pickups (opaque), then the blend pass: blob
  -- shadow + pickup pop ghosts (no depth write, after all opaque).
  -- Movers emit at the advanced frame counter — the exact boxes the step
  -- just collided with, so a rider sits flush on what is on screen.
  local frame = state.frame()
  local out = {}
  local msegs = movers.emit(out, frame)
  local ncube = player.emit(out)
  local ngem = pickups.emit(out, frame)
  local nsh = player.emit_shadow(out)
  local nfx = pickups.emit_fx(out, frame)
  dyn:setstr(0, table.concat(out))
  local off = 0
  for _, s in ipairs(msegs) do
    pal.x_tris(level.tex[s.mat], dyn, s.n, off, 0); off = off + s.n * 72
  end
  pal.x_tris(0, dyn, ncube, off, 0); off = off + ncube * 72
  if ngem > 0 then pal.x_tris(0, dyn, ngem, off, 0) end
  off = off + ngem * 72
  pal.x_tris(level.tex.shadow, dyn, nsh, off, 4); off = off + nsh * 72
  if nfx > 0 then pal.x_tris(0, dyn, nfx, off, 4) end

  local st = pal.frame_stats()
  text.draw(3, 3, ("bounce  %d tris  frame %d")
            :format(st.tris or 0, frame))
  local d = state.doc
  local score = ("gems %d . laps %d"):format(d.score, d.laps)
  hud.text("tr", 3, 3, score, { r = 1, g = 0.85, b = 0.45 })
  if d.clear_t > 0 then
    -- CLEAR banner: holds, then fades out over its last third
    local kb = d.knobs.goal.banner
    local a = m.min(1, 3 * d.clear_t / kb)
    local msg = "COURSE CLEAR!"
    hud.text("t", 0, H // 3, msg,
             { font = "8x16", r = 1, g = 0.9, b = 0.5, a = a })
  end
  if d.demo ~= 0 then
    local msg = "AUTOPLAY * press any key"
    hud.text("t", 0, 14, msg, { r = 1, g = 0.92, b = 0.6, a = 0.95 })
  end
  hud.text("bl", 3, 3, "wasd move . space jump . arrows/drag camera . wheel zoom . c recenter")
end

return game
