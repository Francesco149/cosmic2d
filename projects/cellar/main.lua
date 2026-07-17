-- cellar — the naive top-down action mini-demo (A6). Two rooms: find the
-- key in the cellar, unlock the door, cross the vault, weigh the plate
-- down, take the gem. Analog + digital movement, touch/press interactions,
-- y-sorted drawing, room transitions, and pickups that persist across
-- rooms — the whole A6 top-down checklist, written DELIBERATELY NAIVELY:
-- every hand-rolled block below is a pain marker for the A5 slices.
--
--   PAIN(actor):  props/items/triggers are parallel ad-hoc tables per room;
--                 stable ids are hand-invented ("cellar:key"), iteration
--                 order is array order by construction.
--   PAIN(depth):  the y-sort comparator + rebuilt draw list every frame is
--                 boilerplate every top-down game needs.
--   resolved(query/move): this file's hand-rolled overlap loops and the
--                 axis-at-a-time wall slide moved into cm.box (A5/D090) —
--                 swarm and the demo keep their naive copies as contrast.
--
-- Everything that changes per frame lives in state.doc (snapshots, traces,
-- rewind stay exact); cm.math sin drives bobs off the sim frame count.
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m = cm.require("cm.math")
local box = cm.require("cm.box")

local W, H = pal.gfx_size()
local PW, PH = 10, 12         -- player footprint (collision is the base)
local SPEED = 1.4
local DIAG = 0.70710678

-- ---- the rooms (static data; nothing here mutates at runtime) ----------
-- walls: {x,y,w,h} solids. pillars: props with a small collision base and
-- a tall drawn body, so the player walks behind/before them (depth sort).
-- doors: edge rects that move between rooms (locked ones need the key).
local ROOMS = {
  cellar = {
    bg = { 0.11, 0.09, 0.08 },
    floor = { 0.16, 0.13, 0.11 },
    walls = {
      { 0, 0, W, 12 }, { 0, H - 8, W, 8 },
      { 0, 0, 8, H }, { W - 8, 0, 8, 66 }, { W - 8, 108, 8, H - 108 },
      { 120, 12, 8, 60 },                   -- a wall stub off the top
    },
    pillars = {
      { x = 70, y = 60 }, { x = 170, y = 52 }, { x = 226, y = 96 },
      { x = 96, y = 128 }, { x = 250, y = 132 },
    },
    key = { x = 284, y = 30 },              -- the persistent pickup
    door = { x = W - 8, y = 66, w = 8, h = 42, to = "vault", locked = true },
    spawn = { x = 24, y = 84 },
  },
  vault = {
    bg = { 0.07, 0.09, 0.12 },
    floor = { 0.10, 0.13, 0.17 },
    walls = {
      { 0, 0, W, 12 }, { 0, H - 8, W, 8 },
      { 0, 0, 8, 66 }, { 0, 108, 8, H - 108 }, { W - 8, 0, 8, H },
      { 190, 84, 8, 96 },                   -- the gate wall below the gap
    },
    pillars = {
      { x = 60, y = 48 }, { x = 130, y = 110 }, { x = 262, y = 56 },
    },
    plate = { x = 66, y = 146 },            -- stand here: the gate opens
    gate = { x = 190, y = 12, w = 8, h = 72 }, -- solid until the plate
    gem = { x = 268, y = 140 },
    door = { x = 0, y = 66, w = 8, h = 42, to = "cellar" },
    spawn = { x = 20, y = 84 },
  },
}
-- pillar geometry: the drawn body is taller than the collision base
local PILW, PILBASE, PILTALL = 16, 10, 34

local game = {}

local function reset(d)
  d.room = "cellar"
  d.x, d.y = ROOMS.cellar.spawn.x, ROOMS.cellar.spawn.y
  d.has_key = false
  d.door_open = false
  d.plate = false
  d.gem = false
  d.won = false
end

function game.init()
  input.map({ { "left", input.key.left, input.key.a, "pad:dpleft", "pad:lx-" },
              { "right", input.key.right, input.key.d, "pad:dpright", "pad:lx+" },
              { "up", input.key.up, input.key.w, "pad:dpup", "pad:ly-" },
              { "down", input.key.down, input.key.s, "pad:dpdown", "pad:ly+" },
              { "act", input.key.e, input.key.space, "pad:south" },
              { "reset", input.key.r, "pad:start" } })
  local d = state.doc
  if d.room == nil then reset(d) end
end

local function solids(room, d)
  -- walls + pillar bases + the closed gate/door, rebuilt per call
  -- PAIN(actor/query): no world to ask; every caller reassembles the set
  local list = {}
  for _, r in ipairs(room.walls) do
    list[#list + 1] = { x = r[1], y = r[2], w = r[3], h = r[4] }
  end
  for _, p in ipairs(room.pillars) do
    list[#list + 1] = { x = p.x, y = p.y, w = PILW, h = PILBASE }
  end
  if room.gate and not d.plate then
    list[#list + 1] = { x = room.gate.x, y = room.gate.y,
                        w = room.gate.w, h = room.gate.h }
  end
  if room.door and room.door.locked and not d.door_open then
    list[#list + 1] = { x = room.door.x, y = room.door.y,
                        w = room.door.w, h = room.door.h }
  end
  return list
end

local function near_door(room, d)
  if not room.door then return false end
  local ex, ey, ew, eh = box.expand(d.x, d.y, PW, PH, 6) -- interact reach
  return box.overlap_rect(ex, ey, ew, eh, room.door)
end

function game.step()
  local d = state.doc
  if input.pressed("reset") then reset(d) end
  if d.won then return end
  local room = ROOMS[d.room]

  -- movement: the analog stick wins when deflected, else digital keys;
  -- cm.box.slide is the wall-slide the topdown starter hand-rolls (A5)
  local ax = input.pad_axis(1, "lx") / 127
  local ay = input.pad_axis(1, "ly") / 127
  local dx, dy = ax * SPEED, ay * SPEED
  if ax == 0 and ay == 0 then
    local ix = (input.down("right") and 1 or 0) - (input.down("left") and 1 or 0)
    local iy = (input.down("down") and 1 or 0) - (input.down("up") and 1 or 0)
    local s = (ix ~= 0 and iy ~= 0) and SPEED * DIAG or SPEED
    dx, dy = ix * s, iy * s
  end
  d.x, d.y = box.slide(d.x, d.y, PW, PH, dx, dy, solids(room, d))

  -- touch pickups (the key persists across rooms in doc — the A6 line)
  if d.room == "cellar" and not d.has_key
     and box.touch(d.x, d.y, PW, PH, room.key, 8) then
    d.has_key = true
  end
  if d.room == "vault" and not d.gem
     and box.touch(d.x, d.y, PW, PH, room.gem, 10) then
    d.gem = true
    d.won = true
  end

  -- the pressure plate latches the gate open (walk-on trigger)
  if d.room == "vault" and not d.plate then
    local p = room.plate
    if box.overlap(d.x, d.y, PW, PH, p.x - 7, p.y - 5, 14, 10) then
      d.plate = true
    end
  end

  -- the locked door: press act while touching it, key in hand
  if room.door and room.door.locked and not d.door_open
     and near_door(room, d) and input.pressed("act") and d.has_key then
    d.door_open = true
  end

  -- room transition: walk into an open doorway's rect
  if room.door and (not room.door.locked or d.door_open)
     and box.overlap_rect(d.x, d.y, PW, PH, room.door) then
    local dest = ROOMS[room.door.to]
    d.room = room.door.to
    d.x, d.y = dest.spawn.x, dest.spawn.y
  end
end

function game.draw()
  local d = state.doc
  local room = ROOMS[d.room]
  local t = state.frame()
  pal.begin_frame(room.bg[1], room.bg[2], room.bg[3], 1)
  pal.quad(8, 12, W - 16, H - 20, room.floor[1], room.floor[2], room.floor[3], 1)
  for _, r in ipairs(room.walls) do
    pal.quad(r[1], r[2], r[3], r[4], 0.32, 0.28, 0.26, 1)
  end

  -- flat things under everything that sorts: plate, doorway, gate
  if room.plate then
    local down = d.plate
    pal.quad(room.plate.x - 7, room.plate.y - 5, 14, 10,
             down and 0.25 or 0.45, down and 0.5 or 0.42, 0.3, 1)
  end
  if room.door then
    local open = not room.door.locked or d.door_open
    pal.quad(room.door.x, room.door.y, room.door.w, room.door.h,
             open and 0.08 or 0.55, open and 0.08 or 0.42, open and 0.08 or 0.2, 1)
  end
  if room.gate and not d.plate then
    pal.quad(room.gate.x, room.gate.y, room.gate.w, room.gate.h,
             0.5, 0.55, 0.6, 1)
  end
  -- items bob just above the floor (render-only, off the sim frame)
  if d.room == "cellar" and not d.has_key then
    local k = room.key
    pal.quad(k.x - 3, k.y - 3 + m.sin(t * 0.07) * 2, 6, 6, 0.95, 0.85, 0.3, 1)
  end
  if d.room == "vault" and not d.gem then
    local g = room.gem
    pal.quad(g.x - 4, g.y - 4 + m.sin(t * 0.07) * 2, 8, 8, 0.4, 0.9, 0.85, 1)
  end

  -- PAIN(depth): the y-sort. Rebuild a draw list of pillars + player every
  -- frame and sort by base y (x, then kind, break ties deterministically).
  local list = {}
  for _, p in ipairs(room.pillars) do
    list[#list + 1] = { y = p.y + PILBASE, x = p.x, kind = 0, p = p }
  end
  list[#list + 1] = { y = d.y + PH, x = d.x, kind = 1 }
  table.sort(list, function(a, b)
    if a.y ~= b.y then return a.y < b.y end
    if a.x ~= b.x then return a.x < b.x end
    return a.kind < b.kind
  end)
  for _, e in ipairs(list) do
    if e.kind == 0 then
      local p = e.p
      pal.quad(p.x, p.y + PILBASE - PILTALL, PILW, PILTALL, 0.24, 0.21, 0.19, 1)
      pal.quad(p.x, p.y + PILBASE - PILTALL, PILW, 4, 0.38, 0.34, 0.30, 1)
      pal.quad(p.x, p.y, PILW, PILBASE, 0.20, 0.17, 0.15, 1)
    else
      pal.quad(d.x, d.y - 6, PW, PH + 6, 0.92, 0.72, 0.45, 1)
      pal.quad(d.x + 2, d.y - 4, PW - 4, 4, 0.5, 0.3, 0.2, 1)
    end
  end

  -- HUD: live binding labels, device-flavored (the D084 contract)
  local k = input.pad_connected(1) and "pad" or "key"
  local msg
  if d.won then
    msg = "you took the gem! " .. input.label("reset", k) .. " starts over"
  elseif d.room == "cellar" and room.door.locked and not d.door_open
         and near_door(room, d) then
    msg = d.has_key and (input.label("act", k) .. " unlocks the door")
          or "locked - find the key"
  else
    msg = d.room .. " - " .. (d.has_key and "key in hand" or "find the key")
  end
  text.draw(12, H - 16, msg, { r = 0.95, g = 0.92, b = 0.8, a = 0.9 })
  if d.has_key and not d.won then
    pal.quad(W - 18, H - 17, 6, 6, 0.95, 0.85, 0.3, 1)
  end
end

return game
