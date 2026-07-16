-- __NAME__ — a side-view platformer starter. Run, jump the platforms,
-- reach the flag. Edit me while the game runs (hot reload)!
--
-- Everything that changes per frame lives in state.doc, so snapshots,
-- traces, and rewind stay exact. Constants live up here: tweak one, save,
-- and the running game picks it up.
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m = cm.require("cm.math")

local W, H = pal.gfx_size()

-- the level: solid rectangles {x, y, w, h}. Move one, add one, save!
local SOLIDS = {
  { 0, H - 16, W, 16 },                -- the ground
  { -8, -80, 8, H + 80 },              -- side walls
  { W, -80, 8, H + 80 },
  { 84, H - 56, 96, 10 },
  { 220, H - 92, 96, 10 },
  { 356, H - 130, 88, 10 },
  { 220, H - 170, 80, 10 },
}
local GOAL = { 252, H - 194, 16, 24 }  -- the flag, on the top platform
local PW, PH = 12, 16                  -- player size
local RUN, AIR = 0.6, 0.35             -- ground/air acceleration
local MAXVX, GRAV, JUMP = 2.6, 0.28, -5.6

local game = {}

local function reset(d)
  d.x, d.y, d.vx, d.vy = 24, H - 16 - PH, 0, 0
  d.grounded, d.won = false, false
end

function game.init()
  input.map({ { "left", input.key.left, input.key.a },
              { "right", input.key.right, input.key.d },
              { "jump", input.key.space, input.key.up, input.key.w },
              { "reset", input.key.r } })
  local d = state.doc
  if d.x == nil then reset(d) end
end

local function overlaps(x, y, r)
  return x < r[1] + r[3] and x + PW > r[1]
     and y < r[2] + r[4] and y + PH > r[2]
end

-- move one axis, then push straight back out of any solid. Naive but
-- exact — and plenty for speeds below the player's own size.
local function move_axis(d, dx, dy)
  d.x, d.y = d.x + dx, d.y + dy
  for _, r in ipairs(SOLIDS) do
    if overlaps(d.x, d.y, r) then
      if dx > 0 then d.x = r[1] - PW
      elseif dx < 0 then d.x = r[1] + r[3] end
      if dy > 0 then d.y = r[2] - PH; d.vy = 0; d.grounded = true
      elseif dy < 0 then d.y = r[2] + r[4]; d.vy = 0 end
    end
  end
end

function game.step()
  local d = state.doc
  if input.pressed("reset") then reset(d) end
  if d.won then
    if input.pressed("jump") then reset(d) end
    return
  end
  local a = d.grounded and RUN or AIR
  if input.down("left") then d.vx = m.max(d.vx - a, -MAXVX)
  elseif input.down("right") then d.vx = m.min(d.vx + a, MAXVX)
  else d.vx = d.vx * (d.grounded and 0.78 or 0.98) end
  if input.pressed("jump") and d.grounded then d.vy = JUMP end
  d.vy = m.min(d.vy + GRAV, 6)
  d.grounded = false
  move_axis(d, d.vx, 0)
  move_axis(d, 0, d.vy)
  if d.y > H + 40 then reset(d) end -- fell out of the world
  if overlaps(d.x, d.y, GOAL) then d.won = true end
end

function game.draw()
  pal.begin_frame(0.09, 0.11, 0.16, 1)
  for _, r in ipairs(SOLIDS) do
    pal.quad(r[1], r[2], r[3], r[4], 0.25, 0.34, 0.31, 1)
  end
  pal.quad(GOAL[1] + 6, GOAL[2], 3, GOAL[4], 0.85, 0.83, 0.75, 1) -- the pole
  pal.quad(GOAL[1] + 9, GOAL[2], 11, 8, 0.95, 0.55, 0.40, 1)      -- the flag
  local d = state.doc
  pal.quad(d.x, d.y, PW, PH, 0.95, 0.75, 0.42, 1)
  text.draw(6, 6, d.won and "you made it! space starts over"
            or "__NAME__ - arrows run, space jumps, R resets",
            { r = 0.95, g = 0.92, b = 0.8, a = 0.9 })
end

return game
