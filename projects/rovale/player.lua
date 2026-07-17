-- player — the RO movement kernel: CLICK-TO-MOVE, no physics (demo 3 walks
-- where demos 1/2 run and jump). A click becomes a world point (main's
-- pick ray, sim-legal — mouse is in the input record), snaps to the
-- nearest walkable cell, A*s across the walk grid, and the player follows
-- the cell-center chain at a speed knob. Facing is a smooth sim angle,
-- snapped to 8 directions only at sprite-emit time.
--
-- Sim state = ONE buffer (ro.player): position, facing, walk phase, the
-- path (cell indices), and the click marker. Zero animation state — the
-- sheet row/frame is a pure function of (moving, dist_phase).

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local world = cm.require("world")
local spr = cm.require("cm.spr")
local walk = cm.require("cm.walk")
local mascot = cm.require("cm.mascot")

local P = select(2, ...) or {}

-- ro.player is a cm.walk WALKER buffer (layout owned/documented there):
-- [0]x [4]z [8]face [12]dist_phase [16]len [20]idx [24/28/32]marker
-- [40..] u32 path cells (PATH_MAX)
local PATH_MAX = 160
local buf

P.sheet = nil -- the baked mascot sheet (render-class)

function P.init(force_bake)
  local ok, b = pcall(pal.buf, "ro.player", 40 + PATH_MAX * 4)
  if not ok then
    pal.buf_free("ro.player")
    b = pal.buf("ro.player", 40 + PATH_MAX * 4)
  end
  buf = b
  if buf:f32(0) == 0 and buf:f32(4) == 0 then -- virgin: the path spawn
    buf:f32(0, world.spawn.x)
    buf:f32(4, world.spawn.z)
    buf:f32(8, 0)
  end
  P.sheet = spr.bake(0, mascot.fig, {
    { mascot.idle, 0 },
    { mascot.walk, 0 }, { mascot.walk, 0.25 },
    { mascot.walk, 0.5 }, { mascot.walk, 0.75 },
    { mascot.wave, 0 }, { mascot.wave, 0.5 },
  }, force_bake)
end

function P.pos()
  return buf:f32(0), buf:f32(4)
end

function P.face()
  return buf:f32(8)
end

function P.moving()
  return walk.moving(buf)
end

-- a world-point walk command (real click or the demo's synthetic one):
-- cm.walk snaps to walkable, paths, arms the marker. Returns true if a
-- path exists. Silent: the caller owns the click sfx (a held-repeat
-- re-command must not spam it — human playtest 2026-07-17).
function P.command(wx, wz)
  local k = state.doc.knobs.move
  return walk.command(buf, PATH_MAX, world.GW, world.walkable,
                      wx, wz, 4, k.marker_ttl)
end

function P.step()
  local k = state.doc.knobs.move
  walk.step(buf, world.GW, k.speed, k.turn)
end

-- sheet row + frame: pure function of the sim (walk on a distance phase)
local function anim_rc()
  local k = state.doc.knobs.move
  if P.moving() then
    local ph = buf:f32(12) / k.stride
    return 1 + math.tointeger(ph * 4 // 1) % 4
  end
  return 0
end

function P.emit(out, cam_yaw, cam_pitch)
  local k = state.doc.knobs.spr
  local x, z = buf:f32(0), buf:f32(4)
  local y = world.ground(x, z)
  local tint = 0.7 + 0.3 * world.shadow(x, z)
  local col = spr.oct(buf:f32(8), cam_yaw)
  return spr.billboard(out, P.sheet, x, y, z, k.h, col, anim_rc(), tint,
                       cam_yaw, cam_pitch)
end

function P.emit_shadow(out)
  local x, z = buf:f32(0), buf:f32(4)
  local y = world.ground(x, z)
  return spr.decal(out, x, y + 0.03, z, 0.55, 255, 255, 255, 150)
end

-- the click marker: a pulsing ground ring where the walk was ordered
function P.emit_marker(out)
  local k = state.doc.knobs.move
  local ttl = buf:f32(32)
  if ttl <= 0 then return 0 end
  local t = ttl / k.marker_ttl
  local x, z = buf:f32(24), buf:f32(28)
  local y = world.ground(x, z)
  local r = 0.45 + 0.35 * (1 - t)
  return spr.decal(out, x, y + 0.05, z, r, 255, 246, 190, (t * 220) // 1)
end

return P
