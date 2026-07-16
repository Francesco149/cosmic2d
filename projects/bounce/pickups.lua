-- pickups — the goal loop that makes the course a game: gems hover along
-- the course (level.gems) and a big goal star tops the accent tower
-- (level.goal). Touch a gem: score++, coin sfx, a pop ghost — and it STAYS
-- collected (playtest 2026-07-16: timed gem respawn read as a bug). Touch
-- the star: lap++, bell fanfare, CLEAR banner, every gem respawns — a
-- fresh lap; only the star itself returns on a timer (goal.respawn) so
-- laps can repeat. Every value is a live knob (doc.knobs.goal).
--
-- Determinism: sim state = per-item timers in the named buffer
-- bounce.pickups ([0] goal, [4*i] gem i). Gem encoding: 0 = present,
-- k.pop..1 = collected + pop-ghost countdown, -1 = collected for the lap.
-- Goal keeps the respawn countdown (k.respawn -> 0 = back). Doc counters:
-- score/laps/clear_t. step() reads player pos, writes timers, fires sfx
-- (cm.snd is sim-side). Spin/bob are RENDER-class (emit reads the frame
-- counter; the sim never sees them — pickup tests use the rest position).

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local m4 = cm.require("cm.m4")
local gb = cm.require("gb")
local level = cm.require("level")
local player = cm.require("player")
local audio = cm.require("audio")

local M = select(2, ...) or {}

-- diamond gem: a 2-cone lathe profile {r,y}, 8 segments
local GEM = { 0, -0.30, 0.26, 0, 0, 0.30 }
local GEM_TRIS = 2 * 8 * 2 -- profile segments * n * 2 (some degenerate)
local GEM_COL = { 1.0, 0.82, 0.35 } -- gold
local GOAL_COL = { 0.75, 0.92, 1.0 } -- ice-white star atop the accent tower
local GOAL_SCALE = 1.9

local buf

function M.init()
  local size = 4 * (#level.gems + 1)
  local ok, b = pcall(pal.buf, "bounce.pickups", size)
  if not ok then -- gem list grew across a hot reload
    pal.buf_free("bounce.pickups")
    b = pal.buf("bounce.pickups", size)
  end
  buf = b
end

-- worst-case tris emit()+emit_fx() can produce (dyn buffer sizing)
function M.max_tris()
  return (#level.gems + 1) * GEM_TRIS * 2
end

function M.step()
  local k = state.doc.knobs.goal
  local d = state.doc
  local px, py, pz = player.pos()
  py = py + 0.5 -- cube center
  local r2 = k.r * k.r
  for i, g in ipairs(level.gems) do
    local t = buf:f32(4 * i)
    if t == 0 then
      local dx, dy, dz = g[1] - px, g[2] - py, g[3] - pz
      if dx * dx + dy * dy + dz * dz < r2 then
        buf:f32(4 * i, k.pop)
        d.score = d.score + 1
        audio.sfx("coin")
      end
    elseif t > 0 then -- pop ghost ticking down; then hold at -1 for the lap
      buf:f32(4 * i, t > 1 and t - 1 or -1)
    end
  end
  local t = buf:f32(0)
  if t == 0 then
    local g = level.goal
    local dx, dy, dz = g[1] - px, g[2] - py, g[3] - pz
    if dx * dx + dy * dy + dz * dz < r2 * GOAL_SCALE * GOAL_SCALE then
      buf:f32(0, k.respawn)
      d.laps = d.laps + 1
      d.clear_t = k.banner
      for i = 1, #level.gems do buf:f32(4 * i, 0) end -- fresh lap
      audio.goal()
    end
  else
    buf:f32(0, t - 1)
  end
  if d.clear_t > 0 then d.clear_t = d.clear_t - 1 end
end

-- one spinning bobbing gem; scale pre-multiplies the PROFILE (not the xf)
-- so the lathe xf stays rigid and normals stay unit (gb's xfn caveat)
local function emit_gem(out, p, frame, phase, scale, col, alpha)
  local k = state.doc.knobs.goal
  local prof = GEM
  if scale ~= 1 then
    prof = {}
    for i, v in ipairs(GEM) do prof[i] = v * scale end
  end
  local bob = m.sin((frame / k.bob_f + phase * 0.13) * m.tau) * k.bob
  local xf = m4.mul(m4.translate(p[1], p[2] + bob, p[3]),
                    m4.roty(frame * k.spin + phase))
  return gb.lathe(out, xf, prof, 8, col, alpha)
end

-- present gems + the goal star (opaque segment). Returns tris.
function M.emit(out, frame)
  local n = 0
  for i, g in ipairs(level.gems) do
    if buf:f32(4 * i) == 0 then
      n = n + emit_gem(out, g, frame, i, 1, GEM_COL)
    end
  end
  if buf:f32(0) == 0 then
    n = n + emit_gem(out, level.goal, frame, 0, GOAL_SCALE, GOAL_COL)
  end
  return n
end

-- pickup pops: a just-collected item leaves an expanding fading ghost for
-- goal.pop frames (blend segment, drawn after opaque). Returns tris.
function M.emit_fx(out, frame)
  local k = state.doc.knobs.goal
  local n = 0
  local function ghost(rem, p, phase, base_scale, col) -- rem pop frames left
    if rem > 0 and rem <= k.pop then
      local u = (k.pop - rem) / k.pop -- 0 at pickup -> 1 gone
      n = n + emit_gem(out, p, frame, phase, base_scale * (1 + 1.6 * u),
                       col, ((1 - u) * 200) // 1)
    end
  end
  for i, g in ipairs(level.gems) do
    ghost(buf:f32(4 * i), g, i, 1, GEM_COL)
  end
  ghost(buf:f32(0) - (k.respawn - k.pop), level.goal, 0, GOAL_SCALE, GOAL_COL)
  return n
end

return M
