/* gfx.c — SDL_GPU quad renderer: internal fixed-size target, CPU-batched
 * quads, integer-scaled present. The Lua-facing semantics are documented in
 * docs/ARCHITECTURE.md (PAL API). */
#include "pal.h"

#include <stdlib.h>
#include <string.h>

static SDL_GPUShader *load_shader(const char *path, SDL_GPUShaderStage stage,
                                  Uint32 num_samplers, Uint32 num_uniforms) {
  size_t len = 0;
  void *code = SDL_LoadFile(path, &len);
  if (!code) {
    pal_log("gfx: can't load shader %s: %s", path, SDL_GetError());
    return NULL;
  }
  SDL_GPUShaderCreateInfo ci = {
      .code_size = len,
      .code = code,
      .entrypoint = "main",
      .format = SDL_GPU_SHADERFORMAT_SPIRV,
      .stage = stage,
      .num_samplers = num_samplers,
      .num_uniform_buffers = num_uniforms,
  };
  SDL_GPUShader *sh = SDL_CreateGPUShader(G.dev, &ci);
  SDL_free(code);
  if (!sh) pal_log("gfx: shader %s: %s", path, SDL_GetError());
  return sh;
}

static SDL_GPUGraphicsPipeline *make_pipeline(SDL_GPUShader *vs,
                                              SDL_GPUShader *fs,
                                              SDL_GPUTextureFormat fmt,
                                              bool blend, bool has_vinput) {
  SDL_GPUVertexBufferDescription vbd = {
      .slot = 0,
      .pitch = PAL_VERT_BYTES,
      .input_rate = SDL_GPU_VERTEXINPUTRATE_VERTEX,
  };
  SDL_GPUVertexAttribute attrs[3] = {
      {.location = 0, .buffer_slot = 0,
       .format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0},
      {.location = 1, .buffer_slot = 0,
       .format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 8},
      {.location = 2, .buffer_slot = 0,
       .format = SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = 16},
  };
  SDL_GPUColorTargetDescription ct = {
      .format = fmt,
      .blend_state = {
          .enable_blend = blend,
          .src_color_blendfactor = SDL_GPU_BLENDFACTOR_SRC_ALPHA,
          .dst_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
          .color_blend_op = SDL_GPU_BLENDOP_ADD,
          .src_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE,
          .dst_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
          .alpha_blend_op = SDL_GPU_BLENDOP_ADD,
      },
  };
  SDL_GPUGraphicsPipelineCreateInfo ci = {
      .vertex_shader = vs,
      .fragment_shader = fs,
      .primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
      .rasterizer_state = {.fill_mode = SDL_GPU_FILLMODE_FILL,
                           .cull_mode = SDL_GPU_CULLMODE_NONE},
      .multisample_state = {.sample_count = SDL_GPU_SAMPLECOUNT_1},
      .target_info = {.color_target_descriptions = &ct, .num_color_targets = 1},
  };
  if (has_vinput) {
    ci.vertex_input_state.vertex_buffer_descriptions = &vbd;
    ci.vertex_input_state.num_vertex_buffers = 1;
    ci.vertex_input_state.vertex_attributes = attrs;
    ci.vertex_input_state.num_vertex_attributes = 3;
  }
  SDL_GPUGraphicsPipeline *p = SDL_CreateGPUGraphicsPipeline(G.dev, &ci);
  if (!p) pal_log("gfx: pipeline: %s", SDL_GetError());
  return p;
}

/* upload w*h RGBA8 pixels into an existing GPU texture (shared by create +
 * update): stage in a transfer buffer, copy on a one-shot command buffer. */
static bool tex_upload(SDL_GPUTexture *tex, const void *pixels, int w, int h) {
  Uint32 bytes = (Uint32)(w * h * 4);
  SDL_GPUTransferBuffer *tb = SDL_CreateGPUTransferBuffer(
      G.dev, &(SDL_GPUTransferBufferCreateInfo){
                 .usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = bytes});
  if (!tb) return false;
  void *p = SDL_MapGPUTransferBuffer(G.dev, tb, false);
  memcpy(p, pixels, bytes);
  SDL_UnmapGPUTransferBuffer(G.dev, tb);

  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(G.dev);
  SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(cmd);
  SDL_UploadToGPUTexture(
      cp,
      &(SDL_GPUTextureTransferInfo){.transfer_buffer = tb,
                                    .pixels_per_row = (Uint32)w,
                                    .rows_per_layer = (Uint32)h},
      &(SDL_GPUTextureRegion){
          .texture = tex, .w = (Uint32)w, .h = (Uint32)h, .d = 1},
      false);
  SDL_EndGPUCopyPass(cp);
  SDL_SubmitGPUCommandBuffer(cmd);
  SDL_ReleaseGPUTransferBuffer(G.dev, tb);
  return true;
}

static int tex_slot_create(const void *pixels, int w, int h) {
  int id = -1;
  for (int i = 0; i < PAL_MAX_TEX; i++)
    if (!G.texs[i].used) { id = i; break; }
  if (id < 0) return -1;

  SDL_GPUTextureCreateInfo ti = {
      .type = SDL_GPU_TEXTURETYPE_2D,
      .format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
      .usage = SDL_GPU_TEXTUREUSAGE_SAMPLER,
      .width = (Uint32)w,
      .height = (Uint32)h,
      .layer_count_or_depth = 1,
      .num_levels = 1,
  };
  SDL_GPUTexture *tex = SDL_CreateGPUTexture(G.dev, &ti);
  if (!tex) { pal_log("gfx: tex_create: %s", SDL_GetError()); return -1; }

  if (!tex_upload(tex, pixels, w, h)) {
    SDL_ReleaseGPUTexture(G.dev, tex);
    return -1;
  }

  G.texs[id] = (PalTexture){.tex = tex, .w = w, .h = h, .used = true};
  return id;
}

bool pal_gfx_init(const PalGfxConfig *cfg) {
  if (G.gfx_up) {
    /* reboots re-run boot.lua. Same-config re-init is a no-op; a project
     * SWITCH (D052 — the picker's x_reboot cycle) retargets in place:
     * resize the internal target, retitle, honor the maximized ask. The
     * window itself survives — cm.view adapts to it live anyway. */
    if (cfg->w != G.iw || cfg->h != G.ih) {
      if (!pal_gfx_target_resize(cfg->w, cfg->h)) {
        pal_log("gfx: re-init target resize failed");
        return false;
      }
      G.scale = cfg->scale;
    }
    if (G.win) {
      SDL_SetWindowTitle(G.win, cfg->title ? cfg->title : "cosmic2d");
      if (cfg->maximized)
        SDL_MaximizeWindow(G.win);
      else
        SDL_RestoreWindow(G.win);
    }
    return true;
  }
  G.iw = cfg->w;
  G.ih = cfg->h;
  G.scale = cfg->scale;
  G.headless = cfg->headless;

  G.dev = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_SPIRV, true, NULL);
  if (!G.dev) { pal_log("gfx: no GPU device: %s", SDL_GetError()); return false; }
  pal_log("gfx: driver=%s%s", SDL_GetGPUDeviceDriver(G.dev),
          cfg->headless ? " (headless)" : "");

  if (!cfg->headless) {
    SDL_WindowFlags wf = SDL_WINDOW_RESIZABLE;
    if (cfg->maximized) wf |= SDL_WINDOW_MAXIMIZED; /* editor sessions (v7) */
    G.win = SDL_CreateWindow(cfg->title ? cfg->title : "cosmic2d",
                             cfg->w * cfg->scale, cfg->h * cfg->scale, wf);
    if (!G.win) { pal_log("gfx: window: %s", SDL_GetError()); return false; }
    if (!SDL_ClaimWindowForGPUDevice(G.dev, G.win)) {
      pal_log("gfx: claim window: %s", SDL_GetError());
      return false;
    }
    SDL_SetGPUSwapchainParameters(G.dev, G.win,
                                  SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
                                  cfg->vsync ? SDL_GPU_PRESENTMODE_VSYNC
                                             : SDL_GPU_PRESENTMODE_IMMEDIATE);
  }

  SDL_GPUTextureCreateInfo ti = {
      .type = SDL_GPU_TEXTURETYPE_2D,
      .format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
      .usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER,
      .width = (Uint32)cfg->w,
      .height = (Uint32)cfg->h,
      .layer_count_or_depth = 1,
      .num_levels = 1,
  };
  G.target = SDL_CreateGPUTexture(G.dev, &ti);
  if (!G.target) { pal_log("gfx: target: %s", SDL_GetError()); return false; }

  G.sampler = SDL_CreateGPUSampler(
      G.dev, &(SDL_GPUSamplerCreateInfo){
                 .min_filter = SDL_GPU_FILTER_NEAREST,
                 .mag_filter = SDL_GPU_FILTER_NEAREST,
                 .mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
                 .address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
                 .address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
                 .address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE});
  if (!G.sampler) return false;
  /* linear twin for the VI-soft present blit (pal.x_soft); clamp keeps the
   * edge rows/cols from bleeding the letterbox black in. */
  G.sampler_lin = SDL_CreateGPUSampler(
      G.dev, &(SDL_GPUSamplerCreateInfo){
                 .min_filter = SDL_GPU_FILTER_LINEAR,
                 .mag_filter = SDL_GPU_FILTER_LINEAR,
                 .mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
                 .address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
                 .address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
                 .address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE});
  if (!G.sampler_lin) return false;

  SDL_GPUShader *quad_vs =
      load_shader("pal/shaders/quad.vert.spv", SDL_GPU_SHADERSTAGE_VERTEX, 0, 1);
  SDL_GPUShader *quad_fs = load_shader("pal/shaders/quad.frag.spv",
                                       SDL_GPU_SHADERSTAGE_FRAGMENT, 1, 0);
  SDL_GPUShader *blit_vs =
      load_shader("pal/shaders/blit.vert.spv", SDL_GPU_SHADERSTAGE_VERTEX, 0, 1);
  /* the graded blit: blit.vert + a fragment that samples the game target
   * through the color grade (1 sampler, 1 uniform block). Only used when a
   * grade is active; the default blit stays quad_fs (bit-identical). */
  SDL_GPUShader *grade_fs = load_shader("pal/shaders/blit.frag.spv",
                                        SDL_GPU_SHADERSTAGE_FRAGMENT, 1, 1);
  /* the VI-soft blit (pal.x_soft): bilinear resample + horizontal smear on
   * the game-layer blit only; the sharp default stays quad_fs. */
  SDL_GPUShader *soft_fs = load_shader("pal/shaders/blit_soft.frag.spv",
                                       SDL_GPU_SHADERSTAGE_FRAGMENT, 1, 1);
  if (!quad_vs || !quad_fs || !blit_vs || !grade_fs || !soft_fs) return false;

  G.pipe_scene = make_pipeline(quad_vs, quad_fs,
                               SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, true, true);
  /* blended: the UI canvas composites over the game layer by its alpha
   * (transparent ui texels show the game through). The game blit is opaque
   * (alpha 1) so blending it over the black clear is a no-op (D036). Built for
   * the swapchain format when windowed, or the UNORM offscreen format headless
   * (so pal.x_capture can composite the same way without a window). */
  SDL_GPUTextureFormat blit_fmt =
      G.headless ? SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
                 : SDL_GetGPUSwapchainTextureFormat(G.dev, G.win);
  G.pipe_blit = make_pipeline(blit_vs, quad_fs, blit_fmt, true, false);
  G.pipe_blit_soft = make_pipeline(blit_vs, soft_fs, blit_fmt, true, false);
  /* the grade is a post-pass on the game target (UNORM), before readback +
   * composite — so a headless --shot and the pixel goldens see the graded
   * frame. Opaque (no blend): it overwrites the whole scratch target. */
  G.pipe_grade = make_pipeline(blit_vs, grade_fs,
                               SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, false,
                               false);
  SDL_ReleaseGPUShader(G.dev, quad_vs);
  SDL_ReleaseGPUShader(G.dev, quad_fs);
  SDL_ReleaseGPUShader(G.dev, blit_vs);
  SDL_ReleaseGPUShader(G.dev, grade_fs);
  SDL_ReleaseGPUShader(G.dev, soft_fs);
  if (!G.pipe_scene || !G.pipe_blit || !G.pipe_blit_soft || !G.pipe_grade)
    return false;

  G.readback_cap = (uint32_t)(cfg->w * cfg->h * 4);
  G.readback = SDL_CreateGPUTransferBuffer(
      G.dev, &(SDL_GPUTransferBufferCreateInfo){
                 .usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
                 .size = G.readback_cap});
  if (!G.readback) return false;

  G.lay_ox = 0;
  G.lay_oy = 0;
  G.lay_s = (float)cfg->scale;
  /* until the first present caches the real swapchain size, report the size
   * the window was created at (mechanism for the Lua-side resize ladder) */
  G.win_w = cfg->w * cfg->scale;
  G.win_h = cfg->h * cfg->scale;

  uint32_t white = 0xffffffffu;
  if (tex_slot_create(&white, 1, 1) != 0) {
    pal_log("gfx: builtin white texture failed");
    return false;
  }

  G.gfx_up = true;
  return true;
}

bool pal_gfx_target_resize(int w, int h) {
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  if (w > 4096) w = 4096;
  if (h > 4096) h = 4096;
  if (w == G.iw && h == G.ih) return true; /* no-op */

  SDL_GPUTexture *nt = SDL_CreateGPUTexture(
      G.dev, &(SDL_GPUTextureCreateInfo){
                 .type = SDL_GPU_TEXTURETYPE_2D,
                 .format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
                 .usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET |
                          SDL_GPU_TEXTUREUSAGE_SAMPLER,
                 .width = (Uint32)w,
                 .height = (Uint32)h,
                 .layer_count_or_depth = 1,
                 .num_levels = 1});
  if (!nt) {
    pal_log("gfx: target resize %dx%d: %s", w, h, SDL_GetError());
    return false;
  }

  /* grow the readback transfer buffer if the new target outsizes it */
  uint32_t need = (uint32_t)(w * h * 4);
  if (need > G.readback_cap) {
    SDL_GPUTransferBuffer *nr = SDL_CreateGPUTransferBuffer(
        G.dev, &(SDL_GPUTransferBufferCreateInfo){
                   .usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD, .size = need});
    if (!nr) {
      pal_log("gfx: readback grow %u: %s", need, SDL_GetError());
      SDL_ReleaseGPUTexture(G.dev, nt);
      return false;
    }
    SDL_ReleaseGPUTransferBuffer(G.dev, G.readback);
    G.readback = nr;
    G.readback_cap = need;
  }

  /* SDL_GPU defers the actual free until the GPU is done with the old texture,
   * so releasing it here is safe even mid-flight (same as tex_free). */
  SDL_ReleaseGPUTexture(G.dev, G.target);
  G.target = nt;
  G.iw = w;
  G.ih = h;
  return true;
}

bool pal_gfx_ui_target_resize(int w, int h) {
  if (w <= 0 || h <= 0) { /* free: no ui layer */
    if (G.ui_target) SDL_ReleaseGPUTexture(G.dev, G.ui_target);
    G.ui_target = NULL;
    G.ui_w = G.ui_h = 0;
    return true;
  }
  if (w > 4096) w = 4096;
  if (h > 4096) h = 4096;
  if (G.ui_target && w == G.ui_w && h == G.ui_h) return true; /* no-op */

  SDL_GPUTexture *nt = SDL_CreateGPUTexture(
      G.dev, &(SDL_GPUTextureCreateInfo){
                 .type = SDL_GPU_TEXTURETYPE_2D,
                 .format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
                 .usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET |
                          SDL_GPU_TEXTUREUSAGE_SAMPLER,
                 .width = (Uint32)w,
                 .height = (Uint32)h,
                 .layer_count_or_depth = 1,
                 .num_levels = 1});
  if (!nt) {
    pal_log("gfx: ui target %dx%d: %s", w, h, SDL_GetError());
    return false;
  }
  if (G.ui_target) SDL_ReleaseGPUTexture(G.dev, G.ui_target);
  G.ui_target = nt;
  G.ui_w = w;
  G.ui_h = h;
  return true;
}

void pal_gfx_begin(float r, float g, float b, float a) {
  G.clear[0] = r; G.clear[1] = g; G.clear[2] = b; G.clear[3] = a;
  G.vcount = 0;
  G.seg_count = 0;
  G.cam_x = 0;
  G.cam_y = 0;
  G.clip_on = false;
  G.cur_target = 0; /* draws default to the game target each frame */
  G.grade_set = false; /* the color grade is opt-in per frame (pal.x_grade) */
  G.soft_set = false;  /* so is the VI-soft present blit (pal.x_soft) */
  G.v3count = 0;
  G.seg3d_count = 0;
  G.view3d_count = 0; /* 3D is opt-in per frame, like the grade */
}

/* ---------- 3D retro pipeline (x_view3d/x_tris, docs/COSMIC3D.md §2) ----------
 * The prototype's gpu_proto.c grown into the PAL the cosmic2d way: same
 * CPU-batch + segment model as quads, one extra render pass. Everything here
 * is lazily created on first use so a pure-2D session's frame path (and its
 * pixel goldens) stays byte-identical to cosmic2d's. */

static SDL_GPUGraphicsPipeline *make_pipeline3d(SDL_GPUShader *vs,
                                                SDL_GPUShader *fs, bool blend) {
  SDL_GPUVertexBufferDescription vbd = {
      .slot = 0,
      .pitch = PAL_VERT3D_BYTES,
      .input_rate = SDL_GPU_VERTEXINPUTRATE_VERTEX,
  };
  SDL_GPUVertexAttribute attrs[3] = {
      {.location = 0, .buffer_slot = 0,
       .format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = 0},
      {.location = 1, .buffer_slot = 0,
       .format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 12},
      {.location = 2, .buffer_slot = 0,
       .format = SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = 20},
  };
  SDL_GPUColorTargetDescription ct = {
      .format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
      .blend_state = {
          .enable_blend = blend,
          .src_color_blendfactor = SDL_GPU_BLENDFACTOR_SRC_ALPHA,
          .dst_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
          .color_blend_op = SDL_GPU_BLENDOP_ADD,
          .src_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE,
          .dst_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
          .alpha_blend_op = SDL_GPU_BLENDOP_ADD,
      },
  };
  SDL_GPUGraphicsPipelineCreateInfo ci = {
      .vertex_shader = vs,
      .fragment_shader = fs,
      .primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
      .rasterizer_state = {.fill_mode = SDL_GPU_FILLMODE_FILL,
                           .cull_mode = SDL_GPU_CULLMODE_NONE},
      .multisample_state = {.sample_count = SDL_GPU_SAMPLECOUNT_1},
      .depth_stencil_state = {
          .compare_op = SDL_GPU_COMPAREOP_LESS_OR_EQUAL,
          .enable_depth_test = true,
          .enable_depth_write = !blend, /* decals never write depth */
      },
      .target_info = {.color_target_descriptions = &ct,
                      .num_color_targets = 1,
                      .depth_stencil_format = SDL_GPU_TEXTUREFORMAT_D16_UNORM,
                      .has_depth_stencil_target = true},
  };
  ci.vertex_input_state.vertex_buffer_descriptions = &vbd;
  ci.vertex_input_state.num_vertex_buffers = 1;
  ci.vertex_input_state.vertex_attributes = attrs;
  ci.vertex_input_state.num_vertex_attributes = 3;
  SDL_GPUGraphicsPipeline *p = SDL_CreateGPUGraphicsPipeline(G.dev, &ci);
  if (!p) pal_log("gfx: 3d pipeline: %s", SDL_GetError());
  return p;
}

static bool gfx3d_up(void) {
  if (G.pipe3d_opaque) return true;
  SDL_GPUShader *vs = load_shader("pal/shaders/retro.vert.spv",
                                  SDL_GPU_SHADERSTAGE_VERTEX, 0, 1);
  SDL_GPUShader *fs = load_shader("pal/shaders/retro.frag.spv",
                                  SDL_GPU_SHADERSTAGE_FRAGMENT, 1, 1);
  if (!vs || !fs) {
    if (vs) SDL_ReleaseGPUShader(G.dev, vs);
    if (fs) SDL_ReleaseGPUShader(G.dev, fs);
    return false;
  }
  G.pipe3d_opaque = make_pipeline3d(vs, fs, false);
  G.pipe3d_blend = make_pipeline3d(vs, fs, true);
  SDL_ReleaseGPUShader(G.dev, vs);
  SDL_ReleaseGPUShader(G.dev, fs);
  if (!G.pipe3d_opaque || !G.pipe3d_blend) {
    if (G.pipe3d_opaque) SDL_ReleaseGPUGraphicsPipeline(G.dev, G.pipe3d_opaque);
    if (G.pipe3d_blend) SDL_ReleaseGPUGraphicsPipeline(G.dev, G.pipe3d_blend);
    G.pipe3d_opaque = G.pipe3d_blend = NULL;
    return false;
  }
  return true;
}

bool pal_gfx_is_rt(int id) {
  return id > 0 && id < PAL_MAX_TEX && G.texs[id].used && G.texs[id].depth;
}

bool pal_gfx_view3d(const float mvp[16], float fog_start, float fog_end,
                    float fog_r, float fog_g, float fog_b, bool fog_on,
                    int target, const float *clearcol) {
  if (!gfx3d_up()) return false;
  if (G.view3d_count >= PAL_MAX_VIEW3D) return false;
  if (target >= 0 && !pal_gfx_is_rt(target)) return false;
  PalView3D *v = &G.views3d[G.view3d_count++];
  memcpy(v->mvp, mvp, sizeof v->mvp);
  v->fog[0] = fog_start;
  v->fog[1] = fog_end;
  v->fog[2] = fog_on ? 1.0f : 0.0f;
  v->fog[3] = 0;
  v->fogcol[0] = fog_r;
  v->fogcol[1] = fog_g;
  v->fogcol[2] = fog_b;
  v->fogcol[3] = 1;
  v->target = target < 0 ? -1 : target;
  v->clearcol[0] = clearcol ? clearcol[0] : 0;
  v->clearcol[1] = clearcol ? clearcol[1] : 0;
  v->clearcol[2] = clearcol ? clearcol[2] : 0;
  v->clearcol[3] = clearcol ? clearcol[3] : 1;
  return true;
}

bool pal_gfx_tris(int tex, const void *verts, uint32_t count, uint32_t flags) {
  if (!G.view3d_count) return false; /* x_view3d first (luabind errors) */
  if (!count) return true;
  if (tex < 0 || tex >= PAL_MAX_TEX || !G.texs[tex].used) tex = 0;
  int view = (int)G.view3d_count - 1;

  uint32_t nv = count * 3;
  if (G.v3count + nv > G.v3cap) {
    uint32_t cap = G.v3cap ? G.v3cap : 4096 * 3;
    while (cap < G.v3count + nv) cap *= 2;
    G.verts3d = realloc(G.verts3d, (size_t)cap * PAL_VERT3D_BYTES);
    G.v3cap = cap;
  }
  memcpy(G.verts3d + (size_t)G.v3count * PAL_VERT3D_BYTES, verts,
         (size_t)nv * PAL_VERT3D_BYTES);

  PalSeg3D *s = G.seg3d_count ? &G.segs3d[G.seg3d_count - 1] : NULL;
  if (!s || s->tex != tex || s->flags != flags || s->view != view) {
    if (G.seg3d_count == G.seg3d_cap) {
      G.seg3d_cap = G.seg3d_cap ? G.seg3d_cap * 2 : 64;
      G.segs3d = realloc(G.segs3d, G.seg3d_cap * sizeof *G.segs3d);
    }
    G.segs3d[G.seg3d_count++] = (PalSeg3D){
        .tex = tex, .flags = flags, .view = view, .first = G.v3count, .count = 0};
    s = &G.segs3d[G.seg3d_count - 1];
  }
  G.v3count += nv;
  s->count += nv;
  return true;
}

/* the 3D pass(es): draws the accumulated 3D segments, one render pass per
 * run of consecutive same-target segments (v24 — views carry a target: the
 * game target by default, or an x_rt texture for editor viewports). A
 * target's FIRST run this frame clears (game: the frame clear + depth far;
 * RT: its view's clear color); later runs LOAD, so interleaved submission
 * composes instead of erasing. Depth STOREs for the same reason. Returns
 * whether the GAME target got a 3D pass — the 2D scene_pass then LOADs over
 * it so quads/HUD composite on top (an RT-only frame keeps the 2D clear). */
static bool scene3d_pass(SDL_GPUCommandBuffer *cmd) {
  /* game depth target tracks the internal target size (FOV resizes are live) */
  if (!G.depth3d || G.depth3d_w != G.iw || G.depth3d_h != G.ih) {
    if (G.depth3d) SDL_ReleaseGPUTexture(G.dev, G.depth3d);
    G.depth3d = SDL_CreateGPUTexture(
        G.dev, &(SDL_GPUTextureCreateInfo){
                   .type = SDL_GPU_TEXTURETYPE_2D,
                   .format = SDL_GPU_TEXTUREFORMAT_D16_UNORM,
                   .usage = SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
                   .width = (Uint32)G.iw,
                   .height = (Uint32)G.ih,
                   .layer_count_or_depth = 1,
                   .num_levels = 1});
    if (!G.depth3d) {
      pal_log("gfx: 3d depth target: %s", SDL_GetError());
      G.depth3d_w = G.depth3d_h = 0;
      return false; /* present falls back to the 2D clear */
    }
    G.depth3d_w = G.iw;
    G.depth3d_h = G.ih;
  }

  bool game_touched = false, cleared_game = false;
  bool cleared_rt[PAL_MAX_TEX] = {false};
  struct { float mvp[16]; float fog[4]; } vubo;
  struct { float mode[4]; float fogcol[4]; } fubo;
  uint32_t i = 0;
  while (i < G.seg3d_count) {
    int tgt = G.views3d[G.segs3d[i].view].target;
    uint32_t run_end = i;
    while (run_end < G.seg3d_count &&
           G.views3d[G.segs3d[run_end].view].target == tgt)
      run_end++;
    bool first;
    SDL_GPUTexture *color, *depth;
    const float *cc;
    if (tgt < 0) {
      color = G.target;
      depth = G.depth3d;
      cc = G.clear;
      first = !cleared_game;
      cleared_game = true;
      game_touched = true;
    } else {
      color = G.texs[tgt].tex;
      depth = G.texs[tgt].depth;
      cc = G.views3d[G.segs3d[i].view].clearcol;
      first = !cleared_rt[tgt];
      cleared_rt[tgt] = true;
    }
    SDL_GPUColorTargetInfo ct = {
        .texture = color,
        .clear_color = {cc[0], cc[1], cc[2], cc[3]},
        .load_op = first ? SDL_GPU_LOADOP_CLEAR : SDL_GPU_LOADOP_LOAD,
        .store_op = SDL_GPU_STOREOP_STORE,
    };
    SDL_GPUDepthStencilTargetInfo dst = {
        .texture = depth,
        .clear_depth = 1.0f,
        .load_op = first ? SDL_GPU_LOADOP_CLEAR : SDL_GPU_LOADOP_LOAD,
        .store_op = SDL_GPU_STOREOP_STORE,
    };
    SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &ct, 1, &dst);
    int cur_blend = -1, cur_view = -1;
    for (uint32_t k = i; k < run_end; k++) {
      PalSeg3D *s = &G.segs3d[k];
      int blend = (s->flags & PAL_TRI_BLEND) ? 1 : 0;
      if (blend != cur_blend) {
        SDL_BindGPUGraphicsPipeline(pass,
                                    blend ? G.pipe3d_blend : G.pipe3d_opaque);
        SDL_BindGPUVertexBuffers(pass, 0,
                                 &(SDL_GPUBufferBinding){.buffer = G.vbuf3d}, 1);
        cur_blend = blend;
        cur_view = -1; /* uniforms rebind after a pipeline switch */
      }
      PalView3D *v = &G.views3d[s->view];
      if (s->view != cur_view) {
        memcpy(vubo.mvp, v->mvp, sizeof vubo.mvp);
        memcpy(vubo.fog, v->fog, sizeof vubo.fog);
        SDL_PushGPUVertexUniformData(cmd, 0, &vubo, sizeof vubo);
        cur_view = s->view;
      }
      fubo.mode[0] = (s->flags & PAL_TRI_NEAREST) ? 0.0f : 1.0f;
      fubo.mode[1] = (s->flags & PAL_TRI_ALPHATEST) ? 1.0f : 0.0f;
      fubo.mode[2] = fubo.mode[3] = 0;
      memcpy(fubo.fogcol, v->fogcol, sizeof fubo.fogcol);
      SDL_PushGPUFragmentUniformData(cmd, 0, &fubo, sizeof fubo);
      SDL_BindGPUFragmentSamplers(
          pass, 0,
          &(SDL_GPUTextureSamplerBinding){.texture = G.texs[s->tex].tex,
                                          .sampler = G.sampler},
          1);
      if (getenv("PAL_DBG_3D"))
        pal_log("seg3d %u: tex=%d flags=%u view=%d tgt=%d first=%u count=%u",
                k, s->tex, s->flags, s->view, tgt, s->first, s->count);
      SDL_DrawGPUPrimitives(pass, s->count, 1, s->first, 0);
    }
    SDL_EndGPURenderPass(pass);
    i = run_end;
  }
  return game_touched;
}

static void seg_for(int tex) {
  PalSeg *s = G.seg_count ? &G.segs[G.seg_count - 1] : NULL;
  if (s && s->tex == tex && s->target == G.cur_target &&
      s->has_clip == G.clip_on &&
      (!G.clip_on || (s->clip.x == G.clip.x && s->clip.y == G.clip.y &&
                      s->clip.w == G.clip.w && s->clip.h == G.clip.h)))
    return;
  if (G.seg_count == G.seg_cap) {
    G.seg_cap = G.seg_cap ? G.seg_cap * 2 : 64;
    G.segs = realloc(G.segs, G.seg_cap * sizeof *G.segs);
  }
  G.segs[G.seg_count++] = (PalSeg){.tex = tex,
                                   .target = G.cur_target,
                                   .has_clip = G.clip_on,
                                   .clip = G.clip,
                                   .first = G.vcount,
                                   .count = 0};
}

void pal_gfx_quad(float x, float y, float w, float h, float u0, float v0,
                  float u1, float v1, uint32_t rgba, int tex) {
  if (tex < 0 || tex >= PAL_MAX_TEX || !G.texs[tex].used) tex = 0;
  seg_for(tex);

  if (G.vcount + 6 > G.vcap) {
    G.vcap = G.vcap ? G.vcap * 2 : 4096 * 6;
    G.verts = realloc(G.verts, (size_t)G.vcap * PAL_VERT_BYTES);
  }
  x -= G.cam_x;
  y -= G.cam_y;
  float px[4] = {x, x + w, x, x + w};
  float py[4] = {y, y, y + h, y + h};
  float pu[4] = {u0, u1, u0, u1};
  float pv[4] = {v0, v0, v1, v1};
  static const int idx[6] = {0, 1, 2, 2, 1, 3};
  uint8_t *out = G.verts + (size_t)G.vcount * PAL_VERT_BYTES;
  for (int i = 0; i < 6; i++) {
    int c = idx[i];
    float fx = px[c], fy = py[c], fu = pu[c], fv = pv[c];
    memcpy(out, &fx, 4);
    memcpy(out + 4, &fy, 4);
    memcpy(out + 8, &fu, 4);
    memcpy(out + 12, &fv, 4);
    memcpy(out + 16, &rgba, 4);
    out += PAL_VERT_BYTES;
  }
  G.vcount += 6;
  G.segs[G.seg_count - 1].count += 6;
}

void pal_gfx_clip(bool on, int x, int y, int w, int h) {
  G.clip_on = on;
  if (on) G.clip = (SDL_Rect){x, y, w, h};
}

/* render the accumulated segments belonging to one target into a texture,
 * clearing it first (clear = NULL loads instead: the 3D pass already cleared
 * + drew under the 2D quads). The vertex buffer is shared; we just draw the
 * segs whose target matches, with this target's projection + full scissor. */
static void scene_pass(SDL_GPUCommandBuffer *cmd, SDL_GPUTexture *tex, int tw,
                       int th, int target_id, const float clear[4]) {
  SDL_GPUColorTargetInfo ct = {
      .texture = tex,
      .load_op = clear ? SDL_GPU_LOADOP_CLEAR : SDL_GPU_LOADOP_LOAD,
      .store_op = SDL_GPU_STOREOP_STORE,
  };
  if (clear)
    ct.clear_color = (SDL_FColor){clear[0], clear[1], clear[2], clear[3]};
  SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &ct, 1, NULL);
  if (G.vcount) {
    SDL_BindGPUGraphicsPipeline(pass, G.pipe_scene);
    SDL_BindGPUVertexBuffers(pass, 0,
                             &(SDL_GPUBufferBinding){.buffer = G.vbuf}, 1);
    float proj[4] = {2.0f / tw, -2.0f / th, -1.0f, 1.0f};
    SDL_PushGPUVertexUniformData(cmd, 0, proj, sizeof proj);
    for (uint32_t i = 0; i < G.seg_count; i++) {
      PalSeg *s = &G.segs[i];
      if (s->target != target_id) continue;
      SDL_Rect full = {0, 0, tw, th};
      SDL_SetGPUScissor(pass, s->has_clip ? &s->clip : &full);
      SDL_BindGPUFragmentSamplers(
          pass, 0,
          &(SDL_GPUTextureSamplerBinding){.texture = G.texs[s->tex].tex,
                                          .sampler = G.sampler},
          1);
      SDL_DrawGPUPrimitives(pass, s->count, 1, s->first, 0);
    }
  }
  SDL_EndGPURenderPass(pass);
}

/* blit a target into the bound swapchain pass at a window-px rect (top-left
 * origin + size). The right blit pipeline must already be bound. */
static void blit_layer(SDL_GPUCommandBuffer *cmd, SDL_GPURenderPass *pp,
                       SDL_GPUTexture *tex, SDL_GPUSampler *smp, float ox,
                       float oy, float w, float h, float sw, float sh) {
  /* NDC rect: x0,y0 = top-left, x1,y1 = bottom-right (y down in pixels) */
  float rect[4] = {ox / sw * 2 - 1, 1 - oy / sh * 2, (ox + w) / sw * 2 - 1,
                   1 - (oy + h) / sh * 2};
  SDL_PushGPUVertexUniformData(cmd, 0, rect, sizeof rect);
  SDL_BindGPUFragmentSamplers(
      pp, 0, &(SDL_GPUTextureSamplerBinding){.texture = tex, .sampler = smp},
      1);
  SDL_DrawGPUPrimitives(pp, 6, 1, 0, 0);
}

/* composite the game target (into its viewport rect) + the ui canvas (over the
 * whole window) + the ig layer (imgui, native res, topmost — D049) into a
 * destination texture of sw x sh px. Sets lay_* (the window -> game-viewport
 * -> FOV mouse map). Shared by the live swapchain present and the headless
 * capture, so a screenshot matches the window. */
static void composite(SDL_GPUCommandBuffer *cmd, SDL_GPUTexture *dst, int sw,
                      int sh, SDL_GPUTextureFormat fmt, bool ig_keep) {
  /* game viewport (window px) + integer scale: explicit via pal.x_compose, else
   * a centered integer letterbox (shipped game / default). x_compose{scale=0}
   * = don't blit the game layer at all (the R3 editor draws the game target
   * itself via x_ig_image(-1); the blit would double it). */
  bool hide_game = G.compose_set && G.vp_scale == 0;
  float gs;
  if (G.compose_set) {
    gs = G.vp_scale > 0 ? (float)G.vp_scale : 1.0f; /* 1 = sane mouse map */
    G.lay_ox = (float)G.vp_x;
    G.lay_oy = (float)G.vp_y;
  } else {
    int s = (int)SDL_min((Uint32)sw / (Uint32)G.iw, (Uint32)sh / (Uint32)G.ih);
    if (s < 1) s = 1;
    gs = (float)s;
    G.lay_ox = ((float)sw - (float)G.iw * gs) / 2.0f;
    G.lay_oy = ((float)sh - (float)G.ih * gs) / 2.0f;
  }
  G.lay_s = gs;

  SDL_GPUColorTargetInfo pct = {
      .texture = dst,
      .clear_color = {0, 0, 0, 1},
      .load_op = SDL_GPU_LOADOP_CLEAR,
      .store_op = SDL_GPU_STOREOP_STORE,
  };
  SDL_GPURenderPass *pp = SDL_BeginGPURenderPass(cmd, &pct, 1, NULL);
  if (!hide_game) {
    /* game layer: sharp nearest blit, or the VI-soft resample (pal.x_soft) —
     * bilinear sampling + a 3-tap smear whose taps are one DESTINATION px
     * apart (the frag uniform). Only this layer softens; ui/ig stay sharp. */
    if (G.soft_set) {
      SDL_BindGPUGraphicsPipeline(pp, G.pipe_blit_soft);
      float px[4] = {1.0f / ((float)G.iw * gs), 0, 0, 0};
      SDL_PushGPUFragmentUniformData(cmd, 0, px, sizeof px);
      blit_layer(cmd, pp, G.target, G.sampler_lin, G.lay_ox, G.lay_oy,
                 (float)G.iw * gs, (float)G.ih * gs, (float)sw, (float)sh);
    } else {
      SDL_BindGPUGraphicsPipeline(pp, G.pipe_blit);
      blit_layer(cmd, pp, G.target, G.sampler, G.lay_ox, G.lay_oy,
                 (float)G.iw * gs, (float)G.ih * gs, (float)sw, (float)sh);
    }
  }
  if (G.ui_target && G.ui_scale > 0) {
    SDL_BindGPUGraphicsPipeline(pp, G.pipe_blit);
    blit_layer(cmd, pp, G.ui_target, G.sampler, 0, 0,
               (float)G.ui_w * G.ui_scale, (float)G.ui_h * G.ui_scale,
               (float)sw, (float)sh);
  }
  /* the ig layer (imgui draw data) renders last = above everything, at
   * native destination resolution. No-op when no ig frame was prepared. */
  pal_ig_render_draw(cmd, pp, fmt, ig_keep);
  SDL_EndGPURenderPass(pp);
}

/* the color grade (pal.x_grade) as a post-pass on the game target: sample
 * G.target through pipe_grade into a same-size scratch, then swap so G.target
 * IS the graded frame — the readback (headless --shot + pixel goldens) and the
 * live composite both see it. Render/dev; the ungraded path never runs this,
 * so the default frame (and every golden) is byte-identical. */
static void grade_pass(SDL_GPUCommandBuffer *cmd) {
  if (!G.grade_tmp || G.grade_tmp_w != G.iw || G.grade_tmp_h != G.ih) {
    if (G.grade_tmp) SDL_ReleaseGPUTexture(G.dev, G.grade_tmp);
    G.grade_tmp = SDL_CreateGPUTexture(
        G.dev, &(SDL_GPUTextureCreateInfo){
                   .type = SDL_GPU_TEXTURETYPE_2D,
                   .format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
                   .usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET |
                            SDL_GPU_TEXTUREUSAGE_SAMPLER,
                   .width = (Uint32)G.iw,
                   .height = (Uint32)G.ih,
                   .layer_count_or_depth = 1,
                   .num_levels = 1});
    if (!G.grade_tmp) return;
    G.grade_tmp_w = G.iw;
    G.grade_tmp_h = G.ih;
  }
  SDL_GPUColorTargetInfo ct = {.texture = G.grade_tmp,
                               .load_op = SDL_GPU_LOADOP_DONT_CARE,
                               .store_op = SDL_GPU_STOREOP_STORE};
  SDL_GPURenderPass *pp = SDL_BeginGPURenderPass(cmd, &ct, 1, NULL);
  SDL_BindGPUGraphicsPipeline(pp, G.pipe_grade);
  float rect[4] = {-1, 1, 1, -1}; /* fullscreen; uv (0,0) = top-left */
  SDL_PushGPUVertexUniformData(cmd, 0, rect, sizeof rect);
  SDL_PushGPUFragmentUniformData(cmd, 0, G.grade, sizeof G.grade);
  SDL_BindGPUFragmentSamplers(
      pp, 0,
      &(SDL_GPUTextureSamplerBinding){.texture = G.target, .sampler = G.sampler},
      1);
  SDL_DrawGPUPrimitives(pp, 6, 1, 0, 0);
  SDL_EndGPURenderPass(pp);
  SDL_GPUTexture *t = G.target; /* swap: G.target is now the graded frame */
  G.target = G.grade_tmp;
  G.grade_tmp = t;
}

static void tex_reap(void); /* defined below, near pal_gfx_tex_free */

bool pal_gfx_present(void) {
  tex_reap(); /* release textures freed 2 presents ago (their frames submitted) */
  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(G.dev);
  if (!cmd) { pal_log("gfx: acquire cmd: %s", SDL_GetError()); return false; }

  uint32_t bytes = G.vcount * PAL_VERT_BYTES;
  G.stat_quads = G.vcount / 6;
  G.stat_segs = G.seg_count;
  G.stat_vbytes = bytes;
  G.stat_tris = G.v3count / 3;
  G.stat_segs3d = G.seg3d_count;

  /* 3D batch upload (own buffer; the 2D flush below is untouched) */
  uint32_t bytes3d = G.v3count * PAL_VERT3D_BYTES;
  if (bytes3d) {
    if (bytes3d > G.gpubuf3d_cap) {
      uint32_t cap = G.gpubuf3d_cap ? G.gpubuf3d_cap
                                    : 4096 * 3 * PAL_VERT3D_BYTES;
      while (cap < bytes3d) cap *= 2;
      if (G.vbuf3d) SDL_ReleaseGPUBuffer(G.dev, G.vbuf3d);
      if (G.tbuf3d) SDL_ReleaseGPUTransferBuffer(G.dev, G.tbuf3d);
      G.vbuf3d = SDL_CreateGPUBuffer(
          G.dev, &(SDL_GPUBufferCreateInfo){.usage = SDL_GPU_BUFFERUSAGE_VERTEX,
                                            .size = cap});
      G.tbuf3d = SDL_CreateGPUTransferBuffer(
          G.dev, &(SDL_GPUTransferBufferCreateInfo){
                     .usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = cap});
      if (!G.vbuf3d || !G.tbuf3d) {
        pal_log("gfx: 3d vbuf: %s", SDL_GetError());
        return false;
      }
      G.gpubuf3d_cap = cap;
    }
    void *p3 = SDL_MapGPUTransferBuffer(G.dev, G.tbuf3d, true);
    memcpy(p3, G.verts3d, bytes3d);
    SDL_UnmapGPUTransferBuffer(G.dev, G.tbuf3d);
    SDL_GPUCopyPass *cp3 = SDL_BeginGPUCopyPass(cmd);
    SDL_UploadToGPUBuffer(
        cp3, &(SDL_GPUTransferBufferLocation){.transfer_buffer = G.tbuf3d},
        &(SDL_GPUBufferRegion){.buffer = G.vbuf3d, .size = bytes3d}, true);
    SDL_EndGPUCopyPass(cp3);
  }

  if (bytes) {
    if (bytes > G.gpubuf_cap) {
      uint32_t cap = G.gpubuf_cap ? G.gpubuf_cap : 4096 * 6 * PAL_VERT_BYTES;
      while (cap < bytes) cap *= 2;
      if (G.vbuf) SDL_ReleaseGPUBuffer(G.dev, G.vbuf);
      if (G.tbuf) SDL_ReleaseGPUTransferBuffer(G.dev, G.tbuf);
      G.vbuf = SDL_CreateGPUBuffer(
          G.dev, &(SDL_GPUBufferCreateInfo){.usage = SDL_GPU_BUFFERUSAGE_VERTEX,
                                            .size = cap});
      G.tbuf = SDL_CreateGPUTransferBuffer(
          G.dev, &(SDL_GPUTransferBufferCreateInfo){
                     .usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = cap});
      if (!G.vbuf || !G.tbuf) { pal_log("gfx: vbuf: %s", SDL_GetError()); return false; }
      G.gpubuf_cap = cap;
    }
    void *p = SDL_MapGPUTransferBuffer(G.dev, G.tbuf, true);
    memcpy(p, G.verts, bytes);
    SDL_UnmapGPUTransferBuffer(G.dev, G.tbuf);
    SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(cmd);
    SDL_UploadToGPUBuffer(
        cp, &(SDL_GPUTransferBufferLocation){.transfer_buffer = G.tbuf},
        &(SDL_GPUBufferRegion){.buffer = G.vbuf, .size = bytes}, true);
    SDL_EndGPUCopyPass(cp);
  }

  /* scene passes: game segments -> game target; ui segments -> ui canvas.
   * The game clears to its bg (opaque); the ui canvas clears to transparent so
   * the game viewport shows through wherever no chrome was drawn. When the 3D
   * pass ran, it owned the clear and the 2D pass loads over it (HUD on top). */
  bool ran3d = bytes3d && scene3d_pass(cmd);
  scene_pass(cmd, G.target, G.iw, G.ih, 0, ran3d ? NULL : G.clear);
  if (G.grade_set) grade_pass(cmd); /* bake the grade into the game target */
  if (G.ui_target) {
    static const float transparent[4] = {0, 0, 0, 0};
    scene_pass(cmd, G.ui_target, G.ui_w, G.ui_h, 1, transparent);
  }

  /* close + upload the ig frame (if one is open) BEFORE the composite pass —
   * imgui's buffer/texture uploads need a copy pass, which can't nest inside
   * a render pass. The frame is closed here even if presentation is skipped
   * (minimized), so the ig state machine never strands an open frame. */
  pal_ig_render_prepare(cmd);

  /* present composite: into the live swapchain, or the offscreen capture target
   * (pal.x_capture) so a headless screenshot can show the editor-around-game
   * composite that otherwise only exists in the window. */
  bool live = !G.headless && G.win;
  if (G.cap_on && G.cap_target && !live) {
    G.win_w = G.cap_w;
    G.win_h = G.cap_h;
    composite(cmd, G.cap_target, G.cap_w, G.cap_h, G.cap_fmt, false);
  } else if (live) {
    /* a capture target armed DURING a live session mirrors the composite
     * (the editor's screen-space eyedropper reads it back); it renders
     * first — with ig kept — so the swapchain pass still draws the ig
     * layer and owns the lay_* mouse map. */
    if (G.cap_on && G.cap_target)
      composite(cmd, G.cap_target, G.cap_w, G.cap_h, G.cap_fmt, true);
    SDL_GPUTexture *swap = NULL;
    Uint32 sw = 0, sh = 0;
    if (!SDL_WaitAndAcquireGPUSwapchainTexture(cmd, G.win, &swap, &sw, &sh)) {
      pal_log("gfx: swapchain: %s", SDL_GetError());
      SDL_SubmitGPUCommandBuffer(cmd);
      return false;
    }
    if (swap) { /* NULL = minimized; skip presentation */
      G.win_w = (int)sw; /* cache real swapchain px for pal.x_window_size */
      G.win_h = (int)sh;
      composite(cmd, swap, (int)sw, (int)sh,
                SDL_GetGPUSwapchainTextureFormat(G.dev, G.win), false);
    }
  }

  SDL_SubmitGPUCommandBuffer(cmd);
  return true;
}

const void *pal_gfx_read_begin(size_t *len) {
  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(G.dev);
  SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(cmd);
  SDL_DownloadFromGPUTexture(
      cp,
      &(SDL_GPUTextureRegion){
          .texture = G.target, .w = (Uint32)G.iw, .h = (Uint32)G.ih, .d = 1},
      &(SDL_GPUTextureTransferInfo){.transfer_buffer = G.readback,
                                    .pixels_per_row = (Uint32)G.iw,
                                    .rows_per_layer = (Uint32)G.ih});
  SDL_EndGPUCopyPass(cp);
  SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
  if (!fence) { pal_log("gfx: readback submit: %s", SDL_GetError()); return NULL; }
  SDL_WaitForGPUFences(G.dev, true, &fence, 1);
  SDL_ReleaseGPUFence(G.dev, fence);
  *len = (size_t)G.iw * G.ih * 4;
  return SDL_MapGPUTransferBuffer(G.dev, G.readback, false);
}

void pal_gfx_read_end(void) { SDL_UnmapGPUTransferBuffer(G.dev, G.readback); }

bool pal_gfx_capture(int w, int h) {
  if (w <= 0 || h <= 0) { /* disable + free */
    if (G.cap_target) SDL_ReleaseGPUTexture(G.dev, G.cap_target);
    G.cap_target = NULL;
    G.cap_w = G.cap_h = 0;
    G.cap_on = false;
    return true;
  }
  if (w > 4096) w = 4096;
  if (h > 4096) h = 4096;
  /* a LIVE session's capture is a mirror of the presented composite: it
   * must allocate in the swapchain's format so the ig pipeline (built for
   * that format at init) draws into it. Headless capture keeps RGBA8.
   * Readback hands out RGBA8 either way (BGRA swizzles in place). */
  SDL_GPUTextureFormat fmt = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
  if (!G.headless && G.win)
    fmt = SDL_GetGPUSwapchainTextureFormat(G.dev, G.win);
  if (fmt != SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM &&
      fmt != SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM) {
    pal_log("gfx: capture: unsupported swapchain format %d", (int)fmt);
    return false;
  }
  if (!(G.cap_target && w == G.cap_w && h == G.cap_h && fmt == G.cap_fmt)) {
    SDL_GPUTexture *nt = SDL_CreateGPUTexture(
        G.dev, &(SDL_GPUTextureCreateInfo){
                   .type = SDL_GPU_TEXTURETYPE_2D,
                   .format = fmt,
                   .usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET |
                            SDL_GPU_TEXTUREUSAGE_SAMPLER,
                   .width = (Uint32)w,
                   .height = (Uint32)h,
                   .layer_count_or_depth = 1,
                   .num_levels = 1});
    if (!nt) {
      pal_log("gfx: capture %dx%d: %s", w, h, SDL_GetError());
      return false;
    }
    if (G.cap_target) SDL_ReleaseGPUTexture(G.dev, G.cap_target);
    G.cap_target = nt;
    G.cap_w = w;
    G.cap_h = h;
    G.cap_fmt = fmt;
  }
  G.cap_on = true;
  if (G.headless || !G.win) {
    G.win_w = w; /* so pal.x_window_size reports the captured window size */
    G.win_h = h;
  }
  return true;
}

const void *pal_gfx_cap_read_begin(size_t *len) {
  if (!G.cap_target) return NULL;
  uint32_t need = (uint32_t)(G.cap_w * G.cap_h * 4);
  if (need > G.cap_readback_cap) {
    if (G.cap_readback) SDL_ReleaseGPUTransferBuffer(G.dev, G.cap_readback);
    G.cap_readback = SDL_CreateGPUTransferBuffer(
        G.dev, &(SDL_GPUTransferBufferCreateInfo){
                   .usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD, .size = need});
    if (!G.cap_readback) { pal_log("gfx: cap readback alloc: %s", SDL_GetError()); return NULL; }
    G.cap_readback_cap = need;
  }
  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(G.dev);
  SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(cmd);
  SDL_DownloadFromGPUTexture(
      cp,
      &(SDL_GPUTextureRegion){
          .texture = G.cap_target, .w = (Uint32)G.cap_w, .h = (Uint32)G.cap_h, .d = 1},
      &(SDL_GPUTextureTransferInfo){.transfer_buffer = G.cap_readback,
                                    .pixels_per_row = (Uint32)G.cap_w,
                                    .rows_per_layer = (Uint32)G.cap_h});
  SDL_EndGPUCopyPass(cp);
  SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
  if (!fence) { pal_log("gfx: cap readback submit: %s", SDL_GetError()); return NULL; }
  SDL_WaitForGPUFences(G.dev, true, &fence, 1);
  SDL_ReleaseGPUFence(G.dev, fence);
  *len = (size_t)G.cap_w * G.cap_h * 4;
  uint8_t *p = SDL_MapGPUTransferBuffer(G.dev, G.cap_readback, false);
  if (p && G.cap_fmt == SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM) {
    /* the contract is RGBA8 whatever the target format was (the live
     * mirror rides the swapchain's layout) — swizzle in place */
    for (size_t i = 0; i < *len; i += 4) {
      uint8_t b = p[i];
      p[i] = p[i + 2];
      p[i + 2] = b;
    }
  }
  return p;
}

void pal_gfx_cap_read_end(void) {
  SDL_UnmapGPUTransferBuffer(G.dev, G.cap_readback);
}

int pal_gfx_tex_create(const void *pixels, int w, int h) {
  return tex_slot_create(pixels, w, h);
}

/* an offscreen 3D view target (pal.x_rt, v24 — D137): an ordinary texture
 * slot whose texture is also a color target, plus its own D16 depth so
 * x_view3d{target=} can depth-test into it. Same slot/pend lifetime as any
 * texture (tex_free defers, tex_reap releases both). */
int pal_gfx_rt_create(int w, int h) {
  int id = -1;
  for (int i = 0; i < PAL_MAX_TEX; i++)
    if (!G.texs[i].used) { id = i; break; }
  if (id < 0) return -1;
  SDL_GPUTexture *tex = SDL_CreateGPUTexture(
      G.dev, &(SDL_GPUTextureCreateInfo){
                 .type = SDL_GPU_TEXTURETYPE_2D,
                 .format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
                 .usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET |
                          SDL_GPU_TEXTUREUSAGE_SAMPLER,
                 .width = (Uint32)w,
                 .height = (Uint32)h,
                 .layer_count_or_depth = 1,
                 .num_levels = 1});
  if (!tex) { pal_log("gfx: x_rt: %s", SDL_GetError()); return -1; }
  SDL_GPUTexture *depth = SDL_CreateGPUTexture(
      G.dev, &(SDL_GPUTextureCreateInfo){
                 .type = SDL_GPU_TEXTURETYPE_2D,
                 .format = SDL_GPU_TEXTUREFORMAT_D16_UNORM,
                 .usage = SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
                 .width = (Uint32)w,
                 .height = (Uint32)h,
                 .layer_count_or_depth = 1,
                 .num_levels = 1});
  if (!depth) {
    pal_log("gfx: x_rt depth: %s", SDL_GetError());
    SDL_ReleaseGPUTexture(G.dev, tex);
    return -1;
  }
  G.texs[id] =
      (PalTexture){.tex = tex, .depth = depth, .w = w, .h = h, .used = true};
  return id;
}

/* re-upload into an existing texture in place (no GPU realloc). false if the id
 * is free or the size changed — the caller should free + create instead. */
bool pal_gfx_tex_update(int id, const void *pixels, int w, int h) {
  if (id <= 0 || id >= PAL_MAX_TEX || !G.texs[id].used || G.texs[id].pend)
    return false;
  if (G.texs[id].w != w || G.texs[id].h != h) return false;
  return tex_upload(G.texs[id].tex, pixels, w, h);
}

/* DEFER the GPU release. Draw segments queued this frame reference this slot by
 * ID (resolved to G.texs[id].tex at flush, with no used-check), so releasing —
 * or clearing — the slot now would dangle/NULL them at submit. Instead mark it
 * pending: it stays 'used' with a valid texture (skipped by tex_create,
 * refused by tex_update) until tex_reap() releases it after its frame ships. */
bool pal_gfx_tex_free(int id) {
  if (id <= 0 || id >= PAL_MAX_TEX || !G.texs[id].used || G.texs[id].pend)
    return false;
  G.texs[id].pend = 1;
  return true;
}

/* two-stage deferred delete, run at the top of each present: a slot freed on
 * frame N (pend=1) is bumped to pend=2 this present (frame N still references
 * it in the pass about to submit), then released the NEXT present — frame N is
 * submitted by then, so SDL_GPU's own deferral covers the GPU-side lifetime.
 * Slot 0 (the default white) is never freed. */
static void tex_reap(void) {
  for (int i = 1; i < PAL_MAX_TEX; i++) {
    if (G.texs[i].pend == 2) {
      SDL_ReleaseGPUTexture(G.dev, G.texs[i].tex);
      if (G.texs[i].depth) SDL_ReleaseGPUTexture(G.dev, G.texs[i].depth);
      G.texs[i] = (PalTexture){0};
    } else if (G.texs[i].pend == 1) {
      G.texs[i].pend = 2;
    }
  }
}
