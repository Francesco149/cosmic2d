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
#include "imgui_stdlib.h"

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
  SDL_GPUTextureFormat fmt = SDL_GPU_TEXTUREFORMAT_INVALID;
  ImFont *fonts[2] = {nullptr, nullptr}; /* 0 = sans (Inter), 1 = mono (JBM) */
  uint64_t frame_no = 0;
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
  IG.inited = true;
  pal_log("ig: imgui %s up (%s, fmt %d)", IMGUI_VERSION,
          IG.windowed ? "windowed" : "capture", (int)IG.fmt);
  return true;
}

extern "C" bool pal_ig_forward_events(void) {
  return IG.inited && IG.windowed;
}

extern "C" void pal_ig_sdl_event(const SDL_Event *e) {
  if (pal_ig_forward_events()) ImGui_ImplSDL3_ProcessEvent(e);
}

extern "C" void pal_ig_render_prepare(SDL_GPUCommandBuffer *cmd) {
  if (IG.state != 1) return;
  ImGui::Render();
  IG.state = 2;
  ImDrawData *dd = ImGui::GetDrawData();
  if (dd) ImGui_ImplSDLGPU3_PrepareDrawData(dd, cmd);
}

extern "C" void pal_ig_render_draw(SDL_GPUCommandBuffer *cmd,
                                   SDL_GPURenderPass *pass,
                                   SDL_GPUTextureFormat fmt) {
  if (IG.state != 2) return;
  IG.state = 0;
  if (fmt != IG.fmt) {
    /* pipeline was built for the init-time format; a mismatched destination
     * (live x_capture toggled mid-session) skips ig rather than misbind */
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

static int l_ig_overlay(lua_State *L) {
  IG.overlay = lua_toboolean(L, 1);
  return 0;
}

static int l_ig_line(lua_State *L) {
  if (!in_frame()) return 0;
  float x0 = (float)luaL_checknumber(L, 1), y0 = (float)luaL_checknumber(L, 2);
  float x1 = (float)luaL_checknumber(L, 3), y1 = (float)luaL_checknumber(L, 4);
  uint32_t c = (uint32_t)luaL_checkinteger(L, 5);
  float t = (float)luaL_optnumber(L, 6, 1.0);
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
  dl()->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), ig_col(c), r, 0, t);
  return 0;
}

static int l_ig_rect_fill(lua_State *L) {
  if (!in_frame()) return 0;
  float x = (float)luaL_checknumber(L, 1), y = (float)luaL_checknumber(L, 2);
  float w = (float)luaL_checknumber(L, 3), h = (float)luaL_checknumber(L, 4);
  uint32_t c = (uint32_t)luaL_checkinteger(L, 5);
  float r = (float)luaL_optnumber(L, 6, 0.0);
  dl()->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), ig_col(c), r);
  return 0;
}

static int l_ig_circle(lua_State *L) {
  if (!in_frame()) return 0;
  float x = (float)luaL_checknumber(L, 1), y = (float)luaL_checknumber(L, 2);
  float r = (float)luaL_checknumber(L, 3);
  uint32_t c = (uint32_t)luaL_checkinteger(L, 4);
  float t = (float)luaL_optnumber(L, 5, 1.0);
  dl()->AddCircle(ImVec2(x, y), r, ig_col(c), 0, t);
  return 0;
}

static int l_ig_circle_fill(lua_State *L) {
  if (!in_frame()) return 0;
  float x = (float)luaL_checknumber(L, 1), y = (float)luaL_checknumber(L, 2);
  float r = (float)luaL_checknumber(L, 3);
  uint32_t c = (uint32_t)luaL_checkinteger(L, 4);
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
  dl()->AddPolyline(pts.data(), (int)pts.size(), ig_col(c),
                    closed ? ImDrawFlags_Closed : ImDrawFlags_None, t);
  return 0;
}

static int l_ig_poly_fill(lua_State *L) {
  if (!in_frame()) return 0;
  std::vector<ImVec2> pts;
  if (ig_read_pts(L, 1, pts) < 3) return 0;
  uint32_t c = (uint32_t)luaL_checkinteger(L, 2);
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
  dl()->AddImage((ImTextureID)(intptr_t)t, ImVec2(x, y), ImVec2(x + w, y + h),
                 ImVec2(u0, v0), ImVec2(u1, v1), ig_col(c));
  return 0;
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

/* pal.x_ig_edit{id,x,y,w,h,text,px[,font,readonly,multiline]}
 *   -> text, changed, active   (nil when no ig frame is open)
 * The hard widget (IMGUI.md §2): imgui text editing at an explicit rect. The
 * host keeps a per-id buffer; the passed `text` re-syncs it whenever the
 * widget is NOT active (external reload wins over a stale buffer). Chrome is
 * the caller's: the widget renders bare (transparent window + frame). */
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
  lua_getfield(L, 1, "text");
  size_t tlen = 0;
  const char *text = lua_tolstring(L, -1, &tlen);
  /* the strings stay valid after the pop: the arg table still references
   * them (Lua strings are immutable; the pointer lives as long as they do) */
  lua_pop(L, 10);
  if (w < 8) w = 8;
  if (h < 8) h = 8;
  if (px <= 0) px = 16;
  if (px > IG_MAX_GLYPH_PX) px = IG_MAX_GLYPH_PX; /* widgets raster 1:1 */

  IgEdit &eb = g_edits[id];
  eb.used = IG.frame_no;
  if (!eb.active && text) eb.text.assign(text, tlen);

  ImGui::SetNextWindowPos(ImVec2(x, y));
  ImGui::SetNextWindowSize(ImVec2(w, h));
  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
  ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
  ImGui::PushStyleColor(ImGuiCol_FrameBg, 0);
  char wname[160];
  SDL_snprintf(wname, sizeof wname, "##ed_%s", id);
  ImGuiWindowFlags wf = ImGuiWindowFlags_NoDecoration |
                        ImGuiWindowFlags_NoSavedSettings |
                        ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoNav |
                        ImGuiWindowFlags_NoBackground |
                        ImGuiWindowFlags_NoFocusOnAppearing;
  bool changed = false;
  ImGui::Begin(wname, nullptr, wf);
  ImGui::PushFont(f, px);
  ImGuiInputTextFlags tf =
      ImGuiInputTextFlags_AllowTabInput |
      (readonly ? ImGuiInputTextFlags_ReadOnly : (ImGuiInputTextFlags)0);
  if (multiline)
    changed = ImGui::InputTextMultiline("##t", &eb.text,
                                        ImVec2(-FLT_MIN, -FLT_MIN), tf);
  else {
    ImGui::SetNextItemWidth(-FLT_MIN);
    changed = ImGui::InputText("##t", &eb.text, tf);
  }
  eb.active = ImGui::IsItemActive();
  ImGui::PopFont();
  ImGui::End();
  ImGui::PopStyleColor(1);
  ImGui::PopStyleVar(2);

  lua_pushlstring(L, eb.text.data(), eb.text.size());
  lua_pushboolean(L, changed);
  lua_pushboolean(L, eb.active);
  return 3;
}

static const luaL_Reg ig_funcs[] = {{"x_ig_frame", l_ig_frame},
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
                                    {nullptr, nullptr}};

extern "C" void pal_ig_lua_register(lua_State *L) {
  luaL_setfuncs(L, ig_funcs, 0);
}
