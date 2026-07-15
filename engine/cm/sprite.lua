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
local anim = cm.require("cm.anim")
local state = cm.require("cm.state")
local pack, unpack = string.pack, string.unpack

M.DEFAULT_DUR = 5 -- ticks per new clip frame (~12 fps at 60 Hz)

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
    clips = {}, slices = {}, pivot = { x = w // 2, y = h - 1 },
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

-- deep-copy the clip list (so a snapshot / undo is independent of the live one).
-- Clips are doc-level (not per-layer); frame ops rewrite refs, so they ride the
-- structural snapshot too — undoing a frame delete restores the clips it edited.
local function clone_clips(clips)
  local t = {}
  for i, c in ipairs(clips or {}) do
    local fr = {}
    for j, e in ipairs(c.frames) do fr[j] = { frame = e.frame, dur = e.dur } end
    t[i] = { name = c.name, loop = c.loop, frames = fr }
  end
  return t
end

-- deep-copy the slice list (named rects; doc-level, like clips) for snapshots/undo.
local function clone_slices(slices)
  local t = {}
  for i, s in ipairs(slices or {}) do
    t[i] = { name = s.name, x = s.x, y = s.y, w = s.w, h = s.h }
  end
  return t
end

-- the whole structural state (the layer stack + frame count + clips + cursors)
-- as a self-contained snapshot. Cell pixels + clips are cloned, so it survives
-- later edits.
local function capture_struct(doc)
  local layers = {}
  for i, l in ipairs(doc.layers) do layers[i] = clone_layer(l, doc.w, doc.h, doc.frames) end
  return { layers = layers, frames = doc.frames, clips = clone_clips(doc.clips),
           slices = clone_slices(doc.slices), w = doc.w, h = doc.h,
           pivot = { x = doc.pivot.x, y = doc.pivot.y },
           cur_layer = doc.cur_layer, cur_frame = doc.cur_frame }
end

-- adopt a snapshot's layer stack (it is used exactly once then dropped, so no
-- clone needed — the doc takes ownership of the snapshot's buffers).
local function restore_struct(doc, snap)
  if snap.w then doc.w, doc.h, doc._shade = snap.w, snap.h, nil end -- size rides undo (set_size)
  doc.layers = snap.layers
  doc.frames = snap.frames
  if snap.clips then doc.clips = snap.clips end
  if snap.slices then doc.slices = snap.slices end
  if snap.pivot then doc.pivot = snap.pivot end
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

-- add a layer WITHOUT pushing an undo step — for composed ops that bracket their
-- own struct snapshot (e.g. the studio's paste-into-a-new-layer, one undo step).
function M.raw_add_layer(doc, name)
  local l = new_layer(name or ("layer " .. (#doc.layers + 1)), doc.w, doc.h, doc.frames)
  doc.layers[#doc.layers + 1] = l
  doc.cur_layer = #doc.layers
  return l
end

function M.add_layer(doc, name)
  local before = capture_struct(doc)
  local l = M.raw_add_layer(doc, name)
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

-- ---- frames + clips (animation; Phase 4, STUDIO.md §7) ----
-- A frame is a column in the baked strip: every layer carries one cell per
-- frame (layer.cells[1..frames], 1-based), the gradient fill is shared across a
-- layer's frames. The CLIP frame index is 0-based (it indexes the strip the game
-- draws, like player.lua's f), so cells[k+1] is clip-frame k. Inserting after
-- 1-based position `at` lands the new frame at 0-based index `at` — that identity
-- is why the clip fixups below take `at` / `fi` directly.

local function clips_after_insert(doc, ins0) -- a new 0-based frame appeared at ins0
  for _, c in ipairs(doc.clips) do
    for _, e in ipairs(c.frames) do if e.frame >= ins0 then e.frame = e.frame + 1 end end
  end
end

local function clips_after_delete(doc, del0) -- 0-based frame del0 went away
  for _, c in ipairs(doc.clips) do
    local keep = {}
    for _, e in ipairs(c.frames) do
      if e.frame < del0 then keep[#keep + 1] = e
      elseif e.frame > del0 then e.frame = e.frame - 1; keep[#keep + 1] = e end
    end
    c.frames = keep -- entries pointing AT the deleted frame are dropped
  end
end

local function clips_after_swap(doc, a0, b0) -- 0-based frames a0,b0 traded places
  for _, c in ipairs(doc.clips) do
    for _, e in ipairs(c.frames) do
      if e.frame == a0 then e.frame = b0 elseif e.frame == b0 then e.frame = a0 end
    end
  end
end

-- insert a blank frame after 1-based position `at`, in every layer (one undo step)
function M.add_frame(doc, at)
  at = at or doc.cur_frame
  local before = capture_struct(doc)
  for _, l in ipairs(doc.layers) do table.insert(l.cells, at + 1, paint.image(doc.w, doc.h)) end
  doc.frames = doc.frames + 1
  clips_after_insert(doc, at) -- the new frame's 0-based index == at
  doc.cur_frame = at + 1
  push_struct(doc, before)
end

-- duplicate frame `fi` (its pixels copied) right after it, in every layer
function M.dup_frame(doc, fi)
  fi = fi or doc.cur_frame
  if fi < 1 or fi > doc.frames then return end
  local before = capture_struct(doc)
  for _, l in ipairs(doc.layers) do
    table.insert(l.cells, fi + 1, clone_cell(l.cells[fi], doc.w, doc.h))
  end
  doc.frames = doc.frames + 1
  clips_after_insert(doc, fi) -- the copy's 0-based index == fi
  doc.cur_frame = fi + 1
  push_struct(doc, before)
end

-- delete frame `fi` from every layer (a document always keeps ≥1 frame); clips
-- referencing it lose those entries, higher refs slide down.
function M.delete_frame(doc, fi)
  fi = fi or doc.cur_frame
  if doc.frames <= 1 or fi < 1 or fi > doc.frames then return end
  local before = capture_struct(doc)
  for _, l in ipairs(doc.layers) do table.remove(l.cells, fi) end
  doc.frames = doc.frames - 1
  clips_after_delete(doc, fi - 1) -- 0-based index of the removed frame
  doc.cur_frame = math.min(doc.cur_frame, doc.frames)
  push_struct(doc, before)
end

-- move frame `fi` in the strip order: dir +1 later (right), -1 earlier (left)
function M.move_frame(doc, fi, dir)
  fi = fi or doc.cur_frame
  local ni = fi + dir
  if ni < 1 or ni > doc.frames then return end
  local before = capture_struct(doc)
  for _, l in ipairs(doc.layers) do l.cells[fi], l.cells[ni] = l.cells[ni], l.cells[fi] end
  clips_after_swap(doc, fi - 1, ni - 1)
  doc.cur_frame = ni
  push_struct(doc, before)
end

-- ---- animation clips (named frame sequences; lightweight, not undo-managed —
-- they carry no pixels, and a frame op that touches them rides struct-undo) ----

-- a new clip spanning the whole strip at the default per-frame duration (an
-- instantly playable loop the artist then trims). Returns the clip.
function M.add_clip(doc, name, dur)
  dur = dur or M.DEFAULT_DUR
  local frames = {}
  for f = 0, doc.frames - 1 do frames[#frames + 1] = { frame = f, dur = dur } end
  local clip = { name = name or ("clip " .. (#doc.clips + 1)), loop = "loop", frames = frames }
  doc.clips[#doc.clips + 1] = clip
  doc.dirty = true
  return clip
end

function M.delete_clip(doc, ci)
  if doc.clips[ci] then table.remove(doc.clips, ci); doc.dirty = true end
end

-- ---- pivot / origin (Phase 5, STUDIO.md §3) ----
-- The in-game anchor: the pixel of the cell that the game pins to an entity's
-- position (feet on the ground, a hand on a weapon). Per-doc for v1 (per-frame is
-- a documented follow-up). It is baked into the .meta sidecar the game reads; the
-- studio drags it live (its own struct-undo bracket, one step per drag).

-- set the pivot to a clamped pixel, one undo step (a no-op when unchanged). The
-- studio's live drag mutates doc.pivot directly inside a begin/commit_struct
-- bracket instead — this is for numeric / programmatic sets (e.g. a reset).
function M.set_pivot(doc, x, y)
  x = math.max(0, math.min(doc.w - 1, math.floor(x)))
  y = math.max(0, math.min(doc.h - 1, math.floor(y)))
  if doc.pivot.x == x and doc.pivot.y == y then return end
  local before = capture_struct(doc)
  doc.pivot.x, doc.pivot.y = x, y
  push_struct(doc, before)
end

-- ---- slices (named rects; Phase 5b, STUDIO.md §3) ----
-- A slice is a named rectangle in cell space — an attach point / region the game
-- looks up by name (a hand to hang a weapon on, a hit/hurt box). Per-doc for v1
-- (per-frame keys are a documented follow-up). Baked into .meta beside the pivot;
-- the SLCE chunk keeps them in the editable .spr. Always clamped to the cell.

local function clamp_rect(doc, x, y, w, h)
  x = math.max(0, math.min(doc.w - 1, math.floor(x)))
  y = math.max(0, math.min(doc.h - 1, math.floor(y)))
  w = math.max(1, math.min(doc.w - x, math.floor(w)))
  h = math.max(1, math.min(doc.h - y, math.floor(h)))
  return x, y, w, h
end

-- add a slice WITHOUT an undo step — for a studio gesture that brackets its own
-- struct snapshot (drag-to-create as ONE step). Defaults to a centered rect.
function M.raw_add_slice(doc, name)
  local w = math.max(1, doc.w // 3)
  local h = math.max(1, doc.h // 3)
  local s = { name = name or ("slice " .. (#doc.slices + 1)),
              x = (doc.w - w) // 2, y = (doc.h - h) // 2, w = w, h = h }
  doc.slices[#doc.slices + 1] = s
  return s
end

function M.add_slice(doc, name)
  local before = capture_struct(doc)
  local s = M.raw_add_slice(doc, name)
  push_struct(doc, before)
  return s
end

function M.delete_slice(doc, si)
  if not doc.slices[si] then return end
  local before = capture_struct(doc)
  table.remove(doc.slices, si)
  push_struct(doc, before)
end

-- set a slice's rect, one undo step (clamped, no-op safe). The studio's live drag
-- mutates the rect inside a begin/commit_struct bracket instead.
function M.set_slice_rect(doc, si, x, y, w, h)
  local s = doc.slices[si]
  if not s then return end
  x, y, w, h = clamp_rect(doc, x, y, w, h)
  if s.x == x and s.y == y and s.w == w and s.h == h then return end
  local before = capture_struct(doc)
  s.x, s.y, s.w, s.h = x, y, w, h
  push_struct(doc, before)
end

-- find a slice by name. Accepts a doc, a decoded .meta ({slices=…}), or a raw
-- slice array — the runtime's by-name lookup. nil when absent.
function M.find_slice(src, name)
  local arr = (type(src) == "table" and src.slices) or src
  for _, s in ipairs(arr or {}) do if s.name == name then return s end end
  return nil
end

-- ---- canvas / document size (whole-doc resize; STUDIO.md §3) ----
-- Change the document's pixel dimensions, rebuilding every cell of every layer
-- and frame, in one undo step. Two modes:
--   "canvas" (default) — keep pixels at their native resolution, anchored by
--     `opts.anchor` (a 3x3 grid: nw/n/ne/w/c/e/sw/s/se); the canvas grows with
--     transparent margin or crops the overflow. For a bigger sheet / a mock.
--   "scale"  — nearest-neighbour resample the content to fill the new size.
-- The pivot, slices, and gradient-fill handles ride the same transform. The
-- struct snapshot now carries w/h, so undo restores the old size too.
local ANCHOR = { -- name -> {hx, hy}; 0 = near edge, 1 = centered, 2 = far edge
  nw = { 0, 0 }, n = { 1, 0 }, ne = { 2, 0 },
  w  = { 0, 1 }, c = { 1, 1 }, e  = { 2, 1 },
  sw = { 0, 2 }, s = { 1, 2 }, se = { 2, 2 },
}
M.ANCHOR = ANCHOR -- shared with the studio's anchor picker / preview

function M.set_size(doc, nw, nh, opts)
  opts = opts or {}
  nw = math.max(1, math.floor(nw or doc.w))
  nh = math.max(1, math.floor(nh or doc.h))
  if nw == doc.w and nh == doc.h then return false end
  local ow, oh = doc.w, doc.h
  local scale = opts.mode == "scale"
  local ox, oy = 0, 0
  if not scale then
    local a = ANCHOR[opts.anchor] or ANCHOR.nw
    ox = a[1] * (nw - ow) // 2
    oy = a[2] * (nh - oh) // 2
  end
  local before = capture_struct(doc)
  for _, l in ipairs(doc.layers) do
    for fi, cell in ipairs(l.cells) do
      local img
      if scale then
        img = paint.scale(cell, nw, nh) -- resample (returns a new image)
      else
        img = paint.image(nw, nh)       -- transparent; blit clips at both edges
        paint.blit(img, ox, oy, cell, 0, 0, ow, oh, "set")
      end
      l.cells[fi] = img
    end
  end
  doc.w, doc.h, doc._shade = nw, nh, nil -- gradient scratch re-sizes lazily
  -- remap geometry into the new space
  if scale then
    local sx, sy = nw / ow, nh / oh
    local function rnd(v) return math.floor(v + 0.5) end
    doc.pivot.x = math.max(0, math.min(nw - 1, rnd(doc.pivot.x * sx)))
    doc.pivot.y = math.max(0, math.min(nh - 1, rnd(doc.pivot.y * sy)))
    for _, s in ipairs(doc.slices) do
      s.x, s.y, s.w, s.h = clamp_rect(doc, rnd(s.x * sx), rnd(s.y * sy),
        math.max(1, rnd(s.w * sx)), math.max(1, rnd(s.h * sy)))
    end
    for _, l in ipairs(doc.layers) do
      local f = l.fill
      if f then
        f.p0.x, f.p0.y, f.p1.x, f.p1.y = f.p0.x * sx, f.p0.y * sy, f.p1.x * sx, f.p1.y * sy
      end
    end
  else
    doc.pivot.x = math.max(0, math.min(nw - 1, doc.pivot.x + ox))
    doc.pivot.y = math.max(0, math.min(nh - 1, doc.pivot.y + oy))
    for _, s in ipairs(doc.slices) do
      s.x, s.y, s.w, s.h = clamp_rect(doc, s.x + ox, s.y + oy, s.w, s.h)
    end
    for _, l in ipairs(doc.layers) do
      local f = l.fill
      if f then
        f.p0.x, f.p0.y, f.p1.x, f.p1.y = f.p0.x + ox, f.p0.y + oy, f.p1.x + ox, f.p1.y + oy
      end
    end
  end
  push_struct(doc, before)
  return true
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
      -- one C src-over blit per layer (mode 1), the per-layer opacity scaling
      -- source alpha — byte-identical to the old per-pixel paint.over loop.
      pal.blit32(out.buf, doc.w, doc.h, 0, 0, cell.buf, doc.w, doc.h, 0, 0,
                 doc.w, doc.h, 1, l.opacity)
    end
  end
  return out
end

-- merge layer `li` DOWN onto the layer below (li-1): flatten li's visible pixels
-- (honoring its opacity + gradient fill) over the layer below, per frame, then
-- drop li. The layer below's own fill is baked first so the flattened result
-- stays faithful. One undo step; a no-op for the bottom layer.
function M.merge_down(doc, li)
  li = li or doc.cur_layer
  if li <= 1 then return end
  local before = capture_struct(doc)
  local top, bot = doc.layers[li], doc.layers[li - 1]
  local op = top.opacity
  for f = 1, doc.frames do
    if bot.fill then paint.grad_fill(bot.cells[f], bot.fill, bot.cells[f]) end
    local src = shaded_cell(doc, top, f) -- top's pixels incl. its own fill
    pal.blit32(bot.cells[f].buf, doc.w, doc.h, 0, 0, src.buf, doc.w, doc.h,
               0, 0, doc.w, doc.h, 1, op) -- src-over with the top's opacity
  end
  bot.fill = nil
  table.remove(doc.layers, li)
  doc.cur_layer = li - 1
  push_struct(doc, before)
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

-- clip loop mode <-> a stable u8 id for the CLIP chunk
local LOOP_MODES = { "loop", "once", "pingpong" }
local LOOP_ID = {}
for i, t in ipairs(LOOP_MODES) do LOOP_ID[t] = i end

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
  -- CLIP: the animation clips (names, loop modes, frame sequences) — Phase 4
  if #doc.clips > 0 then
    local parts = { pack("<I4", #doc.clips) }
    for _, c in ipairs(doc.clips) do
      parts[#parts + 1] = pack("<s2I1I4", c.name, LOOP_ID[c.loop] or 1, #c.frames)
      for _, e in ipairs(c.frames) do
        parts[#parts + 1] = pack("<I4I4", e.frame, e.dur)
      end
    end
    w.chunk("CLIP", 1, table.concat(parts))
  end
  -- SLCE: named rects (attach points / hit regions) — Phase 5b
  if #doc.slices > 0 then
    local parts = { pack("<I4", #doc.slices) }
    for _, s in ipairs(doc.slices) do
      parts[#parts + 1] = pack("<s2i4i4i4i4", s.name, s.x, s.y, s.w, s.h)
    end
    w.chunk("SLCE", 1, table.concat(parts))
  end
  -- TAIL is the integrity check
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
    elseif c.tag == "CLIP" and c.version == 1 and doc then
      local nc, pos = unpack("<I4", c.payload)
      doc.clips = {}
      for _ = 1, nc do
        local name, lid, nf
        name, lid, nf, pos = unpack("<s2I1I4", c.payload, pos)
        local frames = {}
        for i = 1, nf do
          frames[i] = {}
          frames[i].frame, frames[i].dur, pos = unpack("<I4I4", c.payload, pos)
        end
        doc.clips[#doc.clips + 1] =
          { name = name, loop = LOOP_MODES[lid] or "loop", frames = frames }
      end
    elseif c.tag == "SLCE" and c.version == 1 and doc then
      local ns, pos = unpack("<I4", c.payload)
      doc.slices = {}
      for _ = 1, ns do
        local name, sx, sy, sw, sh
        name, sx, sy, sw, sh, pos = unpack("<s2i4i4i4i4", c.payload, pos)
        doc.slices[#doc.slices + 1] = { name = name, x = sx, y = sy, w = sw, h = sh }
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

-- ---- the .meta sidecar (sprite RUNTIME metadata the game reads) ----
-- The .png is pixels and the .anim is clips; the .meta carries the rest the game
-- needs at draw time — the pivot (and, Phase 5b, named slices). It is the doc's
-- geometry as canonical doc bytes (cm.state.canon, like .anim / knobs.dat): a
-- dev/asset-class file, boot-loaded, never sim input (D026). A separate sidecar
-- keeps cm.anim purely about animation; the .spr stays the editable source.

-- the runtime metadata as a plain doc tree (integers floored so canon is stable).
function M.meta_of(doc)
  local slices = {}
  for i, s in ipairs(doc.slices or {}) do
    slices[i] = { name = tostring(s.name or ""), x = math.floor(s.x),
                  y = math.floor(s.y), w = math.floor(s.w), h = math.floor(s.h) }
  end
  return { pivot = { x = math.floor(doc.pivot.x), y = math.floor(doc.pivot.y) },
           slices = slices }
end

function M.encode_meta(doc) return state.canon(M.meta_of(doc)) end

-- decode .meta bytes to a normalized { pivot = {x,y}, slices = {…} } (defaults on
-- any garbage, so a missing / corrupt file degrades cleanly to fallbacks caller-side).
function M.decode_meta(bytes)
  local ok, t = pcall(state.parse, bytes)
  if not ok or type(t) ~= "table" then return nil end
  local p = type(t.pivot) == "table" and t.pivot or {}
  local slices = {}
  if type(t.slices) == "table" then
    for _, s in ipairs(t.slices) do
      if type(s) == "table" then
        slices[#slices + 1] = { name = tostring(s.name or ""),
          x = math.floor(tonumber(s.x) or 0), y = math.floor(tonumber(s.y) or 0),
          w = math.max(1, math.floor(tonumber(s.w) or 1)),
          h = math.max(1, math.floor(tonumber(s.h) or 1)) }
      end
    end
  end
  return { pivot = { x = math.floor(tonumber(p.x) or 0),
                     y = math.floor(tonumber(p.y) or 0) }, slices = slices }
end

function M.save_meta(path, doc, fail)
  local ok, err = pal.write_file_atomic(path, M.encode_meta(doc), fail)
  if not ok then return nil, "write sprite metadata " .. path .. " failed: " .. tostring(err) end
  return true
end

-- the game's read path (render-only, like anim.load): nil on any failure.
function M.load_meta(path)
  local bytes = pal.read_file(path)
  if not bytes then return nil end
  return M.decode_meta(bytes)
end

-- A sprite save is one recoverable generation.  The manifest contains every
-- intended byte before any member is replaced.  Bakes publish first and the
-- editable source last; a crash/failure leaves the manifest for load/save to
-- finish idempotently.  This is deliberately not four pretend-independent
-- "successful" atomic writes (A1 / D063).
local TXMAGIC = "CSPRTXN1"

local function txn_path(path) return path .. ".txn" end

local function txn_encode(files)
  return pack("<c8s8s8s8s8", TXMAGIC, files.spr, files.png,
              files.anim, files.meta)
end

local function txn_decode(bytes)
  local ok, magic, spr, png, an, meta, pos = pcall(unpack, "<c8s8s8s8s8", bytes)
  if not ok or magic ~= TXMAGIC or pos ~= #bytes + 1 then return nil end
  return { spr = spr, png = png, anim = an, meta = meta }
end

local function publish(path, files, fail)
  -- Runtime products become complete before the new source claims the save.
  for _, ext in ipairs { "png", "anim", "meta", "spr" } do
    local out = ext == "spr" and path or with_ext(path, "." .. ext)
    local ok, err = pal.write_file_atomic(out, files[ext], fail and fail[ext])
    if not ok then return nil, "publish ." .. ext .. " failed: " .. tostring(err) end
  end
  if fail and fail.cleanup then return nil, "remove recovery manifest failed: injected failure" end
  if not pal.x_remove(txn_path(path)) then
    return nil, "remove recovery manifest failed"
  end
  return true
end

function M.recover(path, fail)
  if not path:match("%.spr$") then path = path .. ".spr" end
  local bytes = pal.read_file(txn_path(path))
  if not bytes then return true end
  local files = txn_decode(bytes)
  if not files then return nil, "corrupt sprite recovery manifest: " .. txn_path(path) end
  return publish(path, files, fail)
end

-- write <path>.spr plus its .png/.anim/.meta runtime products.  Even an empty
-- clip table gets an .anim file, so deleting the last clip cannot leave a stale
-- runtime sidecar. `fail` is the focused selftest seam for transaction stages.
function M.save(doc, path, fail)
  if not path:match("%.spr$") then path = path .. ".spr" end
  local ok, err = M.recover(path, fail and fail.recover)
  if not ok then return nil, "recover previous sprite save failed: " .. tostring(err) end
  local strip = M.bake_image(doc)
  local rgba = strip.buf:str(0, strip.w * strip.h * 4)
  local files = { spr = M.encode(doc), png = pal.png_encode(rgba, strip.w, strip.h),
                  anim = anim.encode(doc.clips or {}), meta = M.encode_meta(doc) }
  ok, err = pal.write_file_atomic(txn_path(path), txn_encode(files),
                                  fail and fail.manifest)
  if not ok then return nil, "write recovery manifest failed: " .. tostring(err) end
  ok, err = publish(path, files, fail)
  if not ok then return nil, err end
  doc.path, doc.dirty = path, false
  -- signal live asset hot-reload (render-only, D040): a running game watches
  -- cm.asset_epoch and re-loads the baked .png/.anim/.meta when it advances, so a
  -- studio paint→save shows on the character with no restart. It can't perturb a
  -- trace: the bump fires only from a save (the sim is paused in the studio, and
  -- --verify/--frames never open it), and the game reads the epoch in draw only.
  -- See projects/sandbox/player.lua:refresh_sprite for the consumer.
  cm.asset_epoch = (cm.asset_epoch or 0) + 1
  return true
end

function M.load(path)
  local rok, rerr = M.recover(path)
  if not rok then return nil, rerr end
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
