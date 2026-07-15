-- cm.ed.cache — ownership/version contract for <project>/.ed.
--
-- .ed is engine-owned and untracked, but not wholly disposable:
--   session.dat{,.good} + journal/ are WORKING RECOVERY (unsaved work)
--   history/                         is a DERIVED rewind cache
--   owner.dat                        is this compatibility marker
--
-- A safe rebuild therefore removes only history/. Unknown/corrupt ownership
-- never licenses deleting working recovery data.

local M = select(2, ...) or {}
local chunk = cm.require("cm.chunk")

M.SCHEMA = 1
M.MAGIC = "CEDO"

function M.dir(root) return root .. "/.ed" end
function M.path(root) return M.dir(root) .. "/owner.dat" end

function M.encode(schema)
  local w = chunk.writer(M.MAGIC)
  w.chunk("OWNR", 1, string.pack("<I4s4", schema or M.SCHEMA, "cosmic2d"))
  return w.result()
end

function M.decode(blob)
  for _, c in ipairs(chunk.read(blob, M.MAGIC)) do
    if c.tag == "OWNR" and c.version == 1 then
      local schema, owner = string.unpack("<I4s4", c.payload)
      if owner ~= "cosmic2d" then error("foreign owner " .. owner, 0) end
      return schema
    end
  end
  error("owner marker has no supported OWNR chunk", 0)
end

local function publish(root, fail)
  pal.mkdir(M.dir(root))
  return pal.write_file_atomic(M.path(root), M.encode(), fail)
end

-- Remove only rebuildable rewind history. session/journal are deliberately
-- outside this operation: clearing them could destroy the only copy of an
-- unsaved edit. Returns true,count or nil,error.
function M.clear(root, fail)
  local dir = M.dir(root) .. "/history"
  local count, errors = 0, {}
  for _, name in ipairs(pal.list_dir(dir) or {}) do
    if not pal.x_remove(dir .. "/" .. name) then
      errors[#errors + 1] = name
    else
      count = count + 1
    end
  end
  if #errors > 0 then
    return nil, "could not remove " .. table.concat(errors, ", ")
  end
  local ok, err = publish(root, fail)
  if not ok then return nil, "owner marker: " .. tostring(err) end
  return true, count
end

-- Missing marker means the pre-contract layout and is adopted in place.
-- Corrupt markers make derived history untrustworthy, so it is rebuilt while
-- working recovery is retained. Newer/foreign ownership is refused: an older
-- editor must not downgrade data it cannot understand. The explicit clear()
-- door is the user's opt-in downgrade operation.
function M.prepare(root, fail)
  local blob = pal.read_file(M.path(root))
  if not blob then
    local ok, err = publish(root, fail and fail.marker)
    if not ok then return nil, "CACHE OWNER WRITE FAILED: " .. tostring(err) end
    return true
  end
  local ok, schema = pcall(M.decode, blob)
  if ok and schema == M.SCHEMA then return true end

  if ok then
    return nil, "CACHE SCHEMA " .. tostring(schema) .. " IS NEWER THAN " ..
                tostring(M.SCHEMA) .. "; preserved .ed; use " ..
                "cm.ed.clear_cache() to rebuild derived history deliberately"
  end
  if tostring(schema):find("foreign owner", 1, true) then
    return nil, "CACHE OWNERSHIP REFUSED: " .. tostring(schema) ..
                "; preserved .ed"
  end

  local why = "unreadable owner marker (" .. tostring(schema) .. ")"
  local cleared, n = M.clear(root, fail and fail.marker)
  if not cleared then return nil, "CACHE REBUILD FAILED after " .. why .. ": " .. n end
  return true, "rebuilt derived .ed cache after " .. why ..
               "; preserved session and journals; removed " .. n .. " files"
end

return M
