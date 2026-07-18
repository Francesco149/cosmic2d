-- cm.atlas — the per-tile baked texture atlas: demo 3's RO signature move as
-- an engine slice (§12 slice 4; born in projects/rovale, D3D-026 logged it
-- engine-shaped: "the terrain bake atlas — module + future editor button").
-- The runtime substrate for the terrain-paint/bake editor window when it
-- unparks.
--
-- The RO 258-slot trick: every terrain TILE gets its own cell in one big
-- texture, with a GUTTER of texels reaching into the neighbour tiles so
-- 3-point filtering never seams — so the ground can carry a unique blended
-- texture per tile with zero visible grid (roBrowser/BrowEdit; see
-- docs/research-3d/ro-render-recipe.md). This module owns the atlas LAYOUT
-- (cell + gutter -> block, tile -> atlas offset, the interior UV rect), the
-- BUDGETED render-class bake loop (K tiles/frame under a loading bar, upload
-- once on completion), and the atlas texture's CONTENTS (create it, fill it,
-- re-upload a finished bake instantly on hot reload) -- persisted in
-- caller-named buffers so a reload never rebakes needlessly.
--
-- The texture's LIFETIME is the CALLER's: A.build creates and returns the
-- atlas texture, but you register handle.tex wherever you free your textures
-- (rovale keeps it in its rc.ro.texids registry, freed with the rest on
-- reload) -- cm.atlas only fills it. That keeps the state buffer to two u32s
-- with no texid slot, which is load-bearing: the bake state then shares the
-- exact shape the demo has always used, so the retrofit is byte-identical and
-- an un-recut trace's own bundle replays clean. (A resized state buffer would
-- collide with the old bundle's raw pal.buf during the double-init that a
-- --verify runs: boot inits the current sources, then trace.verify restores
-- the bundle and inits again over the same named buffers -- D3D-031.)
--
-- What it does NOT own: the per-texel COLOUR is project policy. The caller
-- passes texel(wx, wz) -> r, g, b (0..255, this module clamps + packs) -- for
-- rovale that's the feathered grass/dirt/sand blend with prop shadows
-- multiplied in; a painterly editor would sample its splat weights there.
-- (The cm.walk `ok` / cm.terr `sample_fn` precedent: a pure sample function
-- passed to a pure function, not a stored callback.)
--
-- Determinism: the bake is RENDER-CLASS (draw only) -- the sim never reads
-- atlas pixels, so a trace replays byte-identical under ANY budget (the §10
-- honesty shape; _G.RO_BUDGET proves it). The final atlas is a pure function
-- of texel() and the layout, independent of how many tiles baked per frame.
-- State lives entirely in the caller's named rc.* buffers (the pixel buffer +
-- a small progress/stamp buffer), so the module holds nothing across a hot
-- reload and the returned handle is rebuilt each build() like cm.terr's
-- terrain object.
--
-- Deliberately NOT here: non-uniform / rectangle packing (this is a UNIFORM
-- tile grid -- sprite SHEETS are cm.spr's job), splat-weight sampling, normal
-- / AO / mip baking, and the terrain MESH emission itself (the caller's
-- emitter owns the vertex layout; A.uv is the one seam they must share). All
-- later cuts, earned from real editor pain.

local m = cm.require("cm.math")

local A = select(2, ...) or {}

local floor = math.floor
local char, concat = string.char, table.concat

-- get a named buffer at `size`, recreating it if a prior generation had a
-- different size (the rovale ro.cam/rc.ro.dyn pattern). Returns buf, fresh
-- where fresh=true means it was recreated for a size change (the pixel
-- buffer's contents are then blank, so the bake must restart).
local function getbuf(name, size)
  local ok, b = pcall(pal.buf, name, size)
  if ok then return b, false end
  pal.buf_free(name)
  return pal.buf(name, size), true
end

-- state buffer: [0]u32 next_tile (bake cursor) [4]u32 stamp (bump to rebake)
local ST = 8

-- (re)create an atlas. o:
--   pixels = pixel buffer name (rc.* -- session/render-class)
--   state  = progress/stamp buffer name (rc.*)
--   n      = tiles per side (or w + h for a non-square map; h defaults to w)
--   tile   = world units per tile (the bake samples world space)
--   cell   = interior texels per tile   (default 32, the RO cell)
--   gutter = gutter texels each side    (default 1,  the RO gutter)
--   fill   = 4-byte RGBA pre-bake fill  (default opaque black; only ever
--            seen behind the loading bar before the bake finishes)
--   stamp  = bake-math version; a mismatch discards a stale bake on reload
-- Returns a handle { tex, buf, st, w, h, tile, cell, gutter, block, sx, sy,
-- stamp } -- hold it, pass it to A.bake / A.uv / A.done / A.rebake, and
-- register handle.tex for freeing (cm.atlas never frees it).
function A.build(o)
  local cell = o.cell or 32
  local gutter = o.gutter or 1
  local block = cell + 2 * gutter
  local w = o.w or o.n
  local h = o.h or w
  local sx, sy = w * block, h * block

  local buf, fresh = getbuf(o.pixels, sx * sy * 4)
  local st = getbuf(o.state, ST)
  local fill = o.fill or "\0\0\0\255"
  local tex = pal.tex_create(sx, sy, string.rep(fill, sx * sy))

  local a = { tex = tex, buf = buf, st = st, w = w, h = h, tile = o.tile,
              cell = cell, gutter = gutter, block = block,
              sx = sx, sy = sy, stamp = o.stamp or 0 }
  -- rebake if the math version moved or the pixel buffer was reallocated;
  -- otherwise a bake that finished before the reload re-uploads instantly
  if fresh or st:u32(4) ~= a.stamp then
    st:u32(0, 0); st:u32(4, a.stamp)
  elseif st:u32(0) >= w * h then
    pal.tex_update(tex, buf, sx, sy)
  end
  return a
end

-- bake ONE tile's block of texels. gutter texels sample OUTSIDE the tile
-- (into the neighbours) so 3-point filtering crosses tile borders seamlessly.
local function bake_tile(a, tx, tz, texel)
  local cell, gutter, block, tile = a.cell, a.gutter, a.block, a.tile
  local sx, base = a.sx, tx * a.block
  for py = 0, block - 1 do
    local wz = (tz + (py - gutter + 0.5) / cell) * tile
    local row = {}
    for qx = 0, block - 1 do
      local wx = (tx + (qx - gutter + 0.5) / cell) * tile
      local r, g, b = texel(wx, wz)
      if r > 255 then r = 255 elseif r < 0 then r = 0 end
      if g > 255 then g = 255 elseif g < 0 then g = 0 end
      if b > 255 then b = 255 elseif b < 0 then b = 0 end
      row[qx + 1] = char(floor(r), floor(g), floor(b), 255)
    end
    a.buf:setstr(((tz * block + py) * sx + base) * 4, concat(row))
  end
end

-- bake up to `budget` tiles this frame; returns the done fraction 0..1.
-- Call from DRAW only (render-class). texel(wx, wz) -> r, g, b (project
-- policy). Uploads the finished atlas to the GPU once, on completion.
function A.bake(a, budget, texel)
  local st = a.st
  local next_t = st:u32(0)
  local total = a.w * a.h
  if next_t >= total then return 1 end
  local stop = m.min(total, next_t + budget)
  local w = a.w
  while next_t < stop do
    bake_tile(a, next_t % w, next_t // w, texel)
    next_t = next_t + 1
  end
  st:u32(0, next_t)
  if next_t >= total then pal.tex_update(a.tex, a.buf, a.sx, a.sy) end
  return next_t / total
end

function A.done(a) return a.st:u32(0) >= a.w * a.h end

-- restart the bake (console: after editing the texel math live, or the
-- editor's re-bake button)
function A.rebake(a) a.st:u32(0, 0); a.st:u32(4, a.stamp) end

-- the interior UV rect of tile (tx, tz): the mesh emitter maps this tile's
-- quad to (u0,v0)..(u1,v1) so it samples the tile's cell WITHOUT its gutter
-- (the gutter exists only to feed the filter across borders). The one seam
-- the caller's terrain emitter must share with the bake. Returns u0,v0,u1,v1.
function A.uv(a, tx, tz)
  local e0 = a.gutter / a.block
  local e1 = (a.block - a.gutter) / a.block
  return (tx + e0) / a.w, (tz + e0) / a.h, (tx + e1) / a.w, (tz + e1) / a.h
end

return A
