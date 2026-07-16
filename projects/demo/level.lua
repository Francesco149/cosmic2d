-- level — the demo's two rooms + the portal between them. Each room is a
-- committed .map ASSET (town.map / overworld.map) loaded through
-- cm.map.use into one collision world, so you can open + edit them in the
-- map window (dogfooding). Markers carry the spawn, the portals, coins,
-- and a hazard; main.lua reads them for room logic + sfx.
--
-- The look is 100% PLACED sprites (D061): each room's .map carries a
-- **backdrop** layer (a static hill-silhouette .tm, named so code can reach
-- it) behind a **ground** layer (the colliders autotiled into a .tm) — both
-- render in the map editor. Colliders draw nothing. A per-room grade adds
-- the mood (warm town / cool overworld).

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

-- ---- the sprite-only visuals: two placed tilemaps per room (D061) ----
-- The look is 100% PLACED sprites now (no runtime graybox, no procedural
-- parallax): a **ground** layer (the collider geometry autotiled into a
-- .tm, so it renders in the map editor too) behind which a **backdrop**
-- layer sits — a static hill silhouette .tm, named "backdrop" so code can
-- reach it via cm.map.ref("backdrop"). Colliders render nothing (nofill).

-- a static hill silhouette across the whole room (build-time asset gen —
-- math.sin is fine here, it's not sim; the .tm is committed)
local function build_backdrop(def, tileset)
  local w = math.max(1, math.ceil(def.w / T))
  local h = math.max(1, math.ceil(def.h / T))
  local hills = math.max(3, math.floor(h * 0.55)) -- fill the lower ~half
  local td = tmap.blank(w, h, T, tileset)
  local period = 2 * math.pi / w
  for tx = 0, w - 1 do
    local n = math.sin(period * tx) + 0.5 * math.sin(period * tx * 2 + 1.7)
              + 0.3 * math.sin(period * tx * 3 + 2.3)
    local ridge = math.floor((h - hills) + (1 - (n + 1.8) / 3.6) * hills + 0.5)
    if ridge < 0 then ridge = 0 elseif ridge > h - 1 then ridge = h - 1 end
    for ty = ridge, h - 1 do
      tmap.set(td, tx, ty, ty == ridge and 1 or 2) -- lit ridge / mass
    end
  end
  return td
end

-- the axis-aligned bounds of any collider (map px)
local function collider_bounds(c)
  if c.kind == "quad" then return c.x, c.y, c.w, c.h end
  if c.kind == "circle" then return c.cx - c.r, c.cy - c.r, 2 * c.r, 2 * c.r end
  local minx, miny, maxx, maxy = 1e9, 1e9, -1e9, -1e9
  for i = 1, #c.verts, 2 do
    local x, y = c.verts[i], c.verts[i + 1]
    minx = math.min(minx, x); maxx = math.max(maxx, x)
    miny = math.min(miny, y); maxy = math.max(maxy, y)
  end
  return minx, miny, maxx - minx, maxy - miny
end

local function shift_collider(c, dx, dy)
  if c.kind == "quad" then
    return { kind = "quad", x = c.x + dx, y = c.y + dy, w = c.w, h = c.h }
  elseif c.kind == "circle" then
    return { kind = "circle", cx = c.cx + dx, cy = c.cy + dy, r = c.r }
  end
  local v = {}
  for i = 1, #c.verts, 2 do v[i], v[i + 1] = c.verts[i] + dx, c.verts[i + 1] + dy end
  return { kind = "chain", oneway = c.oneway, closed = c.closed, verts = v }
end

-- a shape-keyed name so identical pieces (both walls, the floor + ceiling)
-- share ONE asset placed at several spots
local function piece_name(c, bw, bh)
  if c.kind == "chain" then return ("platform_%d"):format(bw) end
  if c.kind == "quad" then
    if bh <= 2 * T and bw > 4 * T then return ("floor_%d"):format(bw) end
    if bw <= 2 * T and bh > 4 * T then return ("wall_%d"):format(bh) end
    return ("block_%dx%d"):format(bw, bh)
  end
  return ("blob_%d"):format(bw)
end

-- generate a room's .map + its .tm assets (dev bootstrap; inert once the files
-- are committed). The geometry is SPLIT into small reusable pieces: each
-- collider becomes its own placed .tm (autotiled in isolation, deduped by
-- shape), so a platform is a separate object you can drag/edit/delete without
-- moving the whole map. The backdrop stays a single room-sized tilemap.
local function bootstrap_room(def, room, proj)
  local tiles = "art/tiles.spr"
  pal.write_file(proj .. "/" .. room .. "_bg.tm",
                 tmap.encode(build_backdrop(def, tiles)))
  local places = { { path = room .. "_bg.tm", x = 0, y = 0, layer = 1,
                     name = "backdrop" } }
  local made = {}
  for _, c in ipairs(def.colliders) do
    local bx, by, bw, bh = collider_bounds(c)
    bw, bh = math.max(T, math.floor(bw + 0.5)), math.max(T, math.floor(bh + 0.5))
    local file = piece_name(c, bw, bh) .. ".tm"
    if not made[file] then
      made[file] = true
      local piece = tmap.graybox(
        { w = bw, h = bh, colliders = { shift_collider(c, -bx, -by) }, places = {} },
        { tile = T, tileset = tiles })
      pal.write_file(proj .. "/" .. file, tmap.encode(piece))
    end
    places[#places + 1] = { path = file, x = math.floor(bx + 0.5),
                            y = math.floor(by + 0.5), layer = 2 }
  end
  return map.encode {
    name = def.name, w = def.w, h = def.h, grid = def.grid, bg = def.bg,
    nofill = true, -- colliders draw nothing; the placed tilemaps ARE the art
    layers = { { name = "backdrop", vis = true, on = true },
               { name = "ground", vis = true, on = true } },
    colliders = def.colliders,
    places = places,
    markers = def.markers,
  }
end

-- ---- load / reload a room ----

M.current = nil
M.spawn = { x = 56, y = 316 }
M.portals, M.coins, M.hazards = {}, {}, {}

-- Everything below is a DERIVED view of cm.map's captured runtime slot. Map
-- restore keeps the instance identity and bumps inst.rev; one sync refreshes
-- every copied convenience field, so parked drawing cannot mix past movement
-- with the present room's markers/title/background.
function M.sync()
  local inst = map.current() or map.sync(M.inst)
  if not inst then return false end
  local room = inst.path and inst.path:match("([^/]+)%.map$")
               or cm.require("cm.state").doc.room or "town"
  if M._map_rev == inst.rev and M.current == room then return true end

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
      M.portals[#M.portals + 1] =
        { x = mk.x, y = mk.y, w = mk.w, h = mk.h, to = to }
    elseif mk.kind == "coin" then
      M.coins[#M.coins + 1] =
        { x = mk.x, y = mk.y, w = mk.w, h = mk.h, id = room .. ":" .. i }
    elseif mk.kind == "hazard" then
      M.hazards[#M.hazards + 1] = { x = mk.x, y = mk.y, w = mk.w, h = mk.h }
    end
  end
  M._map_rev = inst.rev
  return true
end

function M.reset(room)
  room = room or "town"
  local proj = cm.main.args.project
  local path = proj .. "/" .. room .. ".map"
  if not pal.read_file(path) then -- dev bootstrap; inert once committed
    pal.write_file(path, bootstrap_room(ROOMS[room], room, proj))
  end
  local inst = map.use{ path = path, name = "demo.mapc" }
  M.inst = inst
  return M.sync()
end

-- ---- render ----

local SKY = {
  town = palette.load("engine/stock/pal/ember-8.pal"),
  overworld = palette.load("engine/stock/pal/frostbyte-8.pal"),
}

-- The landscape is now a PLACED backdrop layer inside the .map (world-space,
-- not parallaxed — it's just placed there, named "backdrop"). All that's left
-- to draw here is a flat per-room sky behind it (screen-fixed base color).
function M.draw_bg(camx, camy)
  M.sync()
  local paint = cm.require("cm.paint")
  local cols = SKY[M.current] and SKY[M.current].colors
  if not (cols and #cols >= 7) then return end
  local r, g, b = paint.unpack(cols[6])
  gfx.layer(0)
  pal.quad(0, 0, 480, 270, r / 255, g / 255, b / 255, 1)
end

-- per-room MOOD grade (M10, cm.grade) — a render-only color-grade pass over
-- the whole composite: warm/golden town, cool/crisp overworld. Set each
-- frame (reset by begin_frame); never sim.
local GRADE = { town = "warm", overworld = "cool" }
function M.grade()
  M.sync()
  cm.require("cm.grade").preset(GRADE[M.current] or "none")
end

function M.collected() -- sim-state set of picked-up coin ids
  local d = cm.require("cm.state").doc
  d.coins = d.coins or {}
  return d.coins
end

function M.draw(camx, camy)
  M.sync()
  -- every visual is a PLACED sprite/tilemap now (the backdrop + ground layers
  -- in the .map); colliders render nothing. gfx.layer(1) is already set by
  -- main.draw, so world coords draw straight.
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
