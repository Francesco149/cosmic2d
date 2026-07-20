# The animation window

Cut a sprite's frame strip into named **clips** the game plays — walk,
idle, blink — with per-frame durations and a live preview.

It edits the **same `.spr`** as the sprite editor: open it from the sprite
window's **anim** header button, or spawn an **animation** window and drag
a `.spr` onto it. Both windows share one undo history and one dirty state —
a frame you paint shows in the playing preview immediately, and **ctrl+s**
in either window saves the same file (the `.anim` sidecar the game reads is
baked beside the `.png`).

## Workflow

1. **+** adds a clip (it starts as the current frame; **-** removes the
   selected clip). Click a clip in the list to select it.
2. **play / pause** previews the clip at real speed (one editor frame =
   one 1/60 s tick). With no clips yet, the preview just cycles the whole
   strip.
3. The **loop chip** cycles the end behavior: **loop / once / pingpong**.
4. The entry chips read **frame:duration** (1-based frame numbers, ticks
   at 60 Hz — `1:8` shows frame 1 for 8 ticks). Click one to select it
   (pausing the preview), **+f / -f** add/remove entries, and the **name**
   and **dur** fields edit the selected clip and entry.

## Walkthrough: idle, walk, blink

Three clips carry most characters, and the timing tricks matter more
than the art:

1. Draw 6 frames in the sprite editor: 2 idle (base + a 1px chest
   shift), 3 walk (contact, passing, contact — mirror the arms), 1
   blink (eyes shut).
2. **idle**: `1:40 2:8` — long base, short shift. Uneven durations are
   what makes idles breathe; equal ones read as a metronome.
3. **walk**: `3:7 4:6 5:7 4:6`, loop — reusing the passing frame (4)
   between contacts buys a 4-beat walk from 3 drawings.
4. **blink**: `1:1 6:3 1:1`, **once** — play it from code on a random
   timer over the idle; a whole-strip blink clip is never needed.
5. **space** to preview each at real speed, then **ctrl+s** — the same
   save as the sprite window; the game's `.anim` sidecar bakes beside
   the strip.

## In the game

```lua
local anim = cm.require("cm.anim")
-- clips load from art/hero.anim beside the baked strip
```

The scripting guide's sprite section covers drawing a clip's current
frame; the demos' player code is the worked example.

Full reference: [the sprite editor](engine/stock/docs/win-sprite.md) and
[animation in game code](engine/stock/docs/scripting.md#animation-clips-and-sprites-cmanim-cmsprite).
