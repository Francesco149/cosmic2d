-- gb.lua — the graybox library: material-checker textures + pre-lit
-- triangle emitters, ported from proto/main.c (tx_gb, draw_gbox) so bounce
-- reproduces the look reference (proto/out/graybox.png) without the baked
-- dump. Everything here is render-class: textures are procedural pixels,
-- emitters turn box descriptions into x_tris vertex bytes (24B: xyz uv
-- rgba), pre-lit per vertex like the whole retro pipeline (COSMIC3D.md §2).
--
-- Emitters collect packed vertex strings into a caller table (concat once,
-- setstr once). Lighting = col * (ambient + sun_color * max(0, -N.L)),
-- verbatim proto/r3d.c light_vertex with the graybox scene's sun/ambient.

local m = cm.require("cm.math")
local m4 = cm.require("cm.m4")

local G = select(2, ...) or {}

-- graybox scene lighting (proto/main.c scene_graybox)
G.ambient = { 0.44, 0.44, 0.50 }
do
  local l = m.sqrt(0.5 ^ 2 + 1.0 + 0.25 ^ 2)
  G.sun = { -0.5 / l, -1.0 / l, -0.25 / l }
end

-- ---- procedural textures (proto tx_gb: value-noise fbm over a checker) ----

local function hash(seed, ix, iy, n)
  local s = (seed ~ ((ix % n) * 374761393) ~ ((iy % n) * 668265263)) & 0xffffffff
  s = (s ~ (s << 13)) & 0xffffffff
  s = s ~ (s >> 17)
  s = (s ~ (s << 5)) & 0xffffffff
  return (s & 0xffff) / 65535.0
end

local function vnoise(seed, x, y, period, cell)
  local n = period // cell
  local gx, gy = (x // cell) % n, (y // cell) % n
  local fx, fy = (x % cell) / cell, (y % cell) / cell
  local a = hash(seed, gx, gy, n)
  local b = hash(seed, gx + 1, gy, n)
  local c = hash(seed, gx, gy + 1, n)
  local d = hash(seed, gx + 1, gy + 1, n)
  local u = fx * fx * (3 - 2 * fx)
  local v = fy * fy * (3 - 2 * fy)
  return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
end

local function fbm(seed, x, y, period)
  return 0.55 * vnoise(seed, x, y, period, period // 4)
       + 0.30 * vnoise(seed * 7 + 1, x, y, period, period // 8)
       + 0.15 * vnoise(seed * 13 + 2, x, y, period, period // 16)
end

-- one 64x64 material checker; A/B = {r,g,b} 0-255, grain 0/1/2 = none/h/v
local function tx_gb(seed, A, B, check, noise_amt, grain)
  local px = {}
  for y = 0, 63 do
    for x = 0, 63 do
      local k = ((x // check) ~ (y // check)) & 1
      local c = k == 1 and A or B
      local r, g, b = c[1], c[2], c[3]
      local v = fbm(seed, x, y, 64) - 0.5
      local amt = noise_amt
      if grain == 1 then
        amt = amt * (0.6 + 0.8 * (0.5 + 0.5 * m.sin(y * 0.9 + fbm(seed * 3 + 1, x, y, 64) * 3)))
      elseif grain == 2 then
        amt = amt * (0.6 + 0.8 * (0.5 + 0.5 * m.sin(x * 0.9 + fbm(seed * 3 + 1, x, y, 64) * 3)))
      end
      local mul = 1 + v * amt
      r = m.clamp(r * mul, 0, 255) // 1
      g = m.clamp(g * mul, 0, 255) // 1
      b = m.clamp(b * mul, 0, 255) // 1
      -- dark seam on check borders: reads as tiles/blocks, not wallpaper
      if x % check == 0 or y % check == 0 then
        r, g, b = r * 3 // 4, g * 3 // 4, b * 3 // 4
      end
      px[#px + 1] = string.char(r, g, b, 255)
    end
  end
  return table.concat(px)
end

-- radial blob, alpha = softness (proto tx_shadow)
local function tx_shadow()
  local px = {}
  for y = 0, 31 do
    for x = 0, 31 do
      local dx, dy = (x - 15.5) / 15.5, (y - 15.5) / 15.5
      local d = m.sqrt(dx * dx + dy * dy)
      local a = d > 1 and 0 or m.min(1, (1 - d) * (1 - d) * 1.8)
      px[#px + 1] = string.char(12, 12, 12, (a * 255) // 1)
    end
  end
  return table.concat(px)
end

local MATS = { -- proto load_graybox_textures, verbatim
  { "grass",  11, { 92, 140, 72 }, { 74, 120, 60 },  16, 0.55, 0 },
  { "stone",  22, { 138, 134, 142 }, { 112, 108, 118 }, 16, 0.40, 0 },
  { "wood",   33, { 168, 124, 82 }, { 146, 104, 66 },  8, 0.50, 1 },
  { "dirt",   44, { 150, 116, 82 }, { 128, 96, 66 },  16, 0.60, 0 },
  { "metal",  55, { 130, 140, 156 }, { 104, 114, 132 }, 32, 0.25, 2 },
  { "accent", 66, { 222, 150, 64 }, { 190, 116, 44 },  8, 0.30, 0 },
}

-- (re)create the material family + shadow blob; ids persist in a named
-- buffer so hot reloads / VM reboots free the previous generation first
-- (the proto3d texids pattern). Returns { grass = id, ..., shadow = id }.
function G.load_textures(idbuf_name)
  local idbuf = pal.buf(idbuf_name, 4 * 16)
  local nold = idbuf:u32(0)
  for i = 1, nold do pal.tex_free(idbuf:u32(4 * i)) end
  local tex, n = {}, 0
  for _, mt in ipairs(MATS) do
    local id = pal.tex_create(64, 64, tx_gb(mt[2], mt[3], mt[4], mt[5], mt[6], mt[7]))
    tex[mt[1]] = id
    n = n + 1
    idbuf:u32(4 * n, id)
  end
  tex.shadow = pal.tex_create(32, 32, tx_shadow())
  n = n + 1
  idbuf:u32(4 * n, tex.shadow)
  idbuf:u32(0, n)
  return tex
end

-- ---- vertex emitters ----

local pack = string.pack

-- one lit vertex: world pos, uv, base col {r,g,b} 0-1 lit by world normal
local function vert(x, y, z, u, v, col, nx, ny, nz, alpha)
  local d = m.max(0, -(nx * G.sun[1] + ny * G.sun[2] + nz * G.sun[3]))
  local r = m.clamp(col[1] * (G.ambient[1] + d), 0, 1)
  local g = m.clamp(col[2] * (G.ambient[2] + d), 0, 1)
  local b = m.clamp(col[3] * (G.ambient[3] + d), 0, 1)
  return pack("<fffffBBBB", x, y, z, u, v,
              (r * 255) // 1, (g * 255) // 1, (b * 255) // 1, alpha or 255)
end
G.vert = vert

-- quad ABCD (ccw) -> 2 tris into out[]; verts are {x,y,z,u,v}, one normal
local function quad(out, a, b, c, d, col, nx, ny, nz, alpha)
  local A = vert(a[1], a[2], a[3], a[4], a[5], col, nx, ny, nz, alpha)
  local B = vert(b[1], b[2], b[3], b[4], b[5], col, nx, ny, nz, alpha)
  local C = vert(c[1], c[2], c[3], c[4], c[5], col, nx, ny, nz, alpha)
  local D = vert(d[1], d[2], d[3], d[4], d[5], col, nx, ny, nz, alpha)
  out[#out + 1] = A .. B .. C .. A .. C .. D
  return 2
end
G.quad = quad

-- single tri ABC (ccw), verts {x,y,z,u,v}, one normal
local function tri(out, a, b, c, col, nx, ny, nz, alpha)
  out[#out + 1] = vert(a[1], a[2], a[3], a[4], a[5], col, nx, ny, nz, alpha)
               .. vert(b[1], b[2], b[3], b[4], b[5], col, nx, ny, nz, alpha)
               .. vert(c[1], c[2], c[3], c[4], c[5], col, nx, ny, nz, alpha)
end
G.tri = tri

-- position/direction through an optional transform. Rigid xfs only
-- (translate*rot): applydir doesn't renormalize, so scale would skew the
-- lighting (same caveat as gbox's rot).
local function xfp(xf, x, y, z)
  if xf then return m4.apply(xf, x, y, z) end
  return x, y, z
end
local function xfn(xf, x, y, z)
  if xf then return m4.applydir(xf, x, y, z) end
  return x, y, z
end

local F = { -- proto draw_gbox face tables: corner indices, normal, uv axes
  { { 0, 1, 2, 3 }, { 0, 0, -1 }, 1, 2 },
  { { 5, 4, 7, 6 }, { 0, 0, 1 }, 1, 2 },
  { { 4, 0, 3, 7 }, { -1, 0, 0 }, 3, 2 },
  { { 1, 5, 6, 2 }, { 1, 0, 0 }, 3, 2 },
  { { 3, 2, 6, 7 }, { 0, 1, 0 }, 1, 3 },
  { { 4, 5, 1, 0 }, { 0, -1, 0 }, 1, 3 },
}

-- box under transform xf (nil = identity): size {sx,sy,sz} around center
-- {cx,cy,cz}, uv scaled by face size * uvs so checker texel density stays
-- constant on any proportion (the graybox structural unit). Normals rotate
-- by rot (the xf minus scale/translate; nil = xf, fine for rigid xfs).
function G.gbox(out, xf, size, center, col, uvs, rot)
  local hx, hy, hz = size[1] / 2, size[2] / 2, size[3] / 2
  local cx, cy, cz = center[1], center[2], center[3]
  local P = {
    { cx - hx, cy - hy, cz - hz }, { cx + hx, cy - hy, cz - hz },
    { cx + hx, cy + hy, cz - hz }, { cx - hx, cy + hy, cz - hz },
    { cx - hx, cy - hy, cz + hz }, { cx + hx, cy - hy, cz + hz },
    { cx + hx, cy + hy, cz + hz }, { cx - hx, cy + hy, cz + hz },
  }
  if xf then
    for i = 1, 8 do
      P[i][1], P[i][2], P[i][3] = m4.apply(xf, P[i][1], P[i][2], P[i][3])
    end
  end
  rot = rot or xf
  for _, f in ipairs(F) do
    local nx, ny, nz = f[2][1], f[2][2], f[2][3]
    if rot then nx, ny, nz = m4.applydir(rot, nx, ny, nz) end
    local uw = size[f[3]] * (uvs or 0.5)
    local vh = size[f[4]] * (uvs or 0.5)
    local i = f[1]
    local a, b, c, d = P[i[1] + 1], P[i[2] + 1], P[i[3] + 1], P[i[4] + 1]
    quad(out, { a[1], a[2], a[3], 0, 0 }, { b[1], b[2], b[3], uw, 0 },
         { c[1], c[2], c[3], uw, vh }, { d[1], d[2], d[3], 0, vh },
         col, nx, ny, nz)
  end
  return 12
end

-- extruded regular n-gon under xf (proto draw_prism): r0 bottom radius, r1
-- top radius, height h from local y=0. Facet-flat side normals; uv wraps
-- the perimeter (4 tiles around, h/2 down). caps: bit0 top, bit1 bottom.
-- Returns tris emitted.
function G.prism(out, xf, n, r0, r1, h, col, caps)
  caps = caps or 0
  local ntris = 0
  for i = 0, n - 1 do
    local a0, a1 = i * m.tau / n, (i + 1) * m.tau / n
    local c0, s0 = m.cos(a0), m.sin(a0)
    local c1, s1 = m.cos(a1), m.sin(a1)
    local nl = m.sqrt((c0 + c1) ^ 2 + (s0 + s1) ^ 2)
    local nx, ny, nz = xfn(xf, (c0 + c1) / nl, 0, (s0 + s1) / nl)
    local u0, u1, vv = i / n * 4, (i + 1) / n * 4, h / 2
    local ax, ay, az = xfp(xf, r1 * c0, h, r1 * s0)
    local bx, by, bz = xfp(xf, r1 * c1, h, r1 * s1)
    local cx, cy, cz = xfp(xf, r0 * c1, 0, r0 * s1)
    local dx, dy, dz = xfp(xf, r0 * c0, 0, r0 * s0)
    quad(out, { ax, ay, az, u0, 0 }, { bx, by, bz, u1, 0 },
         { cx, cy, cz, u1, vv }, { dx, dy, dz, u0, vv }, col, nx, ny, nz)
    ntris = ntris + 2
    if (caps & 1) ~= 0 and r1 > 0.001 then
      local px, py, pz = xfp(xf, 0, h, 0)
      local ux, uy, uz = xfn(xf, 0, 1, 0)
      tri(out, { px, py, pz, 0.5, 0.5 },
          { ax, ay, az, 0.5 + 0.4 * c0, 0.5 + 0.4 * s0 },
          { bx, by, bz, 0.5 + 0.4 * c1, 0.5 + 0.4 * s1 }, col, ux, uy, uz)
      ntris = ntris + 1
    end
    if (caps & 2) ~= 0 then
      local px, py, pz = xfp(xf, 0, 0, 0)
      local ux, uy, uz = xfn(xf, 0, -1, 0)
      tri(out, { px, py, pz, 0.5, 0.5 },
          { cx, cy, cz, 0.5 + 0.4 * c1, 0.5 + 0.4 * s1 },
          { dx, dy, dz, 0.5 + 0.4 * c0, 0.5 + 0.4 * s0 }, col, ux, uy, uz)
      ntris = ntris + 1
    end
  end
  return ntris
end

-- revolve a profile of {r,y, r,y, ...} pairs around local Y under xf (proto
-- draw_lathe), n segments per ring. Smooth ring shading: per-vertex normals
-- from the profile-plane slope, so this bypasses quad(). alpha (0-255,
-- nil = opaque) is for blend-segment ghosts (pickup pops). Returns tris.
function G.lathe(out, xf, prof, n, col, alpha)
  local npts = #prof // 2
  local ntris = 0
  for j = 0, npts - 2 do
    local ra, ya = prof[j * 2 + 1], prof[j * 2 + 2]
    local rb, yb = prof[j * 2 + 3], prof[j * 2 + 4]
    local dy, dr = yb - ya, rb - ra
    local len = m.sqrt(dy * dy + dr * dr)
    local nr = len > 1e-6 and dy / len or 1
    local ny = len > 1e-6 and -dr / len or 0
    for i = 0, n - 1 do
      local a0, a1 = i * m.tau / n, (i + 1) * m.tau / n
      local c0, s0 = m.cos(a0), m.sin(a0)
      local c1, s1 = m.cos(a1), m.sin(a1)
      local n0x, n0y, n0z = xfn(xf, nr * c0, ny, nr * s0)
      local n1x, n1y, n1z = xfn(xf, nr * c1, ny, nr * s1)
      local u0, u1 = i / n * 4, (i + 1) / n * 4
      local v0, v1 = j / (npts - 1) * 2, (j + 1) / (npts - 1) * 2
      local ax, ay, az = xfp(xf, rb * c0, yb, rb * s0)
      local bx, by, bz = xfp(xf, rb * c1, yb, rb * s1)
      local cx, cy, cz = xfp(xf, ra * c1, ya, ra * s1)
      local dx, dy_, dz = xfp(xf, ra * c0, ya, ra * s0)
      local A = vert(ax, ay, az, u0, v1, col, n0x, n0y, n0z, alpha)
      local B = vert(bx, by, bz, u1, v1, col, n1x, n1y, n1z, alpha)
      local C = vert(cx, cy, cz, u1, v0, col, n1x, n1y, n1z, alpha)
      local D = vert(dx, dy_, dz, u0, v0, col, n0x, n0y, n0z, alpha)
      out[#out + 1] = A .. B .. C .. A .. C .. D
      ntris = ntris + 2
    end
  end
  return ntris
end

return G
