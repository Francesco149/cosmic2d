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
local journal = cm.require("cm.ed.journal")
local lex = cm.require("cm.ed.lex")

M.kind = "text"
M.DEF_W, M.DEF_H = 460, 340
M.PX = 13.0
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

-- ---- the per-asset plumbing (ephemeral, on ed.g) ----

local function plumb(ed, path)
  local g = ed.g
  g.tw = g.tw or {}
  local p = g.tw[path]
  if not p then
    p = {}
    g.tw[path] = p
  end
  return p
end

local function working(ed, path)
  ed.doc.assets = ed.doc.assets or {}
  return ed.doc.assets[path]
end

-- open (or re-adopt after a restart) an asset's working state + journal
local function open_asset(ed, path)
  local a = working(ed, path)
  local p = plumb(ed, path)
  if p.j then return a, p end

  local disk = pal.read_file(ed.root .. "/" .. path)
  p.disk = disk or ""
  if not a then
    a = { text = p.disk, jpos = 0 }
    ed.doc.assets[path] = a
  end
  p.j = journal.open(ed.root, path, a.jpos > 0 and a.jpos or nil)
  if not ed.parked then -- parked reopens must never write journals (R6c)
    if #p.j.entries == 0 then
      -- baseline entry: the disk state undo can always come back to
      journal.push(p.j, p.disk, journal.SAVED, pal.time_ns() // 1000000)
    end
    local tip = journal.at(p.j)
    if tip and a.text ~= tip.bytes and p.j.pos == #p.j.entries then
      -- session-restored unsaved work the journal hasn't seen (e.g. the
      -- 600 ms push never fired before quit): journal it now so Ctrl+Z works
      journal.push(p.j, a.text, 0, pal.time_ns() // 1000000)
    end
  end
  a.jpos = p.j.pos
  ed.touch()
  return a, p
end

local function push_now(ed, path, flags)
  local a = working(ed, path)
  local p = plumb(ed, path)
  if not (a and p.j) then return end
  p.due = nil
  if ed.parked then return end -- parked edits are ephemeral (REWIND.md §4)
  if journal.push(p.j, a.text, flags or 0, pal.time_ns() // 1000000) then
    a.jpos = p.j.pos
    ed.touch()
  end
end

-- public open: adopt the window's asset now (spawn-time, console driving,
-- the restart-survival proof). Returns the working state + plumbing.
function M.open_win(win, ed)
  if win.path ~= "" then return open_asset(ed, win.path) end
end

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

function M.dirty(win, ed)
  if win.path == "" then return false end
  local a = working(ed, win.path)
  local p = ed.g.tw and ed.g.tw[win.path]
  return a and p and p.disk ~= nil and a.text ~= p.disk or false
end

function M.save(win, ed)
  if win.path == "" then return end
  if ed.parked then
    pal.log("[ed] parked in the past — writes are walled (bring-back is the door)")
    return
  end
  local a, p = open_asset(ed, win.path)
  if pal.write_file(ed.root .. "/" .. win.path, a.text) then
    p.disk = a.text
    push_now(ed, win.path, journal.SAVED)
    pal.log("[ed] saved " .. win.path)
  else
    pal.log("[ed] SAVE FAILED " .. win.path)
  end
end

function M.undo(win, ed)
  if win.path == "" then return end
  local a, p = open_asset(ed, win.path)
  if p.due then push_now(ed, win.path) end -- close the open gesture first
  local e = journal.undo(p.j)
  if e then
    a.text, a.jpos = e.bytes, p.j.pos
    p.force_set = true -- the widget may be active: overwrite its buffer
    ed.touch()
  end
end

function M.redo(win, ed)
  if win.path == "" then return end
  local a, p = open_asset(ed, win.path)
  local e = journal.redo(p.j)
  if e then
    a.text, a.jpos = e.bytes, p.j.pos
    p.force_set = true
    ed.touch()
  end
end

-- revert-to-saved: a NORMAL edit (journaled), so revert itself is undoable
function M.revert(win, ed)
  if win.path == "" then return end
  local a, p = open_asset(ed, win.path)
  a.text = p.disk or ""
  p.force_set = true
  push_now(ed, win.path)
end

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
  local px = math.max(4, M.PX * z)
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
      local hov = not ctx.alt and i.wx >= ctx.cx and i.wx < ctx.cx + ctx.cw
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

-- header extras: ◀ ▶ history buttons (drawn by the shell's header pass
-- via kind.header, right-aligned before the dirty cluster)
function M.header(win, ctx)
  if not win.hist or #win.hist < 2 then return 0 end
  local z = ctx.z
  local px = math.max(4, 11 * z)
  local i = cm.require("cm.ui").inp
  local bw = px * 1.6
  local x = ctx.hx - bw * 2 -- ctx.hx = right edge available to extras
  for n, glyph in ipairs({ "<", ">" }) do
    local dir = n == 1 and -1 or 1
    local can = win.hpos and ((dir < 0 and win.hpos > 1)
                or (dir > 0 and win.hpos < #win.hist))
    local bx = x + (n - 1) * bw
    local hov = not ctx.alt and i.wx >= bx and i.wx < bx + bw
                and i.wy >= ctx.hy and i.wy < ctx.hy + ctx.hh
    pal.x_ig_text(bx + px * 0.3, ctx.hy + (ctx.hh - px) * 0.45, px,
                  can and (hov and 0xE8E4FFff or 0xb0a8dcff) or 0x5a5480ff,
                  glyph, 1)
    if can and hov and i.clicked[1] then hist_go(win, ctx.ed, dir) end
  end
  return bw * 2
end

function M.draw(win, ctx)
  if win.path == "" then
    draw_picker(win, ctx)
    return
  end
  local ed = ctx.ed
  local a, p = open_asset(ed, win.path)
  local z = ctx.z
  local px = math.max(4, M.PX * z)
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

  -- the widget (invisible input machine) — skipped when occluded
  local g = ed.g
  g.wsy = g.wsy or {}
  local st, active, changed
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
    -- first draw of this window (spawn / restart / navigate): push the
    -- remembered scroll INTO the widget; imgui applies the target next
    -- frame, so the mirror below skips this frame (or it would clobber it)
    local forced = g.wsy[win.id] == nil
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
  if st then sx, sy = st.sx, st.sy end

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
  pal.x_ig_line(tx - 1, ctx.cy, tx - 1, ctx.cy + th, 0x4a437066, 1)

  -- text: per-line token spans (gaps = base face)
  pal.x_ig_clip_push(tx, ty, tw, th)
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
  local g = ed.g
  if g.ctrl and not g.alt and i.clicked[1] and not ctx.occluded
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
          local nw = wm.spawn(ed.doc, "text", cur.wx + 20 / ctx.z,
                              cur.wy + 20 / ctx.z, M.DEF_W, M.DEF_H,
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
end

return M
