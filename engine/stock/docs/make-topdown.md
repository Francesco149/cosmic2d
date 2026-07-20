# Making your top-down game

You started from the **top-down** template: walk a walled room, collect
every gem, one editable `main.lua`. This tutorial grows it into a real
top-down world — rooms as data, art from the tile tools, sound — one
strong tool per step, each linking its full guide.

![The running top-down starter beside this tutorial](media/template-topdown.png)

## 1. Feel first

Play, then edit `SPEED` in `main.lua` and **ctrl+s** — the running game
picks it up instantly. Carve a door in the `WALLS` table the same way.
When something surprising happens, scrub the **rewind** rail under the
game window; resuming from the past rewrites it.

## 2. Floors and walls that look like a place

Top-down lives or dies on its ground. Make a tileset `.spr` (floor,
wall, a mossy variant — the
[sprite editor's fill recipes](engine/stock/docs/win-sprite.md) give
you stone and moss in minutes), then build a floor chunk in the
[tilemap editor](engine/stock/docs/win-tmap.md) — its **ruin wall**
walkthrough is the exact craft. Draw your hero and a gem sprite while
you're there; the [animation window](engine/stock/docs/win-anim.md)
makes the gem glint on a timer.

## 3. The room becomes data

Rebuild the room in the [map editor](engine/stock/docs/win-map.md):
place the tilemap, trace the walls as collider chains, and — the
important move — place the gems as **markers** instead of a code
table. Add a `spawn` marker too. Then:

    local map = cm.require("cm.map")
    local room
    function game.init()
      room = map.use({ path = cm.main.args.project .. "/room1.map",
                       name = "game.room" })
    end

Walk against `room.world:move(...)`, draw with `map.draw_places`, and
read gems from `room.doc.markers` (kind + position, in file order).
Now designers — you, tomorrow — add and move gems without touching
code. A `portal` marker with a custom `to` field
(`map.extras(marker).to`) is the whole multi-room mechanism: on
overlap, `map.use` the named room and place the player at its spawn.

## 4. Sound and mood

`sfx-coin` is one click from your pickup sound (the
[synth walkthrough](engine/stock/docs/win-synth.md) shows how to bend a
preset); the [music walkthrough](engine/stock/docs/win-music.md) builds
a loop — try it with the Game Boy noise family swapped for soft pulses
and a slow rate for dungeon mood. Trigger sounds in `game.step`.

## 5. Ship it

The [getting started](engine/stock/docs/getting-started.md) guide's
last step names the project, writes the controls card, and builds the
player archive. Progress that should survive a session (gems banked,
rooms cleared) goes through `cm.save` — the scripting guide's
player-saves section is short and exact.

Keep going: a patrolling enemy walking marker-to-marker, keys and
doors as paired markers, a dark dungeon variant by swapping the
tileset. The room-as-data step makes all of these cheap.

## Full reference

[Sprite](engine/stock/docs/win-sprite.md) ·
[animation](engine/stock/docs/win-anim.md) ·
[tilemap](engine/stock/docs/win-tmap.md) ·
[map](engine/stock/docs/win-map.md) ·
[synth](engine/stock/docs/win-synth.md) ·
[music](engine/stock/docs/win-music.md) are the complete tool guides.
[Writing a game](engine/stock/docs/scripting.md) is the runtime/API reference,
including movement, maps, markers, audio, and player saves.
