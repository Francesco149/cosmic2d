-- __NAME__ — a top-down starter. Walk the room and collect every gem.
-- Edit me while the game runs (hot reload)!
--
-- Everything that changes per frame lives in state.doc, so snapshots,
-- traces, and rewind stay exact. The sim never calls the OS clock or
-- host math — cm.math's sin drives the gem bob off the sim frame count.
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m = cm.require("cm.math")

local W, H = pal.gfx_size()

-- the room: wall rectangles {x, y, w, h}. Carve doors, add corridors!
local WALLS = {
  { 0, 0, W, 10 }, { 0, H - 10, W, 10 },          -- top / bottom
  { 0, 0, 10, H }, { W - 10, 0, 10, H },          -- left / right
  { 120, 10, 10, 150 },                           -- inner walls
  { 240, H - 160, 10, 150 },
  { 340, 90, 90, 10 },
}
local GEMS = {
  { 60, 50 }, { 200, 40 }, { 430, 40 },
  { 60, H - 50 }, { 300, H - 60 }, { 400, 140 },
}
local PW = 12                 -- player size (square)
local SPEED = 1.8
local DIAG = 0.70710678       -- 1/sqrt(2), a fixed constant on purpose

local game = {}

local function reset(d)
  -- spawn left of the middle wall, on open floor
  d.x, d.y = W / 2 - 60, H / 2 - PW / 2
  d.got = {}
  for i = 1, #GEMS do d.got[i] = false end
  d.count = 0
end

function game.init()
  input.map({ { "left", input.key.left, input.key.a },
              { "right", input.key.right, input.key.d },
              { "up", input.key.up, input.key.w },
              { "down", input.key.down, input.key.s },
              { "reset", input.key.r } })
  local d = state.doc
  if d.x == nil then reset(d) end
end

local function blocked(x, y)
  for _, r in ipairs(WALLS) do
    if x < r[1] + r[3] and x + PW > r[1]
       and y < r[2] + r[4] and y + PW > r[2] then return true end
  end
  return false
end

function game.step()
  local d = state.doc
  if input.pressed("reset") then reset(d) end
  local won = d.count == #GEMS
  local dx = (input.down("right") and 1 or 0) - (input.down("left") and 1 or 0)
  local dy = (input.down("down") and 1 or 0) - (input.down("up") and 1 or 0)
  if won then
    if dx ~= 0 or dy ~= 0 then reset(d) end
    return
  end
  local s = SPEED
  if dx ~= 0 and dy ~= 0 then s = SPEED * DIAG end
  -- one axis at a time so sliding along a wall feels right
  if dx ~= 0 and not blocked(d.x + dx * s, d.y) then d.x = d.x + dx * s end
  if dy ~= 0 and not blocked(d.x, d.y + dy * s) then d.y = d.y + dy * s end
  local cx, cy = d.x + PW / 2, d.y + PW / 2
  for i, g in ipairs(GEMS) do
    if not d.got[i] and m.abs(cx - g[1]) < 10 and m.abs(cy - g[2]) < 10 then
      d.got[i] = true
      d.count = d.count + 1
    end
  end
end

function game.draw()
  pal.begin_frame(0.10, 0.12, 0.11, 1)
  for _, r in ipairs(WALLS) do
    pal.quad(r[1], r[2], r[3], r[4], 0.30, 0.36, 0.32, 1)
  end
  local d = state.doc
  local t = state.frame()
  for i, g in ipairs(GEMS) do
    if not d.got[i] then
      local bob = m.sin(t * 0.08 + i) * 2
      pal.quad(g[1] - 3, g[2] - 3 + bob, 6, 6, 0.55, 0.85, 0.95, 1)
    end
  end
  pal.quad(d.x, d.y, PW, PW, 0.95, 0.75, 0.42, 1)
  local msg = d.count == #GEMS and "all gems! move to start over"
              or ("__NAME__ - arrows walk, R resets - gems " .. d.count
                  .. "/" .. #GEMS)
  text.draw(14, H - 34, msg, { r = 0.95, g = 0.92, b = 0.8, a = 0.9 })
end

return game
