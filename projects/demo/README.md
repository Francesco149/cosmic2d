# cosmic demo

The out-of-the-box game: a two-room platformer with the full moveset —
flash-jumps, up-jumps, flutter, grapple, teleport, slice — coins, spikes,
particles, sound effects, and music that swaps when you portal between
the cozy town and the overworld. It exists to be read and edited: every
asset it uses opens in the editor's own windows.

## Controls

See `CONTROLS.md`. Arrows or the left stick move, Space jumps (again in
the air to flash-jump), and the rest of the kit sits on nearby keys and
pad buttons. Everything is rebindable from the Esc menu's controls page.

## What it teaches

- **A multi-file project**: gameplay split into modules loaded with
  `cm.require`, each adopting the loader's table so live reload and
  bundle re-execution keep one shared state.
- **Maps as assets** (`cm.map`): both rooms are committed `.map` files —
  collider chains, tilemap placements, and markers for spawns, portals,
  coins, and hazards. Open them in the map window and edit while playing.
- **The map mover** (`cm.collide`): the player rides the engine's
  tilemap mover with one-way platforms; feel and assists stay game-side.
- **The camera** (`cm.camera`): follow easing with a deadzone and
  lookahead, world bounds, the portal cut, and a real shake on the spike
  pit — plus per-layer map parallax on the backdrops.
- **Juice and HUD**: particles in a named buffer (`fx.lua`), and HUD
  lines through `cm.hud`'s anchored text with live binding labels.
- **Audio as sim state** (`cm.snd`): instrument presets (`ins/`) and
  two `.song` tracks, played through the deterministic mixer — the music
  swap is part of the recorded, rewindable state.

## File tour

- `main.lua` — boot, input map, room logic, coins/spikes, the portal.
- `player.lua` — the whole moveset controller; tuning constants up top.
- `level.lua` — loads the two `.map` rooms and reads their markers.
- `fx.lua` — the pooled particle system (a named buffer, bulk-drawn).
- `pix.lua` — procedural placeholder pixel art (render-only).
- `audio.lua` — SFX one-shots and the per-room BGM.
- `town.map`, `overworld.map` + `*.tm` — the rooms and their tilemaps.
- `art/`, `ins/`, `sound/` — sprites, instruments, and songs; all open
  in the sprite, instrument, and song windows.
- `project.lua` — name, resolution, and player-packaging metadata.

## Things to try

- Change a jump constant in `player.lua` and feel it instantly (Ctrl+S
  hot-reloads while the game runs).
- Open `town.map` in the map window and add a platform or a coin marker.
- Swap the town music: point `audio.lua` at `overworld.song`.
- Add a third room: a new `.map`, a portal marker on each side.
- Recolor the tiles in the sprite window (`art/tiles.spr`).

## Starter template

The picker's **platformer** starter template is this game's naive
minimal cousin — one file, hand-rolled physics, no maps or audio — the
smallest version of the same shape to grow from.
