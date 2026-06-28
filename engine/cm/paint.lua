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
local max, min = math.max, math.min
local atan, pi = math.atan, math.pi

-- an optional WRITE-CLIP rectangle (doc px, half-open [x0,x1)×[y0,y1)) honored by
-- the write primitives set / over / flood, so the studio can confine a stroke /
-- fill / shape to the active selection (STUDIO.md §5.1: "selection restricts
-- editing"). Off by default — composite / bake / scratch / copy never set it, so
-- they are never clipped. set_clip / clip_off are below.
local clip_x0, clip_y0, clip_x1, clip_y1
local function clipped_out(x, y)
  return clip_x0 ~= nil and (x < clip_x0 or x >= clip_x1 or y < clip_y0 or y >= clip_y1)
end

-- ---- color packing (0..255 ints <-> RGBA8 u32) ----

function M.pack(r, g, b, a)
  return (r & 255) | ((g & 255) << 8) | ((b & 255) << 16) | (((a or 255) & 255) << 24)
end

function M.unpack(rgba)
  return rgba & 255, (rgba >> 8) & 255, (rgba >> 16) & 255, (rgba >> 24) & 255
end

M.CLEAR = 0 -- transparent (all-zero RGBA)

-- set / clear the write-clip rect (see above). Half-open: [x0,x1) × [y0,y1).
function M.set_clip(x0, y0, x1, y1) clip_x0, clip_y0, clip_x1, clip_y1 = x0, y0, x1, y1 end
function M.clip_off() clip_x0 = nil end

-- HSV (all components 0..1; h wraps) -> packed RGBA. The studio's color picker
-- and the Phase-3 gradient ramps both work in HSV. Pure float, dev-class.
function M.hsv(h, s, v, a)
  h = (h - floor(h)) * 6
  local i = floor(h)
  local f = h - i
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  local r, g, b
  if i == 0 then r, g, b = v, t, p
  elseif i == 1 then r, g, b = q, v, p
  elseif i == 2 then r, g, b = p, v, t
  elseif i == 3 then r, g, b = p, q, v
  elseif i == 4 then r, g, b = t, p, v
  else r, g, b = v, p, q end
  return M.pack(floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5), a)
end

-- packed RGBA -> h, s, v (each 0..1; alpha dropped). Inverse of M.hsv for
-- saturated colors; grayscale returns h=0.
function M.to_hsv(rgba)
  local r, g, b = M.unpack(rgba)
  r, g, b = r / 255, g / 255, b / 255
  local mx, mn = max(r, g, b), min(r, g, b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then h = ((g - b) / d) % 6
    elseif mx == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h / 6
    if h < 0 then h = h + 1 end
  end
  return h, mx == 0 and 0 or d / mx, mx
end

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
  if clipped_out(x, y) then return end
  img.buf:u32((y * img.w + x) * 4, rgba)
end

-- straight-alpha source-over (for brush stamps / gradient apply / soft edges).
-- Integer with rounding; sa==0 no-ops, sa==255 is a plain replace.
function M.over(img, x, y, rgba)
  local sa = (rgba >> 24) & 255
  if sa == 0 then return end
  if sa == 255 then return M.set(img, x, y, rgba) end
  if x < 0 or x >= img.w or y < 0 or y >= img.h then return end
  if clipped_out(x, y) then return end
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
  if clipped_out(x, y) then return end -- seeding outside the clip fills nothing
  local target = M.get(img, x, y)
  if target == rgba then return end
  local w, h = img.w, img.h
  -- a clipped-out pixel is treated as a boundary (≠ target), so the fill stays
  -- inside the active selection (STUDIO.md §5.1)
  local function match(xx, ny) return not clipped_out(xx, ny) and M.get(img, xx, ny) == target end
  local stack = { x, y }
  local function seed_row(lx, rx, ny)
    if ny < 0 or ny >= h then return end
    local inside = false
    for xx = lx, rx do
      if match(xx, ny) then
        if not inside then stack[#stack + 1] = xx; stack[#stack + 1] = ny; inside = true end
      else
        inside = false
      end
    end
  end
  while #stack > 0 do
    local cy = stack[#stack]; stack[#stack] = nil
    local cx = stack[#stack]; stack[#stack] = nil
    if match(cx, cy) then
      local lx = cx
      while lx - 1 >= 0 and match(lx - 1, cy) do lx = lx - 1 end
      local rx = cx
      while rx + 1 < w and match(rx + 1, cy) do rx = rx + 1 end
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

-- copy a rectangular region out into a fresh w*h image (a selection lift /
-- clipboard grab). Out-of-bounds source reads come back transparent.
function M.copy_region(img, x, y, w, h)
  local out = M.image(w, h)
  M.blit(out, 0, 0, img, x, y, w, h, "set")
  return out
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

-- nearest-neighbour resample to nw*nh (NO interpolation — pixel art stays
-- crisp, blocks just multiply/decimate). Returns a NEW image.
function M.scale(img, nw, nh)
  local out = M.image(nw, nh)
  local sw, sh = img.w, img.h
  for y = 0, nh - 1 do
    local sy = floor(y * sh / nh)
    for x = 0, nw - 1 do
      local sx = floor(x * sw / nw)
      out.buf:u32((y * nw + x) * 4, img.buf:u32((sy * sw + sx) * 4))
    end
  end
  return out
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

-- ---- gradients (eval + ordered dither — the signature feature, STUDIO.md §6) ----
--
-- A gradient FILL is a small editable object (the studio stores one per layer,
-- the .spr keeps it live): { type, p0={x,y}, p1={x,y}, stops={{pos,rgba}…},
-- levels, dither(0..1 strength), bayer(2|4|8), phase(0..1) }. These are pure
-- functions of the def + a pixel — dev-class float is fine, and selftest pins
-- them with KATs. Pixel-art gradients are *ordered dithering* between a few
-- bands, never a smooth blend: dither_t snaps each pixel to a real ramp band, so
-- every output pixel is an exact ramp color (no AA, STUDIO.md §5.1).

-- float-lerp two packed colors (alpha lerps too); f in 0..1.
function M.lerp_rgba(c0, c1, f)
  local r0, g0, b0, a0 = M.unpack(c0)
  local r1, g1, b1, a1 = M.unpack(c1)
  return M.pack(floor(r0 + (r1 - r0) * f + 0.5), floor(g0 + (g1 - g0) * f + 0.5),
                floor(b0 + (b1 - b0) * f + 0.5), floor(a0 + (a1 - a0) * f + 0.5))
end

-- sample a multi-stop ramp at t (clamped to the end stops). `stops` is an array
-- of { pos = 0..1, rgba } sorted ascending by pos; pos ties take the earlier.
function M.ramp(stops, t)
  local n = #stops
  if n == 0 then return 0 end
  if n == 1 or t <= stops[1].pos then return stops[1].rgba end
  if t >= stops[n].pos then return stops[n].rgba end
  for i = 1, n - 1 do
    local a, b = stops[i], stops[i + 1]
    if t <= b.pos then
      local span = b.pos - a.pos
      return M.lerp_rgba(a.rgba, b.rgba, span > 1e-9 and (t - a.pos) / span or 0)
    end
  end
  return stops[n].rgba
end

-- the classic recursive Bayer index matrices (ordered-dither thresholds).
local BAYER = {
  [2] = { 0, 2, 3, 1 },
  [4] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 },
  [8] = { 0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
          12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
          3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
          15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21 },
}

-- the ordered-dither threshold at (x,y) for a size∈{2,4,8} Bayer cell, in (0,1).
function M.bayer(size, x, y)
  if size ~= 2 and size ~= 8 then size = 4 end
  local v = BAYER[size][(y % size) * size + (x % size) + 1]
  return (v + 0.5) / (size * size)
end

-- the raw axis parameter for a pixel: linear/mirror = projection onto p0→p1
-- (unclamped, may exit 0..1); radial = distance/|axis| (≥0); angular = the
-- turn from the axis direction, wrapped to [0,1). The per-type clamp/wrap/fold
-- is applied in grad_shade (so phase can slide first).
function M.grad_t(kind, x, y, p0x, p0y, p1x, p1y)
  local dx, dy = p1x - p0x, p1y - p0y
  if kind == "radial" then
    local r2 = dx * dx + dy * dy
    if r2 < 1e-9 then return 0 end
    local px, py = x - p0x, y - p0y
    return sqrt((px * px + py * py) / r2)
  elseif kind == "angular" then
    local a = (atan(y - p0y, x - p0x) - atan(dy, dx)) / (2 * pi)
    return a - floor(a)
  else -- linear / mirror
    local len2 = dx * dx + dy * dy
    if len2 < 1e-9 then return 0 end
    return ((x - p0x) * dx + (y - p0y) * dy) / len2
  end
end

-- quantize t into `levels` bands, ordered-dithering across each band boundary.
-- bt is this pixel's Bayer threshold. strength 0 = hard bands (snap to nearest);
-- strength 1 = the whole band dithers (smoothest pixel-art ramp). Returns a
-- band-snapped t' to feed back into the ramp, so the output is an exact band color.
function M.dither_t(t, levels, strength, bt)
  if levels <= 1 then return 0 end
  if t <= 0 then return 0 end
  if t >= 1 then return 1 end
  local tb = t * (levels - 1)
  local base = floor(tb)
  local frac = tb - base
  local p
  if strength <= 0 then
    p = frac < 0.5 and 0 or 1
  else
    p = (frac - 0.5) / strength + 0.5
    p = p < 0 and 0 or (p > 1 and 1 or p)
  end
  local lvl = base + ((bt < p) and 1 or 0)
  if lvl > levels - 1 then lvl = levels - 1 end
  return lvl / (levels - 1)
end

local function fold_tri(t) -- period-2 triangle wave 0→1→0 (for the mirror type)
  local m = t - 2 * floor(t / 2)
  return m > 1 and 2 - m or m
end

-- the gradient color at one pixel: geometry → +phase → per-type normalize →
-- ordered-dither band snap → ramp sample. A complete, pure "color at (x,y)".
function M.grad_shade(fill, x, y)
  local p0, p1 = fill.p0, fill.p1
  local t = M.grad_t(fill.type, x, y, p0.x, p0.y, p1.x, p1.y) + (fill.phase or 0)
  if fill.type == "angular" then t = t - floor(t)
  elseif fill.type == "mirror" then t = fold_tri(t)
  else t = t < 0 and 0 or (t > 1 and 1 or t) end
  t = M.dither_t(t, fill.levels or 2, fill.dither or 0, M.bayer(fill.bayer or 4, x, y))
  return M.ramp(fill.stops, t)
end

-- render `fill` into `img`, but ONLY where `mask` has alpha > 0 — the gradient
-- recolors a layer's *visible* pixels and keeps their per-pixel alpha (the
-- shape is the layer's, the color is the ramp's; STUDIO.md §6). Masked-out
-- pixels are left untouched, so pass a cleared scratch (composite) or the cell
-- itself (in-place destructive stamp). img and mask must share dimensions.
function M.grad_fill(img, fill, mask)
  for y = 0, img.h - 1 do
    for x = 0, img.w - 1 do
      local ma = (M.get(mask, x, y) >> 24) & 255
      if ma ~= 0 then
        local c = M.grad_shade(fill, x, y)
        local ca = (c >> 24) & 255
        local oa = ca == 255 and ma or (ca * ma + 127) // 255
        M.set(img, x, y, (c & 0x00ffffff) | (oa << 24))
      end
    end
  end
end

return M
