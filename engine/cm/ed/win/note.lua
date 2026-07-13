-- cm.ed.win.note — the sticky note (EDITOR.md §7): an x_ig_edit multiline
-- whose content lives only in the editor doc (canvas furniture — no file,
-- no journal). Proves chrome + edit capture + session persistence.
--
-- Occluded windows draw inert text instead of the widget (the widget-z
-- rule, ed.lua); the ALT layer needs no special casing here — the shell
-- gates mouse off imgui in C (pal.x_ig_mouse), so the widget renders
-- unchanged and still can't steal an A-click.

local M = select(2, ...) or {}

M.kind = "note"
M.menu = "note"
M.DEF_W, M.DEF_H = 260, 180
M.PX = 13.5 -- world-px text size

function M.defaults()
  return { text = "" }
end

function M.title(win)
  return "note"
end

-- ctx: { ig, z, cx, cy, cw, ch (content rect, screen px), alt, touch() }
function M.draw(win, ctx)
  local px = math.max(4, M.PX * ctx.z)
  local pad = 6 * ctx.z
  if ctx.occluded then -- inert (widget-z rule); +4,+3 = imgui FramePadding
    pal.x_ig_clip_push(ctx.cx, ctx.cy, ctx.cw, ctx.ch)
    pal.x_ig_text(ctx.cx + pad + 4, ctx.cy + pad * 0.5 + 3, px, 0xffffffff,
                  win.text or "", 0)
    pal.x_ig_clip_pop()
    return
  end
  local text, changed = pal.x_ig_edit {
    id = "note" .. win.id,
    x = ctx.cx + pad, y = ctx.cy + pad * 0.5,
    w = ctx.cw - 2 * pad, h = ctx.ch - pad,
    text = win.text or "", px = px, font = 0, multiline = true,
  }
  if changed then
    win.text = text
    ctx.touch()
  end
end

return M
