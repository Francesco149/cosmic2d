-- projects/picker — the engine's front door (R5, D052): the teidraw-style
-- project picker. Boots when `cosmic` is run with no project argument.
-- Scans projects/* for project.lua and merges the engine-root .recent.dat
-- (cm.main writes it on every real boot — that's how sibling-repo
-- projects like ../cosmic2d-game/cosmic get tiles). A tile opens the
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

M.scan = M.scan or nil -- ephemeral tile cache (render/dev)

local C = {
  bg = 0x141220ff, text = 0xE8E4FFff, dim = 0x8a84b0ff,
  tile = 0x1e1b2eff, tile_edge = 0x4a4370ff, tile_hot = 0x262238ff,
  accent = 0x7fd8a8ff, play = 0xffb46eff, missing = 0x5a5480ff,
}

function M.init()
  view = cm.require("cm.view")
  view.mode = "canvas" -- no game blit; the picker draws the whole window
end

function M.step() end

-- ---- the project list ----

-- Load a project's metadata table (name/author/version/description + the
-- fields the packager reads) by evaluating project.lua — the same load()
-- the engine does on boot (author-controlled source). Returns meta, exists;
-- falls back to a name-only regex if the file won't evaluate.
local function proj_meta(dir)
  local src = pal.read_file(dir .. "/project.lua")
  if not src then return nil, false end
  local chunk = load(src, "@" .. dir .. "/project.lua")
  if chunk then
    local ok, t = pcall(chunk)
    if ok and type(t) == "table" then return t, true end
  end
  return { name = src:match('name%s*=%s*"([^"]*)"') }, true
end

-- One tile record from a project's metadata (nil-safe: a missing/broken
-- project.lua still yields a named tile).
local function tile(path, meta, ok, recent)
  meta = meta or {}
  local name = meta.name
  if not name or name == "" then name = path:match("([^/]+)$") end
  return { path = path, ok = ok, recent = recent, name = name,
           author = meta.author, version = meta.version,
           desc = meta.description }
end

local function norm(p) -- .recent.dat lines arrive as typed on the cli
  return (p:gsub("^%./", ""):gsub("/+$", ""))
end

local function scan()
  if M.scan then return M.scan end
  local tiles, seen = {}, {}
  local names = pal.list_dir("projects") or {}
  table.sort(names)
  for _, n in ipairs(names) do
    local dir = n:match("^([^/]+)/project%.lua$")
    if dir and dir ~= "picker" then
      local path = "projects/" .. dir
      seen[path] = true
      tiles[#tiles + 1] = tile(path, proj_meta(path), true, false)
    end
  end
  local rec = pal.read_file(".recent.dat")
  if rec then
    for line in rec:gmatch("[^\n]+") do
      local path = norm(line)
      if not seen[path] then
        seen[path] = true
        local meta, ok = proj_meta(path)
        table.insert(tiles, 1, tile(path, meta, ok or false, true))
      end
    end
  end
  M.scan = tiles
  return tiles
end

local function launch(path, mode)
  local payload = path .. "\n" .. mode
  local v = pal.buf("boot.next", #payload)
  v:setstr(0, payload)
  pal.log("[picker] " .. mode .. " " .. path)
  pal.x_reboot()
end
M.launch = launch -- scripted driving (proofs, keyboard flows later)

-- ---- new project (G5): scaffold + open in the editor ----

local PROJECT_TMPL = [==[
-- a fresh cosmic2d project. Tweak these; the picker + packager read them.
return {
  name = "__NAME__",
  internal_w = 480,
  internal_h = 270,
  window_scale = 2,
  entry = "main.lua",
  author = "",
  version = "0.1",
  description = "",
}
]==]

local MAIN_TMPL = [==[
-- __NAME__ — a fresh project. Edit me while the game runs (hot reload)!
-- The engine calls init() once, then step() + draw() every frame (60Hz).
-- Spawn editor windows with right-click on the canvas (--edit).

local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m = cm.require("cm.math")

local W, H = pal.gfx_size()
local game = {}

function game.init()
  input.map({
    { "left", input.key.left }, { "right", input.key.right },
    { "jump", input.key.space },
  })
  local d = state.doc
  d.x = d.x or W / 2
  d.y = d.y or H - 24
  d.vy = d.vy or 0
end

function game.step()
  local d = state.doc
  if input.down("left") then d.x = d.x - 2 end
  if input.down("right") then d.x = d.x + 2 end
  if input.pressed("jump") and d.y >= H - 24 then d.vy = -5.2 end
  d.vy = d.vy + 0.3
  d.y = m.min(H - 24, d.y + d.vy)
  if d.y >= H - 24 then d.vy = 0 end
  d.x = m.clamp(d.x, 0, W - 16)
end

function game.draw()
  pal.begin_frame(0.13, 0.15, 0.22, 1)
  pal.quad(0, H - 8, W, 8, 0.30, 0.40, 0.36, 1)          -- the floor
  local d = state.doc
  pal.quad(d.x, d.y - 16, 16, 16, 0.95, 0.75, 0.42, 1)   -- you
  text.draw(6, 6, "hello from __NAME__ — arrows + space. edit main.lua!",
            { r = 0.95, g = 0.92, b = 0.8, a = 0.9 })
end

return game
]==]

local function scaffold()
  local words = cm.require("cm.words")
  local name = words.unique(function(nm)
    return pal.read_file("projects/" .. nm .. "/project.lua") ~= nil
  end)
  local dir = "projects/" .. name
  pal.mkdir(dir)
  pal.write_file(dir .. "/project.lua", (PROJECT_TMPL:gsub("__NAME__", name)))
  pal.write_file(dir .. "/main.lua", (MAIN_TMPL:gsub("__NAME__", name)))
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
  local i = cm.require("cm.ui").inp

  pal.x_ig_rect_fill(0, 0, ig.w, ig.h, C.bg)
  pal.x_ig_text(28, 22, 26, C.text, "cosmic2d", 0)
  pal.x_ig_text(28 + pal.x_ig_text_size("cosmic2d", 26, 0) + 14, 31, 13,
                C.dim, "pick a project — click opens the editor; play boots the game", 0)

  local tiles = scan()
  local pad, tw, th = 20, 240, 100
  local cols = math.max(1, math.floor((ig.w - 2 * pad) / (tw + pad)))
  local x0, y0 = 28, 64
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
    local tag = (t.recent and not t.ok) and "recent · missing"
                or (not t.ok and "missing") or (t.recent and "recent")
    if tag then
      pal.x_ig_text(x + 14, y + th - 22, 10, t.ok and C.dim or C.missing,
                    tag, 0)
    end
    if not t.ok then
      -- ✕ prunes the dead entry from .recent.dat (stale-tile cleanup)
      local rx, ry, rs = x + tw - 26, y + 8, 16
      local rhov = i.wx >= rx and i.wx < rx + rs
                   and i.wy >= ry and i.wy < ry + rs
      pal.x_ig_text(rx + 5, ry + 1, 12, rhov and C.text or C.dim, "x", 0)
      if rhov and i.clicked[1] then
        local rec = pal.read_file(".recent.dat") or ""
        local out = {}
        for line in rec:gmatch("[^\n]+") do
          if norm(line) ~= t.path then out[#out + 1] = norm(line) end
        end
        pal.write_file(".recent.dat",
                       table.concat(out, "\n") .. (#out > 0 and "\n" or ""))
        M.scan = nil
        pal.log("[picker] pruned " .. t.path)
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
