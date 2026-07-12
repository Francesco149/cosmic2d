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
  -- letterbox the target into a rounded filler well, preserving aspect —
  -- the image sits inside a margin so it never touches the panel's
  -- rounded border (human feedback, live round 2)
  local tw, th = pal.gfx_size()
  if tw <= 0 or th <= 0 then return end
  pal.x_ig_rect_fill(ctx.cx, ctx.cy, ctx.cw, ctx.ch, 0x0c0a14ff, 4 * ctx.z)
  local m = 3 * ctx.z
  local aw, ah = ctx.cw - 2 * m, ctx.ch - 2 * m
  if aw <= 0 or ah <= 0 then return end
  local s = math.min(aw / tw, ah / th)
  local dw, dh = tw * s, th * s
  pal.x_ig_image(-1, ctx.cx + m + (aw - dw) * 0.5,
                 ctx.cy + m + (ah - dh) * 0.5, dw, dh)
end

return M
