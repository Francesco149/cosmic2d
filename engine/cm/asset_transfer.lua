-- cm.asset_transfer -- collision-safe copies between cosmic2d projects.
--
-- The editor opens one project at a time, so this is deliberately a saved-
-- bytes operation: the assets window refuses a dirty source before calling
-- here. Both roots are revalidated with cm.project's boot codec, the selected
-- relative path is checked with the project path grammar, links are refused,
-- and no destination file is ever replaced.
--
-- Generated companions travel as one family: a .spr carries its baked
-- .png/.anim/.meta files, and a .terr carries its published atlas when present.
-- Every member is read and staged before publication, then re-read to catch a
-- source changing during the copy. Companions publish first and the editable
-- source last, so a process interruption cannot expose a source whose family
-- is only half present. An ordinary reported failure rolls every published
-- member back and removes the private dot-prefixed staging directory.

local M = select(2, ...) or {}

local project = cm.require("cm.project")

local function join(root, rel)
  return root .. (root:sub(-1) == "/" and "" or "/") .. rel
end

local function default_fs()
  return {
    read = pal.read_file,
    info = pal.x_path_info,
    mkdir = pal.mkdir,
    remove = pal.x_remove,
    write_atomic = pal.write_file_atomic,
    publish = pal.x_file_publish,
  }
end

local function capable(fs)
  return type(fs.read) == "function" and type(fs.info) == "function"
    and type(fs.mkdir) == "function" and type(fs.remove) == "function"
    and type(fs.write_atomic) == "function" and type(fs.publish) == "function"
end

local function path_key(path, platform)
  local out = project.normalize_root(path)
  if out and platform == "windows" then out = out:lower() end
  return out
end

local function same_root(a, b, platform)
  local ak, bk = path_key(a, platform), path_key(b, platform)
  return ak ~= nil and ak == bk
end

-- The generated siblings that are part of one editable asset. Kept pure so
-- future formats can extend this one roster instead of teaching every UI.
function M.companions(path)
  local base = path:match("^(.*)%.[sS][pP][rR]$")
  if base then
    return { base .. ".png", base .. ".anim", base .. ".meta" }
  end
  base = path:match("^(.*)%.[tT][eE][rR][rR]$")
  if base then return { base .. "-atlas.png" } end
  return {}
end

-- Refuse a link anywhere in an existing path prefix. Checking only the final
-- file would let an intermediate linked directory escape the selected project.
local function check_dirs(fs, root, rel, create)
  local info, err = fs.info(root)
  if not info then return nil, "project folder is unavailable: " .. tostring(err) end
  if info.type ~= "directory" then return nil, "project root is not a folder: " .. root end
  if info.link then return nil, "project-folder links are not copied through: " .. root end
  local prefix = root
  local parent = rel:match("^(.*)/[^/]+$")
  if not parent then return true end
  for seg in parent:gmatch("[^/]+") do
    prefix = join(prefix, seg)
    info, err = fs.info(prefix)
    if info then
      if info.link then return nil, "asset path contains a link: " .. prefix end
      if info.type ~= "directory" then
        return nil, "asset parent is not a folder: " .. prefix
      end
    elseif create then
      if not fs.mkdir(prefix) then
        return nil, "cannot create asset folder " .. prefix
      end
      info, err = fs.info(prefix)
      if not info or info.type ~= "directory" or info.link then
        return nil, "created asset folder is unavailable: " .. prefix
          .. (err and (" (" .. tostring(err) .. ")") or "")
      end
    end
  end
  return true
end

local function source_member(fs, root, rel, required)
  local ok, err = check_dirs(fs, root, rel, false)
  if not ok then return nil, err end
  local full = join(root, rel)
  local info
  info, err = fs.info(full)
  if not info then
    if required then return nil, "source asset is unavailable: " .. full end
    return false
  end
  if info.link then return nil, "asset links are not copied: " .. full end
  if info.type ~= "file" then return nil, "asset is not a file: " .. full end
  return { rel = rel, full = full, size = info.size, primary = required }
end

-- Validate and snapshot the transfer shape without writing. The return order
-- is publication order: optional companions first, selected source last.
function M.plan(source, destination, path, opts)
  opts = opts or {}
  local fs = opts.fs or default_fs()
  if not capable(fs) then return nil, "project asset-copy filesystem is unavailable" end

  local src, srcmeta = project.inspect_root(source, fs.read)
  if not src then return nil, "source " .. tostring(srcmeta) end
  local dest, destmeta = project.inspect_root(destination, fs.read)
  if not dest then return nil, "destination " .. tostring(destmeta) end
  if same_root(src, dest, opts.platform or pal.platform) then
    return nil, "source and destination are the same project"
  end
  local rel, err = project.project_path("asset", path)
  if not rel then return nil, err end

  local primary
  primary, err = source_member(fs, src, rel, true)
  if not primary then return nil, err end
  local members = {}
  for _, sibling in ipairs(M.companions(rel)) do
    local member
    member, err = source_member(fs, src, sibling, false)
    if member == nil then return nil, err end
    if member then members[#members + 1] = member end
  end
  members[#members + 1] = primary -- authoritative editable source publishes last

  for _, member in ipairs(members) do
    local ok
    ok, err = check_dirs(fs, dest, member.rel, false)
    if not ok then return nil, err end
    local target = join(dest, member.rel)
    local hit = fs.info(target)
    if hit then return nil, "destination already has " .. member.rel end
    member.target = target
  end
  return { source = src, destination = dest, path = rel,
           source_meta = srcmeta, destination_meta = destmeta,
           members = members, fs = fs }
end

local function cleanup(plan, staging, staged, published)
  local fs, trouble = plan.fs, {}
  for i = #published, 1, -1 do
    if not fs.remove(published[i]) then trouble[#trouble + 1] = published[i] end
  end
  for _, path in ipairs(staged) do
    if fs.info(path) and not fs.remove(path) then trouble[#trouble + 1] = path end
  end
  if staging and fs.info(staging) and not fs.remove(staging) then
    trouble[#trouble + 1] = staging
  end
  return #trouble == 0, trouble
end

local function abort(plan, staging, staged, published, message)
  local clean, trouble = cleanup(plan, staging, staged, published)
  if not clean then
    message = message .. "; rollback could not remove " .. table.concat(trouble, ", ")
  end
  return nil, message
end

-- Copy a selected saved asset family. The source is never written and an
-- existing destination is never replaced. opts.fail is a focused proof seam:
-- { write=..., publish=..., publish_at=N }.
function M.copy(source, destination, path, opts)
  opts = opts or {}
  local plan, err = M.plan(source, destination, path, opts)
  if not plan then return nil, err end
  local fs, fail = plan.fs, opts.fail or {}

  for _, member in ipairs(plan.members) do
    local bytes, rerr = fs.read(member.full)
    if type(bytes) ~= "string" then
      return nil, "cannot read " .. member.full .. ": " .. tostring(rerr)
    end
    if member.size ~= nil and #bytes ~= member.size then
      return nil, "source asset changed while reading; retry: " .. member.rel
    end
    member.bytes = bytes
  end

  local nonce = tostring(opts.nonce or (pal.time_ns and pal.time_ns()) or 0)
  local staging
  for attempt = 0, 8 do
    local candidate = join(plan.destination,
      ".cosmic-asset-copy." .. nonce .. "." .. attempt)
    if not fs.info(candidate) then staging = candidate; break end
  end
  if not staging then return nil, "cannot allocate an asset-copy staging folder" end
  if not fs.mkdir(staging) then return nil, "cannot create staging folder " .. staging end
  local staging_info = fs.info(staging)
  if not staging_info or staging_info.type ~= "directory" or staging_info.link then
    fs.remove(staging)
    return nil, "created staging folder is unavailable: " .. staging
  end

  local staged, published = {}, {}
  for index, member in ipairs(plan.members) do
    local temp = join(staging, tostring(index) .. ".part")
    local ok, werr = fs.write_atomic(temp, member.bytes, fail.write)
    if not ok then
      return abort(plan, staging, staged, published,
        "cannot stage " .. member.rel .. ": " .. tostring(werr))
    end
    member.temp = temp
    staged[#staged + 1] = temp
  end

  -- A stable second read prevents a sprite source and its generated products
  -- from being sampled from two saves when another process edits the project.
  for _, member in ipairs(plan.members) do
    local again = fs.read(member.full)
    if again ~= member.bytes then
      return abort(plan, staging, staged, published,
        "source asset changed during the copy; retry: " .. member.rel)
    end
  end

  for index, member in ipairs(plan.members) do
    local ok
    ok, err = check_dirs(fs, plan.destination, member.rel, true)
    if not ok then return abort(plan, staging, staged, published, err) end
    local pfail = fail.publish
    if fail.publish_at == index then pfail = "rename" end
    ok, err = fs.publish(member.temp, member.target,
                         pfail and { _fail = pfail } or nil)
    if not ok then
      return abort(plan, staging, staged, published,
        "cannot publish " .. member.rel .. ": " .. tostring(err))
    end
    published[#published + 1] = member.target
  end
  if fs.info(staging) and not fs.remove(staging) then
    -- The authoritative files are complete. A private empty dot-directory is
    -- cleanup debt, not grounds to delete a successful user-visible transfer.
    pal.log("[asset-copy] could not remove empty staging folder " .. staging)
  end

  local paths, bytes = {}, 0
  paths[1] = plan.path
  for _, member in ipairs(plan.members) do
    bytes = bytes + #member.bytes
    if not member.primary then paths[#paths + 1] = member.rel end
  end
  return { source = plan.source, destination = plan.destination,
           path = plan.path, paths = paths, bytes = bytes,
           project = plan.destination_meta and plan.destination_meta.name }
end

return M
