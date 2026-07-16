-- __NAME__ — a one-screen arcade starter. Shoot the falling rocks before
-- they slip past; three misses ends the run. Edit me while it runs!
--
-- Everything that changes per frame lives in state.doc, so snapshots,
-- traces, and rewind stay exact. Random numbers come from cm.rand — the
-- engine PRNG that is itself sim state — so a recorded run replays
-- bit-for-bit.
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m = cm.require("cm.math")
local rand = cm.require("cm.rand")

local W, H = pal.gfx_size()

local SHIP_W, SHIP_H = 14, 10
local SPEED = 2.4             -- ship speed
local COOLDOWN = 10           -- frames between shots
local ROCK = 14               -- rock size (square)
local START_EVERY = 46        -- frames between rocks at the start

local game = {}

local function reset(d)
  d.x = W / 2 - SHIP_W / 2
  d.t, d.cool, d.until_next = 0, 0, START_EVERY
  d.score, d.lives, d.over = 0, 3, false
  d.shots, d.rocks = {}, {}
end

function game.init()
  input.map({ { "left", input.key.left, input.key.a },
              { "right", input.key.right, input.key.d },
              { "fire", input.key.space },
              { "reset", input.key.r } })
  local d = state.doc
  if d.x == nil then reset(d) end
end

function game.step()
  local d = state.doc
  if input.pressed("reset") then reset(d) end
  if d.over then
    if input.pressed("fire") then reset(d) end
    return
  end
  d.t = d.t + 1
  if input.down("left") then d.x = d.x - SPEED end
  if input.down("right") then d.x = d.x + SPEED end
  d.x = m.clamp(d.x, 8, W - 8 - SHIP_W)

  d.cool = m.max(0, d.cool - 1)
  if input.down("fire") and d.cool == 0 then
    d.cool = COOLDOWN
    d.shots[#d.shots + 1] = { x = d.x + SHIP_W / 2 - 1, y = H - 22 - SHIP_H }
  end
  for i = #d.shots, 1, -1 do
    local s = d.shots[i]
    s.y = s.y - 4
    if s.y < -8 then table.remove(d.shots, i) end
  end

  -- rocks arrive a touch faster as the run goes on (never below 18 frames)
  d.until_next = d.until_next - 1
  if d.until_next <= 0 then
    d.until_next = m.max(18, START_EVERY - d.t // 240)
    d.rocks[#d.rocks + 1] = { x = rand.range(8, W - 8 - ROCK), y = -ROCK,
                              v = rand.range(8, 16) / 10 }
  end

  local ship_y = H - 18 - SHIP_H
  for i = #d.rocks, 1, -1 do
    local r = d.rocks[i]
    r.y = r.y + r.v
    local hit
    for j = #d.shots, 1, -1 do
      local s = d.shots[j]
      if s.x < r.x + ROCK and s.x + 2 > r.x
         and s.y < r.y + ROCK and s.y + 6 > r.y then
        table.remove(d.shots, j)
        hit = true
        break
      end
    end
    if hit then
      table.remove(d.rocks, i)
      d.score = d.score + 10
    elseif r.x < d.x + SHIP_W and r.x + ROCK > d.x
           and r.y < ship_y + SHIP_H and r.y + ROCK > ship_y then
      table.remove(d.rocks, i) -- rammed the ship
      d.lives = d.lives - 1
    elseif r.y > H then
      table.remove(d.rocks, i) -- slipped past
      d.lives = d.lives - 1
    end
  end
  if d.lives <= 0 then
    d.over = true
    d.best = m.max(d.best or 0, d.score)
  end
end

function game.draw()
  pal.begin_frame(0.07, 0.08, 0.13, 1)
  local d = state.doc
  local ship_y = H - 18 - SHIP_H
  for _, s in ipairs(d.shots) do
    pal.quad(s.x, s.y, 2, 6, 0.95, 0.92, 0.60, 1)
  end
  for _, r in ipairs(d.rocks) do
    pal.quad(r.x, r.y, ROCK, ROCK, 0.62, 0.48, 0.40, 1)
  end
  pal.quad(d.x, ship_y, SHIP_W, SHIP_H, 0.55, 0.85, 0.95, 1)
  pal.quad(d.x + SHIP_W / 2 - 2, ship_y - 4, 4, 4, 0.55, 0.85, 0.95, 1)
  local hud = "score " .. d.score .. "   lives " .. d.lives
  if (d.best or 0) > 0 then hud = hud .. "   best " .. d.best end
  text.draw(6, 6, hud, { r = 0.95, g = 0.92, b = 0.8, a = 0.9 })
  if d.over then
    text.draw(W / 2 - 70, H / 2 - 10,
              "game over - space flies again",
              { r = 0.95, g = 0.75, b = 0.42, a = 1 })
  else
    text.draw(6, H - 14, "__NAME__ - arrows steer, space shoots, R resets",
              { r = 0.95, g = 0.92, b = 0.8, a = 0.55 })
  end
end

return game
