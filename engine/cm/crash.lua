-- cm.crash -- A2 diagnostics + the stable D065 crash handoff envelope.
--
-- Interactive processes keep a flushed plain-text PAL log in the platform's
-- per-user cosmic2d data directory. A contained game error or Lua parachute
-- additionally publishes a small atomic `.ccrash` container beside that log.
-- It names the exact project/history-stream/last-committed-frame tuple that a
-- future A7 crash-focus timeline will resolve; wall time is display metadata,
-- never identity.

local M = select(2, ...) or {}
local chunk = cm.require("cm.chunk")
local pack, unpack = string.pack, string.unpack

M.MAGIC = "CCRP"
M.SCHEMA = 1

local function integer(v, fallback)
  v = math.tointeger(v)
  return v == nil and fallback or v
end

local function encode_evals(evals)
  local parts = { pack("<I4", #(evals or {})) }
  for _, s in ipairs(evals or {}) do parts[#parts + 1] = pack("<s4", s) end
  return table.concat(parts)
end

local function decode_evals(blob)
  local n, pos = unpack("<I4", blob)
  local out = {}
  for i = 1, n do out[i], pos = unpack("<s4", blob, pos) end
  if pos ~= #blob + 1 then error("crash EVAL has trailing bytes", 0) end
  return out
end

function M.encode(o)
  o = o or {}
  local w = chunk.writer(M.MAGIC)
  -- HEAD v1 is the stable A7 locator envelope. Empty stream and -1 frames are
  -- explicit "unavailable" values (boot failure, non-durable/headless ring).
  w.chunk("HEAD", 1, pack("<s4s4s4s4i8i8I4s4s4",
    tostring(o.report_id or ""), tostring(o.project_path or ""),
    tostring(o.project_name or ""), tostring(o.history_stream or ""),
    integer(o.committed_frame, -1), integer(o.attempted_frame, -1),
    math.max(0, integer(o.code_epoch, 0)), tostring(o.error_kind or "unknown"),
    tostring(o.log_path or "")))
  w.chunk("TIME", 1, tostring(o.utc or ""))
  w.chunk("META", 1, pack("<s4s4I4I4s4",
    tostring(o.engine_version or ""), tostring(o.platform or ""),
    math.max(0, integer(o.pal_major, 0)), math.max(0, integer(o.pal_api, 0)),
    tostring(o.exe or "")))
  w.chunk("ERRO", 1, tostring(o.traceback or ""))
  if o.input_record ~= nil then
    w.chunk("INPT", 1, tostring(o.input_record))
  end
  if o.evals ~= nil then w.chunk("EVAL", 1, encode_evals(o.evals)) end
  if o.logs ~= nil then w.chunk("LOGS", 1, tostring(o.logs)) end
  -- A7 §16: the embedded history tail — a self-contained standalone-clip blob of
  -- the safe pre-roll. Additive, so a locator-only report (no tail) is byte-
  -- identical to before. Opened as a trust-gated crash clip on drop; when absent
  -- the drop falls back to matching the local recorded stream.
  if o.tail ~= nil and o.tail ~= "" then w.chunk("CLIP", 1, tostring(o.tail)) end
  return w.result()
end

function M.decode(blob)
  local out, saw_head = { evals = nil }, false
  for _, c in ipairs(chunk.read(blob, M.MAGIC)) do
    if c.tag == "HEAD" and c.version == 1 and not saw_head then
      saw_head = true
      out.report_id, out.project_path, out.project_name, out.history_stream,
        out.committed_frame, out.attempted_frame, out.code_epoch,
        out.error_kind, out.log_path =
          unpack("<s4s4s4s4i8i8I4s4s4", c.payload)
    elseif c.tag == "TIME" and c.version == 1 then
      out.utc = c.payload
    elseif c.tag == "META" and c.version == 1 then
      out.engine_version, out.platform, out.pal_major, out.pal_api, out.exe =
        unpack("<s4s4I4I4s4", c.payload)
    elseif c.tag == "ERRO" and c.version == 1 then
      out.traceback = c.payload
    elseif c.tag == "INPT" and c.version == 1 then
      out.input_record = c.payload
    elseif c.tag == "EVAL" and c.version == 1 then
      out.evals = decode_evals(c.payload)
    elseif c.tag == "LOGS" and c.version == 1 then
      out.logs = c.payload
    elseif c.tag == "CLIP" and c.version == 1 then
      out.tail = c.payload -- A7 §16: the embedded standalone-clip history tail
    end
  end
  if not saw_head then error("crash report has no supported HEAD chunk", 0) end
  return out
end

function M.read(path)
  local blob, err = pal.read_file(path)
  if not blob then return nil, err end
  local ok, report = pcall(M.decode, blob)
  if not ok then return nil, report end
  return report
end

-- The UI will expose/reveal this path later. It is never under the engine or
-- project tree, so read-only extracted artifacts can still diagnose failures.
function M.location()
  if pal.diagnostics_dir and pal.diagnostics_dir ~= "" then
    return pal.diagnostics_dir
  end
  if not pal.user_path then return nil, "PAL lacks per-user path support" end
  local root, err = pal.user_path()
  if not root then return nil, err end
  return root .. "diagnostics"
end

local function recent_logs()
  local out = {}
  for _, l in ipairs(pal.log_lines(0)) do
    out[#out + 1] = ("[pal %8.3f #%d] %s"):format(l.t, l.seq, l.text)
  end
  return table.concat(out, "\n")
end

local function unique_path(dir, stamp, log_path)
  M._seq = (M._seq or 0) + 1
  local n = M._seq
  -- Live log names contain the process ID. Carry it into the report filename
  -- so two engine processes failing in the same UTC second cannot race an
  -- existence check and replace each other's atomic report.
  local pid = tostring(log_path or ""):match(
    "process%-%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ%-(%d+)%.log$")
  local owner = pid and ("-" .. pid) or ""
  while true do
    local id = ("cr1-%s%s-%04d"):format(stamp, owner, n)
    local path = ("%s/crash-%s%s-%04d.ccrash"):format(dir, stamp, owner, n)
    if not pal.mtime(path) then return path, id end
    n = n + 1
    M._seq = n
  end
end

-- Publish a prepared report atomically. `_dir`, `_stamp`, and `_fail` are
-- explicit KAT seams; normal callers supply only the envelope fields.
function M.publish(o, test)
  o, test = o or {}, test or {}
  local dir, derr = test._dir or M.location()
  if not dir then return nil, "diagnostics location unavailable: " .. tostring(derr) end
  if not pal.mkdir(dir) then
    return nil, "create diagnostics directory failed: " .. dir
  end
  local stamp = test._stamp or os.date("!%Y%m%dT%H%M%SZ")
  local log_path = o.log_path or pal.log_path or ""
  local path, rid = unique_path(dir, stamp, log_path)
  o.report_id = o.report_id or rid
  o.utc = o.utc or stamp
  o.logs = o.logs == nil and recent_logs() or o.logs
  o.log_path = log_path
  o.engine_version = o.engine_version or
                     ((pal.read_file("VERSION") or ""):gsub("[%s]+$", ""))
  o.platform = o.platform or pal.platform or ""
  o.pal_major = o.pal_major or (pal.version and pal.version.major) or 0
  o.pal_api = o.pal_api or (pal.version and pal.version.api) or 0
  o.exe = o.exe or pal.exe or ""
  local ok, err = pal.write_file_atomic(path, M.encode(o), test._fail)
  if not ok then return nil, "write crash report failed: " .. tostring(err) end
  return path
end

-- Best-effort integration entry. It deliberately accepts partial main state:
-- the C parachute can call it while cm.main.boot is itself unwinding.
function M.capture(kind, traceback, context)
  context = context or {}
  local main = cm.main
  local locator
  if not context.no_locator and main and main.trace
     and main.trace.ring_locator then
    local ok, got = pcall(main.trace.ring_locator)
    if ok then locator = got end
  end
  -- A7 §16: when the ring named a durable tail, embed the safe pre-roll as a
  -- self-contained clip so a report opened on ANOTHER machine (or after the local
  -- tail is evicted) still carries its timeline. Best-effort: a legacy/spill-off/
  -- mid-unwind ring embeds nothing and the drop falls back to the local match.
  local tail
  if locator and locator.stream and locator.stream ~= ""
     and main and main.trace and main.trace.crash_tail_bytes then
    local ok, bytes = pcall(main.trace.crash_tail_bytes, locator.frame)
    if ok and type(bytes) == "string" and bytes ~= "" then tail = bytes end
  end
  local attempt = context.attempt or (main and main.attempt) or {}
  local project = main and main.args and main.args.project or ""
  local name = main and main.proj and main.proj.name or ""
  return M.publish({
    project_path = project,
    project_name = name,
    history_stream = locator and locator.stream or "",
    committed_frame = locator and locator.frame or -1,
    attempted_frame = context.attempted_frame or attempt.frame or -1,
    code_epoch = cm.code_epoch or 0,
    error_kind = kind or "unknown",
    traceback = traceback or "",
    input_record = attempt.input,
    evals = attempt.evals,
    tail = tail,
  }, context.test)
end

return M
