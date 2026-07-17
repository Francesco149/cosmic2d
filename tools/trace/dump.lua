-- tools/trace/dump.lua <trace> — host-side (plain lua) CTRC survey:
-- chunk census, frame count, EVAL texts, and a per-frame input record
-- summary (bits/mouse/PAD) printed only where the state changes. The
-- re-cut honesty check diffs this output between old and new traces
-- (see replay-driver.lua).
local path = arg[1]
local f = assert(io.open(path, "rb"))
local blob = f:read("a")
f:close()
assert(blob:sub(1, 4) == "CTRC", "not a CTRC container")

local pos = 5
local census, frames, evals = {}, {}, {}
local nchunk = 0
while pos <= #blob do
  local tag = blob:sub(pos, pos + 3)
  local version, len
  version, len, pos = string.unpack("<I4I4", blob, pos + 4)
  local payload = blob:sub(pos, pos + len - 1)
  pos = pos + len
  nchunk = nchunk + 1
  census[tag] = (census[tag] or 0) + 1
  if tag == "FRAM" then
    local rec = string.unpack("<s4", payload)
    frames[#frames + 1] = rec
  elseif tag == "EVAL" then
    local n, p = string.unpack("<I4", payload)
    local cmds = {}
    for i = 1, n do
      local c
      c, p = string.unpack("<s4", payload, p)
      cmds[#cmds + 1] = c
    end
    evals[#evals + 1] = { after_frame = #frames, cmds = cmds }
  end
end

io.write("chunks:")
for t, n in pairs(census) do io.write(" ", t, "=", n) end
io.write("\nframes: ", #frames, "\n")
for _, e in ipairs(evals) do
  io.write("EVAL after frame ", e.after_frame, ": ",
           table.concat(e.cmds, " || "), "\n")
end

-- decode records: v1 + extensions; print one line per frame where the
-- decoded state CHANGES (and the first frame), plus a mouse/extension audit
local prev
local pad_frames, first_pad = 0, nil
for i, rec in ipairs(frames) do
  local bits, mx, my, mbtn, wheel = string.unpack("<I4i2i2Bb", rec)
  local p = 11
  local ext = {}
  while p <= #rec do
    local tag, len = string.unpack("BB", rec, p)
    local payload = rec:sub(p + 2, p + 1 + len)
    p = p + 2 + len
    ext[tag] = payload
  end
  local desc = { ("bits=%08x"):format(bits) }
  if mx ~= 0 or my ~= 0 or mbtn ~= 0 or wheel ~= 0 then
    desc[#desc + 1] = ("mouse=%d,%d,%02x,%d"):format(mx, my, mbtn, wheel)
  end
  if ext[1] then
    pad_frames = pad_frames + 1
    first_pad = first_pad or i
    local n, q = string.unpack("B", ext[1])
    for _ = 1, n do
      local slot, btn = string.unpack("<BI4", ext[1], q)
      q = q + 5
      local ax = {}
      for a = 1, 6 do
        ax[a], q = string.unpack("b", ext[1], q)
      end
      desc[#desc + 1] = ("pad%d=%08x|%d,%d,%d,%d,%d,%d")
        :format(slot + 1, btn, table.unpack(ax))
    end
    if n == 0 then desc[#desc + 1] = "pad-none" end
  end
  for t in pairs(ext) do
    if t ~= 1 then desc[#desc + 1] = ("ext%d!"):format(t) end
  end
  local line = table.concat(desc, " ")
  if line ~= prev then
    io.write(("f%5d %s\n"):format(i, line))
    prev = line
  end
end
io.write("pad-carrying frames: ", pad_frames, " (first ",
         tostring(first_pad), ")\n")
