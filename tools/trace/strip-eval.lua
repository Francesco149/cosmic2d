-- tools/trace/strip-eval.lua <in.ctrace> <out.ctrace> — host-side (plain
-- lua): rewrite a CTRC container without its EVAL chunks. Only for evals
-- that are inert under verify (a guarded re-cut driver arm — see
-- replay-driver.lua); stripping a sim-affecting eval breaks the trace.
local f = assert(io.open(arg[1], "rb")); local blob = f:read("a"); f:close()
assert(blob:sub(1,4) == "CTRC")
local pos, out, dropped = 5, { "CTRC" }, 0
while pos <= #blob do
  local hdr = blob:sub(pos, pos + 11)
  local tag = blob:sub(pos, pos + 3)
  local version, len; version, len, pos = string.unpack("<I4I4", blob, pos + 4)
  local payload = blob:sub(pos, pos + len - 1)
  pos = pos + len
  if tag == "EVAL" then dropped = dropped + 1
  else out[#out + 1] = hdr .. payload end
end
local o = assert(io.open(arg[2], "wb"))
o:write(table.concat(out)); o:close()
print("dropped " .. dropped .. " EVAL chunk(s)")
