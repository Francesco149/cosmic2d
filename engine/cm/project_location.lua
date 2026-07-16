-- cm.project_location -- failure-safe project-folder reveal/rename/move.
--
-- This is picker policy, never sim state. A relocation is one collision-safe
-- native directory rename followed by one atomic recents replacement. The
-- source must already be recent, so every pre-rename failure keeps a working
-- tile and a post-rename metadata failure keeps the old tile as an explicit
-- repair handle. Cross-filesystem moves need recursive copy/delete and remain
-- a later A3 packet; this module never pretends a partial copy is a move.

local M = select(2, ...) or {}

M.API = 16

local project = cm.require("cm.project")

local function join(parent, name)
  return parent .. (parent:sub(-1) == "/" and "" or "/") .. name
end

local function path_key(path, platform)
  local normalized = project.normalize_root(path)
  if not normalized then return nil end
  if platform == "windows" then normalized = normalized:lower() end
  return normalized
end

local function same_path(a, b, platform)
  local ak, bk = path_key(a, platform), path_key(b, platform)
  return ak ~= nil and ak == bk
end

local function inside_path(path, parent, platform)
  local pk, rk = path_key(path, platform), path_key(parent, platform)
  return pk and rk and pk:sub(1, #rk + 1) == rk .. "/"
end

-- Split a normalized project root without asking the host to canonicalize it.
-- Recents deliberately preserve an author-chosen mount/symlink spelling.
function M.parts(value)
  local root, err = project.normalize_root(value)
  if not root then return nil, nil, err end
  local slash = root:match("^.*()/")
  if not slash then return ".", root end
  local parent, name = root:sub(1, slash - 1), root:sub(slash + 1)
  if parent == "" then parent = "/"
  elseif parent:match("^%a:$") then parent = parent .. "/" end
  if name == "" then return nil, nil, "project folder must have a name" end
  return parent, name
end

function M.validate_name(value, platform)
  if type(value) ~= "string" then return nil, "folder name must be text" end
  if value == "" or value == "." or value == ".." then
    return nil, "folder name must not be empty, . or .."
  end
  if #value > 240 then return nil, "folder name is too long" end
  if value:find("[%z\1-\31\127/\\]") then
    return nil, "folder name contains a path separator or control character"
  end
  if value:match("^%s") or value:match("%s$") then
    return nil, "folder name must not begin or end with whitespace"
  end
  platform = platform or pal.platform
  if platform == "windows" then
    if value:find('[<>:"|%?%*]') or value:sub(-1) == "." then
      return nil, "folder name contains characters Windows does not allow"
    end
    local stem = (value:match("^([^%.]+)") or value):upper()
    if stem == "CON" or stem == "PRN" or stem == "AUX" or stem == "NUL"
       or stem:match("^COM[1-9]$") or stem:match("^LPT[1-9]$") then
      return nil, "folder name is reserved by Windows"
    end
  end
  return value
end

function M.destination(parent, name, opts)
  opts = opts or {}
  parent = project.normalize_root(parent)
  if not parent then return nil, "destination parent must be a folder path" end
  local valid, err = M.validate_name(name, opts.platform)
  if not valid then return nil, err end
  return project.normalize_root(join(parent, valid))
end

local function default_fs()
  local fs = {
    read = pal.read_file,
    info = pal.x_path_info,
    move = pal.x_path_move,
    reveal = pal.x_path_reveal,
  }
  function fs.probe(parent, nonce)
    -- A same-parent empty directory proves create/delete authority without
    -- replacing any user bytes (mkdir itself has no-overwrite semantics).
    for attempt = 0, 8 do
      local path = join(parent, ".cosmic-project-location-test."
        .. tostring(nonce) .. "." .. tostring(attempt))
      if not pal.x_path_info(path) then
        if not pal.mkdir(path) then
          return nil, "cannot create a permission probe in " .. parent
        end
        if not pal.x_remove(path) then
          return nil, "cannot remove the permission probe " .. path
        end
        return true
      end
    end
    return nil, "cannot allocate a unique permission probe in " .. parent
  end
  return fs
end

local function active_root(opts)
  if opts.active_root ~= nil then return opts.active_root or nil end
  local main = cm.require("cm.main")
  if main.ed and main.ed.on and main.ed.root then return main.ed.root end
  return main.args and main.args.project or nil
end

local function need_fs(fs)
  return type(fs.read) == "function" and type(fs.info) == "function"
    and type(fs.move) == "function" and type(fs.probe) == "function"
end

-- Validate all cheap/reversible boundaries before the native rename. The
-- returned context is a short-lived capability: x_path_move repeats the
-- collision check atomically, so a race still cannot replace a destination.
function M.preflight(source, destination, opts)
  opts = opts or {}
  local fs = opts.fs or default_fs()
  if not opts.fs and (not pal.version or pal.version.api < M.API
      or type(pal.x_path_move) ~= "function") then
    return nil, "moving a project needs PAL api " .. M.API .. " or newer"
  end
  if not need_fs(fs) then return nil, "project location filesystem is unavailable" end

  local src, err = project.normalize_root(source)
  if not src then return nil, err end
  local dest
  dest, err = project.normalize_root(destination)
  if not dest then return nil, err end
  local platform = opts.platform or pal.platform
  if same_path(src, dest, platform) then
    return nil, "project is already at that location"
  end
  if inside_path(dest, src, platform) then
    return nil, "a project cannot be moved inside itself"
  end
  local active = active_root(opts)
  if active and same_path(src, active, platform) then
    return nil, "return to the project picker before moving the open project"
  end

  local recent = opts.recent or cm.require("cm.recent")
  if type(recent.contains) ~= "function" or not recent.contains(src) then
    return nil, "project must have a recent tile before its folder can move"
  end

  local si, serr = fs.info(src)
  if not si then return nil, "source project folder is unavailable: " .. tostring(serr) end
  if si.type ~= "directory" then return nil, "source project path is not a folder" end
  if si.link then
    return nil, "a project-folder alias cannot move; open its real folder first"
  end
  local meta
  src, meta = project.inspect_root(src, fs.read)
  if not src then return nil, meta end

  local existing = fs.info(dest)
  if existing then return nil, "destination already exists: " .. dest end
  local source_parent, source_name = M.parts(src)
  local dest_parent, dest_name = M.parts(dest)
  if not source_parent or not dest_parent then
    return nil, source_name or dest_name or "project folder must have a parent"
  end
  local dpi, dperr = fs.info(dest_parent)
  if not dpi then
    return nil, "destination parent is unavailable: " .. tostring(dperr)
  end
  if dpi.type ~= "directory" then return nil, "destination parent is not a folder" end
  local spi, sperr = fs.info(source_parent)
  if not spi or spi.type ~= "directory" then
    return nil, "source parent is unavailable: " .. tostring(sperr)
  end

  local nonce = opts.nonce or (pal.time_ns and pal.time_ns()) or 0
  local ok
  ok, err = fs.probe(source_parent, tostring(nonce) .. ".source")
  if not ok then return nil, "source parent is not writable: " .. tostring(err) end
  if not same_path(source_parent, dest_parent, platform) then
    ok, err = fs.probe(dest_parent, tostring(nonce) .. ".destination")
    if not ok then
      return nil, "destination parent is not writable: " .. tostring(err)
    end
  end

  return {
    source = src, destination = dest, meta = meta,
    source_parent = source_parent, source_name = source_name,
    destination_parent = dest_parent, destination_name = dest_name,
    fs = fs, recent = recent,
  }
end

function M.relocate(source, destination, opts)
  opts = opts or {}
  local ctx, err = M.preflight(source, destination, opts)
  if not ctx then return nil, err, { moved = false, source = source } end
  local fail = opts.fail or {}
  local ok
  ok, err = ctx.fs.move(ctx.source, ctx.destination, fail.move)
  if not ok then
    return nil, "project folder was not moved: " .. tostring(err),
      { moved = false, source = ctx.source, destination = ctx.destination }
  end

  ok, err = ctx.recent.replace(ctx.source, ctx.destination, fail.recent)
  if not ok then
    return nil, "folder moved to " .. ctx.destination
      .. ", but recents could not update: " .. tostring(err)
      .. "; the old tile was kept for repair",
      { moved = true, source = ctx.source, destination = ctx.destination }
  end
  return true, ctx.destination,
    { moved = true, source = ctx.source, destination = ctx.destination }
end

function M.rename(source, name, opts)
  opts = opts or {}
  local parent, _, err = M.parts(source)
  if not parent then return nil, err, { moved = false, source = source } end
  local dest
  dest, err = M.destination(parent, name, opts)
  if not dest then return nil, err, { moved = false, source = source } end
  return M.relocate(source, dest, opts)
end

function M.move_to(source, parent, opts)
  opts = opts or {}
  local _, name, err = M.parts(source)
  if not name then return nil, err, { moved = false, source = source } end
  local dest
  dest, err = M.destination(parent, name, opts)
  if not dest then return nil, err, { moved = false, source = source } end
  return M.relocate(source, dest, opts)
end

function M.reveal(source, opts)
  opts = opts or {}
  local fs = opts.fs or default_fs()
  if not opts.fs and (not pal.version or pal.version.api < M.API
      or type(pal.x_path_reveal) ~= "function") then
    return nil, "revealing a project needs PAL api " .. M.API .. " or newer"
  end
  if type(fs.info) ~= "function" or type(fs.read) ~= "function"
      or type(fs.reveal) ~= "function" then
    return nil, "project reveal filesystem is unavailable"
  end
  local root, err = project.inspect_root(source, fs.read)
  if not root then return nil, err end
  local info
  info, err = fs.info(root)
  if not info or info.type ~= "directory" then
    return nil, "project folder is unavailable: " .. tostring(err)
  end
  local ok
  ok, err = fs.reveal(root, opts.fail and opts.fail.reveal)
  if not ok then return nil, tostring(err) end
  return true, root
end

return M
