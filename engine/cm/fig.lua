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
local chunk = cm.require("cm.chunk")

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
      if s.kind == "mesh" then
        -- a .msh part mesh (E5): its color groups were resolved at load
        -- (F.build_doc) — an unresolved path draws nothing, honestly
        for _, gr in ipairs(s._groups or {}) do
          ntris = ntris + gb.emit_baked(out, xf, nxf, gr.bk, gr.col, a)
        end
      else
        -- baked fast path (gb.emit_baked): geometry recorded once, per
        -- frame is transform+light+pack only — byte-identical to the
        -- immediate emitters (the pixel goldens pin it)
        ntris = ntris + gb.emit_baked(out, xf, nxf, bake_of(p, s), s.col, a)
      end
    end
  end
  return ntris
end

-- world joint positions under a pose (the editor's gizmo anchors):
-- the F.emit transform chain, joints only. Returns { {x,y,z}, ... }.
function F.joints(fg, pose, root)
  root = root or m4.ident()
  local world = {}
  local out = {}
  for i, p in ipairs(fg.parts) do
    local e = pose and pose[p.name] or ID
    local rx, ry, rz = ch(e, 1, 0), ch(e, 2, 0), ch(e, 3, 0)
    local jx = p.joint[1] + ch(e, 4, 0)
    local jy = p.joint[2] + ch(e, 5, 0)
    local jz = p.joint[3] + ch(e, 6, 0)
    local rig = m4.translate(jx, jy, jz)
    if ry ~= 0 then rig = m4.mul(rig, m4.roty(ry)) end
    if rx ~= 0 then rig = m4.mul(rig, m4.rotx(rx)) end
    if rz ~= 0 then rig = m4.mul(rig, m4.rotz(rz)) end
    local pp = (p.parent > 0) and world[p.parent] or root
    world[i] = m4.mul(pp, rig)
    out[i] = { world[i][13], world[i][14], world[i][15] }
  end
  return out
end

-- ---- the .fig asset (CFIG, EDITOR3D.md §6.1, E5) -------------------------
--
-- The hand-editable source format for a figure: parts (tree order,
-- parents first) with their shapes, plus named clips of sparse pose
-- keys. Floats are f64 on disk so a figure that exists as Lua data
-- (cm.mascot) converts to a file whose emit is BYTE-EXACT against the
-- code original — the converter KAT's contract. Codec canonical
-- (encode(decode(b)) == b), cm.chunk skip-tolerant.
--
--   HEAD v1: <s4 name>
--   PART v1: <s4 name> <s4 parent ("" = root)> <ddd joint>
--            <I2 nshapes> nshapes x shape:
--              <s4 kind> <BBB col> <I1 flags: 1 at, 2 scale, 4 alpha,
--              8 caps> [at ddd] [scale ddd] [alpha d]
--              gbox: <ddd size> <ddd center> · prism: <I2 n><d r0><d r1>
--              <d h> · lathe: <I2 n><I2 nprof><nprof x d> · ball:
--              <d r><I2 n> · mesh: <s4 path>
--   CLIP v1: <s4 name> <d rate> <I1 flags: 1 loop> <I2 nkeys> nkeys x
--            key: <I2 nentries> entries (part-name sorted) x
--            <s4 part> <I2 mask (9 channel bits)> <set-bit x d>
--   TAIL v1: empty

local MAGIC = "CFIG"
local pk, upk = string.pack, string.unpack

F.SHAPE_KINDS = { "gbox", "ball", "prism", "lathe", "mesh" }

-- colors ride f64 like every float here: a byte-quantized color would
-- perturb gb's lighting math and break the converter's byte-exact emit

function F.encode(doc)
  local w = chunk.writer(MAGIC)
  w.chunk("HEAD", 1, pk("<s4", doc.name or ""))
  for _, p in ipairs(doc.parts or {}) do
    local parts = { pk("<s4s4ddd", p.name or "", p.parent or "",
                       p.joint and p.joint[1] or 0,
                       p.joint and p.joint[2] or 0,
                       p.joint and p.joint[3] or 0),
                    pk("<I2", #(p.shapes or {})) }
    for _, s in ipairs(p.shapes or {}) do
      if s.uvs then error("fig: gbox uvs are not in CFIG v1", 0) end
      local c = s.col or { 0.6, 0.6, 0.6 }
      local flags = (s.at and 1 or 0) | (s.scale and 2 or 0)
                  | (s.alpha and 4 or 0) | (s.caps and 8 or 0)
      parts[#parts + 1] = pk("<s4dddI1", s.kind, c[1], c[2], c[3], flags)
      if s.at then parts[#parts + 1] = pk("<ddd", s.at[1], s.at[2], s.at[3]) end
      if s.scale then
        parts[#parts + 1] = pk("<ddd", s.scale[1], s.scale[2], s.scale[3])
      end
      if s.alpha then parts[#parts + 1] = pk("<d", s.alpha) end
      if s.kind == "gbox" then
        local c = s.center or { 0, 0, 0 }
        parts[#parts + 1] = pk("<dddddd", s.size[1], s.size[2], s.size[3],
                               c[1], c[2], c[3])
      elseif s.kind == "prism" then
        parts[#parts + 1] = pk("<I2ddd", s.n, s.r0, s.r1, s.h)
      elseif s.kind == "lathe" then
        local pr = { pk("<I2I2", s.n, #s.prof) }
        for i = 1, #s.prof do pr[#pr + 1] = pk("<d", s.prof[i]) end
        parts[#parts + 1] = table.concat(pr)
      elseif s.kind == "ball" then
        parts[#parts + 1] = pk("<dI2", s.r, s.n)
      elseif s.kind == "mesh" then
        parts[#parts + 1] = pk("<s4", s.path or "")
      else
        error("fig: unknown shape kind " .. tostring(s.kind), 0)
      end
    end
    w.chunk("PART", 1, table.concat(parts))
  end
  for _, c in ipairs(doc.clips or {}) do
    local parts = { pk("<s4dI1I2", c.name or "", c.rate or 1,
                       c.loop ~= false and 1 or 0, #(c.keys or {})) }
    for _, key in ipairs(c.keys or {}) do
      local names = {}
      for name in pairs(key) do names[#names + 1] = name end
      table.sort(names)
      parts[#parts + 1] = pk("<I2", #names)
      for _, name in ipairs(names) do
        local e = key[name]
        local mask = 0
        for i = 1, 9 do
          if e[i] ~= nil then mask = mask | (1 << (i - 1)) end
        end
        parts[#parts + 1] = pk("<s4I2", name, mask)
        for i = 1, 9 do
          if e[i] ~= nil then parts[#parts + 1] = pk("<d", e[i]) end
        end
      end
    end
    w.chunk("CLIP", 1, table.concat(parts))
  end
  w.chunk("TAIL", 1, "")
  return w.result()
end

function F.decode(bytes)
  local doc = { name = "", parts = {}, clips = {} }
  local seen_head, seen_tail
  for _, c in ipairs(chunk.read(bytes, MAGIC)) do
    if c.tag == "HEAD" and c.version == 1 then
      doc.name = upk("<s4", c.payload)
      seen_head = true
    elseif c.tag == "PART" and c.version == 1 then
      local p, pos = {}, 1
      local parent
      p.name, parent, pos = upk("<s4s4", c.payload, pos)
      p.parent = parent ~= "" and parent or nil
      local jx, jy, jz
      jx, jy, jz, pos = upk("<ddd", c.payload, pos)
      p.joint = { jx, jy, jz }
      p.shapes = {}
      local ns
      ns, pos = upk("<I2", c.payload, pos)
      for _ = 1, ns do
        local s = {}
        local r, g, b, flags
        s.kind, r, g, b, flags, pos = upk("<s4dddI1", c.payload, pos)
        s.col = { r, g, b }
        if flags & 1 ~= 0 then
          local x, y, z
          x, y, z, pos = upk("<ddd", c.payload, pos)
          s.at = { x, y, z }
        end
        if flags & 2 ~= 0 then
          local x, y, z
          x, y, z, pos = upk("<ddd", c.payload, pos)
          s.scale = { x, y, z }
        end
        if flags & 4 ~= 0 then s.alpha, pos = upk("<d", c.payload, pos) end
        if flags & 8 ~= 0 then s.caps = true end
        if s.kind == "gbox" then
          local sx, sy, sz, cx, cy, cz
          sx, sy, sz, cx, cy, cz, pos = upk("<dddddd", c.payload, pos)
          s.size = { sx, sy, sz }
          s.center = { cx, cy, cz }
        elseif s.kind == "prism" then
          s.n, s.r0, s.r1, s.h, pos = upk("<I2ddd", c.payload, pos)
        elseif s.kind == "lathe" then
          local np
          s.n, np, pos = upk("<I2I2", c.payload, pos)
          s.prof = {}
          for i = 1, np do s.prof[i], pos = upk("<d", c.payload, pos) end
        elseif s.kind == "ball" then
          s.r, s.n, pos = upk("<dI2", c.payload, pos)
        elseif s.kind == "mesh" then
          s.path, pos = upk("<s4", c.payload, pos)
        else
          error("fig: unknown shape kind " .. tostring(s.kind), 0)
        end
        p.shapes[#p.shapes + 1] = s
      end
      doc.parts[#doc.parts + 1] = p
    elseif c.tag == "CLIP" and c.version == 1 then
      local cl, pos = {}, 1
      local rate, flags, nk
      cl.name, rate, flags, nk, pos = upk("<s4dI1I2", c.payload, pos)
      cl.rate = rate
      cl.loop = flags & 1 ~= 0
      cl.keys = {}
      for _ = 1, nk do
        local key = {}
        local ne
        ne, pos = upk("<I2", c.payload, pos)
        for _ = 1, ne do
          local name, mask
          name, mask, pos = upk("<s4I2", c.payload, pos)
          local e = {}
          for i = 1, 9 do
            if mask & (1 << (i - 1)) ~= 0 then
              e[i], pos = upk("<d", c.payload, pos)
            end
          end
          key[name] = e
        end
        cl.keys[#cl.keys + 1] = key
      end
      doc.clips[#doc.clips + 1] = cl
    elseif c.tag == "TAIL" then
      seen_tail = true
    end
  end
  if not seen_head then error("fig: missing HEAD", 0) end
  if not seen_tail then error("fig: missing TAIL (truncated?)", 0) end
  -- parents must precede their children (fig.build's contract)
  local seen = {}
  for _, p in ipairs(doc.parts) do
    if p.parent and not seen[p.parent] then
      error(("fig: part '%s': parent '%s' not defined before it")
            :format(p.name, p.parent), 0)
    end
    seen[p.name] = true
  end
  return doc
end

function F.save(doc, path, fail)
  local ok, err = pal.write_file_atomic(path, F.encode(doc), fail)
  if not ok then return nil, "write fig failed: " .. tostring(err) end
  return true
end

-- the fresh starter (the window's new-file door): base/body/head, a
-- gbox each, one empty idle clip
function F.fresh(name)
  return {
    name = name or "", clips = {
      { name = "idle", rate = 1, loop = true, keys = { {}, {} } },
    },
    parts = {
      { name = "base", joint = { 0, 0.9, 0 }, shapes = {
        { kind = "gbox", col = { 0.45, 0.55, 0.60 },
          size = { 0.55, 0.5, 0.38 } } } },
      { name = "body", parent = "base", joint = { 0, 0, 0 }, shapes = {
        { kind = "gbox", col = { 0.60, 0.50, 0.42 },
          size = { 0.42, 0.34, 0.30 }, at = { 0, 0.42, 0 } } } },
      { name = "head", parent = "body", joint = { 0, 0.62, 0 }, shapes = {
        { kind = "ball", col = { 0.85, 0.75, 0.62 }, r = 0.24, n = 8 } } },
    },
  }
end

-- build a doc into the runtime figure, resolving mesh shapes through
-- `read(path) -> bytes` (nil read = mesh shapes draw nothing). Returns
-- the compiled figure; clips stay on the doc.
function F.build_doc(doc, read)
  local fg = F.build({ parts = doc.parts })
  for _, p in ipairs(fg.parts) do
    for _, s in ipairs(p.shapes) do
      if s.kind == "mesh" then
        s._groups = nil
        if read and s.path and s.path ~= "" then
          local ok, groups = pcall(function()
            local bytes = read(s.path)
            if not bytes then error("missing " .. s.path) end
            local mesh = cm.require("cm.mesh")
            return mesh.bake_groups(mesh.decode(bytes))
          end)
          if ok then s._groups = groups end
        end
      end
    end
  end
  return fg
end

-- rebuild a codec doc from a COMPILED figure (parent indices back to
-- names) — the code-figure -> .fig converter (the mascot ships through
-- this; the KAT pins byte-exact emit)
function F.doc_of(fg, name, clips)
  local doc = { name = name or "", parts = {}, clips = clips or {} }
  for i, p in ipairs(fg.parts) do
    doc.parts[i] = {
      name = p.name,
      parent = p.parent > 0 and fg.parts[p.parent].name or nil,
      joint = { p.joint[1], p.joint[2], p.joint[3] },
      shapes = p.shapes,
    }
  end
  return doc
end

-- mirror a `<base>_l` part onto its `<base>_r` twin (creating it as a
-- sibling if missing): joint + shape x geometry negated. Pure; the
-- figure window's mirror button. Returns the target part index.
function F.mirror_lr(doc, pi)
  local p = doc.parts[pi]
  if not p then return nil, "no part" end
  local base = p.name:match("^(.*)_l$")
  if not base then return nil, "select a *_l part to mirror" end
  local tname = base .. "_r"
  local ti
  for i, t in ipairs(doc.parts) do
    if t.name == tname then ti = i break end
  end
  if not ti then
    ti = pi + 1
    table.insert(doc.parts, ti, { name = tname, parent = p.parent })
  end
  local t = doc.parts[ti]
  t.joint = { -p.joint[1], p.joint[2], p.joint[3] }
  t.shapes = {}
  for si, s in ipairs(p.shapes) do
    local c = {}
    for k, v in pairs(s) do
      if type(v) == "table" then
        local cv = {}
        for kk, vv in pairs(v) do cv[kk] = vv end
        c[k] = cv
      elseif k ~= "_groups" then
        c[k] = v
      end
    end
    if c.at then c.at[1] = -c.at[1] end
    if c.center then c.center[1] = -c.center[1] end
    t.shapes[si] = c
  end
  return ti
end

-- delete a part; children reparent to its parent. Pure; refuses the
-- last part. Returns true.
function F.remove_part(doc, pi)
  local p = doc.parts[pi]
  if not p then return nil, "no part" end
  if #doc.parts <= 1 then return nil, "a figure needs one part" end
  for _, q in ipairs(doc.parts) do
    if q.parent == p.name then q.parent = p.parent end
  end
  table.remove(doc.parts, pi)
  -- drop the part from every clip key (sparse poses address by name)
  for _, c in ipairs(doc.clips or {}) do
    for _, key in ipairs(c.keys or {}) do key[p.name] = nil end
  end
  return true
end

return F
