/* main.c — PAL entry: owns the process loop and the Lua VM lifecycle.
 * Everything interesting happens in Lua (engine/boot.lua); the C loop only
 * pumps events, pcalls pt_tick(), and parachutes on errors by watching for
 * file changes and rebooting the VM (named buffers survive — see pal.h). */
#include "pal.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "lauxlib.h"
#include "lualib.h"

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
  lua_getglobal(G.L, "pt_tick");
  if (!lua_isfunction(G.L, -1)) {
    enter_error_state("engine/boot.lua did not define global pt_tick()");
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

static void push_event(PalEvent e) {
  if (G.event_count < PAL_MAX_EVENTS) G.events[G.event_count++] = e;
}

static void window_to_internal(float wx, float wy, float *ix, float *iy) {
  *ix = (wx - G.lay_ox) / G.lay_s;
  *iy = (wy - G.lay_oy) / G.lay_s;
}

static void pump_events(void) {
  SDL_Event e;
  while (SDL_PollEvent(&e)) {
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
      window_to_internal(e.motion.x, e.motion.y, &ev.x, &ev.y);
      push_event(ev);
      break;
    }
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP: {
      PalEvent ev = {.type = PAL_EV_BUTTON,
                     .a = e.button.button,
                     .down = e.type == SDL_EVENT_MOUSE_BUTTON_DOWN};
      window_to_internal(e.button.x, e.button.y, &ev.x, &ev.y);
      push_event(ev);
      break;
    }
    case SDL_EVENT_MOUSE_WHEEL:
      push_event(
          (PalEvent){.type = PAL_EV_WHEEL, .x = e.wheel.x, .y = e.wheel.y});
      break;
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

int main(int argc, char **argv) {
  G.argc = argc;
  G.argv = argv;
  SDL_SetAppMetadata("pettan2d", "0.0", "dev.pettan2d");

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
  }

  if (G.L) lua_close(G.L);
  /* deliberately skip GPU/buffer teardown: the OS reclaims faster than we
   * can, and exit paths stay trivially correct */
  return G.exit_code;
}
