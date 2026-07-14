-- cm.grade — a render-only color grade over the final game composite (M10,
-- PLAN's parked "LUT" pillar as a knob-driven grade). Wraps pal.x_grade: a
-- brightness/contrast/saturation/tint pass applied to the game-target blit,
-- so each room / scene gets a distinct MOOD without touching the art.
--
-- Render/dev only, NEVER sim (D036): the grade lives on the composite, the
-- sim can't read it, and it is reset every frame — set it each frame you
-- want it (like cm.gfx.camera). Goldens are unaffected unless a project asks
-- for a grade (the default blit is byte-identical). Headless --shot sees the
-- grade; --verify (no render) ignores it.

local M = select(2, ...) or {}

-- params = { brightness=, contrast=, saturation=, tint={r,g,b} } — all
-- optional, defaulting to the identity grade in the PAL. Call each frame.
function M.set(params)
  if pal.x_grade then pal.x_grade(params) end
end

function M.off()
  if pal.x_grade then pal.x_grade() end
end

-- a few named moods to reach for (tastes to tune per game). Each is a plain
-- params table; pass one to M.set or use M.preset(name).
M.presets = {
  none = {},
  warm = { brightness = 0.015, contrast = 1.06, saturation = 1.12,
           tint = { 1.09, 1.0, 0.88 } },      -- cozy, golden
  cool = { contrast = 1.05, saturation = 0.97,
           tint = { 0.9, 0.98, 1.12 } },       -- crisp, distant
  dusk = { brightness = -0.02, contrast = 1.12, saturation = 1.18,
           tint = { 1.12, 0.9, 0.82 } },       -- warm low sun
  night = { brightness = -0.03, contrast = 1.08, saturation = 0.85,
            tint = { 0.82, 0.9, 1.18 } },      -- moonlit blue
  noir = { saturation = 0.18, contrast = 1.22,
           tint = { 0.97, 0.98, 1.04 } },      -- near-monochrome
  dream = { brightness = 0.04, contrast = 0.94, saturation = 1.2,
            tint = { 1.06, 0.98, 1.08 } },     -- soft, lifted, rosy
}

-- apply a named preset (unknown / "none" turns the grade off).
function M.preset(name)
  local p = M.presets[name]
  if p and next(p) then M.set(p) else M.off() end
end

return M
