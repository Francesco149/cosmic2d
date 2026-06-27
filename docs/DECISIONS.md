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
