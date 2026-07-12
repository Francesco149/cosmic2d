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

function M.save(root, doc)
  pal.mkdir(M.dir(root))
  return pal.write_file(M.path(root), M.encode(doc))
end

-- nil when there is no session yet; errors loudly on a corrupt one are
-- contained by the caller (a broken session file should not brick --edit)
function M.load(root)
  local blob = pal.read_file(M.path(root))
  if not blob then return nil end
  local ok, doc = pcall(M.decode, blob)
  if not ok then
    pal.log("[ed] session.dat unreadable (" .. tostring(doc) .. "); fresh")
    return nil
  end
  return doc
end

return M
