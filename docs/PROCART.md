# procart — the procedural pixel-art experiment

> Status: round 1 shipped 2026-07-03 (ADR D044); **human verdict same day:
> "promising enough to warrant more exploration" — PROMOTED to round 2.**
> **Round 2 shipped later that day** (both tracks of the brief): the terrain
> STYLE system (presets x day/dusk/dread grades + live dials) targeting the
> Grand Canyon rim-hub look, and chargen2 — 48x64 anime-ish characters with
> the actual cast (Vesper/Gemma/Lumi) baked in as knob bundles. §6 has the
> round-2 read; the human's taste pass is pending.

## 1. The question

Can **mostly-procedural** pixel art hit the cosmic art bar (GAME.md §10 —
cute, cozy, Wadanohara-ish, gradients-as-sophistication) *with personality*?
Two sub-questions, one per generator:

- **Characters**: can procedural knobs (plus a sprinkle of baked choices)
  produce a full cast where each member reads as *someone* — not
  palette-swapped clones?
- **Environments**: can procedural primitives compose into terrain/tile types
  that (a) tile cleanly and (b) **marry** at material borders with no visible
  seam?

Where it lives: **`projects/procart/`**, a separate experimental cartridge —
never in a golden suite, zero risk to the game projects. Run:

```sh
bin/cosmic projects/procart        # gallery: <-/-> or 1..9 pages, R rerolls
```

Pages: **1 CAST** (10 crowd seeds at 48x64) · **2 MOODS** (one seed, every
mood knob — the personality proof) · **3 TRIO** (the baked cast bundles,
`chargen2.CAST`) · **4 MOBS** (cosmic creatures from Bollinger half-masks +
the cute stamp) · **5 TILES** (repeating tile + 3x3 self-tile proof) ·
**6 MARRY** (hard seam vs married border) · **7 TERRAIN** (a composed
material map under a dithered dusk sky) · **8 CANYON** (the rim-hub-shaped
scene under the style system; **S**=style **G**=grade **F**=facet dial
**D**=dither dial live) · **9 STYLES** (the same scene in all four presets,
side by side). Pages 1–3 are round-2 chargen2; 8–9 are the round-2 terrain
demo.

## 2. Architecture (what carries the aesthetic)

Everything is a **pure function of (seed, knobs)** — same seed, same pixels,
forever. Generation is dev/render class (D040): built in draw on demand,
uploaded to a texture, never sim state (proved: 60f `record→verify` PASS with
the heavy bake in draw).

```
prng.lua     splitmix64 stream + stateless hash2(seed,x,y)   [NOT cm.rand —
             art gen must never touch the sim stream]
pnoise.lua   value noise / fbm / worley over hash2, in two modes:
               world-space  — seam-free across regions BY CONSTRUCTION
               periodic     — a single tile that wraps against itself
palgen.lua   hue-shifted shading ramps: shadows rotate toward violet + gain
             saturation, lights rotate toward warm cream + lose it. ONE color
             logic for every character and material = the sheet-wide coherence.
chargen.lua  round-1 characters, 24x32 (kept for in-game-scale crowds;
             also owns MOODS + the sel-out pass chargen2 shares)
chargen2.lua round-2 characters, 48x64 anime-ish + the baked CAST (below)
mobgen.lua   cosmic-creature mobs: Bollinger half-mask templates + the cute
             stamp (body-aware eyes/catchlight/blush/glow) — see §5
tilegen.lua  materials + the marry bake + round 2's STYLE system (below)
main.lua     the gallery cartridge (sim state = {page, seed} + the style/
             grade/facet/dither knob indices, all input-edge driven)
```

### Characters (`chargen.generate(seed, knobs) → img, design`)

- **Baked archetype menus** — the "sprinkle of baked choices": 7 hair styles,
  4 outfits, 7 head accessories, 5 back items (wings/tails), 3 fringes. Each
  is a ~10-line pixel stamp with procedural sub-knobs (lengths, sway, colors).
- **Procedural everything else** — head/body proportions, stature, palettes
  (hair hue free; outfit hue by scheme: mono/complement/analogous/triad; iris
  complements hair; pastel bias 60%), stocking/sleeve/skin rolls.
- **The MOOD dial is the personality**: eye style (round/half/sharp/droopy/
  closed) + brow angle + mouth (open/cat/flat/small/frown/smile) + blush
  level + look-aside. Presets: cheery smug sleepy cool shy grumpy sunny.
  The white **catchlight** is the cuteness carrier; "cool"/"sharp" deletes it.
- **Sel-out outline**: border pixels take a darkened, hue-cooled version of
  what they border — never flat black (black flattens cute art).
- **Knob-pinning rule**: every choice consumes its rng roll even when a knob
  overrides it (`pin()`), so `generate(seed, {mood="smug"})` is the SAME girl
  with one thing changed. This is what makes a designed cast member (pin
  hair+outfit+palette, leave the rest to the seed) coexist with a crowd.

### Tiles & marrying (`tilegen`)

- A **material is a pixel function** `shade(seed, x, y, per, sd)` over world
  coordinates: rock (worley facets + crack lines + per-facet tone), dirt
  (fbm + speckle), grass (v-stretched blade noise), sand (noise-swept dune
  bands), brick (running bond + bevel + per-brick tone), void (dark fbm +
  stars + masked energy veins). All feature periods are powers of two so
  **periodic mode wraps exactly** (the TILES 3x3 proof).
- **The marry bake** (`tilegen.bake(grid)`): each tile contributes a bilinear
  **indicator field** for its material; each material's field is perturbed by
  its **own** low-freq noise; the pixel takes the argmax. Near-ties dither by
  Bayer threshold — a pixel-art transition band, never an alpha blend.
  Borders wobble organically and identically on both sides of any tile edge
  (world-space hashing again). **"air" is a material too**, so ground
  silhouettes wobble the same way.
- **Surface pass**: per-column distance-to-air feeds rim light (rock crest,
  sunny grass) and grass tufts poke INTO the air. This is what makes the
  terrain page read as a place, not a texture swatch.

## 3. Round-1 verdict (agent's read — human's taste pass pending)

- Palette coherence lands immediately (hue-shifted ramps are the single
  highest-value technique — sheet-wide "same universe" feel for free).
- Personality genuinely reads on the MOODS page: same seed, 7 recognizable
  temperaments. Eyes carry most of it; 2px-wide eyes with a lash cap +
  catchlight read at 1x.
- Tiling + marrying both work as designed; the TERRAIN composition with
  surface light + dusk sky is the strongest page — plausibly shippable
  greybox-replacement art.
- Weakest points: outfits below the collar (silhouettes get columnar),
  small accessories at this resolution (a halo is 6 gold pixels), and the
  rock facets still read "cobble" more than the mock's big canyon slabs.

## 4. Where this could go (not committed)

- **Feed the game**: bake married terrain strips for the cosmic greybox maps
  (rim = rock/dirt/grass, gulch = rock/void) behind the M10 pipeline
  (`.spr`/PNG), replacing flat greybox tiles.
- **Portraits**: chargen at 2-3x canvas (48x64) with the same mood dial —
  dialogue-box portraits for cheap NPCs; the cast keeps hand-made art.
- **NPC crowds**: hub background characters from seeds — the procedural cast
  fills the town Vesper/Gemma/Lumi headline.
- **Particles/VFX**: pnoise/palgen feed the deferred M10 procedural sprite
  generator (slash trails, death scatter, dust) — same fabric, different
  consumer.
- **Studio integration**: "generate → hand-finish": a studio command that
  drops a chargen/tilegen result into a .spr as layers for manual polish.

## 5. Deep-research notes (2026-07-03)

Multi-agent research run (105 agents, every claim 3-vote adversarially
verified against primary sources; all survivors were 3-0). What matters:

### Procedural pixel-art prior art

- **Bollinger mask templates** (pixelspaceships → zfedoran/pixel-sprite-
  generator, davebollinger.org): a small integer half-mask (always-border /
  empty / maybe-body / body-or-border) randomized + mirrored — one template
  yields a silhouette family; ~5 numeric style knobs. **Applied: `mobgen.lua`**
  (the MOBS page) — templates authored for STORY.md's mob roster. Gotcha: the
  mirror axis is the mask's inner edge; body mass must hug it.
- **The verified caveat that validates procart's whole design**: Deep-Fold's
  and Lospec's generators (both fetched/verified) admit mask/noise generators
  alone produce *abstract filler needing manual touch-up* — rich
  parameterization (palette, outline style, proportions, accessories) is
  exactly what must be added for personality. That's chargen's mood dial +
  palgen ramps + baked archetypes, and mobgen's "cute stamp" (eyes/blush).
- **Herringbone Wang tiles** (Sean Barrett, nothings.org; reference C in
  `stb_herringbone_wang_tile.h`): square Wang grids leave straight-line seam
  artifacts; herringbone's 1:2 rectangles (≅ hexagonal tiling, 6 edge
  orientations) break them. *Relevant only if we ever ship fixed small
  atlases* — procart's world-space hashing sidesteps repetition entirely
  (nothing repeats, so nothing aligns). Noted, not adopted.
- **GAN sprite generation is a verified negative** (Coutinho & Chaimowicz,
  SBGames 2022 / Graphical Models 2024): works only on modular datasets it
  can memorize; 184–347-image datasets → "unusable" noise. Don't go there.

### Local AI on the available GPUs (8GB RTX 5060 win / 16GB RX 7800 XT nix-lab)

Honest verdict: diffusion never emits true pixel art — **the grid/palette
constraints come from the post-process, not the model**. If we ever want AI
reference→asset:

- **Pixel Art XL LoRA** (nerijs, Civitai #120096): the leading free SDXL
  LoRA; author's own instructions mandate 8x nearest-neighbor downscale.
  Runs on either GPU (ComfyUI CUDA / ROCm — the nix-lab comfyui setup).
- **ComfyUI-PixelArt-Detector** (dimtoneff, active v1.7.3): the complete
  open snapping pipeline (downscale, palette detect/convert, dither) as 6
  ComfyUI nodes; quantization algorithms are all standard + reimplementable.
- **K-Centroid** (Astropulse) — **the most actionable**: per-output-pixel
  k-means over the source tile, pick the dominant cluster centroid. The
  reference implementation is ~3.6 kB of pure Lua (Aseprite extension,
  github.com/Astropulse/K-Centroid-Aseprite) — a direct port candidate for
  a future studio "import image → snap to pixel art" command.
- **Retro Diffusion** (Astropulse, itch.io): strongest purpose-built local
  generator (true grid/palette output, a seamless-Tiling modifier, palette
  transfer; $20 lite / $65 full one-time, runs in Aseprite). Comfortable on
  the RTX 5060 (a 1050 Ti manages 64x64 in ~2.5 min); **Radeon unsupported
  on Windows**, 7000-series-on-Linux supported-but-caveated.
- Recommendation: park AI. Round-1 procgen already beats "reference
  material only" quality for tiles/mobs; revisit K-Centroid when the studio
  grows an import tool, and Retro Diffusion (RTX 5060) if the human wants an
  AI ideation channel inside Aseprite.

### LLM/agent art-direction tooling

**No surviving verified claims** — the strand produced nothing established
(aseprite MCP servers exist but nothing passed verification as more than
experiments). Conclusion: our own loop (llm-feed taste passes + the studio +
procart's knob galleries + agent-side screenshot self-review) *is* the
current state of the art for this workflow. Keep investing in it.

## 6. Round 2 (2026-07-03): the style system + the 48x64 cast

### Terrain styles (`tilegen.style(preset, grade, over)`)

A **style instance** is a bundle of dials every material shade fn reads —
facet size, strata strength/height, contrast (ramp value-range expansion),
texture amplitude, marry dither band, border wobble, rim-light strength,
crevice mode, palette sat/val, hue swing — plus a per-instance cache of
**graded ramps**. A **grade** (day / dusk / dread) rotates every material's
HSV anchors toward an hour-of-day hue and scales sat/val *before* the ramps
are built, and carries the sky gradient stops the demo pages use. Presets:

- **soft** — the round-1 cobble look, still the default (round-1 pages
  render identically).
- **canyon** — the mock: rock switches to a **strata-slab path** — wobbled
  horizontal shelf lines, each course split into big slabs on a running
  bond (per-course widths + offsets), calm per-slab tones, near-black
  crevices, warm sun-lit crest. Canyon strata read as giant irregular
  brickwork, and drawing them that way beats worley for this. (Worley
  stays for wrap tiles — banding can't wrap for free — and for `soft`.)
- **painterly** — ragged borders (big wobble + wide dither band), heavy
  hue swing, more texture.
- **flat** — Wadanohara-ish cel: low texture, crisp borders (tiny dither
  band), low contrast, crevice lines doing the outlines.

`facet_mul`/`band_mul` are the live-dial hooks (the CANYON page's F/D keys).
Learned in the making: **grading belongs on the palette anchors, not the
pixels** (ramps stay bandy and exact — a LUT post pass would blur the
carefully banded colors), and the dusk grade wants *gentle* saturation
(1.04; the first attempt at 1.12 turned every brown pink).

### Characters (`chargen2.generate(seed, knobs)`, 48x64)

Same contract as chargen (pure of (seed, knobs); pin() consumes rolls so
pinning never reshuffles the seed's other choices — proven over 50 seeds).
What doubling the resolution actually bought:

- **The eyes carry the anime read**: a 5-wide iris shaded dark(top) →
  light(bottom) under a heavy lash cap, 2x2 catchlight high-outer, 1px
  reflection low-inner. Sharp (Vesper) deletes the catchlight — deadpan is
  the absence of the cuteness carrier, same trick as round 1.
- **The cast is baked as knob bundles** (`M.CAST`), not as code forks:
  vesper/gemma/lumi are ~15 pinned knobs each over the same generator, plus
  three identity stamps in the baked menus (fin crest, curved horns + wing
  silhouettes, kinked bunny ears + S-curve twintails) and three outfit
  builders (armor/bodysuit/idol). Crowds keep rolling the civilian menus.
- **Body types** (slim/std/soft → head/body widths) + stature + a pinnable
  legs knob (skin/stock/dark) — cheap silhouette variety.
- Gotcha that cost a debug session: helper arg order (`hline(img, x0, x1,
  y)`) — a transposed call painted the hair-cap dome into the torso as a
  "mystery wedge" on every character. Pixel-dump + knob-bisect found it;
  eyeballing the code did not.

### Round-2 verdict (agent's read — human's taste pass pending)

- The canyon/dusk CANYON page is the closest procgen has come to the mock;
  the four presets are genuinely distinct on the STYLES page and the grade
  dial (esp. **dread**) is the cheapest mood lever we own.
- TRIO at 48x64: all three identities read at a glance (horns/bunny/fins
  do heavy lifting). MOODS still proves personality at the new res.
- Weakest points now: outfit interiors below the collar still read simple
  (flat panels; the refs have folds/trim), Gemma's wings read as epaulette
  stripes behind the hair sheet, and crowd characters share one silhouette
  family (three body types is not many).
