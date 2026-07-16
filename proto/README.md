# cosmic3d prototype

Headless aesthetic + architecture tests for the 3D sibling engine. See ../DESIGN.md.

## Build & run (software path)

```sh
nix shell nixpkgs#gcc -c gcc -O2 -std=gnu11 -w -o proto r3d.c main.c -lm
./proto n64        # N64 preset money shot        -> out/n64.png
./proto ps1        # same scene, PS1 rules        -> out/ps1.png
./proto ro         # RO 2.5D preset (baked-figure billboards)
./proto dungeon    # KayKit CC0 assets through the pipeline (needs ../assets/)
./proto graybox    # demo-1 target: material-checkers + prisms/lathe/arc bridge + bouncy cube
./proto openworld  # demo-2 target: zero-texture vertex-color terrain (Body Harvest style)
./proto chars      # rigid-part figure sheet (walk keys + wave)
./proto mascot     # stock-character study: lathe body + floating mitts, squash/stretch
./proto mascoteyes # pupil-size comparison (A..D; B is the adopted default)
./proto rochibi    # RO village v2: CC-BY chibi sprites, river+bridge, tower, yawed cam
./proto ro2        # RO blended-terrain study: per-tile baked textures, contour pond,
                   # baked shadow pockets, diagonal gazebo (closest to real RO)
./proto filters    # nearest vs 3-point vs bilinear; affine vs correct floor
./proto bench      # ms/frame at 480x270
# any scene: add --soft for the VI/emulator blur presentation (the adopted default look)
```

## GPU path (SDL_GPU, headless on lavapipe)

Renders a `--dump`ed scene through a fixed retro pipeline (depth, 3-point in the
fragment shader, fog, alpha test, blend decals):

```sh
./proto ro out/ro.png --dump out/ro.c3dd
nix develop /opt/src/cosmic3d -c bash -c '
  glslangValidator -V retro.vert -o retro.vert.spv &&
  glslangValidator -V retro.frag -o retro.frag.spv &&
  gcc -O2 -std=gnu11 -w -o gpu_proto gpu_proto.c r3d.c \
      $(pkg-config --cflags --libs sdl3) -lm &&
  VK_DRIVER_FILES=$COSMIC_LVP_ICD ./gpu_proto out/ro.c3dd out/ro_gpu.png'
```

(cosmic2d repo is used read-only, only for its devshell: SDL3 + glslang + the
pinned lavapipe ICD.)

## Files

- `r3d.{h,c}` — software rasterizer: perspective-correct + affine + vertex-snap
  modes, z-buffer, near clip, nearest/3-point/bilinear, per-vertex sun light, fog,
  alpha-test, blended decals, Bayer+5551 quantize, integer upscale, PNG out,
  scene-capture hook (feeds the GPU path).
- `main.c` — procedural retro textures, GND-style per-corner-height terrain with
  implicit cliff walls + vertex AO + edit primitives, rigid-part figure (SM64
  model: no skinning, euler keyframes, texture-ish face, sprite baker), OBJ
  loader, scenes.
- `gpu_proto.c`, `retro.{vert,frag}` — the SDL_GPU retro pipeline.
