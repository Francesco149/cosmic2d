-- cm.options — the video/options menu (M8.6, D036). Sets resolution / UI scale
-- / fullscreen DIRECTLY, which the resize ladder can't cover: a borderless or
-- fullscreen window can't be drag-resized (human ask 2026-06-28). Toggled by
-- Esc; available in play AND editor.
--
-- Dev/render class: it drives only the viewport (cm.view + the PAL window
-- control), never sim state. It draws on whatever target is current — the ui
-- canvas when the editor owns it, else the full-window game — like the other
-- dev panels (cm.console/perf/scrub), and lays out against view.surface_size().
local M = select(2, ...) or {}

local ui = cm.require("cm.ui")
local view = cm.require("cm.view")

M.on = M.on or false
local KEY_ESC = 41
-- windowed presets (window px); the ladder maps each to a FOV + integer scale
local SIZES = { { 960, 540 }, { 1280, 720 }, { 1600, 900 }, { 1920, 1080 } }
local UI_SCALES = { 1, 2, 3 }

function M.toggle(on)
  if on == nil then
    M.on = not M.on
  else
    M.on = on == true or on == 1
  end
end

function M.frame()
  for _, k in ipairs(ui.inp.keys) do
    if k.down and not k.rep and k.scancode == KEY_ESC then M.toggle() end
  end
  if not M.on then return end
  ui.capture_mouse() -- clicks land on the menu, not the game/world beneath
  ui.capture_keys() -- ...and held keys don't drive the game behind the menu
                    -- (up-events still pass, so nothing sticks — see cm.ui)

  local st = ui.style
  local SW, SH = view.surface_size()
  local w, h = 184, 140
  local x, y = (SW - w) // 2, (SH - h) // 2
  ui.begin_panel("options", x, y, w, h, { title = "options" })

  local fs, fsc = ui.checkbox("fullscreen  (alt+enter)", view.fullscreen)
  if fsc then view.toggle_fullscreen(fs) end

  ui.label("window size", { color = st.text_dim })
  for r = 1, #SIZES, 2 do
    ui.row({ 1, 1 })
    for c = r, math.min(r + 1, #SIZES) do
      local s = SIZES[c]
      if ui.button(s[1] .. "x" .. s[2], { id = "sz" .. c }) then
        view.set_window_size(s[1], s[2]) -- leaves fullscreen + persists
      end
    end
  end

  ui.label("ui scale", { color = st.text_dim })
  ui.row({ 1, 1, 1 })
  for _, s in ipairs(UI_SCALES) do
    local on = view.cfg.ui_scale == s
    if ui.button(s .. "x", { id = "uis" .. s,
                             color = on and st.accent or st.text }) then
      view.set_ui_scale(s) -- persists
    end
  end

  if ui.button("close") then M.on = false end
  ui.separator() -- set the destructive action apart from "close"
  if ui.button("quit game", { color = st.error }) then
    M.on = false
    cm.main.request_quit() -- the only in-app exit when borderless-fullscreen
  end
  ui.end_panel()
end

return M
