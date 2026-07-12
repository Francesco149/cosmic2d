-- cm.ed.win.image — a picture on the canvas (R4, EDITOR.md §12.5): the
-- asset picker's open-target for plain images (ref sheets, mocks). Aspect-
-- fit over a checker well, read-only. PNG only (pal.png_read is the
-- decoder we have); anything else stays a glyph tile in the picker.

local M = select(2, ...) or {}

M.kind = "image"
M.DEF_W, M.DEF_H = 360, 300

function M.defaults()
  return { path = "" }
end

function M.title(win)
  return win.path:match("([^/]+)$") or "image"
end

function M.accepts(win, path)
  return path:lower():find("%.png$") ~= nil
end

function M.rebind(win, ed, path)
  win.path = path
  ed.touch()
end

local function checker(x, y, w, h, z)
  pal.x_ig_rect_fill(x, y, w, h, 0x232030ff, 4 * z)
  local step = 12 * z
  pal.x_ig_clip_push(x, y, w, h)
  local nx, ny = math.ceil(w / step), math.ceil(h / step)
  for iy = 0, ny - 1 do
    for ix = 0, nx - 1 do
      if (ix + iy) % 2 == 0 then
        pal.x_ig_rect_fill(x + ix * step, y + iy * step, step, step,
                           0x2b2838ff)
      end
    end
  end
  pal.x_ig_clip_pop()
end

function M.draw(win, ctx)
  local ed = ctx.ed
  checker(ctx.cx, ctx.cy, ctx.cw, ctx.ch, ctx.z)
  if win.path == "" then return end
  local ok, t = pcall(cm.require("cm.gfx").texture, ed.root .. "/" .. win.path)
  if not ok then
    pal.x_ig_text(ctx.cx + 8 * ctx.z, ctx.cy + 8 * ctx.z,
                  math.max(4, 12 * ctx.z), 0xf07a7aff, "unreadable image", 0)
    return
  end
  local m = 3 * ctx.z
  local aw, ah = ctx.cw - 2 * m, ctx.ch - 2 * m
  if aw <= 0 or ah <= 0 then return end
  local s = math.min(aw / t.w, ah / t.h)
  local dw, dh = t.w * s, t.h * s
  pal.x_ig_image(t.id, ctx.cx + m + (aw - dw) * 0.5,
                 ctx.cy + m + (ah - dh) * 0.5, dw, dh)
end

return M
