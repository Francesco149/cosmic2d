# cellar

A tiny top-down action game in one file: find the key in the cellar,
unlock the door, cross the vault, weigh the pressure plate down, and take
the gem. It exists to be read — open it in the editor and poke around.

## Controls

See `CONTROLS.md`. Arrows/WASD or the left stick move (the stick is
analog); E/Space or the pad's bottom face button interacts; R restarts.
Everything is rebindable from the Esc menu.

## What it teaches

- **Deterministic state**: everything that changes per frame lives in
  `state.doc` — position, the room you're in, which pickups you hold — so
  snapshots, traces, and rewind carry the whole game by construction.
- **Movement** (`cm.move`): one call merges the analog stick with the
  digital keys into a unit-scale direction; the game keeps its own speed.
- **Collision** (`cm.box`): axis-at-a-time `slide` against a list of
  rects is the whole wall response; `touch` and `expand` are the pickup
  and interact-reach queries.
- **Depth sorting** (`cm.depth`): pillars and the player sort by their
  base y, so you walk behind and in front of the same prop.
- **HUD** (`cm.hud`): the message line is anchored text; button prompts
  come from `hud.label`, which names the player's real current bindings.
- **Rooms and persistence**: rooms are plain static tables; walking into
  an open doorway swaps `doc.room`, and the key persists across rooms
  because it lives in doc, not in the room.

## File tour

- `main.lua` — the whole game, top to bottom: room data, movement,
  pickups, the plate/gate trigger, the locked door, transitions, y-sorted
  drawing, and the HUD. Comments mark where each engine module carries
  what used to be hand-rolled code.
- `project.lua` — name, resolution, and the player-packaging metadata
  (icon, controls, credits, licenses).

## Things to try

- Move the key into the vault, so you have to sneak in before unlocking.
- Add a third room: a new `ROOMS` entry, a door on each side, done.
- Make the gate need the gem too, and put a second gem behind it.
- Raise `SPEED`, shrink the player, or give pillars a wider base.
- Add a timer with `state.frame()` and show a best time on the HUD.

## Starter template

The picker's **top-down** starter template is this game's naive minimal
cousin — same genre shape, deliberately hand-rolled instead of using the
engine modules above, so you can see exactly what they save you.
