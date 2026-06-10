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
