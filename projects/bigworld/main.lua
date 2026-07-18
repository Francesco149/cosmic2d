-- bigworld main.lua — the STREAMING STRESS DEMO (COSMIC3D.md §10, the §8e
-- directive): the mascot in a 2048x2048u world that is never resident —
-- ground is a pure function, chunks page render-class under a gen budget,
-- ~4000 entities live in one buffer with closed-form far state, and THE
-- GLIDER (jump in the air to deploy, jump again to drop) is the
-- fast-travel instrument that stresses all of it.
--
-- Controls (openworld's scheme + the glider): wasd move · space jump /
-- deploy / drop · arrows camera · mouse drag look · wheel zoom · c
-- recenter · ` console. game.demo(1) = ground tour ring; game.demo(2) =
-- the hop-glide soak (jump, deploy, soar until touchdown, again —
-- crosses chunk rows forever; the streaming golden's route).
--
-- Honesty overrides (render-class, for the §10 proof that the sim never
-- sees chunks): _G.BW_RES / _G.BW_BUDGET / _G.BW_DRAW override the
-- stream knobs in draw only — a recorded trace must verify byte-identical
-- under ANY override values.

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
local ents = cm.require("ents")
local audio = cm.require("audio")

local W, H = pal.gfx_size()
local FOVY, ZN, ZF = 55, 0.3, 170

local game = select(2, ...) or {}
game.world = world -- console reach
game.ents = ents

local KNOBS = {
  move = { -- the openworld feel-approved kernel + the glider
    cw = 0.9, ch = 1.6,
    speed = 6.5, accel = 40, fric = 30, air_accel = 20, air_fric = 4,
    jump_h = 1.9, jump_apex_t = 22, fall_mul = 1.5, fall_max = 22,
    coyote = 6, buffer = 5, turn = 0.25,
    snap = 0.45,
    stride = 2.0,
    swim_depth = 1.05, float_depth = 0.95,
    swim_speed = 3.4, swim_accel = 16, swim_fric = 8,
    buoy = 24, wdrag = 3.5, paddle = 0.55,
    -- the glider (§8e: "a fast-travel method to stress-test streaming")
    glide_speed = 26,  -- ~4x run: a chunk row every ~1.2s
    glide_accel = 18,  -- lateral build toward glide_speed
    glide_fall = 1.1,  -- sink rate while deployed
    glide_grav = 30,   -- how fast the fall flattens after deploy
    glide_turn = 0.05, -- steering while deployed (wide, soaring arcs)
  },
  cam = { -- the godot FollowCamera rig (openworld values)
    dist = 8.5, height = 3.4, look_h = 1.3,
    min_dist = 4, max_dist = 15, wheel_step = 0.8,
    pos_lerp = 0.10,
    yaw_follow = 0.16, yaw_lerp = 0.04, min_speed = 1.5,
    orbit = 0.045,
    mouse_yaw = 0.012, mouse_pitch = 0.010, key_pitch = 0.025,
    pitch_min = -0.6, pitch_max = 0.95,
    recenter_lerp = 0.25, hold_frames = 42,
    back_cone = 0.35,
  },
  feel = {
    stretch = 0.32, squash = 0.42, vref = 12,
    squash_frames = 10, lean = 0.12,
    walk_ref = 2.2, idle_f = 120,
    swim_tilt = 0.30,
    glide_tilt = 1.0, -- near-prone: the superman read
  },
  ents = { -- the population (ents.lua)
    promote_r = 20,  -- inside this the closed-form walker goes interactive
    demote_r = 24,   -- ...and past this it drops back (hysteresis)
    greet_r = 4.2, exit_r = 5.6, hold = 150,
    wave_f = 44, blend_f = 14, turn = 0.10,
    cw = 1.15, ch = 1.7, stop_r = 1.6,
  },
  stream = { -- the pager (render-class: draw reads these, the sim never)
    res_r = 5,    -- resident ring radius, chunks
    draw_d = 120, -- submit radius, world units
    budget = 1,   -- chunk generations per frame
  },
  look = { quant = 5, soft = 1 },
}

local cam, dyn, skybuf, dyn_cap

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
  skybuf = pal.buf("rc.bw.sky", 6 * 24)
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

  world.build()
  player.init()
  ents.init()
  audio.init()
  build_sky()

  -- dyn: figures + shadows sized from a real mascot emission (near cap +
  -- the player, plus the far-totem field and slack)
  local probe = {}
  local mtris = player.emit(probe)
  dyn_cap = mtris * 26 + 18 * 320 + 2 * 30 + 512
  local ok, db = pcall(pal.buf, "rc.bw.dyn", dyn_cap * 72)
  if not ok then
    pal.buf_free("rc.bw.dyn")
    db = pal.buf("rc.bw.dyn", dyn_cap * 72)
  end
  dyn = db

  -- ow.cam layout (f32): [0]yaw [4]pitch [8]dist [12/16/20]focus xyz
  -- [24]manual-hold frames [28/32]prev cursor [36]recentering flag
  local ok2, cb = pcall(pal.buf, "bw.cam", 40)
  if not ok2 then
    pal.buf_free("bw.cam")
    cb = pal.buf("bw.cam", 40)
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

-- demo(1): the ground tour — a waypoint ring on the spawn plain (probed
-- headlessly against the world function: every leg walkable, see the
-- probe note in STATUS r17). demo(2): the hop-glide soak — hold a fixed
-- heading; jump when grounded, deploy at the arc's fall, soar until
-- touchdown, repeat. The heading is probed for open plains.
local ROUTE = { -- hexagon r~14 on the spawn plain, h 2.9..3.6 (probed)
  { 1037, 1029 }, { 1030, 1041 }, { 1016, 1041 },
  { 1009, 1029 }, { 1016, 1017 }, { 1030, 1017 },
}
-- probed: mostly plains, gentle slopes, ~5% water (the swims are part of
-- the show — a lake crossing swaps hop-glide for the paddle and back)
local GLIDE_HEADING = { x = -0.7071, z = 0.7071 }

local function route_ctl()
  local d = state.doc
  local px, _, pz = player.pos()
  local wp = ROUTE[d.demo_wp]
  local dx, dz = wp[1] - px, wp[2] - pz
  local dist = m.sqrt(dx * dx + dz * dz)
  if dist < 0.8 then
    d.demo_wp = d.demo_wp % #ROUTE + 1
    wp = ROUTE[d.demo_wp]
    dx, dz = wp[1] - px, wp[2] - pz
    dist = m.sqrt(dx * dx + dz * dz)
  end
  if dist > 1e-4 then dx, dz = dx / dist, dz / dist else dx, dz = 0, 0 end
  local rel = state.frame() - d.demo_t0
  return { wishx = dx, wishz = dz, jump_pressed = rel % 150 == 5 }
end

local function glide_ctl()
  -- the hop-glide: press jump on the ground (launch), press again at the
  -- arc's top (deploy), then hold course; touchdown stows and the next
  -- ground frame launches again. Presses are edges, so alternate frames.
  local rel = state.frame() - state.doc.demo_t0
  local _, vy = player.vel()
  local press = false
  if player.gliding() then
    press = false
  elseif rel % 2 == 0 then
    local px, py, pz = player.pos()
    local grounded_ish = py - world.ground(px, pz) < 0.05
    if grounded_ish then
      press = true -- launch
    elseif vy < -0.5 then
      press = true -- deploy on the way down
    end
  end
  return { wishx = GLIDE_HEADING.x, wishz = GLIDE_HEADING.z,
           jump_pressed = press }
end

local ACTIONS = { "left", "right", "up", "down", "jump" }

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
  if d.demo == 1 then
    return route_ctl()
  elseif d.demo == 2 then
    return glide_ctl()
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
  W, H = input.game_size()
  player.step(build_ctl(), ents.boxes())
  ents.step() -- after the player: greets read this step's position
  -- the orbit-follow rig (cm.rig, D3D-028): orbit/focus state in bw.cam
  local px, py, pz = player.pos()
  local vx, _, vz = player.vel()
  rig.step(cam, state.doc.knobs.cam, px, py, pz, vx, vz, player.yaw())
  if DBG and state.frame() % (tonumber(DBG) or 10) == 0 then
    local px, py, pz = player.pos()
    local vx, vy, vz = player.vel()
    local near, total = ents.count()
    print(("DBG f=%d p=%.2f,%.2f,%.2f v=%.2f,%.2f,%.2f g=%.2f gl=%d ents=%d/%d"):format(
      state.frame(), px, py, pz, vx, vy, vz, world.ground(px, pz),
      player.gliding() and 1 or 0, near, total))
  end
end

function game.draw()
  W, H = input.game_size()
  pal.begin_frame(0, 0, 0, 1)

  gb.sun, gb.ambient = world.sun, world.ambient

  local kl = state.doc.knobs.look
  if kl.quant > 0 then pal.x_grade{ quant = kl.quant } end
  if kl.soft > 0 then pal.x_soft(1) end

  -- sky: NDC passthrough gradient (fog off)
  pal.x_view3d()
  pal.x_tris(0, skybuf, 2, 0, 0)

  local kc = state.doc.knobs.cam
  local ks = state.doc.knobs.stream
  -- the honesty overrides (§10): render-class only, traces must not care
  local res_r = _G.BW_RES or ks.res_r
  local budget = _G.BW_BUDGET or ks.budget
  local draw_d = _G.BW_DRAW or ks.draw_d

  -- camera position derives from the orbit state (cm.rig.view, render-class);
  -- the focus xz feeds paging/submit/entity emit below
  local view = rig.view(cam, kc)
  local fx, fz = cam:f32(12), cam:f32(20)
  local proj = m4.persp(FOVY, W / H, ZN, ZF)
  local fog = world.fog
  pal.x_view3d{
    mvp = m4.mul(proj, view),
    fog_start = fog.s, fog_end = fog.e, fog = fog.col, fog_on = fog.on,
  }

  -- page + submit the streamed chunks (opaque); water offsets collect
  -- for the blend pass below
  local res_n = world.page(fx, fz, res_r, budget)
  local water = {}
  local chunk_tris = world.submit(fx, fz, draw_d, water)

  -- figures (player + entities), then blend: shadows, then water LAST
  local out = {}
  local nfig = player.emit(out) + ents.emit(out, fx, fz, draw_d)
  local nsh = player.emit_shadow(out) + ents.emit_shadow(out)
  if nfig + nsh > dyn_cap then -- never overrun the dyn buffer
    pal.log(("bigworld: dyn overflow %d > %d"):format(nfig + nsh, dyn_cap))
  else
    dyn:setstr(0, table.concat(out))
    pal.x_tris(0, dyn, nfig, 0, 0)
    pal.x_tris(world.tex.shadow, dyn, nsh, nfig * 72, 4)
  end
  for _, c in ipairs(water) do
    pal.x_tris(0, c.buf, c.water_n, c.water_off, 4)
  end

  local st = pal.frame_stats()
  local frame = state.frame()
  text.draw(3, 3, ("bigworld  %d tris  frame %d"):format(st.tris or 0, frame))
  local near, total = ents.count()
  local counter = ("res %d  gen %d  ents %d/%d"):format(
    res_n, world.gen_count, near, total)
  hud.text("tr", 3, 3, counter)
  if player.gliding() then
    local msg = "~ gliding ~"
    hud.text("t", 0, 24, msg, { r = 0.75, g = 0.92, b = 1, a = 0.9 })
  end
  if state.doc.demo ~= 0 then
    local msg = "AUTOPLAY * press any key"
    hud.text("t", 0, 14, msg, { r = 1, g = 0.92, b = 0.6, a = 0.95 })
  end
  hud.text("bl", 3, 3, "wasd move . space jump/glide . arrows/drag camera . wheel zoom . c recenter")
end

return game
