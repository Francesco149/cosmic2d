-- level — the sandbox map: procedural tileset, the tile grid, parallax
-- backdrop. Since M4 the map is NOT code-built: whatever "sandbox.map"
-- buffer exists is adopted as-is (painted state survives hot reloads, VM
-- reboots and snapshot restores untouched); only when there is no buffer
-- at all does boot seed one — from map.dat next to project.lua if saved,
-- else from the procedural build. The build lives on as M.reset(), the
-- editor's reset button / `game.level.reset()` in the console (an eval,
-- so it records into traces — D026). M.save() writes map.dat (the raw
-- self-describing buffer bytes); M.load() is boot-time only, because file
-- contents are not sim input and would not replay.

local pix = cm.require("pix")
local tilemap = cm.require("cm.tilemap")
local gfx = cm.require("cm.gfx")

local M = {}

local T = 16
local MAPW, MAPH = 90, 40 -- the procedural layout's shape (reset target)

-- ---- tile classes (collision meaning lives in code, travels in bundles) --

local STONE, GRASS, PLANK = 1, 2, 3

M.tiles = {
  [STONE] = { solid = true, u = 0, v = 0 },
  [GRASS] = { solid = true, u = 16, v = 0 },
  [PLANK] = { oneway = true, u = 32, v = 0 },
}

-- ---- tileset atlas (64x16: stone | grass | plank | crate) ----

local function build_atlas()
  local img = pix.img(64, 16)
  local n = pix.lcg(0xbeef)

  -- stone fill
  img.rect(0, 0, 16, 16, 0.36, 0.31, 0.27)
  for _ = 1, 14 do
    img.px(math.floor(n() * 16), math.floor(n() * 16), 0.30, 0.255, 0.215)
  end
  for x = 0, 15 do img.px(x, 0, 0.41, 0.355, 0.30) end

  -- grass-topped stone
  img.rect(16, 0, 16, 16, 0.36, 0.31, 0.27)
  for _ = 1, 10 do
    img.px(16 + math.floor(n() * 16), 6 + math.floor(n() * 10),
           0.30, 0.255, 0.215)
  end
  img.rect(16, 0, 16, 4, 0.27, 0.52, 0.30)
  img.rect(16, 0, 16, 2, 0.34, 0.62, 0.34)
  for x = 16, 31 do
    if n() < 0.4 then img.px(x, 4, 0.27, 0.52, 0.30) end -- notched edge
    if n() < 0.3 then img.px(x, 0, 0.45, 0.74, 0.42) end -- light blades
  end

  -- one-way plank (top 6px board, rest transparent)
  img.rect(32, 0, 16, 6, 0.55, 0.41, 0.27)
  img.rect(32, 0, 16, 1, 0.66, 0.51, 0.34)
  img.rect(32, 5, 16, 1, 0.41, 0.29, 0.19)
  for _, gx in ipairs({ 36, 43 }) do
    img.px(gx, 2, 0.74, 0.70, 0.62) -- nails
    img.px(gx, 3, 0.30, 0.22, 0.15)
  end
  img.px(40, 1, 0.45, 0.33, 0.21)
  img.px(40, 2, 0.45, 0.33, 0.21) -- grain
  img.px(40, 3, 0.45, 0.33, 0.21)

  -- crate (12x12 at 50,2 — props sample this sub-rect)
  img.rect(50, 2, 12, 12, 0.62, 0.46, 0.29)
  img.rect(50, 2, 12, 1, 0.72, 0.56, 0.36)
  img.rect(50, 13, 12, 1, 0.42, 0.30, 0.19)
  img.rect(50, 2, 1, 12, 0.48, 0.35, 0.22)
  img.rect(61, 2, 1, 12, 0.48, 0.35, 0.22)
  for i = 0, 11 do -- X brace
    img.px(50 + i, 2 + i, 0.50, 0.36, 0.22)
    img.px(61 - i, 2 + i, 0.50, 0.36, 0.22)
  end
  return img.tex()
end

M.tex = build_atlas()
M.crate_uv = { u = 50, v = 2, w = 12, h = 12 } -- sub-rect in M.tex

-- ---- the map ----

-- rebuild the procedural layout (frees a foreign-shaped buffer first).
-- Sim-mutating: live callers go through the eval path (editor reset
-- button, console `game.level.reset()`); boot seeding calls it directly.
function M.reset()
  local tm = tilemap.new{ name = "sandbox.map", w = MAPW, h = MAPH,
                          tile = T, tiles = M.tiles }
  M.tm, M.W, M.H = tm, tm.w, tm.h
  tm:clear()

  tm:fill(0, 36, 90, 4, STONE) -- the ground slab
  tm:fill(52, 36, 13, 2, 0) -- the prop pit (floor stays at row 38)

  tm:fill(30, 34, 11, 2, STONE) -- mid plateau
  tm:fill(46, 34, 2, 2, STONE) -- pillar before the pit
  tm:fill(0, 25, 6, 1, STONE) -- high-left balcony (full jump from plank 4)
  tm:fill(84, 28, 6, 1, STONE) -- high-right balcony

  -- left tower (each rise is 2 rows; jump apex is ~3.5)
  tm:fill(10, 34, 5, 1, PLANK)
  tm:fill(17, 32, 5, 1, PLANK)
  tm:fill(10, 30, 5, 1, PLANK)
  tm:fill(3, 28, 5, 1, PLANK)

  -- over the plateau, then drifting right above the pit (crate-drop spot)
  tm:fill(32, 31, 5, 1, PLANK)
  tm:fill(38, 29, 5, 1, PLANK)
  tm:fill(45, 27, 5, 1, PLANK)
  tm:fill(52, 25, 5, 1, PLANK)
  tm:fill(59, 23, 5, 1, PLANK)

  -- right stairs out of the pit side
  tm:fill(68, 34, 5, 1, PLANK)
  tm:fill(75, 32, 5, 1, PLANK)
  tm:fill(82, 30, 5, 1, PLANK)

  -- grass pass: any solid with open air above gets the grassy top
  for ty = 0, MAPH - 1 do
    for tx = 0, MAPW - 1 do
      if tm:get(tx, ty) == STONE then
        local above = tm:get(tx, ty - 1)
        local c = M.tiles[above]
        if not (c and c.solid) then tm:set(tx, ty, GRASS) end
      end
    end
  end
end

local function map_file()
  return cm.main.args.project .. "/map.dat"
end

-- persist the live map next to project.lua (the editor's save button).
-- Pure read of sim state: safe to call directly, no eval needed.
function M.save()
  return tilemap.save("sandbox.map", map_file())
end

-- adopt a saved map.dat (boot-time only — see the header note)
function M.load()
  if not tilemap.load("sandbox.map", map_file()) then return false end
  local tm = tilemap.open("sandbox.map", M.tiles)
  M.tm, M.W, M.H = tm, tm.w, tm.h
  pal.log("[level] map.dat adopted (" .. tm.w .. "x" .. tm.h .. ")")
  return true
end

-- adopt whatever map buffer exists (any shape — reloads/reboots/restores
-- never stomp painted cells); seed only when there is none
do
  local ok, tm = pcall(tilemap.open, "sandbox.map", M.tiles)
  if ok then
    M.tm, M.W, M.H = tm, tm.w, tm.h
  elseif not M.load() then
    M.reset()
  end
end

M.spawn = { x = 6 * T, y = 36 * T - 14 } -- on the ground, left area

-- initial crate spots (constants: init must not draw from cm.rand)
M.prop_spots = {
  { 54 * T + 2, 38 * T - 12 }, { 56 * T + 6, 38 * T - 12 },
  { 58 * T + 1, 38 * T - 12 }, { 60 * T + 5, 38 * T - 12 },
  { 62 * T + 3, 38 * T - 12 }, { 55 * T + 8, 38 * T - 24 },
  { 57 * T + 9, 38 * T - 24 }, { 59 * T + 7, 38 * T - 24 },
  { 61 * T + 2, 38 * T - 24 }, { 58 * T + 4, 38 * T - 36 },
  { 70 * T + 4, 36 * T - 12 }, { 26 * T + 2, 36 * T - 12 },
}

-- ---- parallax backdrop (render-only, shapes precomputed once) ----

local SKY = {
  { 0.42, 0.58, 0.80 }, { 0.47, 0.62, 0.81 }, { 0.53, 0.66, 0.82 },
  { 0.61, 0.70, 0.82 }, { 0.70, 0.74, 0.80 }, { 0.78, 0.76, 0.74 },
}

-- stepped pixel silhouettes as flat quad lists {x, y, w, h, shade}, baked
-- once. Built base-up (widest band at the bottom), the lowest band gets a
-- skirt down past base_y. Layers use mul_y ~ 0.1 (mostly-horizontal
-- parallax), so y here is close to screen space.
local function silhouettes(seed, span, base_y, peak_lo, peak_hi, step, taper)
  local n = pix.lcg(seed)
  local quads = {}
  local x = -40
  while x < span do
    local w = 56 + math.floor(n() * 84)
    local peak = peak_lo + math.floor(n() * (peak_hi - peak_lo))
    local shade = 0.94 + n() * 0.12
    local k = 0
    local sx, sw = x, w
    while k * step < peak and sw > 4 do
      quads[#quads + 1] = { sx, base_y - (k + 1) * step, sw,
                            k == 0 and step + 60 or step, shade }
      k = k + 1
      sx = sx + taper * step
      sw = sw - 2 * taper * step
    end
    x = x + w * 0.8 + n() * 30
  end
  return quads
end

local MOUNTAINS = silhouettes(0x5e44, 960 * 0.16 + 560, 250, 80, 150, 9, 0.55)
local HILLS = silhouettes(0xa17c, 960 * 0.36 + 560, 300, 60, 130, 6, 0.65)

local CLOUDS = {}
do
  local n = pix.lcg(0xc10d)
  for i = 1, 7 do
    CLOUDS[i] = { base = n() * 800, y = 30 + n() * 130,
                  w = 30 + n() * 40, spd = 0.05 + n() * 0.06 }
  end
end

-- draw back-to-front; gfx.camera must already be set for this frame
function M.draw_bg(frame)
  gfx.layer(0)
  for i, c in ipairs(SKY) do
    pal.quad(0, (i - 1) * 45, 480, 45, c[1], c[2], c[3], 1)
  end

  gfx.layer(0.16, 0.06)
  for _, s in ipairs(MOUNTAINS) do
    pal.quad(s[1], s[2], s[3], s[4],
             0.56 * s[5], 0.59 * s[5], 0.74 * s[5], 1)
  end

  gfx.layer(0.25, 0.08)
  for _, c in ipairs(CLOUDS) do
    local span = 960 * 0.25 + 480 + 120
    local x = (c.base + frame * c.spd) % span - 60
    pal.quad(x, c.y, c.w, 7, 0.93, 0.94, 0.97, 0.85)
    pal.quad(x + c.w * 0.2, c.y - 4, c.w * 0.55, 5, 0.96, 0.96, 0.99, 0.85)
    pal.quad(x + c.w * 0.15, c.y + 7, c.w * 0.7, 4, 0.88, 0.90, 0.95, 0.7)
  end

  gfx.layer(0.36, 0.10)
  for _, s in ipairs(HILLS) do
    pal.quad(s[1], s[2], s[3], s[4],
             0.33 * s[5], 0.46 * s[5], 0.37 * s[5], 1)
  end
end

return M
