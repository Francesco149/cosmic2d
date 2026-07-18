-- cm.fig — the rigid-part figure runtime (D3D-005, the SM64 technique):
-- rigid part meshes hung on a joint tree, posed by per-part euler rotations
-- (+ translation for Rayman-style FLOATING parts like the mascot's mitts,
-- + scale for squash & stretch), keyframes lerped. NO skinning, ever.
--
-- A figure is DATA compiled by F.build; emission is a pure function of
-- (figure, root m4, pose) into x_tris vertex strings via cm.gb — no state
-- buffers, so cartridges can drive poses straight off the sim frame
-- (the movers precedent: pure functions replay/rewind for free).
--
-- def.parts (tree order, parents first):
--   { name=, parent=name|nil, joint={x,y,z},  -- joint rel. parent joint
--     shapes={shape, ...} }
-- shape = { kind="gbox"|"prism"|"lathe"|"ball", col={r,g,b},
--           at={x,y,z}?,        -- shape origin rel. the part joint
--           scale={sx,sy,sz}?,  -- NON-rigid: positions deform, normals
--                               -- stay on the rigid chain (gb nrmxf)
--           alpha=?,            -- 0-255 blend-segment ghosts
--           -- kind params:
--           gbox:  size={x,y,z}, center={x,y,z}?, uvs=?
--           prism: n=, r0=, r1=, h=, caps=?
--           lathe: prof={r,y,...}, n=
--           ball:  r=, n= }
--
-- pose = { [part_name] = {rx,ry,rz, tx,ty,tz, sx,sy,sz} } — all fields
-- optional/sparse (rot/t default 0, s defaults 1). Rotation order Ry Rx Rz
-- (proto draw_guy). Scale propagates to CHILDREN's positions (a squashed
-- body squashes the eyes on it) but never to lighting.
--
-- Keyframe animation is proto walk_pose generalized: F.cycle(keys, t)
-- wraps t in 0..1 across the key list with lerp; F.mix lerps two poses.
-- Stepped tracks and texture-swap face strips are deferred until a
-- character needs them.

local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")

local F = select(2, ...) or {}

-- compile a def: resolve parent names to indices, validate tree order
function F.build(def)
  local fg = { parts = {}, index = {} }
  for i, p in ipairs(def.parts) do
    local pi = 0
    if p.parent then
      pi = fg.index[p.parent]
        or error(("fig: part '%s': parent '%s' not defined before it")
                 :format(p.name, p.parent))
    end
    fg.parts[i] = {
      name = p.name, parent = pi,
      joint = p.joint or { 0, 0, 0 },
      shapes = p.shapes or {},
    }
    fg.index[p.name] = i
  end
  return fg
end

local ID = {} -- identity pose entry (never written)

local function ch(e, i, dflt) -- pose channel with default
  local v = e[i]
  if v == nil then return dflt end
  return v
end

-- lerp two poses (sparse union of part names)
function F.mix(a, b, t)
  local r = {}
  local function mixone(name)
    if r[name] then return end
    local ea, eb = a[name] or ID, b[name] or ID
    local e = {}
    for i = 1, 6 do
      local va, vb = ch(ea, i, 0), ch(eb, i, 0)
      e[i] = va + (vb - va) * t
    end
    for i = 7, 9 do
      local va, vb = ch(ea, i, 1), ch(eb, i, 1)
      e[i] = va + (vb - va) * t
    end
    r[name] = e
  end
  for name in pairs(a) do mixone(name) end
  for name in pairs(b) do mixone(name) end
  return r
end

-- cycle through keys (a list of poses) at t in 0..1, wrapping, lerped —
-- proto walk_pose generalized to any key count
function F.cycle(keys, t)
  local n = #keys
  local ft = (t % 1) * n
  local k = ft // 1
  return F.mix(keys[k % n + 1], keys[(k + 1) % n + 1], ft - k)
end

-- render-class bake cache: shape table -> its recorded local-space vertex
-- stream (weak keys — a dropped figure frees its bakes; a hot reload of
-- this module starts clean). Shapes are static per figure, so this is
-- derived pure data, never sim state.
local BAKES = setmetatable({}, { __mode = "k" })

local function bake_of(p, s)
  local bk = BAKES[s]
  if not bk then
    if s.kind == "gbox" then
      bk = gb.bake_gbox(s.size, s.center or { 0, 0, 0 }, s.uvs)
    elseif s.kind == "prism" then
      bk = gb.bake_prism(s.n, s.r0, s.r1, s.h, s.caps)
    elseif s.kind == "lathe" then
      bk = gb.bake_lathe(s.prof, s.n)
    elseif s.kind == "ball" then
      bk = gb.bake_ball(s.r, s.n)
    else
      error(("fig: part '%s': unknown shape kind '%s'")
            :format(p.name, tostring(s.kind)))
    end
    BAKES[s] = bk
  end
  return bk
end

-- emit a posed figure under root (an m4). Returns tris emitted.
-- Internals: two transform chains per part — worldp carries pose scale
-- (positions), worldn stays rigid (normals/lighting). Shape-level at/scale
-- compose the same way per shape.
function F.emit(out, fg, root, pose, alpha)
  local worldp, worldn = {}, {}
  local ntris = 0
  for i, p in ipairs(fg.parts) do
    local e = pose[p.name] or ID
    local rx, ry, rz = ch(e, 1, 0), ch(e, 2, 0), ch(e, 3, 0)
    local jx = p.joint[1] + ch(e, 4, 0)
    local jy = p.joint[2] + ch(e, 5, 0)
    local jz = p.joint[3] + ch(e, 6, 0)
    local sx, sy, sz = ch(e, 7, 1), ch(e, 8, 1), ch(e, 9, 1)
    local rig = m4.translate(jx, jy, jz)
    if ry ~= 0 then rig = m4.mul(rig, m4.roty(ry)) end
    if rx ~= 0 then rig = m4.mul(rig, m4.rotx(rx)) end
    if rz ~= 0 then rig = m4.mul(rig, m4.rotz(rz)) end
    local pp = (p.parent > 0) and worldp[p.parent] or root
    local pn = (p.parent > 0) and worldn[p.parent] or root
    local wp = m4.mul(pp, rig)
    worldn[i] = m4.mul(pn, rig)
    if sx ~= 1 or sy ~= 1 or sz ~= 1 then
      wp = m4.mul(wp, m4.scale(sx, sy, sz))
    end
    worldp[i] = wp
    for _, s in ipairs(p.shapes) do
      local xf, nxf = wp, worldn[i]
      if s.at then xf = m4.mul(xf, m4.translate(s.at[1], s.at[2], s.at[3])) end
      if s.scale then
        xf = m4.mul(xf, m4.scale(s.scale[1], s.scale[2], s.scale[3]))
      end
      local a = s.alpha or alpha
      -- baked fast path (gb.emit_baked): geometry recorded once, per
      -- frame is transform+light+pack only — byte-identical to the
      -- immediate emitters (the pixel goldens pin it)
      ntris = ntris + gb.emit_baked(out, xf, nxf, bake_of(p, s), s.col, a)
    end
  end
  return ntris
end

return F
