-- npc — the vale's three locals: mascot COLOR VARIANTS (cm.mascot.build
-- casts them, the D3D-020 pattern) baked to their own sprite sheets,
-- walking small walk-grid-verified routes. Come close and they stop, face
-- you, wave (the baked wave rows), ring the greet bell, and a line types
-- out on the HUD; leave past exit_r and they walk on (hysteresis, one
-- chime per visit — the openworld exchange grammar on billboards).
--
-- Sim state = a cm.actor world in doc (`d.npc` — the D3D-033 re-merge
-- retrofit; three doc actors, well inside the D098 envelope): position,
-- facing, waypoint, greet-start frame+1, spent flag, walk phase, line
-- index. Wave/dialog are pure functions of (actor, frame). The baked
-- sheets are render-class and stay module-local in N.list, linked by
-- the actor's `i`.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local world = cm.require("world")
local spr = cm.require("cm.spr")
local mascot = cm.require("cm.mascot")
local actor = cm.require("cm.actor")
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
  local doc = state.doc
  doc.npc = doc.npc or actor.world()
  N.list = {}
  for i, d in ipairs(DEFS) do
    N.list[i] = {
      def = d,
      sheet = spr.bake(i, mascot.build(d.over), {
        { mascot.idle, 0 },
        { mascot.walk, 0 }, { mascot.walk, 0.25 },
        { mascot.walk, 0.5 }, { mascot.walk, 0.75 },
        { mascot.wave, 0 }, { mascot.wave, 0.5 },
      }, force_bake),
    }
  end
  if actor.count(doc.npc, "npc") == 0 then
    for i, d in ipairs(DEFS) do
      actor.spawn(doc.npc, {
        tag = "npc", i = i,
        x = d.route[1][1], z = d.route[1][2],
        yaw = 0, wp = 1, phase = 0,
        gstart = 0, spent = 0, line = 0,
      })
    end
  end
end

-- greeting is DERIVED per step: greet-start frame+1 on the actor, zero
-- when idle; the spent flag re-arms past exit_r
local function step_one(n, a)
  local k = state.doc.knobs.npc
  local x, z = a.x, a.z
  local px, pz = player.pos()
  local dx, dz = px - x, pz - z
  local d2 = dx * dx + dz * dz
  local greeting = a.gstart ~= 0
  if greeting then
    if d2 > k.exit_r * k.exit_r then
      a.gstart = 0 -- walk on; re-arm happens out here too
      a.spent = 0
    else
      -- hold: face the player (eased), the wave/dialog read the actor
      local want = m.atan2(dx, dz)
      local da = m.atan2(m.sin(want - a.yaw), m.cos(want - a.yaw))
      a.yaw = m.fmod(a.yaw + da * k.turn, m.tau)
      return
    end
  end
  if d2 < k.greet_r * k.greet_r and a.spent == 0 then
    a.gstart = state.frame() + 1 -- greet begins (frame+1: 0 = none)
    a.spent = 1                  -- armed off until exit_r
    a.line = (a.line % #n.def.lines) + 1
    audio.sfx("greet", 100)
    return
  end
  -- amble the route
  local wp = n.def.route[a.wp]
  local tx, tz = wp[1], wp[2]
  local ddx, ddz = tx - x, tz - z
  local d = m.sqrt(ddx * ddx + ddz * ddz)
  if d < k.arrive then
    a.wp = a.wp % #n.def.route + 1
    return
  end
  local step = k.speed / 60.0
  if step > d then step = d end
  a.x = x + ddx / d * step
  a.z = z + ddz / d * step
  a.phase = a.phase + step
  local want = m.atan2(ddx, ddz)
  local da = m.atan2(m.sin(want - a.yaw), m.cos(want - a.yaw))
  a.yaw = m.fmod(a.yaw + da * k.turn, m.tau)
end

function N.step()
  local w = state.doc.npc
  actor.tick(w) -- once per step (cm.actor's contract)
  for a in actor.each(w, "npc") do step_one(N.list[a.i], a) end
end

-- iteration for main's emit/debug loops (ascending id = DEFS order)
function N.each()
  return actor.each(state.doc.npc, "npc")
end

-- the typing dialog line of the nearest ACTIVE greet (nil if none)
function N.dialog()
  local k = state.doc.knobs.npc
  for a in actor.each(state.doc.npc, "npc") do
    if a.gstart ~= 0 then
      local line = N.list[a.i].def.lines[a.line]
      local nch = m.min(#line, (state.frame() - (a.gstart - 1)) // k.type_f)
      return line, nch
    end
  end
end

local function anim_rc(a)
  local k = state.doc.knobs.npc
  if a.gstart ~= 0 then -- waving: two baked frames on a frame clock
    local t = (state.frame() - (a.gstart - 1)) // (k.wave_f // 2)
    return 5 + t % 2
  end
  local ph = a.phase / state.doc.knobs.move.stride
  return 1 + math.tointeger(ph * 4 // 1) % 4
end

-- one NPC -> its own draw segment (each variant is its own sheet texture)
function N.emit_one(a, out, cam_yaw, cam_pitch)
  local k = state.doc.knobs.spr
  local y = world.ground(a.x, a.z)
  local tint = 0.7 + 0.3 * world.shadow(a.x, a.z)
  local col = spr.oct(a.yaw, cam_yaw)
  return spr.billboard(out, N.list[a.i].sheet, a.x, y, a.z, k.h, col,
                       anim_rc(a), tint, cam_yaw, cam_pitch)
end

function N.emit_shadow(out)
  local ntris = 0
  for a in actor.each(state.doc.npc, "npc") do
    local y = world.ground(a.x, a.z)
    ntris = ntris + spr.decal(out, a.x, y + 0.03, a.z, 0.55, 255, 255, 255,
                              150)
  end
  return ntris
end

return N
