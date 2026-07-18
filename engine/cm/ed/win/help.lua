-- cm.ed.win.help — the documentation reader (D061). A proper RENDERED
-- single-window markdown view (not the code-grid): headings, wrapped
-- paragraphs, bullet lists, code spans/fences, and links drawn as their
-- link TEXT (not the `[..](..)` source). One window navigates in place:
--   click a link          → follow it in THIS window (history pushes)
--   ctrl+click a link      → open it in a NEW help window
--   a link to an ASSET     → opens in the right editor window (sprite/map/…)
-- Header ◀ ▶ walk history (mouse back/forward too); ⌂ returns to the doc
-- list; `src` opens the raw markdown in the code editor. No working state,
-- no journal — spawn from the rclick menu, close it fearlessly.
--
-- Stock docs resolve at the ENGINE root (cwd); the reader reads
-- ed.root-relative and reaches them via ../../engine/stock/docs/* — the
-- same resolve_link convention the code editor uses (shared, exposed).

local M = select(2, ...) or {}
local wm = cm.require("cm.ed.wm")
local docs = cm.require("cm.docs")

M.kind = "help"
M.menu = "help"
M.DEF_W, M.DEF_H = 460, 420

local COL = {
  dim = 0x8a84b0ff, text = 0xcfc9ecff, hot = 0xE8E4FFff,
  h1 = 0xE8E4FFff, h2 = 0xc9bcffff, h3 = 0xb7a9f0ff,
  link = 0x7fb8f0ff, link_hot = 0xbcdcffff,
  code = 0x9fdc8fff, code_bg = 0x20203aff, bold = 0xefeaffff,
  bar = 0x1a1730ff, btn = 0x2a2542ff, btn_hot = 0x3a3560ff,
  row = 0x232038ff, row_hot = 0x322d48ff, rule = 0x35305aff,
  field = 0x141220ff, hl = 0x35406a80,
}

local STOCK = "engine/stock/docs"

-- the shipped-doc list (name/title from cm.docs, the shared search index);
-- PATH is ed.root-relative — the reader's read/navigate convention (docs
-- resolve at the engine root via ../../engine/stock/docs/*)
local function list_docs()
  local out = {}
  for _, d in ipairs(docs.list()) do
    out[#out + 1] = { name = d.name, title = d.title,
                      path = "../../" .. STOCK .. "/" .. d.name }
  end
  return out
end

-- the ed.root-relative reader path for a stock doc basename (a search hit)
local function stock_path(name) return "../../" .. STOCK .. "/" .. name end

-- cross-doc search, memoized on the last query (module-local, never captured):
-- the home view recomputes every frame while typing, but the query is stable
-- frame-to-frame so we parse the corpus once per distinct query
local last_q, last_res
local function search_results(q)
  if q ~= last_q then last_q, last_res = q, docs.search(q) end
  return last_res
end

function M.defaults() return { path = "", scroll = 0, q = "" } end

function M.title(win)
  local p = win.path or ""
  if p == "" then return "help" end
  return (p:match("([^/]+)$") or "help"):gsub("%.md$", "")
end

-- ---- navigation (history rides win.hist / win.hpos, captured) ----

local function navigate(win, path, nohist, opts)
  if not nohist then
    win.hist = win.hist or { win.path or "" }
    win.hpos = win.hpos or #win.hist
    for k = #win.hist, win.hpos + 1, -1 do win.hist[k] = nil end
    win.hist[#win.hist + 1] = path
    win.hpos = #win.hist
  end
  win.path = path
  win.scroll = 0
  win._src, win._srcpath = nil, nil
  -- an optional source line to reveal on arrival (a search hit or a #anchor);
  -- hl_line lights it until the next scroll/navigate
  win.goto_line = opts and opts.line or nil
  win.hl_line = win.goto_line
end

local function hist_go(win, dir)
  if not win.hist then return end
  local np = (win.hpos or #win.hist) + dir
  if np < 1 or np > #win.hist then return end
  win.hpos = np
  navigate(win, win.hist[np], true)
end
M.hist_go = hist_go

-- per-window hotkeys (EDITOR.md §13): [ back · ] forward · h home; the hint
-- strip renders them under the focused reader
M.hotkeys = {
  { key = "[", hint = "back",
    when = function(win) return win.hist and (win.hpos or 1) > 1 end,
    fn = function(win) hist_go(win, -1) end },
  { key = "]", hint = "forward",
    when = function(win)
      return win.hist and (win.hpos or #win.hist) < #win.hist
    end,
    fn = function(win) hist_go(win, 1) end },
  { key = "h", hint = "home",
    when = function(win) return win.path ~= "" end,
    fn = function(win) navigate(win, "") end },
}

-- the source line of a doc's #anchor (the heading whose slug matches), or nil
local function anchor_line(ed, rp, frag)
  local src = pal.read_file(ed.root .. "/" .. rp)
  if not src then return nil end
  frag = frag:lower()
  for _, s in ipairs(docs.sections(src)) do
    if docs.heading_slug(s.title) == frag then return s.line end
  end
  return nil
end

-- follow a link target: markdown navigates the reader (ctrl = a new reader
-- window); a `#anchor` reveals that heading (same-doc anchors jump in place);
-- any other asset opens in its proper editor window
local function follow(win, ed, target, newwin)
  local text = cm.require("cm.ed.win.text")
  local frag = target:match("#([^#]*)$")
  if target:sub(1, 1) == "#" then -- a same-doc anchor
    local line = frag and anchor_line(ed, win.path, frag)
    if line then win.goto_line, win.hl_line = line, line; ed.touch() end
    return
  end
  local rp = text.resolve_link(ed, target)
  if not rp then
    pal.log("[help] dead link: " .. tostring(target))
    return
  end
  if rp:lower():find("%.md$") then
    local opts = frag and { line = anchor_line(ed, rp, frag) } or nil
    if newwin then
      local nw = wm.spawn(ed.doc, "help", win.x + 28, win.y + 28,
                          win.w, win.h, M.defaults())
      navigate(nw, rp, false, opts)
    else
      navigate(win, rp, false, opts)
    end
  else
    ed.open_asset_window(rp, win.x + win.w + 20, win.y)
  end
end

-- ---- inline markdown: [text](url), `code`, **bold** ----

local function parse_inline(s)
  local segs, pos = {}, 1
  local function emit(txt)
    if txt ~= "" then segs[#segs + 1] = { t = "text", s = txt } end
  end
  while pos <= #s do
    local best, kind
    local la, lb, lt, lu = s:find("%[([^%]]*)%]%(([^%)]+)%)", pos)
    local ca, cb, ct = s:find("`([^`]+)`", pos)
    local ba, bb, bt = s:find("%*%*([^%*]+)%*%*", pos)
    if la then best, kind = la, "link" end
    if ca and (not best or ca < best) then best, kind = ca, "code" end
    if ba and (not best or ba < best) then best, kind = ba, "bold" end
    if not best then emit(s:sub(pos)); break end
    if kind == "link" then
      emit(s:sub(pos, la - 1))
      segs[#segs + 1] = { t = "link", s = lt ~= "" and lt or lu, url = lu }
      pos = lb + 1
    elseif kind == "code" then
      emit(s:sub(pos, ca - 1))
      segs[#segs + 1] = { t = "code", s = ct }
      pos = cb + 1
    else
      emit(s:sub(pos, ba - 1))
      segs[#segs + 1] = { t = "bold", s = bt }
      pos = bb + 1
    end
  end
  return segs
end

-- draw a run of inline segments, wrapping at maxw; collect link rects into
-- `links`. Returns the y after the block.
local function draw_inline(segs, x0, y0, maxw, px, links, i, ctx, z)
  local x, y = x0, y0
  local lh = px * 1.5
  local spacew = pal.x_ig_text_size(" ", px, 0)
  local function newline() x = x0; y = y + lh end
  for _, seg in ipairs(segs) do
    if seg.t == "link" or seg.t == "code" then
      local font = seg.t == "code" and 1 or 0
      local ww = pal.x_ig_text_size(seg.s, px, font)
      if x + ww > x0 + maxw and x > x0 then newline() end
      if seg.t == "code" then
        pal.x_ig_rect_fill(x - 1, y - 1, ww + 2, px + 2, COL.code_bg, 2 * z)
        pal.x_ig_text(x, y, px, COL.code, seg.s, 1)
      else
        local hot = ctx.hot and i.wx >= x and i.wx < x + ww
                    and i.wy >= y and i.wy < y + px
        local col = hot and COL.link_hot or COL.link
        pal.x_ig_text(x, y, px, col, seg.s, 0)
        pal.x_ig_line(x, y + px, x + ww, y + px, col, math.max(1, z))
        links[#links + 1] = { x = x, y = y, w = ww, h = px, url = seg.url }
      end
      x = x + ww + spacew
    else
      local face = seg.t == "bold" and COL.bold or COL.text
      for word in seg.s:gmatch("%S+") do
        local ww = pal.x_ig_text_size(word, px, 0)
        if x + ww > x0 + maxw and x > x0 then newline() end
        pal.x_ig_text(x, y, px, face, word, 0)
        x = x + ww + spacew
      end
    end
  end
  return y + lh
end

-- ---- the reader ----

local function read_doc(win, ed)
  if win._srcpath == win.path then return win._src end
  win._src = pal.read_file(ed.root .. "/" .. win.path) or ""
  win._srcpath = win.path
  return win._src
end

-- render the markdown body; returns the content height (for scroll clamp)
local function draw_doc(win, ed, src, x0, y0, maxw, px, links, i, ctx, z)
  local y = y0
  local fence = false
  -- iterate the SAME line split cm.docs numbers by, so a search hit's line
  -- (and a #anchor) map to the right rendered row
  local ls, n = docs._lines(src)
  for ln = 1, n do
    local line = ls[ln]
    if win.goto_line == ln then win._goto_y = y end
    if win.hl_line == ln then
      pal.x_ig_rect_fill(x0 - 3 * z, y - 1, maxw + 6 * z, px * 1.5 + 2,
                         COL.hl, 3 * z)
    end
    local fenced = line:match("^%s*```")
    if fenced then
      fence = not fence
    elseif fence or line:match("^    %S") then -- code block (fence or indent)
      pal.x_ig_rect_fill(x0, y - 1, maxw, px + 3, COL.code_bg, 0)
      pal.x_ig_text(x0 + 4 * z, y, px, COL.code, (line:gsub("^    ", "")), 1)
      y = y + px * 1.5
    else
      local h = line:match("^(#+)%s")
      if h then
        local lvl = #h
        local hpx = lvl == 1 and px * 1.7 or lvl == 2 and px * 1.32 or px * 1.12
        local face = lvl == 1 and COL.h1 or lvl == 2 and COL.h2 or COL.h3
        y = y + (lvl == 1 and px * 0.7 or px * 0.5)
        pal.x_ig_text(x0, y, hpx, face, line:gsub("^#+%s*", ""), 0)
        y = y + hpx * 1.35
        if lvl == 1 then
          pal.x_ig_line(x0, y - px * 0.4, x0 + maxw, y - px * 0.4, COL.rule, 1)
        end
      elseif line:match("^%s*[%-%*]%s") then -- a bullet
        local body = line:gsub("^%s*[%-%*]%s+", "")
        pal.x_ig_circle_fill(x0 + 3 * z, y + px * 0.5, math.max(1.5, 2 * z),
                             COL.dim)
        y = draw_inline(parse_inline(body), x0 + 14 * z, y, maxw - 14 * z, px,
                        links, i, ctx, z)
      elseif line:match("^%s*$") then -- blank: paragraph gap
        y = y + px * 0.6
      else
        y = draw_inline(parse_inline(line), x0, y, maxw, px, links, i, ctx, z)
      end
    end
  end
  return y - y0
end

-- a header button; returns true when clicked
local function hbtn(x, y, w, h, label, on, i, ctx, z, px)
  local hot = ctx.hot and i.wx >= x and i.wx < x + w
              and i.wy >= y and i.wy < y + h
  pal.x_ig_rect_fill(x, y, w, h, hot and COL.btn_hot or COL.btn, 3 * z)
  pal.x_ig_text(x + (w - pal.x_ig_text_size(label, px, 0)) * 0.5,
                y + (h - px) * 0.5, px, (hot and on) and COL.hot
                or on and COL.text or COL.dim, label, 0)
  return hot and i.clicked[1]
end

function M.wheel(win, ed, delta)
  win.scroll = math.max(0, (win.scroll or 0) - delta * 40)
  win.hl_line = nil -- scrolling dismisses the "landed here" marker
  return true
end

function M.draw(win, ctx)
  local i = cm.require("cm.ui").inp
  local ed = ctx.ed
  local z = ctx.z
  local px = math.max(6, 13 * z)
  local pad = 8 * z
  win.scroll = win.scroll or 0
  win.path = win.path or "" -- old restored windows predate the path field

  -- header bar: ◀ ▶ · ⌂ home · title · src
  local bh = px * 1.8
  local bx, by = ctx.cx + pad, ctx.cy + 5 * z
  local canback = win.hist and (win.hpos or 1) > 1
  local canfwd = win.hist and (win.hpos or #win.hist) < #win.hist
  pal.x_ig_rect_fill(ctx.cx, ctx.cy, ctx.cw, bh + 6 * z, COL.bar, 0)
  local bw = px * 1.6
  if hbtn(bx, by, bw, bh, "◀", canback, i, ctx, z, px) and canback then
    hist_go(win, -1)
  end
  bx = bx + bw + 3 * z
  if hbtn(bx, by, bw, bh, "▶", canfwd, i, ctx, z, px) and canfwd then
    hist_go(win, 1)
  end
  bx = bx + bw + 6 * z
  local homew = px * 3.2
  if hbtn(bx, by, homew, bh, "docs", win.path ~= "", i, ctx, z, px)
     and win.path ~= "" then
    navigate(win, "")
  end
  bx = bx + homew + 10 * z
  -- title
  local title = win.path == "" and "documentation"
                or (win.path:match("([^/]+)$") or ""):gsub("%.md$", "")
  -- src button (right)
  local srcw = px * 3
  if win.path ~= "" then
    if hbtn(ctx.cx + ctx.cw - pad - srcw, by, srcw, bh, "src", true,
            i, ctx, z, px) then
      ed.open_asset_window(win.path, win.x + win.w + 20, win.y)
    end
  end
  pal.x_ig_text(bx, by + (bh - px) * 0.5, px, COL.hot, title, 0)

  -- body
  local topy = ctx.cy + bh + 10 * z
  local x0 = ctx.cx + pad
  local maxw = ctx.cw - pad * 2
  local links = {}
  local contenth

  -- the home view reserves a FIXED search strip above the scroll region
  local sy0 = topy
  local sh = ctx.cy + ctx.ch - 4 * z - topy
  local results
  if win.path == "" then
    local fh = px * 1.9
    pal.x_ig_rect_fill(x0, topy, maxw, fh, COL.field, 5 * z)
    if (win.q or "") == "" then
      pal.x_ig_text(x0 + 10 * z, topy + (fh - px) * 0.5, px, COL.dim,
                    "search the docs — a module, a task, a term…", 0)
    end
    local qt = pal.x_ig_edit {
      id = "help.q." .. win.id, x = x0 + 8 * z,
      y = topy + (fh - px) * 0.5 - 2 * z, w = maxw - 16 * z, h = px + 4 * z,
      text = win.q or "", px = px, font = 0, multiline = false,
    }
    if qt ~= (win.q or "") then
      win.q = qt:gsub("[\r\n\t]", "")
      win.scroll = 0
    end
    sy0 = topy + fh + 8 * z
    sh = ctx.cy + ctx.ch - 4 * z - sy0
    if (win.q or "") ~= "" then results = search_results(win.q) end
  end

  pal.x_ig_clip_push(ctx.cx, sy0, ctx.cw, sh)
  local y = sy0 - win.scroll
  local inband = function(ry, rh)
    return ctx.hot and i.wx >= x0 and i.wx < x0 + maxw and i.wy >= sy0
           and i.wy < sy0 + sh and i.wy >= ry and i.wy < ry + rh
  end

  if win.path == "" and results then
    -- ranked cross-doc search results
    if #results == 0 then
      pal.x_ig_text(x0, y, px, COL.dim, "no matches", 0)
      contenth = px * 1.8
    else
      pal.x_ig_text(x0, y, px * 0.85, COL.dim,
                    ("%d result%s"):format(#results, #results == 1 and "" or "s"), 0)
      y = y + px * 1.5
      local rh = px * 3.1
      for _, h in ipairs(results) do
        local hov = inband(y, rh - 4 * z)
        pal.x_ig_rect_fill(x0, y, maxw, rh - 4 * z, hov and COL.row_hot or COL.row,
                           4 * z)
        pal.x_ig_clip_push(x0, y, maxw, rh)
        pal.x_ig_text(x0 + 9 * z, y + 5 * z, px * 0.9, hov and COL.hot or COL.h2,
                      h.title .. "  ·  " .. h.section, 0)
        pal.x_ig_text(x0 + 9 * z, y + px * 1.55, px * 0.82, COL.dim, h.snippet, 0)
        pal.x_ig_clip_pop()
        if hov and i.clicked[1] then
          navigate(win, stock_path(h.name), false, { line = h.line })
        end
        y = y + rh
      end
      contenth = (y + win.scroll) - sy0
    end
  elseif win.path == "" then
    -- the browse list (empty query)
    pal.x_ig_text(x0, y, px, COL.dim, "the shipped docs — click to read:", 0)
    y = y + px * 1.8
    local rh = px * 2
    for _, d in ipairs(list_docs()) do
      local hov = inband(y, rh)
      pal.x_ig_rect_fill(x0, y, maxw, rh, hov and COL.row_hot or COL.row, 4 * z)
      pal.x_ig_text(x0 + 10 * z, y + (rh - px) * 0.5, px,
                    hov and COL.hot or COL.text, d.title, 0)
      if hov and i.clicked[1] then navigate(win, d.path) end
      y = y + rh + 5 * z
    end
    contenth = (y + win.scroll) - sy0
  else
    local src = read_doc(win, ed)
    win._goto_y = nil
    contenth = draw_doc(win, ed, src, x0, y, maxw, px, links, i, ctx, z)
  end
  pal.x_ig_clip_pop()

  -- a slim scrollbar when the content overflows
  local maxscroll = math.max(0, contenth - sh)
  if maxscroll > 0 then
    local knobh = math.max(20 * z, sh * sh / contenth)
    local knoby = sy0 + (sh - knobh) * (win.scroll / maxscroll)
    pal.x_ig_rect_fill(ctx.cx + ctx.cw - 4 * z, knoby, 3 * z, knobh,
                       COL.rule, 2 * z)
  end
  win.scroll = math.max(0, math.min(win.scroll, maxscroll))

  -- reveal a pending goto line (a search hit / #anchor): draw_doc measured its
  -- screen y this frame; scroll it near the top and adopt next frame
  if win.goto_line and win._goto_y then
    win.scroll = math.max(0, math.min(win.scroll + (win._goto_y - sy0) - px,
                                      maxscroll))
    win.goto_line, win._goto_y = nil, nil
    ed.touch()
  end

  -- link clicks (over the body only)
  if ctx.hot and i.clicked[1] and i.wy >= sy0 then
    for _, lk in ipairs(links) do
      if i.wx >= lk.x and i.wx < lk.x + lk.w and i.wy >= lk.y
         and i.wy < lk.y + lk.h then
        follow(win, ed, lk.url, ed.g.ctrl and not ctx.alt)
        break
      end
    end
  end
  -- mouse back / forward buttons walk history
  if ctx.focused then
    if i.clicked[4] then hist_go(win, -1) end
    if i.clicked[5] then hist_go(win, 1) end
  end
end

return M
