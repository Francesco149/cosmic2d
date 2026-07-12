-- cm.ed.win.note — the sticky note (EDITOR.md §7): an x_ig_edit multiline
-- whose content lives only in the editor doc (canvas furniture — no file,
-- no journal). Proves chrome + edit capture + session persistence.
--
-- While ALT is held the widget is not submitted (inert text draws instead)
-- so imgui can never steal an A-click — the shell's grammar owns the ALT
-- layer by construction (EDITOR.md §5 routing rule 1).

local M = select(2, ...) or {}

M.kind = "note"
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
  if ctx.alt then
    pal.x_ig_clip_push(ctx.cx, ctx.cy, ctx.cw, ctx.ch)
    pal.x_ig_text(ctx.cx + pad, ctx.cy + pad * 0.7, px, 0xd8d2f2ff,
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
