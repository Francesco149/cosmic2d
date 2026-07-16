-- cm.ed.launcher — the Ctrl+Space command palette (the human's ask). ONE fuzzy
-- field over EVERYTHING: spawn any window kind, PAN TO any open window, open any
-- asset or any doc — with a live PREVIEW of the highlighted result (an image
-- thumbnail, a map schematic, or a code/doc excerpt). A shell overlay like the
-- spawn menu — never a canvas window; all state on ed.g.launcher, gone the
-- frame it's dismissed. The shell drives it: M.open/close/active/draw + the
-- ed.* helpers it calls (spawn_kind / pan_to_window / open_doc / open_asset).

local M = {}
local assets = cm.require("cm.ed.win.assets")
local preview = cm.require("cm.ed.preview")
local chrome = cm.require("cm.ed.chrome")
local pal = chrome.pal

-- the top-level guides (win-*.md are per-window help off the ? button; these
-- three are the readable walkthroughs a newcomer wants from the palette)
local DOCS = { "getting-started", "editor", "scripting" }

local COL = {
  scrim = 0x0a0812c0, panel = 0x1e1b2ef8, edge = 0x4a4370ff,
  field = 0x141220ff, row_hot = 0x3a3560ff, row_sel = 0x2c2848ff,
  text = 0xd8d2f2ff, dim = 0x8a84b0ff, hot = 0xE8E4FFff, accent = 0x7fd8a8ff,
  tag = 0x6a60a0ff, pv_bg = 0x141220ff, code = 0xb8c0e8ff,
  col = 0x8ad0ffff, plc = 0x7fd8a8ff, mk = 0xf0d070ff,
}

local KEY = { up = 82, down = 81, enter = 40, esc = 41, tab = 43 }

function M.open(ed)
  ed.g.launcher = { q = "", sel = 1, focus = true }
  ed.touch()
end

function M.active(ed) return ed.g.launcher ~= nil end

function M.close(ed)
  ed.g.launcher = nil
  ed.touch()
end

-- ---- the entry list (unfiltered), in a friendly default order ----
local function all_entries(ed)
  local out = {}
  for _, w in ipairs(ed.doc.wins) do
    local kind = ed.kinds[w.kind]
    local title = (kind and kind.title and kind.title(w)) or w.kind
    out[#out + 1] = { cat = "win", key = "w" .. w.id, label = title,
                      tag = "pan to", win = w }
  end
  for _, it in ipairs(ed.spawnable()) do
    out[#out + 1] = { cat = "spawn", key = "s:" .. it[1],
                      label = it[2] .. " window", tag = "new", name = it[1] }
  end
  for _, d in ipairs(DOCS) do
    out[#out + 1] = { cat = "doc", key = "d:" .. d, label = d, tag = "doc",
                      doc = d }
  end
  for _, rel in ipairs(assets.all_files(ed)) do
    local _, ext = assets.class_of(rel)
    out[#out + 1] = { cat = "asset", key = "a:" .. rel, label = rel,
                      tag = ext ~= "" and ext or "file", path = rel }
  end
  return out
end

-- filter + rank against the query (empty = the natural order above)
local function filtered(ed, l)
  local all = all_entries(ed)
  if l.q == "" then return all end
  local hits = {}
  for _, e in ipairs(all) do
    local s = assets.fuzzy(l.q, e.label)
    if s then hits[#hits + 1] = { e = e, s = s } end
  end
  table.sort(hits, function(a, b)
    if a.s ~= b.s then return a.s > b.s end
    return a.e.label < b.e.label
  end)
  local out = {}
  for _, h in ipairs(hits) do out[#out + 1] = h.e end
  return out
end

-- ---- activation ----
local function activate(ed, e, ig)
  M.close(ed)
  local raw_ig = ed.g.last_ig or ig
  if e.cat == "win" then ed.pan_to_window(e.win, raw_ig)
  elseif e.cat == "spawn" then ed.spawn_kind(e.name, raw_ig)
  elseif e.cat == "doc" then ed.open_doc(e.doc)
  elseif e.cat == "asset" then
    local c = ed.doc.cam
    local z = cm.require("cm.ed.cam").screen_zoom(c)
    ed.open_asset_window(e.path, c.x + (raw_ig.w / z) * 0.28,
                         c.y + (raw_ig.h / z) * 0.18)
  end
end

-- ---- the preview (cached on l.pv, recomputed when the highlight moves) ----
local function build_preview(ed, e)
  local pv = { cat = e.cat }
  if e.cat == "asset" then
    local cls, ext = assets.class_of(e.path)
    if ext == "map" then
      local ok, doc = pcall(cm.require("cm.map").decode,
                            pal.read_file(ed.root .. "/" .. e.path) or "")
      if ok then pv.map = doc end
    elseif ext == "tm" then
      local ok, doc = pcall(cm.require("cm.tmap").decode,
                            pal.read_file(ed.root .. "/" .. e.path) or "")
      if ok then pv.tm = doc end
    elseif cls == "image" or ext == "spr" then
      local target = e.path
      if ext == "spr" then
        local png = e.path:gsub("%.[sS][pP][rR]$", ".png")
        if (pal.mtime(ed.root .. "/" .. png) or 0) > 0 then target = png else target = nil end
      end
      if target then
        local ok, tex = pcall(cm.require("cm.gfx").texture, ed.root .. "/" .. target)
        if ok then pv.tex = tex end
      end
    elseif cls == "code" then
      pv.lines = preview.head_lines(pal.read_file(ed.root .. "/" .. e.path))
    end
  elseif e.cat == "doc" then
    pv.lines = preview.head_lines(pal.read_file("engine/stock/docs/" .. e.doc .. ".md"))
  elseif e.cat == "spawn" then
    pv.blurb = "Spawn a new\n" .. e.label .. ".\n\nThe window's ? button\n"
               .. "opens its guide."
  elseif e.cat == "win" then
    pv.blurb = "Pan the canvas to\ncenter this window at\nthe current zoom —\n"
               .. "fitting the zoom down\nonly if it overflows\nthe screen."
  end
  return pv
end

local function draw_preview(ed, pv, px, py, pw, ph)
  pal.x_ig_rect_fill(px, py, pw, ph, COL.pv_bg, 4)
  if pv.tex then
    local m = 8
    local sc = math.min((pw - 2 * m) / pv.tex.w, (ph - 2 * m) / pv.tex.h)
    sc = math.min(sc, 12) -- don't blow a tiny sprite up past 12x
    local dw, dh = pv.tex.w * sc, pv.tex.h * sc
    pal.x_ig_image(pv.tex.id, px + (pw - dw) * 0.5, py + (ph - dh) * 0.5, dw, dh)
  elseif pv.map then
    preview.draw_map(pv.map, px + 4, py + 4, pw - 8, ph - 8, COL, pal)
  elseif pv.tm then
    preview.draw_tm(pv.tm, px + 4, py + 4, pw - 8, ph - 8, COL.plc, pal)
  elseif pv.lines then
    preview.draw_lines(pv.lines, px, py, pw, ph, 11, COL.code, pal)
  elseif pv.blurb then
    pal.x_ig_clip_push(px, py, pw, ph)
    local y = py + 8
    for para in (pv.blurb .. "\n"):gmatch("([^\n]*)\n") do
      pal.x_ig_text(px + 8, y, 12, COL.dim, para, 0)
      y = y + 16
    end
    pal.x_ig_clip_pop()
  end
end

-- ---- the overlay ----
function M.draw(ed, ig, i)
  local l = ed.g.launcher
  if not l then return end
  local list = filtered(ed, l)
  local n = #list
  l.sel = n == 0 and 1 or math.max(1, math.min(l.sel, n))

  -- keyboard nav (read raw keys: the edit field owns typing, but arrows/enter/
  -- esc pass through cm.ui.inp regardless of imgui focus)
  for _, e in ipairs(i.keys) do
    if e.down and not e.rep then
      if e.scancode == KEY.down then l.sel = n == 0 and 1 or l.sel % n + 1; ed.touch()
      elseif e.scancode == KEY.up then l.sel = n == 0 and 1 or (l.sel - 2) % n + 1; ed.touch()
      elseif e.scancode == KEY.esc then M.close(ed); return
      elseif e.scancode == KEY.enter and list[l.sel] then
        activate(ed, list[l.sel], ig); return
      end
    end
  end

  local pw, ph = math.min(720, ig.w - 80), math.min(460, ig.h - 80)
  local px = (ig.w - pw) * 0.5
  local py = math.max(40, (ig.h - ph) * 0.34)
  pal.x_ig_overlay(true)
  pal.x_ig_rect_fill(0, 0, ig.w, ig.h, COL.scrim, 0)
  pal.x_ig_rect_fill(px, py, pw, ph, COL.panel, 10)
  pal.x_ig_rect(px, py, pw, ph, COL.edge, 1, 10)

  -- the search field
  local fh = 30
  pal.x_ig_rect_fill(px + 10, py + 10, pw - 20, fh, COL.field, 6)
  if l.q == "" then
    pal.x_ig_text(px + 20, py + 18, 15, COL.dim,
                  "search assets, docs, windows…  (↑↓ enter · esc)", 0)
  end
  local text, _, _, _ = pal.x_ig_edit {
    id = "launcher", x = px + 16, y = py + 15, w = pw - 32, h = fh - 8,
    text = l.q, px = 15, font = 0, multiline = false, focus = l.focus or nil,
  }
  l.focus = nil
  if text ~= l.q then l.q = text:gsub("[\r\n\t]", ""); l.sel = 1; ed.touch() end

  -- split: results (left) + preview (right)
  local listx, listy = px + 10, py + 10 + fh + 8
  local listw = (pw - 30) * 0.52
  local pvx = listx + listw + 10
  local pvw = px + pw - 10 - pvx
  local rows_h = ph - (listy - py) - 30
  local rh = 24
  local vis = math.floor(rows_h / rh)
  local top = math.max(0, math.min(l.sel - math.floor(vis / 2), n - vis))
  if top < 0 then top = 0 end
  pal.x_ig_clip_push(listx, listy, listw, rows_h)
  for idx = top + 1, math.min(n, top + vis) do
    local e = list[idx]
    local y = listy + (idx - top - 1) * rh
    local sel = idx == l.sel
    local hov = i.wx >= listx and i.wx < listx + listw and i.wy >= y and i.wy < y + rh
    if sel or hov then
      pal.x_ig_rect_fill(listx, y, listw, rh - 2, sel and COL.row_sel or COL.row_hot, 4)
    end
    -- tag chip
    pal.x_ig_text(listx + 6, y + 5, 10, COL.tag, "[" .. e.tag .. "]", 0)
    local tw = pal.x_ig_text_size("[" .. e.tag .. "]", 10, 0)
    pal.x_ig_clip_push(listx + 12 + tw, y, listw - 18 - tw, rh)
    pal.x_ig_text(listx + 14 + tw, y + 5, 13, (sel or hov) and COL.hot or COL.text,
                  e.label, 0)
    pal.x_ig_clip_pop()
    if hov and i.clicked[1] then
      if l.sel == idx then activate(ed, e, ig); pal.x_ig_clip_pop(); pal.x_ig_overlay(false); return end
      l.sel = idx; ed.touch()
    end
  end
  pal.x_ig_clip_pop()
  if n == 0 then
    pal.x_ig_text(listx + 6, listy + 6, 13, COL.dim, "no matches", 0)
  end

  -- the preview of the highlighted entry (cached on l.pv)
  local sel_e = list[l.sel]
  if sel_e then
    if not l.pv or l.pv.key ~= sel_e.key then
      l.pv = build_preview(ed, sel_e)
      l.pv.key = sel_e.key
    end
    draw_preview(ed, l.pv, pvx, listy, pvw, rows_h)
  end

  -- footer hint
  pal.x_ig_text(px + 12, py + ph - 18, 11, COL.dim,
    ("%d results · ↑↓ move · enter open · esc close"):format(n), 0)

  pal.x_ig_overlay(false)
  -- a click on the scrim (outside the panel) dismisses
  if i.clicked[1] and not (i.wx >= px and i.wx < px + pw and i.wy >= py and i.wy < py + ph) then
    M.close(ed)
  end
end

return M
