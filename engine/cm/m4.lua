-- cm.m4 — column-major 4x4 matrix helpers for 3D cartridges (fork module,
-- new file: cosmic2d never loads it). Straight ports of proto/r3d.c m4_*
-- (the look reference's conventions: GL-style clip z; the near sliver below
-- ~2*zn*zf/(zf+zn) clips on Vulkan, invisible in practice — see
-- docs/COSMIC3D.md §2 PS1 notes). Layout: m[c*4+r] at index c*4+r+1.
--
-- Render-class math for view/proj; the transform/apply helpers also serve
-- CPU-side vertex emitters (cm.math trig throughout, so anything that leaks
-- into sim state stays bit-stable across platforms).
local m = cm.require("cm.math")

local M = {}

function M.ident()
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

-- a*b; both flat 16-number arrays, column-major
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

function M.translate(x, y, z)
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1 }
end

function M.scale(x, y, z)
  return { x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0, 0, 0, 0, 1 }
end

-- rotations match proto/r3d.c: roty maps local +z toward +x as a grows
function M.rotx(a)
  local c, s = m.cos(a), m.sin(a)
  return { 1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1 }
end

function M.roty(a)
  local c, s = m.cos(a), m.sin(a)
  return { c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1 }
end

function M.rotz(a)
  local c, s = m.cos(a), m.sin(a)
  return { c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

-- transform a point (w=1): returns x,y,z
function M.apply(t, x, y, z)
  return t[1] * x + t[5] * y + t[9] * z + t[13],
         t[2] * x + t[6] * y + t[10] * z + t[14],
         t[3] * x + t[7] * y + t[11] * z + t[15]
end

-- transform a direction (w=0, no translation): normals under rigid xforms
function M.applydir(t, x, y, z)
  return t[1] * x + t[5] * y + t[9] * z,
         t[2] * x + t[6] * y + t[10] * z,
         t[3] * x + t[7] * y + t[11] * z
end

function M.lookat(ex, ey, ez, ax, ay, az, ux, uy, uz)
  local function norm(x, y, z)
    local l = m.sqrt(x * x + y * y + z * z)
    return x / l, y / l, z / l
  end
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
