# procart — the procedural pixel-art experiment

> Status: round 1 shipped 2026-07-03 (ADR D044). **An experiment, explicitly
> allowed to fail**: it may be promoted into the cosmic asset pipeline, mined
> for parts, or abandoned for hand-made art in the studio (M10). The human's
> taste pass on the llm-feed gallery decides.

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
bin/cosmic projects/procart        # gallery: <-/-> or 1..5 pages, R rerolls
```

Pages: **1 CAST** (12 seeds) · **2 MOODS** (one seed, every mood knob — the
personality proof) · **3 TILES** (repeating tile + 3x3 self-tile proof) ·
**4 MARRY** (hard seam vs married border) · **5 TERRAIN** (a composed material
map under a dithered dusk sky — the "could this be a game?" shot).

## 2. Architecture (what carries the aesthetic)

Everything is a **pure function of (seed, knobs)** — same seed, same pixels,
forever. Generation is dev/render class (D040): built in draw on demand,
uploaded to a texture, never sim state (proved: 60f `record→verify` PASS with
the heavy bake in draw).

```
prng.lua    splitmix64 stream + stateless hash2(seed,x,y)   [NOT cm.rand —
            art gen must never touch the sim stream]
pnoise.lua  value noise / fbm / worley over hash2, in two modes:
              world-space  — seam-free across regions BY CONSTRUCTION
              periodic     — a single tile that wraps against itself
palgen.lua  hue-shifted shading ramps: shadows rotate toward violet + gain
            saturation, lights rotate toward warm cream + lose it. ONE color
            logic for every character and material = the sheet-wide coherence.
chargen.lua characters (below)
tilegen.lua materials + the marry bake (below)
main.lua    the gallery cartridge (sim state = {page, seed} only)
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

*Pending — the research workflow's findings land here: procgen-heavy pixel
art prior art, local-AI-model assessment for the available GPUs, and
LLM/agent art-direction tooling.*
