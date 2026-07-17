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

## D3D-015 — the N64 presentation lands: x_grade quant= + pal.x_soft (2026-07-17)

The D3D-003 adopted default look (human-picked on the graybox shot) is in
the engine — pal 0/api16, both halves per-frame render-class opt-ins
reset at begin_frame, proto r3d.c fb_write_png (--soft) the reference
math:

- **The 5551 framebuffer grade**: `pal.x_grade{quant=n}` — a Bayer-4
  dithered n-bit-per-channel quantize appended to the existing grade
  post-pass shader (quant=5 = the N64 16-bit framebuffer). It runs at
  INTERNAL res and bakes into the game target, so readback and pixel
  goldens see it — the deliberate design (the dither is part of the
  frame, exactly like the real console's framebuffer). quant=0 and the
  grade-off path stay byte-identical; every inherited golden passed
  unregenerated.
- **The VI-soft present blit**: `pal.x_soft(on)` — the game-layer blit
  in the composite samples bilinearly (new linear clamp sampler, new
  blit_soft.frag) and smears horizontally 3-tap [1,2,1]/4 with taps one
  DESTINATION pixel apart — the VI resample + smear. Presentation only:
  the internal target never sees it (goldens/readback untouched); the
  ui canvas and ig layer stay sharp; sharp integer pixels remain the
  engine default (D3D-003: selectable, and 2D cartridges never call it).

bounce adopts both via **doc.knobs.look = {quant=5, soft=1}** (armed in
draw each frame, so the knobs are live; render-class — the sim never
reads them). The three bounce pixel goldens were re-shot on pinned
lavapipe (deliberate look change — the internal frame now carries the
dither); trace goldens replay untouched (--verify never draws). New:
**bounce_soft.png, the suite's first COMPOSITE golden** (--win 960x720)
— it pins the soft blit shader + linear sampler end to end, which no
internal-target golden can. Shot twice, byte-stable on lavapipe.

Deliberately NOT done: quantizing inside the 3D scene pass (the grade
already covers the whole frame, HUD included, like real hardware), and
soft-blitting the ui/editor layer (dev chrome wants sharp text). The
"mild horizontal smear" strength is fixed in the shader for now — knob
it only if the human asks after the feel-check.

## D3D-016 — cm.fig: figures are data, poses are frame functions (2026-07-17)

The D3D-005 character model landed as an engine module (new files,
merge-clean). Shape choices:

- **A figure is cm.fig DATA** (parts on a joint tree, each part a list of
  cm.gb shapes), compiled by fig.build, emitted by fig.emit as a pure
  function of (figure, root m4, pose) — no animation state anywhere, the
  movers precedent: traces/rewind replay figures for free. Clips are key
  POSE LISTS lerped by fig.cycle (proto walk_pose generalized); the guy's
  whole walk is still ~10 numbers.
- **Pose channels are sparse per-part arrays** [rx,ry,rz, tx,ty,tz,
  sx,sy,sz]: euler rot in the proto order (Ry Rx Rz), translation for
  Rayman-style floating parts (the mascot's mitts/boots — D3D-005's
  root-only-translation rule is for humanoid joint chains, floating
  parts are the sanctioned exception), scale for squash & stretch.
- **Two transform chains**: positions inherit pose/shape scale down the
  tree (a squashed body squashes the eyes riding it); normals travel a
  parallel RIGID chain into gb's new nrmxf — lighting never skews (the
  D3D-008 player-squash precedent generalized). cm.gb grew G.ball (the
  proto 6-point chunky ball profile) for all the mascot's round parts;
  gb itself promoted out of bounce (second user — the cm.m4 precedent).
- **projects/figure is demo 2's seed**: mascot (idle + walk) + guy
  (technique proof) circling a stage, zero input. First figure goldens:
  figure_show.ctrace (300f) + figure_show.png (f430).

Deferred until a character needs them: stepped (non-lerp) tracks,
texture-swap face strips (the guy's eyes are boxes for now), and any
foot-slide tuning (cadence knobs only — never IK, that would be
skinning-adjacent complexity the model forbids).

## D3D-017 — cm.terr heightfield + the mascot goes playable (2026-07-17)

Round 10, on the mascot lock-in verdict (COSMIC3D.md §8d). Demo 2's
ground and its hero, in one cartridge (projects/openworld):

- **cm.terr is a per-VERTEX height grid** (smooth hills, no cliffs) —
  the Body-Harvest openworld look from proto scene_openworld: banded
  jittered vertex colors (band noise hashes the shared vertex, so seams
  agree across tiles), one y-flattened normal per tile, a neutral detail
  mottle multiplied over the palette, an unlit alpha-blended water plane
  (proto light_vertex's zero-normal rule, honored by terr's own vert —
  gb.vert would ambient-tint it). The per-corner GND tile model with
  auto cliff walls (D3D-006) remains the editor-era asset; RO cliffs
  grow out of this module when demo 3 needs them.
- **T.sample is triangle-exact against T.emit**: both split tiles on the
  NW->SE diagonal, so the walk surface IS the rendered mesh — the
  colliders-are-the-sim-truth rule carried to terrain. Heights are plain
  Lua data from T.vnoise (integer-hash value noise, pure IEEE, no libm):
  deterministic worlds with zero stored bytes.
- **Terrain movement = the bounce kernel, ground swapped**: land when
  integrated y reaches world.ground(x,z); while grounded and not rising,
  a k.snap window glues downhill walks to the slope (bigger drops become
  real falls, so walk-offs still read). Tree trunks are the only side
  colliders — D3D-009/010 clamp rules unchanged. No mantle (nothing to
  mantle), no kill plane (terrain everywhere; world edges clamp).
- **Playable-figure animation rule**: NO animation state. The walk clip
  runs on a DISTANCE phase (one sim f32 — feet cannot slide at any
  speed); idle runs on the frame counter; draw blends idle->walk by
  ground speed, multiplies the live squash/stretch factor into the
  clip's own body-scale channel, and adds run lean on the base joint.
  Composition happens in the POSE (fig.mix output), never in the figure.
- **cm.mascot**: the locked-in mascot def + clips promoted engine-side
  on its second user (figure re-exports it; figure_show goldens verified
  byte-identical). The engine now ships its mascot as a module.
- **The scatter PRNG draws before the accept test** (world.lua trees):
  placement stays replayable no matter how accept rules evolve — the
  same discipline as named-buffer layouts.

Known-open (asked on the feed): deep water is wade-able (no swim/block
rule yet); tree canopies have no collision (trunks only). Goldens:
openworld_tour.ctrace (1000f ring tour, drift-proven) +
openworld_tour.png (f1290 pond crossing).

## D3D-018 — yaw-follow holds inside the back cone (2026-07-17)

Human playtest (openworld): "the camera is vibrating when i walk
backwards". Root cause, reproduced frame-exact with the new demo(2)
backup soak: walking INTO the camera pins the yaw-follow target
('behind' the velocity heading) exactly opposite the current yaw; the
shortest-arc easing's sign then flips with float noise every frame
(yaw alternated 3.18/3.20), and because input is CAMERA-RELATIVE the
ease can never win — camera and wish rotate together, so the pole is
self-sustaining. The godot original (FollowCamera.cs, the feel
reference) has the same unguarded LerpAngle — a latent rig bug, not a
porting error.

Rule: **inside kc.back_cone (default 0.35 rad) of straight-into-the-
camera, yaw-follow HOLDS** — backing up runs at the screen (the classic
third-person read); sideways runs (|angdiff| ~ pi/2) keep the approved
circling. Manual look / recenter unaffected. Applied to both rig copies
(bounce + openworld — the rig promotes engine-side on its third user).

Fallout: bounce_tour.png re-shot (deliberate): the tour's near-reversal
leg (off the goal tower, back west) now enters the cone, so the camera
eases differently and the f1920 framing rotated; the sim path is
byte-identical (world-space route steering), the frame still pins the
ferry carry. All traces + every other pixel golden unchanged.

## D3D-019 — deep water swims: the derived regime + the pond (2026-07-17)

Human direction on the round-10 feed question (block-or-allow deep
water): "just add a basic swim mechanic". Two problems: the mechanic,
and the fact that no deep water existed — the openworld fbm is
base^2*20 - 1.0, floored at -1.0, so the deepest basin was 0.62u of
ankle water on a 1.9u mascot.

- **The pond**: the noise's own deepest basin (42,64) is scooped with a
  quartic radial carve (R=9u, -2.2 at center → 2.8u deep). Outside R
  the heightfield is byte-untouched; the tour route's nearest leg
  passes ~11u out and its 1290-frame telemetry diffed identical through
  the change. Level design stays a deterministic function in world.lua.
- **The swim regime is DERIVED, never stored** (the playable-figure
  no-animation-state rule extended to movement modes): swimming :=
  water deeper than move.swim_depth under the feet AND feet below the
  surface. No flag in the player buffer — the layout didn't grow, and
  there is no transition state to desync.
- **In the regime**: buoyancy springs y to the float line (surface -
  float_depth) against a vertical water drag, settling into a small
  bob; horizontal motion runs swim_speed/accel/fric; a buffered jump
  press becomes a paddle hop (paddle * the jump's v0) — enough to read
  as a stroke and help mantle a bank. Everything else is the unchanged
  kernel: the shore exit is the ordinary landing snap as the ground
  rises through the threshold (float line sits just above the cutoff
  depth, so the regime hands off with a ~0.1u settle, no pop).
- **Depth split**: swim_depth 1.05 vs float_depth 0.95 — shallower
  water stays plain wading (walkable, feet wet), the round-10 question
  answered as allow-with-a-floor.
- **The entry splash is a derived edge too**: regime false at step
  start, true after integration → one splash (sfx-splash.ins, noise2
  through a swept lp filter), velocity-scaled gain. No stored
  was-swimming bit.
- **Presentation**: neutral body scale while swimming (the airborne
  stretch would gong on every bob), a forward paddle tilt
  (feel.swim_tilt) on the base joint, and the walk clip keeps its
  distance phase as the stroke — the paddle is the walk cycle at swim
  speed, no new clip needed for "basic".

Fallout: openworld_tour.ctrace re-recorded — the new move.swim_* knobs
grow the doc tree, and verify refills defaults via game.init after the
SNAP restore, so the old trace's doc compare diverges at frame 1 (the
trajectory itself proved identical). openworld_tour.png re-shot: the
carved pond sits inside the f1290 framing (deliberate look change).
New goldens: openworld_swim.ctrace (900f demo(3) pond-crossing ring:
splash, crossing, mid-pond paddle hop, bank exit, rim walk home) +
openworld_swim.png (f300 mid-pond). Same round, the figure showcase:
one shared anim.ring_rate pins the box guy exactly opposite the ring
mascot (per-walker rates drifted the gap; human: keep the guy, never
let him overlap the mascot) — figure_show goldens re-recorded/re-shot.

## D3D-020 — the first NPC + the proximity exchange (2026-07-17)

Demo 2's Zelda-ish beat (the STATUS next-step list's first option,
taken autonomously): the world gets an inhabitant who ACKNOWLEDGES
you. The pond watcher — a color-variant mascot on the pond's east
bank — turns to face an approaching player, waves, chimes, and speaks
a HUD line.

- **Color variants over new figures**: cm.mascot.build(overrides)
  casts palette variants of the one approved figure (coral body/teal
  mitts vs the player's teal/coral; the antenna star stays gold — the
  species mark, not the individual's). The part tree and all clips
  work on any variant because poses address parts by name. A brand-new
  NPC figure would have needed its own approval round; a recolor of
  the locked-in mascot inherits the verdict.
- **The exchange is radius + hysteresis**: greet begins inside
  knobs.npc.greet_r, ends outside exit_r (a boundary hoverer can't
  machine-gun the chime). The facing EASES toward the player (and back
  home after) so the turn reads as a turn, not a snap.
- **Sim state is one named buffer** (ow.npc): eased yaw, the
  greet-start frame stored as frame+1 (0 stays the not-greeting
  sentinel even for a frame-0 greet), and the greet count (dialog
  lines rotate per greeting). The wave pose and the typewriter reveal
  are pure functions of (buffer, frame) — the zero-animation-state
  rule extends to the exchange.
- **The wave clip lives engine-side** (cm.mascot.wave, frame-driven —
  a waver stands still, so no distance phase). Draft lesson: the mitt
  must sweep ABOVE the head silhouette; held beside it, it reads as an
  ear at 320x240.
- **Dialog is HUD text**, centered on the full line so the typewriter
  reveal doesn't slide, typed at type_f frames/char. No text-box art
  yet — whether the exchange wants a proper bubble/portrait is a feed
  question for the human.
- **The chime reuses bounce's fm-bell** at its fanfare note (a
  human-heard preset in a new snd slot) rather than drafting a new
  synth patch nobody has approved.

Fallout: knobs.npc grows the doc tree and sfx-greet.ins grows
snd.bank, so both openworld traces re-recorded (the D3D-019/round-11
precedents); tour/swim pngs re-shot (the NPC is new world content;
the HUD tris counter moved). New goldens: openworld_npc.ctrace (480f
demo(4): approach, chime edge, turn ease, hold-and-stand) +
openworld_npc.png (f311: wave out-sweep, the full first line typed).
All three traces drift-proven; figure goldens byte-identical through
the cm.mascot builder refactor. Suite ALL GREEN.

## D3D-021 — stars: the wander gets a goal (2026-07-17)

Round 13, autonomous (the STATUS menu's verdict-free option — water
polish and exchange depth stay gated on open feed questions). The
open world's first collectible loop: ten gold stars scattered over
the terrain, a counter, and an all-collected fanfare.

- **The collectible IS the species mark**: the same gold chunky ball
  (G.ball n=6, cm.mascot's star color) the mascot wears on its
  antenna — no new shape language, and the pond watcher's "that star
  on your antenna" line was already pointing at it. Spin reads
  through facet lighting (the lathe is revolution-symmetric; its
  6-segment facets are not).
- **The bounce pickups pattern verbatim-ish** (its second user):
  per-item timers in one named buffer (ow.stars), the 0 / pop..1 /
  -1 encoding, stays-collected (the bounce playtest lesson: timed
  respawn reads as a bug), pop ghosts + spin/bob render-class, coin
  sfx on a new slot from bounce's human-heard preset, fanfare = the
  bell triad on the existing greet slot (no new synth drafts).
- **Placement rides the verified routes**: seven stars on the
  demo(1) ring waypoints, two on the demo(3) swim banks, one beside
  the pond watcher's stand spot — every spot's height sampled on the
  carved terrain before it went in. The mid-pond star floats at a
  pinned y just above the water (the swim regime's reward); every
  other star derives ground + hover per use, never baked at init
  (the module table is reassigned on hot reload — baked state would
  vanish).
- **The come-on star moved off spawn**: the natural first spot
  (71,71) IS the spawn cell — a star there self-collects at boot in
  every session and golden. It sits a leg down the ring instead.
- **demo(5), the star sweep**, chains only verified legs (ring +
  swim routes and their reverses) and ends standing on the watcher's
  star, so the fanfare, the greet chime, and the dialog overlap in
  one closing beat — the golden covers pickup, swim-collect,
  completion, and the exchange in a single trace.

Fallout: knobs.stars + doc counters grow the doc tree and
sfx-coin.ins grows snd.bank, so all three openworld traces
re-recorded and re-shot (stars entered every framing; the tour now
reads 7/10 mid-lap, the npc golden collects the watcher's star). New
goldens: openworld_stars.ctrace (1900f, drift-proven) + .png (f1740:
banner + gold 10/10 counter + the exchange). Suite ALL GREEN.

## D3D-022 — props beyond trees: boulders, pebbles, flower patches (2026-07-17)

Round 14, autonomous (no new feed verdicts; water polish and exchange
depth stay gated). The STATUS menu's remaining verdict-free option:
the world's first props beyond the cone trees — static dressing that
makes the bands read as *places* without touching the sim.

- **Three scatters, three PRNG streams**: boulders/pebbles/flowers
  each run their own xs32 state (seeds 517/733/271). The tree stream
  (seed 99) is byte-identical to round 10 — its trunk boxes are the
  trace-locked collider list. Same in-loop lesson as the trees: every
  draw happens BEFORE the accept test, so placement survives accept-
  rule edits (and it did — the flower band was retuned twice).
- **Boulders keep to the high bands (h >= 3.8)**: every verified demo
  route leg stays h <= 3.3, so the new colliders — world-bounds AABBs
  around the rotated prisms, per D3D-011 — cannot touch a golden
  trace. Proven, not assumed: all 7 traces replayed byte-identical
  with 42 boulder colliders live (137 colliders total). This is the
  cheap way to add colliding props mid-demo: place them where the
  goldens never walk, and the suite becomes the proof.
- **Pebbles and flowers are collider-free walk-over deco** (ankle
  clutter; a 0.1u pebble as a wall would read as a bug, and the
  mantle only helps against real colliders).
- **Flowers grow in patches**: the first draft's uniform scatter read
  as lone lollipops at 320x240; 2-4 clumped flowers per accepted
  patch point (90 patch attempts -> ~25 patches, 95 flowers) read as
  a meadow. Head = a tiny 2-cone diamond lathe (the bounce-gem
  species, 20 tris) on a 3-gon stem — G.ball heads were 3x the tris
  for no read gain. Four petal colors from a fixed palette.
- **Rock gray one shade up from the band color** ({0.56,0.52,0.49} vs
  the band's {0.47,0.43,0.41}): under the warm sun the band color
  itself read charcoal on a standing prism.

Fallout: no knob, doc, or snd change — all 7 traces stand
unregenerated (the round's proof of the render-class/sim split). The
four openworld pixel goldens re-shot deliberately (~2.5k new static
tris in every framing). Suite ALL GREEN; 3 shots on the feed
(density + boulder-gray questions open).

## D3D-023 — the meadow wanderer: NPCs become a list, one walks (2026-07-17)

Round 15, autonomous (no new feed verdicts; water polish and exchange
depth stay gated on R11/R12 answers). The ungated STATUS option that
grows the figure/animation showcase — and after the human trimmed the
props back in R14, more life beat more clutter: a SECOND NPC that
walks its own little route.

- **npc.lua holds a LIST of instances**, each a cm.mascot.build color
  variant with one named sim buffer (36B f32: yaw, greet start/end as
  frame+1, greet count, armed, x, z, waypoint, walk phase). The pond
  watcher is instance 1, behavior unchanged; the lavender/moss MEADOW
  WANDERER is instance 2 with a route. Emission stays a pure function
  of (buffer, frame) — the zero-animation-state rule holds at two.
- **Greeting = start > end.** Keeping BOTH edges in the buffer (old
  code zeroed the start on exit) buys the draw side blend-out for
  free: the wave blends in from the start edge, back out from the end
  edge (frozen at the phase where it stopped), and a walker's gait
  weight makes way symmetrically. No new state, two comparisons.
- **A greet HOLDS a walker, then it walks on** (k.hold = 180f): stop,
  ease facing, wave, line, resume — it has flowers to count. Re-greet
  arms only past exit_r, so a standing player gets one hello per lap,
  not a machine-gun. The armed flag subsumes the watcher's old
  hysteresis exactly.
- **The loop is verified ground like every route**: six legs through
  the flower meadow on the tour's south leg, h 0.50..1.32, >= 1.2u
  clear of every collider, probed headlessly before a line of NPC
  code. Walkers have no collider and glue to world.ground — verified
  gentle terrain is what makes that honest.
- **Stage the entrance, don't spawn it in your face**: the wanderer
  starts on the loop's FAR side (start_wp), so demo(6)'s player
  settles among the flowers before the hello walks into frame — the
  first draft greeted mid-corridor with its back to the camera. Beats
  are placement + timing, not just clips.
- **audio.sfx grew a note override**: the wanderer's hello is the
  same greet bell a fourth up (note 81), not a new preset draft.

Fallout: knobs.npc grew speed/arrive/hold and the ow.npc buffer
layout changed — all four openworld traces re-recorded (drift-proven)
and their pixels re-shot; the wanderer stands in the stars f1740
framing. New goldens: openworld_meet.ctrace (900f) + .png (f690,
face-to-face wave with the full line). Suite ALL GREEN.

## D3D-024 — solid NPCs: dynamic colliders through the player's passes (2026-07-17)

Human on R15, same day: **"make the npcs solid so I can't walk through
them."** The first MOVING colliders in openworld (bounce's movers were
pure functions of the frame; NPC positions are buffer state).

- **npc.boxes() derives the AABBs per step-call from the sim buffers**
  — the boxes ride the wanderer for free, nothing is stored. D3D-011
  holds for round bodies too: the box sits INSIDE the visual (body
  lathe max r 0.82 -> hw 0.575 at cw 1.15), so brushing past reads
  fair, never invisible-wall.
- **player.step grew a dyncol parameter** and its three collision
  passes (x clamp, z clamp, box-top landing) iterate
  { world.colliders, dyncol } — one mechanism, no special cases: NPCs
  block flush, a 1.9u jump clears a 1.7u body, and an NPC head is a
  perch (the box-top rule from the boulder fix applies unchanged).
  Boxes are read pre-npc.step (one sim frame behind the draw, 0.04u
  at amble speed) — keeping the player->npc step order the exchange
  depends on beats chasing same-frame boxes.
- **Solidity cuts both ways**: a walker whose next step would close
  inside stop_r on the player WAITS — direction-aware (moving away
  never freezes), so it reads as queuing and resumes the moment you
  step aside. Without this, a solid player is a body the wanderer
  visibly clips through; with it, blocking its path is a tiny
  interaction. Greet (4.2) fires long before stop_r (1.6), so the
  usual encounter is still hello-first.
- **Proven headless before any golden moved**: route-driven plow test
  pins the player at exactly hw+npc_hw from center; a drop settles at
  ground+ch on the head; a parked player freezes the wanderer at
  stop_r and releases it on walk-away.

Fallout: knobs.npc grew cw/ch/stop_r (doc change) — all five
openworld traces re-recorded + drift-proven. No golden route enters
an NPC box, so all five pixel goldens passed UNREGENERATED — the
suite's own proof that solidity changed nothing it shouldn't. Lesson
banked from the round: never `git checkout` a file to strip a drift
probe while it carries uncommitted work — trim the probe line
instead (sed '$ d'); the probe-append/checkout habit silently
reverted the player's collision edits once and only the re-verify
caught it.

## D3D-025 — the streaming world: pure-function ground, render-class chunks, closed-form far entities (2026-07-17)

The §8e directive (stream a HUGE world with entities everywhere,
stress-tested by a glider) implemented as COSMIC3D.md §10 sketched it —
sketch first, measured (the §10 budget table), then projects/bigworld.

- **Ground is a pure function; the sim never sees chunks.** cm.terr grew
  T.sample_fn (triangle-exact sampling backed by a lattice height
  FUNCTION, no stored grid) and world-lattice ox/oz offsets on
  T.emit/T.emit_water (world-coord positions, jitter hashes, detail UVs
  — chunk borders agree byte-exactly; defaults keep openworld
  byte-identical, proven by the unregenerated suite). bigworld's
  world.hfn = the openworld fbm + a continental octave (plains / ~30u
  mountain regions / lakes) over 2048x2048u. Consequences, all landed:
  no terrain in any snapshot; traces cross chunk boundaries by
  construction; the §8e golden question dissolved.
- **Chunks are render-class buffers under a budget.** 16x16-tile chunks
  (~1ms gen, measured) into rc.bw.c<id> named buffers, nearest-first,
  default 1 gen/frame, evicted past the ring (+1 hysteresis), submitted
  distance-culled in fixed cz/cx order (~30k tris on screen). Prop
  COLLIDERS derive from the same per-chunk pure streams on demand
  (boxes_near, cached — memoizing a pure function is sim-legal), so
  solidity never depends on residency.
- **Far entities are (route, phase) — update-or-don't answered by
  construction.** ~2500 wanderers in ONE buffer (48B slots): position =
  home + circle(base + w*frame + phase_off), O(1) at any frame gap,
  identical under any schedule — no hash order, no update-rate drift
  possible. Near the player (deterministic distance + hysteresis,
  promote 20u / demote 24u) a slot joins bw.near (sim state: traces pin
  the promote/demote history) and runs the interactive kernel: greet/
  wave (chime pitched per species), route freeze via phase_off (so
  demotion needs NO re-anchor), the D3D-024 wait, solidity through
  player.step's dyncol. Spatial access is home-chunk buckets rebuilt
  from the pure placement streams at init; the sim scans a 3x3-ish
  window, the renderer its draw window — never the population.
- **The glider is a movement regime, not a system**: one buffer field;
  deploy on an air jump press (past coyote), 26u/s soar with slow
  steering, gentle sink, drop on press, touchdown/water stows. Pose =
  the breaststroke's glide stretch frozen near-prone. demo(2) hop-glides
  a probed heading forever (~800u/2400f soaked, lake swims included).
- **Proofs**: bigworld_tour.ctrace (900f) + bigworld_glide.ctrace
  (1500f, ~25 chunk boundaries) verify PASS + drift-proven; BOTH verify
  under _G.BW_RES=2/_G.BW_BUDGET=8 (the sim-side honesty proof); the
  glide pixel re-shot under _G.BW_BUDGET=6 is BYTE-IDENTICAL (paging
  config is a pop-in transient only). Suite ALL GREEN with the two new
  pixels; openworld/bounce goldens passed unregenerated through the
  terr change.
- **PAL verdict (the ergonomics finding §8e asked about)**: nothing
  needed at this scale — the frame re-uploads ~30k tris (~2-5ms
  lavapipe) and chunk gen amortizes fine. The retained-GPU-geometry API
  stays a DEFERRED candidate; it starts biting somewhere past ~100k
  submitted tris/frame (the §10 measurements), not here.

Open (feed): glide speed/read, totem->figure pop distance, world
variety, entity density (2467 of a 4000 cap — the walkability accept
rejects mountain/water routes).

## D3D-026 — rovale: the RO recipe in-engine — baked terrain atlas, click-to-move, the live figure→sprite bake (2026-07-17)

The §8f pivot (demo 3) built as COSMIC3D.md §11 sketched it — sketch
first, measured (bake ~4.8µs/texel → 5.7s/map, A* ~2.9ms worst, pick
~60µs), then projects/rovale.

- **The baked blended terrain is a budgeted render-class pass.** Every
  tile gets a UNIQUE 34×34 texture (32 + 1-texel gutters into the
  neighbors) baked by sampling grass/dirt/sand in continuous world
  space, weights feathered over noisy smoothstep bands, prop shadows
  multiplied on the authentic 8×8-per-tile lattice — all packed into ONE
  1088×1088 atlas (one tex_create + one terrain segment). Too slow for
  init (5.7s), it runs in draw under a tiles/frame knob behind a loading
  bar, pixels in a persistent rc. buffer (hot reloads re-upload
  instantly; a BAKE_STAMP mismatch rebakes). Honesty proven the §10
  way: the tour pixel golden re-shot under _G.RO_BUDGET=32 is
  BYTE-IDENTICAL — the sim reads only T.sample + the walk grid.
- **Click-to-move is sim input end to end.** The mouse already lives in
  input record v1, and the camera rig is sim state — so pick ray
  (march + bisect vs W.ground), walk-grid snap, heap A* (64×64 cells of
  1u — the GAT 2× scale), and the cell-chain walk all replay from a
  trace. No physics kernel: RO movement is pathing (facing is a smooth
  sim angle, octant-snapped only at sprite time). demo(1) tours the vale
  by SYNTHESIZING clicks through the same pick+path pipeline (projecting
  the next waypoint into the frame, orbiting the camera when it isn't) —
  the golden trace exercises the entire kernel headlessly.
- **The figure→sprite bake went live** (§5's "model once, use as 3D or
  billboard", the license-clean §8/2 answer): spr.lua rasterizes any
  cm.fig figure — edge functions, z-buffer, the pre-lit vertex colors
  already in the emitted tris, proto bake_guy_sprite's 3/4 camera — into
  an 8-yaw × 7-row sheet (idle/walk×4/wave×2) in ~0.25s/variant at
  boot, pixel-cached in rc. buffers across reloads. The mascot is the
  player; cm.mascot.build color variants are the three NPCs. Billboards
  per the recipe: upright camera-yaw quads, nearest+alphatest, unlit
  tinted 0.7+0.3·shadow(feet), blob decals, water AFTER sprites at
  144/255. Sheet column = octant(facing − camera yaw).
- **Walkable props answered §4's bridge question in miniature**: the
  plaza deck slabs are crisp gbox props whose tops override W.ground
  inside their rotated footprint — the walk grid and A* just see the
  height, and the player steps onto the gazebo deck (tour f≈450 stands
  at 2.10 = inner slab top).
- **Terrain tweaks vs proto ro2**: a ford floor (max-blend to ankle
  depth) where the path crosses the pond arm, and a chunked flat APRON
  ring outside the map so the 15° camera never sees past the world edge
  (fog takes the far rim).
- Goldens: rovale_tour.ctrace (1000f: ford wade, plaza deck stand, two
  greets) verify PASS + drift-proven; rovale_tour.png (f620 greet beat)
  + rovale_pond.png (f200 shoreline) + the RO_BUDGET honesty cmp.
- **Ergonomics candidates logged for the distillation phase** (the §8f
  goal): the terrain bake wants a cm module + editor bake button; the
  sprite baker wants to be cm.spr (any cartridge, any figure); the pick
  ray + walk-grid A* are engine-shaped (cm.walk?); billboards could join
  cm.gb; the sprite depth-pull PAL flag stayed unneeded (smooth vale +
  steep camera — revisit on cliffs).

## D3D-027 — playtest: sprite sheets are committed assets; billboards fully face the camera (2026-07-17)

Four rovale playtest verdicts ("exactly the vibe we would want" plus
fixes), the two decision-shaped ones recorded:

- **The figure→sprite bake outputs ASSETS, not boot work.** spr.lua
  writes each rasterized sheet as a committed RLE `.spx` file
  (projects/rovale/spr/, ~205KB each vs 466KB raw); boots load
  instantly, `game.rebake_sprites()` re-rasterizes + rewrites, and
  SPR_STAMP invalidates stale files in other checkouts (a read-only
  tree — the suite's nix store — just rasterizes in memory). This is
  the editor-era shape: bake is a button, the result is a file asset.
- **Billboards span camera right × camera up** (feet-anchored), not
  upright-Y: upright quads foreshorten under the pitched RO camera
  ("they shrink when i angle the camera"). Full facing = full size at
  any pitch; the top tips away from the eye like RO's lean-back, and
  the smooth vale keeps the head end out of the terrain (the depth-pull
  PAL flag stays unneeded — revisit on cliffs).
- Also: the border apron rebuilt as non-overlapping TILE-lattice bands
  (the overlapping corner strips z-fought — a shimmering diagonal);
  W.terrain_h clamps to exact bounds; the click sfx fires on the press
  edge only (held-repeat re-commands silently).
- Proofs: rovale_tour.ctrace verified UNREGENERATED through all four
  changes (sim untouched except the sfx call site, which the demo path
  reproduces identically); both pixels re-shot deliberately; the
  RO_BUDGET honesty cmp re-proven; suite ALL GREEN.

## D3D-028 — cm.rig: the orbit-follow camera slice opens the distillation phase (2026-07-17)

The §8f/§12 distillation phase's first slice, cut the upstream-A5 way
(votes counted, byte-identical extraction, goldens un-recut — see §12
for the process survey and the full audit).

- **The vote**: bounce, openworld and bigworld carried the godot
  FollowCamera rig as three copies whose MATH was byte-identical (only
  comments differed) — angdiff, the orbit/focus step (wheel zoom,
  drag-look, cam_* keys, recenter, yaw-follow with the D3D-018 back
  cone), the camera-relative wish rotation, the virgin-buffer seed,
  and the draw-side eye derivation. The D3D-018 vibration fix had to
  be applied three times; that is the pain the slice absorbs.
- **cm.rig** (engine/cm/rig.lua, new file — merge-clean) owns the
  40-byte f32 buffer LAYOUT but never the buffer: the cartridge names
  it (bounce.cam/ow.cam/bw.cam all stand), seeds it via R.reset, steps
  it via `R.step(cam, kc, px, py, pz, vx, vz, tyaw)` — target position
  /horizontal velocity/facing passed in, so the module knows no player
  — and draws through `R.view(cam, kc)` (the view matrix; projection
  and fog stay the caller's) + `R.wish(cam, fwd, side)` (the
  camera-relative unit wish). Knobs stay project-owned under
  doc.knobs.cam (each demo tunes its feel); `R.defaults()` hands a new
  cartridge the approved openworld values. Input contract documented:
  mouse wheel/drag + "cam_l/r/u/d" + "recenter" actions, all
  record-backed. No module state, no own buffers — traces, snapshots
  and rewind carry the rig by construction (and the rig dodges
  upstream D092's doc-recanon cost by living in an f32 buffer; §12).
- **Deliberately NOT here**: collision/occlusion zoom, rails, shoulder
  offsets, cinematic splines, the RO fixed-orbit camera (rovale's is a
  different, simpler animal — it stays put until a second RO-style
  cartridge votes).
- **The name is cm.rig, not cm.camera**: upstream A5 shipped cm.camera
  (2D follow/bounds/shake) since our fork; §12 bans fork modules from
  squatting upstream names so the post-1.0 re-merge stays clean.

**Proof.** The full suite runs ALL GREEN with no golden re-cut. Read
honestly (learned mid-round): a trace SNAP carries its CODE BUNDLE
(trace.lua restores it on verify), so trace verify is hermetic against
Lua source edits — the ten trace PASSes pin buffer/doc shapes, not the
new code path. The bit-identity proof is the SEVENTEEN pixel goldens:
each replays its demo from a fresh boot on CURRENT sources — the whole
route through cm.rig's step/wish/view decides every frame's framing —
and all compare byte-exact on pinned lavapipe. No visual surface
changed — no new feed captures (the D097 precedent).

## D3D-029 — cm.spr: the figure→sprite baker promoted engine-side (2026-07-17)

The second §12 slice: the human-logged D3D-026 candidate ("the sprite
baker wants to be cm.spr — any cartridge, any figure").

- **projects/rovale/spr.lua moved verbatim to engine/cm/spr.lua** (git
  mv — merge-clean new file): the deterministic Lua rasterizer, the
  proto bake camera, the 8-yaw × N-row sheet layout, S.oct, the
  camera-facing billboard + decal emitters, and the whole .spx asset
  contract (RLE format, SPR_STAMP=2 — deliberately UNBUMPED so every
  committed sheet stays valid). The one behavioral change: the sheet
  texture registry buffer is rc.spr.tex (16 slots) instead of
  rc.ro.sprtex (render-class — excluded from traces/goldens by the rc.
  rule). `spx_path` already derives from the running project
  (`<project>/spr/sheet<slot>.spx`), so any cartridge gets its own
  committed sheet assets for free; rovale's three requires flip to
  cm.require("cm.spr").
- **Deliberately NOT here**: per-sheet cell sizes / bake cameras
  (varying them needs a per-sheet stamp scheme — a later cut when a
  second sheet SHAPE exists), paper-doll layers, palette dyes. The
  billboard/decal emitters stay in cm.spr rather than cm.gb: they are
  the sprite draw half (sheet fv/DIRS aware); a generic camera-facing
  quad joins cm.gb when a non-sprite user votes.
- **The trace was honestly re-cut** (the upstream cm.actor precedent):
  a trace SNAP's bundle references dependency modules by path when a
  restored parent requires them before their own bundle registration,
  so deleting projects/rovale/spr.lua broke the OLD trace's restore —
  a fact about bundle restore worth knowing, now recorded. The new
  rovale_tour.ctrace (1000f, same synthetic-click tour) verifies PASS,
  survives a deliberate drift probe, and re-verifies BYTE-IDENTICAL
  under _G.RO_BUDGET=32 (the §10-style honesty proof re-proven).

**Proof.** The four committed .spx sheets load through cm.spr with ZERO
rasterize lines and no rewrite (stamp/format byte-compatible: the
files' git status stays clean through a full boot), and both rovale
pixel goldens compare byte-identical on current sources under pinned
lavapipe. Full suite ALL GREEN. No visual change — no feed captures.

## D3D-030 — cm.walk: click-to-move pathing goes engine-side (2026-07-17)

The third §12 slice, the second D3D-026 human-logged candidate ("the
pick ray + walk-grid A* are engine-shaped"). Named cm.walk, NOT
cm.pick — upstream A5's picker list model owns that name (§12 ban).

- **engine/cm/walk.lua** is pure functions, extracted verbatim from
  rovale: K.cell / K.snap (ring search) / K.astar (heap A*, 8-dir, no
  corner cutting) over a caller grid (gw width + a walkable PREDICATE
  — what makes a cell walkable stays project policy: rovale's water
  depth/steepness/blocker/deck rules live on in world.lua),
  K.raycast (the click ray's march+bisect against any sim-legal
  ground function; the NDC ray construction stays with the camera
  model that owns it), and K.command/K.step over a caller-named
  WALKER buffer whose layout the module owns (the cm.rig precedent —
  ro.player's exact shape: pos/facing/dist-phase odometer/path
  chain/click marker). Facing octant-snaps only at sprite time, in
  the caller (cm.spr.oct).
- **Deliberately NOT here**: walkable-rules builders, screen->ray
  math, path smoothing/string-pulling, re-path on dynamic blockers,
  moving obstacles — later cuts on real demo pain (a monster chase
  is the likely first vote).

**Proof.** rovale retrofitted (world.lua −106 lines, player.lua's
command/step become delegations, pick() rides K.raycast): the re-cut
rovale_tour trace verifies PASS un-recut (no module file deleted this
time — the D3D-029 restore lesson respected), and both pixel goldens
compare byte-identical on current sources under pinned lavapipe — the
tour IS synthetic clicks through pick→snap→astar→follow, so the
pixels pin the whole extracted chain. Full suite ALL GREEN. No visual
change — no feed captures.

## D3D-031 — cm.atlas: the per-tile terrain bake goes engine-side (2026-07-17)

The fourth §12 slice, the third D3D-026 human-logged candidate ("the
terrain bake atlas — module + future editor button"). The RO signature
move — every terrain TILE gets its own gutter-padded cell in one big
texture, so the ground carries a unique blended texture per tile with
zero visible grid (the roBrowser/BrowEdit 258-slot trick). Named
cm.atlas; the runtime substrate for the terrain-paint/bake editor
window when the editor unparks.

- **engine/cm/atlas.lua** owns the engine-shaped half of rovale's bake,
  extracted verbatim (byte-identical math): the LAYOUT (cell + gutter →
  block, tile → atlas byte offset, and **A.uv**'s interior UV rect —
  the gutter inset the bake and the mesh emitter must agree on, the one
  seam they share), the **BUDGETED render-class bake loop** (A.bake
  runs K tiles/frame, uploads the atlas once on completion, returns the
  0..1 done fraction for the loading bar), the texture CONTENTS (create
  + fill + re-upload a finished bake instantly on reload), and
  A.done/A.rebake — all over the caller's named rc.* buffers (the pixel
  buffer + a two-u32 progress/stamp buffer). No module state; the
  handle is rebuilt each build() like cm.terr's terrain object.
- **The per-texel COLOUR stays project policy.** The caller passes
  `texel(wx,wz) → r,g,b` (0..255, cm.atlas clamps + packs); rovale's is
  its feathered grass/dirt/sand blend with prop shadows multiplied in +
  the underwater cool/darken, unchanged — just handed over. The
  cm.walk-`ok` / cm.terr-`sample_fn` precedent: a pure sample function
  passed to a pure function, never a stored callback.
- **The texture's LIFETIME stays the caller's** (cm.atlas creates and
  fills it, but rovale keeps it in its rc.ro.texids registry, freed
  with the rest on reload). This was FORCED, and it is the round's
  lesson. The first draft had cm.atlas own the free (a texid slot in
  its state buffer, the gb.load_textures shape) — which grew that
  buffer 8→16 bytes and BROKE the un-recut trace. Why: `--verify`
  double-inits. `cm.main.boot` inits the CURRENT sources (new
  world.build → cm.atlas makes rc.ro.bake@16), then `trace.verify`
  restores the SNAP bundle and inits AGAIN — and the bundle's OLD
  world.lua (D3D-029-era, carried un-recut through cm.walk) does a raw
  `pal.buf("rc.ro.bake", 8)` over that same name → size mismatch, boot
  error. cm.walk never resized a persistent buffer, so it never hit
  this. **Rule: an un-recut retrofit must not change the SIZE of any
  named buffer its stale bundle still creates** — the two generations
  coexist in one process during verify's double-init. Keeping the state
  buffer at its historical 8-byte shape (and the atlas back in the
  count-4 registry) made the whole retrofit byte-identical and the
  bundle replays clean.
- **Deliberately NOT here**: non-uniform / rectangle packing (this is a
  UNIFORM tile grid — sprite SHEETS are cm.spr's), splat-weight
  sampling, normal/AO/mip baking, the terrain MESH emission (the
  caller's emitter owns the vertex layout; A.uv is the shared seam).
  Later cuts from real editor pain.

**Proof.** rovale retrofitted (world.lua −25 lines net: bake_tile /
W.bake / the bake-state block → cm.atlas; a `texel` policy fn + A.uv
wired in). The bake is render-class so `--verify` never runs it → the
committed rovale_tour trace verifies **PASS UN-RECUT** (hermetic
bundle, no module deleted; the sim reads only heights/walk/decks,
untouched). Both pixel goldens compare **byte-identical** on current
sources under pinned lavapipe — and the terrain pixels ARE the atlas,
so they pin the extracted layout + loop + upload chain end to end; the
tour re-shot under _G.RO_BUDGET=32 is byte-identical to the committed
budget-8 golden (the §10 honesty proof: same atlas at any tiles/frame).
Full suite ALL GREEN. No visual change — no feed captures.

## D3D-032 — cm.kin: the shared collide+jump core of the three player kernels (2026-07-17)

§12 slice 5, the harder one flagged since the vote audit: the player
kernel exists as **three diverging copies with an agreed core**. bounce
(the bouncy cube), openworld and bigworld (the mascot) all grew their
`step()` from the same DNA — the D3D-009/010 swept AABB clamp, the D029
fixed-apex jump with coyote/buffer, mantle, the box-top landing raise,
the squash/stretch juice — then each grew its own divergence on top.
That agreed core is now **engine/cm/kin.lua**; the divergence stays in
the cartridges.

**The surface** (pure functions, the cm.walk model — values in, values
out, no module state, no buffers of its own): `approach`, `overlaps`,
`jump_curve` (→ g_rise, v0), `run` (accelerate toward the wish + turn
to the heading, or brake), `gravity` (the rise-slope / heavier-fall
D029 curve), `jump` (buffered press + coyote; the swim paddle-hop is a
`swim`/`paddle` hook so bounce passes `swim=false` and never runs it),
`slide` (one axis of the clamp), `mantle_top`, `ground_top`,
`land_squash`, `lean`. `DT` (60fps) and `EPS` (the D3D-010 epsilon)
are owned here; `K.EPS` is re-exported for the demos' own inline f32
side tests (bounce's mover carry + its per-box land/bonk).

**The clamp is the crown jewel** (`K.slide`). One axis at a time: the
face comes from the pre-move side `p0` (never the velocity sign —
D3D-009), every side test carries `EPS` (D3D-010), a squeezed pre-move
overlap clamps nothing. bounce's mantle interleaves, so `slide` takes
an optional `mantle(b, px, pz, cy)` probe (the cm.walk-`ok` precedent —
a pure fn passed per call, not a stored callback) that RAISES the
working feet `cy` instead of clamping; `cy` threads out of X into Z and
on to the vertical pass, exactly as the old inline `y = top` did. ow/bw
pass no probe (the mascot has no stair run). The collider SOURCE stays
the caller's: bounce merges level boxes + the movers' post-step boxes;
ow passes `{world.colliders}` then `{dyncol}`; bw calls
`world.boxes_near(x,z)` once and shares it across both sweeps and the
ground-top raise. Same iteration order as the old `GROUPS` loops → same
bytes.

**Value-based on purpose** (and it dodges the D3D-031 trap). The three
player buffers DIVERGE — bounce.player 52B, ow.player 56B (+phase),
bw.player 60B (+phase+glide) — so no single owned layout fits (unlike
cm.rig's 40B cam or cm.walk's walker). And because cm.kin never touches
a buffer, it can never resize a PERSISTENT sim buffer, which is exactly
what D3D-031 warns breaks verify's double-init. The retrofit changed no
buffer size and no doc shape, so the traces stay **un-recut**.

**Deliberately NOT here** (divergence / project policy; a later cut
earns it from real pain): the swim regime (buoyancy spring, paddle hop,
entry splash — only the paddle is a hook), the glider (bigworld's §8e
stress instrument), the **vertical assembly** (bounce lands AND bonks
per box in an axis-aligned world; ow/bw integrate against a heightfield
with the k.snap downhill glue — cm.kin hands over slide/ground_top/
mantle_top/land_squash and the demo composes its own ground truth), the
mover carry, the kill-plane respawn, the walk-cycle odometer, and
emit()/the blob shadow (render-class). The camera-relative wish is
cm.rig's / main's.

**Proof — byte-identical, so goldens un-recut (the strongest form),
upgraded to whole-trajectory frame identity.**
- Full suite **ALL GREEN**: the 17 pixel goldens compare byte-identical
  on CURRENT sources under pinned lavapipe (D3D-028's "real proof" —
  bounce_tour is 1920 autoplay frames of the new `step()`, openworld
  1290, bigworld glide 600, plus demo/lap/soft/npc/meet/stars/swim);
  the 10 player traces verify **PASS UN-RECUT** (no buffer resized, no
  doc shape moved → boot's init and the bundle's re-init agree, so the
  double-init stays clean).
- **Whole-trajectory sim byte-identity** (stronger than single-frame
  pixels): re-recorded each demo's tour with the new code AND with the
  committed code (`git stash`), then parsed the CTRC chunk streams —
  `<tag><u32 ver><u32 len><payload>`. EVERY per-frame `FRAM` chunk (plus
  `HEAD`/`EVAL`/`KEYF`/`TAIL`) is byte-identical across all three; the
  ONLY difference is the `SNAP` chunk, which embeds the loaded source
  bundle (`cm.modules()`) and so changed with the source by
  construction. Same chunk count, same bytes, every frame — the mover
  carry, mantle, box-top/bonk, kill-plane (bounce), swim + heightfield +
  dyncol (openworld), and the glider + chunk streams (bigworld) all
  reproduce exactly. (Lesson: a raw `cmp` of two traces is confounded by
  the SNAP bundle — compare FRAM chunks, or use `--verify` / pixels.)

Net −213 lines across the three demos; the triplicated core is one
source of truth now.

## D3D-033 — the NPC greet slice DEFERS to the re-merge (2026-07-17)

§12 slice 5's other half, designed against all three copies (openworld
`npc.lua` — the pond watcher + meadow wanderer; rovale `npc.lua` — the
three ambling greeters; bigworld `ents.lua` — the near-entity kernel of
a ~4000-strong closed-form population) and then **deferred** (human
call, 2026-07-17). This is a legitimate §12 outcome — the worked
precedent is upstream's D096 transition slice: a candidate that, on
audit, finds no *agreed* form to absorb defers rather than inventing one
the re-merge would unwind.

**The audit.** All three share the exchange GRAMMAR — a proximity greet
with `greet_r`/`exit_r` hysteresis, a facing ease, a typed line, a hold
— but diverge in every concrete axis:

| axis | openworld/npc | rovale/npc | bigworld/ents |
|---|---|---|---|
| "greeting" encoded as | `gstart > gend` (two frame+1 edges) | a `u32` greet-start flag ≠ 0 | a `mode` enum (0 far/1 armed/2 greeted) + `since < hold` |
| hold policy | watcher holds till exit; wanderer holds `k.hold` then walks on | holds till exit (no timeout) | holds `k.hold` then resumes, re-arms past `exit_r` |
| movement | explicit waypoint route + the D3D-024 stop_r wait | explicit waypoint route | CLOSED-FORM circular route, `phase_off` absorbs the pause |
| render | figure clip-blend (walk↔wave off the greet edges) | SPRITE-SHEET rows (baked wave frames) | figure clip-blend |
| dialog | typed HUD line | typed HUD line | none (mass entities don't speak) |

The hysteresis state machine — the part that *feels* most duplicated —
has three genuinely incompatible encodings tied to three different
persistent buffer layouts (`ow.npc` 36B, `ro.npc<i>` 32B, `bw.ents`
48B/slot + `bw.near`); there is no common pure form to lift without
forcing an encoding on all three. What IS mechanically identical is thin
peripheral pure-math: the facing ease `fmod(yaw + shortarc·turn, tau)`
(3 copies), the wave-clip-blend edge weights `wb/vb/wavephase` off
`blend_f`/`wave_f` (2 copies — openworld+bigworld; rovale picks sprite
rows instead), and the dialog typing `min(#line, since // type_f)` (2
copies). A `cm.greet` of only those primitives would NOT contain the
greet's actual logic — a weak slice.

**Why defer, not build.** The greet's heart is entity-list management —
stable ids, per-actor timers, the promote/demote lifecycle — which is
exactly what upstream **cm.actor** (A5: "stable ids/tags/timers — our
NPC lists") is positioned to host. §12's standing rule: *don't build 3D
twins of dimension-agnostic slices; keep the demo copies as merge bait
and retrofit onto the upstream module at re-merge, rather than onto a
fork invention we would then unwind.* The greet exchange is
dimension-agnostic (proximity, hysteresis, typed line, facing ease all
read identically in 2D), so the three copies stay as-is until cm.actor
lands, then retrofit onto it. (Contrast cm.kin, D3D-032: the player
collide+jump core has NO upstream twin in the A5 list, so building it
was safe — the precise distinction §12 draws.)

**Deliberately NOT extracted now** (revisit at re-merge): the greet
hysteresis/timer state machine, the hold policies, the three movement
models, the wave render (figure clip-blend vs sprite rows), the typed
dialog, the D3D-024 solidity boxes. If any of the thin pure-math
primitives (facing ease especially, used 3×+) later hurts a *fourth*
user, it earns a home then — likely a `cm.math`/`cm.fig` helper rather
than a `cm.greet` module.

No code changed this packet — an audit + a logged decision. With cm.kin
built and the greet deferred, the §12 distillation slice roadmap is
complete pending the human's editor unpark (the parked terrain-paint /
figure-vertex / sheet-preview windows, whose runtime substrate — cm.rig
/ spr / walk / atlas / kin — now all stands).
