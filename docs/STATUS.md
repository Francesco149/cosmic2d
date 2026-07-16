# cosmic3d — status

Living handoff doc. Update at session/milestone end. (Reset at the fork;
cosmic2d's own status history lives in the upstream repo and
`history/STATUS-2026-07.md`.)

## 2026-07-16 (round 4) — the primitive vocabulary: prisms + lathes

gb.lua now speaks the round half of the proto vocabulary: **G.prism**
(extruded n-gon, cap fans) and **G.lathe** (revolved {r,y} profile,
smooth ring normals) — ports of proto draw_prism/draw_lathe — plus G.tri
and rigid-xf support; all emitters return tri counts (no more
hand-counted segments). level.lua grew PRISMS (12-gon round tower, hex
keep + wood cone roof, octagon pillar), LATHES (the proto dome on the
tower), DECO (y-rotated accent monoliths by the goal tower). Collider
rule (D3D-011): **colliders stay AABB, only visuals rotate** — prisms
take the apothem box (facets flush, corners overhang), rotated deco its
world-bounds box. Also: kill-plane respawn (move.kill_y knob) — the
autoplay trace fell off the world forever; now demo(1) loops the course
indefinitely (future golden material). Verified: facet/monolith walk
soaks clamp at predicted planes, 2D goldens ALL GREEN, 2 shots on
llm-feed (hex keep + cone roof; tower + dome + monoliths).

## Exact next step

The playground now has non-axis-aligned structure; movement slice stays
feel-approved (round-3 verdict). Next, in order of the human directive
(gameplay first, editor parked):

1. **Feel-check the new structure** via the feed (does round collision
   read fair? monolith bounds ok?) — asked in the llm-feed note.
2. **Demo 1 needs a goal loop**: the accent tower is "the goal" but
   nothing happens — pick up / touch feedback (flash, sound hook, respawn
   of a collectible) to make the course a game, still knob-driven.
3. Then: first golden for bounce (demo(1) is deterministic and loops).

Post-upstream-merge queue (unchanged): PAL relative-mouse API + input
record v2 for captured-cursor mouse look. Parked (unchanged): VI-soft
bilinear presentation + 5551/dither grade; editor-primitive distillation.

## 2026-07-16 (later still) — demo 1's movement slice is playable

**projects/bounce**: the bouncy cube runs/jumps around an axis-aligned
graybox playground, all from Lua — no baked dump. gb.lua ports the proto
material checkers + pre-lit gbox emitters; level.lua's ONE box list is
both visuals and colliders; player.lua = camera-relative run + D029
fixed-apex jump (coyote/buffer/fall_mul) + landing squash / air stretch /
lean straight from draw_bouncy_cube + blob-shadow landing cue; pull-string
follow camera as sim state (input is camera-relative — smoke.cam
precedent). Every feel value lives under doc.knobs (move/cam/feel).
game.demo(1) = autoplay loop (stairs → keep → arc left) for screenshots
and a future golden. ADR: D3D-008. Also: cm.m4 (m4 promoted to the engine
+ transform helpers, proto3d byte-identical), PAL_DBG_3D seg dump.
Verified: 2D goldens green; 4 autoplay shots pushed to llm-feed (stair
run, air stretch + shadow, squash, face portrait). NOT yet human
feel-checked — asked via the feed note.

## 2026-07-16 (playtest round) — teleports fixed, the godot camera ported

Human played bounce: "feels pretty good", but walking at the stairs /
jumping could TELEPORT. Root cause: the collision clamp face came from
the velocity sign, which zeroes on the first hit — a second overlapping
box (the 0.7u stair/keep pocket vs the 0.9u player) clamped to its far
face. Fixed: **clamp face from the pre-move side; squeezed overlaps clamp
nothing; land/bonk only from feet-above/head-below** + level rule: no
pockets narrower than the player (stairs now flush with the keep).
ADR: D3D-009. Verified: wall-charge + wall-jump clamp flush, goldens
green, shots on llm-feed.

Camera (human request): ported their godot cosmic project's FollowCamera
(F:\Documents\cosmic = /mnt/f/Documents/cosmic, src/camera/ — the feel
reference for all camera work): orbit yaw/pitch/dist + smoothed focus,
yaw-follow circling behind the heading, **mouse-drag look + wheel zoom +
c recenter**, manual steering pauses yaw-follow. Knobs mirror
CameraTuning under doc.knobs.cam. Captured-cursor mouse look (their
EnableMouseLook) is DEFERRED: needs a PAL relative-mouse API + input
record v2 — record v1 is frozen and engine-shared (merge-sensitive).

## 2026-07-16 (playtest round 2) — phase-through fixed, mantle, wasd

Human: "feels better", but diagonal stair walks PHASED THROUGH and one
pillar was solid on one axis. Root cause (frame-exact _G.DBG trace): a
side clamp stores face-hw in the f32 buffer; (face-hw)+hw can round past
the face, the exact side test reads flush as "squeezed", and the player
slides in. **All side tests now carry EPS=1e-3** (rule in D3D-010: any
geometry test against f32-stored sim state needs an epsilon). Plus two
human requests: **mantle** (steps ≤ move.step_h lift you instead of
blocking — demo(2) walks the whole stair run jumpless; grounded-only,
headroom-checked) and **wasd move / arrows camera** (yaw + pitch, pausing
yaw-follow; drag/wheel/c unchanged). Soak harness kept in-cartridge:
game.demo(2) walk + _G.DBG=n telemetry. Captured-cursor mouse look
re-confirmed as post-merge work (PAL relative-mouse API + record v2).

## Exact next step (done — see the entry above)

Playtest round 3 verdict: **"that feels good"** (after flipping arrow-cam
yaw to the stick convention — godot HandleManualRotation signs; pitch and
drag already matched). The movement slice is feel-approved.

Next: **grow the primitive vocabulary**: prism/lathe emitters in gb.lua
(ports of proto draw_prism/draw_lathe) so the playground escapes
axis-aligned boxes — colliders stay AABB, deco rotates. After that: the
level stops being a hand-typed table — first editor-primitive
distillation step (still parked until gameplay is polished, human
directive 2026-07-16). Post-upstream-merge queue: PAL relative-mouse API
+ input record v2 for captured-cursor mouse look.

Parked (unchanged): VI-soft bilinear presentation + 5551/dither grade pass
(the adopted default presentation — not yet in the PAL blit).

## 2026-07-16 (later) — the PAL 3D pipeline is live

**pal 0/api15**: `pal.x_view3d{mvp, fog_start, fog_end, fog, fog_on}` +
`pal.x_tris(tex, buf, count, off, flags)` (flags: 1 alphatest, 2 nearest,
4 blend/no-depth-write) — retro.vert/frag in pal/shaders/, D16 depth
target, opaque+blend pipelines, same batch/segment model as quads. 3D is
a pre-pass owning the clear; 2D LOADs over it (HUD on top). All lazily
created; the frame path without 3D is byte-identical — **inherited 2D
goldens green, unregenerated**. Views append (≤64/frame): sky NDC pass =
no-arg x_view3d. ADR: D3D-007. `frame_stats` grew tris/segs3d.

**projects/proto3d**: the graybox scene (proto dump, now a committed
scene asset) at 60fps from Lua — parse .c3dd, named buffers p3d.*, Lua
camera math (m4.lua), orbit/zoom controls, HUD text over 3D. Frame 0 =
the money-shot framing; ~0.8ms/frame headless lavapipe. Verified by eye
against proto/out/graybox.png + pushed to llm-feed (2 shots). Also fixed:
proto --dump kept dangling pointers to stack-local textures (segfault on
graybox/mascot dumps) — registry copies the struct now.

## Exact next step (done — see the entry above)

**Demo 1's movement slice** (the roadmap's gameplay-first directive):
bouncy-cube run/jump/squash-stretch in proto3d or a new cartridge —
colliders + walk surface from simple box/prism data (start axis-aligned),
camera follow, feel knobs in the doc tree like smoke's KNOBS. Squash/
stretch = nonuniform scale on the cube verts before submit (CPU-side,
like the prototype's draw_bouncy_cube). Then grow the Lua-side primitive
vocabulary (gbox/prism/lathe emitters into vertex buffers) so the scene
stops being a baked dump and becomes editable gameplay space.

Parked (unchanged): editor-primitive distillation until gameplay is
polished; VI-soft bilinear presentation + 5551/dither grade pass (the
adopted default presentation — not yet in the PAL blit).

## 2026-07-16 — the fork exists; planning + prototype imported

**Where we are.** Forked from cosmic2d @ f791824 (git remote `upstream`,
push-disabled). The 2D engine is untouched and must stay green. A full
scoping phase (done in /opt/src/cosmic3d-planning, imported here) settled
the design — read **docs/COSMIC3D.md**; the short form:

- **Renderer**: one fixed GPU retro pipeline in the PAL (SDL_GPU, additive
  next to the quad pipeline): depth-tested triangles, pre-lit vertex colors,
  3-point/nearest filtering in the frag shader, fog, alpha-test, blend
  decals; low-res internal target; **VI-soft bilinear upscale is the adopted
  default presentation** (sharp selectable); dither/5551 in the grade pass.
  proto/gpu_proto.c + proto/retro.{vert,frag} are the working draft; the
  software rasterizer (proto/r3d.c) defines intended pixels.
- **Demo roadmap** (human-set): 1) N64 platformer with the bouncy-cube
  character — movement feel first (look: proto/out/graybox*.png);
  2) Zelda-ish open world — figures/animation showcase
  (proto/out/openworld.png); 3) RO-style — blended terrain + chibi
  billboards (proto/out/ro2.png, the most human-iterated look; authentic
  client constants in docs/research-3d/ro-render-recipe.md).
- **Characters**: rigid-part figures, no skinning ever; vertex pushing in the
  figure editor from day one; mascot direction approved (lathe teardrop body,
  floating mitts/boots, antenna star, eye style B = bigger round pupils).
- **Terrain**: per-corner-height tiles + splat-painted material weights +
  bake step (unique per-tile blended textures, 1-texel gutters, baked prop
  shadows, corner-smoothed normals); water as a level plane (opacity
  144/255, drawn after sprites); walk grid at 2× (GAT-style). Rule from the
  v6 iteration: **ground materials blend; architecture is crisp-edged props**.
- **Assets**: license-verified packs staged in assets/ (gitignored, see
  assets/README.md); Kushnariova chibi pack (CC-BY) proven in the RO scenes.

**Suite state**: inherited cosmic2d suite untouched since fork (expected
green; run `nix run .#test` before the first engine change to baseline).

## Exact next step (done — see the entry above)

**The PAL 3D pipeline** (mirror proto/gpu_proto.c into pal/src/gfx.c the
cosmic2d way): `pal.x_view3d{...}` (mvp + fog uniforms), `pal.x_tris(tex,
buf, count)` bulk path over named buffers, per-segment state
(filter/alphatest/blend), a depth target on the internal target,
retro.vert/frag compiled into pal/shaders/. Then a minimal `projects/proto3d`
cartridge drawing the graybox scene from Lua at 60fps, headless-screenshot
verified against the prototype look. After that: **demo 1's movement slice**
(bouncy cube: run/jump/squash-stretch on colliders + walk grid) — gameplay
feel before any editor work.

Parked until gameplay is polished (human directive 2026-07-16): distilling
each demo into editor primitives — terrain window (splat brushes + bake),
figure window (vertex pushing + pose keys + face strips), billboard /
paper-doll sprite system.

## Session hygiene contract (same as cosmic2d)

STATUS current at session end; commits in logical units with model-slug
trailers; knowledge in-repo, never in agent memory; llm-feed for anything
visual (human is the taste check); goldens never regenerated to paper over
a break; 2D suite stays green through 3D work.
