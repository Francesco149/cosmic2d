-- cm.text — bitmap text from the baked spleen atlases (D010). Glyphs are
-- white-on-transparent in one texture per font; pal.quad's vertex color
-- tints them, so any color is free. Render-only (no sim state).
--
-- Fonts: "5x8" (dense, debug HUDs) and "8x16" (readable, UI). Atlas
-- textures are created lazily after gfx init; on a VM reboot the cache
-- rebuilds and the old texture leaks — acceptable by the live-reload-leaks
-- pillar until the inspector can collect them.

local M = select(2, ...) or {}

local fonts = {} -- name -> {tex=, data=} (deliberately not on M: a VM
                 -- reboot must rebuild textures, stale ids are meaningless)

local function decode_atlas(data)
  local raw = data.bits:gsub("%x%x", function(h)
    return string.char(tonumber(h, 16))
  end)
  local px = {}
  local n = data.w * data.h
  for i = 0, n - 1 do
    local byte = raw:byte(1 + i // 8)
    if (byte >> (7 - i % 8)) & 1 == 1 then
      px[i + 1] = "\255\255\255\255"
    else
      px[i + 1] = "\0\0\0\0"
    end
  end
  return table.concat(px)
end

local function font(name)
  local f = fonts[name]
  if f then return f end
  local data = cm.require("cm.assets.font_" .. name)
  local tex = pal.tex_create(data.w, data.h, decode_atlas(data))
  f = { tex = tex, data = data }
  fonts[name] = f
  return f
end

-- draw str at x,y (top-left) in the given font ("5x8" default); supports \n.
-- Returns the y below the last line (handy for stacking HUD lines).
function M.draw(x, y, str, opts)
  opts = opts or {}
  local f = font(opts.font or "5x8")
  local d = f.data
  local r, g, b, a = opts.r or 1, opts.g or 1, opts.b or 1, opts.a or 1
  local cx, cy = x, y
  for i = 1, #str do
    local c = str:byte(i)
    if c == 10 then
      cx, cy = x, cy + d.gh
    else
      if c < d.first or c >= d.first + d.count then c = 63 end -- '?'
      local idx = c - d.first
      local sx = (idx % d.cols) * d.gw
      local sy = (idx // d.cols) * d.gh
      pal.quad(cx, cy, d.gw, d.gh, r, g, b, a, f.tex,
               sx / d.w, sy / d.h, (sx + d.gw) / d.w, (sy + d.gh) / d.h)
      cx = cx + d.gw
    end
  end
  return cy + d.gh
end

-- pixel width/height of a string in a font (multi-line aware)
function M.measure(str, fontname)
  local d = font(fontname or "5x8").data
  local w, line, lines = 0, 0, 1
  for i = 1, #str do
    if str:byte(i) == 10 then
      lines = lines + 1
      line = 0
    else
      line = line + 1
      if line > w then w = line end
    end
  end
  return w * d.gw, lines * d.gh
end

return M
