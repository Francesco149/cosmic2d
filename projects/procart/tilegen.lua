-- procart.tilegen — procedural terrain tiles that (a) tile cleanly and (b)
-- MARRY at material borders with no visible seam. Round 2 adds STYLES.
--
-- Three ideas carry everything:
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
-- 3. A STYLE is a bundle of dials every shade function reads (round 2): the
--    look (facet scale, strata banding, contrast, texture amount, dither
--    band, rim light) times a GRADE (day/dusk/dread color grading applied to
--    the palette anchors before the ramps are built). A style instance is
--    pure data + a ramp cache; same (preset, grade, overrides) = same pixels.
--    st.facet_mul / st.band_mul are the live "tunable dial" hooks the canyon
--    demo page exposes.
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

-- base HSV per material. Hues sit near the canyon mock: warm browns for
-- rock/dirt, dusk-warm sand, a cool cosmic void.
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
SALT.strata = prng.mix(11 * 0x51ed2701)

-- ---- styles: the look dials ----
-- facet     rock slab size in world mode (px, before facet_mul)
-- slab_w    rock slab width/height anisotropy (>1 = wide flat canyon slabs)
-- strata    0..1 strength of horizontal strata banding in rock
-- strata_h  strata band height (px)
-- contrast  ramp value-range expansion (1 = round-1; higher = deeper shadows)
-- texture   amplitude of tone-perturbing noise/speckle (0 = flat fills)
-- band      marry near-tie width that dithers (the transition band size)
-- wobble    marry border wobble amplitude
-- rim       surface rim-light strength in ramp steps (0 = off)
-- crack     worley edge width that reads as a crack between slabs
-- crevice   true = crack pixels drop to the outline color (near-black)
-- sat/val   global palette multipliers    swing  palgen hue_swing
M.STYLES = {
  soft = { -- the round-1 look: small cobble facets, pastel, gentle
    facet = 11, slab_w = 1.0, strata = 0, strata_h = 7,
    contrast = 1.0, texture = 1.0, band = 0.14, wobble = 0.55,
    rim = 1, crack = 0.20, crevice = false, sat = 1.0, val = 1.0, swing = 0.35,
  },
  canyon = { -- the mock: big flat strata slabs, near-black crevices, warm crest
    facet = 22, slab_w = 1.7, strata = 1.0, strata_h = 9,
    contrast = 1.6, texture = 0.6, band = 0.10, wobble = 0.45,
    rim = 2, crack = 0.13, crevice = true, sat = 1.05, val = 0.92, swing = 0.5,
  },
  painterly = { -- big soft tone washes, ragged borders, heavy hue swing
    facet = 15, slab_w = 1.2, strata = 0.5, strata_h = 10,
    contrast = 1.25, texture = 1.7, band = 0.26, wobble = 0.85,
    rim = 1, crack = 0.09, crevice = false, sat = 0.92, val = 1.0, swing = 0.65,
  },
  flat = { -- Wadanohara-ish: flat cel fills, sparse texture, crisp borders
    facet = 18, slab_w = 1.5, strata = 0.8, strata_h = 9,
    contrast = 0.85, texture = 0.22, band = 0.03, wobble = 0.5,
    rim = 1, crack = 0.15, crevice = true, sat = 0.85, val = 1.06, swing = 0.18,
  },
}
M.STYLE_NAMES = { "canyon", "soft", "painterly", "flat" }

-- ---- grades: the mood dial (applied to palette anchors pre-ramp) ----
-- hue_to/hue_amt  rotate every material hue toward an hour-of-day anchor
-- s/v             saturation/value multipliers
-- sky             gradient stops for the demo pages' sky (top..horizon)
-- warm_rim        rim-light pixels pull toward this hue (nil = ramp top)
M.GRADES = {
  day = { hue_to = 0.12, hue_amt = 0, s = 1.0, v = 1.0, sky = {
    { pos = 0, rgba = paint.hsv(0.58, 0.55, 0.72) },
    { pos = 0.6, rgba = paint.hsv(0.55, 0.38, 0.88) },
    { pos = 1, rgba = paint.hsv(0.12, 0.25, 1.0) },
  } },
  dusk = { hue_to = 0.95, hue_amt = 0.06, s = 1.04, v = 0.90, warm_rim = 0.07, sky = {
    { pos = 0, rgba = paint.hsv(0.70, 0.55, 0.22) },
    { pos = 0.45, rgba = paint.hsv(0.78, 0.42, 0.38) },
    { pos = 0.75, rgba = paint.hsv(0.93, 0.45, 0.62) },
    { pos = 1, rgba = paint.hsv(0.09, 0.55, 0.95) },
  } },
  dread = { hue_to = 0.72, hue_amt = 0.30, s = 0.55, v = 0.62, sky = {
    { pos = 0, rgba = paint.hsv(0.72, 0.60, 0.06) },
    { pos = 0.55, rgba = paint.hsv(0.70, 0.50, 0.16) },
    { pos = 1, rgba = paint.hsv(0.48, 0.35, 0.34) },
  } },
}
M.GRADE_NAMES = { "day", "dusk", "dread" }

local function hue_toward(h, target, f)
  local d = (target - h) % 1
  if d > 0.5 then d = d - 1 end
  return (h + d * f) % 1
end

local function clamp01(v) return v < 0 and 0 or (v > 1 and 1 or v) end
local function clampi(i, lo, hi) return i < lo and lo or (i > hi and hi or i) end

-- build a style instance: preset name (or a raw dial table) x grade name.
-- over = optional dial overrides (the tunable-knob hook: e.g. facet_mul).
-- The instance carries a private ramp cache — pure of its inputs.
function M.style(preset, grade, over)
  local base = type(preset) == "table" and preset or M.STYLES[preset or "soft"]
  local st = {}
  for k, v in pairs(base) do st[k] = v end
  if over then for k, v in pairs(over) do st[k] = v end end
  st.name = type(preset) == "string" and preset or (st.name or "custom")
  st.grade = grade or "day"
  st.facet_mul = st.facet_mul or 1.0
  st.band_mul = st.band_mul or 1.0
  st._ramps, st._darks = {}, {}
  return st
end

local DEFAULT = M.style("soft", "day")

-- the graded HSV of a material under a style (pre-ramp anchor math)
local function graded_hsv(st, mat)
  local d = DEFS[mat]
  local g = M.GRADES[st.grade]
  local h = hue_toward(d.h, g.hue_to, g.hue_amt)
  local s = clamp01(d.s * st.sat * g.s)
  local v = clamp01(d.v * st.val * g.v)
  return h, s, v, d.n
end

-- ramp + outline color for `mat` under style `st` (cached per instance)
local function ramp(st, mat)
  local r = st._ramps[mat]
  if not r then
    local h, s, v, n = graded_hsv(st, mat)
    -- contrast expands the ramp's value range: deeper shadow floor, brighter top
    local c = st.contrast
    r = palgen.ramp(h, s, v, n, {
      hue_swing = st.swing,
      v_lo = clamp01(v * max(0.08, 0.45 - 0.28 * (c - 1))),
      v_hi = clamp01(min(1, v * 1.15 + 0.08) + 0.10 * (c - 1)),
    })
    st._ramps[mat] = r
  end
  return r
end

local function dark(st, mat)
  local k = st._darks[mat]
  if not k then
    local h, s, v = graded_hsv(st, mat)
    k = palgen.outline(h, s, v)
    st._darks[mat] = k
  end
  return k
end
M.ramp_of, M.dark_of = ramp, dark -- for page composition (tufts, props)

-- ---- per-material shading: color at world pixel (x,y) ----
-- per = periodic mode tile size (nil = world/infinite). sd = surface distance
-- (1 = the first ground row under air; nil = no surface info). st = style
-- instance (nil = DEFAULT). All feature sizes in periodic mode are powers of
-- two so the tile wraps exactly.

local shade = {}

function shade.rock(seed, x, y, per, sd, st)
  local r = ramp(st, "rock")
  local nr = #r
  local mid = floor(nr / 2) + 1

  if per or st.strata <= 0 then
    -- worley cobble: the round-1 look (the soft style + all wrap tiles —
    -- strata banding can't wrap for free, so periodic mode always cobbles)
    local cell = per and 8 or max(4, floor(st.facet * st.facet_mul + 0.5))
    local pc = per and per / cell or nil
    local f1, f2, id = pnoise.worley(seed ~ SALT.rock, x / cell, y / cell, pc, pc)
    local idx = mid + prng.mix(id) % 3 - 1
    local edge = f2 - f1
    if edge < st.crack then
      idx = 1 -- crack between facets
    elseif edge < st.crack * 1.7 then
      idx = idx - 1 -- facet contact shading
    end
    local n = pnoise.fbm(seed ~ SALT.rock, x, y, 1 / 16, 2, per, per)
    if n > 0.60 then idx = idx + 1 elseif n < 0.40 then idx = idx - 1 end
    if sd and sd <= 2 and edge >= st.crack and st.rim > 0 then
      idx = idx + (3 - sd) -- sun-lit rim
    end
    return r[clampi(idx, 1, nr)]
  end

  -- STRATA SLABS (the mock): horizontal courses with wobbled shelf lines,
  -- each course split into big slabs on a running bond — giant irregular
  -- brickwork, which is what canyon strata read as. Crevices go near-black
  -- in crevice styles; slab faces stay CALM (tone varies per slab, not per
  -- pixel) so the big shapes read at a glance.
  local bh = max(4, floor(st.strata_h * st.facet_mul + 0.5))
  -- shelf lines wobble along x only (a fuzzy horizontal line, never a blur)
  local yy = y + floor((pnoise.fbm(seed ~ SALT.strata, x, 0, 1 / 40, 2) - 0.5) * bh * 0.8)
  local bi = floor(yy / bh)
  local inb = yy - bi * bh
  -- slab joints wobble along y the same way
  local sw = max(6, floor(st.facet * st.slab_w * st.facet_mul + 0.5))
  sw = sw + prng.hash2(seed ~ SALT.rock, bi, 1) % (sw // 2 + 1) -- per-course width
  local xo = prng.hash2(seed ~ SALT.rock, bi, 0) % sw -- running-bond offset
  local xx = x + xo + floor((pnoise.fbm(seed ~ SALT.rock, 0, y, 1 / 24, 2) - 0.5) * 4)
  local si = floor(xx / sw)
  local ins = xx - si * sw
  -- crevices: the shelf line under each course + the vertical joint
  if inb == 0 or ins == 0 then
    if st.crevice then return dark(st, "rock") end
    return r[1]
  end
  -- calm per-slab tone: mostly mid, some +/-1 (scaled by strata strength)
  local t = prng.hash2(seed ~ SALT.strata, bi, si) % 10
  local idx = mid + floor((t < 2 and -1 or (t < 4 and 1 or 0)) * st.strata + 0.5)
  if inb == 1 then idx = idx + 1 -- top bevel catches the light
  elseif inb == bh - 1 or ins == 1 then idx = idx - 1 end -- contact shade
  -- sparse texture: big soft fbm patches, amplitude by st.texture
  local n = pnoise.fbm(seed ~ SALT.rock, x, y, 1 / 20, 2)
  if n > 0.5 + 0.14 / max(st.texture, 0.01) then idx = idx + 1
  elseif n < 0.5 - 0.14 / max(st.texture, 0.01) then idx = idx - 1 end
  if sd and sd <= 2 and st.rim > 0 then
    idx = idx + st.rim * (3 - sd) // 2 + 1 -- sun-lit crest
  end
  return r[clampi(idx, 1, nr)]
end

function shade.dirt(seed, x, y, per, sd, st)
  local r = ramp(st, "dirt")
  local n = pnoise.fbm(seed ~ SALT.dirt, x, y, 1 / 8, 3, per, per)
  local idx = 2 + floor(((n - 0.5) * st.texture + 0.5) * 3.2)
  local h = prng.hash2(seed ~ SALT.dirt, x, y) % 100
  local sp = floor(5 * st.texture)
  if h < sp then idx = idx - 1 elseif h < sp * 2 then idx = idx + 1 end -- speckle
  if sd and sd <= 1 and st.rim > 0 then idx = idx + 1 end
  return r[clampi(idx, 1, #r)]
end

function shade.grass(seed, x, y, per, sd, st)
  local r = ramp(st, "grass")
  -- vertically-stretched noise = blade streaks (periods 4 and 2 divide 16)
  local n = pnoise.value2(seed ~ SALT.grass, x / 4, y / 8, per and per // 4, per and per // 8)
  local n2 = pnoise.fbm(seed ~ SALT.grass, x, y, 1 / 8, 2, per, per)
  local idx = 2 + floor((0.5 + ((n * 0.6 + n2 * 0.4) - 0.5) * st.texture) * 3.2)
  local h = prng.hash2(seed ~ SALT.grass, x, y) % 100
  if h < floor(8 * st.texture) then idx = idx + 1 end -- light blade tips
  if sd and sd <= 1 and st.rim > 0 then idx = idx + st.rim end -- sunny crest
  return r[clampi(idx, 1, #r)]
end

function shade.sand(seed, x, y, per, sd, st)
  local r = ramp(st, "sand")
  local n = pnoise.fbm(seed ~ SALT.sand, x, y, 1 / 8, 2, per, per)
  local idx = 3
  local band = (y + floor((n - 0.5) * 7)) % 8 -- noise-swept dune lines
  if band < 1 then idx = 4 elseif band < 3 then idx = 3 else idx = 2 + floor(n * 2) end
  local h = prng.hash2(seed ~ SALT.sand, x, y) % 100
  local sp = floor(4 * st.texture)
  if h < sp then idx = idx + 1 elseif h < sp * 2 then idx = idx - 1 end
  if sd and sd <= 1 and st.rim > 0 then idx = idx + 1 end
  return r[clampi(idx, 1, #r)]
end

function shade.brick(seed, x, y, per, sd, st)
  local r = ramp(st, "brick")
  local bw, bh = 8, 4
  local row = floor(y / bh)
  local xo = x + (row % 2) * (bw // 2) -- running bond offset
  local bx = floor(xo / bw)
  if xo % bw == 0 or y % bh == 0 then
    return st.crevice and dark(st, "brick") or r[1] -- mortar
  end
  local idx = 3 + prng.hash2(seed ~ SALT.brick, bx, row) % 2 -- per-brick tone
  if xo % bw == 1 or y % bh == 1 then idx = idx + 1 -- bevel light (top/left)
  elseif xo % bw == bw - 1 or y % bh == bh - 1 then idx = idx - 1 end -- bevel dark
  local n = pnoise.fbm(seed ~ SALT.brick, x, y, 1 / 8, 2, per, per)
  if n < 0.5 - 0.16 / max(st.texture, 0.01) then idx = idx - 1 end -- wear
  return r[clampi(idx, 1, #r)]
end

function shade.void(seed, x, y, per, sd, st)
  local r = ramp(st, "void")
  local n = pnoise.fbm(seed ~ SALT.void, x, y, 1 / 16, 3, per, per)
  local idx = 1 + floor(n * 2.4)
  local pc = per and per / 8 or nil
  local f1, f2 = pnoise.worley(seed ~ SALT.void ~ 0xbeef, x / 8, y / 8, pc, pc)
  -- energy veins: only where cells meet AND a slow mask allows — sparse
  -- glowing seams in the dark, not a net
  if f2 - f1 < 0.05 and n > 0.52 then
    return paint.hsv(0.50, 0.55, st.grade == "dread" and 1.0 or 0.95)
  end
  local h = prng.hash2(seed ~ SALT.void, x, y) % 1000
  if h < 6 then -- stars
    return ({ paint.hsv(0, 0, 1), paint.hsv(0.5, 0.3, 1), paint.hsv(0.9, 0.3, 1) })[h % 3 + 1]
  elseif h < 22 then
    idx = idx + 1
  end
  return r[clampi(idx, 1, #r)]
end

-- public: color of `mat` at world pixel (x,y). per/sd/st as above.
function M.shade(mat, seed, x, y, per, sd, st)
  return shade[mat](seed, x, y, per, sd, st or DEFAULT)
end

-- ---- single repeating tile (periodic mode) ----

function M.wrap_tile(mat, seed, size, st)
  size = size or 16
  st = st or DEFAULT
  local img = paint.image(size, size)
  for y = 0, size - 1 do
    for x = 0, size - 1 do
      paint.set(img, x, y, shade[mat](seed, x, y, size, nil, st))
    end
  end
  return img
end

-- ---- world-space patch (continuity demo / free-region bake) ----

function M.patch(mat, seed, gx, gy, w, h, st)
  st = st or DEFAULT
  local img = paint.image(w, h)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      paint.set(img, x, y, shade[mat](seed, gx + x, gy + y, nil, nil, st))
    end
  end
  return img
end

-- ---- the marrying bake: material map -> seamless pixels ----

-- indicator-field material pick at world pixel (x,y) over the tile grid
local function field_pick(grid, tw, th, x, y, tile, seed, st)
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
      (pnoise.fbm(seed ~ SALT[m], x, y, 1 / 12, 2) - 0.5) * st.wobble
    if f > f1 then
      m2, f2 = m1, f1
      m1, f1 = m, f
    elseif f > f2 then
      m2, f2 = m, f
    end
  end
  -- near-tie: ordered dither between the top two (a pixel-art transition band)
  local band = st.band * st.band_mul
  if band > 0 and f1 - f2 < band then
    local p = 0.5 + (f1 - f2) / band * 0.5
    if paint.bayer(4, x, y) >= p then return m2 end
  end
  return m1
end

-- bake a tile-material grid into pixels. grid[ty][tx] = material name or
-- "air" (transparent). opts: married=false → hard per-tile pick (the "before"
-- picture), gx/gy world offset, tile size (default 16), style = a style
-- instance from M.style().
function M.bake(grid, seed, opts)
  opts = opts or {}
  local tile = opts.tile or 16
  local married = opts.married ~= false
  local st = opts.style or DEFAULT
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
        mats[row + x] = field_pick(grid, tw, th, gx + x, gy + y, tile, seed, st)
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
        paint.set(img, x, y, shade[m](seed, gx + x, gy + y, nil, sd[row + x], st))
      end
    end
  end

  -- 4. tufts: grass blades poke up into the air above a grass surface
  for x = 0, W - 1 do
    for y = 1, H - 1 do
      if mats[y * W + x] == "grass" and mats[(y - 1) * W + x] == "air" then
        local h = prng.hash2(seed ~ SALT.grass, x, y) % 10
        if h < 4 then
          local g = ramp(st, "grass")
          paint.set(img, x, y - 1, g[4])
          if h < 1 then paint.set(img, x, y - 2, g[5]) end
        end
      end
    end
  end

  return img
end

return M
