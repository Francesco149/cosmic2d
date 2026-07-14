-- level — the demo's two rooms + the portal between them. Each room is a
-- committed .map ASSET (town.map / overworld.map) loaded through
-- cm.map.use into one collision world, so you can open + edit them in the
-- map window (dogfooding). Markers carry the spawn, the portals, coins,
-- and a hazard; main.lua reads them for room logic + sfx.
--
-- The look is the graybox collider fill (the engine's current art path,
-- MAPS.md §5) tinted per-room from a stock palette — cozy town warm,
-- overworld cool.

local gfx = cm.require("cm.gfx")
local map = cm.require("cm.map")
local tmap = cm.require("cm.tmap")
local palette = cm.require("cm.palette")

local M = {}

local T = 16 -- lay geometry on a tidy grid

-- ---- room definitions (the dev source; written to .map on first boot) ----

local function quad(x, y, w, h) return { kind = "quad", x = x, y = y, w = w, h = h } end
local function ledge(x0, x1, y) return { kind = "chain", oneway = true, verts = { x0, y, x1, y } } end
local function coin(x, y) return { x = x, y = y, w = 10, h = 10, kind = "coin", label = "coin", extras = {} } end

local ROOMS = {}

ROOMS.town = {
  name = "cozy town", w = 880, h = 360, grid = 8, bg = { 0.20, 0.16, 0.24 },
  colliders = {
    quad(0, 344, 880, 16),   -- ground
    quad(0, 0, 16, 360),     -- wall L
    quad(864, 0, 16, 360),   -- wall R
    quad(0, 0, 880, 16),     -- ceiling
    -- town "buildings": stepped ledges to hop across
    ledge(120, 248, 296),
    ledge(300, 452, 248),
    ledge(536, 700, 288),
    ledge(700, 820, 216),
  },
  places = {},
  markers = {
    { x = 56, y = 316, w = 16, h = 24, kind = "spawn", label = "spawn", extras = {} },
    coin(180, 272), coin(372, 224), coin(612, 264),
    { x = 828, y = 296, w = 20, h = 48, kind = "portal", label = "to overworld",
      note = "walk in to travel", extras = { { k = "to", v = "overworld" } } },
  },
}

ROOMS.overworld = {
  name = "overworld", w = 1120, h = 420, grid = 8, bg = { 0.10, 0.16, 0.26 },
  colliders = {
    quad(0, 0, 16, 420),     -- wall L
    quad(1104, 0, 16, 420),  -- wall R
    quad(0, 0, 1120, 16),    -- ceiling
    -- a broken ground with a pit (hazard at the bottom), floating platforms
    quad(0, 388, 360, 32),
    quad(560, 388, 560, 32),
    ledge(360, 470, 320),
    ledge(500, 600, 264),
    ledge(200, 320, 256),
    ledge(660, 800, 300),
    ledge(840, 980, 240),
    quad(980, 300, 140, 120), -- a stepped mesa on the right
  },
  places = {},
  markers = {
    { x = 48, y = 356, w = 16, h = 24, kind = "spawn", label = "spawn", extras = {} },
    coin(408, 296), coin(548, 240), coin(260, 232), coin(910, 216),
    { x = 430, y = 402, w = 130, h = 18, kind = "hazard", label = "spikes",
      note = "the pit", extras = {} },
    { x = 1064, y = 252, w = 20, h = 48, kind = "portal", label = "to town",
      note = "walk in to travel", extras = { { k = "to", v = "town" } } },
  },
}

-- ---- load / reload a room ----

M.current = nil
M.spawn = { x = 56, y = 316 }
M.portals, M.coins, M.hazards = {}, {}, {}

function M.reset(room)
  room = room or "town"
  local proj = cm.main.args.project
  local path = proj .. "/" .. room .. ".map"
  if not pal.read_file(path) then -- dev bootstrap; inert once committed
    pal.write_file(path, map.encode(ROOMS[room]))
  end
  local inst = map.use{ path = path, name = "demo.mapc" }
  M.inst, M.world = inst, inst.world
  M.pw, M.ph = inst.doc.w, inst.doc.h
  M.current = room
  M.spawn = { x = 56, y = 316 }
  M.portals, M.coins, M.hazards = {}, {}, {}
  for i, mk in ipairs(inst.doc.markers) do
    if mk.kind == "spawn" then
      M.spawn = { x = mk.x, y = mk.y }
    elseif mk.kind == "portal" then
      local to
      for _, e in ipairs(mk.extras or {}) do if e.k == "to" then to = e.v end end
      M.portals[#M.portals + 1] = { x = mk.x, y = mk.y, w = mk.w, h = mk.h, to = to }
    elseif mk.kind == "coin" then
      M.coins[#M.coins + 1] = { x = mk.x, y = mk.y, w = mk.w, h = mk.h, id = room .. ":" .. i }
    elseif mk.kind == "hazard" then
      M.hazards[#M.hazards + 1] = { x = mk.x, y = mk.y, w = mk.w, h = mk.h }
    end
  end
  return true
end

-- ---- render ----

local SKY = {
  town = palette.load("engine/stock/pal/ember-8.pal"),
  overworld = palette.load("engine/stock/pal/frostbyte-8.pal"),
}

-- The parallax backdrop is a real .tm tilemap (demo/bg.tm) laid from the
-- stock checkerboard sprites (engine/stock/spr/tiles) — a repeating lattice
-- of distant framed blocks (top-lit id1, edges id3/4, interior id2) with a
-- lone slab for rhythm. Written on first boot, then a committed editable
-- asset (open it in the tilemap window). draw_bg tiles + dims + per-room
-- tints it under the sky. The pattern's period is 8 tiles so it wraps
-- seamlessly.
local BG_W, BG_H, BG_T = 16, 16, 16

local function bg_id(tx, ty)
  local u, v = tx % 8, ty % 8
  if u >= 2 and u <= 5 and v >= 2 and v <= 5 then -- a 4x4 framed block
    if v == 2 then return 1 end -- top surface (lit lip)
    if u == 2 then return 3 end -- left edge
    if u == 5 then return 4 end -- right edge
    return 2                    -- interior fill
  end
  if u == 0 and v == 6 then return 5 end -- a lone slab out in the gap
  return 0
end

local function build_bg()
  local doc = tmap.blank(BG_W, BG_H, BG_T, "engine/stock/spr/tiles.spr")
  for ty = 0, BG_H - 1 do
    for tx = 0, BG_W - 1 do
      local id = bg_id(tx, ty)
      if id ~= 0 then tmap.set(doc, tx, ty, id) end
    end
  end
  return doc
end

-- Load (and first-boot-write) the backdrop .tm; re-decodes on asset_epoch
-- bumps so a tilemap-window edit hot-reloads.
function M.load_bg()
  local ep = cm.asset_epoch or 0
  if M.bg and M.bg_ep == ep then return M.bg end
  local path = cm.main.args.project .. "/bg.tm"
  if not pal.read_file(path) then -- dev bootstrap; inert once committed
    pal.write_file(path, tmap.encode(build_bg()))
  end
  M.bg, M.bg_ep = tmap.decode(pal.read_file(path)), ep
  return M.bg
end

function M.draw_bg(camx, camy)
  local paint = cm.require("cm.paint")
  local cols = SKY[M.current] and SKY[M.current].colors
  -- 1) a screen-fixed sky gradient (light top -> darker horizon), read from
  --    the room's stock palette (ember = warm dusk, frostbyte = cool day)
  gfx.layer(0)
  if cols and #cols >= 7 then
    local bands = 8
    local bh = 270 // bands + 1
    for i = 0, bands - 1 do
      local t = i / (bands - 1)
      local ci = math.floor(7 - t * 4 + 0.5)
      local r, g, b = paint.unpack(cols[math.max(1, math.min(#cols, ci))])
      pal.quad(0, i * bh, 480, bh, r / 255, g / 255, b / 255, 1)
    end
  end
  -- 2) the checkerboard-tilemap parallax backdrop (demo/bg.tm) — tiled to
  --    cover the view, dimmed, and tinted from the room palette; scrolls at
  --    ~40% so it reads as distant structures. The VFX/LUT layer recolors
  --    the whole vibe later.
  if cols and #cols >= 5 then
    local bg = M.load_bg()
    local tex = gfx.texture("engine/stock/spr/tiles.png")
    gfx.layer(0.4, 0.45)
    local lx, ly = (camx or 0) * 0.4, (camy or 0) * 0.45
    local pw, ph = bg.w * bg.tile, bg.h * bg.tile
    local vw, vh = pal.gfx_size()
    local r, g, b = paint.unpack(cols[3])
    r, g, b = r / 255, g / 255, b / 255
    for oy = math.floor(ly / ph) * ph, ly + vh, ph do
      for ox = math.floor(lx / pw) * pw, lx + vw, pw do
        tmap.draw(bg, tex, ox, oy, lx, ly, r, g, b, 0.28)
      end
    end
  end
end

-- per-room MOOD grade (M10, cm.grade) — a render-only color-grade pass over
-- the whole composite: warm/golden town, cool/crisp overworld. Set each
-- frame (reset by begin_frame); never sim.
local GRADE = { town = "warm", overworld = "cool" }
function M.grade()
  cm.require("cm.grade").preset(GRADE[M.current] or "none")
end

function M.collected() -- sim-state set of picked-up coin ids
  local d = cm.require("cm.state").doc
  d.coins = d.coins or {}
  return d.coins
end

function M.draw(camx, camy)
  map.draw_fill(M.inst, camx, camy)
  map.draw_places(M.inst, camx, camy)
  -- everything below draws in WORLD coords — gfx.camera (pal.camera) does
  -- the screen offset, so no cam subtraction (that was the parallax bug)
  local frame = cm.require("cm.state").frame()
  local got = M.collected()
  for _, c in ipairs(M.coins) do
    if not got[c.id] then
      local bob = math.floor(2.5 * cm.require("cm.math").sin(frame * 0.12 + c.x))
      pal.quad(c.x, c.y + bob, c.w, c.h, 0.98, 0.82, 0.28, 1)
      pal.quad(c.x + 2, c.y + bob + 2, c.w - 4, c.h - 4, 1.0, 0.95, 0.6, 1)
    end
  end
  for _, h in ipairs(M.hazards) do
    pal.quad(h.x, h.y, h.w, h.h, 0.72, 0.16, 0.20, 1)
    local n = math.max(1, h.w // 10)
    for i = 0, n - 1 do
      pal.quad(h.x + i * 10 + 2, h.y - 4, 6, 5, 0.86, 0.24, 0.26, 1)
    end
  end
end

return M
