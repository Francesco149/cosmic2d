-- player — the bouncy cube (demo 1's movement slice): camera-relative
-- run, fixed-apex jump (the D029 curve, smoke's math in world units),
-- squash & stretch + lean straight from proto draw_bouncy_cube. Every feel
-- value is a live knob (doc.knobs.move/feel, main.lua).
--
-- Determinism: all sim state in the named buffer bounce.player; cm.math
-- trig; fixed dt; collisions are pure-IEEE AABB sweeps vs level.colliders
-- plus the movers' frame boxes (movers.lua — riders get carried).
-- draw() only reads sim state and emits render-class vertex bytes.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local gb = cm.require("cm.gb")
local m4 = cm.require("cm.m4")
local kin = cm.require("cm.kin")
local level = cm.require("level")
local movers = cm.require("movers")
local audio = cm.require("audio")

local M = select(2, ...) or {}

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

-- ctl: wishx/wishz (camera-relative unit move vector or 0,0),
--      jump_pressed (edge)
function M.step(ctl)
  local k = state.doc.knobs.move
  local feel = state.doc.knobs.feel

  local hw, hh = k.cw / 2, k.ch

  -- the fixed-apex jump curve (D029): apex height jump_h units reached in
  -- apex_t frames sets rise gravity + takeoff impulse; falls are heavier.
  local g_rise, v0 = kin.jump_curve(k.jump_h, k.jump_apex_t)

  local x, y, z = buf:f32(O.x), buf:f32(O.y), buf:f32(O.z)
  local vx, vy, vz = buf:f32(O.vx), buf:f32(O.vy), buf:f32(O.vz)
  local yaw = buf:f32(O.yaw)
  local grounded = buf:f32(O.grounded) == 1.0
  local coyote, jbuf = buf:f32(O.coyote), buf:f32(O.jbuf)
  local squash_t = buf:f32(O.squash_t)
  local squash_amt = buf:f32(O.squash_amt)
  local lean = buf:f32(O.lean)

  local EPS = kin.EPS

  -- moving platforms: this step collides against the post-step boxes
  -- (frame+1 = what draw shows); a grounded player whose feet sit on a
  -- mover's pre-step top is RIDING and gets carried by the frame delta
  -- before their own move (x/z add, y tracks the top exactly — glued both
  -- up and down, faster than gravity could follow)
  local F = state.frame()
  local mold = movers.boxes(F)
  local mnew = movers.boxes(F + 1)
  if grounded then
    for i, b in ipairs(mold) do
      if m.abs(y - b[5]) <= EPS
         and x + hw > b[1] and x - hw < b[4]
         and z + hw > b[3] and z - hw < b[6] then
        local nb = mnew[i]
        x = x + (nb[1] - b[1])
        z = z + (nb[3] - b[3])
        y = nb[5]
        break
      end
    end
  end

  -- horizontal: accelerate toward the wish direction, brake to a stop
  local accel = grounded and k.accel or k.air_accel
  local fric = grounded and k.fric or k.air_fric
  vx, vz, yaw = kin.run(vx, vz, yaw, ctl.wishx, ctl.wishz, k.speed, accel, fric, k.turn)

  -- jump: buffered press + coyote window (no swim regime in bounce)
  local jvy, evt
  jvy, jbuf, coyote, grounded, evt = kin.jump(jbuf, coyote, grounded,
    ctl.jump_pressed, k.buffer, k.coyote, v0, false)
  if jvy then vy = jvy end
  if evt == "jump" then audio.sfx("jump", 96) end

  -- gravity: rise slope while ascending, heavier fall, terminal clamp
  vy = kin.gravity(vy, g_rise, k.fall_mul)
  vy = m.max(vy, -k.fall_max)

  -- collide axis-by-axis against the level AABBs (the D3D-009/010 clamp,
  -- in cm.kin now). C = static level boxes + the movers' post-step boxes:
  -- movers land, clamp, and mantle exactly like level geometry (walking
  -- into a docked lift mantles you onto it).
  local C = {}
  for i, b in ipairs(level.colliders) do C[i] = b end
  for _, b in ipairs(mnew) do C[#C + 1] = b end

  -- mantle: a blocked step within step_h of the feet lifts you instead
  -- (stairs are WALKED) if the body fits standing there. Grounded only:
  -- pass nil airborne so there is no mid-air wall-climbing; the probe
  -- raises the working feet (cy threads through both axes).
  local mantle = grounded and function(b, px, pz, cy)
    return kin.mantle_top(b, C, px, pz, cy, hw, hh, k.step_h)
  end or nil

  local nx = x + vx * DT
  nx, vx, y = kin.slide(C, true, nx, y, z, x, vx, hw, hh, mantle)
  x = nx
  local nz = z + vz * DT
  nz, vz, y = kin.slide(C, false, x, y, nz, z, vz, hw, hh, mantle)
  z = nz

  -- vertical vs the box tops (land) and bottoms (bonk) — the bounce ground
  -- truth (an axis-aligned world; ow/bw land on a heightfield instead, so
  -- this pass stays in the demo; cm.kin only hands over the land squash).
  local ny = y + vy * DT
  local landed = false
  for _, b in ipairs(C) do
    if kin.overlaps(b, x, ny, z, hw, hh) then
      if vy <= 0 and y >= b[5] - EPS then -- feet were at/above: land
        ny = b[5]
        landed = true
        local sa, st = kin.land_squash(vy, feel.squash, feel.vref, feel.squash_frames)
        if sa then -- a real landing (not the ~0.7/frame grounded re-collide)
          squash_amt, squash_t = sa, st
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
  lean = kin.lean(lean, hspeed, feel.lean, k.speed)

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
  -- movers count as shadow anchors too (riding the lift keeps the blob
  -- underfoot); draw-frame boxes = what is on screen
  local gy = level.ground_below(x, z, y, movers.boxes(state.frame())) + 0.03
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
