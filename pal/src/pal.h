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
#define PAL_VERSION_API 5

#define PAL_MAX_TEX 256
#define PAL_MAX_EVENTS 256
#define PAL_MAX_WATCH 64
#define PAL_VERT_BYTES 20 /* x f32, y f32, u f32, v f32, rgba u8x4 */
#define PAL_EV_TEXT_MAX 40 /* utf-8 bytes per text event (longer commits split) */
#define PAL_LOG_RING 256
#define PAL_LOG_LINE_MAX 480 /* bytes kept per line (longer lines truncate) */

typedef enum {
  PAL_EV_QUIT,
  PAL_EV_KEY,
  PAL_EV_MOTION,
  PAL_EV_BUTTON,
  PAL_EV_WHEEL,
  PAL_EV_TEXT,
} PalEventType;

typedef struct {
  PalEventType type;
  int a;       /* key: scancode | button: index */
  bool down;   /* key/button */
  bool repeat; /* key */
  float x, y;  /* motion/button: internal coords | wheel: scroll */
  char text[PAL_EV_TEXT_MAX]; /* text: utf-8, NUL-terminated */
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
} PalTexture;

typedef struct {
  int tex;
  bool has_clip;
  SDL_Rect clip;
  uint32_t first, count; /* vertex range */
} PalSeg;

typedef struct {
  char *path;
  int64_t mtime;     /* consumer baseline (parachute / engine last-seen) */
  int64_t cur_mtime; /* current mtime, refreshed by the watcher thread */
} PalWatch;

typedef struct {
  /* core */
  bool quit;
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
  SDL_Window *win;
  SDL_GPUDevice *dev;
  SDL_GPUTexture *target; /* internal render target (iw x ih RGBA8) */
  SDL_GPUSampler *sampler;
  SDL_GPUGraphicsPipeline *pipe_scene, *pipe_blit;
  SDL_GPUBuffer *vbuf;
  SDL_GPUTransferBuffer *tbuf;
  uint32_t gpubuf_cap; /* bytes in vbuf/tbuf */
  SDL_GPUTransferBuffer *readback;
  uint32_t readback_cap; /* bytes in readback; grows if the FOV/target grows */

  /* current letterbox layout (for mouse mapping), updated each present */
  float lay_ox, lay_oy, lay_s;
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

  /* last-present counters (pal.frame_stats) */
  uint32_t stat_quads, stat_segs, stat_vbytes;

  /* log ring (pal.log_lines) */
  PalLogLine log_ring[PAL_LOG_RING];
  uint64_t log_seq;

  PalTexture texs[PAL_MAX_TEX];

  /* events (C queue -> drained by pal.poll_events) */
  PalEvent events[PAL_MAX_EVENTS];
  int event_count;

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
/* cached mtime of a watched path, refreshed off-thread; lazily spawns the
 * watcher thread on first call (live sessions only). Falls back to a direct
 * stat for unwatched paths. Dev-only — never sim state. */
int64_t pal_watch_mtime(const char *path);

/* gfx.c */
typedef struct {
  int w, h, scale;
  const char *title;
  bool headless, vsync;
} PalGfxConfig;
bool pal_gfx_init(const PalGfxConfig *cfg);
/* resize the game internal target (the "FOV" — visible world in internal px).
 * Reallocates the readback buffer if the new size exceeds it. No-op (true) if
 * unchanged. Flows into gfx_size / scene projection / read_pixels. Render-only;
 * the policy cap (D036's 480x270) lives in Lua, not here (mechanism not policy). */
bool pal_gfx_target_resize(int w, int h);
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
bool pal_gfx_tex_free(int id);

/* buf.c */
PalBuf *pal_buf_get(const char *name, size_t size, const char **err);
PalBuf *pal_buf_anon(size_t size);
bool pal_buf_free_named(const char *name);
void pal_buf_destroy(PalBuf *b); /* anonymous only, from Lua __gc */
uint64_t pal_buf_hash(const uint8_t *p, size_t len);

/* luabind.c */
void pal_lua_register(lua_State *L);

#endif
