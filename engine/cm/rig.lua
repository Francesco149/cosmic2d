-- cm.rig — the 3D orbit-follow camera rig (the godot FollowCamera model,
-- ported for bounce 2026-07-16 and copied verbatim into openworld and
-- bigworld; distilled engine-side as the first §12 slice — the math here
-- is the three copies' agreed text, extracted BYTE-IDENTICAL so every
-- committed trace and pixel golden stands un-recut. D3D-028).
--
-- The rig is GAMEPLAY state (input is camera-relative), so it lives in a
-- caller-named f32 buffer the module owns the layout of:
--
--   [0]yaw [4]pitch [8]dist [12/16/20]focus xyz
--   [24]manual-hold frames [28/32]prev cursor [36]recentering flag
--
-- 40 bytes; R.SIZE below. Explicit yaw/pitch/dist + a smoothed focus;
-- drag-look and the cam_* actions steer the orbit directly and pause
-- yaw-follow (hold); yaw-follow eases behind the velocity heading unless
-- the heading sits inside the back cone of straight-INTO-the-camera (the
-- vibration fix, D3D-018); "recenter" eases behind the target's facing.
-- Camera POSITION derives in draw (R.view) — only orbit/focus state
-- steps. Knobs stay project-owned under doc.knobs.cam (each demo tunes
-- its own feel); R.defaults() seeds a new cartridge with the
-- feel-approved openworld/bigworld values.
--
-- Input contract (record-backed, so replay/verify hold): R.step reads
-- mouse wheel + drag (buttons 1/3) and the actions "cam_l" "cam_r"
-- "cam_u" "cam_d" "recenter" — map them in game.init.
--
-- Determinism: cm.math only, no libm; no module state, no buffers of its
-- own — canon, snapshots, traces and rewind carry the rig by
-- construction. Deliberately NOT here: collision/occlusion zoom, rails,
-- shoulder offsets, cinematic splines — later slices earn those from
-- real demo pain.

local m = cm.require("cm.math")
local input = cm.require("cm.input")
local m4 = cm.require("cm.m4")

local R = select(2, ...) or {}

R.SIZE = 40 -- f32 buffer bytes; layout in the header comment

function R.angdiff(target, from) -- shortest arc, (-pi, pi]
  return m.atan2(m.sin(target - from), m.cos(target - from))
end

-- the feel-approved knob set (openworld/bigworld values; bounce runs a
-- tighter dist/height — knobs are the cartridge's to tune)
function R.defaults()
  return {
    dist = 8.5, height = 3.4, look_h = 1.3,
    min_dist = 4, max_dist = 15, wheel_step = 0.8,
    pos_lerp = 0.10,             -- focus chase (PositionSharpness)
    yaw_follow = 0.16,           -- 0 = never auto-rotate, 1 = hard behind
    yaw_lerp = 0.04,             -- how fast yaw-follow catches up
    min_speed = 1.5,             -- below this hspeed the orbit holds still
    orbit = 0.045,               -- cam_l/r yaw rate, rad/frame
    mouse_yaw = 0.012, mouse_pitch = 0.010, -- rad per internal pixel
    key_pitch = 0.025,                      -- cam_u/d pitch, rad/frame
    pitch_min = -0.6, pitch_max = 0.95,     -- rad around the ref elevation
    recenter_lerp = 0.25, hold_frames = 42, -- manual pause of yaw-follow
    back_cone = 0.35, -- heading within this of straight-INTO-the-camera
                      -- pauses yaw-follow (the vibration fix, D3D-018)
  }
end

-- virgin-buffer seed: behind the target's facing at the knob distance,
-- focus on the target (each demo's game.init guard calls this once)
function R.reset(cam, kc, px, py, pz, tyaw)
  cam:f32(0, tyaw + m.pi)
  cam:f32(8, kc.dist)
  cam:f32(12, px); cam:f32(16, py); cam:f32(20, pz)
end

-- one sim step: (px,py,pz) target position, (vx,vz) target horizontal
-- velocity (yaw-follow's heading), tyaw the target's facing (recenter).
function R.step(cam, kc, px, py, pz, vx, vz, tyaw)
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

  -- cam_* actions as the right stick (godot HandleManualRotation signs:
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
    local target = tyaw + m.pi
    yaw = yaw + R.angdiff(target, yaw) * kc.recenter_lerp
    pitch = pitch * (1 - kc.recenter_lerp)
    if m.abs(R.angdiff(target, yaw)) < 0.01 and m.abs(pitch) < 0.01 then
      yaw, pitch, rec = target, 0, 0
    end
  end

  -- yaw-follow: ease behind the heading (the circling on a held sideways
  -- run) unless the player just steered or a recenter is in flight.
  -- Running INTO the camera pins 'behind' exactly opposite the yaw, and
  -- because input is camera-relative the ease can never win — both rotate
  -- together, the shortest arc's sign flips with float noise and the
  -- camera VIBRATES (human playtest 2026-07-17). Inside the back cone
  -- hold instead: backing up runs at the screen, the classic read;
  -- sideways runs (|da| ~ pi/2) still circle. D3D-018.
  local hspeed = m.sqrt(vx * vx + vz * vz)
  if rec == 0 and hold <= 0 and kc.yaw_follow > 0 and hspeed > kc.min_speed then
    local behind = m.atan2(-vx, -vz)
    local da = R.angdiff(behind, yaw)
    if m.abs(da) < m.pi - kc.back_cone then
      yaw = yaw + da * kc.yaw_follow * kc.yaw_lerp
    end
  end
  hold = m.max(0, hold - 1)

  -- the focus chases the target; the rigid orbit hangs off it in draw
  local fx = cam:f32(12) + (px - cam:f32(12)) * kc.pos_lerp
  local fy = cam:f32(16) + (py - cam:f32(16)) * kc.pos_lerp
  local fz = cam:f32(20) + (pz - cam:f32(20)) * kc.pos_lerp

  cam:f32(0, m.fmod(yaw, m.tau)); cam:f32(4, pitch); cam:f32(8, dist)
  cam:f32(12, fx); cam:f32(16, fy); cam:f32(20, fz)
  cam:f32(24, hold); cam:f32(36, rec)
end

-- camera-relative wish vector from held dirs: forward = the camera's view
-- direction on xz, straight from orbit yaw (yaw 0 = camera on +z looking
-- -z); right = cross(forward, up). Returns a unit (or zero) xz pair.
function R.wish(cam, fwd, side)
  local wishx, wishz = 0, 0
  if fwd ~= 0 or side ~= 0 then
    local yaw = cam:f32(0)
    local fx, fz = -m.sin(yaw), -m.cos(yaw)
    wishx = fx * fwd + (-fz) * side
    wishz = fz * fwd + fx * side
    local wl = m.sqrt(wishx * wishx + wishz * wishz)
    if wl > 1e-4 then wishx, wishz = wishx / wl, wishz / wl
    else wishx, wishz = 0, 0 end
  end
  return wishx, wishz
end

-- draw-side eye derivation (render-class): height scales with zoom so the
-- reference elevation angle holds; pitch tilts around it on a constant
-- radius (godot OrbitOffset + ScaleFramingWithDistance). Returns the view
-- matrix; projection/fog stay the caller's.
function R.view(cam, kc)
  local yaw, pitch, dist = cam:f32(0), cam:f32(4), cam:f32(8)
  local fx, fy, fz = cam:f32(12), cam:f32(16), cam:f32(20)
  local h = kc.height * dist / kc.dist
  local e0 = m.atan2(h, dist)
  local R_ = m.sqrt(dist * dist + h * h)
  local elev = m.clamp(e0 + pitch, -1.4, 1.4)
  local hr = m.cos(elev) * R_
  return m4.lookat(fx + m.sin(yaw) * hr, fy + m.sin(elev) * R_,
                   fz + m.cos(yaw) * hr,
                   fx, fy + kc.look_h, fz, 0, 1, 0)
end

return R
