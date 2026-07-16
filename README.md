# cosmic2d

A tiny 2D pixel-art engine / fantasy console. The intended distribution is one
folder containing the engine, editor, tools, and game projects. The source
checkout is built with Nix and the extract-and-run archives are clean-machine
tested; in-editor export is still an alpha release gate.

**Status: alpha candidate.** The engine, infinite-canvas editor, audio stack,
and an out-of-the-box demo game are here. The deterministic suite is green,
but player-facing bundle polish, gamepad support, project/export UX, and broader
genre demos are still release gates; see `docs/ALPHA.md`.

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

The editor release bundles (`nix build .#cosmic` / `.#cosmic-windows`) contain
only the intentional demo and picker; `.#cosmic-dev` and
`.#cosmic-windows-dev` additionally carry internal tests and fixtures. Editor
bundles drop two launchers in their **root**:

- **`cosmic2d-editor`** (`.exe`) — the project picker / editor front door.
- **`demo`** (`.exe`) — the bundled demo, straight to play.

Windows `.exe` launchers use the GUI subsystem, so opening them normally does
not create a second console window. For diagnostics, automation, and headless
runs, use `bin/cosmic-console.exe`; it is the same engine with stdout/stderr
attached to the calling terminal.

Download-shaped editor archives (plus sibling integrity hashes) build with:

```sh
nix build .#cosmic-linux-release     # result/cosmic2d-linux.tar.gz + .sha256
nix build .#cosmic-windows-release   # result/cosmic2d-windows.zip + .sha256
```

Live runs also keep a flushed process log outside the extracted engine folder,
so diagnostics still work from a read-only install and from GUI launchers. The
platform-selected folder is `%APPDATA%\cosmic2d\engine\diagnostics\` on
Windows and `$XDG_DATA_HOME/cosmic2d/engine/diagnostics/` on Linux (falling
back to `~/.local/share/cosmic2d/engine/diagnostics/`). Contained errors add an
atomic `.ccrash` report there; it includes the traceback and exact retained-
history locator. Capped captures and verification runs do not create logs.

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

The developer packager can make the bundled demo into a play-only artifact:

```sh
nix run .#package -- demo          # -> demo-windows.zip + .sha256
nix run .#package -- demo linux    # -> demo-linux.tar.gz + .sha256
```

The bundle contains the selected editable project, engine/editor tooling,
README, licenses/notices, a complete extracted-tree `SHA256SUMS`, and the exact
carried runtime-library inventory. Its named launcher boots the game locked to
play mode; `bin/cosmic2d-editor` remains available for a deliberate authoring
entrance. Verify the archive's sibling checksum before extraction and run
`sha256sum --check SHA256SUMS` from inside the extracted folder afterward.
This is not yet the promised general export flow or final player-facing release
bundle; those remain gates A2 and A3 in `docs/ALPHA.md`.

Alpha artifacts are deliberately unsigned: checksums detect changed bytes but
do not prove publisher identity. Windows may report an unknown publisher. Do
not bypass platform warnings for an artifact whose source you do not trust;
the full verification and future-signing policy is in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

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

Development builds run on Linux and Windows desktop; the Windows binary is a
cross-build. Portable editor and play archives are clean-machine tested on a
stock x86_64 Debian 13 container and native Windows 11. macOS is not supported
for this alpha.

## License

MIT — see [LICENSE](LICENSE). Vendored third-party code keeps its own
(compatible) licenses. Packaged builds reproduce their exact notices plus the
selected platform runtime notices under `LICENSES/`; see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
