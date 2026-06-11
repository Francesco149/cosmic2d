-- fx — particles v0 (M3): one pooled buffer, spawned by gameplay moments
-- (landings, footfalls, throws, crate impacts), drawn via the bulk path.
-- Particles are cosmetic but still SIM state (deterministic, snapshotted):
-- spawn uses pt.rand, step uses fixed dt, pool lives in a named buffer.
--
-- sandbox.fx layout: [0] u32 ring cursor | [4..15] reserved
--   then NPART * 32B: x y vx vy life life0 shade (f32) + 4 spare bytes
-- shade picks the palette: < 1.5 dust (gray-brown), < 3 spark (warm),
-- >= 3 boom (white-blue — dive trails and dash pops).

local m = pt.require("pt.math")
local rand = pt.require("pt.rand")
local ease = pt.require("pt.ease")
local state = pt.require("pt.state")

local M = {}

local DT = 1.0 / 60.0
local NPART = 256
local STRIDE = 32
local HDR = 16

local buf, scratch

function M.init()
  buf = pal.buf("sandbox.fx", HDR + NPART * STRIDE)
  scratch = pal.buf(nil, NPART * 48)
end

-- spawn n particles at (x, y). o: vx0/vx1, vy0/vy1 velocity ranges,
-- life0/life1, shade0/shade1 (palette position), grav override
function M.spawn(x, y, n, o)
  local cur = buf:u32(0)
  for _ = 1, n do
    local p = HDR + cur * STRIDE
    buf:f32(p, x)
    buf:f32(p + 4, y)
    buf:f32(p + 8, m.lerp(o.vx0 or -30, o.vx1 or 30, rand.float()))
    buf:f32(p + 12, m.lerp(o.vy0 or -50, o.vy1 or -10, rand.float()))
    local life = m.lerp(o.life0 or 0.25, o.life1 or 0.55, rand.float())
    buf:f32(p + 16, life)
    buf:f32(p + 20, life)
    buf:f32(p + 24, m.lerp(o.shade0 or 0, o.shade1 or 1, rand.float()))
    cur = (cur + 1) % NPART
  end
  buf:u32(0, cur)
end

function M.step()
  local k = state.doc.knobs.fx
  local g = k.gravity
  for i = 0, NPART - 1 do
    local p = HDR + i * STRIDE
    local life = buf:f32(p + 16)
    if life > 0 then
      local vx, vy = buf:f32(p + 8), buf:f32(p + 12) + g * DT
      vx = vx * (1.0 - k.drag * DT)
      buf:f32(p, buf:f32(p) + vx * DT)
      buf:f32(p + 4, buf:f32(p + 4) + vy * DT)
      buf:f32(p + 8, vx)
      buf:f32(p + 12, vy)
      buf:f32(p + 16, life - DT)
    end
  end
end

function M.draw()
  local n = 0
  for i = 0, NPART - 1 do
    local p = HDR + i * STRIDE
    local life = buf:f32(p + 16)
    if life > 0 then
      local fade = ease.cubic_out(m.clamp(life / buf:f32(p + 20), 0, 1))
      local shade = buf:f32(p + 24)
      local r, g, b
      if shade < 1.5 then -- dust
        local v = 0.42 + 0.22 * shade
        r, g, b = v * 1.12, v, v * 0.82
      elseif shade < 3.0 then -- spark
        local t = shade - 1.5
        r, g, b = 1.0, 0.72 - 0.25 * t, 0.30 - 0.18 * t
      else -- boom
        local t = m.clamp(shade - 3.0, 0, 1)
        r, g, b = 1.0 - 0.18 * t, 0.95 - 0.08 * t, 1.0
      end
      local q = n * 48
      local size = fade > 0.6 and 2 or 1
      scratch:f32(q, buf:f32(p) - size / 2)
      scratch:f32(q + 4, buf:f32(p + 4) - size / 2)
      scratch:f32(q + 8, size)
      scratch:f32(q + 12, size)
      scratch:f32(q + 16, 0)
      scratch:f32(q + 20, 0)
      scratch:f32(q + 24, 1)
      scratch:f32(q + 28, 1)
      scratch:f32(q + 32, r * fade)
      scratch:f32(q + 36, g * fade)
      scratch:f32(q + 40, b * fade)
      scratch:f32(q + 44, fade * 0.9)
      n = n + 1
    end
  end
  if n > 0 then pal.draw_quads(0, scratch, n) end
end

return M
