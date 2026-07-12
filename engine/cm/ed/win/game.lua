-- cm.ed.win.game — the live game window (EDITOR.md §7): the game internal
-- target drawn straight off the GPU via x_ig_image(-1), aspect-locked to
-- the project's internal size. Watch-only in R3 — the sim runs below with
-- all input swallowed by the shell; synthesizing sim input for a focused,
-- playable game window is R4 design.

local M = select(2, ...) or {}

M.kind = "game"

function M.defaults()
  local w, h = pal.gfx_size()
  return {}, w, h -- spawn at the target's native size (world units 1:1)
end

function M.title(win)
  return "game — live"
end

function M.draw(win, ctx)
  -- letterbox the target into the content rect, preserving aspect
  local tw, th = pal.gfx_size()
  if tw <= 0 or th <= 0 then return end
  local s = math.min(ctx.cw / tw, ctx.ch / th)
  local dw, dh = tw * s, th * s
  local dx = ctx.cx + (ctx.cw - dw) * 0.5
  local dy = ctx.cy + (ctx.ch - dh) * 0.5
  pal.x_ig_rect_fill(ctx.cx, ctx.cy, ctx.cw, ctx.ch, 0x0c0a14ff)
  pal.x_ig_image(-1, dx, dy, dw, dh)
end

return M
