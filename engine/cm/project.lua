-- cm.project — the canonical declarative project model.
--
-- project.lua is shared by boot, the picker, player packaging, and the A3
-- settings window.  This module owns its plain-data codec and validation so
-- those entrances cannot quietly grow different interpretations.  The file is
-- still inspectable Lua, but it executes in an empty environment and may only
-- return strings/numbers/booleans/tables.
--
-- Scaffolding publishes project.lua last: a directory is never discoverable
-- as a project until every required source is durable.

local M = select(2, ...) or {}

M.PROJECT_TMPL = [==[
-- a fresh cosmic2d project. Tweak these; the picker + packager read them.
return {
  name = "__NAME__",
  internal_w = 480,
  internal_h = 270,
  window_scale = 2,
  entry = "main.lua",
  author = "",
  version = "0.1",
  description = "__DESC__",
  -- A player export additionally needs project-local icon/controls/credits
  -- files and at least one license. The project settings UI will fill these;
  -- see the scripting guide for the declarative metadata contract.
  -- icon = "icon.png",
  -- controls = "CONTROLS.md",
  -- credits = "CREDITS.md",
  -- licenses = { "LICENSE.md" },
}
]==]

M.MAIN_TMPL = [==[
-- __NAME__ — a fresh project. Edit me while the game runs (hot reload)!
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m = cm.require("cm.math")
local W, H = pal.gfx_size()
local game = {}
function game.init()
  input.map({ { "left", input.key.left }, { "right", input.key.right },
              { "jump", input.key.space } })
  local d = state.doc
  d.x, d.y, d.vy = d.x or W / 2, d.y or H - 24, d.vy or 0
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
  pal.quad(0, H - 8, W, 8, 0.30, 0.40, 0.36, 1)
  local d = state.doc
  pal.quad(d.x, d.y - 16, 16, 16, 0.95, 0.75, 0.42, 1)
  text.draw(6, 6, "hello from __NAME__ - arrows + space. edit main.lua!",
            { r = 0.95, g = 0.92, b = 0.8, a = 0.9 })
end
return game
]==]

-- Starter templates (D081): what the picker's "+ New project" chooser
-- offers. `blank` is the embedded MAIN_TMPL above; the others are real,
-- readable one-file games under engine/stock/templates whose `__NAME__`
-- placeholders are substituted at scaffold time. Order is the chooser's
-- display order; blank stays first as the no-template default.
M.TEMPLATES = {
  { key = "blank", label = "blank",
    note = "the one-file hello: move and jump" },
  { key = "platformer", label = "platformer",
    note = "side view: run, jump platforms, reach the flag",
    main = "engine/stock/templates/platformer.lua" },
  { key = "topdown", label = "top-down",
    note = "walk a walled room and collect every gem",
    main = "engine/stock/templates/topdown.lua" },
  { key = "arcade", label = "arcade",
    note = "one screen: shoot falling rocks, chase the best score",
    main = "engine/stock/templates/arcade.lua" },
}

-- nil means the default (blank); an unknown key is an explicit error so a
-- chooser/registry mismatch cannot silently scaffold the wrong game.
function M.template(key)
  if key == nil then return M.TEMPLATES[1] end
  for _, t in ipairs(M.TEMPLATES) do
    if t.key == key then return t end
  end
  return nil, "unknown starter template: " .. tostring(key)
end

-- The raw main.lua source for a starter template, placeholders intact.
-- `read` is injectable so failure paths stay KAT-able; blank is embedded
-- and never touches the filesystem.
function M.template_main(key, read)
  local tmpl, err = M.template(key)
  if not tmpl then return nil, err end
  if not tmpl.main then return M.MAIN_TMPL end
  read = read or (pal and pal.read_file)
  if type(read) ~= "function" then return nil, "template reader is unavailable" end
  local bytes, rerr = read(tmpl.main)
  if type(bytes) ~= "string" then
    return nil, "cannot read starter template " .. tmpl.main .. ": "
      .. tostring(rerr or "not found")
  end
  return bytes
end

local function trim(value)
  return value:match("^%s*(.-)%s*$")
end

-- The D070 identity validator, shared with the player-bundle helper. Draft
-- settings call the same primitive with an optional description; the complete
-- release validator below makes description mandatory while author stays
-- optional.
function M.one_line(meta, field, optional, max_len)
  local value = meta[field]
  if optional and (value == nil or value == "") then return nil end
  if type(value) ~= "string" then return nil, field .. " must be a string" end
  value = trim(value)
  if value == "" then return nil, field .. " must not be empty" end
  if #value > max_len then
    return nil, field .. " is too long (max " .. max_len .. " bytes)"
  end
  if value:find("[%z\r\n]") then
    return nil, field .. " must fit on one line"
  end
  return value
end

function M.project_path(field, value)
  if type(value) ~= "string" then
    return nil, field .. " must be a project-relative path"
  end
  if value == "" or #value > 240 or value:sub(1, 1) == "/"
      or value:find("\\", 1, true) or value:find(":", 1, true)
      or value:find("[%z\r\n<>#?]") then
    return nil, field .. " must be a safe forward-slash project-relative path"
  end
  for segment in (value .. "/"):gmatch("(.-)/") do
    if segment == "" or segment == "." or segment == ".." then
      return nil, field .. " contains an unsafe path segment: " .. value
    end
  end
  return value
end

-- Validate the complete metadata needed to publish a player bundle.  File
-- existence/content checks remain with the exporter because this pure schema
-- is also loaded by the host-side packaging script (where `pal` is absent).
function M.validate_release(meta)
  if type(meta) ~= "table" then return nil, "project.lua must return a table" end
  local out = {}
  local err
  out.name, err = M.one_line(meta, "name", false, 120)
  if not out.name then return nil, err end
  out.version, err = M.one_line(meta, "version", false, 64)
  if not out.version then return nil, err end
  out.author, err = M.one_line(meta, "author", true, 120)
  if err then return nil, err end
  out.description, err = M.one_line(meta, "description", false, 1000)
  if not out.description then return nil, err end
  for _, field in ipairs({ "icon", "controls", "credits" }) do
    out[field], err = M.project_path(field, meta[field])
    if not out[field] then return nil, err end
  end
  if type(meta.licenses) ~= "table" or #meta.licenses == 0 then
    return nil, "licenses must be a non-empty array of project-relative paths"
  end
  out.licenses = {}
  local seen = {}
  for i = 1, #meta.licenses do
    local path
    path, err = M.project_path("licenses[" .. i .. "]", meta.licenses[i])
    if not path then return nil, err end
    if seen[path] then return nil, "duplicate project license path: " .. path end
    seen[path] = true
    out.licenses[#out.licenses + 1] = path
  end
  for key in pairs(meta.licenses) do
    if type(key) ~= "number" or math.type(key) ~= "integer"
        or key < 1 or key > #meta.licenses then
      return nil, "licenses must be a dense array"
    end
  end
  return out
end

M.RELEASE_TEXT_LIMIT = 512 * 1024
M.RELEASE_ICON_LIMIT = 8 * 1024 * 1024

-- Validate one project-local release reference. `read` is deliberately a
-- tiny injected boundary: the engine supplies pal.read_file while the host
-- packager supplies ordinary Lua file I/O. Keeping the byte/type rules here
-- means the settings window cannot call a file "ready" only for packaging to
-- interpret it differently later.
function M.validate_release_reference(kind, field, value, read)
  local path, err = M.project_path(field, value)
  if not path then return nil, err end
  if kind ~= "icon" and kind ~= "text" then
    return nil, "unknown release reference kind: " .. tostring(kind)
  end
  if type(read) ~= "function" then
    return nil, "release reference reader is unavailable"
  end
  local bytes
  bytes, err = read(path)
  if type(bytes) ~= "string" then
    return nil, "cannot read " .. field .. " " .. path .. ": "
      .. tostring(err or "not found")
  end
  local limit = kind == "icon" and M.RELEASE_ICON_LIMIT or M.RELEASE_TEXT_LIMIT
  if #bytes > limit then
    return nil, field .. " is larger than " .. limit .. " bytes: " .. path
  end

  if kind == "icon" then
    if #bytes < 24 or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then
      return nil, "icon must be a PNG file: " .. path
    end
    local ihdr_len, ihdr, w, h = string.unpack(">I4c4I4I4", bytes, 9)
    if ihdr_len ~= 13 or ihdr ~= "IHDR" or w ~= h or w < 32 or w > 1024 then
      return nil, "icon PNG must be square and 32..1024 pixels: " .. path
    end
    return { path = path, bytes = bytes, w = w, h = h }
  end

  if bytes:find("\0", 1, true) then
    return nil, field .. " must be a text file: " .. path
  end
  local normalized = bytes:gsub("^\239\187\191", "")
                          :gsub("\r\n", "\n"):gsub("\r", "\n")
                          :gsub("%s+$", "")
  if normalized == "" then
    return nil, field .. " must not be empty: " .. path
  end
  return { path = path, bytes = bytes, text = normalized .. "\n" }
end

-- Schema + referenced bytes for one publishable project. The returned
-- normalized texts are what the player README embeds; original license files
-- remain untouched and inspectable in the project.
function M.validate_release_files(meta, read)
  local release, err = M.validate_release(meta)
  if not release then return nil, err end
  local out = { release = release, licenses = {} }
  out.icon, err = M.validate_release_reference(
    "icon", "icon", release.icon, read)
  if not out.icon then return nil, err end
  out.controls, err = M.validate_release_reference(
    "text", "controls", release.controls, read)
  if not out.controls then return nil, err end
  out.credits, err = M.validate_release_reference(
    "text", "credits", release.credits, read)
  if not out.credits then return nil, err end
  for i, path in ipairs(release.licenses) do
    local ref
    ref, err = M.validate_release_reference(
      "text", "licenses[" .. i .. "]", path, read)
    if not ref then return nil, err end
    out.licenses[i] = ref
  end
  return out
end

local function plain(value, path, stack)
  local kind = type(value)
  if kind == "nil" or kind == "string" or kind == "boolean" then return true end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil, path .. " must be a finite number"
    end
    return true
  end
  if kind ~= "table" then return nil, path .. " contains a " .. kind end
  if getmetatable(value) ~= nil then return nil, path .. " must not have a metatable" end
  if stack[value] then return nil, path .. " contains a table cycle" end
  stack[value] = true
  for key, child in pairs(value) do
    local kt = type(key)
    if kt ~= "string" and not (kt == "number" and math.type(key) == "integer") then
      stack[value] = nil
      return nil, path .. " has a non-string/non-integer key"
    end
    local ok, err = plain(child, path .. "[" .. tostring(key) .. "]", stack)
    if not ok then stack[value] = nil; return nil, err end
  end
  stack[value] = nil
  return true
end

function M.validate_plain(meta)
  if type(meta) ~= "table" then return nil, "project.lua must return a table" end
  for key in pairs(meta) do
    if type(key) ~= "string" then
      return nil, "project.lua top-level keys must be strings"
    end
  end
  return plain(meta, "project.lua", {})
end

local function integer_field(value, field, lo, hi)
  if type(value) ~= "number" or math.type(value) ~= "integer"
      or value < lo or value > hi then
    return nil, field .. " must be an integer from " .. lo .. " to " .. hi
  end
  return value
end

-- Boot-time validation: keep old projects additive (the engine still supplies
-- defaults for omitted fields), but reject values PAL would reject later with
-- a less useful generic gfx_init error.
function M.validate_runtime(meta)
  local ok, err = M.validate_plain(meta)
  if not ok then return nil, err end
  if meta.name ~= nil then
    local name
    name, err = M.one_line(meta, "name", false, 120)
    if not name then return nil, err end
  end
  if meta.internal_w ~= nil then
    ok, err = integer_field(meta.internal_w, "internal_w", 1, 4096)
    if not ok then return nil, err end
  end
  if meta.internal_h ~= nil then
    ok, err = integer_field(meta.internal_h, "internal_h", 1, 4096)
    if not ok then return nil, err end
  end
  if meta.window_scale ~= nil then
    ok, err = integer_field(meta.window_scale, "window_scale", 1, 16)
    if not ok then return nil, err end
  end
  if meta.maximized ~= nil and type(meta.maximized) ~= "boolean" then
    return nil, "maximized must be true or false"
  end
  return true
end

-- The editable subset uses strings for number fields so the UI can represent a
-- temporarily empty/invalid field without corrupting the underlying model.
function M.settings(meta)
  meta = meta or {}
  local out = {
    name = type(meta.name) == "string" and meta.name or "",
    author = type(meta.author) == "string" and meta.author or "",
    version = type(meta.version) == "string" and meta.version or "0.1",
    description = type(meta.description) == "string" and meta.description or "",
    internal_w = tostring(meta.internal_w or 480),
    internal_h = tostring(meta.internal_h or 270),
    window_scale = tostring(meta.window_scale or 2),
    maximized = meta.maximized == true,
    icon = type(meta.icon) == "string" and meta.icon or "",
    controls = type(meta.controls) == "string" and meta.controls or "",
    credits = type(meta.credits) == "string" and meta.credits or "",
    licenses = {},
  }
  if type(meta.licenses) == "table" then
    for i = 1, #meta.licenses do
      out.licenses[i] = type(meta.licenses[i]) == "string" and meta.licenses[i] or ""
    end
  elseif meta.licenses ~= nil then
    -- Preserve the fact that malformed release metadata needs attention rather
    -- than silently presenting it as an intentionally unconfigured draft.
    out.licenses[1] = ""
  end
  return out
end

-- A project with no release references at all is an ordinary editable draft.
-- Once any reference is present, the settings form treats the D070 packet as
-- all-or-nothing so a partial configuration cannot be mistaken for one that
-- was deliberately made export-ready.
function M.release_configured(value)
  if type(value) ~= "table" then return false end
  for _, field in ipairs({ "icon", "controls", "credits" }) do
    local v = value[field]
    if v ~= nil and v ~= "" then return true end
  end
  if value.licenses ~= nil then
    if type(value.licenses) ~= "table" then return true end
    if next(value.licenses) ~= nil then return true end
  end
  return false
end

local function form_integer(form, field, lo, hi)
  local raw = form[field]
  if type(raw) ~= "string" or not raw:match("^%s*%d+%s*$") then
    return nil, field .. " must be an integer from " .. lo .. " to " .. hi
  end
  return integer_field(math.tointeger(trim(raw)), field, lo, hi)
end

function M.validate_settings(form)
  if type(form) ~= "table" then return nil, "project settings are unavailable" end
  local out, err = {}
  out.name, err = M.one_line(form, "name", false, 120)
  if not out.name then return nil, err end
  out.author, err = M.one_line(form, "author", true, 120)
  if err then return nil, err end
  out.version, err = M.one_line(form, "version", false, 64)
  if not out.version then return nil, err end
  -- A draft may be undescribed; validate the same D070 shape whenever present.
  out.description, err = M.one_line(form, "description", true, 1000)
  if err then return nil, err end
  out.description = out.description or ""
  out.internal_w, err = form_integer(form, "internal_w", 1, 4096)
  if not out.internal_w then return nil, err end
  out.internal_h, err = form_integer(form, "internal_h", 1, 4096)
  if not out.internal_h then return nil, err end
  out.window_scale, err = form_integer(form, "window_scale", 1, 16)
  if not out.window_scale then return nil, err end
  if type(form.maximized) ~= "boolean" then return nil, "maximized must be true or false" end
  out.maximized = form.maximized
  out.release = M.release_configured(form)
  out.icon, out.controls, out.credits, out.licenses = nil, nil, nil, {}
  if out.release then
    local release
    release, err = M.validate_release {
      name = out.name, author = out.author or "", version = out.version,
      description = out.description, icon = form.icon, controls = form.controls,
      credits = form.credits, licenses = form.licenses,
    }
    if not release then return nil, err end
    out.icon, out.controls, out.credits =
      release.icon, release.controls, release.credits
    out.licenses = release.licenses
  end
  return out
end

local function clone(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}
  seen[value] = out
  for key, child in pairs(value) do out[clone(key, seen)] = clone(child, seen) end
  return out
end

function M.apply_settings(meta, form)
  local settings, err = M.validate_settings(form)
  if not settings then return nil, err end
  local out = clone(meta or {})
  out.name = settings.name
  out.author = settings.author or ""
  out.version = settings.version
  out.description = settings.description
  out.internal_w = settings.internal_w
  out.internal_h = settings.internal_h
  out.window_scale = settings.window_scale
  out.maximized = settings.maximized and true or nil
  out.icon = settings.release and settings.icon or nil
  out.controls = settings.release and settings.controls or nil
  out.credits = settings.release and settings.credits or nil
  out.licenses = settings.release and clone(settings.licenses) or nil
  local ok
  ok, err = M.validate_runtime(out)
  if not ok then return nil, err end
  return out
end

-- ---- canonical inspectable-Lua codec ----

local ORDER = {
  "name", "author", "version", "description",
  "internal_w", "internal_h", "window_scale", "maximized",
  "entry", "seed", "icon", "controls", "credits", "licenses", "editor",
}
local RANK = {}
for i, key in ipairs(ORDER) do RANK[key] = i end

local function sorted_keys(tab)
  local keys = {}
  for key in pairs(tab) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta == "number" end
    if ta == "number" then return a < b end
    local ra, rb = RANK[a] or 100000, RANK[b] or 100000
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  return keys
end

local function scalar(value)
  return type(value) ~= "table"
end

local function dense_array(tab)
  local count, high = 0, 0
  for key in pairs(tab) do
    if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
      return nil
    end
    count, high = count + 1, math.max(high, key)
  end
  return count == high and high or nil
end

local encode_value

local KEYWORD = {}
for word in ("and break do else elseif end false for function goto if in "
             .. "local nil not or repeat return then true until while"):gmatch("%S+") do
  KEYWORD[word] = true
end

local function encode_key(key)
  if type(key) == "string" and key:match("^[%a_][%w_]*$") and not KEYWORD[key] then
    return key
  end
  return "[" .. encode_value(key, 0, {}) .. "]"
end

encode_value = function(value, depth, stack)
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind == "nil" then return "nil" end
  if stack[value] then error("project.lua contains a table cycle", 0) end
  stack[value] = true
  local n = dense_array(value)
  if n == 0 then stack[value] = nil; return "{}" end
  if n and n > 0 then
    local vals, width = {}, 4
    local one_line = true
    for i = 1, n do
      if not scalar(value[i]) then one_line = false; break end
      vals[i] = encode_value(value[i], depth + 1, stack)
      width = width + #vals[i] + 2
    end
    if one_line and width <= 88 then
      stack[value] = nil
      return "{ " .. table.concat(vals, ", ") .. " }"
    end
  end
  local indent = string.rep("  ", depth)
  local child_indent = indent .. "  "
  local lines = { "{" }
  if n then
    for i = 1, n do
      lines[#lines + 1] = child_indent
        .. encode_value(value[i], depth + 1, stack) .. ","
    end
  else
    for _, key in ipairs(sorted_keys(value)) do
      lines[#lines + 1] = child_indent .. encode_key(key) .. " = "
        .. encode_value(value[key], depth + 1, stack) .. ","
    end
  end
  lines[#lines + 1] = indent .. "}"
  stack[value] = nil
  return table.concat(lines, "\n")
end

function M.encode(meta)
  local ok, err = M.validate_plain(meta)
  if not ok then return nil, err end
  local encoded
  ok, encoded = pcall(encode_value, meta, 0, {})
  if not ok then return nil, tostring(encoded) end
  return "-- cosmic2d project settings (editable in the engine)\nreturn " .. encoded .. "\n"
end

function M.decode(bytes, chunkname)
  if type(bytes) ~= "string" then return nil, "project.lua bytes are unavailable" end
  local chunk, err = load(bytes, chunkname or "@project.lua", "t", {})
  if not chunk then return nil, "invalid declarative project metadata: " .. tostring(err) end
  local ran, meta = pcall(chunk)
  if not ran then return nil, "project metadata failed: " .. tostring(meta) end
  local ok
  ok, err = M.validate_plain(meta)
  if not ok then return nil, err end
  return meta
end

function M.read(dir)
  local path = dir .. "/project.lua"
  local bytes, err = pal.read_file(path)
  if not bytes then return nil, "cannot read " .. path .. ": " .. tostring(err) end
  local meta
  meta, err = M.decode(bytes, "@" .. path)
  if not meta then return nil, err end
  return meta, bytes
end

-- Normalize an OS-selected project root into the engine's persistent path
-- spelling. SDL returns UTF-8 but keeps the host's preferred separators;
-- forward slashes make one recents file unambiguous on Windows and keep the
-- existing root .. "/file" joins valid everywhere. This is deliberately not
-- a realpath: an author-chosen symlink/mount spelling should remain stable.
function M.normalize_root(value)
  if type(value) ~= "string" then return nil, "project folder must be a path" end
  if value == "" then return nil, "project folder must not be empty" end
  if #value > 1800 then return nil, "project folder path is too long" end
  if value:find("[%z\r\n]") then
    return nil, "project folder path contains unsupported control characters"
  end
  local path = value:gsub("\\", "/")
  while path:sub(1, 2) == "./" do path = path:sub(3) end
  while #path > 1 and path:sub(-1) == "/" and not path:match("^%a:/$") do
    path = path:sub(1, -2)
  end
  if path == "" then return nil, "project folder must not be empty" end
  return path
end

-- Validate a folder selected by the picker through the exact declarative
-- codec/runtime rules boot uses. `read` is injectable so the path grammar and
-- failure messages stay KAT-able without opening a native dialog.
function M.inspect_root(value, read)
  local root, err = M.normalize_root(value)
  if not root then return nil, err end
  read = read or pal.read_file
  if type(read) ~= "function" then return nil, "project reader is unavailable" end
  local path = root .. "/project.lua"
  local bytes
  bytes, err = read(path)
  if type(bytes) ~= "string" then
    return nil, "not a cosmic2d project (cannot read " .. path .. "): "
      .. tostring(err or "not found")
  end
  local meta
  meta, err = M.decode(bytes, "@" .. path)
  if not meta then return nil, path .. ": " .. tostring(err) end
  local ok
  ok, err = M.validate_runtime(meta)
  if not ok then return nil, path .. ": " .. tostring(err) end
  return root, meta, bytes
end

function M.save(dir, meta, fail)
  local ok, err = M.validate_runtime(meta)
  if not ok then return nil, err end
  local bytes
  bytes, err = M.encode(meta)
  if not bytes then return nil, err end
  local path = dir .. "/project.lua"
  ok, err = pal.write_file_atomic(path, bytes, fail)
  if not ok then return nil, "write project metadata " .. path .. " failed: " .. tostring(err) end
  return true, bytes
end

function M.scaffold(dir, name, fail, template)
  local tmpl, err = M.template(template)
  if not tmpl then return nil, err end
  -- Resolve the template source before any filesystem effect so a missing
  -- or unreadable template can never leave a partial project behind.
  local main_src
  main_src, err = M.template_main(tmpl.key, fail and fail.read)
  if not main_src then return nil, err end
  if pal.read_file(dir .. "/project.lua") then
    return nil, "project already exists: " .. dir
  end
  if not pal.mkdir(dir) then return nil, "create project directory failed: " .. dir end
  local main = dir .. "/main.lua"
  local meta = dir .. "/project.lua"
  -- The name lands inside generated Lua string literals: escape the two
  -- characters that could break out of them (the folder grammar already
  -- bans control characters), and substitute through a table so '%' in a
  -- user-chosen name stays inert.
  local subs = {
    __NAME__ = (name:gsub('[\\"]', "\\%1")),
    __DESC__ = tmpl.main
      and ("started from the " .. tmpl.label .. " starter template") or "",
  }
  local ok
  ok, err = pal.write_file_atomic(main, (main_src:gsub("__%u+__", subs)),
                                  fail and fail.main)
  if not ok then
    pal.x_remove(dir)
    return nil, "write project source " .. main .. " failed: " .. tostring(err)
  end
  ok, err = pal.write_file_atomic(meta, (M.PROJECT_TMPL:gsub("__%u+__", subs)),
                                  fail and fail.meta)
  if not ok then
    pal.x_remove(main)
    pal.x_remove(dir)
    return nil, "write project metadata " .. meta .. " failed: " .. tostring(err)
  end
  return true
end

return M
