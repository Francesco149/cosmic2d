-- cm.ed.win.help — the documentation reader (D061). A proper RENDERED
-- single-window markdown view (not the code-grid): headings, wrapped
-- paragraphs, bullet lists, code spans/fences, and links drawn as their
-- link TEXT (not the `[..](..)` source). One window navigates in place:
--   click a link          → follow it in THIS window (history pushes)
--   ctrl+click a link      → open it in a NEW help window BESIDE this one
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
local lex = cm.require("cm.ed.lex")

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
  field = 0x141220ff, hl = 0x35406a80, sel = 0x5a74c455,
}

-- syntax faces for code blocks — the code editor's exact palette (cm.ed.lex
-- kinds), so a lua sample reads the same in the reader as in the editor. The
-- base face covers identifiers/operators and whole "text" (shell) blocks.
local CODE_FACE = {
  base = 0xd8d2f2ff, kw = 0xc792eaff, str = 0x9fdc8fff,
  num = 0xf2b46eff, com = 0x7a7498ff,
}

-- the copy-feedback dwell (ns): how long a chip / the header button reads
-- "copied" after a click, on the wall clock (the editor redraws every frame)
local COPIED_MS = 1200

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

-- transient per-window selection state, module-local and keyed by win.id —
-- deliberately NOT fields on the captured window: the row model is rebuilt
-- every frame and can be large, and every string key on a win rides
-- state.canon into session.dat. Holds: rows (the run model), a/b (endpoints),
-- drag/moved (the gesture), copy_t (the ctrl+C flash), w (the layout width
-- the rows were built at).
local SEL = {}
function M.sel_state(win)
  local s = SEL[win.id or 0]
  if not s then
    s = {}
    SEL[win.id or 0] = s
  end
  return s
end

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
  win._copied, win._copied_t, win._pagecopy_t = nil, nil, nil -- copy feedback
  SEL[win.id or 0] = nil -- a new doc invalidates the selection + row model
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

-- the scrollbar's pure math (KAT'd; draw feeds it live values): knob
-- geometry from the scroll state, and the scroll a drag position targets
function M.sb_knob(scroll, maxscroll, contenth, sh, sy0, z)
  local knobh = math.max(20 * z, sh * sh / contenth)
  return sy0 + (sh - knobh) * (scroll / maxscroll), knobh
end

function M.sb_target(my, grab, sy0, sh, knobh, maxscroll)
  local t = (my - grab - sy0) / math.max(1, sh - knobh)
  return math.max(0, math.min(t * maxscroll, maxscroll))
end

-- keyboard scrolling (the human's ask): clamped like M.wheel, against last
-- frame's measured extent; win._band is the visible band height from draw
local function scroll_by(win, dy)
  win.scroll = math.max(0, math.min((win.scroll or 0) + dy,
                                    win._maxscroll or math.huge))
  win.hl_line = nil -- scrolling dismisses the "landed here" marker
end
M.scroll_by = scroll_by

local function overflows(win) return (win._maxscroll or 0) > 0 end

-- per-window hotkeys (EDITOR.md §13): [ back · ] forward · h home, plus the
-- reading keys — PgUp/PgDn page, Home/End (and Ctrl+PgUp/PgDn) jump to the
-- top/bottom; the hint strip renders the hinted ones under the focused reader
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
  { key = "pgdn", hint = "scroll", when = overflows, rep = true,
    fn = function(win) scroll_by(win, (win._band or 300) * 0.9) end },
  { key = "pgup", when = overflows, rep = true,
    fn = function(win) scroll_by(win, -(win._band or 300) * 0.9) end },
  { key = "home", hint = "top", when = overflows,
    fn = function(win) scroll_by(win, -math.huge) end },
  { key = "end", when = overflows,
    fn = function(win) scroll_by(win, math.huge) end },
  { key = "ctrl+pgup", when = overflows,
    fn = function(win) scroll_by(win, -math.huge) end },
  { key = "ctrl+pgdn", when = overflows,
    fn = function(win) scroll_by(win, math.huge) end },
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
      -- beside the current reader, matched dimensions (the cross-open
      -- convention): reading forks into a side-by-side pair
      local nw = wm.spawn(ed.doc, "help", win.x + win.w + 16, win.y,
                          win.w, win.h, M.defaults())
      navigate(nw, rp, false, opts)
      ed.doc.focus = nw.id
      ed.reveal_window(nw, ed.g.last_ig)
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

-- ---- the selection row model (true drag-select + copy) ----
--
-- While a doc renders, every drawn text run is recorded into `rows`: one row
-- per VISUAL line, holding its runs in reading order with doc-space coords
-- (x relative to the text left edge, y relative to the content top — so
-- scroll and window moves never invalidate them). Selection endpoints are
-- {ri, ci}: a row index + a 0-based byte offset into the row's JOINED text
-- (runs concatenated, a single space standing in for each horizontal gap —
-- exactly what the eye reads). The pick/x/extract math below is pure over
-- that structure (measure is injected), so the selftest KATs pin it with a
-- fake monospace measure; the reader passes pal.x_ig_text_size.

-- step one utf8 codepoint: the byte AFTER the char starting at byte `i`
local function utf8_next(s, i)
  local c = s:byte(i)
  return i + (c < 0x80 and 1 or c < 0xE0 and 2 or c < 0xF0 and 3 or 4)
end

-- build each row's joined text + every run's j0 (its 0-based offset into it);
-- a gap between runs wider than half a pixel joins as one space
function M.rows_finalize(rows)
  for _, r in ipairs(rows) do
    local t, j = {}, 0
    for k, run in ipairs(r.runs) do
      local prev = r.runs[k - 1]
      if prev and run.x > prev.x + prev.w + 0.5 then
        t[#t + 1] = " "
        j = j + 1
      end
      run.j0 = j
      t[#t + 1] = run.s
      j = j + #run.s
    end
    r.text = table.concat(t)
  end
end

-- doc-space x -> byte offset into the row's joined text, snapped to the
-- nearest codepoint boundary (a click in a gap lands on its edge)
function M.row_pick(row, x, measure)
  for _, run in ipairs(row.runs) do
    if x < run.x then return run.j0 end
    if x < run.x + run.w then
      local pos, wprev = 1, 0
      while pos <= #run.s do
        local nx = utf8_next(run.s, pos)
        local wnext = measure(run.s:sub(1, nx - 1), run.px, run.font)
        if x < run.x + (wprev + wnext) * 0.5 then return run.j0 + pos - 1 end
        pos, wprev = nx, wnext
      end
      return run.j0 + #run.s
    end
  end
  local last = row.runs[#row.runs]
  return last and (last.j0 + #last.s) or 0
end

-- byte offset -> doc-space x (the caret edge of that offset)
function M.row_x(row, ci, measure)
  local endx = 0
  for _, run in ipairs(row.runs) do
    if ci <= run.j0 then return run.x end
    if ci <= run.j0 + #run.s then
      return run.x + measure(run.s:sub(1, ci - run.j0), run.px, run.font)
    end
    endx = run.x + run.w
  end
  return endx
end

-- doc-space point -> selection endpoint {ri, ci}, clamped into the doc
function M.rows_pick(rows, x, y, measure)
  if #rows == 0 then return nil end
  if y < rows[1].y then return { ri = 1, ci = 0 } end
  for ri, r in ipairs(rows) do
    local nxt = rows[ri + 1]
    if y < (nxt and nxt.y or r.y + r.h) then
      return { ri = ri, ci = M.row_pick(r, x, measure) }
    end
  end
  local lr = rows[#rows]
  return { ri = #rows, ci = #(lr.text or "") }
end

-- a..b in reading order (endpoints may arrive reversed)
local function sel_norm(a, b)
  if b.ri < a.ri or (b.ri == a.ri and b.ci < a.ci) then return b, a end
  return a, b
end

-- the selected text: middle rows whole, end rows sliced at their offsets.
-- Rows joining rule: the SAME source line (a wrap) rejoins with the space the
-- wrap consumed; the next source line is a newline; a jump of 2+ source lines
-- crossed a blank — a paragraph break.
function M.sel_text(rows, a, b)
  a, b = sel_norm(a, b)
  local out = {}
  for ri = a.ri, math.min(b.ri, #rows) do
    local r = rows[ri]
    local s = r.text or ""
    if ri > a.ri then
      local dl = r.ln - rows[ri - 1].ln
      out[#out + 1] = dl == 0 and " " or dl == 1 and "\n" or "\n\n"
    end
    local lo = ri == a.ri and a.ci or 0
    local hi = ri == b.ri and b.ci or #s
    out[#out + 1] = s:sub(lo + 1, hi)
  end
  return table.concat(out)
end

-- ---- layout (once per doc/width/font) ----
--
-- The reader is retained-mode for perf (D113): rendering a doc every frame —
-- one text_size + one draw call per WORD over the whole document — cost
-- ~7.5 ms/frame before selection even existed, and the D112 row model doubled
-- it. layout_doc runs ONCE per (src, width, px, z) and produces everything a
-- frame needs, in doc-space coords: the selection row model (runs now carry
-- their face), a decoration list (block panels, inline-code chips, bullet
-- dots, heading rules), the link rects, and a source-line -> y map (goto /
-- landed-highlight targets). paint_doc then draws only the rows/decor
-- intersecting the visible band — no measuring, no allocation.

local function lrow(L, y, h, ln)
  local r = { y = y, h = h, ln = ln, runs = {} }
  L.rows[#L.rows + 1] = r
  return r
end

local function lrun(row, x, w, s, font, px, col, url)
  row.runs[#row.runs + 1] = { x = x, w = w, s = s, font = font, px = px,
                              col = col, url = url }
end

-- lay out a run of inline segments, wrapping at x0+maxw; returns the y after
local function layout_inline(L, segs, x0, y0, maxw, px, z, ln)
  local x, y = x0, y0
  local lh = px * 1.5
  local spacew = pal.x_ig_text_size(" ", px, 0)
  local row = lrow(L, y, lh, ln)
  local function newline()
    x, y = x0, y + lh
    row = lrow(L, y, lh, ln)
  end
  for _, seg in ipairs(segs) do
    if seg.t == "link" or seg.t == "code" then
      local font = seg.t == "code" and 1 or 0
      local ww = pal.x_ig_text_size(seg.s, px, font)
      if x + ww > x0 + maxw and x > x0 then newline() end
      if seg.t == "code" then
        L.decor[#L.decor + 1] = { t = "rect", x = x - 1, y = y - 1,
                                  w = ww + 2, h = px + 2, col = COL.code_bg,
                                  rad = 2 * z }
        lrun(row, x, ww, seg.s, 1, px, COL.code)
      else
        lrun(row, x, ww, seg.s, 0, px, COL.link, seg.url)
        L.links[#L.links + 1] = { x = x, y = y, w = ww, h = px, url = seg.url }
      end
      x = x + ww + spacew
    else
      local face = seg.t == "bold" and COL.bold or COL.text
      for word in seg.s:gmatch("%S+") do
        local ww = pal.x_ig_text_size(word, px, 0)
        if x + ww > x0 + maxw and x > x0 then newline() end
        lrun(row, x, ww, word, 0, px, face)
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

-- lay out one dedented code line as colored lexer runs (mono font 1); the
-- gaps between tokens take the base code face. `toks` are cm.ed.lex 1-based
-- inclusive byte ranges; the caller threads the multi-line carry.
local function layout_code_line(row, x, px, s, toks)
  if #s == 0 then return end
  local function span(a, b, col)
    if b < a then return end
    local seg = s:sub(a, b)
    lrun(row, x + pal.x_ig_text_size(s:sub(1, a - 1), px, 1),
         pal.x_ig_text_size(seg, px, 1), seg, 1, px, col)
  end
  local posb = 1
  for _, t in ipairs(toks) do
    if t.a > posb then span(posb, t.a - 1, CODE_FACE.base) end
    span(t.a, t.b, CODE_FACE[t.k] or CODE_FACE.base)
    posb = t.b + 1
  end
  if posb <= #s then span(posb, #s, CODE_FACE.base) end
end

-- flatten inline segments to their DISPLAYED text (drops `code`/**bold**/link
-- markup, keeps the words) — the parse the reader already renders by
local function flatten_inline(segs)
  local t = {}
  for _, seg in ipairs(segs) do t[#t + 1] = seg.s end
  return table.concat(t)
end

-- the whole doc as plain, un-marked text for the clipboard (the header "copy
-- page"): headings lose their #, bullets become "- ", inline markup flattens to
-- shown text, code blocks dedent verbatim, ``` fence markers drop.
local function page_text(src)
  local kind, ls, n = docs.line_kinds(src)
  local out = {}
  for ln = 1, n do
    local line = ls[ln]
    local k = kind[ln]
    if k == "fence" then                                    -- drop the ``` line
    elseif k == "code" then
      out[#out + 1] = (line:gsub("^    ", ""))
    elseif line:match("^#+%s") then
      out[#out + 1] = line:gsub("^#+%s*", "")
    elseif line:match("^%s*[%-%*]%s") then
      out[#out + 1] = "- " .. flatten_inline(parse_inline(
        (line:gsub("^%s*[%-%*]%s+", ""))))
    elseif line:match("^%s*$") then
      out[#out + 1] = ""
    else
      out[#out + 1] = flatten_inline(parse_inline(line))
    end
  end
  return table.concat(out, "\n")
end

-- lay out the whole markdown body into doc-space rows/decor/links (see the
-- D113 note above layout_inline); everything else about a frame is paint.
local function layout_doc(src, maxw, px, z)
  local L = { rows = {}, decor = {}, links = {}, liney = {} }
  local y = 0
  -- classify code vs prose once (pure, KAT-pinned) over the SAME line split
  -- cm.docs numbers by, so a search hit's line (and a #anchor) map to the right
  -- rendered row. "code" covers a whole fenced/indented block — every nested
  -- line and interior blank — not just the first line.
  local kind, ls, n = docs.line_kinds(src)
  -- map every code line to its block (contiguous run); the lua lexer's carry
  -- threads WITHIN a block (multi-line strings/comments) and resets between
  -- blocks. blocks[bi]._y0/_y1 get the block's doc-space span (panel + chip).
  local blocks = docs.code_blocks(src)
  L.blocks = blocks
  local block_of = {}
  for bi, b in ipairs(blocks) do
    for ln = b.lo, b.hi do block_of[ln] = bi end
  end
  local lh = px * 1.5
  local bpad = 3 * z -- the code panel's vertical padding
  local carry, cur_bi = "", nil
  for ln = 1, n do
    local line = ls[ln]
    L.liney[ln] = y
    local k = kind[ln]
    if k == "fence" then
      -- a ``` marker line: draw nothing, take no vertical space
    elseif k == "code" then
      local bi = block_of[ln]
      local b = blocks[bi]
      if bi ~= cur_bi then
        -- ONE panel for the whole block (its height is known: contiguous
        -- code lines at a fixed advance), not a rect per line
        carry, cur_bi = "", bi
        b._y0 = y
        b._y1 = y + (b.hi - b.lo + 1) * lh + 2 * bpad
        L.decor[#L.decor + 1] = { t = "rect", x = 0, y = b._y0, w = maxw,
                                  h = b._y1 - b._y0, col = COL.code_bg,
                                  rad = 4 * z }
        y = y + bpad
      end
      L.liney[ln] = y -- where the line's text actually sits (post-pad)
      local dline = line:gsub("^    ", "")
      local row = lrow(L, y, lh, ln)
      if b.lang == "lua" then
        local toks
        toks, carry = lex.line("lua", dline, carry)
        layout_code_line(row, 4 * z, px, dline, toks)
      elseif #dline > 0 then
        lrun(row, 4 * z, pal.x_ig_text_size(dline, px, 1), dline, 1, px,
             CODE_FACE.base)
      end
      y = y + lh
      if ln == b.hi then y = y + bpad end
    else
      local h = line:match("^(#+)%s")
      if h then
        local lvl = #h
        local hpx = lvl == 1 and px * 1.7 or lvl == 2 and px * 1.32 or px * 1.12
        local face = lvl == 1 and COL.h1 or lvl == 2 and COL.h2 or COL.h3
        y = y + (lvl == 1 and px * 0.7 or px * 0.5)
        L.liney[ln] = y
        local shown = line:gsub("^#+%s*", "")
        local row = lrow(L, y, hpx * 1.35, ln)
        lrun(row, 0, pal.x_ig_text_size(shown, hpx, 0), shown, 0, hpx, face)
        y = y + hpx * 1.35
        if lvl == 1 then
          L.decor[#L.decor + 1] = { t = "line", x = 0, y = y - px * 0.4,
                                    x2 = maxw, col = COL.rule }
        end
      elseif line:match("^%s*[%-%*]%s") then -- a bullet
        local body = line:gsub("^%s*[%-%*]%s+", "")
        L.decor[#L.decor + 1] = { t = "circle", x = 3 * z, y = y + px * 0.5,
                                  rad = math.max(1.5, 2 * z), col = COL.dim }
        y = layout_inline(L, parse_inline(body), 14 * z, y, maxw - 14 * z, px,
                          z, ln)
      elseif line:match("^%s*$") then -- blank: paragraph gap
        y = y + px * 0.6
      else
        y = layout_inline(L, parse_inline(line), 0, y, maxw, px, z, ln)
      end
    end
  end
  L.contenth = y
  M.rows_finalize(L.rows)
  return L
end

-- paint the visible band from the layout: decor, the landed-line highlight,
-- the selection highlight, then text runs (links pick their hover face and
-- underline live). Doc-space -> screen is x0/yoff; `lo..hi` is the band.
local function paint_doc(win, L, x0, yoff, maxw, px, z, i, ctx, hlmap, sh)
  local lo, hi = win.scroll, win.scroll + sh
  for _, d in ipairs(L.decor) do
    local dh = d.h or (d.rad and d.rad * 2) or 2
    if d.y + dh >= lo - px and d.y <= hi + px then
      if d.t == "rect" then
        pal.x_ig_rect_fill(x0 + d.x, yoff + d.y, d.w, d.h, d.col, d.rad)
      elseif d.t == "circle" then
        pal.x_ig_circle_fill(x0 + d.x, yoff + d.y, d.rad, d.col)
      else
        pal.x_ig_line(x0 + d.x, yoff + d.y, x0 + d.x2, yoff + d.y, d.col, 1)
      end
    end
  end
  if win.hl_line and L.liney[win.hl_line] then
    pal.x_ig_rect_fill(x0 - 3 * z, yoff + L.liney[win.hl_line] - 1,
                       maxw + 6 * z, px * 1.5 + 2, COL.hl, 3 * z)
  end
  if hlmap then
    for ri, hlr in pairs(hlmap) do
      local r = L.rows[ri]
      if r and r.y + r.h >= lo and r.y <= hi then
        pal.x_ig_rect_fill(x0 + hlr.a, yoff + r.y - 1, hlr.b - hlr.a, r.h,
                           COL.sel, 0)
      end
    end
  end
  for _, r in ipairs(L.rows) do
    if r.y > hi then break end -- rows ascend
    if r.y + r.h >= lo then
      for _, run in ipairs(r.runs) do
        local col = run.col
        if run.url then
          local hot = ctx.hot and i.wx >= x0 + run.x
                      and i.wx < x0 + run.x + run.w
                      and i.wy >= yoff + r.y and i.wy < yoff + r.y + run.px
          col = hot and COL.link_hot or COL.link
          pal.x_ig_line(x0 + run.x, yoff + r.y + run.px,
                        x0 + run.x + run.w, yoff + r.y + run.px, col,
                        math.max(1, z))
        end
        pal.x_ig_text(x0 + run.x, yoff + r.y, run.px, col, run.s, run.font)
      end
    end
  end
end

-- the hover "copy" chip over each code block (drawn inside the scroll clip, so
-- it clips to the band; sticky to the band's top while a tall block scrolls).
-- Copies the block's dedented source and flashes "copied". Block extents are
-- doc-space; yoff converts to screen.
local function draw_copy_chips(win, blocks, x0, yoff, maxw, sy0, sh, px, z,
                               i, ctx)
  if not blocks then return end
  local now = pal.time_ns()
  local cpx = math.max(6, px * 0.82)
  for bi, b in ipairs(blocks) do
    local y0s = b._y0 and yoff + b._y0
    local y1s = b._y1 and yoff + b._y1
    if y0s and y1s and y1s > sy0 and y0s < sy0 + sh then
      local copied = win._copied == bi and win._copied_t
                     and (now - win._copied_t) < COPIED_MS * 1000000
      local label = copied and "copied" or "copy"
      local lw = pal.x_ig_text_size(label, cpx, 0)
      local cw, ch = lw + 12 * z, cpx + 6 * z
      local cx = x0 + maxw - cw - 4 * z
      local cy = math.max(sy0 + 3 * z,
                          math.min(y0s + 3 * z, y1s - ch - 3 * z,
                                   sy0 + sh - ch - 3 * z))
      local hot = ctx.hot and i.wx >= cx and i.wx < cx + cw
                  and i.wy >= cy and i.wy < cy + ch
                  and i.wy >= sy0 and i.wy < sy0 + sh
      pal.x_ig_rect_fill(cx, cy, cw, ch, hot and COL.btn_hot or COL.btn, 3 * z)
      pal.x_ig_text(cx + (cw - lw) * 0.5, cy + (ch - cpx) * 0.5, cpx,
                    copied and COL.code or (hot and COL.hot or COL.dim),
                    label, 0)
      if hot and i.clicked[1] then
        pal.x_clipboard(b.text)
        win._copied, win._copied_t = bi, now
      end
    end
  end
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

-- Ctrl+C (the shell's kind_call("copy")): the drag selection to the clipboard
function M.copy(win, ed)
  local sl = M.sel_state(win)
  if win.path == "" or not sl.a or not sl.b or not sl.rows
     or (sl.a.ri == sl.b.ri and sl.a.ci == sl.b.ci) then return end
  pal.x_clipboard(M.sel_text(sl.rows, sl.a, sl.b))
  sl.copy_t = pal.time_ns()
end

-- Esc clears an active selection before the shell's own Esc ladder
function M.escape(win, ed)
  local sl = M.sel_state(win)
  if sl.a then
    sl.a, sl.b, sl.drag = nil, nil, nil
    return true
  end
  return false
end

function M.wheel(win, ed, delta)
  -- clamp against last frame's measured max (win._maxscroll) too, not just 0 —
  -- else a wheel past the end draws one over-scrolled frame before draw's own
  -- clamp snaps it back (the home-list "scroll past then flick back" flicker)
  win.scroll = math.max(0, math.min((win.scroll or 0) - delta * 40,
                                    win._maxscroll or math.huge))
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
  -- src + copy-page buttons (right); copy-page grabs the whole doc as plain text
  local srcw = px * 3
  if win.path ~= "" then
    if hbtn(ctx.cx + ctx.cw - pad - srcw, by, srcw, bh, "src", true,
            i, ctx, z, px) then
      ed.open_asset_window(win.path, win.x + win.w + 20, win.y)
    end
    local pcopied = win._pagecopy_t
                    and (pal.time_ns() - win._pagecopy_t) < COPIED_MS * 1000000
    local plbl = pcopied and "copied" or "copy page"
    local pw = pal.x_ig_text_size("copy page", px, 0) + 14 * z
    if hbtn(ctx.cx + ctx.cw - pad - srcw - 6 * z - pw, by, pw, bh, plbl, true,
            i, ctx, z, px) then
      pal.x_clipboard(page_text(read_doc(win, ed)))
      win._pagecopy_t = pal.time_ns()
    end
  end
  pal.x_ig_text(bx, by + (bh - px) * 0.5, px, COL.hot, title, 0)

  -- body
  local topy = ctx.cy + bh + 10 * z
  local x0 = ctx.cx + pad
  local maxw = ctx.cw - pad * 2
  local contenth

  -- the home view reserves a FIXED search strip above the scroll region
  local sy0 = topy
  local sh = ctx.cy + ctx.ch - 4 * z - topy
  local results
  if win.path == "" then
    -- the home lists' heights all scale with px: anchor the scroll across
    -- a zoom/Aa change the same way the doc view does (px ratio is exact
    -- here — every row height is a px multiple)
    local sl0 = M.sel_state(win)
    if sl0.hpx and sl0.hpx ~= px and (win.scroll or 0) > 0 then
      win.scroll = win.scroll * (px / sl0.hpx)
    end
    sl0.hpx = px
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

  -- ---- drag selection (doc view): endpoints picked against LAST frame's
  -- rows (same indices — the doc and width are stable frame-to-frame; a
  -- reflow drops the selection). Runs before the body draws so this frame's
  -- highlight is current.
  local measure = pal.x_ig_text_size
  local sl = M.sel_state(win)
  local hlmap
  if win.path ~= "" then
    if sl.w ~= maxw then -- a resize reflowed the rows
      sl.a, sl.b, sl.drag = nil, nil, nil
    end
    local prows = sl.rows
    local function mpos() return i.wx - x0, i.wy - sy0 + win.scroll end
    if prows and #prows > 0 then
      if ctx.hot and i.clicked[1] and i.wx >= x0 and i.wx < x0 + maxw
         and i.wy >= sy0 and i.wy < sy0 + sh then
        local dx, dy = mpos()
        local p = M.rows_pick(prows, dx, dy, measure)
        sl.a, sl.b, sl.drag, sl.moved = p, p, true, nil
      elseif sl.drag and i.buttons[1] then
        -- autoscroll while dragging past the band edge
        if i.wy < sy0 then
          win.scroll = math.max(0, win.scroll - (sy0 - i.wy) * 0.25)
        elseif i.wy > sy0 + sh then
          win.scroll = math.min(win._maxscroll or win.scroll,
                                win.scroll + (i.wy - sy0 - sh) * 0.25)
        end
        local dx, dy = mpos()
        local p = M.rows_pick(prows, dx, dy, measure)
        if p.ri ~= sl.a.ri or p.ci ~= sl.a.ci then sl.moved = true end
        sl.b = p
      elseif sl.drag then
        sl.drag = nil -- released: a no-move gesture was a click
        if not sl.moved then sl.a, sl.b = nil, nil end
      end
    end
    -- the highlight map this frame's rows draw under their text
    if sl.a and sl.b and prows
       and not (sl.a.ri == sl.b.ri and sl.a.ci == sl.b.ci) then
      hlmap = {}
      local a, b = sel_norm(sl.a, sl.b)
      for ri = a.ri, math.min(b.ri, #prows) do
        local r = prows[ri]
        local run1, runN = r.runs[1], r.runs[#r.runs]
        local xa = ri == a.ri and M.row_x(r, a.ci, measure)
                   or (run1 and run1.x or 0)
        local xb = ri == b.ri and M.row_x(r, b.ci, measure)
                   or (runN and runN.x + runN.w or 0) + px * 0.4
        if xb > xa then hlmap[ri] = { a = xa, b = xb } end
      end
    end
  end
  sl.w = maxw

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
    -- layout once per (doc, width, font, zoom); every other frame is paint
    local L = sl.L
    if not L or sl.k_src ~= src or sl.k_w ~= maxw or sl.k_px ~= px
       or sl.k_z ~= z then
      -- a reflow of the SAME doc (canvas zoom, Aa scale, window resize)
      -- keeps the view anchored: scroll is content-space px, so it must
      -- scale with the content height — else zooming visibly scrolls the
      -- doc. (The class guard: any window keeping a raw px scroll over
      -- zoom-scaled content needs this; winview's world-unit scroll and
      -- the console's row scroll are immune by construction.)
      local oldh = (L and sl.k_src == src) and L.contenth or nil
      L = layout_doc(src, maxw, px, z)
      if oldh and oldh > 0 and L.contenth > 0 and (win.scroll or 0) > 0 then
        win.scroll = win.scroll * (L.contenth / oldh)
      end
      sl.L, sl.rows = L, L.rows
      sl.k_src, sl.k_w, sl.k_px, sl.k_z = src, maxw, px, z
      sl.a, sl.b, sl.drag = nil, nil, nil -- a reflow drops the selection
      hlmap = nil
    end
    contenth = L.contenth
    local maxscroll = math.max(0, contenth - sh)
    -- reveal a pending goto line (a search hit / #anchor): the layout knows
    -- its y immediately — no measure-then-scroll frame dance
    if win.goto_line then
      local ty = L.liney[win.goto_line]
      if ty then win.scroll = math.max(0, math.min(ty - px, maxscroll)) end
      win.goto_line = nil
      ed.touch()
    end
    win.scroll = math.max(0, math.min(win.scroll, maxscroll))
    local yoff = sy0 - win.scroll
    paint_doc(win, L, x0, yoff, maxw, px, z, i, ctx, hlmap, sh)
    draw_copy_chips(win, L.blocks, x0, yoff, maxw, sy0, sh, px, z, i, ctx)
    -- the ctrl+C ack: a "copied" chip riding the selection head
    if sl.copy_t and sl.a
       and (pal.time_ns() - sl.copy_t) < COPIED_MS * 1000000 then
      local _, b = sel_norm(sl.a, sl.b)
      local r = L.rows[math.min(b.ri, #L.rows)]
      if r then
        local cpx = math.max(6, px * 0.82)
        local lw = pal.x_ig_text_size("copied", cpx, 0)
        local cx = x0 + math.min(M.row_x(r, b.ci, measure), maxw - lw - 12 * z)
        local cy = yoff + r.y + r.h + 2 * z
        pal.x_ig_rect_fill(cx, cy, lw + 12 * z, cpx + 6 * z, COL.btn, 3 * z)
        pal.x_ig_text(cx + 6 * z, cy + 3 * z, cpx, COL.code, "copied", 0)
      end
    end
  end
  pal.x_ig_clip_pop()

  -- a slim scrollbar when the content overflows. The gutter right of the
  -- text band is its live hit zone (disjoint from the selection region, so
  -- a grab never starts a text drag): the knob drags with its grab offset,
  -- a track click centers the knob at the mouse and keeps dragging.
  -- sl.sbdrag is module-local like the selection — never canon.
  local maxscroll = math.max(0, contenth - sh)
  if maxscroll > 0 then
    local knoby, knobh = M.sb_knob(win.scroll, maxscroll, contenth, sh,
                                   sy0, z)
    local gx = x0 + maxw -- everything right of the band
    local hover = ctx.hot and i.wx >= gx and i.wx < ctx.cx + ctx.cw
                  and i.wy >= sy0 and i.wy < sy0 + sh
    if hover and i.clicked[1] then
      sl.sbdrag = (i.wy >= knoby and i.wy < knoby + knobh)
                  and (i.wy - knoby) or knobh * 0.5
    end
    if sl.sbdrag and i.buttons[1] then
      win.scroll = M.sb_target(i.wy, sl.sbdrag, sy0, sh, knobh, maxscroll)
      win.hl_line = nil -- scrolling dismisses the "landed here" marker
      knoby = M.sb_knob(win.scroll, maxscroll, contenth, sh, sy0, z)
    elseif sl.sbdrag then
      sl.sbdrag = nil
    end
    local live = (sl.sbdrag and COL.hot) or (hover and COL.dim) or COL.rule
    local barw = (sl.sbdrag or hover) and 6 * z or 3 * z
    pal.x_ig_rect_fill(ctx.cx + ctx.cw - barw - 1 * z, knoby, barw, knobh,
                       live, 2 * z)
  end
  win.scroll = math.max(0, math.min(win.scroll, maxscroll))
  win._maxscroll = maxscroll -- so M.wheel can clamp before it over-scrolls
  win._band = sh -- the visible band height: the pgup/pgdn page size

  -- link clicks fire on RELEASE of a gesture that never dragged, so link
  -- text is selectable like any other (a drag starting on a link selects);
  -- link rects are doc-space in the layout — convert the mouse once
  if ctx.hot and i.released[1] and not sl.moved and i.wy >= sy0
     and win.path ~= "" and sl.L then
    local mx, my = i.wx - x0, i.wy - sy0 + win.scroll
    for _, lk in ipairs(sl.L.links) do
      if mx >= lk.x and mx < lk.x + lk.w and my >= lk.y
         and my < lk.y + lk.h then
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
