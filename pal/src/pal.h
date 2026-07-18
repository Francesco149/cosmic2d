/* pal.h — platform abstraction layer context. One process = one console. */
#ifndef PAL_H
#define PAL_H

#include <SDL3/SDL.h>
#include <stdbool.h>
#include <stdint.h>

#include "lua.h"

/* stability contract (docs/ARCHITECTURE.md): MAJOR bumps are constitutional
 * events (target: never after 1.0); API bumps on additive changes only */
#define PAL_VERSION_MAJOR 0
#define PAL_VERSION_API 22 /* v22: x_figverts — the baked-figure
                              transform+light loop in C (byte-identical
                              to the cm.gb Lua reference); v21: relative
                              mouse — x_mouse_capture + motion rel
                              deltas; v20: the cosmic3d merge — 3D retro
                              pipeline (x_view3d/x_tris) + retro
                              presentation (x_grade quant=, x_soft VI
                              blit); the fork numbered these v15/v16,
                              which collide with mainline v15–v19 (pads,
                              folder chooser, exe identity, volume gains
                              + display size — v19) */

/* Stable SDL preference identity. SDL maps this pair to the platform-native
 * per-user writable application-data root; changing either string would
 * strand diagnostics and, later, player storage in a second directory. */
#define PAL_PREF_ORG "cosmic2d"
#define PAL_PREF_APP "engine"

#define PAL_MAX_TEX 256
#define PAL_MAX_EVENTS 256
#define PAL_MAX_WATCH 256 /* every cm.require'd file watches for hot-reload;
   the append-only list is shared across VM reboots (D052 project switch), so
   picker (~4) + a project's editor (~69: 60 engine + project + specials) must
   both fit, plus headroom for hopping projects in one session. The watcher
   thread only stats up to watch_count, so a bigger cap is free at runtime. */
#define PAL_VERT_BYTES 20 /* x f32, y f32, u f32, v f32, rgba u8x4 */
#define PAL_VERT3D_BYTES 24 /* x,y,z f32, u,v f32, rgba u8x4 (pre-lit) */
#define PAL_MAX_VIEW3D 64 /* x_view3d calls per frame (sky pass + scene +
   editor viewports); segments reference views by index, so several
   camera/fog setups can coexist in one frame */
#define PAL_EV_TEXT_MAX 40 /* utf-8 bytes per text event (longer commits split) */
#define PAL_EV_DROP_MAX 512 /* bytes per OS-drop path (longer paths ignored) */
#define PAL_LOG_RING 256
#define PAL_LOG_LINE_MAX 480 /* bytes kept per line (longer lines truncate) */

typedef enum {
  PAL_EV_QUIT,
  PAL_EV_KEY,
  PAL_EV_MOTION,
  PAL_EV_BUTTON,
  PAL_EV_WHEEL,
  PAL_EV_TEXT,
  PAL_EV_DROP, /* an OS file drag-dropped onto the window (R4 asset add) */
  PAL_EV_PAD,  /* gamepad (dis)connected (A4): a = SDL joystick instance id,
                  down = connected. The PAL opens/closes the SDL_Gamepad on
                  hot-plug; device->slot policy lives in Lua (cm.input). */
  PAL_EV_PAD_BTN,  /* a = instance id, b = SDL_GamepadButton, down */
  PAL_EV_PAD_AXIS, /* a = instance id, b = SDL_GamepadAxis, v = raw i16 */
} PalEventType;

typedef struct {
  PalEventType type;
  int a;       /* key: scancode | button: index | pad: SDL instance id */
  int b;       /* pad: SDL standard gamepad button/axis number */
  int v;       /* pad axis: raw SDL value (-32768..32767) */
  bool down;   /* key/button/pad */
  bool repeat; /* key */
  float x, y;       /* motion/button: game-space (FOV) px | wheel: scroll */
  float rx, ry;     /* motion: relative delta in game-space px (v21) — real
                       even while the cursor is captured (x_mouse_capture)
                       and the absolute position is frozen */
  float ui_x, ui_y; /* motion/button: ui-canvas px (editor chrome hit-test) */
  float wx, wy;     /* motion/button: raw window px (ig canvas hit-test, v7) */
  char text[PAL_EV_TEXT_MAX]; /* text: utf-8, NUL-terminated */
  char drop[PAL_EV_DROP_MAX]; /* drop: the dropped file's OS path (a fixed
                                 buffer on purpose — no alloc, no leak paths) */
} PalEvent;

/* log ring: every pal_log line lands here (C-owned, survives VM reboots) so
 * the engine console can show boot/parachute errors too */
typedef struct {
  uint64_t seq; /* 1-based, monotonically increasing, 0 = empty slot */
  double t;     /* seconds since process start */
  char text[PAL_LOG_LINE_MAX];
} PalLogLine;

/* named buffers: C-owned so they survive Lua VM reboots (the state model
 * depends on this — see docs/ARCHITECTURE.md "State model") */
typedef struct PalBuf {
  char *name; /* NULL = anonymous (Lua-GC-owned scratch) */
  uint8_t *data;
  size_t size;
  bool alive;
  struct PalBuf *next;
} PalBuf;

typedef struct {
  SDL_GPUTexture *tex;
  int w, h;
  bool used;
  int pend; /* deferred free: 0 = live; 1 = freed this frame; 2 = release next
             * present. The slot stays 'used' with a valid tex until reaped, so
             * draw segments (which reference textures by ID, resolved at flush)
             * always bind a live texture — a mid-frame free can't dangle them.
             * tex_create skips pended slots; tex_update refuses them. */
} PalTexture;

typedef struct {
  int tex;
  int target; /* which render target: 0 = game (FOV), 1 = ui canvas (D036) */
  bool has_clip;
  SDL_Rect clip;
  uint32_t first, count; /* vertex range */
} PalSeg;

/* one 3D camera/fog setup (pal.x_view3d); the retro pipeline's per-view
 * uniforms, snapshotted at call time so segments drawn under different
 * views coexist in one frame (sky pass = identity mvp + fog off) */
typedef struct {
  float mvp[16];   /* column-major, Lua-side policy (proj*view*model) */
  float fog[4];    /* start, end, on, 0 — matches retro.vert VUBO */
  float fogcol[4]; /* r, g, b, 1 — matches retro.frag FUBO */
} PalView3D;

/* x_tris flags (frozen-shape candidate; mirrors proto/gpu_proto.c) */
#define PAL_TRI_ALPHATEST 1u /* cutout: discard texel alpha < 0.5 */
#define PAL_TRI_NEAREST 2u   /* nearest sampling (default: three-point) */
#define PAL_TRI_BLEND 4u     /* alpha blend + depth write OFF (decals) */

typedef struct {
  int tex;
  uint32_t flags; /* PAL_TRI_* */
  int view;       /* index into views3d */
  uint32_t first, count; /* vertex range in the 3D batch */
} PalSeg3D;

typedef struct {
  char *path;
  int64_t mtime;     /* consumer baseline (parachute / engine last-seen) */
  int64_t cur_mtime; /* current mtime, refreshed by the watcher thread */
} PalWatch;

typedef struct {
  /* core */
  bool quit;
  bool reboot; /* pal.x_reboot: close + re-boot the Lua VM after this tick
                  (the parachute cycle without an error — project switch,
                  D052). Named buffers + gfx survive by design. */
  bool error_state;
  bool exit_on_error; /* capped/verify runs: lua error = exit(1), no parachute */
  int exit_code;
  int argc;
  char **argv;
  lua_State *L;

  /* gfx */
  bool gfx_up;
  bool headless;
  int iw, ih, scale; /* internal target size, initial window scale */
  bool mouse_captured; /* relative mouse mode (pal.x_mouse_capture, v21);
                          live-side chrome policy — never read by sim code
                          (the recorded MREL deltas are the authority) */
  SDL_Window *win;
  SDL_GPUDevice *dev;
  SDL_GPUTexture *target; /* game render target (iw x ih RGBA8) — the FOV */
  /* editor/dev UI canvas (D036): a second target at its own scale, composited
   * over the game viewport at present. NULL = no ui layer (shipped game). */
  SDL_GPUTexture *ui_target;
  int ui_w, ui_h;    /* ui canvas size in px (pal.x_ui_target) */
  float ui_scale;    /* integer px scale the ui canvas blits to the window at */
  int cur_target;    /* 0 = game, 1 = ui — where subsequent quads accumulate */
  SDL_GPUSampler *sampler, *sampler_lin; /* nearest (default) / linear (VI) */
  SDL_GPUGraphicsPipeline *pipe_scene, *pipe_blit, *pipe_blit_soft, *pipe_grade;
  SDL_GPUBuffer *vbuf;
  SDL_GPUTransferBuffer *tbuf;
  uint32_t gpubuf_cap; /* bytes in vbuf/tbuf */
  SDL_GPUTransferBuffer *readback;
  uint32_t readback_cap; /* bytes in readback; grows if the FOV/target grows */
  /* headless capture of the full composite (pal.x_capture): the present
   * composite renders into cap_target instead of a swapchain, so a screenshot
   * can show the editor-around-game layout that only exists in the window. */
  SDL_GPUTexture *cap_target;
  int cap_w, cap_h;
  bool cap_on;
  SDL_GPUTextureFormat cap_fmt; /* live mirror = the swapchain's format (so
                                   the ig pipeline matches); headless = RGBA8.
                                   Readback always hands out RGBA8 (swizzled
                                   in place when the target is BGRA). */
  SDL_GPUTransferBuffer *cap_readback;
  uint32_t cap_readback_cap;

  /* current letterbox layout (for mouse mapping), updated each present */
  float lay_ox, lay_oy, lay_s;
  /* explicit game-viewport composite (pal.x_compose); when unset, present
   * auto-letterboxes the game target centered (shipped game / default). */
  bool compose_set;
  int vp_x, vp_y, vp_scale; /* game viewport origin (window px) + integer scale */
  /* per-frame render-only color grade on the game-target blit (pal.x_grade);
   * reset each begin_frame so it is opt-in per frame and can't leak across a
   * reboot. grade[8] = brightness, contrast, saturation, quant bits (0 = off:
   * Bayer-4 dithered n-bit-per-channel quantize, the 5551 grade), tint rgb,
   * pad. */
  bool grade_set;
  float grade[8];
  /* per-frame VI-soft presentation (pal.x_soft): the game-target blit samples
   * bilinearly + smears one dest px horizontally (the N64 VI resample look;
   * proto --soft is the reference). Reset each begin_frame like the grade.
   * Presentation only — the internal target (readback/goldens) never sees it. */
  bool soft_set;
  SDL_GPUTexture *grade_tmp; /* ping-pong scratch for the grade post-pass */
  int grade_tmp_w, grade_tmp_h;
  /* cached swapchain px size (pal.x_window_size), updated each present; the
   * window-resize ladder lives in Lua and reads this. Render-only — the sim
   * never reads window/FOV/viewport (D036 iron rule). */
  int win_w, win_h;

  /* batch accumulation (CPU side, flushed at present) */
  float clear[4];
  uint8_t *verts;
  uint32_t vcount, vcap; /* in vertices */
  PalSeg *segs;
  uint32_t seg_count, seg_cap;
  float cam_x, cam_y;
  bool clip_on;
  SDL_Rect clip;

  /* 3D retro pipeline (x_view3d/x_tris — docs/COSMIC3D.md §2). All lazily
   * created on first 3D use; a pure-2D session never allocates any of it
   * and its frame path is byte-identical to cosmic2d's. */
  SDL_GPUGraphicsPipeline *pipe3d_opaque, *pipe3d_blend;
  SDL_GPUTexture *depth3d; /* D16, sized to the internal target */
  int depth3d_w, depth3d_h;
  uint8_t *verts3d;
  uint32_t v3count, v3cap; /* in vertices */
  PalSeg3D *segs3d;
  uint32_t seg3d_count, seg3d_cap;
  PalView3D views3d[PAL_MAX_VIEW3D];
  uint32_t view3d_count;
  SDL_GPUBuffer *vbuf3d;
  SDL_GPUTransferBuffer *tbuf3d;
  uint32_t gpubuf3d_cap; /* bytes in vbuf3d/tbuf3d */

  /* last-present counters (pal.frame_stats) */
  uint32_t stat_quads, stat_segs, stat_vbytes;
  uint32_t stat_tris, stat_segs3d; /* 3D batch (0 in pure-2D sessions) */

  /* log ring (pal.log_lines) */
  PalLogLine log_ring[PAL_LOG_RING];
  uint64_t log_seq;
  char *diagnostics_dir; /* absolute UTF-8 path; interactive processes only */
  char *log_path;        /* current flushed process log, or NULL in CI */
  SDL_IOStream *log_io;

  PalTexture texs[PAL_MAX_TEX];

  /* events (C queue -> drained by pal.poll_events) */
  PalEvent events[PAL_MAX_EVENTS];
  int event_count;

  /* One native folder chooser at a time. SDL may complete its asynchronous
   * dialog callback on another thread, so Lua starts/polls it through this
   * small process-owned mailbox. It intentionally survives VM reboots like
   * the window, though normal picker use consumes the result before one. */
  SDL_Mutex *folder_mutex;
  int folder_state; /* 0 idle, 1 pending, 2 selected, 3 cancelled, 4 error */
  char *folder_result;

  PalBuf *bufs;

  /* watch list: crash-parachute (inline stat, error state) + the background
   * file-watcher thread that refreshes cur_mtime so the engine's hot-reload
   * poll never stats on the main thread (pal.watch_mtime, dev-only). Append-
   * only: entries are never removed, so indices are stable across threads. */
  PalWatch watch[PAL_MAX_WATCH];
  int watch_count;
  SDL_Mutex *watch_mutex; /* guards watch_count growth + cur_mtime */
  bool watch_started;     /* watcher thread spawned (lazily, live only) */
} Pal;

extern Pal G;

/* main.c */
void pal_log(const char *fmt, ...);
/* drain SDL's queue into G.events now (the loop does this once per tick;
 * pal.x_events_pump lets the selftest observe virtual-pad hot-plug and
 * input synchronously — dev/test only). */
void pal_pump_events(void);
/* Finish the dev/io worker before process teardown. Normal engine quit/crash
 * drains from Lua so it can consume completion status; this is the native
 * last-resort barrier for an early or parachute exit. */
void pal_async_write_shutdown(void);
/* cached mtime of a watched path, refreshed off-thread; lazily spawns the
 * watcher thread on first call (live sessions only). Falls back to a direct
 * stat for unwatched paths. Dev-only — never sim state. */
int64_t pal_watch_mtime(const char *path);

/* hash.c -- release archive/checksum helpers (dev/io, API v14). */
void pal_sha256(const void *data, size_t len, uint8_t out[32]);
bool pal_sha256_file(const char *path, uint8_t out[32], char *err,
                     size_t errcap);
uint32_t pal_crc32(uint32_t prior, const void *data, size_t len);
bool pal_windows_exe_identity(const char *path, const void *png, size_t png_len,
                              int width, int height, const char *title,
                              const char *version, const char *author,
                              const char *slug, char *err, size_t errcap);

/* gfx.c */
typedef struct {
  int w, h, scale;
  const char *title;
  bool headless, vsync;
  bool maximized; /* create the window maximized (editor sessions, v7) */
} PalGfxConfig;
bool pal_gfx_init(const PalGfxConfig *cfg);
/* resize the game internal target (the "FOV" — visible world in internal px).
 * Reallocates the readback buffer if the new size exceeds it. No-op (true) if
 * unchanged. Flows into gfx_size / scene projection / read_pixels. Render-only;
 * the policy cap (D036's 480x270) lives in Lua, not here (mechanism not policy). */
bool pal_gfx_target_resize(int w, int h);
/* create/resize the editor/dev UI canvas (D036). w==0 || h==0 frees it (no ui
 * layer). No-op (true) if unchanged. Render-only. */
bool pal_gfx_ui_target_resize(int w, int h);
/* enable/resize a headless capture target (w==0 frees + disables). When on,
 * present() composites into it instead of a swapchain. Render/dev. */
bool pal_gfx_capture(int w, int h);
/* readback the capture target (RGBA8, top-left); read_end before any gfx call */
const void *pal_gfx_cap_read_begin(size_t *len);
void pal_gfx_cap_read_end(void);
void pal_gfx_begin(float r, float g, float b, float a);
void pal_gfx_quad(float x, float y, float w, float h, float u0, float v0,
                  float u1, float v1, uint32_t rgba, int tex);
void pal_gfx_clip(bool on, int x, int y, int w, int h);
bool pal_gfx_present(void);
/* read_begin maps last-rendered internal target pixels (RGBA8, top-left
 * origin, tightly packed); caller must read_end before any other gfx call */
const void *pal_gfx_read_begin(size_t *len);
void pal_gfx_read_end(void);
int pal_gfx_tex_create(const void *pixels, int w, int h);
bool pal_gfx_tex_update(int id, const void *pixels, int w, int h);
bool pal_gfx_tex_free(int id);
/* 3D retro pipeline (x_ experimental, docs/COSMIC3D.md §2). view3d appends a
 * camera/fog setup for subsequent tris (false = per-frame view cap hit);
 * tris appends `count` triangles of 3 packed verts (PAL_VERT3D_BYTES each,
 * pre-lit color) drawn under the latest view with PAL_TRI_* flags. 3D draws
 * into the game target under all 2D quads (HUD/UI on top), depth-tested;
 * pipelines + depth target are created lazily on the first call. */
bool pal_gfx_view3d(const float mvp[16], float fog_start, float fog_end,
                    float fog_r, float fog_g, float fog_b, bool fog_on);
bool pal_gfx_tris(int tex, const void *verts, uint32_t count, uint32_t flags);

/* buf.c */
PalBuf *pal_buf_get(const char *name, size_t size, const char **err);
PalBuf *pal_buf_anon(size_t size);
bool pal_buf_free_named(const char *name);
void pal_buf_destroy(PalBuf *b); /* anonymous only, from Lua __gc */
uint64_t pal_buf_hash(const uint8_t *p, size_t len);

/* luabind.c */
void pal_lua_register(lua_State *L);

/* snd.c — the audio core (R9b, docs/AUDIO.md §2). Sim bank state lives
 * in the named buffer "snd.bank" (snapshot/trace/rewind for free); the
 * editor bank + device are render/dev class. Registers pal.snd_* and
 * pal.x_snd_* into the pal table at the stack top. */
void pal_snd_lua_register(lua_State *L);

/* snd_dec.c — audio file decoders (wav/mp3/ogg -> i16 @ 48 kHz;
 * editor/dev class). Registers pal.x_snd_decode. */
void pal_snd_dec_lua_register(lua_State *L);

/* ig.cpp — the Dear ImGui host (D049, docs/IMGUI.md). The PAL's one C++ TU;
 * this C ABI is the whole boundary — imgui types never cross it. Render/dev
 * class throughout: live windowed sessions + the --win capture path only. */
bool pal_ig_forward_events(void); /* inited with a real window */
void pal_ig_sdl_event(const SDL_Event *e); /* feed one SDL event to imgui */
/* close the open ig frame + upload draw data (call once per present, before
 * the composite render pass begins; no-op when no frame is open) */
void pal_ig_render_prepare(SDL_GPUCommandBuffer *cmd);
/* draw the prepared data into the composite pass (last = topmost layer).
 * Skips with a log line if `fmt` differs from the pipeline's init format.
 * keep=true leaves the prepared data consumable again — the live capture
 * mirror composites twice per present (cap target, then swapchain). */
void pal_ig_render_draw(SDL_GPUCommandBuffer *cmd, SDL_GPURenderPass *pass,
                        SDL_GPUTextureFormat fmt, bool keep);
/* register the pal.x_ig_* functions into the pal table at the stack top */
void pal_ig_lua_register(lua_State *L);
/* batch N textured quads (8 floats each: x,y,w,h,u0,v0,u1,v1) in one drawlist
 * command — the tilemap/map editors' fast path (luabind marshals a pal.buf) */
void pal_ig_image_quads(int tex, const float *quads, int count, uint32_t rgba);

#endif
