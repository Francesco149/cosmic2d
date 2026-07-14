-- cm.ed.win.help — the getting-started launcher (audit G7). A read-only
-- list of the docs shipped in engine/stock/docs; clicking one opens it in a
-- code-editor window beside this one, where the .md machinery (headings,
-- links, history) does the rest (EDITOR.md §12.2). No working state, no
-- journal — spawn it from the rclick menu, close it fearlessly.
--
-- Stock docs resolve at the ENGINE root (the process cwd), like the stock
-- presets/palettes. The code editor reads ed.root-relative, so it opens them
-- via ../../engine/stock/docs/* (the resolve_link convention) — which lands
-- on the right file for engine-repo projects.

local M = select(2, ...) or {}

M.kind = "help"
M.menu = "help"
M.DEF_W, M.DEF_H = 260, 210

local COL = {
  dim = 0x8a84b0ff, text = 0xd8d2f2ff, hot = 0xE8E4FFff,
  row = 0x262238ff, row_hot = 0x322d48ff,
}

local STOCK = "engine/stock/docs"

-- {name=<file>, title=<first heading or prettified name>}; memoized (the
-- shipped set is static, and a VM reload rebuilds this module anyway).
local cache
local function list_docs()
  if cache then return cache end
  local out = {}
  for _, n in ipairs(pal.list_dir(STOCK) or {}) do
    local file = n:match("([^/]+%.md)$")
    if file then
      local title = file:gsub("%.md$", ""):gsub("[%-_]", " ")
      local src = pal.read_file(STOCK .. "/" .. file)
      local h = src and src:match("^#+%s*([^\n]+)")
      out[#out + 1] = { name = file, title = h or title }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  cache = out
  return out
end

function M.defaults()
  return {}
end

function M.title(win)
  return "help"
end

function M.draw(win, ctx)
  local i = cm.require("cm.ui").inp
  local z = ctx.z
  local px = math.max(5, 12 * z)
  local x0, y = ctx.cx + 8 * z, ctx.cy + 8 * z

  pal.x_ig_text(x0, y, px, COL.hot, "help — getting started", 0)
  y = y + px * 1.5
  pal.x_ig_text(x0, y, math.max(4, 9 * z), COL.dim,
                "open a doc in the code editor", 0)
  y = y + px * 1.4

  local rw = ctx.cw - 16 * z
  local rh = px * 1.9
  for _, d in ipairs(list_docs()) do
    local hov = ctx.hot and i.wx >= x0 and i.wx < x0 + rw
                and i.wy >= y and i.wy < y + rh
    pal.x_ig_rect_fill(x0, y, rw, rh, hov and COL.row_hot or COL.row, 4 * z)
    pal.x_ig_text(x0 + 8 * z, y + (rh - px) * 0.5, px,
                  hov and COL.hot or COL.text, d.title, 0)
    if hov and i.clicked[1] then
      ctx.ed.open_asset_window(
        "../../" .. STOCK .. "/" .. d.name, win.x + win.w + 20, win.y)
    end
    y = y + rh + 5 * z
  end

  if #list_docs() == 0 then
    pal.x_ig_text(x0, y, px, COL.dim, "no docs found", 0)
  end
end

return M
