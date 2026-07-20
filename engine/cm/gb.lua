-- cm.gb — the graybox library: material-checker textures + pre-lit
-- triangle emitters, ported from proto/main.c (tx_gb, draw_gbox) so
-- cartridges reproduce the look reference (proto/out/graybox.png) without
-- the baked dump. Born in projects/bounce (D3D-008), promoted engine-side
-- when the figure cartridge became its second user (the cm.m4 precedent).
-- Everything here is render-class: textures are procedural pixels,
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
-- nrmxf (optional): a RIGID transform for normals when xf carries scale —
-- positions deform, lighting stays rot-only (the player-squash precedent,
-- D3D-008). Returns tris emitted.
function G.prism(out, xf, n, r0, r1, h, col, caps, nrmxf)
  caps = caps or 0
  local nxf = nrmxf or xf
  local ntris = 0
  for i = 0, n - 1 do
    local a0, a1 = i * m.tau / n, (i + 1) * m.tau / n
    local c0, s0 = m.cos(a0), m.sin(a0)
    local c1, s1 = m.cos(a1), m.sin(a1)
    local nl = m.sqrt((c0 + c1) ^ 2 + (s0 + s1) ^ 2)
    local nx, ny, nz = xfn(nxf, (c0 + c1) / nl, 0, (s0 + s1) / nl)
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
      local ux, uy, uz = xfn(nxf, 0, 1, 0)
      tri(out, { px, py, pz, 0.5, 0.5 },
          { ax, ay, az, 0.5 + 0.4 * c0, 0.5 + 0.4 * s0 },
          { bx, by, bz, 0.5 + 0.4 * c1, 0.5 + 0.4 * s1 }, col, ux, uy, uz)
      ntris = ntris + 1
    end
    if (caps & 2) ~= 0 then
      local px, py, pz = xfp(xf, 0, 0, 0)
      local ux, uy, uz = xfn(nxf, 0, -1, 0)
      tri(out, { px, py, pz, 0.5, 0.5 },
          { cx, cy, cz, 0.5 + 0.4 * c1, 0.5 + 0.4 * s1 },
          { dx, dy, dz, 0.5 + 0.4 * c0, 0.5 + 0.4 * s0 }, col, ux, uy, uz)
      ntris = ntris + 1
    end
  end
  return ntris
end

-- per-profile-POINT normals in the (r,y) plane: each point averages its
-- two adjacent segments' perpendiculars (endpoints keep their single
-- segment), so lighting is smooth ALONG the profile as well as around
-- it — segment-flat normals gave every ring a hard circular lighting
-- seam (the mascot's banded body). Returns { nr0,ny0, nr1,ny1, ... }.
local function lathe_ptnorms(prof)
  local npts = #prof // 2
  local sr, sy = {}, {} -- per-SEGMENT perpendicular
  for j = 0, npts - 2 do
    local dy = prof[j * 2 + 4] - prof[j * 2 + 2]
    local dr = prof[j * 2 + 3] - prof[j * 2 + 1]
    local len = m.sqrt(dy * dy + dr * dr)
    sr[j] = len > 1e-6 and dy / len or 1
    sy[j] = len > 1e-6 and -dr / len or 0
  end
  local pn = {}
  for j = 0, npts - 1 do
    local ar, ay = sr[j - 1] or sr[j], sy[j - 1] or sy[j]
    local br, by = sr[j] or sr[j - 1], sy[j] or sy[j - 1]
    local nr, ny = ar + br, ay + by
    local len = m.sqrt(nr * nr + ny * ny)
    if len > 1e-6 then nr, ny = nr / len, ny / len else nr, ny = 1, 0 end
    pn[j * 2 + 1], pn[j * 2 + 2] = nr, ny
  end
  return pn
end

-- revolve a profile of {r,y, r,y, ...} pairs around local Y under xf (proto
-- draw_lathe), n segments per ring. Smooth shading: per-vertex normals
-- from the averaged profile-point perpendiculars (lathe_ptnorms), so this
-- bypasses quad(). alpha (0-255, nil = opaque) is for blend-segment ghosts
-- (pickup pops). nrmxf (optional):
-- rigid normal transform when xf carries scale (see G.prism). Returns tris.
function G.lathe(out, xf, prof, n, col, alpha, nrmxf)
  local npts = #prof // 2
  local nxf = nrmxf or xf
  local pn = lathe_ptnorms(prof)
  local ntris = 0
  for j = 0, npts - 2 do
    local ra, ya = prof[j * 2 + 1], prof[j * 2 + 2]
    local rb, yb = prof[j * 2 + 3], prof[j * 2 + 4]
    local nra, nya = pn[j * 2 + 1], pn[j * 2 + 2]
    local nrb, nyb = pn[j * 2 + 3], pn[j * 2 + 4]
    for i = 0, n - 1 do
      local a0, a1 = i * m.tau / n, (i + 1) * m.tau / n
      local c0, s0 = m.cos(a0), m.sin(a0)
      local c1, s1 = m.cos(a1), m.sin(a1)
      local nb0x, nb0y, nb0z = xfn(nxf, nrb * c0, nyb, nrb * s0)
      local nb1x, nb1y, nb1z = xfn(nxf, nrb * c1, nyb, nrb * s1)
      local na0x, na0y, na0z = xfn(nxf, nra * c0, nya, nra * s0)
      local na1x, na1y, na1z = xfn(nxf, nra * c1, nya, nra * s1)
      local u0, u1 = i / n * 4, (i + 1) / n * 4
      local v0, v1 = j / (npts - 1) * 2, (j + 1) / (npts - 1) * 2
      local ax, ay, az = xfp(xf, rb * c0, yb, rb * s0)
      local bx, by, bz = xfp(xf, rb * c1, yb, rb * s1)
      local cx, cy, cz = xfp(xf, ra * c1, ya, ra * s1)
      local dx, dy_, dz = xfp(xf, ra * c0, ya, ra * s0)
      local A = vert(ax, ay, az, u0, v1, col, nb0x, nb0y, nb0z, alpha)
      local B = vert(bx, by, bz, u1, v1, col, nb1x, nb1y, nb1z, alpha)
      local C = vert(cx, cy, cz, u1, v0, col, na1x, na1y, na1z, alpha)
      local D = vert(dx, dy_, dz, u0, v0, col, na0x, na0y, na0z, alpha)
      out[#out + 1] = A .. B .. C .. A .. C .. D
      ntris = ntris + 2
    end
  end
  return ntris
end

-- chunky low-poly ball of radius R under xf (proto draw_ball: the 6-point
-- lathe profile, NOT a smooth uv-sphere — the era look). Ellipsoids: put
-- the scale in xf and pass the rigid part transform as nrmxf.
local BALLPROF = { 0, -1, 0.62, -0.78, 0.95, -0.20, 0.95, 0.20, 0.62, 0.78, 0, 1 }
function G.ball(out, xf, R, n, col, alpha, nrmxf)
  local prof = {}
  for i = 1, #BALLPROF do prof[i] = BALLPROF[i] * R end
  return G.lathe(out, xf, prof, n, col, alpha, nrmxf)
end

-- ---- baked shapes: the figure fast path ----
--
-- A figure re-emits every shape every frame; the immediate emitters above
-- pay profile trig + matrix-chain + temp-table costs per QUAD (a mascot is
-- ~1000 tris ≈ 1.8 ms of Lua — the bigworld near-NPC frame tank). A bake
-- runs the emitter's exact loop ONCE, recording each vertex's LOCAL inputs
-- — position/uv exactly as fed to xfp, one normal slot per distinct xfn
-- call — in the exact emit order. emit_baked() then does the only
-- per-frame work: transform each normal slot + light it (the vert()
-- expressions verbatim), transform each position (the m4.apply expression
-- verbatim), pack. Same doubles through the same expressions in the same
-- order = the same bytes: pixel goldens stand un-recut, which is also the
-- proof this stays render-class (no sim byte anywhere near it).
--
-- bk = { nv, pos (3/vert local doubles), uv (2/vert), ni (normal slot
-- per vert, 0-based), nrm (3/slot local doubles), ns (slot count) }

local function bk_new()
  return { nv = 0, ns = 0, pos = {}, uv = {}, ni = {}, nrm = {}, lit = {} }
end

local function bk_slot(bk, nx, ny, nz)
  local s = bk.ns
  bk.nrm[s * 3 + 1], bk.nrm[s * 3 + 2], bk.nrm[s * 3 + 3] = nx, ny, nz
  bk.ns = s + 1
  return s
end

local function bk_vert(bk, x, y, z, u, v, slot)
  local i = bk.nv
  bk.pos[i * 3 + 1], bk.pos[i * 3 + 2], bk.pos[i * 3 + 3] = x, y, z
  bk.uv[i * 2 + 1], bk.uv[i * 2 + 2] = u, v
  bk.ni[i + 1] = slot
  bk.nv = i + 1
end

-- G.lathe's loop, recorded (A B C A C D per quad; the b-ring point
-- normal feeds A/B, the a-ring point normal C/D — the immediate path's
-- exact sharing)
function G.bake_lathe(prof, n)
  local bk = bk_new()
  local npts = #prof // 2
  local pn = lathe_ptnorms(prof)
  for j = 0, npts - 2 do
    local ra, ya = prof[j * 2 + 1], prof[j * 2 + 2]
    local rb, yb = prof[j * 2 + 3], prof[j * 2 + 4]
    local nra, nya = pn[j * 2 + 1], pn[j * 2 + 2]
    local nrb, nyb = pn[j * 2 + 3], pn[j * 2 + 4]
    for i = 0, n - 1 do
      local a0, a1 = i * m.tau / n, (i + 1) * m.tau / n
      local c0, s0 = m.cos(a0), m.sin(a0)
      local c1, s1 = m.cos(a1), m.sin(a1)
      local kb0 = bk_slot(bk, nrb * c0, nyb, nrb * s0)
      local kb1 = bk_slot(bk, nrb * c1, nyb, nrb * s1)
      local ka0 = bk_slot(bk, nra * c0, nya, nra * s0)
      local ka1 = bk_slot(bk, nra * c1, nya, nra * s1)
      local u0, u1 = i / n * 4, (i + 1) / n * 4
      local v0, v1 = j / (npts - 1) * 2, (j + 1) / (npts - 1) * 2
      bk_vert(bk, rb * c0, yb, rb * s0, u0, v1, kb0) -- A
      bk_vert(bk, rb * c1, yb, rb * s1, u1, v1, kb1) -- B
      bk_vert(bk, ra * c1, ya, ra * s1, u1, v0, ka1) -- C
      bk_vert(bk, rb * c0, yb, rb * s0, u0, v1, kb0) -- A
      bk_vert(bk, ra * c1, ya, ra * s1, u1, v0, ka1) -- C
      bk_vert(bk, ra * c0, ya, ra * s0, u0, v0, ka0) -- D
    end
  end
  return bk
end

function G.bake_ball(R, n)
  local prof = {}
  for i = 1, #BALLPROF do prof[i] = BALLPROF[i] * R end
  return G.bake_lathe(prof, n)
end

-- G.prism's loop, recorded — side quad then caps PER SEGMENT (the
-- immediate emit order), cap gates static
function G.bake_prism(n, r0, r1, h, caps)
  caps = caps or 0
  local bk = bk_new()
  for i = 0, n - 1 do
    local a0, a1 = i * m.tau / n, (i + 1) * m.tau / n
    local c0, s0 = m.cos(a0), m.sin(a0)
    local c1, s1 = m.cos(a1), m.sin(a1)
    local nl = m.sqrt((c0 + c1) ^ 2 + (s0 + s1) ^ 2)
    local ks = bk_slot(bk, (c0 + c1) / nl, 0, (s0 + s1) / nl)
    local u0, u1, vv = i / n * 4, (i + 1) / n * 4, h / 2
    bk_vert(bk, r1 * c0, h, r1 * s0, u0, 0, ks)  -- A
    bk_vert(bk, r1 * c1, h, r1 * s1, u1, 0, ks)  -- B
    bk_vert(bk, r0 * c1, 0, r0 * s1, u1, vv, ks) -- C
    bk_vert(bk, r1 * c0, h, r1 * s0, u0, 0, ks)  -- A
    bk_vert(bk, r0 * c1, 0, r0 * s1, u1, vv, ks) -- C
    bk_vert(bk, r0 * c0, 0, r0 * s0, u0, vv, ks) -- D
    if (caps & 1) ~= 0 and r1 > 0.001 then
      local kt = bk_slot(bk, 0, 1, 0)
      bk_vert(bk, 0, h, 0, 0.5, 0.5, kt)
      bk_vert(bk, r1 * c0, h, r1 * s0, 0.5 + 0.4 * c0, 0.5 + 0.4 * s0, kt)
      bk_vert(bk, r1 * c1, h, r1 * s1, 0.5 + 0.4 * c1, 0.5 + 0.4 * s1, kt)
    end
    if (caps & 2) ~= 0 then
      local kb = bk_slot(bk, 0, -1, 0)
      bk_vert(bk, 0, 0, 0, 0.5, 0.5, kb)
      bk_vert(bk, r0 * c1, 0, r0 * s1, 0.5 + 0.4 * c1, 0.5 + 0.4 * s1, kb)
      bk_vert(bk, r0 * c0, 0, r0 * s0, 0.5 + 0.4 * c0, 0.5 + 0.4 * s0, kb)
    end
  end
  return bk
end

-- G.gbox's faces, recorded (corner positions repeat per face — the same
-- doubles transform to the same bytes however often)
function G.bake_gbox(size, center, uvs)
  local bk = bk_new()
  local hx, hy, hz = size[1] / 2, size[2] / 2, size[3] / 2
  local cx, cy, cz = center[1], center[2], center[3]
  local P = {
    { cx - hx, cy - hy, cz - hz }, { cx + hx, cy - hy, cz - hz },
    { cx + hx, cy + hy, cz - hz }, { cx - hx, cy + hy, cz - hz },
    { cx - hx, cy - hy, cz + hz }, { cx + hx, cy - hy, cz + hz },
    { cx + hx, cy + hy, cz + hz }, { cx - hx, cy + hy, cz + hz },
  }
  for _, f in ipairs(F) do
    local kf = bk_slot(bk, f[2][1], f[2][2], f[2][3])
    local uw = size[f[3]] * (uvs or 0.5)
    local vh = size[f[4]] * (uvs or 0.5)
    local i = f[1]
    local a, b, c, d = P[i[1] + 1], P[i[2] + 1], P[i[3] + 1], P[i[4] + 1]
    bk_vert(bk, a[1], a[2], a[3], 0, 0, kf)   -- A
    bk_vert(bk, b[1], b[2], b[3], uw, 0, kf)  -- B
    bk_vert(bk, c[1], c[2], c[3], uw, vh, kf) -- C
    bk_vert(bk, a[1], a[2], a[3], 0, 0, kf)   -- A
    bk_vert(bk, c[1], c[2], c[3], uw, vh, kf) -- C
    bk_vert(bk, d[1], d[2], d[3], 0, vh, kf)  -- D
  end
  return bk
end

-- the C fast path's input: 64 bytes per vertex of packed doubles
-- (lx,ly,lz, nlx,nly,nlz, u,v — the exact values the Lua loop reads), in
-- an anonymous pal buffer pal.x_figverts consumes directly. Built lazily
-- on first emit; false = unavailable (host-loaded/fake pal), stay on Lua.
local function build_blob(bk)
  if not (pal.x_figverts and pal.buf) then return false end
  local pos, uv, ni, nrm = bk.pos, bk.uv, bk.ni, bk.nrm
  local parts = {}
  for i = 0, bk.nv - 1 do
    local k = ni[i + 1] * 3
    parts[i + 1] = pack("<dddddddd", pos[i * 3 + 1], pos[i * 3 + 2],
                        pos[i * 3 + 3], nrm[k + 1], nrm[k + 2], nrm[k + 3],
                        uv[i * 2 + 1], uv[i * 2 + 2])
  end
  local s = table.concat(parts)
  local b = pal.buf(nil, #s)
  b:setstr(0, s)
  return b
end

-- transform + light + pack a baked shape under xf (positions) / nxf
-- (normals). The C door (pal.x_figverts, v22) does the loop when present;
-- the Lua loop below is the REFERENCE — the inlined dots are
-- m4.apply/applydir verbatim and the lighting is vert() verbatim, and the
-- C mirrors both in double precision, so all three paths (immediate,
-- baked-Lua, baked-C) produce the same bytes (t_figverts pins it).
function G.emit_baked(out, xf, nxf, bk, col, alpha)
  local a = alpha or 255
  if bk.blob == nil then bk.blob = build_blob(bk) end
  if bk.blob then
    out[#out + 1] = pal.x_figverts(bk.blob, bk.nv, xf, nxf, G.sun,
                                   G.ambient, col, a)
    return bk.nv // 3
  end
  local t1, t5, t9, t13 = xf[1], xf[5], xf[9], xf[13]
  local t2, t6, t10, t14 = xf[2], xf[6], xf[10], xf[14]
  local t3, t7, t11, t15 = xf[3], xf[7], xf[11], xf[15]
  local n1, n5, n9 = nxf[1], nxf[5], nxf[9]
  local n2, n6, n10 = nxf[2], nxf[6], nxf[10]
  local n3, n7, n11 = nxf[3], nxf[7], nxf[11]
  local sun1, sun2, sun3 = G.sun[1], G.sun[2], G.sun[3]
  local am1, am2, am3 = G.ambient[1], G.ambient[2], G.ambient[3]
  local c1, c2, c3 = col[1], col[2], col[3]
  local nrm, lit = bk.nrm, bk.lit
  local max, clamp = m.max, m.clamp
  for k = 0, bk.ns - 1 do
    local lx, ly, lz = nrm[k * 3 + 1], nrm[k * 3 + 2], nrm[k * 3 + 3]
    local nx = n1 * lx + n5 * ly + n9 * lz
    local ny = n2 * lx + n6 * ly + n10 * lz
    local nz = n3 * lx + n7 * ly + n11 * lz
    local d = max(0, -(nx * sun1 + ny * sun2 + nz * sun3))
    lit[k * 3 + 1] = (clamp(c1 * (am1 + d), 0, 1) * 255) // 1
    lit[k * 3 + 2] = (clamp(c2 * (am2 + d), 0, 1) * 255) // 1
    lit[k * 3 + 3] = (clamp(c3 * (am3 + d), 0, 1) * 255) // 1
  end
  local pos, uv, ni = bk.pos, bk.uv, bk.ni
  local parts = {}
  for i = 0, bk.nv - 1 do
    local lx, ly, lz = pos[i * 3 + 1], pos[i * 3 + 2], pos[i * 3 + 3]
    local k = ni[i + 1] * 3
    parts[i + 1] = pack("<fffffBBBB",
                        t1 * lx + t5 * ly + t9 * lz + t13,
                        t2 * lx + t6 * ly + t10 * lz + t14,
                        t3 * lx + t7 * ly + t11 * lz + t15,
                        uv[i * 2 + 1], uv[i * 2 + 2],
                        lit[k + 1], lit[k + 2], lit[k + 3], a)
  end
  out[#out + 1] = table.concat(parts)
  return bk.nv // 3
end

return G
