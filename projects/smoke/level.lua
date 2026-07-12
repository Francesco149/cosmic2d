-- level — the smoke room: ONE room, a couple of platforms, nothing else.
-- The engine repo's minimal test cartridge (revamp R0, D046): a cut-down
-- cosmic greybox that carries the goldens/selftest through the revamp while
-- the game lives in ../cosmic2d-game. Geometry is code (no map.dat); the
-- KITCHECK choreography (demo.lua) is calibrated against THIS room + the
-- default knobs — changing either means re-choreographing (D025).

local pix = cm.require("pix")
local tilemap = cm.require("cm.tilemap")
local gfx = cm.require("cm.gfx")

local M = {}

local T = 16
local STONE, GRASS, PLANK = 1, 2, 3

M.tiles = {
  [STONE] = { solid = true, u = 0, v = 0 },
  [GRASS] = { solid = true, u = 16, v = 0 },
  [PLANK] = { oneway = true, u = 32, v = 0 },
}

-- ---- tileset atlas (stone | grass | plank) ----

local function build_atlas()
  local img = pix.img(48, 16)
  local n = pix.lcg(0xbeef)

  img.rect(0, 0, 16, 16, 0.36, 0.31, 0.27)          -- stone
  for _ = 1, 14 do
    img.px(math.floor(n() * 16), math.floor(n() * 16), 0.30, 0.255, 0.215)
  end
  for x = 0, 15 do img.px(x, 0, 0.41, 0.355, 0.30) end

  img.rect(16, 0, 16, 16, 0.36, 0.31, 0.27)          -- grass-topped stone
  for _ = 1, 10 do
    img.px(16 + math.floor(n() * 16), 6 + math.floor(n() * 10),
           0.30, 0.255, 0.215)
  end
  img.rect(16, 0, 16, 4, 0.27, 0.52, 0.30)
  img.rect(16, 0, 16, 2, 0.34, 0.62, 0.34)
  for x = 16, 31 do
    if n() < 0.4 then img.px(x, 4, 0.27, 0.52, 0.30) end
    if n() < 0.3 then img.px(x, 0, 0.45, 0.74, 0.42) end
  end

  img.rect(32, 0, 16, 6, 0.55, 0.41, 0.27)           -- one-way plank
  img.rect(32, 0, 16, 1, 0.66, 0.51, 0.34)
  img.rect(32, 5, 16, 1, 0.41, 0.29, 0.19)
  for _, gx in ipairs({ 36, 43 }) do
    img.px(gx, 2, 0.74, 0.70, 0.62)
    img.px(gx, 3, 0.30, 0.22, 0.15)
  end
  return img.tex()
end

M.tex = build_atlas()

-- ---- the room (50x22 tiles = 800x352 px; FOV sees 30x17) ----

M.W, M.H = 50, 22

local function build(tm)
  tm:fill(0, 0, 50, 1, STONE)          -- ceiling
  tm:fill(0, 20, 50, 2, STONE)         -- floor slab
  tm:fill(0, 0, 1, 22, STONE)          -- wall L
  tm:fill(49, 0, 1, 22, STONE)         -- wall R
  -- plank A sits above the spawn: the KITCHECK grapple target (128 px above
  -- the floor top — inside grapple_range_max 244, past min_pref 120)
  tm:fill(3, 12, 6, 1, PLANK)
  -- two more platforms for hand-play variety (out of KITCHECK's arcs)
  tm:fill(16, 15, 7, 1, PLANK)
  tm:fill(27, 10, 7, 1, PLANK)
end

-- grass-top cosmetic pass: any solid with open air above gets the grassy
-- top (ty starts at 1: the ceiling row has no "above" and stays stone)
local function grass_pass(tm)
  for ty = 1, tm.h - 1 do
    for tx = 0, tm.w - 1 do
      if tm:get(tx, ty) == STONE then
        local c = M.tiles[tm:get(tx, ty - 1)]
        if not (c and c.solid) then tm:set(tx, ty, GRASS) end
      end
    end
  end
end

-- build (or rebuild) the room. Code is the source of truth, so in-editor
-- (F1) paint tweaks are live-only; geometry edits go here.
function M.reset()
  local tm = tilemap.new{ name = "smoke.map", w = M.W, h = M.H,
                          tile = T, tiles = M.tiles }
  tm:clear()
  build(tm)
  grass_pass(tm)
  M.tm = tm
  return true
end

M.spawn = { x = 5 * T, y = 20 * T - 24 }

-- ---- backdrop: a plain sky gradient (screen-fixed; no parallax layers) ----

local SKY = {
  { 0.42, 0.58, 0.80 }, { 0.47, 0.62, 0.81 }, { 0.53, 0.66, 0.82 },
  { 0.61, 0.70, 0.82 }, { 0.70, 0.74, 0.80 }, { 0.78, 0.76, 0.74 },
}

function M.draw_bg()
  gfx.layer(0)
  for i, c in ipairs(SKY) do
    pal.quad(0, (i - 1) * 45, 480, 45, c[1], c[2], c[3], 1)
  end
end

return M
