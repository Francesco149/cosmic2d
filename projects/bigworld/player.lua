-- player — the mascot in the streaming world: openworld's feel-approved
-- kernel (camera-relative run, D029 fixed-apex jump, terrain landings,
-- k.snap downhill glue, D3D-009/010 clamp rules, the D3D-019 swim regime)
-- with two changes for §10:
--
--   * ground = world.ground, a PURE FUNCTION — no terrain state anywhere,
--     the player walks a world that is never resident;
--   * colliders = world.boxes_near(x, z), derived per step from the
--     per-chunk prop streams — solidity is independent of what the
--     renderer has paged in.
--
-- THE GLIDER (the §8e stress instrument): press jump in the air and the
-- mascot deploys — fall flattens to k.glide_fall, horizontal speed builds
-- toward k.glide_speed along the wish direction (turns are slower,
-- k.glide_turn), and the world streams under you at 4-5x run speed.
-- Press jump again to drop; landing (or deep water) stows it. One buffer
-- field (O.glide); everything else is the same derived-regime pattern as
-- the swim.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local kin = cm.require("cm.kin")
local fig = cm.require("cm.fig")
local mascot = cm.require("cm.mascot")
local world = cm.require("world")
local audio = cm.require("audio")

local M = select(2, ...) or {}

local DT = 1.0 / 60.0

-- named-buffer layout (f32), shared source of truth for step/draw
local O = {
  x = 0, y = 4, z = 8, vx = 12, vy = 16, vz = 20,
  yaw = 24, grounded = 28, coyote = 32, jbuf = 36,
  squash_t = 40, squash_amt = 44, lean = 48, phase = 52,
  glide = 56,
}
local SIZE = 60

local buf

function M.init()
  local ok, b = pcall(pal.buf, "bw.player", SIZE)
  if not ok then -- layout grew across a hot reload
    pal.buf_free("bw.player")
    b = pal.buf("bw.player", SIZE)
  end
  buf = b
  if buf:f32(O.x) == 0 and buf:f32(O.z) == 0 then
    buf:f32(O.x, world.spawn.x)
    buf:f32(O.y, world.spawn.y)
    buf:f32(O.z, world.spawn.z)
    buf:f32(O.yaw, 0)
  end
end

function M.pos()
  return buf:f32(O.x), buf:f32(O.y), buf:f32(O.z)
end

function M.vel()
  return buf:f32(O.vx), buf:f32(O.vy), buf:f32(O.vz)
end

function M.yaw()
  return buf:f32(O.yaw)
end

function M.gliding()
  return buf:f32(O.glide) == 1.0
end

-- the swim regime (D3D-019), derived from the buffer — never stored
function M.swimming()
  local k = state.doc.knobs.move
  local x, y, z = buf:f32(O.x), buf:f32(O.y), buf:f32(O.z)
  return world.water_y - world.ground(x, z) > k.swim_depth
     and y < world.water_y
end

-- ctl: wishx/wishz (camera-relative unit move vector or 0,0),
--      jump_pressed (edge)
-- dyncol: extra AABBs that move (the near entities — main passes
--      ents.boxes()); clamp and land exactly like the prop colliders.
function M.step(ctl, dyncol)
  local k = state.doc.knobs.move
  local feel = state.doc.knobs.feel

  local hw, hh = k.cw / 2, k.ch

  -- the fixed-apex jump curve (D029, bounce's numbers)
  local g_rise, v0 = kin.jump_curve(k.jump_h, k.jump_apex_t)

  local x, y, z = buf:f32(O.x), buf:f32(O.y), buf:f32(O.z)
  local vx, vy, vz = buf:f32(O.vx), buf:f32(O.vy), buf:f32(O.vz)
  local yaw = buf:f32(O.yaw)
  local grounded = buf:f32(O.grounded) == 1.0
  local coyote, jbuf = buf:f32(O.coyote), buf:f32(O.jbuf)
  local squash_t = buf:f32(O.squash_t)
  local squash_amt = buf:f32(O.squash_amt)
  local lean = buf:f32(O.lean)
  local phase = buf:f32(O.phase)
  local glide = buf:f32(O.glide) == 1.0

  -- the swim regime at the step's start: pure derivation
  local wy = world.water_y
  local swim = wy - world.ground(x, z) > k.swim_depth and y < wy
  if swim then glide = false end -- water stows the glider

  -- the glider toggles on a jump press in the air (past the coyote
  -- window, so a late first jump stays a jump), off on a press while
  -- deployed; landing stows it below. The press is consumed either way —
  -- it must not double as a buffered landing jump.
  local jump_pressed = ctl.jump_pressed
  if jump_pressed and glide then
    glide = false
    jump_pressed = false
  elseif jump_pressed and not grounded and coyote <= 0 and not swim then
    glide = true
    jump_pressed = false
    audio.sfx("jump", 60)
  end

  -- horizontal: the glider builds speed along the FACING (the wish only
  -- steers, slower); otherwise cm.kin runs the regime (swim/ground/air).
  local wx, wz = ctl.wishx, ctl.wishz
  if glide then
    -- deployed: no wish = hold course (the fast-travel read: point and soar)
    if wx ~= 0 or wz ~= 0 then
      local d = m.atan2(wx, wz) - yaw
      d = m.atan2(m.sin(d), m.cos(d))
      yaw = yaw + m.clamp(d, -k.glide_turn, k.glide_turn)
    end
    local fx, fz = m.sin(yaw), m.cos(yaw)
    local a = k.glide_accel * DT
    vx = kin.approach(vx, fx * k.glide_speed, a)
    vz = kin.approach(vz, fz * k.glide_speed, a)
  else
    local accel = swim and k.swim_accel or grounded and k.accel or k.air_accel
    local fric = swim and k.swim_fric or grounded and k.fric or k.air_fric
    local sp = swim and k.swim_speed or k.speed
    vx, vz, yaw = kin.run(vx, vz, yaw, wx, wz, sp, accel, fric, k.turn)
  end

  -- jump: buffered press + coyote window; a swim press is the paddle hop.
  -- (jump_pressed was consumed above if it toggled the glider.)
  local jvy, evt
  jvy, jbuf, coyote, grounded, evt = kin.jump(jbuf, coyote, grounded,
    jump_pressed, k.buffer, k.coyote, v0, swim, k.paddle)
  if jvy then vy = jvy end
  if evt == "jump" then audio.sfx("jump", 96)
  elseif evt == "paddle" then audio.sfx("jump", 72) end

  if swim then
    -- buoyancy spring to the float line + water drag: settle with a bob
    vy = vy + (wy - k.float_depth - y) * k.buoy * DT
    vy = vy - vy * k.wdrag * DT
  elseif glide then
    -- deployed: the fall flattens toward the glide sink rate
    vy = kin.approach(vy, -k.glide_fall, k.glide_grav * DT)
  else
    vy = kin.gravity(vy, g_rise, k.fall_mul) -- rise slope / heavier fall
  end
  vy = m.max(vy, -k.fall_max)

  -- collide x then z against the near prop colliders + the near entities
  -- (the D3D-009/010 clamp, in cm.kin) and clamp to the world edge.
  -- boxes_near derives from the pure per-chunk streams — the sim's
  -- colliders exist wherever the player is, resident or not (one call,
  -- shared by both sweeps and the ground-top raise below).
  local sx, sz = world.size()
  local near = world.boxes_near(x, z)

  local nx = m.clamp(x + vx * DT, 2, sx - 2)
  nx, vx = kin.slide(near, true, nx, y, z, x, vx, hw, hh)
  nx, vx = kin.slide(dyncol or {}, true, nx, y, z, x, vx, hw, hh)
  x = nx
  local nz = m.clamp(z + vz * DT, 2, sz - 2)
  nz, vz = kin.slide(near, false, x, y, nz, z, vz, hw, hh)
  nz, vz = kin.slide(dyncol or {}, false, x, y, nz, z, vz, hw, hh)
  z = nz

  -- vertical vs the heightfield + collider tops (kin.ground_top: the
  -- box-top landing rule, feet-at-or-above, EPS per D3D-010)
  local g = world.ground(x, z)
  g = kin.ground_top(near, g, x, y, z, hw)
  g = kin.ground_top(dyncol or {}, g, x, y, z, hw)
  local ny = y + vy * DT
  local landed = false
  if ny <= g then
    local sa, st = kin.land_squash(vy, feel.squash, feel.vref, feel.squash_frames)
    if sa then -- a real landing (a glide touchdown is gentle by design)
      squash_amt, squash_t = sa, st
      audio.sfx("land", m.min(127, (64 - vy * 4) // 1))
    end
    ny = g
    vy = 0
    landed = true
    glide = false -- touchdown stows the glider
  elseif grounded and vy <= 0 and ny - g <= k.snap then
    ny = g
    vy = 0
    landed = true
  end
  y = ny
  grounded = landed

  -- entry splash: the swim regime flipped on across this step
  if not swim and wy - g > k.swim_depth and y < wy then
    audio.sfx("splash", m.min(127, (70 - vy * 5) // 1))
    swim = true
    glide = false
  end

  squash_t = m.max(0, squash_t - 1)

  -- the walk-cycle phase advances with GROUND DISTANCE (no foot sliding)
  local hspeed = m.sqrt(vx * vx + vz * vz)
  if grounded or swim then
    phase = (phase + hspeed * DT / k.stride) % 1
  end

  -- lean into the run (forward pitch on the mascot base)
  lean = kin.lean(lean, hspeed, feel.lean, k.speed)

  buf:f32(O.x, x); buf:f32(O.y, y); buf:f32(O.z, z)
  buf:f32(O.vx, vx); buf:f32(O.vy, vy); buf:f32(O.vz, vz)
  buf:f32(O.yaw, yaw)
  buf:f32(O.grounded, grounded and 1 or 0)
  buf:f32(O.coyote, coyote); buf:f32(O.jbuf, jbuf)
  buf:f32(O.squash_t, squash_t); buf:f32(O.squash_amt, squash_amt)
  buf:f32(O.lean, lean); buf:f32(O.phase, phase)
  buf:f32(O.glide, glide and 1 or 0)
end

-- emit the mascot into out[]; returns tri count. Render-class.
function M.emit(out)
  local k = state.doc.knobs.move
  local feel = state.doc.knobs.feel
  local x, y, z = buf:f32(O.x), buf:f32(O.y), buf:f32(O.z)
  local vx, vz = buf:f32(O.vx), buf:f32(O.vz)
  local vy = buf:f32(O.vy)
  local grounded = buf:f32(O.grounded) == 1.0
  local glide = buf:f32(O.glide) == 1.0
  local f = state.frame()

  local swim = M.swimming()
  local hspeed = m.sqrt(vx * vx + vz * vz)
  local blend = m.min(1, hspeed / feel.walk_ref)
  local pose
  if glide then
    -- deployed: the breaststroke's glide stretch, FROZEN mid-reach — the
    -- superman read — under a strong forward tilt applied below
    pose = fig.cycle(mascot.swim, 0.12)
  else
    pose = fig.mix(fig.cycle(mascot.idle, f / feel.idle_f),
                   fig.cycle(swim and mascot.swim or mascot.walk,
                             buf:f32(O.phase)), blend)
  end

  local s = 1.0
  if swim or glide then -- neutral: the tilt carries the read
  elseif not grounded then
    s = 1 + feel.stretch * m.min(1, m.abs(vy) / feel.vref)
  elseif buf:f32(O.squash_t) > 0 then
    s = 1 - buf:f32(O.squash_amt) * (buf:f32(O.squash_t) / feel.squash_frames)
  end
  local sx, sy, sz = mascot.sq(s)
  local body = pose.body
  body[7], body[8], body[9] = body[7] * sx, body[8] * sy, body[9] * sz
  pose.base[1] = pose.base[1] + buf:f32(O.lean)
  if swim then pose.base[1] = pose.base[1] + feel.swim_tilt end
  if glide then pose.base[1] = pose.base[1] + feel.glide_tilt end

  local root = m4.mul(m4.translate(x, y, z), m4.roty(buf:f32(O.yaw)))
  return fig.emit(out, mascot.fig, root, pose)
end

-- blob shadow, tilted to the local slope; fades with fall height
function M.emit_shadow(out)
  local x, y, z = buf:f32(O.x), buf:f32(O.y), buf:f32(O.z)
  local e, r = 0.6, 1.0
  local gy = world.ground(x, z)
  local dhx = (world.ground(x + e, z) - world.ground(x - e, z)) / (2 * e)
  local dhz = (world.ground(x, z + e) - world.ground(x, z - e)) / (2 * e)
  local a = (127 * m.clamp(1 - (y - gy) / 16, 0.4, 1)) // 1
  local white = { 1, 1, 1 }
  local lift = 0.06
  local function p(dx, dz)
    return { x + dx, gy + lift + dx * dhx + dz * dhz, z + dz }
  end
  local A, B, C, D = p(-r, -r), p(r, -r), p(r, r), p(-r, r)
  gb.quad(out, { A[1], A[2], A[3], 0, 0 }, { B[1], B[2], B[3], 1, 0 },
          { C[1], C[2], C[3], 1, 1 }, { D[1], D[2], D[3], 0, 1 },
          white, 0, 0, 0, a)
  return 2
end

return M
