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

## 8e. Demo 2 sufficiency + the streaming-world direction (2026-07-17)

Human verdict after the round-15/16 NPC work: demo 2's open-world slice
is **"sufficient for now unless there's other things that might
translate to engine ergonomics that we haven't tried for this genre"**
— and the named candidate is exactly that: **streaming a HUGE world
with entities everywhere**, plus the logic to efficiently update (or
not update) entities far from the player. If that needs engine
ergonomics we don't have, we try it. Prerequisite named by the human:
**a fast-travel method (a glider) to stress-test streaming speed**.
Direction accepted — demo 2 pivots from content rounds to the
streaming/entity-scale stress demo; the Body Harvest notes (§9) and
cm.terr are the starting points. Open engine questions it will force:
chunked terrain generation/paging under determinism (named buffers per
chunk?), entity LOD/update scheduling as a sim-legal pattern (no
hash-order iteration), collider set swapping, and whether golden
traces can span chunk boundaries.

## 8f. Streaming verdict + the RO-demo pivot (2026-07-17)

Human on round 17: **"the open world demo you made last time feels
great"** — the streaming world + glider land. Direction: **move onto the
Ragnarok-style demo (demo 3) now**, and after it, **"distil the 3 demos
into the necessary engine ergonomics to accommodate these types of 3d
games without the user hand rolling everything"** — the distillation
phase (editor primitives + engine modules) begins when demo 3's slice
is feel-approved. Demo 3's design is sketched in §11.

**Playtest verdict on the round-18 build (2026-07-17, human): "exactly
the vibe we would want"** — with four fixes, all landed same-day
(permanent .spx sprite assets, the apron corner z-fight, fully
camera-facing billboards, edge-only click sfx; see STATUS + D3D-026).

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

## 10. The streaming world — sketch + measurements (2026-07-17, round 17)

The §8e directive engineered: stream a huge world with entities everywhere,
stress-tested by a glider. Sketched BEFORE code, on top of a headless
measurement soak (below). New cartridge: **projects/bigworld** (openworld
and its goldens stay frozen as the content demo).

### The decisive move: ground is a pure function; chunks are render-class

The PAL re-uploads every submitted 3D vertex every frame (`x_tris` memcpys
into one accumulator; there is no retained GPU geometry). So "streaming"
splits cleanly into two problems, and neither is sim state:

1. **The sim never needs chunks.** bigworld's height at any world lattice
   vertex is a PURE FUNCTION `hfn(seed, vx, vz)` (the openworld fbm shape,
   world-coordinate vnoise — no stored grid). `T.sample` generalizes to a
   function-backed variant: compute the tile's 3 corner lattice heights on
   demand (~3 µs, measured) and interpolate triangle-exact as today. The
   player, every entity, and every trace can stand ANYWHERE in a world of
   any size with zero resident terrain state. Consequences:
   - No per-chunk named sim buffers; snapshots/traces carry nothing
     terrain-ish. **A golden trace spans chunk boundaries trivially** —
     the §8e question dissolves: traces pin player/entity buffers only,
     and chunk paging is pinned by pixel goldens instead.
   - The honesty test writes itself: replay the same trace under a
     DIFFERENT chunk radius / gen budget (render knobs) — byte-identical,
     because the sim never sees chunks.
2. **Chunks exist only as render-class buffers.** Chunk = 16×16 tiles
   (32 u square, 512 terrain tris, ~1 ms to generate — measured). Resident
   ring around the camera in `rc.bw.c<x>_<z>` named buffers (rc. is
   snapshot-excluded), generated under a per-frame budget (1–2 chunks/frame
   keeps 60 fps while gliding), evicted past the radius (buffer churn
   measured free). Per-frame submit = distance-culled resident set; at
   fog_end ≈ 110 u that is ~9×9 chunks ≈ 40 k tris ≈ 2–5 ms on lavapipe
   (measured) — inside budget, laughable on real GPUs. Prop scatter is
   per-chunk deterministic (world-seed + chunk-coord streams, the D3D-022
   draw-before-accept rule), so a chunk regenerates byte-identically on
   every visit; props whose AABBs must collide are derived from the same
   pure streams ON DEMAND by the sim (chunk-local collider query), not
   stored.

### Entities at scale: promote/demote, one buffer, closed-form far state

Finite-huge world (first target: 512×512 tiles = 1024 u square — 64×64
chunks) with **N ≈ 4000 entities in ONE named sim buffer** (fixed slots,
32–48 B: ~128–192 KB — snapshot-friendly; the openworld npc-list pattern
does NOT scale to thousands of per-entity module tables). Placement at
init from world-seed streams (deterministic).

- **Far entities are (route, phase), nothing else.** A far entity's
  position is a closed-form function of its fixed route and a phase
  field — advancing it k frames is `phase += rate * k`, O(1) and EXACT.
  So far entities need no per-frame update at all: "update-or-don't"
  collapses to don't, with a closed-form catch-up whenever someone looks.
  Trajectories are identical regardless of schedule — determinism cannot
  depend on scheduling, by construction (no hash order anywhere).
- **Near entities get promoted** (deterministic distance test + hysteresis
  against the player, sim state only): a promoted slot runs the full
  interactive kernel — ground glue, walk clip, solidity, greets (the
  D3D-020/023/024 machinery, capped to the handful of near slots).
  Demotion re-anchors phase to the nearest route point. Interaction radii
  all sit far inside the promote radius, so far entities never interact.
- **The full-population distance scan measured 0.47 ms at 4 k** (0.66
  µs/slot with f32 reads) — affordable every frame at this scale; chunk
  bucketing is the known upgrade if entity counts go 16 k+ (scan measured
  1.9 ms there).
- Draw: only near/mid entities emit figures; far ones cull at fog (or a
  cheap prism LOD if the read wants density).

### The glider (the stress instrument)

Deploy while airborne (hold jump), fast lateral (~25–30 u/s, 4–5× run),
slow fall (~2 u/s), banked visual. One new player-buffer field (deployed
flag); otherwise a movement regime like swim (D3D-019). Crossing a chunk
row per second loads ~9–11 chunks ≈ 11 ms amortized over 60 frames —
the gen budget holds; pop-in hides behind fog + a prefetch ring.

### Measured budgets (headless lavapipe, 4-core WSL2 box, SHARED and noisy
— treat as ballparks; quiet-window medians)

| what | cost |
|---|---|
| pure ground sample (worst-case 4 lattice corners) | ~3.7 µs/call |
| chunk gen 16×16 tiles (512 tris, 36 KB) | ~1.0 ms |
| chunk gen 32×32 tiles (2048 tris, 144 KB) | ~3.7 ms |
| chunk gen 64×64 tiles (8192 tris, 576 KB) | ~15 ms |
| entity slot update (read+trig+write, one big buffer) | ~0.66 µs/slot |
| distance scan, 16 k slots | ~1.9 ms |
| named-buffer churn (create+set+free 147 KB) | ~0.01 ms |
| x_tris submit+present, 8 k tris | ~0.1 ms med |
| x_tris submit+present, 33 k tris | ~1.5 ms med |
| x_tris submit+present, 66 k tris | ~2.8 ms med |
| x_tris submit+present, 131 k tris | ~13 ms med |
| x_tris submit+present, 262 k tris | ~45 ms med (19 MB/frame upload) |

PAL verdict: **no PAL changes needed for round 1** — named buffers have no
count ceiling (linked list), churn is free, and the real ceiling is the
per-frame re-upload (keep the submitted set ≤ ~50 k tris on lavapipe).
The candidate engine-ergonomics finding this demo exists to prove or
refute: a retained-GPU-geometry PAL API (upload a chunk once, draw by
handle). Deferred until the demo shows the submit cost biting on a real
scene — measure in-demo first.

## 11. The RO demo — sketch + measurements (2026-07-17, round 18)

The §8f pivot engineered. New cartridge: **projects/rovale** — a small
RO-style vale (the proto scene ro2 look: docs/research-3d/
ro-render-recipe.md holds the authentic constants). "Must FEEL like RO"
decomposes into five reads: the camera (15° FOV, steep pitch, free yaw,
stepped zoom), click-to-move on a walk grid, chibi billboard sprites
tinted by baked ground shadow, blended organic terrain with zero tile
grid, and the milky water plane. Sketched before code on a headless
soak (scratch, this box, quiet-window numbers):

| what | cost |
|---|---|
| terrain bake (weights+materials+shadow, Lua) | ~4.8 µs/texel |
| full 32×32-tile map @ 34×34 texels/tile | ~5.7 s |
| atlas assembly (4.7 MB string ops) | ~16 ms |
| `tex_create` 1088×1088 | ~6 ms |
| heap A* on 64×64 walk cells, cross-map worst case | ~2.9 ms/path |
| click ray-march vs T.sample (300 steps + 16 bisect) | ~60 µs |

### Terrain: the ro2 bake as a budgeted render-class pass

Map = one resident cm.terr grid, 32×32 tiles at tile 2.0 (the proto ro2
size — 64 u square; RO maps are villages, not open worlds). Heights,
material weights, prop scatter all deterministic Lua data (the openworld
build_data pattern: fbm + domain-warped pond lobes + plaza flatten).

The signature move is the **per-tile baked blended texture** (§8c): a
UNIQUE 34×34 texel tile (32 + 1-texel gutter each side, the RO 258-slot
trick) sampling materials in continuous world space, weights feathered
over noisy smoothstep bands, prop shadows multiplied in on the authentic
8×8-per-tile lightmap lattice. All tiles pack into ONE 1088×1088 atlas
texture (one segment, one draw). At ~5.7 s the full bake cannot run
synchronously in init: it runs as a **budgeted in-draw pass** (N tiles/
frame knob, bigworld's paging precedent) into the atlas via tex_update,
behind a small LOADING read. It is pure render-class policy: the SIM
reads only T.sample heights + the walk grid — a trace replays
byte-identical whatever the bake budget (the §10 honesty proof shape);
pixel goldens shoot past the completion frame. Disk-caching the baked
atlas is the known dev-comfort upgrade if reload cost annoys (rc-class
cache, suite never reads it).

### Click-to-move: the sim-legal RO kernel

Mouse x/y/buttons are already in the input record v1 — a click IS sim
input. Click → unproject through the sim-state camera (cm.math only) →
ray-march T.sample (60 µs) → snap to the **walk grid** (2× subdivision
of the render grid: 64×64 cells of 1.0 u — the GAT scale exactly);
derive per-cell flags once at init from slope + water depth + prop
colliders → **heap A*** (2.9 ms worst case, fine per click) → the
player walks the waypoint chain at a speed knob, facing snapped to 8
directions for the sprite. No physics, no jump: RO movement is pathing
(the platformer kernel stays in demos 1/2). A destination marker + a
re-click retarget make the feel. Demo autoplay feeds synthetic clicks
through the SAME pick+path pipeline (screen-space, via the sim camera)
so golden traces exercise the whole kernel headlessly.

### Sprites: the figure→sprite bake goes live (the §5 loop closes)

The player and NPCs are **billboards baked from cm.fig figures** — the
proto ro scene's proven hero shot (bake_guy_sprite) and the strategic
license-clean answer (§8/2: our renders, CC0 by construction; the
Kushnariova CC-BY pack stays a reference, never a golden dependency —
assets/ is gitignored and the suite runs from the committed tree). New
cartridge module: a tiny deterministic Lua rasterizer (edge functions +
z-buffer + the pre-lit vertex colors already in the emitted tris) that
renders a figure clip at 8 yaws × N walk frames into a sprite-sheet
texture at load time (tiny res; nearest + alpha-test always). The
mascot chibi (big-head proportions via per-part scale overrides) is the
player; palette variants are the NPCs. This is the demo's headline
ergonomics candidate: **model once → use as 3D (demos 1/2) or billboard
(demo 3)** with zero external art. Billboard draw rules from the
recipe: upright quad, Y-face the camera, ~3 u tall vs 2 u tiles, unlit
but tinted 0.7+0.3·shadow at the feet, blob shadow decal, nearest +
alphatest flags. The depth-pull-toward-camera trick (tall sprites vs
terrain behind) is a flagged PAL candidate — only if clipping shows in
the vale (smooth ground + steep camera should hide it).

### The rest of the read

- **Camera**: sim-state rig — pitch ~50° default (free 30..80), yaw
  free (arrows/drag), stepped wheel zoom, **15° vertical FOV** (m4.persp
  15) — the near-ortho RO look with perspective life. No yaw-follow.
- **Water**: T.emit_water at the authentic 144/255 opacity, submitted
  AFTER the sprite segments (the recipe's draw order); vertex wave +
  texture cycle deferred to a polish round.
- **Props**: round-canopy trees + bushes (gb lathes/balls, ro2's
  species), the diagonal gazebo + crisp plaza slab (§8c v6 rule:
  ground blends, architecture is hard-edged geometry), fence posts.
  Props register shadow casters for the bake and AABBs for the walk
  grid.
- **Presentation**: 480×270 internal (the RO preset res), quant 5 +
  soft on (D3D-015 knobs).
- **Goldens**: one tour trace (click-route autoplay, drift-proven, plus
  the §10-style honesty proof: re-verify under a different bake budget)
  + pixel goldens past bake completion. Audio: a click/step/greet set
  via the bounce .ins pattern.

Round 1 scope: terrain+bake, camera, click-to-move, baked mascot-chibi
player + 2-3 NPC variants wandering/greeting, water, props, HUD, demo,
goldens. Deferred: water wave/cycle, paper-doll layers, palette dyes,
monsters/combat, the terrain-editor window (distillation phase).

## 12. The distillation phase — vote audit + slice roadmap (2026-07-17, round 19)

The §8f directive activates: demo 3 landed "exactly the vibe we would
want", so the three demos distil into engine ergonomics. Before picking
slices, two audits — our own duplication count and a survey of what
upstream cosmic2d did in the same phase (A5, D088–D097, landed since
our fork point).

### The upstream A5 survey (read at f791824..2b885d5)

cosmic2d ran precisely this exercise for 2D and its process is now the
proven house style, adopted here verbatim:

- **Pain-first, votes counted honestly**: a slice absorbs only code
  that exists in multiple agreed copies (or is human-logged as
  engine-shaped); single patterns stay in the demo until they hurt
  twice. Slices that find no duplication DEFER (their D096 transition
  slice is the worked example).
- **One slice per packet**: a `cm.*` module of pure functions / math
  over plain doc tables or the caller's named buffers — no module
  state, no callbacks; determinism by construction. Every ADR carries
  a "deliberately NOT here" list; later slices earn features from real
  pain.
- **Retrofit proof**: at least one demo rides the module the same
  commit. Bit-identical retrofits leave goldens UN-RECUT (their
  cm.box/cm.move proofs; the strongest form). Honest re-cuts only when
  doc shape moves (their cm.actor/cm.camera).

Upstream modules shipped in A5 (none exist in our fork yet; they
arrive at the post-1.0 re-merge): `cm.box`, `cm.actor`, `cm.camera`,
`cm.tween`, `cm.depth`, `cm.hud`, `cm.move`, plus earlier `cm.save`,
`cm.pick` (the project-picker list model — the name is TAKEN; our pick
ray must not squat it). Consequences for the 3D fork:

- **Name collisions banned**: no fork module may claim cm.box,
  cm.actor, cm.camera, cm.tween, cm.depth, cm.hud, cm.move, cm.save,
  cm.pick. The 3D camera slice is `cm.rig`; the pick-ray/pathing slice
  is `cm.walk`.
- **Don't build 3D twins of dimension-agnostic slices.** cm.tween
  (juice counters — our squash/hold/pop timers), cm.hud (anchored
  text — our hand-centered HUD lines), cm.move (stick+key merge),
  cm.actor (stable ids/tags/timers — our NPC lists) all apply to 3D
  cartridges unchanged. The demos keep their naive copies as merge
  bait; at re-merge they retrofit onto the upstream modules instead of
  onto fork inventions we would then have to unwind. Only slices that
  are genuinely 3D-shaped get built here.
- Also noted upstream: **input record v2 exists now** (D082, additive
  quantized-pad extension) plus gamepads/rebinding/options/save — the
  parked relative-mouse+record-v2 work stays post-merge but its
  prerequisite shipped; and their D092 camera found the recorder
  re-canons a moving doc each frame (~3.5KB/frame) — our rigs already
  live in f32 buffers, which sidesteps that cost; keep it that way.

### The fork's vote audit (2026-07-17)

- **Orbit-follow camera rig: 3 copies, byte-identical math** (bounce/
  openworld/bigworld main.lua: angdiff + cam_step + the eye/lookat
  derivation + the camera-relative wish rotation + the virgin-buffer
  seed; the D3D-018 back-cone fix was applied three times). The
  loudest vote → **cm.rig**.
- **Player kernel: 3 diverging copies with an agreed core** (the
  D3D-009/010 clamp rules + EPS, D029 jump, mantle, box-top landing,
  squash/stretch juice). Real divergence on top (swim regime, glider,
  terrain vs box ground) → a later, harder slice; extract only the
  agreed collide+jump core when cut (**cm.kin**, name tentative).
- **NPC greet/wave: 2–3 copies** (openworld npc, rovale npc, bigworld
  ents' near-kernel): greet radius + hysteresis, facing ease, typed
  line, hold. Candidate after the singles; may shrink further at
  re-merge when cm.actor arrives.
- **audio.lua sfx pattern: 4 small copies** (~40 lines each) — thin;
  defer until a slice shape is obvious.
- **Human-logged rovale singles** (D3D-026, engine-shaped by
  direction): the figure→sprite baker (**cm.spr**), the terrain
  bake atlas (module + future editor button), pick ray + walk-grid A*
  (**cm.walk**), camera-facing billboards (**into cm.gb**).

### Slice order

1. **cm.rig** — 3 votes, bit-identical extraction, goldens un-recut.
2. **cm.spr** — the baker as an engine module (any figure, any sheet
   spec, .spx read/write + stamp); rovale retrofits; committed sheets
   stay byte-identical.
3. **cm.walk** — pick ray (march+bisect over a ground fn), grid snap,
   heap A*, cell-chain follow; rovale retrofits, trace un-recut.
4. **Billboards into cm.gb** + the terrain-bake module (likely with
   the editor bake button when the editor unparks).
5. **cm.kin** (the shared collide+jump core) ✓ **DONE** (D3D-032):
   approach/overlaps/jump_curve/run/gravity/jump/slide/mantle_top/
   ground_top/land_squash/lean, value-based (the three player buffers
   diverge, so no owned layout — and it can't resize a persistent
   buffer, dodging the D3D-031 trap); all three kernels retrofitted,
   whole-trajectory FRAM byte-identity + pixels + traces un-recut. The
   **NPC greet slice** (greet radius + hysteresis, facing ease, typed
   line, hold across openworld/rovale/bigworld) is the remaining half.

Editor windows (terrain paint/bake, figure vertex-pushing, sheet
preview) stay parked until the human unparks the editor; the modules
above are their runtime substrate.

### §12a. RO preset presents sharp (human, 2026-07-17)

"For the ragnarok demo, disable the soft VI filter — that's more
appropriate for that art style": rovale runs KNOBS.look.soft = 0
(quant/dither stay). The soft blit remains the N64-preset default
(bounce/openworld/bigworld unchanged). Composite-only, so the internal
pixel goldens stand byte-identical; the committed tour trace stands
(hermetic bundle). Sharp-vs-soft comparison pushed to the feed.
