/* luabind.c — the pal.* Lua module: the porting contract between the PAL
 * and the engine. Semantics + determinism classes: docs/ARCHITECTURE.md. */
#include "pal.h"

#include <string.h>

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
    {"str", l_buf_str}, {"setstr", l_buf_setstr},
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
  cfg.title = luaL_optstring(L, -1, "pettan2d");
  lua_getfield(L, 1, "headless");
  cfg.headless = lua_toboolean(L, -1);
  lua_getfield(L, 1, "vsync");
  cfg.vsync = lua_isnil(L, -1) ? true : lua_toboolean(L, -1);
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
      break;
    case PAL_EV_WHEEL:
      lua_pushstring(L, "wheel");
      lua_setfield(L, -2, "type");
      lua_pushnumber(L, e->x);
      lua_setfield(L, -2, "dx");
      lua_pushnumber(L, e->y);
      lua_setfield(L, -2, "dy");
      break;
    }
    lua_rawseti(L, -2, i + 1);
  }
  G.event_count = 0;
  return 1;
}

static int l_scancode_name(lua_State *L) {
  lua_pushstring(L,
                 SDL_GetScancodeName((SDL_Scancode)luaL_checkinteger(L, 1)));
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

static int l_list_dir(lua_State *L) {
  int count = 0;
  char **names = SDL_GlobDirectory(luaL_checkstring(L, 1), NULL, 0, &count);
  if (!names) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }
  lua_createtable(L, count, 0);
  for (int i = 0; i < count; i++) {
    lua_pushstring(L, names[i]);
    lua_rawseti(L, -2, i + 1);
  }
  SDL_free(names);
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
  for (int i = 0; i < G.watch_count; i++)
    if (strcmp(G.watch[i].path, path) == 0) return 0;
  if (G.watch_count == PAL_MAX_WATCH)
    return luaL_error(L, "watch list full");
  SDL_PathInfo info;
  int64_t mt = SDL_GetPathInfo(path, &info) ? (int64_t)info.modify_time : 0;
  G.watch[G.watch_count++] = (PalWatch){.path = SDL_strdup(path), .mtime = mt};
  return 0;
}

/* ---------- module ---------- */

static const luaL_Reg pal_funcs[] = {
    {"log", l_log},
    {"time_ns", l_time_ns},
    {"sleep_ms", l_sleep_ms},
    {"quit", l_quit},
    {"exit_on_error", l_exit_on_error},
    {"hash", l_hash},
    {"gfx_init", l_gfx_init},
    {"gfx_size", l_gfx_size},
    {"begin_frame", l_begin_frame},
    {"quad", l_quad},
    {"draw_quads", l_draw_quads},
    {"clip", l_clip},
    {"camera", l_camera},
    {"present", l_present},
    {"read_pixels", l_read_pixels},
    {"png_write", l_png_write},
    {"png_read", l_png_read},
    {"tex_create", l_tex_create},
    {"tex_free", l_tex_free},
    {"poll_events", l_poll_events},
    {"scancode_name", l_scancode_name},
    {"buf", l_buf},
    {"buf_free", l_buf_free},
    {"buf_list", l_buf_list},
    {"buf_delta1", l_buf_delta1},
    {"buf_apply_delta1", l_buf_apply_delta1},
    {"read_file", l_read_file},
    {"write_file", l_write_file},
    {"list_dir", l_list_dir},
    {"mtime", l_mtime},
    {"mkdir", l_mkdir},
    {"watch_add", l_watch_add},
    {NULL, NULL}};

void pal_lua_register(lua_State *L) {
  luaL_newmetatable(L, BUFVIEW_MT);
  lua_pushcfunction(L, l_buf_gc);
  lua_setfield(L, -2, "__gc");
  luaL_newlib(L, bufview_methods);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, pal_funcs);
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
  lua_setglobal(L, "pal");
}
