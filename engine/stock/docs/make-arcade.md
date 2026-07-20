# Making your arcade game

You started from the **arcade** template: one screen, shoot the falling
rocks, three misses and the run ends. Arcade games are the fastest
route to FINISHED — this tutorial adds the art, juice, sound, and a
saved best score that make one screen feel complete.

## 1. Feel first

Play a run, then tune the top-of-file knobs live: `START_EVERY` sets
the pressure curve, `COOLDOWN` the fire rate, `SPEED` the ship.
**ctrl+s** while it runs. The template's randomness comes from
`cm.rand` (engine PRNG, part of sim state) — which is why the
**rewind** rail can replay a death bit-for-bit; scrub back and watch
what actually clipped you.

## 2. Art pass

A ship, a rock, and a two-frame thruster flicker: one `.spr` each in
the [sprite editor](engine/stock/docs/win-sprite.md). The
**fill recipes** make rocks fast — a drawn blob silhouette + a masked
**ridged** fill is an asteroid per reroll of **sd**. An explosion is a 4-frame
strip cut in the [animation window](engine/stock/docs/win-anim.md)
(`once`, short durations) played at the hit position.

## 3. Juice

Small screen, so effects carry. On a hit:

    local tween = cm.require("cm.tween")
    local camera = cm.require("cm.camera")

a camera bump (`camera.offset`) plus a white wash drawn through
`tween.flash` reads as impact — and both automatically respect the
player's reduce-shake / reduce-flash accessibility settings, because
they are the engine's policy doors (the scripting guide's *Reduced
effects* section). Score popups are `cm.text` with a one-second climb.

## 4. Sound

`sfx-laser` and `sfx-explosion` are in the synth's preset strip —
click, bend, save as yours (the
[synth walkthrough](engine/stock/docs/win-synth.md)). For music, the
[tracker walkthrough](engine/stock/docs/win-music.md)'s loop pattern
at a fast rate with the noise kit is instant arcade urgency. Trigger
everything from `game.step`.

## 5. The best score survives

Arcade needs exactly one piece of persistence:

    local save = cm.require("cm.save")

Bank `best` when a run ends, show it on the title line. The scripting
guide's player-saves section is the pattern — saves live outside the
project folder, so your exported game never writes into itself.

## 6. Ship it

Name it, controls card, export — the
[getting started](engine/stock/docs/getting-started.md) guide's last
step. One-screen games demo beautifully from the portable player.

Keep going: a second enemy type on a sine path (`cm.math`'s sin — sim
code never calls host math), waves announced with `cm.text`, a
two-ship co-op run off pad 2. Small game, every feature lands the
same day.

## Full reference

[Sprite](engine/stock/docs/win-sprite.md) ·
[animation](engine/stock/docs/win-anim.md) ·
[synth](engine/stock/docs/win-synth.md) ·
[music](engine/stock/docs/win-music.md) are the complete tool guides.
[Writing a game](engine/stock/docs/scripting.md) is the runtime/API reference,
including deterministic randomness, juice, audio, saves, and gamepads.
