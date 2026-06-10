-- pt.repl — the deterministic console-eval path (D022). Console (or game
-- code) submits command strings; pt.main drains the queue at the START of
-- the next sim frame, before input applies. When a trace is recording,
-- drained commands are written as EVAL records, and trace verify re-executes
-- them through the same M.exec at the same point — so a live knob-tweaking
-- session stays byte-replayable, console pokes included.
--
-- Determinism notes: a command runs against live sim state and may do
-- anything game code could (use pt.rand, create buffers, error). All of
-- that replays exactly. What does NOT travel in a trace is this module's
-- dev-side state (queue, history, the env table for `x = 5` assignments):
-- commands recorded mid-session that READ env variables set before
-- recording started will diverge on verify. For verify-clean traces, put
-- state in the doc tree, not in repl locals.
--
-- exec env: reads fall through to _G plus sugar (doc = pt.state.doc,
-- game = the running entry module); bare assignments land in the env table,
-- so a stray `state = 5` can't clobber engine globals.

local M = select(2, ...) or {}

M.queue = M.queue or {}
M.history = M.history or {} -- newest last; console arrows walk it

local HISTORY_MAX = 100

M.env = M.env or setmetatable({}, {
  __index = function(_, k)
    if k == "doc" then return pt.state.doc end
    if k == "game" then return pt.main.game end
    return _G[k]
  end,
})

-- queue a command for the next sim frame (the recordable path)
function M.submit(s)
  s = s:match("^%s*(.-)%s*$")
  if #s == 0 then return end
  M.queue[#M.queue + 1] = s
  if M.history[#M.history] ~= s then
    M.history[#M.history + 1] = s
    if #M.history > HISTORY_MAX then table.remove(M.history, 1) end
  end
end

-- execute one command now. The SAME function runs live (via drain) and
-- during trace verify (EVAL records) — that symmetry is the whole point.
-- Expression results echo as "= v"; errors are caught and echo as "! err".
function M.exec(s)
  pal.log("> " .. s)
  local fn = load("return " .. s, "@repl", "t", M.env)
  if not fn then
    local err
    fn, err = load(s, "@repl", "t", M.env)
    if not fn then
      pal.log("! " .. tostring(err))
      return false
    end
  end
  local res = table.pack(pcall(fn))
  if not res[1] then
    pal.log("! " .. tostring(res[2]))
    return false
  end
  if res.n > 1 then
    local parts = {}
    for i = 2, res.n do parts[#parts + 1] = tostring(res[i]) end
    pal.log("= " .. table.concat(parts, ", "))
  end
  return true
end

-- run + clear the queue; returns the executed commands (nil when idle) so
-- the recorder can write them as this frame's EVAL record
function M.drain()
  if #M.queue == 0 then return nil end
  local cmds = M.queue
  M.queue = {}
  for _, s in ipairs(cmds) do M.exec(s) end
  return cmds
end

return M
