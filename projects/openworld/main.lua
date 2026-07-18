-- openworld main.lua — demo 2's playable seed: THE MASCOT (locked in
-- 2026-07-17) running and jumping over a cm.terr heightfield in the proto
-- scene_openworld look (Body-Harvest vertex-color bands, water basins,
-- cone trees), every feel value a live knob (the bounce KNOBS pattern).
--
-- Controls (bounce's exact scheme): wasd move (camera-relative) · space
-- jump · arrows = camera yaw/pitch · mouse drag = look · wheel = zoom ·
-- c recenter · ` console (game.demo(1) = autoplay wander for screenshots
-- and the golden trace).
--
-- Camera: the godot FollowCamera rig verbatim from bounce (feel-approved
-- there; one cartridge = one copy stays the rule until a third user
-- promotes it engine-side). Determinism: sim state in named buffers
-- (ow.player/ow.cam) + doc tree; cm.math trig; fixed dt; draw only reads.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local rig = cm.require("cm.rig")
local move = cm.require("cm.move")
local hud = cm.require("cm.hud")
local world = cm.require("world")
local player = cm.require("player")
local npc = cm.require("npc")
local stars = cm.require("stars")
local audio = cm.require("audio")

local W, H = pal.gfx_size()
local FOVY, ZN, ZF = 55, 0.3, 160

local game = select(2, ...) or {}
game.world = world -- console reach

local KNOBS = {
  move = { -- the bounce feel-approved kernel + terrain-ground extras
    cw = 0.9, ch = 1.6, -- collider vs tree trunks (mascot ~1.9u tall)
    speed = 6.5, accel = 40, fric = 30, air_accel = 20, air_fric = 4,
    jump_h = 1.9, jump_apex_t = 22, fall_mul = 1.5, fall_max = 22,
    coyote = 6, buffer = 5, turn = 0.25,
    snap = 0.45,  -- downhill glue window (walk-offs bigger than this fall)
    stride = 2.0, -- world units per walk cycle (the distance-driven phase)
    -- deep water swims (D3D-019); depth <= swim_depth stays wading
    swim_depth = 1.05,  -- water deeper than this under the feet = swim
    float_depth = 0.95, -- the feet ride this far below the surface
    swim_speed = 3.4, swim_accel = 16, swim_fric = 8,
    buoy = 24,     -- buoyancy spring to the float line (the surface bob)
    wdrag = 3.5,   -- vertical water drag (settles the bob)
    paddle = 0.55, -- paddle-hop launch, fraction of the jump's v0
  },
  cam = { -- the godot FollowCamera/CameraTuning knob set (bounce values,
          -- pulled back a touch: the mascot is bigger than the cube)
    dist = 8.5, height = 3.4, look_h = 1.3,
    min_dist = 4, max_dist = 15, wheel_step = 0.8,
    pos_lerp = 0.10,
    yaw_follow = 0.16,
    yaw_lerp = 0.04,
    min_speed = 1.5,
    orbit = 0.045,
    mouse_yaw = 0.012, mouse_pitch = 0.010,
    key_pitch = 0.025,
    pitch_min = -0.6, pitch_max = 0.95,
    recenter_lerp = 0.25, hold_frames = 42,
    back_cone = 0.35, -- heading within this of straight-INTO-the-camera
                      -- pauses yaw-follow (the vibration fix, D3D-018)
  },
  feel = {
    stretch = 0.32, squash = 0.42, vref = 12,
    squash_frames = 10, lean = 0.12,
    walk_ref = 2.2, -- ground speed where the walk clip fully takes over
    idle_f = 120,   -- frames per idle breath cycle
    swim_tilt = 0.30, -- forward pitch while swimming (the paddle read)
  },
  npc = { -- the exchange (D3D-020) + the walkers (D3D-023)
    greet_r = 4.2, -- come this close and the exchange begins
    exit_r = 5.6,  -- ...and it ends this far out (hysteresis: no chime spam)
    turn = 0.10,   -- facing ease toward the player / back home
    wave_f = 44,   -- frames per wave cycle
    blend_f = 14,  -- idle->wave blend-in frames
    type_f = 2,    -- frames per typed dialog character
    speed = 2.2,   -- a walker's amble along its route
    arrive = 0.35, -- waypoint arrival radius
    hold = 180,    -- a walker stops this long per greet, then walks on
    -- solid bodies (human verdict 2026-07-17): the collider AABB inside
    -- the round visual (body lathe max r 0.82), and the walker's
    -- won't-plow-through-you radius
    cw = 1.15, ch = 1.7, stop_r = 1.6,
  },
  stars = { -- the wander's goal (stars.lua)
    r = 1.3,        -- pickup radius (3D, vs the mascot's center)
    hover = 0.9,    -- rest height above the ground
    pop = 14,       -- pickup ghost: expand-and-fade frames
    banner = 140,   -- ALL-STARS banner frames
    spin = 0.05,    -- spin, rad/frame (render-class)
    bob = 0.16, bob_f = 80, -- hover bob amplitude (u) / period (frames)
  },
  look = { -- the N64 presentation (D3D-003/015, render-class)
    quant = 5,
    soft = 1,
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
  skybuf = pal.buf("rc.ow.sky", 6 * 24)
  local function sv(x, y, c)
    return string.pack("<fffffBBBB", x, y, 0.9999, 0, 0,
                       (c[1] * 255) // 1, (c[2] * 255) // 1,
                       (c[3] * 255) // 1, 255)
  end
  local t, b = world.sky_top, world.sky_bot
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
  if d.demo_wp == nil then d.demo_wp = 1 end
  d.stars = d.stars or 0   -- stars collected, all time
  d.star_t = d.star_t or 0 -- ALL-STARS banner countdown

  world.build()
  player.init()
  npc.init()
  stars.init()
  audio.init()
  build_sky()

  -- dyn: per-frame figure + shadow + star verts (render-class scratch;
  -- three mascots + three blob shadows + the star field worst-case)
  local dyn_size = (4200 + stars.max_tris()) * 72
  local ok, db = pcall(pal.buf, "rc.ow.dyn", dyn_size)
  if not ok then
    pal.buf_free("rc.ow.dyn")
    db = pal.buf("rc.ow.dyn", dyn_size)
  end
  dyn = db

  -- ow.cam layout (f32): [0]yaw [4]pitch [8]dist [12/16/20]focus xyz
  -- [24]manual-hold frames [28/32]prev cursor [36]recentering flag
  local ok2, cb = pcall(pal.buf, "ow.cam", 40)
  if not ok2 then
    pal.buf_free("ow.cam")
    cb = pal.buf("ow.cam", 40)
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

-- console: game.demo(1) = the autoplay tour — walk the scenic ring around
-- the spawn bowl forever (screenshots and the golden trace); game.demo(3)
-- = the pond crossing (the swim regime on show); game.demo(4) = walk to
-- the pond watcher and stand for the exchange; game.demo(5) = the star
-- sweep — collect all ten stars (ring, banks, the mid-pond swim), end
-- standing by the watcher; game.demo(6) = walk to the flower meadow and
-- stand on the wanderer's loop — it comes around, stops, waves, says its
-- line, and walks on (the lap brings it back); any real press takes back
function game.demo(on)
  local d = state.doc
  if on and on ~= 0 then
    d.demo = on
    d.demo_t0 = state.frame()
    d.demo_wp = 1
  else
    d.demo = 0
  end
end

-- the ring: fixed world waypoints on the grass band around the spawn bowl
-- (terrain is deterministic; every leg verified to stay in h 0.5..3.3 —
-- no wading, no rock climbs). Steering is world-space (no camera in the
-- loop, the bounce ROUTE precedent); the index is sim state (doc.demo_wp)
-- so snapshots/traces replay exactly. A periodic hop keeps the jump arc +
-- squash & stretch on show.
local ROUTE = {
  { 71, 71 }, { 90, 74 }, { 102, 88 }, { 88, 102 }, { 64, 100 },
  { 40, 92 }, { 26, 80 }, { 34, 74 }, { 54, 78 },
}

-- demo(3): the pond crossing — walk the east bank in (splash), swim the
-- deep bowl (the periodic hop becomes a paddle stroke mid-pond), climb
-- the west bank out, loop the north rim home. Every waypoint verified
-- walkable/swimmable against the carved terrain.
local ROUTE_SWIM = {
  { 56, 68 }, { 42, 64 }, { 31, 62 }, { 34, 74 }, { 52, 76 },
}

-- demo(4): the exchange — walk west from the spawn bowl to the pond
-- watcher's bank and STAND (the route holds at its last waypoint instead
-- of wrapping; no periodic hop while held, the dialog is the show)
local ROUTE_NPC = {
  { 64, 71 }, { 58, 71 }, { 55.4, 72.0 },
}

-- demo(5): the star sweep — every leg is a demo(1)/demo(3) leg or its
-- reverse (all verified on the carved terrain): the ring's seven stars,
-- down the west bank, swim the pond star, out the east bank, finish on
-- the watcher's star (the greet fires; the fanfare is the show)
local ROUTE_STARS = {
  { 76, 72 }, { 90, 74 }, { 102, 88 }, { 88, 102 }, { 64, 100 },
  { 40, 92 }, { 26, 80 }, { 34, 74 }, { 31, 62 }, { 42, 64 },
  { 56, 68 }, { 55.4, 72.0 },
}

-- demo(6): the meadow meeting — south from the spawn bowl (east of the
-- z~86-88 tree pair, every leg verified h 0.78..1.68 with >=2u collider
-- clearance) to a stand-spot ON the wanderer's loop; it comes around,
-- greets, walks on, and the next lap greets again
local ROUTE_MEET = {
  { 71, 84 }, { 70.5, 90 }, { 66, 96 },
}

local HOLD_LAST = { [4] = true, [5] = true, [6] = true } -- end standing

local function route_ctl()
  local d = state.doc
  local px, _, pz = player.pos()
  local route = d.demo == 3 and ROUTE_SWIM or d.demo == 4 and ROUTE_NPC
    or d.demo == 5 and ROUTE_STARS or d.demo == 6 and ROUTE_MEET or ROUTE
  local wp = route[d.demo_wp]
  local dx, dz = wp[1] - px, wp[2] - pz
  local dist = m.sqrt(dx * dx + dz * dz)
  if dist < 0.8 then
    if HOLD_LAST[d.demo] and d.demo_wp == #route then -- arrived: stand
      return { wishx = 0, wishz = 0, jump_pressed = false }
    end
    d.demo_wp = d.demo_wp % #route + 1
    wp = route[d.demo_wp]
    dx, dz = wp[1] - px, wp[2] - pz
    dist = m.sqrt(dx * dx + dz * dz)
  end
  if dist > 1e-4 then dx, dz = dx / dist, dz / dist else dx, dz = 0, 0 end
  local rel = state.frame() - d.demo_t0
  return { wishx = dx, wishz = dz, jump_pressed = rel % 150 == 5 }
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
  if d.demo == 2 then -- backup soak: walk INTO the camera forever (the
    -- yaw-follow pole — regression walk for the vibration fix)
    fwd, side, jump_pressed = -1, 0, false
  elseif d.demo ~= 0 then
    return route_ctl()
  else
    -- cm.move (D097): stick verbatim when deflected, else the digital
    -- keys — keys() is the old block's exact integer sums, so recorded
    -- traces (zero axes) replay bit-exact; a live pad steers for free
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
  player.step(build_ctl(), npc.boxes()) -- NPCs are solid (pre-step boxes)
  npc.step() -- after the player: the exchange reads this step's position
  stars.step() -- likewise: pickup tests run on this step's position
  -- the orbit-follow rig (cm.rig, D3D-028): orbit/focus state in ow.cam
  local px, py, pz = player.pos()
  local vx, _, vz = player.vel()
  rig.step(cam, state.doc.knobs.cam, px, py, pz, vx, vz, player.yaw())
  -- feel telemetry: --eval "_G.DBG=10" prints the track every N frames
  if DBG and state.frame() % (tonumber(DBG) or 10) == 0 then
    local px, py, pz = player.pos()
    local vx, vy, vz = player.vel()
    print(("DBG f=%d p=%.3f,%.3f,%.3f v=%.2f,%.2f,%.2f g=%.3f yaw=%.2f stars=%d"):format(
      state.frame(), px, py, pz, vx, vy, vz, world.ground(px, pz), cam:f32(0),
      state.doc.stars))
    for a in npc.each() do
      print(("  npc %d p=%.2f,%.2f yaw=%.2f wp=%d greet %d..%d n=%d"):format(
        a.i, a.x, a.z, a.yaw, a.wp, a.gstart, a.gend, a.greets))
    end
  end
end

function game.draw()
  pal.begin_frame(0, 0, 0, 1)

  -- openworld light on cm.gb every frame (reload-proof): the mascot and
  -- the shadow emit under the same warm sun as the terrain
  gb.sun, gb.ambient = world.sun, world.ambient

  local kl = state.doc.knobs.look
  if kl.quant > 0 then pal.x_grade{ quant = kl.quant } end
  if kl.soft > 0 then pal.x_soft(1) end

  -- sky: NDC passthrough gradient (fog off)
  pal.x_view3d()
  pal.x_tris(0, skybuf, 2, 0, 0)

  -- camera position derives from the orbit state (cm.rig.view, render-class)
  local view = rig.view(cam, state.doc.knobs.cam)
  local proj = m4.persp(FOVY, W / H, ZN, ZF)
  local fog = world.fog
  pal.x_view3d{
    mvp = m4.mul(proj, view),
    fog_start = fog.s, fog_end = fog.e, fog = fog.col, fog_on = fog.on,
  }

  -- static level: terrain (detail-textured) + trees + props
  for _, s in ipairs(world.segs) do
    pal.x_tris(s.tex, world.vbuf, s.count, s.off, 0)
  end

  -- the figures + stars (opaque), then the blend pass: blob shadows,
  -- star pop ghosts, then the water plane LAST so it tints everything
  -- sunk below it
  local out = {}
  local frame = state.frame()
  local nfig = player.emit(out) + npc.emit(out) + stars.emit(out, frame)
  local nsh = player.emit_shadow(out) + npc.emit_shadow(out)
  local nfx = stars.emit_fx(out, frame)
  dyn:setstr(0, table.concat(out))
  pal.x_tris(0, dyn, nfig, 0, 0)
  pal.x_tris(world.tex.shadow, dyn, nsh, nfig * 72, 4)
  pal.x_tris(0, dyn, nfx, (nfig + nsh) * 72, 4)
  pal.x_tris(0, world.vbuf, world.water.count, world.water.off, 4)

  local st = pal.frame_stats()
  text.draw(3, 3, ("openworld  %d tris  frame %d"):format(st.tris or 0, frame))
  -- the star counter, top-right (gold once complete)
  local got, total = stars.count()
  local counter = ("stars %d/%d"):format(got, total)
  hud.text("tr", 3, 3, counter,
           got >= total and { r = 1, g = 0.85, b = 0.35, a = 1 } or nil)
  -- the ALL-STARS banner, fading out (the bounce CLEAR banner read)
  local d = state.doc
  if d.star_t > 0 then
    local kb = d.knobs.stars.banner
    local a = m.min(1, 3 * d.star_t / kb)
    local msg = "ALL THE STARS!"
    hud.text("t", 0, H // 2 - 20, msg, { r = 1, g = 0.85, b = 0.35, a = a })
  end
  -- the exchange line, typing out (centered on the FULL line so the text
  -- doesn't slide while it reveals)
  local line, nch = npc.dialog()
  if line then
    -- hud.place with the FULL line's width: the typed reveal must not
    -- slide (hud.text would measure the substring)
    local lx, ly = hud.place("t", 0, H - 26, text.measure(line), 8, W, H)
    text.draw(lx, ly, line:sub(1, nch),
              { r = 1, g = 0.95, b = 0.72, a = 0.95 })
  end
  if state.doc.demo ~= 0 then
    local msg = "AUTOPLAY * press any key"
    hud.text("t", 0, 14, msg, { r = 1, g = 0.92, b = 0.6, a = 0.95 })
  end
  hud.text("bl", 3, 3, "wasd move . space jump . arrows/drag camera . wheel zoom . c recenter")
end

return game
