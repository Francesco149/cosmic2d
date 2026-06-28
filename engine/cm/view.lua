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
}

M.enabled = false -- true only for live windowed sessions
-- last applied layout (for the HUD / options menu / debugging)
M.scale, M.fov_w, M.fov_h = M.cfg.base_scale, M.cfg.ref_w, M.cfg.ref_h

function M.set_enabled(on) M.enabled = on and true or false end

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

-- Called each live frame before the draw: recompute + apply the FOV. The game
-- fills the window centered (the PAL auto-letterboxes the FOV at its integer
-- scale); the editor UI layer arrives in M8.4. x_fov no-ops when the size is
-- unchanged, so this is cheap to call every frame.
function M.update()
  if not M.enabled then return end
  local W, H = pal.x_window_size()
  if W < 1 or H < 1 then return end
  local fw, fh, scale = M.ladder(W, H)
  M.fov_w, M.fov_h, M.scale = fw, fh, scale
  pal.x_fov(fw, fh)
  pal.x_compose() -- no ui layer yet: auto-letterbox the FOV (M8.4 adds the ui)
end

return M
