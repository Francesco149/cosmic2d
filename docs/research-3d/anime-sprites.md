# Research: RO-style anime sprite sources & customization tools (for demo 3)

(agent-researched 2026-07-16; licenses read on the actual pages)

## Ruled OUT

- **RPG Maker MV/MZ generators**: EULA locks generator output to RPG Maker
  products only ("may not [be used] in other game-development software").
  Bundling in an open repo is doubly out.
- **Game Character Hub (Steam)**: stock parts library is Enterbrain property,
  RPG-Maker-products-only; no library content may be redistributed as assets.
- **charas-project.net**: no formal license; parts derive from RM2K RTP
  (Enterbrain copyright). Legally murky at the root.
- **Actual RO sprites**: Gravity Co. copyright; the format tooling (actOR2,
  zrenderer, SPR/ACT docs) is legal, the assets are not. **No legally free
  RO-style animated set exists** (verified: the itch "ragnarok" tag has only
  AI-assisted static illustration packs, also no-redistribution).
- **Style-correct itch packs** (Pipoya 32x32 chibi, Time Fantasy, Noiracide,
  Shubibubi, Adventure Hollow): all "commercial use OK, NO redistribution" —
  fine for a user's game, cannot be bundled in the engine repo. Pipoya is the
  one to *recommend users install themselves* (free, perfect RM-chibi style,
  4-dir walk).

## Bundleable (verified)

- **Svetlana Kushnariova (Cabbit) 24x32 characters + faces, big pack** —
  CC-BY 3.0 / OGA-BY 3.0, ~53 characters, RMXP-like anime-chibi (closest OGA
  gets to the RO vibe), 4-direction 3-frame walk, face portraits. Credit
  "Svetlana Kushnariova" + OGA link. **Best bundle-now candidate for demo 3.**
  https://opengameart.org/content/24x32-characters-with-faces-big-pack
- **Antifarea / Charles Gabriel** 16x18/18x20 sets — CC-BY 3.0, anime-ish,
  4-dir walk+attack+cast.
- **AxulArt Small 8-direction Characters** — CC-BY 4.0 AND 8-direction (rare),
  but small western-leaning style.
- **Universal LPC generator** — legally bundleable (CC-BY-SA/GPL + ship the
  per-sheet CREDITS.csv) but ShareAlike-viral and visibly the wrong style.
  Fallback only.
- **Emcee Flesher 16x16 Chibi RPG Character Builder v3** — CC-BY 4.0, includes
  a layered generator (base/clothes/hair/weapon), 4-dir; much chunkier than RO.

## The strategic answer: paper-doll system + VRoid-rendered house set

- **VRoid Studio** (pixiv) guidelines explicitly permit using 2D renders of
  your models (including ones built from VRoid preset hair/clothes) in games,
  apps, and material collections, commercially; renders are your copyright →
  releasable CC0. Only shipping *3D model outputs* from preset meshes is
  restricted. **License-verified path to an authentic anime look, 8 directions,
  walk/idle, CC0 forever**: animate the model, orbit the camera 8×, render
  low-res, downsample/posterize.
- **RO's own paper-doll spec** (from ACT/SPR format docs — the system to clone
  in-engine): head and body are separate sprite+animation files composited at
  runtime via per-frame anchor points (headgear stacks the same way); player
  actions = idle/walk/sit/pickup/standby/attack×3/hurt/freeze×2/dead/cast;
  8 directions at 45° (≈2 poses per side mirrored), up to 8 walk frames per
  direction, delays in 25ms units; 8-bit indexed 256-color frames with palette
  index 0 transparent → hair/clothes dyes are just alternate palettes.

## Demo-3 plan distilled

1. Bundle Kushnariova (CC-BY) for immediate 4-direction RO-flavored NPCs.
2. Build the paper-doll billboard system to RO's spec (head/body layers,
   anchors, palette swaps, 8-dir with mirroring).
3. Produce the house character set via VRoid render-to-sprite (CC0), and/or
   the engine's own figure→sprite baker for stylized characters.
