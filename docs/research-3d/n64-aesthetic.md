# Research: N64-style rendering (vs PS1) and how indies recreate it

(agent-researched 2026-07-16; ~25 sources fetched + adversarial verification pass on load-bearing claims)

## 1. Authentic N64 rendering vs PS1

**Texture filtering — the single biggest differentiator.** The N64 RDP does 3-point
("triangular") bilinear filtering, not 4-tap: "rather than doing a full bilinear
interpolation using all four samples, a triangular interpolation is performed that uses
only three points" (official manual ch. 14, https://ultra64.ca/files/documentation/online-manuals/man/pro-man/pro14/14-01.html).
Produces diagonal smearing and hexagonal "rupee" artifacts on regular patterns.
The PS1 GPU has **no filtering at all** — nearest only. N64 = smooth/blurry; PS1 = blocky.

**TMEM: 4KB texture cache.** Max texels per format (manual 13-08):
- 4-bit CI (palettized): 4K texels → 64×64 (16 palettes)
- 8-bit CI: 2K texels → 64×32 (256-entry TLUT)
- RGBA16 (5/5/5/1): 2K texels → 64×32 or 32×32
- 4-bit I/IA: 8K texels → 128×64; 32-bit RGBA: 1K texels
This is why era textures are 32×32/64×32/64×64 stretched over huge surfaces.

**Geometry precision.** N64: perspective-correct texturing, hardware Z-buffer,
subpixel edge precision (16 fractional bits) → **no vertex wobble, no affine warp**.
PS1: affine UV interpolation, no Z-buffer (painter's ordering table), integer screen
coords (GTE, zero fraction bits) = the signature jitter.

**AA and the "soft" N64 look.** RDP per-pixel coverage edge AA + Video Interface
filters (divot median filter, dedither reconstruction, horizontal 320→640
interpolation). The stack is the characteristic N64 softness. Games could disable
pieces via VI_CONTROL.

**Color.** N64 16-bit framebuffer 5/5/5 + coverage; RDP dithers 8-bit down to 5-bit
("magic square" pattern). PS1: 15-bit with documented 4×4 dither matrix. Both dither;
PS1 reads grittier (no VI reconstruction).

**Resolutions.** N64: 320×240 typical, 640×480 hi-res (Expansion Pak era). PS1:
256/320/368/512/640 × 240p/480i.

**Fog.** N64 fog: RSP writes screen-Z-derived fog factor into shade alpha; blender
lerps toward fog color register. Consequence: vertex alpha and fog mutually exclusive.

**Budgets.** N64 characters 250–750 tris typical. Measured: Mario 752 tris (17 rigid
segments), OoT teen Link 757 w/ shield, Banjo 783, Bowser 1002, Goomba 144, Smash 64
chars 256–338. Scene budget ~3–5K polys/frame at 20–30fps (Fast3D >100K polys/sec).
PS1 GTE: 180K textured polys/sec spec.

## 2. The modern indie toolkit

All optional toggles in the popular shader packs:
- **Low-res render target**: 320×240 (4:3) canonical; 320×180/640×360 for 16:9 integer scaling
- **Vertex snapping** (PS1 only): floor() post-projection coords against target res
- **Affine toggle** (PS1 only): `noperspective` interpolation qualifier; era mitigation was subdividing large quads
- **3-point filtering** (N64 only): barycentric 3-texel blend shader (godotshaders.com "N64 3 Point Filtering" is CC0, from Shadertoy Ws2fWV)
- **Per-vertex Gouraud lighting** in vertex shader; textures painted maximally bright (vertex color can only darken)
- **Color quantization + Bayer dithering** post-process; **hard fog**
- Named refs: HPSXRP (Haunted PSX Render Pipeline, Unity), keijiro/Retro3DPipeline,
  dsoft20/psx_retroshader, MenacingMecha Godot PSX Style Demo (MIT), Zorochase
  Ultimate Retro Shader Collection (Godot 4; recommends 32–64px textures for N64 mode),
  Daniel Ilett Retro Shaders Pro (N64 mode = PS1 mode with perspective correction +
  filtering back on, wobble off).

**The N64 recipe subtracts PS1 artifacts**: no snapping, no affine; keep
perspective-correct + Z-buffer; add 3-point filtering, vertex-color lighting,
per-vertex fog, edge softness, dithered 15/16-bit output.

## 3. What makes it read as intentional (artist consensus)

- **Consistency is everything.** Accidental-look killers (Polycount Retro 3D FAQ):
  4-tap bilinear left on, modern lit/PBR materials instead of unlit texture × baked
  vertex color, mismatched texel density, lightmaps sharper than the diffuse,
  ignoring era resolution.
- 98DEMAKE: "if you're going to have ambient occlusion and anti aliasing slapped in
  there — it's hardly 'PS1 inspired' at that point."
- David Szymanski (DUSK): biggest challenge "was just convincing Unity to stop doing
  things that make the game look better"; low-palette textures matter as much as
  low-res; "it all looks like Dusk, which I think is just as important."
- **Craft signals**: pixel-aware UV unwrapping (straight texture line → straight line
  on model; Silent Hill best-in-class), ~100–120 colors per character atlas, baked
  lighting in textures + vertex color mood (Vagrant Story), silhouette economy
  ("if it doesn't add to the silhouette, you don't need it"), 500–600 tris for a hero.
- **N64 mood**: bright saturated Rareware palettes, sparkly particles, vertex-shaded
  ambiance. Macbat 64 dev: "The low-poly art-style kind of acts like a canvas."

## 4. Case studies (verified)

- **Cavern of Dreams** (2023, **Unity** — verification refuted the common "Godot" claim):
  textures 16×16–64×64 with filtering deliberately ON; the "two most important aspects":
  **"vertex shading — painting light and shadow onto a map's geometry"** + filtered
  low-res textures; characters sometimes untextured flat color; largest world ~7,500 tris.
- **Corn Kidz 64** (Unity): 240p internal, locked 30fps ("30fps in 240p does look
  smoother than it does in HD"); squash-and-stretch animation.
- **Pseudoregalia** (UE 5.1): intentionally choppy stepped keyframe animation with a
  disable option.
- **A Short Hike** (Unity): pixelation via low-res RenderTexture, player-adjustable;
  triplanar terrain mapping.
- **Lunistice**: "make a game that looks how people remember the 32-bit era looks.
  Not how it actually is."
- **Haunted PS1** community: annual Demo Discs; graduates Dread Delusion, Fatum Betula.

## 5. Characters: era technique (CONFIRMED) and indie practice

**SM64 characters are segmented rigid hierarchies, no skinning.** Mario =
~17 discrete rigid mesh segments in a parent-child tree (pelvis→torso→head;
arm→forearm→hand; thigh→shin→foot per side) as GEO_ANIMATED_PART nodes; three LOD
hierarchies. Joint gaps tolerated or hidden by overlapping rounded segment ends.
RSP constraint: 1 matrix per vertex, no weighted blending. Much of Mario is untextured
vertex/material color; textures mostly 32×32 (n64decomp/sm64).

**Faces = texture/mesh swap.** Mario blinks via GEO_SWITCH_CASE selecting eye display
lists (open/half/closed from a sheet of 32×32 frames); same mechanism swaps hand
meshes (fist/open/peace). OoT Link: exactly 8 eye + 4 mouth textures per age,
rebound per-frame (zeldaret/oot z_player_lib.c).

**Animation storage (SM64)**: per-joint s16 rotation channels (65536 = 360°),
translation on root only, 30Hz integer-frame sampled, no interpolation; Mario has
209 animations. OoT added "flex" skeletons (continuous mesh, still 1 matrix/vertex),
fractional-frame lerp, and true CPU multi-weight skinning only for organic actors
(Epona, z_skin.c).

**Indie authoring tools**: picoCAD (128×128/16-color sheet, OBJ+GIF; v2 adds
animation timeline + glTF), Blockbench (free; per-face UV, bones + keyframes,
glTF/OBJ export, used far beyond Minecraft), Crocotile 3D ($30; builds 3D from 2D
tilesets, now has bones/weights/vertex color), Blender with "Closest" interpolation +
vertex paint, MagicaVoxel→Mixamo, billboarded sprites (Nightmare Reaper).
**Specs**: modern indie retro characters 300–1500 tris, single 64×64–128×128 atlas.
**Faces**: UV-offset/flipbook expression atlases (Starcube Labs tutorial).
**Animation**: stepped/constant interpolation at low key rates ("on 2s/4s") is the
standard modern stylization (era consoles actually animated at full 30/60 — choppy
12–15fps keys is a modern *stylization*, which Pseudoregalia proves works).
Tutorials: Thomas Potter "PS1 Characters in Blender", Grant Abbitt PS1 texture
painting, Pikuma https://pikuma.com/blog/how-to-make-ps1-graphics, David Colson
https://www.david-colson.com/2021/11/30/ps1-style-renderer.html.
