-- player — the MASCOT, playable (its promotion round: locked in as the
-- engine mascot 2026-07-17). Movement is the bounce cube's feel-approved
-- kernel (camera-relative run, D029 fixed-apex jump, coyote/buffer,
-- squash & stretch) with the ground swapped from AABB tops to the terrain
-- heightfield: land when the integrated y reaches world.ground(x,z), glue
-- to the slope while walking downhill (k.snap), fall past the glue window
-- (walk-offs still fall). Tree trunks + high-band boulders are the side
-- colliders — the bounce clamp rules (pre-move side decides the face,
-- EPS side tests, D3D-009/010) apply unchanged.
--
-- Deep water swims (D3D-019). The regime is DERIVED, never stored: water
-- deeper than k.swim_depth under the feet + feet below the surface. While
-- swimming: buoyancy springs y to the float line (k.buoy) against water
-- drag (k.wdrag) — it settles with a small bob — horizontal motion runs
-- the swim numbers, and a buffered jump press is a paddle hop (enough to
-- read as a stroke and to help mantle the bank). Shallower water is plain
-- wading. The shore exit is the ordinary landing snap: as the ground
-- rises past the swim threshold the regime drops out and the next step
-- lands on the bank — no transition state anywhere.
--
-- Animation: no animation state — the walk clip is driven by a DISTANCE
-- phase (sim state, so feet never slide at any speed), idle by the frame
-- counter, and draw blends idle->walk by ground speed, then multiplies the
-- live squash/stretch into the clip's own body-scale channel and leans the
-- base into the run. Pure function of (player buffer, frame).

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
}
local SIZE = 56

local buf

function M.init()
  local ok, b = pcall(pal.buf, "ow.player", SIZE)
  if not ok then -- layout grew across a hot reload
    pal.buf_free("ow.player")
    b = pal.buf("ow.player", SIZE)
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

-- the swim regime (D3D-019), derived from the buffer — never stored
function M.swimming()
  local k = state.doc.knobs.move
  local x, y, z = buf:f32(O.x), buf:f32(O.y), buf:f32(O.z)
  return world.water_y - world.ground(x, z) > k.swim_depth
     and y < world.water_y
end

-- ctl: wishx/wishz (camera-relative unit move vector or 0,0),
--      jump_pressed (edge)
-- dyncol: extra AABBs that move (the solid NPCs — main passes
--      npc.boxes()); they clamp and land exactly like world.colliders.
--      Positions are the buffers' pre-npc.step values (one sim frame
--      behind the draw) — at amble speeds that's 0.04u, and it keeps
--      the step order player -> npc that the exchange depends on.
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

  -- the swim regime at the step's start (see the header): pure derivation
  local wy = world.water_y
  local swim = wy - world.ground(x, z) > k.swim_depth and y < wy

  -- horizontal: accelerate toward the wish direction, brake to a stop.
  -- The regime picks the rates (swim / ground / air); cm.kin runs it.
  local accel = swim and k.swim_accel or grounded and k.accel or k.air_accel
  local fric = swim and k.swim_fric or grounded and k.fric or k.air_fric
  local sp = swim and k.swim_speed or k.speed
  vx, vz, yaw = kin.run(vx, vz, yaw, ctl.wishx, ctl.wishz, sp, accel, fric, k.turn)

  -- jump: buffered press + coyote window; a swim press is the paddle hop
  local jvy, evt
  jvy, jbuf, coyote, grounded, evt = kin.jump(jbuf, coyote, grounded,
    ctl.jump_pressed, k.buffer, k.coyote, v0, swim, k.paddle)
  if jvy then vy = jvy end
  if evt == "jump" then audio.sfx("jump", 96)
  elseif evt == "paddle" then audio.sfx("jump", 72) end

  if swim then
    -- buoyancy spring to the float line + water drag: settle with a bob
    vy = vy + (wy - k.float_depth - y) * k.buoy * DT
    vy = vy - vy * k.wdrag * DT
  else
    vy = kin.gravity(vy, g_rise, k.fall_mul) -- rise slope / heavier fall
  end
  vy = m.max(vy, -k.fall_max)

  -- collide x then z against the tree trunks + solid NPCs (the D3D-009/010
  -- clamp, in cm.kin) and clamp to the world edge. No mantle — the mascot
  -- has no stair run; a walk-off is a fall (k.snap glue decides below).
  local sx, sz = world.size()

  local nx = m.clamp(x + vx * DT, 2, sx - 2)
  nx, vx = kin.slide(world.colliders, true, nx, y, z, x, vx, hw, hh)
  nx, vx = kin.slide(dyncol or {}, true, nx, y, z, x, vx, hw, hh)
  x = nx
  local nz = m.clamp(z + vz * DT, 2, sz - 2)
  nz, vz = kin.slide(world.colliders, false, x, y, nz, z, vz, hw, hh)
  nz, vz = kin.slide(dyncol or {}, false, x, y, nz, z, vz, hw, hh)
  z = nz

  -- vertical vs the heightfield: land when the integrated y reaches the
  -- ground under the NEW x/z; while grounded and not rising, glue to the
  -- slope within k.snap (downhill walks stick; a real ledge drop exceeds
  -- the window and becomes a fall — walk-offs still read as falls)
  local g = world.ground(x, z)
  -- ...raised to any collider TOP under the feet (round 14 playtest: a
  -- jump onto a boulder fell INTO it — kin.ground_top, feet-at-or-above,
  -- the box-top rule the side clamps rightly skip). Walking off the top
  -- exceeds k.snap and becomes an ordinary fall.
  g = kin.ground_top(world.colliders, g, x, y, z, hw)
  g = kin.ground_top(dyncol or {}, g, x, y, z, hw)
  local ny = y + vy * DT
  local landed = false
  if ny <= g then
    local sa, st = kin.land_squash(vy, feel.squash, feel.vref, feel.squash_frames)
    if sa then -- a real landing (not the ~0.5/frame grounded re-collide)
      squash_amt, squash_t = sa, st
      audio.sfx("land", m.min(127, (64 - vy * 4) // 1))
    end
    ny = g
    vy = 0
    landed = true
  elseif grounded and vy <= 0 and ny - g <= k.snap then
    ny = g
    vy = 0
    landed = true
  end
  y = ny
  grounded = landed

  -- entry splash: the swim regime flipped on across this step (fell in,
  -- or walked off a deep bank) — a derived edge, no stored state
  if not swim and wy - g > k.swim_depth and y < wy then
    audio.sfx("splash", m.min(127, (70 - vy * 5) // 1))
    swim = true
  end

  squash_t = m.max(0, squash_t - 1)

  -- the walk-cycle phase advances with GROUND DISTANCE (no foot sliding)
  -- or while paddling; k.stride = world units per full cycle
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
end

-- emit the mascot (pose = idle->walk blend by ground speed, live squash &
-- stretch multiplied into the clip's body scale, lean on the base) into
-- out[]; returns tri count. Render-class: reads the buffer, never writes.
function M.emit(out)
  local k = state.doc.knobs.move
  local feel = state.doc.knobs.feel
  local x, y, z = buf:f32(O.x), buf:f32(O.y), buf:f32(O.z)
  local vx, vz = buf:f32(O.vx), buf:f32(O.vz)
  local vy = buf:f32(O.vy)
  local grounded = buf:f32(O.grounded) == 1.0
  local f = state.frame()

  -- swimming trades the walk clip for the swim stroke on the same
  -- distance phase; floating still breathes through the idle blend
  local swim = M.swimming()
  local hspeed = m.sqrt(vx * vx + vz * vz)
  local blend = m.min(1, hspeed / feel.walk_ref)
  local pose = fig.mix(fig.cycle(mascot.idle, f / feel.idle_f),
                       fig.cycle(swim and mascot.swim or mascot.walk,
                                 buf:f32(O.phase)), blend)

  -- live squash & stretch (the bounce cube math) composed onto the clip's
  -- own body-scale channel; swimming stays neutral — the surface bob and
  -- the tilt carry the read, airborne stretch would gong on every bob
  local s = 1.0
  if swim then -- neutral
  elseif not grounded then
    s = 1 + feel.stretch * m.min(1, m.abs(vy) / feel.vref)
  elseif buf:f32(O.squash_t) > 0 then
    s = 1 - buf:f32(O.squash_amt) * (buf:f32(O.squash_t) / feel.squash_frames)
  end
  local sx, sy, sz = mascot.sq(s)
  local body = pose.body
  body[7], body[8], body[9] = body[7] * sx, body[8] * sy, body[9] * sz
  pose.base[1] = pose.base[1] + buf:f32(O.lean) -- forward pitch into the run
  if swim then pose.base[1] = pose.base[1] + feel.swim_tilt end

  local root = m4.mul(m4.translate(x, y, z), m4.roty(buf:f32(O.yaw)))
  return fig.emit(out, mascot.fig, root, pose)
end

-- blob shadow, tilted to the local slope so it hugs the hill (tangents
-- from central height differences); fades with fall height. Returns tris.
function M.emit_shadow(out)
  local x, y, z = buf:f32(O.x), buf:f32(O.y), buf:f32(O.z)
  local e, r = 0.6, 1.0
  local gy = world.ground(x, z)
  local dhx = (world.ground(x + e, z) - world.ground(x - e, z)) / (2 * e)
  local dhz = (world.ground(x, z + e) - world.ground(x, z - e)) / (2 * e)
  local a = (127 * m.clamp(1 - (y - gy) / 16, 0.4, 1)) // 1
  local white = { 1, 1, 1 } -- the texture carries the darkness
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
