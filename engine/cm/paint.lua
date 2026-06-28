-- cm.paint — pure pixel-art rasterizers over an RGBA8 cell (M10, the studio).
--
-- Determinism class: dev/render ONLY (D040). The studio is a render-only asset
-- tool — its pixels are never sim state, never recorded, never in --verify. So
-- these may use float math freely (sqrt/etc are dev-class here). They ARE pure
-- functions of their inputs, though, so selftest pins them with KATs (a line is
-- a line) — insurance against a flood-fill / Bresenham regression, not a
-- determinism requirement.
--
-- Every rasterizer is integer / nearest — NO anti-aliasing (STUDIO.md §5.1): a
-- pixel is fully set or untouched, never blended at an edge. "Curves" are clean
-- stair-step pixel lines. Float is allowed in the *test* for a shape (the
-- ellipse inside-test), never to produce a partially-covered edge pixel.
--
-- An "image" is { w, h, buf } where buf is a pal.buf holding w*h*4 bytes RGBA8,
-- a pixel at (x,y) at byte offset (y*w+x)*4 as a little-endian u32 — R the low
-- byte, matching pal.tex_create's RGBA byte order and pal.quad's color packing
-- (luabind color_arg). So a packed pixel uploads to a texture verbatim.

local M = select(2, ...) or {}

local floor, ceil, sqrt, abs = math.floor, math.ceil, math.sqrt, math.abs

-- ---- color packing (0..255 ints <-> RGBA8 u32) ----

function M.pack(r, g, b, a)
  return (r & 255) | ((g & 255) << 8) | ((b & 255) << 16) | (((a or 255) & 255) << 24)
end

function M.unpack(rgba)
  return rgba & 255, (rgba >> 8) & 255, (rgba >> 16) & 255, (rgba >> 24) & 255
end

M.CLEAR = 0 -- transparent (all-zero RGBA)

-- ---- images ----

-- a w*h RGBA8 image. Pass an existing buf (>= w*h*4 bytes) or get an anon one
-- (transparent: pal.buf zero-fills). Anon bufs are dev scratch — held alive by
-- the caller's reference, GC'd when dropped (never snapshot, per D040).
function M.image(w, h, buf)
  buf = buf or pal.buf(nil, w * h * 4)
  return { w = w, h = h, buf = buf }
end

function M.in_bounds(img, x, y)
  return x >= 0 and x < img.w and y >= 0 and y < img.h
end

function M.get(img, x, y)
  if x < 0 or x >= img.w or y < 0 or y >= img.h then return 0 end
  return img.buf:u32((y * img.w + x) * 4)
end

-- raw set (REPLACE — the pixel-art default: pencil overwrites, it does not
-- blend). Out of bounds is a silent no-op (clip).
function M.set(img, x, y, rgba)
  if x < 0 or x >= img.w or y < 0 or y >= img.h then return end
  img.buf:u32((y * img.w + x) * 4, rgba)
end

-- straight-alpha source-over (for brush stamps / gradient apply / soft edges).
-- Integer with rounding; sa==0 no-ops, sa==255 is a plain replace.
function M.over(img, x, y, rgba)
  local sa = (rgba >> 24) & 255
  if sa == 0 then return end
  if sa == 255 then return M.set(img, x, y, rgba) end
  if x < 0 or x >= img.w or y < 0 or y >= img.h then return end
  local off = (y * img.w + x) * 4
  local d = img.buf:u32(off)
  local da = (d >> 24) & 255
  local ia = 255 - sa
  local dterm = (da * ia + 127) // 255 -- dest's weight after the source covers it
  local oa = sa + dterm
  if oa == 0 then img.buf:u32(off, 0); return end
  local sr, sg, sb = rgba & 255, (rgba >> 8) & 255, (rgba >> 16) & 255
  local dr, dg, db = d & 255, (d >> 8) & 255, (d >> 16) & 255
  local orr = (sr * sa + dr * dterm + oa // 2) // oa
  local og  = (sg * sa + dg * dterm + oa // 2) // oa
  local ob  = (sb * sa + db * dterm + oa // 2) // oa
  img.buf:u32(off, M.pack(orr, og, ob, oa))
end

-- fill the whole image with one color (default transparent = clear).
function M.fill(img, rgba)
  rgba = rgba or 0
  local n = img.w * img.h
  for i = 0, n - 1 do img.buf:u32(i * 4, rgba) end
end

-- recolor every pixel exactly equal to `from` → `to` (palette edits / swaps).
function M.replace_color(img, from, to)
  local n = img.w * img.h
  for i = 0, n - 1 do
    if img.buf:u32(i * 4) == from then img.buf:u32(i * 4, to) end
  end
end

-- ---- lines & shapes (no AA) ----

-- Bresenham line, endpoints inclusive, 8-connected. `plot` defaults to set
-- (replace); pass M.over or a brush-stamp plotter to compose thickness/alpha.
function M.line(img, x0, y0, x1, y1, rgba, plot)
  plot = plot or M.set
  x0, y0, x1, y1 = floor(x0), floor(y0), floor(x1), floor(y1)
  local dx = abs(x1 - x0)
  local dy = -abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx + dy
  while true do
    plot(img, x0, y0, rgba)
    if x0 == x1 and y0 == y1 then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x0 = x0 + sx end
    if e2 <= dx then err = err + dx; y0 = y0 + sy end
  end
end

-- axis-aligned rectangle by top-left + size. filled = solid, else 1px outline.
function M.rect(img, x, y, w, h, rgba, filled, plot)
  plot = plot or M.set
  if w <= 0 or h <= 0 then return end
  if filled then
    for yy = y, y + h - 1 do
      for xx = x, x + w - 1 do plot(img, xx, yy, rgba) end
    end
  else
    M.line(img, x, y, x + w - 1, y, rgba, plot)
    M.line(img, x, y + h - 1, x + w - 1, y + h - 1, rgba, plot)
    M.line(img, x, y + 1, x, y + h - 2, rgba, plot)
    M.line(img, x + w - 1, y + 1, x + w - 1, y + h - 2, rgba, plot)
  end
end

-- ellipse by its (inclusive) bounding box corners. Float inside-test, integer
-- output — robust for any box (even/odd), connected outline, no AA. filled =
-- solid scanlines; else the outline (extreme x per row + extreme y per column,
-- so steep arcs stay connected).
function M.ellipse(img, x0, y0, x1, y1, rgba, filled, plot)
  plot = plot or M.set
  if x1 < x0 then x0, x1 = x1, x0 end
  if y1 < y0 then y0, y1 = y1, y0 end
  local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
  local rx, ry = (x1 - x0) / 2, (y1 - y0) / 2
  if rx < 0.5 or ry < 0.5 then M.line(img, x0, y0, x1, y1, rgba, plot); return end
  if filled then
    for y = y0, y1 do
      local ny = (y - cy) / ry
      local d = 1 - ny * ny
      if d >= 0 then
        local hx = rx * sqrt(d)
        for x = ceil(cx - hx), floor(cx + hx) do plot(img, x, y, rgba) end
      end
    end
  else
    for y = y0, y1 do
      local ny = (y - cy) / ry
      local d = 1 - ny * ny
      if d >= 0 then
        local hx = rx * sqrt(d)
        plot(img, floor(cx - hx + 0.5), y, rgba)
        plot(img, floor(cx + hx + 0.5), y, rgba)
      end
    end
    for x = x0, x1 do
      local nx = (x - cx) / rx
      local d = 1 - nx * nx
      if d >= 0 then
        local hy = ry * sqrt(d)
        plot(img, x, floor(cy - hy + 0.5), rgba)
        plot(img, x, floor(cy + hy + 0.5), rgba)
      end
    end
  end
end

-- ---- flood fill (4-connected, EXACT match — tolerance 0, STUDIO.md §5.1) ----

-- scanline flood fill: replace the contiguous region of pixels equal to the
-- seed color with rgba. Exact equality only (no "close enough" — that ruins
-- pixel art). No-op if the seed already is rgba (and so never loops forever).
function M.flood(img, x, y, rgba)
  x, y = floor(x), floor(y)
  if x < 0 or x >= img.w or y < 0 or y >= img.h then return end
  local target = M.get(img, x, y)
  if target == rgba then return end
  local w, h = img.w, img.h
  local stack = { x, y }
  local function seed_row(lx, rx, ny)
    if ny < 0 or ny >= h then return end
    local inside = false
    for xx = lx, rx do
      if M.get(img, xx, ny) == target then
        if not inside then stack[#stack + 1] = xx; stack[#stack + 1] = ny; inside = true end
      else
        inside = false
      end
    end
  end
  while #stack > 0 do
    local cy = stack[#stack]; stack[#stack] = nil
    local cx = stack[#stack]; stack[#stack] = nil
    if M.get(img, cx, cy) == target then
      local lx = cx
      while lx - 1 >= 0 and M.get(img, lx - 1, cy) == target do lx = lx - 1 end
      local rx = cx
      while rx + 1 < w and M.get(img, rx + 1, cy) == target do rx = rx + 1 end
      for xx = lx, rx do img.buf:u32((cy * w + xx) * 4, rgba) end
      seed_row(lx, rx, cy - 1)
      seed_row(lx, rx, cy + 1)
    end
  end
end

-- ---- blit / transforms ----

-- copy a src region (sx,sy,sw,sh; defaults whole src) into dst at (dx,dy).
-- mode "set" replaces, "stamp" writes only non-transparent texels (a sprite
-- brush / paste that respects transparency), "over" alpha-composites.
function M.blit(dst, dx, dy, src, sx, sy, sw, sh, mode)
  sx, sy = sx or 0, sy or 0
  sw, sh = sw or src.w, sh or src.h
  mode = mode or "set"
  for j = 0, sh - 1 do
    for i = 0, sw - 1 do
      local c = M.get(src, sx + i, sy + j)
      if mode == "set" then
        M.set(dst, dx + i, dy + j, c)
      elseif mode == "stamp" then
        if (c >> 24) & 255 ~= 0 then M.set(dst, dx + i, dy + j, c) end
      else
        M.over(dst, dx + i, dy + j, c)
      end
    end
  end
end

function M.flip_h(img)
  local w, h = img.w, img.h
  for y = 0, h - 1 do
    for x = 0, w // 2 - 1 do
      local off_a = (y * w + x) * 4
      local off_b = (y * w + (w - 1 - x)) * 4
      local a, b = img.buf:u32(off_a), img.buf:u32(off_b)
      img.buf:u32(off_a, b); img.buf:u32(off_b, a)
    end
  end
end

function M.flip_v(img)
  local w, h = img.w, img.h
  for y = 0, h // 2 - 1 do
    for x = 0, w - 1 do
      local off_a = (y * w + x) * 4
      local off_b = ((h - 1 - y) * w + x) * 4
      local a, b = img.buf:u32(off_a), img.buf:u32(off_b)
      img.buf:u32(off_a, b); img.buf:u32(off_b, a)
    end
  end
end

-- rotate 90°; dir 1 = clockwise, -1 = counter-clockwise. Returns a NEW image
-- with width/height swapped (the caller adopts it; the source is untouched).
function M.rotate90(img, dir)
  local w, h = img.w, img.h
  local out = M.image(h, w)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local c = img.buf:u32((y * w + x) * 4)
      if dir < 0 then
        out.buf:u32(((w - 1 - x) * h + y) * 4, c) -- CCW: (x,y)->(y, w-1-x)
      else
        out.buf:u32((x * h + (h - 1 - y)) * 4, c)  -- CW:  (x,y)->(h-1-y, x)
      end
    end
  end
  return out
end

return M
