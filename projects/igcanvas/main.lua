-- projects/igcanvas — the living pal.x_ig_* reference (the R2 hello-canvas,
-- D049/docs/IMGUI.md), shaped like uigallery is for cm.ui: a teidraw-style
-- pan/zoom infinite canvas drawn ENTIRELY from Lua through the ig drawlist,
-- proving crisp text at any zoom (the dynamic font atlas), the hard edit
-- widget, and the live game target as a canvas image (x_ig_image(-1)).
--
-- Interaction: wheel = zoom at the cursor · left/middle-drag = pan ·
-- click into the code window = edit (imgui text editing) · alt+enter =
-- fullscreen (cm.view). All canvas state is render/dev (module-local, never
-- sim): the sim below stays the deterministic machine — its only state is
-- the frame counter driving the bouncing-pixels scene on the game target.
local M = select(2, ...) or {}

local state, ui, view

-- canvas camera + interaction state (render/dev; survives hot reload on M)
M.cam = M.cam or { x = -80, y = -110, zoom = 1.0 }
M.drag = M.drag or nil -- {wx, wy, cx, cy} while panning
M.code = M.code or table.concat({
  "-- code ed (pal.x_ig_edit): imgui text editing at an explicit rect —",
  "-- caret / selection / undo / IME for free; chrome is the canvas's.",
  "local function greet(who)",
  '  return ("hello, %s!"):format(who)',
  "end",
  "print(greet('cosmic2d'))",
  "",
  "-- zoom the canvas: this text rasterizes crisp at every size.",
}, "\n")

-- ---- the sim (deterministic; pixels for the live-game window) ----

function M.init()
  view = cm.require("cm.view")
  state = cm.require("cm.state")
  ui = cm.require("cm.ui")
  view.mode = "canvas" -- D049: no game blit; the canvas draws the target
end

function M.step() end -- the scene runs off the frame counter alone

local function draw_game_scene()
  pal.begin_frame(0.055, 0.05, 0.09, 1)
  local f = state.frame()
  local w, h = pal.gfx_size()
  for i = 1, 10 do
    local span = h - 26
    local ph = (f * (1 + i % 3) + i * 53) % (2 * span)
    local y = ph <= span and ph or 2 * span - ph
    local hue = i / 10
    pal.quad(16 + (i - 1) * (w - 48) / 9, 5 + y, 16, 16,
             0.4 + 0.6 * hue, 0.9 - 0.5 * hue, 0.55 + 0.3 * (1 - hue), 1)
  end
  pal.quad(0, h - 10, w, 10, 0.16, 0.13, 0.22, 1)
end

-- ---- the canvas (render/dev, ig drawlist) ----

local C = {
  bg = 0x141220ff, grid = 0x2a2740ff,
  win = 0x1e1b2ecc, win_edge = 0x4a4370ff, title = 0xcfc8ffff,
  body = 0x9a92c8ff, accent = 0x7fd8a8ff, arrow = 0x8878d0ff,
  hud = 0xE8E4FFff, hud_dim = 0x8a84b0ff, pill = 0x262238ee,
}

local function w2s(x, y) -- world -> screen (window px)
  local c = M.cam
  return (x - c.x) * c.zoom, (y - c.y) * c.zoom
end

local function s2w(x, y)
  local c = M.cam
  return x / c.zoom + c.x, y / c.zoom + c.y
end

-- a floating "window": rounded panel + title, in world coords
local function panel(wx, wy, ww, wh, title)
  local x, y = w2s(wx, wy)
  local z = M.cam.zoom
  local tpx = 15 * z
  pal.x_ig_rect_fill(x, y - tpx * 1.6, ww * z, wh * z + tpx * 1.6, C.win, 6 * z)
  pal.x_ig_rect(x, y - tpx * 1.6, ww * z, wh * z + tpx * 1.6, C.win_edge,
                math.max(1, z), 6 * z)
  pal.x_ig_text(x + 8 * z, y - tpx * 1.35, tpx, C.title, title, 0)
  return x, y, z
end

local function grid(igw, igh)
  local z = M.cam.zoom
  local step = 64
  local spx = step * z
  while spx < 24 do step = step * 4 spx = step * z end
  local x0, y0 = s2w(0, 0)
  local gx = (x0 // step) * step
  local gy = (y0 // step) * step
  local r = math.min(2, math.max(1, z))
  local wxn = igw / z + step
  local wyn = igh / z + step
  for i = 0, wxn // step do
    for j = 0, wyn // step do
      local sx, sy = w2s(gx + i * step, gy + j * step)
      pal.x_ig_circle_fill(sx, sy, r, C.grid)
    end
  end
end

local function interact(ig)
  local i = ui.inp
  -- wheel zoom at the cursor (imgui may want the mouse over the edit widget)
  if i.wheel ~= 0 and not ig.mouse then
    local wx, wy = s2w(i.wx, i.wy)
    local z = M.cam.zoom * (i.wheel > 0 and 1.15 ^ i.wheel or 1 / 1.15 ^ -i.wheel)
    z = math.max(0.05, math.min(24, z))
    M.cam.zoom = z
    M.cam.x = wx - i.wx / z -- keep the world point under the cursor
    M.cam.y = wy - i.wy / z
  end
  -- pan: left or middle drag on empty canvas (not over a widget)
  local down = i.buttons[1] or i.buttons[2]
  if down and not M.drag and not ig.mouse and (i.clicked[1] or i.clicked[2]) then
    M.drag = { wx = i.wx, wy = i.wy, cx = M.cam.x, cy = M.cam.y }
  end
  if M.drag then
    if down then
      M.cam.x = M.drag.cx - (i.wx - M.drag.wx) / M.cam.zoom
      M.cam.y = M.drag.cy - (i.wy - M.drag.wy) / M.cam.zoom
    else
      M.drag = nil
    end
  end
end

local function draw_canvas(ig)
  interact(ig)
  local z = M.cam.zoom
  pal.x_ig_rect_fill(0, 0, ig.w, ig.h, C.bg)
  grid(ig.w, ig.h)

  -- window 1: code ed (the hard widget)
  local x, y = panel(0, 0, 430, 240, "code ed — x_ig_edit")
  local px = math.max(4, 13.5 * z)
  local text, changed = pal.x_ig_edit {
    id = "demo_code", x = x + 6 * z, y = y + 4 * z,
    w = (430 - 12) * z, h = (240 - 10) * z,
    text = M.code, px = px, font = 1,
  }
  if changed then M.code = text end

  -- window 2: the live game, sampled straight off the internal target
  local gx, gy = panel(520, 0, 480, 270, "live game — x_ig_image(-1)")
  pal.x_ig_image(-1, gx, gy, 480 * z, 270 * z)

  -- window 3: type specimen — one string at many world sizes, all crisp;
  -- clipped to the panel (x_ig_clip_push), so the big lines don't spill
  local tx, ty = panel(0, 330, 430, 250, "text at any zoom")
  local sizes = { 8, 11, 15, 21, 30, 44, 64 }
  pal.x_ig_clip_push(tx, ty, 430 * z, 244 * z)
  local yy = ty + 6 * z
  for _, s in ipairs(sizes) do
    pal.x_ig_text(tx + 8 * z, yy, s * z, C.body,
                  ("the quick brown fox — %dpx"):format(s), 0)
    yy = yy + s * 1.25 * z
  end
  pal.x_ig_clip_pop()

  -- an arrow between windows, with a label riding it
  local ax0, ay0 = w2s(438, 120)
  local ax1, ay1 = w2s(512, 130)
  pal.x_ig_poly({ ax0, ay0, ax0 + 30 * z, ay0 + 4 * z, ax1 - 8 * z, ay1 },
                C.arrow, math.max(1, 2 * z))
  pal.x_ig_poly_fill({ ax1, ay1, ax1 - 12 * z, ay1 - 6 * z,
                       ax1 - 10 * z, ay1 + 6 * z }, C.arrow)
  pal.x_ig_text(ax0 + 6 * z, ay0 - 16 * z, 12 * z, C.accent, "renders live", 0)

  -- HUD (screen-space overlay layer: above everything, unaffected by zoom)
  pal.x_ig_overlay(true)
  pal.x_ig_rect_fill(10, 8, 620, 40, C.pill, 8)
  pal.x_ig_text(22, 14, 19, C.hud, "igcanvas — the pal.x_ig_* hello canvas", 0)
  pal.x_ig_text(22, 34, 10.5, C.hud_dim,
                "wheel = zoom at cursor · drag = pan · click the code to edit",
                0)
  local zoom_s = ("%d%%"):format(math.floor(z * 100 + 0.5))
  local zw = pal.x_ig_text_size(zoom_s, 16, 1)
  pal.x_ig_rect_fill(ig.w - zw - 34, 8, zw + 24, 26, C.pill, 8)
  pal.x_ig_text(ig.w - zw - 22, 13, 16, C.hud, zoom_s, 1)
  pal.x_ig_overlay(false)
end

function M.draw()
  draw_game_scene()
  local ig = pal.x_ig_frame()
  if ig then draw_canvas(ig) end
end

return M
