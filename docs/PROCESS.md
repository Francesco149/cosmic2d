# cosmic2d — working process (for the agent)

How work happens in this repo. The human is available for questions and
visual checks but sessions are expected to be autonomous and long-running
until human verification is genuinely the blocker.

## Session start (every session, in order)

1. Read `docs/STATUS.md` — current state, in-flight work, next step.
2. `git log --oneline -10` — what actually landed recently.
3. llm-feed health: `curl -sf http://localhost:8777/healthz` → prints `ok`.
   If down, start it in the background and leave it running:
   `cd /opt/src/llm-feed && nix run nixpkgs#python3 -- /opt/src/llm-feed/feed.py serve`
4. Skim PLAN/ARCHITECTURE/DECISIONS only as needed for the task at hand.

All project knowledge lives in **this repo**, never in the agent's private
auto-memory: future sessions must orient from a fresh clone + these docs.

## Session end / milestone end

- Update `docs/STATUS.md`: what works now, what's in flight, exact next step,
  any open questions for the human. STATUS is the handoff — write it so a
  fresh session (or a /clear) can resume without re-reading the whole repo.
- Update ARCHITECTURE/DECISIONS if reality diverged from them.
- Everything committed (see below). Suggest `/clear` to the human when a
  milestone is committed and STATUS is current — context beyond that point
  is dead weight.

## Commits

- Commit **in logical units as you go** — one coherent change per commit
  (docs distill, vendor import, feature, fix), not end-of-session megacommits.
- Direct to `main`, no PRs unless asked. Imperative subject, body explains
  why when non-obvious. Always end with a `Co-Authored-By` trailer naming the
  committing agent's **own model slug**. Never copy another agent's identity
  from an example or an earlier commit. Codex uses
  `Co-Authored-By: Codex <noreply@openai.com>`; Anthropic agents use their
  actual Claude model slug with `<noreply@anthropic.com>`.
- Never commit `bin/`, build output, or llm-feed runtime data (gitignored).

## Build / run / test

Everything runs inside the flake devshell (`nix develop -c <cmd>`):

```sh
nix develop -c make -C pal          # build → bin/cosmic (+ shaders if changed)
bin/cosmic projects/smoke           # run windowed (WSLg window appears on the
                                    #   Windows side; dzn/RTX or lavapipe)
bin/cosmic projects/smoke --headless --frames 120 --shot /tmp/shot.png
bin/cosmic projects/selftest --headless --frames 1       # 22k engine checks
bin/cosmic <proj> --headless --frames N --record t.ctrace  # capture a trace
bin/cosmic <proj> --verify t.ctrace  # golden runner: byte-exact replay, exit 0/1
# re-cut a committed golden after an INTENDED sim/doc change (D093/D094):
# tools/trace/replay-driver.lua replays the old trace's pad records against
# a fresh boot while recording; dump.lua and strip-eval.lua (host lua) are
# the honesty diff and the input-only publish step — headers show usage
bin/cosmic projects/smoke --headless --frames N --eval "game.demo(1)" \
  --shot /tmp/s.png     # --eval queues a console line for frame 1 (recorded
                        # as an EVAL chunk) — drives demos/knobs headlessly
nix run .#test                      # selftest + all committed goldens (lavapipe)
nix flake check                     # same suite as a sandboxed derivation
```

**Testing the Windows build (native, via WSL interop)** — the cross build
is runnable directly from WSL; the exe runs on the Windows side (real
win32 SDL3, host vulkan). The normal agent handoff builds the full development
tree, atomically stages it on the Windows filesystem, preserves `.recent.dat`,
durable project `.ed` state (sessions/journals; derived history is rebuilt), and
machine-local video/knob/map state, then creates or refreshes the per-user
**cosmic2d editor** Start Menu shortcut:

```sh
tools/build-windows.sh
cd /mnt/c/Users/headpats/cosmic2d-win
./bin/cosmic.exe projects/selftest --headless --frames 1   # 22k checks, native
./bin/cosmic.exe projects/smoke --verify tests/traces/smoke_kitcheck.ctrace
   # ^ cross-platform determinism: linux-recorded traces verify byte-exact
./bin/cosmic.exe projects/smoke --edit --win 1280x800 --frames 30 --shot ed.png
```

**Clean-machine release matrix** — build the two editor downloads and the two
demo play exports, then exercise the Linux archives in a stock Debian 13
container and the Windows archives through native PowerShell/Win32:

```sh
nix build .#cosmic-linux-release -o result-linux-release
nix build .#cosmic-windows-release -o result-windows-release
nix run .#package -- demo linux
nix run .#package -- demo windows
nix shell nixpkgs#podman -c tests/linux-portable-smoke.sh \
  result-linux-release/cosmic2d-linux.tar.gz demo-linux.tar.gz
tests/windows-portable-smoke.sh \
  result-windows-release/cosmic2d-windows.zip demo-windows.zip
```

Both checks extract under paths containing spaces and non-ASCII characters,
deny writes to the install trees, launch every public root/bin entrance from an
unrelated working directory, validate the project-derived player README/icon,
and prove live diagnostics land in the platform per-user data root. Windows
also checks project PE title/version resources and UTF-16 player-argument
delegation. The PowerShell file is directly runnable on a clean Windows
machine; its WSL wrapper only copies inputs onto NTFS and invokes it.

The human's normal live entrance is **cosmic2d editor** in the Start Menu; its
shortcut targets `C:\Users\headpats\cosmic2d-win\cosmic2d-editor.exe`. A direct
fixture run remains `bin\cosmic.exe projects\smoke --edit` from that directory.
Windows-only gotcha found this way: unix-absolute paths (`/tmp/...`) can't be
`pal.mkdir`'d there — tests use the platform temp root; engine code is immune
(project paths are engine-root-relative).

**The staging is a SNAPSHOT** (bit us 2026-07-13): the human's live Windows
runs use whatever was staged last. After building any agent-authored engine or
editor change, `tools/build-windows.sh` is mandatory before either side judges
the result natively ("the fix doesn't work" on Windows usually means a stale
stage). Publication uses a complete sibling tree and swap; a copy failure
leaves the previous stage intact. If Windows has the staged executable locked,
the helper asks for the running editor to be closed instead of publishing a
partial tree. Override the destination with `COSMIC_WINDOWS_STAGE` or the
helper's one optional argument.

**Nix builds source the GIT tree** (bit twice, 2026-07-13): `nix run
.#test`, `nix build .#cosmic-windows` and flake checks copy the git
tree — dirty TRACKED files are included, **untracked files are
invisible**. A new module that only exists untracked makes the suite
"PIXEL MISMATCH (or run failed)" and the cross-build boot-error while
the working tree runs fine. `git add` (or commit) new files before
judging any nix-built result.

- Goldens: `VK_DRIVER_FILES` is forced to the flake's lavapipe ICD by the
  test runner — never record goldens on hardware drivers (D007). State
  traces are driver-independent (sim is pure CPU); pixel goldens (M5) are
  not. New golden = trace + `.project` sidecar naming its cartridge dir.
- Pixel golden = `tests/pixels/<name>.png` + `<name>.args` (one argv token
  per line; the runner appends `--shot` and byte-compares). Record ON
  LAVAPIPE: `VK_DRIVER_FILES=$COSMIC_LVP_ICD bin/cosmic <args…> --shot
  tests/pixels/<name>.png` inside the devshell — and mind untracked local
  state (a stray machine-local file, e.g. a knobs.dat, can boot instead of
  the committed defaults; move it aside).
- Time machine (M5): F4 in any live session scrubs the always-on ring
  trace (last `cm.trace.ring.seconds`, default 30); "rewind here" truncates
  the future, "save .ctrace" exports the ring; replay a file with
  `cm.scrub.open_replay("path.ctrace")` from the console. Crash → F4 →
  scrub back and watch it coming is the intended debugging loop.
- The flake only sees **tracked** files: `git add` new files before any
  `nix develop`/`nix build`/`nix run .#test` if files were added.

## Verification loop (how the agent checks its own work)

1. **State**: golden traces + state hashes (M1+) — the primary net. Run them
   before claiming a sim-touching change works.
2. **Pixels**: headless screenshot → push to llm-feed for anything visual.
   The agent looks at the PNG itself first (Read tool renders images);
   the human is the taste check, not the smoke test.
3. **Feel/aesthetics**: human runs it (windowed on WSLg, or the Windows build
   later) — request a check via the feed + a one-line "what to look for".
4. Beyond screenshots, the in-engine trace scrubber (M5) is the intended
   deep-verification tool — invest in it, it pays back agent autonomy.

## llm-feed (visual handoff to the human)

The human keeps a browser tab on `http://localhost:8777`. Push, don't open
image viewers. Always pass `--title` and a short `--note`:

```sh
P="nix run nixpkgs#python3 -- /opt/src/llm-feed/feed.py"
$P image /tmp/shot.png --title "M0 sandbox boot" --note "headless frame 120, animated quads"
$P montage --frames-dir /tmp/frames --glob 'f_*.png' --cols 4 --title "..." --note "..."
$P list / get <id> / clear
```

The human may paste back `crop id=… box=…` region-select strings — resolve
via `feed.py get <id>` and crop from the original source.

## Asking the human

Ask (via the conversation, optionally with a feed push) when:
- an aesthetic/feel judgment gates progress (knob defaults, art direction);
- a decision contradicts PLAN/DECISIONS and rewriting them is warranted;
- something needs the Windows side or a tool install (UAC is fine).
Otherwise: decide, log it in DECISIONS.md if it's binding, and proceed.

## Touching the PAL (stability contract checklist)

Before changing anything under `pal/` (full contract in ARCHITECTURE.md):

1. Is it additive? Changing an existing primitive's semantics is allowed
   pre-1.0 only, needs a DECISIONS entry, and deliberately regenerates
   goldens. Post-1.0: new name instead, old name works forever.
2. Does it touch sim state? Then it's a versioned kernel (`name@N`) and its
   determinism class goes in the API table.
3. Bump `PAL_VERSION_API` on additions; engine code feature-detects, never
   assumes.
4. Run the entire golden suite — every trace ever recorded must still
   replay byte-exact. An old trace breaking is a bug in the change, period.
5. Update the PAL API table in ARCHITECTURE.md in the same commit.

## Determinism discipline (summary; full rules in ARCHITECTURE.md)

Sim code: no wall clock, no `math.random`, no libm trig, no hash-order
dependence, state only in named buffers/doc tree. Every new sim-touching
system documents its snapshot story in DECISIONS.md. If a golden breaks
unexpectedly, that's a bug found, not a golden to regenerate.
