-- cm.recent — the engine-root .recent.dat project list.
-- The list is convenience metadata, but a failed update must remain visible
-- and must never truncate the last usable list.

local M = select(2, ...) or {}

M.path = ".recent.dat"
M.CAP = 12

function M.note(path, fail)
  local lines = { path }
  local seen = { [path] = true }
  local old = pal.read_file(M.path)
  if old then
    for line in old:gmatch("[^\n]+") do
      if not seen[line] and #lines < M.CAP then
        seen[line] = true
        lines[#lines + 1] = line
      end
    end
  end
  return pal.write_file_atomic(M.path, table.concat(lines, "\n"), fail)
end

function M.remove(path, fail)
  local lines = {}
  local old = pal.read_file(M.path) or ""
  for line in old:gmatch("[^\n]+") do
    if line ~= path then lines[#lines + 1] = line end
  end
  return pal.write_file_atomic(M.path, table.concat(lines, "\n"), fail)
end

return M
