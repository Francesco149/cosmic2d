-- cm.palette — the .pal asset codec + palette helpers (the color window).
--
-- A palette is an ordered list of colors (cm.paint packing, R low byte).
-- Games reference one by loading it (M.load / M.color); the palette
-- window designs + saves it; the canvas eyedropper can sample its
-- swatches straight off the screen (no special wiring — that IS the
-- "pick from the canvas color picker" integration).
--
-- CPAL container (cm.chunk idiom, unknown tags skipped):
--   HEAD v1: <s1 name>
--   COLS v1: <u16 count> then count × <u32 rgba>
--
-- doc = { name = "sunset", colors = { rgba, rgba, ... } }
--
-- The ramp generator (M.ramp) is the signature design tool — it bakes
-- the pixel-art color principles (docs research): a value spread with
-- hue-shift toward warm highlights / cool shadows and a saturation bell.

local M = select(2, ...) or {}
local chunk = cm.require("cm.chunk")

M.MAGIC = "CPAL"
M.MAX = 256

function M.fresh(name)
  -- a small hue-shifted starter ramp so a new palette isn't blank
  return { name = name or "palette",
           colors = { 0x1a1420ff, 0x3b2a44ff, 0x6b4a6eff, 0xa87ba0ff,
                      0xd8b9c8ff, 0xf4e6d8ff } }
end

-- ---- codec ----

function M.encode(doc)
  local w = chunk.writer(M.MAGIC)
  w.chunk("HEAD", 1, string.pack("<s1", doc.name or ""))
  local cols = doc.colors or {}
  local n = math.min(#cols, M.MAX)
  local parts = { string.pack("<I2", n) }
  for i = 1, n do parts[i + 1] = string.pack("<I4", cols[i] & 0xffffffff) end
  w.chunk("COLS", 1, table.concat(parts))
  return w.result()
end

function M.decode(bytes)
  local chunks = chunk.read(bytes, M.MAGIC)
  local doc = { name = "", colors = {} }
  for _, c in ipairs(chunks) do
    if c.tag == "HEAD" and c.version == 1 then
      doc.name = string.unpack("<s1", c.payload)
    elseif c.tag == "COLS" and c.version == 1 then
      local n, off = string.unpack("<I2", c.payload)
      for i = 1, n do
        local v
        v, off = string.unpack("<I4", c.payload, off)
        doc.colors[i] = v
      end
    end
  end
  return doc
end

-- ---- the code-facing door (games reference a palette) ----

local pcache = {}
-- load a .pal → its doc (colors are cm.paint-packed, ready for pal.quad
-- etc). Cached, keyed by path + asset epoch (a save in the editor
-- invalidates live). Returns nil if unreadable.
function M.load(path)
  local ep = cm.asset_epoch or 0
  local ent = pcache[path]
  if ent and ent.ep == ep then return ent.doc end
  local bytes = pal.read_file(path)
  if not bytes then return nil end
  local ok, doc = pcall(M.decode, bytes)
  if not ok then return nil end
  pcache[path] = { doc = doc, ep = ep }
  return doc
end

-- color #i (1-based) of a palette, or a fallback (default opaque white)
function M.color(path, i, fallback)
  local d = M.load(path)
  local c = d and d.colors[i]
  return c or fallback or 0xffffffff
end

-- ---- hex import / export (Lospec .hex: RRGGBB per line) ----

function M.parse_hex(s)
  local paint = cm.require("cm.paint")
  local out = {}
  for tok in s:gmatch("[0-9a-fA-F]+") do
    if #tok == 6 or #tok == 8 then
      local r = tonumber(tok:sub(1, 2), 16)
      local g = tonumber(tok:sub(3, 4), 16)
      local b = tonumber(tok:sub(5, 6), 16)
      local a = #tok == 8 and tonumber(tok:sub(7, 8), 16) or 255
      out[#out + 1] = paint.pack(r, g, b, a)
    end
  end
  return out
end

function M.to_hex(colors)
  local paint = cm.require("cm.paint")
  local lines = {}
  for _, c in ipairs(colors) do
    local r, g, b = paint.unpack(c)
    lines[#lines + 1] = string.format("%02x%02x%02x", r, g, b)
  end
  return table.concat(lines, "\n")
end

-- ---- the ramp generator (the signature design tool) ----

local function clamp01(x) return x < 0 and 0 or (x > 1 and 1 or x) end

-- generate n colors dark→light from a base color, applying the pixel-art
-- principles: value spread + per-step hue shift (toward warm as it
-- lightens — SLYNYRD's +deg/step) + a saturation bell (peak mid, taper
-- ends). opts: { hue_shift = deg/step (default 12; sign flips direction),
-- sat_bell = 0..1 (default .35), dark = 0..1 low value factor,
-- light = 0..1 high reach }. Pure, dev-class float (KAT'd).
function M.ramp(base, n, opts)
  local paint = cm.require("cm.paint")
  opts = opts or {}
  n = math.max(2, math.floor(n or 5))
  local hstep = (opts.hue_shift or 12) / 360
  local bell = opts.sat_bell or 0.35
  local h, s, v = paint.to_hsv(base)
  local vlo = v * (opts.dark or 0.38)
  local vhi = math.min(1, v + (1 - v) * (opts.light or 0.85))
  local mid = (n - 1) / 2
  local out = {}
  for i = 0, n - 1 do
    local t = i / (n - 1)
    local vi = vlo + (vhi - vlo) * t
    local hi = (h + hstep * (i - mid)) % 1
    local d = 2 * t - 1
    local si = clamp01(s * (1 - bell * d * d))
    out[i + 1] = paint.hsv(hi, si, vi, 255)
  end
  return out
end

return M
