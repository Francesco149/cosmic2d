-- cm.ed.win.text — the code ed (R4, EDITOR.md §12.2): a real project file
-- in a ghost x_ig_edit. The widget is a pure input machine (caret,
-- selection, mouse picking, clipboard, IME — drawn only as the selection
-- highlight); every visible glyph is OURS on the drawlist: line-number
-- gutter, per-line syntax faces (cm.ed.lex), our own caret, the current-
-- line tint. Since the visible layer is drawlist, it obeys canvas z — an
-- occluded window skips the invisible widget and looks pixel-identical
-- (the D051 dissolution of the R3 widget-z rule).
--
-- The §6 model is unchanged from R3: working state in doc.assets[path]
-- (survives restart via the session), the CJRN journal (Ctrl+Z/Y across
-- restarts), dirty computed as working-vs-disk, Ctrl+S writes the file,
-- revert is a normal undoable edit.
--
-- Docs are a special CODE format (the board): .md keeps the mono grid but
-- headings/links/code spans get faces. Ctrl+click a link → a NEW code
-- window at the pointer, its history seeded with the source file; ◀ ▶
-- header buttons + mouse buttons 4/5 walk a window's own history
-- (win.hist/win.hpos, captured).
--
-- A window with path == "" is the file picker (filter field + a list of
-- the project's text files); picking a file turns it into the editor.
-- Ephemeral per-asset plumbing (journal handles, disk cache, line/token
-- caches, push debounce) lives on the shell's g table, keyed by path.

local M = select(2, ...) or {}
local lex = cm.require("cm.ed.lex")

M.kind = "text"
M.menu = "open file…"
-- defaults lifted from the human's live session (UX round 6b: "what i
-- sized it to right now" — player.lua at 669x757, font ticked to 16):
-- the fresh-editor fallback; open windows still inherit the current
-- code window's size first (ed.text_spawn_size)
M.DEF_W, M.DEF_H = 669, 757
M.PX = 16.0 -- per-window override in win.px via a−/a+ or ctrl+wheel
M.PUSH_MS = 600 -- idle time that ends an edit gesture (teidraw's coalesce)

local EXT = { lua = true, md = true, txt = true, json = true, glsl = true }

-- the code faces (over the shell's palette family)
local FACE = {
  base = 0xd8d2f2ff, kw = 0xc792eaff, str = 0x9fdc8fff, num = 0xf2b46eff,
  com = 0x7a7498ff, h = 0xffd47eff, code = 0x9fdc8fff, link = 0x7fb8f0ff,
  em = 0xE8E4FFff,
  gutter = 0x5a5480ff, gutter_hot = 0xb0a8dcff, caret = 0xE8E4FFff,
  line_tint = 0xffffff08,
}

function M.defaults()
  return { path = "", filter = "" }
end

function M.title(win)
  if win.path == "" then return "open file…" end
  return win.path:match("([^/]+)$") or win.path
end

-- ---- the asset citizen (cm.ed.kit, R9a) — plumbing on ed.g.tw[path],
-- working text in doc.assets[path].text, the §6 contract generated.
-- Raw kind (no codec): gestures close through A.push (the debounced
-- p.due owner), and journal walks flag force_set so the live widget
-- re-reads its buffer.

local A
A = cm.require("cm.ed.kit").asset {
  gkey = "tw", field = "text",
  -- baseline entry: the disk state undo can always come back to (even
  -- an empty file — no fresh(): a new asset adopts the disk bytes)
  baseline_always = true,
  adopt = function(p) p.force_set = true end,
  pre_undo = function(ed, path, a, p) -- close the open gesture first
    if p.due then A.push(ed, path) end
  end,
}

local plumb, working, open_asset, push_now =
  A.plumb, A.working, A.open_asset, A.push

-- public open: adopt the window's asset now (spawn-time, console driving,
-- the restart-survival proof). Returns the working state + plumbing.
M.open_win = A.open_win

-- the shell calls this on quit so no working state misses its journal
function M.flush(ed)
  for path, p in pairs(ed.g.tw or {}) do
    if p.due then push_now(ed, path) end
  end
end

-- ---- history + navigation (EDITOR.md §12.2) ----

-- re-target the window to another file, recording history. `nohist` = a
-- back/fwd jump (the position moves, the list doesn't).
function M.navigate(win, ed, path, nohist)
  if win.path == path then return end
  if win.path ~= "" then
    local p = plumb(ed, win.path)
    if p.due then push_now(ed, win.path) end -- close the open gesture
  end
  if not nohist then
    win.hist = win.hist or (win.path ~= "" and { win.path } or {})
    win.hpos = win.hpos or #win.hist
    for i = #win.hist, win.hpos + 1, -1 do win.hist[i] = nil end
    win.hist[#win.hist + 1] = path
    win.hpos = #win.hist
  end
  win.path = path
  win.filter = nil
  win.sy, win.sx = 0, 0 -- a different file starts at the top
  ed.g.wsy = ed.g.wsy or {}
  ed.g.wsy[win.id] = nil -- force the widget to the fresh scroll
  open_asset(ed, path)
  ed.touch()
end

local function hist_go(win, ed, dir)
  if not win.hist then return end
  local np = (win.hpos or #win.hist) + dir
  if np < 1 or np > #win.hist then return end
  win.hpos = np
  M.navigate(win, ed, win.hist[np], true)
end
M.hist_go = hist_go

-- resolve a link target to an openable path (project-relative; the repo
-- root is reachable via ../.. since project dirs sit two levels deep).
-- Returns the path or nil.
local function resolve_link(ed, target)
  target = target:gsub("#.*$", ""):gsub("^%./", "")
  if target == "" then return nil end
  local cands = {}
  local function add(c) cands[#cands + 1] = c end
  add(target)
  if not target:find("%.%w+$") then add(target .. ".lua") end
  if target:find("^[%w_]+[%.%w_]*$") and target:find("%.") then
    -- dotted module name: cm.* lives in engine/, projects resolve locally
    local slashed = target:gsub("%.", "/") .. ".lua"
    add(slashed)
    add("../../engine/" .. slashed)
  end
  if target:find("^docs/") or target:find("^engine/") then
    add("../../" .. target)
  end
  for _, c in ipairs(cands) do
    local mt = pal.mtime(ed.root .. "/" .. c)
    if mt and mt > 0 then return c end
  end
  return nil
end

-- ---- the focused-window commands (shell hotkeys, EDITOR.md §6) ----
-- generated by cm.ed.kit; undo closes the open p.due gesture first,
-- journal walks force_set so an active widget re-reads its buffer,
-- revert is a NORMAL journaled edit (undoable)

M.dirty, M.save, M.undo, M.redo, M.revert =
  A.dirty, A.save, A.undo, A.redo, A.revert

-- the asset-pick drag-out contract (EDITOR.md §12.5)
function M.accepts(win, path)
  local ext = path:match("%.([%w_]+)$")
  return ext ~= nil and EXT[ext:lower()] or false
end

function M.rebind(win, ed, path)
  M.navigate(win, ed, path)
end

-- ---- the line/token caches (ephemeral) ----

local function split_lines(text)
  local lines = {}
  local pos = 1
  while true do
    local nl = text:find("\n", pos, true)
    if not nl then
      lines[#lines + 1] = text:sub(pos)
      break
    end
    lines[#lines + 1] = text:sub(pos, nl - 1)
    pos = nl + 1
  end
  return lines
end

-- lines + the per-line-start carry array, rebuilt when the text changes
local function line_cache(p, a, lang)
  if p.lines_src == a.text then return p.lines, p.carry end
  p.lines_src = a.text
  p.lines = split_lines(a.text)
  local carry = { "" }
  local c = ""
  for i = 1, #p.lines do
    c = lex.carry_line(lang, p.lines[i], c)
    carry[i + 1] = c
  end
  p.carry = carry
  return p.lines, p.carry
end

-- token memo keyed by carry + line content (interned strings = cheap)
local function tokens_for(p, lang, line, carry)
  p.tok = p.tok or {}
  p.tokn = p.tokn or 0
  local key = carry .. "\1" .. line
  local t = p.tok[key]
  if not t then
    if p.tokn > 8192 then
      p.tok, p.tokn = {}, 0
    end
    t = (lex.line(lang, line, carry))
    p.tok[key] = t
    p.tokn = p.tokn + 1
  end
  return t
end

local function glyphs(s, a, b) -- glyph count of s[a..b] (utf8-aware, safe)
  local n = utf8.len(s, a, b)
  return n or (b - a + 1)
end

-- ---- the picker (path == "") ----

-- pal.list_dir (SDL_GlobDirectory) enumerates recursively — one call
-- returns the whole tree; keep the text-editable extensions
local function project_files(ed)
  local g = ed.g
  if not g.files then
    g.files = {}
    local names = pal.list_dir(ed.root) or {}
    table.sort(names)
    for _, n in ipairs(names) do
      if #g.files >= 400 then break end
      local ext = n:match("%.([%w]+)$")
      if ext and EXT[ext:lower()] and not n:find("^%.ed")
         and not n:find("^%.git") then
        g.files[#g.files + 1] = n
      end
    end
  end
  return g.files
end
M.project_files = project_files

local function draw_picker(win, ctx)
  local ed = ctx.ed
  local z, pad = ctx.z, 8 * ctx.z
  local px = math.max(4, (win.px or M.PX) * z)
  if ctx.occluded then
    pal.x_ig_text(ctx.cx + pad + 4, ctx.cy + pad * 0.6 + 3, px, 0xffffffff,
                  win.filter or "", 1)
  else
    local filter, changed = pal.x_ig_edit {
      id = "pick" .. win.id, x = ctx.cx + pad, y = ctx.cy + pad * 0.6,
      w = ctx.cw - 2 * pad, h = px * 1.6, text = win.filter or "",
      px = px, font = 1,
    }
    if changed then
      win.filter = filter
      ctx.touch()
    end
  end
  local files = project_files(ed)
  local y = ctx.cy + pad * 0.6 + px * 2.0
  local shown = 0
  local i = cm.require("cm.ui").inp
  local needle = (win.filter or ""):lower()
  for _, rel in ipairs(files) do
    if needle == "" or rel:lower():find(needle, 1, true) then
      shown = shown + 1
      if shown > 18 then
        pal.x_ig_text(ctx.cx + pad, y, px, 0x8a84b0ff, "…", 1)
        break
      end
      local rh = px * 1.5
      local hov = ctx.hot and i.wx >= ctx.cx and i.wx < ctx.cx + ctx.cw
                  and i.wy >= y and i.wy < y + rh
      if hov then
        pal.x_ig_rect_fill(ctx.cx + 2, y - 2 * z, ctx.cw - 4, rh, 0x3a3560ff, 4)
      end
      pal.x_ig_text(ctx.cx + pad, y, px, hov and 0xE8E4FFff or 0xd8d2f2cc,
                    rel, 1)
      if hov and i.clicked[1] then
        M.navigate(win, ed, rel)
      end
      y = y + rh
      if y > ctx.cy + ctx.ch then break end
    end
  end
end

-- ---- the editor content ----

-- header extras: a−/a+ font size + ◀ ▶ history buttons (drawn by the
-- shell's header pass via kind.header, right-aligned before the dirty
-- cluster; buttons place right-to-left from ctx.hx). Font size is a
-- per-window CAPTURED field (win.px over the M.PX default) — it rides
-- the session and rewinds honestly.
function M.header(win, ctx)
  local z = ctx.z
  local px = math.max(4, 11 * z)
  local i = cm.require("cm.ui").inp
  local bw = px * 1.6
  local x, used = ctx.hx, 0
  local function button(glyph, can)
    x = x - bw
    used = used + bw
    local hov = ctx.hot and i.wx >= x and i.wx < x + bw
                and i.wy >= ctx.hy and i.wy < ctx.hy + ctx.hh
    pal.x_ig_text(x + px * 0.3, ctx.hy + (ctx.hh - px) * 0.45, px,
                  can and (hov and 0xE8E4FFff or 0xb0a8dcff) or 0x5a5480ff,
                  glyph, 1)
    return can and hov and i.clicked[1]
  end
  local cur = win.px or M.PX
  if button("a+", cur < 64) then
    win.px = math.min(64, cur + 2)
    ctx.ed.touch()
  end
  if button("a-", cur > 8) then
    win.px = math.max(8, cur - 2)
    ctx.ed.touch()
  end
  if win.hist and #win.hist >= 2 then
    if button(">", win.hpos and win.hpos < #win.hist) then
      hist_go(win, ctx.ed, 1)
    end
    if button("<", win.hpos and win.hpos > 1) then
      hist_go(win, ctx.ed, -1)
    end
  end
  return used
end

-- ctrl+wheel over the content: the font-size dial (same clamp as the
-- a−/a+ header buttons; the shell routes it, EDITOR.md §12.7)
function M.ctrl_wheel(win, ed, notches)
  local cur = win.px or M.PX
  win.px = math.max(8, math.min(64, cur + 2 * notches))
  ed.touch()
end

-- ---- find/replace (UX round 5, EDITOR.md §12.2) ----
-- Ctrl+F opens a bar at the top of the window; plain-text literal find,
-- per line (a query containing \n is out of scope). Bar state is
-- EPHEMERAL (ed.g.fr keyed by window id — like the widget scroll mirror);
-- replaces are normal journaled edits, one undo step each.

-- Ctrl+F (a pre-gate shell hotkey — works mid-typing): open + focus
function M.find(win, ed)
  if win.path == "" then return end
  local g = ed.g
  g.fr = g.fr or {}
  local fr = g.fr[win.id] or { q = "", r = "" }
  g.fr[win.id] = fr
  fr.open = true
  fr.refocus = true
end

-- shell Esc offer: close the bar when open (true = consumed)
function M.escape(win, ed)
  local fr = ed.g.fr and ed.g.fr[win.id]
  if fr and fr.open then
    fr.open = false
    return true
  end
  return false
end

-- match list {line, col_a, col_b}, recomputed when the query or the text
-- moved (plain literal find, capped so a 1-char query can't blow up)
local FR_CAP = 2000
local function fr_matches(fr, lines, atext)
  if fr.src == atext and fr.qsrc == fr.q then return fr.m end
  fr.src, fr.qsrc = atext, fr.q
  local m = {}
  if fr.q ~= "" then
    for li = 1, #lines do
      local line, init = lines[li], 1
      while true do
        local s, e = line:find(fr.q, init, true)
        if not s or #m >= FR_CAP then break end
        m[#m + 1] = { li, s, e }
        init = e + 1
      end
      if #m >= FR_CAP then break end
    end
  end
  fr.m = m
  if not fr.at or fr.at > #m or fr.at < 1 then fr.at = #m > 0 and 1 or 0 end
  return m
end

-- scroll the current match into view (the same forced-scroll path as
-- navigate: win.sy is captured, the widget adopts it next frame)
local function fr_jump(win, ed, fr, px, th)
  local mt = fr.m and fr.m[fr.at]
  if not mt then return end
  local want = math.max(0, (mt[1] - 1) * px - th * 0.4)
  win.sy = want
  ed.g.wsy = ed.g.wsy or {}
  ed.g.wsy[win.id] = nil
  ed.touch()
end

-- replace the current match (or all): one journaled undo step.
-- (fr_matches/fr_apply are exposed on M for the selftest KATs.)
local function fr_apply(win, ed, a, p, fr, lines, all)
  local m = fr.m
  if not m or #m == 0 or fr.q == "" then return end
  local starts, off = {}, 1
  for li = 1, #lines do
    starts[li] = off
    off = off + #lines[li] + 1
  end
  local t = a.text
  local function splice(mt)
    local sb = starts[mt[1]] + mt[2] - 1
    local eb = starts[mt[1]] + mt[3] - 1
    t = t:sub(1, sb - 1) .. fr.r .. t:sub(eb + 1)
  end
  if all then
    for k = #m, 1, -1 do splice(m[k]) end
  else
    if not m[fr.at] then return end
    splice(m[fr.at])
  end
  a.text = t
  p.force_set = true
  push_now(ed, win.path)
  ed.touch()
end
M.fr_matches = fr_matches
M.fr_apply = fr_apply

function M.draw(win, ctx)
  if win.path == "" then
    draw_picker(win, ctx)
    return
  end
  local ed = ctx.ed
  local a, p = open_asset(ed, win.path)
  local z = ctx.z
  local px = math.max(4, (win.px or M.PX) * z)
  local lang = lex.lang_of(win.path)
  local lines, carry = line_cache(p, a, lang)

  -- mouse buttons 4/5: this window's history (when focused)
  local i = cm.require("cm.ui").inp
  if ctx.focused and not ctx.occluded then
    if i.clicked[4] then hist_go(win, ed, -1) end
    if i.clicked[5] then hist_go(win, ed, 1) end
  end

  -- gutter geometry (mono metrics; one measure per draw)
  local cw = pal.x_ig_text_size("0", px, 1)
  local digits = #tostring(#lines)
  local gw = math.max(2, digits) * cw + 10 * z
  local tx, ty = ctx.cx + gw, ctx.cy
  local tw, th = ctx.cw - gw, ctx.ch
  if tw < 20 then return end

  -- the find/replace bar reserves a strip across the top (ctrl+F)
  local g = ed.g
  g.fr = g.fr or {}
  local fr = g.fr[win.id]
  local bpx = math.max(4, 12 * z)
  local bh = 0
  if fr and fr.open then
    bh = bpx * 2.1
    ty = ty + bh
    th = th - bh
    if th < px then return end
    fr_matches(fr, lines, a.text) -- fresh for this frame's highlights
  end

  -- the widget (invisible input machine) — skipped when occluded
  g.wsy = g.wsy or {}

  -- the imgui child keeps its scroll in SCREEN px, but px-per-line is
  -- font*zoom — so a canvas zoom (or a font tick) would re-scroll the
  -- content (the human's zoom bug: lines shift unless you're at the
  -- top). Rescale the scroll whenever this WINDOW's effective px moves
  -- so the same LINE stays anchored, and force it into the widget.
  -- (Keyed by window, not path — two windows on one file don't fight.)
  g.wpx = g.wpx or {}
  local lpx = g.wpx[win.id]
  if lpx and math.abs(lpx - px) > 1e-9 then
    local k = px / lpx
    win.sy = (win.sy or 0) * k
    win.sx = (win.sx or 0) * k
    g.wsy[win.id] = nil -- force the rescaled scroll in
    ed.touch()
  end
  g.wpx[win.id] = px

  local st, active, changed, forced
  if not ctx.occluded then
    local text
    local opts = {
      id = "txt" .. win.id, x = tx, y = ty, w = tw, h = th,
      text = a.text, px = px, font = 1, multiline = true, ghost = true,
    }
    if p.force_set then
      opts.set = true
      p.force_set = nil
    end
    -- first draw of this window (spawn / restart / navigate / a px
    -- rescale): push the remembered scroll INTO the widget; imgui
    -- applies the target next frame, so the mirror below skips this
    -- frame (or it would clobber it)
    forced = g.wsy[win.id] == nil
    if forced then
      opts.scroll_y = win.sy or 0
      opts.scroll_x = win.sx or 0
      g.wsy[win.id] = true
    end
    text, changed, active, st = pal.x_ig_edit(opts)
    if changed then
      a.text = text
      lines, carry = line_cache(p, a, lang)
      p.due = pal.time_ns() + M.PUSH_MS * 1000000
      ed.touch()
    end
    -- mirror the widget's scroll into captured state (rewind + restore)
    if st and not forced
       and (st.sy ~= (win.sy or 0) or st.sx ~= (win.sx or 0)) then
      win.sy, win.sx = st.sy, st.sx
      ed.touch()
    end
  end
  local sx, sy = win.sx or 0, win.sy or 0
  if st and not forced then sx, sy = st.sx, st.sy end -- a forced frame
  -- draws from win.sx/sy (the widget adopts them next frame)

  -- gesture end: the widget deactivates (incl. going inert), or the idle
  -- debounce runs out — checked even while inert so no push is stranded
  if p.was_active and not active then
    push_now(ed, win.path)
  elseif p.due and pal.time_ns() >= p.due then
    push_now(ed, win.path)
  end
  p.was_active = active or false

  -- ---- the visible layer (ours, drawlist) ----
  local ox, oy = tx + 4, ty + 3 -- imgui FramePadding — glyphs align 1:1
  local first = math.max(1, math.floor(sy / px) + 1)
  local last = math.min(#lines, first + math.ceil(th / px) + 1)

  -- caret line (for the tint + gutter accent), from the byte offset
  local cline, ccol
  if st and st.caret then
    local nl, pos = 0, 1
    while true do
      local f = a.text:find("\n", pos, true)
      if not f or f > st.caret then break end
      nl = nl + 1
      pos = f + 1
    end
    cline = nl + 1
    ccol = st.caret - pos + 1 -- byte col within the line (0-based length)
  end

  -- current-line tint under everything
  if cline and cline >= first and cline <= last then
    pal.x_ig_rect_fill(tx, oy + (cline - 1) * px - sy, tw, px, FACE.line_tint)
  end

  -- gutter
  local gpx = px * 0.85
  for li = first, last do
    local num = tostring(li)
    local nw = pal.x_ig_text_size(num, gpx, 1)
    pal.x_ig_text(ctx.cx + gw - 6 * z - nw, oy + (li - 1) * px - sy + px * 0.08,
                  gpx, li == cline and FACE.gutter_hot or FACE.gutter, num, 1)
  end
  pal.x_ig_line(tx - 1, ty, tx - 1, ty + th, 0x4a437066, 1)

  -- text: per-line token spans (gaps = base face)
  pal.x_ig_clip_push(tx, ty, tw, th)

  -- find-match highlights, under the glyphs (the current one accented)
  if fr and fr.open and fr.m then
    for mi, mt in ipairs(fr.m) do
      local li = mt[1]
      if li >= first and li <= last then
        local line = lines[li]
        local hx = ox + glyphs(line, 1, mt[2] - 1) * cw - sx
        local hw = math.max(cw * 0.4, glyphs(line, mt[2], mt[3]) * cw)
        local hy = oy + (li - 1) * px - sy
        pal.x_ig_rect_fill(hx, hy, hw, px, mi == fr.at and 0x7fd8a855
                                            or 0x7fd8a822)
        if mi == fr.at then
          pal.x_ig_rect(hx, hy, hw, px, 0x7fd8a8cc, 1)
        end
      end
    end
  end
  for li = first, last do
    local line = lines[li]
    if #line > 0 then
      local ly = oy + (li - 1) * px - sy
      local toks = tokens_for(p, lang, line, carry[li])
      local posb = 1
      for _, t in ipairs(toks) do
        if t.a > posb then
          local seg = line:sub(posb, t.a - 1)
          pal.x_ig_text(ox + glyphs(line, 1, posb - 1) * cw - sx, ly, px,
                        FACE.base, seg, 1)
        end
        pal.x_ig_text(ox + glyphs(line, 1, t.a - 1) * cw - sx, ly, px,
                      FACE[t.k] or FACE.base, line:sub(t.a, t.b), 1)
        posb = t.b + 1
      end
      if posb <= #line then
        pal.x_ig_text(ox + glyphs(line, 1, posb - 1) * cw - sx, ly, px,
                      FACE.base, line:sub(posb), 1)
      end
    end
  end

  -- our caret (the ghost hides imgui's): blink on the wall clock
  if cline and active then
    local on = (pal.time_ns() // 1000000 % 1060) < 530
    if on and cline >= first and cline <= last then
      local line = lines[cline] or ""
      local cx2 = ox + glyphs(line, 1, math.max(0, ccol)) * cw - sx
      pal.x_ig_rect_fill(cx2, oy + (cline - 1) * px - sy,
                         math.max(1, z), px, FACE.caret)
    end
  end
  pal.x_ig_clip_pop()

  -- Ctrl+click a link → a NEW code window at the pointer (EDITOR.md §12.2)
  if g.ctrl and ctx.hot and i.clicked[1] and not ctx.occluded
     and i.wx >= tx and i.wx < tx + tw and i.wy >= ty and i.wy < ty + th then
    local li = math.floor((i.wy - oy + sy) / px) + 1
    local line = lines[li]
    if line and #line > 0 then
      local gi = math.floor((i.wx - ox + sx) / cw) + 1
      local bpos = utf8.offset(line, math.min(gi, glyphs(line, 1, #line)))
                   or math.min(gi, #line)
      local la, lb, target = lex.link_at(line, math.max(1, bpos))
      if target then
        local path = resolve_link(ed, target)
        if path then
          local wm = cm.require("cm.ed.wm")
          local cur = g.cursor or { wx = win.x + 40, wy = win.y + 40 }
          local sw2, sh2 = ed.text_spawn_size() -- your current code
                                                -- window's size (round 6)
          local nw = wm.spawn(ed.doc, "text", cur.wx + 20 / ctx.z,
                              cur.wy + 20 / ctx.z, sw2, sh2,
                              { path = "", filter = "" })
          nw.hist = { win.path }
          nw.hpos = 1
          M.navigate(nw, ed, path)
          ed.touch()
        else
          pal.log("[ed] link target not found: " .. target)
        end
      end
    end
  end

  -- ---- the find/replace bar (its strip was reserved above) ----
  if fr and fr.open then
    local bx, by, bw2 = ctx.cx, ctx.cy, ctx.cw
    pal.x_ig_rect_fill(bx, by, bw2, bh, 0x1a1728f6)
    pal.x_ig_line(bx, by + bh, bx + bw2, by + bh, 0x4a437066, 1)
    local fw2 = math.max(40, math.min(220 * z, bw2 * 0.28))
    local fh2 = bpx * 1.6
    local fy = by + (bh - fh2) * 0.5
    local qsub = false
    if ctx.occluded then
      pal.x_ig_text(bx + 8 * z + 4, fy + 2, bpx, 0xd8d2f2ff, fr.q, 1)
      pal.x_ig_text(bx + 14 * z + fw2 + 4, fy + 2, bpx, 0xd8d2f2ff, fr.r, 1)
    else
      local q, qch, _, qst = pal.x_ig_edit {
        id = "fnd" .. win.id, x = bx + 8 * z, y = fy, w = fw2, h = fh2,
        text = fr.q, px = bpx, font = 1, enter = true,
        focus = fr.refocus or nil,
      }
      fr.refocus = nil
      local r, rch = pal.x_ig_edit {
        id = "rpl" .. win.id, x = bx + 14 * z + fw2, y = fy, w = fw2,
        h = fh2, text = fr.r, px = bpx, font = 1,
      }
      if qch then fr.q = q end
      if rch then fr.r = r end
      qsub = (qst and qst.submit) or false
    end
    if fr.q == "" then
      pal.x_ig_text(bx + 8 * z + 4, fy + 2, bpx, 0x8a84b066, "find", 1)
    end
    if fr.r == "" then
      pal.x_ig_text(bx + 14 * z + fw2 + 4, fy + 2, bpx, 0x8a84b066,
                    "replace", 1)
    end
    local m = fr_matches(fr, lines, a.text)
    if fr.q ~= fr.lastq then
      -- live find: a fresh query jumps to its first match
      fr.lastq = fr.q
      fr.at = #m > 0 and 1 or 0
      if #m > 0 then fr_jump(win, ed, fr, px, th) end
    elseif qsub and #m > 0 then
      -- Enter in the field: next match (and keep the typing flow — the
      -- EnterReturnsTrue submit deactivates the widget)
      fr.at = fr.at % #m + 1
      fr_jump(win, ed, fr, px, th)
      fr.refocus = true
    end
    local bxx = bx + bw2 - 4 * z
    local function btn(w2, label)
      bxx = bxx - w2 - 4 * z
      local hov = ctx.hot and not ctx.occluded
                  and i.wx >= bxx and i.wx < bxx + w2
                  and i.wy >= fy and i.wy < fy + fh2
      pal.x_ig_rect_fill(bxx, fy, w2, fh2,
                         hov and 0x3a3560ff or 0x262238ff, 4)
      local lw2 = pal.x_ig_text_size(label, bpx, 0)
      pal.x_ig_text(bxx + (w2 - lw2) * 0.5, fy + (fh2 - bpx) * 0.45, bpx,
                    hov and 0xE8E4FFff or 0xb0a8dcff, label, 0)
      return hov and i.clicked[1]
    end
    if btn(bpx * 1.6, "x") then fr.open = false end
    if btn(bpx * 2.6, "all") then fr_apply(win, ed, a, p, fr, lines, true) end
    if btn(bpx * 3.4, "repl") then
      fr_apply(win, ed, a, p, fr, lines, false)
    end
    if btn(bpx * 1.6, ">") and #m > 0 then
      fr.at = fr.at % #m + 1
      fr_jump(win, ed, fr, px, th)
    end
    if btn(bpx * 1.6, "<") and #m > 0 then
      fr.at = (fr.at - 2) % #m + 1
      fr_jump(win, ed, fr, px, th)
    end
    local cnt = ("%d/%d"):format(fr.at, #m)
    local cw2 = pal.x_ig_text_size(cnt, bpx, 0)
    pal.x_ig_text(bxx - cw2 - 6 * z, fy + (fh2 - bpx) * 0.45, bpx,
                  0x8a84b0ff, cnt, 0)
  end
end

return M
