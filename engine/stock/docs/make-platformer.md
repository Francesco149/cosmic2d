# Making your platformer

You started from the **platformer** template: run, jump, reach the flag,
all in one `main.lua` you can edit while it runs. This is the tutorial
that turns it into YOUR game — each step uses one of the engine's
strongest tools and links its full guide.

## 1. Feel first

Play it (click the game window, press a key). Now open `main.lua`
beside it and change `JUMP = -5.6` to `-7`; **ctrl+s**. The running
game jumps higher **the same frame** — every constant at the top of the
file is a live feel knob. Tune `RUN`, `MAXVX`, and `GRAV` until moving
feels like yours; this matters more than any art.

Missed why you died? The **rewind** rail under the game window scrubs
back through what just happened, and resuming from the past
**rewrites it** — the whole loop is deterministic.

## 2. A hero, not a rectangle

Spawn a **sprite** window (right-click the canvas), make a 16x16
`art/hero.spr`, and draw — see the
[sprite editor](engine/stock/docs/win-sprite.md) for tools and its
**fill recipes** for instant texture. Cut idle/walk clips in the
[animation window](engine/stock/docs/win-anim.md) (its walkthrough's
timing tricks are exactly what a platformer hero needs). Then in
`game.draw`, replace the player quad:

    local gfx = cm.require("cm.gfx")
    gfx.sprite(gfx.texture(cm.main.args.project .. "/art/hero.png"),
               d.x, d.y)

and it hot-reloads every time you re-save the art.

## 3. A real level

The `SOLIDS` table is fine for a first screen; a level wants the
[map editor](engine/stock/docs/win-map.md). Its **layered lakeside**
walkthrough builds exactly what a platformer needs — parallax
backdrop, fillable ground, water, markers. Draw collider chains for
your terrain (slopes work), add a `spawn` and a `goal` marker, save as
`level1.map`, then swap the code's rectangles for the map:

    local map = cm.require("cm.map")
    local room
    function game.init()
      room = map.use({ path = cm.main.args.project .. "/level1.map",
                       name = "game.room" })
    end

Movement goes through the collision world (it handles slopes and
one-way platforms for free):

    d.x, d.y, hit = room.world:move(d.x, d.y, PW, PH, d.vx, d.vy,
                                    { ground = d.grounded })

Draw it with `map.draw_places(room, camx, camy)` and read the goal
from `room.doc.markers` instead of the `GOAL` table. The scripting
guide's [map](engine/stock/docs/scripting.md) sections have every call.

## 4. Sound

The synth's `sfx-jump` preset is one click from YOUR jump sound —
the [synth walkthrough](engine/stock/docs/win-synth.md) bends it and
builds a bass; the [music walkthrough](engine/stock/docs/win-music.md)
turns that into a four-track loop. Trigger sounds in `game.step`
(never `draw`) — the scripting guide's sound section is the copyable
upload-and-play pattern.

## 5. Ship it

Name it, write the controls card, and build a player archive — the
[getting started](engine/stock/docs/getting-started.md) guide's last
step walks the project window's export door. Players get F1 for
volume, rebinds, and accessibility without you writing anything.

Keep going: a second room via a `portal` marker, coins that
`cm.save` remembers, weather from a parallax layer. One tool at a
time, always with the game running.
