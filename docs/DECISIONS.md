# pettan2d — decision log

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
implementation pt/state.lua.
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
steps). pt.input.apply() is the only path into sim-visible input state,
which lives in the `pt.input` named buffer (cur+prev, so pressed/released
edges are snapshot-consistent). Live sampling adds "sticky tap": a
press+release inside one sample window still sets the bit for one frame.
**Why**: record/replay symmetry by construction; edges survive restore;
sub-frame taps never vanish (feel pillar).
**Revisit when**: text input lands (M2 console) → additive record type in
the container, not a change to record v1; gamepad → new bits/axes likewise.

## D019 — snapshot/trace containers: PSNP/PTRC tagged chunks (M1)

**Context**: D012/D014 need concrete file formats with room to grow.
**Decision**: one chunk grammar (pt/chunk.lua): magic + version-stamped
tagged chunks, unknown tags skipped, truncation = loud error. PSNP = CODE
(full bundle) + BUFS (every named buffer) + DOCT. PTRC = HEAD + SNAP +
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
**Decision**: pt.ease ships the standard family (31 curves: linear +
quad/cubic/quart/quint/sine/expo/circ/back/elastic/bounce × in/out/inout)
as pure deterministic functions over pt.math (which grew exp2 for
expo/elastic). Curves are addressable by NAME via a registry — doc knobs,
timelines and tweens store the name; `pt.ease.register` lets game code add
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
**Decision**: pt.ui is an immediate-mode core: widgets are per-frame calls;
the only retained state is a per-id table keyed by hierarchical id paths,
living on the module (survives hot reload, resets on VM reboot, never
snapshot). Interaction = classic hot/active/focus with one-frame capture
latency; the game receives only events the UI didn't capture, and
up-events always pass (no stuck keys). Iron rule: pt.ui never touches
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
caching inside pt.ui, API unchanged).

## D022 — console evals are recorded sim inputs (EVAL records, M2)

**Context**: the console REPL pokes sim state mid-session; D014 traces
must stay an oracle. Deltas alone would keep *replay* correct but verify
(re-sim) would diverge at the first poke — and a knob-tuning session is
exactly what we want to record and share.
**Decision**: pt.repl is the single eval path: submits queue, the queue
drains at the START of the next sim frame (before input applies), and the
recorder writes drained commands as EVAL v1 chunks before that frame's
FRAM. Verify re-executes them via the same pt.repl.exec at the same point.
Replay-without-re-sim ignores EVALs (their effects are in the deltas). A
contained game error stops an active recording so the trace stays valid up
to the last good frame. Golden: tests/traces/evalfix.ptrace (doc poke,
buffer creation, an erroring command), tamper-tested.
**Snapshot story**: commands are data in the trace; the code they call
travels in bundles (D012). Caveat (documented in pt/repl.lua): repl env
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
**Decision**: pt.main guards require/init/step/draw in live sessions. On
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

