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
-- Sim state is a cm.actor world in doc (`d.npc` — the D3D-033 re-merge
-- retrofit: the hand-rolled per-NPC buffer + hot-reload dance became
-- actor.world/spawn/each; two doc actors are well inside the D098 ~500
-- envelope). Each actor carries x/z/yaw/wp/phase/greets/armed and the
-- greet edges gstart/gend as frame+1 (a frame-0 event can't alias the 0
-- sentinel); "greeting" is simply start > end, which leaves both edges
-- available to the draw side — the wave blends in from the start edge and
-- back out from the end edge as pure functions of (actor, frame). The
-- zero-animation-state rule holds. Static casting (figures, lines,
-- routes) stays module-local in M.list, linked by the actor's `i`.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local fig = cm.require("cm.fig")
local mascot = cm.require("cm.mascot")
local actor = cm.require("cm.actor")
local world = cm.require("world")
local player = cm.require("player")
local audio = cm.require("audio")

local M = select(2, ...) or {}

local DT = 1.0 / 60.0

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
  local d = state.doc
  d.npc = d.npc or actor.world()
  if actor.count(d.npc, "npc") == 0 then
    for i, n in ipairs(M.list) do
      actor.spawn(d.npc, {
        tag = "npc", i = i,
        x = n.x, z = n.z, yaw = n.home_yaw,
        wp = n.start_wp or 1, phase = 0,
        greets = 0, armed = 1, gstart = 0, gend = 0,
      })
    end
  end
end

-- the NPCs' collider AABBs (human verdict 2026-07-17: "make the npcs
-- solid so I can't walk through them"). Derived per call from the sim
-- actors — the boxes ride the wanderer. D3D-011 rule: the box stays
-- INSIDE the round visual (body lathe max r 0.82 -> hw 0.575), only the
-- visual is round. main passes these into player.step, so the player
-- clamps against them exactly like tree trunks — including landing on
-- top (an NPC head is a perch, the box-top rule).
function M.boxes()
  local k = state.doc.knobs.npc
  local hw = k.cw / 2
  local out = {}
  for a in actor.each(state.doc.npc, "npc") do
    local y = world.ground(a.x, a.z)
    out[#out + 1] = { a.x - hw, y, a.z - hw, a.x + hw, y + k.ch, a.z + hw }
  end
  return out
end

local function greeting_since(a) -- frames since the greet began, or nil
  if a.gstart <= a.gend then return nil end
  return state.frame() - (a.gstart - 1)
end

local function step_one(n, a)
  local k = state.doc.knobs.npc
  local f = state.frame()
  local px, _, pz = player.pos()
  local x, z = a.x, a.z
  local dx, dz = px - x, pz - z
  local d2 = dx * dx + dz * dz
  local greeting = a.gstart > a.gend

  if greeting then
    -- ends past exit_r (hysteresis: no chime spam), or — for a walker —
    -- after k.hold frames on its own (it has a route to get back to)
    if d2 > k.exit_r * k.exit_r
       or (n.route and f - (a.gstart - 1) >= k.hold) then
      a.gend = f + 1
      greeting = false
    end
  else
    if d2 > k.exit_r * k.exit_r then a.armed = 1 end
    if a.armed == 1 and d2 < k.greet_r * k.greet_r then
      a.gstart = f + 1
      a.greets = a.greets + 1
      a.armed = 0
      audio.sfx("greet", n.greet_vel, n.greet_note)
      greeting = true
    end
  end

  -- facing target + the walker's motion (a greet holds it in place)
  local target
  if greeting then
    target = m.atan2(dx, dz)
  elseif n.route then
    local wi = a.wp
    local wp = n.route[wi]
    local wx, wz = wp[1] - x, wp[2] - z
    local dist = m.sqrt(wx * wx + wz * wz)
    if dist < k.arrive then
      wi = wi % #n.route + 1
      a.wp = wi
      wp = n.route[wi]
      wx, wz = wp[1] - x, wp[2] - z
      dist = m.sqrt(wx * wx + wz * wz)
    end
    local step = m.min(k.speed * DT, dist)
    if dist > 1e-4 then
      local nx, nz = x + wx / dist * step, z + wz / dist * step
      -- solid NPCs can't plow through a solid player: if this step would
      -- close inside stop_r on the player, wait instead (still facing
      -- route-ward — it reads as queuing, and it resumes the moment the
      -- player steps aside). Direction-aware so walking AWAY from a
      -- close player never freezes.
      local pd2 = (nx - px) * (nx - px) + (nz - pz) * (nz - pz)
      if pd2 >= k.stop_r * k.stop_r or pd2 >= d2 then
        a.x = nx
        a.z = nz
        -- the walk clip rides GROUND DISTANCE (the player's no-foot-slide
        -- rule); knobs.move.stride keeps both gaits in the same unit
        a.phase = (a.phase + step / state.doc.knobs.move.stride) % 1
      end
    end
    target = m.atan2(wx, wz)
  else
    target = n.home_yaw
  end
  local d = m.atan2(m.sin(target - a.yaw), m.cos(target - a.yaw))
  a.yaw = m.fmod(a.yaw + d * k.turn, m.tau)
end

function M.step()
  local w = state.doc.npc
  actor.tick(w) -- once per step (cm.actor's contract)
  for a in actor.each(w, "npc") do step_one(M.list[a.i], a) end
end

-- iteration for main's debug loop (ascending id = M.list order)
function M.each()
  return actor.each(state.doc.npc, "npc")
end

-- the line being spoken + how many chars have typed out, or nil; if two
-- NPCs somehow greet at once, the most recent greet owns the HUD line
function M.dialog()
  local k = state.doc.knobs.npc
  local best, since
  for a in actor.each(state.doc.npc, "npc") do
    local s = greeting_since(a)
    if s and (not since or s < since) then best, since = a, s end
  end
  if not best then return nil end
  local lines = M.list[best.i].lines
  local line = lines[(best.greets - 1) % #lines + 1]
  return line, m.min(#line, since // k.type_f)
end

-- render-class from here down: reads the actors, never writes
local function emit_one(n, a, out)
  local k = state.doc.knobs.npc
  local feel = state.doc.knobs.feel
  local f = state.frame()
  local pose = fig.cycle(mascot.idle, f / feel.idle_f)

  -- layer weights off the greet edges: the wave blends in from the start
  -- edge and back out from the end edge; a walker's gait makes way for it
  -- and picks back up — all pure functions of (actor, frame)
  local s, e = a.gstart, a.gend
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
    pose = fig.mix(pose, fig.cycle(mascot.walk, a.phase), wb)
  end
  if vb > 0 then
    pose = fig.mix(pose, fig.cycle(mascot.wave, wavephase), vb)
  end

  local root = m4.mul(m4.translate(a.x, world.ground(a.x, a.z), a.z),
                      m4.roty(a.yaw))
  return fig.emit(out, n.fig, root, pose)
end

function M.emit(out)
  local nt = 0
  for a in actor.each(state.doc.npc, "npc") do
    nt = nt + emit_one(M.list[a.i], a, out)
  end
  return nt
end

-- the standing blob shadows (the player's slope-hugging math, grounded so
-- no fall fade)
function M.emit_shadow(out)
  local nt = 0
  for a in actor.each(state.doc.npc, "npc") do
    local x, z = a.x, a.z
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
