-- npc — the world's characters and the proximity exchange (D3D-020, the
-- Zelda-ish beat; D3D-023 makes them a LIST). Every NPC is a color-variant
-- mascot (cm.mascot.build — reads as "another one of them", never mistaken
-- for the player) with its own lines. Walk close and it turns to face you,
-- waves (the cm.mascot.wave clip) with a greet chime, and a dialog line
-- types out on the HUD; wander off and it settles back to its own business.
-- Lines rotate per greeting.
--
-- Two kinds of business. The POND WATCHER stands its bank and faces the
-- pond at rest. The MEADOW WANDERER (D3D-023) walks a verified loop
-- through the flower meadow on the tour's south leg — the walk clip on a
-- distance phase like the player, so its feet never slide — and a greet
-- HOLDS it mid-round: it stops, waves, says its line, then walks on after
-- k.hold frames even if you stand there (it has flowers to count). The
-- re-greet arms only once you're past exit_r, so a standing player gets
-- one hello per pass, not a machine-gun of them.
--
-- Sim state is ONE named buffer per NPC (f32):
--   [0]yaw [4]greet-start frame+1 [8]greet count [12]greet-end frame+1
--   [16]armed [20]x [24]z [28]waypoint index [32]walk phase
-- Frames are stored as frame+1 so a frame-0 event can't alias the 0
-- sentinel; "greeting" is simply start > end, which leaves both edges
-- available to the draw side — the wave blends in from the start edge and
-- back out from the end edge as pure functions of (buffer, frame). The
-- zero-animation-state rule holds.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local fig = cm.require("cm.fig")
local mascot = cm.require("cm.mascot")
local world = cm.require("world")
local player = cm.require("player")
local audio = cm.require("audio")

local M = select(2, ...) or {}

local DT = 1.0 / 60.0

-- offsets into the per-NPC buffer (layout in the header comment)
local O = { yaw = 0, gstart = 4, greets = 8, gend = 12, armed = 16,
            x = 20, z = 24, wp = 28, phase = 32 }
local SIZE = 36

-- the wanderer's loop: verified 2026-07-17 against the carved terrain —
-- every leg h 0.50..1.32 (bright grass, dry), >=1.2u clear of all tree and
-- boulder colliders, 15 flower clumps within 6u (it IS the meadow). The
-- tour ring's { 64, 100 } waypoint sits inside it, so the passing tour
-- gets greeted.
local LOOP = {
  { 61, 92 }, { 68, 92 }, { 69, 100 }, { 63, 106 }, { 57, 102 }, { 58, 95 },
}

M.list = {
  { -- the pond watcher (D3D-020): stands the east bank, faces the pond
    buf_name = "ow.npc",
    fig = mascot.build({
      body = { 0.93, 0.55, 0.42 },  -- warm coral
      belly = { 0.97, 0.92, 0.80 },
      mitt = { 0.30, 0.58, 0.60 },  -- deep teal
    }),
    x = 52.5, z = 70.5,
    home_yaw = m.atan2(42.0 - 52.5, 64.0 - 70.5), -- toward the pond center
    greet_vel = 104, greet_note = nil, -- the stock greet bell
    lines = {
      "oh! a visitor! lovely day by the pond, isn't it?",
      "the middle is deep. i've seen you paddle across!",
      "that star on your antenna really suits you.",
    },
  },
  { -- the meadow wanderer (D3D-023): laps the flower meadow forever
    buf_name = "ow.npc2",
    fig = mascot.build({
      body = { 0.70, 0.58, 0.86 },  -- lavender
      belly = { 0.96, 0.93, 0.84 },
      mitt = { 0.44, 0.62, 0.36 },  -- moss green
    }),
    -- starts on the loop's FAR (west) side so demo(6)'s player settles in
    -- the meadow first and the greet arrives on the wanderer's own lap —
    -- walking into frame beats spawning in your face
    x = LOOP[4][1], z = LOOP[4][2], start_wp = 5,
    home_yaw = m.atan2(LOOP[5][1] - LOOP[4][1], LOOP[5][2] - LOOP[4][2]),
    route = LOOP,
    greet_vel = 100, greet_note = 81, -- the same bell, a fourth up
    lines = {
      "hello hello! mind the daisies, they're new.",
      "i walk this meadow every day. the pebbles never move.",
      "have you seen the flowers? i counted forty today!",
    },
  },
}

function M.init()
  for _, n in ipairs(M.list) do
    local ok, b = pcall(pal.buf, n.buf_name, SIZE)
    if not ok then -- layout grew across a hot reload
      pal.buf_free(n.buf_name)
      b = pal.buf(n.buf_name, SIZE)
    end
    n.buf = b
    -- virgin buffer: world x is never 0 (the walkable field starts at 2)
    if b:f32(O.x) == 0 and b:f32(O.z) == 0 then
      b:f32(O.yaw, n.home_yaw)
      b:f32(O.armed, 1)
      b:f32(O.x, n.x); b:f32(O.z, n.z)
      b:f32(O.wp, n.start_wp or 1)
    end
  end
end

local function greeting_since(n) -- frames since the greet began, or nil
  local s, e = n.buf:f32(O.gstart), n.buf:f32(O.gend)
  if s <= e then return nil end
  return state.frame() - (s - 1)
end

local function step_one(n)
  local k = state.doc.knobs.npc
  local b = n.buf
  local f = state.frame()
  local px, _, pz = player.pos()
  local x, z = b:f32(O.x), b:f32(O.z)
  local dx, dz = px - x, pz - z
  local d2 = dx * dx + dz * dz
  local greeting = b:f32(O.gstart) > b:f32(O.gend)

  if greeting then
    -- ends past exit_r (hysteresis: no chime spam), or — for a walker —
    -- after k.hold frames on its own (it has a route to get back to)
    if d2 > k.exit_r * k.exit_r
       or (n.route and f - (b:f32(O.gstart) - 1) >= k.hold) then
      b:f32(O.gend, f + 1)
      greeting = false
    end
  else
    if d2 > k.exit_r * k.exit_r then b:f32(O.armed, 1) end
    if b:f32(O.armed) == 1 and d2 < k.greet_r * k.greet_r then
      b:f32(O.gstart, f + 1)
      b:f32(O.greets, b:f32(O.greets) + 1)
      b:f32(O.armed, 0)
      audio.sfx("greet", n.greet_vel, n.greet_note)
      greeting = true
    end
  end

  -- facing target + the walker's motion (a greet holds it in place)
  local target
  if greeting then
    target = m.atan2(dx, dz)
  elseif n.route then
    local wi = b:f32(O.wp) // 1
    local wp = n.route[wi]
    local wx, wz = wp[1] - x, wp[2] - z
    local dist = m.sqrt(wx * wx + wz * wz)
    if dist < k.arrive then
      wi = wi % #n.route + 1
      b:f32(O.wp, wi)
      wp = n.route[wi]
      wx, wz = wp[1] - x, wp[2] - z
      dist = m.sqrt(wx * wx + wz * wz)
    end
    local step = m.min(k.speed * DT, dist)
    if dist > 1e-4 then
      b:f32(O.x, x + wx / dist * step)
      b:f32(O.z, z + wz / dist * step)
      -- the walk clip rides GROUND DISTANCE (the player's no-foot-slide
      -- rule); knobs.move.stride keeps both gaits in the same unit
      b:f32(O.phase,
            (b:f32(O.phase) + step / state.doc.knobs.move.stride) % 1)
    end
    target = m.atan2(wx, wz)
  else
    target = n.home_yaw
  end
  local yaw = b:f32(O.yaw)
  local d = m.atan2(m.sin(target - yaw), m.cos(target - yaw))
  b:f32(O.yaw, m.fmod(yaw + d * k.turn, m.tau))
end

function M.step()
  for _, n in ipairs(M.list) do step_one(n) end
end

-- the line being spoken + how many chars have typed out, or nil; if two
-- NPCs somehow greet at once, the most recent greet owns the HUD line
function M.dialog()
  local k = state.doc.knobs.npc
  local best, since
  for _, n in ipairs(M.list) do
    local s = greeting_since(n)
    if s and (not since or s < since) then best, since = n, s end
  end
  if not best then return nil end
  local line = best.lines[(best.buf:f32(O.greets) - 1) % #best.lines + 1]
  return line, m.min(#line, since // k.type_f)
end

-- render-class from here down: reads the buffers, never writes
local function emit_one(n, out)
  local k = state.doc.knobs.npc
  local feel = state.doc.knobs.feel
  local b = n.buf
  local f = state.frame()
  local pose = fig.cycle(mascot.idle, f / feel.idle_f)

  -- layer weights off the greet edges: the wave blends in from the start
  -- edge and back out from the end edge; a walker's gait makes way for it
  -- and picks back up — all pure functions of (buffer, frame)
  local s, e = b:f32(O.gstart), b:f32(O.gend)
  local wb = n.route and 1 or 0 -- the walk layer's weight
  local vb, wavephase = 0, 0    -- the wave layer's
  if s > e then
    local since = f - (s - 1)
    wb = wb * m.max(0, 1 - since / k.blend_f)
    vb = m.min(1, since / k.blend_f)
    wavephase = since / k.wave_f
  elseif s > 0 then
    local since_end = f - (e - 1)
    wb = wb * m.min(1, since_end / k.blend_f)
    vb = m.max(0, 1 - since_end / k.blend_f)
    wavephase = (e - s) / k.wave_f -- frozen where the wave stopped
  end
  if wb > 0 then
    pose = fig.mix(pose, fig.cycle(mascot.walk, b:f32(O.phase)), wb)
  end
  if vb > 0 then
    pose = fig.mix(pose, fig.cycle(mascot.wave, wavephase), vb)
  end

  local x, z = b:f32(O.x), b:f32(O.z)
  local root = m4.mul(m4.translate(x, world.ground(x, z), z),
                      m4.roty(b:f32(O.yaw)))
  return fig.emit(out, n.fig, root, pose)
end

function M.emit(out)
  local nt = 0
  for _, n in ipairs(M.list) do nt = nt + emit_one(n, out) end
  return nt
end

-- the standing blob shadows (the player's slope-hugging math, grounded so
-- no fall fade)
function M.emit_shadow(out)
  local nt = 0
  for _, n in ipairs(M.list) do
    local x, z = n.buf:f32(O.x), n.buf:f32(O.z)
    local e, r = 0.6, 1.0
    local gy = world.ground(x, z)
    local dhx = (world.ground(x + e, z) - world.ground(x - e, z)) / (2 * e)
    local dhz = (world.ground(x, z + e) - world.ground(x, z - e)) / (2 * e)
    local white = { 1, 1, 1 } -- the texture carries the darkness
    local lift = 0.06
    local function p(dx, dz)
      return { x + dx, gy + lift + dx * dhx + dz * dhz, z + dz }
    end
    local A, B, C, D = p(-r, -r), p(r, -r), p(r, r), p(-r, r)
    gb.quad(out, { A[1], A[2], A[3], 0, 0 }, { B[1], B[2], B[3], 1, 0 },
            { C[1], C[2], C[3], 1, 1 }, { D[1], D[2], D[3], 0, 1 },
            white, 0, 0, 0, 127)
    nt = nt + 2
  end
  return nt
end

return M
