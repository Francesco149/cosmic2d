-- cm.ed.win.text — a real project file in a mono edit widget: the
-- journal-backed code-ed precursor (EDITOR.md §7). Proves the whole §6
-- model: working state in doc.assets[path] (survives restart via the
-- session), the CJRN journal (Ctrl+Z/Y across restarts), dirty computed
-- as working-vs-disk, Ctrl+S writes the file (and only then does the
-- engine see the change — hot reload reacts on its own), revert = a
-- normal, undoable edit. No highlighting/line numbers/links — that's R4.
--
-- A window with path == "" is the file picker (filter field + a list of
-- the project's text files); picking a file turns it into the editor.
-- Ephemeral per-asset plumbing (journal handles, disk cache, push
-- debounce) lives on the shell's g table, keyed by path — the captured
-- doc holds only {text, jpos} (EDITOR.md §2).

local M = select(2, ...) or {}
local journal = cm.require("cm.ed.journal")

M.kind = "text"
M.DEF_W, M.DEF_H = 460, 340
M.PX = 13.0
M.PUSH_MS = 600 -- idle time that ends an edit gesture (teidraw's coalesce)

local EXT = { lua = true, md = true, txt = true, json = true, glsl = true }

function M.defaults()
  return { path = "", filter = "" }
end

function M.title(win)
  return win.path == "" and "open file…" or win.path
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
  a.jpos = p.j.pos
  ed.touch()
  return a, p
end

local function push_now(ed, path, flags)
  local a = working(ed, path)
  local p = plumb(ed, path)
  if not (a and p.j) then return end
  p.due = nil
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

-- ---- the focused-window commands (shell hotkeys, EDITOR.md §6) ----

function M.dirty(win, ed)
  if win.path == "" then return false end
  local a = working(ed, win.path)
  local p = ed.g.tw and ed.g.tw[win.path]
  return a and p and p.disk ~= nil and a.text ~= p.disk or false
end

function M.save(win, ed)
  if win.path == "" then return end
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
    ed.touch()
  end
end

function M.redo(win, ed)
  if win.path == "" then return end
  local a, p = open_asset(ed, win.path)
  local e = journal.redo(p.j)
  if e then
    a.text, a.jpos = e.bytes, p.j.pos
    ed.touch()
  end
end

-- revert-to-saved: a NORMAL edit (journaled), so revert itself is undoable
function M.revert(win, ed)
  if win.path == "" then return end
  local a, p = open_asset(ed, win.path)
  a.text = p.disk or ""
  push_now(ed, win.path)
end

-- ---- the picker (path == "") ----

local function walk(root, dir, out, depth)
  if depth > 4 or #out > 400 then return end
  local names = pal.list_dir(root .. (dir == "" and "" or "/" .. dir))
  if not names then return end
  table.sort(names)
  for _, n in ipairs(names) do
    local rel = dir == "" and n or dir .. "/" .. n
    if n ~= ".ed" and n ~= ".git" then
      local ext = n:match("%.([%w]+)$")
      if ext and EXT[ext:lower()] then
        out[#out + 1] = rel
      elseif not ext or not n:find("%.") then
        walk(root, rel, out, depth + 1) -- probe: list_dir(nil) on files
      end
    end
  end
end

local function project_files(ed)
  local g = ed.g
  if not g.files then
    g.files = {}
    walk(ed.root, "", g.files, 1)
  end
  return g.files
end

local function draw_picker(win, ctx)
  local ed = ctx.ed
  local z, pad = ctx.z, 8 * ctx.z
  local px = math.max(4, M.PX * z)
  if ctx.alt or ctx.occluded then
    pal.x_ig_text(ctx.cx + pad, ctx.cy + pad * 0.6, px, 0xd8d2f2ff,
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
        win.path = rel
        win.filter = nil
        open_asset(ed, rel)
        ctx.touch()
      end
      y = y + rh
      if y > ctx.cy + ctx.ch then break end
    end
  end
end

-- ---- content ----

function M.draw(win, ctx)
  if win.path == "" then
    draw_picker(win, ctx)
    return
  end
  local ed = ctx.ed
  local a, p = open_asset(ed, win.path)
  local z, pad = ctx.z, 6 * ctx.z
  local px = math.max(4, M.PX * z)

  -- inert under the ALT layer (§5 rule 1: imgui never sees an A-click) and
  -- when a higher window overlaps (the widget would render above it)
  local active = false
  if ctx.alt or ctx.occluded then
    pal.x_ig_text(ctx.cx + pad, ctx.cy + pad * 0.7, px, 0xd8d2f2ff, a.text, 1)
  else
    local text, changed
    text, changed, active = pal.x_ig_edit {
      id = "txt" .. win.id, x = ctx.cx + pad, y = ctx.cy + pad * 0.5,
      w = ctx.cw - 2 * pad, h = ctx.ch - pad,
      text = a.text, px = px, font = 1, multiline = true,
    }
    if changed then
      a.text = text
      p.due = pal.time_ns() + M.PUSH_MS * 1000000
      ed.touch()
    end
  end
  -- gesture end: the widget deactivates (incl. going inert), or the idle
  -- debounce runs out — checked even while inert so no push is stranded
  if p.was_active and not active then
    push_now(ed, win.path)
  elseif p.due and pal.time_ns() >= p.due then
    push_now(ed, win.path)
  end
  p.was_active = active
end

return M
