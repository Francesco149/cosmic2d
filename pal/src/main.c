/* main.c — PAL entry: owns the process loop and the Lua VM lifecycle.
 * Everything interesting happens in Lua (engine/boot.lua); the C loop only
 * pumps events, pcalls cm_tick(), and parachutes on errors by watching for
 * file changes and rebooting the VM (named buffers survive — see pal.h). */
#include "pal.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include <SDL3/SDL_main.h> /* WinMain shim + correct main-thread setup */

#include "lauxlib.h"
#include "lualib.h"

#ifdef _WIN32
#include <direct.h>
#define pal_chdir _chdir
#else
#include <unistd.h>
#define pal_chdir chdir
#endif

Pal G;

void pal_log(const char *fmt, ...) {
  double t = (double)SDL_GetTicksNS() / 1e9;
  PalLogLine *line = &G.log_ring[G.log_seq % PAL_LOG_RING];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(line->text, sizeof line->text, fmt, ap);
  va_end(ap);
  line->seq = ++G.log_seq;
  line->t = t;
  fprintf(stderr, "[pal %8.3f] %s\n", t, line->text);
}

static int msgh(lua_State *L) {
  const char *msg = lua_tostring(L, 1);
  luaL_traceback(L, L, msg ? msg : "(non-string error)", 1);
  return 1;
}

static bool boot_lua(void) {
  G.L = luaL_newstate();
  if (!G.L) return false;
  luaL_openlibs(G.L);
  pal_lua_register(G.L);
  lua_pushcfunction(G.L, msgh);
  if (luaL_loadfile(G.L, "engine/boot.lua") != LUA_OK ||
      lua_pcall(G.L, 0, 0, -2) != LUA_OK) {
    pal_log("boot error: %s", lua_tostring(G.L, -1));
    lua_settop(G.L, 0);
    return false;
  }
  lua_settop(G.L, 0);
  return true;
}

static void enter_error_state(const char *msg) {
  pal_log("=== LUA ERROR ===\n%s", msg ? msg : "(unknown)");
  if (G.exit_on_error) {
    pal_log("exit_on_error set; quitting with code 1");
    G.exit_code = 1;
    G.quit = true;
    return;
  }
  pal_log("=== edit a watched file to reload ===");
  G.error_state = true;
}

static void tick_lua(void) {
  lua_pushcfunction(G.L, msgh);
  lua_getglobal(G.L, "cm_tick");
  if (!lua_isfunction(G.L, -1)) {
    enter_error_state("engine/boot.lua did not define global cm_tick()");
    lua_settop(G.L, 0);
    return;
  }
  if (lua_pcall(G.L, 0, 0, -2) != LUA_OK)
    enter_error_state(lua_tostring(G.L, -1));
  lua_settop(G.L, 0);
}

static bool watches_changed(void) {
  bool changed = false;
  for (int i = 0; i < G.watch_count; i++) {
    SDL_PathInfo info;
    if (!SDL_GetPathInfo(G.watch[i].path, &info)) continue;
    if ((int64_t)info.modify_time != G.watch[i].mtime) {
      G.watch[i].mtime = (int64_t)info.modify_time;
      changed = true;
    }
  }
  return changed;
}

/* Background file-watcher: stats the watch list off the main thread so the
 * engine's hot-reload poll never blocks on a slow FS (WSL 9p / drvfs). The
 * list is append-only with stable indices, so we read the count under the
 * lock, stat each path lock-free (the slow part), then write cur_mtime back
 * under the lock. Detached: it runs until the process exits. */
static int watch_thread_fn(void *unused) {
  (void)unused;
  for (;;) {
    SDL_LockMutex(G.watch_mutex);
    int n = G.watch_count;
    SDL_UnlockMutex(G.watch_mutex);
    for (int i = 0; i < n; i++) {
      SDL_PathInfo info;
      int64_t mt =
          SDL_GetPathInfo(G.watch[i].path, &info) ? (int64_t)info.modify_time : 0;
      SDL_LockMutex(G.watch_mutex);
      G.watch[i].cur_mtime = mt;
      SDL_UnlockMutex(G.watch_mutex);
    }
    SDL_Delay(200);
  }
  return 0;
}

static void watch_start(void) {
  if (G.watch_started) return;
  if (!G.watch_mutex) G.watch_mutex = SDL_CreateMutex();
  SDL_Thread *t = SDL_CreateThread(watch_thread_fn, "cm-watch", NULL);
  if (t) {
    SDL_DetachThread(t);
    G.watch_started = true;
  }
}

int64_t pal_watch_mtime(const char *path) {
  if (!G.watch_started) watch_start(); /* live-session lazy spawn */
  int64_t mt = -1;
  if (G.watch_mutex) {
    SDL_LockMutex(G.watch_mutex);
    for (int i = 0; i < G.watch_count; i++)
      if (SDL_strcmp(G.watch[i].path, path) == 0) {
        mt = G.watch[i].cur_mtime;
        break;
      }
    SDL_UnlockMutex(G.watch_mutex);
  }
  if (mt < 0) { /* unwatched path: one-off direct stat */
    SDL_PathInfo info;
    mt = SDL_GetPathInfo(path, &info) ? (int64_t)info.modify_time : 0;
  }
  return mt;
}

static void push_event(PalEvent e) {
  if (G.event_count < PAL_MAX_EVENTS) G.events[G.event_count++] = e;
}

/* map a window-px mouse coord into both spaces the engine needs: game-space
 * (through the game viewport, what the sim/world use) and ui-canvas space (the
 * editor chrome). The composite that defines these is set each present. */
static void map_mouse(float wx, float wy, PalEvent *ev) {
  ev->x = (wx - G.lay_ox) / G.lay_s; /* window -> game viewport -> FOV px */
  ev->y = (wy - G.lay_oy) / G.lay_s;
  float us = G.ui_scale > 0 ? G.ui_scale : G.lay_s; /* ui canvas: top-left */
  ev->ui_x = wx / us;
  ev->ui_y = wy / us;
  ev->wx = wx; /* raw window px: the ig-canvas space (v7) */
  ev->wy = wy;
}

static void pump_events(void) {
  SDL_Event e;
  while (SDL_PollEvent(&e)) {
    /* the imgui host sees every event too (no-op until it initializes);
     * Lua decides per frame what the game still sees via the x_ig_frame
     * capture flags — policy stays script-side (D049) */
    pal_ig_sdl_event(&e);
    switch (e.type) {
    case SDL_EVENT_QUIT:
      push_event((PalEvent){.type = PAL_EV_QUIT});
      if (G.error_state) G.quit = true;
      break;
    case SDL_EVENT_KEY_DOWN:
    case SDL_EVENT_KEY_UP:
      push_event((PalEvent){.type = PAL_EV_KEY,
                            .a = (int)e.key.scancode,
                            .down = e.type == SDL_EVENT_KEY_DOWN,
                            .repeat = e.key.repeat});
      break;
    case SDL_EVENT_MOUSE_MOTION: {
      PalEvent ev = {.type = PAL_EV_MOTION};
      map_mouse(e.motion.x, e.motion.y, &ev);
      push_event(ev);
      break;
    }
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP: {
      PalEvent ev = {.type = PAL_EV_BUTTON,
                     .a = e.button.button,
                     .down = e.type == SDL_EVENT_MOUSE_BUTTON_DOWN};
      map_mouse(e.button.x, e.button.y, &ev);
      push_event(ev);
      break;
    }
    case SDL_EVENT_MOUSE_WHEEL:
      push_event(
          (PalEvent){.type = PAL_EV_WHEEL, .x = e.wheel.x, .y = e.wheel.y});
      break;
    case SDL_EVENT_DROP_FILE: {
      /* an OS file dropped onto the window: the R4 asset-pick add path.
       * Window px only (wx,wy) — the canvas hit-tests it like any ig-space
       * point; game/ui spaces are meaningless for a drop. */
      const char *path = e.drop.data;
      size_t plen = path ? strlen(path) : 0;
      if (plen == 0 || plen >= PAL_EV_DROP_MAX) {
        pal_log("drop ignored (path %s)", plen ? "too long" : "empty");
        break;
      }
      PalEvent ev = {.type = PAL_EV_DROP, .wx = e.drop.x, .wy = e.drop.y};
      memcpy(ev.drop, path, plen + 1);
      push_event(ev);
      break;
    }
    case SDL_EVENT_TEXT_INPUT: {
      /* split long IME commits into PAL_EV_TEXT_MAX-1 byte chunks, never
       * inside a utf-8 sequence (continuation bytes are 10xxxxxx) */
      const char *s = e.text.text;
      size_t len = s ? strlen(s) : 0;
      while (len > 0) {
        size_t n = len < PAL_EV_TEXT_MAX - 1 ? len : PAL_EV_TEXT_MAX - 1;
        while (n > 0 && n < len && ((unsigned char)s[n] & 0xc0) == 0x80) n--;
        PalEvent ev = {.type = PAL_EV_TEXT};
        memcpy(ev.text, s, n);
        ev.text[n] = '\0';
        push_event(ev);
        s += n;
        len -= n;
      }
      break;
    }
    }
  }
}

/* error screen: keep the window alive and visibly broken */
static void error_frame(void) {
  if (G.gfx_up) {
    pal_gfx_begin(0.55f, 0.07f, 0.35f, 1.0f);
    pal_gfx_present();
  }
  SDL_Delay(100);
  if (watches_changed()) {
    pal_log("watched file changed; rebooting lua vm");
    lua_close(G.L);
    G.event_count = 0;
    if (boot_lua())
      G.error_state = false;
    else
      pal_log("reboot failed; still in error state");
  }
}

/* Make the working directory the one that holds engine/boot.lua, so the binary
 * works when launched from anywhere (double-click, a file manager, another
 * cwd) and not only from the repo root. A no-op when cwd is already correct —
 * explicit `cosmic <project>` runs from the repo root are unchanged. Closes the
 * long-standing "windowed needs cwd=repo-root" debt, on both platforms. */
static void fixup_cwd(void) {
  SDL_PathInfo info;
  if (SDL_GetPathInfo("engine/boot.lua", &info)) return; /* already correct */
  const char *base = SDL_GetBasePath(); /* exe dir, trailing slash; don't free */
  if (!base || pal_chdir(base) != 0) return;
  if (SDL_GetPathInfo("engine/boot.lua", &info)) return; /* exe next to engine/ */
  if (pal_chdir("..") != 0) return; /* bin/ layout: repo root is one up; else
                                       boot_lua reports the missing engine/ */
}

int main(int argc, char **argv) {
  G.argc = argc;
  G.argv = argv;
  SDL_SetAppMetadata("cosmic2d", "0.0", "dev.cosmic2d");

  if (!SDL_Init(SDL_INIT_VIDEO)) {
    /* no display (CI/headless box): the offscreen driver still gives us
     * vulkan for the internal target */
    SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "offscreen");
    if (!SDL_Init(SDL_INIT_VIDEO)) {
      fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
      return 1;
    }
    pal_log("no display; using offscreen video driver");
  }

  fixup_cwd();

  if (!boot_lua()) {
    /* boot.lua sets exit_on_error before loading game code in capped runs;
     * the flag outlives the failed VM, so init-time crashes exit cleanly */
    if (G.exit_on_error) {
      pal_log("exit_on_error set; quitting with code 1");
      return 1;
    }
    G.error_state = true;
    if (!G.gfx_up) {
      /* nothing to show and nothing to watch yet: bail */
      fprintf(stderr, "fatal: boot failed before gfx/watches existed\n");
      return 1;
    }
  }

  while (!G.quit) {
    pump_events();
    if (G.error_state)
      error_frame();
    else
      tick_lua();
    if (G.reboot && !G.quit) {
      /* pal.x_reboot (D052): the parachute cycle on request — the VM goes,
       * named buffers + the window stay; boot.lua adopts what it finds */
      G.reboot = false;
      pal_log("lua vm reboot (requested)");
      lua_close(G.L);
      G.event_count = 0;
      if (!boot_lua()) G.error_state = true;
    }
  }

  if (G.L) lua_close(G.L);
  /* deliberately skip GPU/buffer teardown: the OS reclaims faster than we
   * can, and exit paths stay trivially correct */
  return G.exit_code;
}
