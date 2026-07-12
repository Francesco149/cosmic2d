-- cm.ed.win.game — the live game window (EDITOR.md §7/§12.3): the game
-- internal target drawn straight off the GPU via x_ig_image(-1), aspect-
-- locked to the project's internal size.
--
-- R4: FOCUSED = PLAYING (heuristics-for-intent: content-click focuses, so
-- clicking into the game plays it; clicking anywhere else stops). While
-- playing, the shell's filter_events passes keys through to cm.input and
-- remaps mouse events over the letterboxed image (drawn rect recorded here
-- each frame, ephemeral) into FOV px — the synthesized input rides the
-- normal recorded path, so it is replayable by construction.

local M = select(2, ...) or {}

M.kind = "game"
M.wants_keys = true -- plain-key shell hotkeys suspend while focused (§12.3)

function M.defaults()
  local w, h = pal.gfx_size()
  return {}, w, h -- spawn at the target's native size (world units 1:1)
end

function M.title(win)
  return "game"
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
  local ix = ctx.cx + m + (aw - dw) * 0.5
  local iy = ctx.cy + m + (ah - dh) * 0.5
  pal.x_ig_image(-1, ix, iy, dw, dh)
  -- the image rect in window px (ephemeral): filter_events remaps mouse
  -- events through it next tick (1-frame latency, same class as ig capture)
  local ed = ctx.ed
  ed.g.grect = ed.g.grect or {}
  ed.g.grect[win.id] = { x = ix, y = iy, s = s, w = dw, h = dh }
  -- playing state, unmissable: accent chip in the top-right of the well
  if ctx.focused then
    local px = math.max(4, 10 * ctx.z)
    local label = "PLAYING"
    local lw = pal.x_ig_text_size(label, px, 0)
    pal.x_ig_rect_fill(ctx.cx + ctx.cw - lw - 14 * ctx.z, ctx.cy + 4 * ctx.z,
                       lw + 10 * ctx.z, px * 1.5, 0x7fd8a8cc, 4 * ctx.z)
    pal.x_ig_text(ctx.cx + ctx.cw - lw - 9 * ctx.z, ctx.cy + 4 * ctx.z + px * 0.22,
                  px, 0x10241aff, label, 0)
  end
end

return M
