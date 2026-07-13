-- cm.ed.chips — the right-aligned header chip strip (R9a, EDITOR.md
-- §13): the little hover/on/click buttons every kind's header hand-
-- rolled (sprite's edit/anim, tmap's edit toggle, …), written once.
-- Colors are the house header palette; hover gates on ctx.hot (the
-- one-window-per-frame pointer rule) and the header band.
--
--   function K.header(win, ctx)
--     local s = chips.strip(ctx)
--     if s:chip("edit", win.edit) then ... end
--     if s:chip("anim", false) then ... end
--     return s.used
--   end

local M = select(2, ...) or {}

M.COL = { btn = 0x262238ff, btn_on = 0x4a4370ff,
          hot = 0xE8E4FFff, dim = 0x8a84b0ff }

local S = {}
S.__index = S

-- one chip, laid right-to-left from the strip cursor; returns true on
-- the click (LMB press this frame while hovered)
function S.chip(s, label, on)
  local ctx, i, z, px = s.ctx, s.i, s.ctx.z, s.px
  local w = pal.x_ig_text_size(label, px, 0) + 14 * z
  s.x = s.x - w
  s.used = s.used + w + 4 * z
  local hov = ctx.hot and i.wx >= s.x and i.wx < s.x + w
              and i.wy >= ctx.hy and i.wy < ctx.hy + ctx.hh
  pal.x_ig_rect_fill(s.x, ctx.hy + 3 * z, w, ctx.hh - 6 * z,
                     on and M.COL.btn_on or M.COL.btn, 4 * z)
  pal.x_ig_text(s.x + 7 * z, ctx.hy + (ctx.hh - px) * 0.45, px,
                (hov or on) and M.COL.hot or M.COL.dim, label, 0)
  s.x = s.x - 4 * z
  return hov and i.clicked[1] or false
end

-- the strip cursor over a kind.header ctx ({z, hot, hx, hy, hh, ed})
function M.strip(ctx)
  return setmetatable({ ctx = ctx, x = ctx.hx, used = 0,
                        px = math.max(4, 10.5 * ctx.z),
                        i = cm.require("cm.ui").inp }, S)
end

return M
