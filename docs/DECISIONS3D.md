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
