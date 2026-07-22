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
-- drop point). `c` copies the selected SAVED asset to another known
-- project through cm.asset_transfer: project-relative paths are preserved,
-- generated companions follow, collisions never overwrite, and a failed
-- family copy rolls back.
--
-- Captured (win fields): filter, chip (type filter), tile (size), sel,
-- sy (active grid scroll) + sy_tabs (inactive tab scrolls).
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
-- The sound tab is an author-facing family, not merely decoded PCM: songs
-- and instruments are the editable sources that make those audio files useful.
-- Keeping them in "other" made a stock song disappear from Assets as soon as
-- its new owner clicked the sound chip (the H4 tutorial caught it).
local SOUND = { wav = true, ogg = true, mp3 = true,
                ins = true, song = true }

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
  if ed and ed.g and ed.g.acopy and ed.g.acopy.id == win.id then return true end
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

-- The project-settings release picker needs only plausible small metadata
-- files, including conventional extensionless legal names that the ordinary
-- asset grid intentionally omits. Content/type validation still happens in
-- cm.project after selection; this is merely a useful, bounded candidate list.
local function release_files(ed)
  local g = ed.g
  if not g.arelease then
    local names = pal.list_dir(ed.root) or {}
    table.sort(names)
    g.arelease = {}
    for _, n in ipairs(names) do
      if #g.arelease >= 1000 then break end
      local lower = n:lower()
      local base = lower:match("([^/]*)$") or lower
      local legal = base == "license" or base == "licence"
                    or base == "copying" or base == "notice"
                    or base == "copyright"
                    or base:match("^licen[cs]e[%._%-]")
                    or base:match("^copying[%._%-]")
                    or base:match("^notice[%._%-]")
                    or base:match("^copyright[%._%-]")
      local likely = lower:match("%.png$") or lower:match("%.md$")
                     or lower:match("%.txt$") or lower:match("%.license$")
                     or legal
      if likely then g.arelease[#g.arelease + 1] = n end
    end
  end
  return g.arelease
end
M.release_files = release_files

function M.invalidate(ed)
  ed.g.afiles = nil
  ed.g.files = nil -- the text picker's list too
  ed.g.arelease = nil -- project-settings icon/text/legal candidates
  ed.g.project_ref_checks = nil
end

-- ---- cross-project copy (the `c` door) ----

local function root_key(path)
  local out = cm.require("cm.project").normalize_root(path)
  if out and pal.platform == "windows" then out = out:lower() end
  return out
end

-- Other projects the editor already knows: recents first, then bundled
-- projects not in recents. Every candidate is freshly decoded/validated;
-- stale recent repair handles never become write targets. `candidates` is a
-- proof seam and also makes this list useful to scripted editor extensions.
function M.copy_targets(ed, candidates)
  local paths = {}
  if candidates then
    for _, path in ipairs(candidates) do paths[#paths + 1] = path end
  else
    for _, path in ipairs(cm.require("cm.recent").list()) do
      paths[#paths + 1] = path
    end
    local bundled = pal.list_dir("projects") or {}
    table.sort(bundled)
    for _, path in ipairs(bundled) do
      local dir = path:match("^([^/]+)/project%.lua$")
      if dir and dir ~= "picker" then paths[#paths + 1] = "projects/" .. dir end
    end
  end
  local current, seen = root_key(ed.root), {}
  local out, project = {}, cm.require("cm.project")
  for _, path in ipairs(paths) do
    local root, meta = project.inspect_root(path)
    local key = root and root_key(root)
    if root and key ~= current and not seen[key] then
      seen[key] = true
      out[#out + 1] = {
        root = root,
        name = (meta and meta.name) or root:match("([^/]+)$") or root,
      }
    end
  end
  return out
end

-- Asset-browser tiles are disk files, but one can also have an editor working
-- copy. Copying the disk version while the UI shows newer bytes is never
-- acceptable: refuse and tell the author to Ctrl+S first. All kit asset field
-- names live here; unknown/non-editor files simply have no working state.
local WORK_FIELDS = {
  "text", "spr", "map", "tm", "terr", "msh", "fig", "pal", "ins", "song",
}
function M.has_unsaved(ed, path)
  local a = ed.doc and ed.doc.assets and ed.doc.assets[path]
  if not a then return false end
  local disk = pal.read_file(ed.root .. "/" .. path)
  for _, field in ipairs(WORK_FIELDS) do
    if type(a[field]) == "string" then return a[field] ~= disk end
  end
  return false
end

local function copy_for(win, ed)
  local c = ed and ed.g and ed.g.acopy
  return c and c.id == win.id and c or nil
end

function M.begin_copy(win, ed)
  if ed.parked then
    ed.g.acopy_note = { id = win.id, bad = true,
                        text = "parked in the past — writes are walled" }
    return nil
  end
  local path = win.sel
  if not path or path == "" then return nil end
  ed.g.adel, ed.g.arn = nil, nil
  ed.g.acopy_note = nil
  local state = { id = win.id, path = path, cursor = 1,
                  targets = M.copy_targets(ed) }
  if M.has_unsaved(ed, path) then
    state.note = "save this asset first — the working copy differs from disk"
    state.bad, state.blocked = true, true
  elseif #state.targets == 0 then
    state.note = "no other known project — open the target once from the picker"
    state.bad, state.blocked = true, true
  end
  ed.g.acopy = state
  ed.touch()
  return true
end

local function copy_move(win, ed, delta)
  local c = copy_for(win, ed)
  if not c or #c.targets == 0 then return end
  c.cursor = (c.cursor - 1 + delta) % #c.targets + 1
  if not c.blocked then c.note, c.bad = nil, nil end
  ed.touch()
end

function M.copy_commit(win, ed)
  local c = copy_for(win, ed)
  local target = c and c.targets[c.cursor]
  if not target then return nil end
  if M.has_unsaved(ed, c.path) then
    c.note = "save this asset first — the working copy differs from disk"
    c.bad, c.blocked = true, true
    return nil
  end
  local result, err = cm.require("cm.asset_transfer").copy(
    ed.root, target.root, c.path)
  if not result then
    c.note, c.bad = tostring(err), true
    pal.log("[ed] project asset copy FAILED: " .. tostring(err))
    if ed.summon_console then ed.summon_console() end
    return nil, err
  end
  local n = #result.paths
  local text = ("copied %s to %s%s"):format(
    result.path, target.name, n > 1 and (" (" .. n .. " files)") or "")
  ed.g.acopy = nil
  ed.g.acopy_note = { id = win.id, text = text }
  pal.log("[ed] " .. text .. " · " .. target.root)
  ed.touch()
  return result
end

-- a cached preview object for a path (nil = fall back to a glyph). An image
-- (PNG, or a .spr's baked .png) previews its texture; a .map draws a schematic,
-- a .tm its filled cells, code its first lines — the same renderers the
-- Ctrl+Space launcher uses (cm.ed.preview), so the human's "map thumbnail /
-- code excerpt" shows in the browser too. Cached on ed.g.athumb (cleared on
-- drop/save/delete).
local function preview(ed, path)
  local g = ed.g
  -- every save bumps cm.asset_epoch: the whole thumbnail cache re-reads
  -- so a just-saved sprite/map/tm shows its new look immediately (the
  -- human's report: thumbnails froze until a project reload)
  local epoch = cm.asset_epoch or 0
  if g.athumb_epoch ~= epoch then
    g.athumb, g.athumb_epoch = {}, epoch
  end
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
  local class, class_ext = M.class_of(base)
  -- Instruments have their own canonical folder; songs and decoded audio
  -- share sound/. This is also the honest OS-drop routing now that .ins/.song
  -- participate in the browser's sound family.
  local dir = class == "image" and "art/"
              or class_ext == "ins" and "ins/"
              or class == "sound" and "sound/" or ""
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
  local out = bytes
  if pix then
    local encok
    encok, out = pcall(pal.png_encode, pix, pw, ph)
    if not encok then
      pal.log(("[ed] drop encode FAILED: %s (%s)"):format(rel, tostring(out)))
      if ed.summon_console then ed.summon_console() end
      return
    end
  end
  -- `_drop_fail` is only a focused durability-test seam.
  local ok, err = pal.write_file_atomic(ed.root .. "/" .. rel, out,
                                        ed.g and ed.g._drop_fail)
  if ok then
    if pix then
      pal.log(("[ed] added %s (converted %s, %dx%d)"):format(rel, base, pw, ph))
    else
      pal.log(("[ed] added %s (%d bytes)"):format(rel, #bytes))
    end
    M.invalidate(ed)
    ed.g.aflash = { path = rel, t = pal.time_ns() }
    return rel -- the map window places OS drops at the drop point (R8b)
  else
    pal.log(("[ed] drop write FAILED: %s (%s)"):format(rel, tostring(err)))
    if ed.summon_console then ed.summon_console() end
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
      cm.require("cm.ed.winview").scroll_switch(
        win, "sy", win.chip or "all", c)
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

-- ---- rename / move (human, D144): `r` on the selected tile opens the
-- rename bar prefilled with the full relative path — editing the folder
-- part MOVES the asset. Code refs by the old name break by design (the
-- engine's invalid-asset fallbacks are the graceful floor); everything
-- the EDITOR holds follows: the file, a .spr's baked siblings, the
-- unsaved working state, the undo journal (+.good), and open windows
-- (kind.rebind). ----

local function rename_asset(ed, old, new)
  if ed.parked then
    return nil, "parked in the past — writes are walled"
  end
  if new == old then return true end
  local src = ed.root .. "/" .. old
  local bytes = pal.read_file(src)
  if not bytes then return nil, "unreadable: " .. old end
  if pal.read_file(ed.root .. "/" .. new) ~= nil
     or (ed.doc.assets and ed.doc.assets[new] ~= nil) then
    return nil, "already exists: " .. new
  end
  local dir = new:match("^(.*)/[^/]+$")
  if dir then pal.mkdir(ed.root .. "/" .. dir) end
  local ok, err = pal.write_file_atomic(ed.root .. "/" .. new, bytes)
  if not ok then return nil, tostring(err) end
  pal.x_remove(src)
  -- a .spr's baked build products follow (same set delete takes)
  local ob = old:match("^(.*)%.[sS][pP][rR]$")
  local nb = new:match("^(.*)%.[sS][pP][rR]$")
  if ob and nb then
    for _, ext in ipairs { ".png", ".anim", ".meta" } do
      local b = pal.read_file(ed.root .. "/" .. ob .. ext)
      if b and not pal.read_file(ed.root .. "/" .. nb .. ext)
         and pal.write_file_atomic(ed.root .. "/" .. nb .. ext, b) then
        pal.x_remove(ed.root .. "/" .. ob .. ext)
      end
    end
  end
  -- the unsaved working state + the undo journal follow, so a dirty
  -- asset stays dirty (same bytes) and ctrl+z history survives the move
  if ed.doc.assets and ed.doc.assets[old] ~= nil then
    ed.doc.assets[new] = ed.doc.assets[old]
    ed.doc.assets[old] = nil
  end
  local journal = cm.require("cm.ed.journal")
  for _, pair in ipairs {
    { journal.file(ed.root, old), journal.file(ed.root, new) },
    { journal.good_file(ed.root, old), journal.good_file(ed.root, new) },
  } do
    local b = pal.read_file(pair[1])
    if b and pal.write_file_atomic(pair[2], b) then
      pal.x_remove(pair[1])
    end
  end
  -- open windows follow through each kind's own rebind door
  for _, w in ipairs(ed.doc.wins) do
    if w.path == old then
      local kind = ed.kinds[w.kind]
      if kind and kind.rebind then kind.rebind(w, ed, new)
      else w.path = new end
    end
  end
  M.invalidate(ed)
  if ed.g.athumb then ed.g.athumb[old] = nil end
  -- every epoch-keyed consumer re-reads (a live game's texture memo for
  -- the old path must fall to the invalid-asset floor, not a stale hit)
  cm.asset_epoch = (cm.asset_epoch or 0) + 1
  pal.log("[ed] renamed " .. old .. " -> " .. new)
  return true
end
M.rename_asset = rename_asset -- proof scripting

local function draw_copy_chooser(win, ctx, i)
  local ed, c = ctx.ed, copy_for(win, ctx.ed)
  if not c then return end
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  local row_h = 31 * z
  local max_rows = math.max(1, math.min(6,
    math.floor((ctx.ch - 94 * z) / row_h)))
  local rows = math.min(max_rows, #c.targets)
  local pw = math.min(ctx.cw - 16 * z, 430 * z)
  local ph = 68 * z + math.max(row_h, rows * row_h)
  local x = ctx.cx + (ctx.cw - pw) * 0.5
  local y = ctx.cy + math.max(8 * z, (ctx.ch - ph) * 0.5)
  local interactive = ctx.hot and not ctx.occluded

  -- Modal within this canvas window: the grid still renders beneath it for
  -- context, but its click path is gated while c is up.
  pal.x_ig_rect_fill(ctx.cx, ctx.cy, ctx.cw, ctx.ch, 0x141220dd, 0)
  pal.x_ig_rect_fill(x, y, pw, ph, 0x1e1b2eff, 7 * z)
  pal.x_ig_rect(x, y, pw, ph, 0x4a4370ff, math.max(1, z), 7 * z)
  pal.x_ig_text(x + 10 * z, y + 8 * z, px, COL.name,
                "copy to another project", 0)
  pal.x_ig_clip_push(x + 10 * z, y + 25 * z, pw - 20 * z, px * 1.3)
  pal.x_ig_text(x + 10 * z, y + 25 * z, px * 0.85, COL.dim, c.path, 0)
  pal.x_ig_clip_pop()

  local list_y = y + 42 * z
  if #c.targets > 0 then
    local first = math.max(1, math.min(#c.targets - rows + 1,
      c.cursor - math.floor(rows / 2)))
    for ri = 0, rows - 1 do
      local index = first + ri
      local target = c.targets[index]
      local ry = list_y + ri * row_h
      local hov = interactive and i.wx >= x + 7 * z
                  and i.wx < x + pw - 7 * z
                  and i.wy >= ry and i.wy < ry + row_h - 2 * z
      local selected = index == c.cursor
      pal.x_ig_rect_fill(x + 7 * z, ry, pw - 14 * z, row_h - 2 * z,
                         hov and COL.tile_hot or COL.tile, 4 * z)
      if selected then
        pal.x_ig_rect(x + 7 * z, ry, pw - 14 * z, row_h - 2 * z,
                      COL.tile_sel, math.max(1, z), 4 * z)
      end
      pal.x_ig_text(x + 13 * z, ry + 3 * z, px * 0.9,
                    selected and COL.name or COL.dim, target.name, 0)
      pal.x_ig_clip_push(x + 13 * z, ry + 16 * z,
                         pw - 26 * z, px * 0.9)
      pal.x_ig_text(x + 13 * z, ry + 16 * z, px * 0.72, COL.dim,
                    target.root, 0)
      pal.x_ig_clip_pop()
      if hov and i.clicked[1] then c.cursor = index; ed.touch() end
    end
  else
    pal.x_ig_text(x + 12 * z, list_y + 8 * z, px * 0.85, COL.dim,
                  "Open the target once from ← projects, then retry.", 0)
  end

  if c.note then
    pal.x_ig_clip_push(x + 10 * z, y + ph - 24 * z,
                       pw - 150 * z, 18 * z)
    pal.x_ig_text(x + 10 * z, y + ph - 22 * z, px * 0.78,
                  c.bad and 0xf07a7aff or COL.dim, c.note, 0)
    pal.x_ig_clip_pop()
  end
  local function button(bx, label, enabled)
    local bw, bh = 62 * z, 20 * z
    local by = y + ph - 27 * z
    local hov = enabled and interactive and i.wx >= bx and i.wx < bx + bw
                and i.wy >= by and i.wy < by + bh
    pal.x_ig_rect_fill(bx, by, bw, bh, hov and COL.tile_hot or COL.tile, 4 * z)
    pal.x_ig_rect(bx, by, bw, bh, enabled and 0x4a4370ff or 0x343048ff,
                  math.max(1, z), 4 * z)
    local tw = pal.x_ig_text_size(label, px * 0.82, 0)
    pal.x_ig_text(bx + (bw - tw) * 0.5, by + 4 * z, px * 0.82,
                  enabled and COL.name or COL.dim, label, 0)
    return hov and i.clicked[1]
  end
  local cancel_x = x + pw - 70 * z
  local copy_x = cancel_x - 68 * z
  if button(copy_x, "copy", #c.targets > 0 and not c.blocked) then
    M.copy_commit(win, ed)
  elseif button(cancel_x, "cancel", true) then
    ed.g.acopy = nil
    ed.touch()
  end
end

M.hotkeys = {
  { key = "del", hint = "delete",
    when = function(win, ed)
      return (win.sel or "") ~= "" and not copy_for(win, ed)
    end,
    fn = function(win, ed)
      ed.g.arn = nil -- the two bottom bars share the strip
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
  { key = "r", hint = "rename",
    when = function(win, ed)
      return (win.sel or "") ~= "" and not copy_for(win, ed)
    end,
    fn = function(win, ed)
      ed.g.adel = nil
      ed.g.arn = { id = win.id, path = win.sel, buf = win.sel }
      ed.touch()
    end },
  { key = "c", hint = "copy to another project",
    when = function(win, ed)
      return (win.sel or "") ~= "" and not copy_for(win, ed)
    end,
    fn = function(win, ed) M.begin_copy(win, ed) end },
  { key = "up", hint = "choose target", rep = true,
    when = function(win, ed) return copy_for(win, ed) ~= nil end,
    fn = function(win, ed) copy_move(win, ed, -1) end },
  { key = "down", rep = true,
    when = function(win, ed) return copy_for(win, ed) ~= nil end,
    fn = function(win, ed) copy_move(win, ed, 1) end },
  { key = "enter", hint = "copy",
    when = function(win, ed)
      local c = copy_for(win, ed)
      return c ~= nil and #c.targets > 0 and not c.blocked
    end,
    fn = function(win, ed) M.copy_commit(win, ed) end },
}

function M.escape(win, ed)
  if copy_for(win, ed) then
    ed.g.acopy = nil
    ed.touch()
    return true
  end
  if ed.g.arn and ed.g.arn.id == win.id then
    ed.g.arn = nil
    ed.touch()
    return true
  end
  if ed.g.adel and ed.g.adel.id == win.id then
    ed.g.adel = nil
    ed.touch()
    return true
  end
  return false
end

function M.on_close(win, ed)
  if copy_for(win, ed) then ed.g.acopy = nil end
end

function M.draw(win, ctx)
  local ed = ctx.ed
  local g = ed.g
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  local i = cm.require("cm.ui").inp
  local copy_up = copy_for(win, ed)

  -- Keep the underlying grid visible as context, but make every one of its
  -- controls inert while the in-window target chooser owns interaction.
  local base_i = i
  if copy_up then
    base_i = setmetatable({ clicked = {}, released = {}, buttons = {} },
                          { __index = i })
  end

  local top = chip_row(win, ctx, base_i)

  -- filter box under the chips
  local fy = ctx.cy + top
  local fh = px * 1.7
  pal.x_ig_rect(ctx.cx + 4 * z, fy, ctx.cw - 8 * z, fh, 0x4a437088, 1, 3 * z)
  if (win.filter or "") == "" then
    pal.x_ig_text(ctx.cx + 8 * z + 4, fy + 3, px, 0x8a84b066, "fuzzy search", 1)
  end
  if not ctx.occluded and not copy_up then
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
  local grid_h = math.max(0, ctx.ch - top)
  local rows_vis = math.ceil(grid_h / (cell + name_h)) + 1
  local rows = math.ceil(#shown / cols)
  local content_h = rows > 0
                    and (rows - 1) * (cell + name_h) + tile + name_h or 0
  local view = cm.require("cm.ed.winview")
  local scroll, clamped = view.clamp_scroll(
    win, "sy", z, content_h - grid_h)
  if clamped then ctx.touch() end
  local r0 = math.floor(scroll / (cell + name_h))
  pal.x_ig_clip_push(ctx.cx, gy0, ctx.cw, grid_h)
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

    -- press: select + arm the drag (the shell carries it); double = open.
    -- With a bottom bar armed (rename/delete), clicks in the bar's strip
    -- belong to the bar — a grid tile under it must not steal them and
    -- flip the selection (which disarms the bar; the tape caught it).
    local bar_up = (g.arn and g.arn.id == win.id)
                   or (g.adel and g.adel.id == win.id)
    local in_bar = bar_up and i.wy >= ctx.cy + ctx.ch - px * 1.8
    if hov and i.clicked[1] and not in_bar and not copy_up then
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
  -- the armed rename bar (bottom, accent): full-path field — a changed
  -- folder part moves the asset; enter commits, esc cancels
  local arn = g.arn
  if arn and arn.id == win.id then
    if arn.path ~= win.sel then -- selection moved: disarm
      g.arn = nil
    else
      local by = ctx.cy + ctx.ch - px * 1.6
      pal.x_ig_rect_fill(ctx.cx + 2 * z, by, ctx.cw - 4 * z, px * 1.5,
                         0x7fd8a833, 3 * z)
      local lx = ctx.cx + 6 * z
      pal.x_ig_text(lx, by + px * 0.2, px * 0.9, 0x7fd8a8ff, "rename:", 0)
      lx = lx + pal.x_ig_text_size("rename:", px * 0.9, 0) + 6 * z
      if arn.err then
        pal.x_ig_text(ctx.cx + 6 * z, by - px * 1.2, px * 0.85,
                      0xf07a7aff, arn.err, 0)
      end
      if not ctx.occluded then
        local text, _, _, st = pal.x_ig_edit {
          id = "arn" .. win.id, x = lx, y = by + 1,
          w = ctx.cx + ctx.cw - lx - 8 * z, h = px * 1.3,
          text = arn.buf or "", px = px * 0.9, font = 1,
          enter = true, multiline = false,
        }
        arn.buf = text
        if st and st.submit then
          local new = (text or ""):gsub("[\r\n\t]", "")
                      :gsub("^%s+", ""):gsub("%s+$", "")
          if new == "" or new:find("/$") then
            arn.err = "type a file path"
          elseif new == arn.path then
            g.arn = nil
          else
            -- a basename with no extension keeps the old one
            if not new:match("([^/]*)$"):find("%.") then
              local oext = arn.path:match("%.([%w]+)$")
              if oext then new = new .. "." .. oext end
            end
            local ok, err = rename_asset(ed, arn.path, new)
            if ok then
              win.sel = new
              g.aflash = { path = new, t = pal.time_ns() }
              g.arn = nil
            else
              arn.err = err
            end
          end
          ed.touch()
        end
      end
    end
  end
  draw_copy_chooser(win, ctx, i)
  local copy_note = g.acopy_note
  if copy_note and copy_note.id == win.id and not copy_for(win, ed) then
    pal.x_ig_clip_push(ctx.cx + 6 * z, ctx.cy + ctx.ch - px * 1.35,
                       math.max(0, ctx.cw - 72 * z), px * 1.2)
    pal.x_ig_text(ctx.cx + 6 * z, ctx.cy + ctx.ch - px * 1.3,
                  px * 0.78, copy_note.bad and 0xf07a7aff or COL.dim,
                  copy_note.text, 0)
    pal.x_ig_clip_pop()
  end
  -- footer count
  pal.x_ig_text(ctx.cx + ctx.cw - 60 * z, ctx.cy + ctx.ch - px * 1.3,
                px * 0.85, COL.dim, tostring(#shown), 1)
end

-- content wheel: scroll the grid (§12.7). win.sy holds WORLD units
-- (cm.ed.winview) so the top row stays put under canvas zoom.
function M.wheel(win, ed, dy)
  if copy_for(win, ed) then return true end
  local z = cm.require("cm.ed.cam").screen_zoom(ed.doc.cam)
  cm.require("cm.ed.winview").scroll_by(win, "sy", z,
                                        -dy * 40)
  ed.touch()
end

return M
