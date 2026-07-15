-- cm.gfx — engine drawing conveniences over the narrow pal surface:
-- camera with per-layer parallax multipliers, memoized PNG textures, and
-- sprite (sub-rect) drawing. All render-only; none of this is sim state.

local M = select(2, ...) or {}

local cam_x, cam_y = 0, 0
local snap = false -- pixel-snap the camera (M.pixel_snap) — off by default
local textures = {} -- path -> {id=, w=, h=} (VM reboot rebuilds; old ids
                    -- leak by the live-reload-leaks pillar)

-- set the world camera for this frame (call before drawing layers)
function M.camera(x, y)
  cam_x, cam_y = x, y
end

-- Pixel-snap the camera (opt-in, render-only). A smoothly-lerped camera lands
-- on fractional world/target pixels; because the internal target is 1:1 with
-- world px, a fractional camera makes every tile edge rasterize between pixels,
-- so as the view scrolls the edges CRAWL and adjacent tiles briefly leave a
-- 1px seam ("empty pixels rippling through the columns" — the human's report).
-- Snapping each layer's translation to a whole pixel pins the world grid to
-- the target grid → rock-stable, seam-free tiles (the standard pixel-art fix).
-- The player/entities keep their sub-pixel world positions (they move relative
-- to the snapped camera); only the camera quantizes. Off by default so the
-- goldens (smoke never snaps) stay byte-identical; the demo + shipped games
-- opt in.
function M.pixel_snap(on)
  snap = on ~= false
end

-- activate a parallax layer: subsequent quads shift by camera * multiplier
-- (0 = screen-fixed UI, 1 = world, 0.5 = background at half speed). With
-- pixel_snap on, the per-layer translation rounds to a whole pixel so each
-- layer (world AND every parallax depth) stays pixel-aligned independently.
function M.layer(mul_x, mul_y)
  mul_x = mul_x or 1
  local tx, ty = cam_x * mul_x, cam_y * (mul_y or mul_x)
  if snap then
    tx = tx >= 0 and (tx + 0.5) // 1 or -((-tx + 0.5) // 1)
    ty = ty >= 0 and (ty + 0.5) // 1 or -((-ty + 0.5) // 1)
  end
  pal.camera(tx, ty)
end

-- load (memoized by path) a PNG from the project/engine tree as a texture.
-- With reload=true (the live asset hot-reload path — a studio re-bake), re-read
-- the file and refresh the SAME {id,w,h} table in place so every holder updates;
-- the stale GPU texture is freed (SDL_GPU defers the release, so it's safe even
-- if it was sampled this frame — gfx.c) rather than leaked, since a session can
-- save many times and slots are finite. A re-read that fails keeps the current
-- texture instead of erroring. All render-only; none of this is sim state.
function M.texture(path, reload)
  local t = textures[path]
  if t and not reload then return t end
  local bytes, err = pal.read_file(path)
  if not bytes then
    if t then return t end -- reload of a now-missing file: keep what we have
    error("cm.gfx.texture: " .. path .. ": " .. err, 2)
  end
  local pix, w, h = pal.png_read(bytes)
  if not pix then
    if t then return t end -- reload of a now-corrupt file: keep what we have
    error("cm.gfx.texture: " .. path .. ": " .. w, 2)
  end
  local id = pal.tex_create(w, h, pix)
  if t then
    if t.id then pal.tex_free(t.id) end -- drop the stale GPU texture
    t.id, t.w, t.h = id, w, h
  else
    t = { id = id, w = w, h = h }
    textures[path] = t
  end
  return t
end

-- draw a sub-rect (sx,sy,sw,sh) of texture t at x,y, scaled to dw x dh
-- (defaults: whole texture, native size, white tint)
function M.sprite(t, x, y, o)
  o = o or {}
  local sx, sy = o.sx or 0, o.sy or 0
  local sw, sh = o.sw or t.w, o.sh or t.h
  pal.quad(x, y, o.dw or sw, o.dh or sh,
           o.r or 1, o.g or 1, o.b or 1, o.a or 1, t.id,
           sx / t.w, sy / t.h, (sx + sw) / t.w, (sy + sh) / t.h)
end

return M
