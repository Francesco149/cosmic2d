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
  ref_w = 480,    -- target FOV / art reference; the ladder fills around it (D036)
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
M.fullscreen = M.fullscreen or false -- borderless desktop (alt+enter / options)
M.alt_down = false                   -- modifier tracking for the alt+enter combo
local ALT_L, ALT_R, KEY_ENTER = 226, 230, 40

function M.set_enabled(on) M.enabled = on and true or false end

-- Borderless desktop fullscreen toggle (alt+enter, or the options menu M8.6).
-- The window becomes the screen; the ladder then fills it like any other size.
function M.toggle_fullscreen(on)
  if on == nil then
    M.fullscreen = not M.fullscreen
  else
    M.fullscreen = on and true or false
  end
  pal.x_set_fullscreen(M.fullscreen)
end

-- The surface the dev UI lays out + hit-tests against: the ui canvas when the
-- editor owns the chrome (two-target composite), else the game FOV (the dev
-- panels overlay the full-window game in play mode). Dev modules call this in
-- place of pal.gfx_size() so one switch re-homes all of them (D036).
function M.surface_size()
  if M.ui_active then return M.ui_w, M.ui_h end
  return pal.gfx_size()
end

-- The resize ladder (D036, refined per the human's feel-test 2026-06-28). Two
-- modes:
--   fill (play, default) — pick the integer scale that keeps the FOV NEAR the
--     480x270 reference, then let the FOV FILL the window at that scale (slack
--     < scale px, no letterbox) instead of hard-capping + letterboxing (which
--     put a maximized window in big black bars). FOV maxes *softly* at the
--     reference: a bigger window raises the scale, not the FOV.
--       scale = max(base, floor(W/ref_w), floor(H/ref_h)); FOV = W//scale x H//scale
--   cap (editor preview) — the FOV is HARD-capped at the reference so the inset
--     shows exactly the play-mode view and never reveals world below/around the
--     level (the parallax bleed the human saw when a tall avail rect gave a
--     FOV > 270). Crops below the reference on a small rect; centers (margins)
--     within the avail rect on a large one.
--       scale = max(base, min(floor(W/ref_w), floor(H/ref_h)))
--       FOV   = min(ref_w, W//scale) x min(ref_h, H//scale)
-- fill rungs: 960x540->480x270@2x, 1920x1080->480x270@4x, 1920x1040->480x260@4x
-- (maximized: fills), 1280x720->640x360@2x, 720x540->360x270@2x, 640x360->320x180@2x.
-- cap rungs: 1548x994 (editor@1080p) ->480x270@3x; 588x514 (editor@960x600) ->294x257@2x.
function M.ladder(W, H, cap)
  local c = M.cfg
  local scale, fw, fh
  if cap then
    scale = math.max(c.base_scale, math.min(W // c.ref_w, H // c.ref_h))
    if scale < 1 then scale = 1 end
    fw = math.min(c.ref_w, W // scale)
    fh = math.min(c.ref_h, H // scale)
  else
    scale = math.max(c.base_scale, W // c.ref_w, H // c.ref_h)
    if scale < 1 then scale = 1 end
    fw = W // scale
    fh = H // scale
  end
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
  -- alt+enter toggles borderless fullscreen (live dev convenience; the options
  -- menu M8.6 also exposes it). Track Alt held across frames, fire on Enter-down.
  for _, k in ipairs(cm.require("cm.ui").inp.keys) do
    if k.scancode == ALT_L or k.scancode == ALT_R then M.alt_down = k.down end
    if k.down and not k.rep and k.scancode == KEY_ENTER and M.alt_down then
      M.toggle_fullscreen()
    end
  end
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
    -- cap the FOV at the reference: the inset previews the play view, never
    -- showing past the level's edges (the parallax bleed on a tall avail rect)
    local fw, fh, gs = M.ladder(aw, ah, true)
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
