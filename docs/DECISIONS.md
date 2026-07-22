# cosmic2d — decision log

Append-only ADR log. Each entry: context, decision, why, and what would make
us revisit. New sim-touching systems must state their snapshot story here.

## D001 — language split: C11 PAL + Lua 5.4 for everything else

**Context**: seed left language open; criteria were portability, simple
explicit semantics, embeddable in the platform layer, hot reload, "typo must
not become a 2-hour hunt", performance via platform-layer primitives.
**Decision**: per-platform binary in C11; engine/editor/game code in Lua 5.4
(PUC), vendored and embedded in the PAL.
**Why**: the seed's own framing (fantasy console, numpy analogy, editable
engine without recompiling) is the PICO-8/TIC-80/LÖVE-proven shape, and Lua is
its canonical language: tiny ANSI-C VM (ports anywhere), trivially
embeddable/reloadable, runtime errors are catchable tracebacks instead of
segfaults, and slowness is acceptable because hot loops live in PAL kernels.
Native-DLL hot reload (Handmade style) fails "editable without a compiler";
WASM needs a toolchain shipped per project; a custom language is a tar pit.
**Revisit if**: sim logic measurably can't hold 60 Hz after kernel migration
(then: LuaJIT on x86/ARM as an optional accelerated PAL — 5.1 subset would
constrain engine code, so decide deliberately), or debugging proves worse
than expected (then: invest in the in-engine step debugger sooner).

## D002 — PUC Lua over LuaJIT

**Decision**: PUC 5.4, vendored, compiled into the PAL.
**Why**: portability pillar (ANSI C everywhere vs JIT per-arch), 5.4 integer
subtype helps determinism (exact counters/fixed-point), simpler semantics,
actively maintained. Perf goes to PAL kernels by design (D001).
**Revisit**: see D001.

## D003 — vendored Lua gets a fixed string-hash seed

**Decision**: define `luai_makeseed(L)` to a constant at compile time (PAL
Makefile, `-D` flag — lstate.c's seed block is `#if !defined` guarded), so
the vendored source stays pristine and version bumps reapply for free.
**Why**: stock 5.4 mixes ASLR addresses into the string hash seed, so
table iteration order varies run-to-run; with a fixed seed, same-binary runs
are reproducible even when someone accidentally order-depends. The iron rule
(never depend on hash order in sim) still stands — pointer-keyed tables and
cross-platform builds still vary.
**Revisit**: never (cheap insurance).

## D004 — SDL3 as the platform substrate, SDL_GPU (Vulkan) as first backend

**Context**: seed says "vulkan now, GL/software later", platform layer should
be small and portable.
**Decision**: SDL3 for window/input/audio; rendering through SDL_GPU with the
Vulkan backend on both Linux and Windows. Engine-side renderer interface kept
narrow (quads/textures/clip/camera/target) so GL1.x and software backends can
be added as PAL variants later.
**Why**: raw Vulkan is ~3k lines of boilerplate before the first quad and
duplicates exactly the portability work SDL exists to do; SDL_GPU is Vulkan
underneath on our targets, keeps us one binary dependency from "runs
everywhere SDL runs", and the narrow interface preserves the seed's
GL/software endgame. WSL2 reality check: dzn (Vulkan-on-D3D12, RTX 5060) for
live dev + lavapipe (software) for headless/goldens — both enumerate here.
**Revisit if**: SDL_GPU blocks a needed primitive (then: raw-Vulkan PAL
variant behind the same `pal.*` contract), or the software-renderer milestone
arrives (then it implements the same contract natively).

## D005 — state = named C-side buffers + canonical doc tree; Lua heap never snapshot

**Decision**: see ARCHITECTURE.md "State model".
**Why**: byte-exact snapshot/rewind without serializing closures; state
survives Lua VM reboots (crash parachute + hot reload for free); typed
buffers are exactly the numpy-model surface PAL kernels need; doc tree keeps
ergonomics for irregular data with a canonical (sorted-key) serializer for
hashing.
**Snapshot story**: snapshot = named buffers + doc tree + frame counter.
**Revisit if**: doc-tree serialization shows up in frame profiles (then:
move offenders to buffers, or delta-snapshot).

## D006 — fixed 60 Hz sim; render not interpolated yet

**Decision**: sim steps at exactly 60/s driven by an accumulator; rendering
draws current state (no interpolation in v0); headless lockstep mode steps
1:1 for tests.
**Why**: determinism first; pixel-art at integer scales tolerates 60 Hz
presentation well; interpolation is additive later (store prev transforms)
without breaking traces.
**Revisit when**: high-refresh smoothness lands on the feel agenda (M9-ish).

## D007 — goldens always on pinned software rasterizer (lavapipe)

**Decision**: pixel goldens render on the flake-pinned mesa lavapipe ICD
(`VK_DRIVER_FILES` forced in the golden runner); hardware/dzn drivers are
never golden sources. State-hash goldens are the primary regression net;
pixel goldens guard the PAL per platform.
**Why**: software rasterization is bit-stable across machines; the flake pin
makes it stable across time; hardware drivers are neither.
**Revisit**: mesa bumps in the flake regenerate pixel goldens deliberately
(a noted, reviewed event).

## D008 — repo root is the console; projects/ holds cartridges

**Decision**: one folder = engine + editor + tools + docs + projects;
sharing = zip the folder. `projects/sandbox` is the stock cartridge and
reference implementation. A root config (M10) selects startup project + mode
for end-user shipping.
**Why**: seed's self-contained vision, recipient can play/edit/build.
**Revisit if**: project isolation needs grow (per-project engine versions —
explicitly out of scope for now).

## D009 — colors are raw bytes end-to-end (no sRGB pipeline)

**Decision**: UNORM formats everywhere; no gamma conversion in shaders or
blending; LUT pass operates on raw values.
**Why**: pixel-art authoring intuition ("the bytes I drew are the bytes on
screen"), LUT semantics stay exact, one less cross-driver determinism hazard.
**Revisit if**: the look pillar ever demands linear-light blending (unlikely
for this aesthetic).

## D010 — text starts as baked spleen bitmap font

**Decision**: bake spleen (BSD-3, in nixpkgs) 5x8 + 8x16 BDF into an engine
asset at dev time; commit the baked artifact with attribution; engine draws
text as quads from the atlas.
**Why**: zero-asset-pipeline text on day one for editor/debug UI; pixel-true
at internal resolution; replaced later by in-engine-authored stock fonts.
**Revisit**: when the human designs stock assets (M9+).

## D011 — vendored-deps policy

**Decision**: everything the PAL compiles against beyond SDL3 is vendored
in-repo (lua, stb single-file libs); build artifacts users would otherwise
need a toolchain for (.spv shaders, baked fonts) are committed. SDL3 itself
comes from nixpkgs (linux) / official prebuilt (windows packaging, M7).
**Why**: self-contained pillar; nix flake pins the rest for dev.
**Revisit**: per dependency, in this log.

## D012 — snapshots embed the code bundle (human call, 2026-06-10)

**Context**: code is live-editable, so a snapshot's state trajectory is only
reproducible together with the exact sources that produced it.
**Decision**: every snapshot carries a content-addressed bundle of all
loaded sources (engine + project); traces reference bundles per code epoch
(mid-recording reloads start a new epoch). Restore executes bundle code, not
disk code; adopting disk code is an explicit separate operation. The M1
module loader retains chunk sources to make this cheap.
**Snapshot story**: this *is* the snapshot story for code itself.
**Revisit if**: bundle size hurts (then: store per-file hashes against a
repo-wide content store instead of inline copies).

## D013 — headless is a full live session, minus the window

**Decision**: `--headless` without `--frames` paces to ~60 Hz, polls hot
reload, and supports the crash parachute — identical behavior to windowed
except no window/swapchain. Capped runs (`--frames N`) free-run with reload
polling off (deterministic captures).
**Why**: the agent runs live verification (reload, parachute, soak tests)
without popping windows on the human's desktop; goldens stay deterministic.

## D014 — traces record inputs AND per-frame state deltas (human call, 2026-06-10)

**Context**: traces should be shareable session replays with simple delta
compression (state + changed scripts only), usable both for showcases and
for in-engine per-frame state inspection.
**Decision**: one trace format = starting snapshot + per-frame input records
+ per-frame state deltas (sparse XOR runs vs previous frame) + periodic
keyframes + code-epoch records on reload (D012). Full layout in
ARCHITECTURE.md "Traces".
**Why**: inputs alone need determinism to reconstruct state (useless while
*debugging* determinism); deltas alone can't drive the golden runner's
re-sim comparison. Recording both makes the same file a replay, a random
access debugger timeline, and a determinism oracle that localizes the first
divergent byte. Per-frame deltas of 2D sim state are small; XOR+run encoding
keeps it dependency-free.
**Snapshot story**: keyframes are snapshots; deltas compose between them.
**Revisit if**: trace size hurts for long sessions (then: smarter entropy
coding behind the same record structure), or draw stops being a pure
function of state (would break replay-without-re-sim; don't let it).

## D015 — the PAL freezes at 1.0 (human call, 2026-06-10)

**Context**: after 1.0 there should almost never be a breaking change that
makes traces and a PAL binary incompatible. D012 already makes engine/game
code travel inside traces, so the PAL contract is the *single* remaining
compatibility surface — engine evolution can't break a trace, only a PAL
semantic change can.
**Decision**: the PAL surface is governed by the "PAL stability contract"
(ARCHITECTURE.md): mechanism-not-policy layering, additive-only evolution
post-1.0, `pal.x_*` experimental namespace, versioned C kernels
(`name@N`, old versions callable forever), frozen base semantics declared
now (little-endian, IEEE-754, Lua 5.4, fnv1a-64, tagged version-stamped
chunks, HID scancodes, draw semantics), eternal golden suite as enforcement,
and `pal.version` feature detection with loud refusal.
**Why**: the seed's own pillar ("engine upgrades should not need to touch
the low-level binaries") extended to recorded data; PICO-8-style longevity
requires the hardware spec to be boring and eternal.
**Revisit**: individual rules may grow teeth pre-1.0; the freeze itself is
constitutional and not up for revision after 1.0.

## D016 — canonical doc serialization is binary and type-tagged (M1)

**Context**: snapshots, trace deltas and hashing all need the doc tree as
stable bytes; text formats make float round-tripping and key ordering fiddly.
**Decision**: canonical form v1 (frozen): type-tagged binary, i64/f64 raw LE
bits, u32-length strings, tables as sorted key/value pairs (integer keys
ascending, then string keys bytewise). NaN, shared subtables, fractional and
boolean keys are errors. Spec in ARCHITECTURE "Concrete M1 formats";
implementation cm/state.lua.
**Why**: equal trees ⇒ identical bytes (delta/hash-stable), float bits exact
by construction, ~40 lines each way, no dependencies.
**Snapshot story**: this IS the doc tree's snapshot encoding.
**Revisit if**: doc serialization shows in frame profiles (D005 already
plans the escape: move offenders to buffers).

## D017 — state deltas via pal.buf_delta1 XOR sparse runs (M1)

**Context**: D014 needs per-frame buffer deltas; the codec's exact output
bytes are recorded in traces forever, so the algorithm must never drift.
**Decision**: `pal.buf_delta1/buf_apply_delta1` C kernels, version-in-name
per stability contract rule 4. Format frozen: runs of
`{u32 off, u32 len, len XOR bytes}`; a run ends at the last differing byte
followed by ≥8 equal bytes; empty string = identical; apply is self-inverse.
A better codec someday is `buf_delta2`, and `buf_delta1` stays callable
forever.
**Why**: XOR runs are dependency-free, trivially auditable, and self-inverse
(scrubbing backward through a trace applies the same deltas).
**Revisit if**: trace sizes hurt → entropy-code *around* the same records
(container change, not kernel change).

## D018 — input record v1: 10 bytes, sampled actions, sticky taps (M1)

**Context**: the sim must consume identical input live and replayed (D014);
raw event streams are OS-timing-dependent.
**Decision**: per sim frame, one frozen 10-byte record (u32 action down-bits
in definition order, i16 mouse x/y internal px, u8 button bits, i8 wheel
steps). cm.input.apply() is the only path into sim-visible input state,
which lives in the `cm.input` named buffer (cur+prev, so pressed/released
edges are snapshot-consistent). Live sampling adds "sticky tap": a
press+release inside one sample window still sets the bit for one frame.
**Why**: record/replay symmetry by construction; edges survive restore;
sub-frame taps never vanish (feel pillar).
**Revisit when**: text input lands (M2 console) → additive record type in
the container, not a change to record v1; gamepad → new bits/axes likewise.

## D019 — snapshot/trace containers: CSNP/CTRC tagged chunks (M1)

**Context**: D012/D014 need concrete file formats with room to grow.
**Decision**: one chunk grammar (cm/chunk.lua): magic + version-stamped
tagged chunks, unknown tags skipped, truncation = loud error. CSNP = CODE
(full bundle) + BUFS (every named buffer) + DOCT. CTRC = HEAD + SNAP +
per-frame FRAM (input record + per-buffer kind 0 delta / 1 full / 2 freed +
doc bytes on change) + code-less KEYF every N (cross-checked on verify) +
EPOC on mid-record reload + TAIL. FRAM v1 lists every buffer every frame
(~20B/buffer overhead) — simple beats clever until sizes hurt.
**Why**: matches stability-contract rule 5 (readers read what they know);
KEYF without CODE because SNAP+EPOCs already pin code (bundle dedup).
**Revisit if**: per-frame buffer listing dominates trace size (then: a
set-unchanged flag byte), or long sessions need streaming writes (recorder
currently buffers in memory and writes once at stop).

## D020 — easing curves are first-class and name-addressable (human call, 2026-06-10)

**Context**: satisfying interactions are a pillar; easing should be
available everywhere rather than ad-hoc lerps — and "everywhere" includes
sim state, which cannot hold functions.
**Decision**: cm.ease ships the standard family (31 curves: linear +
quad/cubic/quart/quint/sine/expo/circ/back/elastic/bounce × in/out/inout)
as pure deterministic functions over cm.math (which grew exp2 for
expo/elastic). Curves are addressable by NAME via a registry — doc knobs,
timelines and tweens store the name; `cm.ease.register` lets game code add
curves, and that code travels in bundles (D012), so named curves replay
exactly. Registered curves are endpoint-pinned (f(≤0)=0, f(≥1)=1 exactly).
Engine systems that take a duration accept an easing name wherever it makes
sense (UI animation M2, camera/feel knobs M3, tweens when they land).
**Why**: feel pillar; by-name is the only serialization-safe plug point.
**Snapshot story**: names in doc/buffers + registering code in bundles.
**Revisit if**: curve *parameters* (custom back overshoot, elastic period)
become knobs → parametric registrations (`register("back:2.5", …)`) or a
small curve-descriptor table in the doc tree.

## D021 — engine UI is immediate-mode with dev-side state only (M2)

**Context**: pillar 5 demands panels that scale to a Godot-class inspector;
the engine is hot-reload-first and deterministic-first, so a retained
widget tree would fight both (lifecycle across reloads; UI state leaking
into snapshots).
**Decision**: cm.ui is an immediate-mode core: widgets are per-frame calls;
the only retained state is a per-id table keyed by hierarchical id paths,
living on the module (survives hot reload, resets on VM reboot, never
snapshot). Interaction = classic hot/active/focus with one-frame capture
latency; the game receives only events the UI didn't capture, and
up-events always pass (no stuck keys). Iron rule: cm.ui never touches
buffers/doc/PRNG. ` (console) and F3 (perf) are engine-reserved keys until
M4 play-mode lockdown. **Inspector review gate (PLAN risk list) passed**
via projects/uigallery, an inspector-shaped dogfood: searchable +
virtualized + selectable lists, collapsing sections, drag numbers,
sliders, checkboxes, text fields all compose; identified gaps — enum
dropdown, color field, multi-select, tooltips, drag-reorder — are
additive widgets, not architecture.
**Snapshot story**: none by construction; what a widget edits (doc knobs)
is the caller's write and the caller's snapshot story.
**Revisit if**: M4 docking/z-order outgrows draw-order hover resolution
(then: explicit z-ordered panel registry feeding the same hover model), or
per-frame Lua garbage from UI shows in the perf panel (then: rect/id
caching inside cm.ui, API unchanged).

## D022 — console evals are recorded sim inputs (EVAL records, M2)

**Context**: the console REPL pokes sim state mid-session; D014 traces
must stay an oracle. Deltas alone would keep *replay* correct but verify
(re-sim) would diverge at the first poke — and a knob-tuning session is
exactly what we want to record and share.
**Decision**: cm.repl is the single eval path: submits queue, the queue
drains at the START of the next sim frame (before input applies), and the
recorder writes drained commands as EVAL v1 chunks before that frame's
FRAM. Verify re-executes them via the same cm.repl.exec at the same point.
Replay-without-re-sim ignores EVALs (their effects are in the deltas). A
contained game error stops an active recording so the trace stays valid up
to the last good frame. Golden: tests/traces/evalfix.ctrace (doc poke,
buffer creation, an erroring command), tamper-tested.
**Snapshot story**: commands are data in the trace; the code they call
travels in bundles (D012). Caveat (documented in cm/repl.lua): repl env
variables assigned before recording starts don't travel — keep
trace-relevant state in the doc tree.
**Revisit if**: games want player-facing text entry in the *sim* (then:
the additive text input record type from D018's note — distinct from this,
which is dev-console only), or eval bursts bloat traces (unlikely; they're
strings).

## D023 — game errors pause, never kill (M2)

**Context**: M2 exit criterion "Lua errors never kill the session"; the
M0 magenta screen threw away the session's visual context and the C
parachute rebooted the whole VM for any game typo.
**Decision**: cm.main guards require/init/step/draw in live sessions. On
error: traceback to the log, sim paused (no stepping, no game.draw),
recording stopped, console auto-opens with a banner; the REPL drains
immediately while paused so the wreckage is inspectable. Resume = any
successful hot reload (re-runs reload-idempotent init); boot failures
retry the entry require each poll. Capped/verify runs (`--frames`,
`--verify`) keep exit-on-error fail-fast semantics — CI must die loudly.
The C parachute remains for engine bugs only.
**Snapshot story**: pausing touches no sim state; a half-mutated frame
from the failed step stays as-is for inspection and is never recorded.
**Revisit if**: pause-the-world proves wrong for some games (then: a
project opt-in to keep stepping other systems), or M5's ring trace wants
the error frame captured for time-machine autopsy (then: record the
half-frame behind a marker chunk).


## D024 — tilemaps are self-describing named buffers (M3)

**Context**: M3 needs a tile world that is sim state (snapshot/trace/
reboot-proof), renders through the bulk quad path, and that M4's editor
and inspector can later open without side-channel metadata.
**Decision**: cm.tilemap stores `w/h/tile-size` as a 16-byte header in
the buffer itself, u16 ids after; `new` adopts a same-shape buffer
without touching cells (reload-idempotent init) and rebuilds on shape
change; `open` adopts from the header alone. Tile *classes* (solid /
one-way) and looks are a code-side table — meaning travels in code
bundles (D012), bytes in the buffer. The mover is an axis-separated
boundary-scanning sweep (no tunneling, no epsilons: half-open rects +
exact floor/ceil); one-ways collide only on row entry from at-or-above,
with a `drop` opt for down+jump. OOB = side/bottom walls, open sky.
Pure Lua / pure IEEE today; a hot map would migrate down as a versioned
kernel (`tile_move@1`) per the numpy model, semantics frozen by then.
**Snapshot story**: the buffer is everything; wrapper objects are
rebuilt glue. The sandbox builds its map at level.lua chunk top-level
(clear + refill), so editing the level hot-reloads it — and a bundle
restore re-executes the same build only when the bundle's level code
actually differs (hash-gated), never stomping restored cells. M4's map
painting will retire code-built maps (the build becomes a reset action).
**Revisit if**: maps want layers/flags per cell (then: a header version
bump + documented cell format v2, additive), or Lua collision shows in
cm.perf under real load (then: the versioned-kernel path).

## D025 — the demo is sim input: attract mode + --eval (M3)

**Context**: goldens and montages need interesting *input* in headless
runs, but the sim consumes only input records (D014) and the agent
can't press keys. Scripted input must replay byte-exact and survive the
golden contract forever.
**Decision**: the sandbox ships an attract mode — action states as a
pure function of (frame - doc.demo_t0) over a literal timeline table in
demo.lua. No module state, no wall clock: edges derive from f(rel) vs
f(rel-1), so it's deterministic by construction, travels in code
bundles, and any real move/jump/grab press hands control back. It's
enabled by `game.demo(1)` — normally typed in the console, and in
headless runs injected by the new cm.main `--eval CODE` flag, which
queues the line through cm.repl at boot so it drains at sim frame 1 and
records as a D022 EVAL chunk. The platformer golden is exactly that:
cold boot + one EVAL + 1400 frames of scripted play. Choreography is
calibrated against default doc.knobs; retuning movement knobs means
re-choreographing the demo (goldens are unaffected — they replay the
bundled code and knobs they were recorded with).
**Snapshot story**: demo on/off + anchor live in the doc tree; the
script is code. EVAL records carry the activation into traces.
**Revisit if**: more cartridges want attract scripts (then: a cm.demo
helper for timeline tables), or choreography maintenance hurts (then:
waypoint-seeking driver reading sim state — still deterministic, but it
needs a careful story for mid-trace restores before it's allowed).

## D026 — the editor is a repl client (M4)

**Context**: M4's editor must mutate sim state (paint cells, reset the
map) under the D014 trace contract: a recording made while editing has
to verify byte-exact. The editor's own chrome is dev-side by D021, and
D022 already made console evals recorded sim inputs.
**Decision**: cm.editor owns no sim state and never writes any
directly. Every edit is a command string submitted through cm.repl —
`cm.tilemap.poke("map",x,y,id)` per painted cell (a new by-name static,
the eval-able edit unit), the cartridge's `reset_eval` for the reset
button — so edits drain at frame start, record as EVAL chunks, and
verify re-executes them: an editing session IS a console session.
Cartridges expose their editable surface with `cm.editor.attach(fn)`;
the getter returns {tm, atlas, camx/camy, colliders(), save,
reset_eval} fresh each frame and must only read. F1 toggles editor/play
(F1 joins ` and F3 as engine-reserved); `editor = false` in project.lua
is the play-mode lockdown for shipped zips — it disables all three dev
toggles (contained-error banners still open the console
programmatically). Map persistence: save writes the raw self-describing
buffer bytes to map.dat next to project.lua (a pure read, called
directly); load is boot-time-only by rule, because file bytes are not
sim input and a live load would not replay. The sandbox map is no
longer code-built: any existing buffer is adopted as-is (painting
survives reloads, reboots and restores), an empty boot seeds from
map.dat or the procedural build, which lives on as game.level.reset().
**Why**: zero new trace machinery; determinism of editing falls out of
D022 instead of needing an editor-specific record type. The editpaint
golden pins it: painted cells steer the attract demo, byte-exact.
**Snapshot story**: edits travel as EVALs; editor chrome has none
(D021); map.dat only feeds boot state, which the starting snapshot
captures.
**Revisit if**: bulk tools (rect fill, stamps) bloat eval streams
(then: a batched `poke_run` primitive, still a string), shared-session
editing wants mouse-as-sim-input (then: the D018 extension path), or
M10 packaging needs per-surface lockdown granularity instead of one
flag.

## D027 — the inspector is a state-tree repl client (M4)

**Context**: M4 wants "entity list + inspector (live edit)" under the
same trace contract as painting (D026). The engine deliberately has no
entity class: ALL sim state is named buffers + the doc tree (D005), so
an inspector over exactly those two surfaces IS the entity list — a
crate is bytes in `sandbox.props`, a feel knob is `doc.knobs.move.run`.
**Decision**: cm.inspect (a cm.editor panel, toolbar toggle) renders a
searchable tree of the doc tree and every named buffer. It reads sim
state directly each frame and writes ONLY by submitting command strings
through cm.repl: `doc.knobs.move.run = 142.0` (drag numbers /
checkboxes; literals preserve numeric subtype — floats keep a `.0`
because the canon serializer tags integers and floats differently),
`cm.state.buf_poke(name,kind,off,v)` (new by-name static, the generic
sibling of cm.tilemap.poke; buffers expand to typed u8..f64 lens views
with drag-editable cells), and `pal.buf_free(name)` (the free button =
the manual cleanup for reload-orphaned buffer husks PLAN promises;
hidden for engine `cm.*` buffers). Strings are read-only v0. Drag speed
scales ~1% of magnitude per pixel; no sliders yet — bounded sliders
want real range metadata, which arrives with cartridge-supplied
surfaces (prop-defs era), not heuristics that would cage values.
cm.ui grew `opts.rect` (explicit widget placement) so editors work
inside virtualized list rows — a D021 anticipated additive gap.
**Why**: zero new trace machinery, again: a tuning session records as
EVAL chunks and verifies byte-exact (inspectpoke golden pins all three
command shapes). And "entities" fall out of the state model instead of
becoming a parallel concept; named per-field views can layer on later
without architecture.
**Snapshot story**: edits travel as EVALs; panel chrome (expansion,
lens choices, search) is dev-side per D021 and never recorded.
**Revisit if**: the tuning pass wants sliders/ranges (then: knob
metadata on the editor attach surface, additive), buffers want named
field views (then: cartridge descriptors, same surface), eval echo
spam from long drags grates (then: a quiet submit variant in cm.repl),
or string/new-key/delete editing is missed (widgets, not architecture).

## D028 — tuned knobs persist as canonical doc bytes (M4)

**Context**: the doc tree dies with the Lua heap on a VM reboot
(buffers survive C-side), so a parachute reboot reverted feel tuning to
code defaults; tuning should also travel inside a shared project zip.
map.dat (D026) set the file pattern.
**Decision**: knobs.dat next to project.lua holds
`cm.state.canon(doc.knobs)` — the frozen D016 encoding, reused as a
file format. The cartridge owns it (sandbox: `game.save_knobs()`,
called by the editor save button alongside the map save). Load is
boot-time-only and only when `doc.knobs` is nil — a live doc always
wins, so hot reloads and snapshot restores never re-read the file; the
defaults merge then fills any knobs the file predates. A corrupt file
logs and falls back to defaults.
**Why**: canon already round-trips values and numeric subtypes exactly;
boot-seed-only keeps the D026 iron rule (file bytes are not sim input —
they only feed boot state, which starting snapshots capture).
**Snapshot story**: knobs stay ordinary doc state; the file never
participates after boot.
**Revisit if**: more doc subtrees want per-project persistence (then: a
generalized cm.state.persist helper instead of cartridge copies), or
per-user tuning needs to split from per-project shipping values.

## D029 — the jump is authored as a curve, not raw physics (M4, human ask)

**Context**: the human's tuning session wants finer jump-feel handles
than the raw `jump` impulse + `gravity` pair, which couple height and
duration (change one, both move). The classic parametrization ("build a
better jump") authors height and timing directly.
**Decision**: sandbox knobs.move drops `jump`/`gravity` for five
orthogonal handles: `jump_h` (apex height, px) and `apex_t` (time to
apex, **frames**) derive rise gravity and the takeoff impulse each step
— `g = 2*h*3600/t²`, `v0 = 2*h*60/t`, integer-ratio math so the stock
56 px / 24 f reproduces the retired 280/700 pair **bit-exactly**
(verified: the demo tour PNG-compares byte-identical through the
finale); `fall_mul` scales gravity while falling; `hang_speed`/
`hang_mul` define an apex hang window (airborne, |vy| <= hang_speed,
non-dive) multiplying on top — floaty peaks and snappy drops without
touching the rise. Dives keep `dive.grav` over the same base curve;
`dive.boost_max` (stock 900 ≈ the old unbounded growth) caps steering
while boosted (the cap engaging was verified divergent before the
boostcap golden was recorded). Props get their own
`prop.gravity`/`prop.fall_max` — world gravity for objects, feel curve
for the player, so tuning the jump never floats the crates. The
defaults merge in game.init now also **prunes retired keys** inside
groups KNOBS owns (renames must not linger as dead inspector rows;
custom top-level groups stay untouched). apex_t is guarded against
zero (no NaN positions from a dragged-to-zero knob).
**Why**: orthogonal handles are what live tuning needs; exact-ratio
defaults keep the calibrated demo choreography (D025) valid without
re-choreographing; frames are already the codebase's feel unit
(coyote/buffer).
**Snapshot story**: knobs remain ordinary doc state (D028 persists
them); goldens jumpfeel + boostcap pin the new paths under trace.
**Revisit if**: other cartridges want the curve (then: a cm-level
jump-curve helper), or the hang window wants asymmetry (rise-side vs
fall-side speeds — additive knobs).

## D030 — feel assists are cartridge policy over engine mechanism (M4)

**Context**: the human asked for mantle leniency (a near-miss at a
platform lip should land on top). The tilemap mover is deliberately
exact and epsilon-free (D024) and its semantics are golden-pinned —
assists must not soften the engine's collision truth.
**Decision**: assists live in the CONTROLLER, not the mover. The
sandbox player's mantle (knobs.move.mantle px, stock 4): after the
exact move, a descending player whose feet are within the window below
a standable top it overlaps — or is flush against, on a side bonk —
repositions itself onto the lip and synthesizes hit.down, so the
normal touchdown logic (squash, dive flop, boost evaporation, charge
restore) runs unchanged. One-way tops count (the assist deliberately
bypasses the row-entry rule); never while rising or dropping through.
The pattern generalizes: future assists (step-up, corner shave) are
cartridge code reading the map through existing primitives.
**Why**: the mover stays a frozen, trustworthy mechanism; feel policy
stays hot-tunable cartridge data/code that travels in bundles. The
choreography work surfaced the structural caveat worth recording: a
flush rise against a wall gets no mantle (no overlap, no side-bonk
motion), so scripted wall mounts hold INTO the face — blocked below
the lip, drifting over it — or stack a double jump for clearance.
**Snapshot story**: none beyond the knob (doc tree); the assist is
pure step logic. The mantle golden + platformer_locked pin it.
**Revisit if**: a second cartridge wants the same assist (then: a
shared cm-level helper over the tilemap API, still controller-side),
or assists want engine-side queries the API lacks (add read-only
queries, never mover behavior).

## D031 — prop spawning is an eval: the palette is cartridge commands (M4)

**Context**: M4's last bullet, the prop spawn palette. Spawning mutates
sim state, so it falls under the same trace contract as painting
(D026) and inspector writes (D027): an editing session that drops
crates must record and verify byte-exact. The engine has no entity
concept (D005/D027) — what a "prop" is belongs to the cartridge.
**Decision**: the editor attach surface gains an optional `props` list:
`{ name, icon = {u,v,w,h} (atlas sub-rect for the swatch), spawn =
"game.props.spawn(%d,%d)", erase = "game.props.despawn_at(%d,%d)" }`.
Entries join the swatch strip after the tiles; while one holds the
brush, LMB/RMB press edges (no drag machine-gun) format the entry's
eval with the floored world mouse and submit it through cm.repl — the
editor stays a repl client with a mouse, and what the evals DO is
entirely cartridge code. Sandbox side: `game.props.spawn(x,y)` (crate
centered on the click, capacity-bounded by the buffer's actual size),
`game.props.despawn_at(x,y)` (topmost free crate under the point;
held crates refuse — resolved at EXECUTION time inside the sim frame,
so the eval never embeds a stale index). Despawn keeps the prop list
dense by swapping the last slot into the hole; since that can move the
held crate's index, player.step self-heals its carry by re-finding the
held flag (only the player grabs). props.init now adopts an existing
buffer at ITS size (init re-runs after restores/reloads and pal.buf
errors on mismatch); fresh boots allocate 48 slots.
**Why**: zero new trace machinery for the third time — the propspawn
golden pins spawn, despawn_at (hit and miss), the held refusal and the
swap/self-heal. Eval-format entries are deliberately the thinnest
possible palette contract; richer prop definitions (doc-tree prop
defs, per-entry params) can grow on the same surface without touching
the editor's trust model.
**Snapshot story**: spawns/despawns travel as EVALs; palette selection
is dev-side chrome (D021) and never recorded.
**Revisit if**: cartridges want parameterized spawns (then: entries
carry arg widgets, still formatting one eval), multiple prop kinds
arrive (doc-tree prop defs feeding the entry list), or drag-stamping
wants batched evals (D026's poke_run path).

## D032 — the ring IS the recorder: always-on segment ring trace (M5)

**Context**: M5's time machine needs the last N seconds of play always
available for scrubbing/rewind/export, and D019's revisit trigger has
fired conceptually: the recorder buffers a whole session in memory and
writes once at stop — grow-forever is exactly what an always-on
recorder cannot do.
**Decision**: cm.trace keeps recording-session state as a ring of
**segments**. A segment = (a) a code-less keyframe captured from the
delta mirrors (= state after the previous segment's last frame), (b) a
reference snapshot of the loaded bundle (cm.modules() — Lua strings
are shared, so this is pointers, not copies), and (c) the same encoded
chunk bytes the CTRC v1 recorder already produces (EVAL/FRAM/EPOC, in
order), eagerly closed at `kf` frames (default 60 = 1 s). The ring is
ON in every live session (anything but --verify) and evicts whole
segments older than `seconds` (default 30). On top of it:
- **--record / record_start is a pin**, not a second recorder: it
  forces a segment boundary and exempts segments from eviction;
  record_stop writes HEAD + SNAP (first pinned keyframe + its bundle)
  + the pinned segments' chunks with KEYF at each boundary + TAIL —
  byte-identical CTRC v1 output for the same session (validated by
  re-recording the kitcheck golden and diffing).
- **Export-the-past** ("save what just happened") is the same
  concatenation over whatever the ring still holds — the synthesized
  SNAP makes it a normal trace the verifier accepts.
- **Scrub access**: ring_state_at(f) = nearest keyframe + forward
  XOR-delta walk, O(kf) and never executes game code. delta1 being
  XOR (involutive) leaves bidirectional stepping open to the scrubber
  as an optimization; kind-1 (create/resize) records are the one-way
  barriers.
- **Rewind** = write the scrubbed state into the live buffers/doc
  (state.restore's surgery), restore the bundle as of that frame
  (segment bundle + EPOCs up to it), truncate the ring after it, reset
  the mirrors; the caller re-runs game.init() (same contract as every
  other restore). An active file recording is stopped first (a linear
  trace cannot contain a rewind).
- **Out-of-band restores** (snapshot load) reset the ring; the
  backstop is automatic — record_frame watches the cm.sim frame
  counter and a non-monotonic step resets the ring with a log line.
  Out-of-band *mutation* (error-pause pokes, re-init after reload)
  needs no handling: deltas are computed against the mirrors, so the
  next recorded frame absorbs it (the ring stays scrubbable; only
  re-sim *verify* of an exported window containing such a frame would
  diverge, which is true today for any non-eval poke).
**Why**: one recorder, one byte format, one oracle. The ring replaces
the grow-forever buffering for the always-on case at ~0.5 MB for 30 s
of sandbox state (17 KB × 30 keyframes + sparse deltas); the marquee
payoff is scrubbing backward from a crash — the error pause already
freezes the sim, and the ring holds how it got there.
**Snapshot story**: ring bookkeeping lives in the Lua heap plus
anonymous mirror buffers — never in named buffers or the doc tree, so
recording never perturbs the sim and ring config (trace.ring.seconds/
kf, console-tunable) never enters traces. The ring itself dies with
the VM (parachute reboot = fresh ring), which is correct: its contents
described a code epoch that just crashed.
**Revisit if**: pinned recordings of long sessions hurt memory (then:
pal.x_append_file and stream evicted-but-pinned segments to disk), big
tilemaps make keyframes dominate (then: keyframe spacing per ring
position, or delta'd keyframes), or scrubber drag wants faster access
than O(kf) re-decode (then: cached mirror walk using XOR
reversibility).

## D033 — rename pettan2d → cosmic2d (pre-1.0 break clause; human call, 2026-06-27)

**Context**: the project gained a flagship game identity (**cosmic**, D034)
and the human asked to rename pettan2d → cosmic2d and every pettan-derived
token. D015 freezes the PAL base semantics — including the trace/snapshot
container magic — at 1.0, but **explicitly allows pre-1.0 breaks** with a
DECISIONS entry and a deliberate golden regeneration. We are pre-1.0.
**Decision**: total rename in one mechanical pass. Product/docs, binary
(`bin/cosmic`), the Lua namespace `pt.*` → `cm.*` (the `engine/cm/` dir, the
`cm` global, `cm_tick`), the trace/snapshot container magic `PTRC` → **CTRC**
/ `PSNP` → **CSNP**, the trace extension `.ptrace` → **`.ctrace`**, env vars
(`COSMIC_LVP_ICD`), flake outputs. Word-boundary-safe seds; verified: build
clean, selftest **22308 checks PASS**, and a record → verify round-trip on the
new CTRC magic (exit 0). The committed golden suite (old magic + the
about-to-be-replaced movement choreography, D035) is **intentionally left
stale** and gets re-cut at M6/M7 against real assets — this *is* the
"deliberately regenerate goldens" step the clause requires; sinking effort into
keeping soon-deleted choreography green would be waste. selftest (engine
invariants) remains the live net meanwhile.
**Why**: this is the engine for the cosmic game now; aligning identity before
the 1.0 freeze is the cheap moment. The freeze henceforth governs cosmic's
**CTRC/CSNP** magic, which become the eternal tokens.
**Snapshot story**: unchanged — only the container magic strings differ.
**Revisit**: the freeze itself is unchanged. The namespace prefix `cm` and the
`.ctrace` extension are *choices* (one sed to change) — change them now if you
dislike them, never after 1.0.

## D034 — the stock game is cosmic, an antagonist-mecha-girl spin-off (human call, 2026-06-27)

**Context**: the human now has a specific game to make and wants the engine
**built around** its art and gameplay (PLAN "What this is", GAME.md).
**Decision**: the flagship / stock game is **cosmic** — single-player 2D
action-exploration, cute/cozy with a touch of cosmic dread, starring the
**antagonist mecha girl** of the `cosmic` universe as a spin-off / prequel
(chosen over playing cosmic's protagonist so that project's canon stays free,
and because the mechanical moveset fits a mecha character). MapleStory-style
self-contained maps + portals; power-fantasy slice-through-hordes spectacle; a
Garry's-Mod-flavored physics sandbox; Wadanohara-like pixel art. The game's
cozy **hub** replaces the generic platformer sandbox as the stock cartridge and
the dev testbed. Full design in **GAME.md**. The proposed **fiction spine**
(the mecha girl's reality-bending tech unifies movement + sandbox + dread;
finishing an area's questlines "stabilizes its reality" → unlocks prop-spawning
there) is a **proposal pending the human** (GAME.md §11).
**Why**: a concrete game focuses the roadmap and dogfoods the engine's
batteries; villain-origin keeps cosmic's own (longer-cycle) story untouched.
**Snapshot story**: n/a (design-level). Each game system documents its own as
it lands.
**Revisit**: the human owns the fiction. Identity (mecha-girl spin-off) is
ratified; the spine, progression, area list and boss design are open (GAME.md
§11) and may reshape the later milestones.

## D035 — the MapleStory moveset is cartridge controller policy (human spec, 2026-06-27)

**Context**: cosmic is built around an unconventional MapleStory-derived moveset
(GAME.md §4) that wholesale replaces the old M3/M4 controller (variable-height
jump + air-dive). Movement is the make-or-break feel system.
**Decision**: the new controller — walk, jump (fixed ~1 CH, auto-repeat),
flash-jump (repeatable upright dash, sonic-boom ring), up-jump (vertical,
locks out flash-jump for the airtime), hop + flutter (once-per-airtime diagonal
boost; holding E hovers 10 s then arms a 10 s hop cooldown), grapple (pull to a
platform above, prefers targets beyond ½ screen, 3 s cooldown, once per
airtime), teleport (blink ~5 CW, kills momentum, persistent A↔B mode that
changes appearance, max 2/s), and hold-to-slice continuous attack — is built as
**pure cartridge controller policy** in the hub project's player module, with
**no PAL/engine change**. It rides the existing tilemap mover + one-way
platforms (D024) and reads the map through existing primitives for targeting
(the **D030 pattern**: feel/assists/queries are controller-side, the mover
stays a frozen mechanism). Every value is a live knob under `doc.knobs.move`
(persisted D028, inspector-tunable). Per-airtime flags (hop used, up-jump→FJ
lock, grapple used) reset on landing; the teleport **mode bit**, **hop
cooldown** and **grapple cooldown** persist in a player named buffer / doc
(mode resets on map change). This **supersedes the specifics of D029** (the new
jump is a fixed one-CH height, not the authored variable-height curve) while
reusing the **patterns** of D030 (assists as policy) and D025 (the attract demo
is sim input — re-choreographed against the new moveset).
**Why**: the frozen engine mover stays untouched and trustworthy; all feel is
hot-tunable cartridge data/code that travels in bundles; determinism is
unchanged by construction — integer-frame timers, pure-IEEE tilemap scans,
engine PRNG only, no wall clock, no libm.
**Snapshot story**: knobs are doc state (D028); per-move timers/flags/mode are
ordinary sim state in a player buffer/doc. Goldens re-cut at M7.
**Revisit**: if a move needs a map query the tilemap API lacks (add read-only
queries, never mover behavior); if other cartridges want the moveset (a
cm-level controller helper); exact knob values are M7 calibration + human feel
sign-off. Units are CW/CH (GAME.md §4) so sprite/zoom recalibration is safe.

**M7 implementation + first feel refinements (2026-06-28).** Built in
`projects/sandbox/player.lua` (128-byte player buffer; selftest 22312, record→
verify byte-exact). The human's first live pass on win11 ("feels approximately
right") adjusted three spec points — GAME.md §4 updated to match:
- **Flash jump is ONCE per airtime** (was "repeatable, the staple"): infinite
  flash trivialized traversal; now it re-arms on landing, so the staple is
  jump→flash→land→repeat (still flash-heavy, but you chain the rest of the kit).
- **Teleport ALTERNATES forward/back** (was "forward"): each blink flips the
  A↔B phase, so direction alternates with it — mode A forward/solid, B back/
  phase. Makes the phase mode a movement mechanic, not just appearance.
- **Gravity gives ~1.5× airtime at the SAME heights** (floatier): `jump_apex_t`
  ×1.5 (airtime scales with apex_t, height stays `jump_h`); the fixed-velocity
  impulses (`upjump_v`/`hop_vy`/`fj_vy`) ×2/3 to hold their heights under the
  weaker gravity (height ∝ v²/g, g→4/9).
Implementation choices: grapple is on **`q`** (the spec's `` ` `` is the dev
console); player **grab/throw removed** (E is hop; the sandbox tool returns at
M-physics); a **temporary cooldown HUD** (main.lua `draw_cd_hud`, live-play
only) visualizes the timers for testing — to be removed once the editor can
live-visualize ability/emitter state. The **fancy slice VFX** (orbiting energy
blades + trails) is **deferred** to after the editor/particle-emitter work so it
can be authored live. Final knob values + golden re-cut still await the real art
+ feel sign-off.

**Feel pass 2 (2026-06-28).** Two more refinements from live testing (GAME.md §4
updated):
- **Flutter cooldown only on a real flutter.** The cd arming was too eager — any
  hold > 1 frame counted as a flutter, so a normal tap armed the 10 s cd. Now a
  `flutter_grace` window (10 airborne frames) must pass before the hover (and
  thus the cd) engages; a tap under that is a clean hop with no cd. (Also fixed:
  a stale `flutter_t` let a later teleport re-arm the cd — `flutter_t` now resets
  on flutter end, which had made the cd feel "permanent.")
- **Grapple extends, then reels.** Was an instant reel that slingshot you too
  high on short hops. Now the hook **extends** to the target at `grapple_extend`
  (~1 screenful/s) while you stay under gravity; only on connect does it reel —
  from your current velocity. So a jump *into* a grapple has fallen back to
  downward velocity by connect-time, which the reel must reverse first, damping
  the launch. The landing branch must NOT cancel a grapple (the extend phase is
  grounded for a grapple-from-standing; the reel lifts you off when it connects).

**Feel pass 3 (2026-06-28).**
- **Jump airtime ≈ ⅔ s** (`jump_apex_t` 22.5→21.3; airtime ≈ apex_t·(1+1/√fall_mul)
  frames, height stays `jump_h`).
- **Up-jump and hop are now HEIGHT-based** (`upjump_h`, `hop_h`): the impulse
  velocity is derived from the live gravity each step (`v=√(2·g·h)`), so retuning
  gravity keeps their heights automatically — no more re-deriving ×k velocity
  knobs every gravity change (jump was already height-authored, D029).
- **Grapple launch dampened.** The reel now stops `grapple_stop_ch` CH (≈2) short
  of the platform so the residual coasts up under gravity; a `grapple_min_t` floor
  keeps very-short grapples a small launch (else stopping short would no-op them).
  But the launch is dominated by the post-reel coast ≈ `grapple_vmax`²/2g, so vmax
  is the real lever — lowered 300→220 (accel 720 unchanged, the "accel feels fine"
  ask) to cut a medium grapple's overshoot from ~5.6 CH to ~2.5 CH. **Starting a
  grapple zeroes horizontal momentum**, and **arrows + teleport are locked out for
  the whole grapple** (extend and reel) until it's cancelled — it's a committed
  vertical move (hop was already gated; jump still cancels).

**Feel pass 4 (2026-06-28).**
- **Flutter is a rhythmic hold, not a glide.** The old flutter was a continuous
  slow-fall (`flutter_fall`/`flutter_decel`) that engaged after a frame-count
  grace. Reworked per the human: it now **only begins once you've started FALLING**
  (past the hop's apex) while still holding E — so the "must be falling" gate
  replaces `flutter_grace` as the tap guard (a hop released before the fall is a
  clean hop, no cd). Instead of a glide it delivers a **rhythmic mini-hop every
  `flutter_interval` frames, `flutter_boosts` times** (≈ a few s): each a
  height-based up-kick `flutter_h` (`v=√(2·g·h)`, like hop/up-jump — survives
  gravity retunes) sized to **roughly HOLD altitude** over the beat, plus a small
  forward nudge `flutter_vx` (< `hop_vx`, the "diagonal like the hop but smaller").
  Normal gravity acts between beats; the cd (`hop_cd`) arms on release / timeout /
  land. Knobs replace `flutter_grace`/`flutter_max`/`flutter_fall`/`flutter_decel`
  with `flutter_interval`/`flutter_boosts`/`flutter_h`/`flutter_vx`. Verified: the
  demo's flutter holds y≈480 (no net drift) while drifting forward; KITCHECK +
  TOUR still record→verify byte-exact. Default magnitudes are the human's feel call.
  **Tuned same day (round 4b):** the human wanted the boosts way smaller, upward
  only, more frequent — so `flutter_h` 45→**11** (¼: vy peak ~169→~84), `flutter_vx`
  70→**0** (the boost is straight up), and `flutter_interval` 60→**30** (2/s).
  Verified on TOUR: vy flips every 30f at ~−84, y bobs ~11px holding altitude
  (gentle ~4px/s sink). **Round 4c (same day):** 4b also DUMPED horizontal momentum
  at hover-start — wrong: the human wants a flash-jump's momentum to **carry
  through** the hover (and a held dir to ADD to it). Removed the dump; the flutter
  now applies **no air drag** to horizontal while hovering (momentum preserved),
  only the vertical boosts — holding a dir still accelerates via air control, and
  `flutter_vx`=0 leaves horizontal completely untouched on the beat. Verified: x
  drifts at the carried ~120 through the TOUR hover; determinism byte-exact.
  **Round 4d (same day):** conserving ALL momentum launched you too far. Settled
  on the middle: roll back to the 4b CANCEL (vx=0 dump at hover-start + air drag
  restored, so a flash-jump no longer coasts through) BUT make each boost a slight
  up-FORWARD diagonal — `flutter_vx` 0→**30** (« the ~84 vertical kick → ~20° from
  vertical, <45°). Net: carried momentum is killed, then the small diagonal boosts
  build a gentle forward drift that air drag holds to ~20–34px/s (vs 4c's full ~120).
  Verified on TOUR: x drifts ~gently, vy still flips every 30f at ~−84, y holds.
  **Feel-APPROVED** (2026-06-28, "this feels good, we'll go with this"). With the
  knobs settled, the KITCHECK flutter sub-test was **re-choreographed** to match
  (it had drifted to an airborne jump→flash-jump under the changed arcs): a `{44}`
  settle lands the player first so the test's jump+hop fires from a fresh grounded
  airtime, and the hold is `{130}` so the full 4-boost timeout runs — it now
  triggers, arms hop_cd (~f=590) and blocks the following hop, restoring the
  flutter→cd oracle coverage. KITCHECK + TOUR record→verify byte-exact.

## D036 — viewport model: variable FOV, resize ladder, editor-only UI scale (human ask, 2026-06-27)

**Context**: the human wants (a) an **editor-only UI scale** independent of the
game's pixel scale, (b) a **movable/resizable game render area**, and (c) a
**window-resize ladder** snapping to pixel-perfect multiples — so e.g. a 1080p
window runs the game at 2× in a sub-rect with editor chrome at 1× around it.
Today the PAL renders one fixed internal target integer-scaled to fill the
window (ARCHITECTURE "Rendering"; D006 product decisions).
**Decision (M8)**: generalize the present path. The internal target becomes a
**variable FOV** (the visible game area in internal pixels) capped at the
480×270 reference: below the cap the FOV **crops** (less world visible, sprites
unchanged), at/above the cap the game **integer-upscales**. The window-resize
**ladder** (the human's spec): reference 960×540 = FOV 480×270 at 2× (default;
**borderless when window == screen**); horizontal resize → next whole aspect at
the same vertical res (wider FOV); diagonal resize → next pixel-perfect
resolution, and if chrome is squeezed, **lower the editor UI scale**; 4:3 =
same vertical res, cropped width (720×540 win / 360×270 FOV); 640×360 and
480×360 are the smallest (FOV cropped both ways); FOV maxes at 480×270, beyond
which the game upscales, snapping to **integer multiples by default**. The
**game viewport** is a movable/resizable rect (snaps to pixel-perfect
multiples); **editor UI** draws at its own scale in the leftover space.
**Iron rule**: the sim **never reads window size / FOV / viewport** — FOV is a
render-only camera extent; goldens render at a fixed FOV. Likely a small
**additive** PAL surface (present into a sub-rect at a chosen scale; a separate
UI-scale pass) born `pal.x_*` under the stability contract, documented in the
API table when built.
**Why**: the editor-UX pillar (5) and comfortable dev on the win11 host;
decoupling FOV, UI scale and viewport is what lets one window host the game and
the editor at different scales.
**Snapshot story**: none — viewport / FOV / UI scale are render + dev-side state
(D021 class), never sim, never recorded.
**Revisit**: if variable FOV complicates camera/parallax math (then: keep FOV
fixed and scale-only, the simpler subset), or if fractional scaling is ever
wanted (opt-in; default stays integer).

## D037 — death, the optional economy, and navigation (human spec, 2026-06-27)

**Context**: answering GAME §11's "save model" question, the human specified a
death/respawn + economy + navigation model that realizes the "as forgiving as
you want it to be" pillar economically and threads through M12 (combat) and M13
(world).
**Decision** (design; lands at M12 + M13, GAME.md §8):
- **Death → respawn at the nearest hub** (initially earth + cosmic finale,
  D034/§9); **no progress rollback** (currency, unlocks, quests, secrets
  persist). The save is **persistent + autosaved**. The **walk back** is
  intended gameplay (movement + spectacle make traversal the penalty);
  **opt-out** via **world-map fast-travel** to already-visited maps.
- **Optional economy**: trash enemies drop **currency + farmables** (rolled on
  the engine PRNG → trace-reproducible). Farming is **100% optional** — every
  purchasable is *also* earned via story / side quests; the shop only grants
  things **early**. Two spend lanes: (a) **auxiliary abilities/upgrades** layered
  on the always-available moveset (D035) — radar (reveal missables), extended
  flutter range (reach optional areas), more TBD — a light **opt-out
  metroidvania** gate on *optional* content only; (b) **cheese consumables**
  (HP potions out-regenerating natural regen) to trivialize a boss by choice.
- **Navigation**: a **world map** (visited maps + fast-travel) and a **helper
  arrow** toward the selected quest's objective.
- **Stats & verifiable challenge runs** (later): per-save stat tracking (mobs
  killed, currency farmed, deaths, secrets, time). Determinism makes a recorded
  trace a **byte-exact, provable** challenge run — the D014 trace/regression
  infra doubles as an anti-cheat oracle. A real differentiator and a standing
  reason to keep gameplay a pure function of (input, seed).
**Why**: dual-sourcing (buy OR earn) keeps farming optional and non-punishing;
drops reward the slice-through spectacle; provable runs fall out of determinism
for free.
**Snapshot story**: currency / unlocks / quest flags / stats are ordinary sim
state (doc tree + buffers); the persistent save is a serialized snapshot subset
on the existing infra (D005/D012). Drops use the engine PRNG (D006-class), so
they stay trace-reproducible. Nothing new for the determinism model.
**Revisit if**: the economy ever needs to *punish* (it shouldn't, by design);
fast-travel undermines the intended walk-back (tune its availability); or
verifiable runs need tamper-proofing beyond trace replay (then: sign traces).

## D038 — windows build: pure-Nix mingw cross + cross SDL3 (M6, 2026-06-27)

**Context**: M6 ships the Windows port. D011 anticipated "SDL3 from nixpkgs
(linux) / official prebuilt (windows packaging)". In practice nixpkgs provides a
cross SDL3 (`pkgsCross.mingwW64.sdl3`, the **same 3.4.8** as linux), so the
official-prebuilt path is unnecessary.
**Decision**: build Windows via the flake package `cosmic-windows` using
`pkgsCross.mingwW64` + the nixpkgs cross SDL3 — pure Nix, reproducible, no impure
fetch. Output is self-contained: `cosmic.exe` + `SDL3.dll` + `libmcfgthread`
(the mingw stdenv's DLL symlinks are materialized into real files in a
`postFixup`, since Windows can't follow a /nix/store symlink). The PAL being
**pure SDL3** (file IO via SDL_LoadFile/SaveFile/GlobDirectory/GetPathInfo/
CreateDirectory; time/paths via SDL) meant the only C changes were
`<SDL3/SDL_main.h>` (the Windows entry) and `fixup_cwd()` (self-locate the repo
root via `SDL_GetBasePath` — which also **retires the long-standing
"windowed needs cwd=repo-root" debt on both platforms**). The Makefile gained
overridable `PKG_CONFIG`/`EXE`/`LDFLAGS` (linux build unchanged); the Windows
link is `-mconsole` (so stderr + headless work) + `-static-libgcc`. **Supersedes
D011's "official prebuilt for windows" note.**
**Why**: pure-Nix cross is more reproducible and lower-maintenance than vendoring
a prebuilt, and auto-pins to the same SDL3 as linux. Portability falling out for
near-free validates the small-SDL3-PAL pillar (D004).
**Determinism**: verified byte-exact across the platform boundary — selftest
22308 PASS on `pal windows`; linux↔windows `--verify` both directions PASS; two
independently-recorded sandbox traces are byte-identical. The IEEE-754 /
Lua-5.4 / no-libm discipline (ARCHITECTURE "Determinism") holds cross-platform
as designed, so the golden contract (D015 rule 6) extends to Windows for free.
**Revisit if**: a future PAL primitive isn't covered by SDL3 and needs a
platform `#ifdef` (then: isolate it behind the contract, never leak it to engine
code); or end-user shipping wants a windowed (`-mwindows`, no console) subsystem
build (M15: an additive flag).

## D039 — M8 viewport: the two-target composite realizes D036 (2026-06-28)

**Context**: D036 specified the viewport model (variable FOV, the resize ladder,
an editor-only UI scale, a movable/resizable game viewport) and guessed the
shape would be "a small additive PAL surface (present into a sub-rect at a chosen
scale; a separate UI-scale pass)". M8 had to turn that into a concrete renderer.
The pre-M8 PAL rendered **one** fixed internal target integer-scaled to fill the
window.
**Decision**: the binding constraint is D036's exit criterion — *editor chrome
at 1× around the game at 2×*. The editor must render into a **higher-resolution
surface than the game FOV**, so one target cannot serve both. M8 is therefore a
**two-target composite** (exactly D036's sketch): a **game target** sized to the
variable FOV (`pal.x_fov`, ≤480×270, crops below / integer-upscales above) and a
separate **editor/UI canvas** (`pal.x_ui_target`, ~window/ui_scale). Quads route
per target (`pal.x_target`); `present()` runs a scene pass per target then
composites them into the swapchain (`pal.x_compose`): the game blits to its
viewport rect at an integer game scale, the ui canvas blits over the whole window
at its own integer scale, alpha-over (transparent ui texels show the game). Born
`pal.x_*` (api 4→5, experimental ns; pre-1.0 so still movable). The **resize
ladder** + the editor-vs-play layout live in Lua (`cm.view`): `scale =
max(base, min(⌊W/ref_w⌋, ⌊H/ref_h⌋))`, `FOV = min(ref, ⌊window/scale⌋)` — which
reconciles D036's "widen → wider FOV" with "FOV maxes at 480×270" (widening
widens the cropped FOV up to the cap). The mouse splits into game-space (`x,y`,
the sim + world placement) and ui-canvas-space (`ui_x,ui_y`, the editor chrome).
**Why**: keeps "mechanism in C, policy in Lua" — the PAL moves pixels between
two targets and composites at chosen rects/scales; *where* the viewport sits,
the ladder rungs, the chrome insets and the UI scale are all Lua knobs. One
window can host the game and the editor at independent integer pixel scales,
which is the whole point of D036.
**Iron rule held**: the sim never reads window/FOV/viewport. FOV/compose/ui are
render-only; `cm.view` runs live-only (headless/verify keep the project's fixed
FOV), so the golden suite + record→verify are byte-untouched. Verified:
selftest 22312→22344 (FOV resize incl. readback grow, target-routing isolation,
the ladder rungs, the dual-mouse split); sandbox record→verify byte-exact;
uigallery pixel golden byte-identical (the game-target render is unchanged).
**Snapshot story**: none — viewport / FOV / UI canvas / compose are render +
dev-side state (D021 class), never sim, never recorded (as D036 required).
**Revisit if**: the alpha-over game-blit assumption (game clears opaque) ever
needs a translucent game layer (then a non-blended game blit + blended ui blit);
or fractional UI scaling is wanted (opt-in; default stays integer); or the
movable/resizable viewport (D036) needs the compose rect to be drag-driven
(already expressible via `x_compose`, just not yet wired to a drag handle).

**Revision (2026-06-28, feedback round 4).** Two corrections from live use:
- **ui_scale applies in play mode too, not only the editor.** D036/D039 first
  built the ui canvas only when the editor owned the chrome; in play mode the dev
  panels (options menu / console / perf / scrub) drew on the game target at the
  *game* scale, so changing ui_scale with the editor closed did nothing. Now
  `cm.view.update` **always** allocates the ui canvas at `ui_scale` (the game is
  composed under it — inset in the editor, centered full-window in play), and
  `cm.main` routes the dev panels to it after `editor.frame` regardless of editor
  state. So ui_scale rescales the dev UI live in either mode. (Game-space HUD the
  *cartridge* draws stays on the game target at game scale — correct: it's game
  content, not dev chrome.) Still render-only / live-only — goldens untouched.
- **Options window-size presets are now fill-the-window resolutions** (720×540,
  960×540, 1440×1080, 1920×1080 — a 4:3 + a 16:9 at two heights), each a whole
  multiple of a FOV ≤ the reference so the ladder fills with no letterbox.

## D040 — the asset studio: a sprite/animation editor over render-only assets (M10, human spec 2026-06-28)

**Context**: M10 needs an in-engine sprite/animation editor (GAME.md §10), and
the human pulled it ahead of M9 (audio) because no world content gets built
until assets can be authored in-engine (M10 exit: *the human authors a sprite +
a portrait in the studio*). The brief: palette + color picker + custom palette
slots; no-AA pixel lines/curves/shapes; layers; non-destructive gradient fills
(tweak type/center/phase); brushes incl. a sprite-as-brush; rotate/scale/flip/
copy/paste/undo/redo; an asset browser with previews; then a standardized way to
make + edit animations in the same tool. The human chose the three structural
forks (2026-06-28): a **dedicated full-window studio mode** (over floating
panels / an F1 sub-tab); a **native layered document that bakes to the strip
atlas** (over flat PNG / an indexed-palette doc); and **a solid paint foundation
as the first slice** (over gradients-first / a thin end-to-end slice).
**Decision**: the studio (`cm.studio`) is a **dev/render-class** tool (the D021
family — like `cm.editor`/`cm.console`/`cm.inspect`) over assets that are
**render-only files, not sim state**. The keystone realization: a sprite's
pixels are loaded at boot like a PNG / `map.dat` / a baked font — "file bytes are
not sim input" — so unlike the world editor (`cm.editor`, where the tilemap *is*
sim state and every cell is a recorded EVAL, D022/D026), the studio has **no
determinism tax at all**: it owns no sim state, never records into a trace, never
runs in `--verify`/golden runs, and may use float / `math.random` / libm freely.
The on-disk model is a **native layered `.spr`** (truecolor; layers, palette,
frames, clips, non-destructive gradient fills) over `cm.chunk`'s tagged
container; it **bakes** to `art/<name>.png` — a horizontal strip in the exact
convention the game already draws (`player.lua build_sprite`) — plus
`art/<name>.anim` (clip table as canonical doc bytes). The game consumes the
baked PNG through the unchanged `cm.gfx.texture` path: **zero engine change to
consume**. Decomposition: pure rasterizers `cm.paint` (selftest-covered),
document/format/bake `cm.sprite`, the mode+UI `cm.studio` (full-window on the ui
canvas at `ui_scale`, sim paused, input captured, `F2`), the pure clip evaluator
`cm.anim`. Undo reuses the frozen `pal.buf_delta1` sparse-XOR codec. The full
design is **STUDIO.md**; phased build there (foundation → layers/shapes/transforms
→ gradients → animation → procgen/LUT polish).
**Why**: §1 of every other tool decision here is "is it sim state?" — and for
art the honest answer is no, which collapses the whole problem. No EVAL plumbing,
no golden churn, no replay: the studio is a free creative app, and that freedom
is what lets it be a *good* tool instead of a determinism-constrained one. Native
layered doc (not flat PNG) is forced by the art direction: gradients are the
signature technique (GAME.md §10), and non-destructive gradient fills + layers
need an editable object model PNG can't hold; baking to the existing strip
convention keeps the runtime untouched. Truecolor (not indexed) because gradients
need many colors; an indexed/palette-swap mode is an optional later overlay.
Studio mode (not floating panels) because real authoring — the M10 exit bar —
wants maximum canvas + a real panel layout. Mechanism-in-engine / policy-in-
cartridge for animation (the clip evaluator is pure; the cartridge owns
state→clip + the playhead) mirrors D030/D035 and adds **zero** new sim-state
surface — cosmetic clips recompute from the frame counter, sim-relevant clips
ride the controller's existing named buffer.
**Iron rule held**: the sim never reads asset pixels — they are render-only,
boot-loaded, never snapshotted, never traced. The studio is live/dev-only
(headless/`--verify`/golden runs never instantiate it), so the golden suite +
`record→verify` are byte-untouched; Phase 4's proof is wiring the sandbox player
to a baked studio sprite and showing `record→verify` stays byte-exact (a
render-only asset cannot perturb a trace). The pure `cm.paint` rasterizers are
deterministic by nature and get selftest KATs — insurance, not a determinism
requirement.
**Snapshot story**: none — documents, palettes, undo stacks, tool/canvas state
are all dev-side (D021 class), never sim state, never recorded. Baked assets are
files adopted at boot like `map.dat`/`knobs.dat` (boot-time-only by rule).
**Revisit if**: an asset ever needs to be *generated from sim state at runtime*
(then it's a render target, not an authored asset — different mechanism); or
per-cell PNG compression / a `pal.x_tex_update` in-place upload is wanted for big
canvases (both additive, neither blocks); or indexed-palette authoring is
promoted from optional to a first-class mode.

## D041 — sprite runtime metadata: pivot + slices in a `.meta` sidecar (M10 Phase 5, 2026-06-28)

A sprite needs more than pixels and clips at draw time: a **pivot** (the cell
pixel the game pins to an entity's position — feet on the ground, later a hand on
a weapon) and **named slices** (rectangles the game looks up by name — attach
points, hit/hurt boxes, fx origins). Both live in the editable `.spr` (pivot in
the `HEAD` chunk, slices in a new `SLCE` chunk) and **bake into a third sidecar
beside the `.png`/`.anim`: `<name>.meta`** — the sprite's runtime geometry as
canonical doc bytes (`cm.state.canon`, exactly like `.anim`/`knobs.dat`). The
game reads it via `cm.sprite.load_meta` and queries `cm.sprite.find_slice`. **v1
is per-doc** (one pivot, doc-level slices); **per-frame keys are a documented
follow-up** (when a weapon must track a hand across frames).
**Why**: a separate sidecar keeps `cm.anim` purely about animation and the
flattened `.png` purely about pixels — three small files, each one concern,
each forward-compatibly versioned. The game already loads the baked `.png` +
`.anim`; `.meta` is the same boot-time-or-explicit asset class (D026), so
**consuming the pivot is render-only** — `player.lua` maps the authored pivot
pixel onto the foot point in `draw()`, which is not sim and cannot perturb a
trace (the §1 payoff again; KITCHECK + TOUR `record→verify` stayed byte-exact).
Reusing `cm.chunk` for `SLCE` (skip-tolerant) and `cm.state.canon` for `.meta`
keeps both consistent with the rest of the asset/doc formats. Per-doc-first
mirrors the pivot-granularity call already flagged in STUDIO.md §11: ship the
80% case (a static anchor / a roughly pose-stable hurtbox) and add per-frame
keying only when a real weapon needs it.
**Iron rule held**: render-only, boot-loaded, never sim state, never snapshotted,
never traced — the studio authors it, the game adopts the baked bytes like
`map.dat`. The studio's pivot/slice tools are dev-only (`F2`, gated out of
`--verify`).
**Revisit if**: per-frame pivot/slice keying is needed (extend `.meta` + the
`SLCE`/`HEAD` schema, readers stay back-compatible); or the three sidecars want
folding into one container; or `headless --bake` lands (then `.png`/`.anim`/
`.meta` all become regenerable build product, no longer committed).

## D042 — cosmic2d narrative direction: Vesper's tsundere villain-origin, the shared canyon, the cast (M-content, human call 2026-06-29)

**Context**: M10 (the studio) is feature-complete, so content authoring is
unblocked; the human opened **M-content** with a writing/design pass — first
quests + first maps — plus two new characters to fold in (gemma-san; a bunny-girl
idol) and a mob concept (cosmic creatures). D034 ratified the *identity*
(mecha-girl spin-off) but left the **fiction spine, cast, and area list open**
(GAME.md §11); this fills them in. Reference art + the human's mock board informed
it (`F:\Pictures\cosmic2d-mocks`, `F:\Pictures\oc\{gemma-san,bunny-girl}`); the 3D
universe bible is the canon source (`F:\Documents\cosmic\docs`).
**Decision** (the human's four calls):
1. **Protagonist = Vesper, written as a _tsundere villain-origin_.** You play the
   3D game's antagonist Auditor *before the ice set in* — proud/prickly/secretly
   soft, in a cozy world. The **3D canon is explicitly NOT locked**: cosmic2d may
   *shape* Vesper's character and the cozy direction, and the 3D game is expected
   to lean cozy too (influence is now bidirectional, not inherited).
2. **Setting = the shared Grand Canyon** seam-world of the 3D game (reuse its
   locations — Rim, Whisper Gulch, Echo Reach, Sun Vault, Night Cave, Raven
   Exchange — confirmed by the mock board). The **Rim** is the cozy town hub.
3. **Gemma = a recurring comedic antagonist** (Team-Rocket trajectory): a rival
   cosmic architect who got obsessed with human media and cosplays as a
   chuunibyou dark-fantasy succubus (horns/wings/tail are hard-light cosplay),
   convinced it's how to commune with humans. Not a hub ally.
4. **Lumi = the human local idol** (bunny-girl): hub stage + flavor/shop, plus an
   **early side-quest**. **Mobs = "cosmic creatures"** — reality leaking into
   creature-form where the seam wears thin; slicing one *files it back* (the
   proto-Sweep gesture — the dread, run in reverse).
The narrative layer is **STORY.md** (premise, the dread engine, cast, mob roster,
world, quest spine) + **`docs/maps/`** (one pager per map). First arc drafted:
**Rim Hub** (Q1 First Survey) → **South Trail** (Q2 the idol's gem · Q3 Gemma's
debut) → **Whisper Gulch** (Q4 the first dread beat + the Works' first work-order).
**Why**: a tsundere origin makes the eventual cold-Auditor freeze *tragic* (her
warmth is what she buries — "Nothing I take is lost" is the line she hasn't
learned yet), turning the spin-off into a real prequel with emotional stakes
instead of a disconnected side-story; reusing the canyon is cheap, coherent, and
the mocks already assume it; a recurring-clown rival + a cozy idol + cute
leak-creatures all serve the cute-cozy-with-cosmic-dread pillars (GAME.md §1) and
give the hub the personality it needs to be "fun to simply exist in" (§6). Keeping
the 3D canon unlocked avoids a continuity straitjacket and lets the stronger cozy
direction flow *back* into the 3D project.
**Snapshot story**: n/a — design/narrative-level; no engine or sim surface. Each
content system documents its own determinism story as it lands (combat M12,
sandbox M-physics, economy M13, the dread shader/LUT M-look — the map pages flag
what each beat leans on).
**Revisit**: the human owns the fiction and has final cut on **names** (Lumi is a
proposed placeholder; Gemma's chuuni titles are throwaway gags; the shopkeep's
identity — Bridger cameo vs. new — is open). Canon-binding is loose *by choice*
and may tighten if the 3D project wants it. Lumi's "cold smile" range leaves a
later turn parked (a hidden stake), not promised. The first-arc map pages are
design targets — when a built map diverges, the map wins, fix the page.

## D043 — render-only C compositor primitives: blit32 / fill32 / tex_update (M10 perf, PAL api 6, 2026-06-29)

The studio's pixel bulk-work (composite the visible layers on every edit, clear a
scratch, re-upload the canvas texture) was pure per-pixel **Lua**. At the sizes
the human now reaches with the canvas-resize feature (half-1080p, "a big sprite
sheet or a mock") a single recomposite ran **~800 ms** — about 1 fps per stroke,
unusable. Decision: add three small **portable C** primitives to the PAL and route
the bulk work through them (api 5→6, additive):

- **`pal.blit32(dst,dw,dh,dx,dy, src,sw,sh,sx,sy, w,h, mode[,op])`** — the
  engine's one reusable clipped RGBA8 2D compositor: copy / src-over / stamp +
  a 0..255 source-alpha (per-layer opacity) scale, clipped to both buffers.
- **`buf:fill32(off,count,value)`** — a 32-bit `:fill` (C u32 memset).
- **`pal.tex_update(id,buf,w,h)`** — in-place re-upload into an existing same-size
  texture (no GPU realloc, no Lua-string copy); false on a size change → recreate.

**The binding constraint**: `blit32`'s src-over is the **bit-exact integer math**
of `cm.paint.over`. Compositing/baking is where the `.png` the game loads is
produced, and the selftest pins exact pixels — so a C-accelerated path that
diverged by even one LSB would shift the committed art and break goldens. It does
not: a re-bake of `girl.spr` is `cmp`-identical to the committed `girl.png`, and
the existing composite/blit/fill KATs pass unchanged. Measured win: 960×540×4
layers **813 ms → 9.5 ms (~86×)**; 1920×1080 **3245 → 37 ms**.

**Why a general primitive, not an editor helper** (the human's framing): a 2D
RGBA8 blit with src-over + opacity + clipping is exactly what *any* part of the
engine needs for layer flatten, bake, brush stamp, paste, document resize, and
future dynamic-texture work — so it earns its place in the PAL contract. It is
**render/dev class** (D040 §1 — the studio carries no determinism tax), and it is
not in the sim path (the game draws baked PNGs + quads, never `cm.paint`), so it
**cannot perturb a trace** — confirmed by a 300-frame sandbox record→verify.

**Revisit**: if per-edit composite ever dominates again at extreme sizes / frame
counts, the next step is **dirty-rect** compositing (re-blit only the touched
region) and partial `tex_update` sub-rect upload — both layer cleanly on top of
these primitives without changing the contract. A SIMD/wide-word inner loop is a
pure C-internal optimization if profiling asks. The byte-exact-match-to-Lua rule
is **permanent** as long as both paths exist (a new blend mode adds a new `mode`
number; it never changes an existing one's rounding).

## D044 — procart: the procedural-art experiment cartridge (2026-07-03)

The human asked for an **experimental separate project** testing whether
mostly-procedural pixel art can hit the cute-with-personality bar — procedural
characters (knobs + a sprinkle of baked choices, enough variety for a full
cast) and procedural terrain primitives that tile cleanly and **marry** two
tiles at a border without a visible seam. This also absorbs and expands the
open M10 "procedural sprite generator" next-step into a full pipeline probe.

Decisions:

- **A separate cartridge, `projects/procart/`** — never in a golden suite; the
  experiment may be promoted, mined for parts, or abandoned without touching
  the game projects. Design + verdict criteria live in **docs/PROCART.md**.
- **Art generation gets its own pure PRNG** (`prng.lua`, splitmix64 + coord
  hashes) — never `cm.rand`: assets are pure fn(seed, knobs), and the sim
  stream must not move when art is generated. Dev/render class per D040
  (proved by record→verify with generation running in draw).
- **World-space hashing is the tiling strategy**: materials are pixel
  functions of world coordinates, so region bakes are seam-free by
  construction; the same functions run in periodic mode (feature periods
  divide the tile) for self-wrapping atlas tiles.
- **Border marrying = per-material indicator fields + per-material noise
  wobble + Bayer-dithered tie band** (never alpha blends); "air" is a
  material, so ground silhouettes get the same organic treatment.
- **Hue-shifted ramps (`palgen`) are the shared color logic** for every
  generated asset — the coherence mechanism.
- **Knob-pinning must not reshuffle the seed's other choices** (constant rng
  draw count): one seed can wear every mood — the personality dial.

Revisit triggers: the human's taste pass on the llm-feed gallery (promote /
mine / abandon); if promoted, how bakes enter the M10 asset pipeline
(.spr layers for hand-finishing vs direct PNG strips).

## D045 — the revamp: teidraw-style editor UX + repo split (2026-07-12)

**Context**: the human arrived with a clear, well-defined UX vision after
months of daily-driving teidraw (`../teidraw`), captured as the teidraw board
`cosmic2d` (the diagram convention is now in CLAUDE.md). The old editor shell
grew ad hoc (docked chrome + the studio's separate full-window mode); the
vision unifies everything.

**Decision** (the human's, this is a directional ADR; **docs/REVAMP.md** is
the plan): a multi-session revamp —

- **The editor becomes an infinite canvas with floating windows** (code
  editors, asset pick, sprite ed, the live playable game), a subset of
  teidraw's UX with the same heuristics-for-intent philosophy (main action =
  content interaction; move/select/close behind ALT; no title bars).
- **Dear ImGui is pulled into the binary** for complex widgets (code-editor
  text rendering/wrapping) rather than maintaining our own text stack; the
  canvas grammar stays script-side. C++ is thereby allowed in the platform
  binary ("portable C/C++ helpers").
- **Script engine decision gate before the editor rewrite**: evaluate
  QuickJS vs Lua 5.4 (perf + provable determinism); the editor is written
  once, in the winner. (Bellard's upstream QuickJS got a major perf uplift;
  a fork is probably unnecessary.)
- **Three repos**: `cosmic2d` = engine only; `../cosmic2d-demos` =
  experiments/demos; `../cosmic2d-game` = the cosmic game. Old demos/assets
  archived; current tree preserved as a `pre-revamp` backup branch;
  **breaking API changes are explicitly okay**.
- **Rewind becomes a flagship feature**: ~1 GB adjustable disk-streamed state
  history; frame-by-frame read-only browsing of everything *including the
  editor*; asset bring-back from the past; game/editor switch while
  rewinding. Consequence (supersedes the D040 exemption for the NEW shell):
  editor state must live in named/snapshottable state so history capture
  sees it. The old studio's exemption stands until the new sprite-ed window
  replaces it.
- **The game prototype reboots as a graybox** (movement feel kept verbatim,
  checkerboard/rect placeholders, core loop iterated to feel-great; the
  human fills in art as we go).

**Why**: the engine's UX debt is the binding constraint on everything M10+
taught us; teidraw proves the exact interaction model we want, natively, with
source on disk to crib from. The determinism foundation (the engine's actual
moat) is untouched — the revamp deepens it (rewind) rather than trading it
away.

**Revisit if**: the QuickJS spike fails determinism (stay on Lua — cheap,
good outcome); imgui starts leaking into the canvas grammar (contain or drop
it); the rewind's editor-state capture proves heavier than the feature is
worth (descope to sim+assets history first).

## D046 — revamp review round 1: smoke project · studio retirement · rewind browse semantics (2026-07-12)

**Context**: the human reviewed REVAMP.md and resolved its §7 open questions,
plus pre-answered a rewind design gate that would have surfaced in R6.

**Decisions** (the human's):

- **The engine keeps a minimal smoke project = a cut-down cosmic demo** —
  just a room with a couple of platforms plus the movement code. It is the
  testbed for the whole editor-rewrite phase and the golden/selftest carrier
  (goldens re-cut on it once, at R0). The old sandbox testbed retires to the
  `pre-revamp` branch; the game graybox (R7) comes **after** the editor
  phase — the current greybox is a placeholder anyway.
- **The old studio (F2 full-window mode) dies at R4** when the sprite-ed
  window lands — no parity coexistence.
- **Rewind browsing is interactive but ephemeral**: parked on a rewound
  frame you can poke around — move windows, open assets as they were at that
  point in time — but all such changes are **discarded the moment you scrub
  to another frame**. No reconciliation logic ever runs (later-deleted
  assets / closed windows are non-problems: nothing done while parked
  outlives the frame). Explicit escape hatches only: bring-back-asset and
  resume-from-frame.

**Why**: the smoke keeps the engine repo self-testing without dragging game
content along; a dead studio avoids maintaining two shells; the ephemeral
browse keeps R6 tractable — immutable history + throwaway viewing state is
strictly simpler than any merge/reconcile story, and matches user intent
(you scrub to *look*, not to edit the past).

**Revisit if**: ephemeral browsing feels like data loss in practice (then:
an explicit "copy out of the past" affordance beyond assets — never
in-place reconciliation).

## D047 — R1 script-engine gate: stay on Lua 5.4 (2026-07-12)

*(Performance table superseded by **D048** — retested on QuickJS
2026-06-04, which nixpkgs hadn't picked up; decision unchanged, the
determinism audit stands.)*

**Context**: REVAMP R1 (D045) required deciding QuickJS vs Lua 5.4 *before*
the editor rewrite, on measured performance + a determinism audit — numbers,
not vibes. Spike harness: `tools/r1_scriptbench/` (a dual-host C binary
embedding both VMs behind an identical native surface shaped like our hot
paths; workloads are literal Lua↔JS translations). QuickJS = bellard
upstream **2025-09-13** (the post-perf-uplift line the board pointed at),
built `-O2` like the vendored Lua 5.4.7. Ryzen 9 5900X, WSL2.

**Decision**: **stay on Lua 5.4.** The editor rewrite (R3+) and everything
after is written in Lua. QuickJS is not adopted, not vendored, no fork.

**The performance numbers** (avg/frame unless noted; stable over reruns):

| workload | Lua 5.4.7 | QuickJS 2025-09-13 | QJS/Lua |
|---|---|---|---|
| sim tick, 200 entities (distilled player.step) | 287 µs | 623 µs | 2.2× |
| quad prep, 5k quads, per-call `quad(...)` | 618 µs | 1563 µs | 2.5× |
| quad prep, 5k quads, bulk `buf:f32` writes | 1946 µs | 4705 µs | 2.4× |
| quad prep, 5k quads, `Float32Array` direct (JS-only path) | — | 2928 µs | 1.5× |
| UI churn, 300 widgets (ids/state/rects/format) | 313 µs | 507–586 µs | 1.6–1.9× |
| xoshiro256++ u64 draw (cm.rand verbatim) | 105 ns | 852 ns (BigInt) / 1400 ns (u32-pair) | 8.1× / 13.3× |
| 360 KB source compile+run | ~10 ms | ~24 ms | 2.4× |
| minimal embed, stripped | 276 KB | 883 KB | 3.2× |

Lua wins **every** workload. Even QuickJS's best-case bulk path (typed-array
direct writes, which Lua doesn't have) loses to Lua crossing the C boundary
per float. GC behavior is comparable (p99/max frame times in the same band;
no pathological spikes either side).

**The determinism audit** (`det.lua`/`det.js` + in-bench cross-checks):

- **IEEE f64 arithmetic is bit-identical across both VMs** — arithmetic
  chains, sqrt, and the sim workload's position checksum match to the bit.
  Doubles are not the hazard.
- **Integers are.** JS numbers collapse above 2^53 (Lua is exact 64-bit,
  wrapping); JS bitwise ops truncate to 32 bits; `-7 % 3` = `-1` in JS vs
  `2` in Lua (trunc- vs floor-signed) and likewise `/`+`Math.trunc` vs `//`
  — every negative-coordinate tile index and every modular pattern would
  need a port-time audit. JS has **no int/float subtype distinction**, so
  `cm.state.canon`'s `\3` int8 vs `\4` f64 tags (the doc-tree canonical
  bytes, snapshot identity) are unrepresentable without heuristics that
  change semantics.
- **The PRNG is portable but pays 8–13×**: both a BigInt and a u32-pair
  xoshiro256++ reproduce cm.rand's exact bit stream (proven: identical ref
  draws + 2M-draw accumulators). Bit-exact record→verify in QuickJS is
  therefore *achievable* — it is just slow and rewrites every 64-bit site.
- **Iteration order**: genuinely better in JS (spec'd: int-like keys
  ascending then insertion order; Map = pure insertion) vs Lua's hash
  order. Our iron rule (never depend on it in sim) already neutralizes
  this; it would remove a footgun class, not fix a bug we have.
- **NaN**: payloads survive QuickJS typed-array round-trips (no
  canonicalization hazard); moot anyway — the doc tree bans NaN.
- **GC**: unobservable in pure computation in both (Lua incremental,
  QuickJS refcount+cycle); neither leaks timing into results.

**Why stay**: the only QuickJS pros are JS familiarity, spec'd iteration
order, and typed arrays as an in-language bulk surface — and the measured
typed-array path still loses to Lua. Against that: 1.6–2.5× slower on every
representative frame workload, 8–13× on the PRNG under the sim, a 3.2×
bigger embed, a full engine+cartridge rewrite, and a determinism story that
is provable but strictly riskier (53-bit ceiling, div/mod sign audits,
canon int/float loss). The gate exists so the editor is written once in the
winner; the winner is what we already have.

**Scope limits recorded**: quickjs-ng 0.14 untested (same engine class —
would not flip a uniform 2×/8× gap); no JIT-class engine considered (V8/JSC
are out on embed size, determinism surface, and platform reach). Hot-reload
is parity either way: QuickJS's ES-module cache is not evictable, so a port
would keep our own registry/eval loader exactly like boot.lua's — no win to
migrate for.

**Revisit if**: a future upstream QuickJS (or comparable embeddable engine)
closes the integer-op gap to ~2× on `w_prng` AND user-facing mod scripting
"for the masses" becomes a product goal — rerun `tools/r1_scriptbench/`
against it; the harness is the contract.

## D048 — R1 retest on QuickJS 2026-06-04: numbers revised, decision stands (2026-07-12)

**Context**: the human caught that D047 tested an old release — nixpkgs
pinned bellard's 2025-09-13, but upstream shipped **2026-06-04**, "42%
faster on bench-v8" (custom small-block malloc + micro-optimizations).
Retested with the same harness (`tools/r1_scriptbench/`), same flags
(the 2026 release needs `-std=gnu11` — Atomics.pause inline asm), same
machine. D047's performance table is **superseded by this one**; its
determinism findings reproduced identically and stand as written.

**The revised numbers** (Lua 5.4.7 unchanged; stable over reruns):

| workload | Lua 5.4.7 | QJS 2025-09-13 | **QJS 2026-06-04** | new ratio |
|---|---|---|---|---|
| sim tick, 200 entities | 287 µs | 623 µs | **385 µs** | 1.34× |
| quad prep, per-call | 580 µs | 1563 µs | **583 µs** | **1.0× — parity** |
| quad prep, bulk `buf:f32` | 1911 µs | 4705 µs | **2322 µs** | 1.2× |
| quad prep, `Float32Array` (JS-only) | — | 2928 µs | **1406 µs** | **0.74× — beats Lua's best bulk path** |
| UI churn, 300 widgets | 314–322 µs | 507–586 µs | **335–339 µs** | ~1.05× |
| xoshiro256++ u64 draw | 103 ns | 852 / 1400 ns | **675 (BigInt) / 839 (u32-pair) ns** | **6.5× / 8.1×** |
| 360 KB source compile+run | ~10 ms | ~24 ms | **~25 ms** | 2.5× |
| minimal embed, stripped | 276 KB | 883 KB | **981 KB** | 3.5× |

The uplift is real: general scripting is now **near parity**, and typed
arrays give JS a genuinely better bulk-buffer story than Lua's per-float C
calls. The determinism audit re-ran bit-for-bit identical (f64 parity,
xoshiro streams exact, NaN payloads preserved, integer semantics hazards
all unchanged — they are language spec, not engine speed).

**Decision: still stay on Lua 5.4.** What decided D047 was never the
general-perf gap, and everything that actually decided it survives the
uplift:

1. **64-bit integer work is still 6.5–8× slower** — that's under cm.rand
   on every sim draw, and every 64-bit site becomes a BigInt/u32-pair
   rewrite with its own correctness risk.
2. **The semantic hazards are spec, not perf**: 53-bit ceiling, 32-bit
   bitwise, trunc-vs-floor div/mod signs, and no int/float subtype —
   `cm.state.canon`'s doc-tree tags (snapshot identity itself) would need
   a redesign, not a port.
3. **3.5× embed, 2.5× compile**, and a full engine+cartridge+goldens
   rewrite — to arrive at roughly where we already are.

The honest change from D047: the *upside* case is no longer laughable —
near-parity general perf + a better typed-array bulk surface + JS
familiarity is a real (if insufficient) package. If mod-scripting for a
mass audience ever becomes a product goal, this is a judgment call, not a
formality.

**Revisit if**: user-facing mod scripting becomes a product goal (rerun the
harness against current upstream — QuickJS is visibly improving fast:
2.4× on our workloads in nine months); or a release lands a 64-bit-integer
fast path that brings `w_prng` under ~2× (then the last *technical* blocker
is the canon int/float redesign, and the question becomes purely one of
migration cost vs audience).

## D049 — R2: Dear ImGui hosted in the PAL, as a drawlist + hard widgets, one UI philosophy (2026-07-12)

**Context**: the R3+ editor (REVAMP §2) is an infinite canvas with floating
windows, written in Lua, needing scalable crisp text at any zoom and real
text editing — the two things not worth hand-rolling. teidraw (the direct
prior art, `../teidraw`) proves the target feel on imgui 1.92's dynamic
font atlas. REVAMP §3.1 demanded the imgui/script split be designed before
build so imgui never becomes a second UI philosophy. Full design:
**docs/IMGUI.md**.

**Decision**:

1. **Vendor Dear ImGui 1.92.4** (teidraw's exact pin) into
   `pal/vendor/imgui/` with the SDL3 + SDLGPU3 backends; one C++17 TU
   (`pal/src/ig.cpp`) hosts it behind `extern "C"`; the PAL core stays
   C11. This formalizes the C/C++ helper layer (the board's "portable
   C/C++ helpers" box): C++ allowed for vendored libs + host TUs, C ABI at
   every boundary, numpy-model kernels unchanged.
2. **The split**: Lua gets a native-resolution **screen-space drawlist**
   (shapes / text-at-any-px / images / clip), **hard widgets at explicit
   rects** (multiline text edit), and **frame gate + capture flags** —
   nothing else. ImGui windows/docking/layout/styling/.ini are never
   exposed; window chrome + the ALT grammar + layout stay Lua. Review
   test for every addition: could teidraw's feel be built on this without
   imgui policy leaking?
3. **Rendering**: imgui renders last, into the present pass, at native
   window resolution — a third layer above the game target + ui canvas.
   Crisp text at any zoom = the teidraw cap-and-scale trick (raster
   ≤320 px, vertex-scale above) inside the host, invisible to Lua.
4. **Class**: the whole surface is render/dev, live + `--win`-capture
   only. Goldens keep reading the game target; `--verify`/plain headless
   never initialize imgui; the sim can't read any of it (D036's iron rule
   extends verbatim). No golden is regenerated by R2.
5. **Window model**: game/launcher keeps M8/D036 (960×540 default,
   fullscreen = ladder upscale) — now blessed as the shipped shape.
   Editor sessions boot maximized (`gfx_init{maximized}`, additive).
   Events grow raw window-px `wx,wy` alongside the existing two spaces.
   `x_compose{scale=0}` = skip the game blit (the R3 editor draws the
   game target itself via `x_ig_image(-1, …)`).
6. **PAL API 6→7**, everything born `x_` (contract rule 3); fonts =
   Inter + JetBrains Mono (OFL, teidraw's taste-approved pair) vendored
   in `pal/vendor/fonts/`.

**Consequences**: the binary grows ~0.5–1 MB and a C++ toolchain enters
the build (mingw cross links -static-libstdc++) — accepted; the PAL stays
small where it matters (the contract surface). The engine now has two text
stacks by design: spleen quads in the deterministic/pixel world, imgui
text in the native-res editor world above it.

**Revisit if**: an `x_ig_*` proposal fails the §2 shape test (that's a
design smell, not an exception to grant); or the R3 editor needs imgui
internals (e.g. custom text shaping) that the drawlist can't express —
then extend the *host*, not the surface.

## D050 — R3: the editor shell — canvas grammar, the captured editor domain, undo-forever journals (2026-07-12)

**Context**: R3 (REVAMP §6) rebuilds the editor as the teidraw-style
infinite canvas with floating windows, in Lua on the D049 drawlist. Three
things had to be designed before build: the interaction grammar (the
board specs an ALT layer teidraw itself doesn't have — teidraw's canvas
IS its main action; ours is window content), the unsaved-persists +
undo-forever model, and — the REVAMP §8 risk — a state model R6 rewind
can capture, the exact opposite of D040's "no determinism tax" studio.
Full design: **docs/EDITOR.md**.

**Decision**:

1. **A second, parallel state domain for the editor.** Everything a
   rewound frame must show lives in **`cm.ed.doc`** — a plain-data doc
   tree serialized by the same canonical codec as the sim doc
   (`cm.state.canon`), so R6 deltas/hashing come free. Mid-gesture
   mechanics (drag anchors, hover, ease bookkeeping) are explicitly
   ephemeral module-locals. Editor code need not be deterministic (R6
   browsing is state reconstruction, not re-sim); its *state* must be
   delta-able. Buffer names prefixed **`ed.`** are reserved for the
   editor domain and excluded from sim snapshots/traces from day one
   (KAT-pinned; no existing buffer collides, so no golden moves).
2. **The ALT grammar is the board's spec, with teidraw's tuning**:
   ALT gates all shell mouse interaction (A-click select + drill via
   parent links, A-drag move with selected-first priority,
   A-rightclick close, A-drag-on-empty marquee); plain drag on a 6 px
   edge band resizes; `[`/`]` (+Shift) reorder z, no auto-raise; no
   draggable title bars. Thresholds lifted from teidraw source: 4 px
   click-vs-drag, 320 ms/6 px double-click, 1.16×/notch zoom clamped
   0.02–64 at cursor, 280 ms quart eases, adaptive 32-wu dot grid.
3. **Unsaved-persists via three layers keyed by asset path**: the file
   on disk (the only thing the engine loads — unsaved never takes
   effect), the working state in `cm.ed.doc.assets` (survives restart
   via `<project>/.ed/session.dat`, the 400 ms-debounced CEDS canon
   dump), and the **journal** (`.ed/journal/*.jrn`, a CJRN chunk stream
   of full-snapshot ENTR entries — teidraw's undo.jsonl shape: append
   on gesture end, dedupe vs tip, branch = truncate + rewrite, 4096
   cap). Dirty is computed (working vs disk hash), never tracked.
   Closing a window is non-destructive by construction (state is keyed
   by asset, not window) — so A-rightclick needs no confirm dialog.
4. **New PAL primitive `pal.x_file_append`** (portable C, additive x_
   tier, no api bump) so journal pushes don't rewrite whole files.
5. **Hosting**: `bin/cosmic <project> --edit` (live/`--win` only; no-op
   under verify/plain headless per the D049 absence contract); the sim
   keeps running with all input swallowed by the shell (game-window
   input synthesis is R4); `view.mode = "canvas"`. Interim console
   story: an open console suppresses the ig frame entirely — legacy
   chrome stays usable until it re-hosts as a canvas window at R4.
6. **R3 roster**: note (doc-only sticky), text (journal-backed real
   file — the code-ed precursor), game (watch-only `x_ig_image(-1)`).
   Modules: cm.ed + cm.ed.cam/wm/journal/session/win.* with pure,
   headless-selftestable cores.

**Consequences**: the editor becomes rewind-capturable before rewind
exists — the cost is discipline (every durable field goes in the doc),
bought cheap now instead of as an R6 rewrite. The journal's
full-snapshot entries trade disk for simplicity (~400 MB worst-case per
100 KB text asset at cap); delta entries are an ENTR v2 decision for R4
asset kinds if needed.

**Revisit if**: R4's sprite-ed working sets make full-snapshot journal
entries or the doc-tree text fields visibly slow (→ ENTR v2 deltas /
`ed.*` buffers, both designed-for); or the R6 design finds captured
state it needs that §2's captured/ephemeral line excluded (→ move the
field into the doc, which is the whole point of the line).

## D051 — R4: the windows — ghost-widget code ed, focused-play game window, console/assets/sprite-ed as canvas citizens (2026-07-12)

**Context**: R4 (REVAMP §6) fills the R3 shell with its real citizens:
code ed, the playable game window, the console re-host, asset pick, and
sprite ed — and the F2 studio dies with no coexistence (D046 Q4). Three
designs had to land first: how a syntax-highlighted code editor rides
`x_ig_edit` without imgui leaking policy (and without the §11 widget-z
trap), how a *focused* game window feeds the deterministic sim, and what
of the studio's depth ships in sprite-ed v1. Full design: EDITOR.md §12.

**Decision**:

1. **The ghost-widget split**: `x_ig_edit` grows additive opts (`ghost`,
   `scroll_x/scroll_y`, `enter`, `focus`, `set`) and a 4th return
   (`{sx,sy,caret,sa,sb,submit}`). In ghost mode the widget draws no
   glyphs — it is a pure input machine (caret/selection/mouse/clipboard/
   IME) — and **Lua draws every visible glyph on the drawlist**: syntax
   color, gutter, caret. This keeps imgui a mechanism (D049 §2 test
   passes: teidraw could still be built on it) AND dissolves the
   widget-z trap: occluded windows skip an invisible widget and render
   pixel-identical. The multiline child's scroll + `GetInputTextState`
   offsets are read behind the C ABI; the child-window name shape is a
   vendored-pin internal (re-checked on any imgui bump).
2. **Focused = playing**: content-click already focuses, so clicking
   into the game window plays it. `cm.ed.filter_events` replaces the
   blanket input swallow: keys pass through, mouse remaps through the
   letterboxed image rect to FOV px, wheel feeds the sim — all through
   the normal `cm.input.feed`, so synthesized input is recorded and
   replayable by construction. Plain-key shell hotkeys suspend while a
   game window is focused; ALT, Esc, and Ctrl stay the shell's.
3. **Console = a window kind** reading the same `pal.log_lines` ring;
   Enter submits to the recorded EVAL path; grave spawns/focuses it in
   editor mode. The D050 §8 skip-ig-frame gate is deleted — the last
   legacy-chrome coexistence hack.
4. **Asset pick**: flat no-folder list, type chips + fuzzy subsequence
   search, size slider, texture previews; double-click opens the right
   kind (incl. a trivial `image` window); drag-out re-targets a window
   (`kind.accepts`) or spawns one on empty canvas; **OS drag-in** lands
   via a new additive PAL event `{type="drop", path, wx, wy}`
   (SDL_EVENT_DROP_FILE) and copies into the project (image→`art/`,
   sound→`sound/`, code→root).
5. **Sprite ed works on CSPR bytes as its working state**
   (`doc.assets[path].spr`), so D050's three-layer model applies
   verbatim — journal entries are .spr snapshots (per-open cap 512),
   one paint gesture = one entry, revert/restart-survival free. The
   decoded doc + textures are ephemeral; `ed.*` buffers stay reserved.
   Read-only by default with a header edit toggle. **v1 roster is
   deliberately lean** (pencil/eraser/bucket/eyedropper, palette +
   hex add, layers, frames, zoom/pan); gradients/transforms/clips/
   HSV/pivot editing return window-by-window as content work demands —
   an accepted, recorded gap. `cm.studio`, `--studio`, and F2 are
   deleted (cm.paint/sprite/anim untouched; cm.editor the F1 world
   editor survives until maps become a window).
6. **Wheel routing**: ALT → canvas zoom always; else content that takes
   the wheel (game/sprite/scrollers); else canvas zoom.

**Consequences**: the code path everyone edits in daily is drawlist
glyphs + an invisible widget — one philosophy, no second text renderer;
the game is playable where it lives, and its input path is trace-clean;
the studio's 2171-line full-window mode leaves the tree. The cost is
sprite-ed v1's feature gap vs the studio it replaces, and a documented
dependency on one imgui internal name shape.

**Revisit if**: the ghost overlay ever misaligns with the widget's own
metrics (wrap/tab/IME edge — would force exposing more editor state
through the C ABI instead); sprite journals at 512 full snapshots still
grow painful (→ ENTR v2 deltas); or the human misses a studio feature
weekly (→ that feature is the next sprite-ed round).

## D052 — R5: the project picker + the thin launcher (2026-07-12)

**Context**: R5 (REVAMP §6) gives the engine its front door: a
teidraw-style project picker, and the board's shipped-game story — a
thin launcher exe beside the project, editor/console disabled, the same
zip openable through the editor. Two mechanisms had to be picked: how a
running engine *switches projects* (boot loads exactly one), and how a
renamed exe finds its game.

**Decision**:

1. **Project switch = a Lua VM reboot over surviving C state.** The
   parachute already proves the shape (VM closed + re-booted, window and
   named buffers intact). Additions: `pal.x_reboot()` (request the same
   cycle without an error), the **`boot.next` named buffer** as the
   carrier (named buffers survive reboots BY DESIGN — the picker writes
   `"<path>\n<mode>"`, the next boot adopts + frees it), and
   `pal_gfx_init` learns to **retarget on re-init** (resize the internal
   target via the existing resize path, retitle, honor maximized)
   instead of refusing a different-size project. On an adopted switch,
   cm.main **sweeps all named buffers** first so the old project's sim
   state can't leak into the new session's snapshots/traces.
2. **The picker is a cartridge** (`projects/picker` — igcanvas
   precedent): scans `projects/*` for project.lua + merges the recents
   file (engine-root `.recent.dat`, plain lines, most-recent-first,
   cap 12, gitignored — written by cm.main on every successful real
   boot, which is how sibling-repo projects like ../cosmic2d-game/cosmic
   get remembered). Tiles open in **editor mode by default** (the board:
   the picker is the editor's front door); a ▶ affordance boots play
   mode. `bin/cosmic` with no project argument boots the picker (the old
   default, projects/sandbox, died at R0 anyway).
3. **The launcher is exe-name magic, C-assisted, Lua-decided**:
   `pal.exe` (argv[0]) is exposed; when boot has no project argument and
   the exe basename isn't `cosmic`, cm.main looks for `<name>/` then
   `projects/<name>/` (relative to the engine root the existing
   fixup_cwd already established) and boots it **locked**: `proj.editor
   = false` forced (the existing D-series lockdown every dev surface
   already respects), `--edit` ignored. A shipped zip is therefore: the
   renamed exe + `engine/` + the project dir; the same unzipped folder
   opens fully in the editor via `cosmic <dir> --edit`.

**Consequences**: no process re-exec, no second binary — the launcher IS
cosmic.exe renamed, and switching projects reuses the most battle-tested
path in the PAL (the parachute). The cost: gfx retarget-on-reboot is new
surface area on an old function, and cross-project buffer hygiene is now
cm.main's job (the sweep).

**Revisit if**: a project needs boot-time gfx properties the retarget
can't apply live (a fixed non-resizable window, say); or picker startup
scanning gets slow enough to want a manifest cache.

## D053 — R6: rewind — the editor stream, disk budget, park-ephemeral discipline (2026-07-12)

**Context**: R6 (REVAMP §3.3/§6) is the flagship: ~1 GB of engine
history, streamed from disk, browsable frame by frame *including the
editor*, interactive-but-ephemeral (D046 §7b), with resume-from-frame
and asset bring-back. The M5/D032 ring already does read-only
reconstruction + rewind for the sim; the R3/R4 editor domain was
designed to be capturable. Full design: **docs/REWIND.md**.

**Decision** (the load-bearing choices):

1. **The editor rides the existing ring as a new per-frame `EDOC`
   chunk** (canon bytes of cm.ed.doc, written on change only via a
   `doc_rev` bumped by `cm.ed.touch`; keyframes carry the full ed
   canon). cm.chunk is skip-tolerant, so **CTRC stays v1** — old traces
   load, the verifier ignores EDOC, no golden regenerates.
2. **Disk streaming = whole closed segments spilled to
   `<project>/.ed/history/`**, RAM keeps the open segment + a decode
   LRU; `ring.budget_mb` (default 1024) evicts oldest files. History is
   per-session (wiped at boot) — cross-session time travel is the
   journals'/git's job.
3. **Browsing = the scrub park model extended to the editor**: stash
   the present ed doc, restore the parked frame's, let the normal shell
   frame run against it (fully interactive). **Suspension discipline**
   while parked: session autosave off, journal pushes off, file writes
   walled (bring-back is the door). Scrub away = drop the poked copy;
   **resume adopts the shown doc, pokes included** (least surprising).
   Ephemeral per-asset plumbing (g.tw/g.sw) drops wholesale on park.
4. **Bring-back = working-state copy, not file epochs**: a parked
   frame's `doc.assets[path]` bytes journal-push into the present as
   one undoable step. Assets never opened in a window are out of scope
   (journals already cover everything the editor touched).
5. **UI = the reserved top-right pill** expanding to a top bar
   (timeline/park/play/resume/bring-back), shell overlay, editor
   sessions only; the legacy F4 scrubber keeps play-mode sessions.

**Consequences**: R6 is an extension, not a rewrite — the sim capture,
reconstruction, rewind, and park machinery are reused verbatim; the new
surface is one chunk kind, a spill layer, and discipline flags. The
riskiest edge (the past leaking into session.dat) is contained to one
gate with a park-quit-relaunch proof.

**Revisit if**: soaks show EDOC canon encodes hurting frame time (→
delta the ed canon, kind 2, format has room); or the per-session
history bound turns out to matter to the human (→ a keep-history flag
and boot adoption become an R6.5, the format already round-trips).

## D054 — editor UX round 3: the no-modifier grammar + the game-window FOV range (2026-07-12)

**Context**: the human's live feedback on the R3–R6 shell: they kept
trying to drag windows by the title bar ("which means it should work
like that"), plain-LMB pan on empty canvas fought the select instinct,
and the game window resized as a free rectangle (letterboxing instead
of committing to a size). Plus a new engine contract: the range of
resolutions a game must support.

**Decision**:

1. **The title strip is a drag handle** (no modifier): plain drag
   moves, plain still-click selects; the header-button zone (each
   kind's `header` hook returns its consumed width; recorded per frame,
   1-frame latency like grect) keeps its clicks. ALT-move stays for
   grabbing a window anywhere without aiming at the title.
2. **Plain select lives on the naked canvas**: an empty-canvas left
   press is a marquee (drag selects, still-click clears). **LMB never
   pans; panning = middle button** (space+drag stays; a right-drag is
   nothing — right still-click keeps the spawn menu).
3. **Selection mode** (`alt+V`): the next press can only select — it
   marquees even over windows and outranks the edge bands; a landed
   select disarms it, an empty one keeps it armed; Esc/alt+V exits.
   The escape hatch for "select a window without ALT".
4. **The supported game resolution range** (engine contract, R7 games
   build to it): internal **height fixed**, width **4:3 → 16:9** of it
   — base 540 → **720..960** — widened to include the project's design
   width (odd-aspect dev projects stay legal). The live FOV rides
   `pal.x_fov` (render-only, D036: sim never reads it; headless/verify
   keep the project res, goldens untouched).
5. **The game window resize commits to that range**: always
   aspect-locked; horizontal drags walk the FOV width through the
   range at constant scale then scale past the ends; vertical/corner
   drags scale at the current width; **CTRL snaps the scale to
   integers** (res multiples). `kind.constrain` threads through
   `wm.resize`; the width lives in `win.fw` (captured, restored on
   relaunch), applied via `cm.view.canvas_fov` before the next game
   draw. The window spawns at native+pads and the draw snaps integer
   scales to exact px → **pixel-perfect at 100% (and multiples) with
   zero letterbox**.

**Proof**: selftest 22707→22732 (+25: the new grammar, constrain
threading, the game constraint math); `nix run .#test` ALL GREEN
(traces + pixels byte-identical); scripted `--edit` captures on
llm-feed (the new HUD/chips; the FOV walked to 360x270 with the target
really resizing and the image 1:1).

**Revisit if**: the human's soak finds the header band vs inner edge
band (top 4 px of the strip resizes, not moves) confusing (→ shrink
EDGE_IN over headers); or games want non-540-family heights (the range
math is per-height already — only the docs' example is 540); or two
game windows fighting over one FOV (last resized wins) starts to
matter (→ per-window targets is an R8+ PAL feature).

## D055 — R6.5: cross-session rewind — one continuous past stream (2026-07-12)

**Context**: the human, after the R6 build: "i want it to work across
sessions, it should be one continuous past stream and not reset every
time i restart the editor." Exactly the D053 revisit clause ("the
per-session history bound turns out to matter to the human"). R6 §3 had
deferred this ("the ring can't adopt foreign keyframes safely") — but
R6a/b made segments standalone by construction (keyframes carry full
buffers + doc canon + ed canon), so adoption for browsing was already
safe; what was missing was the timeline and the boot plumbing.

**Decision**:

1. **The timeline is the sim frame counter, made continuous**: at boot
   a live windowed session seeds `cm.sim`'s counter one past the last
   retained on-disk frame (`trace.hist_peek`, called from cm.main
   before game.init; headless/verify/captures keep 0 — goldens
   byte-identical). `ring_start` then **adopts** the retained chain as
   spilled skeletons; recording appends to the same stream.
2. **A manifest makes adoption cheap**: `.ed/history/index`, one line
   per spilled segment, appended at spill; existence-checked +
   id-deduped at scan; only the newest file is fully parsed (the crash
   candidate — corrupt tails delete and retry). Rewritten compact at
   adoption.
3. **Contiguity is the safety rule**: adopt only the chain ending
   exactly at the present frame. Forked timelines (out-of-band restores
   whose frame doesn't match) wipe — unchanged semantics for the reset
   path.
4. **Adopted segments have no code bundle** (bundles were RAM-only):
   browsing/parking/bring-back are exact (state + editor doc ride the
   files); a RESUME into one keeps the current code, logged.
   `ring_export` starts after adopted segments (a CTRC needs a bundle).
5. **The quit path flushes the open segment** (`trace.ring_flush` from
   cm.main's single quit path) so a session's tail joins the stream —
   previously those frames just died with the RAM ring.

**Proof**: selftest 22742→**22749** (adopt span/decode, continued
recording, resume-into-adopted + counter restore, quit flush joins,
fork wipes); three live back-to-back smoke `--edit` sessions form one
0..410 stream — session 3 decodes a session-1 frame with sim bufs AND
the editor doc (bring-back across sessions works); suite ALL GREEN
(goldens untouched — headless never adopts).

**Revisit if**: the pill timeline gets unusable at multi-day spans (→
segment ticks/day markers + a zoomable bar); adopted-history resumes
with drifted code confuse (→ spill bundles content-addressed next to
segments); boot scans get slow at huge budgets (→ cap manifest length
by rewriting on eviction too).

## D056 — the editor resumes its stream; in-place game restart (2026-07-12)

**Context**: the human, closing the workflow loop on D055: "editor
should resume from last snapshotted frame when started, and the game
should have a reset button to restart it."

**Decision**:

1. **Editor boots resume**: when the adopted history reaches the
   present (it does, by the D055 seed), cm.main rewinds onto its last
   frame right after `ring_start` — the sim continues exactly where the
   previous session quit (current code, per D055's adopted-bundle
   rule). Editor sessions only (`--edit`, live); play and headless
   boots stay fresh. A failed resume logs and falls back to the fresh
   boot.
2. **`cm.main.reset_game()` — boot state at the current frame**: frees
   every game named buffer (the `ed.*` domain and `cm.sim` stay),
   clears the doc, zeroes + re-seeds rand like boot, re-runs
   game.init. **The frame counter is deliberately kept** — it is the
   rewind timeline; resetting it would fork and wipe the cross-session
   stream. A restart is just a big recorded delta: the past survives,
   and the restart itself rewinds.
3. **The game window grows a `restart` header button**, routed through
   the recorded EVAL path (cm.repl.submit — recordings replay it),
   walled while parked (the past is read-only; resume first).
4. Found + fixed while designing: `trace.rewind` onto a FULL segment
   deleted its history file without re-spilling — a gap that would
   sever the adoption chain at the next boot. It re-spills now.

**Proof**: selftest 22752→**22753** (the re-spill gap); live triple:
session A warps the player + quits → session B logs "resumed the
session at frame 122" with the player where A left him → session C
restarts via the EVAL path (player at spawn, frame 247 continuing, no
ring reset). Suite ALL GREEN.

**Revisit if**: games grow boot-time state outside buffers/doc that a
resume misses (→ a game.on_resume hook); or the human wants play-mode
(non-editor) sessions to resume too (→ drop the args.edit gate — the
machinery doesn't care).

## D057 — maps rework: colliders + freehand placement, not tilemaps (2026-07-12)

**Context**: the human, pausing the graybox (R7b) for it: "I'd prefer
a non pure tilemap approach for maps — a collider layer (collider
lines with the ability to add slopes and such); for the visuals,
everything is freehand placement of sprites, but tilemaps can also be
placed and they behave as 1 baked sprite (editable in the tile
editor). Workflow: drag assets from the picker to the map editor to
place, drag to move, double-click opens the right editor; snapping
tied to CTRL so we don't nudge pixels." Full design: **docs/MAPS.md**.

**Decision** (the load-bearing points; MAPS.md carries the rest):

1. **A map is three layers**: collider chains (sim truth — solid or
   one-way, slopes by geometry, i32 px verts), freehand placements
   (render-only, file order = z), markers (rects + kind/extras —
   spawn/portals/prop_spots move here). New assets `.map` (CMAP) and
   `.tm` (CTLM; tileset = a .spr whose frames are tiles; pure visual,
   moved as one unit).
2. **`cm.collide` keeps the frozen mover contract** (`move` →
   nx,ny,hit{left,right,up,down,oneway}; `grounded`; `stand_ray` for
   grapple/mantle) — axis-separated sweep vs classified segments
   (|dy/dx| ≤ 1 = floor, steeper = wall), ground-stick on descent,
   arithmetic only. Feel preserved by contract + flat-parity KATs.
3. **The editor rides the existing models wholesale**: CMAP working
   bytes in doc.assets (journals/dirty/restart/rewind free), save →
   the sprite-style recorded hot-reload epoch (traces replay map
   edits; rewind scrubs across them), new `kind.drop` hook for
   place-on-drag-in, **CTRL = snap** (vertices > edges > 45° lock >
   grid, guides drawn; ctrl+wheel dials grid step).
4. **Graybox = the collider fill itself** (checkerboard fill of closed
   solids, slim accent one-ways) — R7b never waits for the tilemap
   window (R8d last).
5. **Deliberate casualties**: smoke migrates first and its goldens
   re-cut once (like R0); maps/*.lua build code, level.lua builders,
   `cm.tilemap`'s mover, and the F1 `cm.editor` all die by R8e.

**Build order**: R8a format+collision core → R8b map window
select/place → R8c collider+marker editing → R8d tilemap window →
R8e game migration (both maps re-authored in the editor = the dogfood
exit); REVAMP §6 gains R8 between R7a and R7b.

**Revisit if**: flat-parity KATs can't hold the kitcheck behavior on
the migrated smoke room (→ keep TM:move alive under a compat flag and
migrate the game only); slope feel needs sub-45° walls or curved
segments (→ material/arc extensions in COLL, format has room); the
per-cell .tm render shows up in profiles (→ the real bake to one
texture, the format already reads "baked sprite"); CTRL-snap polarity
feels backwards live (→ flip the boolean, grammar unchanged).

## D057a — colliders refined: typed + attachable (human, 2026-07-12)

**Context**: the human's read of MAPS.md, same day. Snap polarity
resolved (**CTRL = snap, no snap by default**) and the collider model
sharpened: plain lines-on-a-layer shown as gizmos is right, but
redesigning solid parts of the map shouldn't mean moving two things —
and dynamic/solid objects (props, enemies, platform sprites) need
collision that belongs to them.

**Decision** (folded into MAPS.md §§2/3/6/7):

1. **Typed collider primitives**: line one-way / line solid (blocks
   both ways) / closed chain (polygon solid) / quad / circle. The
   platformer mover sweeps lines/chains/quads; circles are
   overlap-query colliders (hazards, hit-zones) in v1.
2. **Free or attached**: a collider lives on the map's collider layer
   OR attaches to a placement (relative coords, rides it when moved) —
   identical static geometry at sim level; authoring affordance only.
   Attaching **auto-fits from the asset's bounds** (the canonical
   case: one-way line across a platform sprite's full top width),
   points editable after. **Attached colliders edit only while their
   object is selected**; gizmos for everything are **always visible
   in the editor by default** (toggleable), attached ones dimmer when
   unselected.
3. **Tilemap-aware line snapping**: tile edges of placed .tm objects
   are CTRL-snap targets, and **edge-run snap** lays one line along a
   whole contiguous solid run in one click (the long-straight-section
   shorthand; lands with R8d).
4. Dynamic bodies (`body_add/move/remove`, insertion-ordered) stay a
   design slot for R7b's mobs — not on the R8 static path.

**Revisit if**: attached colliders turn out to want sharing across
instances of the same asset (→ default colliders in the .spr/.meta,
placement stores overrides only); circles need real sweeping (→ the
mover grows arc support then, not before).

## D057b — design round 2: named placements; fills + live-apply resolved (human, 2026-07-12)

**Context**: the human's second read of MAPS.md, same day.

**Decision** (folded into MAPS.md §§2/4/5/6/12):

1. **Per-placement colliders confirmed**; placements gain an
   **optional name** for code addressing — `cm.map.get(name)` → a
   handle (read rect, set position/visibility — render-only, like the
   camera). A driven named placement with attached colliders is the
   natural dynamic-body source later (R7b); its static colliders skip
   instancing then.
2. **Graybox fill resolved**: flat untextured polygon fills with the
   gizmo are enough — the checker parity is optional polish.
3. **Live-apply resolved**: Ctrl+S save→hot-reload suffices, with the
   code-ed contract intact (unsaved persists across sessions, journal
   rollback) — which the design already carried; now confirmed.

Remaining §12 opens are defaults, not gates: grid step 8 px (dialable
per window anyway), one-way slopes allowed. R8a is unblocked.

**Revisit if**: name collisions within a map bite (→ editor warns on
duplicate; get() returns first, file order); code wants to *create*
placements at runtime (→ that's an entity/render API question, not a
map-format one — placements stay authored content).

## D058 — R9: audio — the engine core, the sound/music windows, the windowkit (2026-07-13)

**Context**: the human, opening the audio front (the M9 debt): a basic
sound design tool; drag-and-drop mp3/wav/other audio opens a generic
sound player (FM-synth'd ones open in the synth); a music editor
composing designed instruments + samples with stock presets including
gameboy-voice mimics; mouse-driven like everything else; plus
**per-window hotkeys** and the common window patterns **generalized**
so UX changes can't fork per window. Reference surveyed: zexk/wstudio
(a minimal no-plugins DAW guided by a producer). Full design:
**docs/AUDIO.md**.

**Decision** (the load-bearing points; AUDIO.md carries the rest):

1. **The frame lock**: 48000 Hz stereo i16 — exactly **800 samples per
   sim frame**. The sim bank renders per sim step ON the sim thread
   (pure C, fixed-point) into an SPSC FIFO (default 3 frames); the
   audio callback only memcpys. PCM is a pure function of
   (state, commands); state is one versioned named buffer
   (`snd.bank`) → snapshots/traces/rewind for free; **PCM-hash
   goldens**; headless silent by construction.
2. **Two banks** (the D036 split for sound): the recorded **sim bank**
   vs the render-only **editor bank** (PAL-internal state, immediate
   `x_snd_ed_*` API, rendered in the callback for zero-latency
   audition). Goldens can't hear either by construction.
3. **The voice**: 4-op FM (8 OPN-style algorithms, feedback) whose
   operators have **selectable waveforms** (sine/square/pulses/saw/
   tri/**noise-LFSR**) — a single unmodulated op IS a gameboy channel,
   so the chip presets cost nothing. Plus a **sampler voice** (mono
   i16, root note, loop, 16.16 step). 32 voices/bank, deterministic
   stealing. **Kernel discipline: integer/fixed-point only, LUT
   sine/exp, no libm, no float state** — bit-exact across platforms.
4. **Assets**: `.ins` (CINS — one flat defaulted param struct; sample
   type embeds its PCM) and `.song` (CSNG — integer ticks at PPQ 96,
   patterns + bar-clip arrangement, clips copy-on-write and loop to
   fill; playback flattens). Both cm.chunk codecs, pure + KAT'd.
   Presets = stock .ins files (`engine/stock/ins/`), no shipped audio.
5. **The windowkit lands FIRST (R9a)**: `cm.ed.kit.asset` factory
   (the §6 working-bytes/journal contract, hand-copied ×4 today,
   factored once — sprite/map/tmap/text migrate behavior-identical),
   **declarative per-window hotkey tables** (shell-dispatched to the
   focused window, self-rendering hint bar), self-describing kind
   registration (one file per kind), shared header chips +
   viewlock mixin. EDITOR.md §13 records the contract. The audio
   windows are built on the kit, not migrated later.
6. **The windows**: player (kind `sound` — waveform, seek, loop, the
   →ins import door; read-only), synth (kind `synth` — algorithm
   thumbnails, draggable ADSR graphs, audition piano + tracker keys,
   preset strip; full asset citizen), music (kind `music` — piano roll
   on the wstudio four-rule mouse grammar, velocity lane, arrangement
   strip, editor-bank preview). **One grammar exception, deliberate**:
   the roll always snaps to its grid; **CTRL = fine/tick placement**
   (CTRL still reads "the precise variant" in both grammars).
7. **Music is sim state**: cm.snd.seq emits frame-locked commands;
   songs record/replay/rewind like everything else (scrub across a
   track, resume mid-note). v1 ships dry (no effects/automation/swing
   — §13 revisit triggers).

**Build order**: R9a windowkit → R9b PAL core → R9c sound windows +
presets → R9d music window + cm.snd → R9e game sfx/music hookup
(../cosmic2d-game); REVAMP §6 gains R9.

**Revisit if**: 50 ms sim-bank latency reads as lag on sfx (→ shrink
FIFO to 2 frames / smaller device blocks; the editor bank already
proves the low-latency path); the fixed-point FM can't hit a wanted
timbre (→ widen LUTs/rates before reaching for floats); sample-heavy
games bloat ring keyframes (→ static-buffer content-hash flag);
a first real track feels flat dry (→ Freeverb + delay, the proven
3-knob floor, still fixed-point).

**Live-round refinements (the human, 2026-07-13; folded into
AUDIO.md §10, no re-ADR — within-design):** the music window shaped
over four feedback rounds. Round 2: the grid became placement-snap
only (length is last-used; resize to change it), the roll grew the
§12.7 view lock (MMB-pan + wheel-zoom), velocity double-click resets
to 100. Round 3: note selection (shift+marquee / shift+click), and
**pattern length auto-fits its content** (smallest whole bars, min 1;
a fresh pattern is one bar — no stamp padding). Round 4: a **scrub
ruler** (click sets the play-start cursor + paste anchor), **Ctrl+C/
X/V** clipboard, and **Ctrl+drag = duplicate**. That last one
**retires the "CTRL = fine ticks" roll inversion** above — CTRL in
the roll is now duplicate (the universal DAW convention); placement is
grid-only (finer grids + zoom give precision). If a fine-placement
path is wanted back, re-home it on a free chord, not CTRL.

**Round 6 — the model itself (the human: switching tracks/patterns
didn't change the roll).** The earlier FL-style model (shared patterns
placed on tracks via clips) was wrong for the loop workflow: clicking a
track never changed the roll, and playback needed clips the human never
stamped. Moved to the **wstudio per-track model** (the human's original
reference): **each track owns one looping pattern**; the roll edits the
current track's pattern; all tracks loop over `doc.loop1`. The
arrangement strip + pattern chips + clips are **removed** (song mode is
a later growth — the CSNG format stays forward-compatible: `ARRG` reads
+ migrates, TRKS gained `pat`). Loop length **grows to fit, never
auto-shrinks** (the human: "since patterns auto loop we don't need to
auto shrink"). Also fixed a preview crash (`p.flat` rebuilt if an edit
invalidated it mid-play).

**Round 7 — the model, corrected (the human: keep the arrangement).**
Round 6 over-corrected: the human still wants to *arrange patterns as
clips and resize them* — "auto loop" meant a clip loops its pattern
when extended, not that each track is one loop. **Restored the
arrangement** as a two-level model: the arrangement strip (clips) +
**click a clip to DRILL into its pattern** in the roll. Real fixes on
top: **each clip owns its own pattern** — stamping makes a fresh one,
and `normalize` splits any shared pattern (copy-on-write), fixing the
human's "two tracks are the same (edit one, both change)" (a shared-
pattern migration artifact). **Track delete** ("del" per row). Pattern
length grows to fit but never auto-shrinks (clips loop a short one).
The crash fix stays. Round-6 per-track docs migrate to clips; TRKS is
back to v1. Pattern chips removed (drill-down replaces them). Song mode
proper (multiple non-independent placements / a top-level timeline) can
still grow later.

**Round 8 — a batch on the live audio stack (the human), folded into
AUDIO.md §9/§10:** (1) **The first-preset-drop freeze** was
`pal.list_dir` (SDL_GlobDirectory) recursively stat'ing the whole
project tree — including `.ed/history` (thousands of undo-journal files)
— on every assets invalidate; list_dir now prunes dot-directories at the
source (PAL fix, benefits the whole editor). (2) **Pattern REUSE** — the
human wants to place the same pattern multiple times, so round-7's
copy-on-collision retires: `normalize` allows deliberate sharing (heals
only missing patterns), stamping still makes a fresh pattern by default,
and the arrangement gains **ctrl+drag = linked duplicate / ctrl+press =
stamp the active pattern linked** (mirrors the roll's ctrl=duplicate).
(3) **Group velocity + length** — with a selection, dragging offsets the
whole set (CTRL = snap all to one value; one KAT'd core). (4) **Synth
envelope** — the A/D/R times move to a **log axis** (short-end feels
were 1–2 px apart) and the draw/drag mapping is unified (handles jumped
on grab). (5) **Hover-lit resize handles** (clips + notes) and a
**per-track volume panel** (slider + type-in). Proof: KATs
(group_val, env round-trip, sharing round-trips, list_dir prune) +
real-event tapes (ctrl-stamp reuse, group-velocity offset/snap) +
shots. selftest 23063; suite ALL GREEN. Live-feel exit is the human's
ears/hands on the synth drag + the reuse/group drags.

## D059 — the alpha-polish batch: audio primitives, palettes, auto-naming, the demo game, packaging (research-driven, 2026-07-14)

**Context.** Final polish toward an alpha. The human's brief spanned six
streams; three ran as parallel background research/audit agents whose
findings drove the build: (a) a **GB noise channel** DSP study, (b) a
**pixel-art color theory** study, (c) a **shipping-gaps audit** for
"extract the engine and ship a full game." The audit's top-5 blockers
(no packaging path, no demo game, no new-project flow, the type-a-
filename wall, thin stock content) map onto the brief — recorded so the
next session sees the whole picture.

**Decisions.**

1. **Audio: filter + pitch sweep are the missing primitives (R9f).** The
   research settled that the GB noise reads as a *click* not a *sizzle*
   for two reasons — no way to brighten/cut-through (a highpass) and no
   pitch motion over a note (a sweep). Both are added as **voice-wide
   patch fx** (not per-op — simpler, covers the drum/SFX cases): a
   **1-pole filter** (off/lp/hp, cutoff a committed Q16 LUT `SND_FILT_A`,
   ~20Hz–16kHz) and a **pitch sweep** (semitones + ms, gliding every
   op's increment via the existing semitone-ratio LUT). Iron rule kept:
   **both bypass at 0**, stored in the `SndPatch` pad tail + per-voice
   state in the `SndVoice` pad, so every pre-R9f patch and the pinned
   PCM golden render byte-identical. Deferred (the research's 3rd lever):
   per-op filters + a retrigger/loop-gate for machine-gun rustle.

2. **Palettes are HSV-with-hue-shift, not OKLCH (for now).** The color
   research's headline was "interpolate ramps in OKLCH." We shipped the
   ramp generator in **HSV** (value spread + SLYNYRD's warm-highlight/
   cool-shadow hue shift + a saturation bell) because it reuses cm.paint,
   is dev-class-simple, and embodies the load-bearing principles (value
   first, hue shift). OKLCH is the parked upgrade. The **.pal** format is
   a flat ordered color list (CPAL: HEAD+COLS); ramps are a *generator*,
   not first-class named objects yet. Integration by **reuse**: swatches
   live on the canvas, so the existing eyedropper samples them — no new
   picker wiring. 6 stock palettes ship (dmg-4/db16/db32 + originals).

3. **The dictionary is an engine feature, not just an editor helper**
   (the human's steer). `cm.words` (272-word bank + name generator) is a
   `cm.*` module usable from game code for grayboxing/testing text.
   Default RNG is **dev-class** (time-seeded, different every run);
   sim/graybox code that needs determinism **passes its own rng** (e.g.
   cm.rand's stream) and the result is pure over it. The editor's
   `A.pathfield` pre-fills unbound windows with a collision-checked
   3-word name — the naming wall (audit G6) is gone through the one
   chokepoint, covering every asset kind at once.

4. **The demo game lives in the engine repo as `projects/demo`.** The
   flagship game stays in ../cosmic2d-game (D045); the *demo* is
   engine-owned batteries — the packager's default target, the picker's
   showcase, and the new-project template's spiritual source. It reuses
   the real M7 mover (player.lua verbatim, procedural fallback art) so
   it demonstrates *our* movement, across two `.map`-asset rooms (so
   they're editable in the map window) joined by a portal, with per-room
   BGM that swaps and sfx hooked to the moveset. Songs store project-
   relative ins paths; **cm.snd.load_song now resolves them relative to
   the song's project dir** so a self-contained project plays from any
   cwd (and survives packaging's relocation).

5. **Shipping: a flake app packages one project; the picker scaffolds
   new ones.** `nix run .#package -- <proj> [win|linux]` stages a
   trimmed tree (engine runtime + that one project, no tests/no siblings)
   with the launcher renamed to trigger the **R5 play-lock** (D052) and
   README/LICENSE/PLAY.txt included — the audit's #1 blocker (G1/G2/G9).
   engine/ ships whole (the editor code is inert under the play-lock;
   trimming it risks the game's requires). The picker's **"+ New
   project"** tile scaffolds an auto-named project from a runnable
   starter template and opens it in the editor (G5). README rewritten to
   the as-built alpha (G11).

**Consequences.** selftest 23063 → **23082** (+19 KATs); the suite stays
ALL GREEN by construction (defaults bypass; the demo/palette/words are
not golden-bearing). **Revisit triggers:** per-op audio filters +
retrigger if rustle/ambience needs it; OKLCH + first-class named ramps
if the palette editor grows up; a starter-sprite/tileset stock set +
in-editor help + picker metadata (audit G13/G7/G3) when the "batteries"
push resumes. The live-feel exit is the human's ears + eyes on the
drums/SFX, the demo, and the palettes.

## D060 — the gb-noise kernel bug + the map-editor layer/asset rework (2026-07-15)

Two human asks; both surfaced something structural.

**The gb noise was a KERNEL BUG, not a tuning problem.** Sessions had
retuned the gb drums repeatedly and the human still heard no high-range
noise. Rendering the drums headless and looking at the spectrum settled it:
100% of every drum's energy sat below 500 Hz (hat centroid 12 Hz — a DC
click, not a hiss). `wave_sample` stepped the LFSR on `(ph ^ oldph) & MSB`,
but the caller passes `ph = oldph + mod` (the FM modulation), so for an
unmodulated op (every gb drum: alg 7, no mod) `ph == oldph` and the LFSR
NEVER advanced. Freq-clocked noise must step off the frequency increment;
fixed: pass `prevph = oldph - incs[o]`. Tonal waves ignore that arg, so the
PCM golden changes ONLY because its ladder renders a noise op — a
deliberate re-cut (`0xc8826fe…` → `0x9df7dc5…`), the documented "kernel
change re-cuts the golden" path. LESSON: the PCM golden proves determinism,
not musicality — an audio change needs a spectral/audible check, not just a
green hash. (Added a headless render+FFT probe to the toolkit.)

**Map layers/placements are first-class; any asset can attach.** The demo
proved the gap: its maps have zero placements (colliders are the graybox
fill, coins are markers), so the editor "only rendered colliders" because
nothing was placed. The rework (MAPS.md §13):

- **Named LAYERS gate both banks.** A LAYR chunk holds ordered layers with
  two independent flags: `vis` (EDITOR-only render — declutter) and `on`
  (the master switch — an off layer's placements act as if they don't exist
  in-game: no draw, no attached colliders, no ref). This is the split the
  human asked for (hide-while-working vs disable-for-prototyping). Free
  colliders stay layer-independent (level geometry); attached colliders
  follow their placement's layer, which covers prototype overlays.
- **Placement = any asset.** Visual kinds (.spr/.png/.tm) render; every
  other kind — or a visual with `novis` — is a code-addressable NAMED REF
  drawn as a labelled tag. PLCE went to v2 (adds `anim`; layer is a 1-based
  index; bit1 = `novis`, was `hidden`); v1 still decodes (migration).
- **Null refs degrade LOUDLY, never fatally.** `cm.map.ref(name)` returns
  the resolved path or, on a missing name / dangling file, logs a warning +
  a `debug.traceback` and returns a built-in fallback for the kind
  (`engine/stock/error.{ins,song,pal}` + the checker tileset). The editor
  and the game both draw a magenta/black checkerboard for a dangling
  visual. A deleted asset is impossible to miss and never crashes the game.
- **teidraw layer UX.** Clicking a placement auto-selects its layer; a
  `lock` toggle confines picking + new drops to the active layer. The panel
  is per-window state (win.layer/lock/lpanel), not the path-keyed plumb —
  correct for the multi-window contract without needing kit.winui yet.
- **Trivial animation.** A placed `.spr` picks a clip that auto-plays (one
  frame, deterministic off the sim frame in-game / a wall clock in the
  editor). The "just leave it looping" case; code drives anything richer.

REVISIT: markers aren't layered (annotations, always present) — revisit if
a use wants layered markers. Free colliders aren't layerable — revisit if
prototype overlays need disable-able geometry that isn't attached to a
placement. The map window's per-window UI state is hand-rolled on `win`;
fold into kit.winui with the deferred synth/music pass if it drifts.

## D061 — the teidraw map UX + grouping, the rendered help reader, per-window help, sprite-only demo (human, 2026-07-15)

A seven-part human ask, all shipped. Theme: the map editor's direct
manipulation was not teidraw-grade, and help/hotkeys were thin.

**Map: unified direct manipulation + drill.** The three tool-modal gesture
blocks (select/collider/marker) collapsed into ONE model — a shared
gesture-UPDATE dispatch (by `gd.mode`, tool-agnostic), a unified on-hit
`grab_at`, and a tool-specific EMPTY press. Clicking ANY item (a free
collider vertex/edge, a placement, a marker) selects + moves it in the
default tool; **click-again DRILLS** to whatever's beneath (`M.hit_stack`
front→back + `M.drill_pick` step-and-wrap). A collider line moves both
ends together; a vertex moves alone; the sprite under the line is one more
click down. Free colliders became selectable/nudgeable/deletable in every
tool (the keys block's `p.csel` handling lost its collider-tool gate). The
transplanted drag handlers are byte-identical to the old ones — only the
arming + drill are new; the pure cores stay KAT'd.

**Map: teidraw line grammar.** The modal chain (click-click-click-enter)
is retired for the line tool: **drag-on-first-click lays a 2-point line**,
or **click, click** lays one (a rubber-band shows between), then
**shift+click APPENDS** points to the last line (`p.lastcol`). `C` closes
the selected chain. quad/circle unchanged. insert-on-edge-of-selected-chain
dropped (an edge click now moves the whole collider).

**Map: grouping (persisted).** A stable `gid` (0 = ungrouped) rides
**PLCE v3 + MRKR v2** (v1/v2 decode with gid=nil — backward compatible, no
golden touched). Groups span placements + markers (free colliders stay
ungrouped in v1). `ctrl+g` groups (≥2), `ctrl+shift+g` ungroups; clicking a
member selects the whole group (moves together, a faint hull shows the
bounds), click-again drills into the member (`M.drill_chain` inserts a
group level before its first member). Paste re-groups a copied group under
a fresh gid.

**Help: a real rendered reader (not the code grid).** The help window is
now a proper markdown VIEW — headings, wrapped paragraphs, bullets, code
spans/fences, and **links drawn as their link TEXT** (not the `[..](..)`
source). One window navigates in place (click = follow here, **ctrl+click =
a new reader**, an asset link opens its editor via `kind_for`); ◀ ▶ +
mouse back/forward walk history; `docs` = the list home; `src` opens the
raw markdown. Supersedes EDITOR.md §12.2's "docs are a code format, not a
rendered view" — the human asked for the rendered view. `text.resolve_link`
is exposed + shared.

**Per-window help + hotkeys.** Every window's title bar grew a shell-drawn
**? button** → `M.open_help(kind)` opens the kind's doc (`M.help`, else the
editor guide) in the reader. Authored `win-{map,sprite,tmap,synth,music,
sound,palette,assets}.md` (hotkeys + workflow). palette gained a hotkey
table (it had none); the rest already declared theirs.

**Demo: sprite-only visuals.** The demo's look is 100% PLACED sprites now,
editor-visible: a **ground** layer (colliders autotiled into a placed
`.tm`) + a **backdrop** layer (a static hill `.tm`, named, NOT parallaxed).
The runtime graybox + procedural parallax are gone. This also made the
demo's e/g layer toggles *do* something (they had nothing to show/hide
before — the "toggles are broken" report was an empty demo, not a bug).

**Engine-stock resolution, everywhere.** A recurring gap: the editor AND
the game resolved placement/tileset paths only under the project root, so
`engine/stock/*` assets drew a null-ref. Both now try project-root then
engine-root/cwd (`res_path` in the map window, `res_asset` in cm.map,
`tileset_tex` in the tmap window) — the stock-instrument convention. Caught
a Lua gotcha in the fix: `local ok, tex = rp and pcall(...)` truncates
pcall's multi-return to one, silently dropping the texture.

REVISIT: grouping is placements+markers only (colliders need a unified
selection first); the demo backdrop shares the ground's checker tileset so
it blends (art-direction, not structure). D057/D060's map-window sections
are superseded by this direct-manipulation model.

## D062 — atomic persistence begins in the PAL (A1, 2026-07-15)

**Context.** Every overwrite currently uses `SDL_SaveFile`, which truncates
the destination before it knows whether writing will finish. Disk-full,
interruption, or a late close error can therefore replace valid work with a
partial file. Lua cannot portably force buffered data through the OS durability
boundary, and UTF-8 Windows paths must keep using SDL's file opening layer.

**Decision.** PAL API v9 adds `pal.write_file_atomic(path, bytes)`, returning
`true` or `nil,error`. It creates a unique `path.tmp.PID.SEQ` beside the
destination (same filesystem), writes every byte, calls `SDL_FlushIO`, syncs
the native file handle (`fsync` / `FlushFileBuffers`), closes it, then uses
SDL's UTF-8-aware replace rename. No destination mutation occurs before that
last operation. Any earlier failure closes and removes the non-authoritative
temp; an existing destination remains byte-identical. Simultaneous processes
use different temp names. A stale temp is never recovery truth.

The optional `{_fail=stage}` argument is a deliberately explicit KAT seam,
not application policy. Selftest injects `open`, partial `write`, `flush`,
`sync`, `close`, and `rename` failures and proves after each that the known-good
destination is unchanged and no temp remains. It also covers complete and
empty replacement plus a natural missing-directory error. The function is
dev/I/O, never simulation state; traces remain unaffected.

This packet establishes the primitive only. Callers keep their existing
behavior until migrated in small groups with recovery/error UX. Multi-output
sprite transactions need a higher-level protocol and must not be faked by a
sequence of independent atomic renames.

**Revisit.** Add parent-directory durability sync if clean-machine/power-cut
testing finds a supported filesystem where a synced file plus replace rename
can disappear as directory metadata. Replace fixed policy with platform-native
transaction support only if a real multi-file asset requires it.

## D063 — sprite saves publish recoverable generations (A1, 2026-07-15)

**Context.** A sprite save produces one editable `.spr` and three runtime
outputs (`.png`, `.anim`, `.meta`). Independent atomic replacements can still
leave generations mixed after a crash, and the old path ignored failures from
every bake. PNG also wrote directly to a pathname, preventing the complete
generation from being staged before publication.

**Decision.** PAL API v10 adds render/dev-only `pal.png_encode`, the same stb
PNG encoder as `png_write` but returning bytes in memory. `cm.sprite.save`
first encodes all four outputs, atomically writes `<asset>.spr.txn` containing
the complete intended generation, then atomically publishes `.png`, `.anim`,
`.meta`, and finally `.spr`. It always publishes an `.anim`, including the
canonical empty table, so deleting the last clip cannot leave stale runtime
data. Only after all four replacements succeed is the manifest removed and
the document marked clean / asset epoch advanced.

The manifest is recovery truth, not a stale temp: `sprite.load` and the next
`sprite.save` finish it idempotently before proceeding. A corrupt manifest is
an actionable error and is never guessed through. The editor's existing save
error path logs the named failed boundary, opens it as an error in the console,
and retains dirty working bytes. Injected failures cover manifest creation,
each of the four publications, and manifest cleanup; recovery proves matching
source, pixels, empty/non-empty clips, and metadata.

**Consequence.** During an interrupted publication, a runtime process that
does not participate in editor recovery may briefly observe some newer baked
files while the old source remains. The durable manifest makes that state
explicit and repairable; save never claims success. Export validation must
reject or recover outstanding manifests before packaging.

**Revisit.** Add automatic boot-time scanning if assets can commonly be saved
without subsequently being loaded by the editor, or rollback copies if field
testing shows runtime readers observing interrupted generations is harmful.

## D064 — `.ed` has working recovery and derived cache, not one deletion policy (A1, 2026-07-15)

**Context.** `.ed` was described loosely as an untracked cache, but it holds
three different persistence roles. `session.dat` can be the only copy of
unsaved asset bytes, journals are the cross-session undo record, and rewind
history is reconstructible observation data. Treating the directory as one
disposable cache would turn a compatibility recovery action into data loss.

**Decision.** `.ed/owner.dat` is a `CEDO` container with `OWNR v1`, schema 1,
and owner `cosmic2d`. The editor owns the directory and projects do not ship or
commit it. Session plus journals are **working recovery**; history is
**derived cache**. A missing marker is the legacy schema-1 layout and is
adopted atomically without clearing anything. A corrupt marker makes only
derived history untrustworthy: history is cleared, the marker is republished,
and recovery is reported. A foreign or newer marker walls off history and the
editor, preserving the entire directory so an older binary cannot downgrade
unknown data. Validation runs before boot's history scan.

`cm.ed.clear_cache()` is the deliberate compatibility escape hatch: it removes
only rewind-history files and atomically adopts the current marker. It never
deletes session or journals. Failure is logged and opens the console.

**Proof.** Selftests pin legacy adoption, corrupt-marker rebuild, newer-schema
refusal, explicit rebuild, idempotence, atomic marker failure, and preservation
of working recovery at every boundary.

**Revisit.** Add a UI confirmation surface around the explicit command when
project lifecycle/settings UI exists (A3), or split another `.ed` subtree into
a new ownership class if it can neither be rebuilt nor safely read by its own
versioned codec.

## D065 — A7 rewind becomes a full timeline and standalone replay system (human spec, 2026-07-16)

**Context.** R6 proved whole-engine capture, disk spill, frame reconstruction,
editor parking, resume, and asset bring-back, but its hover pill is still a
thin transport over the entire retained range. The human wants the flagship
product surface: minute-scale visual landmarks, a zoomable/pannable ten-minute
view, state-delta activity, A/B clip loops, one-click standalone export, replay
drag-in, and crash reports that lead straight to the preceding minute. Full
design: `REWIND.md` §§10–16.

**Decision.**

1. **A persistent timeline tray supersedes the hover bar.** It opens from the
   pill/F4, defaults to the ten minutes ending at live, wheel-zooms at the
   cursor, and middle-drag pans. A roughly one-minute presented-frame
   filmstrip sits above a log-scaled max-per-pixel activity envelope (separate
   sim/editor/project-file deltas) and explicit code/save/input/restart/error/
   crash events. Index queries never reconstruct frame state.
2. **The left-button grammar is click=seek, drag=A/B.** Releasing a drag loops
   the inclusive range until Esc. Esc first clears clip mode; Esc again closes
   rewind immediately. A clip/export state cannot be bypassed by F4, hover
   collapse, or an outside click. Dropped replay files open persistently and
   use the same two-step Esc hierarchy.
3. **Foreign viewing gets an immutable timeline-source abstraction.** Live
   history, a replay, and a crash-focused source share range/state/activity/
   event/preview/file queries. Loading a replay no longer replaces the live
   ring or adopts its end on close: the live source/present are stashed and
   restored untouched. Resume-from-frame is a live-history action only.
4. **History directory and replay file share one logical segment/blob model.**
   Additive CTRC chunks preserve every old `.ctrace` and golden. A content-
   addressed store deduplicates complete project manifests and file epochs;
   retained segment keyframes reference the manifest that was true there. A
   new UI-exported clip packs state/editor segments, code, every project source
   file and asset reachable from A through B, events, previews, metadata, and
   captured audio when available. It materializes as an isolated replay
   workspace, so the normal editor/asset browser can poke around under the
   parked write wall. This supersedes D055's adopted-history limitation: new-
   format previous-session ranges carry bundle/manifest references and are
   exportable; pre-A7 history is labelled legacy rather than falsely standalone.
5. **Export is one atomic, reveal-on-success action.** The default is a
   timestamped `.ctrace` in engine-root `replays/` (beside `engine/`), then
   Explorer/the platform file manager opens with the result selected. A
   read-only root asks for a writable destination. Video/image/audio rendering
   remains a later consumer of the stable replay artifact, not an embedded
   video editor.
6. **Crash reports carry an exact history locator.** The structured envelope
   names project, history stream, last committed frame, code epoch, error/log,
   and attempted input/evals when available. A contained error pins/embeds a
   one-minute tail; a native failure resolves the newest durable tail on next
   launch. Dropping the report opens and loops the minute before its crash
   boundary. Missing/evicted history fails by identity, never a timestamp guess.
   Partial state from a throwing step is not recorded as a valid frame.

**Consequences.** The present R6 ring remains the state codec, but A7 is more
than drawing a larger slider: it needs summary indexes, preview/media observers,
project-file epochs, a deduplicated blob budget, non-destructive sources, a
platform reveal primitive, and a structured crash handoff. The A2 crash-log
packet should establish the envelope/location now, without prematurely building
the A7 viewer. All new capture data stays observer-only and is ignored by the
determinism verifier.

**Revisit.** Thumbnail cadence may become adaptive if one minute is too sparse
when zoomed in; audio may move to an optional budget class if it materially
shrinks useful history; a cryptographically signed replay trust model waits
until sharing untrusted projects becomes a supported promise.

## D066 — one captured-state lifecycle; loaded maps are state (human correction, 2026-07-16)

**Context.** After switching rooms, parking rewind on an earlier frame restored
the player and collider buffer but drew the map from the present. `cm.map` kept
active path, decoded placements/markers, and named lookups only on the Lua heap;
multi-map level hosts then copied more present-only fields (bounds, tint, title,
markers). This directly contradicted the whole-engine rewind promise and D005's
“Lua heap is never truth” rule. Fixing only `cm.scrub` with `map.reload` would
repeat for every future engine subsystem and every restore entrance.

**Decision.** `cm.state` owns one name-sorted participant lifecycle around the
existing two state forms:

1. `capture()` hooks flush ergonomic Lua handles into ordinary named buffers or
   the canonical doc immediately before every snapshot, ring baseline/frame,
   and verifier comparison.
2. `restore()` hooks rebuild derived handles immediately after every
   `restore_tables`, covering snapshot load, replay load, park/seek/close,
   rewind/resume, verify, and cross-session adoption without caller knowledge.
3. Hooks cannot return private serialized payloads. Captured truth must still be
   a named buffer/doc, preserving one snapshot/trace codec and D005.

`cm.map` is the first participant. A stable `name` slot owns the existing
collider buffer, a `name .. ".mapstate"` `CMRT v1` buffer (active path + canonical
CMAP runtime bytes), and the captured `cm.map.current` slot selector. Map use,
switch, and reload publish both logical map and collision; direct named-
placement table mutations flush at the next capture boundary. Restore decodes
the map state and re-adopts the collision buffer into the same instance/world
table identities. Re-running `map.use` for the same slot/path is restore-
idempotent and adopts captured truth; `fresh=true` explicitly resets from disk.
Cartridge convenience fields copied from a map are revision-keyed derived
caches and must refresh from `inst.rev` before drawing; both bundled multi-map
hosts do so.

**Boundary.** Loaded logical map identity/layout is engine presentation truth
and is captured. Referenced project-file contents (PNG/TM/SPR/audio and source
versions) remain assets; D065's manifest/blob epochs are still required for an
exact standalone historical render after those files change. “Asset” is not an
excuse for mutable engine runtime to live only on the heap.

**Proof.** A focused ring test records map A, switches the same stable slot to
map B, directly moves a named B placement, and restores all three generations.
It pins active path/doc/current lookup, markers, placement mutation, matching
collision, and held instance/world identity. The demo and flagship both boot
with revision-synchronized level views. A second restore with the Lua slot
removed proves CMRT discovery reconstructs the facade without `game.init`; the
full deterministic suite remains the release gate. Old traces retain their
bundled pre-D066 map code and remain readable.

**Revisit.** If participant traversal or a large map's change detection appears
in profiles, add explicit revisioned proxy handles or move the runtime codec to
a PAL helper; do not add subsystem-specific trace chunks or restore calls.

## D067 — per-user diagnostics and exact crash-to-history identity (A2, 2026-07-16)

**Context.** Windows GUI launchers intentionally have no console, extracted
artifacts may be read-only, and the R6 history store had only a project path
plus monotonically continued frames. D065's crash-focused timeline cannot
safely choose “the newest thing around that time”: history may have been
cleared, forked, moved, or replaced. The A2 distribution gate also needs a
useful failure artifact before the full A7 viewer exists.

**Decision.** PAL API v11 adds `pal.user_path()`, backed by SDL's native
per-user writable directory for the fixed organization/application identity
`cosmic2d/engine`. Live interactive processes create `diagnostics/` below it
and flush the C-owned log ring to a unique UTC/PID process log; capped captures
and verification do not create files. The live PAL table exposes the resolved
diagnostics and log paths, so Lua never reconstructs OS policy.

Every durable rewind generation atomically owns
`<project>/.ed/history/stream`, a `CHST` container with an opaque `STRM v1`
`hs1-…` identifier. Contiguous cross-session adoption preserves it. Clearing
derived history or failing the contiguity rule removes it and creates a new
identity; inability to publish the marker disables spill rather than writing
unlocatable history. `cm.trace.ring_locator()` and `hist_locator(project)`
return project, stream, and last fully committed frame. Project path and
display name remain human/discovery hints for now; stream + frame is the exact
local key. A future permanent project UUID can be an additive report field.

`cm.crash` publishes an atomic skip-tolerant `CCRP` container beside the log.
`HEAD v1` freezes report ID, project path/name, history stream, committed and
attempted frames, code epoch, error kind, and log path. Additive chunks carry
UTC/runtime metadata, traceback, attempted input/evals, and recent log text.
Empty stream and frame `-1` explicitly mean unavailable. A contained throwing
step retains its attempted work only as metadata, flushes the open history
segment, and never records its partially mutated state. Engine Lua errors that
escape containment use the same handoff from the C parachute; hard native
failures still leave the line-flushed process log.

**Consequences.** Diagnostics work from GUI and read-only installs and the A7
viewer now has a stable locator/codec to consume without guessing by time.
Reports and logs can contain local paths, code/eval text, and tracebacks, so a
sharing UI must ask before upload. The one-minute pin/embed policy, native-
failure report synthesis on next launch, immutable crash source, drop/view UI,
and log retention controls remain A7 work rather than being hidden in A2.

**Proof.** KATs cover the PAL path, stream creation/adoption/rotation, durable
locator, additive crash decode, binary input/eval metadata, atomic failure
cleanup, unique publication, and disk decode. A live contained-error probe
produces both a flushed process log and `.ccrash` outside the engine tree.

## D068 — release artifacts are checksummed and self-noticing, but alpha is unsigned (A2, 2026-07-16)

**Context.** A portable binary tree redistributes more than cosmic2d's MIT
source: embedded Lua/imgui/audio/image/font work plus SDL and platform runtime
libraries have their own attribution and license conditions. A hash shipped
inside an archive can expose damaged extracted files, but cannot authenticate
the archive that contains it. The project has no signing identity or
certificate and must not turn a plain checksum into a false trust claim.

**Decision.** Every Nix-built dev, editor, and play tree carries the cosmic2d
license, a public third-party inventory, exact common notices, and the selected
platform runtime's upstream notice files. Runtime material is collected from
the exact dependency sources pinned by `flake.lock`; the collector fails when
a component has no recognizable `LICENSE`, `COPYING`, `NOTICE`, `COPYRIGHT`,
or `AUTHORS` file. A final sorted `SHA256SUMS` covers every regular tree file
except itself after all stripping, RPATH edits, executable copies, and launcher
renames. Release trees refuse symlinks rather than silently leaving their
targets unchecked. Packaged zip/tar archives additionally receive a sibling
`<archive>.sha256` whose filename is relative to that sidecar.

Alpha artifacts are explicitly **unsigned**. Their hashes provide integrity
only when the expected value came from a trusted channel; they are not proof
of publisher identity. Official alpha release notes must say this, publish the
archive hash, and never instruct users to disable platform protections. A
future signing packet must establish a stable documented publisher identity,
Authenticode-sign Windows entrances, and attach a verifiable detached
signature to both platform archives before documentation calls any artifact
authenticated.

**Consequences.** Dependency bumps also become notice audits. Project exports
retain the engine notices, but project authors own licensing for assets/code
they add. `SHA256SUMS` verifies extracted contents while the external sidecar
verifies the downloaded archive; neither replaces code signing. Generated
license directories are deliberately verbose and may include upstream notices
for source portions adjacent to the carried library, favoring complete
attribution over a brittle hand-trimmed legal summary.

**Proof.** Packaging KATs cover spaces/non-ASCII, content tampering, symlink
rejection, required legal metadata, and archive sidecar verification. Linux
portable, Windows dev/editor, and both demo play archives carry and verify
their final manifests; the full deterministic suite remains green.

## D069 — clean-machine support is proven from final editor and play archives (A2, 2026-07-16)

**Context.** The first Linux portability probe exercised only a play tarball
and changed its extracted modes while still running as container root. Root can
bypass ordinary Unix write bits, so that was not proof of a read-only install.
It also left the public editor tree, root launchers, native Windows path rules,
and external live diagnostics outside the matrix. A release claim must test the
download shape a user receives, not a Nix store tree or developer staging.

**Decision.** `cosmic-linux-release` and `cosmic-windows-release` wrap the
fully fixed-up public editor trees as `cosmic2d-linux.tar.gz` and
`cosmic2d-windows.zip`, each with the same sibling checksum contract as play
exports. The clean-machine fixtures take one editor archive and one play
archive, verify both download and extracted-tree hashes, extract beneath paths
with spaces and non-ASCII characters, launch from an unrelated cwd, and run
every public editor/game/diagnostic entrance.

The Linux leg uses stock x86_64 Debian 13 plus its software Vulkan driver and
runs cosmic2d as unprivileged uid 65534 after a root-owned `a-w` transition.
It rejects Nix-store dynamic resolution, proves direct write attempts fail, and
requires interactive logs beneath an isolated `XDG_DATA_HOME`. The Windows leg
is a PowerShell 5.1 fixture runnable without WSL or developer tools. It applies
an inheritable NTFS deny ACE only to mutation rights (not generic `W`, whose
`SYNCHRONIZE` overlap would also prevent execution), drives both GUI and console
PEs, and requires fresh logs beneath the native roaming AppData root. Its WSL
shell wrapper is only a local copy-and-invoke convenience.

The matrix owns the self-location boundary it exposed. Portable Linux root
launchers retain executable bits and use `$ORIGIN/lib`; `bin/` launchers use
`$ORIGIN/../lib`. Windows converts SDL's UTF-8 executable base path to UTF-16
and calls `SetCurrentDirectoryW` instead of the active-code-page `_chdir`.

**Consequences.** The A2 clean-machine checkbox is complete for the supported
x86_64 Linux/glibc and Windows desktop envelopes. This does not claim macOS,
other architectures, signing/authentication, arbitrary-project export, or that
the current play packet is suitably player-facing; those remain explicit
gates. Permission checks must continue under a genuinely restricted identity
or ACL, and any new public launcher/archive shape joins both matrices.

**Proof.** Fresh editor and demo play archives pass all entrances from
read-only Unicode paths in Debian 13/Podman and native Windows 11. Both produce
exactly the expected external interactive logs while capped runs produce none,
and both extracted manifests remain unchanged afterward. Native Windows and
Linux selftests pass at 23,300 checks; every committed trace and pixel golden
passes in the full suite.

## D070 — a play archive has project-owned player identity over an inspectable engine (A2, 2026-07-16)

**Context.** The D069 play archive was technically portable but opened with a
bin-only launcher, the engine authoring README, and cosmic2d's application
identity. `project.lua` exposed a display name/version/description but had no
binding contract for an icon, controls, credits, or project-local legal terms.
Calling that shape player-facing would make the first file a player saw explain
how to build an engine project, while leaving the actual game's controls and
license implicit.

**Decision.** A publishable project's declarative `project.lua` now requires
`name`, `version`, `description`, optional `author`, and four project-local
release references: `icon`, `controls`, `credits`, and a non-empty `licenses`
array. References use canonical forward-slash relative paths and may not contain
absolute/drive prefixes, backslashes, empty/`.`/`..` segments, or link-breaking
characters. The icon is a square 32–1024 px PNG; player text and license files
must exist, be non-empty, bounded text. The release helper evaluates the table
in an empty Lua environment and fails before archive publication on every
schema/reference error. This is the first export validator, not permission to
execute arbitrary configuration code during packaging.

The helper replaces the engine README with a concise project-derived player
README and plain-text quick start, copies the validated icon to the root, embeds
controls and credits, and links every author-supplied project license plus the
separate engine/runtime notices. The selected editable project and all tooling
remain present under the D052 contract. The game's root launcher is the obvious
entrance; the deliberate `bin/cosmic2d-editor` entrance remains available but
secondary.

On Linux the root launcher is the locked engine with a root-relative
`$ORIGIN/lib` RPATH. On Windows the root file is a tiny GUI-subsystem Unicode
launcher carrying project-derived multi-resolution icon and exact title/version
resources. It delegates argv with `CreateProcessW` to the same-named locked
engine under `bin/`; engine/editor/diagnostic PEs retain truthful cosmic2d
identity. PAL API v12 adds `pal.x_window_icon(PNG)` so the project icon also
owns the live taskbar/window identity on both platforms. Every boot/switch
applies either the safe project icon or the carried canonical fallback, since
the SDL window survives project switches.

**Consequences.** A missing player file is now an actionable packaging failure,
not a half-described archive. Project authors remain responsible for their own
code/asset licenses; cosmic2d's license and exact dependency notices are still
mandatory and separately labelled. The icon is intentionally duplicated at
the project and archive root for inspectability. Windows numeric version tuples
derive from up to four numeric components while Explorer's string retains the
exact project version. The developer packager still selects only projects
already captured by the Nix source tree; arbitrary opened-project selection,
settings UI, progress/failure UX, and output choice remain A3.

**Proof.** Metadata fixtures pin generated Linux/Windows player surfaces and
reject escaping and missing references. PAL headless tests accept a valid PNG
and report corrupt bytes. Final Linux and Windows editor + play archives verify
both checksum layers, expose every root/bin entrance from unrelated Unicode
paths under real read-only permissions, retain external diagnostics, and keep
their trees byte-valid afterward. Native Windows additionally pins project PE
title/version resources, Unicode argv delegation, and a real windowed project
icon application; Debian 13 pins both root ELF RPATH/launch paths. `nix run
.#test` is ALL GREEN at 23,302 self-checks with every trace and pixel/audio
golden unchanged.

## D071 — project settings are a canonical view over shared source bytes (A3, 2026-07-16)

**Context.** Boot, the picker, and D070 packaging each evaluated `project.lua`
with locally copied rules. An in-editor form could easily become a fourth
interpretation or maintain a second working copy that overwrote simultaneous
code-window edits. Numeric fields also need to represent temporarily invalid
typing without making an invalid render configuration authoritative.

**Decision.** `cm.project` owns one empty-environment/plain-data decoder,
runtime/settings/D070 validators, field merge, and deterministic inspectable-Lua
encoder. Boot and the picker use that decoder; the host player-bundle helper
loads the same pure module and uses its release schema before checking files.
Top-level project keys are strings and values are finite plain data. Canonical
output orders the supported fields first and then preserves extension keys.

The project-settings canvas window is a structured view over the text
citizen's `project.lua` working bytes and journal. Its captured form holds
invalid intermediate strings. Save decodes the latest shared bytes, merges
only name/author/version/description, internal width/height, initial integer
scale, and start-maximized, then journals and atomically saves the canonical
replacement. Concurrent source edits to other keys survive. Validation errors
stay in-window; write failures summon the console, preserve the previous disk
generation, and retain complete dirty bytes for retry. Resolution/window policy
applies on next launch rather than rebuilding the running target.

**Consequences.** Existing declarative projects remain compatible, including
project-specific plain-data extensions; global-dependent config and non-data
values are now rejected consistently with the release contract. A settings save
intentionally normalizes comments/formatting into canonical Lua. The form and
project file belong to editor/project-file history, not sim state, so existing
session and rewind boundaries cover them without a new deterministic record.
Icon/legal pickers and export configuration remain later A3 packets.

**Proof.** Focused KATs reject ambient code and non-data, prove codec fixpoint,
D070 path validation, extension preservation, typed field validation, atomic
failure/retry, shared source/form merge, and visible invalid-form refusal. A
1280x800 editor capture verifies the complete window at 100% canvas zoom.

## D072 — release references are one validated project-local settings packet (A3, 2026-07-16)

**Context.** D071 deliberately left `icon`, `controls`, `credits`, and
`licenses` as source-only fields. Merely adding four path text boxes would still
force authors to know project layout, let the editor and D070 packager disagree
about file contents, and allow a half-configured table to look intentional.
The editor has no native filesystem dialog, but its asset-import path and flat
project walk already provide the right project-local boundary.

**Decision.** Project settings now has **general** and **player files** tabs.
The latter provides editable relative paths plus fuzzy choosers for a PNG icon,
controls/credits text, and an ordered add/remove/pageable license list. The
candidate walk includes conventional extensionless `LICENSE`, `COPYING`,
`NOTICE`, and `COPYRIGHT` names; OS drops remain the one import path and
invalidate both candidates and validation caches.

`cm.project` owns the referenced-byte contract behind an injected reader, so
both PAL-backed editor code and ordinary host Lua call the same checks. Icons
are bounded PNGs with a square 32–1024 px IHDR. Controls, credits, and licenses
are bounded, non-empty, NUL-free text normalized for generated README use.
Paths still use D070's safe project-relative grammar. Per-row editor probes are
mtime-cached ephemera; Ctrl+S and packaging always perform a fresh full check.

An entirely absent release packet remains a saveable draft for compatibility
and incremental game work. Once any release reference is present, settings
require the complete schema and valid saved contents before atomically
publishing `project.lua`. **clear release** is the explicit return to draft.
This makes incomplete intent visible without blocking unrelated draft saves and
prevents a started release configuration from being saved as falsely ready.

**Consequences.** A fresh project can import and select all player metadata
without editing Lua. Invalid/unsafe/missing/wrong-type files stay actionable in
the form and cannot cross its save boundary. Source-side extension keys still
merge through the shared text citizen; release keys are now deliberately owned
by the structured form. Build targets, output choice, arbitrary-root packaging,
progress, cancellation, and artifact publication remain the next A3 packet.

**Proof.** Focused KATs cover draft/partial policy, normalized valid content,
missing files, binary text, wrong icon type/shape, picker mutation, live window
validation, and save refusal without disk mutation. Host release fixtures prove
the same canonical module rejects wrong-type icon and controls selections.
`nix run .#test` is ALL GREEN at 23,330 checks with every committed trace and
pixel/audio golden matching; fresh Linux and Windows demo exports both build.

## D073 — durable history is an async ordered pair; ephemeral owners dispose handles (A7 stability, 2026-07-16)

**Context.** Native Windows testing exposed two independent live-session
failures. Closing each 60-frame rewind segment called the fully durable atomic
writer and cumulative-index replacement directly from `record_frame`; an NTFS
`FlushFileBuffers` took 89.8 ms in a measured 92.6 ms sim frame, which starved
the low-latency audio producer. Separately, each A/B seek discarded the sprite
window's `g.sw` Lua cache without freeing its raw PAL texture. The next editor
draw allocated another slot until the fixed 256-slot table failed and the
contained draw error showed the dark crash backdrop. Both failures were engine
ownership bugs, not corrupt retained history.

**Decision.** PAL API v13 adds a bounded, process-owned FIFO worker for ordered
atomic file pairs. Submission copies both paths/payloads and returns a job ID;
poll is nonblocking; drain is an explicit durability barrier. The worker fully
writes, flushes, OS-syncs, closes, and atomically replaces file one before file
two. It skips file two when file one fails and removes file one if file two
fails, preserving the segment→manifest authority order. The queue is capped at
16 jobs / 64 MiB and refuses overflow rather than blocking the caller or
growing without bound.

`cm.trace.record_frame` now only marks closed segments ready. Render/dev
maintenance serializes them and submits segment + cumulative index pairs;
completion makes a segment demotable. Queued/in-flight segments remain pinned
in RAM. Ordinary frames only poll. Quit/crash, structural rewind/truncation,
replay replacement, explicit cache clear, and VM/project handoff drain before
relying on disk or deleting history. Failure keeps RAM authoritative and
disables further spill.

Editor window kinds that own non-GC resources now expose `drop_ephemeral`.
Park and unpark invoke every owner hook before clearing decoded caches and
audio preview plumbing. Sprite and animation owners call deferred
`pal.tex_free` and nil their IDs, so repeated A/B seeks retain only the small
in-flight deferred-delete set instead of leaking one texture per frame.

**Consequences.** Periodic durable storage latency can no longer appear in sim
timing or starve frame-locked audio; render-side serialization may still appear
as ordinary draw work, while disk sync is entirely on the worker. Normal exit
can wait for durability, intentionally. A failed/full worker queue loses only
derived disk retention, never live rewind RAM or sim determinism. Future editor
caches owning PAL handles must add the disposal hook rather than relying on Lua
collection.

**Proof.** PAL KATs cover successful pair ordering and second-publication
rollback. Rewind KATs prove segment close invokes no synchronous atomic writer,
background drain/adoption/rewind/budget semantics, and injected segment/index
failure behavior. Editor parking KATs prove sprite and animation texture owners
are called on park and unpark. The complete deterministic and native Windows
proofs are recorded in `STATUS.md`.

## D074 — rewind playback follows wall time; editor accessibility has two machine-local scales (2026-07-16)

**Context.** Rewind playback advanced one recorded frame every render call.
That happened to resemble 1× only when presentation was exactly 60 Hz; an
uncapped or high-refresh editor replayed the moment too quickly. Separately,
canvas zoom could enlarge canvas-window text, but fixed native surfaces such as
the HUD, launcher, and rewind tray stayed in tiny physical pixels. One global
scale would either change the captured camera or leave one of those surfaces
unusable, especially on an unscaled 4K display.

**Decision.** Rewind transport uses a wall-clock accumulator against the fixed
60 Hz trace frame period. A newly selected A/B loop or replay presents its first
frame for a complete draw. Thereafter the default 1× rate advances only when a
recorded frame period is due; 2×, 4×, and 8× are explicit transport choices. If
multiple frames become due before a draw, the playhead advances across all of
them but restores only the resulting frame. Inclusive loop arithmetic still
presents B before wrapping to A.

The native editor has two independent render/dev multipliers. `editor_scale`
composes with the captured logical camera zoom for canvas windows and text;
`chrome_scale` creates a matching virtual draw/input space for the project
picker and fixed HUD, menu, launcher, drag-ghost, and rewind surfaces. Both
offer 75–300% manual steps. Auto mode keeps ordinary 1080p at 100% and chooses
the larger of SDL display
scale and conservative window-pixel density, including a 200% unscaled-4K
default. The values and auto flag persist in machine-local `editor.dat` under
the existing `pal.user_path()` root, so one choice covers the picker and every
project. A missing/old file enters auto mode. No PAL API addition is needed.

**Consequences.** Rewatching at 1× now consumes the original wall time on any
render refresh; a slow renderer drops intermediate presentation frames rather
than stretching the transport, while state truth remains the exact recorded
frame at the playhead. Logical camera state, editor sessions, histories,
traces, verification, and packaged projects never contain display preference.
Canvas content and fixed chrome can be made legible independently, and changing
one cannot desynchronize its pointer hit testing.

**Proof.** Clock-injected rewind KATs pin the initial hold, no-early-advance,
exact 1× steps, inclusive B/wrap, and deliberate 2× skipping. Camera KATs pin
scaled world/screen inversion and fit; chrome KATs pin equal draw/input virtual
coordinates; viewport KATs pin 1080p, DPI, 4K, persistence, and corrupt-scale
rejection. The complete Linux/native-Windows run and visual evidence are
recorded in `STATUS.md`.

## D075 — in-editor export streams the saved project with its carried host runtime (A3, 2026-07-16)

**Context.** D070–D072 made player metadata canonical and editable, while the
Nix packager proved the desired player archive. It still captured only projects
named in the source tree and required a developer shell. A public editor already
contains one tested portable runtime, but it does not contain the other OS's
runtime or toolchain. Copying a live editor document would also make an export
silently disagree with Ctrl+S, recovery, and the files another process sees.
Shelling out to `tar`, `zip`, or a compiler would reintroduce exactly the host
knowledge A3 removes.

**Decision.** `cm.export` packages an arbitrary project root with the runtime
carried by the running editor. Linux emits `.tar.gz`; Windows emits `.zip`.
The other visible target is refused with a direct instruction to use that
platform's editor download. This is honest host matching, not a cross-build
claim. Archive writers are small Lua implementations: deterministic ustar in
gzip stored-deflate blocks and ZIP32 stored members. They stream through PAL
append calls, hold at most one input file plus ZIP directory metadata, sort the
walk, reject links/reparse points and unsafe names, and cap unsupported ZIP32
sizes/counts. Project `.ed` recovery state and `video.dat` machine policy never
ship.

The exporter reuses `cm.project` validation and the D070 canonical
README/PLAY/icon surface. It adds every extracted file's exact hash to
`SHA256SUMS`, hashes the finished archive into a sibling `.sha256`, and includes
the runtime-library inventory/notices. Windows public editors carry a dedicated
stripped `cosmic-player.exe` delegating template. PAL's Windows-only resource
seam writes the validated project icon, title, version, author, and internal
slug into a private copy before that root launcher enters the ZIP; the engine
binaries retain cosmic2d identity.

PAL API v14 supplies platform-identical SHA-256/rolling CRC-32, link-aware path
inspection, Windows launcher identity, and `x_file_publish`. Publication first
syncs a complete sibling temp and then performs the one authoritative rename.
An existing name is refused unless the user checks explicit replacement; a
failed replacement preserves the earlier artifact. Cancellation is observed at
file boundaries and removes the temp. The output archive is never exposed as a
partially written file.

The project window's third tab owns target, output location, explicit replace,
preflight, progress, cancellation, terminal path/hash, and retryable errors.
Operation state lives only in `cm.ed.g`, never the captured window or project.
Preflight refuses rewind-past state and any settings/code/sprite/map/tilemap/
palette/instrument/song working bytes that differ from disk, naming the first
asset to save. The build re-reads all authority from disk. Switching tabs does
not stop progress; Alt+right-click close, Esc dismissal, and F4 rewind are
guarded until explicit cancellation or completion. Quit removes a remaining
temp.

**Consequences.** A downloaded editor can export the currently open project
without Nix or filesystem layout knowledge, including a project outside the
engine tree. It cannot export unsaved experiments by accident and cannot claim
cross-platform output it does not carry. Stored compression favors a compact,
auditable implementation over smallest archives; revisit ZIP64 or compressed
deflate only when real projects exceed the current limits or size becomes a
measured release problem. Alpha checksums detect changed bytes but remain
integrity, not publisher authentication or signing.

**Proof.** PAL/export KATs cover hash vectors, rolling CRC, link/type probes,
implicit overwrite refusal, explicit replacement success/failure, matching-host
construction, wrong-host refusal, exact archive/sibling hashes, cancel, and
failed publication. UI KATs cover dirty-asset preflight and close/Esc/rewind
guards. Linux passes 23,401 checks and native Windows 23,403 on API 14. A
writable public Linux bundle exported an external spaced-path project through
the UI to a 30.5 MiB archive; the freshly staged native Windows editor did the
same to a project-branded 38.9 MiB ZIP. Both outer hashes and every extracted
`SHA256SUMS` entry verify. Visual evidence and the complete release matrix are
recorded in `STATUS.md`.

## D076 — external projects stay in place; project switches cross recovery barriers (A3, 2026-07-16)

**Context.** The picker could create projects only below the carried
`projects/` directory. An externally opened project became recent only after a
successful command-line boot, missing paths could only be pruned through a
small `x`, and an editor had no route back to the picker. Copying a selected
folder would create two divergent authorities. Calling SDL's folder-dialog
completion directly into Lua would cross both the main-thread and VM-lifetime
boundaries. A raw editor reboot could also discard a pending text gesture,
`session.dat`, an active export temp, or the exact rewind tail.

**Decision.** **Open folder** registers a project root in place; cosmic2d never
copies or claims ownership of it. PAL API 15 starts SDL's asynchronous native
folder chooser and exposes a pollable process-owned mailbox. Its callback only
copies UTF-8 bytes under a mutex and never enters Lua. `cm.project` normalizes
host separators and validates selected `project.lua` bytes through the same
declarative/runtime contract as boot. Only then does one atomic recents update
make the root newest and deduplicate legacy spellings before the editor switch.

Refresh invalidates the picker's metadata scan immediately. A missing/invalid
recent tile remains visible: **repair** atomically replaces its old root with a
validated selection, while **remove** forgets only the convenience entry. The
list stays newest-first. The editor's fixed **← projects** action uses the one
`cm.main.switch_project` carrier door. It refuses an active export, returns
from parked rewind to the live present, closes pending text into journals,
atomically saves the session, releases ephemeral owners, stops an explicit
recording, and drains/spills history before rebooting into picker mode. The
carrier outranks original command-line project arguments so direct `--edit`
entrances can return too.

**Consequences.** A public editor can adopt and revisit a project anywhere the
user can select without inventing an import-copy policy or requiring a shell.
Recents are pointers, not project storage: removal never deletes bytes, and a
moved/deleted root is repaired explicitly. Dialog and picker state remain
render/dev ephemera and never enter snapshots or deterministic input. Folder
copy/move/duplicate/archive, search/sort/keyboard navigation, thumbnails, and
large-list scrolling remain separate A3 packets.

**Proof.** Focused KATs cover API/headless behavior, path normalization,
selected-folder boot validation, atomic recents failure, repair promotion and
deduplication, and the active-export return guard. Scripted captures prove an
external spaced-path project opens, returns to the picker, and remains the
first recent tile after a fresh process. Full Linux/native-Windows counts and
public-archive proof are recorded in `STATUS.md`.

## D077 — project-folder moves are no-replace, same-filesystem transitions with a durable repair pointer (A3, 2026-07-16)

**Context.** D076 can adopt a project wherever it already lives, but changing
that location still required a file manager. A generic SDL rename replaces an
existing destination and a cross-volume directory move implies recursive copy,
rollback, and delete policy—the same hard boundaries as duplicate/archive,
which this first location packet does not yet own. Updating `.recent.dat`
before the filesystem would point at bytes that might never move; updating it
afterward can fail even though the move is already authoritative. The active
editor also has watchers, recovery state, journals, textures, and history tied
to its root and must never be relocated underneath itself.

**Decision.** A ready **recent** tile owns one `...` folder menu: **reveal**
opens the project directory, **rename folder** edits only its final path
component (the project title remains in settings), and **move folder** chooses
an existing destination parent through the native folder chooser. These are
picker-only render/dev operations. The source must already be recent so a
durable recovery pointer exists, and returning from an editor crosses D076's
teardown/durability boundary before its tile can act.

`cm.project_location` preflights the exact boot-valid source, a real non-alias
directory, inactive ownership, an absent non-descendant destination, existing
directory parents, and create/delete authority in both parents through unique
empty-directory probes. PAL API v16 repeats source/type and destination checks
at the native boundary, then performs an atomic no-replace directory rename:
Linux uses `renameat2(RENAME_NOREPLACE)` and Windows uses UTF-16
`MoveFileExW` without `MOVEFILE_REPLACE_EXISTING`. Different filesystems,
drives, or volumes fail explicitly; they do not fall back to a partial copy.
Reveal delegates to the native host opener: Windows converts the original
UTF-8 path to UTF-16 for `ShellExecuteW`, while Linux percent-encodes it into
a UTF-8 `file:` URI for SDL's desktop-file-manager handoff.

The filesystem transition happens first. Only its success permits one atomic
`recent.replace(old,new)`. A native failure leaves the working source and old
recent entry untouched. If the recents write alone fails afterward, the move
is reported with its exact destination and the old now-stale tile remains
visible as the explicit **repair** route; the engine neither lies that the
move failed nor risks an unsafe rollback over intervening filesystem changes.

**Consequences.** Normal same-volume rename/move and reveal need no terminal,
handle spaces and non-ASCII losslessly, and cannot overwrite another folder.
Cross-volume move awaits the recursive transactional copy work shared with
duplicate. Another cosmic2d process is outside this process-local ownership
check; the native OS still refuses locked/in-use roots where required.
Duplicate, archive/delete confirmation, richer picker navigation, and template
breadth remain later A3 packets.

**Proof.** PAL KATs pin collision preservation, injected native failure,
spaced/UTF-8 directory success, and non-mutating reveal failure. Policy KATs
pin unsafe names, active ownership, required recency, collisions, parent
permissions, native failure ordering, post-move recents recovery, and real
PAL-backed move/rename plus atomic recents. Inspected 100% and 300% picker
captures cover the folder and rename overlays; full platform/release proof is
recorded in `STATUS.md`.

## D078 — duplicate is a staged, cancellable copy published by one no-replace rename (A3, 2026-07-16)

**Context.** D077 relocates a project without copying bytes, but starting a
variant of an existing project still required a file manager and manual
knowledge of which files are project source. A naive recursive copy directly
into the destination can be interrupted into a half-project the picker would
happily boot, can silently follow links, and would drag along machine/editor
state (`.ed` journals and history, machine-local `video.dat`) that D052/D074
define as never being project source. Large trees also need visible progress
and a safe cancel, which a single blocking call cannot give the picker.

**Decision.** Duplicate is a picker-only coroutine job in
`cm.project_location` (`duplicate_start/step/cancel`), the first consumer of
the shared recursive copy primitive reserved for the later cross-filesystem
move. Preflight refuses the active editor root, self-nesting destinations,
existing destinations, alias sources, links inside the tree, invalid source
projects, and unwritable destination parents before anything is written. The
saved project is then copied one file per step into a unique **dot-prefixed
staging sibling** of the destination — `pal.list_dir` prunes dot-directories,
so neither the picker scan nor the copy walk can ever observe a half-copy, and
`.ed`/dot tool state is omitted by the same rule while `video.dat` is excluded
by name. The staged root must revalidate through the exact boot contract, and
the only authoritative transition is one atomic no-replace rename (PAL API 16
`x_path_move`) followed by an atomic `recent.note`.

Any earlier failure or a cancel removes the staging tree and publishes
nothing; the source is never written. A recents failure after publication
reports the exact new root instead of pretending the duplicate failed, since
**open folder** can register it. A hard process kill mid-copy can strand a
staging directory, but its dot prefix keeps it invisible and unbootable, and
it lives in the user-chosen destination parent, never inside a project. Esc
and outside clicks on the running modal request cancellation; they cannot
abandon the job. The name field defaults to `<source folder> copy` under
D077's folder-name grammar.

**Consequences.** Users can fork a project from the picker with no terminal,
across spaced/non-ASCII paths, with honest progress and cancel. A duplicate is
a clean checkout: it opens with fresh editor state and no inherited undo
history. Dot-directories such as `.git` are deliberately not copied (matching
the export contract); authors who want tool state must copy it themselves.
Cross-filesystem move can now reuse `remove_tree` and the staged-copy shape,
adding delete-after-verify policy. Archive/delete confirmation and picker
navigation remain later A3 packets.

**Proof.** Fake-fs KATs pin every preflight refusal, machine-state omission,
recents ordering, injected read/write/publish/recents failures, and mid-copy
cancel, each leaving the source byte-identical and no staging behind; real-PAL
runs prove spaced/UTF-8 duplication, injected atomic-write and publish
failures against real staged files, and `.ed`/`video.dat` omission. Inspected
100% and 300% captures cover the menu, ready modal, mid-copy progress on a
3,000-file fixture, and the published newest-first tile; platform/release
proof is recorded in `STATUS.md`.

## D079 — archive is a dated no-replace backup; delete is confirmed, tile-anchored, and always finishable (A3, 2026-07-16)

**Context.** D078 completed copy-shaped project actions, but backing a
project up or removing it still required a file manager. A backup that
silently replaced an earlier one, or a delete that could vanish a folder on a
misclick — or strand an interrupted half-tree with no in-picker recovery —
would violate the failure-safety line the location packets established.
Deletion also has to remove `.ed` journals and other dot tool state that
`pal.list_dir` deliberately prunes from every ordinary caller.

**Decision.** Both actions are picker-only coroutine jobs in
`cm.project_location` sharing one job harness with duplicate. **Archive**
streams the saved-project walk (identical `.ed`/dot-state and `video.dat`
omission and link refusal as duplicate) through the shared `cm.archive`
writer — the stored-block tar.gz/ZIP32 encoders extracted from `cm.export`,
now with explicit directory members — into a dot-prefixed temp beside a
user-chosen destination parent, published by one atomic no-replace
`x_file_publish`. The name is derived, `<folder> <yyyy-mm-dd>[ (n)]` with the
first free suffix, so same-day backups accumulate and a race still cannot
overwrite one. Every failure or cancel removes the temp; the source is never
written.

**Delete** is the one deliberately destructive job and is triple-anchored:
the exact folder name must arrive as `opts.confirm` (typed in the modal, or
armed by a just-made archive in the same modal session as the two-step
safety-net path); the source must hold a recent tile, which stays in place as
the recovery handle until the whole tree is gone; and the active editor root,
aliases, and links anywhere in the tree are refused before the first removal
(a walk behind a directory link reaches files outside the project). PAL API
17's `x_list_dir_all` — the unpruned twin of `list_dir`, sanctioned only for
read-to-delete — enumerates dot state. `project.lua` is removed first, so an
interrupted delete can never leave a bootable half-project; project validity
is deliberately NOT required, and broken-but-present recent tiles keep a
delete door, so a partial delete always remains finishable from the picker.
The root removal and the atomic recents removal share the final unyielding
step; a recents failure afterwards names the honest missing tile.

**Consequences.** Users can back up and destroy projects from the picker
with no terminal, across spaced/non-ASCII paths. A dated archive extracted
anywhere re-imports through **open folder**. Deleting removes unsaved
editor recovery state by design — the typed confirmation and the
archive-first path in the same modal are the counterweight. `cm.export`
stays host-loadable (no `cm` at module scope) and mirrors the ZIP32 limits
under a selftest pin. Cross-filesystem move can now compose duplicate's
staged copy with delete's confirmed removal.

**Proof.** Fake-fs KATs pin refusals, dated unique naming, omission,
injected append/publish/remove/recents failures, cancel, project.lua-first
ordering, and half-tree retry; real-PAL runs decode the published containers
byte-exactly and prove partial-delete honesty plus the pruned/unpruned
listing contract. Fresh public Linux (stock Debian 13, incl. a read-only
install) and native Windows archives ran the full external spaced/π
archive → re-import → injected-partial-delete → retry → delete matrix.
Inspected captures are on llm-feed; platform/release proof is in `STATUS.md`.

## D080 — the picker scales: scrolling, search/sort, thumbnails, and a mouse-free grammar (A3, 2026-07-16)

**Context.** The picker drew only the tiles that fit the window, so a
library larger than one screen was simply unreachable, and every action —
opening, the `...` folder menu, repair, delete — required a mouse. The
remaining unchecked A3 picker line asked for large-list scrolling, sort and
search, keyboard navigation, and thumbnails, all inside the 100–300%
fixed-chrome contract and without any new persistent state.

**Decision.** The list model and navigation math live in a new pure module,
**`cm.pick`**: ASCII-case-insensitive plain-text filtering over name, path,
and author (non-ASCII bytes compare exactly; queries are never patterns), a
stable name sort with a path tiebreak beside the default recents-first
order, row-major grid cursor movement (clamped, column-preserving `up`,
`down` off a full bottom row lands on the last cell, `pgdn` always reaches
the end), and scroll clamp / smallest-change ensure-visible. The picker UI
consumes it: the tile grid clips under a two-row header (title/actions,
then search + sort toggle + an honest "N of M projects" count) and scrolls
by wheel, draggable scrollbar with page jumps, and PgUp/PgDn. Arrows move a
cursor ring ("+ New project" is the grid's last cell), Enter opens the
editor (Shift+Enter plays; on a broken recent tile Enter opens the repair
chooser), `.` opens the `...` folder menu, Del opens the confirmed delete
door, `/` or Ctrl+F focuses search, and Esc clears the filter. Every modal
button row cycles with arrows/Tab + Enter on a safe default (close/cancel
for archive-success and delete); text fields keep Enter as their own
submit, a just-submitted Enter never double-fires a button, and the search
field goes inert while a modal owns the keys. Thumbnails turned out cheap
after all: the declared `icon` rides `cm.gfx`'s memoized texture cache with
per-path failure memoization, and refresh forces one re-read. All of it is
ephemeral render/dev state.

**Consequences.** A picker holding dozens of projects can reach, filter,
and open any of them without a mouse at any chrome scale, which also
unblocks A4's binding-display work from assuming pointer-only surfaces.
The keyboard grammar reuses the existing scancode conventions (kit's SC
table) rather than inventing a hotkey layer for one cartridge. `cm.pick`
stays host-agnostic pure Lua, so future surfaces (launcher lists, asset
choosers) may adopt the same nav math. Starter templates are now the only
open A3 line.

**Proof.** Selftest KATs pin filtering (case folding, plain-text-not-
pattern, UTF-8 bytes, order preservation, empty results), the name sort's
tiebreak and non-mutation, every cursor clamp/landing rule, degenerate
grids, scroll clamping, and smallest-change ensure-visible. `nix run
.#test` is ALL GREEN with every historical trace and pixel/audio golden
unchanged. Inspected 1280×800 captures on llm-feed cover the 39-project
scrolled grid with clipped tiles and scrollbar, the live search with count,
300% fixed chrome (single scrollable column, complete header), the folder
menu and delete modals with their keyboard rings, and mixed
thumbnail/plain tiles; platform/release proof is recorded in `STATUS.md`.

## D081 — starter templates: a chooser on + New project, scaffolded from stock sources (A3, 2026-07-17)

**Context.** The last open A3 line: creation offered only the embedded
blank scaffold, so a new user's first playable code was always the same
eight-line hello. The roadmap asks for Blank, Platformer, Top-down, and
Arcade starters with random three-word names staying the instant default,
reachable from a fresh archive without a terminal, without growing the
picker grid, and without weakening the atomic scaffold contract.

**Decision.** **`cm.project.TEMPLATES`** is the one registry (key, label,
chooser note, optional stock source path); `template()`/`template_main()`
resolve it, with `nil` meaning blank so every existing `scaffold(dir,
name)` caller keeps its exact behavior. Blank remains the embedded
`MAIN_TMPL`; platformer, top-down, and arcade are real, readable one-file
games under **`engine/stock/templates/`** — deliberately naive per the A5
contract (write demos naively first): `state.doc` for every per-frame
value, `cm.math` trig off the sim frame, `cm.rand` for the arcade spawn
column so recorded runs replay bit-exactly, axis-separated AABB movement,
and ASCII-only HUD text (the shipped pixel font has no em-dash; the blank
template had the same latent defect and was fixed too). `scaffold()`
resolves the template source **before** any filesystem effect, so an
unreadable stock file can never leave a partial project, and the existing
main-first/`project.lua`-last rollback is unchanged. Names are substituted
through a gsub **table** (a `%` in a user name stays inert) with quotes and
backslashes escaped, so a legal-but-hostile folder name cannot break out of
the generated Lua string literals; non-blank projects note "started from
the <label> starter template" in the draft description (A6's provenance
line). The picker's "+ New project" tile opens a chooser modal under the
D080 grammar instead of scaffolding blind: a focused, editable name field
prefilled by `cm.words` (D077 validation plus a memoized existence check),
one row of the four starters (chosen = filled, cursor = ring), the
selection's note line, and create/cancel with create as the safe Enter
default. `M.scaffold(template, name)` stays the scripted proof door.

**Consequences.** A3 is complete: from a fresh archive a user can create,
import, rename, relocate, duplicate, archive, delete, edit, play, and
export projects entirely through the shipped UI. Each starter doubles as
the seed of the matching A6 mini-demo and as A5's honest pain probe — the
duplicated movement/collision boilerplate across the three games is
exactly the evidence A5's shared slices need. A4's binding-display line
("starter templates display the actual current bindings") now has real
surfaces to bind to. The chooser row is the first modal with a
chosen-vs-cursor distinction; if a third selection concept ever appears,
promote the pattern into a shared widget instead of a third hand-rolling.

**Proof.** Selftest pins the registry shape, blank identity, substitutable
stock sources, stock-path-naming read failures, no-effect-before-mkdir,
tricky-name round-trips (`%`, quotes, backslash on POSIX; `%` and spaces on
Windows), per-template metadata boot validation with provenance, and a
120-frame init/step boot smoke per template (input records zeroed, doc and
action defs restored, arcade proven by spawn-clock accounting). Autopilot
bots drove the real sim to completion: the platformer's four-jump staircase
to the flag, all six top-down gems, and arcade score 100. A fresh
checksum-verified public Linux archive in stock Debian 13 (spaced/π path,
uid 65534) created all four starters through the picker door, booted each,
and showed all four tiles in a fresh picker. Linux selftest passes 23,541
checks, the staged native Windows executable 23,543; `nix run .#test` is
ALL GREEN. Inspected captures on llm-feed: the chooser (default, arcade
selected, 300% chrome, fresh-archive, native Windows) and the three
completed/mid-run games.

## D082 — input record v2: additive tagged extensions carry quantized pad state (A4, 2026-07-17)

**Context.** A4 needs gamepads in the deterministic input path. The v1
input record is FROZEN at 10 bytes (action bits, mouse, buttons, wheel)
and is the per-frame unit of every historical trace; the golden suite
replays those bytes through `cm.input.apply` and byte-compares all sim
state, so any extension that changes how a 10-byte record applies — or
that makes the engine allocate new sim state under a v1 replay — breaks
the determinism oracle. Analog axes add a second hazard: raw hardware
values pass through host float/driver behavior and jitter per LSB, which
must never enter the sim as unreproducible input.

**Decision.** The record becomes **self-describing and additive**: the
first 10 bytes are exactly v1, followed by zero or more extensions framed
`u8 tag, u8 len, len bytes`. A bare v1 record is therefore a valid v2
record, records of different lengths mix freely inside one trace (FRAM
already stores them length-prefixed), and `apply()` **skips unknown tags**
(future records degrade gracefully) while rejecting malformed framing or
a malformed known extension loudly. **Tag 1 = PAD**: the complete gamepad
state for the frame — `u8 n`, then up to four 11-byte entries in canonical
ascending-slot order (`u8 slot 0..3`, `u32` SDL3-numbered button bits,
six `i8` quantized axes in SDL order lx ly rx ry lt rt). Entry presence IS
the connected flag; hot-plug appears in the record purely as an entry
(dis)appearing at a frame boundary, and device identity (SDL instance →
slot assignment) never enters the record or the sim. **Deadzone and
quantization happen on the live side only**, in exact integer math
(`quantize_axis`: magnitudes at or inside the deadzone collapse to 0, the
remainder rescales to ±127 with floor division, extremes reach exactly
±127); the recorded value is authoritative, so replay and cross-platform
verify never re-derive axis math, and retuning the deadzone (an A4
options knob, default 8000) can never invalidate a trace. Applied pad
state lives in the new **`cm.input.pad`** named buffer (96 bytes, four
24-byte slots holding cur/prev buttons, cur/prev axes, cur/prev
connected), created only by a PAD-carrying record or a pad reader — both
sim-deterministic — so a v1 replay never observes it. `apply()` touches
pad state **iff the record carries a PAD extension** (pure record→state;
no ambient conditionals that could differ between record and verify
time); the live sampler owns liveness via a latch (`M._pad_live`, set by
pad connects, PAD-carrying applies, and pad readers, surviving hot
reload on M) that keeps the extension coming — `n=0` when nothing is
connected — so held buttons always meet their release edge, while
keyboard-only sessions stay byte-identical to v1. Sub-frame pad-button
taps get the same sticky-tap guarantee as keys. Later A4 packets bind
gamepad buttons to actions **live-side into the existing v1 action
bits**, so rebinding never invalidates traces either. `pad_reset()` is
the explicit live-side domain reset for project boot and tests. The
timeline's input-transition marker now also hashes pad slot+button words
(never axes — quantized stick drift must not saturate the lane).

**Consequences.** The record format is extensible without another design
round: a future tag (e.g. higher-resolution axes, touch) is one more
framed chunk. The alpha envelope is 4 pads × 32 buttons × 6 axes at i8
resolution — revisit via a new tag if a genre demo genuinely needs finer
axes. Records grow by 3 bytes/frame (latched, no pads) to 13+11×n bytes;
the PAD extension keeps being emitted for the rest of a session once
latched, which is honest and negligible. A restored snapshot carrying pad
bytes into a session whose games poll pads re-latches the domain through
the reader path, keeping the stream self-consistent. SDL discovery/
hot-plug/slot assignment and the rebind UI are the next A4 packets and
purely live-side by this design.

**Proof.** Linux selftest 23,585 checks and the staged native Windows
executable 23,587: quantization vectors (deadzone
inclusivity, interior values, exact ±127 extremes, override, monotonic +
symmetric sweep), dormant-domain v1 purity, virgin-reader neutrality,
n=0 latch emission and persistence after the last disconnect, canonical
single/two-pad encodings, press/hold/release edges, sticky taps,
deadzone-at-sampling, disconnect release edges, bare-v1 pad
untouchability, unknown-tag skipping, every malformed-record rejection
(truncated framing, over-length, duplicate extension, count/length/slot
violations), snapshot edge restoration, reader argument validation, and
pad_reset v1 purity. `nix run .#test` is ALL GREEN: every historical
trace verifies byte-exactly and all pixel/audio goldens match, and the
Linux-recorded 830-frame `smoke_kitcheck` trace verifies byte-exactly on
native Windows through the new apply path.

## D083 — SDL gamepad discovery: PAL owns device lifetime, Lua owns slot policy (A4, 2026-07-17)

**Context.** D082 froze the deterministic half of gamepads: the PAD
extension carries slot-addressed state and hot-plug is by design a
live-only concern. What remained was the live half — real SDL3
controllers reaching `cm.input.feed` — plus a headless test vehicle,
because CI and the golden suite have no physical controllers and the
discovery layer must not become the one untested subsystem.

**Decision.** Split along the existing PAL boundary. **The PAL owns
device lifetime** (API 18): `SDL_INIT_GAMEPAD` at process start
(non-fatal when the host lacks it), `SDL_OpenGamepad`/`SDL_CloseGamepad`
on hot-plug events in the pump — so open devices survive Lua VM reboots
exactly like the window — and three DEVICE-level event shapes keyed by
SDL instance id (`gpad` connect/disconnect, `gpadbtn`, `gpadaxis`, SDL
standard numbering, raw i16 axes). **Lua owns policy** in `cm.input`:
first-connected claims the lowest free slot 1..4, a fifth device is
ignored (logged) until a slot frees, reconnect resets its slot in place,
and unassigned-device events drop. Because SDL only announces hot-plug
as events, a fresh VM would never hear about already-connected
controllers: `pal.pad_list()` reports what is attached right now, and
`pad_sync()` (called at project boot) resets then adopts it in ascending
instance-id order — a fresh session never inherits the previous
project's latch, while a still-plugged controller claims its slot before
frame one. The editor's `filter_events` extends the key rule to pads:
hot-plug always passes (the registry must track physical reality),
button downs gate on game-window focus while releases always pass, and
axes gate on focus with `pad_neutralize()` zeroing live axes on the
focus-loss edge (a held stick must not keep driving the sim; held
buttons resolve through their eventual release like keys). **Virtual
SDL gamepads are the test vehicle**: `pal.x_pad_virtual*` attach/poke/
detach a full standard-layout virtual controller and `pal.x_events_pump`
drains SDL synchronously, so KATs and recorded traces exercise the exact
event path physical hardware uses, headless. The starter templates read
pad 1 naively (dpad/left stick + south + start) beside their key maps —
deliberately hardcoded until the A4 rebind packet — and the new dev-tree
`projects/padtest` fixture consumes axes/edges/connectivity into
`state.doc` as the committed gamepad determinism trace.

**Consequences.** Device identity, names, and ordering never enter the
sim or the record, so platform differences in enumeration cannot break
determinism. One SDL quirk is load-bearing for tests: virtual-pad state
changes only become events at the next joystick update, so a sub-frame
tap must pump between down and up or SDL sees no net change (real
hardware always delivers both events). A game that polls pads latches
the PAD extension on — template projects' records run 13 bytes/frame
instead of 10, which is honest and costs nothing. The rebind UI/API and
the deadzone options knob are the next A4 packets; both stay live-side
by construction.

**Proof.** Linux selftest **23,606** checks and the staged native
Windows executable **23,608** on PAL API 18. New KATs pin the slot
policy (claim order, routing by id, unassigned drops, disconnect frees
exactly its slot, lowest-free reclaim, fifth-device refusal, reconnect
reset, neutralize zeroing axes only) and the real SDL path via a virtual
pad (attach arrives as a connected `gpad` event, `pad_list` names it,
slot claim, button/axis readback through SDL numbering, release edge,
`pad_sync` adoption, detach as disconnect) with a loud logged skip where
a host cannot init the subsystem. `nix run .#test` is ALL GREEN —
release manifests, every historical trace, the new 600-frame
`padtest_drive` gamepad trace (two mid-recording hot-plug cycles,
partial/full deflections, a sticky tap), and all pixel goldens — and
both gamepad traces (the committed one and a 294-frame live windowed
WSLg recording) verify byte-exactly on native Windows. A virtual
controller drove a freshly scaffolded platformer template through the
real loop from spawn to the far wall with jumps. `tools/build-windows.sh`
refreshed the Windows stage (4 durable state entries preserved) and
Start Menu shortcut.

## D084 — rebindable actions: bindings are live policy over the frozen v1 bits (A4, 2026-07-17)

**Context.** D082/D083 delivered deterministic pad state and live
discovery, with the templates reading pad 1 through hardcoded readers as
a stopgap. A4's third line needs player rebinding: multiple bindings per
action across keyboard and pads, conflict handling, a persistent binding
store, and template HUDs that stop lying the moment a binding changes.
D082 already fixed the invariant that makes this safe: gamepad inputs
bind to actions **live-side into the existing v1 action bits**, so no
rebinding concept may ever enter the record or the sim.

**Decision.** An action holds a **list of bindings**, each a canonical
descriptor: `key:<scancode>` (numbers in `define()`/`map()` normalize),
`pad:<button>` (pad-1 SDL standard button by name), `pad:<axis><+|->` (a
stick/trigger direction past `axis_threshold`, default 40 of 127,
compared on the same quantized value the PAD extension records), and
`pad2..4:` pins. `sample()` ORs every binding of an action into its
frozen v1 bit — keys with the sticky-tap rule, pad buttons with
`held|tap` cleared by the same record's PAD encode so the bit and the
recorded entry always agree, axes on quantized deflection. Everything is
live policy; replay applies recorded bits and never re-derives bindings.
`define()` validates the whole list before touching the map (no
half-defined actions), and what code declares are the **defaults**.

**The store is video.dat-class machine state**: `<project>/input.dat`
(cm.state canon, `{schema=1, actions={name={descriptors}}}`) holds the
player's per-action override lists; adopted only by interactive windowed
boots (headless/verify/captures keep code defaults, so goldens never
depend on a machine's store), written only by explicit saves through the
atomic primitive with the injectable failure seam, excluded by name from
exports/duplicates/archives, gitignored. Malformed files or entries are
logged and ignored, never fatal; overrides naming actions the project no
longer defines stay inert in the store, so hot reloads and version skew
cannot eat a player's bindings. `rebind(name, list|nil)`, `bindings()`,
`default_bindings()`, `overridden()`, and `save_binds()` are the API.

**Conflicts are surfaced, not refused**: the API allows one input on
several actions (context-dependent overloads are a real pattern) and
`conflicts()` reports them in bit order. The **controls page** in the
Esc options menu is the player surface: binding chips per action (`*`
marks overrides, shared inputs draw in the error color with a footer
note), click a chip or `+` to arm a capture that binds the next key
down, pad button, or ≥64-quantized deflection (`bind_of_pad_event`
normalizes any pad to a pad-1 binding; noise cannot bind), **stealing**
the input from any other action that held it and saying so. Del removes
the armed binding; Esc walks one grammar step at a time (cancel capture
→ leave controls → close menu); esc/grave/del are capture-reserved.
Every change saves immediately — a failure names itself, summons the
console, and keeps the live rebind applied. While the menu is open,
`ui.capture_pads()` extends the key rule to pads (downs swallowed,
releases and hot-plug pass, raw events stay readable in `ui.inp.pads`)
and live axes neutralize like the editor's focus-loss edge.

**Honest names ride the bindings**: `bind_label` renders keys through
`pal.scancode_name` ("Space", "Left"; `key N` fallback) and pads through
the positional vocabulary ("south", "dpad left", "stick left",
"p2 east"); `label(action[, kind])` joins them or picks the first
key/pad-flavored binding. The starter templates dropped their hardcoded
pad readers: dpad/stick/south/start are default bindings beside the
keys, `step()` reads only actions, and the HUD derives from
`input.label`, pad-flavored while a controller is connected — so it
names the actual current bindings, rebinds included. The shipped
scripting guide documents descriptors, `label`, `rebind`, `conflicts`,
and the store's machine-local nature.

**Consequences.** The action map is now the ergonomic default for
single-player input (rebindable for free); raw pad readers remain the
door for analog movement, per-pad multiplayer, and anything bits cannot
express — pinned `padN:` bindings exist but the capture UI deliberately
normalizes to pad 1. The A4 options packet still owes volumes, window
sizes, and the deadzone/threshold knobs; player storage (the next line)
may later want the store under a per-user profile root instead of the
project directory — the codec and exclusion rules are ready either way.

**Proof.** Linux selftest passes **23,655 checks** and the staged native
Windows executable **23,657** on PAL API 18 (49 new KATs:
canonical normalization and refusal-without-half-definition, pad-button/
sticky-tap/axis-threshold-exact/direction/pinned-pad/keyboard sampling
into the v1 bits, conflicts in bit order, host + positional labels,
capture normalization boundaries incl. release/hot-plug refusal, store
load/win/partial-drop/late-adoption/round-trip, byte-exact store
preservation through an injected save failure with the live rebind still
applied, malformed-store fallback, and the ui pad-capture pass rules).
`nix run .#test` is ALL GREEN — every historical trace verifies
byte-exactly and all pixel/audio goldens match, proving bindings changed
no recorded byte — and the Linux-recorded `smoke_kitcheck` (830 frames)
and `padtest_drive` (600 frames) traces both verify byte-exactly on
native Windows. `tools/build-windows.sh` refreshed the Windows stage
(4 durable state entries preserved) and Start Menu shortcut. A scripted
SDL virtual pad
drove the REAL capture path headlessly: armed capture on the scaffolded
platformer bound `pad:north` to jump and persisted it to the project's
`input.dat`; a second run rebinding reset stole `pad:south` from jump
with the honest "moved from jump" note. Inspected captures on llm-feed:
options main page, controls page with the jump override, armed prompt,
red conflict marks with both HUD labels honestly reading "Space", the
steal result, and the pad-flavored template HUD.

## D085 — the options packet: player options are live policy over split per-project stores (A4, 2026-07-17)

**Context.** A4's fourth line owes players the expected desktop options:
volume, window sizes that fit their display (the M8.6 menu hardcoded
four presets sized for 1080p), the deadzone knob D082 reserved and the
axis-threshold knob D084 added, and a door for project-specific
settings. Every one of these must stay what D082–D084 made the input
knobs: **live policy that can never enter the record, the sim, or a
golden**.

**Decision — volume is a device-output affair.** PAL API 19's
`pal.x_snd_gain(master, music, sfx)` (0..128, 128 unity, clamped)
generalizes the editor's monitor-mute split: music/sfx gain the sim
bank's voice categories (music slots 32..47, sfx 0..31, 48..63
master-only) on the **device copy** of the mix, composing with the
mutes; master scales the whole audio-callback output, the editor
audition bank included. The hashed full mix is untouched by
construction — `snd_render` still hashes the true mix, only the fifo
push hears the policy — so every PCM golden and trace is byte-identical
under any volume. The split path now renders headless too, and
`pal.x_snd_dev_tap()` exposes the device copy so KATs prove the gain
math exactly (gain 64 composes with the mix shift into one arithmetic
shift). Gains reset to unity per VM boot like the mute clear; the
project store re-applies the player's volumes immediately after.
`cm.options` speaks percent (0..100) and maps to gains at apply time.

**Window sizes derive from the display.** `pal.x_display_size()`
reports the desktop of the display the window occupies (nil without
one). Pure `cm.view.size_candidates(dw, dh)` generates the
ladder-filling sizes — whole multiples of the project's reference FOV
and its 4:3-capped sibling (D054 families get their own multiples) —
that fit that desktop, largest eight, 1x fallbacks for tiny displays,
the classic static four when no display exists. The options menu
consumes it per frame, so moving the window to another monitor honestly
reshapes the offer.

**The stores split by owner.** `<project>/input.dat` (D084) gains
optional `deadzone`/`axis_threshold` fields — schema 1, additive; old
stores read unchanged, malformed values are ignored, numeric ones
clamp, every load resets to code defaults first (a project switch never
leaks tuning), and **only off-default values persist** so an untouched
player never freezes today's defaults against a future retune.
`<project>/video.dat` becomes the per-project machine-local options
store proper: `cm.view.video_contrib(name, save, load)` lets owning
modules merge flat fragments into the canonical table and adopt-or-
reset on every load. `cm.options` contributes `vol_master/music/sfx`
(percent, omitted at 100) and `custom` — and applies the gains on
adoption, so volumes take effect before the first audible frame.

**Projects declare their own options.** `cm.options.add{id, label,
kind=toggle|slider|choice, default, min/max/step, choices, on_change}`
renders under "game options" on the main page; `get`/`set` are the
scripted doors. Values live in video.dat's `custom` table as plain
scalars; entries for undeclared ids (version skew, hot reload) stay
inert in the store exactly like input.dat's unknown actions, and a
stored value failing a redeclared validation yields the new default
without touching the store. The contract is documented where projects
will read it: these are LIVE presentation settings (read in draw or via
on_change); a sim-read setting belongs in `state.doc` where it is
recorded, or replay breaks.

**The menu surface.** The main page: fullscreen, the fitted size
buttons, ui scale, three volume sliders, then game options — scrolling,
with controls/close/quit fixed at the bottom. The controls page gains
the two stick sliders (deadzone, "stick press at") as percent views
over the exact raw integers. Slider gestures apply live every frame but
persist once on release (an Esc mid-drag still lands the save through
the same flush), keeping the A1 atomic-write discipline without a write
per drag frame.

**Consequences.** Exported games now meet the basic desktop
expectations without project code; templates need nothing. The A4 lines
left are namespaced player storage and the all-inputs determinism
proof. The volume knobs deliberately do not duck or fade (a later
audio-polish affair), and the capture UI still normalizes to pad 1.

**Proof.** Linux selftest passes **23,711 checks** and the staged
native Windows executable **23,713** on PAL API 19 (56 new KATs: gain
clamps and category selection through the dev-tap seam — neutral
identity, music-0 device-only silence, half gain exactly one shift,
uncategorized unity, byte-identical hashed mix under any gain — knob
setter clamps, the retuned-threshold sampling boundary exact at
quantized 80, the input.dat knob ride, size candidates across
1080p/laptop/4K/tiny/no-display and the 960x540 family, the
x_display_size contract, options.add validation without half
declarations, set_vol clamps, the real video.dat round-trip with inert
foreign ids, and redeclaration fallback). `nix run .#test` is ALL
GREEN — every historical trace and all pixel/audio goldens unchanged,
proving no recorded or hashed byte moved. A live windowed WSLg fixture
proved the real end-to-end: run one set volumes, a custom option, and
both stick knobs through the API doors; run two's real interactive boot
adopted all of them (master honestly at its untouched default) from the
published `video.dat`/`input.dat`. Inspected captures on llm-feed: the
main page with volumes, six display-fitted sizes, and game options; the
controls page with the stick knobs at their exact default percents.
The human separately confirmed D084's one untested path: a physical
Switch Pro controller through native win32 SDL drives games and
rebinding correctly.

## D086 — namespaced player storage: saves live under the user root, loads ride the record (A4, 2026-07-17)

**Context.** A4's fifth line owes exported games real save data: outside
the install/project folder, profiles/slots, a schema version with
migration, explicit reset, and named errors. Three questions needed
settling: the namespace key (the project NAME is mutable), what the Lua
API owes determinism — D082..D085 drew the live-policy line for knobs,
but save READS legitimately feed the sim, which is exactly what that
line forbids — and how exports/archives relate to saves.

**Decision — the namespace is a declared id, the files live under the
user root.** `project.lua` gains optional `save_id`: 1..64 of lowercase
`a-z 0-9 - _`, alphanumeric start (`cm.project.save_id_error`), boot-
validated, edited as an ordinary draft-legal identity field on the
settings general tab, and scaffolded from the project name via
`cm.project.save_slug` (non-ASCII-only names fall back to "game") — so
every new project is save-ready while renaming/moving/duplicating a
project never orphans or forks player data silently. Saves live at
`<pal.user_path()>saves/<save_id>/<profile>/slot<n>.sav`; nothing under
a project root, so exports, archives, duplicates, and moves cannot carry
another machine's progress **by construction** rather than by exclusion
list. A project without `save_id` has no store: every door answers
nil + "project declares no save_id" instead of inventing a mutable key.

**The store is input.dat-class, with one new statement for reads.**
`cm.save` binds only in interactive windowed sessions (the exact
load_binds gate); headless / `--frames` / `--verify` see a disabled
store with named reasons, so goldens and verifies never depend on one
machine's saves. Writes are pure outputs — sim code may call
`save.write` freely; on verify the re-simmed call no-ops. Reads feeding
the sim have exactly two sanctioned shapes, both captured by the
existing record stream: **boot loads** fill absent doc fields in
`game.init` (reload-idempotence means the trace SNAP carries the result
and verify's re-run leaves it alone), and **mid-session loads** go
through `save.load(slot)`, which reads+migrates live-side and enqueues
the exact post-migration canon bytes as a `cm.save._apply(%q)` command
on the recorded console-eval channel (D022, via the new history-less
`cm.repl.enqueue`). The payload replays from the EVAL record through the
same `repl.exec`; the registered `save.on_load` handler applies it to
doc at the next frame start on record and verify alike. No trace format
change, and the timeline's EVAL marker shows loads for free. Reading a
slot inside `step()` and branching on it is documented as the
determinism bug it is — the oracle catches it as doc divergence.

**Envelope, migration, reset.** A slot is `cm.state` canon
`{ schema, data }` (plain trees only, validated before any write) under
the A1 atomic-replacement discipline: a failed write preserves the
previous save byte-for-byte. `save.schema(n)` declares the current
version; `save.migrate(from, fn)` registers the step to `from + 1`;
reads chain steps to the declared version, name the exact missing or
failing step, and refuse newer-version saves honestly. Malformed files
are named errors that stay on disk untouched until the next explicit
write. `erase(slot)` (idempotent) and `wipe()` (current profile) are the
explicit resets; `slots()`/`profiles()` enumerate what exists;
`profile(name)` shares the save_id grammar. Bind resets profile and
declarations, so a project switch never leaks another game's schema.

**Consequences.** Exported games can save without a line of platform
code, and the A4 exit promise "save data survives restart" is provable.
The remaining A4 line is the all-inputs determinism proof. Save-file
inspection UI (a slots browser in the Esc menu) and cloud-style
copy/backup are deliberately not this packet; A6's demos will exercise
the high-score/pickup patterns the guide documents.

**Proof.** Linux selftest passes **23,767 checks** and the staged native
Windows executable **23,769** on PAL API 19 (56 new KATs: grammar
accept/reject and slug folding, boot/settings validation with the
trimmed-id round trip, disabled-store refusals, the exact plain-tree
round trip with binary-ish strings, schema stamping, the named
first-run answer, nil/non-plain refusals before any write, an injected
rename failure preserving the previous save byte-for-byte, malformed
bytes unreadable-but-untouched, newer-schema refusal, stepwise
migration with exact missing/raising/empty-step errors, profile/slot
listing and grammar, idempotent erase, profile-scoped wipe, and the
recorded load door round trip including verify-path re-exec). `nix run
.#test` is ALL GREEN — every historical trace and all pixel/audio
goldens unchanged. The live WSLg fixture proved the whole story: run
one started from "no save in slot 1", wrote level 1 to the real
`~/.local/share/cosmic2d/engine/saves/d086-save-fixture/`, and applied
a mid-session load; run two's real boot read level 1 back, bumped to 2,
and recorded a 90-frame trace of the write+load — then, with the saves
**deleted**, `--verify` replayed it byte-exact: the disabled store
no-op'd with named reasons while the recorded EVAL carried the load
payload. The same Linux-recorded trace also verifies byte-exact on the
staged native Windows executable, where no saves exist at all — the
recorded-load channel is cross-platform by construction. Inspected
capture on llm-feed: the settings general tab with the new save id
identity field.

## D087 — the A4 exit proof: one recorded session covers every input domain, and A4 closes (A4, 2026-07-17)

**Context.** A4's last line: prove input recording, rewind, resume,
replay, and cross-platform verify with keyboard, mouse, and gamepad
records together — then walk the gate's exit checklist honestly.
D082–D086 proved each mechanism in isolation; what remained was one
artifact where they all ride the same timeline, plus the gate's product
claims: a controller and a keyboard completing the bundled demo, and
rebindings/saves surviving restart.

**Decision.** `projects/inputproof` is the committed all-inputs fixture:
one sim consuming keyboard action bits (whose actions also declare
pad-button and pad-axis bindings, so the D084 OR-into-one-bit path is in
the record), the v1 mouse fields (x/y, buttons, wheel), the PAD
extension (quantized axes, edges, hot-plug), and both D086 save doors —
`save.write` as a pure output on an action edge, `save.load` through the
recorded eval channel. Its driver is render/dev-side in `draw()`, armed
by a recorded eval (`game.arm_drive`), so it never runs under
`--verify`/`--frames`/`--headless` and the recorded bytes stay the only
authority. The driver feeds synthetic key/mouse events through
`cm.input.feed` — the exact ingestion door PAL events use — drives a
REAL virtual SDL gamepad through the physical event path (D083), and
walks `cm.scrub.open`/`seek`/`rewind_here` mid-session. Because
`trace.rewind` deliberately stops a `--record` pin, the committed
artifact is a `trace.ring_export` — the product's own "save what just
happened" door — which spans the rewind seam as one gapless timeline.

**The trace.** `tests/traces/inputproof_a4exit.ctrace`, 258 frames from
a real windowed WSLg session (windowed so the D086 store binds): held
keys and a sub-frame key tap, a mouse sweep with left/right clicks and
wheel steps, two pad hot-plug cycles, a deadzone-passing-but-
threshold-failing axis deflection contrasted with a full one (the
"left" action fires only past the D084 threshold), a multi-frame and a
sub-frame pad south tap, a save via the pad-bound action, a
keyboard save/load round trip whose EVAL carries the exact bytes, a
scrub rewind from frame 200 to 185 with play resumed, and — across the
seam — all three domains in the same frames plus a second save/load
round trip. The final doc tallies every domain (clicks 1/1, wheel 3,
taps 1, presses/releases 2/2, plugs 2, axsum 1570, saves 3, loads 2/2,
level round-tripped to 1).

**Exit checklist.** The bundled demo now declares real pad bindings
(d-pad/left-stick move, south jump, east hop, west slice, north
teleport, left-shoulder grapple) beside its keys, documented in
CONTROLS.md. Scripted route bots drove the REAL loop headlessly through
`cm.input.feed` and a virtual SDL pad — keyboard mode and controller
mode each completed the full demo (all 7 coins across both rooms via
the portal, spike pit crossed, up-jump chains and a flash-jump gap
dash) at the identical deterministic frame 2688 on Linux, and the
controller run repeated natively on Windows at the same frame.
Rebindings survive restart: a `jump -> key:44 + pad:north` override
saved by session one was the active binding list in a fresh boot.
Save data survives restart: a fresh windowed session read back slot 1
with the exact values the recorded session wrote. Deterministic traces
now cover all supported input domains (kitcheck keyboard+mouse-era,
padtest gamepad, inputproof everything together).

**Consequences.** A4 is closed: exported desktop games meet the basic
player expectations the gate named — discoverable pads, rebindable
actions, options, real saves, and a determinism story that survives all
of them at once. A5/A6 (genre-neutral runtime slices + the demo/starter
matrix) are next and begin from the pain the naive demos expose. The
scratch route bots are deliberately not committed (D081 precedent);
re-derive from the DECISIONS narrative if needed.

**Proof.** Linux selftest passes **23,767** checks and the staged native
Windows executable **23,769** on PAL API 19 (no new KATs — the packet's
proof is the committed trace plus the checklist). `nix run .#test` is
ALL GREEN with the new 258-frame trace beside every historical trace
and all pixel/audio goldens. The Linux-recorded inputproof trace
verifies byte-exact on native Windows (with kitcheck and padtest
re-confirmed), where no saves, no pads, and no rewind history exist —
the record carries everything. `tools/build-windows.sh` refreshed the
Windows stage (4 durable entries preserved) and Start Menu shortcut.
Inspected capture on llm-feed: the fixture at the trace's final state
with every domain tally nonzero.

## D088 — the cellar: naive-first mini-demos before A5 slices (A5/A6, 2026-07-17)

**Context.** A4 closed with D087; A5 (genre-neutral runtime slices) and
A6 (the bundled demo matrix) begin together. A5's own iron rule is
"implement only after writing each demo naively enough to expose its
real pain" — and the top-down and arcade families' bundled proofs did
not exist yet, so the first A5 act is an A6 act: write the naive demos
and let them hurt.

**Decision.** `projects/cellar` is the top-down action mini-demo, one
readable file, deliberately naive. It covers the complete A6 line:
analog-stick movement (quantized ints over 127) beside digital keys
with axis-at-a-time wall sliding, touch pickups, an act-press unlock
gated on the key — the pickup that persists across rooms in doc — a
latching pressure plate opening the vault gate, y-sorted pillar/player
drawing with a deterministic comparator, and doorway room transitions.
Every hand-rolled block carries a `PAIN(actor|query|depth|move)` marker
naming the A5 slice that should absorb it; the AABB overlap loop's
third copy in this repo (demo, topdown template, cellar) is the
evidence the query slice wants. The project stays dev-tree-only
(manifest-asserted absent from editor/play shapes) until the A6
bundling packet brings README/thumbnail/metadata polish.

**Proof.** `tests/traces/cellar_clear.ctrace`: a 556-frame full clear —
key, unlock, portal, plate, gate, gem, win — driven through the real
loop by a virtual SDL pad's analog stick, recorded with committed code
and verifying byte-exact on Linux and the staged native Windows
executable. `nix run .#test` is ALL GREEN with the new trace beside
every historical trace and all pixel/audio goldens; selftest counts are
unchanged (no engine surface changed). Inspected captures on llm-feed:
boot, the vault mid-clear, and the win state.

## D089 — the swarm: the naive arcade mini-demo completes the family set (A5/A6, 2026-07-17)

**Context.** D088's pain-first program: naive demos before A5 slices.
After the cellar, the arcade family's bundled proof was the last one
missing (the platformer demo has covered side-view since M-series).

**Decision.** `projects/swarm` is the one-screen arcade mini-demo, one
readable file, deliberately naive: a twin-stick arena shooter with
waves of edge-spawned chasers drawn from `cm.rand` (the PRNG is sim
state, so runs replay bit-for-bit), 8-way stick/keys movement,
right-stick aim where deflection implies fire, an 8-way facing shot,
two swap-remove actor pools, and juice as three hand-tuned doc counters
(hit pause, screen shake, death flash) with render-only offset math off
the sim frame count — never the PRNG. Score restarts instantly on fire;
the high score persists through the D086 doors: an absent-fill read in
`init` (the boot door — the trace SNAP carries the result) and a
pure-output `save.write` on death. `PAIN(actor|query|effect|move)`
markers name the A5 slices; the AABB overlap loop reaches copy four,
and the swap-remove pools state the stable-id case. Dev-tree only until
the A6 bundling packet.

**Proof.** `tests/traces/swarm_runs.ctrace`: 1,306 frames, two lives
driven by a virtual twin-stick pad through the real loop — waves,
kills, the death juice, the hiscore write, the instant fire-restart,
and a second death with best retained — verifying byte-exact on Linux
and the staged native Windows executable. A live windowed pair proved
the boot door against the real store: run one wrote hiscore 456, run
two's init read it back into doc across a real restart. `nix run
.#test` is ALL GREEN with the new trace beside every historical trace
and all pixel/audio goldens; selftest counts unchanged. Inspected
captures on llm-feed: wave-2 mid-fight and the decaying death flash
with the persisted best.

## D090 — cm.box: the query slice starts pure (A5, 2026-07-17)

**Context.** With all three families' naive demos in (D088/D089), the
PAIN markers voted: the same strict-edge AABB overlap loop existed in
four copies (demo `overlap`, topdown starter `blocked`, cellar, swarm),
plus two hand-rolled axis-at-a-time wall slides. A5's first slice
should absorb exactly that — no more.

**Decision.** `cm.box` is pure functions over plain keyed rects
`{x=,y=,w=,h=}` (actor tables pass through untouched): `overlap` /
`overlap_rect` with STRICT edges (flush contact is not a hit — the
semantics every copy agreed on), `touch` (centered-square pickups),
`contains` (right/bottom exclusive), `expand` (interaction reach),
`hit`/`hits` (first/all list matches in array order, reuse-table form
clears first), and `slide` (whole-step axis-at-a-time with cancelled
axes reported — the classic wall-slide feel). Deliberately NOT here:
sweeping (a big step tunnels — documented; fast movers stay with
`cm.collide`'s world mover), layers/masks, circles, raycasts — later
A5 cuts earn those from real pain. Purity makes the determinism story
trivial (no state, no buffers, exact math on inputs) and the module
free to call from sim or render code alike.

**Consequences.** The cellar is the worked proof of ergonomics: its
query/move pain collapsed into box calls with bit-identical behavior
(the route bot clears at the same frame 510), and its golden was
re-cut with committed code per policy. Swarm and the demo keep their
naive copies deliberately — contrast for the next slices (actor/world
is the loudest remaining vote). The shipped scripting guide gained a
`cm.box` section beside the map mover with the tunneling caveat and
the cellar as the copyable example.

**Proof.** Linux selftest passes **23,795** checks (+28 box KATs: the
strict-edge matrix, containment bounds, expand grow/shrink, query
order and honest misses, reuse clearing, every slide axis case
including flush contact and the documented tunneling) and the staged
native Windows executable **23,797**. `nix run .#test` is ALL GREEN —
the re-cut cellar golden and every historical trace and pixel/audio
golden pass — and the cellar golden re-verifies byte-exact on native
Windows. `tools/build-windows.sh` refreshed the stage and shortcut.

## D091 — cm.actor: the actor/world slice (A5, 2026-07-17)

**Context.** After cm.box (D090), the loudest remaining PAIN vote was
PAIN(actor): swarm ran two swap-remove pools with unstable ids and
re-walked raw arrays per system; cellar keeps parallel ad-hoc prop/item
tables with hand-invented string ids. The A5 contract asks for stable
ids, spawn/despawn, deterministic iteration, tags/groups, timers, and a
documented snapshot/rewind story — as a composable module, not an ECS.

**Decision.** `cm.actor` is bookkeeping over ONE plain doc subtree
(`actor.world()`, stored in `state.doc`): no module state, no buffers,
no state participant, no callbacks — canon, snapshots, traces, rewind,
and hot reload carry a world by construction. Ids are integers assigned
ascending and never reused; the world's single list stays sorted by id
(spawn appends, the sweep preserves order), so `get` is a binary search
and there is no id map to rebuild and no hash order anywhere near
iteration. Iteration (`each`/`count`/`first`/`hit`) is always spawn
order; actors spawned during a pass are visited later in that same
pass. `despawn` only MARKS: every query skips the corpse immediately
and the next `tick` removes it, so despawning inside your own loop is
safe. `tick(w)` — once per step — sweeps then counts down integer frame
timers on the world and every live actor (`timer`/`running`/`time`;
`expired` is true exactly on the zero frame; the pairs walk decrements
each key independently, so hash order cannot matter). Tags are one
string field realizing groups; `hit` is first-in-spawn-order strict-edge
overlap (cm.box semantics) over a tag, with rect-less actors never
hittable. Deliberately NOT here: components/systems, multi-tags,
parent/child, spatial indexes, z/depth, effects — later slices earn
those from demo pain, per §2's composable-module rule.

**Consequences.** Swarm is the retrofit proof: enemies and shots became
tags in one world, the overlap loops became `actor.hit`, and the
cooldown/wave countdowns became world timers (returning before `tick`
during the hit pause freezes the world's clocks for free — the pause
counter itself stays PAIN(effect) beside PAIN(move), which this slice
leaves deliberately naive). The visible rules are unchanged, but
iteration order is now pinned to spawn order where the naive
swap-remove order was incidental, so the golden was honestly re-cut
rather than claimed bit-identical (cellar's D090 claim), and it
verifies byte-exact on both platforms. Cellar and the platformer demo
keep their naive actor tables as contrast for the next slices.

**Proof.** Linux selftest passes **23,836** checks (+41 actor KATs:
ascending stable ids, spawn/despawn refusals, spawn-order iteration
with mid-pass spawn/despawn, tag filtering, corpse invisibility and
order-preserving sweep, binary-search get after compaction, strict-edge
hit including dead-skip and rect-less actors, the full timer lifecycle
on actors and the world, and same-ops-same-canon-bytes) and the staged
native Windows executable ****23,838**** on PAL API 19. `nix run
.#test` is ALL GREEN — the re-cut `swarm_runs.ctrace` (1,346 frames:
a three-wave twin-stick fight to 120, death with the hiscore write, an
instant pad restart, a short second life, best retained) beside every
historical trace and all pixel/audio goldens. The trace verifies
byte-exact on Linux and the staged native Windows executable. The
shipped scripting guide gained an actors section beside cm.box.
`tools/build-windows.sh` refreshed the stage and shortcut. Inspected
captures on llm-feed: wave-2 mid-fight and the settled game over with
best retained.

## D092 — cm.camera: the camera slice (A5, 2026-07-17)

**Context.** After cm.box (D090) and cm.actor (D091), the next §2 slice
was the camera: the platformer demo hand-rolled follow/deadzone/clamp
math over an f32 buffer in `cam_step`, snapped the room swap by hand in
`enter_room`, and §2's camera line asks for follow, bounds, coordinate
conversion, pixel snap, shake, and simple transitions.

**Decision.** `cm.camera` is math over ONE plain doc table (extra
fields pass through, exactly like cm.box rects — the demo parks its
smoothed lookahead there): no module state, no buffers, so canon,
snapshots, traces, and rewind carry a camera by construction. The
camera is its top-left corner plus view size (`new()` defaults to
`pal.gfx_size()`); every motion door ends clamped to optional world
bounds, and a bounds axis smaller than the view centers over it
instead of jittering between clamp edges. `follow(c, x, y, o)` eases
the view CENTER per axis — `lerp`/`lerp_y` over the error beyond
`dead`/`dead_y` (defaults 1 and 0 = snap), `ox`/`oy` offsetting the
target for lookahead (smoothing stays the caller's one-line lerp).
`center` is the cut — the simple transition for init/room swaps/
respawns. `shake(c, mag, frames)` arms integer doc counters ticked by
`tick(c)` once per step; the wobble is render-only cm.math sin off the
remaining count with linear fade (the swarm idiom — never the PRNG),
read by `offset`/`apply`. `to_world`/`to_screen` convert through the
UNSHAKEN camera so mouse aim stays deterministic while the view
wobbles. `apply` hands the shaken top-left to cm.gfx (parallax layers;
`gfx.pixel_snap` keeps the whole-pixel rasterization policy).
Deliberately NOT here: zones/rails, dual-target framing, zoom, smooth
room pans — later slices earn those from real demo pain.

**Consequences.** The platformer demo is the retrofit proof: the
buffer camera and both hand-rolled snap sites collapsed into
bounds/center/follow with the exact same knobs, and the spike pit now
arms a real shake. The retrofit is sim-identical — the full A4 route
bot still completes at the exact frame 2688 — but the camera moving
into doc means the recorder re-canons the demo's whole doc every
frame: demo traces cost ~3.5KB/frame where the buffer camera paid ~1KB
(swarm/cellar already pay this for their moving doc state). Revisit
trigger: if committed traces or long sessions grow painful, a recorder
packet owes doc subtree deltas; the module design does not change.
Cellar and swarm keep their naive/absent cameras as contrast for the
remaining slices (tween/effect is the loudest standing vote).

**Proof.** Linux selftest passes **23,873** checks (+37 camera KATs:
FOV/explicit construction, exact center/cut clamping, immediate bounds
clamp and small-span centering, the exact demo lerp math, deadzone
hold/excess/symmetry, per-axis knobs, lookahead offset, clamped
follow, every shake refusal, countdown/fade/removal/rearm/zero-clears,
offset determinism, shake-excluded conversion round trip, apply with
and without shake, and same-ops-same-canon-bytes) and the staged
native Windows executable **23,875** on PAL API 19. `nix run .#test`
is ALL GREEN — the new `tests/traces/demo_camtour.ctrace` (2,068
frames by virtual pad: the town run with lookahead, an up-jump chain
through the y deadzone, the portal cut, a deliberate dive into the
spikes with the shake and warp, the recovery, and the proper pit jump
to a coin) beside every historical trace and all pixel/audio goldens.
The trace verifies byte-exact on Linux and native Windows. The shipped
scripting guide gained a camera section beside cm.box/cm.actor.
`tools/build-windows.sh` refreshed the stage and shortcut. Inspected
captures on llm-feed: the town run mid-lookahead and the mid-shake
spike-pit frame.

## D093 — LAYR v2: per-layer map parallax (2026-07-17)

**Context.** The human reported the demo's backdrop tilemap does not
parallax. MAPS.md §2 always reserved the slot ("LAYR: named layers
with parallax factors"), cm.gfx.layer has carried per-layer camera
multipliers since M-series, and cm.camera.apply (D092) already hands
the camera to "the parallax layers" — but map layers had no factor
and `draw_places` drew everything at world speed, so every placed
backdrop was welded to the ground.

**Decision.** LAYR grows a v2: per layer, `f par_x, f par_y` after
the name (1 = world speed, 0.5 = half-speed backdrop, 0 = screen-
fixed; doc fields `par_x`/`par_y`, nil = 1). The FLGS idiom governs
canonicality: v2 is written ONLY when some layer's parallax differs
from 1, so an all-world-speed map keeps its exact v1 bytes and no
historical map, mapstate buffer canon, or committed trace moves.
`draw_places` applies the factors per layer through `cm.gfx.layer`
(pixel_snap keeps the rounding policy), culls each layer against the
layer-effective camera, and restores the world layer afterwards; an
all-world-speed map never touches gfx.layer, keeping the caller's
translation byte-authoritative. Parallax is presentation ONLY:
colliders, markers, and named refs stay world-space (the guide says
to keep collider-carrying placements on world-speed layers). The map
window's layer panel gained a **par** row editing the active layer's
pair, journaled like every other layer edit; the editor canvas always
shows authored positions. The demo is the retrofit: both rooms'
backdrop layers ride par_x = 0.5 (par_y stays 1 — the rooms are
shallow and the hill horizon is authored against the room bottom).

**The bundle split-brain found on the way.** Re-cutting the demo
trace exposed a latent trap: `cm.restore_bundle` re-executes any
module whose source hash differs from the trace bundle, passing the
registry table as `prev` — but a module that ignores it (`local M =
{}` + `return M`) gets its result COPIED into the held table once,
after which its functions write fields into a table nobody reads.
Verify then crashes confusingly (level.pw nil at camera.bounds)
instead of reporting an honest divergence. All five demo modules now
adopt the passed table (`local M = select(2, ...) or {}`) exactly
like engine modules, and the shipped scripting guide documents the
idiom as the module contract. The engine loader is unchanged — the
copy semantics are inherent to Lua closures, so the contract is the
fix.

**Consequences.** Maps that never use parallax are byte-identical
forever (the conditional-version rule is now the established shape
for additive LAYR fields). The demo's town/overworld maps re-encoded
with the backdrop factor, so `tests/traces/demo_camtour.ctrace` was
honestly re-cut: parallax is render-only, so the old trace's own
2,068 input records replayed against a fresh boot of the current
demo reproduce the identical tour (the driver proved the old SNAP
doc equals the fresh-boot doc byte-for-byte; the only buffer delta
is the mapstate's 16-byte LAYR v2 growth), and the old trace's one
EVAL — the inert driver-arm — is honestly absent from the input-only
re-cut. Editing project sources still invalidates that project's
committed traces (bundle hash drift); the select-idiom makes the
failure an honest divergence report instead of a crash. Revisit
trigger: a foreground `fg` interleave layer and per-layer tint stay
future LAYR fields; wrapping/repeating backdrops stay a game-side
pattern until a demo demands them.

**Proof.** Linux selftest passes **23,878** checks (+5: the LAYR v2
parallax round trip with 1-stays-nil normalization, legacy v1 read,
and the canonical-version rule in all three directions) and the
staged native Windows executable **23,880** on PAL API 19. `nix run
.#test` is ALL GREEN — the re-cut demo_camtour (verified byte-exact
on Linux AND native Windows) beside every other historical trace and
all pixel/audio goldens, which pins that all-world-speed canon never
moved. Inspected captures on llm-feed: the camera-x=400 before/after
pair (the hill mass hanging back at half speed) and the layer panel
showing the backdrop's 0.5/1. `tools/build-windows.sh` refreshed the
stage (4 durable entries preserved) and Start Menu shortcut.

## D094 — cm.tween: the tween/effect slice (A5, 2026-07-17)

**Context.** The standing PAIN(effect) votes: swarm's hit pause /
screen shake / death flash as three hand-tuned doc counters whose
draw math re-derives each lifetime by hand (`alpha = flash / 14 *
0.55`), the platformer's squash/stretch f32 timers easing over t/t0
in player.lua, and cellar's sin item bobs. §2 lists "easing/tweens,
hit pause, flashes, and basic screen feedback"; cm.ease already
holds the pure curve registry, and cm.actor timers + cm.camera shake
established the doc-counter shape.

**Decision.** `cm.tween` keeps named decaying effects on ANY plain
doc table (the reserved `o.tw` key): `play(o, name, frames [, mag])`
arms (or wholesale replaces — the camera.shake rule) an integer frame
countdown that REMEMBERS its lifetime (`{ t, t0, mag }`), so the draw
math never re-derives t0. `tick(o)` — once per step, top of step —
decrements each effect independently (hash-order-safe) and removes it
one tick AFTER reaching 0: the zero frame exists, so play(n) keeps an
effect present for exactly n post-tick steps and `if tween.on(d,
"pause") then return end` after tick IS the hit-pause idiom — the
tween table ticks through its own freeze while the skipped
actor.tick freezes world timers for free. All presentation math is
pure functions of the remaining fraction `k = t/t0` (1 at the armed
frame's own draw): `val` = mag * curve(k) with cm.ease curves BY NAME
(names live in doc), `mix(from, to, curve)` for explicit endpoints,
`wobble` = cm.camera.offset's exact sin-pair idiom for screens
without a camera (never the PRNG), and the pure `bob(frame, period,
amp)` looping helper for item bobs. No module state, no buffers, no
callbacks: canon, snapshots, traces, rewind, and hot reload carry
running effects by construction. Deliberately NOT here:
sequences/chains, per-field auto-writing tweens, callbacks/events,
springs, wall-clock time, particles (fx.lua's pool is buffer craft).

**Consequences.** Swarm is the retrofit proof: the counter triple
became three plays, one tick, and two draw lines, with gameplay
timing preserved exactly (the post-tick gate freezes the same two
steps the pre-decrement gate did; the shake amplitudes carry over as
stored mags 2.4/7.2 = the old t0 * 0.4). Two honest presentation
deltas: the wobble phase now runs off the remaining count (the
camera idiom) instead of the sim frame, and a pause left pending at
death now decays during game-over instead of freezing — both
render-/doc-shape-only, invisible to play. The golden was honestly
re-cut by replaying the old trace's own 1,346 input records through
a REAL virtual pad against a fresh boot of the retrofitted game
(exact quantize_axis preimages at the default deadzone; the pad
attaches before frame 2 exactly as recorded): the new trace's record
stream is byte-identical to the old one, the fight reproduces (120,
death, instant pad restart, short second life, best retained), and
the inert driver-arm EVAL is stripped so the committed trace is
input-only (the D093 camtour idiom). Cellar and the demo keep their
naive counters/bobs as contrast; PAIN(move) and PAIN(depth) stay
marked for their slices.

**Proof.** Linux selftest passes **23,914** checks (+36 tween KATs:
play refusals and stored t/t0/mag, wholesale replacement,
independent decrement, the zero frame and per-effect removal, the
exact n-step pause gate, empty-table removal from the host, val/mix
against exact cm.ease values including unknown-curve refusal and
idle rests, the wobble sin pair, bob, stop/clear/play(0), and
same-ops-same-canon-bytes) and the staged native Windows executable
**23,916** on PAL API 19. `nix run .#test` is ALL GREEN — the
re-cut swarm_runs.ctrace (verified byte-exact on Linux AND native
Windows) beside every historical trace and all pixel/audio goldens.
Inspected capture on llm-feed: frame 938 of the re-cut golden,
mid-death-flash with the shake visibly offsetting the arena. The
shipped scripting guide gained a juice section beside cm.camera.
`tools/build-windows.sh` refreshed the stage and Start Menu shortcut.

## D095 — cm.depth: the layer/depth slice (A5, 2026-07-17)

**Context.** The standing PAIN(depth) vote: cellar rebuilds a draw
list of pillars + player every frame and sorts it with a hand-rolled
comparator (base y, then x, then kind — every tiebreak written by
hand because hash order must never draw). §2's "layers/depth sorting
… without forcing a scene graph" line; the parallax half already
shipped as cm.gfx.layer + the map's LAYR factors (D092/D093), so
this slice is the within-layer ordering only.

**Decision.** `cm.depth` is pure functions over plain tables — no
module state, no buffers, no scene graph, no callbacks, and nothing
touches doc (draw-order only). `push(l, key, item)` appends an
explicit sort key (a finite number, typically the feet/base y; NaN
refused because it breaks ordering totality) with YOUR item passed
through untouched — a table, a string tag, anything but nil.
`sort(l)` is ascending by key with EQUAL KEYS KEEPING PUSH ORDER:
the seq decoration makes the comparator a total order, so the sorted
result is unique under ANY sort algorithm — determinism by
construction rather than by trusting table.sort's tie behavior.
"Pushed later draws later (on top)" is the tie rule. `each(l)` walks
back-to-front yielding i, item, key; `clear(l)` empties for reuse
(the box.hits pattern). `ysort(items [, field])` is the one-liner
for an array already carrying a numeric field (default "y"): a
stable in-place ascending sort refusing missing/NaN fields by index.
Deliberately NOT here: scene graphs, z properties on drawables,
layer registries, draw callbacks, culling.

**Consequences.** Cellar is the retrofit proof (the only vote —
swarm and the demo don't y-sort): the PAIN(depth) block became
push/sort/each with the player as a plain "player" string item. The
tie rule changed from the hand comparator's x-then-kind to push
order, but the room data has no equal base ys, so the retrofit is
pixel-identical (frame-300 byte compare old vs new draw code) and
draw-only — no doc bytes moved, so the committed cellar_clear golden
stands un-recut and verifies unchanged. PAIN(actor) stays marked in
cellar; PAIN(move) stays marked in swarm for the move slice.

**Proof.** Linux selftest passes **23,934** checks (+20 depth KATs:
push refusals for string/nil/NaN keys and nil items, ascending order
with mixed item types and unmutated pass-through, key reporting,
tie stability by push order, idempotent re-sort, empty/single lists,
negative/float keys, and ysort's stability/custom-field/refusals/
empty-array contract) and the staged native Windows executable
**23,936** on PAL API 19. `nix run .#test` is ALL GREEN — the
un-recut cellar_clear.ctrace verifies byte-exact on Linux AND native
Windows beside every historical trace and all pixel/audio goldens.
Inspected montage on llm-feed: the same pillar with the player's
base-y above vs below its base line — hidden behind, then drawn in
front. The shipped scripting guide gained a depth-sorting section
beside the juice section. `tools/build-windows.sh` refreshed the
stage (4 durable entries preserved) and Start Menu shortcut.

## D096 — cm.hud: the runtime-UI slice; the transition slice defers (A5, 2026-07-17)

**Context.** STATUS pointed this packet at the transition slice with
an honest pain-first audit ordered first. The audit found three
instant cuts and nothing else: cellar sets `d.room` and teleports to
the spawn, the demo's `enter_room` cuts the camera with
cm.camera.center (D092), and the top-down starter is a single room
with no transition at all — no demo or template hand-rolls a
fade/wipe/hold anywhere. Three instant cuts are a pattern, not
boilerplate: there is no duplicated code for a slice to absorb, so
per A5's own rule the transition slice DEFERS until a demo actually
hand-rolls one. Runtime-UI is where the votes are: six sites of
margin/centering arithmetic against `pal.gfx_size()` (the demo's
`(W - text.measure(title)) // 2` dance; the arcade starter's
hand-tuned `W/2 - 70` game-over line, brittle the moment the string
changes), and four copies of the device-flavor label dance
(`local k = input.pad_connected(1) and "pad" or "key"` +
`input.label` concatenation in cellar, swarm, arcade, top-down) —
§2's "runtime UI recipes/components for HUDs" line.

**Decision.** `cm.hud` is render-only — nothing touches doc or
module state, so draw code calls it freely and determinism holds by
construction. `place(anchor, dx, dy, tw, th, w, h)` is the pure
anchor math: nine anchors ("tl" "t" "tr" / "l" "c" "r" / "bl" "b"
"br") land the block's corresponding point on that screen point,
insets push INWARD from the named edges (sign-free at corners,
plain signed shifts on centered axes), and centering floors exactly
like the demo's hand-rolled `// 2`. `text(anchor, dx, dy, str,
opts)` is place() over `pal.gfx_size()` + `cm.text.measure`, drawing
through cm.text with the same opts; multi-line strings place as one
measured block with each line aligned to the anchor's horizontal
side, and the call returns the resolved top-left for relative
badges. `label(action)` absorbs the flavor dance verbatim:
`input.label(action, "pad")` while pad 1 is connected, else the
"key" flavor — rebinds show live (D084's contract), and reading pad
connectivity in draw is the established swarm idiom. Deliberately
NOT here: panels/legibility bars (one vote — the demo keeps its
quads), menus, focus/navigation, dialogue, pause screens (zero
hand-rolled votes; Esc is the engine's menu). The guide documents
the pause idiom as a doc flag + early return + `hud.text("c", ...)`.

**Consequences.** Two pixel-identical retrofit proofs, both
draw-only so both committed goldens stand un-recut: the demo's
three HUD lines (centered title, coins corner, controls line)
became three `hud.text` calls with the measure dance gone, and
cellar's bottom message line + both `input.label` sites became
`hud.text("bl", ...)` + `hud.label` with the `k` computation gone.
Frame-300 byte compares pass for both; cellar_clear and
demo_camtour verify unchanged. Swarm and the three starter
templates keep their naive copies as contrast. PAIN(actor) stays
marked in cellar, PAIN(move) in swarm; the transition slice waits
for its first real hand-rolled fade.

**Proof.** Linux selftest passes **23,957** checks (+23 hud KATs:
all nine anchors over an explicit box, floored odd centering,
signed center shifts, unknown-anchor/non-number-inset/non-string
refusals, a br-anchored glyph landing pixel-exact in its cell via
read_pixels, multi-line centered blocks aligning each line, and the
label flavor pinned live against real pad-1 connect/reset through
the record path — leaving the pad domain unlatched) and the staged
native Windows executable **23,959** on PAL API 19. `nix run
.#test` is ALL GREEN — every historical trace and all pixel/audio
goldens unchanged — and both retrofit goldens (cellar_clear,
demo_camtour) verify byte-exact on native Windows. Inspected
captures on llm-feed: the demo HUD and cellar message line,
byte-identical before/after. The shipped scripting guide gained a
HUD/prompts section beside depth sorting; `tools/build-windows.sh`
refreshed the stage (4 durable entries preserved) and Start Menu
shortcut.

## D097 — cm.move: the movement-input slice (A5, 2026-07-17)

**Context.** The exact-next-packet audit (D096's handoff) counted
the movement-input copies honestly. Swarm's PAIN(move) marker names
the aim/axis dance; cellar carries a byte-identical
stick-wins-else-digital movement block (analog left stick over 127,
else digital -1/0/1 keys with the diagonal scaled by the shared
literal 0.70710678); swarm additionally hand-rolls the 8-way facing
sign dance (right stick wins, else the move direction, else keep)
and the diagonal shot-normalization factor. The starter templates'
"naive pad readers" named in the old handoff no longer exist — D084
replaced them with real default bindings — but the top-down starter
still hand-rolls the digital half (ix/iy + DIAG). That is two full
copies of the merge, three of the digital half, and one of the
facing/unit dance: §2's "input plumbing" exit line has its votes.

**Decision.** `cm.move` is policy over recorded input state plus
pure math — no module state, no buffers, nothing touching doc, so
sim callers stay deterministic by construction. `stick(pad, side)`
returns the recorded quantized axes over 127, exact (the wire value
is the authority; 0 means inside the deadzone). `keys(l, r, u, d)`
is the digital pair from four action names (defaults
left/right/up/down), opposites cancelling. `dir(pad)` is the merged
unit-scale vector the two copies agreed on verbatim: the left stick
raw while deflected (analog magnitude — a full diagonal exceeds
length 1, exactly like the demos), else keys with diagonals scaled
by DIAG; the caller multiplies its own speed. `face8(x, y, fx, fy)`
takes per-axis signs of a nonzero vector (cardinals keep a zero
component) else passes the old facing through — nesting the call is
the aim priority chain. `unit8(fx, fy)` scales a diagonal facing by
DIAG for even shot speed. `DIAG` is exported as the demos' exact
shared literal 0.70710678 — absorbing the agreed constant, not
"improving" it, keeps retrofits bit-identical. Deliberately NOT
here: acceleration/friction envelopes, response curves, radial
clamping, dashes, buffered jumps — the platformer demo's velocity
handling stays its own until a slice earns its votes.

**Consequences.** Swarm's whole marked region collapses (merge →
dir, aim dance → nested face8, shot factor → unit8); cellar's block
becomes dir feeding box.slide. Both retrofits are bit-exact — the
unit-scale reorder only commutes IEEE multiplies and sign flips —
so BOTH committed goldens stand un-recut: swarm_runs (1,346 frames)
and cellar_clear (556 frames) verify byte-exact on Linux and native
Windows with no doc bytes moved. The starter templates keep their
naive digital readers as contrast (the A5 rule). No visual surface
changed, so there are no new captures. The A5 slice list from §2 is
now fully either shipped (box, actor, camera, tween, depth, hud,
move) or honestly deferred (transition, per D096); what remains of
A5 is the performance-envelope audit.

**Proof.** Linux selftest passes **23,991** checks (+34 move KATs:
face8 signs/cardinals/keep-old/nil-pass-through, unit8 exactness at
every sign pair, keys cancellation and custom names,
unmapped-action refusal, dir idle/cardinal/exact-DIAG-diagonal,
stick exactness against the real recorded pad path at full and
partial deflection, stick-over-keys priority, right-stick blindness
in dir, bad-side refusal, and the applied-state teardown leaving
the pad domain unlatched) and the staged native Windows executable
**23,993** on PAL API 19. `nix run .#test` is ALL GREEN — every
historical trace and all pixel/audio goldens unchanged, both
retrofit goldens verifying un-recut on both platforms. The shipped
scripting guide gained a movement section beside Gamepads;
`tools/build-windows.sh` refreshed the stage (4 durable entries
preserved) and Start Menu shortcut.

## D098 — the A5 performance-envelope audit (A5, 2026-07-17)

**Context.** A5's last open line: measure representative
actor/projectile counts through the real loop and write an honest
supported envelope into the shipped guide — an alpha promise, not a
benchmark brag. D092 had already logged the suspect: the always-on
ring recorder re-canons the whole doc on any changed frame
(record_frame hashes first, then `state.doc_bytes()` — the delta
granularity is the WHOLE doc, so cost tracks total doc size, not
how much moved). The bundled demos are too small to find the wall
(swarm's biggest waves are a few dozen actors), so the audit needed
a scaled vehicle.

**Decision.** `projects/perfgauge` is the dev-tree-only audit
vehicle (never bundled): a swarm-shaped world — cm.actor chasers
held at a staircase of populations (100..8,000) by edge respawns
from the sim PRNG, a deterministic bouncing bot for the player, a
rotating 8-way shooter keeping projectiles and `actor.hit` queries
in frame, everything in doc so the recorder pays its real cost.
Observation is dev-side only: `pal.time_ns()` samples in
module-local rings (never doc, deciding nothing) split each frame
into step (the game's own work), post (step end → draw start: snd +
advance + ring record — the recorder tax), draw, and whole tick;
each level warms up 120 frames and measures 480, logging
avg/p50/p95/max. The sim stays bit-deterministic; the printed
numbers are the observation. Run capped (`--headless --frames
4200`) so the loop free-runs — uncapped interactive headless sleeps
16 ms/tick and poisons the tick metric.

**Consequences.** The measured truth (Ryzen 9 5900X reference
desktop; Linux under WSL2 and native Windows within noise of each
other, luaheap byte-identical across platforms): game logic is
essentially never the limit — cm.actor steps 8,000 chasers with
overlap queries in under 3 ms — while the recorder tax is ~9 µs per
small doc table per changed frame and dominates everything. Whole-
frame typicals: 500 actors ~5 ms (comfortable), 1,000 ~10 ms with
p95 ~15/max ~27 (the edge), 2,000 ~20 ms (broken). The in-RAM ring
also retains one canon copy of doc per changed frame — 1.1 GB of
Lua heap at n=8,000 — so memory scales with the same rule. The
shipped guide gained "The performance envelope" before the
determinism checklist: the supported alpha envelope is **about 500
live moving doc-carried actors**, with the honest cost model (total
doc size, not motion), the named-buffer escape hatch for bulk
numeric state (`buf_delta1` C-side deltas), the render-only rule
for flourish, and the F3 overlay as the self-serve gauge. A5 is now
fully closed: every §2 slice shipped or honestly deferred
(transition, D096), the audit line done. Revisit triggers: a real
game needing >500 rich doc actors votes for a recorder-side
per-subtree delta (or doc-canon caching); if that lands, re-run
perfgauge and raise the guide's envelope honestly.

**Proof.** Both platforms ran the full staircase through the real
loop (`bin/cosmic` and the staged `cosmic.exe`, 4,200 frames each);
the per-level tables are in the ADR's numbers above and reproduce
with the committed fixture. No sim-visible engine bytes changed —
the packet adds a dev-tree project and guide prose — and `nix run
.#test` is ALL GREEN: selftest unchanged at **23,991** Linux /
**23,993** native Windows on PAL API 19, every historical trace and
all pixel/audio goldens byte-identical. `tools/build-windows.sh`
refreshed the stage (4 durable entries preserved) and Start Menu
shortcut.

## D099 — A6 bundling polish: the demo matrix closes (A6, 2026-07-17)

**Context.** After D098 closed A5, A6's remaining lines were entirely
distribution-shaped: cellar and swarm existed only as dev-tree
projects with bare project.lua files, no demo had the promised
README/welcome note, the public archives shipped the platformer
alone, headless pixel smoke existed only for smoke/uigallery, and
the puzzle/board recipe gap audit had never been run.

**Decision.** Promote the whole matrix in one packet, changing no
sim-visible byte. (1) Every bundled demo carries the A6 welcome
note — controls, concepts taught, file tour, modification prompts,
and its matching starter-template provenance (demo↔platformer,
cellar↔top-down, swarm↔arcade). (2) cellar and swarm carry full
picker/player metadata: author/version/description, gameplay-cut
128px icons (a posed cellar frame; swarm's wave closing on the
player), CONTROLS/CREDITS/LICENSE — validated through the real
player-bundle door. project.lua is not part of the code bundle, so
all three committed traces verify un-recut (proven empirically on
both platforms, not assumed). (3) `editor.txt` stages both demos;
the manifest test asserts every shipped demo arrives complete,
proves both export through the real play-archive path with pinned
README phrases, and gains the missing perfgauge absent-guard
(dev-tree only per D098 — it had never been added to the leak
lists). Root launchers stay demo-only: the picker is the front door
for the rest. (4) One boot-frame pixel golden per promoted demo
(cellar frame 90, swarm frame 175 on pinned lavapipe) — smoke, not
exhaustive goldens; the committed traces stay the deep state net,
and the demos' sim mixes already ride the trace hashes. (5) The
shipped guide gains "Recipe: a puzzle or board game" (flat doc
grid, pressed-edge turns, doc undo list, hud.place centering with
inverted mouse picking, cm.rand deals, cm.save progress); the gap
audit built the recipe verbatim as a scratch project and it ran
first try — hud.place needing the explicit gfx_size box was the
only friction and the recipe text now shows it. **No fourth demo**:
a puzzle adds no materially different shared capability; the D096
menu/panel and transition deferrals remain the only open cuts,
still awaiting real votes. (6) Both clean-machine smokes assert the
new members (README/icon/CONTROLS present, cellar and swarm boot
from the read-only install) — with this, **A6 is closed** and its
exit checklist walked.

**Consequences.** Opening the archive now demonstrates all three
genre families with thumbnails and welcome notes; the demos teach
by copy against the A5 slices they ride. Anything that later moves
a demo's sim/doc bytes still re-cuts that demo's golden with the
committed replay vehicle (PROCESS.md); README/metadata edits do
not. Revisit triggers: a demo hand-rolling a fade/wipe/hold votes
the transition slice in (D096); a real menu/dialogue vote reopens
the runtime-UI cuts; a puzzle demo joins the matrix only if a real
game shows a shared capability the recipe cannot express.

**Proof.** Linux selftest **23,991** and the staged native Windows
executable **23,993** on PAL API 19 (no new KATs — the proof is the
promoted artifacts). `nix run .#test` is ALL GREEN with the two new
pixel goldens (each re-cut byte-identically on a second run) beside
every historical trace; cellar_clear (556), swarm_runs (1,346), and
demo_camtour (2,068) verify byte-exact on Linux AND native Windows
after the metadata changes. Both public release archives rebuilt;
the Debian 13 container and native PowerShell clean-machine
matrices PASS with the new-member checks; cellar and swarm packaged
as full player archives on both hosts (checksums verified, README
and launcher spot-checked). `tools/build-windows.sh` refreshed the
stage (4 durable entries preserved) and Start Menu shortcut.
Inspected captures on llm-feed: the picker with both new thumbnail
tiles and the gap-audit gridtoy running.

## D100 — the persisted timeline summary index: the A7 information layer (A7, 2026-07-17)

**Context.** A7's foundation (persistent tray, scrub grammar, wall-clocked
transport) is built, but the tray's activity/event lanes read only *resident*
chunk streams. Demoted, spilled, and adopted cross-session segments have no
chunks in RAM, so the tray drew them blank and printed "OLDER LEGACY ACTIVITY
HAS NO SUMMARY INDEX"; the files lane was dead (never populated); and only
input/code/eval/session events existed. The `ALPHA.md` §A7 lines call for a
log-scaled sim/editor/project-file envelope and named markers (asset saves,
restarts, errors) drawable *without state reconstruction*. That needs a
persisted per-segment summary, the enabling infrastructure the thumbnail packet
also rides.

**Decision.** Give every closed segment a coarse, observer-only digest —
`{ sim, editor, files, events }`: the max single-frame changed bytes for named
sim buffers+doc, the editor doc, and project files (asset saves + code epochs),
and the OR of that segment's event bits. (1) `summarize_segment` folds a
segment's chunk stream into the digest at spill (and after a rewind
truncation); it is what lets the whole retained window draw. (2) It persists two
ways, both inside the existing atomic segment+manifest pair write: a `SUMM`
chunk in the segment blob (portable/self-describing) and four extra
whitespace-delimited fields on the manifest line (so cross-session **adoption
reads digests from the manifest alone, never touching a spilled blob**).
Manifest parsing became per-line and tolerates legacy 4-field lines, which read
back as an honest "no summary" gap. (3) `ring_timeline` composes: resident
segments still render *exactly* from chunks (per-frame maxes, precise event
frames); chunk-less segments with a digest render *coarsely* (the segment's max
envelope painted across its visible width, event bits at its leading bin);
`missing` is set only for pre-A7 segments with neither. Seeking an old segment
materializes its chunks through the existing LRU, so it silently upgrades to
exact. (4) Two tiny observer chunks carry the events with no state footprint:
`FSAV` (an editor asset save — path + published size; the bytes belong to the
later blob packet) lights the **files** lane and a **save** marker;
`MARK` carries a lifecycle bit. `cm.ed.kit`'s save door emits `FSAV`;
`cm.main.enter_error` marks **error** before the crash flush; `reset_game` marks
**restart**. All are ignored by state reconstruction and by `verify`, and are
stripped from exported `.ctrace` clips (a clip's own activity index is the §14
packaging packet). (5) The tray gained the three markers (red error, amber
restart, teal save) with a hover tooltip that names the events in a bin, and the
previously-dead files lane now draws.

**Consequences.** The tray is honest across its full zoom range and across
restarts: ten minutes of history — including the previous session — shows its
activity envelope and named markers without decoding a frame. The digest is
single-resolution per segment: zooming *into* old, un-scrubbed history is
coarse-but-honest (max envelope, not per-frame), which is acceptable because
scrubbing there makes it resident and exact. `FSAV` stores only the byte
*length* for now; the content-addressed blob store and multi-resolution
sub-segment buckets are deferred to the packaging packet (§14) and logged as
revisits. No sim/doc byte moved, so every committed trace and pixel golden
stands byte-for-byte.

**Revisit.** A game needing per-frame detail in adopted history votes the
multi-resolution segment index (§12); the clip/replay packaging packet extends
`FSAV` to carry a blob hash and folds the digest into standalone clips; input
markers at exact segment boundaries want the per-segment last-input carried in
the digest if the coarse INPUT bit proves too lossy.

**Proof.** Linux selftest **23,997** on PAL API 19 (6 new KATs in
`t_timeline_summary`: the digest round-trips through spill→demote and
through a cross-session reboot/adopt with sim/files/save/error all lit, the
resident tail still draws files+restart exactly, and a legacy 4-field manifest
reports the missing gap). `nix run .#test` is ALL GREEN — every historical
trace verifies byte-exact and all pixel/audio goldens match, proving the
information layer moved no recorded byte. Inspected capture on llm-feed: the
tray over a 210-frame session with the populated files lane and the
save/error/restart markers; previews honestly report none (the thumbnail
packet). `tools/build-windows.sh` refreshed the stage and Start Menu shortcut.

## D101 — presented-frame previews: the rewind tray's PREVIEWS lane (A7, 2026-07-17)

**Context.** D100 lit the activity/event lanes across the whole retained window,
but the tray's PREVIEWS (film) lane still printed "NO PRESENTED-FRAME PREVIEWS
IN THIS HISTORY". `ALPHA.md` §A7 asks for "roughly one presented-frame thumbnail
per minute … decimating at wide zoom, never re-running the sim." Every primitive
already existed: `pal.read_pixels` reads back the fixed game FOV target (the
`--shot`/golden path), `pal.png_encode`/`png_read` are the compact codec,
`pal.tex_create`/`x_ig_image` draw a texture on the overlay drawlist. So this is
a Lua-only observer packet — no PAL API bump.

**Decision.** About once per `M.thumb_period` recorded frames (default one per
minute at 60 Hz), `thumb_pump` — called from `M.tick` **after present**, so the
game FOV holds the finished frame — point-samples `read_pixels` down to a
height-46 thumbnail (`thumb_dims` normalizes height, caps width at 128; nearest
sampling is cheap enough to run inline at that cadence) and stores it two ways,
exactly mirroring the D100 digest's observer discipline:

1. `seg.thumb = { frame, w, h, png }` on the **open segment** — the in-RAM index
   the tray draws from. It survives `demote` (that only nils the keyframe/chunk
   fields) and dies with the segment on eviction, so it needs zero pruning; a
   rewind truncation clears it when its frame passes the cut. One slot per
   segment: at any sane cadence (period ≫ the 60-frame segment) captures never
   collide, so last-wins within a segment is exactly one preview per segment.
2. A durable `THMB` chunk (`frame,w,h` + PNG) appended to the same segment, so it
   rides the segment blob on spill for a future cross-session preview scan. Like
   `FSAV`/`MARK` it is **stripped from exported `.ctrace` clips** and ignored by
   state reconstruction and `verify` — no recorded byte moves.

`M.ring_thumbs(from,to,max)` returns the in-range previews decimated to `max`,
spread evenly by frame; it is RAM-index only and never loads or decodes a history
blob (so adopted cross-session segments, which carry no in-RAM preview yet,
contribute none while their D100 activity digest still draws). The tray's
`draw_previews` requests `~aw/96` previews, decodes one GPU texture per **visible**
frame into a small per-frame cache, skips any that would still overlap a
neighbour, and frees textures that leave the visible set (and all of them on
close) so the finite texture pool is never exhausted. Chunk-less/adopted history
falls back to the minute ticks + honest absence label.

**Capture gate.** Previews ride a dedicated `M.ring.thumbs` flag (set to
`not args.headless` beside `spill`), not `spill` itself — so previews are a
RAM-index feature independent of whether history hits disk, and a capture/soak
harness can enable them without triggering disk writes. Goldens, traces,
`--verify`, and `--frames` runs are all headless, so the flag is off and no
pixel is ever read: the whole determinism story is unchanged by construction.

**Consequences.** The tray now shows what the game looked like at each retained
moment across its full zoom, seek target in hand. Previews are the game FOV (no
editor chrome, fixed size regardless of window), so they read cleanly at 46px and
never depend on window layout. Cost is one GPU readback + PNG encode about once a
minute (a deliberate, negligible periodic hitch) plus ~a few KB of RAM per
retained minute; both are bounded by the same eviction as the segments. Adopted
cross-session previews and multi-resolution sub-segment previews are still the
packaging packet's job (the durable `THMB` chunk is the forward hook).

**Revisit.** A cadence below the segment length would silently give one preview
per segment (the single `seg.thumb` slot); no sane preview cadence approaches
that, but a game wanting sub-second previews votes a per-segment preview list.
The point-sampled thumbnail votes a box filter (or a PAL `x_downscale`) if the
previews read too aliased at a larger tray size. Cross-session preview recovery
votes the blob scan the `THMB` chunk already feeds.

**Proof.** Linux selftest **24,008** on PAL API 19 (11 new KATs in
`t_timeline_thumbs`: capture→`ring_thumbs` round-trip with exact frames and
`thumb_dims` 160×92→80×46, the PNG decodes to those dims, decimation to a
requested max, previews survive their segment's demotion after spill, `THMB` is
stripped from an exported clip, and `thumb_pump` reads a pixel only when
`ring.thumbs` is set). `nix run .#test` is ALL GREEN — every historical trace
verifies byte-exact and all pixel/audio goldens match, proving the preview layer
moved no recorded byte. Inspected capture on llm-feed: the tray over a ~320-frame
`smoke --edit` session with the PREVIEWS lane populated by one game-FOV thumbnail
per segment. `tools/build-windows.sh` refreshed the stage and Start Menu shortcut.

## D102 — the rewind tray's disk-budget / retention surface (A7, 2026-07-17)

**Context.** D100/D101 finished the A7 information layer — the tray now draws the
activity/event lanes and presented-frame previews across the whole retained
window. `ALPHA.md` §A7 line 4 is next: "visible disk budget/use, retention
controls, pause/clear, and recovery behavior … long sessions remain bounded and
understandable." The tray's head already printed a read-only `used / budget · N
segments`; the machinery to bound history existed (`M.ring.budget_mb` drives
`evict`; `cm.ed.clear_cache` removes `.ed/history` + `ring_reset`s while
preserving unsaved session/journals). This packet turns that readout into a
control.

**The contiguous-ring constraint.** `record_frame` requires `f ==
R.last_frame + 1`; a gap triggers `ring_reset` (history rotates, present
reseeds). So "pause recording while the game keeps running" cannot seamlessly
resume — the sim advanced during the pause. The alternatives are: (a) freeze the
game too (that is already the transport play/pause = scrub park, and it preserves
history); or (b) keep playing and, on resume, start fresh. Park already covers
(a), so the only non-redundant recorder pause is (b): **pause = keep playing,
history freezes and stays scrubbable; resume = a fresh contiguous stream from the
present, the pre-pause history released.** `hist_adopt` makes this automatic —
after a pause the present no longer matches the on-disk tail, so no chain adopts,
the abandoned files are wiped, and `ring_init` starts a fresh generation. This is
the DVR "single continuous file" behavior expressed through our single-stream
ring.

**Decision.**
- **`cm.trace`.** `M.ring.rec_paused` gates `record_frame` (transient session
  state, default off, never persisted — so headless/verify/goldens never see
  it); `set_rec_paused(false)` calls `ring_reset` to reseed. `ring_stats` gains
  `retained_bytes = sum(fbytes or bytes)`, exactly what `evict` bounds, so the
  meter reads true. `reevict()` re-runs eviction now, so shrinking the budget
  drops the oldest segment files the same frame.
- **`cm.view` + `cm.main`.** The disk budget is machine-local editor policy like
  the D074 scaling: `set_history_budget` rides `editor.dat`, `budget_mb_ok`
  clamps to [16, 65536] MB, and boot adopts the persisted value onto the ring
  after spill/thumbs. Unset keeps `cm.trace`'s default; a non-number is ignored.
- **`cm.ed.rewind`.** The head carries a live disk-use **meter** (bar fill =
  `retained/budget`, warming amber past 70% then red past 90%; label = used/budget
  + segment/spill state), a **disk-budget knob** (`-`/`+` over a round-MB ladder,
  persisted immediately; eviction deferred while parked so a viewed past can't
  vanish), a **pause rec** toggle, and a two-click **clear** (`clear` → `sure?`,
  auto-disarms after 3s) that runs the tested `ed.clear_cache` door and frees the
  preview textures. REC PAUSED reads on the collapsed pill and the head status;
  the legend only draws when it still fits left of the control cluster (graceful
  at narrow widths / high chrome scale). `fmt_budget` uses `%g` so a console-set
  fractional budget can't crash the header.

**Recovery scope, named honestly.** Clear drops retained state + previews (RAM
segments, `.ed/history` blobs incl. `THMB`, the tray's decoded textures) and
resumes recording next frame; unsaved session/journals are deliberately kept.
Deduplicated project blobs and captured audio recovery are **not** yet real —
they arrive with the §14 packaging packet — so this packet does not claim them.

**Consequences.** A long session is now bounded and understandable from inside
the tool: the meter shows where storage goes and colors as it fills, the budget
knob is the durable bound, pause stops growth while you keep playing, and clear
reclaims now. All observer/chrome policy: no sim/doc/recorded byte moves, so
every trace and pixel/audio golden is byte-identical.

**Revisit.** Resume-from-pause releasing the pre-pause history is the honest cost
of the single contiguous ring; a user who wants history *preserved* across a
recording pause votes a gapped-timeline / seam-keyframe packet (segments either
side of a recorded gap, seek clamped to available frames). The RAM residency
window (`M.ring.seconds`) stays a console knob, not a second surfaced control,
until a demo needs it.

**Proof.** Linux selftest **24,025** on PAL API 19 (17 new KATs in
`t_timeline_retention`: the paused recorder freezes the live edge while the game
frame advances and resume starts a fresh stream; `retained_bytes` is reported;
`reevict` drops the oldest disk segment immediately and shrinks the total;
`budget_mb_ok` clamps/floors/rejects; the budget round-trips `editor.dat` with a
non-number ignored). `nix run .#test` is ALL GREEN — every historical trace and
all pixel/audio goldens byte-identical, proving the retention surface moved no
recorded byte. Inspected captures on llm-feed: the tray recording (meter, budget
knob, pause/clear), a near-full amber meter with `clear` armed to `sure?`, and
the REC PAUSED state with `resume rec`. `tools/build-windows.sh` refreshed the
stage and Start Menu shortcut.

## D103 — the content-addressed project-blob store + per-segment manifest (A7 §14, 2026-07-17)

**Context.** The A7 information/retention layers (D100–D102) are done, so the
open A7 line is `ALPHA.md` §A7's packaging item: "generalize the history store
and additive `.ctrace` packaging around the same segment + content-addressed
project-blob model … a new clip is standalone." `REWIND.md` §14 is the design.
Its load-bearing prerequisite is the store itself: history currently carries the
project's *code* (each segment's `bundle = cm.modules()`) but not its assets —
only their save *lengths* via `FSAV`. Until a retained segment can name the
COMPLETE project tree, no clip is self-contained and adopted cross-session
history stays unexportable (the R6.5 "no bundle" limit). This packet builds that
foundation; clip packaging, `ring_load` materialization, export UX, and the
crash drop are the follow-ups it unlocks.

**Decision.**
- **The blob store.** A content-addressed store under
  `.ed/history/blobs/<sha256hex>`: `blob_put_bytes` hashes bytes and writes the
  file only if absent (dedup by construction), tracking `R.blob_bytes`. It rides
  `M.ring.spill`, so every headless path (goldens, traces, `--verify`,
  `--frames`, `--win` composite captures) never walks a tree, hashes a file, or
  writes a blob — the whole feature is gated exactly like disk history.
- **The manifest.** A per-segment `{ relpath -> blob hex }` snapshot of the
  project's non-machine files at the segment's keyframe (§14 granularity). The
  baseline is a pruned tree walk at `ring_init` (`pal.list_dir` already skips
  dot-dirs; `video.dat`/`input.dat` excluded like the release exporter), files
  hashed natively (`sha256_file`, read only to store a genuinely new blob). The
  manifest is itself content-addressed (stored as a blob → `manifest_hash`), so
  an unchanged tree dedupes to ONE manifest across every segment. It evolves via
  a render-phase `manifest_pump` when `note_save` (editor save) or
  `on_code_change` (disk reload) sets `R.manifest_dirty` — **deferred out of
  `record_frame`** exactly like spill, so the sim step never does file I/O.
- **Persistence + adoption.** `seg_index_line` gains an optional 9th
  manifest-hash field; `spill_blob` writes a `PMAN` chunk; `seg_load` reads it;
  `hist_scan`/`hist_adopt` recover it (tolerating 4/8/9-field lines). So adopted
  cross-session history carries each segment's manifest hash and is
  materialization-ready — the R6.5 limit is lifted at the data layer.
- **GC + accounting.** Blobs are shared, so they are reclaimed by
  mark-and-sweep, not per-segment eviction: `gc_blobs` at `ring_init` marks
  every retained segment's manifest (and the files it names) reachable and
  deletes the rest (also sweeping crash orphans), recomputing `R.blob_bytes` so
  the disk meter reads true with no per-frame stat. `hist_adopt`'s chain-wipe
  skips the blob subtree (GC owns it), and `cache.clear` removes the history
  listing depth-first (the store is a subtree; `SDL_RemovePath` only unlinks a
  file or an empty directory). The rewind head names the store ("N seg . X
  blobs") beside — not inside — the budget bar, which still bounds only the
  evictable segment bytes.
- **Read side.** `ring_manifest`, `manifest_at`, `blob_get`, `manifest_files`
  are the queries the tray's files lane and the packaging packet build on.

**Observer discipline.** `PMAN` is history chrome, stripped from exported
`.ctrace` like `FSAV`/`MARK`/`THMB` (the clip carrying its own manifest+blobs is
the next packet), so an exported clip is byte-identical to before. The manifest
never enters a named buffer, snapshot, or the verifier. Everything gates on
spill. Net: **no sim/doc/recorded byte moves** — every historical trace and
pixel/audio golden is byte-identical.

**Scope, named honestly.** This is the store + manifest only. Deferred to the
follow-up packets and logged: `.ctrace` clips that embed the manifest + blobs;
`ring_load` materializing the tree into an isolated replay workspace; the
`replays/` export UX; the crash-report drop; adopted-history preview recovery
(the durable `THMB` scan). External (non-editor) file changes mid-session are
folded at the next generation's baseline, not live — the manifest tracks
editor-mediated saves/reloads precisely and re-walks the whole tree on any dirty
mark. Intra-segment materialization precision (a file change mid-segment) is
keyframe-granular by §14 design.

**Revisit.** Full manifest walks at boot re-hash the whole tree; a
(path,mtime,size)→hash cache would skip unchanged files if a large-asset project
makes boot cost show. Blobs GC at `ring_init` only — an in-session GC-on-evict
would keep a very long single session's store tighter if a demo needs it.

**Proof.** Linux selftest **24,049** on PAL API 19 (24 new KATs in
`t_project_blobs`: baseline manifest scope + machine-file exclusion, entry =
content hash + exact blob round-trip, dedup to one blob, save advancing the
manifest while a closed keyframe keeps its own, later segments carrying the
advance, spill→adopt recovering + decoding each segment's manifest hash,
`gc_blobs` sweeping an orphan and keeping a referenced blob, the meter counting
the store, an exported clip with no PMAN, `cache.clear` removing the subtree
depth-first, and a spill-off session capturing no manifest). `nix run .#test`
ALL GREEN — every historical trace and pixel/audio golden byte-identical. A real
windowed `smoke --edit` session created 21 blobs with 9-field index lines all
sharing one manifest hash (unchanged tree = dedup). Inspected capture on
llm-feed: the rewind tray head reading `90.2 KB / 1.00 GB · 3 seg · 177.2 KB
blobs`.

## D104 — the standalone `.ctrace` clip: embed the project tree + materialize (A7 §14/§15, 2026-07-18)

**Context.** D103 built the store + per-segment manifest, so every retained
range (live or adopted) can name a COMPLETE project tree without copying an
unchanged file into every segment. This packet spends that: `ALPHA.md` §A7's
packaging line — "a new clip is standalone … all project source and assets" —
and `REWIND.md` §14 (self-contained clips) / §15 (export UX). The two mechanisms
are (a) an export path that embeds the tree in the `.ctrace`, and (b) a load path
that materializes it into an isolated workspace.

**Decision.**
- **Format (additive, skip-tolerant).** A standalone clip is a normal CTRC
  (HEAD/SNAP/KEYF/FRAM/EVAL/EPOC/TAIL — unchanged) plus three chunks: `MFST` (the
  manifest at A — `{ relpath -> blob }`, decodable without the store), one `BLOB`
  per referenced file version across the range (`pack("<s4s4", hash, bytes)`;
  content-addressed so already deduped — the union of every in-range segment's
  manifest, so a file saved mid-range ships every version needed through B), and
  `LOOP` (the A/B bounds). Legacy readers skip unknown tags; legacy `.ctrace`
  goldens simply lack them.
- **`write_trace` gains a standalone mode.** A new trailing `last_i, standalone`
  pair; a plain call (`record_stop`, `ring_export`) passes neither, so its bytes
  are **identical to before** (goldens hold — the format is purely additive under
  an opt-in flag). `M.export_clip(a, b, path)` is the live-range door: SNAP at
  A's keyframe, whole segments through B's, the embedded tree, `LOOP=(a,b)`. It
  is segment-aligned (the clip's frame span ⊇ [A,B]; the loop pins the exact
  bounds) and **names the missing capability** for an adopted opening segment (no
  code bundle) or a legacy/spill-off one (no manifest) instead of crashing —
  §14's compatibility-check discipline.
- **`ring_load` materializes.** It reads `MFST`/`BLOB`/`LOOP`, writes the tree
  into an **isolated ephemeral replay workspace** — a fixed per-user root
  (`<user_path>replay-workspaces/<manifest-hash>/`, well outside any project),
  named by the manifest's content hash so identical clips share one dir and it
  sweeps siblings so a session leaves at most one behind. It records
  `R.workspace`/`R.replay_loop`; the parked write wall (R6c) already keeps any
  browsing ephemeral. `M.materialize_clip(path)` is the same core exposed as a
  read-only primitive that materializes WITHOUT touching the live ring/state —
  the drag-in preview path and what the round-trip KAT exercises.
- **Export UX (§15).** The rewind tray's "export replay" button (live whenever an
  A/B clip is selected) runs `export_clip` into `replays/` beside `engine/`
  (engine-root-relative, created on first use, atomic write), then reveals the
  folder via `pal.x_path_reveal`. A read-only engine root falls back to
  `<user_path>replays/` and the flash names where it landed; an adopted/legacy
  range flashes the reason with no pointless retry. Filenames are
  `<project>-clip-<A>-<B>.ctrace` with a ` (n)` free-suffix. `scrub.do_load`
  reads `trace.replay_loop()` and opens the replay on that range with the loop
  armed (§14: loading reopens on the same range and loop).

**Observer discipline.** Everything rides `M.ring.spill` (the tree only exists
when history spills) and is opt-in at the write side, so **no sim/doc/recorded
byte moves**: every historical trace and pixel/audio golden is byte-identical.
The workspace is dev chrome under `user_path`, never a project or a buffer.

**Reveal reveals a directory, not a file.** `pal.x_path_reveal` shows the
`replays/` folder — §15's "falling back to opening the folder." Selecting the
exact file (Windows `explorer /select,`) is a later native refinement, not a
blocker. Wall-clock filenames (§15 wants export time) wait for a PAL date door;
the frame-range name is the deterministic identity for now.

**Scope, named honestly.** Live-range standalone export ships (the flagship
flow: spot it, A/B it, export it). Deferred, logged:
- **Adopted-range standalone export.** The tree is captured (adopted segments
  carry `manifest_hash`), but the SNAP needs a code bundle its session never
  spilled. Reconstructing it (host engine `cm.*` + the manifest's project `.lua`
  sources) is its own packet; today the button/`export_clip` refuse honestly.
- **Editor-mount-on-drag-in.** `ring_load` materializes `R.workspace` and
  `M.materialize_clip` previews it, but pointing the asset browser (`ed.root`) at
  the workspace and restoring live on dismiss is the immutable-source / drag-in
  A7 line.
- **Crash-report drop** (§16) still owns the one-minute pre-roll open.

**Revisit.** Whole-tree BLOB embedding copies every referenced version into the
clip; a very large-asset project would want a shared sidecar or selective
inclusion. Mid-range asset *imports* (vs saves) ride the same `manifest_dirty`
path but are keyframe-granular by §14 design.

**Proof.** Linux selftest **24,069** on PAL API 19 (20 new KATs in
`t_standalone_clip`: exactly one `MFST` + frames, `LOOP` = exact A/B, one `BLOB`
per distinct version across two manifests (dedup = 4), both hero versions ride
the range, `materialize_clip` writing every source/asset at its A-frame version
into the workspace seam, machine files excluded, an identical clip reusing the
one content-named workspace, a plain `ring_export` carrying no MFST/BLOB/LOOP,
and adopted + spill-off ranges refusing with a named reason). `nix run .#test`
ALL GREEN — every historical trace and pixel/audio golden byte-identical. A
scripted `ring_load` of a real `export_clip` clip materialized the full tree
under `user_path` with the A-frame asset version and the exact `LOOP` bounds
recovered; the engine-root `replays/` write landed. Inspected capture on
llm-feed: `smoke --edit` parked with an A/B clip and the live "export replay"
button.

## D105 — the drag-in replay clip: mount its project, restore live (A7 §13, 2026-07-18)

**Context.** D104 made `ring_load` materialize a clip's project tree into
`R.workspace` and `M.materialize_clip` preview it, but nothing *consumed* it:
`ALPHA.md` §A7 line 6 and `REWIND.md` §13 want a dropped `.ctrace` to open as an
**immutable timeline source** — the tray opens/fits/loops it and the editor
browses its bundled project, while dismissal restores the untouched live session
rather than adopting the replay's future. This is the drag-in consumer.

**Decision.**
- **Coarse §13 stash, not a source interface.** §13's ideal is a polymorphic
  timeline-source object; this ships its mechanism as one table swap. `cm.trace`
  gains `stash_live` / `restore_live` / `has_stash`: the live ring (`M._R`) is
  parked into `M._stashed_live` and `M._R` cleared so the clip's *destructive*
  `ring_load` lands in a fresh ring; restore swaps the live ring back and sweeps
  the replay workspace. The live ring's on-disk segment/blob files are never
  touched while stashed — recording is dormant (the sim is frozen/parked), so
  nothing spills, evicts, or GCs meanwhile. It refuses to double-stash.
- **`cm.scrub` editor-clip mode.** `open_clip(path)` queues a chrome-phase
  `do_load(path, editor_clip=true)` that (1) `state.snapshot()`s the live present,
  (2) `stash_live()`s, (3) `ring_load`s the clip, (4) mounts `replay_workspace()`
  as the editor root, and (5) enters replay on the recorded A/B `LOOP` — forcing
  the first `apply` so the editor parks immediately (the ephemeral write wall + the
  clip's own editor doc). `close_clip` is the non-adopting dismiss: unmount root,
  `state.restore` the present (no init — the live game resumes stepping exactly
  where it was), `restore_live`, `ed.unpark(false)`. `M.close` routes to it via
  `is_clip()`. A failed load restores live and drops the snapshot honestly.
- **`cm.ed` scoped root swap.** `mount_replay(ws)` / `unmount_replay()` stash and
  restore `M.root` in `ed.g` (ephemeral, never captured), so every asset door
  (`ed.kit` / `launcher` / `cache`, the assets window's glob) browses the clip's
  materialized project; the parked wall keeps edits ephemeral. A dropped `.ctrace`
  routes to the tray, never to `add_dropped` (a recording is not source/art).
- **`cm.ed.rewind` clip UX.** `drop_clip` opens the tray and fits the clip; a
  **REPLAY CLIP / EPHEMERAL** header + **CLIP** pill mark it. The live-only
  retention controls (budget / clear / pause rec) and the adopt-y footer (export
  replay / resume here / bring back) all disable while a clip owns the ring; an
  explicit **eject clip** button restores live beside the Esc layering (clip →
  tray). Dropping a clip while already time-travelling is refused so the present
  snapshot is never a past frame.

**Scope, named honestly.** Live-range replay files ship the full drag-in.
Deferred, logged: the **adopted-range** standalone export still needs its SNAP
bundle reconstructed (D104); **crash-report drop** (§16) still owns the
one-minute pre-roll open; a legacy/non-standalone clip opens the timeline but
mounts no workspace (it has none). The clip's game code executes on load with the
same trust boundary as opening a project (§13); the UI marks it a replay but does
not yet gate an untrusted bundle behind a prompt — a follow-up.

**Proof.** Linux selftest **24,103** on PAL API 19 (34 new KATs).
`t_clip_nondestructive`: `stash_live` parks the live ring, `ring_load` lands the
clip in a fresh one (its own keyframe-aligned range through B, workspace, A/B
loop), `restore_live` swaps it back **byte-for-byte** (range, manifest hash,
`ring_export` bytes) and sweeps the workspace; double-stash + empty-restore
refuse; the `mount_replay`/`unmount_replay` swap is scoped, idempotent, and
reversible. `t_clip_lifecycle` drives the real editor `open_clip -> scrub.frame
-> close` lifecycle headlessly (stubbing `after_restore` so it doesn't re-enter
the selftest) and pins the mount + non-adopting restore of present/ring/doc/root
— it caught the editor failing to park on clip open (the write wall was inert),
now forced. `nix run .#test` ALL GREEN — every historical trace and pixel/audio
golden byte-identical (the packet moves no recorded byte: opt-in write side from
D104, pure stash/restore here). Windowed WSLg fixture: `smoke --edit` exported a
same-session clip, dropped it through the real `drop_clip` door — the tray showed
**REPLAY CLIP / EPHEMERAL**, the A/B loop looping, the greyed retention controls,
`ed.root` mounted to the materialized 20-file workspace — then ejected back to
the live session with `ed.root` restored, the live ring range intact, and play
resumed. Inspected captures on llm-feed: the mounted clip tray and the
restored-live editor.

## D106 — crash reports as timeline entry points: the .ccrash drop (A7 §16, 2026-07-18)

**Context.** D067 froze the `.ccrash` `CCRP` container (its `HEAD` names the exact
project / history-stream / last-committed / attempted-frame tuple, D067), D100 added
the timeline **error** marker, and D103's `ring_locator`/`hist_locator` resolve a
stream+frame. `ALPHA.md` §A7 line 9 and `REWIND.md` §16 want the payoff: dropping a
crash report onto any editor view **opens the crashed minute** — fit the safe
pre-roll ending at the last committed frame, mark the failed next-frame boundary, and
loop it — resolving the referenced history by identity, never by wall-clock time.
D105's drag-in plumbing (`filter_events` routing, the tray, Esc layering) is the
chassis this reuses.

**Decision.**
- **`cm.trace.crash_resolve(report[, preroll])` — identity, never time.** A read-only
  resolver over the live ring: the report's `history_stream` **and**
  `committed_frame` must match `ring_locator()` and fall inside `ring_range()`. It
  returns a focus plan — `a = max(lo, committed − preroll + 1)` (the safe pre-roll,
  up to `CRASH_PREROLL = 60·60` = one minute at 60 Hz), `b = committed` (inclusive:
  the last safe frame), `attempted = committed + 1` (the failed boundary) — or `nil`
  + an honest reason: a stream-less/`-1` report is "no durable history"; a **foreign
  stream** names both ids ("another recording"); a frame below the retained low edge
  is "evicted". A stale over-count past the live edge clamps to it. Nothing here
  mutates the ring.
- **`cm.ed.rewind.drop_crash(ed, path)` — the live source in place, not a clip.**
  Unlike D105's clip drop, a crash focus resolves the **live** ring (no stash, no
  mounted workspace), so it just `scrub.open()`s + `scrub.set_loop(a, b)`s and records
  `r.crash = { committed, attempted, kind, … }`. Because it never leaves the live
  source, **export-the-pre-roll and resume-here stay available** (§16's "inspect,
  export the pre-roll, or resume the last safe frame and retry"). It refuses while a
  clip has the ring stashed (eject first) and names an unreadable report or a failed
  resolution in the tray flash rather than guessing.
- **The tray marks the crash.** `.ccrash` routes in `filter_events` beside `.ctrace`.
  The tray gains **CRASH** mode — a red pill/head/subtitle naming the error kind, a
  `fit_crash` view over the pre-roll + boundary, a bold red **CRASH** boundary wall
  (`draw_crash`) drawn just after the last committed frame (pinned to the panel edge
  in the same-session case where the crash sits at the live edge), and a crash-tinted
  "CRASH PRE-ROLL A .. B (last safe frame)" range label. Esc layering is D105's,
  reworded: first clears the loop and keeps the crash view, second returns to live
  (`M.close` clears `r.crash`).
- **Embedded tail deferred, honestly.** §16 prefers an embedded history tail, then a
  local match. Today's container carries **only the locator**, so the shipping path is
  the exact local-stream/frame resolution; when a report embeds its own tail it will
  route through `scrub.open_clip` exactly like a standalone clip (the code names this).

**Scope, named honestly.** The **contained-error, same-or-continued session** case
ships (the live/adopted stream is in the ring). Cross-process native-failure
next-launch synthesis, an **embedded crash tail**, and the trust prompt before
executing an untrusted bundle (shared with D105) remain their own packets. The digest
already carries D100's error marker; `draw_crash` is the explicit boundary the report
names, independent of whether the digest bit survived.

**Proof.** Linux selftest **24,125** / native Windows **24,127** on PAL API 19 (22 new
KATs, no PAL API bump — this is Lua observer/chrome over frozen D067 records).
`t_crash_resolve`: an exact
match returns `[committed−preroll+1 .. committed]` + boundary `committed+1`; the
pre-roll clamps to the retained low edge; a foreign stream / evicted frame /
stream-less report are each refused with their honest reason; a committed frame past
the live edge clamps. `t_crash_focus` drives the real `drop_crash → escape → escape`
lifecycle headlessly: a matching `.ccrash` parks the **live** ring in place (never a
clip, never stashed), loops the pre-roll, and marks the boundary; a foreign report
never parks; Esc #1 clears the loop but keeps the crash view; Esc #2 returns to live
with the ring range byte-intact. `nix run .#test` ALL GREEN — every historical trace
and pixel/audio golden byte-identical (no sim/doc/recorded byte moved; the resolver
only reads the ring). Windowed WSLg fixture: `smoke --edit` armed a driver that
published a real `.ccrash` from the live locator and dropped it through `drop_crash` —
the tray entered CRASH mode looping the pre-roll with the red boundary wall; a
scripted Esc cleared the loop, parked on the last safe frame, and lit "resume here".
Inspected captures on llm-feed: the crashed-minute loop and the Esc-cleared inspect
state. (`--win` capture is headless so spill is off; the fixture forces a stream
identity for the offscreen shot — real windowed sessions record with spill on.)

## D107 — the trust prompt before running an untrusted replay bundle (A7 §13, 2026-07-18)

**Context.** D105's clip mount and (when embedded tails land) D106's crash focus
execute a dropped `.ctrace`'s bundled game code with the **same trust boundary as
opening a project**, and `REWIND.md` §13 requires the UI to *say so* before executing
an untrusted (dragged-in / downloaded) bundle — the deferral both ADRs named. The
prompt must not tax the common case: your own just-exported clip is your own code.

**Decision.**
- **Code identity, computed without executing anything.** `cm.trace.clip_code_hash
  (path)` is sha256 over everything a replay of the clip can ever run: the SNAP
  bundle plus **every EPOC revision**, in file order, hashed over module *name +
  source* only (the recorded file *path* is machine-local noise and never enters the
  identity). Bytes that cannot be a replay at all — unreadable, bad container,
  SNAP-less, bundle-less — refuse with the reason. An appended EPOC (code a replay
  would also run) changes the identity by construction, so an innocuous-SNAP /
  malicious-EPOC clip can never ride an approved hash.
- **A transient session trust set — never persisted, never near sim/doc.**
  `write_trace` seeds it with the identity of every trace this session writes (from
  the in-memory blob, no re-read): a **same-session self-export never prompts** — it
  is your own code, whichever door wrote it (`export_clip`, `ring_export`,
  `--record`). `trust_clip`/`clip_trusted` are the policy doors; an explicit confirm
  trusts the identity **for the rest of the session** (a cancel is not
  distrust-forever: a later drop simply asks again). A fresh process trusts nothing.
- **The gate lives at the drag-in door, not in `do_load`.** `cm.ed.rewind.drop_clip`
  identifies the clip first; an untrusted identity parks a pending tray prompt —
  `r.trust = { path, hash }` — with **nothing stashed, mounted, or run**. The amber
  **UNTRUSTED REPLAY** panel floats above the tray (drawn even with no live history,
  so the question is never invisible): "<name> contains code; opening it runs that
  code", **cancel** / **run clip** buttons, and Esc layered *above* the clip/loop
  escape. `trust_run` remembers the identity and re-enters the same drop door;
  `trust_cancel` (or Esc, or a crash/close superseding it) drops the prompt with the
  code never having run. `scrub.open_clip`/`open_replay` stay un-prompted scripted
  doors — the CLI-launch trust stance — and gating `do_load` would have broken the
  recorded-eval replay path under verify. The future embedded crash tail routes
  through `open_clip` via this same gated door.

**Revisit triggers.** A persisted (cross-session) trust store, a hash display /
"details" affordance on the prompt, or trusting by publisher identity are future
cuts; the first real complaint about re-confirming a known clip across sessions
votes for the persisted store.

**Proof.** Linux selftest **24,149** / native Windows **24,151** on PAL API 19 (24 new
KATs in `t_clip_trust`, no PAL API bump — pure Lua chrome/policy). Pinned: the
identity is a deterministic sha256, EPOC-sensitive, path-insensitive; missing / junk
/ SNAP-less bytes refuse with the reason; a self-export is pre-trusted; an untrusted
drop parks the prompt with no stash and nothing run; Esc cancels and a later drop
asks again; `trust_run` opens the normal D105 editor clip whose dismissal restores
the untouched live ring; the confirmed identity opens directly for the rest of the
session. `nix run .#test` ALL GREEN — every historical trace and pixel/audio golden
byte-identical (no sim/doc/recorded byte moved). Composite fixture: `smoke --edit`
dropped a foreign-process `.ctrace` through the real `drop_clip` door — the prompt
parked over the still-recording live tray; a scripted `trust_run` opened it as the
normal REPLAY CLIP with the identity trusted thereafter. Inspected captures on
llm-feed: the pending prompt and the confirmed clip.

## D108 — adopted-range standalone export: reconstruct the SNAP bundle (A7 §14, 2026-07-18)

**Context.** D103/D104 made every retained range — live or adopted cross-session —
name a COMPLETE project tree (the per-segment manifest + content-addressed blob
store), and `M.export_clip` packaged a live range into a standalone `.ctrace`. But
it **refused an adopted range**: an adopted segment's *state* keyframe spills
(KFBF/KFDC), yet its live *code bundle* (`cm.modules()`) never did (R6.5 — adopted
sessions' code was RAM-only), so the clip's SNAP had no `CODE` chunk and
`ring_load` would reject it. This was the one place the shipped UI still refused
something the §14 foundation already paid for — `ALPHA.md` §A7 named it the exact
next packet. The manifest already froze every project `.lua` source at the
keyframe; the missing piece was reconstructing a bundle from it.

**Decision.**
- **`reconstruct_bundle(R, seg)`** rebuilds a `cm.modules()`-shaped bundle for a
  no-bundle segment from two sources, mirroring how browsing adopted history
  already resolves code (REWIND.md §3, "resume into an adopted frame keeps the
  current engine"):
  - **Project side, from the captured tree.** Every manifest `.lua` that maps to a
    legal project module name (`mod_name_of_rel`: the inverse of boot.lua's
    `module_path` — `main.lua`→`main`, `player/weapons.lua`→`player.weapons`, the
    special `project.lua`→`@project`; `cm.*`-derived and illegal names skipped
    since they could never be project modules), carried at its **captured source**
    read from the content-addressed store — **never the current disk**, which may
    have been edited since that session.
  - **Engine side, from this install.** `@boot` + every `cm.*` module from the
    running session's `cm.modules()`. The adopted engine code was never captured;
    the host engine is the same install, exactly as adopted-history rewind already
    assumes. `@project` is taken from the manifest (project data), not here.
  - Name-sorted for deterministic SNAP bytes. Returns nil (→ honest refusal) when
    the manifest or its blobs were GC-evicted from the store.
- **`write_trace` gains an optional SNAP-code override** on its `standalone` table
  (`standalone.bundle`). A plain/live export passes none, so its bytes are
  **byte-identical to before** (goldens hold — the change is inert on every
  existing path). `export_clip` now requires the manifest first (a clip is always
  standalone; legacy/spill-off history still refuses honestly), then reconstructs
  the bundle only when the opening segment lacks one, else uses the segment's own.
- **The UI is unchanged.** `export_replay`'s "export replay" button already routed
  refusals to a flash; now an adopted range simply exports. A same-session
  self-export of a reconstructed clip **auto-trusts** through the D107 path
  (`write_trace` → `_trust_written`), so dragging cross-session history back in
  never prompts.

**Observer discipline.** Pure read side (manifest + store + `cm.modules()`); no
buffer, snapshot, or verifier ever sees the reconstruction, and the live/plain
export paths are provably untouched — so **no sim/doc/recorded byte moves**.

**Revisit triggers.** The reconstruction trusts the host engine to match the
adopted session's engine (true for same-install cross-session history; an engine
upgrade between sessions is the documented adopted-history limitation, not new
here). Captured-audio embedding and a wall-clock clip filename stay their own §14
refinements.

**Proof.** Linux selftest **24,155** / native Windows **24,157** on PAL API 19 (6
new adopted-range KATs in `t_standalone_clip`, no PAL API bump — pure Lua). The
KATs create a genuine adopted cross-session range (record → spill → drain → reboot
→ adopt), edit `main.lua` on disk after the keyframe, and prove: the opening
segment truly carries no live bundle; `export_clip` now succeeds; the SNAP's
reconstructed bundle carries the project's `main` at its **captured** source (not
the mutated disk) plus the host `@boot`/`cm.*`; the clip is standalone (MFST +
LOOP) and **materializes its captured tree on load**; and it has a valid, trusted
D107 code identity (self-export). The legacy (spill-off, no-manifest) refusal
stays. `nix run .#test` ALL GREEN — every historical trace and pixel/audio golden
byte-identical.

## D109 — the embedded crash tail: a self-contained `.ccrash` (A7 §16, 2026-07-18)

**Context.** D106 resolves a dropped crash report against **local** history by
identity, which is exactly right on the machine that crashed — but a report from
**another machine**, or one opened after the local tail was **evicted**, names a
stream `crash_resolve` can't find and so "carries no timeline". `REWIND.md` §16 and
`ALPHA.md` §A7 line 9 always specified more: a report *may embed its own one-minute
tail*, and "the viewer prefers embedded data, then an exact local stream/frame
match". D103/D104/D108 already make any retained range a complete self-contained
clip (manifest + content-addressed blobs + reconstructed bundle), and D107's trust
prompt gates running a foreign bundle — so the embedded tail is those two features
composed, exactly as `crash_resolve`'s own comment anticipated ("a report that
embeds its own history tail is opened as a clip instead").

**Decision.**
- **Write side — embed the pre-roll as clip bytes.** `write_trace` split into
  `build_trace_blob` (serialize a range to CTRC bytes, no I/O) + the atomic-write
  wrapper; `export_clip`'s clamp/segment-align/reconstruct split into
  `resolve_clip_range`. On those, **`cm.trace.crash_tail_bytes(committed[, preroll])`**
  packs the safe pre-roll `[max(lo, committed−preroll+1) .. committed]` as the SAME
  standalone-clip bytes `export_clip` writes, in memory, and seeds the D107 trust set
  with them (our own code — a self-drop never prompts). Best-effort: it returns
  `nil` + reason for legacy/spill-off/adopted-evicted history. `cm.crash.capture`
  embeds it as an **additive `CLIP` chunk** in `CCRP` **only when the durable
  locator is present** (alongside it, gated on `ring_flush`'s `exact`), so a
  locator-only report is byte-identical to before and old readers ignore the chunk.
- **Read side — prefer embedded, open as a trust-gated crash clip.** `drop_crash`
  reads the report; **if it carries a tail**, `write_crash_tail` stages it as a
  content-named `.ctrace` under a per-user `crash-tails/` dir (swept to one) so the
  **exact same** `drop_clip` door — `clip_code_hash` → trust check → `open_clip` →
  workspace mount — opens it, flavored CRASH. So a foreign report **prompts** before
  running its bundle; this session's own does not. If staging fails (headless / no
  per-user root) it **falls through** to the local match rather than refusing (the
  locator is still valid). A locator-only report takes D106's in-place path unchanged.
- **`drop_clip(ed, path, crash)` gained the flavor.** The optional `crash` descriptor
  (`{committed, attempted, kind, report_id}`) rides `r.trust.crash` through the prompt
  so `trust_run` re-supplies it after a confirm; on open it sets `r.crash` +
  `r.fit_crash`. The tray reorders `r.crash` ahead of `clip` (header "CRASH TAIL",
  "CRASH A/B" pill), draws the D106 boundary wall over the clip region, and fills the
  crash's `a`/`b` lazily from the clip's own `LOOP` (the report named only the failed
  frame). The clip stays ephemeral: **eject, not resume-here** (resume-here is the
  locator-only in-place affordance).

**Ordering rationale (prefer embedded).** Following §16 and the D106 code comment:
when a tail is embedded, it wins. The crashed-minute view is then **frozen-exact and
identical whether opened on the origin machine or another** — immune to any local
history mutation between crash and drop. The one cost is that a same-session
contained-error report now opens as an ephemeral clip (no resume-here) rather than
in place; re-offering resume-here when an embedded clip's stream still matches the
live ring is a logged refinement, not alpha weight.

**Observer discipline.** The `CLIP` chunk is additive and stripped-by-absence on
every existing path; the staged tail is ephemeral per-user scratch; the tray change
is chrome + policy. **No sim/doc/recorded byte moves** — every trace and pixel/audio
golden is byte-identical.

**Revisit triggers.** The embedded tail is a full standalone clip (all project
source + assets), so a large project makes a large `.ccrash` — a **size budget /
dedup-across-reports / opt-out** is the first refinement if diagnostics dirs grow.
Captured-audio embedding (shared with §14) and cross-process native-failure
next-launch synthesis stay their own packets.

**Proof.** Linux selftest **24,177** / native Windows **24,179** on PAL API 19 (22
new KATs in `t_crash_tail`, no PAL API bump — pure Lua). The KATs prove: the tail is
a standalone clip (SNAP + MFST + LOOP) whose `LOOP` is the safe pre-roll; it stages
under the per-user root and is self-trusted; the `CLIP` chunk round-trips through
`CCRP`; a self-trusted drop opens directly as a CRASH-flavored ephemeral clip
(`is_clip` + `has_stash` + `r.crash`) looping the embedded bounds with the bundled
project mounted; Esc layering (clear loop → eject) restores the byte-untouched live
ring; an **untrusted** tail parks a CRASH-flavored trust prompt and `trust_run`
opens it still flavored CRASH; a **locator-only** report still resolves the local
stream **in place**; and spill-off history embeds no tail (names the legacy limit).
`nix run .#test` ALL GREEN. A windowed `--edit` fixture dropped a real 1.1 MB
embedded-tail `.ccrash` through `drop_crash` and landed the tray in CRASH-over-clip
mode (header "CRASH TAIL / sim.step", CRASH A/B pill, the red boundary wall,
pre-roll looping A2..B44, `ed.root` mounted to the materialized replay-workspace,
retention greyed, eject offered) — inspected on llm-feed. `tools/build-windows.sh`
refreshed the stage (4 durable entries) and Start Menu shortcut.

## D110 — in-engine documentation search: the `cm.docs` index (A8, 2026-07-18)

**Context.** A8 wants a **searchable public API/task reference**. The shipped guides
already exist as markdown under `engine/stock/docs/*.md`, rendered by the D061 help
reader — but nothing could **search** them: the reader had history + links but no
find, and the Ctrl+Space launcher ranked only the three top-level doc **filenames**
by label, never a word of body text. So a term you knew ("shake", "deadzone",
"cm.actor") had no path to the section that covered it. This packet builds the
missing substrate; the reference **content** expansion (project schema, common
failures, compatibility policy as indexed sections) is the next A8 packet, and it
now lands into a searchable surface.

**Decision — a pure search module, `cm.docs`.** A new engine module holds the index
and matcher, KAT-pinned over synthetic corpora so ranking is testable without the
filesystem:
- `sections(src)` — the markdown heading tree as numbered line ranges (`lo..hi`); a
  synthetic level-0 lead covers preamble and is dropped when the doc opens on a
  heading (all shipped docs do). Headings **inside ``` fences are text, not
  headings**, so a `#` comment in a code sample never splits a doc.
- `section_at(secs, line)` / `heading_slug(title)` — the section owning a line, and a
  GitHub-style anchor slug used on **both** sides of an in-doc `#anchor` (so deep
  links resolve by construction).
- `search(query, corpus?)` — ranked `{name,title,section,line,snippet,score}`. Tokens
  split on whitespace, lower-cased, matched **literally** (`,true` plain find — a
  query like `cm.actor` or `(cm.camera)` is not a Lua pattern). A doc qualifies only
  if it contains **every** token (doc-level AND). Within it, a section covering all
  tokens is a **full** hit; if none does, the doc's best-covering section is emitted
  once (the scattered-terms fallback). Ranking: full hits first, then more terms in
  the **heading**, then more terms co-occurring on one **body line**, then
  specificity (deeper heading) and tightness; ties break by `(name, line)` for a
  total order. The hit line is the heading when the term is in it (you land on the
  section), else the best body line; the **snippet previews the first body line** for
  a heading hit (the section name is already the card subtitle — don't repeat it).

**Discipline.** Only `list()` touches the filesystem (`pal.list_dir`/`read_file` at
the engine root, exactly like the reader; results **name-sorted** so readdir order
can't leak in), and it is editor/tool code — **never the sim**: no buffer, no doc, no
snapshot, no verify path calls it. `list()` loads lazily and is memoized, so adding
the module to every boot (the editor shell always loads, and its window ROSTER pulls
`help.lua` → `cm.docs`) costs nothing until a reader opens.

**The reader surface (`cm.ed.win.help`).** The empty-path "home" gains a **fixed
search field** above a scrolling region: a non-empty query renders ranked result
cards (doc title · section · one-line snippet); clicking one navigates to the doc and
reveals the hit. Reveal is a **deferred one-frame scroll** — `draw_doc` now iterates
the **same line split `cm.docs` numbers by** (a shared `_lines` that terminates the
last line but does not double-terminate a `\n`-ended source — the off-by-one that
would mis-map every goto), records the target line's screen `y`, and the next frame
scrolls it near the top; the landed-on line lights (`hl_line`, cleared on the next
scroll/navigate). `follow()` learned `#anchor` (cross-doc `path#frag` and same-doc
`#frag`) via `heading_slug`. The query/goto/highlight fields ride the captured
window (`win.q`/`goto_line`/`hl_line`) — all `state.canon`-legal scalars; the rewind
ring captures the **sim** doc, not the editor doc, so none of this nears determinism.

**No sim/doc/recorded byte moves** — pure Lua chrome + a new pure module; every trace
and pixel/audio golden is byte-identical.

**Revisit triggers / deferred, named honestly.** In-doc **Ctrl+F find** in the reader
(the `text.lua` find model; the shell already routes `Ctrl+F` to `kind_call("find")`
mid-typing, so `M.find` on the help kind is the drop-in) is the immediate follow-up.
**Launcher content-search** (reuse `cm.docs.search` so Ctrl+Space surfaces sections,
not just three filenames), **keyboard nav** of the result list, and **span-precise**
match highlight (the reader wraps text; today's highlight is line-level) are logged.
The **reference content** itself — every module, the project schema, determinism
rules, common failures, and the compatibility policy as indexed sections — is the
next A8 packet.

**Proof.** Linux selftest **24,208** / native Windows **24,210** on PAL API 19 (31
new KATs in `t_docs`, no PAL API bump — pure Lua): `sections` ranges + fence-guarded
headings + lead handling;
`section_at`; `heading_slug`; and `search` — heading hit ranks first and lands on the
heading, body-only hit ranks below, multi-term AND drops a doc missing a token,
scattered terms fall back to one best section, single-doc-term isolation, literal
(pattern-metachar) queries, empty/whitespace/absent → none, plus a tolerant smoke
over the **real** shipped docs (`cm.actor` finds `scripting.md`; an absent token
finds nothing). `nix run .#test` ALL GREEN with every historical trace and
pixel/audio golden byte-identical. Two windowed `smoke --edit` captures inspected on
llm-feed: the home searching `save` (22 ranked hits spanning `scripting.md` + the
`win-*.md` editor guides, `cm.save`'s "Player saves" first), and a hit opening
`scripting.md` scrolled to its section with the landed-on highlight.
`getting-started.md` (stale "remaining alpha work" line fixed) and `editor.md`
(a "Reading and searching the docs" section) document it. `tools/build-windows.sh`
refreshed the stage (4 durable entries) and Start Menu shortcut.

## D111 — docs reader: highlight + copy code, clamp the home scroll (A8, 2026-07-18)

**Context.** The D061 reader renders the shipped guides but three things were
missing, two of them human-reported: **no copy** ("being able to copy text from the
docs is pretty important"), the **home list over-scrolled** ("scroll past the bottom
makes it flicker for one frame and flick back"), and code blocks were flat green with
**no syntax highlighting**. All three are editor chrome over static markdown.

**Decision — one pure index, three reader changes.**
- **`cm.docs.code_blocks(src)`** (pure, KAT-pinned) groups the reader's code lines
  into contiguous **blocks**, built ON `line_kinds` so a block's range always agrees
  with what's drawn (the ``` markers are `fence`, so they bracket a run without
  joining it). Each block is `{lo, hi, lang, text}`: `lang` guessed **lua** (the
  guides' default) or **text** (a shell/command sample the lua lexer would mis-color —
  detected by a path-command/known-tool first token, e.g. `bin/cosmic …`), `text` the
  **dedented** source ready for the clipboard. A false `text` only skips highlighting;
  a false `lua` only mis-colors a shell line — both safe.
- **Syntax highlighting.** `draw_doc` maps each code line to its block, threads the
  **`cm.ed.lex`** lua carry within a block (multi-line strings/comments), and draws
  colored spans in the **code editor's exact palette** (`kw`/`str`/`num`/`com` over a
  lavender base) so a sample reads the same in the reader as in the editor. A `text`
  block stays base face — so `bin/cosmic … --edit` is never read as a lua comment.
- **Copy.** A per-block hover **copy chip** (sticky to the scroll band, so it stays
  reachable on a tall block) writes the block's dedented source via **`pal.x_clipboard`**
  (dev-class: headless returns `""`, never sim input); a header **copy page** button
  writes the whole doc as **plain, un-marked text** (headings/bullets/inline markup
  flattened to the *shown* text via the reader's own `parse_inline`). Both flash
  `copied` on the wall clock (the editor redraws every frame, so no journal touch).
  Full drag-select of prose stays deferred — the reader wraps mixed inline runs, so
  glyph-precise selection is its own packet; `src` (raw markdown in a code editor with
  real selection) remains the escape hatch.
- **Scroll clamp.** `M.wheel` clamped only at 0, never at the top, so a wheel past the
  end set `scroll > maxscroll` for one frame — drawn before `draw`'s own end-of-frame
  clamp snapped it back (the flicker). It now also clamps against last frame's measured
  **`win._maxscroll`** (stable frame-to-frame for a static view; `scroll` resets to 0
  on navigate, so the value is always fresh before a wheel can fire), so no
  over-scrolled frame is ever drawn.

**No sim/doc/recorded byte moves** — pure Lua chrome + a pure module; the copy chip's
feedback fields and `_maxscroll` are canon-legal scalars/transients on the (uncaptured
for rewind) editor window. Every trace and pixel/audio golden is byte-identical.

**Revisit triggers / deferred, named honestly.** **Full prose selection** (glyph-precise
drag-select + copy across wrapped inline runs) is the real "copy any text" packet;
today's answer is per-block copy + copy-page + `src`. A **fenced-block language tag**
would beat the first-token heuristic if the guides ever fence (they use indented blocks
today). **In-doc Ctrl+F find** (D110's deferral) is still the cheap next reader nicety.

**Proof.** Linux selftest **24,225** / native Windows **24,227** on PAL API 19 (7 new
`t_docs` KATs — block ranges over the `km` fixture, dedented text with nested indent +
interior blank, fenced body verbatim, `bin/…` → text vs plain lua → lua). `nix run
.#test` ALL GREEN with every historical trace and pixel/audio golden byte-identical.
Headless `smoke --edit` captures inspected on llm-feed: `scripting.md`'s `project.lua`
block highlighted with a `copy` chip and the `copy page` button; `getting-started.md`'s
`bin/cosmic` block staying plain; the home doc-list scrolled past the end sitting flush
(no over-scroll gap). `engine/stock/docs/editor.md` documents copy + highlighting.
`tools/build-windows.sh` refreshed the stage (4 durable entries) and Start Menu shortcut.

## D112 — docs reader: true drag-selection + one panel per code block (A8, 2026-07-18)

**Context.** D111 shipped per-block copy chips + copy-page and named **full prose
drag-select** the real "copy any text" packet, deferred. The human voted it up
("I'd prefer true selection + copy"), together with the other rendering nit: a
multi-line code block drew a `px+3`-tall background rect per line while lines
advance `px*1.5` apart, so every block read as an obvious stack of striped
single-line boxes.

**Decision — a per-frame row model makes the rendered doc selectable.**
- **One panel per block.** `draw_doc` draws a single rounded rect spanning the
  whole contiguous block (its height is knowable up front — code lines advance at
  a fixed `px*1.5`), with small vertical padding, at block entry; the per-line
  rects are gone. The chip's `_y0/_y1` extents come from the same computation.
- **The row model.** While a doc renders, every drawn text run (prose words, bold,
  links, inline code, headings, code lines — including *empty* code lines, so
  block-interior blanks select) is recorded into **rows**: one per VISUAL line,
  runs in reading order, **doc-space** coords (x rel. the text edge, y rel. the
  content top — scroll and window moves never invalidate them), plus the source
  line `ln`. After the body draws, each row's runs join into its **text** (a
  gap wider than half a pixel becomes one space — exactly what the eye reads).
- **Selection.** Endpoints are `{ri, ci}` — row index + byte offset into the
  row's joined text. A press in the band anchors; a drag picks the head against
  **last frame's rows** (same indices — the doc and width are stable
  frame-to-frame; a reflow drops the selection), with autoscroll past the band
  edges. Picking is **glyph-precise and utf8-safe** (midpoint-snapped, never
  splitting a codepoint). The highlight draws per row at row-creation time, so
  it sits *under* the text but *over* the block panel. **Esc** clears (the
  kind's `escape` hook, ahead of the shell ladder). Links now follow on
  **release of a gesture that never dragged**, so link text is selectable.
- **Copy.** **Ctrl+C** routes through the shell as `kind_call("copy")` (beside
  undo/redo, so it never fires while an imgui edit widget owns the keyboard —
  the code editor keeps its own copy). Extraction: end rows sliced at their
  offsets, middle rows whole; a **wrap rejoins with the space it consumed**, the
  next source line is `\n`, a 2+ line jump crossed a blank — a paragraph break
  (`\n\n`); code rows keep exact dedented indentation. A "copied" tag rides the
  selection head on the wall clock.
- **Where the state lives.** Selection state + the row model are **module-local
  keyed by `win.id`** (`M.sel_state`), deliberately NOT window fields: every
  string key on a captured window rides `state.canon` into `session.dat`, and
  the row model is big and rebuilt every frame. (Observed while placing this:
  the reader's existing `_src` cache — a whole doc string — does persist that
  way; logged as a cheap future trim, not this packet.)

**No sim/doc/recorded byte moves** — pure Lua chrome; the pick/x/extract math is
pure over the row structure with an injected measure, KAT-pinned with a fake
monospace measure (the `text.fr_matches` precedent), and the reader passes
`pal.x_ig_text_size`.

**Revisit triggers / deferred, named honestly.** **Double-click word-select /
triple-click line-select** ride the same model when a real use votes them in.
A **selection that survives a resize** would need doc-anchored (not row-anchored)
endpoints — dropped-on-reflow is the honest v1. The bullet marker (`- `) is
drawn decoration, not a recorded run, so copied bullets lose it (copy-page keeps
it). **In-doc Ctrl+F find** stays the remaining cheap reader nicety (D110).

**Proof.** Linux selftest **24,246** on PAL API 19 (21 new KATs in `t_help_sel`:
row joining incl. touching runs + empty rows, pick midpoint/gap/clamp semantics,
utf8 boundary snapping, `row_x` inverses, band picking, extraction — slices, wrap
rejoin, newline vs paragraph break, code blanks, reversed-endpoint normalization,
empty selection — and the escape contract). `nix run .#test` ALL GREEN with every
historical trace and pixel/audio golden byte-identical. Headless `smoke --edit`
captures inspected on llm-feed: `scripting.md` with a selection spanning prose
into the `project.lua` block (one unified panel, highlight, "copied" tag) with
the copied bytes logged and verified faithful; `getting-started.md`'s two-line
`bin/cosmic` block as one plain-face panel. `engine/stock/docs/editor.md`
documents selection + Ctrl+C. `tools/build-windows.sh` refreshed the stage and
Start Menu shortcut.

## D113 — the docs reader goes retained-mode: layout once, paint the band (A8, 2026-07-18)

**Context.** Opening a doc dropped the WSLg editor from 60 to 42 fps (human-reported,
same day as D112). Measured on the reference desktop with a scripted 200-frame
`smoke --edit` run over `scripting.md`: `help.draw` cost **14.7 ms/frame** after D112 —
but the pre-D112 reader already cost **7.5 ms/frame**. The old design re-laid-out and
re-drew the ENTIRE document every frame (one `x_ig_text_size` + one draw call per WORD,
whole-doc, clip or no clip); D112's per-frame row-model rebuild (a table per run per
frame + `rows_finalize` joins) doubled a cost that was already more than a whole 60 Hz
frame short of comfortable.

**Decision — a layout/paint split; no C helpers needed.**
- **`layout_doc(src, maxw, px, z)`** runs ONCE per (doc, width, font, zoom) and
  produces everything a frame needs, all in doc-space: the **selection row model**
  (D112's rows — runs now carry their face color and link url), a **decoration list**
  (block panels, inline-code chips, bullet dots, heading rules), the **link rects**,
  the **copy-chip block extents**, a **source-line → y map**, and the content height.
  All `x_ig_text_size` measuring lives here. The cache rides `M.sel_state` (module-
  local, never canon'd) keyed by src identity + width + px + z; a reflow honestly
  drops the selection (as D112 already did).
- **`paint_doc`** draws each frame from the cache: decor → landed-line highlight →
  selection highlight → text runs, **only for the visible band** (rows ascend, so the
  row loop early-breaks past it). Zero measuring, zero allocation; link runs pick
  their hover face + underline live. Selection highlight now paints from the SAME
  frame's state (no last-frame hlmap lag), and it sits above panels/under text by
  paint order instead of D112's draw-at-row-creation trick.
- **Goto reveal simplifies**: a search hit / `#anchor` scrolls via the line→y map the
  same frame (the old measure-then-scroll two-frame dance and `_goto_y` are gone).
  Link clicks hit-test the cached doc-space rects with one mouse conversion.

**Measured.** `help.draw` on scripting.md (966 lines): **14.71 → 0.100 ms avg**
(worst 23.0 → 0.26 ms) — ~147× less per-frame work, and ~75× cheaper than even the
pre-D112 reader. The layout frame itself (navigate/resize/zoom) costs about one old
frame. WSLg has ~14 ms of frame budget back.

**No sim/doc/recorded byte moves** — pure editor chrome rework; the D112 selection
KATs pin the unchanged row-model math; the copied bytes, captures, goto reveal, and
chips verified identical on the new path.

**Revisit triggers.** The home search-results view still draws immediate-mode (small,
bounded); if a result list ever reads slow, the same split applies. If a future doc
grows past ~10k lines, layout itself (~one old frame) could chunk lazily — not worth
it for the shipped guides.

**Proof.** Linux selftest **24,246** / native Windows **24,248** on PAL API 19 (no new
KATs — the pure math is unchanged and already pinned; the timing driver is scratch).
`nix run .#test` ALL GREEN, every golden byte-identical. Headless captures re-inspected
on llm-feed: the D112 selection fixture and getting-started panel pixel-matching the
pre-optimization shots; the Player-saves goto reveal landing highlighted. Windows stage
+ Start Menu shortcut refreshed.

## D114 — the cosmic3d merge: retro-3D lands in mainline (2026-07-18)

The 3D fork (`../cosmic3d`, forked at f791824, 97 commits) merges back.
It was built merge-first (COSMIC3D §12): no upstream module names
squatted, demos kept naive copies as merge bait, PAL additions behind
`x_` — so the tree is almost fully additive. What lands: the retro-3D
PAL pipeline (`x_view3d`/`x_tris`, lazily created — a pure-2D session
allocates none of it and its frame path is byte-identical), the retro
presentation doors (`x_grade quant=` Bayer-dithered 5551 grade, `x_soft`
VI blit — presentation only, goldens never see them), the retro/
blit_soft shaders, ten engine modules (`cm.m4/rig/kin/walk/spr/atlas/
gb/terr/fig/mascot`), one sim-core change (`state.sim_buffer` excludes
the `"rc."` render-class domain, D3D-012 — additive; every 2d golden
stands byte-identical as proof), six dev-tree demo projects (bounce/
openworld/bigworld/rovale/figure/proto3d — none staged into releases),
their 12 traces + 14 pixel goldens (glob-discovered by the suite), the
`proto/` reference tree, and the fork docs (COSMIC3D.md, DECISIONS3D.md
— the D3D-*** ADR namespace stays separate and closed; new decisions log
here).

**Conflict policy.** Both sides bumped PAL_VERSION_API from 14
independently (upstream →19, fork →16); the fork's v15/v16 collide with
mainline meanings, so the 3D API renumbered to **v20** — fork docs
referencing "API 15/16" are historical text. docs/STATUS.md keeps
mainline; the fork's round-by-round history is archived verbatim at
`docs/history/STATUS-3D-2026-07.md`. CLAUDE.md/README keep the cosmic2d
identity (this repo remains the engine; 3D is a capability, not a fork
identity). The fork's ignore rules for the 230MB CC0 asset staging area
(`assets/`, README-only) ride along.

**Validation at the 2d bar.** Clean build; `nix run .#test` ALL GREEN on
pinned lavapipe — every historical 2d trace + pixel/audio golden
byte-identical AND all 12 fork traces + 14 fork pixels pass; Linux
selftest 24,246 on api20 pre-KATs. The fork shipped zero selftest KATs
(its bar was goldens + FRAM-identity proofs); the same-day KAT packet
closes that gap (119 checks: t_m4/t_kin/t_walk/t_rig + the rc. domain
pins — 24,365). Render-class emitters (gb/terr/spr/atlas/fig/mascot)
stay golden-pinned, the cm.gfx precedent.

**Revisit triggers.** The 3D demos may later move to ../cosmic2d-demos
(the R0 engine-only rule vs the fork's dev-tree habit — deliberate keep
for now: they are the 3D goldens' cartridges). The fork's parked editor
windows (terrain paint/bake, figure vertex-push, sheet preview) stay
human-gated. 3D documentation intake into the docs/README map is the
deferred packet (see STATUS).

## D115 — the re-merge retrofit wave: cm.actor/hud/move; tween defers (2026-07-18)

The fork's post-merge queue, executed. **cm.hud + cm.move** (goldens
un-recut, the strong form): all 13 HUD measure/centering dances across
the four 3D demos became hud.text anchors (floored centering is the
demos' exact math; the typed-dialog lines keep no-slide full-line
centering via hud.place with an explicit width), and the three digital
fwd/side blocks became move.keys (same integer sums) behind a
move.stick merge — live pads now steer the 3D demos; recorded traces
carry zero axes, so every golden stood byte-identical (`nix run .#test`
ALL GREEN, 20 traces PASS, un-recut).

**cm.actor** (goldens honestly re-cut): openworld's and rovale's
hand-rolled NPC lists (per-NPC named buffers + the hot-reload
pcall/free dance) became one `d.npc` actor.world each — spawn seeds the
cast (`i` links the module-local render-class defs), each/tick drive
step/emit/dialog/boxes. The greet ENCODINGS stay per-demo (openworld's
gstart>gend frame+1 edges, rovale's gstart+spent) — D3D-033's audit
already established they cannot unify; what cm.actor absorbs is the
list management. Doc shape moved → all six affected traces re-recorded
from their own eval-armed autoplay (dump-verified zero input records)
and all seven pixels re-shot on lavapipe; landmarks reproduce (the
meet, stars 10/10 + banner, greets + typed lines — inspected). Known
cost, D092's class: 2–3 moving doc actors re-canon ~2.4KB/frame
(traces ~2×); the recorder per-subtree-delta packet remains the logged
revisit.

**bigworld exempted, deliberately:** its ~4000 entities are closed-form
slots in one buffer — position = f(frame), promote/demote by index, no
per-entity state. That IS its §10 scheduling answer; doc actors would
break the construction and the D098 envelope. The near-kernel stays
slot-based with it.

**cm.tween DEFERS** (the D096 precedent): the 3D demos' juice counters
(bounce squash_t/amt + pickup pop ghosts) live INSIDE persistent f32
player/pickup buffer layouts, already fed by cm.kin value flow — not
doc tables. cm.tween is doc-table policy; "retrofitting" would be a
state migration that deduplicates nothing (the layouts diverge — the
D3D-032 finding). First 3D demo that grows a doc-side juice counter
rides cm.tween then.

## D116 — relative mouse: pal.x_mouse_capture + the MREL record extension (2026-07-18)

The fork's parked captured-cursor look (D3D-009/010), buildable once
D082's additive record v2 shipped — now built. **PAL API v21**:
`pal.x_mouse_capture(on)` flips SDL relative mouse mode (query with no
argument; headless has no window and stays uncaptured), and motion
events carry `rx/ry` — relative deltas scaled by the game viewport like
the absolute pair, real even while the cursor is frozen.

**Record side — extension tag 2, MREL** (the D082 mechanism): `i16 dx,
i16 dy` whole internal pixels per frame, live-side float remainder
carried (the wheel model). Emitted every sample once
`input.capture_mouse()` has been used this session (the `_pad_live`
latch model) so a capture-free session stays byte-identical; applying
ANY record zeroes the applied delta first, so a record without MREL —
every historical trace — reads (0,0). Capture is live chrome policy
like device identity: replay never re-captures, the recorded deltas are
authoritative. Readers: `input.mouse_rel()`; boot runs `mrel_reset`
beside pad_sync (fresh session, no inherited latch), and the Esc
options menu force-releases capture on open (the menu needs the OS
cursor; the game re-captures itself after).

**Consumer:** cm.rig gains captured-cursor look from `mouse_rel()` with
the drag-look knobs — inert at (0,0), so every committed trace and all
drag-look demos are untouched (proof: full suite green, goldens
un-recut). The demos deliberately STAY drag-look — wiring capture into
a demo is a feel change and waits for a human playtest verdict.

**Proof.** Linux selftest 24,377 (12 new KATs: t_input_mrel — dormant
domain emits nothing/reads zero, latch emits 4-byte extension, whole-px
+ carry, still-frame zeros, v1 reset, malformed refused/unknown
skipped, reset ends the domain; t_rig — MREL steers the orbit, v1 moves
nothing), `nix run .#test` ALL GREEN, every golden byte-identical.
Deferred, named honestly: demo adoption (human feel gate), an
editor-shell capture policy (games under `--edit` — today only the Esc
menu releases), and pointer-lock UX niceties (sensitivity option in the
menu) if a real game votes them in.

## D117 — figures go baked: shape bakes + the x_figverts C loop (PAL v22, 2026-07-18)

The human's report: "3-4 NPCs on screen tank bigworld from 240 to ~80
fps". Measured: ONE posed mascot cost **1.84 ms/frame** of Lua — the
immediate gb emitters re-derive profile trig, matrix-chain per quad,
temp tables, and a string.pack per vertex, ~1000 tris per figure, every
figure, every frame. Player + 4 near NPCs ≈ 9 ms — exactly the tank.

**The shape bake.** gb gains bake_lathe/ball/prism/gbox: each runs the
immediate emitter's exact loop ONCE, recording every vertex's LOCAL
inputs (position/uv exactly as fed to xfp, one normal slot per distinct
xfn call) in the exact emit order, plus `emit_baked` — the only
per-frame work: transform each normal slot + light it (the vert()
expressions verbatim), transform each position (the m4.apply expression
verbatim), pack. Same doubles through the same expressions in the same
order = the same bytes. fig.emit caches bakes per shape table (weak
keys, render-class — derived pure data, no sim byte anywhere near it).
Lua-only this is 1.84 → 1.27 ms; the win is capped by per-vertex pack
overhead.

**The C loop (v22).** `pal.x_figverts(blob, nv, xf, nxf, sun, ambient,
col, alpha)` — the bake rides an anonymous pal buffer (64B/vertex of
packed doubles) and the transform+light+pack loop runs in C, mirroring
the Lua reference in double precision and expression order
(m4.apply/applydir dots, vert() lighting, cm.math clamp/max semantics,
floor-to-byte), returning the 24B lit vertex stream for x_tris. The Lua
loop STAYS as the reference and the host-loaded/fake-pal fallback;
emit_baked dispatches. **1.84 → 0.188 ms per figure (~10x)**; end to
end the openworld meet's draw (3 figures + stars + world) fell **7.81 →
2.53 ms** and the bigworld tour draws at ~3.5 ms — the 4-NPC worst case
now adds ~0.8 ms of figures instead of ~7.4.

**Proof — the strongest form, three ways.** (1) A scripted byte-compare
of a full posed mascot: baked path vs the pre-change immediate loop —
70,128 bytes IDENTICAL. (2) 14 new KATs (`t_figverts`): C bytes == Lua
reference bytes across all four shape kinds under a deforming xf with
rigid nxf (the squash case), tri-count agreement, blob build, oversized
nv + out-of-range alpha refusals — Linux selftest **24,391** / native
Windows **24,393**. (3) `nix run .#test` ALL GREEN with every pixel
golden byte-identical and every trace PASS — no re-cut anywhere.

**Deliberately NOT here.** The immediate emitters stay for one-shot
callers (world build, level geometry — they emit once into static
buffers, no per-frame pain). Star/pickup fields still emit immediate
per frame (openworld stars ride gb.lathe directly) — the next profile
vote can move them onto bakes with the same discipline. LE-host
assumption documented on the C door (matches the PAL's existing
targets). A GPU-side matrix/lighting path (true instancing) stays a
post-alpha idea; the C loop already leaves figures ~2% of frame.

**Revisit triggers.** A figure-heavy scene (>20 near figures) votes for
per-figure segment batching (one x_tris per figure instead of per
shape); an editor figure-preview window reuses emit_baked as-is.

## D118 — cross-project clip drops load their own siblings; the console gets selection (2026-07-18)

Two native-Windows findings from the human's first real 3D clip
round-trip (export a bigworld `.ctrace`, switch to the demo project,
drag it back in).

**The drag-in error.** `cm.restore_bundle` seeded unloaded bundle files
and re-ran changed loaded ones in a SINGLE interleaved pass — so when a
cross-project clip's `main` (hash differs from the live project's)
re-ran and its top level required a sibling (`world`) the loop had not
seeded yet, the loader fell through to the LIVE project's disk
(`projects/demo/world.lua`: no such file). Never seen before: a
same-project drop has matching hashes (no re-run) and every clip KAT
project was single-module. Now restore_bundle is TWO passes — seed every
unloaded file first, then re-run the changed ones (which resolve
bundle-seeded siblings through the registry; execution order inside
pass 2 is safe under the D093 module-table-adoption contract). Worse,
the failure TORE THE LIVE SESSION DOWN: scrub's do_load caught the
error after ring_load had already replaced buffers/doc, restored the
stashed ring but never the stashed present — the demo then crashed on
freed buffers. The failure path now heals with the close path's exact
restore order (present state, after_restore, then the live ring).
Repro + fix proven with a real bigworld clip opened from a demo editor
session (loads, mounts, 159 frames) and a truncated clip (fails loudly,
session steps on). 2 new KATs in t_bundle pin the sibling-after-requirer
ordering; the suite's every trace verify rides restore_bundle and stays
green.

**Console select/copy.** The console window's log had no selection (the
human's second report). It now has the docs reader's drag-selection,
console-shaped: glyph-precise utf8-safe picking via pal.x_ig_text_size
(pick_ci — a pure prefix walk), multi-line extraction exactly as shown
(timestamps included, \n-joined — `sel_text`, pure), Ctrl+C through the
shell's kind_call("copy") with a "copied" tag, Esc through the kind
escape hook, drag autoscroll that unsticks the tail-follow, and an
honest validity rule: selection state is module-local by win.id (never
on the captured window — the D112 discipline) and indexes the filtered
list, with the anchored line's text as a tag so a scrollback trim or
filter change DROPS the selection instead of drifting it. The input
line is a real imgui edit — its own Ctrl+C/V/X are the widget's native
clipboard ops (wired via the SDL3 backend); if paste still fails
windowed on a host, that is an imgui-host bug to chase with a repro,
not a console one. 10 new KATs (pick boundaries incl. utf8, extraction
spans + normalization, escape semantics).

Proof: Linux selftest **24,403**; native Windows **pending the stage swap** (the human's staged editor is running — the D118 code is cross-platform-plain Lua and the stage retry is queued; the stale stage still passes its own 24,393);
`nix run .#test` ALL GREEN, every golden byte-identical (both changes
are load-path/chrome — no sim byte moved). Inspected capture on
llm-feed: the console window with a live multi-line selection, partial
first/last lines, and the copied tag.

**Deferred, named honestly:** double-click word-select in the console,
a scrollback-trim-surviving selection (content-anchored endpoints), and
console text search (Ctrl+F via the shell's find route) wait for real
votes; the standalone-clip materialize path warns but proceeds when a
clip carries no tree (legacy) — a "clip carries no assets" pill in the
tray is a cheap future affordance.

## D119 — the 3D documentation pass: scripting.md gains the retro-3D reference (2026-07-18)

The cosmic3d merge (D114) deferred its author-facing docs to a mechanical
session. This is it — pure prose/markdown, no sim/render/recorded byte
moved (selftest holds at **24,403**, `nix run .#test` unaffected by
construction: docs are not compiled).

**Where the 3D reference lives: `engine/stock/docs/scripting.md`, one
file.** The A8 charter designates the scripting guide the "exhaustive
public API/task reference", and one file keeps a single findable module
index and one determinism contract. The 3D content is fenced under a
`## Making a 3D game (the retro pipeline)` umbrella that tells a 2D author
to skip it, then a `## 3D drawing primitives (pal.x_*)` section, then one
`## …(cm.x)` section per module (m4, gb, terr, atlas, fig, mascot, spr,
rig, kin, walk) — the same `## Title (cm.mod)` shape the 2D modules use,
so each is D110-findable by name. Verified: `cm.docs.search` over the real
doc lands every module query on its own section, and `x_view3d` /
`x_figverts` / `pick ray` / `heightfield` / `mouselook` resolve to the
right sections. The 20-line module index and the Compatibility section
(PAL API bumped **19 → 22**, plus the MREL additive-record note) were
updated to match.

**The tricky-parts checklist from the handoff was honored — and one item
corrected against the source.** Fork "PAL API 15/16" numbering is dead;
the doc uses mainline v20 (3D) / v21 (relative mouse) / v22 (baked
figures). The 3D pick ray is documented as `cm.walk.raycast`, never a
"cm.pick" (that name is the 2D picker's). `cm.kin` is documented as pure
value-based functions (not a component system) and `cm.rig`/`cm.walk` as
owning a buffer *layout* but not the buffer — the verbatim layout tables
are reproduced. The capture-vs-recorded split is stated (sim reads
`input.mouse_rel()`, never `pal.x_mouse_capture` state). **Correction:**
the handoff's shorthand called x_grade and x_soft both presentation-only
with the internal target "never" seeing them; the PAL source
(`luabind.c`/`gfx.c`) is explicit that **x_grade bakes into the internal
target before readback — so pixel goldens DO see the grade** — while
x_soft is a present-blit effect the target never sees. The doc states the
real distinction; the load-bearing invariant both share (**neither is ever
read by the sim**, D036) leads.

**ARCHITECTURE.md got the contract-level half.** The `rc.` render-class
buffer domain is documented beside the `ed.` editor domain in the state
model (both excluded from snapshots/traces by `cm.state.sim_buffer`;
D3D-012/D3D-025), and the PAL API contract gained v20/v21/v22 sections
(the 3D pipeline, relative mouse, `x_figverts`). `docs/README.md` notes
that scripting.md now carries the 3D author reference with COSMIC3D.md as
the design doc behind it.

Proof: selftest **24,403** (unchanged — the t_docs smoke parses the new
markdown clean), `cm.docs.search` findability spot-checked headless
against the shipped doc, and reader-safety checked — the shipped bitmap
font only renders a known glyph set, so the new prose was kept to glyphs
the existing docs already use (`>=` and `64x64` replaced `≥`/`64²`).
Deferred, named honestly: DECISIONS3D.md stays a closed namespace (this
entry is in DECISIONS.md, per the merge); the editor's 3D asset windows
(terrain paint, figure vertex-pushing, sheet preview) stay parked, so no
`win-*.md` guide exists for them yet; a worked end-to-end 3D tutorial (the
getting-started walkthrough's 3D twin) is a later A8-style packet, not
attempted here.

## D120 — per-module reference sections close A8's searchable-reference bar (2026-07-18)

The A8 checkbox held on one honest gap: the 20-line "Small module
reference" was still an index, and the 2D modules `cm.tmap`,
`cm.anim`/`cm.sprite`, `cm.palette`/`cm.grade`, and
`cm.rand`/`cm.math`/`cm.ease` had no full section (D119 gave the ten 3D
modules theirs). This packet promotes them — pure prose/markdown plus
selftest Lua, no sim/render/recorded byte moved.

**Four new/deepened sections in `engine/stock/docs/scripting.md`,**
each in the established `## Title (cm.mod)` shape with signatures and a
copyable example lifted from real bundled-project usage:
`## Tilemaps (cm.tmap)` (the .tm doc/codec/grid ops, the placed-on-a-map
common path, `graybox`, the culled batched draw — placed after map
collision); `## Animation clips and sprites (cm.anim, cm.sprite)` (the
old thin `## Animation` deepened: clip shape + loop modes, the
cosmetic/sim-bound timing anchors, `.meta` pivot/slices via
`load_meta`/`find_slice`); `## Palettes and color grading (cm.palette,
cm.grade)` (the demo's sky + per-room mood pattern, the preset table,
the never-sim contract); `## Deterministic randomness, math, and easing
(cm.rand, cm.math, cm.ease)` (stream-in-`cm.sim`-buffer seeding,
`ensure_seeded` vs `seed`, the draw family, the fdlibm trig + wrapped-
angle rule, the by-name endpoint-pinned curve registry) — placed at the
end of the 2D task sections, directly before the 3D umbrella.

**Eight headings retitled to name their modules** — `cm.state`,
`cm.input`, `cm.gfx`/`cm.text`, `cm.map`, `cm.collide`,
`cm.snd`/`cm.ins`, `cm.options`, `cm.save` — because the findability
sweep showed those names landing on the index line or the WRONG doc
(`cm.map` → win-map.md, `cm.snd` → win-music.md): body mentions lose to
foreign heading hits, so the module name belongs in its own heading (the
D119 rule, now uniform). The one in-doc anchor (`#player-saves`) was
updated to the new slug.

**The exit criterion is now KAT-pinned, not just verified once:** t_docs
gained a tolerant sweep — every supported `cm.*` (all 35: the 25 2D + 10
3D) must land a `scripting.md` hit whose section heading names it —
so a future retitle that drops a module name from its heading fails the
suite instead of silently degrading search. Linux selftest **24,403 →
24,438**; `nix run .#test` ALL GREEN, every golden byte-identical (docs
are not compiled). Captures inspected on llm-feed: the reader landed on
the Tilemaps section (heading panel, highlighted copy-chipped example),
and the home search `cm.rand` ranking the new section first.

**This closes ALPHA §A8's searchable-reference checkbox**: modules (now
per-module depth), project schema, determinism rules, common failures,
and compatibility policy are all present, anchored, and findable.
Deferred, named honestly: in-doc Ctrl+F find, launcher content-search,
result keyboard-nav, span-precise highlight (all D110-logged); the
native Windows selftest re-count rides the next successful stage swap
(the staged editor was running — same D118 condition).

## D121 — reader scroll ergonomics + launcher doc-section search (2026-07-18)

Three human asks against the docs surface, all editor chrome — no
sim/doc/recorded byte moved.

**The reader's scrollbar was paint-only; now it is a control.** The
gutter right of the text band (disjoint from the selection region by
construction, so a grab can never start a text drag) is the hit zone:
clicking the knob drags it with its grab offset, clicking the track
centers the knob at the mouse and keeps dragging; the knob widens and
brightens on hover/drag, and dragging dismisses the landed-here
highlight exactly like the wheel. The knob geometry and drag targeting
are pure exported functions (`sb_knob`/`sb_target`) that draw feeds
live values — that is what the KATs pin (floor at 20*z, full-scroll
lands the knob flush at the band bottom, linear track mapping, both
clamps). Drag state rides the module-local `sel_state`, the D112 rule —
never a captured-window field.

**Keyboard scrolling** rides the declarative windowkit table (EDITOR.md
§13), so the hint strip advertises it and the keys can never fire while
an imgui edit widget owns the keyboard: **PgUp/PgDn** page by 0.9 of
the measured band (`win._band`, stored by draw beside `_maxscroll` —
same class of transient scalar), **Home**/**Ctrl+PgUp** jump to the
top, **End**/**Ctrl+PgDn** to the bottom; all clamp through one
`scroll_by` (exported, KAT'd) and every entry when-gates on real
overflow so a short doc renders no hints. The kit's scancode table
already carried pgup/pgdn/home/end — no shell change at all.

**The launcher now content-searches the shipped docs** — D110's named
"launcher content-search" deferral, paid. A non-empty query appends up
to 8 `cm.docs.search` section hits (tag `sect`) BELOW the fuzzy name
matches: the two rankings are incomparable, and a name match ("sprite"
→ the sprite window) should stay first for the palette's primary job.
Each hit previews the doc source from its matching line in the existing
lines pane; enter opens the reader revealed+highlighted at that section
via the same `goto_line` door the reader's home uses. Power users get
Ctrl+Space straight to a doc page; the reader's home search stays the
discoverable path.

Proof: Linux selftest **24,438 → 24,471** (33 new KATs in
`t_help_keys`: the six declared keyspecs parse, paging/clamping/marker
dismissal, the overflow when-gate both ways, and the scrollbar math),
native Windows **24,473** on PAL API 22; `nix run .#test` ALL GREEN,
every golden byte-identical. Captures inspected on llm-feed: the
launcher's `deadzone` sect results with the section preview, and the
reader with the knob + the new hint strip. `editor.md` documents both.
Deferred, named honestly: key-repeat on held PgUp/PgDn (the kit
dispatches on `not e.rep` for every kind — a kit-wide decision, not a
reader hack), launcher result keyboard-nav paging, and in-doc Ctrl+F
find (still the next cheap reader packet).

**Same-day follow-up (the human): the launcher no longer remembers the
last query.** `M.open` always reset `q = ""`, but the ghost edit
widget's per-id buffer survives a dismissal (the field is still ACTIVE
when the overlay dies — nothing ever deactivates it), so on reopen the
widget returned its retained text and `draw`'s change-sync wrote the
old query straight back into `l.q`. The open frame now passes the
widget's `set` flag beside `focus` (deactivate-first + adopt the
incoming empty text — the D051 door built for exactly this). No KAT can
reach it (the widget needs the live imgui host, which the headless
selftest never boots); proven both ways with a scripted draw-hook
driver — open/type/close/reopen read `[stale query]` before the fix and
`[]` after.

## D122 — sprite new-file door; zoom-anchored reader scroll; Aa-invariant game blit (2026-07-18)

Three human reports against the editor surface, all chrome — no
sim/doc/recorded byte moved.

**The sprite window can now create a sprite.** The unbound state showed
only "drag a .spr from an assets window" (a stale comment claimed a path
field that never existed). It now uses the kit's `pathfield` — the
tmap/music new-file prompt: forced `.spr` extension, prefilled unique
auto-name, Enter creates, an existing path offers open/overwrite/cancel
— and the kit's existing `fresh` door supplies the 32x32 starter doc; a
brand-new sprite opens in edit mode. Zero new machinery: the affordance
was one wiring gap.

**Zooming no longer scrolls the docs.** The reader keeps `win.scroll`
in content-space px while every content height scales with the font px
(canvas zoom × Aa scale) — so a zoom re-laid the doc under an unscaled
scroll and the view visibly drifted. On any reflow of the SAME doc the
scroll now rescales by the content-height ratio (exact — the layout is
linear in px), and the home lists do the same by px ratio. **The class
guard, named:** a window that keeps a raw pixel scroll over
zoom-scaled content must anchor it across reflows; `winview`'s
world-unit scroll (assets) and the console's row scroll are immune by
construction — new scrolling windows should use one of those models,
and the reader's ratio anchor is the pattern when they can't.

**The game blit ignores the Aa scale.** `cam.display_scale` multiplies
every canvas window's screen rect, so raising the text size turned a
CTRL-snapped 2x game window into a 2.5x (blurry) or 3x (resized) blit —
the D054 pixel-perfect snap tested the SCREEN scale. The new pure
`game.blit_scale(s, ds)` divides the Aa scale out first: the snap
targets the DESIGN multiple, clamped to the largest integer the well
fits (an Aa below 1 falls back rather than overflowing), so the game
image is a crisp, constant-size integer multiple at any text size — the
chrome grows around it, the pixels do not. Free (non-snapped) resizes
pass through unchanged, and `ed.g.grect` mouse remapping follows the
recorded scale automatically.

Proof: Linux selftest **24,471 → 24,480** (9 `t_game_blit` KATs across
both Aa directions, noise, fallback, and pass-through); `nix run .#test`
ALL GREEN, goldens untouched. The reader anchor and the sprite door are
imgui-host behavior (no headless-selftest reach): one scripted
`smoke --edit` driver proved all three live — scroll 800 → 1200 tracking
contenth ×1.5 exactly across a mid-run Aa flip, the pathfield's bind
door yielding a fresh 32x32 single-layer doc, and `grect.s == 2` for a
2x window at Aa 1.5. Captures inspected on llm-feed (the prefilled
new-sprite prompt). `win-sprite.md` documents the door.

## D123 — FSIZ: the recorded target size; game windows opt their rect out of Aa (2026-07-18)

Two follow-ups on D122 from the human's feel-check.

**The game window still grew (blank well) on an Aa change.** D122 pinned
the blit multiple but the window rect rides the uniform canvas
projection, so the well grew around a constant image. The projection
cannot special-case one window (wm hit-tests in world space), so the
shell now compensates the DOC rect instead: when the applied Aa scale
changes, every game window's image area (rect minus the pads — those
keep chrome-scaled borders) rescales by old/new, keeping the screen
footprint and the crisp blit constant. This edits canon window fields
on an Aa click — deliberate: it is a user action, undo/session treat it
like any resize, and a session opened under a different machine scale
simply shows the rect that machine's click left (the D074 concern does
not apply — nothing rescales at boot, only on a live change).

**Ctrl+edge resizing a 3D demo squashed instead of adapting FOV — and
the fix needed a new recorded input.** The demos froze `W, H =
pal.gfx_size()` at boot (correctly: live size in sim breaks replay), so
a live FOV change stretched their fixed-aspect projection over the new
target; the pick-ray unprojection squashed consistently with it, so a
render-only aspect fix would have broken click-to-move. The live target
size is now first-class recorded input: **extension tag 3 = FSIZ**
(i16 w, i16 h, the D116 MREL model) — `input.game_size()` latches the
domain on first read and every later record carries the frame's
`pal.gfx_size()`; unlike MREL it is a LATCH, not a delta (a bare record
keeps the last size). Until any sized record applies — and in every
pre-FSIZ trace — it returns the project's **design resolution**, which
IS the boot target, so record and replay agree by construction and
every historical golden stands. The applied size lives in the
`cm.input` named buffer ([20]/[22]), so snapshots and rewind restore it
like any input state. All six 3D demos now refresh `W, H =
input.game_size()` at the top of step and draw: aspect adapts, HUD
anchors track, pick rays stay consistent with what is on screen.
`fsiz_reset` joins `mrel_reset` on the boot path. Pure Lua — no PAL
change (the v21 bump was for capture; the record lives in `cm.input`).

Proof: Linux selftest **24,480 → 24,489** (9 t_input_fsiz KATs:
dormant/latch emission, apply authority over the live target, the
bare-record LATCH semantics, design-res fallback + reset, malformed
refusal); `nix run .#test` ALL GREEN — **every committed 3D trace and
pixel golden byte-identical** (their replays carry no FSIZ, so
game_size reads the design res = exactly the old boot-frozen values;
their SNAP bundles carry the old code besides). Live proof on
openworld `--edit`: FOV widened 320x240 → 426x240, `game_size` tracked
it, the scene rendered undistorted at the wide aspect (capture on
llm-feed, shot AT Aa 1.5 with the compensated rect still blitting
exactly 2x — AA_PRE w=866 → AA_POST w=582, grect.s=2.0).
`scripting.md` (the 3D umbrella + the compatibility bullet) and
`ARCHITECTURE.md` (the record-extension list) document it. Deferred,
named honestly: no committed trace exercises a MID-trace FOV change yet
(the first real 3D resize-while-recording session should be exported
and committed as that golden); the 2D demos keep their render-side
`pal.gfx_size()` HUD reads (nothing sim-side depends on it there).

## D124 — replay follows the recorded FOV; rovale ships its bake; varied trees (2026-07-18)

Three reports from the human's native session with the D123 build.

**A replay showed black bars where the live window adapted.** D123 made
the SIM see the recorded size, but nothing re-aimed the render target
during time travel: a clip (or a parked past) recorded at a resized FOV
replayed into the boot-size target and the game window letterboxed it.
Now the game window, while `scrub.paused()`, follows the applied FSIZ:
`input.fsiz_applied()` is the NON-latching read (chrome observing a
replay must never arm the domain into a live recording — 3 KATs pin
that), and a mismatch re-aims `view.canvas_fov`. Scripted proof across
a mid-session FOV change (320 → 426): parked early the target reads
320x240, parked late 426x240, back live the window's own — both
directions, same session.

**rovale no longer bakes its terrain at every boot.** The per-tile
atlas bake (1024 unique 34x34 tiles at 8/frame) filled visibly for ~2s
on every launch. `cm.atlas` gained the shipped-bake snapshot:
`A.export` (PNG of a finished bake — refuses an unfinished one) and
`A.import` (dims-checked, fills the pixel buffer, marks done under the
current stamp, uploads). PNG is lossless RGBA, so an imported atlas is
byte-identical to the bake that produced it — the budgeted loop stays
the dev-side authority. rovale commits
`spr/terrain-atlas-v<BAKE_STAMP>.png` (1.5 MB; the stamp rides the
FILENAME, so a texel-math bump orphans the asset and the progressive
bake silently takes over) — `game.bake_atlas()` on the console
re-exports it, the `rebake_sprites` model. Boot now reads bake-done by
frame 2. 9 KATs (t_atlas_snapshot): a 2x2 bake round-trips
byte-identical through export/import, layout mismatch + garbage refuse,
unfinished-bake export refuses.

**The tree canopy tuft varies per tree.** Every rovale tree carried its
small top ball at the same offset — read as obvious repetition. The
tuft now rides a POSITION hash (never the placement stream, D3D-022:
props, casters, and the walk-grid blockers stand exactly where they
always did, so sim state is untouched): yaw around the canopy, reach,
height, and size all vary, and about a quarter of trees grow a second
tuft. Render-only by construction.

Proof: Linux selftest **24,489 → 24,501** / native Windows **24,503**;
`nix run .#test` ALL GREEN — every trace byte-identical (bundled old
code + no sim byte moved), the two rovale pixel goldens honestly
RE-CUT on pinned lavapipe for the tree change (the shipped atlas
itself is pixel-neutral: the golden frames sit past bake completion
and import is lossless) with landmarks inspected (gazebo, NPCs, path,
pond). Captures on llm-feed: a fresh boot at frame 12 fully baked with
varied trees; the re-cut tour golden. Deferred, named honestly: the
committed mid-trace-FOV golden (D123) still awaits a real recording;
bigworld's noise-driven terrain has no bake to ship (its cost is mesh
emission, already fast).

## D125 — the Aa/FOV footgun fix: derive, stamp, and anchor (2026-07-18)

Two reports from the human's native D124 build: the 3D game window
"starts letterboxed now and then, flickers to filling when I resize",
and changing the global text size (Aa) moves windows apart. Both traced
to the same class of bug — one-shot pushes of state that should be
continuously derived — and the ask was to fix the footgun, not bandaid
the symptoms.

**The letterbox: `view.canvas_fov` was a write-only latch.** The game
window pushed it on resize gestures and at session launch; D124's
paused-time re-aim overwrote it with the recorded FSIZ; NOTHING ever
put the live window's choice back. Reproduced end-to-end: park early in
a session recorded at the design res, unpark — the target stays at
320x240 under a 426-shaped window (black side bars), a resize is the
only cure, and the live recording even stamps the stale size into new
FSIZ records. D124's "back live the window's own" held only in its
input-layer KATs, not in the shell. Now the FOV is **derived every
frame** in `cm.ed.frame`: time-travelling → the recorded FSIZ
(`input.fsiz_applied`, non-latching, D124's rule preserved); live →
`game.pick_fov` (pure, KAT'd) over the doc's game windows — the
explicit owner (`ed.g.fov_owner`, ephemeral, set by resize and launch:
last resized/loaded wins, the D054 multi-window rule) → the last sized
window → the design res when a game window exists at all. A derived
value cannot go stale; the draw-side D124 block is deleted (a draw-side
push also only ran for VISIBLE windows — the shell is the right home).
`constrain` keeps its same-frame `apply_fov` for gesture snappiness.

**The moving windows: two causes, one model.** The Aa canvas-windows
scale multiplies the camera zoom, so changing it IS a zoom — and it was
anchored at the screen origin (cam.x/y untouched), so the whole layout
slid toward/away from the top-left. `cam.aa_anchor` (pure, KAT'd) now
re-anchors the camera so the world point at the viewport center stays
centered: the layout grows/shrinks in place. On top of that, D123's
game-window opt-out (screen footprint constant) rescaled doc rects via
a PROCESS-GLOBAL edge detector (`g._aa_ds`): it fired only on a live
change in the same process, so a session opened at a different Aa than
it was saved at (auto-DPI change, monitor move, cross-machine) was
silently wrong — canon bytes depending on machine-local state with no
reconciliation. Now each game window carries the Aa it was laid out at
(**`win.aa`**, captured — an explicit layout stamp): any mismatch, live
or at load, rescales the image area by old/new (size only since
follow-up 3 — the top-left corner is Aa-invariant like every other
window's), restamps, and touches the doc like a resize. Crisp integer
design multiples recompute EXACTLY (`fw*k/ds`) so repeated flips never
accumulate float drift — a 1 → 1.5 → 1 round trip restores the doc rect
bit-for-bit (KAT'd + proven live). Pre-stamp sessions adopt the current
Aa without rescaling (exactly the old boot behavior). All three
reconciles skip while parked: the past renders as recorded, the present
heals one frame after unpark. An Aa change also cancels an in-flight
camera ease (its endpoints predate the new mapping).

Proof: Linux selftest **24,501 → 24,518** / native Windows **24,520**
(17 new KATs: `t_game_fov`
owner/last-sized/design/out-of-range, `t_game_aa` footprint/center/
round-trip/crisp-recompute/identity, `t_cam_aa` center invariance both
directions); `nix run .#test` ALL GREEN, every trace and pixel/audio
golden byte-identical (all of this is editor chrome — no sim/recorded
byte moved; `win.aa` rides the captured doc like any window field).
Live scripted proofs on a bigworld copy: the D124-class park/unpark now
returns to 426x240 the next frame (was stuck at 320x240 letterboxed,
screenshots both ways); an Aa 1 → 1.5 → 1 flip holds the game image
area at exactly 852 screen px with the note window scaling about the
viewport center, and round-trips the doc exactly; a session saved at
Aa 1 booted at 1.5 heals on frame 1 (582x354, stamp 1.5, same screen
footprint). EDITOR.md §3/§12.3 and the shipped `editor.md` document
the model. Revisit triggers: if a future kind needs Aa-constant
footprint too, generalize the stamp+reconcile into the kind contract
rather than copying it; if per-window content scaling (text grows,
window doesn't) is ever wanted, that is a per-kind layout audit — a
different, much larger packet, deliberately not attempted here; and
the anchor point is the raw VIEWPORT center — if the human reports a
far-off-center window cluster sliding toward a screen edge on an Aa
change (visible in the capture pair on the feed), anchor at the
visible windows' bounds center instead.

**Same-day follow-up (the human, with a trace): zooming flickered
between letterboxed and filled.** `bigworld-clip-441-568.ctrace`
confirmed the setup (a 426x240-FOV session; the human runs Aa 1.5).
Root cause: a LEFTOVER half of the D122 compensation. `blit_scale`
still divided the machine Aa scale out of the well scale before its
integer snap — correct when D122 wrote it (the rect was uncompensated,
so the well grew with Aa and s/ds was the design multiple) — but D123/
D125 moved the Aa compensation into the RECT (`win.aa` reconcile), so a
game window's well scale is ALREADY Aa-invariant (design multiple ×
canvas zoom) and dividing ds out a second time made the snap fire at
s/ds-integer points where s itself was NOT integer: at Aa 1.5 a zoom
sweep crossing z=0.75/1.5/2.25 collapsed the image to r < s (a 2x blit
inside a 3.0x well, fill 0.662) for the frames inside the snap window —
the letterbox blink. Invisible at ds=1 (s/ds == s), which is why the
D125 WSL proofs missed it. Fix: `blit_scale(s)` snaps the well scale
ITSELF — the ds parameter is gone, the draw site no longer reads
`cam.display_scale`, and the "largest fitting integer" clamp died with
it (r is within noise of s by construction). Bonus fixed en route: at
Aa 1.5 / zoom 100% the 2x blit used to return exact=false (s/ds=1.33)
and skipped the whole-px origin snap — it now snaps origin too.
Proof: t_game_blit rewritten to the new contract (8 checks, including
3.02 — the exact old flicker input — passing through unsnapped); Linux
selftest **24,517** / native Windows **24,519**; `nix run .#test` ALL
GREEN, goldens byte-identical. Live: the drv5 zoom sweep 1.0→2.0 at
Aa 1.5 held fill ≥ 0.99 everywhere (was 0.662 at z=1.50); the human's
clip opens clean — recorded FSIZ 426x240 followed while parked, game
window fill 1.000 across the whole A/B loop at Aa 1.5. Before/after
zoom-1.5 captures on llm-feed.

**Same-day follow-up 2 (the human): the CTRL game-window resize at Aa
125% snapped to a non-pixel-perfect size.** The last member of the same
class: `constrain`'s CTRL snap rounded the WORLD-unit scale to integers,
but the Aa canvas scale multiplies the doc rect on screen — at Aa 1.25 a
world-integer multiple draws at 2.5x and the blit never snaps crisp. The
snapped quantity must be the SCREEN design multiple: `game.snap_mult(s,
ds)` (pure, KAT'd) rounds `s*ds` to a whole number ≥ 1 and returns
`k/ds` — exactly the shape `aa_rect`'s crisp branch recomputes, so a
CTRL-snapped window stays crisp across Aa flips (KAT-pinned: the snapped
Aa-1.25 rect flips to Aa 1 as an exact 2x). Both CTRL sites (the
horizontal walk's gesture anchor and the final scale) route through it.
Proof: Linux selftest **24,523** / native Windows **24,525** (6 new
t_game_snap checks); suite ALL GREEN, goldens byte-identical. Live at
Aa 1.25: a scripted CTRL corner drag to world 2.3x through the real
constrain door lands world s=2.4 = screen 3.0000, and the drawn blit
reads s=3.0000 integer-exact (was: world 2.0 = screen 2.5, never
crisp). With this, every place that reasons about game-window
crispness — the blit snap, the rect reconcile, the CTRL snap — speaks
the same unit: the screen design multiple.

**Same-day follow-up 3 (the human): the game window's top-left corner
must not move on an Aa change.** D125 center-anchored the win.aa rect
reconcile (splitting the size delta across both edges to soften
neighbor drift). The human's taste call is the opposite and simpler:
every OTHER window's x,y is Aa-invariant — windows never shift relative
to each other on a font-size change — so the one window that slid
around was the game window itself. The reconcile is now SIZE ONLY:
`aa_rect` returns just (w2, h2), the shell leaves w.x/w.y untouched,
and the window resizes in place from its corner. The size change
relative to neighbors is inherent (that is the Aa opt-out working); the
position change was not. Supersedes the center-anchor sentence in the
main D125 entry. Proof: t_game_aa re-pinned (size-only return, corner
semantics; count holds at Linux **24,523** / native **24,525**); live
Aa 1 → 1.5 → 1 flip holds the game window at x=40,y=40 exactly through
both hops while its rect round-trips 866x514 ↔ 582x354 bit-exact and
the neighbor note window never moves; suite ALL GREEN, goldens
byte-identical. (The viewport-center CAMERA anchor from D125 is
untouched — that one maps ALL windows uniformly and cannot change their
relative layout.)

## D126 — mouse-look capture: the wish/consent pump (2026-07-18)

**Decision.** `input.capture_mouse(on)` no longer touches
`pal.x_mouse_capture`. It declares the cartridge's capture WISH (and still
arms the MREL domain latch); the actual OS relative-mouse mode is DERIVED
every tick by `cm.input.capture_pump(allowed)` from wish AND the shell's
consent — the D125 derive-don't-latch rule applied to the OS cursor. One
owner: nothing else calls the PAL door (the options menu's direct release
is deleted; the pump withholds consent instead). Consent, computed in
`cm.main.tick`: never while the options menu, the crash autopsy, or a
parked time machine needs the cursor; in the editor only while
`cm.ed.game_live()` holds — the focused game window with no shell layer
over play, the EXACT `filter_events` live condition, extracted so the two
consumers can never drift; player mode otherwise consents. The wish
STANDS across a denial, so closing the menu / refocusing the game
re-captures by itself, and a game that armed capture in `game.init` never
manages OS state again.

**Why a wish, not a flip.** The one-shot flip class had three real
failures waiting: a replay/rewind re-running a mouse-look game's `init`
would grab the LIVE cursor while the user browses the past; an
editor session would capture while the user types in the code window
(init runs long before any game window is focused); and the D116-era
menu release lost a boot-armed capture forever (nothing re-asked). All
three die by construction when the OS state is derived per tick.

**The way out is named on screen.** While captured the user cannot click
another window to unfocus — the cursor is gone. The game window's chip
reads **PLAYING · ESC RELEASES MOUSE** (Esc = the shell's universal
get-out, `doc.focus = 0`); ALT, the launcher, an edit widget, time
travel, and the Esc menu also release by dropping the live condition.
While captured (and live), `filter_events` passes motion/button/wheel to
the game regardless of the over-the-image test — the frozen cursor
position is meaningless, the MREL deltas are the payload.

**The demos.** openworld, bounce, and bigworld arm
`input.capture_mouse(true)` in `game.init` — the D116 human-gated feel
change, now voted in. The rig already sums `input.mouse_rel()` with
drag-look, so captured and drag look coexist; sim reads only recorded
deltas, so replay/verify never depend on capture state.

**Determinism.** No sim/doc/recorded byte moved: the wish/`_cap_on` pair
is live chrome on `cm.input` (never in a buffer/snapshot), MREL emission
rules are untouched, and verify replays never sample. Every committed
golden stands byte-identical.

**Proof.** Linux selftest **24,533** / native Windows **24,535** (10 new
capture-pump KATs: wish-alone captures nothing, consent gates both ways,
the domain outlives a dropped wish, reset clears all); `nix run .#test`
ALL GREEN. Live WSLg (real window, scripted driver): focus → `os=true`,
Esc/unfocus → `os=false`, menu open → released, menu closed →
re-captured; the capped composite capture shows the chip hint (on
llm-feed). Windows stage refreshed (7 durable entries + shortcut).

**Revisit triggers.** A game that wants capture only in a sub-state
(e.g. aiming) calls `capture_mouse(false)`/`(true)` from its own logic —
if a real game needs finer grants (per-window wish, capture in an
unfocused-but-watched window), that votes a capture policy surface. If a
player reports "the mouse vanished" in PLAYER mode, the Esc-menu line
may need an on-screen first-capture toast there too.

## D127 — the in-engine Getting Started walkthrough, verified by driving the shipped UI (2026-07-18)

**Context.** ALPHA §A8's first box: "In-engine Getting Started completes
create → modify code/art/map/audio → play/debug/rewind → export, using
only shipped UI." `getting-started.md` was an orientation page; nothing
had ever *walked* the whole promise in one sitting. The packet's method
was the point: script the walkthrough against the real editor with a
synthetic input tape (`pal.x_ig_event`'s documented capture-mode door +
a `pal.poll_events` wrapper), and treat every place the tape could not
proceed through shipped UI as a finding, not a wording problem.

**The walkthrough.** `getting-started.md` now carries "Your first game":
create (picker → the four-starter chooser → platformer), play (focus =
playing), rewind (F4 → park → resume-here → Esc back), change the code
(launcher → main.lua → Ctrl+F find/replace → Ctrl+S → live hot reload),
draw a sprite and draw it from `gfx.sprite`/`gfx.texture`, author a map
marker (`maps/room.map`, label `goal`) and read it via `map.use` +
`room.doc.markers`, make a sound (synth new-file door → the stock
`sfx-jump` preset → `ins.upload` + `snd.on` in `step`), then name the
project and **build a player** (settings → player files → build/export →
atomic archive + SHA-256). Every step was executed as written by the
tape; the walkthrough project (`hello-hopper`) went end-to-end from the
"+ New project" click to a published `hello-hopper-0-1-0-linux.tar.gz`
(from the built release archive — the dev tree carries no portable
runtime and its preflight names that honestly). 12 new t_docs KATs pin
the walkthrough sections + findability ("first game", "walkthrough",
"build a player").

**Three real defects the tape found, all fixed at class level:**

1. **Enter on "+ New project" instantly scaffolded a blank project.**
   The grid's opening Enter was still in the frame's key batch when the
   chooser's name field spawned focused (`enter=true`) and `kb_row`
   defaulted to "create" — same-frame submit, chooser never seen. The
   action now carries `swallow = true` for its opening frame (the
   keyboard-modal class rule: the press that OPENS a modal must not
   activate its default action).
2. **Right-button content affordances were dead** — win-sprite.md's
   documented secondary paint and tmap's rmb-erase. `interact` runs
   BEFORE `draw`, so an unconditional right press armed the spawn-menu
   pend (`g.rpend`), which gates `hot_id()`; the kind never saw
   `clicked[3]`, and a still right-click over an editing sprite opened
   the spawn menu. New `kind.takes_right(win, ed)` claim: sprite and
   tmap (edit mode, content body below the header) keep the press, the
   pend never arms, hot survives, and the header/other windows keep the
   menu. editor.md documents the exception.
3. **A from-scratch text file could not be created in-editor** — the
   unbound code window was a picker over existing files only, so the
   export step's controls/credits/license had no authoring door (D122's
   sprite-window class, one wiring gap). The kit `pathfield` gained
   `opts.exts` (a set of keepable extensions; a bare name still gets the
   forced default) + a root-dir ("" ) auto-name prefill, and the text
   picker now runs it above the file list: typed `.md/.txt/.json/.glsl`
   kept, bare names become `.lua`. `open_asset`'s no-`fresh` path
   (empty bytes + journaled baseline) already handled a missing file.

**Also verified (not changed):** the occlusion rule (an overlapped
window's widgets are inert — the walkthrough now tells users to lay out
windows), the D125/D126 park/derive behaviors under the tape, live hot
reload in a real WSLg window (`[reload]` + the new JUMP in the running
sim, state preserved), and the release-archive export preflight/progress/
SHA surface end-to-end headless.

**Proof.** Linux selftest **24,545** (12 new); `nix run .#test` ALL
GREEN, every golden byte-identical (editor chrome + docs only). The
8-frame walkthrough montage, the new-file door, the right-paint fix, and
the rendered walkthrough are on llm-feed. ALPHA §A8's walkthrough box is
ticked.

**Revisit triggers.** If a second window kind ever wants right-button
content gestures, it adds `takes_right` — if a kind wants finer-than-
content claims (per-sub-rect), that votes a hit-region surface. The tape
driver (scratchpad `drive.lua`) is session tooling; if a third session
rebuilds it, commit a `tools/drive/` version with the proof recipes.

## D128 — the ui nav cursor: the Esc menu drives keyboard-only and pad-only (2026-07-18)

**Context.** ALPHA §A8's accessibility line requires keyboard-reachable
core flows and controller navigation where player-facing. The player-facing
surface is the Esc/options menu — and `cm.ui`'s interaction model was
pointer-only (`hot` = hover, widgets arm on click): a keyboard-only player
could open the menu but operate nothing, and a pad-only player could not
even open it (the Esc grammar read the keyboard alone; pads were read only
by the rebind capture).

**Decision.** `cm.ui` gains a navigation layer — chrome on the module
table, never sim, never persisted:

1. **Scope, claimed per frame.** An overlay that wants its widgets
   reachable calls `ui.nav_scope()` each frame it is open (the
   `capture_keys` shape; one-frame engage latency). Widgets drawn AFTER
   the claim register as nav targets — panels drawn before it (perf,
   console, the editor beneath the menu) never do, so the cursor cannot
   wander behind the claiming overlay. `cm.options` claims it on both
   pages, suspended while a rebind capture is armed (the next press must
   BIND, not navigate).
2. **A spatial cursor.** Arrow keys, dpad (11–14), or the left stick
   (±16384 press / ±8192 release hysteresis) move a cursor over the
   registered rects via pure `ui.nav_pick(items, cur_id, dir)`: the
   dear-imgui shadow rule — in-direction items whose off-axis span
   overlaps the current widget win, nearest first (down from a full-width
   row lands the NEXT row; right walks the row); no shadow hit falls back
   to best-aligned; nothing in the direction wraps to the far end. A
   slider registers its FULL row (label included) so the columns above
   still shadow it. Held pad directions repeat (18-tick delay, 6-tick
   interval, off `ui.ticks`); keyboard repeat rides the OS key-repeat
   events. Nav is inert while a text widget holds `ui.focus` — arrows
   must edit text (Esc blurs and nav resumes).
3. **Activation and adjustment.** Enter/Space/pad-south clicks the
   cursored widget (buttons click, checkboxes toggle, text fields take
   focus); left/right on an adjustable widget (slider ±`step` or
   (max−min)/20; number ±`speed`) steps its value instead of moving.
   The cursored widget draws a 1px accent ring outside its rect — the
   visible focus — is kept scrolled into view through the enclosing
   scroll region, and a mouse press on any target syncs the cursor
   there, so mixed mouse/pad use never strands the ring. The cursor
   seeds onto the first registered widget the moment a scope engages
   (visible focus with zero presses), and prunes when its widget
   vanishes (page switch).
4. **The pad door into the menu.** The pad **back/select** button (SDL 4)
   is the pad Esc: it opens the closed menu and walks the same
   one-step-back grammar (cancel capture → leave controls → close). It is
   therefore the menu's button the way Esc is — the grammar consumes it
   before an armed capture can bind it (`pad:start` was NOT usable: every
   starter template binds it to reset). **East** (B) also walks back but
   only while the menu is open and never while a capture is armed — games
   bind east, so east must stay bindable and only means "back" inside the
   menu.

**Determinism.** All nav state lives on the `cm.ui` module table
(render/dev class). While the menu is open `capture_pads`/`capture_keys`
already keep downs from the game, so recorded input is untouched; the
menu never opens in headless/verify/golden runs, and the pad grammar
reads the same raw `ui.inp.pads` stream the rebind capture already reads.
No sim/doc/recorded byte moved, no PAL change.

**Proof.** Linux selftest **24,605** (36 new in `t_ui_nav`: `nav_pick`
grid geometry incl. the shadow rule + wraps + single-column stay-put;
real `ui.frame` cycles — seed, arrow/dpad/stick moves, slider left/right
steps, Enter/south activation, held-dpad repeat, focus suspension,
mouse-press sync, scroll-into-view, scope prune; the options pad
grammar — back opens/walks/cancels-capture, east closes-from-main /
never-opens / binds-while-armed as `pad:east`). A scripted tape drove
the real menu on `projects/demo` headless: keyboard-only Esc → arrows to
master volume → two lefts → 90% → Esc out; pad-only back → dpad + stick
moves → up-wrap → south into the controls page → east back → back
closed — montage on llm-feed. Two bugs the proof found and fixed at
class level: in-direction scoring without the shadow rule skipped rows
(alignment-dominated) or rows skipped sliders (track-only rects), and a
Lua `and…or` fall-through in the overlap test. `nix run .#test` ALL
GREEN, every golden byte-identical. scripting.md's options section
documents the no-mouse operation.

**Deferred, named honestly.** The rest of the §A8 accessibility line:
reduced flash/shake options (an `options.add` convention + an engine
gate on `cm.camera.shake`/`cm.tween` render output — its own packet),
editor-side keyboard gaps (window focus-cycling, keyboard close/resize;
the launcher already covers keyboard spawn/open), non-color-only polish
(the rewind budget meter's amber/red threshold, the unsaved dot), and
pad navigation for the picker dialogs beyond its existing keyboard nav.
Revisit triggers: a second `ui.nav_scope` consumer (the crash autopsy?
the picker?) votes scope priorities; a game that NEEDS the back/select
button votes a rebindable menu button.

## D129 — reduced flash/shake: the accessibility policy rides the engine's render-only effect doors (2026-07-19)

**Context.** ALPHA §A8's accessibility line (opened by D128's nav cursor)
names "reduced flash/shake options" next. Screen shake and full-screen
flashes are the two classic photosensitivity/vestibular hazards, and the
engine already draws a hard line the feature can stand on: effect
*counters* are recorded sim state in the doc, while the *drawn* wobble
and wash are render-only derivations (`camera.offset`, `tween.wobble`,
game-drawn overlay alphas) that sim results must never read (D092/D094).
A per-player attenuation of the drawn side is therefore replay-safe by
construction.

**Decision.**

1. **The policy lives user-wide in `cm.view`'s accessibility store**
   (`editor.dat`, beside the D-series legibility scales — a
   photosensitive player sets it once per machine, never once per game):
   `cfg.reduce_shake` / `cfg.reduce_flash`, persisted only when set (the
   never-freeze-defaults rule), loaded strictly (`== true`; malformed
   values stay off), reset on every load. Headless / `--frames` /
   `--verify` sessions never load the store (main.lua's existing gate),
   so goldens cannot see the policy by construction.
2. **The scale doors:** `view.shake_scale()` → 0 when reduced else 1;
   `view.flash_scale()` → 0.25 when reduced else 1 (attenuate, don't
   delete: the death-cue survives, the wash goes). `cm.options` exposes
   delegating `shake_scale`/`flash_scale` — the documented game-facing
   reads for HAND-ROLLED effects, draw-only.
3. **The engine's render-only effect doors consume the policy
   themselves:** `camera.offset` (and so `apply`), `tween.wobble`, and
   the new **`tween.flash(o, name [, curve])`** — `val` times the flash
   policy, THE door for flash-overlay alphas. `val`/`k`/`mix` stay pure:
   sim legally reads those (hit pause), so policy in them would be the
   exact determinism bug the module headers warn about. This makes the
   "sim must never read wobble/offset" rule load-bearing rather than
   advisory — the headers and scripting.md now say why.
4. **The Esc menu** gains an "accessibility" section (main page, between
   volume and game options): "reduce screen shake" / "reduce flashes"
   checkboxes — keyboard/pad-reachable for free through D128's nav
   cursor.
5. **Retrofits:** swarm's death wash draws through `tween.flash`; the
   platformer demo's teleport-flash tint multiplies
   `options.flash_scale()` (the worked hand-rolled example). Shake needed
   zero game changes — both demos already ride the engine doors.

**Determinism.** No sim/doc/recorded byte moved; no PAL change. The
scales multiply render output only; at the default 1.0 every drawn byte
is IEEE-identical (x*1.0 == x), and headless sessions never load the
flags, so every golden stands byte-identical.

**Proof.** Linux selftest **24,626** (21 new in `t_reduce_fx`: unity
defaults + the options delegates; reduce-shake zeroes `camera.offset`/
`apply`/`tween.wobble` and releasing restores the exact bytes with the
recorded counters untouched; `tween.flash` attenuates ×0.25 with the
curve carried while `val`/`k` stay pure; the store round trip — only set
flags persist, stored flags adopt, malformed values stay off, a
store-less load resets). `nix run .#test` ALL GREEN, every golden
byte-identical. Headless tape on the REAL swarm Esc menu (captures on
llm-feed): toggling both checkboxes by keyboard, then the death moment
with the wash attenuated and the arena still.

**Revisit triggers.** A player report that 0.25 is still too bright (or
that a game's flash carries information the attenuation hides) votes a
per-effect floor or a stronger setting; a "reduce motion" ask beyond
shake (parallax, camera lerp) is its own packet; a game hand-rolling
shake that ignores `shake_scale()` is a docs/review issue, not an engine
gate.

## D130 — non-color-only chrome: the unsaved title mark and the disk meter's notch + "!" (2026-07-19)

**Context.** The A8 accessibility line's remaining polish (named in D128):
two chrome states that read by color alone — a window's unsaved state was
one amber dot, and the rewind tray's disk-use meter warned only by
warming its fill amber then red.

**Decision.** (1) A dirty window's title now carries a trailing ` *`
beside the dot (the universal editor convention), computed from the same
`kind.dirty` read the dot and reset chip already share. (2) The meter's
threshold rule extracted pure and KAT'd — `rewind.meter_zone(frac)` →
`ok`/`warm` (>0.7)/`near` (>0.9), garbage reads ok — and the fill color,
a permanent 90% notch on the track, and the label's near-state leading
`!` (drawn in the error color, but the glyph is the cue) all derive from
it, so the color and non-color cues cannot drift. The exact used/budget
numbers stay pinned beside both. Warm stays color-plus-fill-fraction
only: it is informational, not an alarm; the notch marks where the alarm
begins.

**Proof.** Linux selftest **24,630** (4 new meter_zone KATs); suite ALL
GREEN, goldens byte-identical (editor chrome only, headless never draws
the tray into goldens with a staged budget). Inspected captures on
llm-feed: `main.lua *` + dot + reset in a live smoke session; the tray at
a staged 95% budget with the red fill past the notch and the `!` label.

**Revisit triggers.** A pattern-fill or shape change on the meter if a
report says the notch is too subtle; the same non-color audit for any new
chrome that gains a threshold color.

## D131 — the Esc menu opens in the editor: launcher door, editor yield, the cm.ui drawlist sink (2026-07-19)

**Context.** The human's ask: devs should be able to test the player
options surface (volumes, rebinds, D129's accessibility toggles) from the
editor. Investigation found a latent half-state: D128's pad back/select
door already opened the menu inside `--edit` — but invisibly (the menu
draws with cm.ui on the ui canvas, and the composite order is game → ui
canvas → **imgui last**, so the editor's windows covered it) and
un-yielded (the editor kept handling the same clicks and hotkeys, and
`consume_legacy_keys` ate the Esc the menu's close grammar needed).

**Decision.** Three small pieces, no PAL change:

1. **The keyboard door:** the Ctrl+Space launcher gains its first `cmd`
   entry — "player options (esc menu)" — activation calls
   `options.toggle(true)`. The pad back/select door is now supported
   rather than latent. Esc deliberately does NOT open it in the editor:
   editor Esc stays the release/get-out (D126), and the menu's own
   grammar still closes one step at a time once open.
2. **The editor yields:** while `options.on`, `ed.interact` returns
   before hotkeys/legacy-strip/canvas interaction (the rewind
   `owns_pointer` precedent), gates imgui's mouse off, and keeps
   `g.ig_kb`/`g.last_ig`/animation fresh. The menu's existing
   `capture_keys/pads/mouse` already hold input from the game beneath.
3. **The cm.ui drawlist sink:** `ui.sink_begin(s)`/`sink_end()` route
   cm.ui's entire draw surface — `rect`, `text`, and the clip stack, all
   of it — to the imgui FOREGROUND drawlist (`pal.x_ig_overlay(true)`)
   at window-px scale `s`. Drawing only: layout, hit tests, and nav stay
   in ui-canvas coords, which map to window px by exactly `s` (the
   composite blits the ui canvas from 0,0 at ui_scale — the sink scale
   IS that scale). `options.frame` brackets its pages with the sink only
   when the editor shell is on; player mode draws the bitmap-font quad
   path byte-identically (the uigallery pixel golden pins it). Text
   renders in the native font at `gh × s` px — a deliberate visual
   difference from player mode, named here: function over pixel parity.

**Proof.** Linux selftest **24,632** (2 new: the launcher lists the
command; activating it opens the menu — via the new `launcher.entries`/
`launcher.activate` seams); `nix run .#test` ALL GREEN, every golden
byte-identical (the sink never engages outside the editor). A scripted
tape on `smoke --edit` proved the full lifecycle headless: launcher →
"options" → Enter opens the menu OVER the editor (shot: panel, sliders,
accessibility checkboxes, nav ring — rendered above the code windows);
Ctrl+Space while open does NOT open the launcher (yield); a click beneath
the menu moves no editor focus (yield); Esc closes via the menu grammar;
Ctrl+Space then opens the launcher again (resume); pad back opens / east
closes. The player-mode swarm menu re-shot pixel-matching D129's capture.

**Revisit triggers.** A second cm.ui overlay needing the sink (perf?
legacy scrub?) votes moving the bracket into a shared overlay helper; a
complaint about native-font metrics in the sunk menu votes a mono font or
measured layout; more launcher commands vote a real command category.

## D132 — the settings window; the vibration limit-cycle fix; the settings architecture (2026-07-19)

**Context.** Two human reports on D131's in-editor menu overlay — it
vibrated ~1px vertically and blocked all editor input — plus the
direction: "either make it a fully native editor window or find another
solution", and "we would want an editor window to set the game's
settings and defaults ... then the game itself decides what settings to
expose to the end user through its in-game menus."

**The vibration was a D128 class bug, not a D131 one.** `nav_item`'s
scroll-into-view demands the cursored widget sit 2px inside the band —
unsatisfiable for the FIRST row, which naturally sits at scroll 0 — so
it wrote a negative scroll and zeroed the velocity every frame, while
end_scroll's elastic spring pulled back: a permanent ~1px limit cycle
(probed: scroll oscillating −0.87..−1.89 forever). It affected the
PLAYER-mode menu too. Fix at the class level: the correction clamps to
the legal scroll range and writes nothing when the value cannot move —
an unchanged value never re-arms the spring. KAT'd (an edge-cursored
scroll rests at exactly 0 across idle frames).

**The overlay path is deleted; the settings window replaces it
(supersedes D131's render half).** The cm.ui drawlist sink and the
editor's wholesale interact yield are gone; the overlay menu now
force-closes under the editor shell (KAT'd) — it is the PLAYER surface
and only renders where it composites on top. In the editor:

1. **`cm.ed.win.settings`** — a native canvas window (the perf/console
   precedent: chrome window, no journal, close fearlessly): the
   project's `options.add` declarations (live values, kind-appropriate
   widgets), the volume knobs, stick deadzone/press-at, and the
   user-wide accessibility toggles. An ordinary window — nothing pauses,
   nothing blocks; occlusion/focus gate input like every other kind.
2. **Doors:** the launcher `cmd` entry ("settings / player options") and
   the pad back/select press in the editor both route to
   `ed.summon_settings()` — focus the existing window or spawn one
   (KAT'd: summon reuses, never twins). The spawn menu lists it too.
3. **`options.preview`/`preview_vol`** — the set doors minus the disk
   write, so a dragging slider applies live and persists once on
   release (the Esc menu's `_dirty` rule, exported).
4. Deliberately absent, named: rebinding (the capture grammar is
   player-facing — test in player mode) and window-size/fullscreen/
   ui-scale (they reshape the editor's own window).

**The architecture (the human's question, answered).** One settings
MODEL, many frontends. cm.options owns the model: declarations
(`options.add`), values + validation + `on_change`, and persistence
(video.dat per machine+project; accessibility user-wide in cm.view).
Frontends render it: the stock Esc menu (player mode — batteries
included, accessibility + rebinding guaranteed), the settings window
(editor), and THE GAME'S OWN MENUS — a game that hand-rolls its
settings screen calls `options.get/set/preview/...`, deciding itself
what to expose; persistence and on_change are identical by
construction. **cm.ui stays the in-game UI kit and raw imgui is NOT
exposed to games:** a game's entire visual output is its render target
— replays, exported clips, pixel goldens, thumbnails, and the editor's
game windows all capture the target — while imgui draws native-res
OUTSIDE it (and its C-side state neither records nor rewinds), so
game-side imgui would fork the visual record A7 is built on. The cost
("waste" of shipping imgui unused by games) buys the target contract;
the remedy for UI pain is growing cm.ui from demo votes (it already has
scroll regions, sliders, nav, styling via `ui.style`).

**Open questions, deliberately not decided here:** declaring option
DEFAULTS in `project.lua` data instead of `options.add` code (would let
the settings window edit defaults, not just values — a project-schema
change); whether a game may suppress/reskin the stock Esc menu without
losing the accessibility/rebind guarantees; an editor rebind surface if
player-mode testing proves too slow a loop.

**Proof.** Linux selftest **24,636** (+4: the limit-cycle rest, the
editor-shell force-close, summon focuses + reuses); `nix run .#test` ALL
GREEN, goldens byte-identical. Tape on smoke --edit: launcher summons
the focused settings window; the launcher still opens while it's up (not
modal); clicking both accessibility toggles flips cfg AND the user-wide
store; a master-volume drag lands 40% saving once on release; pad
back/select focuses the window. The scroll probe that reproduced the
vibration reads scroll=0 vel=0 flat after the fix. Captures on llm-feed.

**Revisit triggers.** The open questions above; a second chrome window
wanting shared kit widgets (settings hand-rolls slider/checkbox/cycle —
a third copy votes extracting them into cm.ed.kit); pad-driving editor
windows (the settings window is mouse-only today).

## D133 — F1 is the player menu key (Esc belongs to games); option defaults are project.lua data (2026-07-19)

**Context.** The human settled D132's open questions: option defaults move
into project.lua; the universal options menu stays UNSUPPRESSABLE and
UNSKINNABLE — the floor every player can count on (accessibility,
rebinding, volume, quit) — but most games are expected to roll their own
settings/pause screens, so the engine must not take over Esc.

**Decision, part 1 — the key.** The player menu moves from Esc to **F1**.
The grammar maps onto D128's pad grammar exactly: **F1 is the keyboard
twin of pad back/select** — opens the closed menu, walks the one-step-back
ladder, cancels an armed capture, reserved from binding; **Esc is the
keyboard twin of pad east** — never opens the menu, walks back only while
the menu is already open (input is captured then, so the game never hears
it), and while a capture is armed it BINDS as `key:41`, because Esc now
belongs to games: pause menus live there. Esc left the RESERVED set; F1
entered it. All player-facing text/docs renamed to "the player menu (F1)".

**Decision, part 2 — defaults as data.** project.lua gains an `options`
list — id/kind/label/default (+ min/max/step | choices), pure data, no
functions — validated by the schema (`project.options_error`, mirroring
options.add's rules exactly so a schema-valid list can never refuse at
boot; `on_change` in data refuses with a message pointing at the code
door). Boot declares each entry through options.add before load_video, so
stored player values land on live definitions in every session shape
(headless included — goldens read the declared defaults). Code attaches
behavior with the new **`options.on_change(id, fn)`**; `options.add`
stays the code-only door (redeclare replaces in place). The worked
example ships: openworld declares `retro_filter` in project.lua and gates
its x_grade/x_soft in draw — default on, so every golden stands
byte-identical while a player can turn the grade off.

**Policy, recorded.** The stock menu is the floor, not the ceiling: games
build their own screens on the same model (options.get/set/preview) and
decide what to expose; the F1 surface guarantees accessibility, rebind,
volume, and quit underneath, in every game, unchanged. Raw imgui stays
editor-only (D132's target-contract reasoning, confirmed by the human).

**Proof.** Linux selftest **24,649** (+13: the F1/Esc keyboard grammar —
F1 opens/walks/cancels, Esc never opens / closes while open / BINDS while
armed; options_error accept + refusal sweep naming entries; boot
validation covers the list; on_change attach + loud unknown). `nix run
.#test` ALL GREEN, every golden byte-identical (openworld's grade gate
defaults on). Tape on openworld headless: Esc opens nothing → F1 opens →
`retro_filter` declared from data, default true, toggled off live → Esc
closes the open menu; the closed frame renders ungraded; the menu capture
shows the game options row with the nav ring on it. Docs: scripting.md
(project shape + the data-first options section + menu key), editor.md,
getting-started.md, templates, demo headers all renamed.

**Deferred, named honestly.** The settings window editing DEFAULTS (write
the options list back into project.lua through the project window's
publish door) is the next slice of this line; a `controls`/pause hint for
players ("F1 = options") in the shipped player HUD is worth a look when
the fresh-user pass (A8) runs.

**Revisit triggers.** A game legitimately needing F1 votes a second
reserved-key review; a project wanting per-option menu ORDER or grouping
votes a layout field on the declaration.

## D134 — the editor keyboard window grammar: focus-cycle, close, resize (2026-07-19)

**Context.** The last named slice of ALPHA §A8's accessibility line
(deferred in D128, carried through D129–D133): the editor's core window
flows were mouse-only — no keyboard way to move focus between canvas
windows, close one, or resize one. The launcher already covers keyboard
spawn/open (Ctrl+Space), arrows already nudge the selection; the gaps
were cycle, close, resize.

**Decision — three keys, one tier each.**

1. **Ctrl+Tab / Ctrl+Shift+Tab cycle `doc.focus` in READING order** —
   y, then x, then id (pure `wm.cycle`; 0/stale seeds at the first or
   last). Reading order, not z order, because the cycle must be stable
   *while you cycle* and z stays explicit-only (§4 no-auto-raise: the
   cycled-to window is selected + focused, never raised). If the target
   is not fully on screen the camera eases to it — `ed.reveal_window`,
   the pan_to_window math behind a pure `cam.contains` gate, so cycling
   across visible windows never moves the camera.
2. **Ctrl+W closes the focused window** (with nothing focused, the
   selection), through the same `can_close` guard as A-rightclick
   (project export jobs still refuse) — fearless by the §6
   unsaved-persists construction; wm.close cleans sel/focus/drill refs.
3. **Alt+arrows resize the selection** (`wm.resize_sel`): the se corner
   walks by the arrows' own 1/10 step, origin anchored, through the
   identical min-clamp + kind-constraint door as a pointer drag — a game
   window keeps its aspect/FOV rules under keyboard resize. Rides the
   plain-key tier beside the move arrows (suspends while typing/playing).

Cycle and close ride the **pre-`ig.kb` ctrl-combo tier** (beside
Ctrl+S/F): leaving or closing the window you are typing in is precisely a
mid-typing move, and Ctrl combos stay the shell's while a game window is
playing (§12.3), so Ctrl+Tab is also the keyboard way OUT of play focus.

**PAL API v23 — `pal.x_ig_kb_release()`.** Cycling focus away from a
window whose ghost `x_ig_edit` is active had no deactivation path: only a
mouse click clears imgui's active id, so the old window's widget would
keep eating keystrokes. The door is `ClearActiveID()` (exactly what a
click on empty space does), guarded no-op headless/pre-init. The same
packet disables imgui's own Ctrl+Tab windowing gearbox at ig init
(`ConfigNavWindowingKeyNext/Prev = 0`) — it is live even without
NavEnableKeyboard (verified in the vendored 1.92.4 source) and would dim
the screen and focus ghost windows the moment two imgui windows exist.

**Determinism.** All chrome: doc.focus/sel and window rects are captured
editor state exactly as a click/drag writes them; no sim/recorded byte
moved; headless sessions never run the editor hotkey path. Goldens stood
byte-identical.

**Proof.** Linux selftest **24,665** / native Windows **24,667** on PAL
API 23 (+16: `wm.cycle` reading order incl. z-scramble immunity, both
wraps, both seeds, stale-id reseed, exact-position id tiebreak, empty,
single-window self-cycle; `wm.resize_sel` multi-select growth with
origins held, min clamp, constraint threading; `cam.contains`
inside/overhang/edge-exact). `nix run .#test` ALL GREEN, every golden
byte-identical; the Linux-recorded kitcheck trace verifies byte-exact on
native Windows. A drive tape on a fresh smoke copy (18-window committed
session) proved the wiring live, twice with byte-identical probes:
seed→tiebreak walk (11→14 while 11 was PLAYING — ctrl stays ours)→wrap→
shift-back; camera yanked to (5000,5000) and one Ctrl+Tab eased it back
to center the target; launcher→main.lua→click into the code text
(`kb=true`)→Ctrl+Tab moved focus AND released the keyboard (`kb=false` —
the v23 door); alt+right/alt+shift+down resized the focused sprite
window 460x380→461x390 with the origin held; Ctrl+W closed it and
cleaned refs. Focus-ring reveal + resize/hint-pill captures on llm-feed.
Docs: shipped editor.md "Keys that matter" + welcome note + hint pill;
EDITOR.md §5 the keyboard window grammar; ARCHITECTURE.md v23;
scripting.md compat version.

**Deferred, named honestly.** Key-repeat on held cycle/nudge/resize keys
(the D121 kit-wide `e.rep` decision, still open); a keyboard door for
z-order already exists (`[`/`]`); pad navigation of editor chrome stays
out of scope (the editor is the dev surface — pads navigate player-facing
chrome via D128). The A8 accessibility checkbox is now ticked: player
menu (D128–D133) + picker + launcher + this grammar cover the
keyboard-reachable core flows.

**Revisit triggers.** A user asking for MRU cycle order (the dear-imgui
model) votes a toggle; a second `x_ig_kb_release` consumer (a future
keyboard close of transient chrome?) votes promoting it into the kit.

## D135 — key repeat everywhere a key steps: the class rule (2026-07-19)

**Context.** The human voted D121's kit-wide deferral (carried through
D134): "I don't see any downside to having global key repeat — it's what
most users expect in the editor." The editor's key handling filtered
`e.rep` out wholesale at every gate, so nothing repeated: holding an
arrow nudged once, holding PgDn paged once, holding Ctrl+Tab cycled
once. imgui edit widgets and cm.ui's nav layer already repeated — the
gap was exactly the shell + windowkit tier.

**Decision — the class rule, not a blanket flip.** A key REPEATS while
held iff its action is a STEP; one-shots stay edge-triggered. Blanket
repeat has real downsides the rule names: a repeating Ctrl+W walks from
close-focused into the close-the-selection fallback (mass close from one
long press), a repeating save hammers the disk, a repeating Del eats
items, repeating toggles (launcher/rewind/selmode/console) oscillate.

- **Shell stepping keys now repeat:** Ctrl+Tab focus-cycle, Ctrl+Z/Y
  undo/redo walks, `[`/`]` z-order steps, nudge + Alt-resize arrows, the
  rewind tray's left/right frame scrub, the launcher's up/down list
  walk. **Shell one-shots stay edge:** Ctrl+S/F/W, Ctrl+Space, copy,
  grave, Alt+V, Esc, the shift+digit zoom fits, rewind's F4/Esc/space.
- **The kit hotkey table gains `rep = true`** (opt-in per entry, the
  same class rule; entries marked: reader pgup/pgdn, palette
  left/right, synth octave ,/.). A matched edge-only entry CONSUMES
  repeats without firing, so a held key a kind owns can never leak into
  the shell's plain-key tier mid-hold (the arrows would have moved the
  window under a kind's cursor otherwise).
- **The map window's own key loop** (wants_keys, outside the kit table)
  applies the rule locally: nudge arrows + brackets repeat; modes, del,
  clipboard, fits stay edge.

All chrome; recorded input never carries repeat-derived state (game
input reads downs/ups as before); no sim/doc byte moved.

**Proof.** Linux selftest **24,673** / native Windows **24,675** (+8:
the kit dispatcher contract in t_kit_rep — edge fires both entry
classes, repeat steps a rep entry, repeat of a plain entry consumed
un-fired, gated-off entries pass through, ups pass through; the
help-paging entries declare rep while the absolute jumps don't; the
D128-era "repeats never dispatch" KAT rewritten to pin the new
consume-without-fire contract). `nix run .#test` ALL GREEN, goldens
byte-identical. A drive tape with synthesized `rep = true` events on a
fresh smoke copy proved the wiring live: one held Ctrl+Tab (edge + 2
repeats) walked focus 3 steps; a held arrow moved the window +3 and a
held Alt+arrow resized +3; a held Ctrl+W with 3 press events closed
exactly ONE window; a held PgUp paged the reader exactly 3 × 0.9-band;
a held launcher Down walked sel 1→4.

**Deferred, named honestly.** OS-level repeat delay/rate is inherited
from SDL (no engine knob — none asked); the picker and player surfaces
already repeat through cm.ui and stay untouched.

**Revisit triggers.** A first report of an unwanted repeat names its key
and the fix is one `rep` flag or one edge gate — the rule localizes the
decision; a kind wanting gesture-state-dependent repeat (hold-to-paint?)
votes a richer kit contract.

## D136 — the settings window publishes option defaults into project.lua (2026-07-19)

**Context.** D133 made option defaults `project.lua` data and named the
next slice honestly: the settings window should be able to write the
options list back — a dev who tunes a knob live and likes the result
edits the file by hand today. The write must ride the project window's
established door (D071's shared `project.lua` text citizen), not a
second serializer.

**Decision.** The settings window's game-options section gains **"save
values as defaults"**: the current live values become the `default`
fields of `project.lua`'s `options` list, written through the SAME
shared working copy as a code window on the file — one journaled
undoable step, atomic save, the ordinary Ctrl+S retry contract on an
interrupted write, conflict-safe by construction with an open project
window or code window. A row whose value differs from its declared
default carries a trailing `*` (the D130 dirty grammar); the button is
inert while every value matches.

Three parts, each with one job:

1. **`cm.project.apply_option_defaults(meta, values)`** — pure merge:
   live values land on MATCHING `meta.options` entries (in list order,
   on a clone, every other key preserved), and the merged list
   re-validates through `options_error` against the FILE's shape — the
   declaration of record — so a live value that no longer fits a
   hand-edited range refuses loudly, naming the entry. Data-declared
   entries only: a live option absent from the list (declared in code
   via `options.add`) is skipped, because boot's code redeclare would
   shadow any data written for it — dead weight, honestly refused when
   NOTHING is data-declared and counted in the status line otherwise
   ("N code-declared kept in code").
2. **`cm.ed.win.settings.save_defaults(win, ed)`** — the door: parked
   guard, decode the LATEST working bytes (unsaved code-window edits
   are the working truth), merge, encode canonical, `textwin.replace`
   + `textwin.save`.
3. **`cm.options.rebase_defaults(values)`** — the live half after a
   successful publish: declarations adopt the new defaults and a stored
   custom value now EQUAL to its default leaves the store (one
   video.dat write). Without the prune, the dev's machine would shadow
   the very defaults it just published — a later hand edit of
   project.lua would silently not show up, the untouched-player rule
   inverted into a footgun.

**Proof.** Linux selftest **24,687** (+14: the pure merge — clone,
order, codec round trip, no-list / only-code-declared / out-of-shape
refusals naming the entry; rebase — declaration moves, equal store
prunes with inert foreign ids surviving the persist, off-shape values
ignored; the door — refusal without a data list, the parked wall, the
disk round trip preserving extension keys, the skipped count, the
atomic-failure retry keeping the complete merged bytes dirty).
`nix run .#test` ALL GREEN, goldens byte-identical (editor chrome +
per-project file writes only). Live tape proof + captures on llm-feed.

**Revisit triggers.** A second consumer of per-row default markers (the
player menu showing "modified" chips?) votes moving the diff read into
cm.options; a project wanting to publish a SUBSET of values votes
per-row publish affordances; the fresh-user pass (A8) judging the
button's discoverability.

## D137 — the 3D authoring suite: the editor unpark, three windows, three source formats (2026-07-19)

**Context.** The human unparked the 3D editor work COSMIC3D.md §12
explicitly parked ("terrain paint/bake, figure vertex-pushing, sheet
preview stay parked until the human unparks the editor"), with the
scope stated plainly: everything code/LLM-generated needs a human-facing
way to make and edit it — heightmap terrain + props as a 3D twin of the
2D map editor (any asset attaches; 2D assets default to billboards), a
3D character editor, and a mesh editor sufficient for the low-poly style
without recreating Blender. Hand editing is the primary path; procedural
generation stays an option. Exit: a human could recreate something like
the openworld/rovale demos by hand. Today NO 3D source format exists —
terrain, figures, and worlds are procedural Lua inside the demos; the
only committed 3D assets are baked outputs (`.spx` sheets, the atlas
`.png`).

**Decision.** The E-series program, designed in **docs/EDITOR3D.md**
(the MAPS.md of 3D — binding alongside this ADR):

1. **PAL API v24 — offscreen 3D views.** `pal.x_rt(w,h)` creates
   render-target textures; `pal.x_view3d` grows an optional target +
   clear; `scene3d_pass` opens one pass per run of same-target views,
   game-target path byte-identical by construction. This is the one new
   PAL mechanism; everything else rides existing doors (`x_ig_image`
   blits RTs; imgui renders after the scene passes).
2. **Three source formats, `cm.chunk` containers**: `.terr` (CTER,
   module `cm.terr3` — heightfield + material weight planes + painted
   shade + water level + derived-with-overrides walk grid + any-asset
   placements incl. billboard-defaulting 2D + markers with route
   polylines; runtime door `terr3.use` on the cm.map captured-buffer
   pattern; render through shared emitters so the editor viewport IS
   the game look), `.msh` (CMSH, module `cm.mesh` — verts + tri/quad
   faces, flat colors, optional per-face texture region, emit pre-lit +
   `x_figverts` blob parity), `.fig` (CFIG, codec in `cm.fig` — part
   tree with primitive AND `.msh` shapes, sparse-pose clips; the mascot
   ships as `engine/stock/fig/mascot.fig`, converter KAT-pinned to the
   code mascot).
3. **Three windows, full windowkit citizens** (roster, kit.asset
   journals, pathfield doors, viewlock, CTRL=snap, tape-proven):
   the **3d map window** (kind `terr`: orbit viewport, height sculpt
   with CTRL level-steps, material paint, shade paint, water drag, walk
   overrides, placements/markers/routes, atlas bake button), the
   **mesh window** (vertex push + face paint + extrude + mirror-x,
   picoCAD-class refusal set: no skinning/modifiers/subdiv/UV-unwrap,
   ever), the **figure window** (parts / pose-clip rail with
   dominant-axis drag rotation + 15° CTRL snap / bake tab writing
   `.spx`).
4. **Procedural is a door, not the path**: `terr3.encode/save` are
   public so generators write the same asset the editor edits; the
   pure-`hfn` streaming path (bigworld) stays code by design.

Deliberately absent, with triggers (EDITOR3D.md §8): per-corner cliff
heights, per-region water, point-light bake, face strips, paper-doll
layers, OBJ import, chunked/streaming `.terr` editing.

**Build order** (EDITOR3D.md §9): E0 viewport substrate → E1 `.terr`
format+runtime → E2 map window terrain half → E3 placements/markers →
E4 mesh → E5 figure → E6 the hand-authoring end-goal proof. One packet
per slice, each with KATs + a real-event tape + llm-feed captures;
ALPHA gates keep their own queue (3D remains outside the alpha promise).

**Revisit triggers.** A demo needing sheer GND-style cliffs votes the
per-corner format extension; a scene needing non-sun lights votes the
point-light bake; a character needing blink votes fig face strips; a
real project asking for CC0 pack import votes the OBJ→`.msh` converter.

## D138 — the native-test reports batch: picker click swallow, mesh selection layer + quad view, sprite brush stamps, side-by-side reader forks (2026-07-19)

**Context.** The human's first native session with the D137 editors
returned a bug report and a UX list: the picker's "+ New project"
dismissed instantly on click (Enter worked), the mesh window needed a
real selection model (universal click grammar, edge mode, box select
in every mode, edge loops, selection continuity across modes, a quad
view at a bigger default), the terrain editor had no custom brushes,
and ctrl+click doc links should fork the reader beside the current
window.

**Decisions.**

1. **A modal's opening frame swallows its own click** (the D127
   opening-Enter swallow, mouse edition). The picker modal shadows
   `i.clicked` for the frame it opens: the same click can never reach
   the modal's buttons or the click-outside dismiss. The class rule:
   any surface that OPENS under the cursor mid-frame must consume the
   opening press on every input channel, not just the keyboard.
2. **The mesh window's selection layer is pure cm.mesh topology**:
   `edges/pick_hits/vert_visible/edge_loop/sel_verts/convert_sel` (+
   `ekey/eunkey`) are KAT'd data functions; the window stays gesture
   plumbing. The universal `sel` mode is the DEFAULT: click = edge
   else front face; click-again drills exactly ONE level (vert / face
   under an edge / second ray face) and a third click cycles back;
   press-drag on the selection moves it; empty drag box-selects
   VISIBLE verts (occlusion-tested; vtx mode keeps the x-ray box).
   Occluded silhouette edges are unpickable — an edge candidate must
   beat the front ray hit (the far-corner-column steal the tape
   caught). CTRL+click an edge = its quad-walk edge loop in every
   mode. Mode switches re-express the selection via `convert_sel`
   (face -> corners -> boundary edges -> back), never drop it.
3. **The quad view is the mesh window's default**: orbit persp +
   top/front/side orthos (`m4.ortho`, GL clip like persp) sharing
   focus+zoom, each pane picking/marqueeing/dragging through its own
   projection; the orbit RT pool grew per-pane subkeys; default window
   880x720. A pane is a projection, not a mode — every editing gesture
   works in all four.
4. **Sprite brush stamps**: an image dropped on the 3d map window
   WHILE A BRUSH TOOL IS ACTIVE becomes that window's brush stamp —
   `terr3.stamp_mask` (alpha x luminance) + `terr3.stamp_at`
   (aspect-true fit into the 2r brush square) replace the radial
   falloff for every brush tool; the select tool keeps drop-to-place.
   The inspector's `stamp: name x` chip clears it. 2D art tools author
   3D ground detail — the material-tex precedent extended to brushes.
5. **Ctrl+click doc links fork the reader BESIDE the source window**
   (x+w+16, matched dimensions, focused, revealed by the D134 eased
   pan) — reading forks into side-by-side pairs instead of cascades.
6. **Drag-dial chips take stable ids** (found by the E5 tape): a
   gesture keyed by a label that carries the live value orphans itself
   after one step. Class rule for any value-labeled drag widget.

**Proofs.** Selftest 24,846 (+39 across the packets); `nix run .#test`
ALL GREEN after every packet, goldens byte-identical; tape proofs on
the real windows for every item (picker click both directions, the
9-check mesh tape, the stamp half-mask stroke, the reader fork, the
E5 figure tape, the explore3d walk/npc tape); captures on llm-feed.
Also this session under D137's program: E4.1 (the mesh selection
layer), E5 (the figure editor), and the 3D vale starter template +
getting-started-3d.md (EDITOR3D.md §9 as-built notes).

**Revisit triggers.** Mesh: n-gon-aware loop select or face-loop
(ctrl+alt) if quad strips prove insufficient; a real reorderable key
rail (drag) when clip counts grow; stamp rotation/spacing knobs when
stamps see real use; per-pane maximize in the quad view.

## D139 — material textures render live (save = bake); the brush well; sprite brush size/opacity + the stamp well (2026-07-19)

**Context.** The human's fifth native pass on the 3D suite: "the
material sampling doesn't feel like it's taking effect — the material
is tagged with the .spr but painting looks like the stock material."
Diagnosis: D138's §4.5 v1 only showed textures through the manual
**bake tex** chip (hidden on the sel/view info row), and any paint
stroke marked the bake stale — so the paint tool NEVER showed the
texture while you were using it. Working as implemented, failing as a
product. Plus three UX asks: dropping a sprite off-swatch should add a
material of it; the brush stamp wants a visible drop target instead of
the invisible any-brush-drop rule; and the sprite editor wants
brush size/opacity/shape, transparency fill, and its own stamp door.

**Decision.**

1. **Textures render LIVE; there is no user-facing bake state.**
   `terr3.bake_into` is the region bake (`bake_pixels` wraps it); the
   3d map window keeps a per-map CPU atlas: a budgeted rows-per-frame
   loop fills it (~6k texels/frame, `tex bake N%` in the strip — a
   48x48 map is ~0.4s of Lua, never one frame's worth), paint/shade
   strokes re-bake just the touched texel rect, and the finished
   buffer serves via tex_create/tex_update. Vertex mode draws only
   while the initial fill runs (or with no textured material).
   Invalidation is explicit: byte re-adopts (undo/redo/esc/reload),
   tex assign/clear/material-add, and cm.asset_epoch (a re-saved
   source image re-bakes; save adopts the new epoch instead of
   re-baking itself). The window frees its raw texture in
   drop_ephemeral (the sprite window's pattern).
2. **Save = bake.** The kind's encode refreshes `doc.stamp`
   (mat_hash with textured mats, else 0) on EVERY encode, and the
   write door publishes `<map>-atlas.png` (finishing the live fill
   synchronously if mid-flight) before after_save bumps the epoch. The
   game's freshness contract — HEAD stamp == mat_hash ⇒ draw the
   atlas — holds by construction after every save; the D138 "bake tex"
   / "x" chips are deleted. A fresh disk atlas seeds the live buffer
   on open, so reopening a saved map costs nothing.
3. **The drop grammar got visible targets.** pnt + viewport drop =
   ADD a material of the image (named from the file, swatch = the
   image's alpha-weighted average color, tex set, selected — one drag
   from "I drew a ground tile" to painting with it; a full mat list
   refuses with a log). Swatch drop = retexture that material
   (unchanged). The brush STAMP door moved to the inspector's
   **brush-shape well** — a square showing the live brush (radial dot
   or the stamp image) that every brush row leads with; dropping an
   image ON it sets the stamp, the `stamp: name x` chip resets. The
   old invisible rule (any image drop while a brush tool is active)
   is gone; non-pnt viewport drops place, as the sel tool always did.
4. **The sprite editor grew the same hands.** `cm.paint.brush` is the
   pure footprint plotter — size 1..32 (classic pixel discs: 3 = the
   plus, 4 = the 12px disc; square = the block), opacity applied ONCE
   per gesture through a per-stroke seen set (a slow drag cannot
   compound), rgba==0 erases (op<1 fades alpha, keeping color) — fed
   to M.line as a plot, clip-aware. The strip under the canvas dials
   size/opacity/shape for pen+eraser ([ ] steps size); the palette
   row leads with a TRANSPARENT swatch (pen erases, bucket =
   transparency fill). The rail's **stamp well** takes a dropped
   .spr (frame 1 composited) or .png: click the canvas to blit its
   opaque pixels (ghost preview, one click = one journal entry),
   `t`/well click re-arms, right-click or the strip chip clears.

**Proofs.** Linux selftest 24,878 (+13: brush footprints/opacity-once/
erase-fade KATs, bake_into row-band + sub-rect == bake_pixels). Two
shell-driven tapes on a fresh smoke copy: the terr tape (18 checks —
viewport drop added the checker material with the average color, the
budgeted bake completed and flipped the mesh to atlas mode, a stroke
patched the live atlas in place with no stale fallback, the well drop
set the stamp, Ctrl+S published the atlas png with a fresh stamp) and
the sprite tape (13 checks — ] steps size, the 12px disc, the opacity
dial to 50% painting alpha 128, the transparent swatch + bucket
clearing the disc, the well drop arming the stamp, the cross blit
respecting transparency, one ctrl+z undoing the whole stamp). The
terr capture shows the checker tiling the painted band live under the
brush falloff; both captures on llm-feed. `nix run .#test` ALL GREEN,
goldens byte-identical.

**Revisit triggers.** Caster shadows multiplied into the atlas (still
deferred from §4.5); stamp rotation/spacing (D138's trigger stands);
drag-to-stamp strokes if single clicks chafe; a shared brush model if
a third editor grows brushes.

**Addendum (same day) — the stale-seed regression.** The human's next
report: adding a custom material turned the textured grass solid green
(painting still worked; ctrl+z flashed texture briefly). Root cause:
lat_for's disk-atlas seed gated on `stamp == mat_hash(doc)` — under
D138 only the bake button wrote the stamp, so that meant "the png
matches this paint"; once D139's encode began refreshing the stamp on
EVERY commit the check became vacuously true, and any invalidation
(material add/assign, undo, esc-cancel) re-seeded the live atlas from
whatever stale png sat on disk (theirs: a D138-era flat-grass bake).
Fix: the seed additionally requires the working bytes to EQUAL the
saved file (`a.terr == p.disk`) — a dirty doc always re-bakes live.
And byte re-adopts now SOFT-refill (`lat_refill`: row=0, buffer and
served texture kept) instead of freeing, so undo/material edits show
the previous bake for the sub-second refill and swap atomically —
no vertex-mode flash. Proven by a tamper-marker tape (atlas painted
solid purple on disk): pre-fix the grass texel read the purple seed
after the add, post-fix it live-bakes the checker through add, undo,
and the republishing save; 7/7, and the D139 tapes + suite stay green.

**Addendum 2 (same day) — lighting moved into the atlas texels.** The
human's third report ("still doing the texture disappear thing", with
the fond-crow-mink project attached) reproduced on their real data as
a RENDERING truth, not a state bug: driving their journal through the
window on both platforms kept the atlas live through every transition,
but the atlas MODE visibly flattened the terrain. Root cause: atlas
verts carried `lit(WHITE) = amb + sun*d`, and a vertex color clamps at
1.0 while flat/sun-facing ground sits at ~1.12 — the entire sunlit
range collapsed to one tone, so turning textures on (exactly when a
material is added) read as "the grass loses its texture and goes solid
green". Fix: the bake multiplies albedo × painted shade × jitter × the
per-tile sun/ambient term, clamped only at the final byte
(terr3.bake_into's lof/jof), and atlas verts are PURE WHITE;
`mat_hash` now covers heights + sun/suncol/amb (they feed the bake, so
they feed the stamp — sculpting stales honestly), and every brush
stroke patches the live atlas (sculpt moves baked lighting). KATs:
the lit flat-texel expectation, a ridge's sun-facing tile baking
brighter than its away twin, sculpt-changes-the-stamp, pure-white
atlas verts (selftest 24,878 → 24,881). Old published atlases
self-orphan (stamp mismatch → vertex fallback until the next save
republishes) — the graceful migration the freshness contract was
built for. The A/B captures on the human's own map are on llm-feed.

**Addendum 3 (same day) — the native crash, billboard yaw, and prop
scaling.** Three more reports. (1) "Editing the brush sprite and
painting again crashes the engine": the Windows minidump (0xC0000005
inside SDL3, scene3d_pass on the stack) plus the crashed process log
(dies right after `saved + baked <sprite>.spr`, and only once an atlas
existed) pinned a CLASS bug spanning the PAL and one Lua holder. The
PAL's deferred texture free keeps a pend slot `used`, so queue-time
validation accepts its id right up to the present whose tex_reap
releases it — anyone drawing a freed id ONE frame late binds NULL into
SDL_GPU and dies. The holder: the explore3d template cached the atlas
TEXTURE ID in terrcache; a sprite save bumps the epoch, the assets
window's thumbnail re-asks cm.gfx.texture for `world-atlas.png`, the
memo frees the old id — and the game keeps drawing it every frame.
Fixed at both levels: the flush now binds WHITE, never NULL (both
segment bind sites in gfx.c — a stale-id draw is a one-frame white
flicker, never a crash; proven by a bench drawing a freed id 7 frames
on), and the template re-asks gfx.texture per frame (a table hit),
caching only the doc-keyed freshness gate. Class rule: raw texture ids
must not be cached across frames by consumers of epoch-refreshed
sources — hold the memo TABLE or re-ask. (2) Billboards in the vale
faced "the player, not the camera": emit_props expects the ORBIT yaw
convention (right = (-sin, cos) — the editor viewport's), the rig
measures yaw from +z toward the camera; the template passed the rig
yaw raw, leaving boards 90° off. It now converts (`-yaw - pi/2`);
game-shot proven full-face. (3) Prop/billboard scaling existed
(-/= on a selection) but was undiscoverable: ctrl+wheel now scales the
selection in sel mode (props: scale; markers: radius), the inspector
hint and win-terr.md name both. Existing template-instantiated
projects carry the old main.lua: the human's two projects were patched
in place on the stage (verbatim-block match, refused if hand-edited);
future scaffolds get the fixed template. Suite ALL GREEN, goldens
byte-identical (the NULL-bind path never fires in golden runs); all
tapes green.

**Addendum 4 (same day) — restages preserve user projects wholesale.**
Verifying addendum 3's restage exposed that tools/stage-windows.sh
preserved ONLY `.ed` state: every project the human created inside the
staged tree lost its payload files (world.terr, art, main.lua) on
every restage — my restage ate fond-crow-mink and deft-cobble-cider,
and four older native projects had already been hollowed silently.
All six were restored: fond-crow-mink from this session's full copy,
deft-cobble-cider + harbor-sparrow-tide + onyx-peach-ferret from
their `.ed` journals (the undo-forever design paying for real:
world.terr tips, sprite tips re-baked through sprite.save, figs,
atlases re-baked, scaffolding regenerated through cm.project.scaffold
with the fixed template), the two never-edited ones re-scaffolded;
every one boot-verified natively. The script now copies any
projects/<name> the fresh stage does not ship WHOLESALE (minus .ed,
which the editor-state pass still handles), verified by a real
restage round trip. Class rule: preservation lists must be
deny-listed (what is DERIVED and rebuildable), never allow-listed
(what someone remembered to keep).

**Addendum 5 (same day) — the published atlas follows its source
sprites; the staleness class gets a contract.** The human's report:
editing the very sprite a material paints with updates the 3d map
window but NOT the running game — the published `<map>-atlas.png` is
derived from the map AND its source images, while the stamp only
hashes the texture PATHS, so a re-saved sprite silently staled the
disk bake with no violation the game could detect. Fix: an
epoch-triggered live-atlas refill REPUBLISHES the png once it lands,
while the map is SAVED (unsaved paint never leaks into the game; a
dirty map publishes on its own Ctrl+S as always), then bumps the
epoch so the game's texture memo re-reads. The changed-bytes guard
makes the follow idempotent — two open maps sharing a sprite each
republish once and the bump ping-pong dies out. Tape: recolor the
ground sprite through sprite.save on a clean textured map → the disk
atlas rewrites once with the new texels, byte-stable for the next 60
frames, editor atlas live throughout. And per the human's ask
("this class keeps happening — find a better way"), the discipline is
now written down as PROCESS.md "Derived state must follow its
sources": name the inputs at the derivation site, epoch-key every
in-memory cache, published bakes follow or self-orphan visibly, raw
GPU ids never cross frames outside their owning cache, and every
derivation's proof tape EDITS A SOURCE and watches it follow.

## D140 — light the verts that are drawn: lathe point normals + terrain per-triangle light (2026-07-20)

The human's native report on stone-dusty-shrew: two terrain quads
"significantly more shaded, not consistent with nearby quads", and the
mascot's "very obvious circular seams" — with the direct ask: double
check we light each vert correctly and that the normals face the right
way. The audit found the normals correctly ORIENTED everywhere (signs
verified against the sun convention in both emitters) but two places
lighting a vert with a normal that does not belong to the surface
actually drawn at it:

- **`gb.lathe`/`bake_lathe` shaded per profile SEGMENT.** One
  perpendicular per profile span means every vert on a shared ring is
  emitted twice with two different normals — smooth AROUND the
  circumference, hard-stepped ALONG the profile: every latitude ring of
  every ball/lathe is a lighting seam (the mascot's bands). The
  comment claimed "smooth ring shading"; the meridional half never
  was. Now `lathe_ptnorms` computes per-profile-POINT normals (each
  point averages its two adjacent segment perpendiculars, endpoints
  keep their single segment) and both the immediate and baked paths
  share verts on the SAME point normal. The mascot/balls/tree-tops
  shade smoothly; silhouettes are untouched (geometry identical);
  prisms stay facet-flat by design. Both paths moved together, so the
  bake==immediate byte KATs and the mascot.fig equivalence KAT hold
  unchanged.
- **`terr3.emit_terrain`/`bake_into` lit per-quad plane fits.** One
  normal per tile from a 4-corner plane fit, while the drawn geometry
  is two triangles (the NW->SE split T.sample walks): on a NON-PLANAR
  quad — hand-sculpted maps are full of them; brush stamps make height
  noise — the tone matches NEITHER visible triangle, so plates pop
  that agree with nothing you can see. Now each triangle is lit by its
  own true (flat_y-softened) normal, in the vertex emitter and in the
  atlas bake (`lof` keys tile x tri; a texel picks its triangle by
  `fu >= fv`). Planar tiles produce bit-identical values to the old
  plane fit, so smooth terrain is visually unchanged; only sculpt
  noise resolves. The flat "painted era" per-face look is KEPT — this
  is not Gouraud smoothing.
- **cm.terr's `T.emit` deliberately unchanged**: its per-tile flattened
  normal is documented intent ("painted era look") and the procedural
  openworld/bigworld/rovale grounds are smooth enough that the
  non-planar mismatch class never bites. Revisit trigger: a hand-
  sculpted asset pipeline ever feeding cm.terr chunks.
- **Migration**: baked lighting lives in atlas TEXELS, so old published
  atlases carry the old per-quad tones with no data input changed.
  `mat_hash` gains an "L2" bake-math version salt: every pre-D140
  atlas self-orphans (stamp mismatch → vertex fallback, correctly lit)
  and one Ctrl+S on the map republishes — tape-proven on the human's
  own project copy (orphan probe, shell-driven Ctrl+S, new stamp +
  changed png bytes: 3/3 PASS). The editor's live atlas never shows
  the stale bake (a fresh fill refuses the seed by the same check).

On the human's actual two quads: the heightfield really dips/bumps
there (sculpt noise, likely stamp-brush residue) — the darkness is
correct shading of real geometry; per-triangle light makes the plates
match the drawn creases, and the smo tool is the cure for the noise
itself. Proof: Linux selftest 24,893 (+12: t_terr3_trilight — the
non-planar quad's shared vert lighting per triangle with exact tones,
planar quads bit-identical to the old plane fit, the bake's per-tri
texels exact; t_lathe_norms — one normal per shared ring, the exact
averaged right-angle point, endpoint perpendiculars, immediate ==
baked bytes; the pre-existing ridge/flat-texel bake KATs hold) / native Windows 24,895 on the refreshed stage; `nix run .#test`
ALL GREEN with all 20 traces byte-exact (sim untouched) and the 14
3D pixel goldens honestly re-cut on pinned lavapipe after A/B
inspection (figure/openworld/rovale/bounce/bigworld: seams gone,
terrain unchanged where planar; the 5 2D goldens byte-identical).

**Addendum (same day) — the human voted smooth: terr3 lighting is
per-vertex.** Follow-up question ("openworld has no visible quad
seams — what does it do different?") and the measured answer:
openworld shades with the same flat per-tile family; its procedural
fbm is simply smooth at tile scale (adjacent-tile light steps mean
~2/255 vs the sculpted vale's ~49/255 max on flat ground — editor
brushes put height energy at exactly the 1-tile wavelength where
per-face shading turns tiles into plates). A 3-way prototype on the
human's own map (flat per-tri / smooth per-vertex / unlit
hand-paint-only) went to llm-feed; the vote: smooth. Landed:
`emit_terrain` lights each VERTEX by its central-difference normal
(one color per shared vert — quad seams impossible by construction;
per-call vertex cache), the atlas bake bilerps the four corner vertex
light terms per texel, and the painted shade plane stays the artistic
hand-shading multiplier on top. The unlit look needs no code: set
`suncol` 0 / `amb` 1 in the map's light rig. The spill contract is
named at the emitter and KAT'd: a height edit at vertex v moves
normals at v±1, so the editor's stroke_patch/patch_mesh rects widened
one tile per side (re-baking [v-2..v+1] reproduces the full re-bake
byte-exactly). mat_hash salt L2→L3 (bake math changed): D140-era
atlases self-orphan, one Ctrl+S republishes — the heal tape re-ran
3/3 PASS on a fresh copy of the human's project, and the landed
editor shot is pixel-identical to the voted prototype panel.
cm.terr/openworld deliberately untouched (its per-tile look is
documented era intent on data that never shows the class). Proof:
Linux selftest 24,892 (the 8 per-tri KATs replaced by 7 smooth KATs:
exact vertex tones, cross-quad byte-identical shared verts, flat
ground unchanged, exact bilerped bake texels, the spill rect) /
native Windows 24,894; `nix run .#test` ALL GREEN with EVERY golden
byte-identical (no golden uses terr3) and all traces byte-exact.

## D141 — the sprite ed mixes: layer blend modes, procedural fills, the mix rail (2026-07-20)

The human's ask, verbatim intent: "layer opacity and a few basic
blending modes + a few procedural primitives to choose from in the
sprite editor... e.g. add a layer of noise and blend it to taste, with
a good roster of procedural primitives to produce various interesting
results like crystal/rock structures from noise". The audit found the
document model half-ready — per-layer opacity existed but had NO
editor control, and the non-destructive gradient-fill system (stops +
levels + ordered dither, D051/STUDIO §6) had no UI at all. Decision:
procedural primitives are NEW FILL TYPES — a procedural fill computes
its t from a deterministic value field instead of geometry and feeds
the SAME stops/levels/dither/ramp pipe, so every generated pixel is an
exact ramp band color (pixel-art quantized by construction, crystal /
rock ramps come free from the stops) and the .spr keeps it live,
reseedable, re-rampable forever until baked.

- **cm.paint value fields**: `phash`/`vnoise` (the terr.lua integer-
  hash family — pure IEEE arithmetic, platform-identical), fbm (oct
  octaves, lacunarity 2), and one 3x3 Worley walk serving three
  types. The roster: **noise** (one octave), **fbm** (clouds),
  **ridged** (creased octaves — strata/veins), **cells** (Worley F1 —
  organic cells), **shards** (F2−F1 — cracks/cobble), **facets**
  (nearest-point hash — flat tone per cell, the crystal read).
  `proc_t` maps px → field via `scale` (feature size, min 2) offset by
  p0; `grad_shade` routes `is_proc` types; phase still slides the ramp.
- **Blend modes**: layer.blend ∈ normal/mul/add/screen/overlay.
  `paint.blend_blit` is the per-pixel integer W3C model — the source
  color is backdrop-weighted (cs' = (1−da)·cs + da·B(cb,cs)) then
  src-over composites with the opacity-scaled source alpha, so a blend
  layer over transparent canvas PAINTS instead of blackening. Normal
  layers keep the C blit32 fast path byte-identically; composite_into
  and merge_down both honor the mode (a merged layer consumes its own).
- **Solid fills**: fill.solid renders the fill UNMASKED over the whole
  canvas (grad_fill's mask arg goes nil) — the "layer of noise" door;
  default stays the D051 semantic (recolor the layer's own alpha — draw
  a silhouette, let ridged shade it). stamp_fill/merge_down honor it.
- **Codec**: FILL chunk v2 appends seed/oct/solid/scale (v1 still
  decodes, procedural fields defaulted — KAT'd on hand-built v1
  bytes); type ids 5..10 append to the frozen 1..4. Blend rides a NEW
  `BLND` chunk (index + mode id, non-normal layers only, the FILL
  binding precedent) so a pre-D141 reader keeps every layer and just
  composites normal. set_size scales fill.scale with the doc.
- **The mix rail** (win/sprite.lua): the layers list gains right-click
  LOCK (red dot; paint already honored `locked` — the toggle was the
  missing half) and `^ v` reorder beside +/-; below it the selected
  layer's controls — **op** dial (5% steps), **mix** chip, **fill**
  chip (cycle fwd/back through none + 10 types), and per-fill dials
  **sd/px/oct/lv/di** + **solid** toggle + **cols** (re-ramp from the
  active secondary→primary) + **bake** (stamp_fill). Dial drags mutate
  the live doc and commit ONE journal entry on release; chips commit
  per click; everything composites live through comp_dirty.
- **Two class bugs found by the work**: (1) `solid and nil or cell` —
  the Lua and/or fall-through (the D128 class, AGAIN) silently kept
  the mask; spelled out with an explicit if at all three grad_fill
  call sites and the tape's flat-canvas probe now pins it. (2) the
  window's default secondary color was `0x000000ff` — DISPLAY-packed
  "opaque black" but the win.color fields are cm.paint-packed (R low
  byte), so the shipped default secondary was TRANSPARENT RED: rmb
  paint with the untouched default painted invisible red pixels, and
  the first fill ramp lerped through half-alpha pink. All seven
  fallbacks now 0xff000000 (paint-packed black). (3, small) journal
  re-adopts (undo/redo/save) rebuilt the decoded doc and snapped
  cur_layer/cur_frame back to 1 — decode_into now carries the cursors
  across, clamped.

Proof: Linux selftest **24,924** (+32: t_procfill — six-type
range/repeatability/reseed sweeps, p0 translation exactness, facets
flat-per-cell, band-exact shading, solid full-coverage; t_blend —
per-mode known answers incl. clamp, transparent-backdrop degrade,
transparent-src skip, opacity scaling, semi-alpha compositing;
t_sprite — mul composite known answer, BLND round-trip with implicit
normal, FILL v2 procedural round-trip + byte-identical decoded
composite, FILL v1 decode with defaults). A shell-driven tape on a
fresh smoke copy proved the REAL rail 12/12: kit fresh door → flood
coat → + adds layer 2 → fill chip cycled to fbm → solid on → mix mul
→ opacity dialed to exactly 75% → one ctrl+z undid the whole dial
gesture / ctrl+y returned it → ctrl+s → the DISK .spr round-trips
blend+fill and the baked .png published. The six-field montage +
procedural-meets-hand panels (masked ridged rock, drawn-gem facets)
and the tape's final frame are on llm-feed. `nix run .#test` ALL
GREEN, goldens byte-identical (the sprite compositor's normal path
is the untouched C blit; no shipped asset carries a blend/fill yet).

Deferred honestly: gradient p0/p1 handle dragging (gradients ship
with a vertical default axis; the dials cover procedural needs), a
per-stop ramp editor (cols re-grabs two stops), layer rename, the
mix rail clipping (not scrolling) past ~8 layers, blend modes in the
C blit path (Lua per-pixel is fine at sprite sizes), and dedicated
stock crystal/rock ramp presets (the palette window's ramp generator
already feeds swatches). Revisit triggers: a shipped demo authoring
big (>=256px) blended sprites; the human asking for gradient axis
control in the window.

**Addendum (same day) — the terrain noise brush (the gap audit's
hand-meets-procedural wall).** The audit's finding: cm.terr ships
value noise/fbm but the 3d map window exposed only hand tools — the
one place a hand-author most expects "generate, then sculpt" required
writing a generator script. Landed as the **nz** brush (`b`), a full
BRUSH_TOOLS citizen (radius/strength/stamp/atlas-patch/walk-stale all
generic): each vertex under the falloff moves by
`str x STEP_FRAC x f x terr3.noise_at(seed, wave, vx, vz)` — a pure,
KAT'd, POSITION-KEYED bipolar field (two octaves of cm.terr's
integer-hash value noise), so re-stroking an area carves toward ONE
coherent relief instead of accumulating a random walk, and the right
button subtracts the same field (tape-probed: ~1% residual, the
remainder being the ray hit shifting on the freshly raised ground —
the field itself is exact). The strip grows sd/wave step chips; the
seed multiplies by 131 into the field so each reroll is a fresh
lattice. win-terr.md documents the intended flow (block forms with nz,
hand-finish with hgt/smo, or roughen hand-built shapes at small wave)
— and writing it tripped the D127 balanced-span KAT once, which is the
guard working. Proof: selftest **24,931** (+3 noise_at KATs), a
shell tape 6/6 on a fresh smoke copy (kit fresh door, sign-exact
sculpt, the carve-out probe, the wave chip through a real click,
full-strength drags for the capture); shot on llm-feed.

## D142 — the release-candidate pass: gate reconcile, the freeze documents, the A7 triage closures (2026-07-20)

The overnight alpha-gating session's audit half, with the standing goal
"ready for alpha release after human signoff". Three moves:

- **The gates now tell the truth.** A5's five checkboxes had never been
  ticked although D090–D098 closed every slice (the transition slice's
  deliberate deferral included) and D098's consequences declared the
  gate done — each box now ticks WITH its evidence and the exit line
  lands, symmetric with A4/A6. The README's status paragraph named
  long-closed gates as open; it now says what actually remains
  (fresh-user pass + executed release checklist). VERSION 0.1-alpha is
  declared the intended frozen string.
- **The freeze documents exist** (A8's third box, now [~] pending only
  the human's tag): docs/CHANGELOG.md (the 0.1-alpha capability
  summary — the ADR log stays the detailed record),
  KNOWN-LIMITATIONS.md (every honest edge with its ADR pointer),
  ISSUE-TEMPLATE.md (replay-clip-first reporting), and
  RELEASE-CHECKLIST.md (the reproducible cut: suite → native →
  artifacts → clean-VM matrix → soak/recovery → tag; every step names
  its existing script). docs/README.md indexes all four as active.
- **A7 was triaged at code level and two smalls landed.** (1) The
  dismissal guard now covers a MOUNTED dropped-replay clip itself, not
  only its A/B loop — F4/the tray x refuse to eject even after Esc
  clears the loop (the guard keyed only on has_loop; a loop-less clip
  was silently ejectable), the Esc ladder stays the deliberate exit
  (it closes with force). KAT'd in the crash-tail sequence. (2) Asset
  IMPORTS mark the timeline: trace.note_import appends the new FIMP
  observer chunk (files activity + the new IMPORT event bit, excluded
  from replay bytes like FSAV/MARK, so exports stay byte-identical);
  the sound-import and instrument-preset doors emit it; the tray draws
  "asset import" at its own tick offset (position, not only color —
  D130). KAT'd through digest adoption. The three larges stay named
  with verdicts in the gate text: captured-audio embedding (no audio
  capture ring EXISTS — a PAL tap + segment store + clip chunk, post-
  alpha unless voted gating), the wall-clock export name (pal has no
  date door; one small binding when wanted), and native-crash
  next-launch synthesis (no signal handler in the PAL; a new C surface
  + boot reconciler).

Release-candidate validation recorded: `nix run .#test` ALL GREEN
(twice today), release-manifests staging PASS, long-session soaks —
400,000 headless swarm frames (~1.9 h of play) max RSS 262 MB clean
exit; 150,000 editor-shell frames (~42 min) max RSS 275 MB clean exit
(the pinned-history growth class stays a named limitation, D032).
Linux selftest **24,933** (+2: the clip-mount F4 guard, the adopted
import marker). What remains before "alpha" is exactly what only the
human can do: the fresh-user pass, the native signoff, and executing
the checklist.

## D143 — the palette generator rework: the working color, pickers, and the channel-rotated swatch bug (2026-07-20)

The human's editor-use report, verbatim asks: appending ramps back to
back was confusing (editing "the current color" after an append edited
the previous ramp's tail; add-then-edit-then-ramp duplicated the base),
HSV alone is hard to hit an imagined color with, the working color
should stay separate from saved colors (loading only on double-click /
enter), and a typed shade count past the slider span drew off the
scale.

**The working color model.** The mix is a per-window scratch
(win.wcol packed + the HSV scratch in kit.winui — HSV stays master
while mixing so grays keep their hue), deliberately not a live edit of
any saved swatch. Movement is always explicit: double-click a swatch
or press enter to ADOPT it into the mix (exact bytes, alpha included);
`+add` inserts the mix after the selection, `set` overwrites the
selection with it; the ramp generator reads the mix, so append/append
/append never disturbs saved colors and never needs the base added
first. Working-color edits touch no doc byte — journal entries exist
only for real palette mutations. The `a` hotkey now adds the working
color (was: white).

**Pickers.** Mode chips sv / hsv / rgb + the always-present hex field:
the 2D SV square (hue slider + drag surface — pick-by-eye; baked to a
96x64 texture only when the hue bucket moves, the sprite window's
tex_create/tex_update pipeline, freed in drop_ephemeral) joins the HSV
sliders and new RGB sliders. The hex field writes back on an
RGB-difference only — comparing full packed values re-stripped an
adopted swatch's alpha every frame (the tape caught it).

**The shades bound.** The typed count and the slider now share one
range (2–32) and the slider widget clamps its drawn fraction — the
class rule: a legal value past a slider's span must never render off
the scale.

**Two latent bugs the proof tape exposed, both the D141
display-packed class:** (1) cm.palette.fresh's starter ramp was
authored as 0xRRGGBBAA literals in cm.paint packing — every starter
color was near-transparent and channel-swapped; now built via
paint.pack and KAT-pinned opaque. (2) The window's disp() produced
ARGB for the ig boundary, which wants 0xRRGGBBAA (the sprite window's
disp comment says exactly this): every swatch had always rendered
channel-ROTATED — pure red drew invisible (alpha 0), pure blue drew
red. Pixel-probed empirically (an R/G/B/W palette screenshotted and
sampled: (30,27,46)=background, background, (255,0,0), white), then
fixed to the sprite window's conversion verbatim. Swatch grids now
auto-shrink tiles so a few 32-shade ramps stay fully visible.

win-palette.md is rewritten around the model, with the cohesive-
palette guide the human asked for: the N-shades-of-each-fundamental
recipe (fixed shade count, mid-tone bases, vibe flavoring via hue
shift + base tint), the shared-shadow and shared-accent glue tricks,
and the wide vs narrow (film / near-monochrome) inversion — one long
dominant ramp + short counter-ramps.

Proof: Linux selftest **24,936** (+3: fresh opaque + dark→light, the
32-shade ramp cap); a 20/20 shell tape on a fresh smoke copy (launcher
open, select-vs-adopt, sv pick with doc-untouched probe, +add/set,
532→32 clamp, 32-shade append, one ctrl+z per append, enter adopt, rgb
drag to exactly 255, ctrl+s disk round trip + clean dirty read), run
twice; the R/G/B/W pixel probe; `nix run .#test` ALL GREEN, goldens
byte-identical (editor chrome only). Captures on llm-feed. Deferred
honestly: alpha in the pickers (palette colors CAN carry alpha; the
mix edits opaque), a rampbuf snap-back on blur (a typed "5"+"32"
shows "532" while meaning 32), palette-window scroll past the
auto-shrink floor (~560 swatches on the default size).

## D144 — asset rename/move + the wrapped hint strip (2026-07-20)

Two editor-polish asks from the human's use notes. **(1) Rename.** The
assets window's `r` opens a rename bar prefilled with the full relative
path (editing the folder part MOVES the asset; a basename typed without
an extension keeps the old one). The contract: code refs by the old
name break by design — the engine's invalid-asset fallbacks are the
graceful floor — but everything the EDITOR holds follows: the file
(read → atomic write → remove, no new PAL surface), a .spr's baked
siblings (.png/.anim/.meta, the delete set), the unsaved working state
(ed.doc.assets key moves, so a dirty asset stays dirty with the same
bytes), the undo journal + its .good twin (undo-forever survives a
rename), and open windows (each kind's own rebind door).
cm.asset_epoch bumps so a live game's texture memo re-reads instead of
serving the old path stale. Collisions (disk OR working-state) refuse
with a visible error; esc cancels; the delete and rename bars share
the bottom strip and disarm each other. En route the tape caught a
real interaction bug: grid tiles under the armed bar stole the
field-focusing click and flipped the selection, which silently
disarmed the bar — clicks in the bar's strip now belong to the bar.
**(2) The hint strip wraps**: the focused window's keybind hints break
to a new line at the window's right edge (whole key+hint pairs) instead
of running past the width — the palette window's grown table was the
reporter. Proof: an 18/18 shell tape (spawn menu → assets window; a
launcher-bound sprite window rebound live across the rename; disk +
journal + working-state + selection probes; collision refusal; esc;
the narrow-palette wrap shot inspected + on llm-feed); selftest
24,936; `nix run .#test` ALL GREEN, goldens byte-identical.

## D145 — fresh projects open on their make-a-game walkthrough (2026-07-20)

The human's ask: instead of the "welcome to the editor shell" note,
open the doc reader on a walkthrough of MAKING A GAME appropriate to
the picked project preset — tutorial style like the tool walkthroughs,
not a feature reference. Landed as three pieces:

- **Three new tutorial pages** (auto-indexed by cm.docs.list, so the
  launcher/search find them): `make-platformer.md` (feel knobs → hero
  sprite + anim → the SOLIDS-to-.map upgrade with room.world:move →
  sfx/music → export), `make-topdown.md` (tiles → the room-becomes-
  data move: gems as markers, portals via map.extras → mood), and
  `make-arcade.md` (art pass → juice through the tween.flash /
  camera.offset accessibility doors → cm.save best score). The 3D
  starter maps to the existing getting-started-3d.md; blank and
  pre-D145 projects get getting-started.md. Every code claim was
  checked against scripting.md's actual API (the first draft invented
  a `snd.play` door and a pad rumble; both caught and corrected).
- **project.lua records its starter**: scaffold substitutes
  `template = "<key>"` (a new PROJECT_TMPL field; registry keys are
  grammar-safe literals). KAT'd per template in the boot-smoke loop.
- **fresh_doc(root) spawns game + reader** (the note is gone; the
  canvas keys live in the bottom hint pill and editor.md — the
  getting-started text that pointed at the note now points at the
  guides). The reader's `read_doc` gains a one-line fallback: a stock
  doc path that misses root-relative retries at the engine root (cwd),
  so an out-of-tree "open folder" project still RENDERS shipped pages
  (link resolution there remains the pre-existing depth-2 limitation,
  deliberately untouched).

Proof: scaffold→open probes for platformer (in-tree AND out-of-tree —
the fallback's live case) and topdown: wins = game+help, help.path =
the right guide, the rendered page inspected (shot on llm-feed);
selftest **24,947** (+11: the per-template `template` key, the docs
sweeps over the new pages); `nix run .#test` ALL GREEN. Deferred
honestly: the reader renders `*italic*` literally (pre-existing — the
new pages avoid single-asterisk emphasis; shipped tool docs still
carry some), out-of-tree stock-doc LINK resolution.

## D146 — the nightly CI cut + the public README hero pass (2026-07-20)

The human's ask: a CI nightly build with an auto release tag bump, and
a public-facing README with hero screenshots of bigworld, rovale, and
the 2D platformer.

- **`.github/workflows/nightly.yml`**: a scheduled (03:00 UTC) +
  manually-dispatchable job that skips when `main` hasn't moved since
  the last `nightly-*` tag, runs the FULL deterministic suite
  (`nix run .#test` — the same gate as local), builds both existing
  flake archive outputs (`cosmic-linux-release` / `cosmic-windows-
  release`, which already carry sibling .sha256s and pass
  release-integrity inside the build), tags `nightly-YYYYMMDD`
  (same-day rerun after a new commit bumps a `.N` suffix), and
  publishes a PRERELEASE with the archives. actionlint-clean.
  Deliberately not the alpha cut: RELEASE-CHECKLIST.md remains the
  human-executed path for versioned releases; nightlies are unsigned
  prerelease artifacts and say so.
- **README**: a hero block up top (rovale's lakeside mascots,
  bigworld's pine hills, the demo platformer — headless captures,
  committed under docs/media/), a plainer opening paragraph
  (deterministic / rewindable / authored-in-editor), and a "grab the
  nightly from Releases" line ahead of the build-from-source path.

Proof: actionlint clean; `tests/release-manifests.sh` PASS with the
new repo files; the three captures inspected. The workflow's first
real run is observable only on GitHub — verifying the initial nightly
(runner disk/time for the nix build, release permissions) is a
follow-up for the human or a future session with repo access.

## D147 — the FM-preset vibe expansion, stock demo songs, and the stock-assets window (2026-07-20)

The queued packet, the human's words: "make sure we have enough FM
presets to create the most common vibes + a few demo stock tracks to
smoke test that … probably also good to have a read only stock asset
window that you can copy assets from if desired (by copying them to
your project). opening a stock asset auto opens it with an auto
generated name unsaved."

- **24 new stock instruments** (engine/stock/ins, patch tables through
  cm.ins encode — the no-committed-generator convention holds; the
  generator lived in the session scratchpad): orchestral/classical
  fm-strings / fm-choir / fm-harp / fm-flute / fm-reed / fm-timpani /
  fm-orchhit / fm-harpsi / fm-musicbox; jazz-latin-funk fm-nylon /
  fm-upright / fm-vibes / fm-muted / fm-clav / fm-slap / fm-cowbell;
  electronic fm-sub / fm-reese / fm-ride / fm-shaker / fm-rim /
  fm-conga; ambient-spooky fm-drone / fm-glass. Calibrated against the
  shipped family (modulator levels 20–175, carriers 190–255); the
  audition renders show clean attack/sustain/decay classes and no
  clipping (worst peak 11.8k/32767). The synth preset rail outgrew a
  window height at 52 stock entries, so it **wheel-scrolls** (clamped,
  per-window winui scratch, a thin scroll cue; a wheel outside the
  rail still declines to canvas zoom — probe-proven both ways).
- **14 stock demo songs** (engine/stock/songs — a NEW stock family),
  one per queued vibe: desert-dunes, water-caverns, noble-court (a 3/4
  minuet), prelude-soft (the rolling-harp opening), battle-charge,
  boss-gate, dnb-rush, breaks-alley, bossa-breeze, bossa-fiesta,
  funk-strut, noir-sleuth (swing), horror-hollow, ambient-drift.
  Hand-composed beat-time tables through cm.song encode. **Track ins
  refs are engine-cwd-relative** ("engine/stock/ins/x.ins") — the sim
  sequencer's read_ins, the music window's preview resolver, and a
  packaged game (engine/stock ships) all open them from any project
  with zero copying; pulling the song INTO a project rewrites nothing
  (the refs still resolve), and per-track drops copy in as before.
  Full-loop sim renders: every instrument resolves, no clipping
  (worst 28.5k transient), mixes eyeballed by RMS envelope.
- **The stock-assets window** (cm.ed.win.stock, on the roster after
  assets): a read-only grid over the five stock families (ins / songs
  / art / fig / pal) — family chips, fuzzy filter, previews (sprite
  textures; palette swatch strips through the D143-safe disp
  conversion), grid order = family roster order (the fuzzy sort
  tie-breaks by list index, not path). Three doors, no write surface
  into stock by construction (no delete/rename/save):
  **double-click = open an unsaved copy** — the stock bytes seed the
  working state at a fresh auto name (stem-2/-3 on collision with disk
  OR unsaved states) and the right window opens DIRTY; ctrl+S keeps
  it, closing without saving leaves the project untouched. **c/enter =
  copy into the project** (family dest dirs ins/ sound/ art/ pal/,
  assets-browser flash, the A7 FIMP import mark). **press-drag**
  carries the engine-relative path on the shell's g.adrag — music
  tracks / sprite wells copy in through their existing drop doors.
- **kit.asset grows `A.seed(ed, path, bytes)`** — the generic
  open-a-copy half: pre-seed a not-yet-existing project path as
  unsaved working state; declines existing files or working states
  (seeding never clobbers); the seed bytes journal as the undo floor
  through the existing open_asset flow. synth / music / sprite /
  palette / figure export it as `kind.seed`; a kind without the door
  falls back to a real copy in stock.open_copy.

Proof: selftest **25,017** (+70: t_stock_ins decode/canonical/audible
sweep over all 52 with the 24 pinned by name; t_stock_songs
decode/canonical/flatten/ins-resolution/audible over all 14 pinned;
t_stock_window list/prune/dest/unique/copy/seed-contract/parked-wall);
`nix run .#test` ALL GREEN, goldens byte-identical; the synth-rail
tape (scroll probe exact at 6 notches, off-rail wheel zooms) and the
stock-window tape (6/6: select, c-copy lands bytes, double-click opens
ins/fm-bell.ins dirty with no disk write, songs chip) both on fresh
smoke copies; captures on llm-feed. **The audio taste check NEEDS the
human**: the presets and all 14 songs want a native listen (synth
window preset rail + stock window double-click into the music window,
space to play). Deferred honestly: preset-rail keyboard walk, a song
"play" door directly in the stock grid (today: open the copy, space in
the music window), stock-window arrow-key selection, PCM goldens
pinning the new presets bit-exact once the human approves them.

### D147 addendum — the polish round (2026-07-20, same day)

The human's notes after browsing (pre-listen): six items, all landed.

- **The multi-window preview divergence** ("two copies of breaks-alley
  open played differently — restart fixed it", deft-cobble-cider) is a
  CLASS bug: `kit.snd_alloc` round-robins the editor bank's 64 patch
  slots and never frees, so enough audio windows in one session WRAP
  the counter and two live holders share a slot — the later upload
  silently replaces the earlier window's patch; a restart empties the
  bank and hides it. Fix: **`kit.snd_claim(ed, slot, tag)`** stamps
  slot ownership on ed.g; the synth audition (every bound frame) and
  the music preview_slots (every start/blip) check the stamp and
  re-send their patch on a lost claim — an upload is cheap, so
  stealing resolves on the victim's next play instead of persisting
  to restart. KAT'd (t_snd_claim, 5) + tape-probed (a stolen slot
  re-claims on the next audition frame). Named edge: two windows
  BOTH mid-preview on collided slots fight until one restarts its
  preview — acceptable; simultaneous previews are already a mess.
- **The rail marks the last-loaded preset** (win.lastpre — captured,
  survives restarts): filled pill + accent label. Tape-proven.
- **The bossa rework.** Studied the human's reference ("How to make
  the silliest bossa nova song", eBm1JEj8wpo) — transcript via yt-dlp
  (yutu's caption download is owner-only; timedtext/innertube are
  POT-walled now) + FL piano-roll frame reads at 360p (the only
  stream YouTube serves this session). What the frames show: FIVE-
  voice close-position ninth chords (intervals 3-4-3-4 from the root
  = m9) with ONE voice dropping a semitone (m7→6: the im9→im6/9
  vamp), anticipated comping, key B♭ ("back to F" bass), rim + paired
  kicks ("two, two again") + manually-placed quiet rides, a cute
  2-octave lead, deliberately robotic ("sounds like Undertale").
  Both songs rebuilt on that recipe: **bossa-breeze** = B♭maj9 / Gm9 /
  Cm9 / F9 two bars each, soft keys on the dotted-quarter anticipation
  chain, surdo upright, xylophone lead; **bossa-fiesta** = one-bar
  changes + a G9 (V/ii) sparkle, busier comping with a bar-crossing
  anticipation, flute lead + xylophone octave echoes, conga/shaker/
  ride on top. **fm-xylo** is the new preset (3x quint partial over
  the fundamental, 10x strike click, fast wooden decay).
- **noir-sleuth's melody** rewritten in crime-jazz language (Mancini/
  Peter Gunn traits: chromatic creeps, the ♭5, strolling motifs with
  silence, shouting brass): F–F#–G–G#–A and B♭–B–C–C#–D half-step
  climbs on swung 8ths, a D–C–B♭ / A–A♭–G chromatic descent answer,
  the resolve falling through F# to a hanging D; the muted trumpet
  stabs land a half-step off in the melody's rests. The rhythm
  section is untouched (human-approved as-is).
- **fm-flute / fm-harpsi realistic passes** ("too electronic"): the
  flute drops the chippy tri carrier for a gently detuned sine pair +
  soft octave + constant low breath noise (fixed 6.2 kHz, sustain 13);
  the harpsi drops raw saw carriers + the c14 tine for the classic
  decaying-FM-index pluck (c3 modulator, index 175 falling to 22) +
  a 4' octave rank, fb 2 for quill edge at the attack only.
  noble-court and bossa-fiesta inherit through their ins refs.

Proof: selftest **25,023** (+6: t_snd_claim ×5, the fm-xylo pin);
`nix run .#test` ALL GREEN, goldens byte-identical; full-loop renders
clean (fiesta trimmed from a 32.4k peak to 28.3k); the rail-mark tape
2/2 with the highlight shot on llm-feed. The native listen remains
the verdict on all of it.

### D147 addendum 2 — the second polish round (2026-07-20, same day)

Six more notes from the human's listen; the headline is a REAL bug.

- **"The long chords stop after ~1 bar" (dunes)** was the music
  preview's voice allocation, not the composition and not the kernel
  (a 6-second held-note probe cleared the envelope first — fm-organ
  sustains dead flat). The preview picked voices with a blind
  round-robin (`8 + pvoice % 24`) and `x_snd_ed_on` with an explicit
  index OVERWRITES that voice — so ~24 note events (about one bar of
  busy percussion) after a pad started, its voices were stomped
  mid-note. The SIM path never had the bug (the kernel allocator
  prefers free voices and steals oldest only when full), which is why
  exported games sounded right while the editor lied. Fix:
  **`music.preview_voice(pheld, blips, pvoice)`** — pure, KAT'd —
  skips voices still held or ringing a blip, wraps, and steals in
  order only when all 24 are genuinely occupied. Named edge, accepted:
  the synth window's per-window 4-voice audition blocks can still
  collide across MANY windows (kit.snd_alloc's vbase also wraps);
  audition notes are short blips, revisit if reported.
- **fm-kick had no punch** ("all bass, even at max volume — part of
  why the bossa rhythm disappears"): it was a static half-rate sine.
  Punch is the pitch drop: the body now falls 20 semitones over 60 ms
  from the played note (the gb-noise-kick door, left un-fixed so the
  note tunes it) + a 3.8 kHz beater snap. Both bossas also push
  kick/rim gains up now that the ride no longer masks them.
- **fm-ride was harsh/electronic** ("overpowers everything, only good
  for harsh electronic styles"): noise2's short-mode LFSR is metallic
  by construction — swapped for plain white noise, high-passed at 150,
  level down (105 vs 150, gain 92 vs 118), gentler stick ping.
- **bossa-fiesta's "odd chord overlaps"**: the and-of-4 comping hit
  played the CURRENT bar's chord while the next bar restated its own
  downbeat — two chords ringing across the barline. The hit now plays
  the NEXT chord and replaces its downbeat (true bossa anticipation;
  the loop seam anticipates bar 1's chord).
- **breaks-alley "a good beat with 2 random chords"**: grew a real
  progression riding the 2-bar bass cells (Gm7 / E♭maj7 / Gm7 / F13
  rootless) and a G-minor-pentatonic lead hook (fm-lead, modest gain).
- **noir-sleuth's melody, rewrite two** ("doesn't sound coherent or in
  key — just rewrite"): the chromatic-creep draft ignored the walking
  bass's implied changes. Now chord-anchored D-minor phrases following
  the walk (Dm | descent | B♭7 | A7 | Dm | gm | ii–V | A7→Dm), one
  swung pickup per phrase, exactly one chromatic descent (C–B–B♭–A)
  resolving INTO a chord tone; the muted trumpet reduced to four
  sparse chord-tone answers.
- **fm-reed** attack eased to ~35 ms + lp 210, dunes lead velocities
  104→90 (the "softer with a soft attack" ask).

Proof: selftest **25,028** (+5 t_preview_voice); `nix run .#test` ALL
GREEN, goldens byte-identical; all 14 loops re-rendered clean (peaks
≤ 28.6k). Still awaiting the human's ears for the final call.

## D148 — rendered tutorial images + complete starter/tool walkthrough coverage (2026-07-20)

The alpha docs now SHOW the tools they teach, and the tutorial promise is a
tested inventory rather than an impression.

- The help reader supports strict standalone Markdown image blocks,
  `![alt](local-path)`. Images resolve relative to the current document (with
  the historical project-root spelling retained), load through `cm.gfx`, keep
  their aspect, stay intrinsic at 1x until the text band caps them, scale with
  canvas/Aa, cull with the retained layout, and become `[image: alt]` in
  copy-page text. Missing media renders an honest labelled well. Inline images
  and HTTP fetches remain deliberately unsupported: shipped help must work
  offline and a block is the readable unit in a narrow canvas window.
- The retained layout's derivation key now names every input that can change an
  image: Markdown bytes, document path + editor root, width/font/zoom, and
  `cm.asset_epoch`. A saved replacement therefore reflows dimensions instead
  of leaving a stale texture/layout.
- Implementing the external-project path exposed a real D145 latent bug:
  Lua patterns cannot repeat a capture, so `gsub("^(%.%./)+", "")` matched
  nothing. An explicit leading-`../` loop now backs `read_doc`, anchor lookup,
  media resolution, and cross-doc navigation. The proof capture opens the
  stock top-down guide from `/tmp/.../project`, not a conveniently nested
  repository project.
- Six truthful, cropped PNGs ship under `engine/stock/docs/media` (386–642 px
  wide, 20–142 KiB): a running top-down starter beside its guide, procedural
  sprite fills, a real seven-track bossa arrangement, palette ramps, the stock
  song grid, and the 3D terrain editor. No generated/mock UI and no full-screen
  1280/1400 px payloads.
- Every picker starter is covered: blank gains its one-file
  `init/step/draw` walkthrough; platformer/top-down/arcade/3D retain focused
  tutorials and now end in explicit full-reference handoffs. Every focused
  authoring guide (14: project/assets/stock, 2D/3D art+maps, sound/synth/music,
  palette) has a `Walkthrough:` exercising its power move and a full-reference
  link. The smaller shared-help tools (game/code/image/console/perf/note/
  settings/help) are taught together as a debugging desk in `editor.md`.
- Selftest pins the five-template mapping, all 14 authoring guides, the utility
  roster, reference handoffs, image parsing/aspect/path fallback, six distinct
  decodable media files with nonempty alt text, and the 700x550 maximum.

Proof: Linux selftest **25,085** (+57 over D147 addendum 2); Markdown link
audit **106 targets / 0 issues**; release-manifests PASS; the external-root
reader capture inspected and posted to llm-feed; `nix run .#test` **ALL GREEN**
with every trace and pixel golden byte-identical. One harness catch paid for
itself: the first clean Nix run correctly omitted the untracked PNGs and failed
the new media contract; staging the coherent unit made the clean-source run
pass, demonstrating the test is checking shipped input rather than the loose
worktree.

## D149 — useful track faders + final stock-audio mix pass (2026-07-20)

The last audio taste notes exposed one general control-law defect and three
source-level mix problems. They land together because the preset, track fader,
editor preview, and runtime sequencer form one audible contract.

- Track gain no longer uses a plain `preset * track / 128` multiply. That law
  made loud presets saturate before the slider ended and prevented quiet
  presets from ever reaching 255. `cm.snd.track_gain` is now the single
  preview/runtime door and piecewise-interpolates **0 → preset → 255**:
  track 0 is exact silence, 128 exactly preserves the authored preset, and 255
  reaches full encoded gain. Below-unity stock mix values keep the historical
  math byte-for-byte; only two shipped tracks sit above 128, and an inventory
  audit finds their baked gain moves by at most one encoded step. An
  exhaustive 256×256 KAT pins range and monotonicity with the three anchors.
- `fm-epiano` keeps its tine identity but gains an LP 218 ceiling, 8–10 ms
  operator attacks, and a quieter high-ratio strike. `fm-nylon` keeps the
  pluck with 5–8 ms attacks instead of a zero-time digital edge. Both bossa
  songs inherit those source changes without arrangement duplication.
- `fm-kick` retains the tuned -20-semitone sub drop, but now adds a short
  swept 120 Hz knock and a stronger 3.2 kHz beater. In the exact
  bossa-breeze kick stem its peak rises **4,071 → 5,904** samples
  (**+3.23 dB**) and RMS rises 796 → 977, while the complete mix still peaks
  at only -2.14 dBFS. The request's rhythm is therefore materially more
  present at ordinary volume without spending the song's headroom.
- `noir-sleuth` is a whole new 108 BPM seven-piece arrangement, not a third
  melody patch over the rejected backing. Its crime-jazz grammar is structural:
  swung ride skip-beats, cross-stick 2/4, feathered kick, a walking D-minor
  bass through Dm(maj9), Gm9, A7b9, Bb7#11, and iiø–V, sparse rootless
  vibraphone comping, a reed minor-blues/b5 title hook, one altered-dominant
  chromatic fall, and muted-horn call/response in the deliberate gaps. Source
  pins retain the ensemble and per-lane note vocabulary.

Proof: selftest **25,094** (+9 over D148); all 14 stock songs rendered for a
complete loop through the real sim sequencer/kernel with **zero clipped
samples** (peaks -8.00 to -0.62 dBFS; bossa-breeze -2.14, bossa-fiesta -2.77,
noir -7.35); stock instruments/songs remain canonical and audible;
release-manifests PASS; `nix run .#test` **ALL GREEN** with every committed
trace and pixel golden byte-identical. The refreshed Windows stage passes the
native selftest at **25,096** (Linux +2 platform checks) and the 830-frame
`smoke_kitcheck` trace byte-exact. The final musical verdict remains the
explicit human native listen.

## D150 — window teardown owns previews; asset scroll belongs to each tab (2026-07-20)

Two human reports exposed the same lifecycle class: persistent state retained
an offset/voice after the UI owner that made it meaningful had changed or
vanished.

- Every shell dismissal now routes through one `ed.close_window` door. It
  resolves the existing optional `kind.can_close` guard, then invokes a new
  optional `kind.on_close(win, ed)` teardown while the window still exists,
  then delegates structural removal to pure `wm.close`. A-rightclick and
  Ctrl+W share the door; `wm.update` accepts it as one callback instead of
  knowing kind policy. A refused guard never tears down.
- Music uses `on_close` to release every editor-bank voice in both its held
  sequencer table and short audition-blip table, deduplicated over the fixed
  8..31 range, before clearing playback ownership. Previously the closed
  window stopped calling `preview_step`, so horror-hollow's opening drone had
  no remaining code path to send note-off. Empty blip tables now nil
  themselves instead of requesting redraw forever.
- Project and stock asset browsers keep the active tab offset in the legacy
  `win.sy` field and inactive offsets in captured `win.sy_tabs`, all in the
  shared winview world-unit convention. On every draw, the current filtered
  item count, column count, tile size, and viewport derive the actual maximum;
  `winview.clamp_scroll` snaps into it before choosing the first row. Thus a
  newly selected short/empty tab starts visibly at its content, returning to a
  long tab restores its place, and filter/tile/window changes cannot strand the
  viewport below the final row. Old sessions remain valid because their live
  `sy` is saved into the side table only on the first switch.

Proof: Linux selftest **25,104** (+10: shell guard/hook ordering, exact music
voice release/state clear, per-tab restore, zoom-correct live clamp including
empty content). A real 1280x800 headless stock-window capture injected
`sy=10000` on the 14-song tab and visibly snapped to its two real rows; the
capture was inspected and posted to llm-feed. Full deterministic/native proof
is recorded in STATUS with the session handoff.

## D151 — track pan is an authored, audible mix control (2026-07-20)

The `.song` format and both sequencers already carried per-track pan, but the
music window exposed only gain. A capability that can only be reached by
rewriting binary asset bytes is not an editor capability, so the selected
track's rail now opens a two-row **mix** panel:

- volume keeps its 0..255 useful-fader law; pan adds a matching drag slider
  and numeric field over **-64 left .. 0 center .. +64 right**. The center is
  visibly marked and a ±2 drag band snaps exactly to zero. Each drag is one
  journal entry; typed submits are one entry; a playing preview re-bakes the
  track patch live.
- `cm.snd.track_pan` is the single composition door for the instrument's
  authored pan plus the song-track offset, clamped to the encoded stereo
  range. Editor-bank preview and recorded/rewindable sim playback both use it.
- All 14 stock vibe songs and both platformer-demo songs received a deliberate
  stereo pass. Kick, sub, bass, and other foundations stay centered; hats,
  rides, hand percussion, pads, harmony, and answering voices spread in
  complementary positions. The stock-song inventory now pins that every mix
  contains both left and right placements within range.

Proof: Linux selftest **25,106** (+2: the shared pan-composition door and the
stock stereo inventory); a real UI tape dragged overworld's selected track
from -16 to +32 through the new control and observed one dirty working song;
the 1280x800 capture was inspected and posted to llm-feed. Every stock/demo
song rendered for a complete loop through the real sim sequencer: **zero
clipped samples**, maximum channel peak 30,586, and channel RMS imbalance at
or below 1.50 dB. The 2,068-frame demo camera-tour trace was honestly recut
after the song-state change: its decoded and raw `FRAM` input records are
byte-identical to the prior trace, and the replacement verifies end to end.
That recut also fixed the generic driver to pump a newly attached virtual pad
before staging a non-neutral first record. The human's speakers remain the
final taste check.

## D152 — nightlies move; candidates do not, and both cuts are recoverable (2026-07-20)

The first public automation should not turn a network interruption into either
a false-green release or a tag that has to be edited by hand. The two release
classes therefore share the same tested build spine but keep intentionally
different identities:

- `nightly` is the one moving prerelease. Its workflow runs at 03:17 UTC (and
  manually), skips only when the existing release targets the same commit
  **and** carries all four expected archive/checksum assets, and resumes an
  incomplete same-commit cut. It verifies the complete deterministic suite,
  builds both release derivations, checks both sibling hashes, creates an
  annotated moving tag, and replaces the release assets idempotently.
- A candidate is an immutable annotated `v<VERSION>-rc.N` tag. Pushing that
  shape starts `release-candidate.yml`, which rejects any mismatch with the
  checked-out `VERSION`, runs the same suite/build/hash spine, and creates or
  repairs the matching GitHub **prerelease** without moving the tag. Its notes
  repeat the experimental-alpha/no-stability contract.
- `tools/tag-release-candidate.sh [--push] [REF]` is the single easy local
  door. It requires a clean tree, derives the next positive candidate number,
  and, before a push, refuses a ref that is not already contained by
  `origin/main`. Normal use is therefore `tools/tag-release-candidate.sh
  --push` after the main push; the tag push itself triggers the build.
- Third-party actions are pinned to current full commit SHAs, workflow tokens
  are narrowed to `contents: write`, jobs have timeouts, build outputs remain
  inspectable as Actions artifacts, and a failed checksum can never reach a
  release upload.

The public README is the matching product surface, not a milestone ledger: its
first screen states batteries-included + deterministic + rewindable + hot
reload + infinite canvas, immediately warns that nothing is stable until the
project is past alpha, and shows a 2x2 of the actual rovale, bigworld,
openworld, and platformer demos plus authoring-tool captures. Although the
engine began in 2D, the README treats 2D, N64-era 3D, and RO-style 2.5D as the
first-class paths they now are; rovale and bigworld lead because they are the
most developed showcases today.

Proof before the first remote cut: `actionlint`, `shellcheck`, and `bash -n`
pass; every pinned action commit resolves; `nix run .#test` is **ALL GREEN**
(Linux selftest **25,106**, all traces and pixels); the fresh Windows stage
passes native selftest **25,108** and the 830-frame cross-platform trace; both
release derivations build and their sibling SHA-256 files verify.

The first hosted rehearsals then exposed a runner-specific constraint rather
than a game mismatch: every Ubuntu job passed selftest and every trace, but
lavapipe intermittently exited 139 during different long 3D
pixel tours. Every capture that completed matched its golden byte-for-byte,
and the failure set changed by run. A one-worker Mesa experiment was exact
locally but made the hosted envelope worse (`rc.3` took longer and lost all
four heavy tours), so it was removed rather than laundering a failed theory
into permanent CI. Both workflows explicitly pin Ubuntu 24.04 and share one
non-cancelling concurrency group. The common golden runner now gives only a
SIGSEGV capture process up to three fresh attempts; Lua/product errors and all
other exits remain immediate failures, and a completed attempt still has to
byte-match the pinned golden. The unchanged full-render suite is ALL GREEN
locally with every capture succeeding on its first attempt.

## D153 — headless presentation bounds its offscreen GPU queue (2026-07-20)

The hosted rehearsals made the failure shape decisive. `rc.4` gave each
SIGSEGV capture three fresh processes: the 1,920-frame bounce tour and
1,740-frame starfield exhausted all three, with individual attempts stretching
from roughly two to four minutes. In the same job every shorter capture and
the 1,290-frame openworld and 620-frame rovale tours completed and matched
their committed PNGs byte-for-byte. Retries did not repair the class, and no
completed render ever produced a pixel mismatch.

The missing invariant was at the headless presentation boundary. A live
swapchain naturally limits frames in flight through acquire/present, while the
offscreen path submitted command buffers as quickly as the simulation and Lua
draw could produce them. On a slow software Vulkan host, render work could
therefore accumulate without a bound. `pal_gfx_present` now submits headless
frames with an SDL GPU fence and waits for completion before beginning the
next tick. Windowed presentation keeps its asynchronous swapchain path.

This is deliberately a runtime lifetime fix, not a CI exception: the workflow
still runs the complete release suite, the retry guard remains narrow, and no
trace or pixel golden changed. Linux `nix run .#test` is **ALL GREEN** with
selftest **25,106**, every trace exact, and all 19 pixel captures byte-identical
(including the four historically failing long tours). The Windows tree was
rebuilt and passes native selftest **25,108** plus an 830-frame native headless
smoke run.

## D154 — release payloads stage outside the tracked distribution manifests (2026-07-20)

`rc.5` proved D153 remotely: its full deterministic suite passed, both release
derivations built, both sibling checksums verified, and the workflow artifact
was retained. Publication alone failed because the workflow copied those four
files into the repository's existing `dist/` tree, then passed `dist/*` to
`gh release`. That glob correctly included the tracked `dist/manifests/`
directory, which the GitHub release uploader refuses as a non-file.

Both candidate and nightly workflows now use a fresh `release-dist/` staging
directory for copying, checksum verification, Actions artifact retention, and
GitHub release upload. The staging namespace cannot collide with shipped
source directories, and every publication glob therefore contains exactly
the Linux archive, Windows archive, and their two sibling SHA-256 files.

## D155 — mesh texturing the picoCAD way: manual per-face UVs, stock checkers, and the sprite animation slots as texture frames (2026-07-21)

The human's ask, verbatim scope: "a picocad style uv mapping mode (one
face at a time)" — checkered stock defaults, drag a `.spr` in, drag the
face from the stock texture onto the sprite, move each vertex; grid
adjustment settings; `.spr` hot reload; the sprite animation slots
reused for swapping/animating textures; a vehicle-select demo; and a
way to choose sprite canvas size ("we need bigger sprites").

**The refusal reconciles, not falls.** D137's "no UV unwrap — ever" was
always about AUTOMATIC unwrapping; EDITOR3D.md §5 explicitly designed
"planar per-face UVs, the picoCAD model" and the CMSH FACE chunk
reserved the textured flag + texel UVs from day one. D155 implements
that designed half and extends it with the stock-checker default and
strip-frame animation. Every wall stands: one image per mesh, 3/4-gon
faces only, manual islands only.

**Format (CMSH, additive).** HEAD v2 appends `tw,th` — the UV
reference FRAME size in texels (the bound `.spr`'s canvas; a baked
strip holds `png_w // tw` frames) — and is written only when the size
differs from the 64x64 default, so every pre-D155 doc still encodes
byte-canonically as v1 (KAT-pinned). FACE gains flag bit3 `checker` +
one index byte (1..7, `cm.mesh.CHK_COLS`, append-only); bit2
(image UVs) and bit3 are mutually exclusive, both codec-refused. A
pre-D155 reader of a new file skips nothing it needs: unknown flag
bits sit in already-read bytes, chunk length delimits the extra index
byte, and the face keeps its flat color.

**Rendering.** `bake_groups` now keys groups by (texture source,
color): flat faces group by color exactly as before; checker faces
group per tile index with UVs from the new pure `plan_uv` (dominant-
axis planar projection, world units — the sampler tiles per unit);
image faces bake `(frame*tw + texel)/strip_w` — the SAME texel map
shifted into any strip frame. Each group keeps the first member face's
color as the flat FALLBACK, so the legacy single-buffer `emit()` (and
any texture-blind consumer — figure part meshes, an unresolved image)
degrades to the pre-texture look, never white. The texture-aware door
is `emit_segments(doc, xf, nxf, opts)` → one `{tex, flags, bytes,
ntris}` per group: checker groups bind the 7 stock 16x16 two-tone
tiles (`checker_tex`, generational free through the `rc.mesh.chk`
buffer — the rc.spr.tex pattern) with NEAREST; image groups bind
`opts.tex_id` with ALPHATEST|NEAREST (the sprite rule), lit on a WHITE
base. `terr3.emit_props` merges mesh segments into its (tex, flags)
batches — placed textured props render in the 3d map window and the
explore3d template through their existing epoch-keyed resolvers (which
now also resolve the mesh's strip texture; ids live only in the
epoch-keyed caches, the D139 discipline).

**Texture animation = the sprite animation slots.** No new mechanism:
the `.spr` already bakes a horizontal frame strip and already carries
`.anim` clips. A mesh's UV map is authored once against ONE frame;
`bake_groups{frame=n}` re-aims it at frame n (O(faces), memoized per
frame by consumers). Swapping a texture is picking a frame; animating
one is driving n from `cm.anim.frame_at`. Placed props stay frame 0.

**The window.** The `uv` chip / `u` opens the uv tab: the viewport
drops to one perspective pane, the right side is the panel — 7 checker
tiles (click = re-color the face selection; click with no selection =
select that color's faces; the selected checker face's planar ghost
rides its tile), the bound image below at a quantized fit zoom, `all`
(enable texturing: every plain face gets a checker, colors cycling
1..7), `off`, and the GRID ADJUSTMENT SETTINGS — texel snap 1/2/4/8
and grid overlay off/4/8/16 — plus `fr n/N` frame preview. Dropping a
`.spr`/`.png` on the window binds it as THE image (kind.drop, the terr
materials precedent) and records tw/th from the source. Press-drag
from a tile onto the image places the faces' planar islands at the
cursor (snapped, clamped in-frame); islands drag whole; per-vertex
handles drag one UV point; every drag is one journal entry and Esc
reverts mid-gesture (the mutating-gesture contract). The 3D panes
always render textures live through epoch-keyed `gfx.texture` +
`emit_segments` — a sprite re-save re-bakes the same frame (the tape
probes it).

**Derived-follows-source (the tape's catch).** The first tape run
exposed the D139 class live: doc.tw recorded at drop time went stale
when the tape resized the sprite, exploding the frame count
(`fr 1/24`). Now the window resolves the bound `.spr`'s live canvas
size + frame count each epoch (`spr_dims` memo), the live math ALWAYS
uses the source size (`bake_groups` opts.tw/th now override the doc's
recorded value), doc.tw/th silently re-adopts the source size outside
gestures (riding the next commit), and frame count comes from the
sprite doc itself. The recorded tw/th remains the runtime fallback for
games, which read only the baked strip.

**Sprite canvas size (the mid-session ask).** `sprite.set_size`
existed unexposed since D-era studio work; every sprite was born
32x32 forever. The sprite window header (edit mode) gains `size`: a
bar with a `WxH` field, canvas (anchored, default) / scale (resample)
mode chip, apply/Enter — one undo step, commit through the ordinary
journal, cap 1024.

**The demo — projects/garage.** A mock vehicle-select screen:
`art/truck.msh` (56 verts / 42 faces, every visible face UV-mapped
into the 64x64 frame) over `art/truck.spr` (2 livery frames — sunset
red / coast blue — plus the `flash` clip). The truck rotates on a
pedestal; left/right swaps the livery (frame swap through the slots);
enter strobes the livery through the `.anim` clip via
`cm.anim.frame_at` AND pulses the scene light (render-class decay off
recorded anchor frames in state.doc). Sim state is exactly
`{sel, flash0, swap0}`; assets resolve through epoch-keyed memos so
editing truck.spr live hot-reloads the running screen. Both liveries
headless-shot and inspected; assets were generated by a committed-free
scratchpad generator through the public codec doors.

**Proof.** Linux selftest gains 36 KATs (+HEAD v1/v2 canonicality,
checker refusals, plan_uv floor/wall, strip frame-0/frame-1/clamp
exactness, checker world-unit tiling, fallback color, segment
tex/flags routing incl. the never-white miss, stable checker ids,
extrude checker inheritance). A 22/22 shell tape on a fresh smoke copy
drove the REAL window: u → all (6 faces, ≥6 colors) → 3D face pick →
tile re-color → .spr drop (tex+frame size recorded) → tile-to-image
drag (island placed, integer in-frame texels) → vertex drag exactly +4
texels → ONE ctrl+z undid the gesture → ctrl+s (disk .msh: 5 checkers
+ 1 island, image kept) → sprite re-save re-baked the preview
(meshkey) → the size bar resized tiles.spr to 64x48 (disk .spr + strip
png follow). Suite + goldens: see STATUS.

**Deferred honestly:** UV islands for triangle fans (hexagon caps
want per-vert placement today), island rotate/flip chips, a zoomable
UV canvas, per-face frame offsets (a face animating out of phase),
checker faces keeping custom UVs, editor-side livery preview in the
3d map window (placed props pin frame 0). Revisit triggers: a real
project texturing a character head (rotate/flip), or wanting per-face
animation phase.

## D156 — the sprite ed marquee + the session-wide pixel clipboard (2026-07-21)

**The ask (the human, mid-session):** "add a marquee selection and
copypaste to the sprite editor (ideally allow it to paste to another
instance of the sprite editor too)."

**The decision.** A sixth rail tool, **`m` marquee**: drag a rectangle
on the canvas (clamped to it), a plain click deselects, right-click
cancels the drag, Esc clears — selection is a READ (locked layers
select fine) and lives on the window (`win.msel`, sprite px). The
clipboard is **`ed.g.sprclip`** `{ w, h, bytes, gen }` — ephemeral on
the editor global exactly like `g.mapclip` and the music clip (the
established convention: crosses windows and assets within the session,
dropped with `ed.g` on rewind seeks, never serialized). **Ctrl+C**
copies the selection from the ACTIVE layer's current cell (no
selection = the whole cell) — it arrives through the shell's existing
`kind_call("copy")` tier, so the sprite kind simply grew `M.copy`; a
kit `ctrl+c` entry rides along purely as the hint. **Ctrl+X** copies
then clears the region to transparency — one journal entry.
**Ctrl+V** arms the **paste tool**: the clip ghosts on the cursor
(the stamp well's exact idiom — same translucent preview, same
center anchor) and each click lays its opaque pixels
(`paint.blit "stamp"`) as one journal entry; Esc drops back to the
pen. Because the clip is plain bytes on `ed.g`, pasting into a second
sprite window — including one bound to a DIFFERENT `.spr` — is the
same code path; the ghost texture is per-window plumbing keyed by the
clip generation and freed in `drop_ephemeral` (the D139 raw-id rule).

**Why not a floating/movable pasted selection** (aseprite's model):
the stamp idiom already ships and reads instantly; a floating layer
adds a modal state machine the window doesn't otherwise have.
Revisit trigger: wanting to nudge a paste before committing, or
marquee-drag-to-move within the canvas.

**Proof.** A 10/10 probe tape on a fresh two-sprite project drove the
REAL window end to end: launcher-open truck.spr → `m` → a real 11px
pointer drag → `win.msel` exactly {2,2,12x12} → Ctrl+C fills
g.sprclip (576 bytes) without touching pixels → Ctrl+X zeroes exactly
the region (outside probed intact) → ONE Ctrl+Z restores the probed
byte → launcher-open rock.spr in a SECOND window → Ctrl+V arms paste
→ one click lands the truck clip's center pixel byte-exact at the
click point with the rock window journal-dirty. Marquee + cross-window
paste captures on llm-feed. Suite ALL GREEN; selftest count unchanged
(the feature is window chrome over KAT'd paint doors).

**Deferred honestly:** floating paste / move-selection, marquee as a
paint mask (`paint.set_clip` exists for it), copy-merged (composite)
instead of active-layer, system-clipboard PNG interop.

## D157 — the music roll grammar, round 9: click selects, right-click deletes, octave steps, the armed ghost paste (2026-07-21)

**The ask (the human):** "if a note isn't aligned to one of the
thicker grid lines, clicking it snaps it to the grid. desired ux:
clicking a note does not move or delete it, it selects it, and then
resizing and moving prioritizes the already selected note (and if
there's any overlap it shows through the overlap so the overlap can
be fixed). right click to delete a note. ctrl+up/down to move by 1
octave. also add copy paste that works between separate song windows
… we need a way to paste at a certain position within a pattern,
maybe by showing a ghost … confirming by clicking (while still being
able to pan and zoom around)."

**The two shipped bugs behind the report.** (1) A plain press on a
note armed `nmove`, which snapped the note's ABSOLUTE tick to the
grid — for an off-grid note the very first gesture frame yanked it
onto the line (the reported "clicking snaps it"), and because that
counted as `moved`, the wstudio motionless-release-DELETE rule made a
careful click a coin flip between teleport and delete. (2) The kit
`ctrl+c` hotkey was DEAD: the shell's session-clipboard tier
(`kind_call("copy")`, the tier D156 rode) consumes Ctrl+C before kit
hotkeys ever see it, so the music clipboard could never fill and
Ctrl+V always no-opped — found by this ADR's probe tape, fixed by
moving copy to `M.copy` on the kind (the D156 convention).

**The decision — round 9 of the roll grammar.** A press on a note
SELECTS it (an unselected note replaces the selection; `p.nsels` refs)
and arms the group gesture over the selection — the single-note
`nmove`/`nsize` gestures are deleted, a lone note is a selection of
one. Motionless release keeps the selection and changes nothing;
DELETE moves to **right-click** (a `kind.takes_right` claim, the
sprite/tmap precedent) and the Del key. Moves snap the DELTA to the
nearest grid step (`snapd`), so an off-grid note moves in grid steps
but KEEPS its offset; resize still snaps length to grid multiples
(that stays the deliberate way to change the add length). Selected
notes hit-test FIRST (a drag grabs what you selected even under an
overlap) and draw LAST, slightly translucent with an outline, so an
overlapped note reads through the selection and the overlap can be
fixed. **Ctrl+Up/Down** steps the selection ±12 semitones through the
new pure `M.clamp_dp` (one delta for the whole set — all or nothing,
so intervals never squash; KAT'd). **Ctrl+V arms a ghost paste**: the
old paste anchored at the scrub cursor, which lives in SONG space and
points at nothing inside a pattern whose clip doesn't start the song.
The clipboard ghost now rides the mouse over the roll (anchored at
the clip's earliest note, pitch delta clamped as a set), placement
snaps like ADD, one click places it as one journal entry and the
pasted notes become the selection; Esc / right-click cancels; MMB pan
and wheel zoom stay live while armed. The clipboard remains
`ed.g.musicclip`, so copy-here-paste-there across two song windows is
the same code path (proven cross-window in the tape).

**Why not paste-stays-armed for repeated stamping** (the sprite paste
tool's model): the human asked for "confirming by clicking" — one
confirm, one paste, no surprise second stamp on the next click.
Revisit trigger: wanting to stamp a riff several times in a row.

**Proof.** A **20/20 probe tape** on a fresh smoke copy with two
`song.fresh()` files drove the REAL window: launcher-open → grid 1/32
add at tick 36 → grid 1/8 → Esc → a plain click keeps tick 36 (no
snap, no delete) and selects → a 48-tick drag lands tick 84 (one grid
step, offset kept) → ctrl+up 60→72 → ctrl+down back → right-click
deletes exactly the note under the cursor → Ctrl+C fills the session
clipboard → Ctrl+V arms, the click lands snapped tick 240 / mouse
pitch 65 / dur 12 (a REAL paste, not an add) and disarms with the
paste selected → Esc cancels a re-arm → a second window on the OTHER
song arms and lands the same clip at tick 96 / pitch 58. The armed
cross-window ghost shot is on llm-feed. Selftest **25,146** (+4
`clamp_dp` KATs); `nix run .#test` ALL GREEN, every golden
byte-identical (window chrome only). win-music.md rewritten to the
round-9 grammar.

**Deferred honestly:** repeated-stamp paste (the revisit trigger
above), paste into the arrangement strip (clips), a visible clipboard
indicator in the transport row.

## D158 — the music roll, round 10: rail-band drops, the piano keys column, add-drag sustain (2026-07-21)

**Context — three asks from the human's native pass.** (1) "Dragging
instrument presets onto the song tracks — the hitbox is offset;
sometimes it changes the track above." Real, and worse than an offset:
`M.drop` re-derived the row with HARDCODED z=1 math (`py // 28`) off a
guessed content origin, and never learned about D151's mix panel — the
selected track's row is `px*3.45 + 3z` TALLER than the rest, so every
drop below the selection resolved one-plus rows high (and often out of
range, silently falling back to the selected track — the probe tape's
drop point resolved to "row 4" of a 3-track song under the old math).
The class: a drop handler re-deriving layout the draw owns. (2) A
piano at the roll's side. (3) Holding the drag while placing a note
should sustain it.

**The decision.** (1) **The DRAW records the rail's row bands**
(contiguous world-coord `{y0,y1}` strips per track, the selected row's
band carrying its panel) into ephemeral plumbing (`p.rdrop[win.id]`),
and `M.drop` resolves the row through the pure `M.rail_hit` (KAT'd) —
the drop can no longer disagree with the pixels because the pixels are
the source. Outside the rail (or past the last row) the drop still
binds the selected track. While an `.ins` drag is in flight
(`ed.g.adrag`), the row it would bind draws an accent OUTLINE — the
target is visible before release. (2) **The piano keys column** sits
on the roll's left edge (`KEYS_W = min(18z, 14% of the roll)`): one
shared x-shift moves ruler + roll + velocity lane right, so all three
tick axes stay aligned while the arrangement keeps the full width.
White/black keys per row, seam lines at B|C and E|F, the octave labels
moved onto the keys (the roll keeps its C gridlines). Click a key to
audition the pitch on the active track's instrument (the existing
`blip` door); dragging glissandos; the key under the cursor highlights
while hovering the roll — a pitch readout for free. (3) **Add-drag
SUSTAINS**: the fresh note arms the `selsize` gesture (not `selmove`),
so holding the press and dragging right stretches the note's end
exactly like an edge resize, and the result becomes the new last-used
length. The sustain only ENGAGES once the cursor moves >3z px — else
the press frame itself would yank the last-used length down to one
grid cell under a plain click. Round 9's drag-to-move on the fresh
note is superseded deliberately: the note is selected on release, so
move is one more drag away, and sustain is what a placement drag means
in every tracker the human plays.

**Proof.** A **24/24 probe tape** on a fresh smoke copy drove the real
window: the roll shifted by exactly KEYS_W with the velocity lane
following; a plain click added tick 48/dur 48 (threshold untripped);
press+drag added tick 384/dur 336 with `lastdur` adopting 336 and the
first note untouched; the next plain click placed at 336; a keys press
armed the audition (blip live) and released clean; with track 2
selected (panel expanded) a drop over track 3's band bound track 3
while the OLD math provably resolved row 4; a drop outside the rail
bound the selected track. Selftest **25,150** (+4 `rail_hit` KATs);
`nix run .#test` ALL GREEN, every golden byte-identical (window chrome
only). win-music.md carries the keys column, the sustain, and the
drop highlight.

**Deferred honestly:** dropping an `.ins` onto an ARRANGEMENT lane
(only the rail resolves per-row today); pressing roll notes doesn't
light the matching piano key during playback; a keys-column width
preference.

## D159 — the music roll, round 11: clipless tracks auto-create, hold-to-sustain in musical time (2026-07-21)

**Context — two reports on the round-10 build.** (1) Selecting a
track with NO clips left the roll on the previously selected pattern
while auditions and placement previews used the NEW track's
instrument — you'd edit pattern A's notes hearing track B's sound.
The rail's drill-in only followed a clip when one existed; with none,
`win.pat` simply went stale. (2) "The sustain when holding a click is
still very short": round 10's sustain was drag-distance-only with
NEAREST-line snapping (the note end lagged up to half a cell behind
the cursor), and the audition blip died after 10 frames regardless —
a held click neither grew the note nor kept sounding, so nothing
about holding read as sustaining.

**The decision.** (1) **Selecting a clipless track auto-creates**: a
fresh one-bar pattern + a clip at the song start (the human's ask),
through the new shared `M.stamp_fresh` (KAT'd) — the same core the
arrangement's press-empty stamp now calls, so the two creation paths
can't drift. One journal entry; re-selecting a track WITH clips
still just drills in and creates nothing. The invariant restored:
the roll always edits a pattern the selected track actually plays.
(2) **Holding IS sustaining.** The fresh-add gesture gains a second
growth clock: a motionless hold grows the note in MUSICAL time at
the doc's bpm (frames are the clock — 60fps live, deterministic
under tapes; `ticks = held * bpm * PPQ / 3600`, ceil-snapped to the
grid, growing from the last-used length upward so a quick click
still places the default). Dragging past the 3z threshold switches
to cursor-following with CEIL snapping — the note end always COVERS
the cursor (the round-10 nearest-snap read as "too short"); the
plain edge-resize keeps its nearest-snap feel untouched. And the
audition now RINGS for the whole gesture: `blip_hold` turns the
voice on once and refreshes a 2-frame fuse in `p.blips` every held
frame — the moment anything stops refreshing it (release, Esc,
window close) the existing blip expiry/cleanup paths release the
voice, so no new lifecycle surface exists. You hear the note for
exactly as long as you hold it.

**Why frames, not wall clock, for the growth**: pal.time_ns growth
would be unprobeable in a headless tape (frames run as fast as they
can) and would jitter with frame rate live; the editor already
redraws every frame during a live gesture (the gesture touches), so
frames ARE the steady clock, and the tape pins exact durations.

**Proof.** A **17/17 probe tape** on a fresh smoke copy: rail-click
on clipless track 2 created pattern 2 + a tick-0 clip and drilled in;
re-selecting track 1 drilled into its own clip with NO new pattern; a
45-frame motionless hold grew the note 48→96 (probed mid-hold, voice
fuse live at 2) →144 on release with `lastdur` adopting 144; a quick
click placed 144; a 100px drag's note end covered the cursor tick on
a grid multiple; the held voice expired 3 frames after release.
Selftest **25,153** (+3 `stamp_fresh` KATs); `nix run .#test` ALL
GREEN, goldens byte-identical. The capture is on llm-feed;
win-music.md carries the round-11 grammar.

**Deferred honestly:** a numeric length readout while sustaining
(the note rect itself is the only cue); auto-created patterns
linger unreferenced if their track is deleted before use (the
existing unreferenced-pattern class, harmless bytes).

### D159 addendum — the human's vote: hold auditions, never grows (2026-07-21)

The round-11 build went to the human and came back with the model
CORRECTED: "holding holds the note indefinitely like on the synth
piano roll, but the note placed is just the default with no extension
from holding. same for clicking the pattern piano roll." Round 12
implements the vote verbatim and D159's musical-time growth is GONE
(one session old, never shipped to a tag): a motionless hold on a
fresh add keeps the note at the last-used length while `blip_hold`
rings the audition until release — hold = HEAR, drag = LENGTH (the
CEIL cursor-following stays), a plain click stays a plain click. The
keys column adopts the same synth-piano contract: a key press holds
its voice until release (was a 10-frame blip), and a drag glissandos
— the old voice is abandoned to its 2-frame fuse, the new pitch
holds. The synth window's piano (`p.held` + explicit note_off) is
the model but NOT the mechanism: the music window keeps the fuse
pattern so every existing cleanup path stays the release path.
Proof: the tape re-cut to the round-12 semantics passes **20/20**
(hold 45 frames → dur stays 48, lastdur untouched, voice fuse live
mid-hold and expired after release; keys ringing 22 frames into a
hold, glissando swaps voices, release silences; drag end covers the
cursor and sets the default); selftest **25,153** (unchanged — the
growth had no KAT, deliberately); the win-music.md rewrap en route
re-proved the D127 balanced-span guard (it refused a `**` span my
edit left crossing lines). Suite ALL GREEN.

### D159 addendum 2 — moves ring too, and the rc.9 cut (2026-07-21)

The human's last piece of the synth-piano contract: "clicking and
holding an already placed note (even if I don't end up moving it)
should hold the note like the piano roll and follow where I move it."
Round 13 wires the SAME `blip_hold` into the move gesture: pressing a
note arms the group move AND rings the grabbed note at its own
velocity immediately — a motionless press-release is a pure audition
(the selection semantics are untouched: no move, no commit) — and as
the drag steps the pitch delta the old voice is abandoned to its fuse
and the new pitch holds (the keys-column glissando verbatim). The
ctrl+drag duplicate arms the same gesture and rings the same way. The
old pitch-change 10-frame blip in the move handler is gone. Every
press-audition in the window now speaks one contract: press = hear,
hold = sustain, release = silence — add (selsize), keys, move
(selmove), duplicate. Proof: the tape extends to **27/27** (press an
existing note → ringing fuse live at frame 14 with the note UNMOVED →
+2-row drag swaps the voice and moves the pitch → release silences
and commits); selftest **25,153**; suite ALL GREEN, goldens
byte-identical. **rc.9** is cut from this state (the human's call:
"push another RC build once that's implemented") via
`tools/tag-release-candidate.sh --push` — the hosted candidate
workflow is the build proof.

## D160 — the HELPDOCS program contract + the synth session: ref-doc split, sweep guards, the missing op knobs exposed (2026-07-22)

**Context.** The human's docs direction (2026-07-21/22): every tool's
help opens with a sizable tutorial that makes something meaningful,
and the COMPLETE reference of every knob and button splits into its
own doc linked at the top, with screenshots of both UI-at-step and
results; tutorials are executed live (drive tapes) while being
screenshotted, and UX rough edges found en route get fixed, not
documented around. `docs/HELPDOCS.md` carries the queue (one session
per tool, presets included); the human pulled the synth forward as
the first session — "it could use more detailed explanations of each
knob and all the combinations used to make the different stock
sounds".

**Decision — the ref-doc contract (binding for every HELPDOCS row).**
A finished tool session ships `ref-<tool>.md` beside `win-<tool>.md`:
the tutorial doc links the ref in its first lines ("Every knob and
button: …"), the ref links back, and the ref covers the complete
control surface — organized by UI region, sourced from the window's
code, never memory. Three sweep guards pin it in the selftest's
`t_docs` (the D120 what-is-written-must-be-findable loop, extended to
what-the-UI-binds-must-be-documented): (1) a `REF_DOCS` kind→ref
mapping — for every mapped kind the ref ships, the top link and the
back link resolve; (2) every `kind.hotkeys` entry is findable in the
ref (multi-char keys verbatim, hint labels verbatim — so the hint
strip's own words are searchable); (3) the existing image sweep
already refuses a dead or oversized capture. The mapping grows one
row per completed session; an unmapped kind is simply not yet done.

**The synth session itself.** `ref-synth.md` documents every knob
(window map, a 30-second FM primer, the eight algorithm wirings as a
preformatted diagram decoded from the kernel's ALG tables, feedback,
gain/pan, filter, sweep, the full operator panel, piano/tracker keys,
sample instruments) and — the human's explicit ask — reverse-engineers
ALL 53 stock presets into family recipes (Game Boy channels, bells
7:2, keys/plucks, winds/choir, detuned ensembles, the fixed-Hz drum
kit, the swept sfx family) with the real numbers, extracted by
decoding every `.ins` through `cm.ins` headless. `ref-sound.md`
covers the sound player. `win-synth.md` is rewritten as the
"four-sound chip kit" tutorial (lead from the init patch, bass from
gb-pulse-50, kick from scratch through sweep + fixed-Hz, jump from
sfx-jump); a drive tape executes it as written on a fresh smoke copy
— every gesture through the real UI — and probes the resulting `.ins`
docs (all VERDICTs pass); the five bundled screenshots are the tape's
own frames, cropped to the window.

**The UX fix the ask exposed.** The op panel exposed only
level/coarse/fine — but `detune` (the ensemble-width knob: strings
∓14, reese ∓34) and `fixed` (the drum kit's non-tracking Hz: kick
body 120 Hz, hat hiss 9 kHz) existed in the patch format, the kernel,
and half the stock presets, reachable only by hand-editing patch
tables; the synth.lua header comment even promised a detune slider.
Both are now sliders on every op panel: `dtn` −63…+63 raw, `fix` as a
0–255 log index over 20 Hz–12 kHz (the envelope-axis rule: equal
pixels = equal ratios; index 0 = track the note, shown as "note").
The idx↔hz mapping is KAT'd: exact ends, ±1-notch round trip with no
regrab creep (integer-Hz quantization packs the low end tighter than
the notch spacing — pinned, not hidden), and the stock drum anchors
land within 3%. `DEF_H` 512→560 keeps the ADSR graph comfortable
under the two new rows; existing windows keep their sizes.

**Observed en route, deferred honestly:** the committed smoke editor
session (19 windows of old proof-tape leftovers) shows one reader
code-span ("cm.rand") drawing OVER unrelated topmost windows at a
fixed world position — a draw-order/clip oddity in the help window
class, reproducible by just opening the smoke session headless and
shooting frame 40. Logged for the editor-shell HELPDOCS session
(H13), not chased here. Also deferred: island-style fixed-Hz typing
(the slider is coarse at the top octave), a per-op mute/solo for
recipe A/B-ing, and the tutorial's bass step still leaves `dtn`
unexercised by the tape (documented as optional).

**Revisit triggers.** A new synth voice parameter (a knob without a
ref section fails no sweep — extend the hotkey sweep's spirit by
hand); a real table renderer in the reader (the algorithm diagram
wants to be a table); HELPDOCS rows landing (grow `REF_DOCS`).

## D161 — the HELPDOCS sprite session: the hero tutorial, the coordinate readout, tapes ship in-repo (2026-07-22)

**Context.** HELPDOCS row H1 under the D160 contract: `win-sprite.md`
becomes the sizable tutorial, `ref-sprite.md` the complete reference,
screenshots are the proof tape's own frames, and UX rough edges found
en route are fixed at class level.

**The session.** `ref-sprite.md` covers the full control surface by UI
region (header, view mode, the view lock, tool rail + stamp well,
canvas gestures, marquee/clipboard, the size bar, the layers rail with
mix + fill controls, palette row + `.pal` stacking, frames row, brush
strip, every kit hotkey, file/bake notes); the old walkthrough's fill
recipes move there intact. `win-sprite.md` is the "paint the hero"
tutorial: a 32x32 hooded adventurer through silhouette stroke → flood
→ masked linear cel-shade (ramp born secondary→primary, light at the
top) → di 30% → bake → the three-dot face → a *mul* shadow layer → an
*add* light layer → two duplicated frames (H2's strip) → save + view
mode. The drive tape executes every step through the real UI on a
fresh smoke copy (15 VERDICTs green: pixel-exact face colors, blend
modes, dither value, baked ramp direction, the 96x32 baked strip);
the four bundled screenshots are the tape's frames. `REF_DOCS` grows
the sprite row (selftest 25,199, +23).

**The UX fix the session surfaced.** The tutorial names positions
("the eye at 15,11") and the canvas had no way to read them — a named
position could not be followed exactly, failing the done-contract's
execute-as-written clause. Edit mode now shows the hovered pixel as
`x,y` top-right of the canvas (over-canvas + in-bounds only, the
EDITING-chip idiom). No golden moved.

**The doc bug the tape caught.** After the flood step the bucket is
still armed and the brush strip does not exist for it — "set the size
dial" was unfollowable, and the tape's dabs flood-filled whole layers.
Step 8 now begins by pressing `p`. (A second tape-authoring class got
documented in the tape itself: an input gesture scheduled to overlap a
paint stroke drags the stroke through UI chips — keep gestures
disjoint in time.)

**Binding: HELPDOCS tapes ship in-repo.** H7's tape was scratchpad-
ephemeral, which left the §3 "capture recipe documented in the H1
tape" clause pointing at nothing durable. As of H1 each session's tape
commits as `tools/drive/tape-<tool>-tutorial.lua`; the H1 tape's
header carries the shared capture recipe (fresh smoke copy → full
proof run → per-shot `--frames` reruns → crop to the logged CROP rects
→ stage under `media/`). Tapes are dev tooling, not shipped assets —
release archives are untouched.

**Deferred honestly:** the marquee/clipboard and stamp surfaces are
referenced, not taped here (the D156 proof tape already drives them
end-to-end); the palette row truncating on narrow windows is
documented ("widen the window"), not reflowed; the hero leaves the
optional ink re-outline flourish to prose.

**Revisit triggers.** New sprite-ed controls (extend `ref-sprite.md`
+ the hotkey sweep catches kit keys automatically); a fill-point
gesture editor (the ref documents the fixed vertical axis); HELPDOCS
rows landing (grow `REF_DOCS`, ship the row's tape).

### D161 addendum — the reader-rendering reports (2026-07-22)

The human's first read of the shipped tutorial surfaced two reader
classes, both fixed and both KAT'd corpus-wide (selftest +48):

1. **The glyph class.** "⧉" rendered as `?` — the reader font covers
   ASCII plus the workhorse typographic set the corpus already uses
   (em/en dashes, minus, middot, ×, ±, ∓, ≈, ellipsis, arrows, °, µ,
   ▶ ◀) and nothing else. The frames chip is now **dup**, the empty
   stamp well **img** (chips are words the docs can say), and a docs
   sweep refuses any shipped glyph outside the covered set — the
   allowed table IS the coverage contract; extend it only after
   checking the font actually draws the newcomer.
2. **The glued-indent class.** Two-digit list steps wrapped at 4-space
   continuations lex as indented code (`line_kinds`' `^    ` rule) and
   rendered as code blocks. Continuations are ≤3 spaces now (GitHub's
   lazy continuation keeps rendering them as the same paragraph);
   win-synth.md steps 10–11 carried the same latent bug. The sweep
   refuses a ≥4-space line glued directly to a prose line — deliberate
   indented blocks always sit after a blank line.

The four tutorial screenshots were re-taped off the relabeled chips
(15/15 VERDICTs green; goldens untouched).

## D162 — the HELPDOCS anim session: the hero animated, clip rename lands, tapes chain (2026-07-22)

**Context.** HELPDOCS row H2 under the D160 contract: `win-anim.md`
becomes the sizable tutorial (bring the H1 hero to life), `ref-anim.md`
the complete reference, screenshots are the proof tape's own frames,
UX rough edges found en route fixed at class level.

**The session.** `ref-anim.md` covers the full control surface by UI
region (binding + the sprite-header door, the shared-document/journal
contract, preview pane + its no-clips strip cycle, clip rail, transport
+ loop semantics incl. the pingpong bounce order, entry chips + fields,
hotkeys, the timing model — 1-based UI over 0-based data — and the
`.anim` sidecar/`cm.anim` runtime pattern). `win-anim.md` is the
"bring the hero to life" tutorial: frame 2 becomes the exhale (pick
the body green, drop the clasp pixel one row), frame 3 the blink
(eyes dabbed shut), then three clips — idle `1:40 2:8` (uneven
durations breathe), walk `1:6 2:6` (the same two drawings at even
tempo read as a march: the timing lesson stated as such), blink
`1:1 3:3 1:1` **once** (fired from code over the idle) — ending in
**ctrl+s** and the game.step snippet. The old walkthrough's timing
wisdom survives inside the new steps; the old workflow bullets grew
into the reference. `REF_DOCS` grows the anim row (selftest 25,257,
+10).

**The UX fixes the session surfaced.** (1) The tutorial names clips
and the window could not rename one — clips were stuck as `clipN`,
reachable only by hand-editing the `.spr`; the old doc even described
a name field that did not exist. The entry row now carries **name**
(empty or already-taken names refused: the name is `anim.find`'s
lookup key and the rail's selection key). (2) No kit hotkeys — the
old doc promised **space** and nothing dispatched it; **space**
(play/pause) and **l** (loop cycle) land as the sound player's
convention, hint strip for free. (3) The preview cache keyed only
(doc, frame), so a paint committed from a sprite window on the same
path never reached a PAUSED preview until the playhead moved — the
key now includes the shared journal's position (undo/redo/save were
already covered by doc identity re-adopts).

**Binding: tutorial tapes may chain.** H2's tutorial legitimately
starts on H1's artifact (the saved hero + the restored view-mode
session), so its tape runs on a smoke copy that has already run the
H1 tape — the capture recipe in the tape header spells out both runs,
and per-shot reruns take a FRESH copy each time (the H1 save makes
reruns on a shared copy non-idempotent: the spawn door would hit the
open/overwrite choice). The chain is the user's own story — finish
the sprite tutorial, open the animation window. 20/20 VERDICTs green;
the final probe replays the doc's game.step math verbatim against the
saved `art/hero.anim` (frame_at boundaries, duration, the once-hold).

**Deferred honestly:** mid-gesture (uncommitted) stroke pixels still
wait for the commit to reach a paused preview — commit-grain
freshness is the contract; the entry-chip row truncates on narrow
windows (documented "widen the window", the palette-row precedent);
entries append only (+f copies the last — reordering is remove +
re-add); the clip rail neither scrolls nor pages past ~9 clips; the
duplicate-name refusal is silent (no toast).

**Revisit triggers.** New anim-window controls (extend `ref-anim.md`;
the hotkey sweep catches kit keys automatically); a real project
overflowing the clip rail (add scroll); HELPDOCS rows landing (grow
`REF_DOCS`, ship the row's tape); if a later session gives the hero
true contact frames, re-shoot the walk phases.

## D163 — crisp tutorial screenshots: the @2x capture contract + linear-sampled reader images (2026-07-22)

**Context.** The human's report on the shipped HELPDOCS shots: "all
the fonts in the screenshots are very pixelated and blurry, and it's
not the resolution — in the actual editor a same-size window renders
the fonts way better." Verified real, with two class-level causes.

**The diagnosis.** (1) Capture side: headless tapes run a 1280x800
surface at dpi 1, so `accessibility_default` resolves display scale 1
and every glyph rasterizes at ~11px — a size no human on a modern
monitor ever sees (the native editor auto-resolves scale ≥1.25 off
the real display, so its glyphs rasterize proportionally larger — the
§4 "below the cap text is pixel-perfect" contract is per RASTER size).
(2) Display side: the reader scales images by the canvas zoom through
`x_ig_image`, whose unconditional NEAREST sampler (the R8d pixel-art
contract) shears glyphs and 1px UI lines at fractional ratios —
"pixelated AND blurry" was fractional NEAREST upscaling of an 11px
rasterization.

**The contract.** Tutorial screenshots capture at 2x and ship as
`media/<name>@2x.png`:

- `pal.x_ig_image` grows an optional trailing `linear` arg (default
  false — the NEAREST contract is untouched for sprites/tiles/the
  game target). The help reader draws screenshots with it: they are
  pictures, not game pixels. No golden renders reader images; every
  golden stayed byte-identical.
- The reader lays an `@2x` image out at HALF its intrinsic pixels
  (`help.image_line` targets carry the marker), so a 2x capture reads
  the same size as a 1x one: 1:1 crisp at zoom 2 (the common scaled
  display), linearly supersampled below, never blown up.
- `D.shot_zoom(name, frame, kind[, mag])` in drive.lua: per-shot
  reruns set `SHOT` (via `rawset(_G, …)` — `--eval` runs sandboxed)
  and the camera zooms ×2 anchored at screen (40, 48) two frames
  before the shot — glyphs RASTERIZE at 2x while every input step ran
  at z = 1. Proof runs never zoom. Shots must sit at gesture-QUIET
  frames (a bump mid-drag remaps the gesture's remaining motions —
  H1's two mid-gesture shots moved, f415→f430 and f618→f634); crop
  rects read off `D.win` at the shot frame so they scale along; tall
  windows rerun on a taller surface (the tape headers say which).
- The docs image-budget KAT caps LAYOUT size (≤700x550): `@2x`
  intrinsics may reach 1400x1100. Media grew 672K → 992K — accepted;
  the crisp read is the product surface.
- The drive plan fires with a ONE-FRAME lag (`--frames N` fires
  closures through N−1: the wrapper installs during frame 1's eval),
  so shot reruns use `--frames <shot>+1` — documented in the recipe;
  the state drift is one draw tick, chosen so no shot's phase flips.

**Also landed.** The H7 synth tape adopted in-repo as
`tape-synth-tutorial.lua` (the D161 tapes-ship rule predated by one
session; the scratchpad copy was recovered) — it now synthesizes its
own deterministic `hit.wav` fixture. All thirteen HELPDOCS shots
(sprite 4, anim 4, synth 4, sound 1) re-taped at @2x, every VERDICT
green (15/15, 20/20, 8/8).

**Deferred honestly.** The six pre-program 1x captures (sprite-fills,
terrain-vale, template-topdown, music-bossa, palette-ramps,
stock-songs) stay 1x until their queue rows re-tape them (H3/H4/H8/
H9/H15 + the ref-sprite fills card); the montage/comparison images on
llm-feed are dev-side and out of scope; a reader-side smooth-downscale
for 1x images displayed above zoom 1 is subsumed by re-taping.

**Revisit triggers.** A queue row landing (its shots are born @2x); a
reader image feature that scales differently (keep the layout-size
budget authoritative); any future in-editor capture tool (it should
bake the @2x convention in).

## D164 — the palette tutorial is a color script, and exact slider values are UI (2026-07-22)

**Context.** HELPDOCS H3 asked for a detailed palette-window tutorial,
a complete control reference, taped screenshots, and the usual rule that
an unfollowable step is a product finding. The old guide demonstrated
several independent ramps, but it neither made one game-ready artifact nor
carried the palette into art. Worse, a recipe could say "H 260" while the
window exposed only an unlabeled drag position. The `.pal` codec also caps
at 256 colors while several UI growth doors could display more, leaving the
encoder to omit the tail silently.

**The artifact and lesson.** `win-palette.md` now makes
`pal/moonlit-vale.pal`: night violet, moss teal, and lantern gold as three
five-shade hue-shifted ramps; one repeated near-black joins their shadows;
one rose accent stays scarce. The sequence deliberately crosses all three
ways of thinking about color: SV for a by-eye fundamental, exact HSV for a
related material, exact RGB for a supplied paint-over value, and hex for a
known accent. It then saves, drags the palette from assets onto H1's hero,
and floods the body from the attached row while the sprite's *mul* shadow
and *add* rim layers preserve volume. The final code example names palette
indices by role instead of scattering color literals.

**The UI binding.** Every palette drag slider has a fixed 40-scale-pixel
value bay before its track. H and ramp hue read in degrees (signed where
appropriate), S/V in percent, RGB as 0..255 bytes, and ramp n as an integer.
The fixed bay matters: the thumb and track do not shift when a value gains
or loses a digit. Values remain continuous drag controls, with the existing
hex entry and shades field as typed doors. Paste, +add, duplicate, and
append-ramp now all stop at `palette.MAX`; replace already produces a bounded
ramp. Thus every palette the UI grows is representable by the encoder, with
no hidden working-only tail.

**Reference, tape, and pictures.** New `ref-palette.md` is organized by the
surface under the pointer: new/open/rebind and header, saved swatches versus
per-window working scratch, picker modes and alpha-aware hex, edit/order
buttons, ramp controls and math, pointer/keyboard grammar, sprite stacking,
file format, and runtime APIs. `REF_DOCS` grows the palette mapping. The
shipped `tools/drive/tape-palette-tutorial.lua` chains H1 on a fresh smoke
copy and passes 23/23 VERDICTs, including exact saved hex order, the real
asset-filter/drag attachment, and the hero paint. Its five real @2x crops
are picker, ramp, adopted HSV, finished 16 colors, and palette-in-use; all
were inspected in the reader and as an llm-feed montage. The obsolete 1x
`palette-ramps.png` is replaced, paying one of D163's six deferred captures.

**Proof.** Linux selftest **25,274** (+17 from the palette `REF_DOCS`
sweep); `nix run .#test` is ALL GREEN with every trace and pixel golden
byte-identical. `tools/build-windows.sh` refreshed the development tree,
preserved 11 durable Windows-side entries and the Start Menu shortcut, and
the staged native executable passes **25,276** checks on PAL API 24.

**Deferred honestly.** HSV/RGB channels have exact feedback but no typed
numeric entry, so fine values are still reached by drag; the max-color door
stops quietly rather than showing a toast or disabled chip. Swatches do not
print an index in every cell — the selected `i/n` counter is authoritative.
Palette stacking is an editor-layout paint source: choosing a swatch bakes
RGBA into sprite pixels, with no retained palette index or live LUT link.
The tutorial tape drives mix/adopt/replace/append/add/set/save/attach/paint,
not copy/paste, move, delete, or duplicate; those remain fully described in
the reference and covered by the existing editor guards.

**Revisit triggers.** Typed channel input or a visible max-state; a
palette-indexed sprite/rendering feature (which must define save/runtime
link semantics rather than pretending the present row is one); any new
palette control (extend `ref-palette.md` and its tape); HELPDOCS H4 now owns
the assets/stock side of the drag-and-copy story.

### D164 addendum — one shared shadow is one swatch; captures fit their content (2026-07-22)

The human's first reader pass caught two mistakes in the H3 delivery. First,
"shared shadow" had been implemented by overwriting slots 1, 6, and 11 with
the same `171525`. Identical saved bytes do not become three roles; they waste
two slots and visually teach the opposite of a disciplined 16-color budget.
The corrected color script stores `171525` once at slot 1 and uses that swatch
wherever materials meet. The original dark teal `223528` and dark red-brown
`4f2e2e` remain at 6 and 11 as useful chromatic outlines. The tutorial and
reference now state this distinction, and the tape pins all sixteen ordered
hex values plus exactly one occurrence of the universal shadow.

Second, the first four crops preserved the palette window's full 500px
general-purpose height even though these small grids ended around its middle.
This was real dead space, not a reader-scale artifact. A named SHOT rerun now
resizes the real window one frame before capture only, then still crops its
whole rounded frame: picker/ramp are 760×584, adopted HSV 760×480, and the
finished palette 760×540 instead of 760×1000 each. The proof run and written
tutorial never receive the hidden resize; every shot starts from its own fresh
H1-derived copy. The occupied hero result remains 920×760 and was re-taped so
its attached row shows the corrected colors.

Proof remains 23/23 tape VERDICTs (`one-shared-shadow true copies=1`), Linux
selftest **25,274**, and `nix run .#test` ALL GREEN with every golden
byte-identical. All five replacements were visually inspected and the
llm-feed montage was refreshed; the native Windows reader stage was refreshed
again and remains at **25,276** checks on PAL API 24.

## D165 — Assets organizes the project; Stock lends parts without owning the result (2026-07-22)

**Context.** HELPDOCS H4 pairs two browsers whose old short walkthroughs
blurred several materially different actions. Assets needed to teach that its
flat grid still manages real paths, that rename/move carries editor authority,
and that a drag is interpreted by its destination. Stock needed to teach the
difference between opening an unsaved experiment, copying exact bytes now,
and asking a receiving well/track to adopt a library item. The H4 row also
required complete references and four proof-tape screenshots: mid-rename,
in-flight drag, filtered Stock, and the editable unsaved copy.

**The paired story.** The tutorial is one project-curation arc split at the
window boundary. `win-assets.md` has eight exact steps: filter H1's hero,
rename/move the editable family to `art/characters/moonrunner.spr`, watch its
already-open Sprite window and `.png`/`.anim`/`.meta` family follow, carry
`plank.png` to bare canvas, then carry it into the Sprite `img` well without
confusing a relationship with a pixel edit. `win-stock.md` continues for nine
steps: filter `noir-sleuth.song`, double-click it into an unsaved Music working
copy, audition and save, rename it `sound/moonlit-route.song`, direct-copy
`fm-glass.ins`, audition and rename that project file `ins/moon-glass.ins`,
then drag the local instrument onto the first song track and save the explicit
kit. The remaining untouched track references legally stay
`engine/stock/ins/...`; local ownership is deliberate per voice, never an
implicit dependency crawl.

**The reference boundary.** New `ref-assets.md` covers header/state, all four
type chips, full-path fuzzy rank, tile sizing and per-tab scroll, every preview,
the select/open/carry routing ladder, `r` move semantics, two-press deletion,
the collision-safe cross-project chooser, OS imports, companion-family rules,
the parked write wall, and all pointer/key hints. New `ref-stock.md` covers the
five families/destinations and exactly three adoption doors: double-click seeds
unsaved editor state; **c / enter** atomically copies one source file; drag
delegates to a receiver (notably Music copying/binding `.ins`). It names what
does **not** recurse or bake. `REF_DOCS` grows both rows, so reference presence,
top links, backlinks, and declared hotkey hints remain KAT-pinned.

**The product finding.** The written flow chose Assets' **sound** chip to find
the saved `.song`; the tile vanished. `class_of` treated only decoded
`.wav`/`.ogg`/`.mp3` as sound and left the engine's own `.song`/`.ins` authoring
sources in `all`. Sound is now the author-facing family: both editable formats
join the chip and use the sound glyph. The same classification reaches OS
imports, so `.song` correctly lands in `sound/` and `.ins` in its canonical
`ins/` rather than following generic sound routing. Selftests pin both class
membership and destinations. Assets' ambiguous **c — copy to project** hint is
also corrected to **copy to another project**; Stock retains **copy to project**.

**Tape and pictures.** `tools/drive/tape-assets-stock-tutorial.lua` chains the
H1 tape on a fresh smoke copy and executes both pages as written. Its 20/20
VERDICTs cover the sprite fixture, filter/selection, family move and open-window
follow, bare-canvas opener, stamp-well receiver, Stock filter, unsaved seed,
Music audition, save/rename, direct instrument copy, Synth open/audition and
follow-on rename, local track bind, and final decoded disk song. Four real @2x
frames are tightly fitted: Assets rename 1040x500, drag over the live Sprite
well 920x760, Stock filter 1120x460, and unsaved Music 1360x880 intrinsic. The
in-flight named rerun re-arms a real shell carry only after the @2x camera move,
avoiding the D163 mid-gesture remap. All four were inspected individually, in
both readers, and as an llm-feed montage. The obsolete unreferenced 1x
`stock-songs.png` is retired.

**Proof.** Linux selftest **25,300** (+26); `nix run .#test` is ALL GREEN with
every trace and pixel golden byte-identical. The H4 tape is 20/20 and both
tutorial pages render cleanly in the real reader. `tools/build-windows.sh`
refreshed the development tree (11 durable entries plus the Start Menu
shortcut), and the staged native executable passes **25,302** checks on PAL
API 24.

**Deferred honestly.** Both grids still select tiles by pointer: Assets has no
plain-arrow cursor/Enter-open, and Stock has no arrow cursor (Enter is direct
copy). The old Assets guide's unimplemented arrow claim is removed rather than
preserved as fiction. Assets tiles label basenames while fuzzy search retains
full paths; duplicate basenames want a later disambiguation affordance. H4 does
not tape destructive delete, OS drag-in, or cross-project **c** (their focused
durability/KAT coverage predates this session). Stock has no direct audition
button: the receiving Music/Synth window owns transport. A directly copied
stock `.spr` is source-only until the user opens and saves it to bake the
runtime family; the reference says so.

**Revisit triggers.** Keyboard accessibility work reaches either grid (add one
shared, visible navigation contract rather than two ad hoc cursors); duplicate
basenames make a real project ambiguous (show path context); Stock gains a
preview transport (keep it non-editing and editor-bank-only); new file families
or receiver drops land (extend both references and the tape). HELPDOCS H5 now
owns the map-building side of project assets.

## D166 — the map tutorial proves a route, and exact coordinates are authoring UI (2026-07-22)

**Context.** HELPDOCS H5 required more than a collider catalogue: one detailed
lesson had to create a playable level, show the decisive editor states, and
walk the result through the real runtime. The old map guide mixed historical
grammars with the current surface. In particular, it gave no way to follow an
exact coordinate recipe by eye, MAPS.md still described `C` as a close-chain
command even though plain `c` now selects Col mode, and Graybox failed in the
natural new-map order when `maps/` did not exist yet.

**The artifact and lesson.** `win-map.md` now builds **Moonlit Crossing** in
13 exact steps. The authored CMAP has a closed eight-point terrain chain with
two true 45-degree banks, a dashed one-way bridge, a circle query hazard,
complete `spawn` and `goal` marker records, two named layers, a generated
graybox tilemap, and two plank placements demonstrating free pixels versus
Ctrl alignment. The lesson then saves, uses the bundled smoke console to load
the map into its stable room slot, wraps circles as a temporary reset hazard,
and walks the real mover up and down the slopes. A reusable code section shows
the production shape: `map.use`, revision-aware marker derivation,
`world:move`, `world:circles`, goal overlap, `draw_fill`, and `draw_places`.

**The current interaction boundary.** Move is the one direct-manipulation
mode: repeated clicks drill collider handles/edges, markers, groups, and
placements. Col and Mkr only place; Sel is a one-shot marquee that returns to
Move. A selected chain closes only through its visible **closed** chip. Plain
`c` always enters Col. The stale selected-collider hint now says "closed chip
toggles" instead of promising "c closes", and MAPS.md gains an as-built H5
section that explicitly supersedes the older intermediate description.

**The two product fixes.** The map view's compact top-right status now reports
rounded authored `x,y` while the pointer is over the view, followed by zoom and
grid; off-view it keeps the compact zoom/grid form. `M.view_status` is pure and
KAT-pinned. Graybox now creates the generated tilemap's project-relative parent
before its atomic write, so `maps/moonlit-crossing.map` may publish
`maps/moonlit-crossing_gb.tm` before the map's first Ctrl+S. The existing
failure door remains unchanged: a failed atomic write does not mutate the map.

**Reference, tape, and pictures.** New `ref-map.md` is the exhaustive surface
contract: create/rebind, all header chips and state, view lock/readout, Move
drill, selection/groups, collider kinds and draw grammar, Ctrl target priority
and edge-runs, markers/extras, asset drops/opening, placement and attached
collider inspectors, layers/parallax, map fields/Graybox, clipboard/order,
hotkeys, journal/save/reload/rewind failures, CMAP chunks, and runtime use.
`REF_DOCS` grows the map row. The shipped
`tools/drive/tape-map-tutorial.lua` drives the written lesson on a fresh smoke
copy and passes **21/21 VERDICTs**, including every authored coordinate and
field, generated/saved bytes, runtime circle query, grounded slope traversal,
and hazard reset. Four real @2x crops show the selected solid/one-way chains,
complete marker inspector, live Ctrl carry over the generated skin, and the
same route running. All were inspected individually and in the real reader;
the labelled montage is on llm-feed.

**Proof.** Linux selftest **25,310** (+10); `nix run .#test` is ALL GREEN with
every committed trace and all 19 pixel goldens byte-identical. The Windows
development tree is refreshed (11 durable entries plus the Start Menu
shortcut), and the staged native executable passes **25,312** checks on PAL
API 24.

**Deferred honestly.** The tutorial demonstrates layer naming/lock but not
parallax or the independent editor/game visibility switches; it does not tape
grouping, clipboard/z-order, attached colliders, OS drops, asset double-click,
or destructive reset. Those surfaces are described in the reference and keep
their existing focused KAT/durability coverage. The circle-to-reset wrapper is
deliberately a smoke-console adapter, not a claim that circles damage actors by
themselves. Graybox is a replaceable blockout skin; HELPDOCS H6 owns authored
tile painting and reuse. Chain vertices have a live coordinate readout and
precise snapping, not typed per-vertex fields.

**Revisit triggers.** A project needs arbitrary non-grid vertex entry (add an
exact selected-vertex inspector); a second authoring mode begins picking
existing objects (preserve the clear place/manipulate boundary); Graybox gains
more generated asset families (keep parent creation and atomic failure
semantics shared); a new map control or CMAP chunk lands (extend
`ref-map.md` and the executable tape). HELPDOCS H6 now owns the reusable
tilemap chunk that replaces this lesson's generated skin.
