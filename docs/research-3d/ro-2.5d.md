# Research: Ragnarok Online 2.5D tech, editor UX, and editable terrain models

(agent-researched 2026-07-16)

## 1. RO's actual tech (three files per map)

**GND — terrain.** Grid of "cubes", each storing **four per-corner heights** plus up
to three textured surfaces: upward ground surface, north-facing wall, east-facing
wall. **Walls are not authored geometry** — a wall plane exists implicitly wherever
adjacent cubes differ in height; it becomes visible when a texture is assigned.
Surface texture id -1 = invisible. File carries a texture path list; each surface
stores a texture index + explicit per-corner UVs (rotation/flips = UV permutations).
Effective texel density ~**32 px per tile**. Geometry scale factor 10 constant.
GND 1.8/1.9 moved water (level, wave params, multiple planes) from RSW into GND.
Docs: https://ragnarokresearchlab.github.io/file-formats/gnd/ ,
https://github.com/Duckwhale/RagnarokFileFormats

**Lightmaps.** Per-surface **8×8-texel lightmap** slice: 64 bytes grayscale
shadow/AO + 192 bytes RGB color light, 1px border, packed into a runtime atlas.
"Dynamic" lights in RSW are actually baked here. The chunky posterized per-tile
shadows are a big part of RO's look.

**GAT — walkability.** Separate **2× finer grid** (1 GND cube = 2×2 GAT cells).
Per cell: 4 corner heights + u32 type: 0 walkable, 1 blocked, 2/4 water variants,
3 walkable water, 5 cliff-snipable (ranged attacks pass), 6 cliff-blocked.
Gameplay resolution is the GAT cell.

**RSW — scene.** Global directional light (lon/lat + diffuse/ambient RGB), placed
objects: RSM model instances (pos/rot/scale), light sources (baked), audio emitters,
particle emitters; fixed 5-level quadtree for culling. Buildings/trees/bridges are
RSM models placed on the heightfield.

**Numbers.** Prontera = 312×392 GAT cells; typical maps 200–400 cells/side
(~100–200 GND cubes). **Camera: perspective with very narrow vertical FOV (~15°)** —
looks near-orthographic while still perspective; pitch constrained ~-50°..-70°, yaw
free (Shift+RMB), stepped zoom. (https://ragnarokresearchlab.github.io/rendering/camera-controls/)

**Sprites.** SPR = indexed-color bitmaps, 256-color palette (index 0 transparent);
ACT = animations: frames, per-layer placements, **anchor points** attaching the
separately-rendered head sprite to the body (+ headgears). .pal palette swaps =
cheap dyes. **Players 8 directions, most monsters 4**; client picks direction frame
from (entity facing − camera yaw), billboards the quad.

## 2. BrowEdit mapper UX

Modes: Texture (F1), Object (F2), Height (F3), vertex Height (F4), Wall (F5), GAT,
lightmap generation. Workflow: fill base texture → paint per-tile textures from a
palette window → shape heights (select region + drag; hotkeys connect/random/
flatten/smooth) → texture the implicit walls → place RSM models → paint GAT →
place lights → bake lightmaps offline.
**Pain**: crashy, texture list ordering brittle, object rotations render differently
in-game, GAT edit missing in BrowEdit 3 for years. **Nice**: direct per-tile texture
painting + drag-height is fast and legible; implicit walls mean cliffs "just happen";
lightmap baking = big payoff, zero runtime cost.
Design lesson: RO mapping survived two decades on a janky community tool because the
*data model* is simple — tile grid + texture indices + baked light; the editor is
just brushes over arrays.

## 3. Modern indies doing 3D terrain + 2D sprites

- **Cassette Beasts** (Godot; closest to target scope): fixed-angle camera, grid-based
  3D terrain via GridMap (mesh tiles, pixel-art textured), Sprite3D billboards with
  per-angle Aseprite renders; world streamed as 16×8 chunks of 32×32 tiles.
- **Octopath Traveler** (HD-2D ceiling): billboarded pixel sprites, dynamic lights,
  DoF/tilt-shift; sprites cast shadow-map shadows via billboarding tricks.
- **Threads of Time** (UE5): hand-authored normal maps on sprites for dynamic lighting.
- **Delver** (open source, zlib, libGDX): tile-based 3D + billboards — readable
  reference code (github.com/Interrupt/delverengine).
- **SpiritVale**: current indie MMO explicitly recreating RO's look.

**Recurring solutions**:
- Billboarding: full camera-facing for characters (RO-style, feet pinned), Y-axis-only
  for foliage so it doesn't lean back.
- Depth: write real depth from the billboard with alpha cutout → z-buffer handles
  sorting vs terrain and each other; foot-pivot + slight camera-ward offset (or
  per-pixel depth bias) fixes slope/cliff clipping.
- Lighting tiers: (a) unlit sprite tinted by sampling terrain light at the feet
  (RO's way — cheapest, most cohesive), (b) lit billboard with fixed up-normal,
  (c) normal-mapped sprites.
- Shadows: blob/capsule decals under feet are standard; real shadow maps from
  billboards need hacks.
- Directions: 8 players / 4 monsters is the RO-proven cost/benefit point.
- With ~15° FOV, sprite perspective distortion is negligible (1 sprite px ≈ fixed
  world size).

## 4. Terrain data models that edit well

Per-corner-height tile grids are the shared foundation (RO, WC3, Transport/RCT):
a tile with 4 corner heights is trivially brush-editable and renders as 2 triangles.

- **Warcraft 3** (war3map.w3e): heights at tilepoints, per point: ground height i16,
  water level, flags (ramp/blight/water), 4-bit ground texture (max 16), 5-bit
  variation, 4-bit cliff texture, 4-bit **cliff layer level**. Key insight: separates
  **smooth height** (freeform raise/lower) from **discrete cliff levels**; cliffs are
  pre-made models selected by encoding the four corner layer-diffs into a filename
  ("BAAA" → CliffsBAAAx.mdx) — marching-squares auto-tiling in 3D. **Ramps** = a
  per-point flag swapping in ramp pieces. Ground texture **auto-blending**: 4-bit
  corner-share encoding = 16 blend patterns per texture pair. The WC3 editor UX
  (cliff tool + ramp tool + blend brush + smooth raise/lower) is the gold standard.
- **Transport/RCT**: adjacent corners differ ≤1 unit → only 19 unique slope tiles.
- **RO**: no cliff auto-tiling at all — implicit walls you hand-texture. Simpler
  engine, more editor labor. Synthesis: auto-assign wall textures (biome "cliff
  material", UV by wall height) with manual override.

**The overhang problem.** One heightfield = no caves/under-bridges.
- RO: doesn't solve it; bridges are raised heightfield or models; multi-level =
  separate maps + warps. 20 years of content shipped without overhangs.
- WC3: bridges are doodads with pathing overrides.
- GridMap-style 3D tilemaps are volumetric but lose smooth per-corner heights.
- Patterns for a new engine: (a) heightfield + walkable mesh props with nav patches
  (covers bridges, cheapest), (b) multiple stacked heightfield layers with portal
  cells (caves/multi-story), (c) full 3D tile volumes. For RO-like scope: (a), then
  (b) later.

**Suggested synthesis**: GND-style per-corner-height render tiles + implicit
auto-textured walls; WC3-style ramp/cliff auto-tiling + blend-brush texture painting;
GAT-style 2× walk grid with type flags; baked low-res per-tile lightmaps (8×8 is
charming and lights sprites for free by sampling at the feet); narrow-FOV (~15°)
perspective camera, pitch clamped 50–70°, free yaw; layered palette-indexed sprites,
8/4 directions, depth-writing cutout billboards, blob shadows.
