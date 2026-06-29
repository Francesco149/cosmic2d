# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-29
**Phase**: **M-content — opening-arc writing pass (story + first maps).** M10 (the
studio) is feature-complete; with asset authoring unblocked, this session opened
**M-content**: the narrative layer + the first quests/maps the human asked for.
**Docs only — no engine/sim/binary/selftest change.** (M10 history + its
next-steps are preserved below.)

### M-content — first quests + first maps (this session) — D042
The human's brief: write the first few quests + design the first few maps; fold in
**gemma-san** (a rival cosmic architect → chuunibyou succubus cosplayer) and a
**bunny-girl idol**; mobs are **cosmic creatures**. References consulted: the mock
board `F:\Pictures\cosmic2d-mocks` (world look — *explicitly NOT* the target art
style per the human, just inspiration; notably the mocks set cosmic2d in the
**same Grand Canyon** as the 3D game and label gemma **"RIVAL ARCHITECT"** with a
ready mob roster), the character sheets `F:\Pictures\oc\{gemma-san,bunny-girl}`,
and the 3D universe bible `F:\Documents\cosmic\docs`.

Four directional calls (human, via the question prompt → **ADR D042**):
- **Protagonist = Vesper as a _tsundere villain-origin_** (3D canon NOT locked —
  cosmic2d shapes her; the 3D game leans cozy too).
- **Setting = the shared Grand Canyon** (reuse 3D locations; the Rim is the hub).
- **Gemma = recurring comedic antagonist** (Team-Rocket clown; chuuni succubus
  *cosplay* — she's an architect, the horns/wings/tail are hard-light).
- **Lumi (idol) = hub idol + an early side-quest**; mobs = reality-leak creatures
  (slicing one *files it back* — the proto-Sweep gesture, the dread).

Wrote (docs only):
- **`docs/STORY.md`** — story/cast bible: premise, the **dread engine** (cozy ↔
  cosmic dread via dramatic irony — her stabilization is a rehearsal of the
  Sweep), full cast (Vesper / Gemma / **Lumi** + the shop + the Works), the **mob
  roster** (Star Mote · Fold Slime · Pebble Drone · Cactus Satellite · Glyph
  Beetle · Thread Imp · Mirror Wisp · Tiny Floodfish), world/areas, the opening
  **quest spine** (Q1–Q4), and a names/open-questions list.
- **`docs/maps/`** — the map-page format (README) + three one-pagers: **rim-hub.md**
  ("First Survey" — Q1 hub+tutorial, meet Lumi, light the trail portal),
  **south-trail.md** ("The Long Light" — Q2 the idol's stolen gem + Q3 Gemma's
  debut duel), **whisper-gulch.md** ("The Whisper Below" — Q4 grapple/teleport gym
  + the first cosmic-dread beat + the Works' first work-order).
- Cross-linked from **GAME.md** (intro + §9) and **CLAUDE.md** (doc index); ADR
  **D042** logged in DECISIONS.md.

### M-content — greybox + scene scripts (this session, cont.)
- **Tone calibrated** (human): **mostly cozy, doesn't take itself too seriously;
  dread used sparingly** — a few earned moments + quiet hints for the acute fans.
  STORY §2 updated with the calibration.
- **Greyboxed the first 2 maps** in a NEW cartridge **`projects/cosmic/`** (copied
  from the sandbox so the proven M7 moveset works as-is; the sandbox + its
  determinism goldens/selftest stay **untouched** — a new project is in no golden
  suite). A multi-map **host** (`level.lua`: registry + portal travel
  `game.travel`/`level.go`), two annotated map modules (`maps/rim_hub.lua`,
  `maps/south_trail.lua`) = blockout geometry + **MARKERS** carrying the plan
  (spawn · portals · Lumi stage · shop · sandbox nook · rooftop/grapple/tp gym ·
  horde arena · hidden tp-vault · Gemma's overlook…), a render-only **plan
  overlay** (labeled boxes, `M` toggles), **portals** (stand in one, press Up; `N`
  cycles maps for dev), and a `player.warp`. Run: `bin/cosmic projects/cosmic`.
  Two annotated montages on llm-feed (Rim Hub · South Trail).
- **Scene scripts written** (the screenplay layer — staging, cast, full dialogue,
  comedic timing, tied to the greybox markers): **`docs/maps/rim-hub.scenes.md`**
  (Q1: the drop · reception/Star-Mote tutorial · meet Lumi · the coffee gag ·
  light the trail + the dusk restage) and **`docs/maps/south-trail.scenes.md`**
  (Q2 the gem · the Sunshelf horde + the *one* dread hint · the hidden vault ·
  **Gemma's full comedic debut** + duel + the fond defeat · Lumi payoff).

**Next step (resume here):** the human **mocks the art** — the cast (Vesper
tsundere tweak, Gemma, Lumi) + a Rim/Trail look — and refines sprites in the
**studio** (M10, F2), walking the greybox (`bin/cosmic projects/cosmic`) to feel
the spaces and drag-cropping the llm-feed montages for layout notes. **Then we
code the logic:** a dialogue runner + triggers, portal/quest state, combat (M12)
for the hordes + Gemma, the sandbox (M-physics). **Deferred (human's call):**
richer **map rendering** — baked zoomed/dimmed parallax layers + a non-grid
decor/props layer — comes *after* the art mockup; the map modules leave
`parallax`/`decor` slots open for it (the human may mock whole scenes as studio
layers first). Good `/clear` point (committed, STATUS current).

---

**Date**: 2026-06-28
**Phase**: **M10 — the studio (in-engine sprite/animation editor): Phases 1–4 ALL
COMPLETE (paint · layers/shapes/selection/transforms · gradients · animation +
the M10 exit proof). Phase 5 IN PROGRESS — 5a pivots + 5b named slices + 5c asset
hot-reload DONE (studio tools + a `.meta` sidecar + the game anchors the pivot,
D041; and a studio save now live-reloads the in-game sprite — the paint→see-it
loop is closed), `record→verify` byte-exact; next is the procedural sprite
generator / headless `--bake` / per-frame pivot+slice keys.**
New direction this session (human spec): build a solid in-editor asset editor —
the keystone that unblocks all content authoring, so **pulled ahead of M9
(audio)**. M8 (viewport) is feature-complete and M7 (movement) is feel-approved;
both stand below as history.

### M10 the studio — where we are
- **Design is captured** (the careful-design deliverable the human asked for):
  **`docs/STUDIO.md`** is the full design bible (determinism class, document
  model, `.spr` format, the full-window studio UX + tool roster, the gradient
  system, the animation model, the asset browser, the bake pipeline, the phased
  plan, and an explicit "usability traps" section). **ADR D040** is the binding
  decision; **PLAN M10** + **GAME §10** point at STUDIO.md.
- **The three structural forks (human's calls 2026-06-28)**: a **dedicated
  full-window studio mode** (`F2`); a **native layered `.spr` doc that bakes to
  the strip atlas** the game already draws (truecolor + palette, not indexed);
  **solid paint foundation first** (Phase 1).
- **The keystone insight (D040 §1)**: a sprite's pixels are a **render-only
  asset** (boot-loaded like a PNG / `map.dat`), NOT sim state — so the studio
  carries **no determinism tax**: no EVAL plumbing, no trace recording, never in
  `--verify`/golden runs. Totally unlike `cm.editor` (the world editor, where
  the tilemap IS sim state). This is what makes it a free, good creative tool.
- **Module plan**: `cm.paint` (pure no-AA rasterizers, selftest-covered),
  `cm.sprite` (doc model + `.spr` save/load + bake), `cm.studio` (mode + UI on
  the ui canvas, sim paused, `F2`), `cm.anim` (pure clip evaluator). Assets in
  `<project>/art/`.

### M10 build progress (this session)
- **1a DONE** `f2b72c1` — `cm.paint`: the pure no-AA rasterizers (get/set/over,
  line/rect/ellipse, exact flood fill, blit/stamp, flip, rotate90). selftest
  +23.
- **1b DONE** `b3b8f72` — `cm.sprite`: document model (layers×frames, palette,
  pivot), the `.spr` container (CSPR over cm.chunk), composite + bake to the
  strip PNG, `buf_delta1` undo/redo. selftest +19.
- **1c DONE** `0a1c219` — `cm.studio`: the F2 full-window studio (shell + canvas
  + core tools), wired into cm.main (pause gate + frame() on the ui canvas).
  Canvas: checkerboard, composite→one texture, cursor-anchored zoom, middle-drag
  pan, grid, hover. Tools: pencil/eraser/bucket/eyedropper, primary/secondary
  (LMB/RMB), Alt=pick, X=swap, Ctrl+Z/Y undo, Ctrl+S save. Palette panel.
- **1d DONE** `e305c29` — HSV+hex **color picker** (SV square + hue strip + hex
  field, set_prim sync), **palette save-slots** (6 project-level presets in
  art/palettes.dat, L=load/R=save, + "+ add color"), and the **asset browser**
  (menubar "browse": modal thumbnail grid of `<project>/art/*.spr`, click-to-
  open, new/refresh/close). Plus `cm.ui.text_input` now takes `opts.rect`.
- **selftest 22351→22397** (+46, cm.paint + cm.sprite KATs); all green.
- **Layout human-approved** ("looks reasonable so far, let's continue"); 3
  screenshots on llm-feed (MVP shell, dock+picker, browser).

### M10 Phase 2 — layers / shapes / selection / transforms (this session)
- **2a DONE** `e8bb594` — **layers**: cm.sprite structural ops (add now undoable,
  dup with pixels, delete keeps ≥1, reorder), each one undo step via a coarse
  **snapshot** (the layer stack + frames + cursors, cells cloned); undo/redo
  unified into one polymorphic `step_apply` (cell-delta vs struct); undo stack
  **capped at 64**. Studio LAYERS dock (add/dup/del/up/dn, opacity slider, eye+
  lock toggles, top-down rows, click-select); the dock now **scrolls as a whole**
  for short windows.
- **2b DONE** `05a71fd` — **shapes**: line/rect/ellipse (no-AA) with a **live
  preview** (a transparent scratch cell composited as one overlay quad — no real
  pixels until release), commit = one undo step. **Shift** constrains (line 45°,
  rect square, ellipse circle); a **fill/outline** mode (rail glyph or `F`); RMB
  = secondary; status shows live WxH. Keys L/R/O.
- **2c DONE** `dc89f4a` — **selection + clipboard**: marquee (`M`, marching
  ants), **floating selection** — Move (`V`) lifts a selection into a float
  (cuts a hole) and drags it; it stamps (alpha-masked) on Enter / tool-switch /
  new marquee. `^C/^X/^V` copy/cut/paste, Del drops/clears, `^D` deselects.
  cm.paint.copy_region added.
- **2d DONE** `28ed326` — **transforms + brush**: flip H/V, rotate 90° CW/CCW,
  scale — on the float (lifting a selection first) else the whole cell (rotate
  gated to square sprites; whole-sprite resize deferred). **Custom brush** from a
  selection (sprite-as-brush): the pencil stamps it alpha-masked along the
  stroke. cm.paint.scale (nearest) added. Menubar cluster fH/fV/rL/rR/x2//2;
  rail brs/1px; keys H/J flip, `[`/`]` rotate.
- **selftest 22397→22413** (+16: structural ops/snapshot-undo/cap, copy_region,
  scale). All green. Each sub-phase has a montage on llm-feed.

### M10 Phase 3 — gradients (the signature feature, STUDIO.md §6) — this session
- **3a DONE** `f984948` — **`cm.paint` gradient math** (pure, dev-class, no-AA):
  `lerp_rgba`/`ramp` (multi-stop, clamped), `bayer` (2/4/8 recursive ordered-
  dither matrices), `grad_t` (linear/mirror projection · radial dist/|axis| ·
  angular turn-wrapped), `dither_t` (quantize to `levels` bands, ordered-dither
  each boundary — strength 0 = hard bands, 1 = smoothest; snaps to a real ramp
  band so every output pixel is an exact ramp color, never an AA blend),
  `grad_shade`/`grad_fill` (masked by a source alpha → recolor visible pixels,
  keep coverage). selftest +21 KATs.
- **3b DONE** `c09e64d` — **`cm.sprite` non-destructive fills**: a fill is bound
  to a **layer** (`layer.fill`), not a doc-global index array — rides reorder/
  dup/delete for free. composite/bake apply it via a per-doc shade scratch masked
  by the frame's alpha (live pixels untouched; bake flattens, `.spr` keeps live).
  `begin/commit/cancel_struct` (a frame-spanning struct-undo bracket), `set_/
  clear_/stamp_fill` (each one undo step; stamp bakes destructively). `FILL`
  chunk in CSPR (layer→def binding, floats for handles). clone_layer deep-copies
  the fill. selftest +8 (composite-masked, round-trip, stamp/undo, dup, clear).
- **3c DONE** `1e2224d` — **`cm.studio` gradient tool + handles + panel**: the
  **D** tool drags an axis onto the active layer (live composite = the real
  preview; re-drag keeps the ramp; new fill = prim→sec, inherits last params).
  **On-canvas handles** (dotted axis + draggable p0/p1, radial rim circle), the
  whole drag one undo step (no-op clicks push nothing). **GRADIENT dock panel**:
  type selector, a **multi-stop ramp editor** (click bar = add stop; markers
  select/drag/RMB-delete; set-col/del), dither/levels/phase sliders, bayer 2/4/8,
  **bake**/**clear**. `demo_gradient()` smoke aid.
- **selftest 22413→22442** (+29). All green; sandbox boots clean; no engine/
  binary change. Montage (radial/linear/angular) on llm-feed.

### M10 Phase 4 — animation (timeline + clips + cm.anim + the exit proof) — this session
- **4a DONE** `c499136` — **`cm.anim`**: the pure clip evaluator + the `.anim`
  codec. `frame_at(clip, elapsed) → frame_index` (integer-only — safe from sim OR
  render): **loop** wraps, **once** holds the final frame, **pingpong** bounces
  A,B,C,B (interior reversed; ≤2 frames → plain loop). `duration`, `find`, and
  `encode/decode/load/save` — the `.anim` sidecar is the clip array as canonical
  doc bytes (`cm.state.canon`, like knobs.dat); `normalize()` keeps the bytes
  stable. The engine **mechanism**; the cartridge owns **policy** (D030/D035), no
  sim state of its own. selftest +15.
- **4b DONE** `9d09525` — **`cm.sprite` frames + clips**: `add/dup/delete/
  move_frame`, each one undo step (`capture_struct` now also clones `doc.clips`,
  so a frame op that rewrites clip refs rides struct-undo). The clip frame index
  is **0-based** (the strip column the game draws); clip-ref fixups keep them
  consistent across insert/delete/move. `add_clip`/`delete_clip`; the **`CLIP`
  chunk** in CSPR (round-trips); `save()` now also bakes `<name>.anim` beside the
  `.png`. selftest +13.
- **4c DONE** `f5508f9` — **studio timeline + CLIPS panel**: the frame thumbnail
  strip (select/add/dup/del/reorder, wheel-scroll), **onion skin** (prev=warm/
  next=cool under the current at low alpha), an **fps** slider + **▶play/■stop**
  live preview (samples `cm.anim.frame_at` at the WALL CLOCK — `pal.time_ns`
  scaled to 60 ticks/s — dev-only, never sim; editing disabled mid-play), and a
  **CLIPS dock panel** (list/new/del/select, rename, loop mode, the frame
  SEQUENCE as chips with add-current/RMB-remove, per-entry dur). `TIME_H 24→46`;
  `demo_anim()` smoke aid. (studio is dev/render-only — not selftested.)
- **4d DONE** `5933d17` — **the M10 exit proof**: the sandbox player now draws a
  **studio-authored sprite**. `projects/sandbox/art/girl.{spr,png,anim}` — the
  editable 12-frame doc + the baked strip + the clip table; `genart.lua` is the
  one-shot bootstrap (`--eval "cm.require('genart').girl()"`). `player.lua`
  `load_sprite()` loads `girl.png` via `cm.gfx.texture` + `girl.anim` via
  `cm.anim` at boot (file bytes ≠ sim input, D026; `build_sprite` stays the
  fallback); NF derived from the strip width. Moveset poses 0..10 stay
  **state-driven**; the idle pose now plays the **timed breath clip** via
  `cm.anim.frame_at(idle, state.frame())` — cosmetic, zero stored state, pure +
  render-only.
- **selftest 22442→22470** (+28). **Determinism proven**: a KITCHECK trace
  recorded BEFORE 4d **verifies PASS** against the new player (sim byte-
  identical); a fresh re-record is byte-identical to itself; TOUR 400f + KITCHECK
  200f record→verify PASS. The trace FILE grows only by its embedded module
  source — exactly why the pre-change trace still verifies (the §1 payoff: a
  render-only asset cannot perturb the trace). Montage on llm-feed.

**Phases 1–4 are COMPLETE; the M10 exit proof is hit** — the studio authors
multi-layer sprites with shapes/selection/transforms/gradients AND animation
(frames + clips + onion + live preview), the bake pipeline produces the strip +
`.anim` the game loads, and the sandbox player draws a studio-authored,
clip-animated sprite with `record→verify` byte-exact. The remaining M10 exit
*criterion* (PLAN: the human authors a real character sprite + a portrait) is the
human's taste/usage pass on the now-complete tool, not an engine task.

**Next step (resume here): Phase 5 — continue** (STUDIO.md §10; **5a pivots + 5b
slices + 5c asset hot-reload are DONE this session**, see the Phase 5 sections
above — the editor loop is now closed). Remaining, none blocking — pick by what
content authoring needs next:
**headless `--bake`** (regenerate `art/*.png`+`.anim`+`.meta` from `.spr` without
the studio, so the baked outputs need not be committed — pairs naturally with the
hot-reload that just landed: an external `--bake` while the game runs would then
also want the file-watcher reload path noted in 5c),
**per-frame pivot/slice keys** (the deferred half of 5a/5b — extend `.meta` + the
HEAD/SLCE schema, readers stay back-compatible), an optional indexed/palette-swap
mode, the **procedural sprite generator** (noise/shape/gradient/bevel/blend —
M10's other half, feeding particles/liquids/dust), and the **LUT post pass** +
palette/LUT editor. Good `/clear` point.

Known small items: the **baked `art/girl.png`+`.anim`+`.meta` are committed** (the
game loads them at boot) — they become regenerable build product once Phase 5's
headless `--bake` lands; `genart.lua` re-bakes meanwhile. **Slices are authored +
baked + queryable (`find_slice`) but not yet consumed by the game** (the slice
VFX / weapon-attach that would read them is the deferred M7/particle work);
**pivot/slices are per-doc** (per-frame keys deferred). The studio **play
preview uses a wall clock** (`pal.time_ns`, dev-only) — faithful to how the game
runs a clip but not frame-stepped; **onion shows only the immediate neighbors**
(±1); **clip editing isn't separately undoable** (only frame ops are — clips
carry no pixels). **Gradient** fills aren't clipped by the selection (they're
masked by layer alpha instead — a possible future nicety); a gradient fill only
recolors a layer's existing pixels (by design); **one fill per layer**; whole-doc
**resize is now done** (menubar size / `cm.sprite.set_size`, see round 2 below) —
only **rotate of a non-square doc** stays deferred; the dock can need its
scroll on short windows. None blocking.

### Studio feedback round 1 (2026-06-28) — `35b150a`
Two asks from the human's first real use ("feels great so far"):
- **Selection now restricts editing** to the marquee — a write-clip in `cm.paint`
  (`set_clip`/`clip_off`, honored by set/over/flood) that the studio sets around
  pencil/eraser/bucket/shape edits + the live shape preview; composite/bake are
  never clipped (a defensive `clip_off` guards `rebuild_tex`). The marquee stays
  visible across tool switches as the active mask. selftest +5.
- **Paste lands on its own new layer** (never overwrites what's beneath):
  `paste()` floats with a `new_layer` flag; `commit_float()` creates the layer +
  stamps as ONE undo step (a struct bracket around the new `sprite.raw_add_layer`).
  A **merge-down** button (LAYERS panel, now 2 rows of 3) flattens a layer onto
  the one below — `sprite.merge_down` (opacity + gradient fill honored, one undo
  step). selftest +3. Verified by `--win` captures (clipped fill, paste→2 layers,
  merge→1).

### Studio feedback round 2 (2026-06-29) — image-size / canvas resize
The human's ask: "set the image size to anything, so I can work on a big sprite
sheet or a mock" — the studio had no way to change a doc's dimensions (the
whole-sprite resize deferred since Phase 2d). Now done, end to end:
- **`cm.sprite.set_size(doc, w, h, {mode, anchor})`** — rebuilds every cell of
  every layer/frame in one undo step. **canvas** mode (default) keeps pixels at
  native resolution, anchored by a 3×3 grid (`nw`…`se`) — grow with transparent
  margin or crop the overflow (for a bigger sheet / a mock); **scale** mode
  nearest-neighbour resamples the content to fill. Remaps the pivot, slices, and
  gradient-fill handles into the new space. **Key fix**: the struct-undo snapshot
  now carries `w/h` (capture/restore_struct), so undo restores the old dimensions
  alongside the old-sized cells — previously snapshots assumed a fixed size.
- **Studio UI**: a menubar **size** button opens an **IMAGE SIZE** modal (W/H
  digit fields, a canvas-vs-scale toggle, the 3×3 anchor picker, and a live
  preview of where the existing pixels land in the new canvas). Enter applies;
  apply commits a pending float first so no pixels are lost. Modal follows the
  asset-browser takeover pattern (`M.resize`, gated in `M.frame`).
- selftest **22506→22524** (+18 KATs: canvas grow/crop, anchors, scale-resample,
  pivot/slice remap, undo restores size+pixels, no-op returns false). All green;
  pure render-only studio code (D040 §1 — no determinism tax). Five `--win`
  captures on… (push to llm-feed). No engine/binary/sim change.

### Studio feedback round 3 (2026-06-29) — crash fix · large-image perf · curve
Three asks from the human's use of the now-resizable studio:
- **Crash fixed** — `studio.lua` `build_preview` called `sel_clip()` which was a
  `local function` defined *below* it, so the call hit a nil global and crashed
  any shape-tool drag. Moved `sel_clip` above its first use. (A latent bug, not
  from the resize work; surfaced now that bigger canvases get more shape use.)
- **Large-image performance — the big one (PAL api 5→6).** The studio composited
  / cleared / re-uploaded with per-pixel Lua loops; at half-1080p a single
  recomposite was **~800 ms** (≈1 fps per stroke — unusable). Added three
  **portable, reusable** C primitives (ARCHITECTURE api v6 table) and routed the
  bulk pixel work through them:
  - **`pal.blit32`** — the engine's one clipped RGBA8 2D compositor (copy / src-
    over / stamp + per-layer opacity). Its over-blend is the **exact integer
    math** of `cm.paint.over`, so composite/bake stay **byte-identical** (proven:
    a re-bake of `girl.spr` is `cmp`-identical to the committed `girl.png`).
  - **`buf:fill32`** — a 32-bit `:fill` (C u32 memset) for clears/solid fills.
  - **`pal.tex_update`** — re-upload into an existing same-size texture in place
    (no GPU realloc, no Lua-string copy); the canvas/thumbs/float pool ids via
    `cm.studio.tex_upload`. (This is the upgrade STUDIO §8 had predicted.)
  Wired into `composite_into`, `merge_down`, `paint.fill`, `paint.blit` (clip-off
  fast path; the clipped brush path stays Lua), and the studio upload sites.
  **Measured: 960×540×4 layers 813 ms → 9.5 ms (~86×); 1920×1080 3245 → 37 ms.**
- **Curve tool (C) — MS-Paint style.** `cm.paint.curve` (cubic Bézier as
  connected no-AA segments, sample count ∝ control-polygon length). Studio tool
  `M.curve` state machine: drag the two endpoints (straight-line preview), then
  drag twice to pull each control point (a cubic), the second release commits;
  switching tools abandons it. Reuses the shape preview overlay; status shows the
  phase.
- selftest **22524→22536** (+12: `fill32`, `blit32` copy/stamp/over-parity/
  opacity/edge-clip, `tex_update` ×3, `curve` ×3). All green. **Determinism
  intact** (render-only): sandbox 300f record→verify byte-exact; uigallery pixel
  golden byte-identical; **both linux + windows build clean** (portable C). The
  two sandbox pixel goldens mismatch as before (pre-existing M5-era staleness).
  Curve preview + large-doc composite captures on llm-feed.

### Studio feedback round 3 follow-ups (2026-06-29)
A few quick asks after using the above:
- **Rename the sprite** — the doc was always saved as `untitled.spr` with no way
  to name it. The menubar filename is now an **inline editable field**: type a
  name, Save writes `<name>.spr` (+ `.png`/`.anim`/`.meta`) under the project's
  `art/`. Editing sets `doc.name` and clears `doc.path` so the new name takes
  effect — a rename for an unsaved doc, a save-as (old file stays) for one loaded
  from disk. Name is sanitized to a bare filename (no path separators; a typed
  `.spr` is dropped so the file isn't double-extensioned).
- **Curve renders clean 1px** (was staircasing — fat 2-wide steps on near-diagonal
  spans). `cm.paint.curve` now oversamples to the distinct pixels it crosses then
  **drops staircase L-corners** (a pixel whose before/after neighbours are
  diagonally adjacent collapses to one diagonal pixel) — a 45° curve is now a
  single-pixel diagonal (KAT pins it: collinear-control curve = exactly N
  on-diagonal pixels, zero off-diagonal). Sampling gaps stay line-bridged.
- **Hover tooltips on the rail** — a one-frame `M.tip` fed by whatever the cursor
  is over (every tool button via its `tip`, plus the shape-mode / `brs` / `1px`
  buttons), drawn last near the cursor. The bottom-right status already names the
  active tool. (Answered a question too: the wordless **square button below the
  tools is the shape FILL/OUTLINE toggle**, `F` — filled = rect/ellipse solid,
  hollow glyph = outline; now self-documenting via its tooltip.)
- ASCII-only tip text (the 5x8 font has no `·`/`°`; were rendering as `??`).
- selftest still 22536 (curve KAT strengthened to assert the no-staircase
  property); determinism re-verified (sandbox 200f record→verify byte-exact).

### Studio feedback round 4 (2026-06-29) — selection + color picker polish
Four asks from more studio use (all in `cm.studio`, dev/render-only — no engine/
sim/binary change, D040 §1; selftest still 22536, sandbox unaffected):
- **Clear the selection** — a plain click (no drag) with the select tool now
  drops the marquee (it used to leave a stray 1×1 selection). `handle_select`
  tracks whether the pointer moved; no-move on release ⇒ `M.sel = nil`. `^D` and
  a fresh drag still work; the tool tooltip now says `drag=select, click=clear; ^D`.
- **Marquee ants too fast** — `draw_marquee` crawled off `ui.ticks` (render
  frames), so on a high-refresh display the dashes flew. Now it advances on the
  **wall clock** (`pal.time_ns`, ~3 steps/s) → framerate-independent (studio is
  render-only, so `pal.time_ns` never enters a trace).
- **Picker snap** — clicking a **palette** swatch set `M.prim` directly without
  syncing the picker, so the SV-square cursor / hue / sliders didn't move to the
  picked colour. The swatch now calls `M.set_prim` (the same sync the eyedropper /
  hex / swap already used) → the picker snaps, so you can pick a colour then nudge
  a darker shade off it.
- **More ways to adjust a colour** (not just the MS-paint square) — added **R/G/B
  + H/S/V channel sliders** under the SV square, each with a result-gradient track
  (`color_slider`: previews the colour across that channel's range), a handle, and
  the value. **Drag V down = a darker shade of the same hue** (HSV edits write
  `M.hsv` then repack so the hue survives a trip to black; RGB edits go through
  `set_prim`). Drags latch on `M.pick` (shared with the square/strip → don't fight
  the dock wheel). Verified by `--win` captures (snap-to-red; the full slider
  stack); both pushed to llm-feed.

### M10 Phase 5 — pivots + slices (this session) — `082eb0b`, `7cf0b29`
The keystone authoring metadata, end to end (D041): the sprite's runtime
*geometry* the game needs at draw time. Both per-doc for v1; per-frame keys
deferred (a documented `.meta`/schema extension when a weapon must track a hand).
- **5a pivots DONE** `082eb0b` — the doc already carried a per-doc pivot (feet-
  center default) in the `.spr` HEAD, but nothing set it, baked it, or used it.
  Now: `cm.sprite` pivot rides struct-undo + `set_pivot` (clamped, no-op-safe);
  a new **`.meta` sidecar** (pivot — and 5b slices — as canonical doc bytes,
  `cm.state.canon`, like `.anim`) baked by `save` beside `.png`/`.anim`, with
  `load_meta` for the game. `cm.studio` **Pivot tool (P)** — drag the on-canvas
  crosshair (one struct-undo step/drag); always-visible crosshair; status
  `pivot @x,y`. **player.lua** anchors the authored pivot pixel to the foot point
  (was a hardcoded bottom-edge), mirrored on facing, squash/stretch scaling
  around it — render-only (file bytes, D026) → can't perturb a trace. genart set
  girl's feet pivot (8,22) + re-baked (.png/.anim byte-identical; .spr HEAD +
  new .meta). selftest +10.
- **5b slices DONE** `7cf0b29` — a slice = a named rect (attach point / hit box /
  fx origin). `cm.sprite` `doc.slices` + raw/add/delete/set_slice_rect (clamped,
  undoable, ride struct-undo); the **`SLCE` chunk** in `.spr`; slices in `.meta`;
  `find_slice(doc|meta|array, name)` for the runtime. `cm.studio` **Slice tool
  (K)** — drag a rect to set the active slice's region (creates one if none; one
  undo step/drag); a **SLICES dock panel** (list/select/+slice/del/inline
  rename); on-canvas magenta rects (faint always, bright+labelled with the tool,
  selected accented). No game/sim surface touched. selftest +10.
- **selftest 22478→22498** (+20). **Determinism proven**: KITCHECK 470f + TOUR
  820f `record→verify` byte-exact (pivot consumption is render-only). Three
  screenshots on llm-feed (studio pivot crosshair · the anchored sprite in-game ·
  studio named slices). The game **consumes the pivot**; slices are authored,
  baked, and queryable (`find_slice`) but **not yet consumed** — the slice VFX /
  weapon attach that reads them is the deferred M7/particle-emitter work.

### M10 Phase 5c — asset hot-reload (this session) — closes the editor loop
The keystone that makes the studio a real authoring tool: **paint in F2 → Ctrl+S
→ the in-game sprite updates live, no restart**. End to end, pure render-only
(D040 §1 — sprites carry no determinism tax), so it cannot perturb a trace.
- **The signal**: `cm.sprite.save` bumps `cm.asset_epoch` — a render-only counter
  on the `cm` root, the asset-side sibling of `cm.code_epoch` (boot.lua). It only
  ever moves on a save (the studio pauses the sim, and `--verify`/`--frames` never
  open it); consumers read it in **draw only** so it can't enter a trace.
- **The re-texture path**: `cm.gfx.texture(path, reload)` — `reload=true` re-reads
  the PNG and refreshes the memoized `{id,w,h}` **in place** (every holder
  updates), **freeing** the old GPU texture (SDL_GPU defers the release so it is
  safe mid-frame; the 256-slot cap makes freeing — not leaking — right for
  repeated saves) and **keeping** the current texture if the re-read fails.
- **The consumer is the cartridge** (D030 — the engine rings the bell, the game
  decides what to reload): `player.lua` `refresh_sprite()` re-derives strip / NF /
  clips / `.meta` pivot when `cm.asset_epoch` advances, checked atop `M.draw`.
  `M.step` is **untouched** so the sim is byte-identical.
- **Proof**: selftest **22498->22506** (+8: save bumps the epoch; reload refreshes
  in place after the strip grows; a failed reload keeps the old texture). The
  sandbox `sandbox_idle` render is **byte-identical** to the pre-change tree (git
  stash A/B); **KITCHECK 470f + TOUR 820f `record->verify` byte-exact**. A scripted
  headless save->reload (recolor girl.spr magenta via the `cm.sprite.save` path,
  the same one the studio's Ctrl+S takes) flips the in-game character live --
  before/after montage on llm-feed; the recolor was reverted, committed art clean.
- **Scope note**: the in-process save signal serves the F2 loop. An *external*
  writer (a separate `--bake` editing `art/` while the game runs) would also want
  a file-watcher path -- a documented follow-up (needs wall-clock mtime polling
  gated out of capped/verify runs, like `cm.reload`), not needed for the loop.

**Launch**: `bin/cosmic --studio` (drops into the project's asset browser;
project defaults to projects/sandbox) — or `F2` in any running session. The
`--studio` flag is live/capture-only (gated out of `--verify`).

Controls (studio): F2 toggle · tools B/E/G·L/R/O·**C(curve)**·**D(gradient)**·I·M(select)/
V(move)·**P(pivot)**·**K(slice)** · LMB primary / RMB secondary · Alt=eyedropper · X swap · F fill-mode ·
**curve: drag the ends, then drag 2 bends (2nd release commits)** ·
Shift constrain · wheel zoom · middle-drag pan · Ctrl+Z/Y · Ctrl+S save (**live-
reloads the in-game sprite — no restart**) · ^C/^X/
^V/^D clipboard (**paste → new layer**) · Enter stamp float · Del clear · with a
marquee, paint/fill/shape **clip to the selection**; **select tool: drag=marquee,
click=clear (or ^D)** · H/J flip · `[`/`]` rotate ·
menubar fH/fV/rL/rR/x2//2 + browse/new/**size** (resize doc: canvas/scale +
anchor)/save/close · rail brs/1px · palette slots
L=load R=save · **LAYERS** panel: add/dup/del · up/dn/**merge** (flatten onto
below). **Gradient**: drag an axis on a layer → a non-destructive fill
masked to its pixels; drag the p0/p1 handles; the dock panel tunes type / ramp
(click bar=add stop, RMB marker=delete) / dither / levels / bayer / phase;
bake=stamp to pixels, clear=remove. **Timeline** (bottom): the frame thumbnail
strip (click=select, +f/dup/del/`<`/`>`), onion toggle, fps, ▶play/■stop (previews
the active clip or the whole strip). **CLIPS** dock panel: +clip/del, click a row
to make it active, rename, loop/once/pingpong, the sequence chips (click=select
entry, RMB=remove, "+ add frame N"), per-entry dur. **Pivot (P)**: drag the
yellow crosshair to set the in-game anchor (baked to `.meta`; the game pins it to
the feet). **Slice (K)**: drag a rect → a named region; the **SLICES** dock panel
lists/selects/renames/deletes them (attach points / hit boxes; baked to `.meta`,
queryable via `cm.sprite.find_slice`). **COLOR** dock panel: SV square + hue strip
+ hex + **R/G/B & H/S/V sliders** (pick a colour and drag V for a darker shade);
clicking a palette swatch snaps the whole picker to it.

---

## M8/M7 (previous milestones, still current as shipped) — history below

**Phase (M8)**: **M8 — viewport & editor UX (D036): FEATURE-COMPLETE** (pending the
golden re-cut, which is deferred — see below). The whole D036 model ships:
variable-FOV two-target composite (editor chrome at its own scale **around** the
game viewport), the resize ladder, alt+enter borderless fullscreen (**human-
approved**), and the **options menu** (Esc) to set resolution/scale/fullscreen
directly, **now persisted across launches** (video.dat). Layout approved ("it
looks correct yes"); three feel passes applied (round 3: **Esc opens the options
menu instead of quitting**, + a menu quit button + persistence). M8 is covered
by **selftest 22312→22351** (+39: viewport/composite/ladder/mouse-split/capture);
determinism byte-exact; both linux + windows builds clean. M7
movement remains FEEL-APPROVED; its deferred items (CW≈26 scale, slice VFX) wait
on real assets.
**Done this session (M8.1–M8.6 + capture, all on `main`, selftest 22312→22351,
determinism byte-exact, uigallery golden byte-identical, goldens else unaffected):**
- **M8.1** `ea7dc9a` — PAL **api 4→5**: `pal.x_fov(w,h)` (the variable game FOV =
  resizable internal target), `pal.x_window_size()`, `x_set_window_size`/
  `x_set_fullscreen` (options menu). Additive `x_*` (experimental ns).
- **M8.2** `f11ab36` — PAL **two-target composite**: `pal.x_ui_target` (a second
  editor/UI canvas), `pal.x_target("game"|"ui")` routing, `pal.x_compose{…}`
  (game→sub-rect at integer scale, ui→whole window at its own scale, alpha-over).
  Mouse events carry BOTH game-space `x,y` (sim, unchanged) + ui-canvas `ui_x,
  ui_y` (editor chrome). present() factored into scene_pass + blit_layer.
- **M8.3** `758dd40` — `cm.view`: the D036 resize **ladder** (scale =
  max(2,min(⌊W/480⌋,⌊H/270⌋)); FOV = min(480,⌊W/scale⌋)×min(270,⌊H/scale⌋)),
  live only (headless/verify keep the fixed FOV). Game fills the window at a
  variable FOV in play mode.
- **M8.4** `6c07b6a` — editor + dev UI on the **ui canvas** at its own scale
  (`cfg.ui_scale`, default **2×** — see knob note); the game becomes an **inset
  viewport** (window minus the toolbar/inspector) at its own integer scale. The
  mouse splits: `inp.gx/gy` game-space (world placement), `inp.mx/my` ui-canvas
  (panel hit-test). console/scrub/perf re-homed via `view.surface_size()`.
- **Capture** `11cbc23` — `pal.x_capture(w,h)` / `x_capture_read()` + engine
  `--win WxH`: composite into an offscreen target so a headless `--shot` shows
  the editor-around-game layout (only the swapchain has it otherwise). This is
  how the layout was self-verified + pushed to llm-feed. **Also fixes** the
  "graphics pipeline not bound" SIGILL the human saw: `pipe_blit` was only built
  for a window; now built unconditionally (UNORM format headless). Live path
  unchanged. `t_capture` guards the composite layering + the headless blit pipe.
  Capture a view: `bin/cosmic projects/sandbox --win 1920x1080 --frames 30 \
  --shot /tmp/e.png --eval "cm.editor.toggle(true)"`.
- **Docs**: **D039** (the two-target composite realizing D036) + the
  **ARCHITECTURE api v5 table**.

### M8 feedback round 1 (2026-06-28, win11) — `bf58389`
Layout approved. Applied: **fill-the-window ladder** — a maximized window was
letterboxing the game in black bars (the old min-of-floors + 480×270 cap); now
the scale is chosen to keep the FOV near the reference and the FOV fills the
window at that scale (1920×1040 → 480×260@4×; the editor inset sits snug, no
margins). **alt+enter** toggles borderless fullscreen (`pal.x_set_fullscreen`).
selftest 22349; verified by `--win` capture (maximized play fills edge-to-edge;
editor inset fills the central rect) on llm-feed. **Still open**: confirm
`cfg.ui_scale` (2× readable vs D036's literal 1×) on win11; test the alt+enter
toggle natively (headless can't).

### M8 feedback round 2 (2026-06-28, win11) — `02d55c4`, `2ea0973`
Fullscreen **approved**. Fixed "parallax bleeds through the bottom in fullscreen
editor mode": a FOV taller/wider than the 480×270 design renders past the sim
camera's clamp (the sim can't read the live FOV — determinism), revealing
undesigned world. Also latent in play mode (1280×720→640×360 bled). Fix —
**unified ladder** (supersedes round-1's fill): `scale = max(base, ⌊W/ref_w⌋,
⌊H/ref_h⌋)` (max-of-fits, so maximize still FILLS) **+ FOV hard-capped at the
reference** (so the render never exceeds the design → never bleeds). Net: fills
on whole-multiple windows (incl. maximized 16:9 → 480×260), thin letterbox /
editor margins otherwise; no bleed in play or editor. **M8.6 options menu**
(`cm.options`, Esc): fullscreen toggle, windowed presets (960×540…1920×1080),
ui-scale 1×/2×/3× — sets res directly when you can't drag-resize. **M8.5**:
api5 table extended (x_capture); nested-subdir module load + deep hot-reload
verified (the loader watch_adds every required file, dotted names → nested
paths).

### M8 feedback round 3 (2026-06-28) — `ff1e234`, `929d0e6`
The human couldn't reach the options menu: Esc still **quit** the game. The
sandbox bound Esc→`pal.quit()` in `game.step()`, firing alongside `cm.options`'
own Esc toggle and killing the game before the menu opened. **Fixed** — Esc is
now engine-reserved for the options menu (like ` for the console); the sandbox
no longer binds or acts on it. That removed the only keyboard quit, and
borderless fullscreen has no window-close button, so the options menu gained a
red **"quit game"** button; it and the window-close (X) now share one
`cm.main.request_quit()` (a game's `on_quit` hook fires from either). The menu
also captures the keyboard while open (mirroring the mouse capture) so the
player doesn't run around behind it. **Options persistence** (the deferred
follow-up) also landed: resolution / ui-scale / fullscreen save to
`<project>/video.dat` (`cm.view.save_video`/`load_video`, canonical bytes like
knobs.dat) and apply before the first frame — interactive sessions only, so
headless/`--frames`/`--verify`/`--win` keep the fixed FOV (goldens + determinism
byte-stable; gitignored). selftest 22351; sandbox record→verify byte-exact
(300f); save/load round-trip + menu render verified headless. The **interactive
behaviors** (Esc opens not quits; settings persist across a real relaunch) are
the human's native pass — headless has no window events. (The human's own
test-session video.dat — ui_scale=1, fullscreen — was observed on disk, which
*proves* persistence works end-to-end; I reset it during testing, so the next
launch starts from defaults.)

### M8/M7 feedback round 4 (2026-06-28) — `3894779`, `429530d`, `f890256`
Three asks from the human's first real play:
- **Window presets now FILL the window** (options menu): 720×540, 960×540,
  1440×1080, 1920×1080 (a 4:3 + a 16:9 at two heights) — each a whole multiple of
  a FOV ≤ the 480×270 reference, so the ladder fills with no letterbox (was the
  old 16:9-only set that letterboxed at e.g. 1280×720). See cm.view.ladder.
- **ui_scale applies in PLAY mode too** (D039 revision): the dev chrome (options
  menu / console / perf / scrub) now ALWAYS rides a ui canvas at `cfg.ui_scale` —
  cm.view.update allocates it in play as well as the editor (game composed under
  it, centered full-window in play), and cm.main routes the panels there after
  `editor.frame` regardless of editor state. So changing ui_scale with the editor
  closed rescales the menu live (it didn't before — it drew at the game scale).
  Render-only / live-only; goldens untouched.
- **Flutter is a rhythmic hold, not a glide** (M7 feel pass 4 + 4b, GAME.md §4 +
  D035): hold E after a hop and KEEP holding once you START FALLING → a small
  UPWARD height-based mini-hop every `flutter_interval`(30f≈2/s), `flutter_boosts`
  (4) times, sized (`flutter_h`=11) to roughly HOLD altitude with a gentle ~11px
  bob. Carried momentum is CANCELLED at hover-start (a flash-jump doesn't launch
  you far) and each boost is a slight up-FORWARD diagonal (`flutter_vx`=30 « the
  ~84 vertical → ~20°, <45°) so you drift forward a little; air drag keeps it
  gentle, hold a dir to steer. Replaces the `flutter_grace`/`_max`/`_fall`/`_decel`
  glide knobs; the "must be falling" gate is the tap guard. **4b** tuned the boosts
  ¼ smaller + 2/s; **4c** kept momentum (too far); **4d** cancel + slight diagonal
  (the keeper) — **FEEL-APPROVED** ("this feels good, we'll go with this"). Verified
  on TOUR: x drifts gently ~20–34px/s, vy flips every 30f at ~−84, y holds; selftest
  22351; KITCHECK + TOUR record→verify byte-exact; montage on llm-feed. With the
  knobs settled, the **KITCHECK flutter sub-test was re-choreographed** (a `{44}`
  settle so its jump+hop fires from a fresh grounded airtime + a `{130}` hold for the
  full 4-boost timeout): it triggers again, arms hop_cd (~f=590) and blocks the next
  hop — flutter→cd oracle coverage restored.

**Still open / deferred**:
- **`cfg.ui_scale`** default (2× now; D036 says 1×) — the human's taste call,
  live-tunable + in the options menu (and now persisted). Not blocking.
- **Golden suite re-cut** — DEFERRED (D033 + STATUS): the pixel goldens
  (sandbox_idle/tour) are M5-era and would just re-cut again when real art lands
  (M10); the `.ptrace`→`.ctrace` trace re-cut waits on confirming the rename
  (D033, human's call). selftest (22351) is the live net meanwhile.

**Next:** the **flutter is feel-approved** (round 4d) — M7's last open feel knob
to be dialed by hand is settled; the moveset is approved end-to-end. Remaining:
the `cfg.ui_scale` default taste (2× vs D036's 1×) on win11; the deferred golden
re-cut; then **M9 (audio)** or circle back to M7's asset-gated items (the CW≈26
absolute scale via FOV/scale + `move.cw/ch`; the slice VFX once the editor's
particle-emitter work lands). Good `/clear` point — M8 + the M7 feel passes are
committed and STATUS is current.

## This session (2026-06-27) — M7 moveset

The whole MapleStory moveset (GAME.md §4) now lives in the hub cartridge as
pure controller policy. Commits: `2a810a4` (controller + wiring), `69569c4`
(attract demo).

- **`projects/sandbox/player.lua`** rewritten: the old A-Hat-in-Time kit
  (variable-height jump, dive/boost/double-jump, crate grab) is gone; in its
  place — walk, jump (fixed ~1 CH, hold to auto-repeat), **flash jump** (repeat-
  able dash + sonic-boom ring), **up jump** (fixed vertical, once/airtime, locks
  out flash jump), **hop + flutter** (hop once/airtime; hold E hovers up to 10 s
  then arms a 10 s hop cd — a *1-frame TAP* never arms it), **grapple**
  (deterministic column scan for a standable top above, prefers past ½ screen,
  slow reel, once/airtime, 3 s cd, jump cancels), **teleport** (~5 CW blink,
  momentum dump, max 2/s, persistent A↔B phase mode that tints the sprite), and
  **hold-D slice** (slash stub; enemies at M12). New 128-byte buffer layout
  (pcall self-heals the old 96-byte one on reload). New 11-frame placeholder
  sprite + grapple beam + phase tint.
- **`main.lua`**: action map (hop=E, **grapple=q** — the spec's `` ` `` is the
  dev console, so q is the proxy), new ctl edges, retired dive/dj/throw knobs.
  **`level.lua`**: spawn lifted clear of the ground for any cw/ch.
- **`demo.lua`** re-choreographed: TOUR showreel + KITCHECK rule oracle, both
  byte-exact on `--verify`.
- **Determinism proven**: `selftest 22312 PASS`; record→verify byte-exact —
  TOUR 820 frames, KITCHECK 470 frames. No PAL/engine change (binary untouched).
- **Calibration**: every value is a live knob under `doc.knobs.move` (D028);
  `cw`/`ch` are the character box AND the CW/CH unit. Defaults are placeholders
  sized to the current 16 px-tile map at 1:1 — the absolute *6 CW ≈ ⅓ screen*
  anchor (CW≈26) needs M8 zoom + real art (a cw/ch/zoom knob change).
- **Montage** pushed to llm-feed ("M7 moveset — final demo tour").

### Feedback round 1 (2026-06-28, human win11 pass — "feels approximately right")

Applied (GAME.md §4 + D035 updated; selftest 22312 + record→verify both
timelines still byte-exact; montage "M7 moveset v2" on llm-feed):

- **Flash jump → once per airtime** (was infinite/repeatable): re-arms on
  landing. Verified via the fj flag (fires once, 2nd airborne press blocked,
  resets on land).
- **Teleport → alternates forward/back** (was forward only), tied to the A↔B
  phase flip: mode A fwd/solid, B back/phase.
- **Flutter "permanent cooldown" fixed**: it was the (correct) 10 s hop_cd being
  *invisible* + a real bug where a teleport re-armed it while a stale
  `flutter_t` lingered (now reset on flutter end). Mid-air hop works when off cd.
- **1.5× airtime, same heights**: `jump_apex_t` ×1.5; `upjump_v`/`hop_vy`/`fj_vy`
  ×2/3 (height ∝ v²/g).
- **Temporary cooldown HUD** (main.lua `draw_cd_hud`, live-play only): hop/
  grapple/tp bars + spent air-moves + phase mode — the requested cd viz.

Deferred per the human: the **fancy slice VFX** (orbiting energy blades + trail
particles) waits for the editor/particle-emitter work so it can be authored
live; final knob tuning waits for the real art.

### Feedback round 2 (2026-06-28)

GAME.md §4 + D035 updated; selftest 22312 + record→verify both timelines still
byte-exact; montage "M7 moveset v3" on llm-feed:

- **Flutter cd only on a real flutter** (was: any tap armed the 10 s cd). A
  `flutter_grace` (10 airborne frames) must pass before the hover — and thus the
  cd — engages; a normal tap is a clean hop. (Verified: `flutter_t` starts only
  after `hop_active`>grace, cd arms on land.) Also reconfirmed the teleport-
  re-arm bug fix.
- **Grapple extends → reels** (was: instant reel, short-range slingshot). The
  hook climbs to the target at `grapple_extend` (~1 screenful/s) under gravity;
  it reels only on connect, from your current velocity — so a jump-into-grapple
  has fallen to downward velocity (verified +70 px/s at connect) that the reel
  reverses first, damping the launch. Key fix: landing no longer cancels a
  grapple (the extend phase is grounded for a grapple-from-standing).

### Feedback round 3 (2026-06-28)

GAME.md §4 + D035 updated; selftest 22312 + record→verify both timelines:

- **Jump airtime ≈ ⅔ s** (apex_t 22.5→21.3; measured 0.65 s for a clean jump),
  height unchanged.
- **Up-jump & hop are height-based now** (`upjump_h`/`hop_h`): velocity derived
  from live gravity, so gravity retunes auto-preserve heights (no more ×k impulse
  recomputes).
- **Grapple launch dampened**: reel stops ~2 CH short of the platform
  (`grapple_stop_ch`) so the residual coasts under gravity; `grapple_min_t` keeps
  very-short grapples a small launch. The launch is really capped by
  `grapple_vmax` (coast ≈ vmax²/2g) — lowered 300→220, cutting a medium grapple's
  overshoot ~5.6 CH → **~2.5 CH** (accel 720 unchanged). **Grapple start zeroes
  horizontal momentum; arrows + teleport are locked out for the whole grapple**
  (committed vertical move; jump still cancels).

## What works right now (the engine, M0–M6 + the M7 moveset)

**Runs on Windows** (M6): `nix build .#cosmic-windows` → `cosmic.exe`, byte-exact
state parity with linux.


Boot + live sessions + hot reload + crash parachute; the PAL draw/state/input/
trace stack; the determinism kit (fixed 60 Hz, engine PRNG, cm.math, named
buffers + canonical doc tree); snapshot/restore with code bundles (D012);
cm.ui/console/repl/perf; error containment (game errors pause, never kill);
cm.tilemap with one-way platforms; the editor + inspector + prop palette
(everything edits via recorded EVALs); the M5 **time machine** (always-on
segment ring D032, F4 scrubber, rewind, `.ctrace` export, replay playback); the
suite under `nix flake check`. Detail: ARCHITECTURE.md + DECISIONS D001–D032 +
git history.

**The M7 moveset** (this session): walk / jump / flash-jump / up-jump /
hop+flutter / grapple / teleport / hold-slice, all deterministic, every value a
live knob — pending the human's feel tuning. See the session note above.

## M6 — windows port: DONE (agent-verified 2026-06-27, commit `6b39cf6`)

Cross-build via the flake's `packages.cosmic-windows` (`pkgsCross.mingwW64` +
nixpkgs cross SDL3 3.4.8 — pure Nix, no impure downloads; **D038**). The PAL is
pure SDL3, so the only C changes were `<SDL3/SDL_main.h>` (Windows entry) and
`fixup_cwd()` (self-locate via `SDL_GetBasePath` — **closes the cwd=repo-root
debt on both platforms**). Ships self-contained: `cosmic.exe` + `SDL3.dll` +
`libmcfgthread`. Verified on the win11 host via WSL interop:

- **selftest 22308 checks PASS** on `pal windows`;
- **cross-platform determinism parity is byte-exact** — linux records → windows
  `--verify` PASS, windows records → linux `--verify` PASS, and the two
  independently-recorded sandbox traces are **byte-identical**;
- the full Vulkan pipeline **renders headless on windows** (screenshot pushed
  to llm-feed).

Build it: `nix build .#cosmic-windows`; the `result/` tree is runnable on win11
(`cosmic.exe` beside `SDL3.dll` + `engine/`/`projects/`).

**Post-M6 windowed bug, FIXED** (commit `6209bbc`): the human's windowed run hit
a **key-stick** — `cm.input` was sampled only inside `sim_step`, so on a >60 Hz
monitor (vsync) the render loop's zero-sim-step ticks dropped their polled
events (a key-up landing there never cleared → stuck). Now `feed()` ingests
events **every tick**, `sample()` builds the record **per sim step**; headless
lockstep + trace determinism are byte-identical (selftest 22308→**22312** with
new regression cases; parity re-verified).

**Post-M6 perf fix** (commit `cae9024`): running from a WSL terminal showed
rhythmic frame spikes — the 4 Hz hot-reload poll stat'd ~30 module files inline
on the main thread, slow over 9p/drvfs. PAL gained a **background file-watcher
thread** (`pal.watch_mtime`, API 3→4); `cm.reload` reads cached mtimes, no
main-thread FS. Lazy-spawned (never in capped/verify runs → determinism
intact); parachute keeps its inline stat. Verified: selftest 22312, hot reload
still fires (linux), windows binary runs stably with the thread up.

Latest build (both fixes) deployed to `C:\temp\cosmic`. **Human-verified
2026-06-27**: windowed run is perfectly smooth — input releases cleanly, no
frame spikes from a WSL terminal.

## Next step — finish M8 (M8.4 → M8.6 → M8.5), then close M7's deferred items

**M8.1–M8.3 are done** (see the Phase block up top: PAL api5 viewport surface +
two-target composite + the resize ladder). Remaining M8 sub-steps:

1. **M8.4 — editor + dev UI onto the ui canvas**: route `editor`/`ui`/`console`/
   `scrub`/`perf` draws through `pal.x_target("ui")`; lay them out against the
   ui-canvas size (not `gfx_size`, which is now the FOV); panels hit-test in
   ui-space (`ui_x/ui_y`), the world overlay + prop placement stay game-space
   (`x/y`); the game becomes a central viewport rect via `pal.x_compose`. This
   is the big Lua refactor and the visible payoff (editor at 1× around game at
   2×). **Default layout is a taste call — checkpoint with the human first.**
2. **M8.6 — options menu**: set resolution/scale/fullscreen directly (a
   borderless/fullscreen window can't be drag-resized). PAL hooks exist
   (`x_set_window_size`/`x_set_fullscreen`); needs the menu UI + persistence.
3. **M8.5 — docs + goldens + multi-file**: ADR for the two-target model, the
   ARCHITECTURE api5 table, multi-file/subdir hot-reload at scale, golden re-cut.
   The **zoom** delivers the GAME.md §4 anchor (6 CW ≈ ⅓ screen, CW≈26 at the
   480-wide FOV) — set the FOV/scale + `move.cw/ch` together here. Plus the
   editor's live particle-emitter work for the deferred M7 **slice VFX**.
2. **Then close M7's deferred items** (once scale + assets settle): final knob
   tuning with the real sprite; the slice VFX; and **re-cut the golden suite** —
   committed traces are still dormant `.ptrace` (suite globs `.ctrace`). Plan:
   **delete** the obsolete-mechanic traces (boostcap/boostlock/divecancel/djscale/
   jumpfeel/platformer*/sandbox_ease/old kitcheck/sandbox); **re-cut as `.ctrace`**
   the engine-feature goldens (editpaint, inspectpoke, propspawn, mantle) +
   churn/evalfix; **add** a fresh `kitcheck.ctrace`; **re-shoot** the pixel
   goldens (sandbox_idle, sandbox_tour). selftest 22312 is the live net until then.

Controls (dev): arrows · space=jump (hold=auto-repeat; airborne=flash, Up=up-jump)
· e=hop (hold=flutter) · **q=grapple** · r=teleport · d=slice. F1=editor ·
**Esc=options menu** · **alt+enter=borderless fullscreen** · `=console · F3=perf ·
F4=time machine. `game.save_knobs()` persists tuning. The temporary cooldown HUD
shows hop/grapple/tp timers.

## Known small items / debts

- **M7 feel knobs are placeholders** — `doc.knobs.move` defaults are agent
  guesses for the human to dial in (with the real art). cw/ch=12/18 fit the
  current map at 1:1; absolute screen-scale (CW≈26) is M8.
- **Slice VFX is a stub, deferred** — the fancy version (orbiting energy blades
  + trail particles) waits for the editor/particle-emitter work so it can be
  live-authored (human's call). The attack input + a placeholder slash exist.
- **Cooldown HUD is temporary** (main.lua `draw_cd_hud`, live-play only) — a
  testing aid; remove once the editor can visualize ability/emitter state.
- **Golden suite still stale, now also pre-sign-off** (D033): committed
  `.ptrace` are dormant; the M7 re-cut waits for locked knobs (next-step #2).
  selftest 22312 is the live net.
- **Grapple onto a SOLID platform from directly below bonks** (hit.up) — the
  two map balconies are STONE; grapple works through one-way planks (most of
  the map). The real hub (M-content) follows the one-way rule (GAME.md §4).
- **Grapple is on `q`, not the spec's `` ` ``** (the dev console owns backtick
  unless the project locks the editor). A shipped/locked build can bind grave.
- **Player grab/throw is gone** — E is hop now; the crate pit is inert physics.
  The sandbox grab/float/constrain "tool" returns with M-physics (GAME.md §7).
- `projects/sandbox/map.dat` is **untracked local state** that shadows the
  procedural map at boot (PROCESS warns for goldens); left as-is.
- Confirm the rename *choices* `cm` (prefix) and `.ctrace` (ext) are
  acceptable — one sed to change now, frozen after 1.0 (D033).
- Carry-over M5/M4 debts still stand: console-eval rewind caveat, scrub previews
  with current draw code, bundle-mode-after-restore pauses disk reload, pinned
  recordings grow memory, inspector strings read-only / no add-delete, props can
  squeeze into a wall in pathological piles. (Full list was in the M5 STATUS in
  git history if one bites.)

## Design questions — RESOLVED 2026-06-27 (GAME.md §11, D037)

The human answered all six: fiction spine **ratified**; **earth + a cosmic
finale**, two hubs; **~3–5 hand-crafted bosses**; **full moveset from the
start**; teleport **phase-shift** modes (A solid / B phases); and a
**hub-respawn + optional-economy** model (currency/farmable drops, dual-sourced
abilities incl. radar + flutter-range, cheese consumables, world map + quest
arrow, no-rollback death, verifiable challenge stats). Captured in GAME.md §8/§11
and **D037**. Remaining opens are milestone-local (ability roster, boss roster,
HP/regen tuning) and don't block M6/M7.

(Always-open: art is human-authored; the agent designs map layouts + scenery
from primitives and writes story/quests once we reach M-content.)
