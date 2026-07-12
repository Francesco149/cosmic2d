-- genmap — dev regenerator for room.map (R8a, MAPS.md §10). The .map FILE
-- is the committed source the cartridge boots from; this module re-emits
-- it when the geometry must change before the map window can edit
-- colliders (R8c) — after that, edit the file in the editor and delete me.
-- The geometry is the old level.lua room 1:1 on the tile edges (50x22 at
-- T=16 = 800x352): the KITCHECK choreography is calibrated against it
-- (D025).
--
--   bin/cosmic projects/smoke --headless --frames 1 \
--     --eval "print(cm.require('genmap').write())"

local map = cm.require("cm.map")

local M = {}

function M.doc()
  return {
    name = "smoke room", w = 800, h = 352, grid = 8, bg = { 1, 1, 1 },
    colliders = {
      { kind = "quad", x = 0, y = 0, w = 800, h = 16 },     -- ceiling
      { kind = "quad", x = 0, y = 320, w = 800, h = 32 },   -- floor slab
      { kind = "quad", x = 0, y = 0, w = 16, h = 352 },     -- wall L
      { kind = "quad", x = 784, y = 0, w = 16, h = 352 },   -- wall R
      -- plank A above the spawn: the KITCHECK grapple target (128 px over
      -- the floor top — inside grapple_range_max 244, past min_pref 120)
      { kind = "chain", oneway = true, verts = { 48, 192, 144, 192 } },
      -- two more platforms for hand-play variety (out of KITCHECK's arcs)
      { kind = "chain", oneway = true, verts = { 256, 240, 368, 240 } },
      { kind = "chain", oneway = true, verts = { 432, 160, 544, 160 } },
    },
    places = {},
    markers = {
      { x = 80, y = 296, w = 16, h = 24, kind = "spawn", label = "spawn",
        note = "player.init reads me", extras = { { k = "name", v = "start" } } },
    },
  }
end

function M.write()
  local path = cm.main.args.project .. "/room.map"
  return pal.write_file(path, map.encode(M.doc())) and path
end

return M
