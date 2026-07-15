/* luabind.c — the pal.* Lua module: the porting contract between the PAL
 * and the engine. Semantics + determinism classes: docs/ARCHITECTURE.md. */
#include "pal.h"

#include <errno.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

#include "lauxlib.h"
#include "lualib.h"
#include "stb/stb_image.h"
#include "stb/stb_image_write.h"

#define BUFVIEW_MT "pal.buf"

typedef struct {
  PalBuf *b;
  bool anon;
} BufView;

/* ---------- buffer views ---------- */

static BufView *checkview_at(lua_State *L, int idx) {
  BufView *v = luaL_checkudata(L, idx, BUFVIEW_MT);
  if (!v->b->alive) luaL_error(L, "buffer was freed");
  return v;
}

static BufView *checkview(lua_State *L) { return checkview_at(L, 1); }

static uint8_t *view_span(lua_State *L, BufView *v, lua_Integer off,
                          lua_Integer len) {
  if (off < 0 || len < 0 || (size_t)(off + len) > v->b->size)
    luaL_error(L, "buffer access out of bounds (off=%I len=%I size=%I)",
               off, len, (lua_Integer)v->b->size);
  return v->b->data + off;
}

#define NUM_ACCESSOR(NAME, CTYPE, PUSH, CHECK)                        \
  static int l_buf_##NAME(lua_State *L) {                             \
    BufView *v = checkview(L);                                        \
    lua_Integer off = luaL_checkinteger(L, 2);                        \
    uint8_t *p = view_span(L, v, off, (lua_Integer)sizeof(CTYPE));    \
    if (lua_gettop(L) >= 3) {                                         \
      CTYPE val = (CTYPE)CHECK(L, 3);                                 \
      memcpy(p, &val, sizeof val);                                    \
      return 0;                                                       \
    }                                                                 \
    CTYPE val;                                                        \
    memcpy(&val, p, sizeof val);                                      \
    PUSH(L, val);                                                     \
    return 1;                                                         \
  }

#define PUSH_INT(L, v) lua_pushinteger(L, (lua_Integer)(v))
#define PUSH_NUM(L, v) lua_pushnumber(L, (lua_Number)(v))

NUM_ACCESSOR(u8, uint8_t, PUSH_INT, luaL_checkinteger)
NUM_ACCESSOR(i8, int8_t, PUSH_INT, luaL_checkinteger)
NUM_ACCESSOR(u16, uint16_t, PUSH_INT, luaL_checkinteger)
NUM_ACCESSOR(i16, int16_t, PUSH_INT, luaL_checkinteger)
NUM_ACCESSOR(u32, uint32_t, PUSH_INT, luaL_checkinteger)
NUM_ACCESSOR(i32, int32_t, PUSH_INT, luaL_checkinteger)
NUM_ACCESSOR(i64, int64_t, PUSH_INT, luaL_checkinteger)
NUM_ACCESSOR(f32, float, PUSH_NUM, luaL_checknumber)
NUM_ACCESSOR(f64, double, PUSH_NUM, luaL_checknumber)

static int l_buf_size(lua_State *L) {
  lua_pushinteger(L, (lua_Integer)checkview(L)->b->size);
  return 1;
}

static int l_buf_name(lua_State *L) {
  BufView *v = checkview(L);
  if (v->b->name)
    lua_pushstring(L, v->b->name);
  else
    lua_pushnil(L);
  return 1;
}

static int l_buf_fill(lua_State *L) {
  BufView *v = checkview(L);
  lua_Integer off = luaL_checkinteger(L, 2);
  lua_Integer len = luaL_checkinteger(L, 3);
  lua_Integer byte = luaL_optinteger(L, 4, 0);
  memset(view_span(L, v, off, len), (int)byte, (size_t)len);
  return 0;
}

/* buf:fill32(byte_off, count, value) — write `count` native-endian u32s. The
 * 32-bit sibling of :fill (a byte memset): clears / solid-fills an RGBA8 image
 * in one C call (cm.paint.fill) instead of a per-pixel Lua loop. byte_off must
 * be 4-aligned (image offsets always are: pixel n is at n*4). */
static int l_buf_fill32(lua_State *L) {
  BufView *v = checkview(L);
  lua_Integer off = luaL_checkinteger(L, 2);
  lua_Integer count = luaL_checkinteger(L, 3);
  uint32_t val = (uint32_t)luaL_checkinteger(L, 4);
  uint8_t *p = view_span(L, v, off, count * 4);
  if ((off & 3) != 0) return luaL_error(L, "fill32: offset must be 4-aligned");
  uint32_t *w = (uint32_t *)p;
  for (lua_Integer i = 0; i < count; i++) w[i] = val;
  return 0;
}

static int l_buf_str(lua_State *L) {
  BufView *v = checkview(L);
  lua_Integer off = luaL_checkinteger(L, 2);
  lua_Integer len = luaL_checkinteger(L, 3);
  lua_pushlstring(L, (const char *)view_span(L, v, off, len), (size_t)len);
  return 1;
}

static int l_buf_setstr(lua_State *L) {
  BufView *v = checkview(L);
  lua_Integer off = luaL_checkinteger(L, 2);
  size_t slen;
  const char *s = luaL_checklstring(L, 3, &slen);
  memcpy(view_span(L, v, off, (lua_Integer)slen), s, slen);
  return 0;
}

static int l_buf_copy(lua_State *L) {
  BufView *dst = checkview(L);
  lua_Integer doff = luaL_checkinteger(L, 2);
  BufView *src = luaL_checkudata(L, 3, BUFVIEW_MT);
  if (!src->b->alive) return luaL_error(L, "source buffer was freed");
  lua_Integer soff = luaL_checkinteger(L, 4);
  lua_Integer len = luaL_checkinteger(L, 5);
  uint8_t *d = view_span(L, dst, doff, len);
  if (soff < 0 || (size_t)(soff + len) > src->b->size)
    return luaL_error(L, "source range out of bounds");
  memmove(d, src->b->data + soff, (size_t)len);
  return 0;
}

/* RGBA8 straight-alpha source-over, integer math IDENTICAL to cm.paint.over —
 * so a C-accelerated composite / bake is byte-for-byte the Lua result (the
 * baked .png the game loads, and the selftest KATs, must not shift). */
static inline uint32_t blend_over(uint32_t s, uint32_t d) {
  uint32_t sa = s >> 24;
  if (sa == 0) return d;
  if (sa == 255) return s;
  uint32_t da = d >> 24;
  uint32_t ia = 255 - sa;
  uint32_t dterm = (da * ia + 127) / 255;
  uint32_t oa = sa + dterm;
  if (oa == 0) return 0;
  uint32_t sr = s & 255, sg = (s >> 8) & 255, sb = (s >> 16) & 255;
  uint32_t dr = d & 255, dg = (d >> 8) & 255, db = (d >> 16) & 255;
  uint32_t r = (sr * sa + dr * dterm + oa / 2) / oa;
  uint32_t g = (sg * sa + dg * dterm + oa / 2) / oa;
  uint32_t b = (sb * sa + db * dterm + oa / 2) / oa;
  return r | (g << 8) | (b << 16) | (oa << 24);
}

/* pal.blit32(dst,dw,dh, dx,dy, src,sw,sh, sx,sy, w,h, mode [,op]) — the engine's
 * one reusable 2D RGBA8 compositor: a clipped rectangular blit between two
 * pal.bufs. It is what makes layer-flatten, bake, brush stamp, float paste and
 * document resize one C call instead of a per-pixel Lua loop. mode: 0 copy
 * (replace), 1 src-over (alpha blend, matches cm.paint.over), 2 stamp (copy
 * where src alpha != 0). op (0..255, default 255) scales source alpha first
 * (per-layer opacity). The w*h window is clipped to BOTH buffers; pixels that
 * fall outside either are skipped. */
static int l_blit32(lua_State *L) {
  BufView *dv = checkview_at(L, 1);
  long dw = (long)luaL_checkinteger(L, 2), dh = (long)luaL_checkinteger(L, 3);
  long dx = (long)luaL_checkinteger(L, 4), dy = (long)luaL_checkinteger(L, 5);
  BufView *sv = luaL_checkudata(L, 6, BUFVIEW_MT);
  if (!sv->b->alive) return luaL_error(L, "blit32: source buffer was freed");
  long sw = (long)luaL_checkinteger(L, 7), sh = (long)luaL_checkinteger(L, 8);
  long sx = (long)luaL_checkinteger(L, 9), sy = (long)luaL_checkinteger(L, 10);
  long w = (long)luaL_checkinteger(L, 11), h = (long)luaL_checkinteger(L, 12);
  int mode = (int)luaL_checkinteger(L, 13);
  long op = (long)luaL_optinteger(L, 14, 255);
  if (dw < 0 || dh < 0 || sw < 0 || sh < 0)
    return luaL_error(L, "blit32: negative dimension");
  if ((size_t)(dw * dh * 4) > dv->b->size)
    return luaL_error(L, "blit32: dst smaller than dw*dh*4");
  if ((size_t)(sw * sh * 4) > sv->b->size)
    return luaL_error(L, "blit32: src smaller than sw*sh*4");
  /* clip the w*h window to src@(sx,sy) and dst@(dx,dy) simultaneously */
  if (sx < 0) { dx -= sx; w += sx; sx = 0; }
  if (sy < 0) { dy -= sy; h += sy; sy = 0; }
  if (dx < 0) { sx -= dx; w += dx; dx = 0; }
  if (dy < 0) { sy -= dy; h += dy; dy = 0; }
  if (sx + w > sw) w = sw - sx;
  if (sy + h > sh) h = sh - sy;
  if (dx + w > dw) w = dw - dx;
  if (dy + h > dh) h = dh - dy;
  if (w <= 0 || h <= 0) return 0;
  uint32_t *dp = (uint32_t *)dv->b->data;
  const uint32_t *sp = (const uint32_t *)sv->b->data;
  bool scale_a = op < 255;
  for (long j = 0; j < h; j++) {
    uint32_t *drow = dp + (dy + j) * dw + dx;
    const uint32_t *srow = sp + (sy + j) * sw + sx;
    for (long i = 0; i < w; i++) {
      uint32_t s = srow[i];
      if (scale_a) {
        uint32_t a = (s >> 24) * (uint32_t)op / 255;
        s = (s & 0x00ffffffu) | (a << 24);
      }
      if (mode == 1) {
        drow[i] = blend_over(s, drow[i]);
      } else if (mode == 2) {
        if (s >> 24) drow[i] = s;
      } else {
        drow[i] = s;
      }
    }
  }
  return 0;
}

static int l_buf_hash(lua_State *L) {
  BufView *v = checkview(L);
  lua_Integer off = luaL_optinteger(L, 2, 0);
  lua_Integer len = luaL_optinteger(L, 3, (lua_Integer)v->b->size - off);
  uint8_t *p = view_span(L, v, off, len);
  lua_pushinteger(L, (lua_Integer)pal_buf_hash(p, (size_t)len));
  return 1;
}

static int l_buf_gc(lua_State *L) {
  BufView *v = luaL_checkudata(L, 1, BUFVIEW_MT);
  if (v->anon) pal_buf_destroy(v->b);
  return 0;
}

static const luaL_Reg bufview_methods[] = {
    {"u8", l_buf_u8},   {"i8", l_buf_i8},       {"u16", l_buf_u16},
    {"i16", l_buf_i16}, {"u32", l_buf_u32},     {"i32", l_buf_i32},
    {"i64", l_buf_i64}, {"f32", l_buf_f32},     {"f64", l_buf_f64},
    {"size", l_buf_size}, {"name", l_buf_name}, {"fill", l_buf_fill},
    {"fill32", l_buf_fill32}, {"str", l_buf_str}, {"setstr", l_buf_setstr},
    {"copy", l_buf_copy}, {"hash", l_buf_hash}, {NULL, NULL}};

static void push_view(lua_State *L, PalBuf *b, bool anon) {
  BufView *v = lua_newuserdatauv(L, sizeof *v, 0);
  v->b = b;
  v->anon = anon;
  luaL_setmetatable(L, BUFVIEW_MT);
}

static int l_buf(lua_State *L) {
  lua_Integer size = luaL_checkinteger(L, 2);
  if (size < 0 || size > (lua_Integer)1 << 31)
    return luaL_error(L, "bad buffer size");
  if (lua_isnoneornil(L, 1)) {
    push_view(L, pal_buf_anon((size_t)size), true);
  } else {
    const char *err;
    PalBuf *b = pal_buf_get(luaL_checkstring(L, 1), (size_t)size, &err);
    if (!b) return luaL_error(L, "pal.buf(%s): %s", lua_tostring(L, 1), err);
    push_view(L, b, false);
  }
  return 1;
}

static int l_buf_free(lua_State *L) {
  lua_pushboolean(L, pal_buf_free_named(luaL_checkstring(L, 1)));
  return 1;
}

static int l_buf_list(lua_State *L) {
  lua_newtable(L);
  int i = 1;
  for (PalBuf *b = G.bufs; b; b = b->next) {
    if (!b->alive || !b->name) continue;
    lua_createtable(L, 0, 2);
    lua_pushstring(L, b->name);
    lua_setfield(L, -2, "name");
    lua_pushinteger(L, (lua_Integer)b->size);
    lua_setfield(L, -2, "size");
    lua_rawseti(L, -2, i++);
  }
  return 1;
}

/* delta codec v1 — FROZEN (stability contract rule 4: versioned kernel).
 * delta = concatenated runs of { u32 off LE, u32 len LE, len XOR bytes };
 * a run extends to the last differing byte that is followed by fewer than
 * 8 equal bytes; runs are emitted in ascending offset order; identical
 * buffers yield the empty string. apply is XOR, hence self-inverse. */
#define DELTA1_GAP 8

static void put_u32le(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v & 0xff);
  p[1] = (uint8_t)((v >> 8) & 0xff);
  p[2] = (uint8_t)((v >> 16) & 0xff);
  p[3] = (uint8_t)((v >> 24) & 0xff);
}

static uint32_t get_u32le(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static int l_buf_delta1(lua_State *L) {
  BufView *prev = checkview_at(L, 1);
  BufView *cur = checkview_at(L, 2);
  if (prev->b->size != cur->b->size)
    return luaL_error(L, "buf_delta1: size mismatch (%I vs %I)",
                      (lua_Integer)prev->b->size, (lua_Integer)cur->b->size);
  const uint8_t *p = prev->b->data, *c = cur->b->data;
  size_t n = prev->b->size;
  luaL_Buffer B;
  luaL_buffinit(L, &B);
  size_t i = 0;
  while (i < n) {
    if (p[i] == c[i]) {
      i++;
      continue;
    }
    size_t start = i, last = i, eq = 0;
    for (size_t j = i + 1; j < n && eq < DELTA1_GAP; j++) {
      if (p[j] != c[j]) {
        last = j;
        eq = 0;
      } else {
        eq++;
      }
    }
    uint8_t hdr[8];
    put_u32le(hdr, (uint32_t)start);
    put_u32le(hdr + 4, (uint32_t)(last - start + 1));
    luaL_addlstring(&B, (const char *)hdr, 8);
    for (size_t k = start; k <= last; k++)
      luaL_addchar(&B, (char)(p[k] ^ c[k]));
    i = last + 1;
  }
  luaL_pushresult(&B);
  return 1;
}

static int l_buf_apply_delta1(lua_State *L) {
  BufView *v = checkview_at(L, 1);
  size_t len;
  const uint8_t *d = (const uint8_t *)luaL_checklstring(L, 2, &len);
  size_t pos = 0;
  while (pos < len) {
    if (pos + 8 > len)
      return luaL_error(L, "buf_apply_delta1: truncated run header");
    uint32_t off = get_u32le(d + pos), rl = get_u32le(d + pos + 4);
    pos += 8;
    if (rl == 0 || (size_t)off + rl > v->b->size || pos + rl > len)
      return luaL_error(L, "buf_apply_delta1: bad run (off=%I len=%I)",
                        (lua_Integer)off, (lua_Integer)rl);
    for (uint32_t k = 0; k < rl; k++) v->b->data[off + k] ^= d[pos + k];
    pos += rl;
  }
  return 0;
}

/* ---------- core ---------- */

static int l_hash(lua_State *L) {
  size_t len;
  const char *s = luaL_checklstring(L, 1, &len);
  lua_pushinteger(L, (lua_Integer)pal_buf_hash((const uint8_t *)s, len));
  return 1;
}

static int l_log(lua_State *L) {
  pal_log("%s", luaL_checkstring(L, 1));
  return 0;
}

/* pal.log_lines(after_seq) -> array of {seq=, t=, text=}: ring entries newer
 * than after_seq, oldest first. Under log floods the ring overwrites; callers
 * detect a gap when the first returned seq > after_seq + 1. */
static int l_log_lines(lua_State *L) {
  uint64_t after = (uint64_t)luaL_optinteger(L, 1, 0);
  uint64_t lo = G.log_seq > PAL_LOG_RING ? G.log_seq - PAL_LOG_RING : 0;
  if (after < lo) after = lo;
  lua_createtable(L, (int)(G.log_seq - after), 0);
  int out = 1;
  for (uint64_t s = after + 1; s <= G.log_seq; s++) {
    PalLogLine *line = &G.log_ring[(s - 1) % PAL_LOG_RING];
    if (line->seq != s) continue; /* already overwritten mid-iteration */
    lua_createtable(L, 0, 3);
    lua_pushinteger(L, (lua_Integer)line->seq);
    lua_setfield(L, -2, "seq");
    lua_pushnumber(L, line->t);
    lua_setfield(L, -2, "t");
    lua_pushstring(L, line->text);
    lua_setfield(L, -2, "text");
    lua_rawseti(L, -2, out++);
  }
  return 1;
}

static int l_time_ns(lua_State *L) {
  lua_pushinteger(L, (lua_Integer)SDL_GetTicksNS());
  return 1;
}

static int l_quit(lua_State *L) {
  G.exit_code = (int)luaL_optinteger(L, 1, 0);
  G.quit = true;
  return 0;
}

static int l_exit_on_error(lua_State *L) {
  G.exit_on_error = lua_toboolean(L, 1);
  return 0;
}

static int l_quitting(lua_State *L) {
  lua_pushboolean(L, G.quit);
  return 1;
}

static int l_sleep_ms(lua_State *L) {
  SDL_Delay((Uint32)luaL_checkinteger(L, 1));
  return 0;
}

/* ---------- gfx ---------- */

static void check_gfx(lua_State *L) {
  if (!G.gfx_up) luaL_error(L, "gfx not initialized (call pal.gfx_init first)");
}

static int l_gfx_init(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  PalGfxConfig cfg = {.w = 480, .h = 270, .scale = 2, .vsync = true};
  lua_getfield(L, 1, "w");
  cfg.w = (int)luaL_optinteger(L, -1, cfg.w);
  lua_getfield(L, 1, "h");
  cfg.h = (int)luaL_optinteger(L, -1, cfg.h);
  lua_getfield(L, 1, "scale");
  cfg.scale = (int)luaL_optinteger(L, -1, cfg.scale);
  lua_getfield(L, 1, "title");
  cfg.title = luaL_optstring(L, -1, "cosmic2d");
  lua_getfield(L, 1, "headless");
  cfg.headless = lua_toboolean(L, -1);
  lua_getfield(L, 1, "vsync");
  cfg.vsync = lua_isnil(L, -1) ? true : lua_toboolean(L, -1);
  lua_getfield(L, 1, "maximized");
  cfg.maximized = lua_toboolean(L, -1);
  if (cfg.w < 1 || cfg.h < 1 || cfg.w > 4096 || cfg.h > 4096 || cfg.scale < 1)
    return luaL_error(L, "gfx_init: bad size/scale");
  if (!pal_gfx_init(&cfg))
    return luaL_error(L, "gfx_init failed (see log): %s", SDL_GetError());
  return 0;
}

static int l_gfx_size(lua_State *L) {
  check_gfx(L);
  lua_pushinteger(L, G.iw);
  lua_pushinteger(L, G.ih);
  return 2;
}

/* pal.x_window_size() -> sw, sh : real swapchain px, cached each present.
 * The window-resize ladder (D036) lives in Lua and reads this. Render-only. */
static int l_x_window_size(lua_State *L) {
  check_gfx(L);
  lua_pushinteger(L, G.win_w);
  lua_pushinteger(L, G.win_h);
  return 2;
}

/* pal.x_fov(w, h) -> w, h : resize the game internal target (visible world in
 * internal px). The 480x270 policy cap is enforced in Lua, not here. Call
 * before begin_frame for the frame that should use the new size. Render-only. */
static int l_x_fov(lua_State *L) {
  check_gfx(L);
  int w = (int)luaL_checkinteger(L, 1);
  int h = (int)luaL_checkinteger(L, 2);
  if (!pal_gfx_target_resize(w, h))
    return luaL_error(L, "x_fov: resize failed (see log)");
  lua_pushinteger(L, G.iw);
  lua_pushinteger(L, G.ih);
  return 2;
}

/* pal.x_set_window_size(w, h) : resize the OS window (windowed mode; SDL
 * ignores it in fullscreen). Live only; headless no-op. Render/dev. */
static int l_x_set_window_size(lua_State *L) {
  check_gfx(L);
  int w = (int)luaL_checkinteger(L, 1);
  int h = (int)luaL_checkinteger(L, 2);
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  if (G.win && !SDL_SetWindowSize(G.win, w, h))
    pal_log("gfx: set_window_size %dx%d: %s", w, h, SDL_GetError());
  return 0;
}

/* pal.x_set_fullscreen(on) : borderless desktop fullscreen (on) or windowed
 * (off). The mode is NULL → SDL uses borderless-desktop, so the OS resolution
 * is untouched. Live only; headless no-op. Render/dev. */
static int l_x_set_fullscreen(lua_State *L) {
  check_gfx(L);
  bool on = lua_toboolean(L, 1);
  if (G.win && !SDL_SetWindowFullscreen(G.win, on))
    pal_log("gfx: set_fullscreen %d: %s", (int)on, SDL_GetError());
  return 0;
}

/* pal.x_ui_target(w, h) -> w, h : create/resize the editor/dev UI canvas (the
 * second target composited over the game viewport). w==0 || h==0 frees it (no
 * ui layer). Render/dev (D036). */
static int l_x_ui_target(lua_State *L) {
  check_gfx(L);
  int w = (int)luaL_optinteger(L, 1, 0);
  int h = (int)luaL_optinteger(L, 2, 0);
  if (!pal_gfx_ui_target_resize(w, h))
    return luaL_error(L, "x_ui_target: resize failed (see log)");
  lua_pushinteger(L, G.ui_w);
  lua_pushinteger(L, G.ui_h);
  return 2;
}

/* pal.x_capture(w, h) : enable a headless capture target sized w x h (0 frees +
 * disables). When on, present() composites into it; pal.x_capture_read() reads
 * it back. Lets a headless --shot capture the editor-around-game composite that
 * otherwise lives only in the window. Render/dev. */
static int l_x_capture(lua_State *L) {
  check_gfx(L);
  int w = (int)luaL_optinteger(L, 1, 0);
  int h = (int)luaL_optinteger(L, 2, 0);
  if (!pal_gfx_capture(w, h))
    return luaL_error(L, "x_capture: failed (see log)");
  return 0;
}

/* pal.x_capture_read() -> pixels, w, h : the capture target as RGBA8 (top-left,
 * tightly packed), post-present. */
static int l_x_capture_read(lua_State *L) {
  check_gfx(L);
  size_t len;
  const void *p = pal_gfx_cap_read_begin(&len);
  if (!p) return luaL_error(L, "x_capture_read: no capture target / failed");
  lua_pushlstring(L, p, len);
  lua_pushinteger(L, G.cap_w);
  lua_pushinteger(L, G.cap_h);
  pal_gfx_cap_read_end();
  return 3;
}

/* pal.x_target("game"|"ui") : route subsequent quads to a target. Reset to
 * "game" by every begin_frame. Render. */
static int l_x_target(lua_State *L) {
  check_gfx(L);
  const char *which = luaL_checkstring(L, 1);
  if (strcmp(which, "game") == 0)
    G.cur_target = 0;
  else if (strcmp(which, "ui") == 0)
    G.cur_target = 1;
  else
    return luaL_error(L, "x_target: expected 'game' or 'ui'");
  return 0;
}

/* pal.x_compose{ x=, y=, scale=, ui_scale= } : define the present composite —
 * the game target blits to (x,y) at integer `scale` (window px); `scale = 0`
 * skips the game blit entirely (v7: the ig-canvas editor draws the game
 * target itself via x_ig_image(-1)); if `ui_scale` > 0 and a ui target
 * exists, it blits over the whole window at that integer scale, alpha-over
 * the game. pal.x_compose() (no arg) resets to the default centered
 * letterbox with no ui layer. Render/dev (D036). */
static int l_x_compose(lua_State *L) {
  check_gfx(L);
  if (lua_isnoneornil(L, 1)) {
    G.compose_set = false;
    G.ui_scale = 0;
    return 0;
  }
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_getfield(L, 1, "scale");
  int gscale = (int)luaL_optinteger(L, -1, 1);
  lua_getfield(L, 1, "x");
  int vx = (int)luaL_optinteger(L, -1, 0);
  lua_getfield(L, 1, "y");
  int vy = (int)luaL_optinteger(L, -1, 0);
  lua_getfield(L, 1, "ui_scale");
  int us = (int)luaL_optinteger(L, -1, 0);
  if (gscale < 0) gscale = 0;
  G.vp_x = vx;
  G.vp_y = vy;
  G.vp_scale = gscale;
  G.ui_scale = us > 0 ? (float)us : 0;
  G.compose_set = true;
  return 0;
}

/* pal.x_grade{ brightness=, contrast=, saturation=, tint={r,g,b} } : a
 * render-only color grade over the game-target blit (per-room mood). Reset
 * every begin_frame, so set it each frame you want it; pal.x_grade() (no arg)
 * turns it off. Defaults are the identity grade. Render/dev, never sim (D036,
 * the sim can't read it — it only affects the final composite). */
static int l_x_grade(lua_State *L) {
  check_gfx(L);
  if (lua_isnoneornil(L, 1)) {
    G.grade_set = false;
    return 0;
  }
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_getfield(L, 1, "brightness");
  G.grade[0] = (float)luaL_optnumber(L, -1, 0.0);
  lua_getfield(L, 1, "contrast");
  G.grade[1] = (float)luaL_optnumber(L, -1, 1.0);
  lua_getfield(L, 1, "saturation");
  G.grade[2] = (float)luaL_optnumber(L, -1, 1.0);
  G.grade[3] = 0.0f;
  float tr = 1.0f, tg = 1.0f, tb = 1.0f;
  lua_getfield(L, 1, "tint");
  if (lua_istable(L, -1)) {
    lua_geti(L, -1, 1);
    tr = (float)luaL_optnumber(L, -1, 1.0);
    lua_geti(L, -2, 2);
    tg = (float)luaL_optnumber(L, -1, 1.0);
    lua_geti(L, -3, 3);
    tb = (float)luaL_optnumber(L, -1, 1.0);
  }
  G.grade[4] = tr;
  G.grade[5] = tg;
  G.grade[6] = tb;
  G.grade[7] = 0.0f;
  G.grade_set = true;
  return 0;
}

static int l_begin_frame(lua_State *L) {
  check_gfx(L);
  pal_gfx_begin((float)luaL_optnumber(L, 1, 0), (float)luaL_optnumber(L, 2, 0),
                (float)luaL_optnumber(L, 3, 0), (float)luaL_optnumber(L, 4, 1));
  return 0;
}

static uint32_t color_arg(lua_State *L, int first) {
  float c[4];
  for (int i = 0; i < 4; i++) {
    float f = (float)luaL_optnumber(L, first + i, 1.0);
    c[i] = f < 0 ? 0 : (f > 1 ? 1 : f);
  }
  return (uint32_t)(c[0] * 255.0f + 0.5f) |
         ((uint32_t)(c[1] * 255.0f + 0.5f) << 8) |
         ((uint32_t)(c[2] * 255.0f + 0.5f) << 16) |
         ((uint32_t)(c[3] * 255.0f + 0.5f) << 24);
}

static int l_quad(lua_State *L) {
  check_gfx(L);
  float x = (float)luaL_checknumber(L, 1);
  float y = (float)luaL_checknumber(L, 2);
  float w = (float)luaL_checknumber(L, 3);
  float h = (float)luaL_checknumber(L, 4);
  uint32_t rgba = color_arg(L, 5);
  int tex = (int)luaL_optinteger(L, 9, 0);
  float u0 = (float)luaL_optnumber(L, 10, 0);
  float v0 = (float)luaL_optnumber(L, 11, 0);
  float u1 = (float)luaL_optnumber(L, 12, 1);
  float v1 = (float)luaL_optnumber(L, 13, 1);
  pal_gfx_quad(x, y, w, h, u0, v0, u1, v1, rgba, tex);
  return 0;
}

/* bulk quad path: count quads of 12 f32 LE each (x,y,w,h, u0,v0,u1,v1,
 * r,g,b,a — colors 0..1, clamped, same rounding as pal.quad) read from a
 * buffer view at byte_off. layout FROZEN (stability contract rule 5). */
static int l_draw_quads(lua_State *L) {
  check_gfx(L);
  int tex = (int)luaL_checkinteger(L, 1);
  BufView *v = checkview_at(L, 2);
  lua_Integer count = luaL_checkinteger(L, 3);
  lua_Integer off = luaL_optinteger(L, 4, 0);
  if (count < 0) return luaL_error(L, "draw_quads: negative count");
  if (off < 0 || (size_t)(off + count * 48) > v->b->size)
    return luaL_error(L, "draw_quads: out of bounds (off=%I count=%I size=%I)",
                      off, count, (lua_Integer)v->b->size);
  const uint8_t *p = v->b->data + off;
  for (lua_Integer i = 0; i < count; i++, p += 48) {
    float q[12];
    memcpy(q, p, 48);
    uint32_t rgba = 0;
    for (int ch = 0; ch < 4; ch++) {
      float f = q[8 + ch];
      f = f < 0 ? 0 : (f > 1 ? 1 : f);
      rgba |= (uint32_t)(f * 255.0f + 0.5f) << (8 * ch);
    }
    pal_gfx_quad(q[0], q[1], q[2], q[3], q[4], q[5], q[6], q[7], rgba, tex);
  }
  return 0;
}

/* pal.x_ig_image_quads(tex, buf, count[, off[, rgba]]) — batch N textured
 * quads (8 f32 each: x,y,w,h,u0,v0,u1,v1, screen px + uv) onto the imgui
 * drawlist in ONE call; rgba tints all (default white). The map/tilemap
 * editors' fast path — see pal_ig_image_quads (ig.cpp). No-op outside a frame. */
static int l_ig_image_quads(lua_State *L) {
  int tex = (int)luaL_checkinteger(L, 1);
  BufView *v = checkview_at(L, 2);
  lua_Integer count = luaL_checkinteger(L, 3);
  lua_Integer off = luaL_optinteger(L, 4, 0);
  uint32_t rgba = (uint32_t)luaL_optinteger(L, 5, 0xffffffffu);
  if (count < 0) return luaL_error(L, "x_ig_image_quads: negative count");
  if (off < 0 || (size_t)(off + count * 32) > v->b->size)
    return luaL_error(L, "x_ig_image_quads: out of bounds (off=%I count=%I size=%I)",
                      off, count, (lua_Integer)v->b->size);
  pal_ig_image_quads(tex, (const float *)(v->b->data + off), (int)count, rgba);
  return 0;
}

static int l_clip(lua_State *L) {
  check_gfx(L);
  if (lua_gettop(L) == 0) {
    pal_gfx_clip(false, 0, 0, 0, 0);
  } else {
    pal_gfx_clip(true, (int)luaL_checkinteger(L, 1),
                 (int)luaL_checkinteger(L, 2), (int)luaL_checkinteger(L, 3),
                 (int)luaL_checkinteger(L, 4));
  }
  return 0;
}

static int l_camera(lua_State *L) {
  check_gfx(L);
  G.cam_x = (float)luaL_optnumber(L, 1, 0);
  G.cam_y = (float)luaL_optnumber(L, 2, 0);
  return 0;
}

static int l_present(lua_State *L) {
  check_gfx(L);
  if (!pal_gfx_present()) return luaL_error(L, "present failed (see log)");
  return 0;
}

static int l_read_pixels(lua_State *L) {
  check_gfx(L);
  size_t len;
  const void *p = pal_gfx_read_begin(&len);
  if (!p) return luaL_error(L, "read_pixels failed (see log)");
  lua_pushlstring(L, p, len);
  pal_gfx_read_end();
  return 1;
}

static int l_png_write(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  size_t len;
  const char *data = luaL_checklstring(L, 2, &len);
  int w = (int)luaL_checkinteger(L, 3);
  int h = (int)luaL_checkinteger(L, 4);
  if (len != (size_t)w * h * 4)
    return luaL_error(L, "png_write: data is %I bytes, want w*h*4=%I",
                      (lua_Integer)len, (lua_Integer)w * h * 4);
  if (!stbi_write_png(path, w, h, 4, data, w * 4))
    return luaL_error(L, "png_write: failed writing %s", path);
  return 0;
}

static int l_png_read(lua_State *L) {
  size_t len;
  const char *data = luaL_checklstring(L, 1, &len);
  int w, h, comp;
  stbi_uc *pix = stbi_load_from_memory((const stbi_uc *)data, (int)len, &w,
                                       &h, &comp, 4);
  if (!pix) {
    lua_pushnil(L);
    lua_pushstring(L, stbi_failure_reason());
    return 2;
  }
  lua_pushlstring(L, (const char *)pix, (size_t)w * h * 4);
  stbi_image_free(pix);
  lua_pushinteger(L, w);
  lua_pushinteger(L, h);
  return 3;
}

static int l_tex_create(lua_State *L) {
  check_gfx(L);
  int w = (int)luaL_checkinteger(L, 1);
  int h = (int)luaL_checkinteger(L, 2);
  size_t len;
  const char *data = luaL_checklstring(L, 3, &len);
  if (w < 1 || h < 1 || len != (size_t)w * h * 4)
    return luaL_error(L, "tex_create: data is %I bytes, want w*h*4",
                      (lua_Integer)len);
  int id = pal_gfx_tex_create(data, w, h);
  if (id < 0) return luaL_error(L, "tex_create failed (out of slots?)");
  lua_pushinteger(L, id);
  return 1;
}

/* pal.tex_update(id, buf, w, h) — re-upload pixels straight from a pal.buf into
 * an existing same-size texture (no GPU realloc, no Lua-string copy: the cheap
 * path for a canvas that changes every frame). Returns false if the slot is
 * free or the size differs — the caller then tex_free + tex_create instead. */
static int l_tex_update(lua_State *L) {
  check_gfx(L);
  int id = (int)luaL_checkinteger(L, 1);
  BufView *v = luaL_checkudata(L, 2, BUFVIEW_MT);
  if (!v->b->alive) return luaL_error(L, "tex_update: buffer was freed");
  int w = (int)luaL_checkinteger(L, 3);
  int h = (int)luaL_checkinteger(L, 4);
  if (w < 1 || h < 1 || (size_t)w * h * 4 > v->b->size)
    return luaL_error(L, "tex_update: buffer smaller than w*h*4");
  lua_pushboolean(L, pal_gfx_tex_update(id, v->b->data, w, h));
  return 1;
}

static int l_tex_free(lua_State *L) {
  check_gfx(L);
  lua_pushboolean(L, pal_gfx_tex_free((int)luaL_checkinteger(L, 1)));
  return 1;
}

/* ---------- input ---------- */

static int l_poll_events(lua_State *L) {
  lua_createtable(L, G.event_count, 0);
  for (int i = 0; i < G.event_count; i++) {
    PalEvent *e = &G.events[i];
    lua_createtable(L, 0, 5);
    switch (e->type) {
    case PAL_EV_QUIT:
      lua_pushstring(L, "quit");
      lua_setfield(L, -2, "type");
      break;
    case PAL_EV_KEY:
      lua_pushstring(L, "key");
      lua_setfield(L, -2, "type");
      lua_pushinteger(L, e->a);
      lua_setfield(L, -2, "scancode");
      lua_pushboolean(L, e->down);
      lua_setfield(L, -2, "down");
      lua_pushboolean(L, e->repeat);
      lua_setfield(L, -2, "rep");
      break;
    case PAL_EV_MOTION:
      lua_pushstring(L, "motion");
      lua_setfield(L, -2, "type");
      lua_pushnumber(L, e->x);
      lua_setfield(L, -2, "x");
      lua_pushnumber(L, e->y);
      lua_setfield(L, -2, "y");
      lua_pushnumber(L, e->ui_x);
      lua_setfield(L, -2, "ui_x");
      lua_pushnumber(L, e->ui_y);
      lua_setfield(L, -2, "ui_y");
      lua_pushnumber(L, e->wx);
      lua_setfield(L, -2, "wx");
      lua_pushnumber(L, e->wy);
      lua_setfield(L, -2, "wy");
      break;
    case PAL_EV_BUTTON:
      lua_pushstring(L, "button");
      lua_setfield(L, -2, "type");
      lua_pushinteger(L, e->a);
      lua_setfield(L, -2, "button");
      lua_pushboolean(L, e->down);
      lua_setfield(L, -2, "down");
      lua_pushnumber(L, e->x);
      lua_setfield(L, -2, "x");
      lua_pushnumber(L, e->y);
      lua_setfield(L, -2, "y");
      lua_pushnumber(L, e->ui_x);
      lua_setfield(L, -2, "ui_x");
      lua_pushnumber(L, e->ui_y);
      lua_setfield(L, -2, "ui_y");
      lua_pushnumber(L, e->wx);
      lua_setfield(L, -2, "wx");
      lua_pushnumber(L, e->wy);
      lua_setfield(L, -2, "wy");
      break;
    case PAL_EV_WHEEL:
      lua_pushstring(L, "wheel");
      lua_setfield(L, -2, "type");
      lua_pushnumber(L, e->x);
      lua_setfield(L, -2, "dx");
      lua_pushnumber(L, e->y);
      lua_setfield(L, -2, "dy");
      break;
    case PAL_EV_TEXT:
      lua_pushstring(L, "text");
      lua_setfield(L, -2, "type");
      lua_pushstring(L, e->text);
      lua_setfield(L, -2, "text");
      break;
    case PAL_EV_DROP:
      lua_pushstring(L, "drop");
      lua_setfield(L, -2, "type");
      lua_pushstring(L, e->drop);
      lua_setfield(L, -2, "path");
      lua_pushnumber(L, e->wx);
      lua_setfield(L, -2, "wx");
      lua_pushnumber(L, e->wy);
      lua_setfield(L, -2, "wy");
      break;
    }
    lua_rawseti(L, -2, i + 1);
  }
  G.event_count = 0;
  return 1;
}

/* pal.x_remove(path): delete a file (or empty dir). The R6 history
 * spill's eviction/wipe path (D053); dev-side file hygiene only. */
static int l_x_remove(lua_State *L) {
  lua_pushboolean(L, SDL_RemovePath(luaL_checkstring(L, 1)));
  return 1;
}

/* pal.x_reboot(): close + re-boot the Lua VM after this tick (D052 — the
 * picker's project switch; the parachute cycle without an error). */
static int l_x_reboot(lua_State *L) {
  (void)L;
  G.reboot = true;
  return 0;
}

static int l_scancode_name(lua_State *L) {
  lua_pushstring(L,
                 SDL_GetScancodeName((SDL_Scancode)luaL_checkinteger(L, 1)));
  return 1;
}

/* pal.text_input(on): enable/disable text events (utf-8, layout/IME aware).
 * No-op headless: text events only exist where a window does. */
static int l_text_input(lua_State *L) {
  if (G.win) {
    if (lua_toboolean(L, 1))
      SDL_StartTextInput(G.win);
    else
      SDL_StopTextInput(G.win);
  }
  return 0;
}

/* pal.x_clipboard([s]) -> s : OS clipboard get (and set, when given). Dev
 * class; headless/offscreen returns "" — never an error, never sim input. */
static int l_x_clipboard(lua_State *L) {
  if (lua_gettop(L) >= 1 && !lua_isnil(L, 1))
    SDL_SetClipboardText(luaL_checkstring(L, 1));
  char *t = SDL_GetClipboardText();
  lua_pushstring(L, t ? t : "");
  SDL_free(t);
  return 1;
}

/* pal.frame_stats() -> counters from the last present + live resource counts */
static int l_frame_stats(lua_State *L) {
  lua_createtable(L, 0, 6);
  lua_pushinteger(L, G.stat_quads);
  lua_setfield(L, -2, "quads");
  lua_pushinteger(L, G.stat_segs);
  lua_setfield(L, -2, "segs");
  lua_pushinteger(L, G.stat_vbytes);
  lua_setfield(L, -2, "vbytes");
  int ntex = 0;
  for (int i = 0; i < PAL_MAX_TEX; i++)
    if (G.texs[i].used) ntex++;
  lua_pushinteger(L, ntex);
  lua_setfield(L, -2, "textures");
  lua_Integer nbuf = 0, buf_bytes = 0;
  for (PalBuf *b = G.bufs; b; b = b->next) {
    if (!b->alive || !b->name) continue;
    nbuf++;
    buf_bytes += (lua_Integer)b->size;
  }
  lua_pushinteger(L, nbuf);
  lua_setfield(L, -2, "bufs");
  lua_pushinteger(L, buf_bytes);
  lua_setfield(L, -2, "buf_bytes");
  return 1;
}

/* ---------- files ---------- */

static int l_read_file(lua_State *L) {
  size_t len;
  void *data = SDL_LoadFile(luaL_checkstring(L, 1), &len);
  if (!data) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }
  lua_pushlstring(L, data, len);
  SDL_free(data);
  return 1;
}

static int l_write_file(lua_State *L) {
  size_t len;
  const char *data = luaL_checklstring(L, 2, &len);
  lua_pushboolean(L, SDL_SaveFile(luaL_checkstring(L, 1), data, len));
  return 1;
}

/* Flush an SDL file stream through the OS durability boundary. SDL_FlushIO
 * empties user-space buffering; fsync/FlushFileBuffers asks the filesystem to
 * persist it before the atomic rename. SDL_IOFromFile publishes its native
 * handle through stream properties while retaining UTF-8 path handling. */
static bool sync_file(SDL_IOStream *io, char *err, size_t errcap) {
  SDL_PropertiesID props = SDL_GetIOProperties(io);
#ifdef _WIN32
  HANDLE h = (HANDLE)SDL_GetPointerProperty(
      props, SDL_PROP_IOSTREAM_WINDOWS_HANDLE_POINTER, NULL);
  if (!h) {
    SDL_snprintf(err, errcap, "no Windows file handle");
    return false;
  }
  if (!FlushFileBuffers(h)) {
    SDL_snprintf(err, errcap, "FlushFileBuffers failed (%lu)",
                 (unsigned long)GetLastError());
    return false;
  }
#else
  int fd = (int)SDL_GetNumberProperty(
      props, SDL_PROP_IOSTREAM_FILE_DESCRIPTOR_NUMBER, -1);
  if (fd < 0) {
    SDL_snprintf(err, errcap, "no file descriptor");
    return false;
  }
  if (fsync(fd) != 0) {
    SDL_snprintf(err, errcap, "fsync failed: %s", strerror(errno));
    return false;
  }
#endif
  return true;
}

static bool fail_at(lua_State *L, const char *stage) {
  if (!lua_istable(L, 3)) return false;
  lua_getfield(L, 3, "_fail");
  const char *got = lua_tostring(L, -1);
  bool yes = got && strcmp(got, stage) == 0;
  lua_pop(L, 1);
  return yes;
}

static uint64_t atomic_temp_seq;

/* pal.write_file_atomic(path, bytes [, {_fail=stage}]) -> true | nil,error
 *
 * Write a unique path.tmp.PID.SEQ in the destination directory, flush +
 * OS-sync it, close it, then atomically replace path. Any failure before the
 * rename removes the temp and leaves an existing destination untouched.
 * `_fail` is the explicit selftest seam (open/write/flush/sync/close/rename),
 * not application policy. */
static int l_write_file_atomic(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  size_t len;
  const char *data = luaL_checklstring(L, 2, &len);
  size_t plen = strlen(path);
  char *tmp = SDL_malloc(plen + 64);
  if (!tmp) {
    lua_pushnil(L);
    lua_pushliteral(L, "out of memory");
    return 2;
  }
  unsigned long pid =
#ifdef _WIN32
      (unsigned long)GetCurrentProcessId();
#else
      (unsigned long)getpid();
#endif
  SDL_snprintf(tmp, plen + 64, "%s.tmp.%lu.%llu", path, pid,
               (unsigned long long)++atomic_temp_seq);

  SDL_IOStream *io = NULL;
  char detail[256] = {0};
  const char *stage = "open";
  bool ok = false;

  /* A stale temp is never authoritative. PID + monotonic process sequence
   * keeps simultaneous writers off each other's temp; remove the exact name
   * in the unlikely PID-reuse collision before opening it. */
  SDL_PathInfo tmpinfo;
  if (SDL_GetPathInfo(tmp, &tmpinfo) && !SDL_RemovePath(tmp)) {
    SDL_snprintf(detail, sizeof detail, "%s", SDL_GetError());
    goto done;
  }
  if (fail_at(L, "open")) {
    SDL_snprintf(detail, sizeof detail, "injected failure");
    goto done;
  }
  io = SDL_IOFromFile(tmp, "wb");
  if (!io) {
    SDL_snprintf(detail, sizeof detail, "%s", SDL_GetError());
    goto done;
  }

  stage = "write";
  size_t want = fail_at(L, "write") && len ? len / 2 : len;
  size_t wrote = SDL_WriteIO(io, data, want);
  if (wrote != want || want != len) {
    SDL_snprintf(detail, sizeof detail, "%s",
                 want != len ? "injected partial write" : SDL_GetError());
    goto done;
  }

  stage = "flush";
  if (fail_at(L, "flush") || !SDL_FlushIO(io)) {
    SDL_snprintf(detail, sizeof detail, "%s",
                 fail_at(L, "flush") ? "injected failure" : SDL_GetError());
    goto done;
  }

  stage = "sync";
  if (fail_at(L, "sync")) {
    SDL_snprintf(detail, sizeof detail, "injected failure");
    goto done;
  }
  if (!sync_file(io, detail, sizeof detail)) goto done;

  stage = "close";
  if (!SDL_CloseIO(io)) {
    io = NULL;
    SDL_snprintf(detail, sizeof detail, "%s", SDL_GetError());
    goto done;
  }
  io = NULL;
  if (fail_at(L, "close")) {
    SDL_snprintf(detail, sizeof detail, "injected failure");
    goto done;
  }

  stage = "rename";
  if (fail_at(L, "rename") || !SDL_RenamePath(tmp, path)) {
    SDL_snprintf(detail, sizeof detail, "%s",
                 fail_at(L, "rename") ? "injected failure" : SDL_GetError());
    goto done;
  }
  ok = true;

done:
  if (io && !SDL_CloseIO(io) && !detail[0])
    SDL_snprintf(detail, sizeof detail, "%s", SDL_GetError());
  if (!ok) SDL_RemovePath(tmp);
  SDL_free(tmp);
  if (ok) {
    lua_pushboolean(L, 1);
    return 1;
  }
  lua_pushnil(L);
  lua_pushfstring(L, "atomic write %s failed: %s", stage,
                  detail[0] ? detail : "unknown error");
  return 2;
}

/* x_file_append(path, bytes) -> bool — append to a file, creating it if
 * missing. Born for the R3 editor's undo journals (D050): an append-only
 * chunk stream must not rewrite a multi-MB file per gesture. */
static int l_x_file_append(lua_State *L) {
  size_t len;
  const char *data = luaL_checklstring(L, 2, &len);
  SDL_IOStream *io = SDL_IOFromFile(luaL_checkstring(L, 1), "ab");
  if (!io) {
    lua_pushboolean(L, 0);
    return 1;
  }
  size_t n = SDL_WriteIO(io, data, len);
  bool ok = SDL_CloseIO(io) && n == len;
  lua_pushboolean(L, ok);
  return 1;
}

/* recursive directory walk that PRUNES dot-directories (.ed, .git, …).
 * SDL_GlobDirectory would descend into them — and the .ed undo journal is
 * thousands of history files, so globbing the project root stat'd the whole
 * tree just to throw it away (every caller already filters ^%.ed/^%.git).
 * On a native Windows FS that froze the editor on the first preset drop
 * (the drop's assets invalidate → a full re-glob). Emitting relative paths
 * matches the old SDL_GlobDirectory shape; callers table.sort afterward. */
typedef struct {
  lua_State *L;
  int tbl;      /* absolute stack index of the result table */
  int *n;       /* running entry count (shared across recursion) */
  const char *rel; /* this dir's path relative to the requested root ("" = root) */
} ListCtx;

static SDL_EnumerationResult SDLCALL list_cb(void *ud, const char *dirname,
                                             const char *fname) {
  ListCtx *c = (ListCtx *)ud;
  char abspath[2048], relpath[2048];
  size_t dl = SDL_strlen(dirname);
  int sep = dl && (dirname[dl - 1] == '/' || dirname[dl - 1] == '\\');
  SDL_snprintf(abspath, sizeof abspath, "%s%s%s", dirname, sep ? "" : "/", fname);
  if (c->rel[0])
    SDL_snprintf(relpath, sizeof relpath, "%s/%s", c->rel, fname);
  else
    SDL_snprintf(relpath, sizeof relpath, "%s", fname);

  SDL_PathInfo info;
  bool isdir = SDL_GetPathInfo(abspath, &info)
               && info.type == SDL_PATHTYPE_DIRECTORY;
  if (isdir && fname[0] == '.') return SDL_ENUM_CONTINUE; /* prune .ed/.git */

  lua_pushstring(c->L, relpath);
  lua_rawseti(c->L, c->tbl, ++(*c->n));

  if (isdir) {
    ListCtx child = {c->L, c->tbl, c->n, relpath};
    SDL_EnumerateDirectory(abspath, list_cb, &child);
  }
  return SDL_ENUM_CONTINUE;
}

static int l_list_dir(lua_State *L) {
  const char *root = luaL_checkstring(L, 1);
  lua_newtable(L);
  int n = 0;
  ListCtx c = {L, lua_gettop(L), &n, ""};
  if (!SDL_EnumerateDirectory(root, list_cb, &c)) {
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }
  return 1;
}

static int l_mtime(lua_State *L) {
  SDL_PathInfo info;
  if (!SDL_GetPathInfo(luaL_checkstring(L, 1), &info)) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushinteger(L, (lua_Integer)info.modify_time);
  return 1;
}

static int l_mkdir(lua_State *L) {
  lua_pushboolean(L, SDL_CreateDirectory(luaL_checkstring(L, 1)));
  return 1;
}

static int l_watch_add(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  SDL_PathInfo info;
  int64_t mt = SDL_GetPathInfo(path, &info) ? (int64_t)info.modify_time : 0;
  if (!G.watch_mutex) G.watch_mutex = SDL_CreateMutex();
  SDL_LockMutex(G.watch_mutex); /* sync count growth with the watcher thread */
  bool dup = false, full = false;
  for (int i = 0; i < G.watch_count; i++)
    if (strcmp(G.watch[i].path, path) == 0) {
      dup = true;
      break;
    }
  if (!dup) {
    if (G.watch_count == PAL_MAX_WATCH)
      full = true;
    else
      G.watch[G.watch_count++] =
          (PalWatch){.path = SDL_strdup(path), .mtime = mt, .cur_mtime = mt};
  }
  SDL_UnlockMutex(G.watch_mutex);
  if (full) return luaL_error(L, "watch list full");
  return 0;
}

static int l_watch_mtime(lua_State *L) {
  lua_pushinteger(L, (lua_Integer)pal_watch_mtime(luaL_checkstring(L, 1)));
  return 1;
}

/* ---------- module ---------- */

static const luaL_Reg pal_funcs[] = {
    {"log", l_log},
    {"log_lines", l_log_lines},
    {"time_ns", l_time_ns},
    {"sleep_ms", l_sleep_ms},
    {"quit", l_quit},
    {"quitting", l_quitting},
    {"exit_on_error", l_exit_on_error},
    {"hash", l_hash},
    {"gfx_init", l_gfx_init},
    {"gfx_size", l_gfx_size},
    {"x_window_size", l_x_window_size},
    {"x_fov", l_x_fov},
    {"x_set_window_size", l_x_set_window_size},
    {"x_set_fullscreen", l_x_set_fullscreen},
    {"x_ui_target", l_x_ui_target},
    {"x_target", l_x_target},
    {"x_compose", l_x_compose},
    {"x_grade", l_x_grade},
    {"x_capture", l_x_capture},
    {"x_capture_read", l_x_capture_read},
    {"x_clipboard", l_x_clipboard},
    {"begin_frame", l_begin_frame},
    {"quad", l_quad},
    {"draw_quads", l_draw_quads},
    {"x_ig_image_quads", l_ig_image_quads},
    {"clip", l_clip},
    {"camera", l_camera},
    {"present", l_present},
    {"read_pixels", l_read_pixels},
    {"png_write", l_png_write},
    {"png_read", l_png_read},
    {"tex_create", l_tex_create},
    {"tex_update", l_tex_update},
    {"tex_free", l_tex_free},
    {"blit32", l_blit32},
    {"poll_events", l_poll_events},
    {"x_reboot", l_x_reboot},
    {"x_remove", l_x_remove},
    {"scancode_name", l_scancode_name},
    {"text_input", l_text_input},
    {"frame_stats", l_frame_stats},
    {"buf", l_buf},
    {"buf_free", l_buf_free},
    {"buf_list", l_buf_list},
    {"buf_delta1", l_buf_delta1},
    {"buf_apply_delta1", l_buf_apply_delta1},
    {"read_file", l_read_file},
    {"write_file", l_write_file},
    {"write_file_atomic", l_write_file_atomic},
    {"x_file_append", l_x_file_append},
    {"list_dir", l_list_dir},
    {"mtime", l_mtime},
    {"mkdir", l_mkdir},
    {"watch_add", l_watch_add},
    {"watch_mtime", l_watch_mtime},
    {NULL, NULL}};

void pal_lua_register(lua_State *L) {
  luaL_newmetatable(L, BUFVIEW_MT);
  lua_pushcfunction(L, l_buf_gc);
  lua_setfield(L, -2, "__gc");
  luaL_newlib(L, bufview_methods);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, pal_funcs);
  pal_ig_lua_register(L);  /* the pal.x_ig_* surface (ig.cpp, D049) */
  pal_snd_lua_register(L); /* the pal snd_* + x_snd_* surface (snd.c, R9b) */
  pal_snd_dec_lua_register(L); /* pal.x_snd_decode (snd_dec.c, R9b) */
  lua_createtable(L, 0, 2);
  lua_pushinteger(L, PAL_VERSION_MAJOR);
  lua_setfield(L, -2, "major");
  lua_pushinteger(L, PAL_VERSION_API);
  lua_setfield(L, -2, "api");
  lua_setfield(L, -2, "version");
#ifdef _WIN32
  lua_pushstring(L, "windows");
#else
  lua_pushstring(L, "linux");
#endif
  lua_setfield(L, -2, "platform");
  lua_createtable(L, G.argc > 1 ? G.argc - 1 : 0, 0);
  for (int i = 1; i < G.argc; i++) {
    lua_pushstring(L, G.argv[i]);
    lua_rawseti(L, -2, i);
  }
  lua_setfield(L, -2, "argv");
  /* argv[0] — the launcher story (D052): a renamed exe boots the project
   * with its own name; the decision lives in Lua (cm.main) */
  lua_pushstring(L, G.argc > 0 ? G.argv[0] : "cosmic");
  lua_setfield(L, -2, "exe");
  lua_setglobal(L, "pal");
}
