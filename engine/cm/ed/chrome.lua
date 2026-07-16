-- cm.ed.chrome -- scaled draw/input adapter for native editor chrome.
--
-- Canvas windows already have a world camera and its independent machine-local
-- accessibility multiplier. HUDs, menus, the launcher, and rewind instead use
-- fixed window pixels. This adapter gives those surfaces a virtual coordinate
-- space: callers keep their taste-approved 1x layout, while every draw/widget
-- coordinate and glyph size is multiplied at the PAL boundary and pointer
-- coordinates are divided by the same amount.

local M = select(2, ...) or {}

M.s = M.s or 1

function M.set_scale(s)
  M.s = math.max(0.5, math.min(4, tonumber(s) or 1))
  return M.s
end

function M.scale() return M.s end

local function n(v) return v and v * M.s or v end

function M.virtual_ig(ig)
  return setmetatable({ w = ig.w / M.s, h = ig.h / M.s }, { __index = ig })
end

function M.virtual_input(i, scale)
  scale = tonumber(scale) or M.s
  return setmetatable({ wx = (i.wx or 0) / scale,
                        wy = (i.wy or 0) / scale }, { __index = i })
end

function M.frame(ig, i, scale)
  M.set_scale(scale)
  return M.virtual_ig(ig), M.virtual_input(i)
end

function M.x_ig_overlay(on) return pal.x_ig_overlay(on) end

function M.x_ig_line(x0, y0, x1, y1, color, thick)
  return pal.x_ig_line(n(x0), n(y0), n(x1), n(y1), color, n(thick))
end

function M.x_ig_rect(x, y, w, h, color, thick, round)
  return pal.x_ig_rect(n(x), n(y), n(w), n(h), color, n(thick), n(round))
end

function M.x_ig_rect_fill(x, y, w, h, color, round)
  return pal.x_ig_rect_fill(n(x), n(y), n(w), n(h), color, n(round))
end

function M.x_ig_circle(x, y, r, color, thick)
  return pal.x_ig_circle(n(x), n(y), n(r), color, n(thick))
end

function M.x_ig_circle_fill(x, y, r, color)
  return pal.x_ig_circle_fill(n(x), n(y), n(r), color)
end

function M.x_ig_poly(points, color, thick, closed)
  local scaled = {}
  for i, v in ipairs(points) do scaled[i] = n(v) end
  return pal.x_ig_poly(scaled, color, n(thick), closed)
end

function M.x_ig_poly_fill(points, color)
  local scaled = {}
  for i, v in ipairs(points) do scaled[i] = n(v) end
  return pal.x_ig_poly_fill(scaled, color)
end

function M.x_ig_text(x, y, px, color, text, font, wrap_w)
  return pal.x_ig_text(n(x), n(y), n(px), color, text, font, n(wrap_w))
end

function M.x_ig_text_size(text, px, font, wrap_w)
  local w, h = pal.x_ig_text_size(text, n(px), font, n(wrap_w))
  if not w then return nil end
  return w / M.s, h / M.s
end

function M.x_ig_image(tex, x, y, w, h, ...)
  return pal.x_ig_image(tex, n(x), n(y), n(w), n(h), ...)
end

function M.x_ig_clip_push(x, y, w, h)
  return pal.x_ig_clip_push(n(x), n(y), n(w), n(h))
end

function M.x_ig_clip_pop() return pal.x_ig_clip_pop() end

function M.x_ig_edit(opts)
  local scaled = {}
  for k, v in pairs(opts) do scaled[k] = v end
  scaled.x, scaled.y = n(opts.x), n(opts.y)
  scaled.w, scaled.h = n(opts.w), n(opts.h)
  scaled.px = n(opts.px)
  return pal.x_ig_edit(scaled)
end

-- Drop-in PAL view used inside fixed-chrome modules. Non-imgui calls (time,
-- files, logging) still resolve to the host unchanged.
M.pal = setmetatable({}, {
  __index = function(_, key)
    local scaled = key:sub(1, 5) == "x_ig_" and M[key]
    return scaled or pal[key]
  end,
})

return M
