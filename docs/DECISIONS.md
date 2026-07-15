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
