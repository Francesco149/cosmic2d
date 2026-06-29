# Map design pages

One file per **map** (cosmic2d's unit: a self-contained space connected by
portals, GAME.md §1/§4). Each page carries: the story/quest beat, the **movement
identity** (which of the moveset §4 the map is *about*), the gimmick, a
**zone-by-zone layout**, the quests/secrets/collectibles, the mobs it uses, the
set-piece, dialogue sketches, and **scope notes** (what it reuses; what it must
not become). Mirrors the proven one-pager format from the 3D project's
`docs/levels/`.

These are **design targets, not contracts** — built greybox-first (procedural
tilemap + primitives in the editor), feel-tuned, then dressed with real art once
the human pixels it. When a built map diverges from its page, the map wins; fix
the page. Story + cast context: [`../STORY.md`](../STORY.md).

Reading order = play order (the opening arc):

1. [Rim Hub — "First Survey"](rim-hub.md) — hub + tutorial; Q1, meet Lumi
2. [South Trail — "The Long Light"](south-trail.md) — first region; Q2 (Lumi) + Q3 (Gemma)
3. [Whisper Gulch — "The Whisper Below"](whisper-gulch.md) — vertical gym; Q4, first dread beat

**Scene scripts** (full staging + dialogue): [`rim-hub.scenes.md`](rim-hub.scenes.md)
· [`south-trail.scenes.md`](south-trail.scenes.md).
**Greybox** (walkable blockout + the plan overlay): `projects/cosmic/` — run
`bin/cosmic projects/cosmic`; geometry + markers in `projects/cosmic/maps/*.lua`.

*Later areas (mock board, not yet designed):* Echo Falls, Echo Reach, Sun Vault,
Night Cave, Blue Garden Spring, Fold Observatory, Raven Exchange, Bright Inside.

## Shared conventions

- **Platforms** are one-way (jump-through) interior, solid bottom/top — the
  engine's existing tilemap (GAME.md §4 "Platforms", D024). Design *up*.
- **Portals** connect maps (press Up). Trailhead-sign portals light up as they
  unlock; the Rim is the hub they all fan out from.
- **The vista does tutorial work** — the canyon on your shoulder telegraphs
  "you'll go down there" without text (3D `rim.md` lesson; teach by terrain).
- **Economy:** mobs drop **stardust** (currency) + farmables; secrets hide behind
  hidden portals, movement-gated nooks, and breakables (GAME.md §8). 100% is for
  love, not progress — main-path traversal alone always opens the next portal.
- **Sandbox** prop-spawning is **always on in the hub**; gated elsewhere until a
  map's questlines are cleared (GAME.md §2/§7).
