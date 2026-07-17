-- npc — the pond watcher: demo 2's first NPC and the proximity exchange
-- (D3D-020, the Zelda-ish beat). A COLOR-VARIANT mascot (cm.mascot.build —
-- coral body, teal mitts: reads as "another one of them", never mistaken
-- for the player) stands on the pond's east bank. Walk close and it turns
-- to face you, waves (the cm.mascot.wave clip) with a greet chime, and a
-- dialog line types out on the HUD; wander off and it settles back toward
-- the pond. Lines rotate per greeting.
--
-- Sim state is ONE named buffer (ow.npc): facing yaw (eased, so the turn
-- reads as a turn), the greet-start frame (0 = not greeting; stored as
-- frame+1 so a frame-0 greet can't alias the sentinel), and the greet
-- count (line rotation). The wave/dialog are pure functions of (buffer,
-- frame) — the zero-animation-state rule holds. Greet enter/exit radii
-- carry hysteresis so hovering on the boundary can't machine-gun the
-- chime.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local fig = cm.require("cm.fig")
local mascot = cm.require("cm.mascot")
local world = cm.require("world")
local player = cm.require("player")
local audio = cm.require("audio")

local M = select(2, ...) or {}

-- the variant: body/mitt palette swapped vs the player (star stays gold —
-- it's the species mark, not the individual's)
M.fig = mascot.build({
  body = { 0.93, 0.55, 0.42 },  -- warm coral
  belly = { 0.97, 0.92, 0.80 },
  mitt = { 0.30, 0.58, 0.60 },  -- deep teal
})

-- the spot: the pond's east bank (h ~0.86, dry, above water_y=0), facing
-- the pond center at rest — both demo routes pass within greeting range
M.x, M.z = 52.5, 70.5
M.home_yaw = m.atan2(42.0 - 52.5, 64.0 - 70.5) -- toward the pond center

M.lines = {
  "oh! a visitor! lovely day by the pond, isn't it?",
  "the middle is deep. i've seen you paddle across!",
  "that star on your antenna really suits you.",
}

-- ow.npc layout (f32): [0]yaw [4]greet-start frame+1 (0 = idle) [8]greets
local buf

function M.init()
  local ok, b = pcall(pal.buf, "ow.npc", 12)
  if not ok then
    pal.buf_free("ow.npc")
    b = pal.buf("ow.npc", 12)
  end
  buf = b
  M.y = world.ground(M.x, M.z)
  if buf:f32(0) == 0 and buf:f32(4) == 0 then buf:f32(0, M.home_yaw) end
end

function M.greeting() -- frames since the greet began, or nil
  local t0 = buf:f32(4)
  if t0 <= 0 then return nil end
  return state.frame() - (t0 - 1)
end

function M.step()
  local k = state.doc.knobs.npc
  local px, _, pz = player.pos()
  local dx, dz = px - M.x, pz - M.z
  local d2 = dx * dx + dz * dz
  if buf:f32(4) > 0 then
    if d2 > k.exit_r * k.exit_r then buf:f32(4, 0) end
  elseif d2 < k.greet_r * k.greet_r then
    buf:f32(4, state.frame() + 1)
    buf:f32(8, buf:f32(8) + 1)
    audio.sfx("greet", 104)
  end
  -- ease the facing: toward the player mid-greet, home otherwise
  local target = buf:f32(4) > 0 and m.atan2(dx, dz) or M.home_yaw
  local yaw = buf:f32(0)
  local d = m.atan2(m.sin(target - yaw), m.cos(target - yaw))
  buf:f32(0, m.fmod(yaw + d * k.turn, m.tau))
end

-- the line being spoken + how many chars have typed out, or nil
function M.dialog()
  local since = M.greeting()
  if not since then return nil end
  local k = state.doc.knobs.npc
  local line = M.lines[(buf:f32(8) - 1) % #M.lines + 1]
  return line, m.min(#line, since // k.type_f)
end

-- render-class from here down: reads the buffer, never writes
function M.emit(out)
  local k = state.doc.knobs.npc
  local feel = state.doc.knobs.feel
  local f = state.frame()
  local pose = fig.cycle(mascot.idle, f / feel.idle_f)
  local since = M.greeting()
  if since then -- blend the wave in over blend_f frames (no snap)
    pose = fig.mix(pose, fig.cycle(mascot.wave, since / k.wave_f),
                   m.min(1, since / k.blend_f))
  end
  local root = m4.mul(m4.translate(M.x, M.y, M.z), m4.roty(buf:f32(0)))
  return fig.emit(out, M.fig, root, pose)
end

-- the standing blob shadow (the player's slope-hugging math, grounded so
-- no fall fade)
function M.emit_shadow(out)
  local e, r = 0.6, 1.0
  local gy = M.y
  local dhx = (world.ground(M.x + e, M.z) - world.ground(M.x - e, M.z)) / (2 * e)
  local dhz = (world.ground(M.x, M.z + e) - world.ground(M.x, M.z - e)) / (2 * e)
  local white = { 1, 1, 1 } -- the texture carries the darkness
  local lift = 0.06
  local function p(dx, dz)
    return { M.x + dx, gy + lift + dx * dhx + dz * dhz, M.z + dz }
  end
  local A, B, C, D = p(-r, -r), p(r, -r), p(r, r), p(-r, r)
  gb.quad(out, { A[1], A[2], A[3], 0, 0 }, { B[1], B[2], B[3], 1, 0 },
          { C[1], C[2], C[3], 1, 1 }, { D[1], D[2], D[3], 0, 1 },
          white, 0, 0, 0, 127)
  return 2
end

return M
