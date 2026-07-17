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
local spr = cm.require("spr")
local mascot = cm.require("cm.mascot")

local P = select(2, ...) or {}

-- ro.player layout: [0]x [4]z [8]face [12]dist_phase [16]u32 path_len
-- [20]u32 path_idx [24]marker x [28]marker z [32]marker ttl
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
  return buf:u32(20) < buf:u32(16)
end

-- a world-point walk command (real click or the demo's synthetic one):
-- snap to walkable, path, arm the marker. Returns true if a path exists.
-- Silent: the caller owns the click sfx (a held-repeat re-command must
-- not spam it — human playtest 2026-07-17).
function P.command(wx, wz)
  local k = state.doc.knobs.move
  local px, pz = buf:f32(0), buf:f32(4)
  local scx, scz = world.cell(px, pz)
  local gcx, gcz = world.cell(wx, wz)
  gcx, gcz = world.snap_walkable(gcx, gcz, 4)
  if not gcx then return false end
  local path = world.astar(scx, scz, gcx, gcz)
  if not path then return false end
  local n = m.min(#path, PATH_MAX)
  for i = 1, n do buf:u32(36 + i * 4, path[i]) end
  buf:u32(16, n)
  buf:u32(20, 0)
  buf:f32(24, wx)
  buf:f32(28, wz)
  buf:f32(32, k.marker_ttl)
  return true
end

function P.step()
  local k = state.doc.knobs.move
  local x, z = buf:f32(0), buf:f32(4)
  local len, idx = buf:u32(16), buf:u32(20)
  local left = k.speed / 60.0
  while idx < len and left > 1e-6 do
    local cell = buf:u32(36 + (idx + 1) * 4)
    local tx = (cell % world.GW) + 0.5
    local tz = (cell // world.GW) + 0.5
    local dx, dz = tx - x, tz - z
    local d = m.sqrt(dx * dx + dz * dz)
    if d < 1e-4 then
      idx = idx + 1
    else
      local step = m.min(d, left)
      x = x + dx / d * step
      z = z + dz / d * step
      left = left - step
      buf:f32(12, buf:f32(12) + step)
      -- ease the facing toward the travel direction (short arc)
      local want = m.atan2(dx, dz)
      local face = buf:f32(8)
      local da = m.atan2(m.sin(want - face), m.cos(want - face))
      buf:f32(8, m.fmod(face + da * k.turn, m.tau))
      if step >= d - 1e-6 then idx = idx + 1 end
    end
  end
  buf:f32(0, x)
  buf:f32(4, z)
  buf:u32(20, idx)
  buf:f32(32, m.max(0, buf:f32(32) - 1))
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
