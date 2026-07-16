# cosmic3d decisions — append-only ADR log (fork-specific)

Shared engine decisions stay in docs/DECISIONS.md (untouched in this fork for
merge cleanliness). 3D-fork decisions land here as D3D-NNN. Full arguments
live in docs/COSMIC3D.md; entries here are the binding one-paragraph form.

## D3D-001 — fork cosmic2d; re-merge after 1.0 (2026-07-16)

cosmic3d is a git clone of cosmic2d (remote `upstream`, push-disabled) so the
histories stay mergeable. Rationale: cosmic2d is mid-alpha-gate and its PAL
wants to freeze at 1.0; landing 3D primitives there now fights the release.
Rule: shared files get surgical, additive edits only; new work goes in new
files/modules. Revisit: after cosmic2d 1.0, evaluate one shared PAL with
additive `x_` 3D primitives.

## D3D-002 — GPU retro pipeline; software rasterizer as look reference (2026-07-16)

The 3D renderer is ONE fixed SDL_GPU pipeline added beside the quad pipeline
(same make_pipeline shape): depth-tested triangles `pos f32x3 / uv f32x2 /
col unorm8x4`, pre-lit vertex colors (lighting is Lua/kernel policy, NOT in
the PAL), mvp+fog uniforms, manual 3-point/nearest filtering + alpha test in
the frag shader, blend+no-depth-write variant for decals. Proven: the
prototype's GPU and software paths render identical scenes on lavapipe.
Pixel goldens stay lavapipe-pinned (pixels were never sim state). The
software rasterizer (proto/r3d.c) stays in-repo as the definition of
intended pixels. User confirmed a GPU renderer that *looks* like a retro
rasterizer is the intent.

## D3D-003 — the two aesthetic presets are policy, not engine forks (2026-07-16)

N64 preset: 320×240-class target, 3-point filtering, vertex light + painted
AO, fog, 5551+Bayer grade, 32–64px textures, 250–800-tri characters.
RO preset: 480×270-class target, ~15° FOV camera pitched 40–70°, blended
heightfield terrain, nearest+cutout sprites, blob shadows, water plane at
144/255 opacity drawn after sprites. PS1 extras (affine wobble + vertex
snap) are a cheap optional third preset. **VI-soft bilinear upscale is the
default presentation** (human-picked); sharp integer pixels selectable.

## D3D-004 — demo roadmap (2026-07-16, human-set)

1) N64 platformer, bouncy-cube protagonist (3D twin of cosmic2d's demo) —
movement feel + level aesthetic first. 2) Zelda-ish open world — exploration
+ the figure/animation showcase; Body-Harvest vertex-color terrain + detail
texture + pitch fog. 3) RO-style — must *feel* like RO: blended-bake terrain
(scene ro2 v6 look), chibi billboards (Kushnariova CC-BY now; house set via
VRoid render-to-sprite or figure baker later), paper-doll system to RO's
head/body/anchor spec. Editor-primitive distillation is parked until the
gameplay is polished.

## D3D-005 — characters: rigid-part figures, no skinning ever (2026-07-16)

The SM64 technique is the native character model: rigid part meshes on a
joint tree, per-joint euler keyframes (lerp/stepped), root-only translation,
texture-swap face strips, joint gaps hidden by overlap. Figure editor gets
picoCAD-class vertex pushing from day one (human-set). Figures bake to
8-direction sprite sheets (proven in the prototype) — the model-once /
use-as-3D-or-billboard loop. Mascot direction approved: lathe teardrop body,
Rayman-style floating mitts/boots, antenna star, eye style B. Standing
constraint: stock characters must not read as "Minecraft people".

## D3D-006 — terrain: splat-paint + bake; blends vs props (2026-07-16)

Terrain = per-corner-height tile grid + painted material weights + a bake
step producing a unique low-res texture per tile: materials sampled in
continuous world space, smoothstep-feathered noise-perturbed borders,
1-texel gutter per tile (filter-seam fix), corner-smoothed normals, prop
shadows multiplied in on the authentic 8×8-per-tile grid. Water is a level
plane; shorelines are height contours. Walk grid at 2× render resolution
(GAT-style) is what the sim reads. Rule (human, v6): **ground materials
blend; architecture is crisp-edged geometry/props** — paved areas are
aligned slab props over a circular trampled blend, never terrain bakes.
Real RO never runtime-blends tiles (hand-painted transitions); our bake is
a deliberate ergonomic upgrade reproducing the same read
(docs/research-3d/ro-render-recipe.md is the authoritative reference).

## D3D-007 — x_view3d appends per-frame views; 3D pre-pass owns the clear (2026-07-16)

Two implementation-shape choices made landing the pipeline (agent, within
the COSMIC3D.md §2 spec). (1) `pal.x_view3d` APPENDS a camera/fog setup
(cap 64/frame) instead of setting one global: segments bind the latest view
at call time, so the sky NDC pass (no-arg = identity mvp + fog off), the
scene view, and future editor viewports/split-screen coexist in one frame
without PAL churn. (2) 3D renders in its own pre-pass with the D16 depth
target attached, clearing color+depth; the 2D quad pass then LOADs over it.
The 2D pipeline objects are untouched and a frame with no 3D keeps the
exact cosmic2d pass structure — the inherited pixel goldens stayed green
unregenerated. Everything 3D is lazily created on first use (pure-2D
sessions allocate nothing). Vertex layout (24B: pos f32x3, uv f32x2,
pre-lit rgba u8x4) and PAL_TRI_* flags (1 alphatest, 2 nearest, 4 blend +
no depth write) mirror the prototype dump exactly — proto/gpu_proto.c
remains the twin, r3d.c the pixel reference.

## D3D-008 — movement slice: sim camera, one box list, Lua emitters (2026-07-16)

Three shape choices from demo 1's movement slice (projects/bounce):

1. **The follow camera is SIM state.** Input is camera-relative (up = away
   from camera), so the sim must know the camera — bounce.cam is a named
   buffer stepped in game.step (pull-string model: manual z/x orbit rotates
   the offset instantly, the position eases toward dist-behind). This is the
   smoke.cam precedent, not a break of the render-class rule: view/proj
   MATRICES are still built only in draw; the D036 corollary ("the sim never
   reads pixels") holds. Gameplay cameras are gameplay; presentation stays
   presentation.

2. **One box list is the level.** level.lua's BOXES table emits the visuals
   (gb.gbox, grouped per material into x_tris segments) AND derives the
   collider AABBs. No dual bookkeeping; the axis-aligned start the STATUS
   directive asked for. Rotated/prism/lathe structure joins when the
   primitive vocabulary grows — colliders will then need a shape beyond the
   AABB list (likely keep colliders axis-aligned + let deco rotate).

3. **gb.lua ports proto pixel-math verbatim, in Lua.** Material checkers
   (tx_gb fbm/value-noise, six materials), the shadow blob, gbox emission
   with uv-scaled texel density, and light_vertex (ambient + sun·N, pre-lit
   u8 colors) are straight ports of proto/main.c+r3d.c — the look reference
   stays the source of truth, now without the baked .c3dd middleman. Player
   verts (squash/stretch via T·R·S with normals lit rot-only) rebuild each
   draw into a fixed-size scratch buffer (bounce.dyn) — render-class derived
   data, never read by the sim.

Movement itself reuses cosmic2d's D029 fixed-apex math in world units
(g_rise = 2h·3600/t², v0 = 2h·60/t, fall_mul, coyote+buffer) — the 2D kit's
feel discipline transplanted, every value a doc.knobs entry. Debug find
along the way: an "invisible" blend blob shadow was actually correct
behavior (its own alpha falloff hides the uncovered rim when grounded);
PAL_DBG_3D now dumps seg3d state for the next such chase.

## D3D-009 — collision clamps from pre-move side; camera = the godot rig (2026-07-16)

Human playtest of bounce found teleports: walking at the stairs or jumping
could fling the cube across geometry. Root cause: the axis resolver picked
the clamp face from the VELOCITY SIGN — but velocity zeroes on the first
hit, so a second overlapping box in the same pass clamped to its far face
(vx==0 read as "not >0" → +x side). The stair/keep pocket (0.7u gap,
0.9u player) guaranteed the double overlap. Two rules adopted:

1. **The clamp face comes from which side the player was on pre-move**
   (x+hw <= b.x0 → clamp -x face; x-hw >= b.x1 → +x face; already
   overlapping → clamp nothing, let another axis/frame resolve). The
   y-pass lands only if the feet STARTED at/above the top and bonks only
   if the head started below the bottom — no more side-clip snap-to-top.
2. **Level rule: no pockets narrower than the player** between colliders
   (un-fittable gaps are squeeze cases by construction). The stair run is
   now flush with the keep.

Camera: replaced the pull-string cam with a port of the human's godot
cosmic project rig (F:\Documents\cosmic, src/camera/FollowCamera.cs +
CameraTuning.cs — read it before touching camera feel; knob names
mirror it): explicit orbit yaw/pitch/dist hung off a smoothed focus,
composing drives — yaw-follow easing behind the velocity heading (the
circling on sideways runs), manual look pausing yaw-follow briefly,
recenter behind the facing, wheel zoom with angle-preserving framing.
Mouse look ships as DRAG-look (absolute cursor deltas from the frozen
10-byte input record v1); true captured-cursor look needs a PAL
relative-mouse API + a record revision — deferred, engine-shared surface,
merge-sensitive. Headless runs see zeroed mouse fields so autoplay/
goldens stay deterministic (same design as the godot original).

## D3D-010 — epsilon side tests, the mantle, wasd/arrow controls (2026-07-16)

Second playtest round. The D3D-009 resolver had a float hole: a side
clamp stores `face - hw` into the f32 player buffer, and `(face-hw)+hw`
can round PAST the face — the exact pre-move side test then classified
the flush player as "squeezed" (clamp nothing) and it slid into the box.
Symptoms: diagonal walks phased through the stairs; one pillar was solid
on one axis only (per-face rounding luck). Rule: **any geometric side
test against sim state stored in f32 buffers carries an epsilon** (1e-3
world units here — far above f32 noise at these coordinates, far below
one frame of motion). Found via a frame-exact `_G.DBG=1` track — the
telemetry hook + `game.demo(2)` (pure forward walk) stay in the
cartridge as the collision soak harness.

Mantle (human-requested): a blocked step whose top is within `step_h`
(knob, 0.6u) of the feet lifts the player instead of clamping — only if
grounded and the body fits at the raised spot (headroom scan). Stairs
are WALKED, jumps are for gaps; no squash on the lift. This replaces any
step-up leniency in the jump itself and is checked before both x and z
clamps.

Controls settled: **wasd = movement, arrows = camera** (left/right yaw,
up/down pitch at knob rates, pausing yaw-follow like every manual
drive), mouse drag look + wheel zoom + c recenter unchanged. Captured
cursor mouse-look confirmed as the post-upstream-merge plan (needs the
PAL relative-mouse API + input record v2).

## D3D-011 — the primitive vocabulary: prisms, lathes, rotated deco (2026-07-16)

gb.lua grew the round half of the proto vocabulary — `G.prism` (extruded
n-gon, facet-flat side normals, optional top/bottom cap fans) and
`G.lathe` (profile-of-{r,y}-pairs revolved around Y, smooth per-vertex
ring normals from the profile slope), straight ports of proto/main.c
draw_prism/draw_lathe, plus `G.tri` and rigid-transform helpers. All
emitters now RETURN their tri count so level.lua stopped hand-counting
segment sizes. Emitters accept an m4 xf; rigid (translate*rot) only —
applydir doesn't renormalize, scale would skew lighting.

The level speaks it: BOXES stay the axis-aligned walk surfaces; new
PRISMS (12-gon round tower, hex keep, octagon pillar — the two metal
pillar boxes replaced), LATHES (the proto graybox dome, *0.8, on the
tower), DECO (y-rotated accent monoliths ringing the goal tower).
**Collider rule: colliders stay AABB, only visuals rotate.** Prisms get
the apothem box of the wider radius — facets clamp flush, corners
overhang the collider (visuals may overhang colliders, never the
reverse). Rotated deco gets its world-bounds AABB — a touch fat at the
corners, never thinner than the visual. Placement keeps the D3D-009 gap
rule (> cw where collider faces oppose). Soak-verified: walk-into-facet
clamps at exactly apothem-hw; monolith at bounds-hw.

Kill plane (surfaced by the autoplay trace running off the world edge
and falling forever): `y < move.kill_y` (knob, -12) respawns at
level.spawn with a landing squash so the reset reads as feedback, not a
glitch. demo(1) now loops the course indefinitely — future golden
material.

## D3D-012 — the goal loop + the render-class buffer domain "rc." (2026-07-16)

Demo 1 became a game (the STATUS directive: touch feedback, sound hook,
respawning collectibles, all knob-driven). **pickups.lua**: gold diamond
gems (2-cone lathe profile, 8 segments) hover along the course
(level.gems); pickup = coin sfx + doc.score + an expanding fading pop
ghost (blend pass); a collected gem respawns after goal.respawn frames,
so autoplay loops keep collecting — the world never goes dead. The
ice-white goal star (1.9x gem) tops the accent tower: touch = bell
fanfare triad, doc.laps, a fading 8x16 COURSE CLEAR banner, and every
gem respawns (a fresh lap). Knobs under doc.knobs.goal (radius, respawn,
pop, banner, spin, bob). Sim state = per-item respawn countdowns in the
named buffer bounce.pickups + doc counters; pickup tests use REST
positions — spin/bob live only in emit (render-class animation off the
frame counter). audio.lua reuses the demo cartridge's SFX pattern and
its tuned .ins presets (copied into ins/); player.lua fires
jump/land/kill-respawn hooks. gb.lathe grew an alpha param (ghosts).

**The "rc." buffer domain** (engine change, cm/state.lua, surgical):
recording the first bounce trace golden diverged at frame 1 on
bounce.texids — PAL texture ids are SESSION-DEPENDENT (the id counter
differs on replay), and bounce.dyn is rebuilt per draw() while --verify
never draws. These buffers are render-class: they live in named buffers
only so the PAL and hot-reload can see them, but their bytes are not
sim state. Rule: **name such buffers "rc.*" — state.sim_buffer excludes
the prefix from snapshots, traces and goldens** exactly like the D050
"ed." editor domain. bounce renamed texids/dyn/sky into it. The iron
rule stands: anything the SIM reads stays in verified buffers
(bounce.player/cam/pickups); "rc." is for what only the renderer reads.
(proto3d.texids has the same latent issue; rename when that cartridge
next gets touched — it has no trace golden.)

## D3D-013 — movers: kinematic platforms as pure frame functions (2026-07-17)

The course's first moving colliders (movers.lua): level.MOVERS boxes
shuttle their TOP surface between two endpoints, cosine-eased ping-pong
over a period in frames. Positions are **pure functions of the sim
frame** (phase = frame % period, cm.math trig) — no state buffer at
all, so snapshots/traces/rewind replay them for free and the sim/draw
split is one function called with two frame values: player.step
collides against the post-step boxes (frame+1 — exactly what draw
emits, so a rider sits flush with what's on screen), and a grounded
player whose feet sit on a mover's pre-step top is RIDING: carried by
the frame delta before its own move (x/z add; y tracks the top, glued
both directions — faster than gravity could follow). Movers join the
static collider list for the axis sweeps, so they land/clamp/mantle
like level geometry: a lift docked at 0.4 (< step_h) is boarded by
just walking into it.

Rules that fall out:
- **A moving box breaks the static gap rule by construction** (it
  transiently forms narrower-than-the-player pockets against statics).
  That is safe since D3D-009/010 — squeezed overlaps clamp nothing and
  never teleport — but course design still keeps RIDERS clear of walls
  (flush docks are fine; carrying a rider INTO a wall is not resolved).
- Standing under a descending mover squeeze-phases (benign, resolves
  when it leaves); a mover never scoops a player standing inside its
  path — you board from outside (mantle/land), by design.
- Blob shadow anchors on movers too (ground_below takes an extra box
  list at the draw frame).

demo(4), the mover tour, drives everything: waypoint routes grew
**wait predicates** (reach the point -> stand, doc.demo_hold, letting
the mover carry the demo anywhere meanwhile -> advance when the
predicate passes). Lift -> dome shoulder -> the goal-star leap laps at
~f840; the wall ferry crosses at ~f1800. Goldens: bounce_tour.ctrace
(1000f, vertical carry + the lap) and bounce_tour.png (f1920, the
ferry mid-crossing — pixel-pins horizontal carry).

## D3D-014 — cartridge modules MUST use the reload table pattern (2026-07-17)

Found recording the movers round: ANY drift between working sources
and a trace's bundled code crashed --verify ("attempt to index a nil
value" in player.step — level.colliders nil after the bundle restore).
Root cause: bounce modules opened with `local L = {}`, violating the
boot.lua module convention. On restore_bundle/hot-reload, run_chunk
re-runs the chunk, which builds a FRESH table; the loader copies its
contents into the original shared table (identity preserved for
everyone holding a reference) — but the re-run chunk's CLOSURES keep
writing the fresh local, so level.build() populated a table no other
module could see. Engine modules and upstream cartridges all use the
documented pattern; the fork's cartridges now do too:

    local M = select(2, ...) or {}   -- reuse the module table on reload

**Rule: every cartridge module whose table carries state written after
load starts with the select(2, ...) pattern — in practice, just use it
everywhere.** Both bounce traces were re-recorded so their bundles
carry compliant sources; verified that traces now survive deliberate
source drift (the exact case that crashed). Also reaffirmed the hard
way: pixel goldens are shot on PINNED LAVAPIPE only (VK_DRIVER_FILES=
$COSMIC_LVP_ICD, the dev-shell export) — a dzn/WSL shot looks right
and byte-mismatches.
