-- cm.export -- self-contained in-editor player archive builder (A3/D075).
--
-- A public editor already carries one complete portable runtime: Linux in the
-- Linux download, Windows in the Windows download.  This module combines that
-- matching runtime with an arbitrary open project and streams a player-facing
-- archive without a shell, Nix, tar, zip, or a compiler.  Work advances one
-- file per step so the project window can show progress and cancel safely.
-- The only authoritative transition is pal.x_file_publish(temp, final).

local M = select(2, ...) or {}

M.API = 14
M.MAX_FILE = 0xffffffff
M.MAX_ZIP_ENTRIES = 65535

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function leaf(path)
  return (tostring(path):gsub("[\\/]+$", ""):match("([^\\/]+)$")) or "game"
end

local function join(a, b)
  if a:match("[\\/]$") then return a .. b end
  return a .. "/" .. b
end

local function safe_slug(value)
  local slug = trim(value):lower():gsub("[^a-z0-9_-]+", "-")
  slug = slug:gsub("%-+", "-"):gsub("^[%._%-]+", ""):gsub("[%._%-]+$", "")
  if slug == "" then slug = "game" end
  return slug:sub(1, 48):gsub("[%._%-]+$", "")
end
M.slug = safe_slug

local MD_ESCAPE = {
  ["\\"] = "\\\\", ["`"] = "\\`", ["*"] = "\\*", ["_"] = "\\_",
  ["{"] = "\\{", ["}"] = "\\}", ["["] = "\\[", ["]"] = "\\]",
  ["<"] = "\\<", [">"] = "\\>", ["#"] = "\\#", ["|"] = "\\|",
}
local function md(value)
  return (value:gsub(".", function(ch) return MD_ESCAPE[ch] or ch end))
end

-- Canonical project-owned files at the root of either the host packager's
-- staging tree or this streaming exporter. `checked` is the output of
-- cm.project.validate_release_files.
function M.player_surface(checked, slug, platform)
  local release = checked.release
  local title, version = release.name, release.version
  local launcher = slug .. (platform == "windows" and ".exe" or "")
  local editor = "bin/cosmic2d-editor" .. (platform == "windows" and ".exe" or "")
  local project_link = "projects/" .. slug
  local lines = {
    "# " .. md(title), "", md(release.description), "",
    "Version `" .. md(version) .. "`"
      .. (release.author and (" · by " .. md(release.author)) or ""), "",
    "## Play", "",
    platform == "windows" and ("Double-click `" .. launcher .. "`.")
      or ("Run `./" .. launcher .. "`."),
    "", "## Controls", "", checked.controls.text:gsub("\n$", ""),
    "", "## Credits", "", checked.credits.text:gsub("\n$", ""),
    "", "## Licenses", "",
    "Project code and assets carry these author-supplied terms:", "",
  }
  for _, path in ipairs(release.licenses) do
    local label = path:match("([^/]+)$")
    lines[#lines + 1] = "- [" .. md(label) .. "](<" .. project_link
      .. "/" .. path .. ">)"
  end
  lines[#lines + 1] = "- [cosmic2d engine license](LICENSE)"
  lines[#lines + 1] = "- [engine and runtime notices](THIRD_PARTY_NOTICES.md)"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "## About this build"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "The editable project is included at `" .. project_link
    .. "`. To deliberately inspect it with the included authoring tools, run `"
    .. editor .. "`."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "This alpha build is unsigned. `SHA256SUMS` covers every "
    .. "extracted file; the archive's sibling `.sha256` verifies the download "
    .. "when obtained from a trusted source."
  lines[#lines + 1] = ""
  local quick = title .. "\nversion " .. version .. "\n\n"
    .. (platform == "windows" and ("Double-click " .. launcher .. " to play.\n")
        or ("Run ./" .. launcher .. " to play.\n"))
    .. "See README.md for controls, credits, licenses, and integrity notes.\n"
  return {
    { name = "README.md", bytes = table.concat(lines, "\n") },
    { name = "PLAY.txt", bytes = quick },
    { name = "icon.png", bytes = checked.icon.bytes },
  }
end

local function default_fs()
  return {
    read = pal.read_file, write_atomic = pal.write_file_atomic,
    append = pal.x_file_append, remove = pal.x_remove, mkdir = pal.mkdir,
    list = pal.list_dir, info = pal.x_path_info, publish = pal.x_file_publish,
    sha = pal.sha256, sha_file = pal.sha256_file, crc = pal.crc32,
    identity = pal.x_windows_exe_identity,
    user_path = pal.user_path,
  }
end

local function fail(message) error(tostring(message), 0) end

local function check_rel(path)
  if path == "" or path:sub(1, 1) == "/" or path:find("\\", 1, true)
      or path:find("%z") or path:find("//", 1, true) then
    fail("unsafe archive path: " .. path)
  end
  for part in (path .. "/"):gmatch("(.-)/") do
    if part == "" or part == "." or part == ".." then
      fail("unsafe archive path: " .. path)
    end
  end
end

local function add_entry(ctx, entry)
  check_rel(entry.name)
  if ctx.names[entry.name] then fail("duplicate archive path: " .. entry.name) end
  ctx.names[entry.name] = true
  entry.mode = entry.mode or 420 -- 0644
  ctx.entries[#ctx.entries + 1] = entry
  return entry
end

local function add_file(ctx, source, name, mode)
  local info, err = ctx.fs.info(source)
  if not info then fail("cannot inspect " .. source .. ": " .. tostring(err)) end
  if info.link then fail("release input is a symbolic/reparse link: " .. source) end
  if info.type ~= "file" then fail("release input is not a file: " .. source) end
  if info.size > M.MAX_FILE then fail("release input exceeds 4 GiB: " .. source) end
  return add_entry(ctx, { name = name, source = source, size = info.size, mode = mode })
end

local function add_tree(ctx, source, prefix, accept)
  local root, err = ctx.fs.info(source)
  if not root then fail("release input is missing: " .. source .. ": " .. tostring(err)) end
  if root.link or root.type ~= "directory" then
    fail("release input is not a real directory: " .. source)
  end
  local found
  found, err = ctx.fs.list(source)
  if not found then fail("cannot list release input " .. source .. ": " .. tostring(err)) end
  table.sort(found)
  for _, rel in ipairs(found) do
    local full = join(source, rel)
    local info, ierr = ctx.fs.info(full)
    if not info then fail("cannot inspect " .. full .. ": " .. tostring(ierr)) end
    if info.link then fail("release input is a symbolic/reparse link: " .. full) end
    if info.type == "file" and (not accept or accept(rel, full)) then
      if info.size > M.MAX_FILE then fail("release input exceeds 4 GiB: " .. full) end
      add_entry(ctx, { name = prefix .. "/" .. rel, source = full,
                       size = info.size, mode = 420 })
    elseif info.type ~= "file" and info.type ~= "directory" then
      fail("release input has unsupported type: " .. full)
    end
  end
end

local COMMON_TREES = {
  { "engine", "engine" }, { "projects/picker", "projects/picker" },
  { "LICENSES", "LICENSES" }, { "pal/shaders", "pal/shaders" },
  { "pal/vendor/fonts", "pal/vendor/fonts" },
}
local COMMON_FILES = {
  "LICENSE", "THIRD_PARTY_NOTICES.md", "pal/res/cosmic2d.png",
}

local function runtime_inventory(ctx)
  local lines = { "cosmic2d carried runtime libraries", "platform: " .. ctx.target, "" }
  if ctx.target == "linux" then
    lines[#lines + 1] = "These shared objects are carried in lib/:"
    local libs = {}
    for _, entry in ipairs(ctx.entries) do
      if entry.name:match("^lib/[^/]+$") then libs[#libs + 1] = entry.name end
    end
    table.sort(libs)
    for _, path in ipairs(libs) do lines[#lines + 1] = path end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "The matching pinned source notices are under LICENSES/linux-runtime/."
  else
    lines[#lines + 1] = "These runtime DLL copies are carried in the tree:"
    local dlls = {}
    for _, entry in ipairs(ctx.entries) do
      if entry.name:lower():match("%.dll$") then dlls[#dlls + 1] = entry.name end
    end
    table.sort(dlls)
    for _, path in ipairs(dlls) do lines[#lines + 1] = path end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "The matching pinned source notices are under LICENSES/windows-runtime/."
  end
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

local function collect(ctx, checked)
  for _, spec in ipairs(COMMON_TREES) do
    add_tree(ctx, join(ctx.runtime, spec[1]), spec[2])
  end
  for _, rel in ipairs(COMMON_FILES) do add_file(ctx, join(ctx.runtime, rel), rel) end

  local project_prefix = "projects/" .. ctx.slug
  add_tree(ctx, ctx.project_root, project_prefix, function(rel)
    -- .ed and other dot-directories are pruned by pal.list_dir. video.dat is
    -- per-machine viewport policy, never project source (D036/D074).
    return rel ~= "video.dat" and not rel:match("^%.ed/")
  end)

  if ctx.target == "linux" then
    add_tree(ctx, join(ctx.runtime, "lib"), "lib")
    local engine = join(ctx.runtime, "bin/cosmic")
    add_tree(ctx, join(ctx.runtime, "bin"), "bin", function(rel)
      return rel ~= "cosmic"
    end)
    add_file(ctx, engine, "bin/" .. ctx.slug, 493) -- 0755
    add_file(ctx, engine, "bin/cosmic2d-editor", 493)
    local root_launcher = join(ctx.runtime, "cosmic2d-editor")
    add_file(ctx, root_launcher, ctx.slug, 493)
  else
    local engine = join(ctx.runtime, "bin/cosmic.exe")
    add_tree(ctx, join(ctx.runtime, "bin"), "bin", function(rel)
      local lower = rel:lower()
      return lower ~= "cosmic.exe" and lower ~= "cosmic-player.exe"
    end)
    add_file(ctx, engine, "bin/" .. ctx.slug .. ".exe", 493)
    add_file(ctx, engine, "bin/cosmic2d-editor.exe", 493)
    -- Root DLLs let the project-branded direct engine entrance start under the
    -- normal Windows loader rules. Keep the bin copies for every inner tool.
    for _, entry in ipairs({ table.unpack(ctx.entries) }) do
      local dll = entry.name:match("^bin/([^/]+%.[dD][lL][lL])$")
      if dll then add_file(ctx, entry.source, dll, 420) end
    end
    local root = add_file(ctx, join(ctx.runtime, "bin/cosmic-player.exe"),
                          ctx.slug .. ".exe", 493)
    if not ctx.skip_windows_identity then root.windows_identity = checked end
  end

  for _, entry in ipairs(M.player_surface(checked, ctx.slug, ctx.target)) do
    add_entry(ctx, entry)
  end
  add_entry(ctx, { name = "RUNTIME-LIBRARIES.txt", bytes = runtime_inventory(ctx) })
  if #ctx.entries + 1 > M.MAX_ZIP_ENTRIES and ctx.target == "windows" then
    fail("project has too many files for a ZIP export")
  end
end

local function bytes_for(ctx, entry)
  if entry.bytes then return entry.bytes end
  local bytes, err = ctx.fs.read(entry.source)
  if not bytes then fail("cannot read " .. entry.source .. ": " .. tostring(err)) end
  if entry.size and #bytes ~= entry.size then
    fail("file changed during export; retry: " .. entry.source)
  end
  if entry.windows_identity then
    if type(ctx.fs.identity) ~= "function" then
      fail("this Windows runtime cannot brand the player launcher")
    end
    local scratch = ctx.temp .. ".launcher.exe"
    ctx.fs.remove(scratch)
    local wrote, write_err = ctx.fs.write_atomic(scratch, bytes)
    if not wrote then fail("cannot stage Windows player launcher: " .. tostring(write_err)) end
    local checked = entry.windows_identity
    local r = checked.release
    local branded, brand_err = ctx.fs.identity(
      scratch, checked.icon.bytes, checked.icon.w, checked.icon.h,
      r.name, r.version, r.author or "", ctx.slug)
    if not branded then
      ctx.fs.remove(scratch)
      fail("cannot brand Windows player launcher: " .. tostring(brand_err))
    end
    local patched, patch_err = ctx.fs.read(scratch)
    ctx.fs.remove(scratch)
    if not patched then fail("cannot read branded Windows launcher: " .. tostring(patch_err)) end
    bytes = patched
  end
  return bytes
end

local function append(ctx, bytes)
  if bytes == "" then return end
  if ctx.target == "windows" and ctx.out_bytes + #bytes > M.MAX_FILE then
    fail("ZIP32 export exceeds 4 GiB")
  end
  if not ctx.fs.append(ctx.temp, bytes) then fail("write temporary archive failed") end
  ctx.out_bytes = ctx.out_bytes + #bytes
end

local function zip_member(ctx, entry, bytes)
  local name = ctx.slug .. "/" .. entry.name
  if #name > 65535 then fail("ZIP path is too long: " .. entry.name) end
  local size = #bytes
  if size > M.MAX_FILE or ctx.out_bytes > M.MAX_FILE then
    fail("ZIP32 export exceeds 4 GiB")
  end
  local crc = ctx.fs.crc(bytes)
  local offset = ctx.out_bytes
  local flags, date = 0x0800, 33 -- UTF-8; deterministic 1980-01-01
  append(ctx, string.pack("<I4I2I2I2I2I2I4I4I4I2I2",
    0x04034b50, 20, flags, 0, 0, date, crc, size, size, #name, 0) .. name)
  append(ctx, bytes)
  ctx.central[#ctx.central + 1] = string.pack(
    "<I4I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4",
    0x02014b50, 0x0314, 20, flags, 0, 0, date, crc, size, size,
    #name, 0, 0, 0, 0, (entry.mode or 420) << 16, offset) .. name
end

local function tar_split(path)
  if #path <= 100 then return path, "" end
  for cut = #path, 1, -1 do
    if path:sub(cut, cut) == "/" then
      local prefix, name = path:sub(1, cut - 1), path:sub(cut + 1)
      if #prefix <= 155 and #name <= 100 then return name, prefix end
    end
  end
  fail("tar path exceeds the portable 255-byte limit: " .. path)
end

local function field(value, width)
  local s = tostring(value or "")
  if #s > width then fail("tar header field is too long: " .. s) end
  return s .. string.rep("\0", width - #s)
end

local function octal(value, width)
  local s = string.format("%o", value)
  if #s > width - 1 then fail("tar numeric field overflow") end
  return string.rep("0", width - 1 - #s) .. s .. "\0"
end

local function tar_header(path, size, mode)
  local name, prefix = tar_split(path)
  local h = field(name, 100) .. octal(mode or 420, 8) .. octal(0, 8)
    .. octal(0, 8) .. octal(size, 12) .. octal(0, 12) .. string.rep(" ", 8)
    .. "0" .. field("", 100) .. "ustar\0" .. "00"
    .. field("cosmic2d", 32) .. field("cosmic2d", 32)
    .. octal(0, 8) .. octal(0, 8) .. field(prefix, 155) .. string.rep("\0", 12)
  if #h ~= 512 then fail("internal tar header size") end
  local sum = 0
  for i = 1, #h do sum = sum + h:byte(i) end
  local check = string.format("%06o\0 ", sum)
  return h:sub(1, 148) .. check .. h:sub(157)
end

local function gzip_block(ctx, bytes, final)
  local at = 1
  if #bytes == 0 and final then
    append(ctx, "\1\0\0\255\255")
    return
  end
  while at <= #bytes do
    local n = math.min(65535, #bytes - at + 1)
    local last = final and at + n > #bytes
    append(ctx, string.char(last and 1 or 0)
      .. string.pack("<I2I2", n, (~n) & 0xffff)
      .. bytes:sub(at, at + n - 1))
    at = at + n
  end
end

local function tar_emit(ctx, bytes)
  ctx.tar_crc = ctx.fs.crc(bytes, ctx.tar_crc)
  ctx.tar_size = (ctx.tar_size + #bytes) & 0xffffffff
  gzip_block(ctx, bytes, false)
end

local function tar_member(ctx, entry, bytes)
  tar_emit(ctx, tar_header(ctx.slug .. "/" .. entry.name, #bytes, entry.mode))
  tar_emit(ctx, bytes)
  local pad = (-#bytes) % 512
  if pad > 0 then tar_emit(ctx, string.rep("\0", pad)) end
end

local function checksums(ctx)
  local paths = {}
  for path in pairs(ctx.hashes) do paths[#paths + 1] = path end
  table.sort(paths)
  local lines = {}
  for _, path in ipairs(paths) do
    lines[#lines + 1] = ctx.hashes[path] .. "  " .. path .. "\n"
  end
  return table.concat(lines)
end

local function finish_zip(ctx)
  local start = ctx.out_bytes
  local central = table.concat(ctx.central)
  append(ctx, central)
  append(ctx, string.pack("<I4I2I2I2I2I4I4I2", 0x06054b50, 0, 0,
    #ctx.central, #ctx.central, #central, start, 0))
end

local function finish_tar(ctx)
  tar_emit(ctx, string.rep("\0", 1024))
  gzip_block(ctx, "", true)
  append(ctx, string.pack("<I4I4", ctx.tar_crc, ctx.tar_size))
end

local function job_yield(job, phase, detail, done, total)
  job.phase, job.detail = phase, detail
  job.done, job.total = done or job.done or 0, total or job.total or 0
  coroutine.yield()
  if job.cancel_requested then error({ cancel = true }, 0) end
end

local function run(job, opts)
  local project = opts.project or cm.require("cm.project")
  local fs = opts.fs or default_fs()
  job.fs = fs
  local ctx = {
    fs = fs, runtime = opts.runtime_root or ".", project_root = opts.project_root,
    target = opts.target, names = {}, entries = {}, hashes = {}, central = {},
    out_bytes = 0, tar_crc = 0, tar_size = 0,
    skip_windows_identity = opts.skip_windows_identity,
  }
  job_yield(job, "preflight", "validating saved project and player files", 0, 1)
  if type(ctx.project_root) ~= "string" or ctx.project_root == "" then
    fail("export needs the open project folder")
  end
  if ctx.target ~= "linux" and ctx.target ~= "windows" then
    fail("target must be Linux or Windows")
  end
  local host = opts.host_platform or pal.platform
  if ctx.target ~= host then
    fail((ctx.target == "windows" and "Windows" or "Linux")
      .. " export needs the matching cosmic2d editor download")
  end
  if not opts.fs and (pal.version.api < M.API
      or type(pal.x_file_publish) ~= "function") then
    fail("export needs PAL API " .. M.API .. " or newer")
  end
  local meta_bytes, read_err = fs.read(join(ctx.project_root, "project.lua"))
  if not meta_bytes then fail("cannot read saved project.lua: " .. tostring(read_err)) end
  local meta, decode_err = project.decode(meta_bytes, "@" .. ctx.project_root .. "/project.lua")
  if not meta then fail(decode_err) end
  local checked, release_err = project.validate_release_files(meta, function(rel)
    return fs.read(join(ctx.project_root, rel))
  end)
  if not checked then fail("player metadata: " .. tostring(release_err)) end
  ctx.slug = safe_slug(opts.slug or leaf(ctx.project_root))
  if ctx.slug == "cosmic2d-editor" or ctx.slug == "cosmic"
      or ctx.slug == "picker" then
    ctx.slug = "game-" .. ctx.slug
  end
  local version = safe_slug(checked.release.version)
  ctx.basename = ctx.slug .. "-" .. version .. "-" .. ctx.target
  local output = trim(opts.output_dir)
  if output == "" then
    local user, user_err = fs.user_path()
    if not user then fail("default export folder unavailable: " .. tostring(user_err)) end
    output = join(user, "exports")
  end
  if output:find("[%z\r\n]") then fail("output folder contains unsafe characters") end
  if not fs.mkdir(output) then fail("cannot create output folder: " .. output) end
  local oi = fs.info(output)
  if not oi or oi.type ~= "directory" or oi.link then
    fail("output location is not a real folder: " .. output)
  end
  local probe = join(output, ".cosmic-export-write-test")
  local ok, probe_err = fs.write_atomic(probe, "")
  if not ok then fail("output folder is not writable: " .. tostring(probe_err)) end
  fs.remove(probe)
  local ext = ctx.target == "windows" and ".zip" or ".tar.gz"
  ctx.final = join(output, ctx.basename .. ext)
  ctx.sidecar = ctx.final .. ".sha256"
  if not opts.replace and (fs.info(ctx.final) or fs.info(ctx.sidecar)) then
    fail("output already exists; move it or choose another folder: " .. ctx.final)
  end
  local nonce = tostring((opts.nonce or pal.time_ns())):gsub("[^0-9]", "")
  ctx.temp = join(output, "." .. ctx.basename .. ext .. ".tmp." .. nonce)
  fs.remove(ctx.temp)
  job.output_dir, job.output, job.temp, job.target = output, ctx.final, ctx.temp, ctx.target
  job.slug = ctx.slug

  job_yield(job, "collecting", "walking portable runtime and project", 0, 1)
  collect(ctx, checked)
  job.total = #ctx.entries + 1
  if ctx.target == "linux" then
    append(ctx, "\31\139\8\0\0\0\0\0\0\255") -- gzip, no timestamp, OS unknown
  end

  for index, entry in ipairs(ctx.entries) do
    job_yield(job, "building", entry.name, index - 1, #ctx.entries + 1)
    local bytes = bytes_for(ctx, entry)
    ctx.hashes[entry.name] = fs.sha(bytes)
    if ctx.target == "windows" then zip_member(ctx, entry, bytes)
    else tar_member(ctx, entry, bytes) end
  end
  local sum = checksums(ctx)
  local sum_entry = { name = "SHA256SUMS", bytes = sum, mode = 420 }
  job_yield(job, "building", "SHA256SUMS", #ctx.entries, #ctx.entries + 1)
  if ctx.target == "windows" then
    zip_member(ctx, sum_entry, sum); finish_zip(ctx)
  else
    tar_member(ctx, sum_entry, sum); finish_tar(ctx)
  end

  job_yield(job, "publishing", "syncing complete artifact", job.total, job.total)
  local publish_opts = {}
  if opts.fail and opts.fail.publish then
    for key, value in pairs(opts.fail.publish) do publish_opts[key] = value end
  end
  publish_opts._replace = opts.replace or false
  local published, publish_err = fs.publish(ctx.temp, ctx.final, publish_opts)
  if not published then fail(publish_err) end
  job.temp = nil
  local digest, hash_err = fs.sha_file(ctx.final)
  if not digest then fail("artifact built but checksum failed: " .. tostring(hash_err)) end
  local side = digest .. "  " .. leaf(ctx.final) .. "\n"
  local side_ok, side_err = fs.write_atomic(ctx.sidecar, side,
                                            opts.fail and opts.fail.sidecar)
  if not side_ok then fail("artifact built but checksum publication failed: " .. tostring(side_err)) end
  job.checksum, job.bytes = digest, ctx.out_bytes
end

function M.start(opts)
  opts = opts or {}
  local job = { phase = "starting", detail = "preparing export", done = 0, total = 1 }
  job.co = coroutine.create(function() run(job, opts) end)
  return job
end

function M.step(job)
  if not job or job.terminal then return job end
  local ok, err = coroutine.resume(job.co)
  if not ok then
    if type(err) == "table" and err.cancel then
      job.phase, job.detail, job.cancelled = "cancelled", "export cancelled", true
    else
      job.phase, job.detail, job.error = "failed", tostring(err), tostring(err)
    end
    if job.temp then
      (job.fs or default_fs()).remove(job.temp)
      job.temp = nil
    end
    job.terminal = true
  elseif coroutine.status(job.co) == "dead" then
    job.phase, job.detail, job.complete, job.terminal =
      "complete", "artifact and checksum published", true, true
  end
  return job
end

function M.cancel(job)
  if not job or job.terminal then return false end
  job.cancel_requested = true
  return true
end

function M.cleanup(job)
  if job and job.temp then
    (job.fs or default_fs()).remove(job.temp)
    job.temp = nil
  end
end

return M
