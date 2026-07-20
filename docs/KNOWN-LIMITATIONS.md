# Known limitations — 0.1-alpha

Honest edges of the first release. Each has an ADR or gate reference;
none is a surprise found in the field. Out-of-scope-by-design items
(networking, mobile/touch, web export, localization tooling, visual
scripting, advanced physics) are listed in `ALPHA.md` §5 and are not
repeated here.

## Platform envelope

- Linux (incl. WSL2) and Windows only; no macOS. The Windows build is
  cross-compiled and natively smoke-tested; goldens run on pinned
  lavapipe only.
- Performance envelope: about 500 live, moving, doc-carried actors at
  60 Hz on the reference machine (D098; scripting.md "The performance
  envelope"). The recorder tax, not game logic, is the ceiling —
  named buffers are the documented opt-out for bulk state.

## Rewind / replay (gate A7 leftovers)

- Standalone replay clips do not yet embed captured audio; a clip
  replays silent audio-wise on a machine without the session (A7).
- No recording-friendly image/video/frame/audio export from a replay —
  deliberately after the replay artifact stabilizes (A7).
- Replay export names are frame-stamped, not wall-clock (needs a PAL
  date door); the export reveals the folder, not the exact file (A7,
  D104).
- A native (C-level) crash writes a minidump + diagnostics log but does
  not yet synthesize its embedded-tail replay on next launch the way a
  Lua-level crash report does (D106/D109 refinement).
- Very long PINNED sessions (rewind recorder paused with history held)
  grow memory; bounded sessions are fine (D032 revisit trigger in
  cm/trace.lua).

## Editor

- The room-transition runtime slice is deliberately unbuilt: demos cut
  instantly and no shared code exists to absorb (D096); it lands when a
  demo hand-rolls one.
- Sprite editor (D141): gradient fills use a default vertical axis (no
  handle-drag UI yet); ramps re-grab from the two active colors rather
  than a per-stop editor; layers cannot be renamed; the mix rail clips
  (does not scroll) past roughly 8 layers.
- Figure clips are lerp-only — stepped tracks and texture-swap face
  strips are deferred until a character needs them (cm/fig.lua).
- The documentation reader renders no markdown tables (guarded by a
  selftest KAT — shipped docs use preformatted blocks instead).
- The mesh editor is deliberately picoCAD-class: no skinning, no
  modifiers, no subdivision, no UV unwrap (D137's stated wall).

## Player-facing

- The player menu's discoverability hint for fresh players ("F1 =
  options" in shipped games) awaits the fresh-user pass (A8).
- Option-default publishing from the settings window moves whole lists,
  not per-row subsets (D136 revisit trigger).
