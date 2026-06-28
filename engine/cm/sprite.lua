-- cm.sprite — the studio's sprite DOCUMENT: the layered/animated model, the
-- .spr on-disk format (cm.chunk container), baking to the strip atlas the game
-- draws, and undo via the frozen pal.buf_delta1 codec (M10, D040, STUDIO.md §3/§4).
--
-- Determinism class: dev/render ONLY. A sprite is a render-only asset, never sim
-- state — every buffer here is anonymous (pal.buf(nil,…)), so nothing is named,
-- snapshot, or recorded. The game consumes only the BAKED output (a PNG strip
-- loaded at boot like any texture); this module's authoring half is the studio's.
--
-- A document:
--   { name, w, h, frames, palette={rgba…},
--     layers = { { name, opacity=0..255, hidden, locked, cells={img per frame} } },
--     clips  = { … },                 -- animation (Phase 4)
--     pivot  = {x,y},                  -- in-game origin
--     -- runtime-only (never serialized): cur_layer, cur_frame, path, dirty,
--     --   _undo/_redo/_scratch }
-- A cell is a cm.paint image ({w,h,buf}); layers are bottom→top.

local M = select(2, ...) or {}

local paint = cm.require("cm.paint")
local chunk = cm.require("cm.chunk")
local pack, unpack = string.pack, string.unpack

-- A small cozy default palette nodding at the art direction (GAME.md §10): the
-- white/gold bodysuit + cyan accent, soft skins, a few neutrals + ink. Truecolor
-- swatches, not an index constraint (D040). Transparent is the canvas, not a slot.
local DEF = {
  { 0, 0, 0 }, { 32, 28, 44 }, { 64, 60, 84 }, { 120, 124, 148 },
  { 198, 202, 220 }, { 246, 248, 252 }, -- ink → white ramp
  { 247, 219, 188 }, { 214, 160, 134 }, { 150, 98, 92 }, -- skins
  { 236, 232, 245 }, { 150, 156, 196 }, -- suit white + shadow
  { 108, 220, 250 }, { 64, 150, 210 }, -- cyan accents
  { 248, 214, 122 }, { 206, 152, 70 }, -- gold
  { 122, 200, 142 }, { 210, 110, 120 }, -- a green + a rose
}

function M.default_palette()
  local p = {}
  for i, c in ipairs(DEF) do p[i] = paint.pack(c[1], c[2], c[3], 255) end
  return p
end

local function new_layer(name, w, h, frames)
  local cells = {}
  for f = 1, frames do cells[f] = paint.image(w, h) end -- transparent
  return { name = name, opacity = 255, hidden = false, locked = false, cells = cells }
end

-- a blank document: one transparent layer, one frame, the default palette.
function M.new(w, h, opts)
  opts = opts or {}
  local doc = {
    name = opts.name or "untitled",
    w = w, h = h, frames = 1,
    palette = opts.palette or M.default_palette(),
    layers = { new_layer("layer 1", w, h, 1) },
    clips = {}, pivot = { x = w // 2, y = h - 1 },
    cur_layer = 1, cur_frame = 1, dirty = false,
    _undo = {}, _redo = {},
  }
  return doc
end

function M.cell(doc, li, fi)
  local l = doc.layers[li or doc.cur_layer]
  return l and l.cells[fi or doc.cur_frame]
end

-- ---- structure ops ----

function M.add_layer(doc, name)
  local l = new_layer(name or ("layer " .. (#doc.layers + 1)), doc.w, doc.h, doc.frames)
  doc.layers[#doc.layers + 1] = l
  doc.cur_layer = #doc.layers
  doc.dirty = true
  return l
end

-- ---- compositing + bake ----

-- flatten the VISIBLE layers of one frame into `out` (a w*h image), bottom→top,
-- honoring per-layer opacity. out is cleared first. This is what the canvas
-- previews and what bake lays into the strip.
function M.composite_into(doc, fi, out)
  paint.fill(out, 0)
  for _, l in ipairs(doc.layers) do
    if not l.hidden and l.opacity > 0 then
      local cell = l.cells[fi]
      if l.opacity >= 255 then
        for i = 0, doc.w * doc.h - 1 do
          local c = cell.buf:u32(i * 4)
          if (c >> 24) ~= 0 then paint.over(out, i % doc.w, i // doc.w, c) end
        end
      else
        for i = 0, doc.w * doc.h - 1 do
          local c = cell.buf:u32(i * 4)
          local a = (c >> 24) & 255
          if a ~= 0 then
            a = a * l.opacity // 255
            paint.over(out, i % doc.w, i // doc.w,
                       (c & 0x00ffffff) | (a << 24))
          end
        end
      end
    end
  end
  return out
end

-- bake every frame into one horizontal strip image (frames cells laid L→R) —
-- the exact convention the game draws (player.lua build_sprite). Returns the
-- strip image; callers take strip.buf:str(...) for a texture / PNG.
function M.bake_image(doc)
  local strip = paint.image(doc.w * doc.frames, doc.h)
  local tmp = paint.image(doc.w, doc.h)
  for f = 1, doc.frames do
    M.composite_into(doc, f, tmp)
    paint.blit(strip, (f - 1) * doc.w, 0, tmp, 0, 0, doc.w, doc.h, "set")
  end
  return strip
end

-- ---- the .spr container (CSPR; rides cm.chunk, skip-tolerant) ----

local function layer_flags(l)
  return (l.hidden and 1 or 0) | (l.locked and 2 or 0)
end

function M.encode(doc)
  local w = chunk.writer("CSPR")
  w.chunk("HEAD", 1, pack("<I4I4I4I4I4i4i4s2",
    doc.w, doc.h, doc.frames, #doc.layers, 0,
    doc.pivot.x, doc.pivot.y, doc.name))
  local pal = { pack("<I4", #doc.palette) }
  for _, c in ipairs(doc.palette) do pal[#pal + 1] = pack("<I4", c) end
  w.chunk("PALT", 1, table.concat(pal))
  local cellbytes = doc.w * doc.h * 4
  for _, l in ipairs(doc.layers) do
    local parts = { pack("<s2I1I1", l.name, l.opacity, layer_flags(l)) }
    for f = 1, doc.frames do parts[#parts + 1] = l.cells[f].buf:str(0, cellbytes) end
    w.chunk("LAYR", 1, table.concat(parts))
  end
  -- CLIP is written in Phase 4; TAIL is the integrity check
  w.chunk("TAIL", 1, pack("<I4I4", #doc.layers, doc.frames))
  return w.result()
end

function M.decode(blob)
  local chunks = chunk.read(blob, "CSPR")
  local doc, li = nil, 0
  local cellbytes
  for _, c in ipairs(chunks) do
    if c.tag == "HEAD" and c.version == 1 then
      local w, h, frames, _, _, px, py, name = unpack("<I4I4I4I4I4i4i4s2", c.payload)
      doc = M.new(w, h, { name = name })
      doc.frames = frames
      doc.layers = {} -- HEAD declares the count; LAYR chunks fill them in order
      doc.pivot = { x = px, y = py }
      cellbytes = w * h * 4
    elseif c.tag == "PALT" and c.version == 1 and doc then
      local n, pos = unpack("<I4", c.payload)
      doc.palette = {}
      for i = 1, n do doc.palette[i], pos = unpack("<I4", c.payload, pos) end
    elseif c.tag == "LAYR" and c.version == 1 and doc then
      li = li + 1
      local name, opacity, flags, pos = unpack("<s2I1I1", c.payload)
      local l = { name = name, opacity = opacity,
                  hidden = (flags & 1) ~= 0, locked = (flags & 2) ~= 0, cells = {} }
      for f = 1, doc.frames do
        local img = paint.image(doc.w, doc.h)
        img.buf:setstr(0, c.payload:sub(pos, pos + cellbytes - 1))
        l.cells[f] = img
        pos = pos + cellbytes
      end
      doc.layers[li] = l
    end
    -- unknown tags/versions skipped (forward-compatible by rule)
  end
  if not doc then error("not a CSPR sprite document", 0) end
  if #doc.layers == 0 then doc.layers = { new_layer("layer 1", doc.w, doc.h, doc.frames) } end
  doc.cur_layer = math.min(doc.cur_layer or 1, #doc.layers)
  doc._undo, doc._redo = {}, {}
  return doc
end

-- ---- disk IO (dev/asset class: boot-time-or-explicit, never sim input) ----

local function with_ext(path, ext)
  return (path:gsub("%.spr$", "")) .. ext
end

-- write <path>.spr (source) + bake <path>.png (the strip the game loads). The
-- caller (studio) ensures the art dir exists. Returns true, or nil+err.
function M.save(doc, path)
  if not path:match("%.spr$") then path = path .. ".spr" end
  if not pal.write_file(path, M.encode(doc)) then return nil, "write .spr failed" end
  local strip = M.bake_image(doc)
  pal.png_write(with_ext(path, ".png"), strip.buf:str(0, strip.w * strip.h * 4),
                strip.w, strip.h)
  doc.path, doc.dirty = path, false
  return true
end

function M.load(path)
  local bytes, err = pal.read_file(path)
  if not bytes then return nil, err or "no file" end
  local ok, doc = pcall(M.decode, bytes)
  if not ok then return nil, doc end
  doc.path = path
  doc.name = (path:gsub(".*/", ""):gsub("%.spr$", ""))
  return doc
end

-- ---- undo / redo (per-stroke, via the frozen sparse-XOR codec) ----
-- begin_edit snapshots the target cell; end_edit diffs it and pushes one step.
-- A delta is its own inverse (XOR), so undo applies it (→ before) and redo
-- applies it again (→ after). Structural ops get coarse snapshots later (Ph2).

function M.begin_edit(doc, li, fi)
  li, fi = li or doc.cur_layer, fi or doc.cur_frame
  local cell = M.cell(doc, li, fi)
  local n = doc.w * doc.h * 4
  doc._scratch = doc._scratch or pal.buf(nil, n)
  doc._scratch:copy(0, cell.buf, 0, n)
  doc._edit = { li = li, fi = fi }
end

function M.end_edit(doc)
  local e = doc._edit
  if not e then return end
  doc._edit = nil
  local cell = M.cell(doc, e.li, e.fi)
  local delta = pal.buf_delta1(doc._scratch, cell.buf)
  if #delta == 0 then return end -- no actual change
  doc._undo[#doc._undo + 1] = { li = e.li, fi = e.fi, delta = delta }
  doc._redo = {}
  doc.dirty = true
end

function M.can_undo(doc) return #doc._undo > 0 end
function M.can_redo(doc) return #doc._redo > 0 end

function M.undo(doc)
  local e = doc._undo[#doc._undo]
  if not e then return false end
  doc._undo[#doc._undo] = nil
  pal.buf_apply_delta1(M.cell(doc, e.li, e.fi).buf, e.delta)
  doc._redo[#doc._redo + 1] = e
  doc.cur_layer, doc.cur_frame, doc.dirty = e.li, e.fi, true
  return true
end

function M.redo(doc)
  local e = doc._redo[#doc._redo]
  if not e then return false end
  doc._redo[#doc._redo] = nil
  pal.buf_apply_delta1(M.cell(doc, e.li, e.fi).buf, e.delta)
  doc._undo[#doc._undo + 1] = e
  doc.cur_layer, doc.cur_frame, doc.dirty = e.li, e.fi, true
  return true
end

return M
