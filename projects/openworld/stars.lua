-- stars — the wander's goal (round 13): ten gold stars scattered over the
-- world, the same chunky-ball species mark the mascot wears on its antenna
-- (cm.mascot's star color; the pond watcher already talks about it). Seven
-- ride the scenic ring, one sits on the pond's west bank, one FLOATS
-- mid-pond (the swim regime's reward), one waits beside the pond watcher.
-- Touch one: counter++, coin sfx, a pop ghost — and it STAYS collected
-- (the bounce playtest lesson: timed respawn reads as a bug). Collect all
-- ten: a bell fanfare + a fading banner. Every value is a live knob
-- (doc.knobs.stars).
--
-- Determinism: sim state = per-star timers in the named buffer ow.stars
-- (bounce.pickups encoding: 0 present, k.pop..1 pop-ghost countdown, -1
-- collected) + doc counters (stars/star_t). step() reads player pos,
-- writes timers, fires sfx (cm.snd is sim-side). Spin/bob are RENDER-class
-- (emit reads the frame counter; pickup tests use the rest position).

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local world = cm.require("world")
local player = cm.require("player")
local audio = cm.require("audio")

local M = select(2, ...) or {}

-- {x, z, [y]}: y defaults to ground + k.hover (derived); the pond star pins
-- its own y (the ground there is 2.8u under water — it floats just above
-- the surface, bobbing through it). Spots verified on the carved terrain:
-- ring stars sit on the demo(1) waypoints (g 0.9..3.0), the banks on the
-- demo(3) swim route, the last beside the pond watcher's stand spot.
M.STARS = {
  { 76.0, 72.0 },   -- the come-on: down the first leg from the spawn bowl
  { 90.0, 74.0 },   -- the scenic ring...
  { 102.0, 88.0 },
  { 88.0, 102.0 },
  { 64.0, 100.0 },
  { 40.0, 92.0 },
  { 26.0, 80.0 },
  { 31.0, 62.0 },       -- the pond's west bank
  { 42.0, 64.0, 0.35 }, -- mid-pond, floating (swim out to it)
  { 55.4, 72.0 },       -- beside the pond watcher (the greet fires too)
}

local STAR_COL = { 1.00, 0.85, 0.35 } -- cm.mascot's antenna-star gold
local R_BALL = 0.30
local N_SEG = 6
local BALL_TRIS = 48 -- 5-segment ball profile: 2 cap fans + 3 rings * 2*n

local buf

-- rest height, derived every use (never baked into M.STARS — the module
-- body reassigns that table on every hot reload)
local function star_y(s)
  return s[3] or world.ground(s[1], s[2]) + state.doc.knobs.stars.hover
end

function M.init()
  local ok, b = pcall(pal.buf, "ow.stars", 4 * #M.STARS)
  if not ok then -- star list grew across a hot reload
    pal.buf_free("ow.stars")
    b = pal.buf("ow.stars", 4 * #M.STARS)
  end
  buf = b
end

-- worst-case tris emit()+emit_fx() can produce (dyn buffer sizing)
function M.max_tris()
  return #M.STARS * BALL_TRIS * 2
end

function M.count()
  return state.doc.stars, #M.STARS
end

function M.step()
  local k = state.doc.knobs.stars
  local d = state.doc
  local px, py, pz = player.pos()
  py = py + 0.8 -- mascot center (~1.9u tall)
  local r2 = k.r * k.r
  for i, s in ipairs(M.STARS) do
    local t = buf:f32(4 * (i - 1))
    if t == 0 then
      local dx, dy, dz = s[1] - px, star_y(s) - py, s[2] - pz
      if dx * dx + dy * dy + dz * dz < r2 then
        buf:f32(4 * (i - 1), k.pop)
        d.stars = d.stars + 1
        audio.sfx("coin")
        if d.stars == #M.STARS then
          d.star_t = k.banner
          audio.fanfare()
        end
      end
    elseif t > 0 then -- pop ghost ticking down; then hold at -1 forever
      buf:f32(4 * (i - 1), t > 1 and t - 1 or -1)
    end
  end
  if d.star_t > 0 then d.star_t = d.star_t - 1 end
end

-- one spinning bobbing star (spin reads through the facet lighting; the
-- lathe itself is revolution-symmetric)
local function emit_star(out, s, frame, phase, scale, alpha)
  local k = state.doc.knobs.stars
  local bob = m.sin((frame / k.bob_f + phase * 0.13) * m.tau) * k.bob
  local xf = m4.mul(m4.translate(s[1], star_y(s) + bob, s[2]),
                    m4.roty(frame * k.spin + phase))
  return gb.ball(out, xf, R_BALL * scale, N_SEG, STAR_COL, alpha)
end

-- present stars (opaque segment). Returns tris.
function M.emit(out, frame)
  local n = 0
  for i, s in ipairs(M.STARS) do
    if buf:f32(4 * (i - 1)) == 0 then
      n = n + emit_star(out, s, frame, i, 1)
    end
  end
  return n
end

-- pickup pops: a just-collected star leaves an expanding fading ghost
-- (blend segment, drawn after the shadows). Returns tris.
function M.emit_fx(out, frame)
  local k = state.doc.knobs.stars
  local n = 0
  for i, s in ipairs(M.STARS) do
    local rem = buf:f32(4 * (i - 1))
    if rem > 0 then
      local u = (k.pop - rem) / k.pop -- 0 at pickup -> 1 gone
      n = n + emit_star(out, s, frame, i, 1 + 1.6 * u, ((1 - u) * 200) // 1)
    end
  end
  return n
end

return M
