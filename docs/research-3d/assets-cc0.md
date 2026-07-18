# Research: verified royalty-free assets for bundled demos

(agent-researched 2026-07-16; every license read on the actual page, not snippets)

## Safe to bundle (verified CC0)

- **Kenney.nl** — site-wide CC0 ("public domain licensed (CC0) … even commercial
  projects", kenney.nl/support). Retro-fitting 3D kits: **Nature Kit** (~330 models),
  Fantasy Town Kit, Modular Dungeon / Mini Dungeon, Graveyard Kit, Castle Kit,
  Pirate Kit, Modular Cave Kit. Formats per pack: GLTF/GLB, OBJ, FBX. Characters
  mostly unanimated — use Quaternius/KayKit for those.
- **Quaternius** (quaternius.com) — CC0 stated per pack. **Ultimate Animated
  Character Pack** (52 animated characters; FBX/OBJ/Blend, newer packs also GLTF),
  Universal Base Characters (rigged, retargetable), Universal Animation Libraries
  (250+ anims), RPG Character Pack, Ultimate RPG Pack, Modular Men/Women.
  Best CC0 source for rigged+animated low-poly humanoids. Also per-model via
  poly.pizza/u/Quaternius.
- **KayKit** (kaylousberg.itch.io) — CC0 verified on both packs fetched ("Free for
  personal and commercial use, no attribution required. (CC0 Licensed)"; the
  "please don't resell unmodified" line is a non-binding ask). **Dungeon Remastered**
  (200+ assets; FBX/GLTF/OBJ; free), **Adventurers** (5 rigged+animated characters +
  25 weapons; FBX/GLTF; free tier only is bundlable). Best single style match for an
  N64 fantasy demo. GitHub releases exist: github.com/KayKit-Game-Assets.
- **Screaming Brain Studios** — all packs "CC0/Public Domain … redistributed however
  you like." **Tiny Texture Pack 1/2/3** (375+ seamless tiling textures at
  512/256/**128px**: brick/wood/tile/roof/grass) — closest match to the 64×64 retro
  brief (downscale 128→64).
- **Elegant Crow — Retro PSX Style Tree Pack** (elegantcrow.itch.io) — CC0 verified.
  36 trees (52 tris each) + 8 bushes (16 tris), pixelated textures. FBX only.
- **ambientCG** — CC0 verified ("You can include the raw files in your project").
  Photoreal, wrong vibe raw, but free to downscale/posterize into PSX textures and
  redistribute derivatives.
- **Retro3DGraphicsCollection** (github.com/Miziziziz/Retro3DGraphicsCollection) —
  curated list, policy: everything CC0 or commercial-no-attribution; deliberately
  PS1-styled (rigged knight, villagers, sorcerer, nature, skyboxes). Spot-check each
  linked asset.
- **OGA CC0 8-direction sprites**: "Hand-Drawn Square Characters Animated 8 Directions
  Top Down free cc0" (4 characters, 128×128, idle/walk/jump, 8 dirs); pre-rendered-3D
  "Super Clone Cyborg" isometric sheet (8 dirs × 32 frames) — pre-rendered sheets are
  exactly the RO look.

## Flagged / avoid for bundling

- **Elbolilloduro PSX pack** (huge: 20 chars, buildings, 100+ food items; .dae+.png):
  models CC0 **but bundled textures derive from Textures.com — not redistributable**.
  Usable only after retexturing.
- **Pizza Doggy PSX Mega Pack** (€9.97, 490+ assets): custom license PDF, assume
  no-redistribution. Not bundlable.
- **loafbrr** packs: license per-pack, often only stated inside the download; paid
  packs assume non-redistributable.
- **LPC sprites** (OpenGameArt): CC-BY-SA/GPL — redistributable but share-alike
  infects demo assets + big attribution burden. Quarantine or skip.
- General itch.io warning: "free"/"royalty-free" usually means "use in your compiled
  game," NOT "redistribute raw assets." Only take packs whose page says CC0/CC-BY.

## Strategy for RO-style sprites with zero license risk

Render our own 8-direction sheets from Quaternius/KayKit CC0 animated models
(8 camera angles, low-res, unfiltered) — or from the engine's own rigid-part
figures: output stays CC0-equivalent, matches the engine's own look, and doubles
as a built-in engine feature (figure → sprite sheet baker).

## Bottom line

Kenney + Quaternius + KayKit + Screaming Brain Studios covers environments, animated
characters, and retro textures entirely under verified CC0 with zero attribution
obligations. Add Elegant Crow trees for PSX foliage.
