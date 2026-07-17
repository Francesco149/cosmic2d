-- swarm — the naive one-screen arcade mini-demo (A6). Twin-stick-ish
-- arena shooter: waves of chasers pour in from the edges, you kite and
-- shoot until they get you, then you restart instantly and chase the
-- high score. Waves/timers, many lightweight actors, projectiles and
-- overlap tests, juice (hit pause / shake / flash), score + a PERSISTED
-- high score through the D086 boot door — the whole A6 arcade checklist,
-- written DELIBERATELY NAIVELY; the hand-rolled blocks are pain markers
-- for the A5 slices:
--
--   PAIN(actor):  two swap-remove pools (enemies, shots) — cheap, but ids
--                 are unstable and every system re-walks raw arrays.
--   PAIN(query):  the AABB overlap loop, copy number FOUR in this repo.
--   PAIN(effect): hit pause, screen shake, and the death flash are three
--                 hand-tuned doc counters plus draw-side offset math.
--   PAIN(move):   the aim/axis normalization dance is re-derived yet again.
--
-- Determinism: everything per-frame lives in state.doc; spawns come from
-- cm.rand (the PRNG is sim state, so runs replay bit-for-bit); the shake
-- offset is render-only math off the sim frame count, never the PRNG.
-- The high score is read ONCE in init under the reload-idempotence
-- contract (absent-fill only) — the trace SNAP carries the result — and
-- written back as a pure output on death.
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m = cm.require("cm.math")
local rand = cm.require("cm.rand")
local save = cm.require("cm.save")

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
  d.cool = 0
  d.enemies, d.shots = {}, {}
  d.wave, d.until_wave = 0, 30
  d.score = 0
  d.over = false
  d.pause, d.shake, d.flash = 0, 0, 0
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

-- PAIN(query): copy number four of this exact loop
local function hits(x, y, w, h, e, s)
  return x < e.x + s and x + w > e.x and y < e.y + s and y + h > e.y
end

local function spawn_wave(d)
  d.wave = d.wave + 1
  local n = 3 + d.wave * 2
  for _ = 1, n do
    -- PAIN(actor): raw table append; edge picked from the sim PRNG
    local side = rand.range(0, 3)
    local e
    if side == 0 then e = { x = rand.range(0, W - ESIZE), y = -ESIZE }
    elseif side == 1 then e = { x = rand.range(0, W - ESIZE), y = H }
    elseif side == 2 then e = { x = -ESIZE, y = rand.range(0, H - ESIZE) }
    else e = { x = W, y = rand.range(0, H - ESIZE) } end
    e.speed = 0.4 + d.wave * 0.05 + rand.range(0, 19) * 0.01
    d.enemies[#d.enemies + 1] = e
  end
end

function game.step()
  local d = state.doc
  if input.pressed("reset") then reset(d) end
  if d.shake > 0 then d.shake = d.shake - 1 end
  if d.flash > 0 then d.flash = d.flash - 1 end
  if d.over then
    if input.pressed("fire") then reset(d) end -- instant restart
    return
  end
  -- juice: hit pause freezes the world for a beat (render still runs)
  if d.pause > 0 then d.pause = d.pause - 1 return end

  -- 8-way movement: stick wins when deflected, else digital keys
  local ax = input.pad_axis(1, "lx") / 127
  local ay = input.pad_axis(1, "ly") / 127
  local dx, dy = ax * SPEED, ay * SPEED
  if ax == 0 and ay == 0 then
    local ix = (input.down("right") and 1 or 0) - (input.down("left") and 1 or 0)
    local iy = (input.down("down") and 1 or 0) - (input.down("up") and 1 or 0)
    local s = (ix ~= 0 and iy ~= 0) and SPEED * 0.70710678 or SPEED
    dx, dy = ix * s, iy * s
  end
  d.x = m.clamp(d.x + dx, 4, W - 4 - PW)
  d.y = m.clamp(d.y + dy, 4, H - 4 - PW)
  -- facing: the right stick aims when deflected, else the move direction
  -- PAIN(move): another hand-rolled aim/axis dance
  local rx = input.pad_axis(1, "rx") / 127
  local ry = input.pad_axis(1, "ry") / 127
  if rx ~= 0 or ry ~= 0 then
    d.fx = rx ~= 0 and (rx > 0 and 1 or -1) or 0
    d.fy = ry ~= 0 and (ry > 0 and 1 or -1) or 0
  elseif dx ~= 0 or dy ~= 0 then
    d.fx = dx ~= 0 and (dx > 0 and 1 or -1) or 0
    d.fy = dy ~= 0 and (dy > 0 and 1 or -1) or 0
  end

  -- shooting: 8-way along the facing
  d.cool = m.max(0, d.cool - 1)
  local firing = input.down("fire") or rx ~= 0 or ry ~= 0
  if firing and d.cool == 0 then
    d.cool = COOLDOWN
    local n = (d.fx ~= 0 and d.fy ~= 0) and 0.70710678 or 1
    d.shots[#d.shots + 1] = { x = d.x + PW / 2 - 2, y = d.y + PW / 2 - 2,
                              vx = d.fx * BSPEED * n, vy = d.fy * BSPEED * n }
  end

  -- shots fly, die at the walls; PAIN(actor): swap-remove pool
  for i = #d.shots, 1, -1 do
    local s = d.shots[i]
    s.x, s.y = s.x + s.vx, s.y + s.vy
    if s.x < 0 or s.x > W or s.y < 0 or s.y > H then
      d.shots[i] = d.shots[#d.shots]
      d.shots[#d.shots] = nil
    end
  end

  -- chasers home axis-at-a-time (no sqrt, no trig — naive and exact)
  for _, e in ipairs(d.enemies) do
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
  for si = #d.shots, 1, -1 do
    local s = d.shots[si]
    for ei = #d.enemies, 1, -1 do
      local e = d.enemies[ei]
      if hits(s.x, s.y, 4, 4, e, ESIZE) then
        d.enemies[ei] = d.enemies[#d.enemies]
        d.enemies[#d.enemies] = nil
        d.shots[si] = d.shots[#d.shots]
        d.shots[#d.shots] = nil
        d.score = d.score + 10
        d.pause = 2          -- juice: a 2-frame hit pause
        d.shake = 6
        break
      end
    end
  end

  -- an enemy reaches you: run over
  for _, e in ipairs(d.enemies) do
    if hits(d.x, d.y, PW, PW, e, ESIZE) then
      d.over = true
      d.flash = 14
      d.shake = 18
      if d.score > d.hiscore then
        d.hiscore = d.score
        -- pure output (D086): result deliberately ignored; on replay the
        -- disabled store no-ops and the sim never hears about it
        save.write(1, { hiscore = d.hiscore })
      end
      return
    end
  end

  -- waves: a breather, then the next one pours in
  if #d.enemies == 0 then
    d.until_wave = (d.until_wave or BREATHER) - 1
    if d.until_wave <= 0 then
      spawn_wave(d)
      d.until_wave = BREATHER
    end
  end
end

function game.draw()
  local d = state.doc
  local t = state.frame()
  -- juice: render-only shake off the sim frame count (never the PRNG)
  local sx = d.shake > 0 and m.sin(t * 2.7) * d.shake * 0.4 or 0
  local sy = d.shake > 0 and m.sin(t * 3.1 + 2) * d.shake * 0.4 or 0
  pal.begin_frame(0.07, 0.07, 0.10, 1)
  pal.quad(2 + sx, 2 + sy, W - 4, H - 4, 0.10, 0.10, 0.14, 1)
  for _, s in ipairs(d.shots) do
    pal.quad(s.x + sx, s.y + sy, 4, 4, 0.95, 0.9, 0.55, 1)
  end
  for _, e in ipairs(d.enemies) do
    pal.quad(e.x + sx, e.y + sy, ESIZE, ESIZE, 0.85, 0.3, 0.35, 1)
    pal.quad(e.x + 2 + sx, e.y + 2 + sy, ESIZE - 4, ESIZE - 4, 0.6, 0.15, 0.2, 1)
  end
  if not d.over then
    pal.quad(d.x + sx, d.y + sy, PW, PW, 0.55, 0.85, 0.95, 1)
    pal.quad(d.x + d.fx * 4 + 3 + sx, d.y + d.fy * 4 + 3 + sy, 4, 4,
             0.85, 0.95, 1.0, 1)
  end
  if d.flash > 0 then -- juice: the death flash washes the arena
    local a = d.flash / 14 * 0.55
    pal.quad(0, 0, W, H, 0.9, 0.25, 0.25, a)
  end
  local k = input.pad_connected(1) and "pad" or "key"
  local msg = d.over
    and ("run over! " .. input.label("fire", k) .. " restarts instantly")
    or ("wave " .. d.wave .. "  score " .. d.score)
  text.draw(10, 8, msg, { r = 0.95, g = 0.92, b = 0.8, a = 0.95 })
  text.draw(10, 20, "best " .. (d.hiscore or 0),
            { r = 0.8, g = 0.9, b = 0.95, a = 0.8 })
end

return game
