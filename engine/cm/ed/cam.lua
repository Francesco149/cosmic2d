-- cm.ed.cam — camera math for the editor canvas (EDITOR.md §3).
-- Pure functions over a cam table {x, y, zoom} (world offset + scale;
-- screen = (world - cam) * zoom, window px, top-left origin). The cam table
-- itself lives in cm.ed.doc (captured state); everything here is math.
-- Tuning constants are teidraw's (taste-approved by construction): 1.16x
-- per wheel notch clamped 0.02–64 anchored at the cursor, 280 ms
-- quart_inout eases, the adaptive 32-wu dot grid aiming for 18–44 px.

local M = select(2, ...) or {}

M.ZMIN, M.ZMAX = 0.02, 64.0
M.EASE_MS = 280
M.GRID_BASE = 32 -- world units
M.GRID_LO, M.GRID_HI = 18, 44 -- comfy screen-px pitch band

function M.new()
  return { x = 0.0, y = 0.0, zoom = 1.0 }
end

function M.w2s(c, x, y)
  return (x - c.x) * c.zoom, (y - c.y) * c.zoom
end

function M.s2w(c, x, y)
  return x / c.zoom + c.x, y / c.zoom + c.y
end

-- zoom by factor keeping the world point under screen (sx,sy) fixed
function M.zoom_at(c, sx, sy, factor)
  local z = c.zoom * factor
  if z < M.ZMIN then z = M.ZMIN elseif z > M.ZMAX then z = M.ZMAX end
  local wx, wy = M.s2w(c, sx, sy)
  c.zoom = z
  c.x = wx - sx / z
  c.y = wy - sy / z
end

-- wheel notches -> zoom factor (1.16 per notch, either direction)
function M.wheel_factor(notches)
  return 1.16 ^ notches
end

-- the camera that fits world rect (x,y,w,h) into a vw x vh viewport with a
-- screen-px margin, centered; degenerate rects get zoom 1. Returns a new cam.
function M.fit(x, y, w, h, vw, vh, margin)
  margin = margin or 48
  local avw, avh = vw - 2 * margin, vh - 2 * margin
  local z = 1.0
  if w > 0 and h > 0 and avw > 0 and avh > 0 then
    z = math.min(avw / w, avh / h)
    if z < M.ZMIN then z = M.ZMIN elseif z > M.ZMAX then z = M.ZMAX end
  end
  return { x = x + w * 0.5 - vw * 0.5 / z,
           y = y + h * 0.5 - vh * 0.5 / z, zoom = z }
end

-- a camera at 100% centered on the same world point the current cam centers
function M.at_100(c, vw, vh)
  local cx, cy = M.s2w(c, vw * 0.5, vh * 0.5)
  return { x = cx - vw * 0.5, y = cy - vh * 0.5, zoom = 1.0 }
end

-- linear interp between two cams (the 280 ms ease samples this with an
-- eased k; linear zoom over 280 ms reads fine — teidraw does the same)
function M.lerp(a, b, k)
  return { x = a.x + (b.x - a.x) * k,
           y = a.y + (b.y - a.y) * k,
           zoom = a.zoom + (b.zoom - a.zoom) * k }
end

-- adaptive grid: world step doubled/halved so the screen pitch lands in
-- the comfy band; alpha fades in across the band (0.35 -> 1.0)
function M.grid(zoom)
  local step = M.GRID_BASE
  while step * zoom < M.GRID_LO do step = step * 2 end
  while step * zoom > M.GRID_HI and step > 1e-6 do step = step * 0.5 end
  local t = (step * zoom - M.GRID_LO) / (M.GRID_HI - M.GRID_LO)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return step, 0.35 + 0.65 * t
end

return M
