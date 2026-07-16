-- cm.pick — the picker's list model and navigation math (D080).
-- Pure functions over plain tile tables: search filtering, name ordering,
-- grid cursor movement, and scroll clamping. No filesystem, no pal, no
-- globals — the picker UI supplies tiles and geometry, selftest supplies
-- fixtures. Matching is ASCII-case-insensitive plain text (no patterns);
-- non-ASCII bytes compare exactly, which is the honest contract for the
-- UTF-8 names the location packets allow.

local M = select(2, ...) or {}

local function fold(s)
  return tostring(s or ""):lower()
end

-- Does one tile match a query? Plain substring against name, path, and
-- author. An empty/nil query matches everything.
function M.match(tile, query)
  query = fold(query)
  if query == "" then return true end
  return fold(tile.name):find(query, 1, true) ~= nil
      or fold(tile.path):find(query, 1, true) ~= nil
      or fold(tile.author):find(query, 1, true) ~= nil
end

-- The displayed list: filter by query, then order by mode.
--  "recent" keeps the incoming order (recents newest-first, then bundled).
--  "name" is a stable ASCII-case-insensitive name sort, path tiebreak.
-- Always returns a fresh array; the input is never mutated.
function M.view(tiles, query, mode)
  local out = {}
  for _, t in ipairs(tiles or {}) do
    if M.match(t, query) then out[#out + 1] = t end
  end
  if mode == "name" then
    table.sort(out, function(a, b)
      local an, bn = fold(a.name), fold(b.name)
      if an ~= bn then return an < bn end
      return tostring(a.path or "") < tostring(b.path or "")
    end)
  end
  return out
end

-- Grid cursor movement over `cells` cells laid out row-major in `cols`
-- columns (the picker's last cell is "+ New project", so cells is always
-- at least 1). `key` is one of left/right/up/down/home/end/pgup/pgdn;
-- `page_rows` sizes the pgup/pgdn jump (default 3). No wrapping: upward
-- moves past the first row keep their column, a plain `down` off a full
-- bottom row lands on the last cell (and does nothing when already on
-- the bottom row), and `pgdn` past the end always reaches the last cell.
function M.nav(cursor, key, cells, cols, page_rows)
  cells = math.max(1, cells or 1)
  cols = math.max(1, cols or 1)
  cursor = math.max(1, math.min(cells, cursor or 1))
  local jump = cols * math.max(1, page_rows or 3)
  local r = cursor
  if key == "left" then r = cursor - 1
  elseif key == "right" then r = cursor + 1
  elseif key == "up" then r = cursor - cols
  elseif key == "down" then r = cursor + cols
  elseif key == "pgup" then r = cursor - jump
  elseif key == "pgdn" then r = cursor + jump
  elseif key == "home" then r = 1
  elseif key == "end" then r = cells
  end
  if (key == "up" or key == "pgup") and r < 1 then
    r = (cursor - 1) % cols + 1 -- first row, same column
  elseif key == "down" and r > cells then
    local last_row = (cells - 1) // cols
    r = (cursor - 1) // cols == last_row and cursor or cells
  elseif key == "pgdn" and r > cells then
    r = cells
  end
  return math.max(1, math.min(cells, r))
end

-- Clamp a scroll offset to the scrollable range.
function M.clamp(scroll, content_h, view_h)
  return math.max(0, math.min(scroll or 0,
                              math.max(0, (content_h or 0) - (view_h or 0))))
end

-- The smallest clamped scroll change that brings [y, y+h) (content
-- coordinates) fully into the view window [scroll, scroll+view_h).
function M.ensure_visible(scroll, y, h, content_h, view_h)
  scroll = M.clamp(scroll, content_h, view_h)
  if y < scroll then
    scroll = y
  elseif y + h > scroll + view_h then
    scroll = y + h - view_h
  end
  return M.clamp(scroll, content_h, view_h)
end

return M
