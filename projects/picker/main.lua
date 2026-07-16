-- projects/picker — the engine's front door (R5, D052): the teidraw-style
-- project picker. Boots when `cosmic` is run with no project argument.
-- Scans projects/* for project.lua and merges the engine-root .recent.dat.
-- Open folder registers an arbitrary project in place (no copy), while stale
-- recent tiles can be repaired through the same native chooser. A tile opens the
-- project IN THE EDITOR (the picker is the editor's front door); the ▶
-- zone boots plain play mode.
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
local recent = cm.require("cm.recent")

M.scan = M.scan or nil -- ephemeral tile cache (render/dev)
M.folder = M.folder or nil -- active native chooser intent (open or repair)
M.notice = M.notice or nil -- latest actionable lifecycle result

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
  return { path = path, ok = state == "ready", state = state,
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

local function begin_folder(repair)
  if M.folder then return nil, "a folder chooser is already active" end
  if pal.version.api < 15 or type(pal.x_folder_dialog) ~= "function"
     or type(pal.x_folder_dialog_poll) ~= "function" then
    local err = "opening a project folder needs PAL api >= 15"
    say(err, true)
    return nil, err
  end
  local ok, err = pal.x_folder_dialog()
  if not ok then say(err, true); return nil, err end
  M.folder = { repair = repair }
  say(repair and ("choose the replacement for " .. repair.path)
             or "choose a cosmic2d project folder")
  return true
end
M.begin_folder = begin_folder

local function accept_folder(raw)
  local intent = M.folder
  M.folder = nil
  local root, meta = project.inspect_root(raw)
  if not root then say(meta, true); return nil, meta end
  local ok, err
  if intent and intent.repair then
    ok, err = recent.replace(intent.repair.path, root)
  else
    ok, err = recent.note(root)
  end
  if not ok then
    local msg = "cannot update recent projects: " .. tostring(err)
    say(msg, true)
    return nil, msg
  end
  M.scan = nil -- registration is visible before the project-switch tick ends
  say((intent and intent.repair and "repaired · opening " or "opening ")
      .. (meta.name or root))
  launch(root, "edit")
  return true
end
M.accept_folder = accept_folder -- scripted lifecycle proof door

local function poll_folder()
  if not M.folder then return false end
  local state, value = pal.x_folder_dialog_poll()
  if state == "pending" then return false end
  if state == "selected" then return accept_folder(value) == true end
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
            M.folder and "choosing…" or "open folder", not M.folder) then
    begin_folder()
  end
  if button(refresh_x, 18, refresh_w, 28, "refresh", not M.folder) then refresh() end
  if M.notice then
    pal.x_ig_clip_push(28, 55, math.max(40, ig.w - 56), 18)
    pal.x_ig_text(28, 55, 11, M.notice.bad and C.bad or C.dim,
                  M.notice.text, 0)
    pal.x_ig_clip_pop()
  else
    pal.x_ig_text(28, 55, 11, C.dim,
                  "Open keeps an external project in its current folder.", 0)
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
    pal.x_ig_rect_fill(x, y, tw, th, hov and C.tile_hot or C.tile, 8)
    pal.x_ig_rect(x, y, tw, th, (hov and not phov) and C.accent
                  or C.tile_edge, hov and 1.5 or 1, 8)
    -- two subtitle rows under the name: a byline (author · version) then
    -- the description; the path stands in for whichever the metadata omits
    -- so metadata-less / sibling-repo projects still show where they live.
    local bl = byline(t)
    local desc = (t.desc and t.desc ~= "") and t.desc or nil
    local sub1 = bl or t.path
    local sub2 = desc or (bl and t.path) or nil
    pal.x_ig_clip_push(x, y, tw - (t.ok and 8 or 30), th)
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
      if t.recent and button(x + 14, y + th - 52, 70, 24, "repair", not M.folder) then
        begin_folder(t)
      end
      if t.recent and button(x + 92, y + th - 52, 70, 24, "remove", not M.folder) then
        local ok, err = recent.remove(t.path)
        if ok then
          M.scan = nil
          say("removed missing recent · " .. t.path)
        else
          say("cannot remove recent: " .. tostring(err), true)
        end
      end
    end
    if t.ok then
      pal.x_ig_rect_fill(pzx, pzy, pzw, pzh,
                         phov and 0x3a3560ff or 0x26223855, 6)
      pal.x_ig_text(pzx + 8, pzy + 6, 12, phov and C.play or C.dim,
                    "play", 0)
      if hov and i.clicked[1] then
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
      if hov and i.clicked[1] then scaffold() end
    end
  end

  if #tiles == 0 then
    pal.x_ig_text(x0, y0 + 96, 15, C.dim,
                  "no projects yet — click + New project", 0)
  end
end

return M
