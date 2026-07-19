-- cm.ed.orbit — the shared per-window ORBIT view helper for 3D editor
-- viewports (E0, D137): the winview sibling for windows whose content is
-- a 3D scene rendered into a pal.x_rt target (the 3d map / mesh / figure
-- windows).
--
-- THE INVARIANT (winview's, in 3D): every CAPTURED view field lives on
-- the window in WORLD units — win.oyaw/opitch (radians), win.odist
-- (world units), win.ofx/ofy/ofz (the focus point). Nothing here stores
-- screen px, so canvas zoom and window resizes cannot drift the view;
-- the RT is recreated at the view rect's device px each time it changes
-- size and the camera never notices.
--
-- Grammar (the map-window wheel ladder, orbited): middle-drag = orbit,
-- shift+middle-drag = pan the focus on the ground plane, wheel = stepped
-- dolly, shift+1 = fit. All handlers are pure field updates here; the
-- window kind wires them through kit.viewlock exactly like a 2D view.
--
-- Everything is cm.math trig (bit-stable), pure functions over the win
-- table — KAT-able headless, no pal calls.

local m = cm.require("cm.math")
local m4 = cm.require("cm.m4")

local M = select(2, ...) or {}

M.FOV = 50           -- vertical degrees; per-window override = win.ofov
M.ZN, M.ZF = 0.3, 600
M.PITCH_MIN, M.PITCH_MAX = -1.45, -0.12 -- rad; look-down orbit band
M.DIST_MIN, M.DIST_MAX = 2, 400
M.STEP = 1.25        -- wheel dolly ladder

function M.defaults(dist, fx, fy, fz)
  return { oyaw = 0.7, opitch = -0.7, odist = dist or 40,
           ofx = fx or 0, ofy = fy or 0, ofz = fz or 0 }
end

-- camera basis from yaw/pitch: fwd points from eye TOWARD the focus;
-- right/up complete a right-handed frame with world +y up.
function M.basis(win)
  local cy, sy = m.cos(win.oyaw), m.sin(win.oyaw)
  local cp, sp = m.cos(win.opitch), m.sin(win.opitch)
  local fx, fy, fz = cy * cp, sp, sy * cp
  local rx, ry, rz = -sy, 0, cy
  local ux = ry * fz - rz * fy
  local uy = rz * fx - rx * fz
  local uz = rx * fy - ry * fx
  return fx, fy, fz, rx, ry, rz, ux, uy, uz
end

function M.eye(win)
  local fx, fy, fz = M.basis(win)
  return win.ofx - fx * win.odist,
         win.ofy - fy * win.odist,
         win.ofz - fz * win.odist
end

-- view-projection for a viewport of aspect w/h (plus the pieces gizmo
-- code needs: eye + the matrices separately)
function M.vp(win, aspect)
  local ex, ey, ez = M.eye(win)
  local view = m4.lookat(ex, ey, ez, win.ofx, win.ofy, win.ofz, 0, 1, 0)
  local proj = m4.persp(win.ofov or M.FOV, aspect, M.ZN, M.ZF)
  return m4.mul(proj, view), view, proj, ex, ey, ez
end

-- middle-drag orbit: screen deltas in px, ~0.008 rad/px
function M.orbit(win, dxs, dys)
  win.oyaw = win.oyaw + dxs * 0.008
  local p = win.opitch - dys * 0.008
  if p < M.PITCH_MIN then p = M.PITCH_MIN end
  if p > M.PITCH_MAX then p = M.PITCH_MAX end
  win.opitch = p
end

-- shift+middle-drag: pan the focus on the ground plane (camera-relative
-- right + the forward direction flattened to y=0), scaled so a drag
-- roughly tracks the ground under the cursor at the focus distance.
function M.pan(win, dxs, dys, viewh)
  local fx, _, fz, rx, _, rz = M.basis(win)
  local fl = m.sqrt(fx * fx + fz * fz)
  if fl > 1e-6 then fx, fz = fx / fl, fz / fl else fx, fz = 0, 1 end
  local s = 2 * win.odist / (viewh > 0 and viewh or 1)
  win.ofx = win.ofx - (rx * dxs) * s + fx * dys * s
  win.ofz = win.ofz - (rz * dxs) * s + fz * dys * s
end

function M.dolly(win, dy)
  local d = win.odist * (dy > 0 and 1 / M.STEP or M.STEP)
  if d < M.DIST_MIN then d = M.DIST_MIN end
  if d > M.DIST_MAX then d = M.DIST_MAX end
  win.odist = d
end

-- shift+1: frame a bounding sphere (cx,cy,cz,r) — dist from the fov so
-- the sphere fills ~80% of the vertical band
function M.fit(win, cx, cy, cz, r)
  win.ofx, win.ofy, win.ofz = cx, cy, cz
  local half = (win.ofov or M.FOV) * (m.pi / 180) * 0.5
  local d = (r > 0 and r or 1) / (m.tan(half) * 0.8)
  if d < M.DIST_MIN then d = M.DIST_MIN end
  if d > M.DIST_MAX then d = M.DIST_MAX end
  win.odist = d
end

-- cursor (px in the viewport rect, origin top-left, size vw x vh) ->
-- world ray {ox,oy,oz, dx,dy,dz} (dir normalized). Built from the basis
-- directly — no matrix inverse.
function M.ray(win, vw, vh, sx, sy)
  local fx, fy, fz, rx, ry, rz, ux, uy, uz = M.basis(win)
  local half = (win.ofov or M.FOV) * (m.pi / 180) * 0.5
  local th = m.tan(half)
  local aspect = vw / (vh > 0 and vh or 1)
  local nx = (2 * sx / (vw > 0 and vw or 1) - 1) * th * aspect
  local ny = (1 - 2 * sy / (vh > 0 and vh or 1)) * th
  local dx = fx + rx * nx + ux * ny
  local dy = fy + ry * nx + uy * ny
  local dz = fz + rz * nx + uz * ny
  local l = (dx * dx + dy * dy + dz * dz) ^ 0.5
  local ex, ey, ez = M.eye(win)
  return { ox = ex, oy = ey, oz = ez,
           dx = dx / l, dy = dy / l, dz = dz / l }
end

-- world point -> viewport px (+ clip w for behind-camera tests): the
-- gizmo overlay projector. Returns nil when behind the near plane.
function M.project(vpm, vw, vh, x, y, z)
  local cx = vpm[1] * x + vpm[5] * y + vpm[9] * z + vpm[13]
  local cy = vpm[2] * x + vpm[6] * y + vpm[10] * z + vpm[14]
  local cw = vpm[4] * x + vpm[8] * y + vpm[12] * z + vpm[16]
  if cw <= 1e-6 then return nil end
  return (cx / cw * 0.5 + 0.5) * vw, (0.5 - cy / cw * 0.5) * vh, cw
end

return M
