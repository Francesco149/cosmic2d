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
--     layers = { { name, opacity=0..255, hidden, locked, cells={img per frame},
--                  fill = nil | {type,p0,p1,stops,levels,dither,bayer,phase} } },
--     clips  = { … },                 -- animation (Phase 4)
--     pivot  = {x,y},                  -- in-game origin
--     -- runtime-only (never serialized): cur_layer, cur_frame, path, dirty,
--     --   _undo/_redo/_scratch/_shade/_struct }
-- A cell is a cm.paint image ({w,h,buf}); layers are bottom→top.
--
-- Gradient fills (Phase 3, STUDIO.md §6) are NON-DESTRUCTIVE: a fill is a small
-- editable object bound to a layer (layer.fill), re-rendered at composite/bake
-- time masked by that layer's per-frame alpha — the .spr keeps it live, bake
-- flattens it. Bound to the LAYER (not a doc-global fills[] keyed by index) so
-- it survives reorder/dup/delete for free; the FILL chunk carries the binding.

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

-- ---- structure ops (each one undoable via a coarse snapshot, STUDIO.md §3) ----

-- deep-copy a cell / layer so a snapshot is independent of the live doc.
local function clone_cell(src, w, h)
  local img = paint.image(w, h)
  img.buf:copy(0, src.buf, 0, w * h * 4)
  return img
end

-- deep-copy a layer's gradient fill (so a snapshot / dup is independent of the
-- live one — nested p0/p1/stops cloned). nil stays nil.
local function clone_fill(f)
  if not f then return nil end
  local stops = {}
  for i, s in ipairs(f.stops) do stops[i] = { pos = s.pos, rgba = s.rgba } end
  return { type = f.type, p0 = { x = f.p0.x, y = f.p0.y },
           p1 = { x = f.p1.x, y = f.p1.y }, stops = stops,
           levels = f.levels, dither = f.dither, bayer = f.bayer, phase = f.phase }
end

local function clone_layer(l, w, h, frames)
  local cells = {}
  for f = 1, frames do cells[f] = clone_cell(l.cells[f], w, h) end
  return { name = l.name, opacity = l.opacity, hidden = l.hidden,
           locked = l.locked, cells = cells, fill = clone_fill(l.fill) }
end

-- the whole structural state (the layer stack + frame count + cursors) as a
-- self-contained snapshot. Cell pixels are cloned, so it survives later edits.
local function capture_struct(doc)
  local layers = {}
  for i, l in ipairs(doc.layers) do layers[i] = clone_layer(l, doc.w, doc.h, doc.frames) end
  return { layers = layers, frames = doc.frames,
           cur_layer = doc.cur_layer, cur_frame = doc.cur_frame }
end

-- adopt a snapshot's layer stack (it is used exactly once then dropped, so no
-- clone needed — the doc takes ownership of the snapshot's buffers).
local function restore_struct(doc, snap)
  doc.layers = snap.layers
  doc.frames = snap.frames
  doc.cur_layer = math.min(snap.cur_layer or 1, #snap.layers)
  doc.cur_frame = math.min(snap.cur_frame or 1, snap.frames)
end

local UNDO_CAP = 64 -- dev memory; drop the oldest step past this (STUDIO.md §3)
local function trim_undo(doc)
  while #doc._undo > UNDO_CAP do table.remove(doc._undo, 1) end
end

-- wrap a structural mutation: capture `before` first, mutate, then commit.
local function push_struct(doc, before)
  doc._undo[#doc._undo + 1] = { kind = "struct", snap = before }
  doc._redo = {}
  doc.dirty = true
  trim_undo(doc)
end

function M.add_layer(doc, name)
  local before = capture_struct(doc)
  local l = new_layer(name or ("layer " .. (#doc.layers + 1)), doc.w, doc.h, doc.frames)
  doc.layers[#doc.layers + 1] = l
  doc.cur_layer = #doc.layers
  push_struct(doc, before)
  return l
end

-- duplicate a layer in place (its pixels copied), the copy sitting just above
-- the source and becoming the active layer.
function M.dup_layer(doc, li)
  li = li or doc.cur_layer
  local src = doc.layers[li]
  if not src then return end
  local before = capture_struct(doc)
  local cp = clone_layer(src, doc.w, doc.h, doc.frames)
  cp.name = src.name .. " copy"
  table.insert(doc.layers, li + 1, cp)
  doc.cur_layer = li + 1
  push_struct(doc, before)
  return cp
end

-- delete a layer (a document always keeps at least one).
function M.delete_layer(doc, li)
  li = li or doc.cur_layer
  if #doc.layers <= 1 then return end
  local before = capture_struct(doc)
  table.remove(doc.layers, li)
  doc.cur_layer = math.min(doc.cur_layer, #doc.layers)
  push_struct(doc, before)
end

-- move a layer in the draw order: dir +1 = UP (toward the top/front), -1 = down.
function M.move_layer(doc, li, dir)
  li = li or doc.cur_layer
  local ni = li + dir
  if ni < 1 or ni > #doc.layers then return end
  local before = capture_struct(doc)
  doc.layers[li], doc.layers[ni] = doc.layers[ni], doc.layers[li]
  doc.cur_layer = ni
  push_struct(doc, before)
end

-- ---- gradient fills (non-destructive; Phase 3, STUDIO.md §6) ----

-- A generic structural-undo bracket for a studio gesture that spans frames (e.g.
-- dragging a gradient axis live): begin captures `before`, commit pushes the one
-- step, cancel drops it. Use when a per-stroke delta bracket won't fit because
-- the mutation isn't a single cell edit.
function M.begin_struct(doc) doc._struct = capture_struct(doc) end
function M.commit_struct(doc)
  if doc._struct then push_struct(doc, doc._struct); doc._struct = nil end
end
function M.cancel_struct(doc) doc._struct = nil end

-- set / replace a layer's gradient fill (one undo step). Takes ownership of
-- `fill`. Pass nil via clear_fill, not here.
function M.set_fill(doc, li, fill)
  li = li or doc.cur_layer
  local l = doc.layers[li]
  if not l then return end
  local before = capture_struct(doc)
  l.fill = fill
  push_struct(doc, before)
end

function M.clear_fill(doc, li)
  li = li or doc.cur_layer
  local l = doc.layers[li]
  if not l or not l.fill then return end
  local before = capture_struct(doc)
  l.fill = nil
  push_struct(doc, before)
end

-- bake a layer's fill into its pixels (DESTRUCTIVE) and drop the fill object —
-- one undo step (a structural snapshot covers both the recolored pixels and the
-- removed fill). Recolors every frame's visible pixels by the same geometry.
function M.stamp_fill(doc, li)
  li = li or doc.cur_layer
  local l = doc.layers[li]
  if not l or not l.fill then return end
  local before = capture_struct(doc)
  for f = 1, doc.frames do paint.grad_fill(l.cells[f], l.fill, l.cells[f]) end
  l.fill = nil
  push_struct(doc, before)
end

-- the cell to composite for a layer+frame: the raw cell, or — if the layer has a
-- gradient fill — a shaded copy (the fill recolored over the cell's alpha) in a
-- per-doc reuse scratch. The shade is transient; the live pixels are untouched.
local function shaded_cell(doc, l, fi)
  local cell = l.cells[fi]
  if not l.fill then return cell end
  local s = doc._shade
  if not s or s.w ~= doc.w or s.h ~= doc.h then
    s = paint.image(doc.w, doc.h); doc._shade = s
  end
  paint.fill(s, 0)
  paint.grad_fill(s, l.fill, cell)
  return s
end

-- ---- compositing + bake ----

-- flatten the VISIBLE layers of one frame into `out` (a w*h image), bottom→top,
-- honoring per-layer opacity. out is cleared first. This is what the canvas
-- previews and what bake lays into the strip.
function M.composite_into(doc, fi, out)
  paint.fill(out, 0)
  for _, l in ipairs(doc.layers) do
    if not l.hidden and l.opacity > 0 then
      local cell = shaded_cell(doc, l, fi)
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

-- gradient-fill type <-> a stable u8 id for the FILL chunk
local FILL_TYPES = { "linear", "radial", "angular", "mirror" }
local FILL_TID = {}
for i, t in ipairs(FILL_TYPES) do FILL_TID[t] = i end

-- one fill record: layer index (the binding) + the def. Floats keep fractional
-- handle coords; spaces in the pack format are ignored (readability only).
local FILL_FMT = "<I4 I1 ffff ff I2 I1 I1"
local function encode_fill(idx, f)
  local parts = { pack(FILL_FMT, idx, FILL_TID[f.type] or 1,
    f.p0.x, f.p0.y, f.p1.x, f.p1.y, f.dither or 0, f.phase or 0,
    f.levels or 2, f.bayer or 4, #f.stops) }
  for _, s in ipairs(f.stops) do parts[#parts + 1] = pack("<fI4", s.pos, s.rgba) end
  return table.concat(parts)
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
  -- FILL: the non-destructive gradient fills (one record per layer that has one)
  local fills = {}
  for i, l in ipairs(doc.layers) do
    if l.fill then fills[#fills + 1] = encode_fill(i, l.fill) end
  end
  if #fills > 0 then
    w.chunk("FILL", 1, pack("<I4", #fills) .. table.concat(fills))
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
    elseif c.tag == "FILL" and c.version == 1 and doc then
      -- comes after the LAYR chunks (encode order), so the layers exist
      local nf, pos = unpack("<I4", c.payload)
      for _ = 1, nf do
        local idx, tid, p0x, p0y, p1x, p1y, dith, ph, lv, by, ns
        idx, tid, p0x, p0y, p1x, p1y, dith, ph, lv, by, ns, pos =
          unpack(FILL_FMT, c.payload, pos)
        local stops = {}
        for i = 1, ns do
          stops[i] = {}
          stops[i].pos, stops[i].rgba, pos = unpack("<fI4", c.payload, pos)
        end
        local l = doc.layers[idx]
        if l then
          l.fill = { type = FILL_TYPES[tid] or "linear",
                     p0 = { x = p0x, y = p0y }, p1 = { x = p1x, y = p1y },
                     stops = stops, dither = dith, phase = ph, levels = lv, bayer = by }
        end
      end
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
  trim_undo(doc)
end

function M.can_undo(doc) return #doc._undo > 0 end
function M.can_redo(doc) return #doc._redo > 0 end

-- apply one undo step (cell-delta or structural snapshot) and push its inverse
-- onto `dest` (the opposite stack). Shared by undo + redo (they are mirror
-- images: a delta is its own inverse; a snapshot swaps with the live state).
local function step_apply(doc, src, dest)
  local e = src[#src]
  if not e then return false end
  src[#src] = nil
  if e.kind == "struct" then
    local cur = capture_struct(doc)
    restore_struct(doc, e.snap)
    dest[#dest + 1] = { kind = "struct", snap = cur }
  else
    pal.buf_apply_delta1(M.cell(doc, e.li, e.fi).buf, e.delta)
    doc.cur_layer, doc.cur_frame = e.li, e.fi
    dest[#dest + 1] = e
  end
  doc.dirty = true
  return true
end

function M.undo(doc) return step_apply(doc, doc._undo, doc._redo) end
function M.redo(doc) return step_apply(doc, doc._redo, doc._undo) end

return M
