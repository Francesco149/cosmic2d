# Writing a game

A project is Lua. Its `main.lua` returns a `game` table with three methods
the engine calls for you:

    local game = {}

    function game.init()  end   -- once, at boot / after a reload
    function game.step()  end   -- every frame (fixed 60 Hz) — the sim
    function game.draw()  end   -- every frame — render only

    return game

Split `step` (simulation) from `draw` (rendering): only `step` may change
game state. Keep drawing side-effect free and the engine can snapshot,
rewind, and replay your game deterministically.

## Modules

Pull in engine modules with `cm.require`:

    local state = cm.require("cm.state")   -- the sim state tree (state.doc)
    local input = cm.require("cm.input")   -- buttons
    local text  = cm.require("cm.text")    -- bitmap text
    local m     = cm.require("cm.math")    -- deterministic math

Your own files are modules too: `cm.require("player")` loads `player.lua`
from the project.

## State, input, drawing

Keep sim state in `state.doc` (it is what gets snapshotted):

    local d = state.doc
    d.x = d.x or 100

Map and read buttons:

    input.map({ { "left", input.key.left }, { "jump", input.key.space } })
    if input.down("left")    then d.x = d.x - 2 end
    if input.pressed("jump") then d.vy = -5 end   -- edge, not held

Draw in `game.draw` with the PAL surface:

    local W, H = pal.gfx_size()
    pal.begin_frame(0.1, 0.1, 0.15, 1)          -- clear
    pal.quad(d.x, d.y, 16, 16, 1, 0.8, 0.4, 1)  -- x,y,w,h, r,g,b,a
    text.draw(6, 6, "hello!", { r = 1, g = 1, b = 1, a = 1 })

## Hot reload

Edit `main.lua` while the game runs — the change lands on the next frame,
no restart. `init` re-runs, so guard one-time state with `x = x or default`.

For the batteries — a full moveset, sprites, maps, and audio — read
`projects/demo/` and the deep-dive docs in `docs/`.

Back to [Getting started](engine/stock/docs/getting-started.md).
