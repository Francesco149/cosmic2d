-- W1 sim tick: distilled player.step shape — per entity: ~18 buf:f32 reads,
-- float physics w/ branches, tile collision vs a solids array, ~12 writes.
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local DT = 1 / 60
local NE = 200          -- entities
local FRAMES = 600
local STRIDE = 32

-- 50x22 room: floor + 3 planks (same data both languages)
local RW, RH, TS = 50, 22, 8
local sol = {}
for i = 0, RW * RH - 1 do sol[i + 1] = 0 end
for tx = 0, RW - 1 do sol[(RH - 1) * RW + tx + 1] = 1; sol[tx + 1] = 1 end
for ty = 0, RH - 1 do sol[ty * RW + 1] = 1; sol[ty * RW + RW] = 1 end
for tx = 10, 18 do sol[15 * RW + tx + 1] = 1 end
for tx = 24, 32 do sol[11 * RW + tx + 1] = 1 end
for tx = 36, 44 do sol[7 * RW + tx + 1] = 1 end

local function solid_at(px, py)
  local tx, ty = floor(px / TS), floor(py / TS)
  if tx < 0 or tx >= RW or ty < 0 or ty >= RH then return true end
  return sol[ty * RW + tx + 1] == 1
end

local function approach(v, target, step)
  if v < target then return min(v + step, target)
  else return max(v - step, target) end
end

-- init entities
for e = 0, NE - 1 do
  local b = e * STRIDE
  buf:f32(b + 0, 40 + (e % 40) * 8)  -- x
  buf:f32(b + 1, 24 + floor(e / 40) * 16) -- y
  buf:f32(b + 4, 1)                  -- facing
end

local W, H = 6, 10
local walk_speed, walk_accel, fric = 90, 900, 1200
local g_rise, g_fall, v0, vmax = 1800, 2200, -210, 260
local coyote_n, jbuf_n = 6, 5

local function step_entity(e, f)
  local b = e * STRIDE
  local x, y = buf:f32(b + 0), buf:f32(b + 1)
  local vx, vy = buf:f32(b + 2), buf:f32(b + 3)
  local facing = buf:f32(b + 4)
  local grounded = buf:f32(b + 5) == 1
  local coyote, jbuf = buf:f32(b + 6), buf:f32(b + 7)
  local hop_cd = buf:f32(b + 8)
  local flutter_t = buf:f32(b + 9)
  local tp_cd = buf:f32(b + 10)
  local attack_t = buf:f32(b + 11)
  local squash_t, stretch_t = buf:f32(b + 12), buf:f32(b + 13)

  -- deterministic pseudo-input from the frame counter (same both langs)
  local ph = f + e * 7
  local dir = (floor(ph / 16) % 3) - 1
  local press = (ph % 37) == 0

  if dir ~= 0 then facing = dir end
  if grounded then
    if dir ~= 0 then vx = approach(vx, dir * walk_speed, walk_accel * DT)
    else vx = approach(vx, 0, fric * DT) end
    coyote = coyote_n
  else
    if dir ~= 0 then vx = approach(vx, dir * walk_speed, walk_accel * 0.6 * DT) end
    coyote = max(coyote - 1, 0)
  end

  if press then jbuf = jbuf_n else jbuf = max(jbuf - 1, 0) end
  if jbuf > 0 and coyote > 0 then
    vy, jbuf, coyote, grounded = v0, 0, 0, false
    stretch_t = 0.12
  end

  vy = min(vy + (vy < 0 and g_rise or g_fall) * DT, vmax)

  -- move x then y, corner checks (tm:move distillation)
  local nx = x + vx * DT
  if vx > 0 then
    if solid_at(nx + W, y) or solid_at(nx + W, y + H - 1) then
      nx = floor((nx + W) / TS) * TS - W - 0.001; vx = 0
    end
  elseif vx < 0 then
    if solid_at(nx, y) or solid_at(nx, y + H - 1) then
      nx = (floor(nx / TS) + 1) * TS + 0.001; vx = 0
    end
  end
  x = nx
  local ny = y + vy * DT
  local was = grounded
  grounded = false
  if vy > 0 then
    if solid_at(x, ny + H) or solid_at(x + W, ny + H) then
      ny = floor((ny + H) / TS) * TS - H - 0.001
      vy = 0; grounded = true
      if not was then squash_t = 0.10 end
    end
  elseif vy < 0 then
    if solid_at(x, ny) or solid_at(x + W, ny) then
      ny = (floor(ny / TS) + 1) * TS + 0.001; vy = 0
    end
  end
  y = ny

  hop_cd = max(hop_cd - DT, 0)
  tp_cd = max(tp_cd - DT, 0)
  attack_t = max(attack_t - DT, 0)
  squash_t = max(squash_t - DT, 0)
  stretch_t = max(stretch_t - DT, 0)
  flutter_t = grounded and 0 or max(flutter_t - DT, 0)

  buf:f32(b + 0, x); buf:f32(b + 1, y)
  buf:f32(b + 2, vx); buf:f32(b + 3, vy)
  buf:f32(b + 4, facing)
  buf:f32(b + 5, grounded and 1 or 0)
  buf:f32(b + 6, coyote); buf:f32(b + 7, jbuf)
  buf:f32(b + 8, hop_cd); buf:f32(b + 9, flutter_t)
  buf:f32(b + 10, tp_cd); buf:f32(b + 11, attack_t)
  buf:f32(b + 12, squash_t); buf:f32(b + 13, stretch_t)
end

-- warmup
for f = 1, 60 do for e = 0, NE - 1 do step_entity(e, f) end end

local times = {}
for f = 1, FRAMES do
  local t0 = now()
  for e = 0, NE - 1 do step_entity(e, f) end
  times[f] = now() - t0
end

table.sort(times)
local sum = 0
for i = 1, FRAMES do sum = sum + times[i] end
local chk = 0
for e = 0, NE - 1 do chk = chk + buf:f32(e * STRIDE) + buf:f32(e * STRIDE + 1) end
emit(string.format("w_sim %d entities: avg %.1f us  p50 %.1f  p99 %.1f  max %.1f  (chk %.3f)",
  NE, sum / FRAMES / 1000, times[floor(FRAMES / 2)] / 1000,
  times[floor(FRAMES * 0.99)] / 1000, times[FRAMES] / 1000, chk))
