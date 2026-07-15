# cosmic2d

A tiny 2D pixel-art engine / fantasy console. One self-contained folder holds
the engine, its editor and tools, and your game projects — make a game with
the built-in editor, share it by zipping a folder, and the recipient can play
it, edit it live, or build their own with the same binary.

**Status: alpha.** The engine, the infinite-canvas editor, the audio stack,
and an out-of-the-box demo game are all here. Rough edges remain, but you can
make and ship a small platformer today.

## Try it

Linux/WSL2 with [Nix](https://nixos.org):

```sh
nix develop -c make -C pal     # build bin/cosmic
bin/cosmic                     # the project picker — the front door
```

The picker lists your projects. Open the bundled **demo** (a two-room
platformer with music that swaps between rooms), or press **+ New project**
to scaffold your own. A tile opens a project in the editor; the ▶ zone plays
it.

```sh
bin/cosmic projects/demo            # play the demo directly
bin/cosmic projects/demo --edit     # open it in the editor
```

A packaged engine bundle (`nix build .#cosmic` / `.#cosmic-windows`) drops two
launchers in its **root** so there's nothing to figure out — extract and run
the one you want:

- **`cosmic2d-editor`** (`.exe`) — the project picker / editor front door.
- **`demo`** (`.exe`) — the bundled demo, straight to play.

## Make a game

Everything is authored in the editor (`--edit`, or via the picker): an
infinite canvas of floating windows. Spawn windows from the right-click
menu — a **code editor**, a **sprite editor** (+ animation), a **map editor**
(collider chains, one-ways, markers) and **tilemaps**, a **sound player**, a
**synth** (FM + Game Boy voices with filter/pitch-sweep), a **music** tracker,
and a **palette** designer. New assets and projects auto-name themselves with
three random words, so nothing blocks on a filename.

The game itself is hot-reloadable Lua: edit `main.lua` while it runs. See
`projects/demo/` for a complete, commented example — the moveset, two rooms,
sound effects, and two 30-second BGMs.

## Ship a game

Package a project into a standalone, play-only artifact for someone who just
wants to play:

```sh
nix run .#package -- demo          # -> demo-windows.zip (self-contained)
nix run .#package -- demo linux    # -> demo-linux.tar.gz
```

The bundle contains only the engine runtime + that one project + this README
and LICENSE; the launcher is renamed so running it boots the game locked to
play mode (no editor, no other projects).

## Shape of the thing

- **Two layers**: a small per-platform C binary ("PAL": SDL3 + Vulkan via
  SDL_GPU, embedded Lua 5.4, typed memory buffers, a frame-locked FM/sampler
  audio synth) under a fully hot-reloadable Lua engine — game code, physics,
  the editor, and all tools are Lua you can edit while the game runs.
- **Deterministic to the bit**: fixed 60 Hz sim, snapshot/rewind any frame
  (emulator-style), input-trace regression tests against state + pixel + PCM
  goldens on a pinned software Vulkan driver.
- **Batteries included**: a platformer moveset, sprite/animation + map +
  tilemap editors, an FM/Game-Boy synth and a music tracker with stock
  instruments and sound effects, a palette designer with stock palettes, and
  a demo game to start from.

Deep dives live in `docs/` — `PLAN.md` (vision), `ARCHITECTURE.md` (the
two-layer design + determinism rules), `EDITOR.md`, `AUDIO.md`, `MAPS.md`.

## Platforms

Linux and Windows desktop (the Windows build is a self-contained cross-build,
produced by the packager above). macOS is not yet supported.

## License

MIT — see [LICENSE](LICENSE). Vendored third-party code keeps its own
(compatible) licenses, noted in `pal/vendor/`.
