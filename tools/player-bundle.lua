-- Build the player-facing root of a staged cosmic2d game bundle.
--
-- Usage:
--   lua player-bundle.lua PROJECT_DIR BUNDLE_ROOT SLUG {linux|windows} [RC_OUT]
--
-- project.lua is evaluated as a plain-data chunk in an empty environment. The
-- selected project is already trusted engine code, but keeping release metadata
-- declarative makes failures reproducible and gives the future in-editor exporter
-- one small contract to validate.

local project_dir, bundle_root, slug, platform, rc_out = ...

local function die(message)
  io.stderr:write("player bundle: " .. tostring(message) .. "\n")
  os.exit(1)
end

if not project_dir or not bundle_root or not slug or not platform then
  die("usage: player-bundle.lua PROJECT_DIR BUNDLE_ROOT SLUG {linux|windows} [RC_OUT]")
end
if platform ~= "linux" and platform ~= "windows" then
  die("platform must be linux or windows")
end
if not slug:match("^[a-z0-9][a-z0-9_-]*$") then
  die("project slug must use lowercase ASCII letters, digits, '_' or '-'")
end
if platform == "windows" and (not rc_out or rc_out == "") then
  die("Windows player bundles need an RC output path")
end

project_dir = project_dir:gsub("/+$", "")
bundle_root = bundle_root:gsub("/+$", "")

-- Load the same pure project model used by engine boot, the picker, and the
-- settings window.  Derive it from this script's path: packaging may run from
-- an arbitrary build directory, so cwd is not an authority.
local script = (arg and arg[0] or ""):gsub("\\", "/")
local repo = script:match("^(.*)/tools/[^/]+$")
if not repo and script:match("^tools/[^/]+$") then repo = "." end
if not repo then die("cannot locate engine/cm/project.lua from " .. script) end
local loaded, project = pcall(dofile, repo .. "/engine/cm/project.lua")
if not loaded then die("cannot load canonical project model: " .. tostring(project)) end
local export_loaded, exporter = pcall(dofile, repo .. "/engine/cm/export.lua")
if not export_loaded then die("cannot load canonical player surface: " .. tostring(exporter)) end

local function read_all(path, label, limit)
  local file, err = io.open(path, "rb")
  if not file then die("cannot read " .. label .. " " .. path .. ": " .. tostring(err)) end
  local bytes, rerr = file:read("*a")
  local ok, cerr = file:close()
  if not bytes then die("cannot read " .. label .. " " .. path .. ": " .. tostring(rerr)) end
  if not ok then die("cannot close " .. label .. " " .. path .. ": " .. tostring(cerr)) end
  if limit and #bytes > limit then
    die(label .. " is larger than " .. limit .. " bytes: " .. path)
  end
  return bytes
end

local function write_all(path, bytes, label)
  local file, err = io.open(path, "wb")
  if not file then die("cannot write " .. label .. " " .. path .. ": " .. tostring(err)) end
  local ok, werr = file:write(bytes)
  if ok then ok, werr = file:close() else file:close() end
  if not ok then die("cannot write " .. label .. " " .. path .. ": " .. tostring(werr)) end
end

local meta_path = project_dir .. "/project.lua"
local meta_bytes = read_all(meta_path, "project metadata", 512 * 1024)
local meta, decode_err = project.decode(meta_bytes, "@" .. meta_path)
if not meta then die(decode_err) end

local function read_project(path)
  local full = project_dir .. "/" .. path
  local file, err = io.open(full, "rb")
  if not file then return nil, err end
  local bytes, rerr = file:read("*a")
  local ok, cerr = file:close()
  if not bytes then return nil, rerr end
  if not ok then return nil, cerr end
  return bytes
end

local checked, release_err = project.validate_release_files(meta, read_project)
if not checked then die(release_err) end
local release = checked.release

local title, version = release.name, release.version
local author = release.author

local surface = exporter.player_surface(checked, slug, platform)
for _, entry in ipairs(surface) do
  write_all(bundle_root .. "/" .. entry.name, entry.bytes,
            "player " .. entry.name)
end

-- The Windows root entrance is a tiny delegating launcher. Give that player-
-- facing file the project's icon/title/version; the carried engine and editor
-- binaries retain truthful cosmic2d engine identity.
if platform == "windows" then
  local nums = {}
  for number in version:gmatch("%d+") do
    nums[#nums + 1] = math.min(65535, tonumber(number))
    if #nums == 4 then break end
  end
  while #nums < 4 do nums[#nums + 1] = 0 end
  local function rc(value)
    return value:gsub("\\", "\\\\"):gsub('"', '\\"')
  end
  local company = author or title
  local rc_text = ([=[#pragma code_page(65001)
#include <windows.h>

#define IDI_GAME 101
IDI_GAME ICON "game.ico"

1 VERSIONINFO
 FILEVERSION %d,%d,%d,%d
 PRODUCTVERSION %d,%d,%d,%d
 FILEFLAGSMASK VS_FFI_FILEFLAGSMASK
 FILEFLAGS VS_FF_PRERELEASE
 FILEOS VOS_NT_WINDOWS32
 FILETYPE VFT_APP
 FILESUBTYPE VFT2_UNKNOWN
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904b0"
    BEGIN
      VALUE "CompanyName", "%s\0"
      VALUE "FileDescription", "%s\0"
      VALUE "FileVersion", "%s\0"
      VALUE "InternalName", "%s\0"
      VALUE "OriginalFilename", "%s.exe\0"
      VALUE "ProductName", "%s\0"
      VALUE "ProductVersion", "%s\0"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x0409, 1200
  END
END
]=]):format(nums[1], nums[2], nums[3], nums[4],
             nums[1], nums[2], nums[3], nums[4], rc(company), rc(title),
             rc(version), rc(slug), rc(slug), rc(title), rc(version))
  write_all(rc_out, rc_text, "Windows player resources")
end

io.stdout:write(("player bundle: %s v%s (%s)\n"):format(title, version, platform))
