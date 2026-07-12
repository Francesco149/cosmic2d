-- level — the smoke room: ONE room, a couple of platforms, nothing else.
-- The engine repo's minimal test cartridge (revamp R0, D046). R8a: the
-- room is a .map ASSET (room.map — colliders + markers, MAPS.md) loaded
-- through cm.map.use into a cm.collide world; the render is the graybox
-- collider fill (flat polys + accent one-ways, D057b). genmap.lua is the
-- dev regenerator until the map window edits colliders (R8c). The
-- KITCHECK choreography (demo.lua) is calibrated against THIS room + the
-- default knobs — changing either means re-choreographing (D025).

local gfx = cm.require("cm.gfx")
local map = cm.require("cm.map")

local M = {}

M.spawn = { x = 80, y = 296 }

-- load (or reload) the room from the asset. cm.map.use rebuilds the
-- world buffer ("smoke.mapc") — sim state, snapshot/trace/rewind-proof.
function M.reset(name) -- name: "room" (default) | "slopes" (the R8a proof)
  name = name or "room"
  local path = cm.main.args.project .. "/" .. name .. ".map"
  if not pal.read_file(path) then -- dev bootstrap; inert once committed
    cm.require("genmap").write(name)
  end
  local inst = map.use{ path = path, name = "smoke.mapc" }
  M.inst, M.world = inst, inst.world
  M.pw, M.ph = inst.doc.w, inst.doc.h
  for _, mk in ipairs(inst.doc.markers) do
    if mk.kind == "spawn" then M.spawn = { x = mk.x, y = mk.y } end
  end
  return true
end

-- ---- render: sky bands + the collider fill ----

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

function M.draw(camx, camy)
  map.draw_fill(M.inst, camx, camy)
end

return M
