-- pix — tiny procedural pixel-art builder for placeholder assets.
-- Render-only: textures rebuild on every reload/reboot (old ids leak by the
-- live-reload pillar). Deterministic from constants, but NEVER from cm.rand:
-- module top-levels and game.init must not touch the sim PRNG stream.

local M = {}

-- a constant-seeded LCG for art noise (decorative variety, not sim state)
function M.lcg(seed)
  local z = seed
  return function()
    z = (z * 1103515245 + 12345) & 0x7fffffff
    return z / 0x7fffffff
  end
end

local char = string.char

local function key(r, g, b, a)
  return char(
    math.floor(math.min(math.max(r, 0), 1) * 255 + 0.5),
    math.floor(math.min(math.max(g, 0), 1) * 255 + 0.5),
    math.floor(math.min(math.max(b, 0), 1) * 255 + 0.5),
    math.floor(math.min(math.max(a, 0), 1) * 255 + 0.5))
end

-- new w x h canvas, transparent; :px and :rect take colors in 0..1
function M.img(w, h)
  local px = {}
  for i = 1, w * h do px[i] = "\0\0\0\0" end
  local img = { w = w, h = h }
  function img.px(x, y, r, g, b, a)
    if x < 0 or x >= w or y < 0 or y >= h then return end
    px[y * w + x + 1] = key(r, g, b, a or 1)
  end
  function img.rect(x, y, rw, rh, r, g, b, a)
    for yy = y, y + rh - 1 do
      for xx = x, x + rw - 1 do img.px(xx, yy, r, g, b, a) end
    end
  end
  function img.tex()
    return { id = pal.tex_create(w, h, table.concat(px)), w = w, h = h }
  end
  return img
end

return M
