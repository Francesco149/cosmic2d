-- cm.ed.win.stock — the read-only stock-assets browser (D147): the
-- engine's shipped asset families (instruments, demo songs, sprites,
-- figures, palettes) in one grid you can pull INTO your project. The
-- queued ask, verbatim: "a read only stock asset window that you can
-- copy assets from if desired (by copying them to your project);
-- opening a stock asset auto opens it with an auto generated name
-- unsaved."
--
-- Three doors, no write surface of its own:
--   double-click  = OPEN A COPY, unsaved: the stock bytes seed the
--                   working state at a fresh auto-named project path
--                   (kit A.seed) and the right editor window opens
--                   dirty — play with it, Ctrl+S keeps it, closing
--                   loses nothing on disk.
--   c / enter     = COPY into the project (the file lands at the same
--                   auto-name, the assets browser flashes it).
--   press-drag    = the shell carries the ENGINE-relative path
--                   (g.adrag) — a music track binds it (its resolve
--                   copies in), a sprite/terr well stamps it.
--
-- Stock paths are engine-cwd-relative by the D061 convention; nothing
-- here writes into engine/stock (read-only by construction — there is
-- no delete/rename/save door).

local M = select(2, ...) or {}

M.kind = "stock"
M.help = "win-stock"
M.menu = "stock assets"
M.DEF_W, M.DEF_H = 560, 380

local COL = {
  tile = 0x262238ff, tile_hot = 0x3a3560ff, tile_sel = 0x7fd8a8ff,
  name = 0xd8d2f2ff, dim = 0x8a84b0ff, glyph = 0x6a60a0ff,
  chip = 0x262238ff, chip_on = 0x4a4370ff, hot = 0xE8E4FFff,
}

-- the shipped families: key = the filter chip, dir = the engine-
-- relative source, dest = where a copy lands in the project
local FAMILIES = {
  { key = "ins", dir = "engine/stock/ins", dest = "ins/" },
  { key = "songs", dir = "engine/stock/songs", dest = "sound/" },
  { key = "art", dir = "engine/stock/spr", dest = "art/" },
  { key = "fig", dir = "engine/stock/fig", dest = "art/" },
  { key = "pal", dir = "engine/stock/pal", dest = "pal/" },
}
M.FAMILIES = FAMILIES

function M.defaults()
  return { filter = "", chip = "all", tile = 84 }
end

function M.title(win)
  return "stock assets"
end

function M.ctrl_wheel(win, ed, notches)
  win.tile = math.max(48, math.min(160, (win.tile or 84) + 8 * notches))
  ed.touch()
end

-- the flat list: { rel (engine-relative), name, family, dest } — cached
-- on ed.g (the stock tree only changes with the engine itself, but a
-- cheap invalidate hook keeps proofs honest)
function M.stock_list(ed)
  local g = ed.g
  if g.stocklist then return g.stocklist end
  local assets = cm.require("cm.ed.win.assets")
  local out = {}
  for _, fam in ipairs(FAMILIES) do
    local names = pal.list_dir(fam.dir) or {}
    table.sort(names)
    names = assets.prune_baked(names) -- tiles.png shadows under tiles.spr
    for _, n in ipairs(names) do
      if n:match("([^/]*)$"):find("%.") then
        out[#out + 1] = { rel = fam.dir .. "/" .. n, name = n,
                          family = fam.key, dest = fam.dest }
      end
    end
  end
  g.stocklist = out
  return out
end

function M.invalidate(ed)
  ed.g.stocklist = nil
  ed.g.stockthumb = nil
end

-- a stock rel path -> the project dest path (no uniquifying)
function M.dest_for(rel)
  local base = rel:match("([^/]+)$")
  for _, fam in ipairs(FAMILIES) do
    if rel:sub(1, #fam.dir + 1) == fam.dir .. "/" then
      return fam.dest .. base
    end
  end
  return base
end

-- the auto name: the stock stem, uniquified against disk AND unsaved
-- working states ("-2", "-3", ... on collision)
function M.unique_dest(ed, rel)
  local dest = M.dest_for(rel)
  local dir, stem, ext = dest:match("^(.-)([^/]+)%.([%w_]+)$")
  if not stem then return dest end
  local function taken(p)
    return pal.read_file(ed.root .. "/" .. p) ~= nil
           or (ed.doc.assets and ed.doc.assets[p] ~= nil)
  end
  local cand, n = dest, 2
  while taken(cand) do
    cand = dir .. stem .. "-" .. n .. "." .. ext
    n = n + 1
  end
  return cand
end

-- COPY a stock asset into the project (the `c` door). Returns the
-- project-relative path it landed at.
function M.copy_in(ed, rel)
  if ed.parked then
    pal.log("[ed] parked in the past — writes are walled")
    return nil
  end
  local bytes = pal.read_file(rel)
  if not bytes then
    pal.log("[ed] stock unreadable: " .. rel)
    return nil
  end
  local dest = M.unique_dest(ed, rel)
  local dir = dest:match("^(.*)/[^/]+$")
  if dir then pal.mkdir(ed.root .. "/" .. dir) end
  local ok, err = pal.write_file_atomic(ed.root .. "/" .. dest, bytes)
  if not ok then
    pal.log(("[ed] stock copy FAILED: %s (%s)"):format(dest, tostring(err)))
    if ed.summon_console then ed.summon_console() end
    return nil
  end
  local assets = cm.require("cm.ed.win.assets")
  assets.invalidate(ed)
  cm.require("cm.trace").note_import(dest, #bytes)
  ed.g.aflash = { path = dest, t = pal.time_ns() }
  pal.log("[ed] copied stock -> " .. dest)
  return dest
end

-- OPEN a stock asset as an unsaved project copy (the double-click
-- door): seed the working bytes at a fresh auto name, open the right
-- window there — dirty, journaled to the seed floor, nothing on disk
-- until the user's own Ctrl+S. Kinds without a seed door (none of the
-- stock families today) fall back to a real copy.
function M.open_copy(ed, rel, wx, wy)
  local bytes = pal.read_file(rel)
  if not bytes then
    pal.log("[ed] stock unreadable: " .. rel)
    return nil
  end
  local dest = M.unique_dest(ed, rel)
  local kname = cm.require("cm.ed.win.assets").kind_for(dest)
  local kind = kname and ed.kinds and ed.kinds[kname]
  if kind and kind.seed and kind.seed(ed, dest, bytes) then
    pal.log("[ed] opened stock copy (unsaved) -> " .. dest)
  else
    dest = M.copy_in(ed, rel)
    if not dest then return nil end
  end
  if ed.open_asset_window then ed.open_asset_window(dest, wx, wy) end
  return dest
end

-- ---- previews (ephemeral, epoch-free: stock is immutable in-session) ----

local function preview(ed, e)
  local g = ed.g
  g.stockthumb = g.stockthumb or {}
  local hit = g.stockthumb[e.rel]
  if hit ~= nil then return hit or nil end
  local pv = false
  local ext = e.name:match("%.([%w_]+)$")
  ext = ext and ext:lower() or ""
  if ext == "spr" or ext == "png" then
    local target = e.rel
    if ext == "spr" then
      local png = e.rel:gsub("%.spr$", ".png")
      target = (pal.mtime(png) or 0) > 0 and png or nil
    end
    if target then
      local ok, tex = pcall(cm.require("cm.gfx").texture, target)
      if ok then pv = { kind = "image", tex = tex } end
    end
  elseif ext == "pal" then
    local ok, doc = pcall(cm.require("cm.palette").decode,
                          pal.read_file(e.rel) or "")
    if ok and doc.colors and #doc.colors > 0 then
      pv = { kind = "pal", colors = doc.colors }
    end
  end
  g.stockthumb[e.rel] = pv
  return pv or nil
end

-- cm.paint packing -> drawlist 0xRRGGBBAA (the sprite window's disp,
-- verbatim — the D143 channel-rotation lesson)
local function disp(c)
  local r, g, b, a = cm.require("cm.paint").unpack(c)
  return (r << 24) | (g << 16) | (b << 8) | a
end

-- ---- hotkeys ----

M.hotkeys = {
  { key = "c", hint = "copy to project",
    when = function(win) return (win.sel or "") ~= "" end,
    fn = function(win, ed) M.copy_in(ed, win.sel) end },
  { key = "enter",
    when = function(win) return (win.sel or "") ~= "" end,
    fn = function(win, ed) M.copy_in(ed, win.sel) end },
}

-- ---- content ----

local CHIPS = { "all", "ins", "songs", "art", "fig", "pal" }

function M.draw(win, ctx)
  local ed = ctx.ed
  local g = ed.g
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  local i = cm.require("cm.ui").inp
  local assets = cm.require("cm.ed.win.assets")

  -- family chips
  local x = ctx.cx + 4 * z
  local y = ctx.cy + 3 * z
  local ch = px * 1.7
  for _, c in ipairs(CHIPS) do
    local w = pal.x_ig_text_size(c, px, 0) + 14 * z
    local on = (win.chip or "all") == c
    local hov = ctx.hot and i.wx >= x and i.wx < x + w
                and i.wy >= y and i.wy < y + ch
    pal.x_ig_rect_fill(x, y, w, ch, on and COL.chip_on or COL.chip, 5 * z)
    pal.x_ig_text(x + 7 * z, y + px * 0.3, px,
                  (on or hov) and COL.hot or COL.dim, c, 0)
    if hov and i.clicked[1] then
      win.chip = c
      ctx.touch()
    end
    x = x + w + 4 * z
  end
  -- the standing affordance line (the hint strip covers the keys once a
  -- tile is selected; this names the window's nature up front)
  local cap = "read-only · double-click opens an unsaved copy"
  local capw = pal.x_ig_text_size(cap, px * 0.8, 0)
  if ctx.cx + ctx.cw - 8 * z - capw > x then
    pal.x_ig_text(ctx.cx + ctx.cw - 8 * z - capw, y + px * 0.45,
                  px * 0.8, COL.dim, cap, 0)
  end
  local top = ch + 8 * z

  -- filter box
  local fy = ctx.cy + top
  local fh = px * 1.7
  pal.x_ig_rect(ctx.cx + 4 * z, fy, ctx.cw - 8 * z, fh, 0x4a437088, 1, 3 * z)
  if (win.filter or "") == "" then
    pal.x_ig_text(ctx.cx + 8 * z + 4, fy + 3, px, 0x8a84b066, "fuzzy search", 1)
  end
  if not ctx.occluded then
    local text, changed = pal.x_ig_edit {
      id = "stf" .. win.id, x = ctx.cx + 6 * z, y = fy + 1,
      w = ctx.cw - 12 * z, h = fh - 2, text = win.filter or "",
      px = px, font = 1, multiline = false,
    }
    if changed then
      win.filter = text:gsub("[\r\n\t]", "")
      ctx.touch()
    end
  else
    pal.x_ig_text(ctx.cx + 8 * z + 4, fy + 3, px, 0xffffffff,
                  win.filter or "", 1)
  end
  top = top + fh + 6 * z

  -- filter + rank
  local chip = win.chip or "all"
  local needle = win.filter or ""
  local shown = {}
  for li, e in ipairs(M.stock_list(ed)) do
    if chip == "all" or e.family == chip then
      local s = assets.fuzzy(needle, e.name)
      if s then shown[#shown + 1] = { e = e, s = s, li = li } end
    end
  end
  table.sort(shown, function(a, b)
    if a.s ~= b.s then return a.s > b.s end
    return a.li < b.li -- family roster order, not path order
  end)

  -- the grid
  local tile = (win.tile or 84) * z
  local name_h = px * 1.4
  local cell = tile + 8 * z
  local gy0 = ctx.cy + top
  local cols = math.max(1, math.floor((ctx.cw - 8 * z) / cell))
  local rows_vis = math.ceil((ctx.ch - top) / (cell + name_h)) + 1
  local scroll = cm.require("cm.ed.winview").scroll_px(win, "sy", z)
  local r0 = math.floor(scroll / (cell + name_h))
  pal.x_ig_clip_push(ctx.cx, gy0, ctx.cw, ctx.ch - top)
  local now = pal.time_ns()
  for idx = r0 * cols + 1, math.min(#shown, (r0 + rows_vis) * cols) do
    local e = shown[idx].e
    local col = (idx - 1) % cols
    local row = (idx - 1) // cols
    local tx = ctx.cx + 6 * z + col * cell
    local ty = gy0 + row * (cell + name_h) - scroll
    local hov = ctx.hot and i.wx >= tx and i.wx < tx + tile
                and i.wy >= ty and i.wy < ty + tile + name_h
    local selected = win.sel == e.rel
    pal.x_ig_rect_fill(tx, ty, tile, tile, hov and COL.tile_hot or COL.tile,
                       5 * z)
    if selected then
      pal.x_ig_rect(tx - 1, ty - 1, tile + 2, tile + 2, COL.tile_sel,
                    math.max(1, 1.5 * z), 6 * z)
    end
    local pv = preview(ed, e)
    if pv and pv.kind == "image" then
      local tex, m = pv.tex, 4 * z
      local s = math.min((tile - 2 * m) / tex.w, (tile - 2 * m) / tex.h)
      pal.x_ig_image(tex.id, tx + (tile - tex.w * s) * 0.5,
                     ty + (tile - tex.h * s) * 0.5, tex.w * s, tex.h * s)
    elseif pv and pv.kind == "pal" then
      local n = math.min(#pv.colors, 16)
      local rows = n > 8 and 2 or 1
      local per = math.ceil(n / rows)
      local sw = (tile - 8 * z) / per
      local sh = math.min(sw, (tile - 8 * z) / rows)
      for ci = 1, n do
        local cx2 = tx + 4 * z + ((ci - 1) % per) * sw
        local cy2 = ty + (tile - rows * sh) * 0.5 + ((ci - 1) // per) * sh
        pal.x_ig_rect_fill(cx2, cy2, sw - 1, sh - 1, disp(pv.colors[ci]), 0)
      end
    else
      local glyph = e.family == "ins" and "~"
                    or e.family == "songs" and "))" or "?"
      local gpx = tile * 0.3
      local gwd = pal.x_ig_text_size(glyph, gpx, 1)
      pal.x_ig_text(tx + (tile - gwd) * 0.5, ty + tile * 0.32, gpx,
                    COL.glyph, glyph, 1)
    end
    -- the family tag rides every tile (this window spans five)
    pal.x_ig_text(tx + 5 * z, ty + tile - px * 1.1, px * 0.75, COL.dim,
                  e.family, 0)
    local nm = e.name
    local nw = pal.x_ig_text_size(nm, px * 0.9, 0)
    pal.x_ig_clip_push(tx, ty + tile, tile, name_h)
    pal.x_ig_text(tx + math.max(0, (tile - nw) * 0.5), ty + tile + 2 * z,
                  px * 0.9, hov and COL.name or COL.dim, nm, 0)
    pal.x_ig_clip_pop()

    if hov and i.clicked[1] then
      local dbl = win.sel == e.rel and g.stclick
                  and (now - g.stclick) < 320 * 1e6
      win.sel = e.rel
      g.stclick = now
      ctx.touch()
      if dbl then
        M.open_copy(ed, e.rel, win.x + win.w + 20, win.y)
      else
        -- the shell carries the ENGINE-relative path: music tracks /
        -- wells copy it in through their own drop doors
        g.adrag = { path = e.rel, sx = i.wx, sy = i.wy, from = win.id }
      end
    end
  end
  pal.x_ig_clip_pop()
  if #shown == 0 then
    pal.x_ig_text(ctx.cx + 10 * z, gy0 + 10 * z, px, COL.dim,
                  "no matches", 1)
  end
end

function M.wheel(win, ed, dy)
  local z = cm.require("cm.ed.cam").screen_zoom(ed.doc.cam)
  cm.require("cm.ed.winview").scroll_by(win, "sy", z, -dy * 40)
  ed.touch()
end

return M
