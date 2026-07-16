# Research: Body Harvest decomp + slopstudio technique library

(agent-explored 2026-07-16; both dirs read-only)

## /opt/src/body-harvest — N64 Body Harvest decompilation (+ video notes)

A matching decomp (~62% decompiled) of DMA Design's 1998 open-world N64 game, plus
dense analysis notes. The extractable techniques:

- **Streaming heightmap terrain via a scrolling ring buffer**: 256×256 grid of
  256×256-unit tiles, 6-bit vertex heights (`&0x3F`, `<<5`). Only a **19×19 vertex
  window** around the camera is resident; it scrolls one column/row at a time,
  recomputing only the new edge. Ground sampler picks the tile triangle by
  `(xInTile+zInTile) < 0x100` and barycentric-interpolates.
  `decomp/src.us/overlay_gameplay/outside/BF9C0.c` (sampler :2798, ring builder
  :1325, scroll :1521, init :1497).
- **Vertex-color-only terrain** (no textures): landscape palette bilinearly sampled
  into vertex colors (BF9C0.c:658), modulated by per-era tint tables (:96-129),
  one normalized sun vector `{0.39,0.89,-0.3}` for per-vertex shading. Reskinning
  an era = swapping constant tables.
- **Pitch-dependent fog** (:1311): fog near/far recomputed from camera pitch —
  hides the LOD horizon when looking level, opens when looking down. Outdoor
  `gSPFogPosition(0x1900,0xE800)` black fog; interiors (995,1000).
- **Dither/geometry-mode tricks**: `G_AC_DITHER` alpha compare for cheap
  transparency, `G_CD_MAGICSQ` color dither, per-object `G_FOG/G_CULL/G_LIGHTING`
  toggles. Steep-slope bitmask (>10-unit corner deltas) gates a detail overlay.
- **Content streaming in 4MB**: code overlays sharing VRAM slots (eras overwrite
  each other), 2KB DMA blocks, MIO0 LZ for geometry + RNC for textures, 3-byte
  opcode mission bytecode VM, fixed entity pools (255 aliens/128 vehicles/255
  buildings), s16 world coords.

Priority reading: `notes/FACTS.md` (indexed claims), `BF9C0.c` (terrain
masterclass), `notes/RAM_MAP.md`, `core/loader.c`.

## /opt/src/slopstudio-projects — video-essay studio; research/ tree is the value

- `research/video-study/*lethal-company/STUDY.md` — teardown of Lethal Company's
  renderer (via Acerola): render at 860×520 and upscale (low-res as aesthetic);
  **posterize the volumetric-light buffer** the engine already computed (the
  game's signature look is one quantize step); depth+normal 3×3 edge detection;
  stock fog/bloom/color-correct composited well. Thesis: bespoke-looking style ≈
  stock effects + taste. Directly applicable to our grade-pass design.
- `research/video-topics/body-harvest-n64/DOSSIER.md` — compact gem list of the
  above BH techniques (+ F3DEX 1.21 / L3DEX microcode note).

## Implications adopted into DESIGN.md

- Zero-texture vertex-color terrain mode (graybox + stylized option, nearly free).
- Pitch-dependent fog for the open-world demo.
- Ring-buffer streaming as the scale path for big maps (not needed at RO map sizes).
- The grade pass (dither/LUT/posterize) is where "distinctive look" lives — keep
  investing there rather than in shader features.
