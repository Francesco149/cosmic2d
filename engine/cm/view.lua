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
-- The options menu (M8.6) mutates these; they persist via save_video/load_video.
M.cfg = {
  base_scale = 2, -- default art zoom: a 960x540 window = a 480x270 FOV at 2x
  ref_w = 480,    -- target FOV / art reference; the ladder fills around it (D036)
  ref_h = 270,
  ui_scale = 2,   -- editor chrome scale, independent of the game's (D036)
}

M.enabled = false -- true only for live windowed sessions
-- nil = the classic play/editor-chrome model (the ladder below). "canvas" =
-- an ig-canvas editor session (D049/R2): the game target is NOT blitted by
-- the composite (the canvas draws it via pal.x_ig_image(-1)); the ui canvas
-- stays up so the legacy dev chrome keeps working (it renders UNDER the ig
-- layer — acceptable until R3/R4 re-host it). Cartridges/the editor shell
-- set this in init (render/dev state, never sim).
M.mode = M.mode or nil
-- last applied layout (for the HUD / options menu / debugging)
M.scale, M.fov_w, M.fov_h = M.cfg.base_scale, M.cfg.ref_w, M.cfg.ref_h
-- ui-layer state: true while the editor owns a separate ui canvas (the
-- two-target composite); ui_w/ui_h is that canvas size.
M.ui_active = false
M.ui_w, M.ui_h = M.cfg.ref_w, M.cfg.ref_h
M.fullscreen = M.fullscreen or false -- borderless desktop (alt+enter / options)
M.alt_down = false                   -- modifier tracking for the alt+enter combo
-- last WINDOWED size (px): update() keeps it current every windowed frame (so a
-- drag-resize is remembered too); it's what we restore on leaving fullscreen and
-- save to video.dat. x_window_size() reports the SCREEN while fullscreen, so we
-- can't requery it then — hence we track it continuously.
M.win_w = M.win_w or M.cfg.ref_w * M.cfg.base_scale
M.win_h = M.win_h or M.cfg.ref_h * M.cfg.base_scale
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
  M.save_video() -- persist the choice (no-op headless / pre-boot)
end

-- ---- the options menu's persisted choices (M8.6 follow-up) ----
-- Window size / fullscreen / ui scale persist across launches in
-- <project>/video.dat (canonical bytes via cm.state, like the sandbox's
-- knobs.dat). Machine-local + render/dev ONLY: it is NOT doc-tree state (never a
-- sim input — D028/D036), so it is read only in interactive windowed sessions
-- and written only on a user change; headless / --frames / --verify / --win keep
-- the project's fixed FOV and never touch it (goldens, captures + determinism
-- stay byte-stable). Gitignored. The options menu (cm.options) routes all three
-- changes through here, so the mutation and the save live in one place.

local function video_path()
  local a = cm.main and cm.main.args
  return (a and a.project) and (a.project .. "/video.dat") or nil
end

function M.save_video()
  local path = video_path()
  if not path then return end -- headless / before boot wired args: nothing to do
  local t = { ui_scale = M.cfg.ui_scale, fullscreen = M.fullscreen,
              win_w = M.win_w, win_h = M.win_h }
  pal.write_file(path, cm.require("cm.state").canon(t))
end

-- pick a windowed preset (the options menu): leave fullscreen first — SDL
-- ignores SetWindowSize in fullscreen — then apply, remember, persist.
function M.set_window_size(w, h)
  if M.fullscreen then
    M.fullscreen = false
    pal.x_set_fullscreen(false)
  end
  M.win_w, M.win_h = w, h
  pal.x_set_window_size(w, h)
  M.save_video()
end

function M.set_ui_scale(s)
  M.cfg.ui_scale = s
  M.save_video()
end

-- boot (interactive windowed sessions only): adopt the saved choices before the
-- first frame. Seeds the windowed-size baseline from the live window, then lays
-- the file over it. Unreadable / absent file → silently keep the defaults.
function M.load_video()
  local cw, ch = pal.x_window_size()
  if cw and cw > 0 then M.win_w, M.win_h = cw, ch end
  local path = video_path()
  local bytes = path and pal.read_file(path)
  if not bytes then return end
  local ok, t = pcall(cm.require("cm.state").parse, bytes)
  if not ok or type(t) ~= "table" then
    pal.log("[video] " .. tostring(path) .. " unreadable; using defaults")
    return
  end
  if type(t.ui_scale) == "number" and t.ui_scale >= 1 and t.ui_scale <= 8 then
    M.cfg.ui_scale = t.ui_scale
  end
  if type(t.win_w) == "number" and type(t.win_h) == "number" then
    M.win_w, M.win_h = t.win_w, t.win_h
  end
  if t.fullscreen then
    M.fullscreen = true
    pal.x_set_fullscreen(true)
  else
    pal.x_set_window_size(M.win_w, M.win_h)
  end
end

-- The surface the dev UI lays out + hit-tests against: the ui canvas when the
-- editor owns the chrome (two-target composite), else the game FOV (the dev
-- panels overlay the full-window game in play mode). Dev modules call this in
-- place of pal.gfx_size() so one switch re-homes all of them (D036).
function M.surface_size()
  if M.ui_active then return M.ui_w, M.ui_h end
  return pal.gfx_size()
end

-- The resize ladder (D036, refined by the human's feel-test 2026-06-28). One
-- formula for play AND editor:
--   scale = max(base, floor(W/ref_w), floor(H/ref_h))  -- max-of-fits: a bigger
--                                                         window raises the scale
--   FOV   = min(ref_w, W//scale) x min(ref_h, H//scale) -- hard-capped at the ref
-- Max-of-fits FILLS rather than dropping to a smaller scale with big letterbox
-- (the maximize complaint). The reference CAP is load-bearing: the sim camera
-- clamps to the design size and must not read the live FOV (determinism), so a
-- FOV taller/wider than 480x270 would render past the camera's clamp and reveal
-- undesigned world — the "parallax bleed through the bottom" the human saw. With
-- the cap the render never exceeds what the sim planned, so it never bleeds.
-- Net: fills exactly when the window is ~a whole multiple of 480x270 (incl. a
-- maximized 16:9 screen, a few px under -> 480x260); thin letterbox / editor
-- margins otherwise. Rungs: 960x540->480x270@2x, 1920x1080->480x270@4x,
-- 1920x1040->480x260@4x (maximize fills), 1280x720->480x270@2x (capped),
-- 720x540->360x270@2x, 640x360->320x180@2x; editor avail 1548x994->480x270@3x.
function M.ladder(W, H)
  local c = M.cfg
  local scale = math.max(c.base_scale, W // c.ref_w, H // c.ref_h)
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
  -- track the live windowed size for persistence (a drag-resize too); while
  -- fullscreen W/H is the SCREEN, so leave the remembered windowed size alone.
  if not M.fullscreen then M.win_w, M.win_h = W, H end

  if M.mode == "canvas" then
    -- ig-canvas session: full-window imgui at native res on top; the game
    -- target keeps the project's fixed FOV (the canvas decides how to show
    -- it); scale=0 = no game blit. The ui canvas stays for the dev chrome.
    local us = math.max(1, M.cfg.ui_scale)
    local uw, uh = math.ceil(W / us), math.ceil(H / us)
    pal.x_ui_target(uw, uh)
    M.ui_w, M.ui_h = uw, uh
    pal.x_compose { x = 0, y = 0, scale = 0, ui_scale = us }
    M.ui_active = true
    cm.require("cm.ui").ui_space = true
    return
  end

  -- The dev chrome ALWAYS rides a ui canvas at cfg.ui_scale — in the editor AND
  -- in play (so the options menu / console / perf / scrub honor ui_scale with
  -- the editor closed too, not only when it's open). The game target composes
  -- UNDER it: inset into the central rect when the editor owns the chrome (the
  -- toolbar across the top + the inspector down the right), else centered
  -- full-window. So ui_scale rescales the dev UI live in either mode.
  local us = math.max(1, M.cfg.ui_scale)
  local uw, uh = math.ceil(W / us), math.ceil(H / us)
  pal.x_ui_target(uw, uh)
  M.ui_w, M.ui_h = uw, uh

  local ed = cm.require("cm.editor")
  local editor_on = ed and ed.on and not ed.locked()
  local top = editor_on and ed.TB_H * us or 0 -- chrome insets (window px)
  local right = editor_on and (ed.show_insp and ed.IW or 0) * us or 0
  local aw = math.max(1, W - right)
  local ah = math.max(1, H - top)
  local fw, fh, gs = M.ladder(aw, ah)
  M.fov_w, M.fov_h, M.scale = fw, fh, gs
  pal.x_fov(fw, fh)
  local vx = (aw - fw * gs) // 2 -- center the game in the available rect
  local vy = top + (ah - fh * gs) // 2
  pal.x_compose { x = vx, y = vy, scale = gs, ui_scale = us }
  M.ui_active = true

  cm.require("cm.ui").ui_space = true -- dev panels hit-test in ui-canvas space
end

return M
