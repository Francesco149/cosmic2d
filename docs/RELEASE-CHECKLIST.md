# Release checklist — reproducible alpha cut

Every step is runnable from a clean checkout; nothing depends on a
warm machine. A release is the human executing this list top to
bottom and signing the result. Record outcomes (counts, hashes, dates)
in `STATUS.md` as you go.

For a rehearsal cut, run `tools/tag-release-candidate.sh --push` from a clean
`main` after pushing the commit. It creates the next annotated
`v<VERSION>-rc.N` tag and its tag push runs the release-candidate workflow:
the deterministic suite, both verified archives, an Actions artifact, and a
GitHub prerelease. A failed runner can be retried normally or rebuilt with the
workflow's manual `tag` input; the tag never moves. This does **not** mark the
project alpha or replace the final checklist below.

## 1. Tree state

- [ ] Worktree clean on `main`; `STATUS.md` current; no `[ ]` P0/P1
      items open in `ALPHA.md` A-gates.
- [ ] `VERSION` holds the release string (currently `0.1-alpha`);
      `docs/CHANGELOG.md` and `docs/KNOWN-LIMITATIONS.md` reflect it.

## 2. The deterministic suite

- [ ] `nix develop -c make -C pal` builds clean.
- [ ] `bin/cosmic projects/selftest --headless --frames 1` passes;
      record the count.
- [ ] `nix run .#test` — ALL GREEN: every trace byte-exact, every
      pixel golden matching on pinned lavapipe.

## 3. Native Windows

- [ ] `tools/build-windows.sh` cross-builds and stages the dev tree
      (durable Windows-side editor state preserved — verify the count
      of preserved entries it reports).
- [ ] Native selftest passes (`cosmic.exe projects/selftest --headless
      --frames 1`, expected Linux count +2); the kitcheck trace
      verifies byte-exact natively.
- [ ] A human plays one demo and opens the editor natively.

## 4. Release artifacts

- [ ] `tests/release-manifests.sh` — manifests stage clean (dev/editor/
      player splits, legal skeleton present, internals absent).
- [ ] Build the archives (the flake's linux-portable and windows
      archive outputs); `tools/release-integrity.sh archive <file>`
      passes for each; record SHA-256 sums.
- [ ] `tests/linux-portable-smoke.sh` in a clean container;
      `tests/windows-portable-smoke.*` on a clean Windows VM —
      extract-and-run, picker up, demo plays.
- [ ] In-editor export of one project on each host produces a working
      player archive (walk `getting-started.md`'s final step).

## 5. Longevity and recovery

- [ ] Long-session soak: a headless game session and a headless editor
      session, hours-equivalent frame counts; RSS bounded (record the
      numbers). Known exception: pinned-history sessions
      (`KNOWN-LIMITATIONS.md`).
- [ ] Corrupt-state spot check: truncate a `.spr` txn manifest and a
      session journal on a scratch copy; the engine recovers or
      degrades with a message, never crashes (the A1 seams).
- [ ] Open a project created by the previous release (or a copy from
      `tests/`): loads, plays, saves forward.

## 6. The cut

- [ ] Freeze: tag the rev (`v<VERSION>`), attach archives + SHA-256s.
- [ ] Flip `README.md` from "alpha candidate" to "alpha" — only here,
      at A8 exit (ALPHA.md's rule).
- [ ] `STATUS.md`: record the release block (counts, hashes, date,
      known limitations pointer) and the next program pointer.
