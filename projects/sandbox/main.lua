-- sandbox main.lua — M0 demo cartridge: animated quads.
-- Sim state lives in a named buffer, so it survives hot reloads: edit a
-- color or speed below and save while it runs — motion continues seamlessly.
-- (math.sin here is fine for M0 demo cosmetics; golden'd sim code must use
-- pt.math once it exists — see docs/ARCHITECTURE.md "Determinism".)

local W, H = pal.gfx_size() -- boot.lua inits gfx before loading us
local sim -- [0]=u32 frame counter

local game = {}

function game.init()
  sim = pal.buf("sandbox.sim", 64)
end

function game.step(input)
  sim:u32(0, sim:u32(0) + 1)
end

function game.draw()
  local t = sim:u32(0)
  pal.begin_frame(0.09, 0.09, 0.13, 1)

  -- corner markers, orientation proof: red TL / green TR / blue BL / white BR
  pal.quad(0, 0, 8, 8, 1, 0.25, 0.25, 1)
  pal.quad(W - 8, 0, 8, 8, 0.25, 1, 0.4, 1)
  pal.quad(0, H - 8, 8, 8, 0.35, 0.45, 1, 1)
  pal.quad(W - 8, H - 8, 8, 8, 1, 1, 1, 1)

  -- orbiting quads
  for i = 0, 15 do
    local ph = t * 0.02 + i * 0.41
    local x = W / 2 + math.sin(ph) * (50 + i * 9) - 8
    local y = H / 2 + math.cos(ph * 0.7 + i) * (30 + i * 5.5) - 8
    local r = 0.55 + 0.45 * math.sin(i * 0.7)
    local g = 0.55 + 0.45 * math.sin(i * 0.7 + 2.1)
    local b = 0.55 + 0.45 * math.sin(i * 0.7 + 4.2)
    pal.quad(x, y, 16, 16, r, g, b, 0.9)
  end

  -- center pulse
  local s = 26 + 9 * math.sin(t * 0.05)
  pal.quad(W / 2 - s / 2, H / 2 - s / 2, s, s, 1, 0.8, 0.3, 1)
end

return game
