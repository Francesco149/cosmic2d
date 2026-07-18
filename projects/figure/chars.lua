-- chars.lua — the showcase cast. The MASCOT lives engine-side now
-- (cm.mascot — locked in as THE engine mascot 2026-07-17, promoted on its
-- second user); re-exported here so the cartridge reads as one cast list.
--
-- GUY (draw_guy, the joint-tree technique proof): big-head chunky box
-- figure, 7 parts, the 4-key lerped walk (~10 numbers of animation asset).
-- Kept as the hierarchical-rotation exercise for cm.fig; the mascot is the
-- stock character (D3D-005: no Minecraft people as heroes).
--
-- Clips are POSE KEY LISTS for fig.cycle(keys, t): pure functions of the
-- sim frame, no animation state anywhere.

local fig = cm.require("cm.fig")
local mascot = cm.require("cm.mascot")

local C = select(2, ...) or {}

C.mascot = mascot.fig
C.mascot_idle = mascot.idle
C.mascot_walk = mascot.walk

-- ---- the guy (proto GUY + walk_key, verbatim numbers) --------------------

local skin = { 0.95, 0.78, 0.62 }
local shirt = { 0.86, 0.30, 0.24 }
local sleeve = { 0.70, 0.22, 0.18 }
local pants = { 0.28, 0.26, 0.34 }
local belt = { 0.30, 0.42, 0.72 }
local hair = { 0.55, 0.32, 0.16 }
local guy_dark = { 0.10, 0.08, 0.12 }

C.guy = fig.build({ parts = {
  { name = "pelvis", joint = { 0, 0.95, 0 }, shapes = {
    { kind = "gbox", size = { 0.44, 0.28, 0.30 }, center = { 0, 0.06, 0 },
      col = belt } } },
  { name = "torso", parent = "pelvis", joint = { 0, 0.20, 0 }, shapes = {
    { kind = "gbox", size = { 0.52, 0.50, 0.34 }, center = { 0, 0.25, 0 },
      col = shirt } } },
  { name = "head", parent = "torso", joint = { 0, 0.55, 0 }, shapes = {
    { kind = "gbox", size = { 0.56, 0.52, 0.50 }, center = { 0, 0.30, 0 },
      col = skin },
    -- face: eyes as flat dark boxes on +z (texture-swap strips later)
    { kind = "gbox", size = { 0.07, 0.13, 0.02 },
      center = { -0.12, 0.32, 0.25 }, col = guy_dark },
    { kind = "gbox", size = { 0.07, 0.13, 0.02 },
      center = { 0.12, 0.32, 0.25 }, col = guy_dark },
    -- hair: cap + back panel
    { kind = "gbox", size = { 0.60, 0.18, 0.54 }, center = { 0, 0.52, 0 },
      col = hair },
    { kind = "gbox", size = { 0.60, 0.42, 0.10 }, center = { 0, 0.36, -0.24 },
      col = hair } } },
  -- limbs overlap upward past their joint so rotation never opens a gap
  { name = "arm_l", parent = "torso", joint = { -0.34, 0.44, 0 }, shapes = {
    { kind = "gbox", size = { 0.20, 0.56, 0.20 }, center = { 0, -0.20, 0 },
      col = sleeve } } },
  { name = "arm_r", parent = "torso", joint = { 0.34, 0.44, 0 }, shapes = {
    { kind = "gbox", size = { 0.20, 0.56, 0.20 }, center = { 0, -0.20, 0 },
      col = sleeve } } },
  { name = "leg_l", parent = "pelvis", joint = { -0.14, 0, 0 }, shapes = {
    { kind = "gbox", size = { 0.22, 0.60, 0.24 }, center = { 0, -0.24, 0 },
      col = pants } } },
  { name = "leg_r", parent = "pelvis", joint = { 0.14, 0, 0 }, shapes = {
    { kind = "gbox", size = { 0.22, 0.60, 0.24 }, center = { 0, -0.24, 0 },
      col = pants } } },
} })

-- proto walk_key: 4 keys, s = 0/1/0/-1; the whole clip is ~10 numbers
local function guy_key(k)
  local s = (k == 0 or k == 2) and 0 or (k == 1 and 1 or -1)
  local headx = (k == 1 or k == 3) and 0.06 or -0.02
  return {
    leg_l = { 0.7 * s, 0, 0 },
    leg_r = { -0.7 * s, 0, 0 },
    arm_l = { -0.6 * s, 0, 0 },
    arm_r = { 0.6 * s, 0, 0 },
    torso = { 0, 0.08 * s, 0 },
    head = { headx, 0, 0 },
  }
end
C.guy_walk = { guy_key(0), guy_key(1), guy_key(2), guy_key(3) }

return C
