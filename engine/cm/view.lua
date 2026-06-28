-- cm.view — the viewport policy (D036). Maps the live window size to a game
-- FOV + integer scale via the resize ladder, and applies it through the PAL's
-- additive viewport surface (pal.x_fov / x_compose, api5).
--
-- Render/dev ONLY. This is never sim state: the sim must not read window / FOV
-- / viewport (D036 iron rule), so nothing here is recorded or snapshotted.
-- It runs only in live windowed sessions; headless / verify keep the project's
-- fixed FOV, so the golden suite + determinism are untouched.
local M = {}

-- Live-tunable knobs. Deliberately NOT in doc.knobs (that is sim state, D028).
-- The options menu (M8.6) mutates these; persistence lands with it.
M.cfg = {
  base_scale = 2, -- default art zoom: a 960x540 window = a 480x270 FOV at 2x
  ref_w = 480,    -- the FOV cap / art reference resolution (D036)
  ref_h = 270,
  ui_scale = 2,   -- editor chrome scale, independent of the game's (D036)
}

M.enabled = false -- true only for live windowed sessions
-- last applied layout (for the HUD / options menu / debugging)
M.scale, M.fov_w, M.fov_h = M.cfg.base_scale, M.cfg.ref_w, M.cfg.ref_h
-- ui-layer state: true while the editor owns a separate ui canvas (the
-- two-target composite); ui_w/ui_h is that canvas size.
M.ui_active = false
M.ui_w, M.ui_h = M.cfg.ref_w, M.cfg.ref_h

function M.set_enabled(on) M.enabled = on and true or false end

-- The surface the dev UI lays out + hit-tests against: the ui canvas when the
-- editor owns the chrome (two-target composite), else the game FOV (the dev
-- panels overlay the full-window game in play mode). Dev modules call this in
-- place of pal.gfx_size() so one switch re-homes all of them (D036).
function M.surface_size()
  if M.ui_active then return M.ui_w, M.ui_h end
  return pal.gfx_size()
end

-- The resize ladder (D036). Widening the window widens the FOV up to the cap;
-- below the cap the FOV crops at the base scale, above it the game upscales by
-- whole multiples. One formula reproduces every rung the human specified
-- (960x540->480x270@2x, 1920x1080->480x270@4x, 720x540->360x270@2x 4:3 crop,
-- 640x360->320x180@2x and 480x360->240x180@2x, the smallest, cropped both ways):
--   scale = max(base, min(floor(W/ref_w), floor(H/ref_h)))
--   FOV   = min(ref_w, floor(W/scale)) x min(ref_h, floor(H/scale))
function M.ladder(W, H)
  local c = M.cfg
  local scale = math.max(c.base_scale, math.min(W // c.ref_w, H // c.ref_h))
  if scale < 1 then scale = 1 end
  local fw = math.min(c.ref_w, W // scale)
  local fh = math.min(c.ref_h, H // scale)
  if fw < 1 then fw = 1 end
  if fh < 1 then fh = 1 end
  return fw, fh, scale
end

-- Called each live frame before the draw: recompute + apply the layout.
--   play mode  — the game fills the window (PAL auto-letterboxes the FOV); no
--                ui layer, so dev panels overlay the full-window game.
--   editor on  — the two-target composite (D036): the editor chrome draws on a
--                ui canvas at cfg.ui_scale, the game is inset into the leftover
--                central rect (window minus the toolbar/inspector) at its own
--                integer scale. x_fov / x_ui_target no-op when unchanged.
function M.update()
  if not M.enabled then return end
  local W, H = pal.x_window_size()
  if W < 1 or H < 1 then return end

  local ed = cm.require("cm.editor")
  local editor_on = ed and ed.on and not ed.locked()

  if editor_on then
    local us = math.max(1, M.cfg.ui_scale)
    local uw, uh = math.ceil(W / us), math.ceil(H / us)
    pal.x_ui_target(uw, uh)
    M.ui_w, M.ui_h = uw, uh
    -- chrome insets (window px): the editor owns the sizes (ui-canvas px) — the
    -- toolbar across the top, the inspector down the right when shown.
    local top = ed.TB_H * us
    local right = (ed.show_insp and ed.IW or 0) * us
    local aw = math.max(1, W - right)
    local ah = math.max(1, H - top)
    local fw, fh, gs = M.ladder(aw, ah)
    M.fov_w, M.fov_h, M.scale = fw, fh, gs
    pal.x_fov(fw, fh)
    -- center the game in the available rect
    local vx = (aw - fw * gs) // 2
    local vy = top + (ah - fh * gs) // 2
    pal.x_compose { x = vx, y = vy, scale = gs, ui_scale = us }
    M.ui_active = true
  else
    pal.x_ui_target(0, 0) -- free the canvas: no ui layer in play mode
    local fw, fh, gs = M.ladder(W, H)
    M.fov_w, M.fov_h, M.scale = fw, fh, gs
    pal.x_fov(fw, fh)
    pal.x_compose()
    M.ui_active = false
  end

  cm.require("cm.ui").ui_space = M.ui_active -- panels hit-test in this space
end

return M
