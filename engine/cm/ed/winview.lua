-- cm.ed.winview — the shared per-window content-view helper (the
-- generalized fix for the canvas-zoom drift family, 2026-07-12).
--
-- THE INVARIANT: every CAPTURED view field is stored in WORLD units
-- (canvas units), never screen px — win.zoom = world units per content
-- px, win.px/py = pan in world units, scroll fields = world units. The
-- canvas zoom then cancels out by construction: a window's content
-- stays glued to its frame at any zoom.
--
-- The footgun this kills: three windows hand-rolled screen-px view
-- state and each drifted under canvas zoom in its own way — the asset
-- grid's top row wandered (screen-px scroll over z-scaled rows), the
-- map window's content kept its screen size while the frame scaled
-- (screen-scale win.zoom), and the sprite ed's wheel anchor mixed both
-- conventions. The code editor (line-anchored, UX round 6) and the
-- console (line-indexed) already stored content units; new kinds
-- should come here instead of rolling their own.

local M = select(2, ...) or {}

-- resolve the frame's view transform for a content rect (screen px)
-- showing cw x ch content px. Reads win.zoom/win.px/win.py (world
-- units; nil = fit + center). pad = fit margin in world units (per
-- side). Returns everything in SCREEN px — zoom = screen px per
-- content px — plus fit (screen) and wz (the canvas zoom) so gesture
-- code can convert back:
--   { cx, cy, w, h, ox, oy, zoom, fit, wz }
function M.view(win, z, cvx, cvy, cvw, cvh, cw, ch, pad)
  local m = (pad or 6) * z
  local fit = math.min((cvw - 2 * m) / cw, (cvh - 2 * m) / ch)
  local zoom = win.zoom and win.zoom * z or fit
  local ox, oy
  if win.px then
    ox = cvx + win.px * z
    oy = cvy + win.py * z
  else
    ox = cvx + (cvw - cw * zoom) * 0.5
    oy = cvy + (cvh - ch * zoom) * 0.5
  end
  return { cx = cvx, cy = cvy, w = cvw, h = cvh, ox = ox, oy = oy,
           zoom = zoom, fit = fit, wz = z }
end

-- wheel-zoom about a screen anchor: the content point under (ax, ay)
-- stays put. lo/hi clamp the WORLD scale. v is the current M.view.
function M.wheel_zoom(win, v, ax, ay, dy, lo, hi)
  local oldw = win.zoom or v.fit / v.wz
  local neww = oldw * (dy > 0 and 1.25 or 0.8)
  if neww < lo then neww = lo elseif neww > hi then neww = hi end
  local cxp = (ax - v.ox) / (oldw * v.wz) -- content coords of the anchor
  local cyp = (ay - v.oy) / (oldw * v.wz)
  win.px = (ax - cxp * neww * v.wz - v.cx) / v.wz
  win.py = (ay - cyp * neww * v.wz - v.cy) / v.wz
  win.zoom = neww
end

-- middle-drag pan: gesture-start screen origin (ox0, oy0) plus a screen
-- delta; pins the current zoom so a fit view stops re-fitting mid-pan
function M.pan(win, v, ox0, oy0, dxs, dys)
  win.px = (ox0 + dxs - v.cx) / v.wz
  win.py = (oy0 + dys - v.cy) / v.wz
  win.zoom = win.zoom or v.fit / v.wz
end

function M.reset(win) -- shift+1: back to fit + center
  win.zoom, win.px, win.py = nil, nil, nil
end

-- 1-D content scroll (the asset grid): win[key] holds WORLD units.
function M.scroll_px(win, key, z) -- the frame's screen-px offset
  return (win[key] or 0) * z
end

function M.scroll_by(win, key, z, dpx, max_wu) -- dpx in screen px
  local v = (win[key] or 0) + dpx / z
  if v < 0 then v = 0 end
  if max_wu and v > max_wu then v = max_wu end
  win[key] = v ~= 0 and v or nil
end

-- Switch one captured scroll field between named content tabs. The active
-- tab keeps using win[key] (so old sessions remain valid); inactive offsets
-- live in a small captured side table, also in world units.
function M.scroll_switch(win, key, from, to)
  if from == to then return false end
  local tk = key .. "_tabs"
  local tabs = win[tk]
  if not tabs then
    tabs = {}
    win[tk] = tabs
  end
  tabs[from] = win[key] or 0
  local v = tabs[to] or 0
  win[key] = v ~= 0 and v or nil
  return true
end

-- Clamp against the CURRENT content/layout extent. max_px is screen-space
-- because grids already know their rendered row heights; storage stays world
-- space. Returns the screen offset and whether captured state changed.
function M.clamp_scroll(win, key, z, max_px)
  local old = win[key] or 0
  local hi = math.max(0, max_px or 0) / z
  local v = math.max(0, math.min(hi, old))
  win[key] = v ~= 0 and v or nil
  return v * z, v ~= old
end

return M
