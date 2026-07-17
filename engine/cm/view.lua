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
-- ref/base_scale defaults are the classic 480x270@2x model; cm.main.boot
-- re-seeds them from the project's design res (D054/R7 — games can be
-- 960x540-family now, and the ladder's cap must be THEIR design res).
M.cfg = {
  base_scale = 2, -- default art zoom: a 960x540 window = a 480x270 FOV at 2x
  ref_w = 480,    -- target FOV / art reference; the ladder fills around it (D036)
  ref_h = 270,
  ui_scale = 2,   -- legacy cm.ui chrome scale, independent of game's (D036)
  editor_scale = 1, -- native editor canvas windows/content (machine-local)
  chrome_scale = 1, -- fixed native chrome: HUD, launcher, rewind tray
  access_auto = true,
}

M.ACCESS_SCALES = {
  0.75, 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3,
}
M.access_resolved = false

local function access_scale(s)
  if type(s) ~= "number" or s ~= s or s < 0.75 or s > 3 then return nil end
  local best, dist
  for _, candidate in ipairs(M.ACCESS_SCALES) do
    local d = math.abs(candidate - s)
    if not dist or d < dist then best, dist = candidate, d end
  end
  return best
end

-- Native imgui pixels need an accessibility default of their own: the game
-- ladder/ui canvas does not scale the editor overlay. SDL's display scale is
-- authoritative when configured; physical resolution is a conservative
-- fallback for unscaled 1440p/4K desktops (common on Linux).
function M.accessibility_default(dpi, w, h)
  dpi = type(dpi) == "number" and dpi > 0 and dpi or 1
  w, h = tonumber(w) or 1920, tonumber(h) or 1080
  local resolution = math.min(w / 1920, h / 1080)
  local wanted = math.max(1, dpi, resolution)
  wanted = math.floor(wanted * 4 + 0.5) / 4
  return math.max(1, math.min(3, wanted))
end

function M.resolve_accessibility(dpi, w, h, force)
  M.access_dpi, M.access_w, M.access_h = dpi, w, h
  if M.cfg.access_auto and (force or not M.access_resolved) then
    local s = M.accessibility_default(dpi, w, h)
    M.cfg.editor_scale, M.cfg.chrome_scale = s, s
    M.access_resolved = true
  end
  return M.cfg.editor_scale, M.cfg.chrome_scale
end

function M.set_editor_scale(s)
  s = access_scale(s)
  if not s then return nil, "invalid editor content scale" end
  M.cfg.editor_scale, M.cfg.access_auto = s, false
  M.access_resolved = true
  M.save_accessibility()
  return s
end

function M.set_chrome_scale(s)
  s = access_scale(s)
  if not s then return nil, "invalid fixed chrome scale" end
  M.cfg.chrome_scale, M.cfg.access_auto = s, false
  M.access_resolved = true
  M.save_accessibility()
  return s
end

local function step_scale(current, direction)
  current = access_scale(current) or 1
  local at = 1
  for i, s in ipairs(M.ACCESS_SCALES) do if s == current then at = i; break end end
  at = math.max(1, math.min(#M.ACCESS_SCALES, at + direction))
  return M.ACCESS_SCALES[at]
end

function M.step_editor_scale(direction)
  return M.set_editor_scale(step_scale(M.cfg.editor_scale, direction))
end

function M.step_chrome_scale(direction)
  return M.set_chrome_scale(step_scale(M.cfg.chrome_scale, direction))
end

function M.set_access_auto(on)
  M.cfg.access_auto = on ~= false
  M.access_resolved = false
  if M.cfg.access_auto then
    M.resolve_accessibility(M.access_dpi, M.access_w, M.access_h, true)
  end
  M.save_accessibility()
  return M.cfg.access_auto
end

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
-- Per-project window size / fullscreen / legacy ui scale persist in
-- <project>/video.dat (canonical bytes via cm.state, like the sandbox's
-- knobs.dat). Machine-local + render/dev ONLY: it is NOT doc-tree state (never a
-- sim input — D028/D036), so it is read only in interactive windowed sessions
-- and written only on a user change; headless / --frames / --verify / --win keep
-- the project's fixed FOV and never touch it (goldens, captures + determinism
-- stay byte-stable). Gitignored. The options menu (cm.options) routes all three
-- changes through here, so the mutation and the save live in one place. Native
-- editor accessibility is user-wide and has its separate store below.

-- `_video_path` is a selftest seam (like `_access_path` below); production
-- always derives from the booted project root.
local function video_path()
  if M._video_path then return M._video_path end
  local a = cm.main and cm.main.args
  return (a and a.project) and (a.project .. "/video.dat") or nil
end

-- video.dat contributors (A4/D085): video.dat is THE per-project machine-
-- local options store, and other modules own knobs that belong in it (the
-- volume knobs + project-declared options live in cm.options). A contributor
-- is { save = fn() -> flat table fragment, load = fn(t|nil) }: save fragments
-- merge into the canonical table; load runs on every load_video — with the
-- parsed table, or nil when the file is missing/unreadable — so adopting and
-- resetting-to-defaults are one path and a project switch never leaks knobs.
M._contrib = M._contrib or {}
function M.video_contrib(name, save, load)
  M._contrib[name] = { save = save, load = load }
end

local function contrib_load(t)
  for _, c in pairs(M._contrib) do c.load(t) end
end

-- Editor legibility is a user preference, not a project setting. Keep it in
-- the one PAL-provided per-user root so the picker and every project share it.
-- `_access_path` is a selftest seam; production always uses pal.user_path().
local function accessibility_path()
  if M._access_path then return M._access_path end
  if not pal.user_path then return nil, "PAL lacks per-user path support" end
  local root, err = pal.user_path()
  if not root then return nil, err end
  return root .. "editor.dat"
end

function M.save_accessibility()
  local path, path_err = accessibility_path()
  if not path then
    if path_err then pal.log("[display] save FAILED: " .. tostring(path_err)) end
    return nil, path_err
  end
  local t = { editor_scale = M.cfg.editor_scale,
              chrome_scale = M.cfg.chrome_scale,
              access_auto = M.cfg.access_auto,
              history_budget_mb = M.cfg.history_budget_mb }
  local ok, err = pal.write_file_atomic(path, cm.require("cm.state").canon(t),
                                        M._access_save_fail)
  if not ok then
    pal.log(("[display] save FAILED %s: %s"):format(path, tostring(err)))
  end
  return ok, err
end

function M.load_accessibility()
  M.access_resolved = false
  M.cfg.access_auto = true -- missing/old generations opt into safe auto
  M.cfg.editor_scale, M.cfg.chrome_scale = 1, 1
  local path, path_err = accessibility_path()
  if not path then
    if path_err then pal.log("[display] load FAILED: " .. tostring(path_err)) end
    return
  end
  local bytes = pal.read_file(path)
  if not bytes then return end
  local ok, t = pcall(cm.require("cm.state").parse, bytes)
  if not ok or type(t) ~= "table" then
    pal.log("[display] " .. tostring(path) .. " unreadable; using defaults")
    return
  end
  local editor_scale = access_scale(t.editor_scale)
  local chrome_scale = access_scale(t.chrome_scale)
  if editor_scale then M.cfg.editor_scale = editor_scale end
  if chrome_scale then M.cfg.chrome_scale = chrome_scale end
  if t.access_auto == false then
    M.cfg.access_auto = false
    M.access_resolved = true
  end
  local mb = M.budget_mb_ok(t.history_budget_mb)
  if mb then M.cfg.history_budget_mb = mb end
end

-- The rewind history disk budget (A7 retention surface) is machine-local editor
-- policy, exactly like the scaling above: it bounds total retained history in
-- MB and rides editor.dat so a chosen bound survives restart across every
-- project. nil == unset (cm.trace keeps its own default). Range: 16 MB .. 64 GB.
function M.budget_mb_ok(v)
  if type(v) ~= "number" or v ~= v then return nil end
  local mb = math.floor(v)
  if mb < 16 then mb = 16 elseif mb > 65536 then mb = 65536 end
  return mb
end

function M.set_history_budget(v)
  local mb = M.budget_mb_ok(v)
  if not mb then return nil, "invalid history budget" end
  M.cfg.history_budget_mb = mb
  M.save_accessibility()
  return mb
end

function M.save_video()
  local path = video_path()
  if not path then return end -- headless / before boot wired args: nothing to do
  local t = { ui_scale = M.cfg.ui_scale, fullscreen = M.fullscreen,
              win_w = M.win_w, win_h = M.win_h }
  for _, c in pairs(M._contrib) do
    for k, v in pairs(c.save() or {}) do t[k] = v end
  end
  local ok, err = pal.write_file_atomic(path, cm.require("cm.state").canon(t),
                                        M._save_fail)
  if not ok then
    pal.log(("[video] save FAILED %s: %s"):format(path, tostring(err)))
  end
  return ok, err
end

-- Windowed-size candidates for the options menu (A4/D085): sizes the ladder
-- FILLS with no letterbox — whole multiples of a FOV ≤ the project reference
-- (both the 16:9 reference itself and its 4:3-capped sibling, e.g. 480x270 →
-- 360x270; see M.ladder) — that actually FIT the given desktop. Pure: KAT'd
-- against fixed desktops. Scales start at 2 (1x of a 270-line game is a
-- stamp); when nothing at 2x+ fits the tiny display, 1x candidates step in,
-- and the smallest FOV at 1x is the unconditional floor. Largest 8 keep the
-- list menu-sized. nil/absent desktop (headless, no SDL display) → the
-- classic static four, unchanged from M8.6.
M.FALLBACK_SIZES = { { 720, 540 }, { 960, 540 }, { 1440, 1080 }, { 1920, 1080 } }

function M.size_candidates(dw, dh)
  local c = M.cfg
  local fovs = { { c.ref_w, c.ref_h } }
  local w43 = (c.ref_h * 4) // 3
  if w43 * 3 == c.ref_h * 4 and w43 < c.ref_w then
    fovs[#fovs + 1] = { w43, c.ref_h }
  end
  if type(dw) ~= "number" or type(dh) ~= "number" or dw < 1 or dh < 1 then
    local out = {}
    for i, s in ipairs(M.FALLBACK_SIZES) do out[i] = { s[1], s[2] } end
    return out
  end
  local out = {}
  local function collect(smin, smax)
    for s = smin, smax do
      for _, f in ipairs(fovs) do
        local w, h = f[1] * s, f[2] * s
        if w <= dw and h <= dh then out[#out + 1] = { w, h } end
      end
    end
  end
  collect(2, 12)
  if #out == 0 then collect(1, 1) end
  if #out == 0 then
    local f = fovs[#fovs] -- nothing fits at all: the smallest FOV at 1x
    out[1] = { f[1], f[2] }
  end
  table.sort(out, function(a, b)
    local aa, ba = a[1] * a[2], b[1] * b[2]
    if aa ~= ba then return aa < ba end
    return a[1] < b[1]
  end)
  while #out > 8 do table.remove(out, 1) end -- keep the LARGEST 8
  return out
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
  M.load_accessibility()
  local cw, ch = pal.x_window_size()
  if cw and cw > 0 then M.win_w, M.win_h = cw, ch end
  local path = video_path()
  local bytes = path and pal.read_file(path)
  if not bytes then
    contrib_load(nil)
    return
  end
  local ok, t = pcall(cm.require("cm.state").parse, bytes)
  if not ok or type(t) ~= "table" then
    pal.log("[video] " .. tostring(path) .. " unreadable; using defaults")
    contrib_load(nil)
    return
  end
  contrib_load(t)
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
    -- One exception (D054): the editor's game window may pick a FOV width
    -- in the supported 4:3..16:9 range (a horizontal resize walks it);
    -- apply it here so the target resizes BEFORE the game draws into it
    -- (the x_fov contract). Render-only, exactly like the ladder below.
    local f = M.canvas_fov
    if f then
      local gw, gh = pal.gfx_size()
      if f.w ~= gw or f.h ~= gh then pal.x_fov(f.w, f.h) end
    end
    local us = math.max(1, M.cfg.ui_scale)
    local uw, uh = math.ceil(W / us), math.ceil(H / us)
    pal.x_ui_target(uw, uh)
    M.ui_w, M.ui_h = uw, uh
    pal.x_compose { x = 0, y = 0, scale = 0, ui_scale = us }
    M.ui_active = true
    cm.require("cm.ui").ui_space = true
    return
  end

  -- The dev chrome ALWAYS rides a ui canvas at cfg.ui_scale — in play too
  -- (so the options menu / console / perf / scrub honor ui_scale). The game
  -- target composes UNDER it, centered full-window. (The F1 editor's chrome
  -- insets died with it at R8e — the canvas editor draws the game target
  -- itself through x_compose{scale=0}, the branch above.)
  local us = math.max(1, M.cfg.ui_scale)
  local uw, uh = math.ceil(W / us), math.ceil(H / us)
  pal.x_ui_target(uw, uh)
  M.ui_w, M.ui_h = uw, uh

  local fw, fh, gs = M.ladder(W, H)
  M.fov_w, M.fov_h, M.scale = fw, fh, gs
  pal.x_fov(fw, fh)
  local vx = (W - fw * gs) // 2 -- center the game in the window
  local vy = (H - fh * gs) // 2
  pal.x_compose { x = vx, y = vy, scale = gs, ui_scale = us }
  M.ui_active = true

  cm.require("cm.ui").ui_space = true -- dev panels hit-test in ui-canvas space
end

return M
