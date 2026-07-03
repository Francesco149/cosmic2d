-- procart.tilegen — procedural terrain tiles that (a) tile cleanly and (b)
-- MARRY at material borders with no visible seam.
--
-- Two ideas carry everything:
--
-- 1. WORLD-SPACE SAMPLING. A material is a pure pixel function shade(x, y) of
--    world coordinates through stateless hashes (pnoise). Bake any rectangle
--    and it continues seamlessly into any neighboring rectangle — continuity
--    is by construction, not by edge-matching. For a single tile that must
--    repeat against ITSELF (an atlas tile), the same functions run in
--    periodic mode (`per` = tile size; all feature periods divide it).
--
-- 2. INDICATOR FIELDS + NOISE + ORDERED DITHER for borders. Each tile of a
--    material map contributes a bilinear "indicator field" for its material;
--    each material's field is perturbed by its own low-frequency noise; a
--    pixel takes the argmax material. Borders wobble organically, identically
--    on both sides of any tile edge (world-space again). Where the top two
--    fields are close, a Bayer threshold picks between them — a DITHERED
--    transition band, never an alpha blend (pixel art stays pixel art).
--    "air" is a material too, so ground silhouettes get the same treatment.
--
-- Dev/render class (D040): pure functions of (seed, coords), float math fine,
-- never sim state.

local paint = cm.require("cm.paint")
local palgen = cm.require("palgen")
local prng = cm.require("prng")
local pnoise = cm.require("pnoise")

local M = {}

local floor, min, max = math.floor, math.min, math.max

-- ---- materials ----

-- base HSV per material (ramps built lazily below). Hues sit near the canyon
-- mock: warm browns for rock/dirt, dusk-warm sand, a cool cosmic void.
local DEFS = {
  rock = { h = 0.07, s = 0.50, v = 0.62, n = 6 },
  dirt = { h = 0.078, s = 0.46, v = 0.50, n = 5 },
  grass = { h = 0.30, s = 0.52, v = 0.60, n = 5 },
  sand = { h = 0.115, s = 0.40, v = 0.90, n = 5 },
  brick = { h = 0.045, s = 0.22, v = 0.60, n = 5 },
  void = { h = 0.72, s = 0.55, v = 0.30, n = 5 },
}
M.MATERIALS = { "rock", "dirt", "grass", "sand", "brick", "void" }

-- per-material noise salt (decorrelates the border wobble of each material)
local SALT = {}
for i, name in ipairs(M.MATERIALS) do SALT[name] = prng.mix(i * 0x51ed2701) end
SALT.air = prng.mix(7 * 0x51ed2701)

local ramps = {} -- material -> ramp (lazy; pure of DEFS)
local function ramp(mat)
  local r = ramps[mat]
  if not r then
    local d = DEFS[mat]
    r = palgen.ramp(d.h, d.s, d.v, d.n)
    ramps[mat] = r
  end
  return r
end

local function clampi(i, lo, hi) return i < lo and lo or (i > hi and hi or i) end

-- ---- per-material shading: color at world pixel (x,y) ----
-- per = periodic mode tile size (nil = world/infinite). sd = surface distance
-- (1 = the first ground row under air; nil = no surface info). All feature
-- sizes are powers of two so periodic mode wraps exactly.

local shade = {}

function shade.rock(seed, x, y, per, sd)
  local r = ramp("rock")
  -- facet size: big slabs in world mode (the mock look); 8px cells in wrap
  -- mode so the period stays integral
  local cell = per and 8 or 11
  local pc = per and per / cell or nil
  local f1, f2, id = pnoise.worley(seed ~ SALT.rock, x / cell, y / cell, pc, pc)
  local idx = 3 + prng.mix(id) % 3 -- flat facet base tone
  local edge = f2 - f1
  if edge < 0.20 then
    idx = 1 -- crack between facets
  elseif edge < 0.34 then
    idx = idx - 1 -- facet contact shading
  end
  local n = pnoise.fbm(seed ~ SALT.rock, x, y, 1 / 16, 2, per, per)
  if n > 0.60 then idx = idx + 1 elseif n < 0.40 then idx = idx - 1 end
  if sd and sd <= 2 and edge >= 0.20 then idx = idx + (3 - sd) end -- sun-lit rim
  return r[clampi(idx, 1, #r)]
end

function shade.dirt(seed, x, y, per, sd)
  local r = ramp("dirt")
  local n = pnoise.fbm(seed ~ SALT.dirt, x, y, 1 / 8, 3, per, per)
  local idx = 2 + floor(n * 3.2)
  local h = prng.hash2(seed ~ SALT.dirt, x, y) % 100
  if h < 5 then idx = idx - 1 elseif h < 10 then idx = idx + 1 end -- speckle
  if sd and sd <= 1 then idx = idx + 1 end
  return r[clampi(idx, 1, #r)]
end

function shade.grass(seed, x, y, per, sd)
  local r = ramp("grass")
  -- vertically-stretched noise = blade streaks (periods 4 and 2 divide 16)
  local n = pnoise.value2(seed ~ SALT.grass, x / 4, y / 8, per and per // 4, per and per // 8)
  local n2 = pnoise.fbm(seed ~ SALT.grass, x, y, 1 / 8, 2, per, per)
  local idx = 2 + floor((n * 0.6 + n2 * 0.4) * 3.2)
  local h = prng.hash2(seed ~ SALT.grass, x, y) % 100
  if h < 8 then idx = idx + 1 end -- light blade tips
  if sd and sd <= 1 then idx = idx + 1 end -- sunny crest
  return r[clampi(idx, 1, #r)]
end

function shade.sand(seed, x, y, per, sd)
  local r = ramp("sand")
  local n = pnoise.fbm(seed ~ SALT.sand, x, y, 1 / 8, 2, per, per)
  local idx = 3
  local band = (y + floor((n - 0.5) * 7)) % 8 -- noise-swept dune lines
  if band < 1 then idx = 4 elseif band < 3 then idx = 3 else idx = 2 + floor(n * 2) end
  local h = prng.hash2(seed ~ SALT.sand, x, y) % 100
  if h < 4 then idx = idx + 1 elseif h < 8 then idx = idx - 1 end
  if sd and sd <= 1 then idx = idx + 1 end
  return r[clampi(idx, 1, #r)]
end

function shade.brick(seed, x, y, per, sd)
  local r = ramp("brick")
  local bw, bh = 8, 4
  local row = floor(y / bh)
  local xo = x + (row % 2) * (bw // 2) -- running bond offset
  local bx = floor(xo / bw)
  if xo % bw == 0 or y % bh == 0 then return r[1] end -- mortar
  local idx = 3 + prng.hash2(seed ~ SALT.brick, bx, row) % 2 -- per-brick tone
  if xo % bw == 1 or y % bh == 1 then idx = idx + 1 -- bevel light (top/left)
  elseif xo % bw == bw - 1 or y % bh == bh - 1 then idx = idx - 1 end -- bevel dark
  local n = pnoise.fbm(seed ~ SALT.brick, x, y, 1 / 8, 2, per, per)
  if n < 0.34 then idx = idx - 1 end -- wear
  return r[clampi(idx, 1, #r)]
end

function shade.void(seed, x, y, per, sd)
  local r = ramp("void")
  local n = pnoise.fbm(seed ~ SALT.void, x, y, 1 / 16, 3, per, per)
  local idx = 1 + floor(n * 2.4)
  local pc = per and per / 8 or nil
  local f1, f2 = pnoise.worley(seed ~ SALT.void ~ 0xbeef, x / 8, y / 8, pc, pc)
  -- energy veins: only where cells meet AND a slow mask allows — sparse
  -- glowing seams in the dark, not a net
  if f2 - f1 < 0.05 and n > 0.52 then
    return paint.hsv(0.50, 0.55, 0.95)
  end
  local h = prng.hash2(seed ~ SALT.void, x, y) % 1000
  if h < 6 then -- stars
    return ({ paint.hsv(0, 0, 1), paint.hsv(0.5, 0.3, 1), paint.hsv(0.9, 0.3, 1) })[h % 3 + 1]
  elseif h < 22 then
    idx = idx + 1
  end
  return r[clampi(idx, 1, #r)]
end

-- public: color of `mat` at world pixel (x,y). per/sd as above.
function M.shade(mat, seed, x, y, per, sd)
  return shade[mat](seed, x, y, per, sd)
end

-- ---- single repeating tile (periodic mode) ----

function M.wrap_tile(mat, seed, size)
  size = size or 16
  local img = paint.image(size, size)
  for y = 0, size - 1 do
    for x = 0, size - 1 do
      paint.set(img, x, y, shade[mat](seed, x, y, size, nil))
    end
  end
  return img
end

-- ---- world-space patch (continuity demo / free-region bake) ----

function M.patch(mat, seed, gx, gy, w, h)
  local img = paint.image(w, h)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      paint.set(img, x, y, shade[mat](seed, gx + x, gy + y, nil, nil))
    end
  end
  return img
end

-- ---- the marrying bake: material map -> seamless pixels ----

M.WOBBLE = 0.55 -- border wobble amplitude (fraction of a full field)
M.BAND = 0.14 -- near-tie width that dithers instead of hard-picking

-- indicator-field material pick at world pixel (x,y) over the tile grid
local function field_pick(grid, tw, th, x, y, tile, seed)
  local fx = x / tile - 0.5
  local fy = y / tile - 0.5
  local tx0, ty0 = floor(fx), floor(fy)
  local ux, uy = fx - tx0, fy - ty0
  ux = ux * ux * (3 - 2 * ux) -- smoothstep: rounder blobs
  uy = uy * uy * (3 - 2 * uy)
  local names, fields, nf = {}, {}, 0
  local function add(tx, ty, w)
    tx = tx < 0 and 0 or (tx > tw - 1 and tw - 1 or tx)
    ty = ty < 0 and 0 or (ty > th - 1 and th - 1 or ty)
    local m = grid[ty + 1][tx + 1]
    if fields[m] == nil then
      nf = nf + 1
      names[nf] = m
      fields[m] = 0
    end
    fields[m] = fields[m] + w
  end
  add(tx0, ty0, (1 - ux) * (1 - uy))
  add(tx0 + 1, ty0, ux * (1 - uy))
  add(tx0, ty0 + 1, (1 - ux) * uy)
  add(tx0 + 1, ty0 + 1, ux * uy)
  if nf == 1 then return names[1] end
  -- perturb each candidate's field with its own noise; take the top two
  local m1, f1, m2, f2 = nil, -1e9, nil, -1e9
  for i = 1, nf do
    local m = names[i]
    local f = fields[m] +
      (pnoise.fbm(seed ~ SALT[m], x, y, 1 / 12, 2) - 0.5) * M.WOBBLE
    if f > f1 then
      m2, f2 = m1, f1
      m1, f1 = m, f
    elseif f > f2 then
      m2, f2 = m, f
    end
  end
  -- near-tie: ordered dither between the top two (a pixel-art transition band)
  if f1 - f2 < M.BAND then
    local p = 0.5 + (f1 - f2) / M.BAND * 0.5
    if paint.bayer(4, x, y) >= p then return m2 end
  end
  return m1
end

-- bake a tile-material grid into pixels. grid[ty][tx] = material name or
-- "air" (transparent). opts: married=false → hard per-tile pick (the "before"
-- picture), gx/gy world offset, tile size (default 16).
function M.bake(grid, seed, opts)
  opts = opts or {}
  local tile = opts.tile or 16
  local married = opts.married ~= false
  local th, tw = #grid, #grid[1]
  local W, H = tw * tile, th * tile
  local img = paint.image(W, H)
  local gx, gy = opts.gx or 0, opts.gy or 0

  -- 1. material per pixel
  local mats = {}
  for y = 0, H - 1 do
    local row = y * W
    for x = 0, W - 1 do
      if married then
        mats[row + x] = field_pick(grid, tw, th, gx + x, gy + y, tile, seed)
      else
        mats[row + x] = grid[y // tile + 1][x // tile + 1]
      end
    end
  end

  -- 2. surface distance (rows since air, per column — feeds rim/crest light)
  local sd = {}
  for x = 0, W - 1 do
    local run = 99
    for y = 0, H - 1 do
      if mats[y * W + x] == "air" then run = 0 else run = run + 1 end
      sd[y * W + x] = run
    end
  end

  -- 3. shade
  for y = 0, H - 1 do
    local row = y * W
    for x = 0, W - 1 do
      local m = mats[row + x]
      if m ~= "air" then
        paint.set(img, x, y, shade[m](seed, gx + x, gy + y, nil, sd[row + x]))
      end
    end
  end

  -- 4. tufts: grass blades poke up into the air above a grass surface
  for x = 0, W - 1 do
    for y = 1, H - 1 do
      if mats[y * W + x] == "grass" and mats[(y - 1) * W + x] == "air" then
        local h = prng.hash2(seed ~ SALT.grass, x, y) % 10
        if h < 4 then
          local g = ramp("grass")
          paint.set(img, x, y - 1, g[4])
          if h < 1 then paint.set(img, x, y - 2, g[5]) end
        end
      end
    end
  end

  return img
end

return M
