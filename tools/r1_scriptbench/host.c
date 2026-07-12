/* R1 spike: dual-host bench harness — vendored Lua 5.4.7 vs QuickJS
 * 2025-09-13, one binary, identical native surface, so the boundary-crossing
 * cost is measured on the same C code.
 *
 * Native surface (mirrors PAL shapes used by the engine's hot paths):
 *   now()                    -> monotonic ns (double)
 *   emit(s)                  -> print a line
 *   buf:f32(off[, v])        -> read/write a float in the named-buffer mock
 *                               (method-call shape, like pal.buf views)
 *   quad(x,y,w,h,u0,v0,u1,v1,r,g,b,a) -> per-call submit (pal.quad shape)
 *   draw_quads(n)            -> batch flush from the scratch (resets cursor)
 *   rect(x,y,w,h,c)          -> UI solid-rect submit (cm.ui.rect -> pal shape)
 *   JS only: scratch_f32     -> Float32Array aliasing the same scratch
 *                               (the typed-array direct-write path Lua lacks)
 *
 * usage: host <lua|qjs> <script>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "quickjs.h"

#define FB_N (1 << 16)          /* named-buffer mock: 64Ki floats */
static float FB[FB_N];
#define SCRATCH_N (12 * 100000) /* quad scratch: 100k quads */
static float SCRATCH[SCRATCH_N];
static long long g_quads, g_flushes, g_rects; /* keep work observable */

static double now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
}

/* ---------------- Lua side ---------------- */

static int l_now(lua_State *L) { lua_pushnumber(L, now_ns()); return 1; }
static int l_emit(lua_State *L) {
  fputs(luaL_checkstring(L, 1), stdout); fputc('\n', stdout); return 0;
}
static int l_bf32(lua_State *L) {
  /* buf:f32(off[, v]) — arg 1 is the buf table (self) */
  int o = (int)luaL_checkinteger(L, 2);
  if (o < 0 || o >= FB_N) return luaL_error(L, "oob");
  if (lua_gettop(L) >= 3) { FB[o] = (float)luaL_checknumber(L, 3); return 0; }
  lua_pushnumber(L, FB[o]); return 1;
}
static int l_quad(lua_State *L) {
  long long b = (g_quads % 100000) * 12;
  for (int i = 0; i < 12; i++)
    SCRATCH[b + i] = (float)luaL_checknumber(L, i + 1);
  g_quads++; return 0;
}
static int l_draw_quads(lua_State *L) {
  g_flushes++; (void)luaL_checkinteger(L, 1); return 0;
}
static int l_rect(lua_State *L) {
  long long b = (g_rects % 100000) * 12;
  for (int i = 0; i < 4; i++) SCRATCH[b + i] = (float)luaL_checknumber(L, i + 1);
  SCRATCH[b + 4] = (float)luaL_checkinteger(L, 5);
  g_rects++; return 0;
}

static int run_lua(const char *path) {
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  lua_pushcfunction(L, l_now);        lua_setglobal(L, "now");
  lua_pushcfunction(L, l_emit);       lua_setglobal(L, "emit");
  lua_pushcfunction(L, l_quad);       lua_setglobal(L, "quad");
  lua_pushcfunction(L, l_draw_quads); lua_setglobal(L, "draw_quads");
  lua_pushcfunction(L, l_rect);       lua_setglobal(L, "rect");
  lua_newtable(L);
  lua_pushcfunction(L, l_bf32); lua_setfield(L, -2, "f32");
  lua_setglobal(L, "buf");
  if (luaL_dofile(L, path)) {
    fprintf(stderr, "lua: %s\n", lua_tostring(L, -1));
    return 1;
  }
  lua_close(L);
  return 0;
}

/* ---------------- QuickJS side ---------------- */

static JSValue j_now(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  return JS_NewFloat64(ctx, now_ns());
}
static JSValue j_emit(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  const char *s = JS_ToCString(ctx, argv[0]);
  if (!s) return JS_EXCEPTION;
  fputs(s, stdout); fputc('\n', stdout);
  JS_FreeCString(ctx, s);
  return JS_UNDEFINED;
}
static JSValue j_bf32(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int32_t o; double v;
  if (JS_ToInt32(ctx, &o, argv[0])) return JS_EXCEPTION;
  if (o < 0 || o >= FB_N) return JS_ThrowRangeError(ctx, "oob");
  if (argc >= 2) {
    if (JS_ToFloat64(ctx, &v, argv[1])) return JS_EXCEPTION;
    FB[o] = (float)v; return JS_UNDEFINED;
  }
  return JS_NewFloat64(ctx, FB[o]);
}
static JSValue j_quad(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  long long b = (g_quads % 100000) * 12;
  for (int i = 0; i < 12; i++) {
    double v; if (JS_ToFloat64(ctx, &v, argv[i])) return JS_EXCEPTION;
    SCRATCH[b + i] = (float)v;
  }
  g_quads++; return JS_UNDEFINED;
}
static JSValue j_draw_quads(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int32_t n; if (JS_ToInt32(ctx, &n, argv[0])) return JS_EXCEPTION;
  g_flushes++; return JS_UNDEFINED;
}
static JSValue j_rect(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  long long b = (g_rects % 100000) * 12;
  for (int i = 0; i < 4; i++) {
    double v; if (JS_ToFloat64(ctx, &v, argv[i])) return JS_EXCEPTION;
    SCRATCH[b + i] = (float)v;
  }
  int32_t c; if (JS_ToInt32(ctx, &c, argv[4])) return JS_EXCEPTION;
  SCRATCH[b + 4] = (float)c;
  g_rects++; return JS_UNDEFINED;
}

static int run_qjs(const char *path) {
  JSRuntime *rt = JS_NewRuntime();
  JSContext *ctx = JS_NewContext(rt);
  JSValue g = JS_GetGlobalObject(ctx);
  JS_SetPropertyStr(ctx, g, "now", JS_NewCFunction(ctx, j_now, "now", 0));
  JS_SetPropertyStr(ctx, g, "emit", JS_NewCFunction(ctx, j_emit, "emit", 1));
  JS_SetPropertyStr(ctx, g, "quad", JS_NewCFunction(ctx, j_quad, "quad", 12));
  JS_SetPropertyStr(ctx, g, "draw_quads", JS_NewCFunction(ctx, j_draw_quads, "draw_quads", 1));
  JS_SetPropertyStr(ctx, g, "rect", JS_NewCFunction(ctx, j_rect, "rect", 5));
  JSValue buf = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, buf, "f32", JS_NewCFunction(ctx, j_bf32, "f32", 2));
  JS_SetPropertyStr(ctx, g, "buf", buf);
  /* typed-array alias of the scratch — the path Lua has no equivalent of */
  JSValue ab = JS_NewArrayBuffer(ctx, (uint8_t *)SCRATCH, sizeof(SCRATCH),
                                 NULL, NULL, 0 /* not shared */);
  JS_SetPropertyStr(ctx, g, "scratch_ab", ab);
  JS_FreeValue(ctx, g);

  FILE *f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "open %s failed\n", path); return 1; }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  char *src = malloc(n + 1);
  if (fread(src, 1, n, f) != (size_t)n) { fprintf(stderr, "read failed\n"); return 1; }
  src[n] = 0; fclose(f);

  JSValue r = JS_Eval(ctx, src, n, path, JS_EVAL_TYPE_GLOBAL);
  int rc = 0;
  if (JS_IsException(r)) {
    JSValue e = JS_GetException(ctx);
    const char *s = JS_ToCString(ctx, e);
    fprintf(stderr, "qjs: %s\n", s ? s : "?");
    JSValue st = JS_GetPropertyStr(ctx, e, "stack");
    const char *ss = JS_ToCString(ctx, st);
    if (ss) fprintf(stderr, "%s\n", ss);
    rc = 1;
  }
  JS_FreeValue(ctx, r);
  free(src);
  JS_FreeContext(ctx);
  JS_FreeRuntime(rt);
  return rc;
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: host <lua|qjs> <script>\n"); return 2; }
  if (!strcmp(argv[1], "lua")) return run_lua(argv[2]);
  if (!strcmp(argv[1], "qjs")) return run_qjs(argv[2]);
  fprintf(stderr, "unknown vm %s\n", argv[1]);
  return 2;
}
