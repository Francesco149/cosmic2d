-- W2 quad-batch prep: 5000 quads/frame, 300 frames.
-- A: per-call quad(...) (pal.quad shape)
-- B: 12x buf:f32 writes + draw_quads (the tilemap bulk path)
local floor = math.floor
local NQ, FRAMES = 5000, 300
local TW, TH = 256, 256

local function stats(times, label)
  table.sort(times)
  local sum = 0
  for i = 1, #times do sum = sum + times[i] end
  emit(string.format("%s: avg %.1f us  p50 %.1f  p99 %.1f  max %.1f",
    label, sum / #times / 1000, times[floor(#times / 2)] / 1000,
    times[floor(#times * 0.99)] / 1000, times[#times] / 1000))
end

-- A: per-call
local times = {}
for f = 1, FRAMES do
  local t0 = now()
  local cam = f * 0.5
  for i = 0, NQ - 1 do
    local tx = (i % 100) * 8 - cam
    local ty = floor(i / 100) * 8
    local u = (i % 32) * 8
    quad(tx, ty, 8, 8, u / TW, 0, (u + 8) / TW, 8 / TH, 1, 1, 1, 1)
  end
  draw_quads(NQ)
  times[f] = now() - t0
end
stats(times, "w_quad A percall")

-- B: bulk buffer writes (engine tilemap path: s:f32(o, v) x12 per quad)
times = {}
for f = 1, FRAMES do
  local t0 = now()
  local cam = f * 0.5
  local o = 0
  for i = 0, NQ - 1 do
    local tx = (i % 100) * 8 - cam
    local ty = floor(i / 100) * 8
    local u = (i % 32) * 8
    buf:f32(o, tx);            buf:f32(o + 1, ty)
    buf:f32(o + 2, 8);         buf:f32(o + 3, 8)
    buf:f32(o + 4, u / TW);    buf:f32(o + 5, 0)
    buf:f32(o + 6, (u + 8) / TW); buf:f32(o + 7, 8 / TH)
    buf:f32(o + 8, 1); buf:f32(o + 9, 1); buf:f32(o + 10, 1); buf:f32(o + 11, 1)
    o = o + 12
    if o >= 60000 then o = 0 end
  end
  draw_quads(NQ)
  times[f] = now() - t0
end
stats(times, "w_quad B bufwrite")
