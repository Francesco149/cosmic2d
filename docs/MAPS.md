# MAPS.md — the map system (R8, D057)

> The map rework the human asked for before the graybox continues
> (2026-07-12): **maps stop being pure tilemaps.** Collision becomes a
> **collider layer** (line chains, slopes included); visuals become
> **freehand sprite placement**, with tilemaps demoted to *one placeable
> object kind* that behaves like a single baked sprite (editable in its
> own tile editor). Maps get a real **map window** on the canvas —
> drag assets in from the picker, drag placements around, double-click
> into the right editor, **CTRL = snap**. This doc is the design;
> ADR **D057** is the binding decision. The F1 world editor
> (`cm.editor`) dies here, as EDITOR.md §12.6 prophesied.

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

Visuals never collide; colliders never render (except graybox/debug
fill, §5); markers drive spawns/triggers. Placements moving never
touches the sim; collider edits are sim-visible through one recorded
path (§9).

## 2. The map asset (.map, CMAP)

A map is a **file asset** like a sprite — `maps/rim_hub.map` — a
`cm.chunk` container (skip-tolerant, versioned):

- **HEAD**: name, bounds w/h px, bg tint, grid step (the map's own
  snap default), version.
- **COLL** (one per chain): flags (u32: solid|oneway|closed), material
  (u8, future), vertex count, verts as **i32 px pairs** (integer px —
  colliders sit on pixels; slopes come from non-axis-aligned segments,
  not fractional coords).
- **PLCE** (one per placement, file order = z order): layer id (u8),
  flags (u32: flip_x), x/y i32 px, path (project-relative; `.spr`,
  `.png`, or `.tm`).
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

**The world** = the map's chains, instantiated into a named buffer
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

`cm.map.use(path)` (the level.lua successor): decode `.map` →
**collider buffer** (named, e.g. `cosmic.mapc`: header + chains,
canonical bytes — snapshot/trace/rewind-visible by construction) +
**render tables** (placements/markers, plain Lua, render-only) +
markers handed to game logic. Portals/spawn/prop_spots all read from
markers — `maps/*.lua` build code dies.

Placements are render-only state — deliberately *outside* sim
snapshots (like all art). Colliders are sim truth — *inside*, as the
buffer. Markers: read at map-use time by game code into its own sim
state (props spawned, portal rects), same as today's tables.

## 5. Rendering + the graybox language

Draw order per frame: bg tint/parallax (future LAYR) → placements in
file order (`.spr`/`.png` = one quad; `.tm` = the existing culled
batched-quads path per visible cell — "behaves as one baked sprite"
means *placement/move/z as a unit*, not literally pre-baked; a real
bake is a later optimization if profiles ask) → game entities
(interleave point: a placement layer flagged `fg`, future) → fx.

**The graybox needs zero visual assets**: the collider layer renders
directly — closed solid chains **filled** in the checkerboard grays
(the fill is the graybox, not a debug overlay), one-ways as the slim
accent slabs, exactly GRAYBOX.md §3's language. Art later = placements
stacked on top, then the collider fill switches off (per-map flag).
This keeps R7b unblocked the moment colliders edit (§11) — tilemaps
(.tm) aren't on the graybox critical path at all.

## 6. The map window (kind `map`)

A canvas window like sprite ed (EDITOR.md §12.6 idioms throughout):
opens via asset-picker double-click on a `.map`, the spawn menu, or
drag-out; keyed by path; multiple maps open fine.

- **View**: own camera — wheel = zoom at cursor, middle-drag = pan
  (`kind.takes_middle`), shift+1 fit. Zoom % chip. The map draws
  exactly as the game renders it (placements + collider fill/lines +
  marker overlay, each toggleable via header chips).
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
  ×8. Del deletes. `]`/`[` = z within the layer (placement order),
  matching the canvas z keys.
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
- **Inspector strip** (window bottom, one row): selection's x/y
  (editable x_ig_edit fields), layer chip, flip_x toggle — markers
  swap in kind/label/extras fields.

**Collider tool**:
- click = select chain (nearest edge); vertices show as handles.
  Drag a handle = move vertex; drag an edge = move the chain;
  **click an edge inserts a vertex** at that point; del = selected
  vertex (chain if none).
- **draw**: press on empty starts a chain, each click appends a
  vertex, **Enter/double-click ends open, C closes** (closed+solid =
  fillable ground); Esc cancels. CTRL snaps every placed vertex (§7).
- Chain flags on the inspector strip: solid/one-way, closed. One-way
  chains render dashed in the accent color.
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
   neighbors (butting decor together seamlessly);
3. **45° lock** — while *drawing/dragging collider vertices*, the
   segment to the previous vertex locks to 0/45/90° when no stronger
   snap hits (classic slope authoring);
4. **grid** — the map's grid step (HEAD default 8 px; **ctrl+wheel
   dials it** — the map ed's `kind.ctrl_wheel`, per-window override in
   `win.grid`).

Active snap draws its guide (the teidraw-style thin line / highlight
dot) so the lock is always legible. Marquee + resize snap the same
way. (If CTRL-to-snap polarity feels backwards live — some humans
expect snap-by-default — it's one boolean; the grammar survives
either way. Flagged in §12.)

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
hot-reloads it** — `cm.map.use` re-decode rides the same recorded
epoch/EVAL path sprite saves use (D041 5c), so traces replay map
changes and **rewind scrubs across them** (the collider buffer is
ring-visible; a rewound frame shows the old cliff). Unsaved map edits
are visible in the map window but not the sim — the map window is
authoring, the game window is truth; "apply live on gesture end" is a
possible later toggle, not v1 (§12).

Goldens: assets are committed files; headless loads them; nothing new
leaks in. The determinism sweep: no wall-clock, no libm, ordered
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
  `cm.tilemap` keeps grid+draw for `.tm`.

## 11. Build order (R8a–R8e) + exits

- **R8a — format + collision core**: cm.map/cm.tmap codecs (KAT'd),
  cm.collide (mover parity + slopes + queries, KAT'd), the collider
  buffer + `cm.map.use`, collider-fill render; smoke migrates, goldens
  re-cut. *Exit*: suite ALL GREEN on the .map smoke; a slope test room
  walks/slides correctly in a headless capture.
- **R8b — the map window, select/place**: view + working-state/journal
  plumbing, select tool end-to-end (move/nudge/z/del/marquee),
  `kind.drop` drag-in, double-click-to-editor, inspector, CTRL snap
  for placements, save→hot-reload. *Exit*: scripted --edit capture:
  drag a sprite from the picker onto the map, snap-align it to a
  ledge, Ctrl+S, the game window shows it; undo/restart survival
  proven.
- **R8c — collider editing**: the collider tool (draw/insert/drag/
  flags), 45° lock + vertex/edge snap, marker tool + inspector.
  *Exit*: author a new slope in a live session, walk it in the game
  window; the whole edit rewinds and comes back.
- **R8d — the tilemap window** (§8). *Exit*: build a small .tm from a
  tileset .spr, place it, edit it through double-click, journaled.
- **R8e — the game migration** (§10, in ../cosmic2d-game): both maps
  re-authored in the editor, movement/feel re-checked (the human),
  legacy map code deleted both repos. *Exit*: the human walks both
  .map maps and R7b resumes on top.

## 12. Open questions (human)

1. **Snap polarity** (§7): CTRL = snap (proposed) — or snap by
   default, CTRL = free? One boolean either way; live feel decides.
2. **Graybox = collider fill** (§5): checkerboard fill of closed
   solids as *the* graybox visual — sign off? (It keeps R7b off the
   tilemap critical path entirely.)
3. **Grid default 8 px** with ctrl+wheel dial (§7) — or default to
   the tile-ish 32?
4. **One-way slopes** (§3): allowed (proposed) — any feel veto?
5. **Live-apply**: is save-to-apply (Ctrl+S) enough for map editing,
   or is "sim adopts on gesture end" wanted sooner than "later
   toggle"?
