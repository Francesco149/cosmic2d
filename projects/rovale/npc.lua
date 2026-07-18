-- npc — the vale's three locals: mascot COLOR VARIANTS (cm.mascot.build
-- casts them, the D3D-020 pattern) baked to their own sprite sheets,
-- walking small walk-grid-verified routes. Come close and they stop, face
-- you, wave (the baked wave rows), ring the greet bell, and a line types
-- out on the HUD; leave past exit_r and they walk on (hysteresis, one
-- chime per visit — the openworld exchange grammar on billboards).
--
-- Sim state per NPC = ONE buffer (ro.npc<i>): position, facing, waypoint,
-- greet-start frame+1, re-arm flag, walk phase, line index. Wave/dialog
-- are pure functions of (buffer, frame).

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local world = cm.require("world")
local spr = cm.require("cm.spr")
local mascot = cm.require("cm.mascot")
local player = cm.require("player")
local audio = cm.require("audio")

local N = select(2, ...) or {}

-- variants: body/mitt overrides that read as "another one of them"
-- without ever being mistaken for the player (openworld's casting rule)
local DEFS = {
  { name = "greeter", -- plaza host, coral
    over = { body = { 0.85, 0.45, 0.38 }, mitt = { 0.30, 0.62, 0.60 } },
    route = { { 36.0, 27.5 }, { 39.5, 29.5 }, { 43.5, 27.0 }, { 44.5, 23.0 },
              { 41.5, 28.0 } },
    lines = { "welcome to the vale!",
              "the gazebo is older than the pond.",
              "market day was yesterday. always is." } },
  { name = "wanderer", -- path walker, lavender
    over = { body = { 0.62, 0.55, 0.78 }, mitt = { 0.45, 0.62, 0.35 } },
    -- starts mid-path: waypoint 1 is also the spawn pose, and the player
    -- spawns near the south end — no boot-frame greet
    route = { { 25.5, 41.0 }, { 25.5, 37.0 }, { 27.5, 33.0 }, { 27.0, 40.0 },
              { 29.5, 48.0 }, { 31.5, 52.5 }, { 27.0, 46.0 } },
    lines = { "the path goes where the water lets it.",
              "i count the fence posts. eleven, today.",
              "you walk like you have somewhere to be." } },
  { name = "angler", -- pond bank, moss
    over = { body = { 0.45, 0.58, 0.38 }, mitt = { 0.94, 0.80, 0.42 } },
    route = { { 29.5, 44.5 }, { 31.5, 46.5 }, { 30.5, 49.0 }, { 28.8, 46.8 } },
    lines = { "the fish ignore me today.",
              "shallow water, deep thoughts.",
              "saw a star fall past the far bank once." } },
}

N.list = {}

function N.init(force_bake)
  N.list = {}
  for i, d in ipairs(DEFS) do
    local name = "ro.npc" .. i
    local ok, b = pcall(pal.buf, name, 32)
    if not ok then
      pal.buf_free(name)
      b = pal.buf(name, 32)
    end
    if b:f32(0) == 0 and b:f32(4) == 0 then
      b:f32(0, d.route[1][1])
      b:f32(4, d.route[1][2])
      b:u32(12, 1)
    end
    N.list[i] = {
      def = d, buf = b, buf_name = name,
      sheet = spr.bake(i, mascot.build(d.over), {
        { mascot.idle, 0 },
        { mascot.walk, 0 }, { mascot.walk, 0.25 },
        { mascot.walk, 0.5 }, { mascot.walk, 0.75 },
        { mascot.wave, 0 }, { mascot.wave, 0.5 },
      }, force_bake),
    }
  end
end

-- greeting is DERIVED per step: greet-start frame+1 in the buffer, zero
-- when idle; armed flag re-arms past exit_r
local function step_one(n)
  local k = state.doc.knobs.npc
  local b = n.buf
  local x, z = b:f32(0), b:f32(4)
  local px, pz = player.pos()
  local dx, dz = px - x, pz - z
  local d2 = dx * dx + dz * dz
  local greeting = b:u32(16) ~= 0
  if greeting then
    if d2 > k.exit_r * k.exit_r then
      b:u32(16, 0) -- walk on; re-arm happens out here too
      b:u32(20, 0)
    else
      -- hold: face the player (eased), the wave/dialog read the buffer
      local want = m.atan2(dx, dz)
      local face = b:f32(8)
      local da = m.atan2(m.sin(want - face), m.cos(want - face))
      b:f32(8, m.fmod(face + da * k.turn, m.tau))
      return
    end
  end
  if d2 < k.greet_r * k.greet_r and b:u32(20) == 0 then
    b:u32(16, state.frame() + 1) -- greet begins (frame+1: 0 = none)
    b:u32(20, 1)                 -- armed off until exit_r
    b:u32(28, (b:u32(28) % #n.def.lines) + 1)
    audio.sfx("greet", 100)
    return
  end
  -- amble the route
  local wp = n.def.route[b:u32(12)]
  local tx, tz = wp[1], wp[2]
  local ddx, ddz = tx - x, tz - z
  local d = m.sqrt(ddx * ddx + ddz * ddz)
  if d < k.arrive then
    b:u32(12, b:u32(12) % #n.def.route + 1)
    return
  end
  local step = k.speed / 60.0
  if step > d then step = d end
  b:f32(0, x + ddx / d * step)
  b:f32(4, z + ddz / d * step)
  b:f32(24, b:f32(24) + step)
  local want = m.atan2(ddx, ddz)
  local face = b:f32(8)
  local da = m.atan2(m.sin(want - face), m.cos(want - face))
  b:f32(8, m.fmod(face + da * k.turn, m.tau))
end

function N.step()
  for _, n in ipairs(N.list) do step_one(n) end
end

-- the typing dialog line of the nearest ACTIVE greet (nil if none)
function N.dialog()
  local k = state.doc.knobs.npc
  for _, n in ipairs(N.list) do
    local g = n.buf:u32(16)
    if g ~= 0 then
      local line = n.def.lines[n.buf:u32(28)]
      local nch = m.min(#line, (state.frame() - (g - 1)) // k.type_f)
      return line, nch
    end
  end
end

local function anim_rc(n)
  local k = state.doc.knobs.npc
  local g = n.buf:u32(16)
  if g ~= 0 then -- waving: two baked frames on a frame clock
    local t = (state.frame() - (g - 1)) // (k.wave_f // 2)
    return 5 + t % 2
  end
  local ph = n.buf:f32(24) / state.doc.knobs.move.stride
  return 1 + math.tointeger(ph * 4 // 1) % 4
end

-- one NPC -> its own draw segment (each variant is its own sheet texture)
function N.emit_one(n, out, cam_yaw, cam_pitch)
  local k = state.doc.knobs.spr
  local x, z = n.buf:f32(0), n.buf:f32(4)
  local y = world.ground(x, z)
  local tint = 0.7 + 0.3 * world.shadow(x, z)
  local col = spr.oct(n.buf:f32(8), cam_yaw)
  return spr.billboard(out, n.sheet, x, y, z, k.h, col, anim_rc(n), tint,
                       cam_yaw, cam_pitch)
end

function N.emit_shadow(out)
  local ntris = 0
  for _, n in ipairs(N.list) do
    local x, z = n.buf:f32(0), n.buf:f32(4)
    local y = world.ground(x, z)
    ntris = ntris + spr.decal(out, x, y + 0.03, z, 0.55, 255, 255, 255, 150)
  end
  return ntris
end

return N
