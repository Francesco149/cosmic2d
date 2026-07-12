-- cm.ed.journal — the undo-forever journal (EDITOR.md §6): per-asset,
-- cross-session undo history. teidraw's undo.jsonl translated to the
-- house container: a CJRN chunk stream whose ENTR records are appended
-- over time (the cm.chunk format is append-friendly — magic, then chunks
-- until EOF — so appending one serialized record is a valid file).
--
--   ENTR v1 payload: <i64 wall-ms> <u8 flags (bit0 = was-saved)> <s4 bytes>
--
-- Entries are FULL snapshots of the asset's working bytes (teidraw's
-- shape: simple, debuggable; dedupe vs the tip, no deltas — ENTR v2 is
-- the R4 escape hatch if sprite docs need it). Linear history: editing
-- while rewound truncates the tail and rewrites the file (the branch
-- rule). The in-memory handle {path, entries, pos} is EPHEMERAL shell
-- state; the captured cursor lives in cm.ed.doc.assets[path].jpos.
--
-- Pure over byte strings + pal file I/O — selftested headless.

local M = select(2, ...) or {}
local chunk = cm.require("cm.chunk")

local pack, unpack = string.pack, string.unpack

M.CAP = 4096 -- max entries kept (teidraw's default), oldest dropped
M.MAGIC = "CJRN"
M.SAVED = 1 -- flags bit0: this entry was written to the real file

local function encode_entry(e)
  local payload = pack("<i8I1s4", e.t or 0, e.flags or 0, e.bytes)
  return "ENTR" .. pack("<I4I4", 1, #payload) .. payload
end

local function decode_entry(payload)
  local t, flags, bytes = unpack("<i8I1s4", payload)
  return { t = t, flags = flags, bytes = bytes }
end

-- the asset path -> journal file key ('/' -> '__', EDITOR.md §6)
function M.file(root, path)
  return root .. "/.ed/journal/" .. path:gsub("/", "__") .. ".jrn"
end

local function rewrite(j)
  local w = chunk.writer(M.MAGIC)
  for _, e in ipairs(j.entries) do
    -- writer.chunk re-frames; encode via the same shape for byte parity
    w.chunk("ENTR", 1, pack("<i8I1s4", e.t or 0, e.flags or 0, e.bytes))
  end
  pal.mkdir(j.dir)
  return pal.write_file(j.path, w.result())
end

-- open (or start) the journal for an asset. A corrupt file degrades to a
-- fresh journal with one log line — history is a convenience, never a boot
-- blocker. pos lands on the last entry (jpos, when given, re-parks it —
-- the session-restored cursor).
function M.open(root, asset_path, jpos)
  local j = {
    path = M.file(root, asset_path),
    dir = root .. "/.ed/journal",
    entries = {},
    pos = 0,
  }
  local blob = pal.read_file(j.path)
  if blob then
    local ok, chunks = pcall(chunk.read, blob, M.MAGIC)
    if ok then
      for _, c in ipairs(chunks) do
        if c.tag == "ENTR" and c.version == 1 then
          j.entries[#j.entries + 1] = decode_entry(c.payload)
        end
      end
    else
      pal.log("[ed] journal unreadable (" .. tostring(chunks) .. "): " ..
              j.path .. " — starting fresh")
    end
  end
  if #j.entries > M.CAP then -- over cap from an older, bigger cap
    local keep = {}
    for i = #j.entries - M.CAP + 1, #j.entries do keep[#keep + 1] = j.entries[i] end
    j.entries = keep
    rewrite(j)
  end
  j.pos = #j.entries
  if jpos and jpos >= 0 and jpos <= #j.entries then j.pos = jpos end
  return j
end

-- push the working bytes as a new entry (gesture end). Identical-to-tip
-- pushes are dropped; a push while rewound truncates the tail (branch =
-- rewrite, teidraw's rule); the cap drops the oldest (also a rewrite).
-- Returns true when an entry landed.
function M.push(j, bytes, flags, t)
  local tip = j.entries[j.pos]
  if tip and tip.bytes == bytes and (j.pos == #j.entries) then
    if flags and flags ~= tip.flags then -- e.g. a save marks the same text
      tip.flags = flags
      rewrite(j)
    end
    return false
  end
  local e = { t = t or 0, flags = flags or 0, bytes = bytes }
  if j.pos < #j.entries then
    for i = #j.entries, j.pos + 1, -1 do j.entries[i] = nil end
    j.entries[#j.entries + 1] = e
    j.pos = #j.entries
    rewrite(j)
    return true
  end
  j.entries[#j.entries + 1] = e
  j.pos = #j.entries
  if #j.entries > M.CAP then
    table.remove(j.entries, 1)
    j.pos = #j.entries
    rewrite(j)
    return true
  end
  if #j.entries == 1 then
    rewrite(j) -- first entry writes the container (magic + record)
  else
    pal.mkdir(j.dir)
    if not pal.x_file_append(j.path, encode_entry(e)) then
      rewrite(j) -- append failed (moved dir?): full rewrite recovers
    end
  end
  return true
end

function M.undo(j)
  if j.pos <= 1 then return nil end
  j.pos = j.pos - 1
  return j.entries[j.pos]
end

function M.redo(j)
  if j.pos >= #j.entries then return nil end
  j.pos = j.pos + 1
  return j.entries[j.pos]
end

function M.at(j)
  return j.entries[j.pos]
end

return M
