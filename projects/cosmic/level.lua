-- level — the cosmic GREYBOX map host. Unlike the sandbox's single painted
-- map, cosmic hosts MULTIPLE maps (a registry) you travel between via portals
-- (press Up). Each map module (maps/*.lua) declares its blockout geometry +
-- the annotated MARKERS that carry design intent. For the greybox, code is the
-- source of truth (use() rebuilds the buffer), so in-editor (F1) paint tweaks
-- are live-only — geometry edits go in the map module. Rich parallax/decor
-- rendering is deferred to the post-art-mockup pass (human 2026-06-29); maps
-- leave `parallax`/`decor` slots open for it.
--
-- API kept compatible with player/props/main: tm, tex, spawn{x,y}, crate_uv,
-- prop_spots, draw_bg(frame). New: markers, current, title, use(name), go(name,at).

local pix = cm.require("pix")
local tilemap = cm.require("cm.tilemap")
local gfx = cm.require("cm.gfx")
local state = cm.require("cm.state")

local M = {}

local T = 16
local STONE, GRASS, PLANK = 1, 2, 3

M.tiles = {
  [STONE] = { solid = true, u = 0, v = 0 },
  [GRASS] = { solid = true, u = 16, v = 0 },
  [PLANK] = { oneway = true, u = 32, v = 0 },
}

-- ---- tileset atlas (greybox: stone | grass | plank | crate) ----

local function build_atlas()
  local img = pix.img(64, 16)
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

  img.rect(50, 2, 12, 12, 0.62, 0.46, 0.29)          -- crate (props sub-rect)
  img.rect(50, 2, 12, 1, 0.72, 0.56, 0.36)
  img.rect(50, 13, 12, 1, 0.42, 0.30, 0.19)
  img.rect(50, 2, 1, 12, 0.48, 0.35, 0.22)
  img.rect(61, 2, 1, 12, 0.48, 0.35, 0.22)
  for i = 0, 11 do
    img.px(50 + i, 2 + i, 0.50, 0.36, 0.22)
    img.px(61 - i, 2 + i, 0.50, 0.36, 0.22)
  end
  return img.tex()
end

M.tex = build_atlas()
M.crate_uv = { u = 50, v = 2, w = 12, h = 12 }

-- ---- the map registry + the live map ----

local MAPS = {
  rim_hub = cm.require("maps.rim_hub"),
  south_trail = cm.require("maps.south_trail"),
}
M.maps = MAPS
M.order = { "rim_hub", "south_trail" } -- for a dev cycle key

-- grass-top cosmetic pass: any solid with open air above gets the grassy top
local function grass_pass(tm)
  for ty = 0, tm.h - 1 do
    for tx = 0, tm.w - 1 do
      if tm:get(tx, ty) == STONE then
        local c = M.tiles[tm:get(tx, ty - 1)]
        if not (c and c.solid) then tm:set(tx, ty, GRASS) end
      end
    end
  end
end

-- build (or rebuild) the live tilemap to map `name`. Greybox: code is the
-- source of truth, so this rebuilds the buffer (tilemap.new frees a
-- foreign-shaped one first). Mutates sim state — boot/portal call it directly
-- (no goldens/traces target this project; logic/recording comes later).
function M.use(name)
  local def = MAPS[name]
  if not def then pal.log("[level] unknown map: " .. tostring(name)); return false end
  local tm = tilemap.new{ name = "cosmic.map", w = def.w, h = def.h,
                          tile = T, tiles = M.tiles }
  tm:clear()
  def.build(tm)
  grass_pass(tm)
  M.tm, M.W, M.H = tm, tm.w, tm.h
  M.def, M.current, M.title = def, name, def.title
  M.spawn = def.spawn
  M.markers = def.markers or {}
  M.prop_spots = def.prop_spots or {}
  M.bg_tint = (def.bg and def.bg.tint) or { 1, 1, 1 }
  state.doc.map = name
  return true
end

-- portal travel: switch to `name`, return the arrival point {x,y} (the marker
-- named `at`, else the map's default spawn). Returns nil for a locked/unknown
-- destination (a "(future)" portal) so the caller leaves the player put.
function M.go(name, at)
  if not MAPS[name] then return nil end
  M.use(name)
  if at then
    for _, mk in ipairs(M.markers) do
      if mk.name == at then return { x = mk.x + mk.w * 0.5 - M.W, y = mk.y - 24 } end
    end
  end
  return M.spawn
end

-- ---- parallax backdrop (render-only placeholder; tinted per map) ----

local SKY = {
  { 0.42, 0.58, 0.80 }, { 0.47, 0.62, 0.81 }, { 0.53, 0.66, 0.82 },
  { 0.61, 0.70, 0.82 }, { 0.70, 0.74, 0.80 }, { 0.78, 0.76, 0.74 },
}

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
  local t = M.bg_tint or { 1, 1, 1 }
  gfx.layer(0)
  for i, c in ipairs(SKY) do
    pal.quad(0, (i - 1) * 45, 480, 45, c[1] * t[1], c[2] * t[2], c[3] * t[3], 1)
  end

  gfx.layer(0.16, 0.06)
  for _, s in ipairs(MOUNTAINS) do
    pal.quad(s[1], s[2], s[3], s[4],
             0.56 * s[5] * t[1], 0.59 * s[5] * t[2], 0.74 * s[5] * t[3], 1)
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
             0.33 * s[5] * t[1], 0.46 * s[5] * t[2], 0.37 * s[5] * t[3], 1)
  end
end

return M
