-- cm.ed.session — session.dat: the editor doc's cross-restart persistence
-- (EDITOR.md §2). One CEDS chunk container wrapping the ed-doc canon bytes;
-- saved on a 400 ms debounce after any doc mutation (teidraw's autosave
-- shape), loaded at --edit boot. This file is what makes layout + unsaved
-- work survive a restart. Lives under <project>/.ed/ (untracked).

local M = select(2, ...) or {}
local chunk = cm.require("cm.chunk")
local state = cm.require("cm.state")

M.DEBOUNCE_NS = 400 * 1000000
local MAGIC = "CEDS"

function M.dir(root) return root .. "/.ed" end
function M.path(root) return M.dir(root) .. "/session.dat" end
function M.good_path(root) return M.dir(root) .. "/session.dat.good" end

function M.encode(doc)
  local w = chunk.writer(MAGIC)
  w.chunk("DOCB", 1, state.canon(doc))
  return w.result()
end

function M.decode(blob)
  local chunks = chunk.read(blob, MAGIC)
  for _, c in ipairs(chunks) do
    if c.tag == "DOCB" and c.version == 1 then
      local doc = state.parse(c.payload)
      if type(doc) ~= "table" then error("session doc is not a table", 0) end
      return doc
    end
  end
  error("session has no DOCB chunk", 0)
end

function M.save(root, doc, fail)
  pal.mkdir(M.dir(root))
  local blob = M.encode(doc)
  local ok, err = pal.write_file_atomic(M.good_path(root), blob,
                                        fail and fail.good)
  if not ok then return nil, "last-known-good: " .. tostring(err) end
  ok, err = pal.write_file_atomic(M.path(root), blob, fail and fail.live)
  if not ok then return nil, "live session: " .. tostring(err) end
  return true
end

local function decode_file(path)
  local blob, err = pal.read_file(path)
  if not blob then return nil, err end
  local ok, doc = pcall(M.decode, blob)
  if ok then return doc end
  return nil, doc
end

-- Returns doc [, recovery_message]. A damaged live file falls back to the
-- separately atomically-maintained last-known-good copy.
function M.load(root)
  local doc, err = decode_file(M.path(root))
  if doc then return doc end
  local good, good_err = decode_file(M.good_path(root))
  if good then
    return good, "session.dat unreadable (" .. tostring(err) ..
                 "); restored session.dat.good"
  end
  -- A genuinely absent session is the normal first-run case.
  if pal.read_file(M.path(root)) == nil and
     pal.read_file(M.good_path(root)) == nil then return nil end
  return nil, "session metadata unreadable (live: " .. tostring(err) ..
              "; backup: " .. tostring(good_err) .. "); starting fresh"
end

return M
