# MAPS.md — the map system (R8, D057)

> The map rework the human asked for before the graybox continues
> (2026-07-12): **maps stop being pure tilemaps.** Collision becomes a
> **collider layer** (line chains, slopes included); visuals become
> **freehand sprite placement**, with tilemaps demoted to *one placeable
> object kind* that behaves like a single baked sprite (editable in its
> own tile editor). Maps get a real **map window** on the canvas —
> drag assets in from the picker, drag placements around, double-click
> into the right editor, **CTRL = snap** (confirmed; no snap by
> default). Colliders are **typed gizmos** (line one-way / line solid
> / quad / circle), freehand on the collider layer or **attached to a
> placed object** so solid props move as one thing. This doc is the
> design; ADR **D057** (+ addendum) is the binding decision. The F1
> world editor (`cm.editor`) dies here, as EDITOR.md §12.6 prophesied.

## 1. Why (what pure tilemaps cost us)

The current model (`cm.tilemap`): one u16 grid per map is *both* the
collision truth and the visual, maps are procedural Lua (`M.build(tm)`),
F1 pokes cells through EVAL, nothing persists as an editable asset.
That shape blocks exactly the things the game wants next:

- **No slopes** — the canyon setting is all rims and switchbacks, and
  the grid can only do stairs.
- **Art is grid-shackled** — decor/parallax were "deferred slots"
  because nothing non-grid *can* be placed.
- **No editing workflow** — maps aren't assets, so the R3–R6 editor
  (working copies, journals, undo-forever, rewind) can't touch them.

The new model splits the three concerns a map actually has:

| layer         | what                                        | who reads it |
|---------------|---------------------------------------------|--------------|
| **colliders** | line chains w/ slopes; solid or one-way     | the sim      |
| **visuals**   | freehand placements (sprites, images, tilemaps) | render only |
| **markers**   | rects w/ kind+keys (spawn/portal/prop/arena…) | game logic  |

Placements never collide *by themselves* — but a collider can be
**attached to a placement** (§3: refined by the human, 2026-07-12), so
a solid prop / awning / platform sprite moves as one thing when the
map gets redesigned. Colliders never render in-game (in the editor
they're **always-visible gizmos**, §6; the graybox fill is §5); markers
drive spawns/triggers. Collider edits reach the sim through one
recorded path (§9).

## 2. The map asset (.map, CMAP)

A map is a **file asset** like a sprite — `maps/rim_hub.map` — a
`cm.chunk` container (skip-tolerant, versioned):

- **HEAD**: name, bounds w/h px, bg tint, grid step (the map's own
  snap default), version.
- **COLL** (one per *free* collider): shape (u8: **chain | quad |
  circle**), flags (u32: solid|oneway|closed), material (u8, future),
  then the geometry — chain: vertex count + verts as **i32 px pairs**
  (integer px — colliders sit on pixels; slopes come from
  non-axis-aligned segments, not fractional coords); quad: x/y/w/h
  i32; circle: cx/cy/r i32.
- **PLCE** (one per placement, file order = z order): layer id (u8),
  flags (u32: bit0 flip_x, bit1 hidden — an authored hide toggle; the
  fill/places draw skips hidden), x/y i32 px, path (project-relative;
  `.spr`, `.png`, or `.tm`), an **optional name** (string, empty = anonymous —
  names exist to address placements from code, §4), then **0..n
  attached colliders** (same encoding as COLL, coords **relative to
  the placement origin** — they ride the placement when it moves).
- **LAYR** (optional, future): named layers with parallax factors.
  V1 renders one implicit layer; the format carries the slot so
  GRAYBOX's deferred parallax/decor lands here without a version bump.
- **MRKR** (one per marker): rect i32 px, kind (string: spawn / portal
  / prop / arena / poi / secret / shop / npc…), label, note, extras as
  flat k=v string pairs (`to=south_trail at=from_rim`).
- **TAIL**: integrity.

The tilemap object (**.tm, CTLM**): HEAD (w, h, tile_px, tileset path —
a `.spr` whose **frames are the tiles**), GRID (u16 ids, row-major, 0 =
empty), TAIL. A `.tm` is *pure visual*: placed like a sprite, moved as
one unit, no collision. Its collision, if wanted, is drawn as collider
chains like everything else's.

Canonical encode/decode lives in `cm.map` / `cm.tmap` (pure, KAT'd,
sibling of `cm.sprite`).

## 3. Collision — `cm.collide`

New engine module; `cm.tilemap` keeps grid+draw for `.tm` rendering and
**loses its mover role** (the `TM:move` sweep survives verbatim until
smoke+game migrate, then dies).

**The collider roster** (refined by the human, 2026-07-12 — typed
primitives, freehand or attached):

| type            | what                                            | mover sweeps it |
|-----------------|-------------------------------------------------|-----------------|
| **line, solid** | open chain; blocks **both ways** (walls, thin floors/ceilings) | yes |
| **line, one-way** | open chain; support from above only; sloped ok; `opts.drop` passes | yes |
| **closed chain** | polygon solid (interior is ground — the §5 graybox fill) | yes (its edges) |
| **quad**        | rect sugar — stored as x/y/w/h, swept as its 4-edge loop | yes |
| **circle**      | overlap/point queries only in v1 (hazards, entity hit-zones) — the platformer AABB mover does **not** sweep circles | no |

**Free vs attached**: a collider either lives on the map's collider
layer (free — the terrain), or is **attached to a placement**
(relative coords; instanced into the world offset by the placement's
position at load). At sim level the two are identical static geometry
— attachment is an *authoring* affordance: move the prop, its
collision comes along. Attaching offers **auto-fit defaults** read
from the asset's bounds (§6): the canonical case is the one-way
platform sprite — attach "line one-way" and it defaults to the
sprite's full width across its top, then edit points if needed.

**Dynamic bodies** (design slot, built when R7b needs it): game
entities (mobs, carried props) get `cm.collide.body_add / body_move /
body_remove` handles on the world — insertion-ordered, so
deterministic. Not on the R8 static path; props keep their own AABB
logic until then (they swap their *world* queries to cm.collide like
the player does).

**The world** = all instanced static colliders in a named buffer
(§9), plus a deterministic spatial index (coarse grid of segment lists,
**insertion-ordered** — no hash-order dependence) rebuilt on load/epoch.

**Segment classification** by slope, not by authoring mode: for a
walker of max-slope knob `s_max` (default 1.0 = 45°), a segment with
|dy/dx| ≤ s_max is a **floor/ceiling** (by which side the solid is on),
steeper is a **wall**. One-way chains are floors only (support from
above; sloped one-ways allowed — same math).

**The mover keeps the frozen contract** — this is the feel-preservation
guarantee:

```lua
cm.collide.move(world, x, y, w, h, dx, dy, opts) -> nx, ny, hit
-- hit = { left, right, up, down, oneway }  (same shape as TM:move)
cm.collide.grounded(world, x, y, w, h, opts) -> grounded, on_oneway
```

Axis-separated sweep like today: X pass vs walls, Y pass vs
floors/ceilings; on a floor the feet-center column tracks `y = line(x)`
so walking a slope is continuous (plus a **ground-stick probe** of a
few px on descent so walking downhill doesn't become micro-falling —
stick distance = knob, applies only when `hit.down` was true last
axis-pass and vy ≥ 0). All arithmetic: segment interpolation is
mul/div on the endpoints — **no libm, no trig** (ARCHITECTURE iron
rules). `opts.drop` bypasses one-ways exactly as today.

**Queries** (the game's existing probes, generalized):

```lua
cm.collide.stand_ray(world, x, y0, y1) -> y|nil, oneway  -- first standable
   -- floor crossing the vertical ray; grapple_scan + mantle_top ride this
cm.collide.solid_at(world, px, py) -> bool               -- closed-solid test
```

**KAT plan**: flat-world parity (a grid room expressed as chains ==
`TM:move` results, exhaustively over a scripted input set), slope walk
up/down 45°+22.5° (no seam hops, stick holds), one-way slope support +
drop-through, wall-vs-floor classification edges, index determinism
(same world → same buffer bytes). The smoke kitcheck choreography is
the integration proof: it must fire every movement rule on the migrated
room byte-identically frame-for-frame *in behavior* (new golden, §10).

## 4. What the sim sees

`cm.map.use{path=, name=}` (the level.lua successor) decodes `.map` into one
stable named slot with two captured buffers:

- `name`: the collider header + chains/circles;
- `name .. ".mapstate"`: `CMRT v1`, the active path plus canonical CMAP runtime
  bytes (bounds/layers/placements/markers).

`cm.map.current` captures which slot backs `get`/`ref`/`reload`. Decoded docs,
name lookups, render caches, and collision wrappers are derived Lua glue. They
are rebuilt in place through `cm.state`'s universal participant lifecycle after
every table restore, so held instance/world references survive snapshot load,
park, rewind, cross-session resume, and map changes without split state.

This corrects the original “render tables are outside snapshots” decision. Art
*pixels/files* remain project assets (A7 file epochs capture their historical
versions), but the loaded logical map, active-map identity, markers, and
placement transforms are presentation truth and therefore captured. Direct
`cm.map.get(name)` table mutations are flushed at every state-capture boundary;
trace code has no map-specific chunk or restore call.

**Named placements** (human, 2026-07-12): `cm.map.get(name)` → a
handle over a named placement — read its rect, set position /
visibility (captured presentation mutations: doors slide,
signs blink, elevator *visuals* track). If a named placement carries
attached colliders and the game wants to *drive* it, the handle is
the natural source for a dynamic body (§3's `body_*` slot adopts its
colliders); its static instances are skipped at load then. V1 builds
the lookup + render setters; the body promotion lands with dynamic
bodies at R7b.

## 5. Rendering + the graybox language

Draw order per frame: bg tint/parallax (future LAYR) → placements in
file order (`.spr`/`.png` = one quad; `.tm` = the existing culled
batched-quads path per visible cell — "behaves as one baked sprite"
means *placement/move/z as a unit*, not literally pre-baked; a real
bake is a later optimization if profiles ask) → game entities
(interleave point: a placement layer flagged `fg`, future) → fx.

**The graybox needs zero visual assets**: the collider layer renders
directly — closed solids as **flat untextured polygon fills** (the
human, 2026-07-12: the fill visual doesn't matter much — a plain poly
with the gizmo is enough; the GRAYBOX.md checker parity is optional
polish, not a requirement), one-ways as the slim accent slabs. Art
later = placements stacked on top, then the collider fill switches
off (per-map flag). This keeps R7b unblocked the moment colliders
edit (§11) — tilemaps (.tm) aren't on the graybox critical path at
all. **End state re-confirmed (human, 2026-07-13, on the walked R8e
maps): colliders render NO visuals in the game — sprites and placed
tilemaps make all the visuals; colliders exist only as editor gizmos.
The in-game fill is temporary MVP scaffolding.**

**Built (same day)**: the per-map switch is the optional **FLGS**
chunk (bit0 `nofill`; `draw_fill` no-ops on it — editor gizmos
unaffected), toggled by the map inspector's **fill** chip. The
**graybox** chip next to it takes a collider blockout to the end
state in one click: `cm.tmap.graybox` rasterizes the FREE colliders
into `<map>_gb.tm` over the stock tileset (closed solids fill by
cell-center column intervals and autotile — 1 top / 2 interior /
3 left / 4 right / 5 slab / 6 pillar; one-way segments lay slab
cells; attached colliders skip — their placements carry their own
visuals), places it at 0,0 as the bottom placement (`name=graybox`)
and flips `nofill` on. Re-clicking regenerates from the current
colliders. Both game maps run this way.

## 6. The map window (kind `map`)

A canvas window like sprite ed (EDITOR.md §12.6 idioms throughout):
opens via asset-picker double-click on a `.map`, the spawn menu, or
drag-out; keyed by path; multiple maps open fine. A spawn-menu window
starts unbound: drag a `.map` in to bind it, or type a path into its
field — a path with no file **creates a fresh map** (project design
res, grid 8) whose first Ctrl+S writes the file (built at R8b).

- **View**: own camera — wheel = zoom at cursor, middle-drag = pan
  (`kind.takes_middle`), shift+1 fit. Zoom % chip. **Focused = the
  view lock** (the human's ask, built with R8c; EDITOR.md §12.7):
  while the window is focused its camera takes wheel + middle-drag
  from anywhere on the canvas — priority over canvas zoom/pan; any
  canvas action or Esc unfocuses; an accent border + EDITING chip
  make the lock unmissable. **Focus is the one gate**: an unfocused
  map window's view is inert (no hover wheel/MMB — Esc actually lets
  go), and **any press or wheel outside the window releases the lock
  the moment it happens** (own resize band excepted; ALT stays the
  canvas layer). View state rides `cm.ed.winview` (world units,
  EDITOR.md §12.9). The map draws
  exactly as the game renders it, plus **collider gizmos — always on
  by default** (the human's call): solid lines in the accent, one-ways
  dashed, quads/circles outlined; attached ones tinted dimmer until
  their object is selected. Header chips toggle gizmos / markers /
  the graybox fill.
- **Working state = the CMAP bytes**: `doc.assets[path] = { map =
  <bytes>, jpos }` — the §6 EDITOR.md three-layer model verbatim:
  dirty = bytes ≠ disk, journal = CMAP snapshots (cap 512), one gesture
  = one entry, Ctrl+S/Z/Y, revert-as-edit, restart survival + rewind
  (EDOC) for free. Decoded doc + spatial index = ephemeral plumbing
  keyed by path.
- **Tools** (header chips, sprite-ed style): **select** (default) ·
  **collider** · **marker**. `wants_keys` while focused (del/arrows
  belong to the tool, not the shell).

**Select tool** (placements + markers):
- click = select topmost under cursor; shift+click = add; drag on
  empty = marquee; still-click empty = clear (the shell's own grammar,
  echoed inside).
- drag selection = move (CTRL = snap, §7). Arrows nudge 1 px, shift
  ×8. Del deletes. `]`/`[` = z within the layer (placement order,
  multi-selections move as a block, order kept), matching the canvas
  z keys.
- **clipboard + view (the gap-fill round)**: Ctrl+A selects every
  placement + marker; Ctrl+C/X copy/cut the selection (deep copies on
  an ephemeral shell clip — pasted placements drop their `name`, names
  address uniquely from code); Ctrl+V pastes centered under the cursor
  when it's over the view (grid-step offset otherwise); Ctrl+D
  duplicates in place (+grid step). Shift+1 = fit map, **Shift+2 =
  fit the selection** (or the selected free collider). The inspector
  grew: placement **layer** + **hide** (persisted, PLCE bit1), the
  map's **name**, and exact **x/y/r fields for circles**.
- **double-click a placement** → `ed.open_asset_window(path)` — the
  sprite ed / image window / tilemap ed, next to the map window
  (assets.lua's 320 ms convention). Double-click a marker → its
  inspector focuses.
- **drag-in from the asset picker**: the existing `g.adrag` carry;
  the map kind takes a new **`kind.drop(win, ed, path, wx, wy)`** hook
  — release over map content **places** at the drop point (CTRL
  snapping live during the carry) instead of rebinding. `accepts`
  stays the rebind predicate and answers only `.map` (retarget the
  window); `.spr`/`.png`/`.tm` route to `drop`. Shell change: on
  release, prefer `kind.drop` when the kind has one and it claims the
  path. OS file drops over the map window place the same way (copy
  into the project first, the assets-window path).
- **Attached colliders** (the human's refinement): a selected
  placement shows its attached colliders' handles — **editable only
  while the object is selected** (visible-but-inert otherwise). The
  inspector grows a **+col** button with a type picker (line one-way /
  line solid / quad / circle) that **auto-fits from the asset's
  bounds** — one-way: a line across the sprite's top at full width;
  quad: the bounds; circle: inscribed — then handles/points edit as
  usual. Del with a handle selected removes the collider.
- **Inspector strip** (window bottom, one row): selection's x/y
  (editable x_ig_edit fields), an optional **name** field (§4 code
  addressing), layer chip, flip_x toggle, **+col** — markers swap in
  kind/label/extras fields. With **nothing selected** (select tool)
  the strip shows the MAP's own fields — **w / h / grid / bg** ("r g b"
  tint floats) — so a fresh spawn-menu map can be sized and tinted
  without leaving the editor (an R8e catch: fresh maps were stuck at
  the project res).

**Collider tool** (free colliders — the terrain layer; attached ones
edit through their object, above):
- type chips on the strip: **line / quad / circle**, plus the
  solid/one-way flag (one-way applies to lines).
- click = select the nearest collider (edge); vertices/handles show.
  Drag a handle = move vertex (quad corners / circle radius likewise);
  drag an edge = move the whole collider; **click an edge of the
  SELECTED chain inserts a vertex**; del = selected vertex (whole
  collider if none).
- **draw**: line — press on empty starts a chain, each click appends
  a vertex, **Enter/double-click ends open, C closes** (closed+solid =
  fillable ground); Esc cancels. Quad/circle — drag out. CTRL snaps
  every placed vertex/edge (§7). **A CTRL press always draws** (built
  at R8c): the pick radius would otherwise eat the snap zone, and
  drawing a slope FROM the ground line is the canonical case — plain
  press picks, CTRL press starts a snapped draw from anywhere.
- The whole gesture set journals per gesture (vertex drag end = one
  entry).

**Marker tool**: drag = new rect; select/move/resize like placements;
inspector edits kind/label/note/extras (`k=v` pairs, one line).

## 7. Snapping — the CTRL grammar

The human's ask verbatim: snapping lives on CTRL so alignment never
means nudging pixels. **Plain drag = free px. CTRL held = snap**, at
any point during the gesture (press CTRL mid-drag to engage). Matches
the existing family: CTRL already means "the precise variant"
(resize-to-multiples, size dials) and already gates the pointer off
imgui, so CTRL+gestures reach the kind cleanly.

Snap resolution, strongest first, threshold ~6 px-at-zoom:

1. **vertices** — collider vertices + placement corners near the
   cursor (align art to collision and chains to each other);
2. **edges** — nearest collider line / placement edge (slide along
   it); placements also snap edge-to-edge and center-to-center with
   neighbors (butting decor together seamlessly). Over a placed
   tilemap, its **tile edges** (the .tm grid at the placement's
   offset) are edge targets too — line colliders click onto tile
   boundaries;
3. **edge-run** (the human's shorthand, line tool over a tilemap):
   CTRL-hovering a solid tile's exposed edge proposes **the whole
   contiguous run** — the preview line spans left/right until the
   tiles stop — and one click lays the full segment. Long straight
   sections in one click instead of two snapped vertices. *(Lands
   with R8d, when .tm placements exist.)*
4. **45° lock** — while *drawing/dragging collider vertices*, the
   segment to the previous vertex locks to 0/45/90° when no stronger
   snap hits (classic slope authoring);
5. **grid** — the map's grid step (HEAD default 8 px; **ctrl+wheel
   dials it** — the map ed's `kind.ctrl_wheel`, per-window override in
   `win.grid`).

Active snap draws its guide (the teidraw-style thin line / highlight
dot) so the lock is always legible. Marquee + resize snap the same
way.

## 8. The tilemap window (kind `tmap`)

Opens on `.tm` double-click. Sprite-ed idioms: wheel zoom / MMB pan,
edit toggle, working CTLM bytes in `doc.assets`, journal cap 512.
V1 roster: tile palette strip from the bound tileset (`.spr` frames) ·
paint / erase / rect-fill · grid resize (grow/crop fields) · pick
(eyedrop a cell). Retarget tileset = inspector field. Not v1:
autotiling rules, multi-cell stamps, animated tiles (format leaves
room; D057 records the gap). Ships in R8d, after the graybox path —
nothing in §5 needs it.

## 9. Live loop, determinism, rewind

The **sprite precedent verbatim** (EDITOR.md §12.6): editing touches
working bytes only; **Ctrl+S saves the .map and the running game
hot-reloads it** — `cm.map.reload` rides the recorded EVAL path and publishes
the collider plus map-runtime buffers together, so traces replay map changes
and **rewind scrubs across them** (a rewound frame shows the old cliff *and*
its matching placements/markers). Re-running `cm.map.use` for the same stable
slot/path adopts captured state; `fresh=true` is the explicit reset-to-disk
operation. Unsaved map edits
are visible in the map window but not the sim — the map window is
authoring, the game window is truth; "apply live on gesture end" is a
possible later toggle, not v1 (§12).

Goldens: assets are committed files; headless loads them; the runtime buffers
make the loaded logical map part of trace truth. The determinism sweep: no wall-clock, no libm, ordered
iteration everywhere (chains/placements are arrays; the spatial index
is insertion-ordered), collider buffer canonical.

## 10. Migration (and the deliberate golden re-cut)

- **smoke** first: `projects/smoke/room.map` authored to reproduce the
  current room 1:1 (flat chains on the old tile edges), level.lua →
  `cm.map.use`. The kitcheck choreography re-records → **goldens
  re-cut once, deliberately** (like R0; an *unexpected* break stays a
  bug). Smoke's player.lua swaps `tm:move` → `cm.collide.move` — same
  contract, mechanical.
- **game maps**: rim_hub + south_trail re-authored as `.map` **in the
  map editor itself** (the dogfood pass — building two real maps is
  the UX exit), markers carrying spawn/portals/prop_spots; `maps/*.lua`
  + level.lua build code die; player.lua mover swap as smoke. The
  graybox look = §5 collider fill.
- **`cm.editor` (F1) + `cm.tilemap`'s mover die** once both are over.
  *(R8e outcome: `cm.tilemap` died WHOLE — R8d's `cm.tmap` had already
  taken `.tm` grid+draw, so nothing kept it alive. cm.inspect stays,
  hostless, awaiting a canvas-window host.)*

## 11. Build order (R8a–R8e) + exits

- **R8a — format + collision core** ✅ **BUILT (2026-07-12)**:
  cm.map/cm.tmap codecs (KAT'd), cm.collide (mover parity + slopes +
  queries, KAT'd), the collider buffer + `cm.map.use`, collider-fill
  render; smoke migrates, goldens re-cut. *Exit*: suite ALL GREEN on
  the .map smoke; a slope test room walks/slides correctly in a
  headless capture. *(Hit: the 830-frame kitcheck track BIT-IDENTICAL
  old mover vs new; the slopes.map walk grounded every frame; selftest
  22753→23653; three llm-feed shots.)*
- **R8b — the map window, select/place** ✅ **BUILT (2026-07-12)**:
  view + working-state/journal plumbing, select tool end-to-end
  (move/nudge/z/del/marquee), `kind.drop` drag-in, double-click-to-
  editor, inspector, CTRL snap for placements, save→hot-reload.
  *Exit*: scripted --edit capture: drag a sprite from the picker onto
  the map, snap-align it to a ledge, Ctrl+S, the game window shows it;
  undo/restart survival proven. *(Hit: the CTRL vertex snap landed the
  drop exactly on the platform end; the recorded cm.map.reload EVAL
  hot-reloaded the running game in the capture; unsaved placement
  survived a restart and walked back through undo/redo; selftest
  23653→23684; kitcheck re-cut = code-bundle refresh only, FRAM
  chunk-stream proven byte-identical; 2 llm-feed shots. Bonus beyond
  the letter: an unbound map window creates a fresh .map from a typed
  path — the R8e authoring door.)*
- **R8c — collider editing** ✅ **BUILT (2026-07-12)**: the collider
  tool (line/quad/circle, draw/insert/drag/flags), **attached
  colliders** (+col auto-fit, selected-only editing, gizmo tinting),
  45° lock + vertex/edge snap, marker tool + inspector. *Exit*: author
  a new slope in a live session, walk it in the game window; attach a
  one-way to a platform sprite and move them as one; the whole edit
  rewinds and comes back. *(Hit, driven through the REAL event path —
  a scripted tape into pal.poll_events: CTRL edge-snap landed v1
  exactly on the ground top, the 45 lock trued the segment, ctrl+s
  hot-reloaded and the player walked the slope grounded; +col's
  one-way rode a real drag to (520,239) and stand_ray answered there
  after reload; parked at frame 3 the map window showed the pre-edit
  doc and scrub-close brought it all back. Bonus: the focus view lock
  (the human's ask — own pan/zoom priority, EDITOR.md §12.7). Two
  proof catches fixed: CTRL-press-draws, parked g.mw plumbing.
  selftest 23684→23732; suite ALL GREEN, goldens untouched; 4 llm-feed
  shots.)*
- **R8d — the tilemap window** (§8) + the **edge-run snap** (§7)
  ✅ **BUILT (2026-07-12)**. *Exit*: build a small .tm from a tileset
  .spr, place it, edit it through double-click, journaled; trace a
  collider run along its top in one click. *(Hit, the R8c tape idiom —
  real events into pal.poll_events, 15/15 PASS: real strokes painted
  deco.tm (pen + palette click, one gesture = one journal entry,
  ctrl+z/y walked it, ctrl+s wrote disk == working bytes); kind.drop
  placed it at exactly (200,224) on room.map; a real double-click on
  the placement opened its editor; collider tool + CTRL hover proposed
  the whole exposed run and ONE click laid exactly that chain
  (264,272)-(296,272); map ctrl+s → the recorded reload → stand_ray
  answers on the laid run and the game window draws the tiles. Save =
  cm.asset_epoch bump (pure visual — no recorded EVAL needed); tile
  edges joined snap_targets/snap_rect via the opts.tm hook; smoke grew
  art/tiles.spr. selftest 23745→23761; suite ALL GREEN, goldens
  untouched; shot on llm-feed.)*
- **R8e — the game migration** (§10, in ../cosmic2d-game): both maps
  re-authored in the editor, movement/feel re-checked (the human),
  legacy map code deleted both repos. *Exit*: the human walks both
  .map maps and R7b resumes on top. ✅ **BUILT (2026-07-13), awaiting
  the human's walk.** *(Hit: rim_hub + south_trail authored end to end
  through the REAL editor event path — the R8c/R8d tape idiom grown to
  full-map scale (spawn menu → path field → the new map w/h/grid/bg
  inspector fields → CTRL-snapped quads/one-way chains → markers with
  kind/label/note/extras TYPED via the new `pal.x_ig_event` capture-io
  mirror → ctrl+s); both saved CMAPs byte-identical to the intended
  docs (124 + 95 checks, 0 FAIL). Game migrated onto cm.map/cm.collide
  (spawns/portals/prop_spots from markers); walk proof through real
  events: rim descends the fold-in planks and stops exactly at the
  petroglyph wall face, portal lands on south's from_rim shelf, the
  switchback descent grounds onto the sunshelf. maps/*.lua died; the
  F1 cm.editor + cm.tilemap died engine-side (selftest 23766→22926).
  Two dogfood catches fed back into the engine: fresh maps had no
  w/h/grid/bg editing surface, and capture tapes couldn't reach imgui
  fields at all. 4 llm-feed shots.)*

## 12. Open questions (human)

1. **Snap polarity** — ✅ **RESOLVED (human, 2026-07-12): CTRL =
   snap, no snap by default.** (Same round: colliders refined into
   typed free/attached primitives — folded into §§2/3/6/7.)
2. **Graybox = collider fill** — ✅ **RESOLVED (human, 2026-07-12)**:
   fine, and the visual barely matters — flat untextured polygons
   with the gizmo (§5). R7b stays off the tilemap critical path.
3. **Grid default 8 px** with ctrl+wheel dial (§7) — or default to
   the tile-ish 32?
4. **One-way slopes** (§3): allowed (proposed) — any feel veto?
5. **Live-apply** — ✅ **RESOLVED (human, 2026-07-12)**: Ctrl+S
   save→hot-reload is enough, with the code-ed contract intact:
   unsaved map edits persist across sessions and roll back through
   the journal (§6 — already the design; now confirmed).
6. *(new, resolved at asking)* **Per-placement colliders** confirmed
   the right call; placements gained **optional names** for code
   addressing (§4).

## 13. Layers, asset attachment, refs, animation (as-built, D060, 2026-07-15)

The R8 map gained a full layer/asset system so you build levels by PLACING
things (not only drawing colliders). All of it is codec + window + game.

**Layers (LAYR chunk).** `doc.layers = { {name, vis, on}, ... }`, ordered
back→front (z). Two independent flags:
- `vis` — EDITOR-only render. `false` = the layer's placements don't draw
  and can't be picked in the editor; the game is unaffected. (Declutter.)
- `on` — the master switch. `false` = the placements act as if they DON'T
  EXIST in-game: no draw, no attached colliders, no name in `by_name`, no
  fill. In the editor they show dimmed so you can re-enable them. (Prototype
  overlays.) Gated in `M.use`/`reload`/`geom`/`draw_places` via `place_on`.
Absent LAYR ⇒ one synthesized `{name="main",vis=on=true}`; every placement
falls onto it (old maps upgrade transparently). `M.z_order(doc)` gives the
stable layer-ordered draw sequence (original indices, deterministic).

**Placements = any asset (PLCE v2).** `{ path, x, y, layer(1-based idx),
flip, vis, name, anim, cols }`. Visual kinds (.spr/.png/.tm) render their
image; every other kind — or a visual with `vis=false` — is a NAMED REF: no
image, a code handle at a position, drawn as a labelled tag in the editor.
v1 PLCE still decodes (bit1 `hidden`→`vis=false`, no anim, layer→1).

**Null refs — graceful, loud.** `cm.map.ref(name)` → a usable cwd-relative
path from the live map, or (missing name / unreadable file) a `[map] NULL
REF` warning + `debug.traceback` and the built-in fallback for the kind:
`M.FALLBACK = { spr/png = the checker tileset, ins = error.ins, song =
error.song, pal = error.pal }` (all in `engine/stock/`). A dangling VISUAL
placement draws a magenta/black checkerboard in the editor AND in-game
(`M.draw_null`). `e.g. cm.snd.music(cm.map.ref("bgm"))` plays the attached
song, or the error jingle if it's gone.

**Animation (trivial auto-play).** A `.spr` placement's `anim` names a clip
from its `.anim` sidecar; it auto-plays one frame (not the whole strip),
sized to the frame. `M.spr_info(path)` caches frames/size/clips;
`M.place_frame(path, anim, elapsed)` → the current frame. `elapsed` is the
sim frame in-game (deterministic, render-only) and a wall clock in the
editor preview. Richer animation stays code-driven.

**The map window.** A right-side LAYER PANEL (header chip `lyr`): rows
front-at-top with `e`(vis)/`g`(on) toggles, active-layer highlight, a
`lock` toggle, and a `+ x ^ v` + rename footer. Clicking a placement
auto-selects its layer (teidraw); `lock` confines picking/marquee + drops
to the active layer. The inspector gains a `vis` toggle (image ↔ named
ref) and an `anim:<clip>` cycler for .spr. Panel/active-layer/lock live on
`win` (per-window), not the path-keyed plumb.

## 14. Teidraw direct manipulation + grouping (as-built, D061, 2026-07-15)

The R8 tool-modal gestures (§6) collapsed into one teidraw model. §6/§7's
select/collider/marker split still names the tools, but SELECTION + MOVE are
now unified across all of them.

**Unified select/move/drill.** `M.hit_stack(doc, mx, my, dims, opts)` returns
everything under a point front→back: free-collider vertices, then edges, then
markers, then placements (reverse Z). `M.drill_pick(stack, prev, sx, sy, thr)`
steps one entry down on a repeat click at the ~same screen point (wraps;
resets when the point moves). A single `grab_at` (used by every tool on a hit)
selects + arms the right drag: a **vertex** moves that point, an **edge** moves
the whole collider (both ends), a **sprite/marker** moves whole — and
click-again drills to what's beneath (line → the sprite under it). The
gesture-UPDATE handlers run in one `gd.mode`-dispatched block, tool-agnostic;
only the EMPTY-press differs (collider draws, marker new-rect, select marquee).
Free colliders are selectable/nudgeable/deletable in ANY tool now.

**The line grammar** (collider tool, line type): drag-on-first-click lays a
2-point line; or click, click lays one (`line2` waits for the 2nd click with a
rubber-band); then **shift+click appends** a point to the last line
(`p.lastcol`). `C` closes the selected chain. quad/circle still drag out. The
modal chain (§6) is retired; insert-on-edge is dropped (an edge click moves the
whole collider).

**Grouping.** A persisted `gid` (0 = ungrouped) rides **PLCE v3 / MRKR v2**
(v1/v2 decode gid=nil). Groups span placements + markers (free colliders stay
ungrouped in v1). `ctrl+g` groups the selection (≥2), `ctrl+shift+g` ungroups.
Clicking a member selects the whole group (they move together; a faint hull
draws the bounds, bright when selected); click-again drills into the member
(`M.drill_chain` inserts a `{t="group"}` level before its first member). Paste
re-groups a copied group under a fresh gid. Pure cores: `item_gid`,
`group_members`, `next_gid`, `group_sel`, `ungroup_sel`, `drill_chain` — all
KAT'd.

**Engine-stock placements resolve in the editor.** `res_path(ed, path)` tries
the project root then the engine root / cwd, so `engine/stock/*` sprites and
tilesets render in the map window the way the game resolves them (win_tex,
tm_doc, tmap.tileset_tex). The game side mirrors it (`cm.map.res_asset` for
place_tex/place_tm). Stock art is placeable in any project.
