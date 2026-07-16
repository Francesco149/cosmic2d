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
local chunk, load_err = loadfile(meta_path, "t", {})
if not chunk then die("invalid declarative project metadata: " .. tostring(load_err)) end
local ran, meta = pcall(chunk)
if not ran then die("project metadata failed: " .. tostring(meta)) end
if type(meta) ~= "table" then die("project.lua must return a table") end

local function one_line(field, optional, max_len)
  local value = meta[field]
  if optional and (value == nil or value == "") then return nil end
  if type(value) ~= "string" then die(field .. " must be a string") end
  value = value:match("^%s*(.-)%s*$")
  if value == "" then die(field .. " must not be empty") end
  if #value > max_len then die(field .. " is too long (max " .. max_len .. " bytes)") end
  if value:find("[%z\r\n]") then die(field .. " must fit on one line") end
  return value
end

local title = one_line("name", false, 120)
local version = one_line("version", false, 64)
local author = one_line("author", true, 120)
local description = one_line("description", false, 1000)

local function project_path(field, value)
  if type(value) ~= "string" then die(field .. " must be a project-relative path") end
  if value == "" or #value > 240 or value:sub(1, 1) == "/"
      or value:find("\\", 1, true) or value:find(":", 1, true)
      or value:find("[%z\r\n<>#?]") then
    die(field .. " must be a safe forward-slash project-relative path")
  end
  for segment in (value .. "/"):gmatch("(.-)/") do
    if segment == "" or segment == "." or segment == ".." then
      die(field .. " contains an unsafe path segment: " .. value)
    end
  end
  return value
end

local icon_path = project_path("icon", meta.icon)
local controls_path = project_path("controls", meta.controls)
local credits_path = project_path("credits", meta.credits)
if type(meta.licenses) ~= "table" or #meta.licenses == 0 then
  die("licenses must be a non-empty array of project-relative paths")
end
local licenses, seen = {}, {}
for i = 1, #meta.licenses do
  local path = project_path("licenses[" .. i .. "]", meta.licenses[i])
  if seen[path] then die("duplicate project license path: " .. path) end
  seen[path] = true
  licenses[#licenses + 1] = path
end
for key in pairs(meta.licenses) do
  if type(key) ~= "number" or math.type(key) ~= "integer"
      or key < 1 or key > #meta.licenses then
    die("licenses must be a dense array")
  end
end

local function release_text(field, path)
  local bytes = read_all(project_dir .. "/" .. path, field, 512 * 1024)
  if bytes:find("\0", 1, true) then die(field .. " must be a text file: " .. path) end
  bytes = bytes:gsub("^\239\187\191", "")
               :gsub("\r\n", "\n"):gsub("\r", "\n")
               :gsub("%s+$", "")
  if bytes == "" then die(field .. " must not be empty: " .. path) end
  return bytes .. "\n"
end

local controls = release_text("controls", controls_path)
local credits = release_text("credits", credits_path)
for i, path in ipairs(licenses) do
  release_text("licenses[" .. i .. "]", path) -- validate; originals stay inspectable
end

local icon = read_all(project_dir .. "/" .. icon_path, "icon", 8 * 1024 * 1024)
if #icon < 24 or icon:sub(1, 8) ~= "\137PNG\r\n\26\n" then
  die("icon must be a PNG file: " .. icon_path)
end
local ihdr_len, ihdr, icon_w, icon_h = string.unpack(">I4c4I4I4", icon, 9)
if ihdr_len ~= 13 or ihdr ~= "IHDR" or icon_w ~= icon_h
    or icon_w < 32 or icon_w > 1024 then
  die("icon PNG must be square and 32..1024 pixels: " .. icon_path)
end

-- Escape metadata as Markdown text. Author-owned controls and credits are
-- intentionally Markdown and are embedded verbatim below their fixed headings.
local MD_ESCAPE = {
  ["\\"] = "\\\\", ["`"] = "\\`", ["*"] = "\\*", ["_"] = "\\_",
  ["{"] = "\\{", ["}"] = "\\}", ["["] = "\\[", ["]"] = "\\]",
  ["<"] = "\\<", [">"] = "\\>", ["#"] = "\\#", ["|"] = "\\|",
}
local function md(value)
  return (value:gsub(".", function(ch) return MD_ESCAPE[ch] or ch end))
end

local launcher = slug .. (platform == "windows" and ".exe" or "")
local editor = "bin/cosmic2d-editor" .. (platform == "windows" and ".exe" or "")
local project_link = "projects/" .. slug
local lines = {
  "# " .. md(title), "", md(description), "",
  "Version `" .. md(version) .. "`" .. (author and (" · by " .. md(author)) or ""), "",
  "## Play", "",
}
if platform == "windows" then
  lines[#lines + 1] = "Double-click `" .. launcher .. "`."
else
  lines[#lines + 1] = "Run `./" .. launcher .. "`."
end
lines[#lines + 1] = ""
lines[#lines + 1] = "## Controls"
lines[#lines + 1] = ""
lines[#lines + 1] = controls:gsub("\n$", "")
lines[#lines + 1] = ""
lines[#lines + 1] = "## Credits"
lines[#lines + 1] = ""
lines[#lines + 1] = credits:gsub("\n$", "")
lines[#lines + 1] = ""
lines[#lines + 1] = "## Licenses"
lines[#lines + 1] = ""
lines[#lines + 1] = "Project code and assets carry these author-supplied terms:"
lines[#lines + 1] = ""
for _, path in ipairs(licenses) do
  local label = path:match("([^/]+)$")
  lines[#lines + 1] = "- [" .. md(label) .. "](<" .. project_link .. "/" .. path .. ">)"
end
lines[#lines + 1] = "- [cosmic2d engine license](LICENSE)"
lines[#lines + 1] = "- [engine and runtime notices](THIRD_PARTY_NOTICES.md)"
lines[#lines + 1] = ""
lines[#lines + 1] = "## About this build"
lines[#lines + 1] = ""
lines[#lines + 1] = "The editable project is included at `" .. project_link .. "`. "
  .. "To deliberately inspect it with the included authoring tools, run `" .. editor .. "`."
lines[#lines + 1] = ""
lines[#lines + 1] = "This alpha build is unsigned. `SHA256SUMS` covers every extracted file; "
  .. "the archive's sibling `.sha256` verifies the download when obtained from a trusted source."
lines[#lines + 1] = ""

write_all(bundle_root .. "/README.md", table.concat(lines, "\n"), "player README")
write_all(bundle_root .. "/PLAY.txt",
  title .. "\nversion " .. version .. "\n\n"
  .. (platform == "windows" and ("Double-click " .. launcher .. " to play.\n")
      or ("Run ./" .. launcher .. " to play.\n"))
  .. "See README.md for controls, credits, licenses, and integrity notes.\n",
  "player quick-start")
write_all(bundle_root .. "/icon.png", icon, "player icon")

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
