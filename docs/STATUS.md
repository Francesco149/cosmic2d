# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-07-12 (overnight session — R4 built end to end)
**Phase**: **REVAMP R4 — the windows: BUILT (ADR D051 + EDITOR.md §12);
awaiting the human's exit session (the one true gate).** The human
confirmed R3's resize feel at session start; design-doc-first per REVAMP
§3.1, then all five citizens, each a commit with scripted proofs:

- **D051 + EDITOR.md §12** — the R4 design. The structural idea: the
  **ghost-widget split** — `x_ig_edit` grew additive opts (`ghost/enter/
  focus/set/scroll_x/scroll_y`) + a 4th return `{sx,sy,caret,sa,sb,
  submit}` (imgui-internals read, pin-checked), and in ghost mode draws
  NO glyphs. Lua draws every visible glyph on the drawlist (which obeys
  canvas z) — so the R3 widget-z trap dissolved, and syntax color became
  possible at all. Also new: `PAL_EV_DROP` (SDL drop-file → `{type=
  "drop", path, wx, wy}`).
- **R4a code ed** (`37ad47a`): `cm.ed.lex` (pure lua/md line tokenizers +
  `link_at`, KAT'd), gutter + faces + own caret + current-line tint on
  the ghost widget; .md keeps the mono grid with heading/link/code faces
  (docs are a *code format*, the board's spec); **Ctrl+click a link →
  new code window** (module dots resolve into `../../engine/`, docs into
  `../../docs/`); per-window **back/fwd history** (◀ ▶ + mouse 4/5).
  Scroll is captured per window; restart survival re-proven. Found+fixed:
  capped/headless quits lost the sub-400 ms session tail →
  `cm.ed.quit_flush` backstop in cm.main.
- **R4b playable game** (focused = playing): `cm.ed.filter_events`
  replaces the blanket swallow — keys pass (Esc+grave stay the shell's;
  releases always pass so nothing sticks), mouse remaps through the
  letterboxed image rect to FOV px, wheel over it feeds the sim — all on
  the normal recorded input path (replayable by construction, KAT'd).
  Plain-key shell hotkeys suspend while playing; Esc unfocuses. PLAYING
  chip on the window.
- **R4c console window**: same pal.log ring, colored faces, header
  filter, Enter → the recorded EVAL path, up/down repl history; grave
  summons it on the canvas; the D050 §8 skip-ig-frame gate DELETED
  (error-notify adopts into a window). Content-wheel routing landed
  (§12.7): ALT+wheel always zooms; kind.wheel hooks take content scroll.
- **R4d asset picker + image window**: flat list (one recursive
  `pal.list_dir` — the old nested walks double-counted, fixed in the
  text picker too), type chips + pure fuzzy scorer (KAT'd), size slider,
  PNG previews (.spr shows its baked sibling), double-click opens the
  right kind, **drag-out rebinds** a window (`kind.accepts/rebind`) or
  spawns on empty canvas, **OS drop over an assets window copies into
  the project** (image→art/, sound→sound/, code→root; collisions
  suffix _2; tile flashes).
- **R4e sprite ed; the F2 studio DIED** (D046 Q4): read-only fit view +
  header **edit** toggle; pencil/eraser/bucket/eyedropper, doc palette +
  hex add, layers (select/eye/add/del), frame chips, wheel zoom at
  cursor + middle-drag pan (the shell yields the middle button via
  `kind.takes_middle`). **Working state = the CSPR bytes** in
  doc.assets → the whole D050 model free (journal cap 512 via the new
  per-open cap; one gesture = one entry; save = `sprite.save` bake +
  hot-reload epoch). Proven live: paint → save → unsaved edit → restart
  (the mouth line survived, dirty dots) → undo (gone in both windows).
  Colors stay in cm.paint packing (drawlist converts — a real channel-
  swap bug caught by looking at the shot). `cm.studio` (2171 lines) +
  `--studio` + F2 deleted; cm.paint/sprite/anim untouched.
- **Proof**: selftest 22644→**22676** (+32: lex, fuzzy/class, filter
  gate, journal per-open cap); `nix run .#test` ALL GREEN throughout
  (goldens never moved); **windows native**: selftest 22676 PASS,
  smoke_kitcheck verifies byte-exact, `--edit` capture renders the R4
  windows identically (staged at `C:\Users\headpats\cosmic2d-win`).
  5 shots on llm-feed (the R4 exit composition on the real cosmic
  project · code ed faces · sprite restart survival · picker drop-in ·
  native windows).

**Next step (resume here):** the human's **R4 exit session** (REVAMP §6):
`bin/cosmic ../cosmic2d-game/cosmic --edit` (or smoke) — play the game in
its window (click in = play, Esc = out), edit a script with Ctrl+S and
watch hot reload, toggle girl.spr's sprite ed and tweak pixels, drag a
ref image from Explorer onto an assets window. Known R4 scope notes:
sprite ed v1 is deliberately lean (no gradients/transforms/clips UI —
the .spr carries them; the anim window is future), sound files have no
window (M9 never landed), perf/scrub still hide under the canvas, the
image window is PNG-only. Then **R5 — project picker + launcher**
(REVAMP §6): teidraw-style picker front door, the thin same-name
launcher exe (editor/console disabled), shipped zip openable in the
editor. Good `/clear` point after the human's pass — R4 is committed,
docs current.

---

**Date**: 2026-07-12 (R3 session, cont. — feedback rounds 1+2 + the windows PAL)
**Phase**: **R3 feedback rounds 1+2 applied ("feels good", "windows build
is smooth" + asks); the windows build now actually TESTED natively —
selftest + cross-platform trace verify PASS on win11.**

Round 2 (human tried precise edge grabs, still failed — diagnosis: they
resize under ALT, where the old grammar turned an edge press into a move
(inside) or a marquee (just outside), exactly as reported):

- **The edge band now wins over the ALT grammar** — pressing it resizes
  whether ALT is held or not ("dragging edges resizes" rides the same
  layer as move on the board). And the band is **asymmetric, biased
  outward** (10 px outside / 4 inside): the rim just outside the border
  resizes, the interior moves — so edge-vs-move never fight. Hover now
  accents the exact grabbed edge(s), and the accent stays on while
  resizing. KATs: ALT+edge press → resize (never move/marquee), outward
  band geometry (selftest 22641→22644).
- **Game window content got its margin + filler**: the target letterboxes
  inside a rounded dark well inset from the panel (it used to sit flush
  over the rounded border); all window content is inset 4 px-at-zoom
  from the panel edges now.

- **ALT shimmer fixed properly** (human: contents shifted + dimmed under
  ALT — it was our inert-text fallback, not WSLg: x_ig_edit renders with
  imgui FramePadding(4,3) + white text, the fallback didn't match). The
  real fix is the one IMGUI.md §11 pre-blessed: **`pal.x_ig_mouse(on)`** —
  the shell gates mouse events off imgui in C while ALT is held, so
  widgets render UNCHANGED (zero shimmer) but can never take the A-click;
  the off-transition parks the pointer + releases buttons. The inert swap
  now exists only for the widget-z occlusion rule, and matches the widget
  pixel-for-pixel (+4,+3, white).
- **Edge resize was a 3-px target** (band 6 = ±3 around the border; a miss
  outward started a pan — read as "doesn't work"). `wm.EDGE_PX` 6→12.
- **The windows PAL, set up + tested for real** (recipe now in
  PROCESS.md): staged at `C:\Users\headpats\cosmic2d-win` and driven via
  WSL interop — **all 22641 selftest checks PASS on the native exe**, and
  the linux-recorded golden traces (**smoke_kitcheck 830f + churn**)
  **verify byte-exact on windows** — the first demonstration of
  ARCHITECTURE's cross-PLATFORM determinism goal. The `--edit --win`
  capture renders identically on host vulkan. One windows-only gotcha
  found + fixed: unix-absolute `/tmp` dirs can't be mkdir'd there (ed
  selftests now use the platform temp root; engine code was immune).
- Live windows run for the human: `bin\cosmic.exe projects\smoke --edit`
  from `cosmic2d-win`. Suite ALL GREEN on linux after all of it
  (selftest 22641, traces, pixels byte-identical).

**Next step (resume here):** human re-checks the two feel fixes live
(ALT steadiness + edge resize) + optionally the native windows --edit;
then **R4 — the windows** (see the R3 block below for the full brief).

---

**Date**: 2026-07-12 (R3 session)
**Phase**: **REVAMP R3 — editor shell: BUILT (ADR D050 + docs/EDITOR.md);
awaiting the human taste pass (the exit's feel half).** Design-doc-first
per REVAMP §3.1, then the whole shell end to end:

- **docs/EDITOR.md (D050)** — the STUDIO.md successor: the ALT grammar is
  *the board's* spec (teidraw has no ALT layer — its canvas IS the main
  action; ours is window content), with teidraw's tuning lifted from its
  source (1.16×/notch zoom-at-cursor clamped 0.02–64, 4 px click-vs-drag,
  320 ms/6 px double-click, 280 ms quart eases, adaptive 32-wu dot grid,
  400 ms autosave debounce, 4096-entry journals).
- **The R6-critical state model, implemented**: everything a rewound frame
  must show lives in **cm.ed.doc** (plain data, cm.state.canon-clean);
  gestures/hover/eases are ephemeral module-locals. The **`ed.` buffer
  prefix is reserved** for the editor domain — cm.state snapshots +
  cm.trace recordings exclude it (KAT-pinned; no existing name collides,
  every golden byte-identical).
- **cm.ed + cm.ed.{cam,wm,session,journal} + win.{note,text,game}**: pan/
  zoom canvas, chrome (headers are labels, never drag handles), the full
  grammar — A-click select/drill, A-drag move (selected-first priority),
  A-rightclick close (fearless: state is keyed by asset, not window),
  marquee, plain-drag edge resize (6 px band), `]`/`[` (+shift) explicit z
  (no auto-raise), Esc, shift+1/2/0 fit anims, arrow nudges. Boot:
  **`bin/cosmic <project> --edit`** (forces maximized; sim keeps running,
  game input swallowed — game-window input synthesis is R4).
- **Unsaved-persists + undo-forever, PROVEN across restart** (the exit's
  mechanical half, scripted --eval proof): working copies in
  doc.assets[path] (session.dat = CEDS canon dump, 400 ms debounce, in
  gitignored `<project>/.ed/`), dirty = working-vs-disk (computed, never
  tracked), **CJRN journals** (append-only chunk stream via the new
  `pal.x_file_append`; full-snapshot entries, dedupe vs tip, save
  re-flags, branch = truncate+rewrite, cap 4096, corrupt degrades fresh).
  Ctrl+S/Z/Y on the focused window; header **reset** button = an
  *undoable* revert. The text window = the R4 code-ed precursor, with a
  fuzzy file picker on the right-click spawn menu.
- **Widget-z rule** (found + fixed): imgui edit widgets always render
  above the background drawlist, so an overlapped window draws its text
  inert (correct-looking — it's behind). EDITOR.md §11; the interleaved
  story is R4 design.
- **ALL GREEN**: selftest 22545→**22641** (+96: cam math, wm hit/grammar
  KATs driven by synthetic input frames, session round-trip, journal
  codec/branch/cap, ed-domain exclusion); `nix run .#test` end-to-end
  (3 traces + 3 pixels byte-identical — the ed.* filter changed
  cm.state/cm.trace and nothing moved); windows cross build clean; live
  windowed verified on WSLg (imgui windowed backend, maximized). 3 shots
  on llm-feed (restart survival · 62% zoom · spawn menu + picker).

**Next step (resume here):** the human's **taste pass on the live shell**
(`bin/cosmic projects/smoke --edit` on WSLg) — the R3 exit's feel half:
does the canvas feel teidraw-smooth (zoom-at-cursor, pan, the ALT
grammar, edge resize)? Then **R4 — the windows** (REVAMP §6): code ed
(highlighting, line numbers, links/doc format), asset pick (previews,
drag-in/out), sprite ed (re-host cm.paint/sprite/anim; the F2 studio
dies here, D046), the playable game window (input synthesis), console
re-hosted as a canvas window. Known R3 scope notes: wheel always zooms
(content scroll routing is R4), game window is watch-only, drill/groups
are plumbed but inert (windows are all leaves), legacy chrome hides
behind an open console (the §8 interim gate). Good `/clear` point — R3
is committed, docs current.

---

**Date**: 2026-07-12 (R2 session)
**Phase**: **REVAMP R2 — platform layer revamp: DONE (ADR D049 +
docs/IMGUI.md).** Design-doc-first per REVAMP §3.1, then built end to end:

- **imgui in the PAL**: Dear ImGui **1.92.4 vendored** (teidraw's exact pin;
  SDL3 + SDLGPU3 backends, demo excluded) + **Inter/JetBrains Mono** (OFL,
  teidraw's fonts) in `pal/vendor/`. One C++17 TU — `pal/src/ig.cpp` —
  hosts it behind the C ABI in pal.h; the rest of the PAL stays C11. The
  C/C++ helper-layer rules are now in ARCHITECTURE Conventions (extern "C"
  boundary, no exceptions/RTTI across, $(CXX) links, mingw static libstdc++).
- **The split held to D049's shape**: Lua gets a native-res **drawlist**
  (line/rect/circle/poly/text/image/clip + an overlay layer), **text at any
  px** (dynamic font atlas; raster capped at 320px, vertices scale above —
  crisp at every zoom), **x_ig_edit** (per-id buffered imgui text editing at
  an explicit rect), and **x_ig_frame** capture flags. ImGui windows/layout/
  styling are NOT exposed. imgui renders **last, into the present pass, at
  native window resolution** — a third layer above game target + ui canvas.
- **PAL api 6→7, purely additive** (no semantic break was needed; every
  pre-v7 golden replays byte-exact, nothing regenerated): the x_ig_*
  surface, `gfx_init{maximized}` (editor-session window), raw window-px
  `wx,wy` on mouse events (cm.ui keeps `inp.wx/wy`), `x_compose{scale=0}`
  (skip the game blit — the canvas draws the target via `x_ig_image(-1)`),
  `pal.x_clipboard`. cm.view grew **mode="canvas"**; the classic ladder /
  960×540 / fullscreen-upscale model is unchanged for play + shipped games.
- **Headless visual loop works for ig**: in `--win WxH` capture mode the
  host runs without the SDL3 platform backend (io driven manually) and
  renders into the capture target — `--shot` shows the real canvas. Plain
  headless/verify get nil + no-ops (**selftest 22536→22545** pins the
  absence contract, wx/wy plumbing, and scale=0 compositing).
- **`projects/igcanvas`** (the R2 exit, living x_ig_* reference like
  uigallery): pan/zoom infinite canvas fully in Lua — floating panels, the
  code-ed widget (mono), a type specimen 8–64px, the **live game target as
  a canvas image**, arrow + HUD pills; boots **maximized**. Wheel = zoom at
  cursor, drag = pan. 3 shots on llm-feed (100% / 260% / 42%).
- **ALL GREEN**: `nix run .#test` end-to-end (selftest 22545 + 3 traces +
  3 pixel goldens byte-identical); `nix build .#cosmic-windows` clean
  (cosmic.exe, no new DLLs). Live windowed verified on WSLg (igcanvas
  inits imgui; smoke never touches it). Fullscreen = the unchanged M8
  alt+enter/ladder machinery (KATs green; live feel check = human's).
  Known quirks (documented in IMGUI.md §11): legacy dev chrome renders
  UNDER the ig layer in canvas mode until R3/R4 re-host it; SDL3-backend
  text input vs pal.text_input shouldn't share a frame.

**Next step (resume here): R3 — the editor shell** (REVAMP §6): the
infinite canvas + floating-window system in Lua — pan/zoom, window chrome,
the ALT interaction grammar (A-click/A-drag/A-rightclick, drill-down
select, bring-to-front, edge resize), unsaved-persists + undo-forever
journals. **Design doc first (EDITOR.md** — the D036/STUDIO.md successor;
per REVAMP §8 design the R3 state model with R6 rewind capture in mind:
window layout / open docs / unsaved buffers in named+snapshottable state,
unlike the D040 studio). igcanvas is the sketchpad to steal from. Good
`/clear` point — R2 is committed, docs current.

---

**Date**: 2026-07-12 (later session)
**Phase**: **REVAMP R1 — script-engine gate: DONE. Decision: STAY ON LUA 5.4
(ADR D047 + D048).** The QuickJS-vs-Lua spike ran end to end: a dual-host C
binary (`tools/r1_scriptbench/`, committed + re-runnable) embedding the
vendored Lua 5.4.7 AND bellard's QuickJS behind one native surface shaped
like our hot paths, workloads as literal Lua↔JS translations. First pass
(D047) tested the nixpkgs pin 2025-09-13; **the human caught that upstream
had shipped 2026-06-04 ("42% faster")** — retested, D048 revises the table
(decision unchanged).

- **Performance (D048, QJS 2026-06-04)** — general workloads near parity:
  sim tick 287 vs 385 µs (1.34×), quad per-call 580 vs 583 µs (parity),
  bulk buf-writes 1911 vs 2322 µs (1.2×), UI churn ~315 vs ~337 µs (~1.05×).
  QuickJS's typed-array path now **beats** Lua's best bulk path (1406 vs
  1911 µs). But **xoshiro256++ stays 6.5–8×** (103 ns vs 675 BigInt / 839
  u32-pair) — that's under cm.rand on every sim draw. Embed 276 KB vs
  981 KB stripped (3.5×); 360 KB source compiles ~10 vs ~25 ms.
- **Determinism — provable in JS, strictly riskier (unchanged by the
  uplift; re-verified on 2026-06-04)**: IEEE f64 is bit-identical across
  both VMs (sim checksums + arithmetic bit patterns match exactly); both JS
  xoshiro ports reproduce cm.rand's exact bit stream — bit-exact
  record→verify IS achievable. But: 53-bit integer ceiling, 32-bit bitwise
  ops, trunc-vs-floor div/mod sign flips (-7 % 3 = -1 vs 2), and no
  int/float subtype — which breaks `cm.state.canon`'s \3-int/\4-float
  doc-tree tags. JS iteration order is spec'd (genuinely better than Lua),
  NaN payloads survive typed arrays, GC unobservable in both.
- **Why still Lua**: the blockers were never general perf — they're the
  integer story (6.5–8× + rewrite risk at every 64-bit site), the canon
  int/float redesign, 3.5× embed, and a whole-engine rewrite for no net
  gain. D048 records honestly that the upside case is now *real* (parity +
  typed arrays + JS familiarity) — just insufficient; revisit triggers
  updated (QuickJS moved 2.4× on our workloads in nine months).
- **ADRs D047 + D048** appended (numbers, scope limits, revisit triggers);
  REVAMP §3.2 + §6 R1 + §8 QuickJS risk marked resolved. **No engine/sim/
  binary change** — the spike ran in the scratchpad; only docs + the
  harness enter the repo. Goldens/selftest untouched (nothing to re-run).

**Next step (resume here): R2 — platform layer revamp** (REVAMP.md §6):
imgui hosted in the binary + the script-side surface for the hard widgets
(crib from `../teidraw` — imgui ≥1.92 dynamic-font-atlas prior art); the new
window model (maximized editor / 960×540 game window / fullscreen upscale);
C/C++ helper layer formalized; PAL API break blessed (version bump, contract
table rewritten). Design doc/ADR before build per REVAMP §3.1 — decide the
imgui/script split carefully so imgui never becomes a second UI philosophy.
The editor rewrite (R3+) is unblocked and will be written in **Lua**. Good
`/clear` point — R1 is committed, docs current.

---

**Date**: 2026-07-12 (same session, cont.)
**Phase**: **REVAMP R0 — the split: DONE.** The human resolved REVAMP §7
(engine-first; smoke = cut-down cosmic; goldens re-cut at R0; the old studio
dies at R4) + pre-answered the rewind browse gate (interactive-but-ephemeral,
§7b) — ADR **D046**. Then the split shipped, all on main:

- **`pre-revamp` branch** (keep forever) = the full old tree, INCLUDING the
  human's previously-untracked files (sandbox map.dat, cosmic mock/untitled)
  committed there so nothing is lost.
- **`../cosmic2d-game`** (new repo, `1b677e1`): cosmic/ + GAME/STORY/maps
  docs. Boots: `bin/cosmic ../cosmic2d-game/cosmic` (project paths resolve
  against the ENGINE root — the binary chdirs there at boot). mock/untitled
  stay untracked there (gitignored). Parked until R7.
- **`../cosmic2d-demos`** (new repo, `66ff4d1`): procart/ + PROCART.md +
  sandbox/ (ARCHIVED old testbed, map.dat committed). procart's round-2
  taste pass folds into the art track later.
- **`projects/smoke`** (`61ec00f`): ONE room (50x22) + 3 planks + the M7
  moveset verbatim (player/fx/pix from cosmic, buffers renamed smoke.*).
  demo.lua = the KITCHECK re-choreographed for the room + an attack section;
  telemetry-verified every rule fires (grapple engage/cancel/block, FJ
  once-per-airtime + re-arm, up-jump lockout, hop taps, flutter + hop_cd
  arming + block, teleport rate-cap + A<->B flips). Fixed a latent nil in
  player.lua's procedural fallback sprite (NF used before assignment —
  never ran while girl.png existed; smoke is its first real user).
- **Goldens re-cut** (`29f31c3`): smoke_kitcheck.ctrace (830f, verify PASS,
  re-record byte-identical) + smoke_idle/smoke_kit pixel goldens (pinned
  lavapipe); uigallery golden still byte-identical. **Found + fixed dead
  fixtures**: churn/evalfix still used the pre-rename `pt.*` global — dead
  since the cm rename, hidden because the flake's `*.ctrace` glob matched
  nothing while traces were `*.ptrace` (so `nix run .#test` had silently
  stopped after selftest). Ported to cm.*, re-recorded; the D033 ptrace→
  ctrace rename is hereby confirmed + done. **`nix run .#test` is
  end-to-end ALL GREEN** (selftest 22536 + 3 traces + 3 pixels) — the
  trace+pixel stages actually run again. 3 shots on llm-feed.

**Next step (resume here): R1 — the script-engine spike** (REVAMP.md §6):
QuickJS vs Lua 5.4 bench (sim tick / quad-batch prep / UI churn) +
determinism audit (bit-exact record→verify, integer semantics, iteration
order) + embedding/hot-reload story → an ADR with numbers, migrate-or-stay.
R2 (imgui + window model) prep can interleave. Good `/clear` point — R0 is
committed everywhere and all three repos are green.

---

**Date**: 2026-07-12
**Phase**: **THE REVAMP — kickoff (D045, docs/REVAMP.md). Plan written,
awaiting the human's review; R0 (repo split) is the first build step.**

The human arrived with a well-defined UX vision as a teidraw board
(`cosmic2d` board; the diagram convention is now a CLAUDE.md section —
boards live in `/mnt/f/Documents/teidraw/`, export via
`/opt/src/teidraw/build/teidraw <boardDir> --export-txt/--export`). This
session: learned the teidraw CLI, exported + read the board, and wrote the
plan — **docs/REVAMP.md** (target UX · architecture deltas · repo split ·
R0–R7 roadmap with exit criteria · open questions §7) + **ADR D045** +
PLAN.md banner + CLAUDE.md pointers. Docs only, no code change.

The gist: editor → teidraw-style infinite canvas with floating windows
(code ed / asset pick / sprite ed / live game), imgui pulled in for complex
widgets, QuickJS-vs-Lua decision gate BEFORE the editor rewrite, three-repo
split (engine / `../cosmic2d-demos` / `../cosmic2d-game`), disk-streamed
~1 GB rewind incl. editor state, game prototype reboots as a graybox
keeping the M7 movement feel. procart pauses as-is (its round-2 taste pass
folds into the graybox/art track later); the pure art modules survive.

**Next step (resume here):** the human reviews REVAMP.md — especially the
**open questions in §7** (sequencing of the game graybox, where the sandbox
lands, golden re-cut timing, old-studio retirement). Then **R0 — the
split**: `pre-revamp` backup branch → create `../cosmic2d-demos` +
`../cosmic2d-game` → engine-only repo with a minimal smoke project,
selftest green in all three. R1 (QuickJS spike) can prep in parallel.

---

**Date**: 2026-07-03 (second session)
**Phase**: **procart round 2 SHIPPED (both tracks of the promoted brief) —
awaiting the human's taste pass.** Commits `797f58c` (terrain styles) +
`ef74527` (chargen2) + this docs pass; PROCART.md §6 is the full round-2
record. No engine/sim/binary change; 60f record→verify PASS both tracks.

### What shipped this session
- **Terrain STYLE system** (`tilegen.style(preset, grade, over)`): presets
  soft (=round 1, default) / **canyon** (the mock — strata-slab rock:
  wobbled shelf lines, running-bond slab courses, near-black crevices,
  warm crest) / painterly / flat, × grades **day/dusk/dread** (palette-
  anchor color grading + sky stops). Gallery **page 8 CANYON** = the
  rim-hub-shaped scene with LIVE knobs (S style · G grade · F facet ·
  D dither — all sim state), **page 9 STYLES** = all presets side by side.
- **chargen2** (48x64, anime-ish per the refs): big gradient-iris eyes w/
  catchlight (sharp deletes it = Vesper's deadpan), domed 2-tone hair caps,
  chunky fringes, rounded head + jaw taper, body types. **The cast is baked
  as knob bundles** (`chargen2.CAST.{vesper,gemma,lumi}`) + identity stamps
  (fin crest / curved horns + hard-light wings / bunny ears + huge S-curve
  twintails) + outfit builders (armor / bodysuit / idol). Pages 1–3
  (cast/moods/trio) now render chargen2; old chargen kept for crowds.
- 7 shots on llm-feed (canyon dusk/day/dread, styles grid, trio, cast,
  moods). Pin-stability proven over 50 seeds.
- **Feedback round 1 applied** (`6c223d1`, human: "shorter legs, very round
  heads"): the head + hair cap are now one paint.ellipse (cap = the same
  ellipse clipped above the fringe line), feet rose to 56+stature and hems
  dropped (visible leg ~4-7 rows). Human is now playing with the gallery to
  probe style variety — expect direct knob/style feedback next.

**Next step (resume here):** the human's **taste pass on llm-feed** →
round 3 by verdict. Known weak points to attack if promoted again
(PROCART.md §6): outfit interiors below the collar (folds/trim), Gemma's
wings read as stripes behind the hair sheet, more body-type variety; plus
the round-1 backlog (mob bob anims, K-Centroid studio import, the
"generate → hand-finish" studio bridge, NPC crowds). If the terrain styles
pass, the natural next move is **baking married canyon strips for the
cosmic greybox maps** (rim = rock/dirt/grass at canyon/dusk) behind the
M10 pipeline. Note: WSLg's wayland socket was down this session — headless
runs needed `SDL_VIDEO_DRIVER=offscreen` (shots render fine through it).

---

**Date**: 2026-07-03
**Phase**: **procart — the procedural pixel-art experiment (D044, docs/PROCART.md).**
The human's brief: a separate experimental project probing whether
mostly-procedural art can nail a cute aesthetic *with personality* — multiple
characters from procedural knobs (a sprinkle of baked choices is fine, with
enough variety for a full cast), plus procedural terrain primitives that tile
cleanly and **marry** two tiles at a border with no visible seam; deep research
on procgen pixel-art prior art, local AI models for the available GPUs, and
LLM art-direction tooling. Explicitly allowed to fail / be abandoned for
manual art. This also expands and closes M10's open "procedural sprite
generator" next-step. **No engine/sim/binary change** (all new code is the
`projects/procart/` cartridge + docs).

### procart — what shipped (3 commits, all on main)
- **`projects/procart/`** — a 7-page gallery cartridge (`bin/cosmic
  projects/procart`; ←/→ or 1..7 pages, R rerolls; sim state = {page, seed}
  only; 60f record→verify PASS proves generation is render-only):
  CAST (12 seeds) · MOODS (one seed, 7 mood knobs — the personality proof) ·
  TRIO (Vesper/Gemma/Lumi via pinned knobs — the production-workflow proof) ·
  MOBS (STORY.md's roster via Bollinger half-masks + the cute stamp) ·
  TILES (wrap tile + 3x3 self-tile proof) · MARRY (hard vs married seam) ·
  TERRAIN (a composed married material map under a dithered dusk sky).
- **Core modules** (each a pure fn of (seed, knobs), dev/render class D040):
  `prng` (splitmix64 + coord hashes — deliberately NOT cm.rand; art gen never
  moves the sim stream), `pnoise` (value/fbm/worley; world-space = seam-free
  by construction, periodic = self-tiling), `palgen` (hue-shifted ramps =
  the sheet-wide coherence), `chargen` (baked archetype menus × procedural
  proportions/palettes + the MOOD dial; sel-out outlines; pin() keeps knob
  overrides from reshuffling the seed's other choices), `mobgen` (mask
  templates + body-aware eyes/blush/glow), `tilegen` (6 materials as
  world-space pixel fns; the marry bake = per-material indicator fields +
  noise wobble + Bayer tie-band dither; air is a material → organic ground
  silhouettes + surface rim light + grass tufts).
- **Deep research done** (105-agent verified run; distilled in PROCART.md §5):
  Bollinger masks (applied → mobgen), the personality-needs-parameterization
  caveat (validates chargen's design), herringbone Wang tiles (noted, not
  needed — world-space hashing never repeats), GAN sprites = verified negative,
  AI = diffusion + mandatory snapping (Pixel Art XL LoRA + ComfyUI-PixelArt-
  Detector free on either GPU; **K-Centroid is ~3.6 kB of pure Lua — a direct
  studio-import-tool port candidate**; Retro Diffusion strongest local option,
  RTX 5060 comfortable / RX 7800 XT caveated); LLM art-direction tooling:
  **no verified prior art exists** — our llm-feed + studio + knob-gallery loop
  is the state of the art. Recommendation: park AI, keep procgen.
- All 7 pages pushed to llm-feed with notes. `.claude/` gitignored; the
  human's mock/untitled studio files left untracked as asked.

**Taste pass verdict (human, 2026-07-03): "promising enough to warrant more
exploration" — PROMOTED to round 2.** The next-session brief, verbatim intent:

1. **Terrain styles**: explore *different styles* for the terrain — try
   several looks for generating the **Grand Canyon hub map** (rim-hub; use
   `docs/maps/rim-hub.md` + the human's mock `projects/cosmic/art/mock.png`
   as the anchor), and ideally a **demo with tunable style/mood knobs**
   (style presets + mood dials on the material palettes/shapes — palgen hue/
   sat/value anchors, facet scale, dither amount, LUT-ish dusk/day/dread
   grading are the natural knobs).
2. **Characters need more tweaking**: try **double resolution** (24x32 →
   48x64), **more anime-ish** in the style of the references
   (`F:\Pictures\pixel-art-ref`, the oc sheets); potentially **bake in
   hairstyles, faces, and body types based on our actual cast**
   (Vesper/Gemma/Lumi first, more once the cast aesthetic is locked) —
   i.e. shift the baked:procedural ratio toward baked for the identity
   carriers while keeping procedural variety for crowds.

Deferred/backlog from round 1 (PROCART.md §4): mob bob anims, K-Centroid
studio import, the studio "generate → hand-finish" bridge, NPC crowds.
M-content (dialogue runner, combat M12) resumes after the art exploration.

---

**Date**: 2026-06-29
**Phase**: **M-content — opening-arc writing pass (story + first maps).** M10 (the
studio) is feature-complete; with asset authoring unblocked, this session opened
**M-content**: the narrative layer + the first quests/maps the human asked for.
**Docs only — no engine/sim/binary/selftest change.** (M10 history + its
next-steps are preserved below.)

### M-content — first quests + first maps (this session) — D042
The human's brief: write the first few quests + design the first few maps; fold in
**gemma-san** (a rival cosmic architect → chuunibyou succubus cosplayer) and a
**bunny-girl idol**; mobs are **cosmic creatures**. References consulted: the mock
board `F:\Pictures\cosmic2d-mocks` (world look — *explicitly NOT* the target art
style per the human, just inspiration; notably the mocks set cosmic2d in the
**same Grand Canyon** as the 3D game and label gemma **"RIVAL ARCHITECT"** with a
ready mob roster), the character sheets `F:\Pictures\oc\{gemma-san,bunny-girl}`,
and the 3D universe bible `F:\Documents\cosmic\docs`.

Four directional calls (human, via the question prompt → **ADR D042**):
- **Protagonist = Vesper as a _tsundere villain-origin_** (3D canon NOT locked —
  cosmic2d shapes her; the 3D game leans cozy too).
- **Setting = the shared Grand Canyon** (reuse 3D locations; the Rim is the hub).
- **Gemma = recurring comedic antagonist** (Team-Rocket clown; chuuni succubus
  *cosplay* — she's an architect, the horns/wings/tail are hard-light).
- **Lumi (idol) = hub idol + an early side-quest**; mobs = reality-leak creatures
  (slicing one *files it back* — the proto-Sweep gesture, the dread).

Wrote (docs only):
- **`docs/STORY.md`** — story/cast bible: premise, the **dread engine** (cozy ↔
  cosmic dread via dramatic irony — her stabilization is a rehearsal of the
  Sweep), full cast (Vesper / Gemma / **Lumi** + the shop + the Works), the **mob
  roster** (Star Mote · Fold Slime · Pebble Drone · Cactus Satellite · Glyph
  Beetle · Thread Imp · Mirror Wisp · Tiny Floodfish), world/areas, the opening
  **quest spine** (Q1–Q4), and a names/open-questions list.
- **`docs/maps/`** — the map-page format (README) + three one-pagers: **rim-hub.md**
  ("First Survey" — Q1 hub+tutorial, meet Lumi, light the trail portal),
  **south-trail.md** ("The Long Light" — Q2 the idol's stolen gem + Q3 Gemma's
  debut duel), **whisper-gulch.md** ("The Whisper Below" — Q4 grapple/teleport gym
  + the first cosmic-dread beat + the Works' first work-order).
- Cross-linked from **GAME.md** (intro + §9) and **CLAUDE.md** (doc index); ADR
  **D042** logged in DECISIONS.md.

### M-content — greybox + scene scripts (this session, cont.)
- **Tone calibrated** (human): **mostly cozy, doesn't take itself too seriously;
  dread used sparingly** — a few earned moments + quiet hints for the acute fans.
  STORY §2 updated with the calibration.
- **Greyboxed the first 2 maps** in a NEW cartridge **`projects/cosmic/`** (copied
  from the sandbox so the proven M7 moveset works as-is; the sandbox + its
  determinism goldens/selftest stay **untouched** — a new project is in no golden
  suite). A multi-map **host** (`level.lua`: registry + portal travel
  `game.travel`/`level.go`), two annotated map modules (`maps/rim_hub.lua`,
  `maps/south_trail.lua`) = blockout geometry + **MARKERS** carrying the plan
  (spawn · portals · Lumi stage · shop · sandbox nook · rooftop/grapple/tp gym ·
  horde arena · hidden tp-vault · Gemma's overlook…), a render-only **plan
  overlay** (labeled boxes, `M` toggles), **portals** (stand in one, press Up; `N`
  cycles maps for dev), and a `player.warp`. Run: `bin/cosmic projects/cosmic`.
  Two annotated montages on llm-feed (Rim Hub · South Trail).
- **Scene scripts written** (the screenplay layer — staging, cast, full dialogue,
  comedic timing, tied to the greybox markers): **`docs/maps/rim-hub.scenes.md`**
  (Q1: the drop · reception/Star-Mote tutorial · meet Lumi · the coffee gag ·
  light the trail + the dusk restage) and **`docs/maps/south-trail.scenes.md`**
  (Q2 the gem · the Sunshelf horde + the *one* dread hint · the hidden vault ·
  **Gemma's full comedic debut** + duel + the fond defeat · Lumi payoff).

**Next step (resume here):** the human **mocks the art** — the cast (Vesper
tsundere tweak, Gemma, Lumi) + a Rim/Trail look — and refines sprites in the
**studio** (M10, F2), walking the greybox (`bin/cosmic projects/cosmic`) to feel
the spaces and drag-cropping the llm-feed montages for layout notes. **Then we
code the logic:** a dialogue runner + triggers, portal/quest state, combat (M12)
for the hordes + Gemma, the sandbox (M-physics). **Deferred (human's call):**
richer **map rendering** — baked zoomed/dimmed parallax layers + a non-grid
decor/props layer — comes *after* the art mockup; the map modules leave
`parallax`/`decor` slots open for it (the human may mock whole scenes as studio
layers first). Good `/clear` point (committed, STATUS current).

---

**Date**: 2026-06-28
**Phase**: **M10 — the studio (in-engine sprite/animation editor): Phases 1–4 ALL
COMPLETE (paint · layers/shapes/selection/transforms · gradients · animation +
the M10 exit proof). Phase 5 IN PROGRESS — 5a pivots + 5b named slices + 5c asset
hot-reload DONE (studio tools + a `.meta` sidecar + the game anchors the pivot,
D041; and a studio save now live-reloads the in-game sprite — the paint→see-it
loop is closed), `record→verify` byte-exact; next is the procedural sprite
generator / headless `--bake` / per-frame pivot+slice keys.**
New direction this session (human spec): build a solid in-editor asset editor —
the keystone that unblocks all content authoring, so **pulled ahead of M9
(audio)**. M8 (viewport) is feature-complete and M7 (movement) is feel-approved;
both stand below as history.

### M10 the studio — where we are
- **Design is captured** (the careful-design deliverable the human asked for):
  **`docs/STUDIO.md`** is the full design bible (determinism class, document
  model, `.spr` format, the full-window studio UX + tool roster, the gradient
  system, the animation model, the asset browser, the bake pipeline, the phased
  plan, and an explicit "usability traps" section). **ADR D040** is the binding
  decision; **PLAN M10** + **GAME §10** point at STUDIO.md.
- **The three structural forks (human's calls 2026-06-28)**: a **dedicated
  full-window studio mode** (`F2`); a **native layered `.spr` doc that bakes to
  the strip atlas** the game already draws (truecolor + palette, not indexed);
  **solid paint foundation first** (Phase 1).
- **The keystone insight (D040 §1)**: a sprite's pixels are a **render-only
  asset** (boot-loaded like a PNG / `map.dat`), NOT sim state — so the studio
  carries **no determinism tax**: no EVAL plumbing, no trace recording, never in
  `--verify`/golden runs. Totally unlike `cm.editor` (the world editor, where
  the tilemap IS sim state). This is what makes it a free, good creative tool.
- **Module plan**: `cm.paint` (pure no-AA rasterizers, selftest-covered),
  `cm.sprite` (doc model + `.spr` save/load + bake), `cm.studio` (mode + UI on
  the ui canvas, sim paused, `F2`), `cm.anim` (pure clip evaluator). Assets in
  `<project>/art/`.

### M10 build progress (this session)
- **1a DONE** `f2b72c1` — `cm.paint`: the pure no-AA rasterizers (get/set/over,
  line/rect/ellipse, exact flood fill, blit/stamp, flip, rotate90). selftest
  +23.
- **1b DONE** `b3b8f72` — `cm.sprite`: document model (layers×frames, palette,
  pivot), the `.spr` container (CSPR over cm.chunk), composite + bake to the
  strip PNG, `buf_delta1` undo/redo. selftest +19.
- **1c DONE** `0a1c219` — `cm.studio`: the F2 full-window studio (shell + canvas
  + core tools), wired into cm.main (pause gate + frame() on the ui canvas).
  Canvas: checkerboard, composite→one texture, cursor-anchored zoom, middle-drag
  pan, grid, hover. Tools: pencil/eraser/bucket/eyedropper, primary/secondary
  (LMB/RMB), Alt=pick, X=swap, Ctrl+Z/Y undo, Ctrl+S save. Palette panel.
- **1d DONE** `e305c29` — HSV+hex **color picker** (SV square + hue strip + hex
  field, set_prim sync), **palette save-slots** (6 project-level presets in
  art/palettes.dat, L=load/R=save, + "+ add color"), and the **asset browser**
  (menubar "browse": modal thumbnail grid of `<project>/art/*.spr`, click-to-
  open, new/refresh/close). Plus `cm.ui.text_input` now takes `opts.rect`.
- **selftest 22351→22397** (+46, cm.paint + cm.sprite KATs); all green.
- **Layout human-approved** ("looks reasonable so far, let's continue"); 3
  screenshots on llm-feed (MVP shell, dock+picker, browser).

### M10 Phase 2 — layers / shapes / selection / transforms (this session)
- **2a DONE** `e8bb594` — **layers**: cm.sprite structural ops (add now undoable,
  dup with pixels, delete keeps ≥1, reorder), each one undo step via a coarse
  **snapshot** (the layer stack + frames + cursors, cells cloned); undo/redo
  unified into one polymorphic `step_apply` (cell-delta vs struct); undo stack
  **capped at 64**. Studio LAYERS dock (add/dup/del/up/dn, opacity slider, eye+
  lock toggles, top-down rows, click-select); the dock now **scrolls as a whole**
  for short windows.
- **2b DONE** `05a71fd` — **shapes**: line/rect/ellipse (no-AA) with a **live
  preview** (a transparent scratch cell composited as one overlay quad — no real
  pixels until release), commit = one undo step. **Shift** constrains (line 45°,
  rect square, ellipse circle); a **fill/outline** mode (rail glyph or `F`); RMB
  = secondary; status shows live WxH. Keys L/R/O.
- **2c DONE** `dc89f4a` — **selection + clipboard**: marquee (`M`, marching
  ants), **floating selection** — Move (`V`) lifts a selection into a float
  (cuts a hole) and drags it; it stamps (alpha-masked) on Enter / tool-switch /
  new marquee. `^C/^X/^V` copy/cut/paste, Del drops/clears, `^D` deselects.
  cm.paint.copy_region added.
- **2d DONE** `28ed326` — **transforms + brush**: flip H/V, rotate 90° CW/CCW,
  scale — on the float (lifting a selection first) else the whole cell (rotate
  gated to square sprites; whole-sprite resize deferred). **Custom brush** from a
  selection (sprite-as-brush): the pencil stamps it alpha-masked along the
  stroke. cm.paint.scale (nearest) added. Menubar cluster fH/fV/rL/rR/x2//2;
  rail brs/1px; keys H/J flip, `[`/`]` rotate.
- **selftest 22397→22413** (+16: structural ops/snapshot-undo/cap, copy_region,
  scale). All green. Each sub-phase has a montage on llm-feed.

### M10 Phase 3 — gradients (the signature feature, STUDIO.md §6) — this session
- **3a DONE** `f984948` — **`cm.paint` gradient math** (pure, dev-class, no-AA):
  `lerp_rgba`/`ramp` (multi-stop, clamped), `bayer` (2/4/8 recursive ordered-
  dither matrices), `grad_t` (linear/mirror projection · radial dist/|axis| ·
  angular turn-wrapped), `dither_t` (quantize to `levels` bands, ordered-dither
  each boundary — strength 0 = hard bands, 1 = smoothest; snaps to a real ramp
  band so every output pixel is an exact ramp color, never an AA blend),
  `grad_shade`/`grad_fill` (masked by a source alpha → recolor visible pixels,
  keep coverage). selftest +21 KATs.
- **3b DONE** `c09e64d` — **`cm.sprite` non-destructive fills**: a fill is bound
  to a **layer** (`layer.fill`), not a doc-global index array — rides reorder/
  dup/delete for free. composite/bake apply it via a per-doc shade scratch masked
  by the frame's alpha (live pixels untouched; bake flattens, `.spr` keeps live).
  `begin/commit/cancel_struct` (a frame-spanning struct-undo bracket), `set_/
  clear_/stamp_fill` (each one undo step; stamp bakes destructively). `FILL`
  chunk in CSPR (layer→def binding, floats for handles). clone_layer deep-copies
  the fill. selftest +8 (composite-masked, round-trip, stamp/undo, dup, clear).
- **3c DONE** `1e2224d` — **`cm.studio` gradient tool + handles + panel**: the
  **D** tool drags an axis onto the active layer (live composite = the real
  preview; re-drag keeps the ramp; new fill = prim→sec, inherits last params).
  **On-canvas handles** (dotted axis + draggable p0/p1, radial rim circle), the
  whole drag one undo step (no-op clicks push nothing). **GRADIENT dock panel**:
  type selector, a **multi-stop ramp editor** (click bar = add stop; markers
  select/drag/RMB-delete; set-col/del), dither/levels/phase sliders, bayer 2/4/8,
  **bake**/**clear**. `demo_gradient()` smoke aid.
- **selftest 22413→22442** (+29). All green; sandbox boots clean; no engine/
  binary change. Montage (radial/linear/angular) on llm-feed.

### M10 Phase 4 — animation (timeline + clips + cm.anim + the exit proof) — this session
- **4a DONE** `c499136` — **`cm.anim`**: the pure clip evaluator + the `.anim`
  codec. `frame_at(clip, elapsed) → frame_index` (integer-only — safe from sim OR
  render): **loop** wraps, **once** holds the final frame, **pingpong** bounces
  A,B,C,B (interior reversed; ≤2 frames → plain loop). `duration`, `find`, and
  `encode/decode/load/save` — the `.anim` sidecar is the clip array as canonical
  doc bytes (`cm.state.canon`, like knobs.dat); `normalize()` keeps the bytes
  stable. The engine **mechanism**; the cartridge owns **policy** (D030/D035), no
  sim state of its own. selftest +15.
- **4b DONE** `9d09525` — **`cm.sprite` frames + clips**: `add/dup/delete/
  move_frame`, each one undo step (`capture_struct` now also clones `doc.clips`,
  so a frame op that rewrites clip refs rides struct-undo). The clip frame index
  is **0-based** (the strip column the game draws); clip-ref fixups keep them
  consistent across insert/delete/move. `add_clip`/`delete_clip`; the **`CLIP`
  chunk** in CSPR (round-trips); `save()` now also bakes `<name>.anim` beside the
  `.png`. selftest +13.
- **4c DONE** `f5508f9` — **studio timeline + CLIPS panel**: the frame thumbnail
  strip (select/add/dup/del/reorder, wheel-scroll), **onion skin** (prev=warm/
  next=cool under the current at low alpha), an **fps** slider + **▶play/■stop**
  live preview (samples `cm.anim.frame_at` at the WALL CLOCK — `pal.time_ns`
  scaled to 60 ticks/s — dev-only, never sim; editing disabled mid-play), and a
  **CLIPS dock panel** (list/new/del/select, rename, loop mode, the frame
  SEQUENCE as chips with add-current/RMB-remove, per-entry dur). `TIME_H 24→46`;
  `demo_anim()` smoke aid. (studio is dev/render-only — not selftested.)
- **4d DONE** `5933d17` — **the M10 exit proof**: the sandbox player now draws a
  **studio-authored sprite**. `projects/sandbox/art/girl.{spr,png,anim}` — the
  editable 12-frame doc + the baked strip + the clip table; `genart.lua` is the
  one-shot bootstrap (`--eval "cm.require('genart').girl()"`). `player.lua`
  `load_sprite()` loads `girl.png` via `cm.gfx.texture` + `girl.anim` via
  `cm.anim` at boot (file bytes ≠ sim input, D026; `build_sprite` stays the
  fallback); NF derived from the strip width. Moveset poses 0..10 stay
  **state-driven**; the idle pose now plays the **timed breath clip** via
  `cm.anim.frame_at(idle, state.frame())` — cosmetic, zero stored state, pure +
  render-only.
- **selftest 22442→22470** (+28). **Determinism proven**: a KITCHECK trace
  recorded BEFORE 4d **verifies PASS** against the new player (sim byte-
  identical); a fresh re-record is byte-identical to itself; TOUR 400f + KITCHECK
  200f record→verify PASS. The trace FILE grows only by its embedded module
  source — exactly why the pre-change trace still verifies (the §1 payoff: a
  render-only asset cannot perturb the trace). Montage on llm-feed.

**Phases 1–4 are COMPLETE; the M10 exit proof is hit** — the studio authors
multi-layer sprites with shapes/selection/transforms/gradients AND animation
(frames + clips + onion + live preview), the bake pipeline produces the strip +
`.anim` the game loads, and the sandbox player draws a studio-authored,
clip-animated sprite with `record→verify` byte-exact. The remaining M10 exit
*criterion* (PLAN: the human authors a real character sprite + a portrait) is the
human's taste/usage pass on the now-complete tool, not an engine task.

**Next step (resume here): Phase 5 — continue** (STUDIO.md §10; **5a pivots + 5b
slices + 5c asset hot-reload are DONE this session**, see the Phase 5 sections
above — the editor loop is now closed). Remaining, none blocking — pick by what
content authoring needs next:
**headless `--bake`** (regenerate `art/*.png`+`.anim`+`.meta` from `.spr` without
the studio, so the baked outputs need not be committed — pairs naturally with the
hot-reload that just landed: an external `--bake` while the game runs would then
also want the file-watcher reload path noted in 5c),
**per-frame pivot/slice keys** (the deferred half of 5a/5b — extend `.meta` + the
HEAD/SLCE schema, readers stay back-compatible), an optional indexed/palette-swap
mode, the **procedural sprite generator** (noise/shape/gradient/bevel/blend —
M10's other half, feeding particles/liquids/dust), and the **LUT post pass** +
palette/LUT editor. Good `/clear` point.

Known small items: the **baked `art/girl.png`+`.anim`+`.meta` are committed** (the
game loads them at boot) — they become regenerable build product once Phase 5's
headless `--bake` lands; `genart.lua` re-bakes meanwhile. **Slices are authored +
baked + queryable (`find_slice`) but not yet consumed by the game** (the slice
VFX / weapon-attach that would read them is the deferred M7/particle work);
**pivot/slices are per-doc** (per-frame keys deferred). The studio **play
preview uses a wall clock** (`pal.time_ns`, dev-only) — faithful to how the game
runs a clip but not frame-stepped; **onion shows only the immediate neighbors**
(±1); **clip editing isn't separately undoable** (only frame ops are — clips
carry no pixels). **Gradient** fills aren't clipped by the selection (they're
masked by layer alpha instead — a possible future nicety); a gradient fill only
recolors a layer's existing pixels (by design); **one fill per layer**; whole-doc
**resize is now done** (menubar size / `cm.sprite.set_size`, see round 2 below) —
only **rotate of a non-square doc** stays deferred; the dock can need its
scroll on short windows. None blocking.

### Studio feedback round 1 (2026-06-28) — `35b150a`
Two asks from the human's first real use ("feels great so far"):
- **Selection now restricts editing** to the marquee — a write-clip in `cm.paint`
  (`set_clip`/`clip_off`, honored by set/over/flood) that the studio sets around
  pencil/eraser/bucket/shape edits + the live shape preview; composite/bake are
  never clipped (a defensive `clip_off` guards `rebuild_tex`). The marquee stays
  visible across tool switches as the active mask. selftest +5.
- **Paste lands on its own new layer** (never overwrites what's beneath):
  `paste()` floats with a `new_layer` flag; `commit_float()` creates the layer +
  stamps as ONE undo step (a struct bracket around the new `sprite.raw_add_layer`).
  A **merge-down** button (LAYERS panel, now 2 rows of 3) flattens a layer onto
  the one below — `sprite.merge_down` (opacity + gradient fill honored, one undo
  step). selftest +3. Verified by `--win` captures (clipped fill, paste→2 layers,
  merge→1).

### Studio feedback round 2 (2026-06-29) — image-size / canvas resize
The human's ask: "set the image size to anything, so I can work on a big sprite
sheet or a mock" — the studio had no way to change a doc's dimensions (the
whole-sprite resize deferred since Phase 2d). Now done, end to end:
- **`cm.sprite.set_size(doc, w, h, {mode, anchor})`** — rebuilds every cell of
  every layer/frame in one undo step. **canvas** mode (default) keeps pixels at
  native resolution, anchored by a 3×3 grid (`nw`…`se`) — grow with transparent
  margin or crop the overflow (for a bigger sheet / a mock); **scale** mode
  nearest-neighbour resamples the content to fill. Remaps the pivot, slices, and
  gradient-fill handles into the new space. **Key fix**: the struct-undo snapshot
  now carries `w/h` (capture/restore_struct), so undo restores the old dimensions
  alongside the old-sized cells — previously snapshots assumed a fixed size.
- **Studio UI**: a menubar **size** button opens an **IMAGE SIZE** modal (W/H
  digit fields, a canvas-vs-scale toggle, the 3×3 anchor picker, and a live
  preview of where the existing pixels land in the new canvas). Enter applies;
  apply commits a pending float first so no pixels are lost. Modal follows the
  asset-browser takeover pattern (`M.resize`, gated in `M.frame`).
- selftest **22506→22524** (+18 KATs: canvas grow/crop, anchors, scale-resample,
  pivot/slice remap, undo restores size+pixels, no-op returns false). All green;
  pure render-only studio code (D040 §1 — no determinism tax). Five `--win`
  captures on… (push to llm-feed). No engine/binary/sim change.

### Studio feedback round 3 (2026-06-29) — crash fix · large-image perf · curve
Three asks from the human's use of the now-resizable studio:
- **Crash fixed** — `studio.lua` `build_preview` called `sel_clip()` which was a
  `local function` defined *below* it, so the call hit a nil global and crashed
  any shape-tool drag. Moved `sel_clip` above its first use. (A latent bug, not
  from the resize work; surfaced now that bigger canvases get more shape use.)
- **Large-image performance — the big one (PAL api 5→6).** The studio composited
  / cleared / re-uploaded with per-pixel Lua loops; at half-1080p a single
  recomposite was **~800 ms** (≈1 fps per stroke — unusable). Added three
  **portable, reusable** C primitives (ARCHITECTURE api v6 table) and routed the
  bulk pixel work through them:
  - **`pal.blit32`** — the engine's one clipped RGBA8 2D compositor (copy / src-
    over / stamp + per-layer opacity). Its over-blend is the **exact integer
    math** of `cm.paint.over`, so composite/bake stay **byte-identical** (proven:
    a re-bake of `girl.spr` is `cmp`-identical to the committed `girl.png`).
  - **`buf:fill32`** — a 32-bit `:fill` (C u32 memset) for clears/solid fills.
  - **`pal.tex_update`** — re-upload into an existing same-size texture in place
    (no GPU realloc, no Lua-string copy); the canvas/thumbs/float pool ids via
    `cm.studio.tex_upload`. (This is the upgrade STUDIO §8 had predicted.)
  Wired into `composite_into`, `merge_down`, `paint.fill`, `paint.blit` (clip-off
  fast path; the clipped brush path stays Lua), and the studio upload sites.
  **Measured: 960×540×4 layers 813 ms → 9.5 ms (~86×); 1920×1080 3245 → 37 ms.**
- **Curve tool (C) — MS-Paint style.** `cm.paint.curve` (cubic Bézier as
  connected no-AA segments, sample count ∝ control-polygon length). Studio tool
  `M.curve` state machine: drag the two endpoints (straight-line preview), then
  drag twice to pull each control point (a cubic), the second release commits;
  switching tools abandons it. Reuses the shape preview overlay; status shows the
  phase.
- selftest **22524→22536** (+12: `fill32`, `blit32` copy/stamp/over-parity/
  opacity/edge-clip, `tex_update` ×3, `curve` ×3). All green. **Determinism
  intact** (render-only): sandbox 300f record→verify byte-exact; uigallery pixel
  golden byte-identical; **both linux + windows build clean** (portable C). The
  two sandbox pixel goldens mismatch as before (pre-existing M5-era staleness).
  Curve preview + large-doc composite captures on llm-feed.

### Studio feedback round 3 follow-ups (2026-06-29)
A few quick asks after using the above:
- **Rename the sprite** — the doc was always saved as `untitled.spr` with no way
  to name it. The menubar filename is now an **inline editable field**: type a
  name, Save writes `<name>.spr` (+ `.png`/`.anim`/`.meta`) under the project's
  `art/`. Editing sets `doc.name` and clears `doc.path` so the new name takes
  effect — a rename for an unsaved doc, a save-as (old file stays) for one loaded
  from disk. Name is sanitized to a bare filename (no path separators; a typed
  `.spr` is dropped so the file isn't double-extensioned).
- **Curve renders clean 1px** (was staircasing — fat 2-wide steps on near-diagonal
  spans). `cm.paint.curve` now oversamples to the distinct pixels it crosses then
  **drops staircase L-corners** (a pixel whose before/after neighbours are
  diagonally adjacent collapses to one diagonal pixel) — a 45° curve is now a
  single-pixel diagonal (KAT pins it: collinear-control curve = exactly N
  on-diagonal pixels, zero off-diagonal). Sampling gaps stay line-bridged.
- **Hover tooltips on the rail** — a one-frame `M.tip` fed by whatever the cursor
  is over (every tool button via its `tip`, plus the shape-mode / `brs` / `1px`
  buttons), drawn last near the cursor. The bottom-right status already names the
  active tool. (Answered a question too: the wordless **square button below the
  tools is the shape FILL/OUTLINE toggle**, `F` — filled = rect/ellipse solid,
  hollow glyph = outline; now self-documenting via its tooltip.)
- ASCII-only tip text (the 5x8 font has no `·`/`°`; were rendering as `??`).
- selftest still 22536 (curve KAT strengthened to assert the no-staircase
  property); determinism re-verified (sandbox 200f record→verify byte-exact).

### Studio feedback round 4 (2026-06-29) — selection + color picker polish
Four asks from more studio use (all in `cm.studio`, dev/render-only — no engine/
sim/binary change, D040 §1; selftest still 22536, sandbox unaffected):
- **Clear the selection** — a plain click (no drag) with the select tool now
  drops the marquee (it used to leave a stray 1×1 selection). `handle_select`
  tracks whether the pointer moved; no-move on release ⇒ `M.sel = nil`. `^D` and
  a fresh drag still work; the tool tooltip now says `drag=select, click=clear; ^D`.
- **Marquee ants too fast** — `draw_marquee` crawled off `ui.ticks` (render
  frames), so on a high-refresh display the dashes flew. Now it advances on the
  **wall clock** (`pal.time_ns`, ~3 steps/s) → framerate-independent (studio is
  render-only, so `pal.time_ns` never enters a trace).
- **Picker snap** — clicking a **palette** swatch set `M.prim` directly without
  syncing the picker, so the SV-square cursor / hue / sliders didn't move to the
  picked colour. The swatch now calls `M.set_prim` (the same sync the eyedropper /
  hex / swap already used) → the picker snaps, so you can pick a colour then nudge
  a darker shade off it.
- **More ways to adjust a colour** (not just the MS-paint square) — added **R/G/B
  + H/S/V channel sliders** under the SV square, each with a result-gradient track
  (`color_slider`: previews the colour across that channel's range), a handle, and
  the value. **Drag V down = a darker shade of the same hue** (HSV edits write
  `M.hsv` then repack so the hue survives a trip to black; RGB edits go through
  `set_prim`). Drags latch on `M.pick` (shared with the square/strip → don't fight
  the dock wheel). Verified by `--win` captures (snap-to-red; the full slider
  stack); both pushed to llm-feed.

### M10 Phase 5 — pivots + slices (this session) — `082eb0b`, `7cf0b29`
The keystone authoring metadata, end to end (D041): the sprite's runtime
*geometry* the game needs at draw time. Both per-doc for v1; per-frame keys
deferred (a documented `.meta`/schema extension when a weapon must track a hand).
- **5a pivots DONE** `082eb0b` — the doc already carried a per-doc pivot (feet-
  center default) in the `.spr` HEAD, but nothing set it, baked it, or used it.
  Now: `cm.sprite` pivot rides struct-undo + `set_pivot` (clamped, no-op-safe);
  a new **`.meta` sidecar** (pivot — and 5b slices — as canonical doc bytes,
  `cm.state.canon`, like `.anim`) baked by `save` beside `.png`/`.anim`, with
  `load_meta` for the game. `cm.studio` **Pivot tool (P)** — drag the on-canvas
  crosshair (one struct-undo step/drag); always-visible crosshair; status
  `pivot @x,y`. **player.lua** anchors the authored pivot pixel to the foot point
  (was a hardcoded bottom-edge), mirrored on facing, squash/stretch scaling
  around it — render-only (file bytes, D026) → can't perturb a trace. genart set
  girl's feet pivot (8,22) + re-baked (.png/.anim byte-identical; .spr HEAD +
  new .meta). selftest +10.
- **5b slices DONE** `7cf0b29` — a slice = a named rect (attach point / hit box /
  fx origin). `cm.sprite` `doc.slices` + raw/add/delete/set_slice_rect (clamped,
  undoable, ride struct-undo); the **`SLCE` chunk** in `.spr`; slices in `.meta`;
  `find_slice(doc|meta|array, name)` for the runtime. `cm.studio` **Slice tool
  (K)** — drag a rect to set the active slice's region (creates one if none; one
  undo step/drag); a **SLICES dock panel** (list/select/+slice/del/inline
  rename); on-canvas magenta rects (faint always, bright+labelled with the tool,
  selected accented). No game/sim surface touched. selftest +10.
- **selftest 22478→22498** (+20). **Determinism proven**: KITCHECK 470f + TOUR
  820f `record→verify` byte-exact (pivot consumption is render-only). Three
  screenshots on llm-feed (studio pivot crosshair · the anchored sprite in-game ·
  studio named slices). The game **consumes the pivot**; slices are authored,
  baked, and queryable (`find_slice`) but **not yet consumed** — the slice VFX /
  weapon attach that reads them is the deferred M7/particle-emitter work.

### M10 Phase 5c — asset hot-reload (this session) — closes the editor loop
The keystone that makes the studio a real authoring tool: **paint in F2 → Ctrl+S
→ the in-game sprite updates live, no restart**. End to end, pure render-only
(D040 §1 — sprites carry no determinism tax), so it cannot perturb a trace.
- **The signal**: `cm.sprite.save` bumps `cm.asset_epoch` — a render-only counter
  on the `cm` root, the asset-side sibling of `cm.code_epoch` (boot.lua). It only
  ever moves on a save (the studio pauses the sim, and `--verify`/`--frames` never
  open it); consumers read it in **draw only** so it can't enter a trace.
- **The re-texture path**: `cm.gfx.texture(path, reload)` — `reload=true` re-reads
  the PNG and refreshes the memoized `{id,w,h}` **in place** (every holder
  updates), **freeing** the old GPU texture (SDL_GPU defers the release so it is
  safe mid-frame; the 256-slot cap makes freeing — not leaking — right for
  repeated saves) and **keeping** the current texture if the re-read fails.
- **The consumer is the cartridge** (D030 — the engine rings the bell, the game
  decides what to reload): `player.lua` `refresh_sprite()` re-derives strip / NF /
  clips / `.meta` pivot when `cm.asset_epoch` advances, checked atop `M.draw`.
  `M.step` is **untouched** so the sim is byte-identical.
- **Proof**: selftest **22498->22506** (+8: save bumps the epoch; reload refreshes
  in place after the strip grows; a failed reload keeps the old texture). The
  sandbox `sandbox_idle` render is **byte-identical** to the pre-change tree (git
  stash A/B); **KITCHECK 470f + TOUR 820f `record->verify` byte-exact**. A scripted
  headless save->reload (recolor girl.spr magenta via the `cm.sprite.save` path,
  the same one the studio's Ctrl+S takes) flips the in-game character live --
  before/after montage on llm-feed; the recolor was reverted, committed art clean.
- **Scope note**: the in-process save signal serves the F2 loop. An *external*
  writer (a separate `--bake` editing `art/` while the game runs) would also want
  a file-watcher path -- a documented follow-up (needs wall-clock mtime polling
  gated out of capped/verify runs, like `cm.reload`), not needed for the loop.

**Launch**: `bin/cosmic --studio` (drops into the project's asset browser;
project defaults to projects/sandbox) — or `F2` in any running session. The
`--studio` flag is live/capture-only (gated out of `--verify`).

Controls (studio): F2 toggle · tools B/E/G·L/R/O·**C(curve)**·**D(gradient)**·I·M(select)/
V(move)·**P(pivot)**·**K(slice)** · LMB primary / RMB secondary · Alt=eyedropper · X swap · F fill-mode ·
**curve: drag the ends, then drag 2 bends (2nd release commits)** ·
Shift constrain · wheel zoom · middle-drag pan · Ctrl+Z/Y · Ctrl+S save (**live-
reloads the in-game sprite — no restart**) · ^C/^X/
^V/^D clipboard (**paste → new layer**) · Enter stamp float · Del clear · with a
marquee, paint/fill/shape **clip to the selection**; **select tool: drag=marquee,
click=clear (or ^D)** · H/J flip · `[`/`]` rotate ·
menubar fH/fV/rL/rR/x2//2 + browse/new/**size** (resize doc: canvas/scale +
anchor)/save/close · rail brs/1px · palette slots
L=load R=save · **LAYERS** panel: add/dup/del · up/dn/**merge** (flatten onto
below). **Gradient**: drag an axis on a layer → a non-destructive fill
masked to its pixels; drag the p0/p1 handles; the dock panel tunes type / ramp
(click bar=add stop, RMB marker=delete) / dither / levels / bayer / phase;
bake=stamp to pixels, clear=remove. **Timeline** (bottom): the frame thumbnail
strip (click=select, +f/dup/del/`<`/`>`), onion toggle, fps, ▶play/■stop (previews
the active clip or the whole strip). **CLIPS** dock panel: +clip/del, click a row
to make it active, rename, loop/once/pingpong, the sequence chips (click=select
entry, RMB=remove, "+ add frame N"), per-entry dur. **Pivot (P)**: drag the
yellow crosshair to set the in-game anchor (baked to `.meta`; the game pins it to
the feet). **Slice (K)**: drag a rect → a named region; the **SLICES** dock panel
lists/selects/renames/deletes them (attach points / hit boxes; baked to `.meta`,
queryable via `cm.sprite.find_slice`). **COLOR** dock panel: SV square + hue strip
+ hex + **R/G/B & H/S/V sliders** (pick a colour and drag V for a darker shade);
clicking a palette swatch snaps the whole picker to it.

---

## M8/M7 (previous milestones, still current as shipped) — history below

**Phase (M8)**: **M8 — viewport & editor UX (D036): FEATURE-COMPLETE** (pending the
golden re-cut, which is deferred — see below). The whole D036 model ships:
variable-FOV two-target composite (editor chrome at its own scale **around** the
game viewport), the resize ladder, alt+enter borderless fullscreen (**human-
approved**), and the **options menu** (Esc) to set resolution/scale/fullscreen
directly, **now persisted across launches** (video.dat). Layout approved ("it
looks correct yes"); three feel passes applied (round 3: **Esc opens the options
menu instead of quitting**, + a menu quit button + persistence). M8 is covered
by **selftest 22312→22351** (+39: viewport/composite/ladder/mouse-split/capture);
determinism byte-exact; both linux + windows builds clean. M7
movement remains FEEL-APPROVED; its deferred items (CW≈26 scale, slice VFX) wait
on real assets.
**Done this session (M8.1–M8.6 + capture, all on `main`, selftest 22312→22351,
determinism byte-exact, uigallery golden byte-identical, goldens else unaffected):**
- **M8.1** `ea7dc9a` — PAL **api 4→5**: `pal.x_fov(w,h)` (the variable game FOV =
  resizable internal target), `pal.x_window_size()`, `x_set_window_size`/
  `x_set_fullscreen` (options menu). Additive `x_*` (experimental ns).
- **M8.2** `f11ab36` — PAL **two-target composite**: `pal.x_ui_target` (a second
  editor/UI canvas), `pal.x_target("game"|"ui")` routing, `pal.x_compose{…}`
  (game→sub-rect at integer scale, ui→whole window at its own scale, alpha-over).
  Mouse events carry BOTH game-space `x,y` (sim, unchanged) + ui-canvas `ui_x,
  ui_y` (editor chrome). present() factored into scene_pass + blit_layer.
- **M8.3** `758dd40` — `cm.view`: the D036 resize **ladder** (scale =
  max(2,min(⌊W/480⌋,⌊H/270⌋)); FOV = min(480,⌊W/scale⌋)×min(270,⌊H/scale⌋)),
  live only (headless/verify keep the fixed FOV). Game fills the window at a
  variable FOV in play mode.
- **M8.4** `6c07b6a` — editor + dev UI on the **ui canvas** at its own scale
  (`cfg.ui_scale`, default **2×** — see knob note); the game becomes an **inset
  viewport** (window minus the toolbar/inspector) at its own integer scale. The
  mouse splits: `inp.gx/gy` game-space (world placement), `inp.mx/my` ui-canvas
  (panel hit-test). console/scrub/perf re-homed via `view.surface_size()`.
- **Capture** `11cbc23` — `pal.x_capture(w,h)` / `x_capture_read()` + engine
  `--win WxH`: composite into an offscreen target so a headless `--shot` shows
  the editor-around-game layout (only the swapchain has it otherwise). This is
  how the layout was self-verified + pushed to llm-feed. **Also fixes** the
  "graphics pipeline not bound" SIGILL the human saw: `pipe_blit` was only built
  for a window; now built unconditionally (UNORM format headless). Live path
  unchanged. `t_capture` guards the composite layering + the headless blit pipe.
  Capture a view: `bin/cosmic projects/sandbox --win 1920x1080 --frames 30 \
  --shot /tmp/e.png --eval "cm.editor.toggle(true)"`.
- **Docs**: **D039** (the two-target composite realizing D036) + the
  **ARCHITECTURE api v5 table**.

### M8 feedback round 1 (2026-06-28, win11) — `bf58389`
Layout approved. Applied: **fill-the-window ladder** — a maximized window was
letterboxing the game in black bars (the old min-of-floors + 480×270 cap); now
the scale is chosen to keep the FOV near the reference and the FOV fills the
window at that scale (1920×1040 → 480×260@4×; the editor inset sits snug, no
margins). **alt+enter** toggles borderless fullscreen (`pal.x_set_fullscreen`).
selftest 22349; verified by `--win` capture (maximized play fills edge-to-edge;
editor inset fills the central rect) on llm-feed. **Still open**: confirm
`cfg.ui_scale` (2× readable vs D036's literal 1×) on win11; test the alt+enter
toggle natively (headless can't).

### M8 feedback round 2 (2026-06-28, win11) — `02d55c4`, `2ea0973`
Fullscreen **approved**. Fixed "parallax bleeds through the bottom in fullscreen
editor mode": a FOV taller/wider than the 480×270 design renders past the sim
camera's clamp (the sim can't read the live FOV — determinism), revealing
undesigned world. Also latent in play mode (1280×720→640×360 bled). Fix —
**unified ladder** (supersedes round-1's fill): `scale = max(base, ⌊W/ref_w⌋,
⌊H/ref_h⌋)` (max-of-fits, so maximize still FILLS) **+ FOV hard-capped at the
reference** (so the render never exceeds the design → never bleeds). Net: fills
on whole-multiple windows (incl. maximized 16:9 → 480×260), thin letterbox /
editor margins otherwise; no bleed in play or editor. **M8.6 options menu**
(`cm.options`, Esc): fullscreen toggle, windowed presets (960×540…1920×1080),
ui-scale 1×/2×/3× — sets res directly when you can't drag-resize. **M8.5**:
api5 table extended (x_capture); nested-subdir module load + deep hot-reload
verified (the loader watch_adds every required file, dotted names → nested
paths).

### M8 feedback round 3 (2026-06-28) — `ff1e234`, `929d0e6`
The human couldn't reach the options menu: Esc still **quit** the game. The
sandbox bound Esc→`pal.quit()` in `game.step()`, firing alongside `cm.options`'
own Esc toggle and killing the game before the menu opened. **Fixed** — Esc is
now engine-reserved for the options menu (like ` for the console); the sandbox
no longer binds or acts on it. That removed the only keyboard quit, and
borderless fullscreen has no window-close button, so the options menu gained a
red **"quit game"** button; it and the window-close (X) now share one
`cm.main.request_quit()` (a game's `on_quit` hook fires from either). The menu
also captures the keyboard while open (mirroring the mouse capture) so the
player doesn't run around behind it. **Options persistence** (the deferred
follow-up) also landed: resolution / ui-scale / fullscreen save to
`<project>/video.dat` (`cm.view.save_video`/`load_video`, canonical bytes like
knobs.dat) and apply before the first frame — interactive sessions only, so
headless/`--frames`/`--verify`/`--win` keep the fixed FOV (goldens + determinism
byte-stable; gitignored). selftest 22351; sandbox record→verify byte-exact
(300f); save/load round-trip + menu render verified headless. The **interactive
behaviors** (Esc opens not quits; settings persist across a real relaunch) are
the human's native pass — headless has no window events. (The human's own
test-session video.dat — ui_scale=1, fullscreen — was observed on disk, which
*proves* persistence works end-to-end; I reset it during testing, so the next
launch starts from defaults.)

### M8/M7 feedback round 4 (2026-06-28) — `3894779`, `429530d`, `f890256`
Three asks from the human's first real play:
- **Window presets now FILL the window** (options menu): 720×540, 960×540,
  1440×1080, 1920×1080 (a 4:3 + a 16:9 at two heights) — each a whole multiple of
  a FOV ≤ the 480×270 reference, so the ladder fills with no letterbox (was the
  old 16:9-only set that letterboxed at e.g. 1280×720). See cm.view.ladder.
- **ui_scale applies in PLAY mode too** (D039 revision): the dev chrome (options
  menu / console / perf / scrub) now ALWAYS rides a ui canvas at `cfg.ui_scale` —
  cm.view.update allocates it in play as well as the editor (game composed under
  it, centered full-window in play), and cm.main routes the panels there after
  `editor.frame` regardless of editor state. So changing ui_scale with the editor
  closed rescales the menu live (it didn't before — it drew at the game scale).
  Render-only / live-only; goldens untouched.
- **Flutter is a rhythmic hold, not a glide** (M7 feel pass 4 + 4b, GAME.md §4 +
  D035): hold E after a hop and KEEP holding once you START FALLING → a small
  UPWARD height-based mini-hop every `flutter_interval`(30f≈2/s), `flutter_boosts`
  (4) times, sized (`flutter_h`=11) to roughly HOLD altitude with a gentle ~11px
  bob. Carried momentum is CANCELLED at hover-start (a flash-jump doesn't launch
  you far) and each boost is a slight up-FORWARD diagonal (`flutter_vx`=30 « the
  ~84 vertical → ~20°, <45°) so you drift forward a little; air drag keeps it
  gentle, hold a dir to steer. Replaces the `flutter_grace`/`_max`/`_fall`/`_decel`
  glide knobs; the "must be falling" gate is the tap guard. **4b** tuned the boosts
  ¼ smaller + 2/s; **4c** kept momentum (too far); **4d** cancel + slight diagonal
  (the keeper) — **FEEL-APPROVED** ("this feels good, we'll go with this"). Verified
  on TOUR: x drifts gently ~20–34px/s, vy flips every 30f at ~−84, y holds; selftest
  22351; KITCHECK + TOUR record→verify byte-exact; montage on llm-feed. With the
  knobs settled, the **KITCHECK flutter sub-test was re-choreographed** (a `{44}`
  settle so its jump+hop fires from a fresh grounded airtime + a `{130}` hold for the
  full 4-boost timeout): it triggers again, arms hop_cd (~f=590) and blocks the next
  hop — flutter→cd oracle coverage restored.

**Still open / deferred**:
- **`cfg.ui_scale`** default (2× now; D036 says 1×) — the human's taste call,
  live-tunable + in the options menu (and now persisted). Not blocking.
- **Golden suite re-cut** — DEFERRED (D033 + STATUS): the pixel goldens
  (sandbox_idle/tour) are M5-era and would just re-cut again when real art lands
  (M10); the `.ptrace`→`.ctrace` trace re-cut waits on confirming the rename
  (D033, human's call). selftest (22351) is the live net meanwhile.

**Next:** the **flutter is feel-approved** (round 4d) — M7's last open feel knob
to be dialed by hand is settled; the moveset is approved end-to-end. Remaining:
the `cfg.ui_scale` default taste (2× vs D036's 1×) on win11; the deferred golden
re-cut; then **M9 (audio)** or circle back to M7's asset-gated items (the CW≈26
absolute scale via FOV/scale + `move.cw/ch`; the slice VFX once the editor's
particle-emitter work lands). Good `/clear` point — M8 + the M7 feel passes are
committed and STATUS is current.

## This session (2026-06-27) — M7 moveset

The whole MapleStory moveset (GAME.md §4) now lives in the hub cartridge as
pure controller policy. Commits: `2a810a4` (controller + wiring), `69569c4`
(attract demo).

- **`projects/sandbox/player.lua`** rewritten: the old A-Hat-in-Time kit
  (variable-height jump, dive/boost/double-jump, crate grab) is gone; in its
  place — walk, jump (fixed ~1 CH, hold to auto-repeat), **flash jump** (repeat-
  able dash + sonic-boom ring), **up jump** (fixed vertical, once/airtime, locks
  out flash jump), **hop + flutter** (hop once/airtime; hold E hovers up to 10 s
  then arms a 10 s hop cd — a *1-frame TAP* never arms it), **grapple**
  (deterministic column scan for a standable top above, prefers past ½ screen,
  slow reel, once/airtime, 3 s cd, jump cancels), **teleport** (~5 CW blink,
  momentum dump, max 2/s, persistent A↔B phase mode that tints the sprite), and
  **hold-D slice** (slash stub; enemies at M12). New 128-byte buffer layout
  (pcall self-heals the old 96-byte one on reload). New 11-frame placeholder
  sprite + grapple beam + phase tint.
- **`main.lua`**: action map (hop=E, **grapple=q** — the spec's `` ` `` is the
  dev console, so q is the proxy), new ctl edges, retired dive/dj/throw knobs.
  **`level.lua`**: spawn lifted clear of the ground for any cw/ch.
- **`demo.lua`** re-choreographed: TOUR showreel + KITCHECK rule oracle, both
  byte-exact on `--verify`.
- **Determinism proven**: `selftest 22312 PASS`; record→verify byte-exact —
  TOUR 820 frames, KITCHECK 470 frames. No PAL/engine change (binary untouched).
- **Calibration**: every value is a live knob under `doc.knobs.move` (D028);
  `cw`/`ch` are the character box AND the CW/CH unit. Defaults are placeholders
  sized to the current 16 px-tile map at 1:1 — the absolute *6 CW ≈ ⅓ screen*
  anchor (CW≈26) needs M8 zoom + real art (a cw/ch/zoom knob change).
- **Montage** pushed to llm-feed ("M7 moveset — final demo tour").

### Feedback round 1 (2026-06-28, human win11 pass — "feels approximately right")

Applied (GAME.md §4 + D035 updated; selftest 22312 + record→verify both
timelines still byte-exact; montage "M7 moveset v2" on llm-feed):

- **Flash jump → once per airtime** (was infinite/repeatable): re-arms on
  landing. Verified via the fj flag (fires once, 2nd airborne press blocked,
  resets on land).
- **Teleport → alternates forward/back** (was forward only), tied to the A↔B
  phase flip: mode A fwd/solid, B back/phase.
- **Flutter "permanent cooldown" fixed**: it was the (correct) 10 s hop_cd being
  *invisible* + a real bug where a teleport re-armed it while a stale
  `flutter_t` lingered (now reset on flutter end). Mid-air hop works when off cd.
- **1.5× airtime, same heights**: `jump_apex_t` ×1.5; `upjump_v`/`hop_vy`/`fj_vy`
  ×2/3 (height ∝ v²/g).
- **Temporary cooldown HUD** (main.lua `draw_cd_hud`, live-play only): hop/
  grapple/tp bars + spent air-moves + phase mode — the requested cd viz.

Deferred per the human: the **fancy slice VFX** (orbiting energy blades + trail
particles) waits for the editor/particle-emitter work so it can be authored
live; final knob tuning waits for the real art.

### Feedback round 2 (2026-06-28)

GAME.md §4 + D035 updated; selftest 22312 + record→verify both timelines still
byte-exact; montage "M7 moveset v3" on llm-feed:

- **Flutter cd only on a real flutter** (was: any tap armed the 10 s cd). A
  `flutter_grace` (10 airborne frames) must pass before the hover — and thus the
  cd — engages; a normal tap is a clean hop. (Verified: `flutter_t` starts only
  after `hop_active`>grace, cd arms on land.) Also reconfirmed the teleport-
  re-arm bug fix.
- **Grapple extends → reels** (was: instant reel, short-range slingshot). The
  hook climbs to the target at `grapple_extend` (~1 screenful/s) under gravity;
  it reels only on connect, from your current velocity — so a jump-into-grapple
  has fallen to downward velocity (verified +70 px/s at connect) that the reel
  reverses first, damping the launch. Key fix: landing no longer cancels a
  grapple (the extend phase is grounded for a grapple-from-standing).

### Feedback round 3 (2026-06-28)

GAME.md §4 + D035 updated; selftest 22312 + record→verify both timelines:

- **Jump airtime ≈ ⅔ s** (apex_t 22.5→21.3; measured 0.65 s for a clean jump),
  height unchanged.
- **Up-jump & hop are height-based now** (`upjump_h`/`hop_h`): velocity derived
  from live gravity, so gravity retunes auto-preserve heights (no more ×k impulse
  recomputes).
- **Grapple launch dampened**: reel stops ~2 CH short of the platform
  (`grapple_stop_ch`) so the residual coasts under gravity; `grapple_min_t` keeps
  very-short grapples a small launch. The launch is really capped by
  `grapple_vmax` (coast ≈ vmax²/2g) — lowered 300→220, cutting a medium grapple's
  overshoot ~5.6 CH → **~2.5 CH** (accel 720 unchanged). **Grapple start zeroes
  horizontal momentum; arrows + teleport are locked out for the whole grapple**
  (committed vertical move; jump still cancels).

## What works right now (the engine, M0–M6 + the M7 moveset)

**Runs on Windows** (M6): `nix build .#cosmic-windows` → `cosmic.exe`, byte-exact
state parity with linux.


Boot + live sessions + hot reload + crash parachute; the PAL draw/state/input/
trace stack; the determinism kit (fixed 60 Hz, engine PRNG, cm.math, named
buffers + canonical doc tree); snapshot/restore with code bundles (D012);
cm.ui/console/repl/perf; error containment (game errors pause, never kill);
cm.tilemap with one-way platforms; the editor + inspector + prop palette
(everything edits via recorded EVALs); the M5 **time machine** (always-on
segment ring D032, F4 scrubber, rewind, `.ctrace` export, replay playback); the
suite under `nix flake check`. Detail: ARCHITECTURE.md + DECISIONS D001–D032 +
git history.

**The M7 moveset** (this session): walk / jump / flash-jump / up-jump /
hop+flutter / grapple / teleport / hold-slice, all deterministic, every value a
live knob — pending the human's feel tuning. See the session note above.

## M6 — windows port: DONE (agent-verified 2026-06-27, commit `6b39cf6`)

Cross-build via the flake's `packages.cosmic-windows` (`pkgsCross.mingwW64` +
nixpkgs cross SDL3 3.4.8 — pure Nix, no impure downloads; **D038**). The PAL is
pure SDL3, so the only C changes were `<SDL3/SDL_main.h>` (Windows entry) and
`fixup_cwd()` (self-locate via `SDL_GetBasePath` — **closes the cwd=repo-root
debt on both platforms**). Ships self-contained: `cosmic.exe` + `SDL3.dll` +
`libmcfgthread`. Verified on the win11 host via WSL interop:

- **selftest 22308 checks PASS** on `pal windows`;
- **cross-platform determinism parity is byte-exact** — linux records → windows
  `--verify` PASS, windows records → linux `--verify` PASS, and the two
  independently-recorded sandbox traces are **byte-identical**;
- the full Vulkan pipeline **renders headless on windows** (screenshot pushed
  to llm-feed).

Build it: `nix build .#cosmic-windows`; the `result/` tree is runnable on win11
(`cosmic.exe` beside `SDL3.dll` + `engine/`/`projects/`).

**Post-M6 windowed bug, FIXED** (commit `6209bbc`): the human's windowed run hit
a **key-stick** — `cm.input` was sampled only inside `sim_step`, so on a >60 Hz
monitor (vsync) the render loop's zero-sim-step ticks dropped their polled
events (a key-up landing there never cleared → stuck). Now `feed()` ingests
events **every tick**, `sample()` builds the record **per sim step**; headless
lockstep + trace determinism are byte-identical (selftest 22308→**22312** with
new regression cases; parity re-verified).

**Post-M6 perf fix** (commit `cae9024`): running from a WSL terminal showed
rhythmic frame spikes — the 4 Hz hot-reload poll stat'd ~30 module files inline
on the main thread, slow over 9p/drvfs. PAL gained a **background file-watcher
thread** (`pal.watch_mtime`, API 3→4); `cm.reload` reads cached mtimes, no
main-thread FS. Lazy-spawned (never in capped/verify runs → determinism
intact); parachute keeps its inline stat. Verified: selftest 22312, hot reload
still fires (linux), windows binary runs stably with the thread up.

Latest build (both fixes) deployed to `C:\temp\cosmic`. **Human-verified
2026-06-27**: windowed run is perfectly smooth — input releases cleanly, no
frame spikes from a WSL terminal.

## Next step — finish M8 (M8.4 → M8.6 → M8.5), then close M7's deferred items

**M8.1–M8.3 are done** (see the Phase block up top: PAL api5 viewport surface +
two-target composite + the resize ladder). Remaining M8 sub-steps:

1. **M8.4 — editor + dev UI onto the ui canvas**: route `editor`/`ui`/`console`/
   `scrub`/`perf` draws through `pal.x_target("ui")`; lay them out against the
   ui-canvas size (not `gfx_size`, which is now the FOV); panels hit-test in
   ui-space (`ui_x/ui_y`), the world overlay + prop placement stay game-space
   (`x/y`); the game becomes a central viewport rect via `pal.x_compose`. This
   is the big Lua refactor and the visible payoff (editor at 1× around game at
   2×). **Default layout is a taste call — checkpoint with the human first.**
2. **M8.6 — options menu**: set resolution/scale/fullscreen directly (a
   borderless/fullscreen window can't be drag-resized). PAL hooks exist
   (`x_set_window_size`/`x_set_fullscreen`); needs the menu UI + persistence.
3. **M8.5 — docs + goldens + multi-file**: ADR for the two-target model, the
   ARCHITECTURE api5 table, multi-file/subdir hot-reload at scale, golden re-cut.
   The **zoom** delivers the GAME.md §4 anchor (6 CW ≈ ⅓ screen, CW≈26 at the
   480-wide FOV) — set the FOV/scale + `move.cw/ch` together here. Plus the
   editor's live particle-emitter work for the deferred M7 **slice VFX**.
2. **Then close M7's deferred items** (once scale + assets settle): final knob
   tuning with the real sprite; the slice VFX; and **re-cut the golden suite** —
   committed traces are still dormant `.ptrace` (suite globs `.ctrace`). Plan:
   **delete** the obsolete-mechanic traces (boostcap/boostlock/divecancel/djscale/
   jumpfeel/platformer*/sandbox_ease/old kitcheck/sandbox); **re-cut as `.ctrace`**
   the engine-feature goldens (editpaint, inspectpoke, propspawn, mantle) +
   churn/evalfix; **add** a fresh `kitcheck.ctrace`; **re-shoot** the pixel
   goldens (sandbox_idle, sandbox_tour). selftest 22312 is the live net until then.

Controls (dev): arrows · space=jump (hold=auto-repeat; airborne=flash, Up=up-jump)
· e=hop (hold=flutter) · **q=grapple** · r=teleport · d=slice. F1=editor ·
**Esc=options menu** · **alt+enter=borderless fullscreen** · `=console · F3=perf ·
F4=time machine. `game.save_knobs()` persists tuning. The temporary cooldown HUD
shows hop/grapple/tp timers.

## Known small items / debts

- **M7 feel knobs are placeholders** — `doc.knobs.move` defaults are agent
  guesses for the human to dial in (with the real art). cw/ch=12/18 fit the
  current map at 1:1; absolute screen-scale (CW≈26) is M8.
- **Slice VFX is a stub, deferred** — the fancy version (orbiting energy blades
  + trail particles) waits for the editor/particle-emitter work so it can be
  live-authored (human's call). The attack input + a placeholder slash exist.
- **Cooldown HUD is temporary** (main.lua `draw_cd_hud`, live-play only) — a
  testing aid; remove once the editor can visualize ability/emitter state.
- **Golden suite still stale, now also pre-sign-off** (D033): committed
  `.ptrace` are dormant; the M7 re-cut waits for locked knobs (next-step #2).
  selftest 22312 is the live net.
- **Grapple onto a SOLID platform from directly below bonks** (hit.up) — the
  two map balconies are STONE; grapple works through one-way planks (most of
  the map). The real hub (M-content) follows the one-way rule (GAME.md §4).
- **Grapple is on `q`, not the spec's `` ` ``** (the dev console owns backtick
  unless the project locks the editor). A shipped/locked build can bind grave.
- **Player grab/throw is gone** — E is hop now; the crate pit is inert physics.
  The sandbox grab/float/constrain "tool" returns with M-physics (GAME.md §7).
- `projects/sandbox/map.dat` is **untracked local state** that shadows the
  procedural map at boot (PROCESS warns for goldens); left as-is.
- Confirm the rename *choices* `cm` (prefix) and `.ctrace` (ext) are
  acceptable — one sed to change now, frozen after 1.0 (D033).
- Carry-over M5/M4 debts still stand: console-eval rewind caveat, scrub previews
  with current draw code, bundle-mode-after-restore pauses disk reload, pinned
  recordings grow memory, inspector strings read-only / no add-delete, props can
  squeeze into a wall in pathological piles. (Full list was in the M5 STATUS in
  git history if one bites.)

## Design questions — RESOLVED 2026-06-27 (GAME.md §11, D037)

The human answered all six: fiction spine **ratified**; **earth + a cosmic
finale**, two hubs; **~3–5 hand-crafted bosses**; **full moveset from the
start**; teleport **phase-shift** modes (A solid / B phases); and a
**hub-respawn + optional-economy** model (currency/farmable drops, dual-sourced
abilities incl. radar + flutter-range, cheese consumables, world map + quest
arrow, no-rollback death, verifiable challenge stats). Captured in GAME.md §8/§11
and **D037**. Remaining opens are milestone-local (ability roster, boss roster,
HP/regen tuning) and don't block M6/M7.

(Always-open: art is human-authored; the agent designs map layouts + scenery
from primitives and writes story/quests once we reach M-content.)
