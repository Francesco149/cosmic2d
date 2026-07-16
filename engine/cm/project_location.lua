-- cm.project_location -- failure-safe project-folder reveal/rename/move/
-- duplicate.
--
-- This is picker policy, never sim state. A relocation is one collision-safe
-- native directory rename followed by one atomic recents replacement. The
-- source must already be recent, so every pre-rename failure keeps a working
-- tile and a post-rename metadata failure keeps the old tile as an explicit
-- repair handle. Cross-filesystem moves need recursive copy/delete and remain
-- a later A3 packet; this module never pretends a partial copy is a move.
--
-- Duplicate is the first consumer of the recursive copy-job primitive: the
-- saved project is copied one file per step (progress + cancel) into a unique
-- dot-prefixed staging sibling of the destination, machine/editor state (.ed,
-- video.dat) is omitted, the staged root must revalidate as a project, and the
-- only authoritative transition is one atomic no-replace rename. Every earlier
-- failure or a cancel cleans the staging tree and publishes nothing; the
-- source is never written.

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
    list = pal.list_dir,
    mkdir = pal.mkdir,
    remove = pal.x_remove,
    write_atomic = pal.write_file_atomic,
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

-- ---- duplicate: the recursive project copy job ----

local function fail(message) error(tostring(message), 0) end

local function need_copy_fs(fs)
  return need_fs(fs) and type(fs.list) == "function"
    and type(fs.mkdir) == "function" and type(fs.remove) == "function"
    and type(fs.write_atomic) == "function"
end

-- Best-effort recursive removal of a staging tree this module created itself.
-- Children sort deepest-first so empty directories fall after their contents.
local function remove_tree(fs, root)
  if not root or not fs.info(root) then return true end
  local names = fs.list(root) or {}
  table.sort(names, function(a, b) return #a > #b end)
  local ok = true
  for _, rel in ipairs(names) do
    if not fs.remove(join(root, rel)) then ok = false end
  end
  if not fs.remove(root) then ok = false end
  if not ok then return nil, "could not clean staging folder " .. root end
  return true
end
M.remove_tree = remove_tree -- reused by the later cross-filesystem move

local function job_yield(job, phase, detail, done, total)
  job.phase, job.detail = phase, detail
  job.done, job.total = done or job.done or 0, total or job.total or 0
  coroutine.yield()
  if job.cancel_requested then error({ cancel = true }, 0) end
end

-- Enumerate the saved project exactly as it will be published. pal.list_dir
-- prunes dot-directories, so `.ed` (and other tool state like `.git`) never
-- enters a duplicate; machine-local `video.dat` is excluded by name (D036/
-- D074). Links are refused rather than followed or silently flattened.
local function collect_tree(fs, source)
  local names, err = fs.list(source)
  if not names then
    fail("cannot list project folder " .. source .. ": " .. tostring(err))
  end
  table.sort(names)
  local dirs, files = {}, {}
  for _, rel in ipairs(names) do
    if rel ~= "video.dat" then
      local full = join(source, rel)
      local info, ierr = fs.info(full)
      if not info then
        fail("project changed during duplicate; retry: " .. full
          .. ": " .. tostring(ierr))
      end
      if info.link then
        fail("project contains a link; duplicate refuses to copy it: " .. full)
      end
      if info.type == "directory" then dirs[#dirs + 1] = rel
      elseif info.type == "file" then files[#files + 1] = rel
      else fail("project contains an unsupported file type: " .. full) end
    end
  end
  return dirs, files
end

local function duplicate_run(job, source, parent, name, opts)
  local fs = opts.fs or default_fs()
  if not opts.fs and (not pal.version or pal.version.api < M.API
      or type(pal.x_path_move) ~= "function") then
    fail("duplicating a project needs PAL api " .. M.API .. " or newer")
  end
  if not need_copy_fs(fs) then fail("project duplicate filesystem is unavailable") end
  job.fs = fs
  local platform = opts.platform or pal.platform
  local ofail = opts.fail or {}

  job_yield(job, "preflight", "validating source and destination", 0, 1)
  local src, err = project.normalize_root(source)
  if not src then fail(err) end
  local active = active_root(opts)
  if active and same_path(src, active, platform) then
    fail("return to the project picker before duplicating the open project")
  end
  local dest
  dest, err = M.destination(parent, name, opts)
  if not dest then fail(err) end
  if same_path(src, dest, platform) then
    fail("a duplicate needs a new folder name or parent")
  end
  if inside_path(dest, src, platform) then
    fail("a project cannot be duplicated into itself")
  end

  local si, serr = fs.info(src)
  if not si then fail("source project folder is unavailable: " .. tostring(serr)) end
  if si.type ~= "directory" then fail("source project path is not a folder") end
  if si.link then
    fail("a project-folder alias cannot duplicate; open its real folder first")
  end
  local meta
  src, meta = project.inspect_root(src, fs.read)
  if not src then fail(meta) end

  if fs.info(dest) then fail("destination already exists: " .. dest) end
  local dest_parent, dest_name = M.parts(dest)
  if not dest_parent then fail(dest_name or "destination must have a parent") end
  local dpi, dperr = fs.info(dest_parent)
  if not dpi then fail("destination parent is unavailable: " .. tostring(dperr)) end
  if dpi.type ~= "directory" then fail("destination parent is not a folder") end
  local nonce = tostring(opts.nonce or (pal.time_ns and pal.time_ns()) or 0)
  local ok
  ok, err = fs.probe(dest_parent, nonce .. ".duplicate")
  if not ok then fail("destination parent is not writable: " .. tostring(err)) end
  job.source, job.destination = src, dest

  job_yield(job, "collecting", "walking saved project files", 0, 1)
  local dirs, files = collect_tree(fs, src)
  job.total = #files + 3 -- copy steps + validate + publish + recents

  -- The staging root is dot-prefixed: pal.list_dir prunes it, so the picker
  -- scan and this module's own tree enumeration can never see a half-copy.
  local staging
  for attempt = 0, 8 do
    local candidate = join(dest_parent,
      ".cosmic-duplicate." .. nonce .. "." .. attempt)
    if not fs.info(candidate) then staging = candidate break end
  end
  if not staging then
    fail("cannot allocate a unique staging folder in " .. dest_parent)
  end
  if not fs.mkdir(staging) or not fs.info(staging) then
    fail("cannot create staging folder " .. staging)
  end
  job.staging = staging
  for _, rel in ipairs(dirs) do
    if not fs.mkdir(join(staging, rel)) then
      fail("cannot create staging folder " .. join(staging, rel))
    end
  end

  for index, rel in ipairs(files) do
    job_yield(job, "copying", rel, index - 1, job.total)
    local bytes, rerr = fs.read(join(src, rel))
    if not bytes then
      fail("cannot read " .. join(src, rel) .. ": " .. tostring(rerr))
    end
    local wok, werr = fs.write_atomic(join(staging, rel), bytes, ofail.write)
    if not wok then
      fail("cannot write " .. join(staging, rel) .. ": " .. tostring(werr))
    end
  end

  job_yield(job, "validating", "checking the staged copy", #files, job.total)
  local staged_root, staged_err = project.inspect_root(staging, fs.read)
  if not staged_root then fail("staged duplicate is not valid: " .. tostring(staged_err)) end

  job_yield(job, "publishing", dest, #files + 1, job.total)
  ok, err = fs.move(staging, dest, ofail.publish)
  if not ok then fail("duplicate was not published: " .. tostring(err)) end
  job.staging = nil
  job.published = dest

  -- The duplicate now exists; a late cancel must not misreport it as
  -- unpublished, so recents registration runs without another yield.
  job.phase, job.detail, job.done =
    "recents", "registering the new project", #files + 2
  local recent = opts.recent or cm.require("cm.recent")
  ok, err = recent.note(dest, ofail.recent)
  if not ok then
    fail("project duplicated to " .. dest .. ", but recents could not update: "
      .. tostring(err) .. "; use open folder to register it")
  end
  job.done, job.name = job.total, meta and meta.name or dest_name
end

function M.duplicate_start(source, parent, name, opts)
  opts = opts or {}
  local job = { phase = "starting", detail = "preparing duplicate",
                done = 0, total = 1 }
  job.co = coroutine.create(function()
    duplicate_run(job, source, parent, name, opts)
  end)
  return job
end

function M.duplicate_step(job)
  if not job or job.terminal then return job end
  local ok, err = coroutine.resume(job.co)
  if not ok then
    if type(err) == "table" and err.cancel then
      job.phase, job.detail, job.cancelled =
        "cancelled", "duplicate cancelled", true
    else
      job.phase, job.detail, job.error = "failed", tostring(err), tostring(err)
    end
    if job.staging then
      local cleaned, clean_err = remove_tree(job.fs or default_fs(), job.staging)
      if not cleaned and job.error then
        job.error = job.error .. "; " .. tostring(clean_err)
        job.detail = job.error
      elseif not cleaned then
        job.detail = job.detail .. "; " .. tostring(clean_err)
      end
      job.staging = nil
    end
    job.terminal = true
  elseif coroutine.status(job.co) == "dead" then
    job.phase, job.detail, job.complete, job.terminal =
      "complete", "duplicate published", true, true
  end
  return job
end

function M.duplicate_cancel(job)
  if not job or job.terminal then return false end
  job.cancel_requested = true
  return true
end

return M
