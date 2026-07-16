-- m4.lua — column-major 4x4 matrix helpers for the proto3d camera.
-- Straight ports of proto/r3d.c m4_* (the look reference's conventions:
-- GL-style clip z; the near sliver below ~2*zn*zf/(zf+zn) clips on Vulkan,
-- invisible in practice — see docs/COSMIC3D.md §2 PS1 notes). Render-class
-- math; trig via cm.math so replays are bit-stable everywhere.
local m = cm.require("cm.math")

local M = {}

-- a*b; both flat 16-number arrays, column-major (m[c*4+r] at index c*4+r+1)
function M.mul(a, b)
  local r = {}
  for c = 0, 3 do
    for row = 0, 3 do
      local s = 0
      for k = 0, 3 do s = s + a[k * 4 + row + 1] * b[c * 4 + k + 1] end
      r[c * 4 + row + 1] = s
    end
  end
  return r
end

local function norm(x, y, z)
  local l = m.sqrt(x * x + y * y + z * z)
  return x / l, y / l, z / l
end

function M.lookat(ex, ey, ez, ax, ay, az, ux, uy, uz)
  local fx, fy, fz = norm(ax - ex, ay - ey, az - ez)
  local sx, sy, sz = norm(fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux)
  local tx, ty, tz = sy * fz - sz * fy, sz * fx - sx * fz, sx * fy - sy * fx
  return {
    sx, tx, -fx, 0,
    sy, ty, -fy, 0,
    sz, tz, -fz, 0,
    -(sx * ex + sy * ey + sz * ez),
    -(tx * ex + ty * ey + tz * ez),
    (fx * ex + fy * ey + fz * ez), 1,
  }
end

function M.persp(fovy_deg, aspect, zn, zf)
  local f = 1 / m.tan(fovy_deg * (m.pi / 180) * 0.5)
  local r = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  r[1] = f / aspect
  r[6] = f
  r[11] = (zf + zn) / (zn - zf)
  r[12] = -1
  r[15] = (2 * zf * zn) / (zn - zf)
  return r
end

return M
