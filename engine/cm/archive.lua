-- cm.archive -- streaming uncompressed-deflate tar.gz and ZIP32 writers.
--
-- Extracted from cm.export (D075) so the picker's dated project backup
-- (D079) emits the identical container bytes without carrying a second
-- format implementation. Both formats stream: every member is emitted
-- through the caller's sink as it is added, so multi-hundred-MB trees never
-- exist in memory. gzip uses stored (uncompressed) deflate blocks and ZIP
-- stores members, which keeps the writers dependency-free and, deliberately,
-- keeps member bytes greppable in tests. Errors raise with error(msg, 0);
-- callers run inside coroutine jobs and surface them as named failures.

local M = select(2, ...) or {}

M.MAX_FILE = 0xffffffff -- ZIP32 per-file and total ceiling (also tar sanity)
M.MAX_ZIP_ENTRIES = 65535

local function fail(message) error(tostring(message), 0) end

-- Reject entry names that could escape the extraction directory. Shared by
-- the exporter and the project archive; both only ever add project-relative
-- paths, so a hit is a caller bug or a hostile tree.
function M.check_rel(path)
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

-- ---- tar member encoding ----

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

local function tar_header(path, size, mode, typeflag)
  local name, prefix = tar_split(path)
  local h = field(name, 100) .. octal(mode or 420, 8) .. octal(0, 8)
    .. octal(0, 8) .. octal(size, 12) .. octal(0, 12) .. string.rep(" ", 8)
    .. (typeflag or "0") .. field("", 100) .. "ustar\0" .. "00"
    .. field("cosmic2d", 32) .. field("cosmic2d", 32)
    .. octal(0, 8) .. octal(0, 8) .. field(prefix, 155) .. string.rep("\0", 12)
  if #h ~= 512 then fail("internal tar header size") end
  local sum = 0
  for i = 1, #h do sum = sum + h:byte(i) end
  local check = string.format("%06o\0 ", sum)
  return h:sub(1, 148) .. check .. h:sub(157)
end

-- ---- the writer ----

local Writer = {}
Writer.__index = Writer

-- opts.format: "tar.gz" | "zip"; opts.sink(bytes): must persist all bytes or
-- raise; opts.crc: pal.crc32-compatible rolling CRC-32.
function M.writer(opts)
  local w = setmetatable({
    format = opts.format, sink = opts.sink, crc = opts.crc,
    out_bytes = 0, members = 0, central = {}, tar_crc = 0, tar_size = 0,
  }, Writer)
  if w.format ~= "tar.gz" and w.format ~= "zip" then
    fail("unsupported archive format: " .. tostring(opts.format))
  end
  if type(w.sink) ~= "function" or type(w.crc) ~= "function" then
    fail("archive writer needs a byte sink and CRC-32")
  end
  if w.format == "tar.gz" then
    w:append("\31\139\8\0\0\0\0\0\0\255") -- gzip, no timestamp, OS unknown
  end
  return w
end

function Writer:append(bytes)
  if bytes == "" then return end
  if self.format == "zip" and self.out_bytes + #bytes > M.MAX_FILE then
    fail("ZIP32 export exceeds 4 GiB")
  end
  self.sink(bytes)
  self.out_bytes = self.out_bytes + #bytes
end

local function gzip_block(w, bytes, final)
  local at = 1
  if #bytes == 0 and final then
    w:append("\1\0\0\255\255")
    return
  end
  while at <= #bytes do
    local n = math.min(65535, #bytes - at + 1)
    local last = final and at + n > #bytes
    w:append(string.char(last and 1 or 0)
      .. string.pack("<I2I2", n, (~n) & 0xffff)
      .. bytes:sub(at, at + n - 1))
    at = at + n
  end
end

local function tar_emit(w, bytes)
  w.tar_crc = w.crc(bytes, w.tar_crc)
  w.tar_size = (w.tar_size + #bytes) & 0xffffffff
  gzip_block(w, bytes, false)
end

local function zip_add(w, name, bytes, mode, external_dir)
  if #name > 65535 then fail("ZIP path is too long: " .. name) end
  if w.members + 1 > M.MAX_ZIP_ENTRIES then
    fail("archive has too many files for a ZIP export")
  end
  local size = #bytes
  if size > M.MAX_FILE or w.out_bytes > M.MAX_FILE then
    fail("ZIP32 export exceeds 4 GiB")
  end
  local crc = w.crc(bytes)
  local offset = w.out_bytes
  local flags, date = 0x0800, 33 -- UTF-8; deterministic 1980-01-01
  w:append(string.pack("<I4I2I2I2I2I2I4I4I4I2I2",
    0x04034b50, 20, flags, 0, 0, date, crc, size, size, #name, 0) .. name)
  w:append(bytes)
  local external = ((mode or 420) << 16) | (external_dir and 0x10 or 0)
  w.central[#w.central + 1] = string.pack(
    "<I4I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4",
    0x02014b50, 0x0314, 20, flags, 0, 0, date, crc, size, size,
    #name, 0, 0, 0, 0, external, offset) .. name
  w.members = w.members + 1
end

-- A regular file member. The name is the caller's complete archive-relative
-- path (including any leading folder prefix).
function Writer:member(name, bytes, mode)
  M.check_rel(name)
  if self.format == "zip" then
    zip_add(self, name, bytes, mode)
  else
    tar_emit(self, tar_header(name, #bytes, mode))
    tar_emit(self, bytes)
    local pad = (-#bytes) % 512
    if pad > 0 then tar_emit(self, string.rep("\0", pad)) end
    self.members = self.members + 1
  end
end

-- An explicit directory member so empty folders survive extraction (the
-- exporter never emits these; the project backup preserves the exact tree).
function Writer:dir(name, mode)
  M.check_rel(name)
  if self.format == "zip" then
    zip_add(self, name .. "/", "", mode or 493, true)
  else
    tar_emit(self, tar_header(name .. "/", 0, mode or 493, "5"))
    self.members = self.members + 1
  end
end

function Writer:finish()
  if self.format == "zip" then
    local start = self.out_bytes
    local central = table.concat(self.central)
    self:append(central)
    self:append(string.pack("<I4I2I2I2I2I4I4I2", 0x06054b50, 0, 0,
      #self.central, #self.central, #central, start, 0))
  else
    tar_emit(self, string.rep("\0", 1024))
    gzip_block(self, "", true)
    self:append(string.pack("<I4I4", self.tar_crc, self.tar_size))
  end
  return self.out_bytes
end

return M
