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
  -- the level VISUALS are a checkerboard tilemap autotiled from the colliders
  -- (MAPS.md §5 end state) — colliders themselves render nothing in game.
  M.fg = tmap.graybox(inst.doc, { tile = 16,
                                  tileset = "engine/stock/spr/tiles.spr" })
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

-- The background is a parallax LANDSCAPE: two silhouette tilemap layers (far
-- mountains, near hills) laid from the stock checker tiles, colorized from the
-- room palette and scrolled at different depths. All the background COLOR
-- lives in these tinted tiles — there's no separate sky gradient to drift out
-- of sync; a flat per-room sky sits behind. Built in memory (procedural,
-- deterministic; math.sin here is render-only, never sim). SIL_W = the page
-- width in tiles = the horizontal period, so the wrap is seamless.
local SIL_W = 48

-- a silhouette layer: SIL_W x H tiles, filled below an undulating ridge. rmax
-- is the ridge height in tiles; phase shifts the contour so layers differ.
local function build_sil(H, rmax, phase)
  local doc = tmap.blank(SIL_W, H, 16, "engine/stock/spr/tiles.spr")
  local w = 2 * math.pi / SIL_W
  for tx = 0, SIL_W - 1 do
    local n = math.sin(w * tx + phase) + 0.5 * math.sin(w * tx * 2 + phase * 1.7)
              + 0.3 * math.sin(w * tx * 3 + phase * 2.3)
    local r = math.floor((n + 1.8) / 3.6 * rmax + 0.5)
    if r < 0 then r = 0 elseif r > rmax then r = rmax end
    for ty = rmax - r, H - 1 do
      tmap.set(doc, tx, ty, ty == rmax - r and 1 or 2) -- lit ridge / mass
    end
  end
  return doc
end

local sil_far, sil_near
local function silhouettes()
  if not sil_far then
    sil_far = build_sil(22, 13, 0.0)  -- distant mountains (taller)
    sil_near = build_sil(22, 8, 2.3)  -- nearer rolling hills
  end
  return sil_far, sil_near
end

-- draw the silhouette OPAQUE, tiled horizontally at a world `top` (row-0 y),
-- tinted; a small muly gives a gentle vertical drift. Opaque = no muddy
-- inter-layer blend (the checker tiles are solid).
local function draw_sil(doc, tex, mulx, muly, top, camx, camy, r, g, b)
  gfx.layer(mulx, muly)
  local lx, ly = (camx or 0) * mulx, (camy or 0) * muly
  local pw, vw = doc.w * doc.tile, pal.gfx_size()
  for ox = math.floor(lx / pw) * pw, lx + vw, pw do
    tmap.draw(doc, tex, ox, top, lx, ly, r, g, b, 1)
  end
end

function M.draw_bg(camx, camy)
  local paint = cm.require("cm.paint")
  local cols = SKY[M.current] and SKY[M.current].colors
  if not (cols and #cols >= 7) then return end
  local tex = gfx.texture("engine/stock/spr/tiles.png")
  local function col(i)
    local r, g, b = paint.unpack(cols[i])
    return r / 255, g / 255, b / 255
  end
  -- 1) a flat per-room sky (screen-fixed; a flat fill can't reveal a parallax
  --    mismatch the way the old moving gradient did)
  gfx.layer(0)
  local sr, sg, sb = col(6)
  pal.quad(0, 0, 480, 270, sr, sg, sb, 1)
  -- 2) two opaque silhouette layers from the checker tiles — distant mountains
  --    (lighter/hazier, slow) behind nearer hills (darker, fast). Opaque, so
  --    the near layer cleanly occludes the far one (no muddy blend). Tinted
  --    dark room shades = a colorized landscape that all moves together.
  local far, near = silhouettes()
  local fr, fg, fb = col(4)
  draw_sil(far, tex, 0.18, 0.09, 58, camx, camy, fr, fg, fb)
  local nr, ng, nb = col(3)
  draw_sil(near, tex, 0.36, 0.15, 106, camx, camy, nr, ng, nb)
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
  -- the level geometry as a checkerboard tilemap (colliders render NOTHING —
  -- placed tiles + sprites make every visual, MAPS.md §5); gfx.layer(1) is
  -- already set by main.draw, so world coords draw straight.
  if M.fg then
    tmap.draw(M.fg, gfx.texture("engine/stock/spr/tiles.png"), 0, 0, camx, camy)
  end
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
