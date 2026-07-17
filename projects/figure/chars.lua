-- chars.lua — the two stock figures, as cm.fig data (ports of proto/main.c):
--
-- MASCOT (draw_mascot, the approved direction): lathe teardrop body — no
-- boxes in the silhouette — Rayman-style floating mitten hands/boots,
-- belly patch, big white eyes (style B: bigger + rounder pupils,
-- human-picked), mouth, antenna star. The "base" part carries bob/lean
-- (proto's root), "body" carries the squash scale so eyes/belly/antenna
-- squash with it while mitts/boots stay parented to base — exactly the
-- proto transform tree.
--
-- GUY (draw_guy, the joint-tree technique proof): big-head chunky box
-- figure, 7 parts, the 4-key lerped walk (~10 numbers of animation asset).
-- Kept as the hierarchical-rotation exercise for cm.fig; the mascot is the
-- stock character (D3D-005: no Minecraft people as heroes).
--
-- Clips are POSE KEY LISTS for fig.cycle(keys, t): pure functions of the
-- sim frame, no animation state anywhere.

local fig = cm.require("cm.fig")

local C = select(2, ...) or {}

-- ---- the mascot ----------------------------------------------------------

local body_c = { 0.28, 0.60, 0.62 }  -- deep teal
local belly_c = { 0.94, 0.90, 0.78 } -- cream
local mitt_c = { 0.95, 0.52, 0.38 }  -- coral
local dark = { 0.10, 0.09, 0.13 }
local white = { 0.97, 0.97, 0.95 }
local star_c = { 1.00, 0.85, 0.35 }

-- eye style B from the pupil study (proto g_mstyle, human-picked)
local EYE_W, EYE_H, PUP_W, PUP_H = 0.17, 0.24, 0.11, 0.13

C.mascot = fig.build({ parts = {
  { name = "base", joint = { 0, 0.95, 0 } }, -- bob (ty) + lean (rz) live here
  { name = "body", parent = "base", shapes = { -- squash (s) lives here
    { kind = "lathe", col = body_c, n = 12, -- teardrop, fatter at the bottom
      prof = { 0, -0.95, 0.55, -0.80, 0.82, -0.38, 0.80, 0.10,
               0.60, 0.55, 0.30, 0.85, 0, 0.98 } },
    { kind = "ball", col = belly_c, r = 1, n = 10, -- belly patch, tucked low
      at = { 0, -0.48, 0.20 }, scale = { 0.46, 0.38, 0.50 } },
    { kind = "ball", col = white, r = 1, n = 8, -- eyes
      at = { -0.26, 0.28, 0.62 }, scale = { EYE_W, EYE_H, 0.10 } },
    { kind = "ball", col = white, r = 1, n = 8,
      at = { 0.26, 0.28, 0.62 }, scale = { EYE_W, EYE_H, 0.10 } },
    { kind = "ball", col = dark, r = 1, n = 6, -- pupils, slight right glance
      at = { -0.23, 0.26, 0.74 }, scale = { PUP_W, PUP_H, 0.05 } },
    { kind = "ball", col = dark, r = 1, n = 6,
      at = { 0.29, 0.26, 0.74 }, scale = { PUP_W, PUP_H, 0.05 } },
    { kind = "ball", col = dark, r = 1, n = 6, -- mouth
      at = { 0, 0.02, 0.80 }, scale = { 0.13, 0.05, 0.04 } },
  } },
  { name = "ant", parent = "body", joint = { 0, 0.90, 0 }, shapes = {
    { kind = "prism", col = dark, n = 5, r0 = 0.035, r1 = 0.025, h = 0.45 },
    { kind = "ball", col = star_c, r = 0.16, n = 6, at = { 0, 0.55, 0 } },
  } },
  { name = "hand_l", parent = "base", shapes = {
    { kind = "ball", col = mitt_c, r = 0.22, n = 8 } } },
  { name = "hand_r", parent = "base", shapes = {
    { kind = "ball", col = mitt_c, r = 0.22, n = 8 } } },
  { name = "foot_l", parent = "base", shapes = {
    { kind = "ball", col = mitt_c, r = 0.24, n = 8,
      scale = { 1.1, 0.72, 1.35 } } } },
  { name = "foot_r", parent = "base", shapes = {
    { kind = "ball", col = mitt_c, r = 0.24, n = 8,
      scale = { 1.1, 0.72, 1.35 } } } },
} })

-- squash s -> the volume-ish scale triple (proto: 1/sqrt(s), s, 1/sqrt(s))
local function sq(s)
  local xz = 1 / (s ^ 0.5)
  return xz, s, xz
end

-- mascot pose helper: bob/lean on base, squash on body, everything else
-- positional. h*/f* = {x,y,z} hand/foot offsets rel. base; ant = sway rad.
local function mpose(bob, lean, s, hl, hr, fl, fr, ant)
  local sx, sy, sz = sq(s)
  return {
    base = { 0, 0, lean, 0, bob, 0 },
    body = { 0, 0, 0, 0, 0, 0, sx, sy, sz },
    ant = { 0, 0, ant },
    hand_l = { 0, 0, 0, hl[1], hl[2], hl[3] },
    hand_r = { 0, 0, 0, hr[1], hr[2], hr[3] },
    foot_l = { 0, 0, 0, fl[1], fl[2], fl[3] },
    foot_r = { 0, 0, 0, fr[1], fr[2], fr[3] },
  }
end

-- idle: proto mascot_idle + a soft breath (squash osc) and antenna sway
C.mascot_idle = {
  mpose(0.00, 0, 1.00, { -0.88, -0.42, 0.12 }, { 0.88, -0.42, 0.12 },
        { -0.34, -0.90, 0.18 }, { 0.34, -0.90, 0.18 }, 0.10),
  mpose(0.03, 0.02, 1.03, { -0.88, -0.38, 0.12 }, { 0.88, -0.38, 0.12 },
        { -0.34, -0.90, 0.18 }, { 0.34, -0.90, 0.18 }, -0.06),
  mpose(0.00, 0, 1.00, { -0.88, -0.42, 0.12 }, { 0.88, -0.42, 0.12 },
        { -0.34, -0.90, 0.18 }, { 0.34, -0.90, 0.18 }, -0.14),
  mpose(0.02, -0.02, 1.02, { -0.88, -0.40, 0.12 }, { 0.88, -0.40, 0.12 },
        { -0.34, -0.90, 0.18 }, { 0.34, -0.90, 0.18 }, 0.02),
}

-- walk: contact/passing × 2 (mirrored). Feet swing z and lift on the pass;
-- mitts counter-swing; body hops (bob) with a touch of squash at contact;
-- antenna trails the hop. +z = forward (root yaw points the figure).
C.mascot_walk = {
  mpose(-0.02, 0.03, 0.96,                          -- L contact (squashed)
        { -0.88, -0.42, -0.30 }, { 0.88, -0.42, 0.34 },
        { -0.34, -0.90, 0.34 }, { 0.34, -0.90, -0.28 }, 0.16),
  mpose(0.08, 0.00, 1.06,                           -- R passing (stretched)
        { -0.88, -0.40, 0.02 }, { 0.88, -0.40, 0.02 },
        { -0.34, -0.90, 0.10 }, { 0.34, -0.62, 0.04 }, -0.10),
  mpose(-0.02, -0.03, 0.96,                         -- R contact
        { -0.88, -0.42, 0.34 }, { 0.88, -0.42, -0.30 },
        { -0.34, -0.90, -0.28 }, { 0.34, -0.90, 0.34 }, -0.16),
  mpose(0.08, 0.00, 1.06,                           -- L passing
        { -0.88, -0.40, 0.02 }, { 0.88, -0.40, 0.02 },
        { -0.34, -0.62, 0.04 }, { 0.34, -0.90, 0.10 }, 0.10),
}

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
