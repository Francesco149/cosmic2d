# cosmic3d — status

Living handoff doc. Update at session/milestone end. (Reset at the fork;
cosmic2d's own status history lives in the upstream repo and
`history/STATUS-2026-07.md`.)

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

## Exact next step

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
