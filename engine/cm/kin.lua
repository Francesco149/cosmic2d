-- cm.kin — the shared collide+jump core of the three player kernels (§12
-- slice 5, D3D-032). bounce (the bouncy cube), openworld and bigworld (the
-- mascot) each grew a step() from the same movement DNA — the D3D-009/010
-- swept AABB clamp, the D029 fixed-apex jump, mantle, the box-top landing
-- raise, the squash/stretch juice — then diverged (mover carry, the swim
-- regime, the glider, terrain vs box ground). This module is the AGREED
-- core, as pure functions; the divergence stays in the cartridges, which
-- keep their own step() orchestration and call in for the shared mechanics.
--
-- The pieces, all pure (no module state, no buffers of its own — the
-- cm.walk precedent). Values in, values out; the caller owns the player
-- buffer and its layout (deliberately — the three layouts DIVERGE:
-- bounce.player 52B, ow.player 56B +phase, bw.player 60B +phase+glide, so
-- no single owned layout fits; value-based also means cm.kin can never
-- resize a persistent sim buffer, which the D3D-031 double-init rule warns
-- against). DT (60fps) and EPS (the D3D-010 epsilon) are owned here.
--
--   K.approach(v, target, step)         move v toward target, capped
--   K.overlaps(b, x, y, z, hw, hh)      swept point-box vs AABB {x0y0z0x1y1z1}
--   K.jump_curve(jump_h, apex_t)        -> g_rise, v0 (the D029 curve)
--   K.run(vx,vz,yaw, wx,wz, speed,accel,fric,turn)
--                                       -> vx,vz,yaw (accel+turn, or brake)
--   K.gravity(vy, g_rise, fall_mul)     -> vy (rise slope / heavier fall)
--   K.jump(jbuf,coyote,grounded, pressed, buffer,coyote_reset, v0, swim,paddle)
--                                       -> vy?, jbuf,coyote,grounded, evt
--   K.slide(list, xaxis, cx,cy,cz, p0, v, hw,hh [,mantle])
--                                       -> n, v, cy  (one axis of the clamp)
--   K.mantle_top(b, list, px,pz, y, hw,hh, step_h)  -> top? (the stair lift)
--   K.ground_top(list, g, x,y,z, hw)    -> g (raise ground to a box top)
--   K.land_squash(vy, squash,vref,frames)          -> amt?, t?
--   K.lean(lean, hspeed, amount, speed) -> lean
--
-- The face-picking rule (D3D-009): a side clamp reads WHICH SIDE THE PLAYER
-- WAS ON pre-move (p0), never the velocity sign — velocity zeroes on the
-- first hit and a sign-based clamp then snaps a later overlap to the wrong
-- face (the stair teleport). A pre-move overlap on the moving axis
-- (squeezed) clamps nothing. Every f32 side test carries EPS (D3D-010): a
-- clamp stores face-hw, (face-hw)+hw can round PAST the face, and an exact
-- test then reads the flush player as squeezed — one frame later it slides
-- in. EPS is far above f32 noise, far below a frame of motion.
--
-- Deliberately NOT here (project policy / divergence, or a later cut earns
-- it): the swim regime (buoyancy, paddle hop, entry splash — the paddle is
-- a hook in K.jump, the rest is the cartridge's derivation); the glider;
-- the vertical assembly (bounce lands/bonks per box, ow/bw land on a
-- heightfield with k.snap glue — cm.kin hands over slide/ground_top/
-- mantle_top/land_squash and the demo composes its own ground truth); the
-- mover carry; the kill-plane respawn; the walk-cycle odometer; emit() and
-- the blob shadow (render-class); the camera-relative wish (cm.rig's).

local m = cm.require("cm.math")

local K = select(2, ...) or {}

local DT = 1.0 / 60.0
local EPS = 1e-3
K.EPS = EPS -- the demos reuse it for their own inline f32 side tests

-- move v toward target by at most step (the accel/brake/glide primitive)
function K.approach(v, target, step)
  if v < target then return m.min(v + step, target) end
  return m.max(v - step, target)
end

-- a swept player box (centre x,z, half-width hw; feet at y, height hh) vs
-- an AABB b = {x0,y0,z0, x1,y1,z1}. Half-open on y from the feet up.
function K.overlaps(b, x, y, z, hw, hh)
  return x + hw > b[1] and x - hw < b[4]
     and y + hh > b[2] and y < b[5]
     and z + hw > b[3] and z - hw < b[6]
end

-- the fixed-apex jump curve (D029): apex height jump_h reached in apex_t
-- frames sets the rise gravity and the takeoff impulse.
function K.jump_curve(jump_h, apex_t)
  apex_t = m.max(apex_t, 1.0)
  local g_rise = 2.0 * jump_h * 3600.0 / (apex_t * apex_t)
  local v0 = 2.0 * jump_h * 60.0 / apex_t
  return g_rise, v0
end

-- horizontal locomotion: accelerate toward the wish (unit wx,wz) at `speed`
-- and turn yaw toward the heading (shortest arc, `turn` factor), or brake
-- to a stop at `fric`. The regime picks speed/accel/fric (ground/air/swim);
-- the glide's build-along-facing is a different block and stays in bigworld.
function K.run(vx, vz, yaw, wx, wz, speed, accel, fric, turn)
  if wx ~= 0 or wz ~= 0 then
    local a = accel * DT
    vx = K.approach(vx, wx * speed, a)
    vz = K.approach(vz, wz * speed, a)
    local d = m.atan2(wx, wz) - yaw
    d = m.atan2(m.sin(d), m.cos(d))
    yaw = yaw + d * turn
  else
    local f = fric * DT
    vx = K.approach(vx, 0, f)
    vz = K.approach(vz, 0, f)
  end
  return vx, vz, yaw
end

-- one gravity tick: the rise slope while ascending, the heavier fall past
-- the apex (fall_mul). The terminal clamp (max vy -fall_max) is the
-- caller's — it is shared across the swim/glide branches too.
function K.gravity(vy, g_rise, fall_mul)
  return vy - (vy > 0 and g_rise or g_rise * fall_mul) * DT
end

-- the D029 buffered-press + coyote jump. Arms jbuf on a press, refreshes
-- coyote while grounded, fires when both are live (impulse v0, consumes
-- both, leaves the ground); a swimming caller gets the paddle hop instead
-- (v0*paddle, no ground leave) — bounce passes swim=false so that branch
-- never runs. Silent: returns evt ("jump"/"paddle"/nil) for the caller's
-- sfx (the cm.walk rule — a held re-press must not spam it). Decrements
-- both timers. Returns the vy impulse (or nil), jbuf, coyote, grounded, evt.
function K.jump(jbuf, coyote, grounded, pressed, buffer, coyote_reset, v0, swim, paddle)
  if pressed then jbuf = buffer end
  if grounded then coyote = coyote_reset end
  local vy, evt
  if jbuf > 0 and coyote > 0 then
    vy = v0
    jbuf, coyote = 0, 0
    grounded = false
    evt = "jump"
  elseif jbuf > 0 and swim then
    vy = v0 * paddle
    jbuf = 0
    evt = "paddle"
  end
  jbuf = m.max(0, jbuf - 1)
  coyote = m.max(0, coyote - 1)
  return vy, jbuf, coyote, grounded, evt
end

-- one axis of the D3D-009/010 swept clamp. Moving along X (xaxis=true) or
-- Z, the candidate position is (cx,cy,cz) with the OTHER two axes already
-- resolved; p0 is the pre-move coord on the moving axis (the face-picking
-- reference), v its velocity. For each overlapped box the player was
-- outside of pre-move, clamp to that face and zero v; a squeezed pre-move
-- overlap clamps nothing. An optional mantle(b, px, pz, cy) probe (bounce's
-- stair lift) may instead RAISE cy (step up, keep the run) — cy threads out
-- so a later box and the next axis see the lifted feet. Returns n, v, cy.
function K.slide(list, xaxis, cx, cy, cz, p0, v, hw, hh, mantle)
  local lo = xaxis and 1 or 3
  local hi = xaxis and 4 or 6
  local n = xaxis and cx or cz
  for _, b in ipairs(list) do
    local px = xaxis and n or cx
    local pz = xaxis and cz or n
    if K.overlaps(b, px, cy, pz, hw, hh)
       and (p0 + hw <= b[lo] + EPS or p0 - hw >= b[hi] - EPS) then
      local top = mantle and mantle(b, px, pz, cy)
      if top then
        cy = top
      elseif p0 + hw <= b[lo] + EPS then
        n = b[lo] - hw
        v = 0
      else
        n = b[hi] + hw
        v = 0
      end
    end
  end
  return n, v, cy
end

-- the stair lift (bounce): a blocked box whose top is within step_h of the
-- feet (y) lifts the player instead of blocking, IF the body fits standing
-- there (no box in `list` overlaps that footprint at the new height).
-- Grounded-only is the caller's (it passes mantle=nil when airborne).
function K.mantle_top(b, list, px, pz, y, hw, hh, step_h)
  local lift = b[5] - y
  if lift <= 0 or lift > step_h then return nil end
  for _, o in ipairs(list) do
    if K.overlaps(o, px, b[5] + EPS, pz, hw, hh) then return nil end
  end
  return b[5]
end

-- raise the ground height g to any box TOP strictly under the feet interior
-- (the round-14 fix: a fall entering a collider through its top face needs
-- its own landing plane, the side clamps rightly ignore squeezed overlaps).
-- Feet-at-or-above only (y >= top-EPS); walking off the top drops g back and
-- the caller's k.snap window decides fall-or-glue.
function K.ground_top(list, g, x, y, z, hw)
  for _, b in ipairs(list) do
    if b[5] > g and y >= b[5] - EPS
       and x + hw > b[1] + EPS and x - hw < b[4] - EPS
       and z + hw > b[3] + EPS and z - hw < b[6] - EPS then
      g = b[5]
    end
  end
  return g
end

-- the landing squash: a real landing (impact faster than the grounded
-- re-collide, vy < -2) returns the squash amount + duration scaled by the
-- fall speed; nil otherwise. The caller applies them and plays its own land
-- sfx (which shares the note formula but audio is project-side).
function K.land_squash(vy, squash, vref, frames)
  if vy < -2 then
    return squash * m.min(1, -vy / vref), frames
  end
end

-- lean into the run: ease the pitch toward `amount` scaled by ground speed
-- over the run speed. The 0.2 smoothing matches all three kernels.
function K.lean(lean, hspeed, amount, speed)
  local t = amount * m.min(1, hspeed / speed)
  return lean + (t - lean) * 0.2
end

return K
