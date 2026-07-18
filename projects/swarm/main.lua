-- swarm — the one-screen arcade mini-demo (A6). Twin-stick-ish arena
-- shooter: waves of chasers pour in from the edges, you kite and shoot
-- until they get you, then you restart instantly and chase the high
-- score. Waves/timers, many lightweight actors, projectiles and overlap
-- tests, juice (hit pause / shake / flash), score + a PERSISTED high
-- score through the D086 boot door — the whole A6 arcade checklist.
--
--   resolved(actor/query): the two swap-remove pools, the hand-rolled
--                 overlap loops (copy four), and the cooldown/wave
--                 countdowns moved into cm.actor (A5/D091): one world in
--                 doc, tags "enemy"/"shot", stable ids, spawn-order
--                 iteration, world timers. cellar and the demo keep
--                 their naive tables as contrast.
--   resolved(effect): the hit pause / shake / death flash counter triple
--                 moved into cm.tween (A5/D094): named effects on the doc
--                 root remembering their lifetime, one tick, and the
--                 eased draw math (val/wobble) instead of hand-tuned
--                 offset/alpha formulas re-deriving each t0. cellar and
--                 the demo keep their naive counters as contrast.
--   resolved(move): the stick+key merge, aim chain, and 8-way shot
--                 normalization moved into cm.move (A5/D097): dir is the
--                 merged unit-scale vector, the nested face8 chain is the
--                 aim priority, unit8 evens the diagonal shots. cellar's
--                 movement block rides dir too; the starter templates
--                 keep their naive readers as contrast.
--
-- Determinism: everything per-frame lives in state.doc — the actor world
-- is a plain doc subtree, so snapshots/traces/rewind carry it by
-- construction; spawns come from cm.rand (the PRNG is sim state, so runs
-- replay bit-for-bit); the shake wobble is render-only math off the
-- effect's remaining count, never the PRNG. The high score is read ONCE
-- in init under the reload-idempotence contract (absent-fill only) — the
-- trace SNAP carries the result — and written back as a pure output on
-- death.
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m = cm.require("cm.math")
local rand = cm.require("cm.rand")
local save = cm.require("cm.save")
local actor = cm.require("cm.actor")
local tween = cm.require("cm.tween")
local move = cm.require("cm.move")

local W, H = pal.gfx_size()
local PW = 10                 -- player square
local SPEED = 1.6
local ESIZE = 9
local BSPEED = 3.4
local COOLDOWN = 9
local BREATHER = 90           -- frames between waves

local game = {}

local function reset(d)
  d.x, d.y = W / 2 - PW / 2, H / 2 - PW / 2
  d.fx, d.fy = 1, 0            -- facing (last nonzero move dir)
  d.world = actor.world()      -- enemies + shots, one world in doc
  actor.timer(d.world, "wave", 30)
  d.wave = 0
  d.score = 0
  d.over = false
  tween.clear(d)
end

function game.init()
  input.map({ { "left", input.key.left, input.key.a, "pad:dpleft", "pad:lx-" },
              { "right", input.key.right, input.key.d, "pad:dpright", "pad:lx+" },
              { "up", input.key.up, input.key.w, "pad:dpup", "pad:ly-" },
              { "down", input.key.down, input.key.s, "pad:dpdown", "pad:ly+" },
              { "fire", input.key.space, "pad:rshoulder" },
              { "reset", input.key.r, "pad:start" } })
  save.schema(1)
  local d = state.doc
  if d.x == nil then
    reset(d)
    -- the D086 boot door: absent-fill only, so replay/verify (disabled
    -- store) and a live boot (real store) both land in the SNAP honestly
    if d.hiscore == nil then
      local data = save.read(1)
      d.hiscore = (data and data.hiscore) or 0
    end
  end
end

local function spawn_wave(d)
  d.wave = d.wave + 1
  local n = 3 + d.wave * 2
  for _ = 1, n do
    -- edge picked from the sim PRNG; the world assigns the stable id
    local side = rand.range(0, 3)
    local x, y
    if side == 0 then x, y = rand.range(0, W - ESIZE), -ESIZE
    elseif side == 1 then x, y = rand.range(0, W - ESIZE), H
    elseif side == 2 then x, y = -ESIZE, rand.range(0, H - ESIZE)
    else x, y = W, rand.range(0, H - ESIZE) end
    actor.spawn(d.world, { tag = "enemy", x = x, y = y, w = ESIZE, h = ESIZE,
                           speed = 0.4 + d.wave * 0.05 + rand.range(0, 19) * 0.01 })
  end
end

function game.step()
  local d = state.doc
  if input.pressed("reset") then reset(d) end
  tween.tick(d) -- pause/shake/flash decay whether or not the world runs
  if d.over then
    if input.pressed("fire") then reset(d) end -- instant restart
    return
  end
  -- juice: hit pause freezes the world for a beat (render still runs);
  -- returning before tick also freezes every actor timer — pause for free
  if tween.on(d, "pause") then return end
  local w = d.world
  actor.tick(w) -- once per step: sweep last frame's dead, run the timers

  -- 8-way movement: cm.move merges the stick (wins when deflected) with
  -- the digital keys at unit scale; the speed stays ours
  local mx, my = move.dir(1)
  d.x = m.clamp(d.x + mx * SPEED, 4, W - 4 - PW)
  d.y = m.clamp(d.y + my * SPEED, 4, H - 4 - PW)
  -- facing: the aim chain — right stick wins, else the move direction,
  -- else the last facing sticks
  local rx, ry = move.stick(1, "r")
  d.fx, d.fy = move.face8(rx, ry, move.face8(mx, my, d.fx, d.fy))

  -- shooting: 8-way along the facing (unit8 evens the diagonals), gated
  -- by the cooldown timer; aiming implies firing
  local firing = input.down("fire") or rx ~= 0 or ry ~= 0
  if firing and not actor.running(w, "cool") then
    actor.timer(w, "cool", COOLDOWN)
    local ux, uy = move.unit8(d.fx, d.fy)
    actor.spawn(w, { tag = "shot", x = d.x + PW / 2 - 2, y = d.y + PW / 2 - 2,
                     w = 4, h = 4,
                     vx = ux * BSPEED, vy = uy * BSPEED })
  end

  -- shots fly, die at the walls (despawn marks; next tick sweeps)
  for s in actor.each(w, "shot") do
    s.x, s.y = s.x + s.vx, s.y + s.vy
    if s.x < 0 or s.x > W or s.y < 0 or s.y > H then actor.despawn(w, s) end
  end

  -- chasers home axis-at-a-time (no sqrt, no trig — naive and exact)
  for e in actor.each(w, "enemy") do
    local ex, ey = d.x - e.x, d.y - e.y
    local aex = ex < 0 and -ex or ex
    local aey = ey < 0 and -ey or ey
    if aex > aey then
      e.x = e.x + (ex > 0 and e.speed or -e.speed)
    else
      e.y = e.y + (ey > 0 and e.speed or -e.speed)
    end
  end

  -- shot x enemy overlaps: kill, score, juice
  for s in actor.each(w, "shot") do
    local e = actor.hit(w, "enemy", s.x, s.y, s.w, s.h)
    if e then
      actor.despawn(w, e)
      actor.despawn(w, s)
      d.score = d.score + 10
      tween.play(d, "pause", 2)      -- juice: a 2-frame hit pause
      tween.play(d, "shake", 6, 2.4) -- peak px, fading over 6 frames
    end
  end

  -- an enemy reaches you: run over
  if actor.hit(w, "enemy", d.x, d.y, PW, PW) then
    d.over = true
    tween.play(d, "flash", 14, 0.55)
    tween.play(d, "shake", 18, 7.2)
    if d.score > d.hiscore then
      d.hiscore = d.score
      -- pure output (D086): result deliberately ignored; on replay the
      -- disabled store no-ops and the sim never hears about it
      save.write(1, { hiscore = d.hiscore })
    end
    return
  end

  -- waves: a breather timer arms when the field empties, spawns on expiry
  if actor.count(w, "enemy") == 0 then
    if actor.expired(w, "wave") then
      spawn_wave(d)
    elseif not actor.running(w, "wave") then
      actor.timer(w, "wave", BREATHER)
    end
  end
end

function game.draw()
  local d = state.doc
  -- juice: render-only shake off the effect counter (never the PRNG)
  local sx, sy = tween.wobble(d, "shake")
  pal.begin_frame(0.07, 0.07, 0.10, 1)
  pal.quad(2 + sx, 2 + sy, W - 4, H - 4, 0.10, 0.10, 0.14, 1)
  for s in actor.each(d.world, "shot") do
    pal.quad(s.x + sx, s.y + sy, 4, 4, 0.95, 0.9, 0.55, 1)
  end
  for e in actor.each(d.world, "enemy") do
    pal.quad(e.x + sx, e.y + sy, ESIZE, ESIZE, 0.85, 0.3, 0.35, 1)
    pal.quad(e.x + 2 + sx, e.y + 2 + sy, ESIZE - 4, ESIZE - 4, 0.6, 0.15, 0.2, 1)
  end
  if not d.over then
    pal.quad(d.x + sx, d.y + sy, PW, PW, 0.55, 0.85, 0.95, 1)
    pal.quad(d.x + d.fx * 4 + 3 + sx, d.y + d.fy * 4 + 3 + sy, 4, 4,
             0.85, 0.95, 1.0, 1)
  end
  -- juice: the death flash washes the arena — through the reduce-flash-
  -- aware door (D129), so the wash attenuates for players who asked
  local a = tween.flash(d, "flash")
  if a > 0 then pal.quad(0, 0, W, H, 0.9, 0.25, 0.25, a) end
  local k = input.pad_connected(1) and "pad" or "key"
  local msg = d.over
    and ("run over! " .. input.label("fire", k) .. " restarts instantly")
    or ("wave " .. d.wave .. "  score " .. d.score)
  text.draw(10, 8, msg, { r = 0.95, g = 0.92, b = 0.8, a = 0.95 })
  text.draw(10, 20, "best " .. (d.hiscore or 0),
            { r = 0.8, g = 0.9, b = 0.95, a = 0.8 })
end

return game
