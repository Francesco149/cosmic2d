-- cm.ed.preview — shared asset-preview renderers used by BOTH the Ctrl+Space
-- launcher and the asset browser (the human's ask: previews in both). Pure
-- drawlist, no state: a map SCHEMATIC (colliders + placements + markers), a
-- .tm cell schematic, and a code/doc HEAD excerpt. Colours default to the
-- editor palette; callers may override.

local M = {}

local DEF = { col = 0x8ad0ffff, plc = 0x7fd8a8ff, mk = 0xf0d070ff,
              dim = 0x8a84b0ff, code = 0xb8c0e8ff }

-- the first `n` lines of a text blob, tabs softened (nil = unreadable)
function M.head_lines(bytes, n)
  if not bytes then return nil end
  n = n or 20
  local out = {}
  for line in (bytes .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line:gsub("\t", "  ")
    if #out >= n then break end
  end
  return out
end

function M.draw_lines(lines, px, py, pw, ph, size, col)
  size = size or 11
  col = col or DEF.code
  pal.x_ig_clip_push(px, py, pw, ph)
  for i, line in ipairs(lines) do
    local y = py + 3 + (i - 1) * (size + 2)
    if y > py + ph then break end
    pal.x_ig_text(px + 4, y, size, col, line, 1)
  end
  pal.x_ig_clip_pop()
end

-- a map schematic scaled to fit (px,py,pw,ph): colliders as lines, placements
-- + markers as rects. col optional overrides.
function M.draw_map(doc, px, py, pw, ph, col)
  col = col or DEF
  local minx, miny, maxx, maxy = 1e9, 1e9, -1e9, -1e9
  local function ext(x, y)
    if x < minx then minx = x end
    if x > maxx then maxx = x end
    if y < miny then miny = y end
    if y > maxy then maxy = y end
  end
  for _, c in ipairs(doc.colliders or {}) do
    if c.kind == "chain" then
      for k = 1, #c.verts, 2 do ext(c.verts[k], c.verts[k + 1]) end
    elseif c.kind == "quad" then
      ext(c.x, c.y); ext(c.x + c.w, c.y + c.h)
    elseif c.kind == "circle" then
      ext(c.cx - c.r, c.cy - c.r); ext(c.cx + c.r, c.cy + c.r)
    end
  end
  for _, p in ipairs(doc.places or {}) do ext(p.x, p.y); ext(p.x + 32, p.y + 32) end
  for _, mk in ipairs(doc.markers or {}) do ext(mk.x, mk.y); ext(mk.x + mk.w, mk.y + mk.h) end
  if minx > maxx then
    pal.x_ig_text(px + 4, py + 4, 11, col.dim or DEF.dim, "empty map", 1)
    return
  end
  local mw, mh = math.max(1, maxx - minx), math.max(1, maxy - miny)
  local s = math.min(pw / mw, ph / mh) * 0.92
  local ox = px + (pw - mw * s) * 0.5 - minx * s
  local oy = py + (ph - mh * s) * 0.5 - miny * s
  for _, p in ipairs(doc.places or {}) do
    pal.x_ig_rect_fill(ox + p.x * s, oy + p.y * s, math.max(2, 32 * s),
                       math.max(2, 32 * s), 0x7fd8a844, 1)
  end
  for _, mk in ipairs(doc.markers or {}) do
    pal.x_ig_rect(ox + mk.x * s, oy + mk.y * s, mk.w * s, mk.h * s, col.mk or DEF.mk, 1)
  end
  for _, c in ipairs(doc.colliders or {}) do
    if c.kind == "chain" then
      for k = 1, #c.verts - 2, 2 do
        pal.x_ig_line(ox + c.verts[k] * s, oy + c.verts[k + 1] * s,
                      ox + c.verts[k + 2] * s, oy + c.verts[k + 3] * s,
                      col.col or DEF.col, 1)
      end
    elseif c.kind == "quad" then
      pal.x_ig_rect(ox + c.x * s, oy + c.y * s, c.w * s, c.h * s, col.col or DEF.col, 1)
    elseif c.kind == "circle" then
      pal.x_ig_circle(ox + c.cx * s, oy + c.cy * s, c.r * s, col.col or DEF.col, 1)
    end
  end
end

-- a .tm schematic: a filled cell per non-empty tile
function M.draw_tm(doc, px, py, pw, ph, color)
  local tmap = cm.require("cm.tmap")
  local s = math.min(pw / doc.w, ph / doc.h) * 0.92
  local ox = px + (pw - doc.w * s) * 0.5
  local oy = py + (ph - doc.h * s) * 0.5
  for ty = 0, doc.h - 1 do
    for tx = 0, doc.w - 1 do
      if tmap.get(doc, tx, ty) ~= 0 then
        pal.x_ig_rect_fill(ox + tx * s, oy + ty * s, math.max(1, s),
                           math.max(1, s), color or DEF.plc, 0)
      end
    end
  end
end

return M
