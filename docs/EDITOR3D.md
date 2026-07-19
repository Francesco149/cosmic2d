# EDITOR3D.md — the 3D authoring suite (E-series, D137)

> The human unparked the 3D editor windows (2026-07-19): **everything that
> was code/LLM-generated needs a human-facing way to make and edit it.**
> The heightmap terrain + props get a 3D equivalent of the 2D map editor
> where any asset attaches to the map (2D assets default to billboards);
> 3D characters get an editor; low-poly meshes get an editor sufficient
> for the style without recreating Blender. Hand editing is always an
> option and usually the primary one; procedural generation stays a door,
> not the only path. **The exit is concrete: a human could recreate
> something similar to the openworld and rovale demos by hand-crafting
> the terrain and hand-placing the props.** This doc is the design; ADR
> **D137** is the binding decision. COSMIC3D.md §12 parked exactly this
> work ("terrain paint/bake, figure vertex-pushing, sheet preview…
> until the human unparks the editor") — this is the unpark.

## 0. Where this sits

ALPHA.md scopes 3D out of the *alpha release*; that stands. The E-series
is a parallel program on the same repo, riding the same session hygiene
contract (one packet per session slice, ADRs for binding choices, proofs
before claims). The A8 gates keep their own queue.

What exists (the runtime substrate, all pure/deterministic, D114–D117):
`cm.terr` (heightfield math + emit), `cm.fig`/`cm.gb`/`cm.mascot`
(rigid-part figures, baked-verts fast path via `pal.x_figverts`),
`cm.spr` (figure→sprite baker, `.spx`), `cm.atlas` (per-tile baked
texture atlas, `.png`), `cm.walk` (pick ray / walk grid / A*), `cm.rig`,
`cm.kin`, `cm.m4`. What does NOT exist: any 3D *source* file format —
terrain, figures, worlds are all procedural Lua in the demos
(`world.lua`/`npc.lua` hardcode noise, scatter PRNGs, part trees,
routes). The editors' job is to give every one of those a file-backed,
hand-editable twin, with the procedural path demoted to "a way to
produce/refresh the same file".

The three editors ride the proven house contracts unchanged:

- **windowkit asset citizen** (EDITOR.md §13, AUDIO.md §7): roster line,
  `kit.asset` working bytes + journal (undo-forever, unsaved-persists,
  restart survival, rewind/EDOC), `kit.pathfield` new-file door, Ctrl+S
  atomic save → recorded hot-reload, dirty `*` + amber dot, `kit.viewlock`.
- **the map-window UX** (MAPS.md, D057/D060/D061): tools as header chips,
  unified select/move/drill, CTRL = snap (never snap by default),
  inspector strip, drag-in from the assets window places, double-click
  opens the right editor, markers with kind/label/extras.
- **the sim/render split** (ARCHITECTURE.md): heights, colliders, walk
  grid, markers, placement transforms are captured sim/presentation
  truth (the cm.map runtime-buffer precedent); emitted triangles, baked
  atlases and sprite sheets are render-class, budgeted, golden-pinned.

## 1. The one new PAL mechanism: offscreen 3D views (v24)

Today `scene3d_pass` hardcodes `G.target` — 3D can only render into the
shared game target, so editor windows cannot host independent 3D
viewports (and two 3D windows would fight over one target). The additive
fix, PAL API v24:

- `pal.x_rt(w, h) -> texid` — creates a render-target texture
  (COLOR_TARGET | SAMPLER) in the ordinary texture table: drawable by
  `pal.x_ig_image` / `x_tris` sampling like any texture, freed by
  `pal.tex_free`. Each RT lazily owns a matching D16 depth texture.
- `pal.x_view3d` grows an optional trailing `target` texid (absent/-1 =
  the game target, today's behavior byte-for-byte) plus an optional
  clear color for that view. `PalView3D` carries them; `scene3d_pass`
  walks views in submission order and opens one render pass per run of
  consecutive same-target views (first view in a run clears, the rest
  load). The game path stays a single pass with the frame clear —
  **every existing golden is byte-identical by construction.**
- Lua-side lifetime: editor viewports register their RTs in a
  generational idbuf (the `rc.` pattern) sized to the window's device-px
  view rect, recreated on resize; headless works (lavapipe), so editor
  tape proofs and screenshots exercise the real path.

Everything else the editors need already exists: `x_ig_image` blits any
texid into a window, imgui renders after the scene passes so a same-frame
RT is current, `tex_create/update` covers CPU-built previews.

## 2. The asset map (what files exist after E-series)

| asset | magic | source of | edited by | consumed via |
|---|---|---|---|---|
| `.terr` | CTER | a 3D map: heightfield, materials/weights, shade, water, walk, placements, markers/routes | the **3d map window** (kind `terr`) | `cm.terr3.use` (sim) + `cm.terr3` emit helpers (render) |
| `.msh` | CMSH | one low-poly mesh (props, figure part meshes) | the **mesh window** (kind `mesh`) | `cm.mesh.emit` / baked blob (`x_figverts`) |
| `.fig` | CFIG | a rigid-part figure + its clips | the **figure window** (kind `figure`) | `cm.fig.load` → `fig.emit` / `fig.cycle` / `spr.bake` |
| `.spx` | CSPX | *(exists)* baked 8-dir sprite sheet | the figure window's **bake** tab (button) | `cm.spr` billboards |
| atlas `.png` | — | *(exists)* baked per-tile terrain textures | the 3d map window's **bake** button | `cm.atlas.import` |

Derived/baked stay stamped binaries adopted at boot (the `.spx`/atlas
precedent): bake is a button, a stale stamp orphans the file, the
budgeted live path takes over. Source formats are `cm.chunk` containers
(skip-tolerant, versioned) like CMAP/CSPR — old bytes never move;
extensions are new chunks.

## 3. `.terr` — the 3D map asset (CTER, module `cm.terr3`)

`cm.terr` stays the pure heightfield math (build/sample/emit); `cm.terr3`
is the codec + runtime door + placement emit — the `cm.map` of 3D.

### 3.1 The model

- **Terrain = per-vertex heightfield**, `(w+1)×(h+1)` f32 heights over
  `w×h` tiles of `tile` world units — exactly the shipped `cm.terr`
  shape that both target demos use. Smooth slopes, basins, knolls; steep
  slopes read as cliffs. The GND-style per-corner split (sharp cliff
  seams, implicit wall quads) is a **named revisit trigger**, not v1:
  neither exit demo needs it, and it changes `T.sample`'s sim contract.
- **Materials are data**: an ordered material list (≤ 8), each
  `{name, col={r,g,b}, tex=path?}` — `tex` is an ordinary project image
  (drawn in the *sprite editor*: the 2D tools author the 3D ground).
  **Per-vertex weight planes** (u8 per material) say how much of each
  material each vertex wears; weights normalize at use.
- Two render modes from ONE stored model:
  - **vertex mode** (openworld's look): emit colors = weighted material
    colors × painted shade, with the world-hashed jitter that keeps
    band borders organic. Zero bake, always current.
  - **baked-atlas mode** (rovale's look): the bake button runs
    `cm.atlas` over a texel function derived from the same weights —
    sampling each material's `tex` in continuous world space (flat
    color + hash mottle when `tex` is absent), feathered by the weight
    planes, prop shadows multiplied in from caster placements. Committed
    as the stamped atlas `.png`; the stamp hashes the inputs so a stale
    atlas self-orphans.
- **Shade** = one more paintable u8 plane (255 = 1.0) multiplying vertex
  light — the "painted vertex AO" the N64 aesthetic doc calls the single
  most important element, as a first-class brush.
- **Water** = a level plane: `{on, y, col, alpha}`. Shorelines are the
  height contour, the ro2 lesson. Per-region water is a revisit trigger.
- **Walk grid** = derived, GAT-style 2× subdivision: walkable = slope ≤
  `max_slope` AND water depth ≤ `wade_depth` AND not inside a blocker
  placement — thresholds stored in HEAD — plus a sparse list of
  hand-painted per-cell overrides (force walk / force block) for the
  bridge/overhang cases. The sim reads only heights + colliders + this
  grid (the colliders-are-the-truth split).
- **Placements**: any project asset at `{x, z}` with `y` either
  ground-snapped (+offset) or absolute, yaw, uniform scale, optional
  name (code addressing), flags, optional collider, extras `k=v`:
  - `.msh` → the mesh, transformed, pre-lit by the map's sun/ambient.
  - `.fig` → the figure, posed by `anim=<clip>` extras (idle by
    default), emitted live 3D — or baked billboard in RO-style projects
    (game policy).
  - `.spr`/`.png` → **a billboard by default** (the human's rule):
    upright camera-yaw-facing quad, feet-anchored at ground, nearest +
    alpha-test always (the sprite rule), world height = `scale` (u).
  - anything else → a named ref at a position (the D060 model): sounds,
    songs, instruments — game code fetches by name.
  - flags: `caster` (feeds the bake's soft shadow + a blob decal),
    `blocker` (stamps the walk grid), collider `none | auto | box`
    (auto = the asset's bounds; box = hand-edited local AABB → a sim
    collider instanced at load, the attached-collider idea in 3D).
- **Markers**: `{kind, label, x, z, r, points?, extras, note}` — kind
  vocabulary as 2D (spawn / poi / npc / portal / …) plus **routes**:
  a marker whose `points` polyline is an NPC patrol loop. openworld's
  and rovale's hardcoded route tables become route markers the game
  reads (`terr3.markers(kind)`), closing the NPC authoring gap.
- HEAD also carries: name, sun dir + color, ambient, fog (start/end/col
  — the map owns its look), spawn `{x, z, yaw}`, walk thresholds,
  billboard ppu default, atlas stamp.

### 3.2 CTER chunks

`HEAD` (name, w, h, tile, sun/amb/fog, water, walk knobs, spawn, flags,
bake stamp) · `MATS` (n × name/col/tex) · `HTS` (f32 heights) · `WTS`
(n_mat × u8 plane) · `SHDE` (u8 plane) · `PROP` (one per placement,
file order = draw order) · `MRKR` (one per marker, `points` list for
routes) · `WOVR` (sparse walk overrides) · `TAIL`. Canonical
encode/decode in `cm.terr3`, KAT'd round-trip + refusals like cm.map.

### 3.3 The runtime door

`cm.terr3.use{path=, name=}` — decode, build the `cm.terr` grid, derive
the walk grid + overrides, instance placement colliders into a
`cm.collide`-style AABB set, capture the runtime bytes in named buffers
(`<name>.t3state`, the CMRT pattern) so traces/rewind/park replay map
edits; `terr3.reload(path)` is the recorded-EVAL hot-reload the window's
`after_save` submits. Readers: `terr3.ground(x,z)` (T.sample),
`terr3.walkable(cx,cz)`, `terr3.markers(kind)`, `terr3.get(name)`
(live placement handle — move/hide, captured), `terr3.spawn()`.

Render helpers (render-class, policy-thin): `terr3.emit_terrain(out,
doc, opts)` (vertex or atlas UV mode), `terr3.emit_water`,
`terr3.emit_props(out, doc, cam_yaw, ...)` (meshes + figures +
billboards + caster decals, distance-sorted blend segments), plus
`terr3.texel(doc)` — the bake's texel closure. The editor viewport draws
through the SAME emitters as the game: WYSIWYG by construction, and
every editor feature exercises the shipped render path.

**Procedural stays a door**: `terr3.encode(doc)`/`save` are public — a
project script (or console one-liner) can generate a doc (noise, scatter)
and write the `.terr`, which is then hand-editable. That is the
"baking stuff procedurally is always an option" answer: generation
produces the asset, the asset is the truth, the editor edits it. The raw
`cm.terr`-in-code path (bigworld's pure `hfn` streaming) stays fully
supported for worlds that outgrow a resident grid.

## 4. The 3d map window (kind `terr`, `win/terr.lua`)

A canvas window, `win-map`'s sibling in every contract: spawn-menu +
`.terr` double-click + drag-in bind; unbound window = `kit.pathfield`
(fresh 48×48 map, tile 2.0, one grass material); `kit.asset` working
CTER bytes, journal cap 512, one gesture = one entry; Ctrl+S → save +
recorded `terr3.reload`; `kit.viewlock` focus = the one gate.

### 4.1 View

An offscreen 3D viewport (the §1 RT) filling the content rect, drawn
through the real emitters, composited with imgui gizmo overlays
(projected via the same view-proj — `m4.apply` + viewport transform,
exported pure for KATs). **Orbit camera** per window (`cm.ed.orbit`, a
`winview` sibling storing yaw/pitch/dist/focus on `win`): middle-drag =
orbit, shift+middle = pan on the ground plane, wheel = stepped dolly,
shift+1 = fit map, shift+2 = fit selection. Grid overlay chip (tile
lattice at low pitch fades out), walk overlay chip (green/red cells +
override tint), gizmo/marker chips as win-map. A compass + N/E labels
anchor yaw; the sun direction draws as a small gnomon (lighting is
data here, not vibes).

Picking is exact, not approximate: cursor → NDC ray (m4 inverse) →
`cm.walk.raycast` against `T.sample` for ground; ray-vs-AABB for
placements (mesh/figure bounds, billboard quads); nearest-vertex within
a px threshold for brush center display. All pure + KAT'd.

### 4.2 Tools (header chips; keys as win-map)

- **select** (default, the move/drill tool): click = topmost placement /
  marker / route point under cursor, click-again drills; drag = move on
  the ground plane (y-offset preserved; CTRL snaps to the tile lattice /
  half-tile / neighbor alignment, threshold 6 px-at-view); `R`+drag or
  the inspector dial = yaw (CTRL = 15° steps); `S`+drag = scale (CTRL =
  0.25 steps); arrows nudge by tile/8 (shift ×1 tile — key repeat rides
  D135); Del deletes; Ctrl+C/X/V/D as win-map (paste lands under the
  cursor's ground hit); `[`/`]` = draw order. Marquee on empty drag.
  Double-click a placement → its editor (mesh/figure/sprite window)
  beside the map — the 2D map's cross-open convention.
- **height** (the sculpt tool): a radius-`r` falloff brush (ctrl+wheel
  dials r, the win-map grid-dial precedent; shift+wheel dials strength).
  Left-drag = raise, right-drag = lower (`takes_right`), **CTRL = snap
  the affected vertices to level steps** (the WC3 cliff-levels grammar —
  step = `tile/2`), `F`+drag = flatten to the height under the press,
  `M`+drag = smooth, `V`+click-click = ramp (connect two picked heights
  across the brush corridor). One stroke = one journal entry.
- **paint** (materials): the material strip (swatches from MATS, `+`
  adds, double-click renames/recolors/retextures via the inspector);
  left-drag paints weight toward the active material, right-drag erases
  toward the underlying mix; strength = flow. A `bands` helper in the
  inspector seeds weights from height bands (sand→grass→rock→snow with
  jitter) — one click gives the openworld starting read, then you paint.
- **shade**: darken/lighten brush over the SHDE plane (right = lighten).
  The cheap hand-painted-AO pass.
- **water**: drag the plane's level live in the viewport (CTRL = 0.25
  steps); inspector edits color/alpha/on.
- **walk**: paint force-block / force-walk overrides per GAT cell
  (left/right), or clear; the overlay shows derived vs overridden cells
  distinctly (shape, not only color — D130 rule).
- **marker**: click places (kind from the strip), drag moves; route
  kind: click lays points polyline (Enter/double-click ends, the map
  line grammar), points editable like collider vertices.

### 4.3 Inspector strip + panels

Bottom strip (selection-dependent, win-map's exact idiom): placement →
x/z/y-off fields, yaw, scale, name, y-mode toggle, collider chip
(none/auto/box — box spawns editable handles), caster/blocker toggles,
`anim:` cycler for `.fig`; marker → kind/label/r/extras; nothing
selected → the MAP's fields (w/h/tile resize with grow/crop anchor,
sun yaw/pitch dials, ambient, fog, spawn `set to camera`, walk
thresholds, water, bake button + stamp state, render-mode chip
vertex/atlas). A right-side panel (the map layer-panel precedent) lists
materials in paint mode and placements/markers (filterable, click =
select + reveal) in select mode.

### 4.4 Drag-in and the billboard default

`kind.drop` claims every asset kind: `.msh`/`.fig` place as themselves,
`.spr`/`.png` place as billboards (ghost preview during carry, live
ground-snap), other kinds place as named refs. `accepts` stays the
rebind predicate answering only `.terr`. OS file drops route through the
assets-window copy first, as 2D.

### 4.5 Bake

The bake button (map inspector) runs the atlas bake as the budgeted
in-draw pass over `terr3.texel(doc)` with a progress fraction on the
button itself; done → atlas `.png` written beside the map (stamped),
render-mode flips to atlas, save notes it. Casters multiply their soft
shadows in — moving a caster invalidates the stamp (the button shows
`stale`), the vertex mode stays live meanwhile. Honest rule: an
unexpectedly-different bake on pinned lavapipe is a bug, not a re-bake.

## 5. `.msh` + the mesh window (kind `mesh`, module `cm.mesh`)

The picoCAD-class refusal set, stated up front: **no skinning, no
modifiers, no subdivision, no sculpt, no n-gons beyond quads, no UV
unwrap** — verts, tris/quads, flat colors, optional per-face texture
region from ONE image. That is sufficient for the style (SM64 parts are
boxes and prisms; KayKit props are exactly this) and it is the wall
against Blender creep.

### 5.1 CMSH

`HEAD` (name, tex path?, flags) · `VERT` (n × f32 xyz) · `FACE` (n ×
{nv 3|4, idx[nv] u16, col rgb, flags: doublesided | unlit, uv[nv] u16
texels iff textured}) · `TAIL`. `cm.mesh.emit(out, xf, nxf, doc, opts)`
pre-lights flat per-face normals through the gb sun/ambient (quads
triangulate on the stored diagonal); `cm.mesh.bake(doc) -> bk` produces
the 64-B/vert blob so meshes ride `pal.x_figverts` exactly like gb
shapes — placed props and mesh figure parts get the C fast path for
free. Bounds (`cm.mesh.bounds`) feed auto-colliders and pick.

### 5.2 The window

Viewport = orbit RT view (ground shadow + lattice floor for scale, unit
gnomon); left = the tool strip; bottom = inspector.

- **vertex mode**: click/marquee select verts (projected-px pick),
  drag moves on the camera-facing plane; `X/Y/Z` during drag axis-locks
  (the dominant-axis grammar); CTRL snaps to the model grid (ctrl+wheel
  dials step: 1 → 1/2 → 1/4 → 1/8 u). Del dissolves (faces touching
  collapse or die), `M` merges selected at mean. **Mirror-X chip**: live
  mirrored editing across x=0 (the character/prop symmetry workhorse —
  cheap to build against 4-vert faces, transformative to use).
- **face mode**: click selects a face (drill to backfaces), left paints
  the active color (palette strip riding the project `.pal` doors like
  the sprite editor), right eyedrops; `E` extrudes the selected face
  along its normal (THE power op — box → anything); `F` fills a new
  face from 3–4 selected verts; flip / doublesided / unlit toggles in
  the inspector; texture region assign = drag a rect on the tex
  thumbnail (planar per-face UVs, the picoCAD model).
- **add menu** (spawn-strip): box / prism n / wedge / plane / lathe
  profile (rotates a drawn 2D profile — the mascot teardrop path),
  dropped at origin, selected, ready to push.
- Stats line: verts / tris / bounds — the budget is visible (the
  250–800 tris/character guardrail from the aesthetic doc).

Same citizen wiring: `kit.asset` (fresh = a unit box), journal 512,
pathfield door, save → `cm.asset_epoch` bump (meshes are render assets;
placed instances hot-update through the map's plumb).

## 6. `.fig` + the figure window (kind `figure`)

### 6.1 CFIG

`HEAD` (name) · `PART` (one per part, tree order: name, parent, joint
xyz, shapes n × {kind gbox|prism|lathe|ball|**mesh**, col, at?, scale?,
alpha?, per-kind params; mesh = `.msh` path}) · `CLIP` (one per clip:
name, rate, flags loop|once, keys n × sparse pose — per part-name a
present-mask + up to 9 f32 rx..sz) · `TAIL`. `cm.fig` grows
`encode/decode/load` (load → the `F.build` def + clips table, mesh
shapes resolved through `cm.mesh`). **The mascot ships as
`engine/stock/fig/mascot.fig`** — generated once from `cm.mascot` (the
converter is a KAT: code mascot == decoded file mascot, byte-exact
emit), so every project starts with a real, riffable character;
`cm.mascot` stays as the API it is.

Faces stay geometry (eye/pupil balls) in v1 — the runtime has no face
strips yet; texture-swap face strips are the named follow-up (they need
a `fig.emit` texture door first). Deliberately absent, forever: skinning,
weights, IK.

### 6.2 The window

Three tabs (header chips) over one orbit viewport + left part-tree
panel:

- **parts**: the tree (select/rename/add child/delete/reparent by drag;
  ordering = tree order, parents first — the codec enforces it). The
  selected part's shapes list in the inspector: kind, params (n/r0/r1/h
  /prof/size/…), color (palette doors), at/scale/alpha; `+shape` menu
  incl. `mesh…` (pathfield to a `.msh`; double-click opens the mesh
  window beside — the cross-open convention). Viewport: drag the
  selected part's **joint** gizmo to move it (CTRL = grid snap); the
  whole figure re-emits live. Mirror helper: `mirror L→R` button copies
  a `_l`-suffixed part's shapes/joint to its `_r` twin, x-negated (the
  naming convention the mascot already uses).
- **pose** (the clip editor): clip list (add/rename/dup/del, rate,
  loop), a **key rail** along the bottom (the audio clip-rail idiom):
  keys as diamonds, click selects, drag reorders, `+` inserts a copy of
  the current pose, Del removes; play/pause (space) previews at rate
  with `fig.cycle`'s exact lerp — what you scrub is what ships.
  Viewport posing: **drag a part to rotate it around the dominant
  axis** (screen delta → the axis most aligned with the camera; `X/Y/Z`
  locks; CTRL = 15° steps), shift+drag = translate (root part only by
  default — the root-translation rule), `sq` field = squash triple
  (`mascot.sq`). Ghost chips: onion-skin the previous/next key at low
  alpha (alpha-blend segments exist). Edits write the SELECTED key's
  sparse pose; a part untouched in a key stays sparse (inherit-lerp),
  the `clear part` chip re-sparses it.
- **bake**: the sheet preview (all 8 dirs × row list, rendered by
  `cm.spr`'s real rasterizer at CW×CH), row list = named clip + `t`
  pairs (add/remove/reorder), and the **bake button** → `.spx` beside
  the figure (pathfield default `spr/<name>.spx`) through the atomic
  save door. The model-once-use-anywhere loop closes here on a button.

Wiring: full `kit.asset` citizen (fresh = a 3-part starter: base/body/
head with a gbox each), journal 512, `exts={"fig"}`, save →
asset_epoch; a `.terr` placement of the figure hot-updates on save.

## 7. Determinism, goldens, proofs

- Editor viewports are chrome: RT rendering never touches sim bytes; no
  existing golden can move (the §1 same-target guarantee covers the
  game path bit-for-bit).
- `.terr` runtime buffers ride the cm.map capture/participant pattern:
  traces span map hot-reloads, rewind shows the old terrain with its
  matching placements. KATs: codec round-trips + refusals for all three
  formats, walk-grid derivation, pick math (ray/AABB/vertex), brush
  falloff/level-snap math, mesh emit == gb emit for the primitive
  starters, fig file mascot == code mascot, orbit/project math.
- Every window lands with a **tape proof** on the real event path (the
  D127 drive idiom) + llm-feed captures; the E-series exit is the
  §9 hand-authoring proof.

## 8. Deliberately not here (named, with triggers)

- Per-corner cliff heights + implicit wall quads (revisit: a demo needs
  sheer GND cliffs the slope look can't fake).
- Per-region water, water wave/cycle (polish trigger).
- Point-light bake (trigger: a scene needs non-sun light; casters-only
  shadows ship first).
- Paper-doll layered sprites, palette dyes (the RO §5 extension).
- Texture-swap face strips (needs the fig texture door; first character
  that needs blinking).
- Streaming-world editing (bigworld's pure-`hfn` path stays code; a
  chunked .terr is its own program).
- Mesh: UV unwrap, smoothing groups, bones — never (the §5 refusal).
- OBJ import for CC0 packs (trigger: a real project asks; the formats
  leave room — a converter writes `.msh`).

## 9. Build order (E0–E6) + exits

> **As-built (2026-07-19, the unpark session):** E0 ✅ E1 ✅ E2 ✅ E3 ✅
> E4 ✅ (commits 0f2168c/4c2da64/8bee98b/126a70a) and the E6 loop
> PROVEN early: a scripted tape hand-authored a vale (tree mesh in the
> mesh window; terrain/path/water/props/billboards/route/spawn in the
> 3d map window) and a scratch cartridge played it — ground, walk grid,
> colliders, spawn, and the NPC route all read from the authored file,
> zero world code (captures on llm-feed). **E5 (the figure editor) is
> the next packet**; the committed-fixture + demo-adoption half of E6
> follows it. Honest deferrals so far: the atlas bake button (§4.5),
> mesh-bounds auto-fit for placement colliders (auto boxes are
> generic-sized), per-face texture-region ASSIGN UI in the mesh window
> (the format + emit carry them; the strip edits colors only),
> multi-select in the 3d map window, and route double-click-to-end
> (Enter only).
>
> **E4.1 (same session, the human's native-test reports):** the mesh
> window grew the selection/manipulation layer the E4 slice deferred —
> **sel**, the universal default mode (click = edge else front face,
> click-again drills ONE level to the vert/face behind, press-drag on
> the selection moves it, empty drag box-selects VISIBLE verts,
> occluded silhouette edges never steal clicks), an **edge mode**, box
> select in every mode (faces fully boxed, edges both-ends boxed, vtx
> stays the x-ray box), **ctrl+click edge loops** in every mode (quad
> walk via opposite edges, tris stop it; face mode takes the walked
> strip), and **selection continuity across mode switches**
> (`cm.mesh.convert_sel` — the touched-vert union re-expressed in the
> target mode). The viewport is a **2x2 quad view by default** (orbit
> persp + top/front/side orthos sharing focus+zoom via `m4.ortho`;
> every pane picks/marquees/drags through its own projection; the RT
> pool grew per-pane subkeys) at a 2x default window size (880x720).
> The pure substrate lives in cm.mesh (`ekey/eunkey/edges/pick_hits/
> vert_visible/edge_loop/sel_verts/convert_sel`), KAT'd.
>
> **E5 ✅ (same session):** the figure editor landed — CFIG codec in
> cm.fig (f64 floats end to end so the cm.mascot converter's emit is
> BYTE-EXACT; `encode/decode/save/fresh/build_doc/doc_of/joints/
> mirror_lr/remove_part`, canonical + KAT'd), `F.emit` grew the mesh
> shape kind (`.msh` part meshes via bake_groups), the shipped
> `engine/stock/fig/mascot.fig` (KAT: byte-identical to a fresh
> conversion AND its decoded figure emits the code mascot's exact
> bytes), and `win/figure.lua` — parts/pose/bake tabs per §6.2 with
> the .msh DROP door (a dropped mesh becomes a shape on the selected
> part), key-rail clip editing, dominant-axis pose drags, onion skins,
> and the .spx bake button through cm.spr's exported
> rasterize_sheet/spx_encode. E5-exit tape proven on the real window
> (mascot in, hat from a .msh, walk retimed by the rate dial, a pose
> drag, spr/mascot.spx baked valid). Deferred honestly: part rename +
> reparent-by-drag (tree order edits by hand today), key-rail drag
> reorder, lathe profile editing, the `sq` squash field (scale
> channels pose it), mesh-shape path typing (the drop door + cross-
> open cover it).

- **E0 — the viewport substrate**: PAL v24 (`x_rt`, view targets),
  `cm.ed.orbit`, and a proving window skeleton (kind `terr` bound to
  nothing renders the lattice floor + gnomon in its own RT; two open at
  once don't fight). *Exit*: headless `--edit` shot shows two live
  viewports; suite green, goldens byte-identical.
- **E1 — `.terr` format + runtime**: cm.terr3 codec + KATs, `use`/
  `reload`/readers/emitters, walk derivation; a committed fixture map.
  *Exit*: a scripted game loads a `.terr`, walks its ground, reads a
  route marker; trace replays across a reload.
- **E2 — the 3d map window, terrain half**: view/pick, height/paint/
  shade/water/walk tools, inspector, journal, save→hot-reload. *Exit*:
  tape: sculpt a hill, paint a path, drag water, override a walk cell,
  Ctrl+S, the game window's player walks the new ground; undo walks it
  back; llm-feed captures.
- **E3 — placements + markers**: select/move/rotate/scale/drill, drag-in
  (billboard default), colliders/caster/blocker, routes, panels,
  cross-open. *Exit*: tape: place a mesh prop + a billboard + a route;
  the game spawns an NPC on the route; collider blocks the player.
- **E4 — `.msh` + the mesh window**: codec/emit/bake KATs, both modes,
  mirror-x, extrude, palette/texture region. *Exit*: tape: box → extrude
  → push → paint a recognizable tree; place it in the map; figverts
  parity KAT.
- **E5 — `.fig` + the figure window**: codec, mascot.fig converter KAT,
  parts/pose/bake tabs, `.spx` bake button. *Exit*: tape: open
  mascot.fig, add a hat part from a `.msh`, retime the walk clip, bake
  a sheet; rovale-style billboard renders it.
- **E6 — the end-goal proof**: hand-author a small vale through the
  shipped windows only (terrain, water, path, props from the mesh
  window, an NPC figure on a route, spawn, bake) on a tape; a tiny
  game script plays it. openworld/rovale adopt file-backed pieces where
  it deduplicates honestly (their procedural builds can WRITE `.terr`
  via the §3.3 door); bigworld stays code by design. *Exit*: the
  llm-feed montage a human can compare to the demos; STATUS closes the
  program with honest deferral list.

## 10. Open questions (human)

1. **Billboard scale default** — `scale` = world height feels right
   (rovale sprites are 3.0 u); a per-map ppu default also exists in
   HEAD. Veto welcome.
2. **The level-step for CTRL sculpting** — `tile/2` proposed; WC3 uses
   fixed cliff levels. Dial-able via ctrl+wheel in height tool?
3. **Fig faces** — geometry-only v1 confirmed acceptable? (Mascot's
   look is proven with ball eyes.)
4. **Material cap 8** — enough? (rovale uses 3 + shadow.)
