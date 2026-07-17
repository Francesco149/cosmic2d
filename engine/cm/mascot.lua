-- cm.mascot — THE engine mascot, as cm.fig data (locked in by the human
-- 2026-07-17, COSMIC3D.md §8d: "the stylized design helps the bounce and
-- animations feel more natural"). Lathe teardrop body — no boxes in the
-- silhouette — Rayman-style floating mitten hands/boots, belly patch, big
-- white eyes (style B: bigger + rounder pupils, human-picked), mouth,
-- antenna star. Born in projects/figure/chars.lua; promoted engine-side
-- when openworld became its second user (the cm.gb/cm.m4 precedent).
--
-- Transform tree (proto draw_mascot): "base" carries bob (ty) and lean
-- (rx/rz), "body" carries the squash scale so eyes/belly/antenna squash
-- with it while mitts/boots stay parented to base.
--
-- Clips are POSE KEY LISTS for fig.cycle(keys, t): pure functions of the
-- sim frame / walk phase, no animation state anywhere. M.pose builds a
-- full mascot pose from the feel parameters; M.sq is the volume-ish
-- squash triple — exported so cartridges can compose live squash &
-- stretch on top of a clip (the openworld player).

local fig = cm.require("cm.fig")

local M = select(2, ...) or {}

local body_c = { 0.28, 0.60, 0.62 }  -- deep teal
local belly_c = { 0.94, 0.90, 0.78 } -- cream
local mitt_c = { 0.95, 0.52, 0.38 }  -- coral
local dark = { 0.10, 0.09, 0.13 }
local white = { 0.97, 0.97, 0.95 }
local star_c = { 1.00, 0.85, 0.35 }

-- eye style B from the pupil study (proto g_mstyle, human-picked)
local EYE_W, EYE_H, PUP_W, PUP_H = 0.17, 0.24, 0.11, 0.13

M.fig = fig.build({ parts = {
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
function M.sq(s)
  local xz = 1 / (s ^ 0.5)
  return xz, s, xz
end

-- full mascot pose from feel parameters: bob/lean on base, squash on body,
-- everything else positional. h*/f* = {x,y,z} hand/foot offsets rel. base;
-- ant = sway rad.
function M.pose(bob, lean, s, hl, hr, fl, fr, ant)
  local sx, sy, sz = M.sq(s)
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
M.idle = {
  M.pose(0.00, 0, 1.00, { -0.88, -0.42, 0.12 }, { 0.88, -0.42, 0.12 },
         { -0.34, -0.90, 0.18 }, { 0.34, -0.90, 0.18 }, 0.10),
  M.pose(0.03, 0.02, 1.03, { -0.88, -0.38, 0.12 }, { 0.88, -0.38, 0.12 },
         { -0.34, -0.90, 0.18 }, { 0.34, -0.90, 0.18 }, -0.06),
  M.pose(0.00, 0, 1.00, { -0.88, -0.42, 0.12 }, { 0.88, -0.42, 0.12 },
         { -0.34, -0.90, 0.18 }, { 0.34, -0.90, 0.18 }, -0.14),
  M.pose(0.02, -0.02, 1.02, { -0.88, -0.40, 0.12 }, { 0.88, -0.40, 0.12 },
         { -0.34, -0.90, 0.18 }, { 0.34, -0.90, 0.18 }, 0.02),
}

-- walk: contact/passing × 2 (mirrored). Feet swing z and lift on the pass;
-- mitts counter-swing; body hops (bob) with a touch of squash at contact;
-- antenna trails the hop. +z = forward (root yaw points the figure).
M.walk = {
  M.pose(-0.02, 0.03, 0.96,                          -- L contact (squashed)
         { -0.88, -0.42, -0.30 }, { 0.88, -0.42, 0.34 },
         { -0.34, -0.90, 0.34 }, { 0.34, -0.90, -0.28 }, 0.16),
  M.pose(0.08, 0.00, 1.06,                           -- R passing (stretched)
         { -0.88, -0.40, 0.02 }, { 0.88, -0.40, 0.02 },
         { -0.34, -0.90, 0.10 }, { 0.34, -0.62, 0.04 }, -0.10),
  M.pose(-0.02, -0.03, 0.96,                         -- R contact
         { -0.88, -0.42, 0.34 }, { 0.88, -0.42, -0.30 },
         { -0.34, -0.90, -0.28 }, { 0.34, -0.90, 0.34 }, -0.16),
  M.pose(0.08, 0.00, 1.06,                           -- L passing
         { -0.88, -0.40, 0.02 }, { 0.88, -0.40, 0.02 },
         { -0.34, -0.62, 0.04 }, { 0.34, -0.90, 0.10 }, 0.10),
}

-- swim: alternate mitt strokes (reach forward near the surface, pull back
-- low) over a boot flutter kick, rolling into each stroke (rz), a glide
-- stretch between strokes; antenna trails the roll. The rider (openworld
-- player) adds the forward paddle pitch on base rx — keys keep rx clear.
-- Driven by the same distance phase as walk: one cycle = one L+R stroke.
M.swim = {
  M.pose(0.02, 0.10, 1.03,                           -- L reach / R pull
         { -0.78, -0.16, 0.66 }, { 0.86, -0.60, -0.40 },
         { -0.30, -0.84, -0.42 }, { 0.30, -1.00, -0.26 }, -0.14),
  M.pose(0.06, 0.00, 1.06,                           -- glide (stretched)
         { -0.84, -0.38, 0.16 }, { 0.84, -0.38, 0.16 },
         { -0.32, -0.94, -0.34 }, { 0.32, -0.94, -0.34 }, 0.06),
  M.pose(0.02, -0.10, 1.03,                          -- R reach / L pull
         { -0.86, -0.60, -0.40 }, { 0.78, -0.16, 0.66 },
         { -0.30, -1.00, -0.26 }, { 0.30, -0.84, -0.42 }, 0.14),
  M.pose(0.06, 0.00, 1.06,                           -- glide
         { -0.84, -0.38, 0.16 }, { 0.84, -0.38, 0.16 },
         { -0.32, -0.94, -0.34 }, { 0.32, -0.94, -0.34 }, -0.06),
}

return M
