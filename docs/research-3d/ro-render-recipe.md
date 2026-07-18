# Research: the RO rendering recipe (from accurate reimplementations)

(agent-researched 2026-07-16 from roBrowser, BrowEdit3, Doddler's Ragnarok
ReBuild, and Ragnarok Research Lab source; file refs verified)

Scale: original client = 10 units per GND cell; reimplementations divide by 5
→ GAT tile = 1 unit, GND cell = 2 (heights /5, negated).

## Ground
- Up to 3 quads per cell: TOP + north wall + east wall; walls span to the
  neighbor's corner heights, use the tile's 4 explicit free-form UVs in a
  different corner order.
- Normals: face normal per TOP quad, then corner-smoothed by averaging the 4
  sharing cells; walls get constant axis normals. Atlas packs textures in
  258px slots (256 + 1px duplicated border) against bleeding.
- **Per-tile vertex colors**: each TOP tile has an RGBA belonging to its
  bottom-left corner; other corners take neighbors' colors → smooth painted
  gradients multiplying the diffuse. This is the ONLY runtime "blending"
  ground does.

## Lightmaps (the exact math)
- One 8×8 texel block per surface: 64 bytes shadow + 192 bytes RGB color.
  Pack into an atlas; **posterize color: c = (c>>4)<<4** (16 levels); shadow
  byte in alpha, unposterized. Bilinear sampling of the interior only
  (0.125..0.875 of the block — the 1-texel border makes cross-tile blending
  seamless).
- Fragment application:
  `out = tex * clamp((Ambient + Diffuse) * lm.shadow) + lm.rgb`
  — shadow **multiplies** the light, color channel **adds after** (not
  attenuated by shadow). Apply shadow after lighting or it washes out.
- Authentic combined light cap (BrowEdit3 gnd.vs "what the official client
  does"): total light clamped to screen(A,D) = 1-(1-A)(1-D). If lightmaps
  are disabled, ambient × 1.5.
- Ground diffuse floor: max(dot(N,L), 0.1); models use floor 0.5.

## Texture transitions — CONFIRMED
RO never alpha-blends two tile textures at runtime. One texture id + 4 free
UVs per surface; transitions are hand-painted border tiles. "Rotation" =
permuting/mirroring the 4 UVs (flip-H, flip-V, diagonal swap — no rotation
flag). Magenta (255,0,255) keys transparency; shaders discard at alpha 0.
(cosmic3d's per-tile bake reproduces the same read automatically — a
deliberate improvement, not a reconstruction.)

## Water
- Flat plane, one quad per submerged cell; emit only if any corner is above
  waterLevel − waveHeight (edges hidden where terrain pierces the plane).
- Vertex wave: y += sin(radians(offset + 0.5·wavePitch·(x+z+checkerJitter)))
  · waveHeight, offset = (frame·waveSpeed)%360−180, frame = 60fps tick.
- Texture cycling: 32 frames (water<type><00-31>.jpg), advance every
  animSpeed ticks (default 3 → 1.6s full cycle); UVs tile every 4 cells.
- **Opacity 0.5625 (144/255)**, SrcAlpha blend, **depth-write OFF**, unlit.
- Draw order: water renders AFTER sprites.

## RSM models
Shade types: 0 none (unlit-ish), 1 flat (per-face), 2 smooth (per
smoothGroup). Per-vertex light with 0.5 diffuse floor; NO lightmaps on
models. Whole-model alpha byte; per-face twoSide flag disables culling.
Alpha-test discard. Draw after ground, depth-tested.

## Sprites
- **1 sprite px = 1/35 GND cell** (roBrowser px/175 × size 5).
- Billboard: upright, Y-rotation to camera; roBrowser adds a shear so
  sprites lean back slightly with camera pitch. **The load-bearing trick**
  (Rebuild): keep the quad vertical and pull fragments toward the camera in
  depth (billboard.cginc) so tall sprites don't clip into terrain/walls
  behind them.
- Unlit, but multiplied by (a) the ground lightmap shadow under the feet
  (roBrowser averages a 6×6 texel window of a CPU shadow bitmap) and (b) an
  env tint with only 30% swing: env = 1-(1-D)(1-A); tint = env·0.3 + 0.7.
- Blob shadow is literally a sprite (shadow.spr) at GAT height, scaled per
  entity, skipped when sitting/dead, darkened by the same shadow factor.
- Palette sprites: custom 4-tap bilinear over the palette LUT.

## Fog / sky / camera / order
- Fog per map: near/far percentages ×240 world units;
  mix(color, fogColor, smoothstep(near, far, depth)) in every shader.
- Sky: solid clear color + ~150 billboarded cloud sprites on listed maps.
- Camera: FOV 15°, near 1 far 1000 (scaled), pitch ~30–90° (default ~60°),
  yaw free, stepped zoom.
- Draw order: Ground → Models → cursor → Sky clouds → Effects1 → Sprites →
  **Water** → damage text → Effects2.

## Applied to the prototype (scene ro2, 2026-07-16)
Water opacity 0.5625; sprites tinted 0.7+0.3·shadow at feet; shadow bake
sampled on the 8×8-per-tile grid. Still open for the real engine: water
texture cycling + wave, sprite depth-pull, lightmap color channel (additive
colored light), per-tile vertex colors as a second gradient layer, sprite
lean-back shear.
