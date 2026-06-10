-- pt.gfx — engine drawing conveniences over the narrow pal surface:
-- camera with per-layer parallax multipliers, memoized PNG textures, and
-- sprite (sub-rect) drawing. All render-only; none of this is sim state.

local M = select(2, ...) or {}

local cam_x, cam_y = 0, 0
local textures = {} -- path -> {id=, w=, h=} (VM reboot rebuilds; old ids
                    -- leak by the live-reload-leaks pillar)

-- set the world camera for this frame (call before drawing layers)
function M.camera(x, y)
  cam_x, cam_y = x, y
end

-- activate a parallax layer: subsequent quads shift by camera * multiplier
-- (0 = screen-fixed UI, 1 = world, 0.5 = background at half speed)
function M.layer(mul_x, mul_y)
  mul_x = mul_x or 1
  pal.camera(cam_x * mul_x, cam_y * (mul_y or mul_x))
end

-- load (once) a PNG from the project/engine tree as a texture
function M.texture(path)
  local t = textures[path]
  if t then return t end
  local bytes, err = pal.read_file(path)
  if not bytes then error("pt.gfx.texture: " .. path .. ": " .. err, 2) end
  local pix, w, h = pal.png_read(bytes)
  if not pix then error("pt.gfx.texture: " .. path .. ": " .. w, 2) end
  t = { id = pal.tex_create(w, h, pix), w = w, h = h }
  textures[path] = t
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
