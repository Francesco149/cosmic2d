-- cm.recent — the engine-root .recent.dat project list.
-- The list is convenience metadata, but a failed update must remain visible
-- and must never truncate the last usable list.

local M = select(2, ...) or {}

M.path = ".recent.dat"
M.CAP = 12

local function canonical(path)
  return cm.require("cm.project").normalize_root(path)
end

local function prior(exclude)
  local lines, seen = {}, {}
  for path in pairs(exclude or {}) do seen[path] = true end
  for raw in (pal.read_file(M.path) or ""):gmatch("[^\n]+") do
    local line = canonical(raw)
    if line and not seen[line] and #lines < M.CAP then
      seen[line] = true
      lines[#lines + 1] = line
    end
  end
  return lines
end

local function publish(lines, fail)
  return pal.write_file_atomic(M.path, table.concat(lines, "\n"), fail)
end

function M.note(path, fail)
  path = canonical(path)
  if not path then return nil, "invalid recent project path" end
  local lines = { path }
  for _, line in ipairs(prior({ [path] = true })) do
    if #lines >= M.CAP then break end
    lines[#lines + 1] = line
  end
  return publish(lines, fail)
end

function M.remove(path, fail)
  path = canonical(path)
  if not path then return nil, "invalid recent project path" end
  return publish(prior({ [path] = true }), fail)
end

-- Repair a stale entry in one atomic generation: the replacement becomes the
-- most recent project, the dead spelling disappears, and any prior occurrence
-- of the new spelling is deduplicated. A failed write leaves the old repair
-- target discoverable for a retry.
function M.replace(path, replacement, fail)
  path, replacement = canonical(path), canonical(replacement)
  if not path or not replacement then
    return nil, "invalid recent project path"
  end
  local lines = { replacement }
  for _, line in ipairs(prior({ [path] = true, [replacement] = true })) do
    if #lines >= M.CAP then break end
    lines[#lines + 1] = line
  end
  return publish(lines, fail)
end

return M
