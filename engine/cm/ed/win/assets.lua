-- cm.ed.win.assets — the asset picker (R4, EDITOR.md §12.5): a file
-- manager with previews. No folders — one flat list of project files,
-- type chips + fuzzy subsequence search, a tile-size slider, previews
-- for images (a .spr previews its baked .png sibling). Double-click
-- opens the right window kind; press-drag a tile and the SHELL carries
-- the drag (g.adrag): released over a window whose kind accepts(path) →
-- that window re-targets; over empty canvas → spawns the right kind
-- there. OS drag-in lands in cm.ed.filter_events (a "drop" event copies
-- the file into the project — image→art/, sound→sound/, code→root — and
-- the new tile flashes; non-png images convert to .png on the way in,
-- and a drop outside asset/map windows opens the right window at the
-- drop point).
--
-- Captured (win fields): filter, chip (type filter), tile (size), sel.
-- Ephemeral: the file list + preview texture cache + double-click clock
-- (on ed.g, invalidated on drops/saves/refresh).

local M = select(2, ...) or {}

M.kind = "assets"
M.help = "win-assets"
M.menu = "assets"
M.DEF_W, M.DEF_H = 520, 380

local CODE = { lua = true, md = true, txt = true, json = true, glsl = true }
-- every format stb_image decodes (plus .spr, ours): a drop of any of
-- these converts to .png on the way in (add_dropped below)
local IMAGE = { png = true, jpg = true, jpeg = true, gif = true, spr = true,
                bmp = true, tga = true, hdr = true, psd = true, pic = true,
                ppm = true, pgm = true, pnm = true }
local SOUND = { wav = true, ogg = true, mp3 = true }

local COL = {
  tile = 0x262238ff, tile_hot = 0x3a3560ff, tile_sel = 0x7fd8a8ff,
  name = 0xd8d2f2ff, dim = 0x8a84b0ff, glyph = 0x6a60a0ff,
  chip = 0x262238ff, chip_on = 0x4a4370ff, flash = 0x7fd8a8ff,
}

function M.defaults()
  return { filter = "", chip = "all", tile = 84 }
end

-- ctrl+wheel over the content: the preview-size dial (same 48..160 range
-- as the header slider; the shell routes it, EDITOR.md §12.7)
function M.ctrl_wheel(win, ed, notches)
  win.tile = math.max(48, math.min(160, (win.tile or 84) + 8 * notches))
  ed.touch()
end

function M.title(win)
  return "assets"
end

function M.class_of(path)
  local ext = path:match("%.([%w_]+)$")
  ext = ext and ext:lower() or ""
  if IMAGE[ext] then return "image", ext end
  if SOUND[ext] then return "sound", ext end
  if CODE[ext] then return "code", ext end
  return "other", ext
end

-- the window kind a double-click / canvas-drop opens for a file: the
-- kind roster self-describes routing (kind.exts, EDITOR.md §13) — one
-- canonical opener per extension — with class fallbacks after
function M.kind_for(path)
  local class, ext = M.class_of(path)
  for name, kind in pairs(cm.require("cm.ed").kinds) do
    for _, e in ipairs(kind.exts or {}) do
      if e == ext then return name end
    end
  end
  if class == "image" then return "image" end -- any stb-decodable format
  if class == "code" then return "text" end
  return nil -- unknowns have no window (sound routes via exts, R9c)
end

-- fuzzy subsequence score: nil = no match; higher = better (consecutive
-- runs + start-of-word hits count, spread hurts). Pure — selftested.
function M.fuzzy(needle, hay)
  if needle == "" then return 0 end
  needle, hay = needle:lower(), hay:lower()
  local score, hi, last, run = 0, 0, nil, 0
  for ni = 1, #needle do
    local c = needle:sub(ni, ni)
    local found = hay:find(c, hi + 1, true)
    if not found then return nil end
    if last and found == last + 1 then
      run = run + 1
      score = score + 2 + run -- consecutive runs snowball
    else
      run = 0
      local prev = found > 1 and hay:sub(found - 1, found - 1) or "/"
      if prev == "/" or prev == "_" or prev == "-" or prev == "." then
        score = score + 3 -- start-of-word hit
      end
      if last then score = score - math.min(5, found - last - 1) * 0.2 end
    end
    last, hi = found, found
  end
  return score - #hay * 0.01 -- shorter paths win ties
end

-- ---- the file list (ephemeral, shared on ed.g) ----

-- a .spr's baked build products (.png strip, .anim, .meta — what
-- sprite.save writes) shadow under their source in the browser: the
-- human edits the .spr, the bakes are noise. Pure — selftested. A
-- .png with no .spr sibling (plank.png) stays.
function M.prune_baked(names)
  local spr = {}
  for _, n in ipairs(names) do
    local base = n:lower():match("^(.*)%.spr$")
    if base then spr[base] = true end
  end
  local out = {}
  for _, n in ipairs(names) do
    local base, ext = n:lower():match("^(.*)%.(%w+)$")
    local baked = base and spr[base]
                  and (ext == "png" or ext == "anim" or ext == "meta")
    if not baked then out[#out + 1] = n end
  end
  return out
end

-- pal.list_dir (SDL_GlobDirectory) enumerates RECURSIVELY — one call
-- returns the whole tree as relative paths. Keep entries whose basename
-- has an extension (files, by the project convention), prune .ed/.git
-- and the baked siblings of .spr sources.
local function all_files(ed)
  local g = ed.g
  if not g.afiles then
    local keep = {}
    local names = pal.list_dir(ed.root) or {}
    table.sort(names)
    for _, n in ipairs(names) do
      if #keep >= 1000 then break end
      if not n:find("^%.ed") and not n:find("^%.git")
         and n:match("([^/]*)$"):find("%.") then
        keep[#keep + 1] = n
      end
    end
    g.afiles = M.prune_baked(keep)
  end
  return g.afiles
end

M.all_files = all_files -- the launcher (Ctrl+Space) shares this cached list

function M.invalidate(ed)
  ed.g.afiles = nil
  ed.g.files = nil -- the text picker's list too
end

-- a cached preview object for a path (nil = fall back to a glyph). An image
-- (PNG, or a .spr's baked .png) previews its texture; a .map draws a schematic,
-- a .tm its filled cells, code its first lines — the same renderers the
-- Ctrl+Space launcher uses (cm.ed.preview), so the human's "map thumbnail /
-- code excerpt" shows in the browser too. Cached on ed.g.athumb (cleared on
-- drop/save/delete).
local function preview(ed, path)
  local g = ed.g
  g.athumb = g.athumb or {}
  local hit = g.athumb[path]
  if hit ~= nil then return hit or nil end
  local cls, ext = M.class_of(path)
  local pv = false
  if ext == "spr" or cls == "image" then
    local target = path
    if ext == "spr" then
      local png = path:gsub("%.[sS][pP][rR]$", ".png")
      target = (pal.mtime(ed.root .. "/" .. png) or 0) > 0 and png or nil
    end
    if target then
      local ok, tex = pcall(cm.require("cm.gfx").texture, ed.root .. "/" .. target)
      if ok then pv = { kind = "image", tex = tex } end
    end
  elseif ext == "map" then
    local ok, doc = pcall(cm.require("cm.map").decode,
                          pal.read_file(ed.root .. "/" .. path) or "")
    if ok then pv = { kind = "map", doc = doc } end
  elseif ext == "tm" then
    local ok, doc = pcall(cm.require("cm.tmap").decode,
                          pal.read_file(ed.root .. "/" .. path) or "")
    if ok then pv = { kind = "tm", doc = doc } end
  elseif cls == "code" then
    local lines = cm.require("cm.ed.preview").head_lines(
      pal.read_file(ed.root .. "/" .. path), 14)
    if lines then pv = { kind = "code", lines = lines } end
  end
  g.athumb[path] = pv
  return pv or nil
end

-- ---- the OS drop add (called from cm.ed.filter_events) ----

function M.add_dropped(ed, ospath)
  if ed.parked then
    pal.log("[ed] parked in the past — writes are walled")
    return
  end
  local base = ospath:match("([^/\\]+)$")
  if not base then return end
  local bytes = pal.read_file(ospath)
  if not bytes then
    pal.log("[ed] drop unreadable: " .. ospath)
    return
  end
  local class = M.class_of(base)
  local dir = class == "image" and "art/" or class == "sound" and "sound/" or ""
  if dir ~= "" then pal.mkdir(ed.root .. "/" .. dir:sub(1, -2)) end
  local stem, ext = base:match("^(.*)%.([%w_]+)$")
  if not stem then stem, ext = base, "" end
  -- on-the-fly image conversion (the human's ask): anything stb decodes
  -- (jpg/bmp/gif/tga/hdr/psd/pnm…) lands as .png — the project's one
  -- canonical image format (previews, map placeables, the sprite
  -- pipeline all speak it). Undecodable "images" store raw, logged.
  local pix, pw, ph
  if class == "image" and ext:lower() ~= "png" and ext:lower() ~= "spr" then
    pix, pw, ph = pal.png_read(bytes)
    if pix then
      ext = "png"
    else
      pal.log(("[ed] drop: can't decode %s (%s) — storing raw")
              :format(base, tostring(pw)))
    end
  end
  local rel = dir .. stem .. (ext ~= "" and "." .. ext or "")
  local n = 2
  while (pal.mtime(ed.root .. "/" .. rel) or 0) > 0 do
    rel = dir .. stem .. "_" .. n .. (ext ~= "" and "." .. ext or "")
    n = n + 1
  end
  local ok
  if pix then
    ok = pcall(pal.png_write, ed.root .. "/" .. rel, pix, pw, ph)
    if ok then
      pal.log(("[ed] added %s (converted %s, %dx%d)"):format(rel, base, pw, ph))
    end
  else
    ok = pal.write_file(ed.root .. "/" .. rel, bytes)
    if ok then pal.log(("[ed] added %s (%d bytes)"):format(rel, #bytes)) end
  end
  if ok then
    M.invalidate(ed)
    ed.g.aflash = { path = rel, t = pal.time_ns() }
    return rel -- the map window places OS drops at the drop point (R8b)
  else
    pal.log("[ed] drop write FAILED: " .. rel)
  end
end

-- ---- content ----

local CHIPS = { "all", "code", "image", "sound" }

local function chip_row(win, ctx, i)
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  local x = ctx.cx + 4 * z
  local y = ctx.cy + 3 * z
  local h = px * 1.7
  for _, c in ipairs(CHIPS) do
    local w = pal.x_ig_text_size(c, px, 0) + 14 * z
    local on = (win.chip or "all") == c
    local hov = ctx.hot and i.wx >= x and i.wx < x + w
                and i.wy >= y and i.wy < y + h
    pal.x_ig_rect_fill(x, y, w, h, on and COL.chip_on or COL.chip, 5 * z)
    pal.x_ig_text(x + 7 * z, y + px * 0.3, px,
                  (on or hov) and 0xE8E4FFff or COL.dim, c, 0)
    if hov and i.clicked[1] then
      win.chip = c
      ctx.touch()
    end
    x = x + w + 4 * z
  end
  -- the size slider, right-aligned
  local sw = math.min(110 * z, ctx.cx + ctx.cw - x - 12 * z)
  if sw > 30 then
    local sx = ctx.cx + ctx.cw - sw - 8 * z
    local sy = y + h * 0.5
    pal.x_ig_line(sx, sy, sx + sw, sy, 0x4a4370ff, math.max(1, z))
    local t = ((win.tile or 84) - 48) / (160 - 48)
    local kx = sx + t * sw
    local hov = ctx.hot and i.wx >= sx - 6 and i.wx < sx + sw + 6
                and i.wy >= y and i.wy < y + h
    pal.x_ig_circle_fill(kx, sy, math.max(3, 4.5 * z),
                         hov and 0xE8E4FFff or 0xb0a8dcff)
    local g = ctx.ed.g
    if hov and i.buttons[1] and not g.adrag then g.aslider = win.id end
    if g.aslider == win.id then
      if i.buttons[1] then
        local nt = math.max(0, math.min(1, (i.wx - sx) / sw))
        win.tile = math.floor(48 + nt * (160 - 48))
        ctx.touch()
      else
        g.aslider = nil
      end
    end
  end
  return h + 8 * z
end

-- ---- delete (human, morning round): del on the selected tile arms a
-- confirm, a second del executes. A .spr takes its baked build
-- products (.png/.anim/.meta) with it. Parked = walled. ----

local function delete_asset(ed, path)
  if ed.parked then
    pal.log("[ed] parked in the past — writes are walled")
    return
  end
  pal.x_remove(ed.root .. "/" .. path)
  local base = path:match("^(.*)%.[sS][pP][rR]$")
  if base then
    pal.x_remove(ed.root .. "/" .. base .. ".png")
    pal.x_remove(ed.root .. "/" .. base .. ".anim")
    pal.x_remove(ed.root .. "/" .. base .. ".meta")
  end
  M.invalidate(ed)
  if ed.g.athumb then ed.g.athumb[path] = nil end
  pal.log("[ed] deleted " .. path)
end

M.hotkeys = {
  { key = "del", hint = "delete",
    when = function(win) return (win.sel or "") ~= "" end,
    fn = function(win, ed)
      local armed = ed.g.adel
      if armed and armed.id == win.id and armed.path == win.sel then
        delete_asset(ed, win.sel)
        win.sel = nil
        ed.g.adel = nil
      else
        ed.g.adel = { id = win.id, path = win.sel }
      end
      ed.touch()
    end },
}

function M.escape(win, ed)
  if ed.g.adel and ed.g.adel.id == win.id then
    ed.g.adel = nil
    ed.touch()
    return true
  end
  return false
end

function M.draw(win, ctx)
  local ed = ctx.ed
  local g = ed.g
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  local i = cm.require("cm.ui").inp

  local top = chip_row(win, ctx, i)

  -- filter box under the chips
  local fy = ctx.cy + top
  local fh = px * 1.7
  pal.x_ig_rect(ctx.cx + 4 * z, fy, ctx.cw - 8 * z, fh, 0x4a437088, 1, 3 * z)
  if (win.filter or "") == "" then
    pal.x_ig_text(ctx.cx + 8 * z + 4, fy + 3, px, 0x8a84b066, "fuzzy search", 1)
  end
  if not ctx.occluded then
    local text, changed = pal.x_ig_edit {
      id = "af" .. win.id, x = ctx.cx + 6 * z, y = fy + 1,
      w = ctx.cw - 12 * z, h = fh - 2, text = win.filter or "",
      px = px, font = 1, multiline = false, -- a search field is single-line;
      -- the multiline default spawns a child window whose active-ID tracking
      -- is flaky under the host's NoFocusOnAppearing flag (2nd+ keystrokes were
      -- being dropped -> "fuzzy finds nothing past 1 char", the human's bug)
    }
    if changed then
      win.filter = text:gsub("[\r\n\t]", "") -- never let a stray control char
      ctx.touch()                            -- into the needle (kills matches)
    end
  else
    pal.x_ig_text(ctx.cx + 8 * z + 4, fy + 3, px, 0xffffffff,
                  win.filter or "", 1)
  end
  top = top + fh + 6 * z

  -- filter + rank the list
  local files = all_files(ed)
  local chip = win.chip or "all"
  local needle = win.filter or ""
  local shown = {}
  for _, rel in ipairs(files) do
    if chip == "all" or M.class_of(rel) == chip then
      local s = M.fuzzy(needle, rel)
      if s then shown[#shown + 1] = { rel = rel, s = s } end
    end
  end
  table.sort(shown, function(a, b)
    if a.s ~= b.s then return a.s > b.s end
    return a.rel < b.rel
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
    local e = shown[idx]
    local col = (idx - 1) % cols
    local row = (idx - 1) // cols
    local x = ctx.cx + 6 * z + col * cell
    local y = gy0 + row * (cell + name_h) - scroll
    local hov = ctx.hot and i.wx >= x and i.wx < x + tile
                and i.wy >= y and i.wy < y + tile + name_h
    local selected = win.sel == e.rel
    pal.x_ig_rect_fill(x, y, tile, tile, hov and COL.tile_hot or COL.tile,
                       5 * z)
    if selected then
      pal.x_ig_rect(x - 1, y - 1, tile + 2, tile + 2, COL.tile_sel,
                    math.max(1, 1.5 * z), 6 * z)
    end
    if g.aflash and g.aflash.path == e.rel then
      local age = (now - g.aflash.t) / 1e9
      if age < 1.2 then
        local a = math.floor((1 - age / 1.2) * 200)
        pal.x_ig_rect(x - 2, y - 2, tile + 4, tile + 4,
                      (COL.flash & ~0xff) | a, math.max(1, 2 * z), 6 * z)
      else
        g.aflash = nil
      end
    end
    local pv = preview(ed, e.rel)
    if pv and pv.kind == "image" then
      local tex, m = pv.tex, 4 * z
      local s = math.min((tile - 2 * m) / tex.w, (tile - 2 * m) / tex.h)
      local dw, dh = tex.w * s, tex.h * s
      pal.x_ig_image(tex.id, x + (tile - dw) * 0.5, y + (tile - dh) * 0.5,
                     dw, dh)
    elseif pv and pv.kind == "map" then
      cm.require("cm.ed.preview").draw_map(pv.doc, x + 3 * z, y + 3 * z,
                                           tile - 6 * z, tile - 6 * z)
    elseif pv and pv.kind == "tm" then
      cm.require("cm.ed.preview").draw_tm(pv.doc, x + 3 * z, y + 3 * z,
                                          tile - 6 * z, tile - 6 * z, COL.glyph)
    elseif pv and pv.kind == "code" then
      cm.require("cm.ed.preview").draw_lines(pv.lines, x + 3 * z, y + 2 * z,
        tile - 4 * z, tile - name_h, math.max(4, tile * 0.085), COL.dim)
    else
      local class, ext = M.class_of(e.rel)
      local glyph = class == "sound" and "~" or "?"
      local gpx = tile * 0.3
      local gwd = pal.x_ig_text_size(glyph, gpx, 1)
      pal.x_ig_text(x + (tile - gwd) * 0.5, y + tile * 0.32, gpx,
                    COL.glyph, glyph, 1)
      if ext ~= "" then
        local epx = math.max(4, tile * 0.13)
        pal.x_ig_text(x + 5 * z, y + tile - epx * 1.5, epx, COL.dim, ext, 1)
      end
    end
    local name = e.rel:match("([^/]+)$")
    local nw = pal.x_ig_text_size(name, px * 0.9, 0)
    pal.x_ig_clip_push(x, y + tile, tile, name_h)
    pal.x_ig_text(x + math.max(0, (tile - nw) * 0.5), y + tile + 2 * z,
                  px * 0.9, hov and COL.name or COL.dim, name, 0)
    pal.x_ig_clip_pop()

    -- press: select + arm the drag (the shell carries it); double = open
    if hov and i.clicked[1] then
      local dbl = win.sel == e.rel and g.aclick
                  and (now - g.aclick) < 320 * 1e6
      win.sel = e.rel
      g.aclick = now
      ctx.touch()
      if dbl then
        ed.open_asset_window(e.rel, win.x + win.w + 20, win.y)
      else
        g.adrag = { path = e.rel, sx = i.wx, sy = i.wy, from = win.id }
      end
    end
  end
  pal.x_ig_clip_pop()
  if #shown == 0 then
    pal.x_ig_text(ctx.cx + 10 * z, gy0 + 10 * z, px, COL.dim,
                  "no matches", 1)
  end
  -- the armed delete confirm (bottom bar, red)
  local armed = g.adel
  if armed and armed.id == win.id then
    if armed.path ~= win.sel then -- selection moved: disarm
      g.adel = nil
    else
      local by = ctx.cy + ctx.ch - px * 1.6
      pal.x_ig_rect_fill(ctx.cx + 2 * z, by, ctx.cw - 4 * z, px * 1.5,
                         0xf07a7a33, 3 * z)
      pal.x_ig_text(ctx.cx + 6 * z, by + px * 0.2, px * 0.9, 0xf07a7aff,
                    "delete " .. armed.path .. "?  del confirms · esc cancels",
                    0)
    end
  end
  -- footer count
  pal.x_ig_text(ctx.cx + ctx.cw - 60 * z, ctx.cy + ctx.ch - px * 1.3,
                px * 0.85, COL.dim, tostring(#shown), 1)
end

-- content wheel: scroll the grid (§12.7). win.sy holds WORLD units
-- (cm.ed.winview) so the top row stays put under canvas zoom.
function M.wheel(win, ed, dy)
  cm.require("cm.ed.winview").scroll_by(win, "sy", ed.doc.cam.zoom,
                                        -dy * 40)
  ed.touch()
end

return M
