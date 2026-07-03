-- procart.palgen — procedural palette ramps with HUE-SHIFTED shading, the
-- single technique that most makes pixel art read as "art" instead of
-- programmer-shaded blocks: shadows don't just darken, they rotate the hue
-- toward a cool anchor (violet/blue) and gain saturation; highlights rotate
-- toward a warm anchor (soft yellow) and desaturate. Every material and
-- character ramp in procart comes from here, so the whole sheet shares one
-- color logic — that shared logic IS the aesthetic coherence.
--
-- Dev/render class (D040). Pure functions of their inputs.

local paint = cm.require("cm.paint")

local M = {}

-- shortest-path hue lerp on the wheel (h in 0..1)
local function hue_toward(h, target, f)
  local d = (target - h) % 1
  if d > 0.5 then d = d - 1 end
  return (h + d * f) % 1
end

local function clamp01(v) return v < 0 and 0 or (v > 1 and 1 or v) end

-- build an n-step ramp (index 1 = deepest shadow … n = brightest light)
-- around a base HSV color. opts:
--   shadow_hue / light_hue  — the anchors shading rotates toward
--                             (defaults: 0.72 cool violet, 0.13 warm cream)
--   hue_swing — how far shading rotates toward the anchors (0..1, default 0.35)
--   v_lo / v_hi — value range of the ramp ends relative to base v
--   s_boost — extra saturation in the shadows (default 0.25)
-- Returns an array of packed RGBA (alpha 255).
function M.ramp(h, s, v, n, opts)
  opts = opts or {}
  local sh = opts.shadow_hue or 0.72
  local lh = opts.light_hue or 0.13
  local swing = opts.hue_swing or 0.35
  local v_lo = opts.v_lo or (v * 0.45)
  local v_hi = opts.v_hi or math.min(1, v * 1.15 + 0.08)
  local s_boost = opts.s_boost or 0.25
  local out = {}
  local mid = (n + 1) / 2
  for i = 1, n do
    local t = n > 1 and (i - 1) / (n - 1) or 0.5 -- 0 = shadow end, 1 = light end
    local depth = (mid - i) / math.max(mid - 1, 1) -- >0 in shadows, <0 in lights
    local hh, ss, vv
    if i < mid then
      hh = hue_toward(h, sh, swing * clamp01(depth))
      ss = clamp01(s + s_boost * clamp01(depth))
    else
      hh = hue_toward(h, lh, swing * clamp01(-depth))
      ss = clamp01(s * (1 - 0.45 * clamp01(-depth)))
    end
    vv = v_lo + (v_hi - v_lo) * t
    out[i] = paint.hsv(hh, ss, clamp01(vv))
  end
  return out
end

-- an outline color for a ramp: its shadow end pulled darker and toward the
-- cool anchor — never plain black (black outlines flatten cute art).
function M.outline(h, s, v, opts)
  opts = opts or {}
  local hh = hue_toward(h, opts.shadow_hue or 0.72, 0.5)
  return paint.hsv(hh, clamp01(s * 0.7 + 0.2), math.max(0.08, v * 0.22))
end

-- sample a ramp by a 0..1 value (nearest step — bands, never blends)
function M.at(ramp, t)
  local n = #ramp
  local i = math.floor(t * n) + 1
  if i < 1 then i = 1 elseif i > n then i = n end
  return ramp[i]
end

return M
