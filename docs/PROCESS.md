# pettan2d — working process (for the agent)

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
  why when non-obvious. Always end with the trailer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Never commit `bin/`, build output, or llm-feed runtime data (gitignored).

## Build / run / test

Everything runs inside the flake devshell (`nix develop -c <cmd>`):

```sh
nix develop -c make -C pal          # build → bin/pettan (+ shaders if changed)
bin/pettan projects/sandbox         # run windowed (WSLg window appears on the
                                    #   Windows side; dzn/RTX or lavapipe)
bin/pettan projects/sandbox --headless --frames 120 --shot /tmp/shot.png
nix run .#test                      # golden suite (M1+), runs on pinned lavapipe
```

- Goldens: `VK_DRIVER_FILES` is forced to the flake's lavapipe ICD by the
  test runner — never record goldens on hardware drivers (D007).
- The flake only sees **tracked** files: `git add` new files before any
  `nix develop`/`nix build` if the flake inputs changed.

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
