-- padtest — the gamepad determinism fixture (A4/D083). A dot driven by
-- pad 1's left stick plus per-button tallies, all in state.doc, so a
-- recorded gamepad trace exercises the full PAD-extension path through
-- the sim: quantized axes, press/release edges, connect/disconnect.
-- tests/traces/padtest_drive.ctrace replays this on every platform.
--
-- Deliberately reads pads EVERY frame: the pad readers activate the pad
-- domain (cm.input latches the PAD extension on), which is exactly the
-- shape a real gamepad game has. Keyboard also steers, so the fixture is
-- hand-testable without a controller.
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")

local W, H = pal.gfx_size()
local DOT = 8

local game = {}

function game.init()
  input.map({ { "left", input.key.left }, { "right", input.key.right },
              { "up", input.key.up }, { "down", input.key.down } })
  local d = state.doc
  if d.x == nil then
    d.x, d.y = W / 2, H / 2
    d.presses = 0  -- south press edges
    d.releases = 0 -- south release edges
    d.plugs = 0    -- pad-1 connect transitions
    d.axsum = 0    -- running |quantized lx| sum (exact integer)
    d.was_conn = false
  end
end

function game.step()
  local d = state.doc
  local lx, ly = input.pad_axis(1, "lx"), input.pad_axis(1, "ly")
  -- quantized -127..127 over 32 px/s at 60 Hz: exact float math per frame
  d.x = d.x + lx * (32 / 127 / 60)
  d.y = d.y + ly * (32 / 127 / 60)
  if input.down("left") then d.x = d.x - 1 end
  if input.down("right") then d.x = d.x + 1 end
  if input.down("up") then d.y = d.y - 1 end
  if input.down("down") then d.y = d.y + 1 end
  if d.x < 0 then d.x = 0 elseif d.x > W - DOT then d.x = W - DOT end
  if d.y < 0 then d.y = 0 elseif d.y > H - DOT then d.y = H - DOT end

  if input.pad_pressed(1, "south") then d.presses = d.presses + 1 end
  if input.pad_released(1, "south") then d.releases = d.releases + 1 end
  local conn = input.pad_connected(1)
  if conn and not d.was_conn then d.plugs = d.plugs + 1 end
  d.was_conn = conn
  d.axsum = d.axsum + (lx < 0 and -lx or lx)
end

function game.draw()
  pal.begin_frame(0.08, 0.09, 0.12, 1)
  local d = state.doc
  pal.quad(d.x, d.y, DOT, DOT, 0.55, 0.85, 0.95, 1)
  text.draw(6, 6, ("pads:%s presses:%d releases:%d plugs:%d axsum:%d")
            :format(input.pad_connected(1) and "1" or "-", d.presses,
                    d.releases, d.plugs, d.axsum),
            { r = 0.95, g = 0.92, b = 0.8, a = 0.9 })
end

return game
