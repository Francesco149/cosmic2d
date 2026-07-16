-- projects/picker — the engine's front door (R5, D052): the teidraw-style
-- project picker. Boots when `cosmic` is run with no project argument.
-- Scans projects/* for project.lua and merges the engine-root .recent.dat.
-- Open folder registers an arbitrary project in place (no copy), while stale
-- recent tiles can be repaired through the same native chooser. Ready recent
-- tiles expose reveal/rename/move/duplicate/archive/delete; relocation is a
-- collision-safe directory rename followed by an atomic recents update,
-- duplicate is a staged cancellable copy published by one no-replace rename,
-- archive streams a dated no-replace backup, and delete demands the exact
-- folder name (or a just-made archive as its safety net) before the tree and
-- its tile go. A tile opens the project IN THE EDITOR (the picker is the
-- editor's front door); the ▶ zone boots play mode.
--
-- The switch mechanism (D052): write "<path>\n<mode>" into the `boot.next`
-- named buffer (named buffers survive VM reboots by contract) and call
-- pal.x_reboot() — the next boot adopts the carrier, sweeps the old
-- buffers, and boots the chosen project.
--
-- Everything here is render/dev over the x_ig drawlist; the sim below is
-- an empty shell. Headless/verify never see any of it (ig absence).

local M = select(2, ...) or {}

local view
local chrome = cm.require("cm.ed.chrome")
local project = cm.require("cm.project")
local location = cm.require("cm.project_location")
local recent = cm.require("cm.recent")

M.scan = M.scan or nil -- ephemeral tile cache (render/dev)
M.folder = M.folder or nil -- active native chooser (open / repair / move-to)
M.notice = M.notice or nil -- latest actionable lifecycle result
M.action = M.action or nil -- ready-tile project-folder overlay

local C = {
  bg = 0x141220ff, text = 0xE8E4FFff, dim = 0x8a84b0ff,
  tile = 0x1e1b2eff, tile_edge = 0x4a4370ff, tile_hot = 0x262238ff,
  accent = 0x7fd8a8ff, play = 0xffb46eff, missing = 0x5a5480ff,
  bad = 0xff8295ff,
}

function M.init()
  view = cm.require("cm.view")
  view.mode = "canvas" -- no game blit; the picker draws the whole window
end

function M.step() end

-- ---- the project list ----

-- Load a project's metadata table through the same declarative codec and
-- runtime validation used by boot. Broken metadata falls back to a name-only
-- regex so a recent entry stays visible and repairable.
local function proj_meta(dir)
  local src = pal.read_file(dir .. "/project.lua")
  if not src then return nil, "missing", "folder or project.lua is missing" end
  local t, err = project.decode(src, "@" .. dir .. "/project.lua")
  if t then
    local ok
    ok, err = project.validate_runtime(t)
    if ok then return t, "ready" end
  end
  return { name = src:match('name%s*=%s*"([^"]*)"') }, "invalid", tostring(err)
end

-- One tile record from a project's metadata (nil-safe: a missing/broken path
-- still yields a named recent tile).
local function tile(path, meta, state, is_recent, issue)
  meta = meta or {}
  local name = meta.name
  if not name or name == "" then name = path:match("([^/]+)$") end
  local ok = state == "ready"
  -- A broken recent tile whose folder still exists (e.g. a half-deleted
  -- tree) keeps the confirmed-delete door; a fully missing folder only
  -- needs its tile removed.
  local present = ok
  if not ok and is_recent then
    local info = pal.x_path_info(path)
    present = (info and info.type == "directory") or false
  end
  return { path = path, ok = ok, state = state, present = present,
           recent = is_recent, issue = issue, name = name or path,
           author = meta.author, version = meta.version,
           desc = meta.description }
end

local function scan()
  if M.scan then return M.scan end
  local tiles, seen = {}, {}
  -- Recents are already newest-first; keep that order exactly, then append
  -- bundled projects that were not recently opened.
  local rec = pal.read_file(recent.path)
  if rec then
    for line in rec:gmatch("[^\n]+") do
      local path = project.normalize_root(line)
      if path and not seen[path] then
        seen[path] = true
        local meta, state, issue = proj_meta(path)
        tiles[#tiles + 1] = tile(path, meta, state, true, issue)
      end
    end
  end
  local names = pal.list_dir("projects") or {}
  table.sort(names)
  for _, n in ipairs(names) do
    local dir = n:match("^([^/]+)/project%.lua$")
    if dir and dir ~= "picker" then
      local path = "projects/" .. dir
      if not seen[path] then
        seen[path] = true
        local meta, state, issue = proj_meta(path)
        tiles[#tiles + 1] = tile(path, meta, state, false, issue)
      end
    end
  end
  M.scan = tiles
  return tiles
end

-- Public proof/console door: open a ready recent tile's folder actions without
-- synthesizing a mouse event. Ordinary UI reaches the same state through ... .
local function open_actions(value, mode)
  local root = project.normalize_root(type(value) == "table" and value.path or value)
  if not root then return nil, "project action needs a folder path" end
  local found
  for _, item in ipairs(scan()) do
    if item.path == root then found = item; break end
  end
  if not found then return nil, "project tile is not ready" end
  if not found.ok and not (mode == "delete" and found.present) then
    return nil, "project tile is not ready"
  end
  if not found.recent then
    return nil, "open the project once before changing its folder"
  end
  if mode == "duplicate" or mode == "archive" then
    return M.begin_folder { kind = mode, source = root, name = found.name }
  end
  local _, folder_name = location.parts(root)
  M.action = {
    path = root, name = found.name, mode = mode or "menu",
    folder = folder_name or found.name,
    rename = mode == "delete" and "" or folder_name or found.name,
    focus = (mode == "rename" or mode == "delete") and true or nil,
  }
  return true
end
M.open_actions = open_actions

local say

local function launch(path, mode)
  pal.log("[picker] " .. mode .. " " .. path)
  local ok, err = cm.require("cm.main").switch_project(path, mode)
  if not ok then say("cannot open project: " .. tostring(err), true) end
  return ok, err
end
M.launch = launch -- scripted driving (proofs, keyboard flows later)

-- ---- arbitrary project folders + stale recent repair ----

say = function(text, bad)
  M.notice = { text = tostring(text), bad = bad and true or false }
  pal.log("[picker] " .. (bad and "FAILED: " or "") .. tostring(text))
end

local function begin_folder(intent)
  if M.folder then return nil, "a folder chooser is already active" end
  -- Backward-compatible public shape from D076: a tile table means repair.
  if intent and not intent.kind and intent.path then
    intent = { kind = "repair", tile = intent }
  end
  intent = intent or { kind = "open" }
  if pal.version.api < 15 or type(pal.x_folder_dialog) ~= "function"
     or type(pal.x_folder_dialog_poll) ~= "function" then
    local err = "opening a project folder needs PAL api >= 15"
    say(err, true)
    return nil, err
  end
  local start
  if intent.kind == "move" or intent.kind == "duplicate"
      or intent.kind == "archive" then
    start = location.parts(intent.source)
  end
  local ok, err = pal.x_folder_dialog(start)
  if not ok then say(err, true); return nil, err end
  M.folder = intent
  if intent.kind == "repair" then
    say("choose the replacement for " .. intent.tile.path)
  elseif intent.kind == "move" then
    say("choose the destination parent for " .. intent.source)
  elseif intent.kind == "duplicate" then
    say("choose the destination parent for a duplicate of " .. intent.source)
  elseif intent.kind == "archive" then
    say("choose the destination folder for an archive of " .. intent.source)
  else
    say("choose a cosmic2d project folder")
  end
  return true
end
M.begin_folder = begin_folder

local function accept_folder(raw)
  local intent = M.folder
  M.folder = nil
  -- A hot reload may preserve D076's old {repair=tile} ephemeral shape while
  -- its native dialog is still open.
  if intent and intent.repair and not intent.kind then
    intent = { kind = "repair", tile = intent.repair }
  end
  if intent and intent.kind == "duplicate" then
    -- The chosen parent only prepares the duplicate modal; nothing is copied
    -- until its editable folder name is confirmed there.
    local parent, perr = project.normalize_root(raw)
    if not parent then say(perr, true); return nil, perr end
    local _, source_name = location.parts(intent.source)
    M.action = {
      path = intent.source, name = intent.name, mode = "duplicate",
      parent = parent, rename = (source_name or "project") .. " copy",
      focus = true,
    }
    say("name the duplicate of " .. intent.source)
    return true, parent, false
  end
  if intent and intent.kind == "archive" then
    -- The dated archive name is derived, so the job starts as soon as the
    -- destination is chosen; the modal owns progress, cancel, and the
    -- delete-with-a-safety-net follow-up.
    local parent, perr = project.normalize_root(raw)
    if not parent then say(perr, true); return nil, perr end
    local _, source_name = location.parts(intent.source)
    M.action = {
      path = intent.source, name = intent.name, mode = "archive",
      parent = parent, folder = source_name or "project",
      job = location.archive_start(intent.source, parent),
    }
    say("archiving " .. intent.source)
    return true, parent, false
  end
  if intent and intent.kind == "move" then
    local ok, result, outcome = location.move_to(intent.source, raw)
    M.scan = nil -- either the new tile or the stale repair handle is visible
    if not ok then
      say(result, true)
      return nil, result, false, outcome
    end
    say("moved project folder · " .. result)
    return true, result, false, outcome
  end
  local root, meta = project.inspect_root(raw)
  if not root then say(meta, true); return nil, meta end
  local ok, err
  if intent and intent.kind == "repair" then
    ok, err = recent.replace(intent.tile.path, root)
  else
    ok, err = recent.note(root)
  end
  if not ok then
    local msg = "cannot update recent projects: " .. tostring(err)
    say(msg, true)
    return nil, msg
  end
  M.scan = nil -- registration is visible before the project-switch tick ends
  say((intent and intent.kind == "repair" and "repaired · opening " or "opening ")
      .. (meta.name or root))
  launch(root, "edit")
  return true, root, true
end
M.accept_folder = accept_folder -- scripted lifecycle proof door

-- Start the prepared duplicate job (UI button + scripted proof door). The job
-- advances inside the modal so progress and cancel stay visible.
function M.start_duplicate(opts)
  local a = M.action
  if not a or a.mode ~= "duplicate" then return nil, "no duplicate is prepared" end
  if a.job and not a.job.terminal then return nil, "a duplicate is already running" end
  a.error = nil
  a.job = location.duplicate_start(a.path, a.parent, a.rename, opts)
  return a.job
end

-- Start the prepared delete (UI button + scripted proof door). The typed (or
-- archive-armed) confirmation travels as opts.confirm so the policy layer
-- re-verifies it against the exact folder name.
function M.start_delete(opts)
  local a = M.action
  if not a or a.mode ~= "delete" then return nil, "no delete is prepared" end
  if a.job and not a.job.terminal then return nil, "a delete is already running" end
  a.error = nil
  opts = opts or {}
  if opts.confirm == nil then opts.confirm = a.rename end
  a.job = location.delete_start(a.path, opts)
  return a.job
end

local function poll_folder()
  if not M.folder then return false end
  local state, value = pal.x_folder_dialog_poll()
  if state == "pending" then return false end
  if state == "selected" then
    local ok, _, switched = accept_folder(value)
    return ok == true and switched == true
  end
  M.folder = nil
  if state == "error" then say("folder chooser: " .. tostring(value), true)
  elseif state == "cancelled" then say("folder selection cancelled")
  elseif state ~= "idle" then say("unexpected folder chooser state: " .. tostring(state), true) end
  return false
end

local function refresh()
  M.scan = nil
  say("project list refreshed")
end
M.refresh = refresh

-- ---- new project (G5): scaffold + open in the editor ----

local function scaffold()
  local words = cm.require("cm.words")
  local name = words.unique(function(nm)
    return pal.read_file("projects/" .. nm .. "/project.lua") ~= nil
  end)
  local dir = "projects/" .. name
  local ok, err = cm.require("cm.project").scaffold(dir, name)
  if not ok then
    pal.log("[picker] CREATE FAILED: " .. tostring(err))
    return nil, err
  end
  M.scan = nil
  pal.log("[picker] new project " .. dir)
  launch(dir, "edit")
end
M.scaffold = scaffold

-- ---- draw ----

-- "by <author>  ·  v<version>" from whatever metadata is present, or nil.
local function byline(t)
  local parts = {}
  if t.author and t.author ~= "" then parts[#parts + 1] = "by " .. t.author end
  if t.version and t.version ~= "" then parts[#parts + 1] = "v" .. t.version end
  return #parts > 0 and table.concat(parts, "  ·  ") or nil
end

function M.draw()
  pal.begin_frame(0.078, 0.07, 0.125, 1) -- the target is never shown
  local ig = pal.x_ig_frame()
  if not ig then return end
  view.resolve_accessibility(ig.dpi, ig.w, ig.h)
  local i
  ig, i = chrome.frame(ig, cm.require("cm.ui").inp,
                       view.cfg.chrome_scale or 1)
  local pal = chrome.pal
  local modal_at_start = M.action ~= nil

  pal.x_ig_rect_fill(0, 0, ig.w, ig.h, C.bg)
  if poll_folder() then return end -- selected folder queued a VM reboot
  pal.x_ig_text(28, 22, 26, C.text, "cosmic2d", 0)
  pal.x_ig_text(28 + pal.x_ig_text_size("cosmic2d", 26, 0) + 14, 31, 13,
                C.dim, "pick a project — click opens the editor; play boots the game", 0)

  local function button(x, y, w, h, label, enabled)
    local hov = enabled and i.wx >= x and i.wx < x + w
                and i.wy >= y and i.wy < y + h
    pal.x_ig_rect_fill(x, y, w, h, hov and C.tile_hot or C.tile, 6)
    pal.x_ig_rect(x, y, w, h, hov and C.accent or C.tile_edge, 1, 6)
    local tw = pal.x_ig_text_size(label, 11, 0)
    pal.x_ig_text(x + (w - tw) * 0.5, y + 6, 11,
                  enabled and (hov and C.text or C.dim) or C.missing, label, 0)
    return hov and i.clicked[1]
  end

  local open_w, refresh_w = 104, 72
  local refresh_x = ig.w - 28 - refresh_w
  local open_x = refresh_x - 8 - open_w
  if button(open_x, 18, open_w, 28,
            M.folder and "choosing…" or "open folder",
            not M.folder and not modal_at_start) then
    begin_folder()
  end
  if button(refresh_x, 18, refresh_w, 28, "refresh",
            not M.folder and not modal_at_start) then refresh() end
  if M.notice then
    pal.x_ig_clip_push(28, 55, math.max(40, ig.w - 56), 18)
    pal.x_ig_text(28, 55, 11, M.notice.bad and C.bad or C.dim,
                  M.notice.text, 0)
    pal.x_ig_clip_pop()
  else
    pal.x_ig_text(28, 55, 11, C.dim,
                  "Open keeps an external project in place · ... manages its folder.", 0)
  end

  local tiles = scan()
  local pad, tw, th = 20, 240, 112
  local cols = math.max(1, math.floor((ig.w - 2 * pad) / (tw + pad)))
  local x0, y0 = 28, 82
  for idx, t in ipairs(tiles) do
    local col, row = (idx - 1) % cols, (idx - 1) // cols
    local x = x0 + col * (tw + pad)
    local y = y0 + row * (th + pad)
    if y > ig.h then break end
    local hov = i.wx >= x and i.wx < x + tw and i.wy >= y and i.wy < y + th
    -- the play zone, bottom-right of the tile
    local pzx, pzy, pzw, pzh = x + tw - 50, y + th - 34, 44, 26
    local phov = hov and i.wx >= pzx and i.wx < pzx + pzw
                 and i.wy >= pzy and i.wy < pzy + pzh
    local azx, azy, azw, azh = x + tw - 36, y + 8, 28, 22
    local ahov = t.recent and t.ok and i.wx >= azx and i.wx < azx + azw
                 and i.wy >= azy and i.wy < azy + azh
    pal.x_ig_rect_fill(x, y, tw, th, hov and C.tile_hot or C.tile, 8)
    pal.x_ig_rect(x, y, tw, th, (hov and not phov and not ahov) and C.accent
                  or C.tile_edge, hov and 1.5 or 1, 8)
    -- two subtitle rows under the name: a byline (author · version) then
    -- the description; the path stands in for whichever the metadata omits
    -- so metadata-less / sibling-repo projects still show where they live.
    local bl = byline(t)
    local desc = (t.desc and t.desc ~= "") and t.desc or nil
    local sub1 = bl or t.path
    local sub2 = desc or (bl and t.path) or nil
    pal.x_ig_clip_push(x, y, tw - (t.ok and t.recent and 46 or
                                   (t.ok and 8 or 30)), th)
    pal.x_ig_text(x + 14, y + 11, 16, t.ok and C.text or C.missing,
                  t.name, 0)
    if sub1 then pal.x_ig_text(x + 14, y + 33, 10, C.dim, sub1, 1) end
    if sub2 then pal.x_ig_text(x + 14, y + 51, 10, C.dim, sub2, 1) end
    pal.x_ig_clip_pop()
    local tag = t.recent and (t.ok and "recent" or ("recent · " .. t.state))
                or (not t.ok and t.state)
    if tag then
      pal.x_ig_text(x + 14, y + th - 22, 10, t.ok and C.dim or C.missing,
                    tag, 0)
    end
    if not t.ok then
      if t.issue then
        pal.x_ig_clip_push(x + 14, y + 51, tw - 28, 17)
        pal.x_ig_text(x + 14, y + 51, 10, C.bad, t.issue, 0)
        pal.x_ig_clip_pop()
      end
      if t.recent and button(x + 14, y + th - 52, 70, 24, "repair",
                             not M.folder and not modal_at_start) then
        begin_folder(t)
      end
      if t.recent and button(x + 92, y + th - 52, 70, 24, "remove",
                             not M.folder and not modal_at_start) then
        local ok, err = recent.remove(t.path)
        if ok then
          M.scan = nil
          say("removed missing recent · " .. t.path)
        else
          say("cannot remove recent: " .. tostring(err), true)
        end
      end
      -- A broken folder that still exists (e.g. an interrupted delete)
      -- keeps the confirmed-delete door so leftovers never strand.
      if t.recent and t.present
          and button(x + 170, y + th - 52, 56, 24, "delete",
                     not M.folder and not modal_at_start) then
        open_actions(t.path, "delete")
      end
    end
    if t.ok then
      local action_clicked = false
      if t.recent and button(azx, azy, azw, azh, "...",
                             not M.folder and not modal_at_start) then
        open_actions(t)
        action_clicked = true
      end
      pal.x_ig_rect_fill(pzx, pzy, pzw, pzh,
                         phov and 0x3a3560ff or 0x26223855, 6)
      pal.x_ig_text(pzx + 8, pzy + 6, 12, phov and C.play or C.dim,
                    "play", 0)
      if hov and i.clicked[1] and not action_clicked and not ahov
          and not modal_at_start then
        launch(t.path, phov and "play" or "edit")
      end
    end
  end

  -- the "+ New project" tile, at the end of the grid (G5): scaffolds a
  -- 3-random-words project from the template and opens it in the editor
  do
    local idx = #tiles + 1
    local col, row = (idx - 1) % cols, (idx - 1) // cols
    local x = x0 + col * (tw + pad)
    local y = y0 + row * (th + pad)
    if y <= ig.h then
      local hov = i.wx >= x and i.wx < x + tw and i.wy >= y and i.wy < y + th
      pal.x_ig_rect_fill(x, y, tw, th, hov and C.tile_hot or C.tile, 8)
      pal.x_ig_rect(x, y, tw, th, hov and C.accent or C.tile_edge,
                    hov and 1.5 or 1, 8)
      pal.x_ig_text(x + 14, y + 14, 18, hov and C.text or C.accent,
                    "+ New project", 0)
      pal.x_ig_text(x + 14, y + 42, 11, C.dim,
                    "3 random words · opens in the editor", 1)
      if hov and i.clicked[1] and not modal_at_start then scaffold() end
    end
  end

  if #tiles == 0 then
    pal.x_ig_text(x0, y0 + 96, 15, C.dim,
                  "no projects yet — click + New project", 0)
  end

  -- Ready recent-tile actions live in one modal so ordinary tile click/play
  -- stays generous. Relocation errors remain in context; a post-move recents
  -- failure closes it because the stale tile is now the deliberate repair UI.
  if M.action then
    local a = M.action
    local pw = math.min(560, ig.w - 48)
    -- The delete layout is the tallest; 240 keeps its buttons on screen at
    -- 300% fixed chrome on an ordinary 1280x800 window (D074's logical 266).
    local ph = (a.mode == "rename" or a.mode == "menu") and 224
               or a.mode == "duplicate" and 226
               or a.mode == "archive" and 226
               or a.mode == "delete" and 240 or 224
    local px, py = (ig.w - pw) * 0.5, math.max(24, (ig.h - ph) * 0.38)
    local busy = (a.job and not a.job.terminal) or false
    for _, key in ipairs(i.keys) do
      if key.down and not key.rep and key.scancode == 41 then
        -- Esc can never abandon a running job silently; it asks the job to
        -- cancel and the job settles its own state before the modal closes.
        if busy then
          location.job_cancel(a.job)
        else
          M.action = nil
          return
        end
      end
    end
    if busy then
      for _ = 1, 12 do -- a few files per frame keeps large trees responsive
        location.job_step(a.job)
        if a.job.terminal then break end
      end
    end
    if a.job and a.job.terminal then
      -- Terminal handling runs exactly once: the handle is cleared here.
      local job = a.job
      a.job = nil
      if a.mode == "duplicate" then
        if job.complete then
          M.scan = nil
          say("duplicated project folder · " .. tostring(job.published))
          M.action = nil
          return
        elseif job.cancelled then
          say("duplicate cancelled")
        else
          if job.published then M.scan = nil end
          say(job.error or "duplicate failed", true)
          a.error = job.error or "duplicate failed"
        end
      elseif a.mode == "archive" then
        -- Success keeps the modal open: the fresh archive is the safety net
        -- for the delete offered right here.
        if job.complete then
          say("archived project folder · " .. tostring(job.published))
          a.archived = job.published
        elseif job.cancelled then
          say("archive cancelled")
          M.action = nil
          return
        else
          say(job.error or "archive failed", true)
          a.error = job.error or "archive failed"
        end
      elseif a.mode == "delete" then
        M.scan = nil -- any removal already changed what the tile means
        if job.complete then
          say("deleted project folder · " .. tostring(a.path))
          M.action = nil
          return
        elseif job.cancelled and (job.removed or 0) > 0 then
          local msg = "delete cancelled; already-removed files are gone"
          say(msg, true)
          a.error = msg
        elseif job.cancelled then
          say("delete cancelled")
        else
          say(job.error or "delete failed", true)
          a.error = job.error or "delete failed"
        end
      end
    end
    busy = (a.job and not a.job.terminal) or false
    pal.x_ig_overlay(true)
    pal.x_ig_rect_fill(0, 0, ig.w, ig.h, 0x080611cc)
    pal.x_ig_rect_fill(px, py, pw, ph, C.tile, 10)
    pal.x_ig_rect(px, py, pw, ph, C.tile_edge, 1, 10)
    pal.x_ig_text(px + 18, py + 16, 17,
                  a.mode == "delete" and C.bad or C.text,
                  a.mode == "rename" and "rename project folder"
                    or a.mode == "duplicate" and "duplicate project"
                    or a.mode == "archive" and "archive project"
                    or a.mode == "delete" and "delete project folder"
                    or "project folder", 0)
    pal.x_ig_text(px + 18, py + 42, 12, C.accent, a.name or "project", 0)
    pal.x_ig_clip_push(px + 18, py + 61, pw - 36, 18)
    -- Duplicate/archive trade the source-path row (already on the tile and
    -- menu) for the destination parent so the flow fits 300% fixed chrome.
    pal.x_ig_text(px + 18, py + 61, 10, C.dim,
                  (a.mode == "duplicate" or a.mode == "archive")
                    and ("into  " .. tostring(a.parent))
                    or a.path, 1)
    pal.x_ig_clip_pop()

    -- The shared destination-folder-name field. The modal uses imgui's
    -- foreground drawlist; a normal widget window is behind that layer. Keep
    -- x_ig_edit as the IME/selection machine and mirror its glyphs,
    -- selection, and caret in the foreground explicitly.
    local function name_field(id, fy, fh, enabled)
      pal.x_ig_rect_fill(px + 18, fy, pw - 36, fh, 0x141220ff, 5)
      pal.x_ig_rect(px + 18, fy, pw - 36, fh, C.tile_edge, 1, 5)
      local shown, st, active
      if enabled then
        local text, changed
        text, changed, active, st = pal.x_ig_edit {
          id = id, x = px + 25, y = fy + 6,
          w = pw - 50, h = fh - 10, text = a.rename or "", px = 13,
          font = 1, multiline = false, enter = true, focus = a.focus or nil,
          ghost = true,
        }
        a.focus = nil
        if changed then
          a.rename = text:gsub("[\r\n\t]", "")
          a.error = nil
        end
        shown = changed and a.rename or text
      else
        shown = a.rename or ""
      end
      local sx = st and st.sx or 0
      local tx, ty = px + 25 - sx, fy + 8
      pal.x_ig_clip_push(px + 23, fy + 3, pw - 46, fh - 6)
      if active and st and st.sa and st.sb and st.sb > st.sa then
        local before = shown:sub(1, st.sa)
        local selected = shown:sub(st.sa + 1, st.sb)
        local bx = pal.x_ig_text_size(before, 13, 1)
        local sw = pal.x_ig_text_size(selected, 13, 1)
        pal.x_ig_rect_fill(tx + bx, fy + 6, math.max(1, sw), 18, 0x5a548099, 2)
      end
      pal.x_ig_text(tx, ty, 13, enabled and C.text or C.dim, shown, 1)
      if active and st and st.caret then
        local before = shown:sub(1, st.caret)
        local cx = pal.x_ig_text_size(before, 13, 1)
        pal.x_ig_line(tx + cx, fy + 6, tx + cx, fy + 25, C.accent, 1)
      end
      pal.x_ig_clip_pop()
      local valid, name_error = location.validate_name(a.rename)
      return valid, name_error, st and st.submit
    end

    if a.mode == "rename" then
      local fy, fh = py + 92, 32
      local valid, name_error, submit =
        name_field("picker_project_folder_rename", fy, fh, true)
      local status = a.error or name_error
      if status then
        pal.x_ig_clip_push(px + 18, fy + 39, pw - 36, 18)
        pal.x_ig_text(px + 18, fy + 39, 10, C.bad, status, 0)
        pal.x_ig_clip_pop()
      else
        pal.x_ig_text(px + 18, fy + 39, 10, C.dim,
                      "Only the folder changes; project name stays in settings.", 0)
      end
      local by = py + ph - 44
      if button(px + 18, by, 104, 28, "rename folder", valid ~= nil)
          or (submit and valid) then
        local ok, result, outcome = location.rename(a.path, a.rename)
        M.scan = nil
        if ok then
          say("renamed project folder · " .. result)
          M.action = nil
        else
          say(result, true)
          a.error = result
          if outcome and outcome.moved then M.action = nil end
        end
      end
      if M.action and button(px + 132, by, 72, 28, "cancel", true) then
        M.action = nil
      end
    elseif a.mode == "duplicate" then
      local fy, fh = py + 84, 32
      local valid, name_error, submit =
        name_field("picker_project_folder_duplicate", fy, fh, not busy)
      local status = a.error or name_error
      if status then
        pal.x_ig_clip_push(px + 18, fy + 39, pw - 36, 18)
        pal.x_ig_text(px + 18, fy + 39, 10, C.bad, status, 0)
        pal.x_ig_clip_pop()
      elseif not busy then
        pal.x_ig_text(px + 18, fy + 39, 10, C.dim,
                      "Copies the saved project; editor history stays behind.", 0)
      end
      if busy then
        local job = a.job
        local ratio = (job.total and job.total > 0)
                      and math.min(1, (job.done or 0) / job.total) or 0
        pal.x_ig_text(px + 18, py + 140, 11, C.accent,
                      tostring(job.phase or "copying"), 0)
        pal.x_ig_rect_fill(px + 18, py + 154, pw - 36, 8, 0x141220ff, 3)
        pal.x_ig_rect_fill(px + 18, py + 154,
                           math.max(2, (pw - 36) * ratio), 8, C.accent, 3)
        pal.x_ig_clip_push(px + 18, py + 166, pw - 36, 14)
        pal.x_ig_text(px + 18, py + 166, 10, C.dim,
                      tostring(job.detail or ""), 1)
        pal.x_ig_clip_pop()
      end
      local by = py + ph - 44
      if busy then
        if button(px + 18, by, 104, 28, "cancel copy", true) then
          location.job_cancel(a.job)
        end
      else
        if button(px + 18, by, 104, 28, "duplicate", valid ~= nil)
            or (submit and valid) then
          M.start_duplicate()
        end
        if M.action and button(px + 132, by, 72, 28, "cancel", true) then
          M.action = nil
        end
      end
    elseif a.mode == "archive" then
      local by = py + ph - 44
      if busy then
        local job = a.job
        local ratio = (job.total and job.total > 0)
                      and math.min(1, (job.done or 0) / job.total) or 0
        pal.x_ig_text(px + 18, py + 96, 11, C.accent,
                      tostring(job.phase or "archiving"), 0)
        pal.x_ig_rect_fill(px + 18, py + 112, pw - 36, 8, 0x141220ff, 3)
        pal.x_ig_rect_fill(px + 18, py + 112,
                           math.max(2, (pw - 36) * ratio), 8, C.accent, 3)
        pal.x_ig_clip_push(px + 18, py + 126, pw - 36, 14)
        pal.x_ig_text(px + 18, py + 126, 10, C.dim,
                      tostring(job.detail or ""), 1)
        pal.x_ig_clip_pop()
        if button(px + 18, by, 118, 28, "cancel archive", true) then
          location.job_cancel(a.job)
        end
      elseif a.archived then
        -- The parent is on the "into" row; the dated file name is the news.
        pal.x_ig_text(px + 18, py + 90, 10, C.dim, "archived as", 0)
        pal.x_ig_clip_push(px + 18, py + 106, pw - 36, 16)
        pal.x_ig_text(px + 18, py + 106, 11, C.accent,
                      a.archived:match("([^/]+)$") or a.archived, 1)
        pal.x_ig_clip_pop()
        pal.x_ig_text(px + 18, py + 132, 10, C.dim,
                      "The folder is unchanged. Deleting now keeps this "
                      .. "archive as the safety net.", 0)
        if button(px + 18, by, 128, 28, "delete folder…", true) then
          -- Two-step confirmation: this click arms it, the delete screen's
          -- explicit red button (naming the folder) is the second step.
          a.mode, a.error, a.rename = "delete", nil, a.folder
        end
        if M.action and button(px + 156, by, 72, 28, "close", true) then
          M.action = nil
        end
      else
        if a.error then
          pal.x_ig_clip_push(px + 18, py + 96, pw - 36, 34)
          pal.x_ig_text(px + 18, py + 96, 10, C.bad, a.error, 1)
          pal.x_ig_clip_pop()
        end
        if button(px + 18, by, 72, 28, "close", true) then
          M.action = nil
        end
      end
    elseif a.mode == "delete" then
      pal.x_ig_text(px + 18, py + 84, 10, C.bad,
                    "Permanently removes this folder — including editor "
                    .. "history and any unsaved work.", 0)
      local by = py + ph - 44
      if busy then
        local job = a.job
        local ratio = (job.total and job.total > 0)
                      and math.min(1, (job.done or 0) / job.total) or 0
        pal.x_ig_text(px + 18, py + 110, 11, C.bad,
                      tostring(job.phase or "deleting"), 0)
        pal.x_ig_rect_fill(px + 18, py + 126, pw - 36, 8, 0x141220ff, 3)
        pal.x_ig_rect_fill(px + 18, py + 126,
                           math.max(2, (pw - 36) * ratio), 8, C.bad, 3)
        pal.x_ig_clip_push(px + 18, py + 140, pw - 36, 14)
        pal.x_ig_text(px + 18, py + 140, 10, C.dim,
                      tostring(job.detail or ""), 1)
        pal.x_ig_clip_pop()
        if button(px + 18, by, 112, 28, "cancel delete", true) then
          location.job_cancel(a.job)
        end
      else
        local armed
        if a.archived then
          -- The just-made archive is the safety net; no retyping.
          armed = a.rename == a.folder
          pal.x_ig_text(px + 18, py + 106, 10, C.dim, "safety net", 0)
          pal.x_ig_clip_push(px + 18, py + 122, pw - 36, 16)
          pal.x_ig_text(px + 18, py + 122, 11, C.accent,
                        a.archived:match("([^/]+)$") or a.archived, 1)
          pal.x_ig_clip_pop()
          if a.error then
            pal.x_ig_clip_push(px + 18, py + 146, pw - 36, 18)
            pal.x_ig_text(px + 18, py + 146, 10, C.bad, a.error, 0)
            pal.x_ig_clip_pop()
          end
        else
          local fy, fh = py + 106, 32
          name_field("picker_project_folder_delete", fy, fh, true)
          armed = a.rename == a.folder
          local status = a.error
          if status then
            pal.x_ig_clip_push(px + 18, fy + 39, pw - 36, 18)
            pal.x_ig_text(px + 18, fy + 39, 10, C.bad, status, 0)
            pal.x_ig_clip_pop()
          else
            pal.x_ig_text(px + 18, fy + 39, 10, C.dim,
                          'Type the folder name "' .. tostring(a.folder)
                          .. '" to confirm.', 0)
          end
        end
        if button(px + 18, by, 122, 28, "delete forever", armed) and armed then
          M.start_delete()
        end
        if M.action and button(px + 150, by, 72, 28, "cancel", true) then
          M.action = nil
        end
      end
    else
      pal.x_ig_text(px + 18, py + 91, 11, C.dim,
                    "Reveal, rename, move, duplicate, archive, or delete "
                    .. "this project's folder.", 0)
      if a.error then
        pal.x_ig_clip_push(px + 18, py + 112, pw - 36, 18)
        pal.x_ig_text(px + 18, py + 112, 10, C.bad, a.error, 0)
        pal.x_ig_clip_pop()
      end
      local by1, by2 = py + ph - 80, py + ph - 44
      if button(px + pw - 48, py + 12, 30, 24, "x", true) then
        M.action = nil
      end
      if M.action and button(px + 18, by1, 88, 28, "reveal", true) then
        local ok, result = location.reveal(a.path)
        if ok then
          say("revealed project folder · " .. result)
          M.action = nil
        else
          say(result, true)
          a.error = result
        end
      end
      if M.action and button(px + 116, by1, 112, 28, "rename folder", true) then
        a.mode, a.focus, a.error = "rename", true, nil
      end
      if M.action and button(px + 238, by1, 102, 28, "move folder", true) then
        local ok, err = begin_folder { kind = "move", source = a.path }
        if ok then M.action = nil else a.error = err end
      end
      if M.action and button(px + 18, by2, 96, 28, "duplicate", true) then
        local ok, err = begin_folder { kind = "duplicate", source = a.path,
                                       name = a.name }
        if ok then M.action = nil else a.error = err end
      end
      if M.action and button(px + 124, by2, 96, 28, "archive", true) then
        local ok, err = begin_folder { kind = "archive", source = a.path,
                                       name = a.name }
        if ok then M.action = nil else a.error = err end
      end
      if M.action and button(px + 230, by2, 96, 28, "delete…", true) then
        a.mode, a.focus, a.error, a.rename = "delete", true, nil, ""
      end
    end
    pal.x_ig_overlay(false)
    if M.action and not busy and i.clicked[1]
        and not (i.wx >= px and i.wx < px + pw
                 and i.wy >= py and i.wy < py + ph) then
      M.action = nil
    end
  end
end

return M
