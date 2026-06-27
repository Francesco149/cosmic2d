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
