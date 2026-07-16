-- player — the bouncy cube (demo 1's movement slice): camera-relative
-- run, fixed-apex jump (the D029 curve, smoke's math in world units),
-- squash & stretch + lean straight from proto draw_bouncy_cube. Every feel
-- value is a live knob (doc.knobs.move/feel, main.lua).
--
-- Determinism: all sim state in the named buffer bounce.player; cm.math
-- trig; fixed dt; collisions are pure-IEEE AABB sweeps vs level.colliders.
-- draw() only reads sim state and emits render-class vertex bytes.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local gb = cm.require("gb")
local m4 = cm.require("cm.m4")
local level = cm.require("level")
local audio = cm.require("audio")

local M = {}

local DT = 1.0 / 60.0

-- named-buffer layout (f32), shared source of truth for step/draw
local O = {
  x = 0, y = 4, z = 8, vx = 12, vy = 16, vz = 20,
  yaw = 24, grounded = 28, coyote = 32, jbuf = 36,
  squash_t = 40, squash_amt = 44, lean = 48,
}
local SIZE = 52

local buf

function M.init()
  local ok, b = pcall(pal.buf, "bounce.player", SIZE)
  if not ok then -- layout grew across a hot reload
    pal.buf_free("bounce.player")
    b = pal.buf("bounce.player", SIZE)
  end
  buf = b
  if buf:f32(O.x) == 0 and buf:f32(O.z) == 0 and buf:f32(O.y) == 0 then
    buf:f32(O.x, level.spawn.x)
    buf:f32(O.y, level.spawn.y)
    buf:f32(O.z, level.spawn.z)
    buf:f32(O.yaw, m.pi / 2) -- face +x, toward the stair run
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

local function approach(v, target, step)
  if v < target then return m.min(v + step, target) end
  return m.max(v - step, target)
end

local function overlaps(b, x, y, z, hw, hh)
  return x + hw > b[1] and x - hw < b[4]
     and y + hh > b[2] and y < b[5]
     and z + hw > b[3] and z - hw < b[6]
end

-- ctl: wishx/wishz (camera-relative unit move vector or 0,0),
--      jump_pressed (edge)
function M.step(ctl)
  local k = state.doc.knobs.move
  local feel = state.doc.knobs.feel

  local hw, hh = k.cw / 2, k.ch

  -- the fixed-apex jump curve (D029): apex height jump_h units reached in
  -- apex_t frames sets rise gravity + takeoff impulse; falls are heavier.
  local apex_t = m.max(k.jump_apex_t, 1.0)
  local g_rise = 2.0 * k.jump_h * 3600.0 / (apex_t * apex_t)
  local v0 = 2.0 * k.jump_h * 60.0 / apex_t

  local x, y, z = buf:f32(O.x), buf:f32(O.y), buf:f32(O.z)
  local vx, vy, vz = buf:f32(O.vx), buf:f32(O.vy), buf:f32(O.vz)
  local yaw = buf:f32(O.yaw)
  local grounded = buf:f32(O.grounded) == 1.0
  local coyote, jbuf = buf:f32(O.coyote), buf:f32(O.jbuf)
  local squash_t = buf:f32(O.squash_t)
  local squash_amt = buf:f32(O.squash_amt)
  local lean = buf:f32(O.lean)

  -- horizontal: accelerate toward the wish direction, brake to a stop
  local wx, wz = ctl.wishx, ctl.wishz
  local moving = wx ~= 0 or wz ~= 0
  if moving then
    local a = (grounded and k.accel or k.air_accel) * DT
    vx = approach(vx, wx * k.speed, a)
    vz = approach(vz, wz * k.speed, a)
    -- turn toward the input heading, shortest arc
    local target = m.atan2(wx, wz)
    local d = target - yaw
    d = m.atan2(m.sin(d), m.cos(d))
    yaw = yaw + d * k.turn
  else
    local f = (grounded and k.fric or k.air_fric) * DT
    vx = approach(vx, 0, f)
    vz = approach(vz, 0, f)
  end

  -- jump: buffered press + coyote window
  if ctl.jump_pressed then jbuf = k.buffer end
  if grounded then coyote = k.coyote end
  if jbuf > 0 and coyote > 0 then
    vy = v0
    jbuf, coyote = 0, 0
    grounded = false
    audio.sfx("jump", 96)
  end
  jbuf = m.max(0, jbuf - 1)
  coyote = m.max(0, coyote - 1)

  -- gravity: rise slope while ascending, heavier fall, terminal clamp
  vy = vy - (vy > 0 and g_rise or g_rise * k.fall_mul) * DT
  vy = m.max(vy, -k.fall_max)

  -- collide axis-by-axis against the level AABBs. The clamp face comes
  -- from WHICH SIDE THE PLAYER WAS ON pre-move, never from the velocity
  -- sign: velocity zeroes on the first hit, and a sign-based clamp then
  -- snapped later overlaps to the wrong face — walking into a
  -- narrower-than-the-player pocket teleported across the far box.
  -- A pre-move overlap on the same axis (squeezed) clamps nothing here;
  -- another axis or the next frame resolves it.
  --
  -- EPS: the side tests MUST tolerate float noise. A clamp stores
  -- face-hw in the f32 buffer; (face-hw)+hw can round PAST the face, and
  -- an exact test then reads the flush player as "squeezed" — one frame
  -- later it is sliding INTO the box (the stair phase-through / one-axis
  -- pillar bug). 1e-3 is far above f32 noise, far below a frame of motion.
  local EPS = 1e-3
  local C = level.colliders

  -- mantle: a blocked step whose top is within step_h of the feet lifts
  -- the player instead (stairs are WALKED, jumps are for gaps) — if the
  -- body fits standing there. Grounded only: no mid-air wall-climbing.
  local function mantle_top(b, px_, pz_)
    if not grounded then return nil end
    local lift = b[5] - y
    if lift <= 0 or lift > k.step_h then return nil end
    for _, o in ipairs(C) do
      if overlaps(o, px_, b[5] + EPS, pz_, hw, hh) then return nil end
    end
    return b[5]
  end

  local nx = x + vx * DT
  for _, b in ipairs(C) do
    if overlaps(b, nx, y, z, hw, hh) then
      if x + hw <= b[1] + EPS or x - hw >= b[4] - EPS then
        local top = mantle_top(b, nx, z)
        if top then
          y = top -- step up, keep the run
        elseif x + hw <= b[1] + EPS then
          nx = b[1] - hw
          vx = 0
        else
          nx = b[4] + hw
          vx = 0
        end
      end
    end
  end
  x = nx
  local nz = z + vz * DT
  for _, b in ipairs(C) do
    if overlaps(b, x, y, nz, hw, hh) then
      if z + hw <= b[3] + EPS or z - hw >= b[6] - EPS then
        local top = mantle_top(b, x, nz)
        if top then
          y = top
        elseif z + hw <= b[3] + EPS then
          nz = b[3] - hw
          vz = 0
        else
          nz = b[6] + hw
          vz = 0
        end
      end
    end
  end
  z = nz
  local ny = y + vy * DT
  local landed = false
  for _, b in ipairs(C) do
    if overlaps(b, x, ny, z, hw, hh) then
      if vy <= 0 and y >= b[5] - EPS then -- feet were at/above: land
        ny = b[5]
        landed = true
        -- a real landing (not the grounded re-collide, ~0.7/frame) squashes
        if vy < -2 then
          squash_amt = feel.squash * m.min(1, -vy / feel.vref)
          squash_t = feel.squash_frames
          audio.sfx("land", m.min(127, (64 - vy * 4) // 1))
        end
        vy = 0
      elseif vy > 0 and y + hh <= b[2] + EPS then -- head was below: bonk
        ny = b[2] - hh
        vy = 0
      end
    end
  end
  y = ny
  grounded = landed

  -- kill plane: off the world edge (the ground collider is finite) -> back
  -- to spawn with a landing squash, so falls read as a reset, not a glitch
  if y < k.kill_y then
    x, y, z = level.spawn.x, level.spawn.y, level.spawn.z
    vx, vy, vz = 0, 0, 0
    squash_amt = feel.squash
    squash_t = feel.squash_frames
    grounded = true
    audio.sfx("hit")
  end

  squash_t = m.max(0, squash_t - 1)

  -- lean into the run (proto's lean param, here pitch toward the heading)
  local hspeed = m.sqrt(vx * vx + vz * vz)
  local ltarget = feel.lean * m.min(1, hspeed / k.speed)
  lean = lean + (ltarget - lean) * 0.2

  buf:f32(O.x, x); buf:f32(O.y, y); buf:f32(O.z, z)
  buf:f32(O.vx, vx); buf:f32(O.vy, vy); buf:f32(O.vz, vz)
  buf:f32(O.yaw, yaw)
  buf:f32(O.grounded, grounded and 1 or 0)
  buf:f32(O.coyote, coyote); buf:f32(O.jbuf, jbuf)
  buf:f32(O.squash_t, squash_t); buf:f32(O.squash_amt, squash_amt)
  buf:f32(O.lean, lean)
end

-- proto draw_bouncy_cube's part list: body + eyes/pupils/mouth on +z
local BODY = { 0.92, 0.34, 0.30 }
local WHITE = { 0.95, 0.95, 0.92 }
local DARK = { 0.08, 0.07, 0.10 }
local PARTS = {
  { { 1.0, 1.0, 1.0 }, { 0, 0.5, 0 }, BODY },
  { { 0.20, 0.30, 0.03 }, { -0.20, 0.62, 0.50 }, WHITE },
  { { 0.20, 0.30, 0.03 }, { 0.20, 0.62, 0.50 }, WHITE },
  { { 0.10, 0.16, 0.03 }, { -0.17, 0.58, 0.52 }, DARK },
  { { 0.10, 0.16, 0.03 }, { 0.17, 0.58, 0.52 }, DARK },
  { { 0.26, 0.05, 0.03 }, { 0.0, 0.30, 0.51 }, DARK },
}

-- emit the cube (squash/stretch from live sim state) into out[]; returns
-- tri count. Render-class: reads the buffer, never writes it.
function M.emit(out)
  local feel = state.doc.knobs.feel
  local x, y, z = buf:f32(O.x), buf:f32(O.y), buf:f32(O.z)
  local vy = buf:f32(O.vy)
  local grounded = buf:f32(O.grounded) == 1.0

  local s = 1.0
  if not grounded then
    s = 1 + feel.stretch * m.min(1, m.abs(vy) / feel.vref)
  elseif buf:f32(O.squash_t) > 0 then
    s = 1 - buf:f32(O.squash_amt) * (buf:f32(O.squash_t) / feel.squash_frames)
  end
  local sxz = 1 / m.sqrt(s) -- volume-ish preserving (proto)

  local rot = m4.mul(m4.roty(buf:f32(O.yaw)), m4.rotx(buf:f32(O.lean)))
  local root = m4.mul(m4.translate(x, y, z), m4.mul(rot, m4.scale(sxz, s, sxz)))
  for _, p in ipairs(PARTS) do
    gb.gbox(out, root, p[1], p[2], p[3], 0.5, rot)
  end
  return #PARTS * 12
end

-- blob shadow quad on the surface below (blend segment, drawn after
-- opaque); fades with fall height. Returns tri count.
function M.emit_shadow(out)
  local x, y, z = buf:f32(O.x), buf:f32(O.y), buf:f32(O.z)
  local gy = level.ground_below(x, z, y) + 0.03
  -- gentle height fade only: the blob is the landing-target cue, most
  -- needed high up (proto uses a constant 0.5)
  local a = (127 * m.clamp(1 - (y - gy) / 16, 0.4, 1)) // 1
  local white = { 1, 1, 1 } -- the texture carries the darkness
  local r = 0.9
  gb.quad(out, { x - r, gy, z - r, 0, 0 }, { x + r, gy, z - r, 1, 0 },
          { x + r, gy, z + r, 1, 1 }, { x - r, gy, z + r, 0, 1 },
          white, 0, 0, 0, a)
  return 2
end

return M
