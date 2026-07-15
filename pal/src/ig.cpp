/* ig.cpp — the Dear ImGui host (D049, docs/IMGUI.md): the PAL's one C++ TU.
 * Hosts the imgui context + SDL3/SDLGPU3 backends behind the C ABI in pal.h
 * and exposes the pal.x_ig_* Lua surface: a native-resolution drawlist, text
 * at any pixel size (the teidraw cap-and-scale trick, §4), and hard widgets
 * at explicit rects. ImGui windows/layout/styling are deliberately NOT
 * exposed — one UI philosophy (IMGUI.md §2).
 *
 * Class: render/dev, live windowed + --win capture sessions only. Nothing
 * here is sim-readable or recorded; plain headless / --verify never
 * initialize it (x_ig_frame returns nil, every other call is a no-op). */
#include "imgui.h"
#include "imgui_impl_sdl3.h"
#include "imgui_impl_sdlgpu3.h"
#include "imgui_internal.h" /* x_ig_edit state export (D051): GetInputTextState,
                               FindWindowByName, SetScrollY — pin-internal use,
                               re-checked on any imgui bump */
#include "imgui_stdlib.h"

#include <cstring>
#include <map>
#include <string>
#include <vector>

extern "C" {
#include "pal.h"

#include "lauxlib.h"
}

/* raster cap for dynamically sized text: glyphs rasterize at most this many
 * px (bounds the atlas); above it vertices scale up (teidraw's kMaxGlyphPx) */
static const float IG_MAX_GLYPH_PX = 320.0f;
/* per-id edit buffers unused for this many ig frames get pruned */
static const uint64_t IG_EDIT_TTL = 600;

struct IgEdit {
  std::string text;
  bool active = false;
  uint64_t used = 0;
};

static struct {
  bool inited = false, failed = false, windowed = false;
  int state = 0; /* 0 idle | 1 frame open | 2 rendered (draw data ready) */
  bool overlay = false; /* drawlist target: background (default) | foreground */
  bool fmt_warned = false;
  bool mouse_on = true; /* x_ig_mouse: Lua gates mouse events off imgui while
                           the shell's ALT layer owns the pointer (the
                           IMGUI.md §11 filter-in-C fix — widgets render
                           normally but can never take the click) */
  SDL_GPUTextureFormat fmt = SDL_GPU_TEXTUREFORMAT_INVALID;
  ImFont *fonts[2] = {nullptr, nullptr}; /* 0 = sans (Inter), 1 = mono (JBM) */
  uint64_t frame_no = 0;
  /* pixel-art sampling (the human's ask, R8d round 3): images draw with a
   * NEAREST sampler — sprites/tiles/the game target must never blur under
   * the backend's bilinear default (seams between atlas tiles, soft 2x
   * game pixels). Fonts + AA shape fringes stay linear: the flags track
   * which sampler the tail of each drawlist currently wants (bg | fg), so
   * switch callbacks are only inserted at image<->shape/text transitions. */
  SDL_GPUSampler *nearest = nullptr;
  bool px_bg = false, px_fg = false;
} IG;

static std::map<std::string, IgEdit> g_edits;

/* ---------- host lifecycle ---------- */

static ImFont *load_font(ImGuiIO &io, const char *path, const char *what) {
  SDL_PathInfo info;
  if (!SDL_GetPathInfo(path, &info)) {
    pal_log("ig: %s font missing (%s); falling back", what, path);
    return nullptr;
  }
  ImFontConfig cfg;
  cfg.RasterizerMultiply = 1.35f; /* heavier coverage (teidraw's setting) */
  /* size 0 = no fixed size: the ≥1.92 dynamic atlas rasterizes on demand */
  return io.Fonts->AddFontFromFileTTF(path, 0.0f, &cfg);
}

static bool ig_ensure(void) {
  if (IG.inited) return true;
  if (IG.failed) return false;
  /* needs a surface to exist: a real window, or the --win capture target
   * (headless editor screenshots, IMGUI.md §3) */
  if (!G.gfx_up || (!G.win && !G.cap_on)) {
    IG.failed = true;
    pal_log("ig: unavailable (no window and no capture target)");
    return false;
  }
  IMGUI_CHECKVERSION();
  ImGui::CreateContext();
  ImGuiIO &io = ImGui::GetIO();
  io.IniFilename = nullptr; /* layout persistence is the engine's job (D049) */
  io.LogFilename = nullptr;
  IG.windowed = G.win != nullptr;
  IG.fmt = IG.windowed ? SDL_GetGPUSwapchainTextureFormat(G.dev, G.win)
                       : SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
  if (IG.windowed && !ImGui_ImplSDL3_InitForSDLGPU(G.win)) {
    pal_log("ig: ImGui_ImplSDL3_Init failed");
    ImGui::DestroyContext();
    IG.failed = true;
    return false;
  }
  ImGui_ImplSDLGPU3_InitInfo info;
  info.Device = G.dev;
  info.ColorTargetFormat = IG.fmt;
  info.MSAASamples = SDL_GPU_SAMPLECOUNT_1;
  if (!ImGui_ImplSDLGPU3_Init(&info)) {
    pal_log("ig: ImGui_ImplSDLGPU3_Init failed");
    if (IG.windowed) ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext();
    IG.failed = true;
    return false;
  }
  IG.fonts[0] = load_font(io, "pal/vendor/fonts/InterVariable.ttf", "sans");
  if (!IG.fonts[0]) IG.fonts[0] = io.Fonts->AddFontDefault();
  IG.fonts[1] =
      load_font(io, "pal/vendor/fonts/JetBrainsMono-Regular.ttf", "mono");
  if (!IG.fonts[1]) IG.fonts[1] = IG.fonts[0];
  {
    /* the image sampler: nearest, clamped — the backend's linear one is
     * right for fonts, wrong for pixel art (lives as long as G.dev) */
    SDL_GPUSamplerCreateInfo si = {};
    si.min_filter = SDL_GPU_FILTER_NEAREST;
    si.mag_filter = SDL_GPU_FILTER_NEAREST;
    si.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
    si.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    si.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    si.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    si.min_lod = -1000.0f;
    si.max_lod = 1000.0f;
    IG.nearest = SDL_CreateGPUSampler(G.dev, &si);
    if (!IG.nearest) pal_log("ig: nearest sampler failed (%s)", SDL_GetError());
  }
  IG.inited = true;
  pal_log("ig: imgui %s up (%s, fmt %d)", IMGUI_VERSION,
          IG.windowed ? "windowed" : "capture", (int)IG.fmt);
  return true;
}

extern "C" bool pal_ig_forward_events(void) {
  return IG.inited && IG.windowed;
}

extern "C" void pal_ig_sdl_event(const SDL_Event *e) {
  if (!pal_ig_forward_events()) return;
  if (!IG.mouse_on) {
    switch (e->type) {
    case SDL_EVENT_MOUSE_MOTION:
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP:
    case SDL_EVENT_MOUSE_WHEEL:
      return;
    default:
      break;
    }
  }
  ImGui_ImplSDL3_ProcessEvent(e);
}

/* sampler-switch draw callbacks: the SDLGPU3 backend consults
 * RenderState.SamplerCurrent per draw command and resets it to linear at
 * the start of every RenderDrawData (the ≥1.92.2 sanctioned hook). */
static void cb_sampler_nearest(const ImDrawList *, const ImDrawCmd *) {
  ImGui_ImplSDLGPU3_RenderState *rs =
      (ImGui_ImplSDLGPU3_RenderState *)ImGui::GetPlatformIO()
          .Renderer_RenderState;
  if (rs && IG.nearest) rs->SamplerCurrent = IG.nearest;
}

static void cb_sampler_default(const ImDrawList *, const ImDrawCmd *) {
  ImGui_ImplSDLGPU3_RenderState *rs =
      (ImGui_ImplSDLGPU3_RenderState *)ImGui::GetPlatformIO()
          .Renderer_RenderState;
  if (rs) rs->SamplerCurrent = rs->SamplerDefault;
}

extern "C" void pal_ig_render_prepare(SDL_GPUCommandBuffer *cmd) {
  if (IG.state != 1) return;
  /* a drawlist ending on the nearest sampler would leak it into the lists
   * that render after it (widget windows render between bg and fg) */
  if (IG.px_bg) {
    ImGui::GetBackgroundDrawList()->AddCallback(cb_sampler_default, nullptr);
    IG.px_bg = false;
  }
  if (IG.px_fg) {
    ImGui::GetForegroundDrawList()->AddCallback(cb_sampler_default, nullptr);
    IG.px_fg = false;
  }
  ImGui::Render();
  IG.state = 2;
  ImDrawData *dd = ImGui::GetDrawData();
  if (dd) ImGui_ImplSDLGPU3_PrepareDrawData(dd, cmd);
}

extern "C" void pal_ig_render_draw(SDL_GPUCommandBuffer *cmd,
                                   SDL_GPURenderPass *pass,
                                   SDL_GPUTextureFormat fmt, bool keep) {
  if (IG.state != 2) return;
  if (!keep) IG.state = 0;
  if (fmt != IG.fmt) {
    /* pipeline was built for the init-time format; a mismatched destination
     * skips ig rather than misbind (the live capture mirror allocates in
     * the swapchain's format exactly so this never fires for it) */
    if (!IG.fmt_warned) {
      IG.fmt_warned = true;
      pal_log("ig: target format %d != init format %d; skipping ig layer",
              (int)fmt, (int)IG.fmt);
    }
    return;
  }
  ImGui_ImplSDLGPU3_RenderDrawData(ImGui::GetDrawData(), cmd, pass);
}

/* ---------- Lua surface ---------- */

static ImDrawList *dl(void) {
  return IG.overlay ? ImGui::GetForegroundDrawList()
                    : ImGui::GetBackgroundDrawList();
}

/* lazily switch the CURRENT drawlist's tail sampler: images want nearest
 * (pixel art never blurs), everything else wants linear (glyph atlas +
 * the baked AA-line/fringe textures need it). One callback per
 * transition — a run of tile cells costs a single switch. */
static void want_px(bool on) {
  bool *f = IG.overlay ? &IG.px_fg : &IG.px_bg;
  if (*f == on) return;
  *f = on;
  dl()->AddCallback(on ? cb_sampler_nearest : cb_sampler_default, nullptr);
}

/* colors cross the boundary as 0xRRGGBBAA (imgui packs ABGR internally) */
static ImU32 ig_col(uint32_t rgba) {
  return IM_COL32((rgba >> 24) & 255, (rgba >> 16) & 255, (rgba >> 8) & 255,
                  rgba & 255);
}

static ImFont *ig_font(lua_State *L, int idx) {
  lua_Integer f = luaL_optinteger(L, idx, 0);
  return IG.fonts[f == 1 ? 1 : 0];
}

/* an open frame gates every drawlist/widget call: outside one they are safe
 * no-ops, which is also the whole headless/verify story (IMGUI.md §8) */
static bool in_frame(void) { return IG.state == 1; }

static int l_ig_frame(lua_State *L) {
  if (!ig_ensure()) {
    lua_pushnil(L);
    return 1;
  }
  if (IG.state == 1) ImGui::EndFrame(); /* orphan from an errored tick */
  ImGuiIO &io = ImGui::GetIO();
  if (IG.windowed) {
    ImGui_ImplSDLGPU3_NewFrame();
    ImGui_ImplSDL3_NewFrame();
  } else {
    /* capture mode: no platform backend — drive the io ourselves */
    io.DisplaySize = ImVec2((float)G.cap_w, (float)G.cap_h);
    io.DeltaTime = 1.0f / 60.0f;
    ImGui_ImplSDLGPU3_NewFrame();
  }
  ImGui::NewFrame();
  IG.state = 1;
  IG.overlay = false;
  IG.px_bg = IG.px_fg = false;
  IG.frame_no++;
  /* prune edit buffers whose widget vanished (window closed) */
  for (auto it = g_edits.begin(); it != g_edits.end();)
    it = (IG.frame_no - it->second.used > IG_EDIT_TTL) ? g_edits.erase(it)
                                                       : std::next(it);
  lua_createtable(L, 0, 6);
  lua_pushboolean(L, io.WantCaptureMouse);
  lua_setfield(L, -2, "mouse");
  lua_pushboolean(L, io.WantCaptureKeyboard);
  lua_setfield(L, -2, "kb");
  lua_pushboolean(L, io.WantTextInput);
  lua_setfield(L, -2, "text");
  float dpi = IG.windowed ? SDL_GetWindowDisplayScale(G.win) : 1.0f;
  lua_pushnumber(L, dpi > 0 ? dpi : 1.0f);
  lua_setfield(L, -2, "dpi");
  lua_pushnumber(L, io.DisplaySize.x);
  lua_setfield(L, -2, "w");
  lua_pushnumber(L, io.DisplaySize.y);
  lua_setfield(L, -2, "h");
  return 1;
}

/* pal.x_ig_mouse(on) — gate mouse input to imgui (default on). Off while
 * the editor shell's ALT layer owns the pointer: widgets keep rendering
 * (no visual change) but hover/click/wheel never reach them. On the
 * off-transition the pointer is parked off-screen and buttons released so
 * nothing sticks hovered or mid-drag. Safe any time (no-op before init). */
static int l_ig_mouse(lua_State *L) {
  bool on = lua_toboolean(L, 1);
  if (IG.inited && IG.mouse_on && !on) {
    ImGuiIO &io = ImGui::GetIO();
    io.AddMousePosEvent(-FLT_MAX, -FLT_MAX);
    for (int b = 0; b < 3; b++) io.AddMouseButtonEvent(b, false);
  }
  IG.mouse_on = on;
  return 0;
}

static int l_ig_overlay(lua_State *L) {
  IG.overlay = lua_toboolean(L, 1);
  return 0;
}

/* pal.x_ig_event(e) — feed one pal-shaped event table into the imgui io.
 * CAPTURE MODE ONLY: --win capture sessions have no platform backend, so
 * nothing feeds the io — a scripted proof driver that injects a synthetic
 * tape into pal.poll_events mirrors the same events here, and imgui
 * widgets (x_ig_edit fields) become tape-drivable like everything else.
 * Windowed sessions no-op (the SDL3 backend already forwards real events;
 * a second feed would double them). Mouse events honor the x_ig_mouse
 * gate exactly like pal_ig_sdl_event. Returns true when ingested. */
static ImGuiKey ig_key_from_scancode(int sc) {
  if (sc >= 4 && sc <= 29) return (ImGuiKey)(ImGuiKey_A + (sc - 4));
  if (sc >= 30 && sc <= 38) return (ImGuiKey)(ImGuiKey_1 + (sc - 30));
  switch (sc) {
  case 39: return ImGuiKey_0;
  case 40: return ImGuiKey_Enter;
  case 41: return ImGuiKey_Escape;
  case 42: return ImGuiKey_Backspace;
  case 43: return ImGuiKey_Tab;
  case 44: return ImGuiKey_Space;
  case 74: return ImGuiKey_Home;
  case 76: return ImGuiKey_Delete;
  case 77: return ImGuiKey_End;
  case 79: return ImGuiKey_RightArrow;
  case 80: return ImGuiKey_LeftArrow;
  case 81: return ImGuiKey_DownArrow;
  case 82: return ImGuiKey_UpArrow;
  case 224: case 228: return ImGuiMod_Ctrl;
  case 225: case 229: return ImGuiMod_Shift;
  case 226: case 230: return ImGuiMod_Alt;
  default: return ImGuiKey_None;
  }
}

static lua_Number ev_num(lua_State *L, const char *k, lua_Number def) {
  lua_getfield(L, 1, k);
  lua_Number v = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : def;
  lua_pop(L, 1);
  return v;
}

static int l_ig_event(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  if (!IG.inited || IG.windowed) {
    lua_pushboolean(L, false);
    return 1;
  }
  ImGuiIO &io = ImGui::GetIO();
  lua_getfield(L, 1, "type");
  const char *t = lua_tostring(L, -1);
  lua_pop(L, 1);
  bool ok = false;
  if (!t) {
    /* fall through: not an event table */
  } else if (strcmp(t, "motion") == 0) {
    if (IG.mouse_on)
      io.AddMousePosEvent((float)ev_num(L, "wx", -FLT_MAX),
                          (float)ev_num(L, "wy", -FLT_MAX));
    ok = true;
  } else if (strcmp(t, "button") == 0) {
    if (IG.mouse_on) {
      int b = (int)ev_num(L, "button", 0);
      int igb = b == 1 ? 0 : (b == 3 ? 1 : (b == 2 ? 2 : -1));
      lua_getfield(L, 1, "down");
      bool down = lua_toboolean(L, -1);
      lua_pop(L, 1);
      lua_getfield(L, 1, "wx"); /* position rides the click when present */
      bool has_pos = lua_isnumber(L, -1);
      lua_pop(L, 1);
      if (has_pos)
        io.AddMousePosEvent((float)ev_num(L, "wx", 0), (float)ev_num(L, "wy", 0));
      if (igb >= 0) io.AddMouseButtonEvent(igb, down);
    }
    ok = true;
  } else if (strcmp(t, "wheel") == 0) {
    if (IG.mouse_on)
      io.AddMouseWheelEvent((float)ev_num(L, "dx", 0), (float)ev_num(L, "dy", 0));
    ok = true;
  } else if (strcmp(t, "text") == 0) {
    lua_getfield(L, 1, "text");
    const char *s = lua_tostring(L, -1);
    if (s) io.AddInputCharactersUTF8(s);
    lua_pop(L, 1);
    ok = s != nullptr;
  } else if (strcmp(t, "key") == 0) {
    ImGuiKey k = ig_key_from_scancode((int)ev_num(L, "scancode", 0));
    lua_getfield(L, 1, "down");
    bool down = lua_toboolean(L, -1);
    lua_pop(L, 1);
    if (k != ImGuiKey_None) {
      io.AddKeyEvent(k, down);
      ok = true;
    }
  }
  lua_pushboolean(L, ok);
  return 1;
}

static int l_ig_line(lua_State *L) {
  if (!in_frame()) return 0;
  float x0 = (float)luaL_checknumber(L, 1), y0 = (float)luaL_checknumber(L, 2);
  float x1 = (float)luaL_checknumber(L, 3), y1 = (float)luaL_checknumber(L, 4);
  uint32_t c = (uint32_t)luaL_checkinteger(L, 5);
  float t = (float)luaL_optnumber(L, 6, 1.0);
  want_px(false);
  dl()->AddLine(ImVec2(x0, y0), ImVec2(x1, y1), ig_col(c), t);
  return 0;
}

static int l_ig_rect(lua_State *L) {
  if (!in_frame()) return 0;
  float x = (float)luaL_checknumber(L, 1), y = (float)luaL_checknumber(L, 2);
  float w = (float)luaL_checknumber(L, 3), h = (float)luaL_checknumber(L, 4);
  uint32_t c = (uint32_t)luaL_checkinteger(L, 5);
  float t = (float)luaL_optnumber(L, 6, 1.0);
  float r = (float)luaL_optnumber(L, 7, 0.0);
  want_px(false);
  dl()->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), ig_col(c), r, 0, t);
  return 0;
}

static int l_ig_rect_fill(lua_State *L) {
  if (!in_frame()) return 0;
  float x = (float)luaL_checknumber(L, 1), y = (float)luaL_checknumber(L, 2);
  float w = (float)luaL_checknumber(L, 3), h = (float)luaL_checknumber(L, 4);
  uint32_t c = (uint32_t)luaL_checkinteger(L, 5);
  float r = (float)luaL_optnumber(L, 6, 0.0);
  want_px(false);
  dl()->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), ig_col(c), r);
  return 0;
}

static int l_ig_circle(lua_State *L) {
  if (!in_frame()) return 0;
  float x = (float)luaL_checknumber(L, 1), y = (float)luaL_checknumber(L, 2);
  float r = (float)luaL_checknumber(L, 3);
  uint32_t c = (uint32_t)luaL_checkinteger(L, 4);
  float t = (float)luaL_optnumber(L, 5, 1.0);
  want_px(false);
  dl()->AddCircle(ImVec2(x, y), r, ig_col(c), 0, t);
  return 0;
}

static int l_ig_circle_fill(lua_State *L) {
  if (!in_frame()) return 0;
  float x = (float)luaL_checknumber(L, 1), y = (float)luaL_checknumber(L, 2);
  float r = (float)luaL_checknumber(L, 3);
  uint32_t c = (uint32_t)luaL_checkinteger(L, 4);
  want_px(false);
  dl()->AddCircleFilled(ImVec2(x, y), r, ig_col(c), 0);
  return 0;
}

/* pts = flat array {x1,y1,x2,y2,…} (window px) */
static int ig_read_pts(lua_State *L, int idx, std::vector<ImVec2> &out) {
  luaL_checktype(L, idx, LUA_TTABLE);
  lua_Integer n = luaL_len(L, idx);
  out.reserve((size_t)(n / 2));
  for (lua_Integer i = 1; i + 1 <= n; i += 2) {
    lua_rawgeti(L, idx, i);
    lua_rawgeti(L, idx, i + 1);
    out.push_back(
        ImVec2((float)lua_tonumber(L, -2), (float)lua_tonumber(L, -1)));
    lua_pop(L, 2);
  }
  return (int)out.size();
}

static int l_ig_poly(lua_State *L) {
  if (!in_frame()) return 0;
  std::vector<ImVec2> pts;
  if (ig_read_pts(L, 1, pts) < 2) return 0;
  uint32_t c = (uint32_t)luaL_checkinteger(L, 2);
  float t = (float)luaL_optnumber(L, 3, 1.0);
  bool closed = lua_toboolean(L, 4);
  want_px(false);
  dl()->AddPolyline(pts.data(), (int)pts.size(), ig_col(c),
                    closed ? ImDrawFlags_Closed : ImDrawFlags_None, t);
  return 0;
}

static int l_ig_poly_fill(lua_State *L) {
  if (!in_frame()) return 0;
  std::vector<ImVec2> pts;
  if (ig_read_pts(L, 1, pts) < 3) return 0;
  uint32_t c = (uint32_t)luaL_checkinteger(L, 2);
  want_px(false);
  dl()->AddConvexPolyFilled(pts.data(), (int)pts.size(), ig_col(c));
  return 0;
}

/* pal.x_ig_text(x, y, px, rgba, text [,font, wrap_w]) — text at ANY pixel
 * size: rasterize at min(px, cap), scale vertices for the rest (IMGUI.md §4)
 * so the atlas stays bounded while zoomed-in text stays smooth. */
static int l_ig_text(lua_State *L) {
  if (!in_frame()) return 0;
  float x = (float)luaL_checknumber(L, 1), y = (float)luaL_checknumber(L, 2);
  float px = (float)luaL_checknumber(L, 3);
  uint32_t c = (uint32_t)luaL_checkinteger(L, 4);
  size_t slen;
  const char *s = luaL_checklstring(L, 5, &slen);
  ImFont *f = ig_font(L, 6);
  float wrap = (float)luaL_optnumber(L, 7, 0.0);
  if (px <= 0.0f || slen == 0) return 0;
  want_px(false);
  ImDrawList *d = dl();
  if (px <= IG_MAX_GLYPH_PX) {
    d->AddText(f, px, ImVec2(x, y), ig_col(c), s, s + slen, wrap);
    return 0;
  }
  float k = px / IG_MAX_GLYPH_PX;
  int vtx0 = d->VtxBuffer.Size;
  d->AddText(f, IG_MAX_GLYPH_PX, ImVec2(0, 0), ig_col(c), s, s + slen,
             wrap > 0 ? wrap / k : 0.0f);
  for (int i = vtx0; i < d->VtxBuffer.Size; i++) {
    ImDrawVert &v = d->VtxBuffer[i];
    v.pos.x = v.pos.x * k + x;
    v.pos.y = v.pos.y * k + y;
  }
  return 0;
}

static int l_ig_text_size(lua_State *L) {
  if (!ig_ensure()) {
    lua_pushnil(L);
    return 1;
  }
  size_t slen;
  const char *s = luaL_checklstring(L, 1, &slen);
  float px = (float)luaL_checknumber(L, 2);
  ImFont *f = ig_font(L, 3);
  float wrap = (float)luaL_optnumber(L, 4, 0.0);
  if (px <= 0.0f) px = 1.0f;
  float rp = px <= IG_MAX_GLYPH_PX ? px : IG_MAX_GLYPH_PX;
  float k = px / rp;
  ImVec2 sz = f->CalcTextSizeA(rp, FLT_MAX, wrap > 0 ? wrap / k : 0.0f, s,
                               s + slen);
  lua_pushnumber(L, sz.x * k);
  lua_pushnumber(L, sz.y * k);
  return 2;
}

/* pal.x_ig_image(tex, x, y, w, h [,u0,v0,u1,v1, rgba]) — a PAL texture on the
 * drawlist; tex == -1 = the game internal target (the live-game preview). */
static int l_ig_image(lua_State *L) {
  if (!in_frame()) return 0;
  int tex = (int)luaL_checkinteger(L, 1);
  float x = (float)luaL_checknumber(L, 2), y = (float)luaL_checknumber(L, 3);
  float w = (float)luaL_checknumber(L, 4), h = (float)luaL_checknumber(L, 5);
  float u0 = (float)luaL_optnumber(L, 6, 0.0);
  float v0 = (float)luaL_optnumber(L, 7, 0.0);
  float u1 = (float)luaL_optnumber(L, 8, 1.0);
  float v1 = (float)luaL_optnumber(L, 9, 1.0);
  uint32_t c = (uint32_t)luaL_optinteger(L, 10, 0xffffffffu);
  SDL_GPUTexture *t;
  if (tex == -1) {
    t = G.target;
  } else {
    if (tex < 0 || tex >= PAL_MAX_TEX || !G.texs[tex].used) return 0;
    t = G.texs[tex].tex;
  }
  want_px(true);
  dl()->AddImage((ImTextureID)(intptr_t)t, ImVec2(x, y), ImVec2(x + w, y + h),
                 ImVec2(u0, v0), ImVec2(u1, v1), ig_col(c));
  return 0;
}

/* Batch: draw `count` textured quads of ONE texture in a SINGLE drawlist
 * command (one PrimReserve + N writes), instead of an AddImage call each.
 * Each quad is 8 floats in `quads`: x, y, w, h, u0, v0, u1, v1 (screen px +
 * uv); rgba tints them all. The map/tilemap editors render thousands of cells
 * per frame — per-cell AddImage was ~2.9 ms; this collapses the Lua↔C + imgui
 * per-call overhead. luabind.c marshals a pal.buf into this. */
extern "C" void pal_ig_image_quads(int tex, const float *quads, int count,
                                   uint32_t rgba) {
  if (!in_frame() || count <= 0 || !quads) return;
  SDL_GPUTexture *t;
  if (tex == -1) {
    t = G.target;
  } else {
    if (tex < 0 || tex >= PAL_MAX_TEX || !G.texs[tex].used) return;
    t = G.texs[tex].tex;
  }
  want_px(true);
  ImDrawList *d = dl();
  ImU32 col = ig_col(rgba);
  d->PushTexture((ImTextureID)(intptr_t)t);
  d->PrimReserve(6 * count, 4 * count);
  for (int i = 0; i < count; i++) {
    const float *q = quads + i * 8;
    d->PrimRectUV(ImVec2(q[0], q[1]), ImVec2(q[0] + q[2], q[1] + q[3]),
                  ImVec2(q[4], q[5]), ImVec2(q[6], q[7]), col);
  }
  d->PopTexture();
}

static int l_ig_clip_push(lua_State *L) {
  if (!in_frame()) return 0;
  float x = (float)luaL_checknumber(L, 1), y = (float)luaL_checknumber(L, 2);
  float w = (float)luaL_checknumber(L, 3), h = (float)luaL_checknumber(L, 4);
  dl()->PushClipRect(ImVec2(x, y), ImVec2(x + w, y + h), true);
  return 0;
}

static int l_ig_clip_pop(lua_State *L) {
  if (!in_frame()) return 0;
  dl()->PopClipRect();
  return 0;
}

/* pal.x_ig_edit{id,x,y,w,h,text,px[,font,readonly,multiline,
 *               ghost,enter,focus,set,scroll_x,scroll_y]}
 *   -> text, changed, active, state   (nil when no ig frame is open)
 * The hard widget (IMGUI.md §2): imgui text editing at an explicit rect. The
 * host keeps a per-id buffer; the passed `text` re-syncs it whenever the
 * widget is NOT active (external reload wins over a stale buffer). Chrome is
 * the caller's: the widget renders bare (transparent window + frame).
 *
 * The D051 ghost-widget split (EDITOR.md §12.1):
 *   ghost      — draw NO glyphs (transparent text; imgui's caret goes with
 *                it): the widget is a pure input machine and Lua draws every
 *                visible glyph on the drawlist (syntax color / gutter / its
 *                own caret). The selection highlight still renders.
 *   enter      — EnterReturnsTrue (state.submit; single-line submit rows)
 *   focus      — grab keyboard focus this frame
 *   set        — adopt `text` even while ACTIVE (history nav / undo while
 *                focused); deactivates first so imgui's copy can't win
 *   scroll_x/y — force the widget's scroll this frame (restore / link jump;
 *                applied next frame by imgui's scroll target). Omit to let
 *                the widget own scrolling (wheel, caret-follow).
 * state = {sx, sy, caret, sa, sb, submit}: scroll px (the multiline child's,
 * which persists while inactive), caret/selection BYTE offsets while active
 * (absent otherwise), and the enter flag. Reading these goes through imgui
 * internals (GetInputTextState + the 1.92 child-window name shape) — a
 * vendored-pin dependency, re-checked on any imgui bump. */
static int l_ig_edit(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  if (!in_frame()) {
    lua_pushnil(L);
    return 1;
  }
  lua_getfield(L, 1, "id");
  const char *id = lua_tostring(L, -1);
  if (!id) return luaL_error(L, "x_ig_edit: id is required");
  lua_getfield(L, 1, "x");
  float x = (float)lua_tonumber(L, -1);
  lua_getfield(L, 1, "y");
  float y = (float)lua_tonumber(L, -1);
  lua_getfield(L, 1, "w");
  float w = (float)lua_tonumber(L, -1);
  lua_getfield(L, 1, "h");
  float h = (float)lua_tonumber(L, -1);
  lua_getfield(L, 1, "px");
  float px = (float)lua_tonumber(L, -1);
  lua_getfield(L, 1, "font");
  ImFont *f = IG.fonts[lua_tointeger(L, -1) == 1 ? 1 : 0];
  lua_getfield(L, 1, "readonly");
  bool readonly = lua_toboolean(L, -1);
  lua_getfield(L, 1, "multiline");
  bool multiline = lua_isnil(L, -1) ? true : lua_toboolean(L, -1);
  lua_getfield(L, 1, "ghost");
  bool ghost = lua_toboolean(L, -1);
  lua_getfield(L, 1, "enter");
  bool enter = lua_toboolean(L, -1);
  lua_getfield(L, 1, "focus");
  bool want_focus = lua_toboolean(L, -1);
  lua_getfield(L, 1, "set");
  bool force_set = lua_toboolean(L, -1);
  lua_getfield(L, 1, "scroll_x");
  bool has_sx = lua_isnumber(L, -1);
  float set_sx = (float)lua_tonumber(L, -1);
  lua_getfield(L, 1, "scroll_y");
  bool has_sy = lua_isnumber(L, -1);
  float set_sy = (float)lua_tonumber(L, -1);
  lua_getfield(L, 1, "text");
  size_t tlen = 0;
  const char *text = lua_tolstring(L, -1, &tlen);
  /* the strings stay valid after the pop: the arg table still references
   * them (Lua strings are immutable; the pointer lives as long as they do) */
  lua_pop(L, 16);
  if (w < 8) w = 8;
  if (h < 8) h = 8;
  if (px <= 0) px = 16;
  if (px > IG_MAX_GLYPH_PX) px = IG_MAX_GLYPH_PX; /* widgets raster 1:1 */

  char wname[160];
  SDL_snprintf(wname, sizeof wname, "##ed_%s", id);

  IgEdit &eb = g_edits[id];
  eb.used = IG.frame_no;
  if (force_set && text && eb.active) {
    /* external overwrite of an active widget: deactivate first, so imgui's
     * internal copy can't write the old text back over ours */
    ImGuiWindow *host = ImGui::FindWindowByName(wname);
    if (host && ImGui::GetInputTextState(host->GetID("##t")))
      ImGui::ClearActiveID();
    eb.text.assign(text, tlen);
    if (!want_focus) want_focus = true; /* keep the editing flow alive */
  } else if ((!eb.active || force_set) && text) {
    eb.text.assign(text, tlen);
  }

  ImGui::SetNextWindowPos(ImVec2(x, y));
  ImGui::SetNextWindowSize(ImVec2(w, h));
  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
  ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
  ImGui::PushStyleColor(ImGuiCol_FrameBg, 0);
  if (ghost) ImGui::PushStyleColor(ImGuiCol_Text, 0);
  ImGuiWindowFlags wf = ImGuiWindowFlags_NoDecoration |
                        ImGuiWindowFlags_NoSavedSettings |
                        ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoNav |
                        ImGuiWindowFlags_NoBackground |
                        ImGuiWindowFlags_NoFocusOnAppearing;
  bool changed = false, submit = false;
  std::string before;
  if (enter) before = eb.text; /* enter conflates the return; diff for real */
  ImGui::Begin(wname, nullptr, wf);
  ImGui::PushFont(f, px);
  ImGuiInputTextFlags tf =
      ImGuiInputTextFlags_AllowTabInput |
      (readonly ? ImGuiInputTextFlags_ReadOnly : (ImGuiInputTextFlags)0) |
      (enter ? ImGuiInputTextFlags_EnterReturnsTrue : (ImGuiInputTextFlags)0);
  if (want_focus) ImGui::SetKeyboardFocusHere();
  bool ret;
  if (multiline)
    ret = ImGui::InputTextMultiline("##t", &eb.text,
                                    ImVec2(-FLT_MIN, -FLT_MIN), tf);
  else {
    ImGui::SetNextItemWidth(-FLT_MIN);
    ret = ImGui::InputText("##t", &eb.text, tf);
  }
  if (enter) {
    submit = ret;
    changed = eb.text != before;
  } else {
    changed = ret;
  }
  eb.active = ImGui::IsItemActive();

  /* state export (D051): caret/selection while active; scroll always */
  ImGuiID tid = ImGui::GetCurrentWindow()->GetID("##t");
  ImGuiInputTextState *st = ImGui::GetInputTextState(tid);
  float out_sx = 0.0f, out_sy = 0.0f;
  int caret = -1, sa = 0, sb = 0;
  if (st) {
    caret = st->GetCursorPos();
    sa = st->GetSelectionStart();
    sb = st->GetSelectionEnd();
    if (sa > sb) {
      int t = sa;
      sa = sb;
      sb = t;
    }
    if (has_sx) st->Scroll.x = set_sx;
    out_sx = st->Scroll.x;
  }
  if (multiline) {
    /* the child window InputTextEx begun for us: 1.92.4 names it
     * "<host>/<label>_%08X" — it persists while inactive and owns Scroll.y */
    char cname[224];
    SDL_snprintf(cname, sizeof cname, "%s/%s_%08X", wname, "##t",
                 (unsigned)tid);
    ImGuiWindow *child = ImGui::FindWindowByName(cname);
    if (child) {
      if (has_sy) ImGui::SetScrollY(child, set_sy);
      out_sy = child->Scroll.y;
    }
  }
  ImGui::PopFont();
  ImGui::End();
  if (ghost) ImGui::PopStyleColor(1);
  ImGui::PopStyleColor(1);
  ImGui::PopStyleVar(2);

  lua_pushlstring(L, eb.text.data(), eb.text.size());
  lua_pushboolean(L, changed);
  lua_pushboolean(L, eb.active);
  lua_createtable(L, 0, 6);
  lua_pushnumber(L, out_sx);
  lua_setfield(L, -2, "sx");
  lua_pushnumber(L, out_sy);
  lua_setfield(L, -2, "sy");
  if (caret >= 0) {
    lua_pushinteger(L, caret);
    lua_setfield(L, -2, "caret");
    lua_pushinteger(L, sa);
    lua_setfield(L, -2, "sa");
    lua_pushinteger(L, sb);
    lua_setfield(L, -2, "sb");
  }
  lua_pushboolean(L, submit);
  lua_setfield(L, -2, "submit");
  return 4;
}

static const luaL_Reg ig_funcs[] = {{"x_ig_frame", l_ig_frame},
                                    {"x_ig_mouse", l_ig_mouse},
                                    {"x_ig_overlay", l_ig_overlay},
                                    {"x_ig_line", l_ig_line},
                                    {"x_ig_rect", l_ig_rect},
                                    {"x_ig_rect_fill", l_ig_rect_fill},
                                    {"x_ig_circle", l_ig_circle},
                                    {"x_ig_circle_fill", l_ig_circle_fill},
                                    {"x_ig_poly", l_ig_poly},
                                    {"x_ig_poly_fill", l_ig_poly_fill},
                                    {"x_ig_text", l_ig_text},
                                    {"x_ig_text_size", l_ig_text_size},
                                    {"x_ig_image", l_ig_image},
                                    {"x_ig_clip_push", l_ig_clip_push},
                                    {"x_ig_clip_pop", l_ig_clip_pop},
                                    {"x_ig_edit", l_ig_edit},
                                    {"x_ig_event", l_ig_event},
                                    {nullptr, nullptr}};

extern "C" void pal_ig_lua_register(lua_State *L) {
  luaL_setfuncs(L, ig_funcs, 0);
}
