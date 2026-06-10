-- sandbox main.lua — M1 demo cartridge: a particle playground exercising
-- the whole new stack. Edit anything while it runs; sim state lives in
-- named buffers + the doc tree, so hot reload never drops a particle.
--
--   arrows / wasd   push the emitter around
--   space           particle burst from the emitter
--   mouse click     burst at the cursor
--   escape          quit
--
-- Determinism notes: all sim randomness from pt.rand, all sim trig from
-- pt.math, fixed dt. Draw-side flourishes may use wall-clock-free state
-- only (everything you see replays byte-exact from a trace).

local m = pt.require("pt.math")
local rand = pt.require("pt.rand")
local state = pt.require("pt.state")
local input = pt.require("pt.input")
local text = pt.require("pt.text")
local gfx = pt.require("pt.gfx")
local ease = pt.require("pt.ease")

local W, H = pal.gfx_size()
local DT = 1.0 / 60.0
local NPART = 1024
local PSTRIDE = 24 -- x y vx vy life hue (f32 each)

-- sandbox.sim: [0] f32 emitter x | [4] y | [8] vx | [12] vy
--              [16] u32 particle ring cursor | [20] u32 live count
local sim
local parts -- sandbox.particles: NPART * PSTRIDE
local scratch -- anon draw buffer (render-only, not sim state)

local game = {}

-- starfield decoration: pure function of a constant, rebuilt per reload —
-- deliberately NOT sim state and NOT from pt.rand (init must not touch the
-- sim PRNG stream, or reload would not be idempotent)
local stars = {}
do
  local z = 0x5747a5
  local function n()
    z = (z * 1103515245 + 12345) & 0x7fffffff
    return z / 0x7fffffff
  end
  for i = 1, 90 do
    stars[i] = { x = n() * (W + 200) - 100, y = n() * (H + 100) - 50,
                 depth = 0.25 + 0.45 * n(), b = 0.25 + 0.6 * n() }
  end
end

function game.init()
  sim = pal.buf("sandbox.sim", 64)
  parts = pal.buf("sandbox.particles", NPART * PSTRIDE)
  scratch = pal.buf(nil, NPART * 48)
  if sim:f32(0) == 0 and sim:f32(4) == 0 then -- virgin state only
    sim:f32(0, W / 2)
    sim:f32(4, H / 2)
  end
  local d = state.doc
  d.knobs = d.knobs or { gravity = 170.0, drag = 1.6, accel = 420.0,
                         trickle = 2, burst = 44, bounce = 0.78,
                         speed_curve = "quad_in", fade_curve = "cubic_out" }
  input.map({
    { "left", input.key.left, input.key.a },
    { "right", input.key.right, input.key.d },
    { "up", input.key.up, input.key.w },
    { "down", input.key.down, input.key.s },
    { "burst", input.key.space },
    { "quit", input.key.escape },
  })
end

local function spawn(x, y, n, kick)
  local cur = sim:u32(16)
  local speed_curve = state.doc.knobs.speed_curve or "quad_in"
  for _ = 1, n do
    local o = cur * PSTRIDE
    local a = rand.float() * m.tau
    -- eased speed distribution: most particles slow, a fast tail (denser
    -- core, longer streaks — feel knob, swap the curve name live)
    local sp = ease.mix(24.0, 134.0, rand.float(), speed_curve) + kick
    parts:f32(o, x)
    parts:f32(o + 4, y)
    parts:f32(o + 8, m.cos(a) * sp)
    parts:f32(o + 12, m.sin(a) * sp - kick * 0.6)
    parts:f32(o + 16, 1.4 + rand.float() * 1.8) -- seconds of life
    parts:f32(o + 20, rand.float())
    cur = (cur + 1) % NPART
  end
  sim:u32(16, cur)
end

function game.step()
  local k = state.doc.knobs

  if input.down("quit") then pal.quit() end

  -- emitter: push, drag, soft wall bounce
  local ex, ey = sim:f32(0), sim:f32(4)
  local evx, evy = sim:f32(8), sim:f32(12)
  local ax = (input.down("right") and 1 or 0) - (input.down("left") and 1 or 0)
  local ay = (input.down("down") and 1 or 0) - (input.down("up") and 1 or 0)
  evx = (evx + ax * k.accel * DT) * (1.0 - k.drag * DT)
  evy = (evy + ay * k.accel * DT) * (1.0 - k.drag * DT)
  ex = ex + evx * DT
  ey = ey + evy * DT
  if ex < 12 then ex, evx = 12, -evx * 0.5 end
  if ex > W - 12 then ex, evx = W - 12, -evx * 0.5 end
  if ey < 12 then ey, evy = 12, -evy * 0.5 end
  if ey > H - 12 then ey, evy = H - 12, -evy * 0.5 end
  sim:f32(0, ex)
  sim:f32(4, ey)
  sim:f32(8, evx)
  sim:f32(12, evy)

  -- emission
  spawn(ex, ey, k.trickle, 0)
  if input.pressed("burst") then spawn(ex, ey, k.burst, 60) end
  if input.button_pressed(1) then
    local mx, my = input.mouse()
    spawn(m.clamp(mx, 0, W), m.clamp(my, 0, H), k.burst, 30)
  end

  -- particles: integrate, bounce, age
  local g, bounce = k.gravity, k.bounce
  local live = 0
  for i = 0, NPART - 1 do
    local o = i * PSTRIDE
    local life = parts:f32(o + 16)
    if life > 0 then
      local x, y = parts:f32(o), parts:f32(o + 4)
      local vx, vy = parts:f32(o + 8), parts:f32(o + 12)
      vy = vy + g * DT
      x = x + vx * DT
      y = y + vy * DT
      if y > H - 2 then
        y = H - 2
        vy = -vy * bounce
        vx = vx * 0.96
      end
      if x < 1 then x, vx = 1, -vx * bounce end
      if x > W - 1 then x, vx = W - 1, -vx * bounce end
      parts:f32(o, x)
      parts:f32(o + 4, y)
      parts:f32(o + 8, vx)
      parts:f32(o + 12, vy)
      parts:f32(o + 16, life - DT)
      live = live + 1
    end
  end
  sim:u32(20, live)
end

local function hue(t, phase)
  return 0.62 + 0.38 * m.sin(t * m.tau + phase)
end

function game.draw()
  pal.begin_frame(0.055, 0.06, 0.10, 1)
  local frame = state.frame()
  local ex, ey = sim:f32(0), sim:f32(4)

  -- camera orbits the emitter lazily; parallax via layer multipliers
  local cx = ex - W / 2 + m.sin(frame * 0.004) * 14
  local cy = ey - H / 2 + m.cos(frame * 0.003) * 9
  gfx.camera(cx * 0.25, cy * 0.25)

  for _, s in ipairs(stars) do
    gfx.layer(s.depth)
    pal.quad(s.x, s.y, 1, 1, s.b, s.b, s.b * 1.1, 1)
  end

  gfx.layer(1)
  -- particles via the bulk path: pack live ones into the scratch buffer
  local fade_fn = ease.get(state.doc.knobs.fade_curve or "cubic_out")
  local n = 0
  for i = 0, NPART - 1 do
    local o = i * PSTRIDE
    local life = parts:f32(o + 16)
    if life > 0 then
      local q = n * 48
      local fade = fade_fn(m.clamp(life, 0, 1))
      local h0 = parts:f32(o + 20)
      scratch:f32(q, parts:f32(o) - 1)
      scratch:f32(q + 4, parts:f32(o + 4) - 1)
      scratch:f32(q + 8, 2)
      scratch:f32(q + 12, 2)
      scratch:f32(q + 16, 0)
      scratch:f32(q + 20, 0)
      scratch:f32(q + 24, 1)
      scratch:f32(q + 28, 1)
      scratch:f32(q + 32, hue(h0, 0) * fade)
      scratch:f32(q + 36, hue(h0, 2.1) * fade)
      scratch:f32(q + 40, hue(h0, 4.2) * fade)
      scratch:f32(q + 44, fade)
      n = n + 1
    end
  end
  pal.draw_quads(0, scratch, n)

  -- emitter core: pulsing diamond
  local p = 3.5 + 1.5 * m.sin(frame * 0.11)
  pal.quad(ex - p, ey - 1, p * 2, 2, 1, 0.9, 0.55, 0.9)
  pal.quad(ex - 1, ey - p, 2, p * 2, 1, 0.9, 0.55, 0.9)

  -- HUD: screen-fixed
  gfx.layer(0)
  local rec = pt.trace and pt.trace.recording and pt.trace.recording()
  text.draw(3, 3, ("frame %d  live %d%s"):format(frame, sim:u32(20),
                                                 rec and "  REC" or ""),
            { g = 0.95, b = 0.8, a = 0.9 })
  text.draw(3, H - 11, "arrows/wasd push * space burst * click burst at cursor",
            { r = 0.55, g = 0.6, b = 0.7, a = 0.9 })
end

return game
