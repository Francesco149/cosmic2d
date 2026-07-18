# Research: what cosmic2d gives a 3D sibling (philosophy + transplantable parts)

(agent-explored 2026-07-16, repo at /opt/src/cosmic2d; file:line refs are to that repo)

## The editor grammar (the "universal manipulation" UX)

Provenance: the editor is a deliberate subset of teidraw's UX with the same
**heuristics-for-intent** philosophy — "main action = content interaction;
move/select/close behind ALT; no title bars" (DECISIONS.md:1228, D045). One maximized
window, infinite canvas, every tool a floating window (code, assets, sprite/map/audio
editors, the live playable game). Chrome/grammar/hit-testing all Lua; imgui only
rasterizes text + the one hard text-edit widget.

**ALT grammar** (EDITOR.md:160-215), priority per event: active text edit owns input
except ALT-gated events → selection mode (alt+V) → edge bands resize → ALT held =
shell owns mouse → title strip drag/click → window content → empty canvas (marquee /
middle-pan / wheel-zoom / right-click spawn menu). Gestures: click = release within
4px; drag = crossing 4px; double = 320ms/6px. A-click select, click-again drill
(generic over parent links); A-drag move; A-rightclick closes with **no confirm**
("closing is non-destructive by construction" — working state + journal keyed by
asset, not window). Watch rule: "**Grammar creep** — resist inventing extra modifier
combos. New interactions must map to heuristics-for-intent, not chords" (EDITOR.md:374).

**CTRL grammar** (MAPS.md:334-368): "snapping lives on CTRL so alignment never means
nudging pixels. Plain drag = free px. CTRL held = snap, at any point during the
gesture." Snap resolution strongest-first: vertices → edges → edge-run → 45° lock →
grid (ctrl+wheel per-window step). Active snap always draws a guide line/dot.

**Wheel ladder + focus view-lock** (EDITOR.md:621-666): ALT→canvas zoom always;
CTRL→hovered kind's size dial; else content; else canvas. A focused own_view window
(sprite/map/tilemap) treats its whole rect as the view surface; accent border +
EDITING chip; "focus is the ONE gate, anything outside the window releases it."

**Unified direct manipulation** (MAPS.md:561-576, D061): one grab_at handles a vertex
(moves the point), an edge (moves the whole collider), a sprite/marker; click-again
drills. Read-only by default with an obvious edit toggle on every asset editor.
Auto-naming: cm.words 3-word collision-checked names kill the filename wall (D059.3).

## The asset citizen (three layers)

Every editable asset keyed by project-relative path (EDITOR.md:222-281, factored as
cm.ed.kit.asset(spec) — adding a kind is one module + a roster line):
1. file on disk — the saved truth; the game only loads this;
2. working state (cm.ed.doc.assets[path]), survives restart; dirty is computed
   (working ~= disk bytes), never tracked;
3. journal (.ed/journal/<key>.jrn) — full-snapshot entries, undo forever.
Formats are cm.chunk skip-tolerant versioned containers with pure KAT'd codecs:
.spr (layers/palette/frames/clips; bakes to png atlas + .anim + .meta), .map, .tm,
.pal (flat color list; SLYNYRD-style ramp generator), .ins, .song.
Cross-references: map placements are named refs (cm.map.ref) resolving any asset;
null refs degrade LOUDLY never fatally (magenta checkerboard + stock error assets).

## The map model (direct 3D ancestor)

R8 (MAPS.md, D057): maps are three concerns —
| layer | what | who reads |
|---|---|---|
| colliders | line chains w/ slopes, quads, circles; solid/one-way | the sim |
| visuals | freehand placements (sprites, images, tilemaps) | render only |
| markers | rects with kind+keys | game logic |
Colliders are i32-pixel chains ("slopes come from non-axis-aligned segments, not
fractional coords"); classification by slope not authoring mode; all mul/div on
endpoints — no libm/trig. Attached colliders ride placements. Graybox: colliders
render as flat fills with zero visual assets; in-game colliders render nothing.
D066: loaded map/markers/placements are captured presentation truth (rebuilt through
cm.state participants after restore); art files stay project assets; Ctrl+S map saves
ride the recorded EVAL path so rewind scrubs across them.

## Philosophy anchors

- Pillars (PLAN.md:33-61): determinism is the foundation; two layers + numpy model;
  **batteries included** ("a user makes and ships a game without leaving it");
  spectacle/game-feel knobs; editor UX that scales.
- Alpha honesty (ALPHA.md:22-27): "Unsupported paths must be named honestly rather
  than implied by 'batteries included.'" Alpha scope excludes macOS/mobile/web/
  consoles/**3D**/networking/second backend.
- Refusals: no imgui as a second UI philosophy (test: "could teidraw's feel be built
  on this without imgui policy leaking?"); code editor: 1 file/window, no tabs, no
  autocomplete; no folders in asset picker (flat + chips + fuzzy); studio killed with
  no coexistence period; live-reload orphans acceptable.
- Art direction (PLAN.md:64-79): LUT color grading ambition ("sprites authored
  neutral; a LUT pass tunes the whole game's look"); procedural generators feed
  environments/particles, **characters stay hand-made**.

## Rendering seam for 3D

pal/src/gfx.c is 788 lines, single-purpose. Everything already TRIANGLELIST,
cull NONE, no depth state anywhere. The make_pipeline(vs,fs,fmt,blend,has_vinput)
factory is called 3× (scene/blit/grade); a pipe_scene3d with depth-stencil target +
3-attr vertex format is an **additive change of the same shape**. Main new work:
depth attachment on scene_pass, a real 4×4 matrix uniform (now: 4-float ortho),
per-vertex Z. Three-target composite (game target / ui canvas / native-res imgui
layer) and the integer-scale letterbox stay as-is; grade_pass (pal.x_grade:
brightness/contrast/sat/tint, pre-readback so goldens see it) is the natural home
for LUT + dither/5551 quantize. Shaders: tiny GLSL 450 → committed SPIR-V; engine/user
code cannot define shaders (keeps backends swappable). Pixel goldens: pinned lavapipe
only; sim never reads pixels — a GPU 3D pipeline is fully consistent with the
determinism model.

## Current alpha state (context)

A0–A2 complete; A3 (project/export UX) in progress; A7 rewind foundation done;
suite green at ~23,330 checks. Remaining: export UX, gamepad/player settings, genre
demos, rewind product UI, RC pass.
