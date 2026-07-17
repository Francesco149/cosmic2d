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
