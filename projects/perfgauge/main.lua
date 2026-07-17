-- perfgauge — the A5 performance-envelope audit vehicle (dev-tree only,
-- never bundled). A swarm-shaped world scaled through a staircase of
-- enemy counts: each level holds N chasers alive (edge respawns from the
-- sim PRNG), a deterministic bouncing bot stands in for the player, a
-- rotating 8-way shooter keeps projectiles and shot-x-enemy overlap
-- queries in the frame, and everything per-frame lives in state.doc —
-- so the always-on ring recorder re-canons the whole moving world every
-- frame, exactly the D092 cost the envelope must include.
--
-- Observation is dev-side only: wall times from pal.time_ns() live in
-- module-local rings, never in doc, and decide nothing in the sim — the
-- run is bit-deterministic; the printed numbers are not (they are the
-- point). Four windows per frame:
--
--   step  game.step top -> bottom            (the game's own sim work)
--   post  game.step end -> game.draw start   (snd + advance + ring
--                                             record/canon: the engine
--                                             tax on a doc-heavy world)
--   draw  game.draw top -> bottom            (quads; backend-dependent)
--   tick  step top -> next step top          (the whole loop)
--
-- Run it capped so the loop free-runs (an uncapped interactive headless
-- session sleeps 16 ms per tick and poisons the tick metric):
--
--   bin/cosmic projects/perfgauge --headless --frames 4200
--
-- Each level warms up WARMUP frames (spawn spike + GC settle), measures
-- MEASURE frames, logs avg/p50/p95/max per window + the Lua heap, then
-- climbs. 7 levels x 600 frames = 4200 steps; the run self-quits after
-- the last flush as a backup to the frame cap.
local state = cm.require("cm.state")
local rand = cm.require("cm.rand")
local actor = cm.require("cm.actor")
local move = cm.require("cm.move")
local text = cm.require("cm.text")

local W, H = pal.gfx_size()
local ESIZE = 9
local BSPEED = 3.4
local COOLDOWN = 9
local WARMUP = 120
local MEASURE = 480
local LEVELS = { 100, 250, 500, 1000, 2000, 4000, 8000 }
-- the 8 shot directions, walked in order (fx, fy pairs for move.unit8)
local DIRS = { { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 },
               { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } }

local game = {}

-- dev-side rings; gate mirrors "this frame is measured" (set from doc in
-- step, read in draw). Nothing here feeds the sim.
local obs = { step = {}, post = {}, draw = {}, tick = {},
              last0 = nil, step_end = nil, gate = false }

local function push(ring, ms) ring[#ring + 1] = ms end

local function stats(ring)
  local n = #ring
  if n == 0 then return "-" end
  local s = {}
  for i = 1, n do s[i] = ring[i] end
  table.sort(s)
  local sum = 0.0
  for i = 1, n do sum = sum + s[i] end
  return ("avg %6.3f  p50 %6.3f  p95 %6.3f  max %7.3f"):format(
    sum / n, s[(n + 1) // 2], s[math.ceil(n * 0.95)], s[n])
end

local function flush_level(n_target)
  pal.log(("[perfgauge] n=%d  step  %s"):format(n_target, stats(obs.step)))
  pal.log(("[perfgauge] n=%d  post  %s"):format(n_target, stats(obs.post)))
  pal.log(("[perfgauge] n=%d  draw  %s"):format(n_target, stats(obs.draw)))
  pal.log(("[perfgauge] n=%d  tick  %s  luaheap %dK"):format(
    n_target, stats(obs.tick), collectgarbage("count") // 1))
  obs.step, obs.post, obs.draw, obs.tick = {}, {}, {}, {}
end

function game.init()
  local d = state.doc
  if d.li == nil then
    d.li = 1
    d.k = 0
    d.dir = 1
    d.px, d.py = W / 2, H / 2
    d.pvx, d.pvy = 1.3, 0.9
    d.world = actor.world()
  end
end

local function spawn_enemy(d)
  -- exactly swarm's edge picker: side + position from the sim PRNG
  local side = rand.range(0, 3)
  local x, y
  if side == 0 then x, y = rand.range(0, W - ESIZE), -ESIZE
  elseif side == 1 then x, y = rand.range(0, W - ESIZE), H
  elseif side == 2 then x, y = -ESIZE, rand.range(0, H - ESIZE)
  else x, y = W, rand.range(0, H - ESIZE) end
  actor.spawn(d.world, { tag = "enemy", x = x, y = y, w = ESIZE, h = ESIZE,
                         speed = 0.4 + rand.range(0, 19) * 0.01 })
end

function game.step()
  local t0 = pal.time_ns()
  if obs.gate and obs.last0 then push(obs.tick, (t0 - obs.last0) / 1e6) end
  obs.last0 = t0

  local d = state.doc
  local target = LEVELS[d.li]
  if target == nil then return end -- staircase done; draw quits
  obs.gate = d.k >= WARMUP
  local w = d.world
  actor.tick(w)

  -- the bot: a deterministic bouncing stand-in for the player
  d.px = d.px + d.pvx
  d.py = d.py + d.pvy
  if d.px < 4 or d.px > W - 4 - ESIZE then d.pvx = -d.pvx end
  if d.py < 4 or d.py > H - 4 - ESIZE then d.pvy = -d.pvy end

  -- hold the population: respawn the deficit at the edges
  for _ = actor.count(w, "enemy") + 1, target do spawn_enemy(d) end

  -- rotating 8-way shooter on the world cooldown (swarm's fire shape)
  if not actor.running(w, "cool") then
    actor.timer(w, "cool", COOLDOWN)
    d.dir = d.dir % #DIRS + 1
    local ux, uy = move.unit8(DIRS[d.dir][1], DIRS[d.dir][2])
    actor.spawn(w, { tag = "shot", x = d.px + 3, y = d.py + 3, w = 4, h = 4,
                     vx = ux * BSPEED, vy = uy * BSPEED })
  end

  -- shots fly, die at the walls
  for s in actor.each(w, "shot") do
    s.x, s.y = s.x + s.vx, s.y + s.vy
    if s.x < 0 or s.x > W or s.y < 0 or s.y > H then actor.despawn(w, s) end
  end

  -- chasers home axis-at-a-time (swarm's exact loop — every enemy moves
  -- every frame, so the ring recorder re-canons the whole world)
  for e in actor.each(w, "enemy") do
    local ex, ey = d.px - e.x, d.py - e.y
    local aex = ex < 0 and -ex or ex
    local aey = ey < 0 and -ey or ey
    if aex > aey then
      e.x = e.x + (ex > 0 and e.speed or -e.speed)
    else
      e.y = e.y + (ey > 0 and e.speed or -e.speed)
    end
  end

  -- shot x enemy overlaps: the list-scan query under audit
  for s in actor.each(w, "shot") do
    local e = actor.hit(w, "enemy", s.x, s.y, s.w, s.h)
    if e then
      actor.despawn(w, e)
      actor.despawn(w, s)
    end
  end

  -- level clock (pure doc; the flush itself is dev-side logging)
  d.k = d.k + 1
  if d.k >= WARMUP + MEASURE then
    flush_level(target)
    obs.gate = false
    d.li = d.li + 1
    d.k = 0
  end

  obs.step_end = pal.time_ns()
  if obs.gate then push(obs.step, (obs.step_end - t0) / 1e6) end
end

function game.draw()
  local td = pal.time_ns()
  if obs.gate and obs.step_end then
    push(obs.post, (td - obs.step_end) / 1e6)
  end
  local d = state.doc
  if LEVELS[d.li] == nil then pal.quit() end -- backup to the frame cap
  pal.begin_frame(0.07, 0.07, 0.10, 1)
  for s in actor.each(d.world, "shot") do
    pal.quad(s.x, s.y, 4, 4, 0.95, 0.9, 0.55, 1)
  end
  -- two quads per enemy, exactly swarm's draw shape
  for e in actor.each(d.world, "enemy") do
    pal.quad(e.x, e.y, ESIZE, ESIZE, 0.85, 0.3, 0.35, 1)
    pal.quad(e.x + 2, e.y + 2, ESIZE - 4, ESIZE - 4, 0.6, 0.15, 0.2, 1)
  end
  pal.quad(d.px, d.py, ESIZE, ESIZE, 0.55, 0.85, 0.95, 1)
  text.draw(10, 8, ("n %d  k %d"):format(LEVELS[d.li] or 0, d.k),
            { r = 0.95, g = 0.92, b = 0.8, a = 0.95 })
  if obs.gate then push(obs.draw, (pal.time_ns() - td) / 1e6) end
end

return game
