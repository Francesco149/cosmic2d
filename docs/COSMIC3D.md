# cosmic3d — scoping & design (draft 0)

2026-07-16. Scoping session for a 3D sibling of cosmic2d targeting two aesthetics:
**N64-era 3D** and **Ragnarok-Online-style 2.5D** (3D tile terrain + billboard
sprites). Backed by four research passes (see `docs/research-3d/`) and a working prototype
(`proto/` — a software rasterizer AND an SDL_GPU retro pipeline rendering identical
scenes; screenshots in `proto/out/`).

The one-paragraph verdict: **fork, don't extend** — a sibling repo with the same
PAL+Lua architecture, determinism model, editor grammar, and asset citizen, whose
PAL grows one fixed retro-3D triangle pipeline (GPU, SDL_GPU, additive next to the
quad pipeline) plus a handful of primitives. The two aesthetics share one renderer
recipe with different *policy defaults*. Maps are a GND/WC3-synthesis heightfield
tile asset — brushes over arrays, no modeling. Characters are rigid-part "figure"
assets (the actual SM64 technique: ~17 rigid segments, no skinning, texture-swap
faces) — posed and keyframed in the editor with the existing manipulation grammar,
and bakeable to 8-direction sprite sheets for the RO mode.

---

## 1. Fork vs extend

Recommendation: **new sibling repo (`cosmic3d`)**, not a mode of cosmic2d.

- cosmic2d's ALPHA.md explicitly scopes 3D out of the alpha, and the PAL stability
  contract wants to freeze at 1.0 — landing a 3D pipeline mid-alpha-gate fights the
  other agent's release work.
- The editor shell, cm.* engine modules (state, trace, chunk, input, repl, ui, snd,
  words, ed.kit), and the PAL are designed to transplant. The genuinely new things —
  3D pipeline, terrain asset, figure asset, 3D scene window — are additive modules
  in the same shapes (a new asset kind is "one module + a roster line").
- The PAL question (share one binary vs fork) can stay open: the 3D primitives are
  additive `pal.x_*` entries, so a shared PAL is *possible* under the additive rule.
  Pragmatically, forking the PAL now and re-merging post-cosmic2d-1.0 avoids
  coordination cost while both evolve. **Human call.**

What transplants wholesale (see docs/research-3d/cosmic2d-transplant.md): the two-layer
architecture, named buffers + doc tree + traces/goldens, the ALT/CTRL manipulation
grammar with its gesture thresholds, the three-layer asset citizen with journals,
auto-naming, the three-target composite + integer-scale presentation, the LUT/grade
pass, the audio stack, the containment/parachute model — i.e., almost everything
except "what is a map" and "what is a character".

## 2. Renderer: GPU pipeline, software as reference

Both were prototyped against identical scene dumps (`proto/gpu_proto.c` renders the
same lit world-space triangles as `proto/r3d.c`; outputs match visually on lavapipe).

| | software rasterizer | SDL_GPU retro pipeline |
|---|---|---|
| look | exact control (3-point, dither) | identical (proven; filtering done in frag shader) |
| perf | 5.9 ms/frame @ 480×270, ~2k tris, 1 thread, -O2 | negligible per-frame; scales to RO map sizes, higher res, overdraw |
| determinism | bit-exact pixels everywhere; could be a versioned PAL kernel | pixels pinned via lavapipe goldens — already cosmic2d's model (sim never reads pixels) |
| integration | new large C kernel + readback path | **additive**: gfx.c's make_pipeline factory + depth target + matrix uniform; ~300 lines host + 2 tiny shaders in the prototype |
| risk | perf ceiling: big RO maps, higher internal res, fill-rate/overdraw | driver variance in subpixel edges (already accepted for 2D quads, rule 5) |

**Recommendation: GPU.** The prototype shows the retro look survives the GPU path
intact (3-point filtering, per-vertex lighting, fog, cutout billboards, blended
decals, sky gradient — all identical), integration is the same shape as the existing
quad pipeline, and it removes the perf ceiling for exactly the aesthetic that needs
scale (RO maps). The software rasterizer stays valuable as (a) the reference
implementation that defines intended pixels, (b) a possible future backend for
exotic ports. Keep it in-repo as a test tool.

### The retro pipeline (PAL mechanism, frozen-shape candidate)

One new pipeline + primitives, all `x_` experimental initially:

- vertex: `pos f32x3, uv f32x2, col unorm8x4` (24 B) — same batching model as quads
  (CPU-side scratch, segments keyed by texture/state, one upload).
- `pal.x_view3d(mat4 mvp, fog_start, fog_end, fog_r,g,b, fog_on)` — sets the 3D
  camera + fog for subsequent 3D segments. *Lighting is NOT in the PAL*: vertex
  colors arrive pre-lit (policy in Lua/kernels — sun/ambient/vertex-AO are engine
  policy, exactly like the prototype).
- `pal.x_tris(tex, buf, count)` — bulk triangles from a named buffer (the
  `draw_quads` sibling; the numpy model: Lua or kernels fill vertex buffers).
- per-segment state: filter (`nearest` | `threepoint`), alpha-test on/off,
  blend+no-depth-write (decals), depth test/write defaults on.
- fragment shader (fixed, committed SPIR-V): manual 3-point/nearest via texelFetch,
  alpha test, fog mix — the prototype's `retro.frag` is the working draft.
- present path unchanged: 3D renders into the same internal target (project-config
  resolution, e.g. 320×240 or 480×270), integer-upscaled; grade pass grows the
  **dither/quantize-5551** option (prototype does Bayer-4×4 + 5-bit; on GPU this
  belongs in the grade shader) and later the real LUT.
- PS1 mode extras (cheap, optional): a `noperspective` shader variant for affine
  warp; vertex snapping is CPU-side policy (snap positions before submit). N64 mode
  needs neither (research: N64 = perspective-correct + z-buffer; the recipe is
  *subtracting* PS1 artifacts).

Sim/render split is unchanged: draw is render-class; the sim owns terrain buffers,
entity state, animation frames. Headless + goldens work exactly like cosmic2d
(lavapipe pinned).

## 3. The two aesthetic presets (policy, not engine forks)

**N64 preset** (validated in `proto/out/n64.png`): 320×240-ish internal, 3-point
filtering, per-vertex sun+ambient, painted vertex AO/shadow ("vertex shading" is
what era artists call the single most important element), fog with matched sky
gradient, 5551+dither grade, chunky props, rigid-part characters, 250–800 tris/
character, 32–64 px textures, bright saturated palette.

**RO preset** (validated in `proto/out/ro.png`): 480×270 internal (or higher),
camera = perspective with **~15° vertical FOV** pitched 50–70°, free yaw, stepped
zoom — near-orthographic look with perspective life; heightfield tile terrain with
implicit cliff walls; billboard sprite characters (nearest + alpha-test ALWAYS for
sprites — filtering smears pixel art), blob-shadow decals, sprites tinted by ground
light at the feet; baked 8×8-per-tile lightmaps later (the posterized soft shadows
are half of RO's charm).

What makes it "intentional artstyle, not bad graphics" — engine-enforced consistency
(this is the batteries-included differentiator; docs/research-3d/n64-aesthetic.md §3):
- one filtering rule per material class (3-point world / nearest sprites), never
  system bilinear;
- texel-density guardrails: the terrain is ~32 px/tile by construction; the texture
  windows default to 32/64 px canvases with the palette designer's ramps;
- unlit-by-default materials (texture × vertex color), no "modern" lighting to
  accidentally leave on;
- palette discipline via the existing .pal designer + LUT grade;
- stepped low-rate keyframes as the *default* animation interpolation (a stylization
  choice modern indies proved out — Pseudoregalia).

## 4. The map model (author worlds without Blender)

A `.terr` asset (working name) — the GND/WC3 synthesis, all brushes over arrays:

- **tile grid, per-corner heights** (f32 ×4) + per-tile top texture id + UV
  rot/flip. Two triangles per tile; smooth slopes come from shared corners,
  sharp cliffs from unshared ones.
- **implicit walls**: any height discontinuity between neighbors generates the wall
  quad automatically, textured by the map's **cliff material** (auto-UV by wall
  height), per-wall override possible. Cliffs "just happen" (RO), no wall authoring.
- **WC3-style edit verbs** (the whole editor tool set):
  raise/lower vertex or region (plain drag = smooth, **CTRL = snap to level
  steps** — the existing CTRL grammar gives WC3's cliff-levels for free),
  flatten, smooth, ramp (connect two levels across a tile span),
  texture brush with **auto-blend** at boundaries (16 corner-share patterns per
  texture pair — kills the harsh staircase edges visible in the prototype path),
  water level per region.
- **walk grid**: 2× subdivision of the render grid (GAT-style), per-cell flags
  (walkable / blocked / water / cliff-but-shootable), heights derived from render
  grid + manual patches. The sim reads ONLY this + collider volumes — same
  colliders-are-the-sim-truth split as cosmic2d maps.
- **placements**: props (meshes, figures, billboards, lights-for-baking, markers)
  as freehand placements with optional attached collision/walk patches — walkable
  props are the bridge/overhang answer (WC3's answer; RO shipped an MMO for 20
  years without overhangs). Stacked terrain layers with portal cells are the
  later cave/multi-story extension if ever needed.
- **baked lighting**: per-tile 8×8 lightmap bake (sun + placed point lights),
  posterized; sprites sample it at their feet. Editor button, zero runtime cost,
  huge charm payoff.
- performance: a 200×200-tile map ≈ 80k tris worst case unculled — trivial for the
  GPU path with chunked visibility (RO's own maps are this size).

The terrain window is a `map`-window sibling: own camera (orbit/pan/zoom on the
same wheel ladder), focus view-lock, journal/undo-forever, tools = select / height /
texture / walk / placements — every edit a repl submission so terrain editing
records and replays like everything else.

## 5. The character model (the hard part)

**The `figure` asset: rigid-part hierarchy — the literal SM64 technique.**
No skinning, no rigging, no weight painting, ever (that's the refusal that keeps
this from becoming Blender). Validated in `proto/out/chars.png` + both scenes:

- a figure = a small tree of **parts** (name, parent, joint offset, mesh, color
  or texture region); a part's mesh is a parametric primitive (box, rounded box,
  cylinder-ish prism, wedge) with per-part scale — or, later, a picoCAD-class
  vertex-pushed hull edited with the same grab/drag/CTRL-snap verbs. Era-accurate:
  Mario is ~17 rigid segments, mostly untextured vertex color; joint gaps are hidden
  by overlapping segment ends (the prototype's limbs overlap upward past their
  joints for exactly this).
- **faces are texture swaps**: a face strip (eyes/mouth frames — 32×32-class, drawn
  in the existing sprite editor) mapped onto the head part; blink/expressions =
  frame index, the OoT/SM64 mechanism. Personality lives in proportions (big head),
  palette, and the face strip — all sprite-editor-native skills, no sculpting.
- **animation = per-joint euler keyframes** at low rates, lerp or stepped; root
  translation only. The prototype's 4-key walk is ~10 numbers and reads instantly.
  The anim window is the existing clip-rail model (clips = named {key: pose}
  sequences with loop modes); posing = drag part rotations directly in the viewport
  with the universal grammar (drag rotates around the dominant axis, CTRL snaps to
  15° steps), keys on a rail.
- **the sprite bake**: any figure renders to an 8-direction × N-frame sprite sheet
  (one button; low-res, nearest) → RO-mode characters, portraits, and zero-license
  sprite content generated from the engine's own assets. This closes the loop:
  model once, use as 3D (N64 mode) or billboard (RO mode).
- RO-style layered paper-doll sprites (separate head/body sheets with anchor
  points, palette swaps) are a natural later extension of the same billboard
  renderer; the SPR/ACT anchor mechanism is documented in docs/research-3d/ro-2.5d.md.

Escape hatch for imported content: a minimal OBJ (+PNG) importer for static props
covers the CC0 packs (Kenney/KayKit ship OBJ). Imported *animated* characters
(glTF skinning) are explicitly out of scope — figures are the native path.

## 6. Demo assets (verified licenses; see docs/research-3d/assets-cc0.md)

Bundlable, all CC0 verified on-page: **Kenney** (Nature/Castle/Dungeon kits, OBJ),
**Quaternius** (animated character packs — as *source material* for figures/sprites),
**KayKit** (Dungeon Remastered + Adventurers free tier), **Screaming Brain Studios**
(Tiny Texture Packs, 128 px seamless — downscale to 64), **Elegant Crow** PSX trees
(FBX only — needs conversion), OGA "Hand-Drawn Square Characters" 8-direction CC0
sheet. Flagged non-bundlable: Pizza Doggy PSX Mega Pack (custom license),
Elbolilloduro (CC0 models, non-redistributable textures), LPC (share-alike), most
paid itch packs. The strongest zero-risk sprite path: bake our own sheets from
figures or from Quaternius models.

**Staged** (230MB in `assets/`, every pack with a LICENSE-NOTE.txt, archives and
FBX/blend duplicates deleted): kenney-nature-kit (329 OBJ+GLB, flat colors, plus
pre-rendered sprite PNGs), kenney-castle-kit + kenney-graveyard-kit (shared 512²
colormap atlases), quaternius-ultimate-animated-character (52 self-contained
animated glTF), quaternius-ultimate-nature (150 OBJ), sbs-textures (410 seamless
128/256px tiles incl. dirt/stone/water), kaykit-dungeon (203 GLB + 417 OBJ, 1024²
atlas), kaykit-adventurers (rigged GLB + per-char textures), oga-sprites (257
frame PNGs, 4 characters × 8 directions). KayKit dungeon OBJs already render in
the prototype (`proto/out/dungeon.png`).

## 7. Prototype (what exists in `proto/`)

- `r3d.{h,c}` — deterministic software rasterizer: perspective-correct + affine
  modes, z-buffer, near-plane clipping, nearest/3-point/bilinear sampling,
  per-vertex sun lighting, fog, alpha-test cutouts, blended decals, Bayer-4×4 +
  RGBA5551 quantize, integer upscale, PNG out, scene-capture hook.
- `main.c` — procedural 64×64 "hand-painted" textures (grass/dirt/cliff/brick/
  water), the per-corner-height terrain with implicit cliff walls + border skirt +
  vertex AO + editing primitives (raise vertex / flatten / paint), the 7-part rigid
  figure with 4-key walk + face + hair, **the figure→sprite baker** (renders the
  figure at any yaw/pose into a cutout sprite — the RO scene's billboards ARE baked
  figures), billboard sprites + blob shadows, an OBJ loader (KayKit assets proven),
  six scenes (`filters`, `chars`, `n64`, `ps1`, `ro`, `dungeon`), `--dump` scene
  capture, `bench`.
- `gpu_proto.c` + `retro.{vert,frag}` — the SDL_GPU path (headless, lavapipe),
  rendering the captured scenes through the fixed retro pipeline. Built with
  cosmic2d's devshell; mirrors gfx.c patterns.
- `out/*.png` — the evidence. `n64.png`/`ro.png` (software) vs
  `n64_gpu.png`/`ro_gpu.png` (GPU): same look.
- bench: 5.9 ms/frame software @ 480×270; GPU per-frame negligible.

Build: `nix shell nixpkgs#gcc -c gcc -O2 -std=gnu11 -w -o proto r3d.c main.c -lm`;
GPU: `nix develop /opt/src/cosmic3d -c bash -c 'glslangValidator -V retro.vert -o
retro.vert.spv && … gcc … gpu_proto.c r3d.c $(pkg-config --cflags --libs sdl3)'`,
run with `VK_DRIVER_FILES=$COSMIC_LVP_ICD`.

## 8. Decisions from the human (2026-07-16)

1. **Fork now**, figure out ergonomics, merge later.
2. **Demo roadmap**:
   - **Demo 1 — N64 platformer, bouncy-cube protagonist**: the 3D version of
     cosmic2d's 2D platformer demo. Focus: satisfying movement + level
     aesthetic. (Prototyped: `proto/out/graybox.png` — the cube with a face +
     squash & stretch has instant personality with zero modeling.)
   - **Demo 2 — Zelda-ish open world**: exploration feel; the character
     modeling + animation showcase (figures).
   - **Demo 3 — RO-style**: must *feel* like RO — anime/RPGMaker-style sprites
     via found packs or a customization tool. Research verdict
     (docs/research-3d/anime-sprites.md): RPG Maker generator output and Game Character
     Hub are license-locked to RPG Maker products — ruled out; every
     style-correct pack (Pipoya etc.) forbids redistribution; the bundleable
     pick is **Kushnariova's 24×32 anime-chibi pack (CC-BY, 4-dir)**; the
     strategic answer is an in-engine **paper-doll sprite system cloning RO's
     own architecture** (separate head/body layers with per-frame anchors,
     palette-swap dyes, 8 dirs with mirroring, ≤8 walk frames) fed by a
     license-clean house set rendered via **VRoid Studio** (pixiv guidelines
     explicitly allow using 2D renders of your models in games/material
     collections → our renders can ship CC0) and/or the figure→sprite baker.
3. **Figure editor: vertex pushing from day one** (picoCAD-class, not just
   parametric primitives). Mario-style eyes/personality on characters is a
   first-class problem: face texture strips + the eye/brow/mouth idiom from the
   bouncy cube.
4. **Composition over blending**: prioritize a shape vocabulary that escapes
   axis-aligned boxes (RO's diagonal + curved structures). Prototyped as the
   **graybox language**: material-checkers (checkerboards flavored as
   grass/stone/wood/dirt/metal/accent — style-neutral but N64-feeling) over
   prisms/lathes/arc-bridges/rotated slabs with uv-scaled texel density.
   CC0 packs remain reference/base material for neutral demo content.
   Terrain texture auto-blend: deprioritized.
5. **Soft look adopted as the default** (human-confirmed on the graybox shot):
   VI-style bilinear upscale + mild horizontal smear is the N64 preset's default
   presentation; sharp integer pixels stay selectable. PS1 preset stays a cheap
   optional toggle. In the real engine this lives in the present/blit stage
   (bilinear blit + smear pass or shader), not in the internal render.

## 8b. Mascot + RO-composition round (2026-07-16, later)

- **Mascot ("stock 3D character that isn't a Minecraft person")**: prototyped in
  `proto/out/mascot.png` — no boxes in the silhouette: lathe teardrop body,
  **Rayman-style floating mitten hands/boots** (eliminates joint gaps AND makes
  animation trivial — hands/feet are just positioned spheres), belly patch, big
  white eyes, antenna star (the "cosmic" hook), squash & stretch. Pupil study
  (`out/mascoteyes.png`): human picked **style B — bigger + rounder pupils** as
  the default; the glint variants (C/D) stay available for later tweaking.
- **RO composition v2** (`out/rochibi.png`): human feedback applied — sprites
  scaled to 3.0 world units and big round lathe-canopy trees (both against a
  raised terrain), plus composition beyond minecraft-flat: two-level plateau
  with ramps, octagonal tower + cone roof landmark, diagonal river with a
  wooden arc bridge at the path crossing, camera yawed ~30° so the tile grid
  never sits screen-parallel. Kushnariova CC-BY chibi sprites (color-keyed
  RMXP sheets) verified as the bundleable demo-3 direction.

## 8c. RO blended-terrain round (2026-07-16, from real RO reference shots)

The user supplied two RO screenshots (beach + forest gazebo); the gap analysis
vs the tile scene and what closed it (`proto/out/ro2.png`, scene `ro2`):

- **Baked blended tile textures**: each terrain tile gets a UNIQUE 32×32 texture
  baked by sampling materials (grass/dirt/sand/stone) in **continuous world
  space** and mixing by weight functions whose *inputs* are noise-perturbed —
  ragged organic borders, zero visible tile grid, no seams. This is the map
  bake step the editor would run (and what "texture blending" means for us —
  note real RO uses hand-painted transition tiles, no runtime blending; baking
  achieves the same read automatically).
- **Smooth heightmap + water as a level plane**: the pond shoreline is the
  height contour where ground dips under the water plane — organic shape for
  free. Basins/knolls sculpted as smooth blends (gaussian falloff), plazas
  flattened.
- **Baked shadow pockets**: prop positions are known before the bake; tree/bush
  canopies multiply a soft shadow into the tile textures (max ~58% darkening).
  This is the poor man's 8×8 lightmap and carries the reference's lush look.
- **Diagonal structures**: the gazebo (stone deck + posts + shingle pyramid
  roof) and its plaza are rotated ~31°; weight painting is done in the rotated
  frame so even the *material* border is diagonal.
- Engine implications: the terrain asset needs material-weight painting (splat
  brush) + a bake step producing per-tile textures (with prop shadows), water
  level per region, and props with world rotation. All brushes over arrays.
- **The authentic RO recipe** was extracted from roBrowser/BrowEdit3/Ragnarok
  ReBuild/RRL sources into docs/research-3d/ro-render-recipe.md — exact lightmap math
  (shadow multiplies light, posterized color channel adds after), water
  constants (opacity 144/255, 32-frame cycle, vertex wave, depth-write off,
  drawn after sprites), sprite rules (1px = 1/35 cell, unlit but tinted by
  ground shadow at feet with 30% swing, depth-pull toward camera so tall
  sprites don't clip terrain — the load-bearing billboard trick), fog
  smoothstep, and confirmation that RO never runtime-blends tile textures
  (hand-painted transitions; our bake is a deliberate improvement). The cheap
  wins are already applied to scene ro2 v4.
- **v5 refinements from human feedback**: material weights feather over
  smoothstep bands (~1–1.6 units) instead of binary thresholds — gradients,
  not splotches; the plaza pavement pattern bakes in the gazebo's rotated
  frame so structure and ground grids agree; corner-smoothed normals (RO's
  getSmoothNormal); **1-texel gutter on every baked tile** (the RO 258px-slot
  border trick) killing filter seams at tile boundaries; lobed domain-warped
  pond; RO-closeup camera (pitch ~40°, dist ~66). The openworld scene gained
  a BH-style neutral detail texture multiplied over its vertex colors.
- **v6 (final this round, human-approved direction)**: paved areas belong to
  *structures*, not the terrain bake — the plaza is a crisp thin slab prop
  aligned with the gazebo (the Prontera-square pattern), sitting on a
  circular uneven trampled-dirt blend. Design rule: ground materials blend;
  architecture is geometry with hard edges. Human verdict: the three demo
  looks (graybox platformer, openworld, RO) are visually sufficient.

## 8d. Mascot lock-in (2026-07-17)

Human verdict on the round-9 figure showcase (`projects/figure`, cm.fig
runtime): **"it looks good. the stylized design helps the bounce and
animations feel more natural"** — the stylized design (lathe teardrop body,
Rayman floating mitts/boots, antenna star, style-B eyes) is **locked in as
the engine mascot**. The figure runtime's animation read is approved with
it. Remaining round-9 feed questions (eye size at 320×240, keep the box guy
in the showcase) stay open, non-blocking.

## 9. Body Harvest techniques (from ../body-harvest decomp, see notes there)

An N64 open-world game whose whole huge terrain fits 4MB — directly relevant
to demo 2 (open world) and the terrain system:

- **Streaming heightmap ring buffer**: 256×256 tile world, only a 19×19 vertex
  window resident, scrolled one row/column at a time as the camera moves
  (recompute the new edge only). 6-bit heights. The pattern for big cosmic3d
  maps if/when whole-map-resident stops being enough.
- **Vertex-color-only terrain**: no terrain textures at all — a landscape
  palette bilinearly sampled into vertex colors + per-era tint tables + one
  sun vector. Swap the tables to reskin the world. A zero-texture terrain mode
  is a great graybox/stylized option and is nearly free in our pipeline
  (vertex colors already carry lighting/AO).
- **Pitch-dependent fog**: fog near/far recomputed from camera pitch — tight
  fog at the horizon when looking level, opened up when looking down. The
  draw-distance trick for open-world feel.
- Reference reading: `../body-harvest/notes/FACTS.md`,
  `decomp/src.us/overlay_gameplay/outside/BF9C0.c` (the terrain renderer),
  and `../slopstudio-projects/docs/research-3d/video-study/*lethal-company/STUDY.md`
  (cheap post-processing stack = distinctive look; low-res-and-upscale as an
  aesthetic).
