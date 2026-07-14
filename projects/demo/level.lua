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

function M.draw_bg()
  gfx.layer(0)
  local pal_doc = SKY[M.current]
  local cols = pal_doc and pal_doc.colors
  if not (cols and #cols >= 7) then return end
  -- a sky gradient from a LIGHT band at the top down to a darker horizon,
  -- read from the room's stock palette (ember = warm dusk, frostbyte =
  -- cool day). The caller cleared via pal.begin_frame; these paint over it.
  local paint = cm.require("cm.paint")
  local bands = 8
  local bh = 270 // bands + 1
  for i = 0, bands - 1 do
    local t = i / (bands - 1)
    local ci = math.floor(7 - t * 4 + 0.5) -- top ~7 (light) -> bottom ~3
    local r, g, b = paint.unpack(cols[math.max(1, math.min(#cols, ci))])
    pal.quad(0, i * bh, 480, bh, r / 255, g / 255, b / 255, 1)
  end
end

function M.collected() -- sim-state set of picked-up coin ids
  local d = cm.require("cm.state").doc
  d.coins = d.coins or {}
  return d.coins
end

function M.draw(camx, camy)
  map.draw_fill(M.inst, camx, camy)
  map.draw_places(M.inst, camx, camy)
  local frame = cm.require("cm.state").frame()
  local got = M.collected()
  -- coins: a little bobbing gold pickup
  for _, c in ipairs(M.coins) do
    if not got[c.id] then
      local bob = math.floor(2.5 * cm.require("cm.math").sin(frame * 0.12 + c.x))
      pal.quad(c.x - camx, c.y - camy + bob, c.w, c.h, 0.98, 0.82, 0.28, 1)
      pal.quad(c.x - camx + 2, c.y - camy + bob + 2, c.w - 4, c.h - 4, 1.0, 0.95, 0.6, 1)
    end
  end
  -- hazards: red spikes
  for _, h in ipairs(M.hazards) do
    pal.quad(h.x - camx, h.y - camy, h.w, h.h, 0.72, 0.16, 0.20, 1)
    local n = math.max(1, h.w // 10)
    for i = 0, n - 1 do
      pal.quad(h.x - camx + i * 10 + 2, h.y - camy - 4, 6, 5, 0.86, 0.24, 0.26, 1)
    end
  end
end

return M
