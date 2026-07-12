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
    /* reboots re-run boot.lua; same-config re-init is a no-op */
    if (cfg->w == G.iw && cfg->h == G.ih) return true;
    pal_log("gfx: re-init with different size needs an engine restart");
    return false;
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

  SDL_GPUShader *quad_vs =
      load_shader("pal/shaders/quad.vert.spv", SDL_GPU_SHADERSTAGE_VERTEX, 0, 1);
  SDL_GPUShader *quad_fs = load_shader("pal/shaders/quad.frag.spv",
                                       SDL_GPU_SHADERSTAGE_FRAGMENT, 1, 0);
  SDL_GPUShader *blit_vs =
      load_shader("pal/shaders/blit.vert.spv", SDL_GPU_SHADERSTAGE_VERTEX, 0, 1);
  if (!quad_vs || !quad_fs || !blit_vs) return false;

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
  SDL_ReleaseGPUShader(G.dev, quad_vs);
  SDL_ReleaseGPUShader(G.dev, quad_fs);
  SDL_ReleaseGPUShader(G.dev, blit_vs);
  if (!G.pipe_scene || !G.pipe_blit) return false;

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
 * clearing it first. The vertex buffer is shared; we just draw the segs whose
 * target matches, with this target's projection + full-rect scissor. */
static void scene_pass(SDL_GPUCommandBuffer *cmd, SDL_GPUTexture *tex, int tw,
                       int th, int target_id, const float clear[4]) {
  SDL_GPUColorTargetInfo ct = {
      .texture = tex,
      .clear_color = {clear[0], clear[1], clear[2], clear[3]},
      .load_op = SDL_GPU_LOADOP_CLEAR,
      .store_op = SDL_GPU_STOREOP_STORE,
  };
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
 * origin + size). pipe_blit must already be bound. */
static void blit_layer(SDL_GPUCommandBuffer *cmd, SDL_GPURenderPass *pp,
                       SDL_GPUTexture *tex, float ox, float oy, float w,
                       float h, float sw, float sh) {
  /* NDC rect: x0,y0 = top-left, x1,y1 = bottom-right (y down in pixels) */
  float rect[4] = {ox / sw * 2 - 1, 1 - oy / sh * 2, (ox + w) / sw * 2 - 1,
                   1 - (oy + h) / sh * 2};
  SDL_PushGPUVertexUniformData(cmd, 0, rect, sizeof rect);
  SDL_BindGPUFragmentSamplers(
      pp, 0,
      &(SDL_GPUTextureSamplerBinding){.texture = tex, .sampler = G.sampler}, 1);
  SDL_DrawGPUPrimitives(pp, 6, 1, 0, 0);
}

/* composite the game target (into its viewport rect) + the ui canvas (over the
 * whole window) + the ig layer (imgui, native res, topmost — D049) into a
 * destination texture of sw x sh px. Sets lay_* (the window -> game-viewport
 * -> FOV mouse map). Shared by the live swapchain present and the headless
 * capture, so a screenshot matches the window. */
static void composite(SDL_GPUCommandBuffer *cmd, SDL_GPUTexture *dst, int sw,
                      int sh, SDL_GPUTextureFormat fmt) {
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
  SDL_BindGPUGraphicsPipeline(pp, G.pipe_blit);
  if (!hide_game)
    blit_layer(cmd, pp, G.target, G.lay_ox, G.lay_oy, (float)G.iw * gs,
               (float)G.ih * gs, (float)sw, (float)sh);
  if (G.ui_target && G.ui_scale > 0)
    blit_layer(cmd, pp, G.ui_target, 0, 0, (float)G.ui_w * G.ui_scale,
               (float)G.ui_h * G.ui_scale, (float)sw, (float)sh);
  /* the ig layer (imgui draw data) renders last = above everything, at
   * native destination resolution. No-op when no ig frame was prepared. */
  pal_ig_render_draw(cmd, pp, fmt);
  SDL_EndGPURenderPass(pp);
}

bool pal_gfx_present(void) {
  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(G.dev);
  if (!cmd) { pal_log("gfx: acquire cmd: %s", SDL_GetError()); return false; }

  uint32_t bytes = G.vcount * PAL_VERT_BYTES;
  G.stat_quads = G.vcount / 6;
  G.stat_segs = G.seg_count;
  G.stat_vbytes = bytes;
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
   * the game viewport shows through wherever no chrome was drawn. */
  scene_pass(cmd, G.target, G.iw, G.ih, 0, G.clear);
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
  if (G.cap_on && G.cap_target) {
    G.win_w = G.cap_w;
    G.win_h = G.cap_h;
    composite(cmd, G.cap_target, G.cap_w, G.cap_h,
              SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM);
  } else if (!G.headless && G.win) {
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
                SDL_GetGPUSwapchainTextureFormat(G.dev, G.win));
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
  if (!(G.cap_target && w == G.cap_w && h == G.cap_h)) {
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
      pal_log("gfx: capture %dx%d: %s", w, h, SDL_GetError());
      return false;
    }
    if (G.cap_target) SDL_ReleaseGPUTexture(G.dev, G.cap_target);
    G.cap_target = nt;
    G.cap_w = w;
    G.cap_h = h;
  }
  G.cap_on = true;
  G.win_w = w; /* so pal.x_window_size reports the captured window size */
  G.win_h = h;
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
  return SDL_MapGPUTransferBuffer(G.dev, G.cap_readback, false);
}

void pal_gfx_cap_read_end(void) {
  SDL_UnmapGPUTransferBuffer(G.dev, G.cap_readback);
}

int pal_gfx_tex_create(const void *pixels, int w, int h) {
  return tex_slot_create(pixels, w, h);
}

/* re-upload into an existing texture in place (no GPU realloc). false if the id
 * is free or the size changed — the caller should free + create instead. */
bool pal_gfx_tex_update(int id, const void *pixels, int w, int h) {
  if (id <= 0 || id >= PAL_MAX_TEX || !G.texs[id].used) return false;
  if (G.texs[id].w != w || G.texs[id].h != h) return false;
  return tex_upload(G.texs[id].tex, pixels, w, h);
}

bool pal_gfx_tex_free(int id) {
  if (id <= 0 || id >= PAL_MAX_TEX || !G.texs[id].used) return false;
  SDL_ReleaseGPUTexture(G.dev, G.texs[id].tex);
  G.texs[id].used = false;
  return true;
}
