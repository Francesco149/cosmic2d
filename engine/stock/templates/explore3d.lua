-- __NAME__ — a 3D starter: a little vale, you, and a wandering friend.
-- Edit me while the game runs (hot reload)!
--
-- FIRST BOOT writes two assets next to this file, then never again:
--   world.terr      the 3D map   (edit: spawn menu > "3d map")
--   art/mascot.fig  the character (edit: spawn menu > "figure")
-- After that the game reads the FILES. Sculpt the hills, paint the
-- ground, drop props, drag the npc route, save with Ctrl+S — the
-- running game reloads the world the same frame. That is the whole
-- loop: the editors shape assets, this cartridge just plays them.
-- The docs button (or Ctrl+Space) finds "getting-started-3d".
--
-- Determinism: everything that changes per frame lives in state.doc;
-- terrain/figure files load into captured buffers (cm.terr3), so
-- snapshots, traces, and rewind stay exact.

local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m = cm.require("cm.math")
local m4 = cm.require("cm.m4")
local terr3 = cm.require("cm.terr3")
local fig = cm.require("cm.fig")
local gb = cm.require("cm.gb")
local gfx = cm.require("cm.gfx")
local mesh = cm.require("cm.mesh")
local rig = cm.require("cm.rig")   -- the orbit-follow camera (openworld's)
local kin = cm.require("cm.kin")   -- accel/friction/turn easing
local move = cm.require("cm.move") -- stick-or-keys move vector

local FOVY, ZN, ZF = 55, 0.3, 300
local DT = 1 / 60
-- the openworld-approved walk feel (units/second; kin.run applies DT)
local SPEED, ACCEL, FRIC, TURN = 6.5, 40, 30, 0.25
local STRIDE = 2.0               -- world units per walk cycle
local NPC_SPEED = 1.8            -- units/second along the route
local NPC_TURN = 0.15

local root = cm.main.args.project
local game = {}

-- ---- first boot: generate the assets (yours to edit afterwards) ----

local function ensure_assets()
  if not pal.read_file(root .. "/world.terr") then
    local doc = terr3.fresh("vale", 28, 28, 2.0)
    -- soft hills from two bumps + a pond dip — enough terrain to read;
    -- the 3d map window's sculpt brush takes it from here
    local function bump(cx, cz, r, h, vx, vz)
      local dx, dz = vx - cx, vz - cz
      local d2 = (dx * dx + dz * dz) / (r * r)
      if d2 >= 1 then return 0 end
      local t = 1 - d2
      return h * t * t
    end
    for vz = 0, doc.h do
      for vx = 0, doc.w do
        local hgt = bump(7, 8, 8, 3.2, vx, vz)
                  + bump(21, 20, 9, 4.4, vx, vz)
                  - bump(19, 7, 6, 2.6, vx, vz)
        doc.hts[vz * (doc.w + 1) + vx + 1] = hgt
      end
    end
    doc.water = { on = true, y = -0.5, col = { 0.25, 0.45, 0.62 },
                  alpha = 150 }
    doc.fog = { on = true, s = 40, e = 110,
                col = { 0.62, 0.72, 0.85 } }
    doc.spawn = { x = 28, z = 30, yaw = 0 }
    -- the friend's patrol: a route marker — drag its points in the
    -- 3d map window's mkr tool and the npc follows your edit
    doc.markers[1] = { kind = "route", x = 24, z = 24, points = {
      24, 24, 36, 26, 38, 36, 26, 38 } }
    pal.write_file_atomic(root .. "/world.terr", terr3.encode(doc))
    pal.log("[__NAME__] wrote world.terr - open it in the 3d map window")
  end
  if not pal.read_file(root .. "/art/mascot.fig") then
    pal.mkdir(root .. "/art")
    local stock = pal.read_file("engine/stock/fig/mascot.fig")
    if stock then
      pal.write_file_atomic(root .. "/art/mascot.fig", stock)
      pal.log("[__NAME__] wrote art/mascot.fig - open it in the figure "
              .. "window")
    end
  end
end

-- ---- the world + the character (files -> runtime) ----

local world -- terr3 instance (captured buffers; reload-proof)
local figure, clips -- the built mascot + its clip table

local function load_figure()
  local bytes = pal.read_file(root .. "/art/mascot.fig")
  if not bytes then return end
  local doc = fig.decode(bytes)
  figure = fig.build_doc(doc, function(path)
    return pal.read_file(root .. "/" .. path)
  end)
  clips = {}
  for _, c in ipairs(doc.clips) do clips[c.name] = c end
end

local cam -- the rig's orbit/focus state (a captured named buffer)

local function reset(d)
  local sp = world.doc.spawn
  d.x, d.z, d.yaw, d.phase = sp.x, sp.z, sp.yaw, 0
  d.vx, d.vz = 0, 0
  local route = terr3.markers(world.doc, "route")[1]
  d.nseg = 1
  d.nx = route and route.points[1] or sp.x + 4
  d.nz = route and route.points[2] or sp.z
  d.nyaw, d.nphase = 0, 0
  rig.reset(cam, d.knobs.cam, d.x, terr3.ground(world.doc, d.x, d.z),
            d.z, d.yaw)
end

function game.init()
  ensure_assets()
  world = terr3.use{ path = root .. "/world.terr", name = "world" }
  load_figure()
  -- openworld's control map: wasd walks camera-relative, arrows orbit
  -- the camera, c recenters behind you; drag the mouse to look around,
  -- wheel zooms (the rig reads those directly — all recorded input)
  input.map({
    { "left", input.key.a }, { "right", input.key.d },
    { "up", input.key.w }, { "down", input.key.s },
    { "cam_l", input.key.left }, { "cam_r", input.key.right },
    { "cam_u", input.key.up }, { "cam_d", input.key.down },
    { "recenter", input.key.c },
    { "reset", input.key.r, "pad:start" },
  })
  cam = pal.buf("vale.cam", rig.SIZE)
  local d = state.doc
  d.knobs = d.knobs or {}
  d.knobs.cam = d.knobs.cam or rig.defaults()
  if d.x == nil then reset(d) end
end

-- a live map edit hot-reloads through terr3; the figure re-reads when
-- any asset saves (cm.asset_epoch — the editor bumps it on Ctrl+S)
local seen_epoch = cm.asset_epoch or 0
local function refresh_assets()
  local epoch = cm.asset_epoch or 0
  if epoch ~= seen_epoch then
    seen_epoch = epoch
    load_figure()
  end
end

-- walkable test through the derived walk grid (slope + water + blockers
-- + your painted overrides — the wlk tool)
local function can_stand(x, z)
  local cell = world.doc.tile * 0.5
  return terr3.walkable(world, math.floor(x / cell), math.floor(z / cell))
end

function game.step()
  world = terr3.current() or world
  local d = state.doc
  if input.pressed("reset") then reset(d) end

  -- you: the openworld kernel — stick-or-keys, camera-relative wish,
  -- accel/friction with the yaw easing toward the heading (no snaps)
  local sx, sy = move.stick(1)
  local fwd, side
  if sx ~= 0 or sy ~= 0 then fwd, side = -sy, sx
  else
    local ix, iy = move.keys()
    fwd, side = -iy, ix
  end
  local wishx, wishz = rig.wish(cam, fwd, side)
  d.vx, d.vz, d.yaw = kin.run(d.vx or 0, d.vz or 0, d.yaw,
                              wishx, wishz, SPEED, ACCEL, FRIC, TURN)
  -- integrate axis-separated so hills and water edges slide, not stick
  local nx = d.x + d.vx * DT
  if can_stand(nx, d.z) then d.x = nx else d.vx = 0 end
  local nz = d.z + d.vz * DT
  if can_stand(d.x, nz) then d.z = nz else d.vz = 0 end
  local hspeed = m.sqrt(d.vx * d.vx + d.vz * d.vz)
  d.phase = (d.phase + hspeed * DT / STRIDE) % 1

  -- the camera follows (orbit + yaw-follow + drag-look + arrows/c)
  local py = terr3.ground(world.doc, d.x, d.z)
  rig.step(cam, d.knobs.cam, d.x, py, d.z, d.vx, d.vz, d.yaw)

  -- the friend: walk the route marker's polyline, forever, easing its
  -- facing toward the heading (m.atan2 — atan is the 1-arg one!)
  local route = terr3.markers(world.doc, "route")[1]
  if route and #route.points >= 4 then
    local pts = route.points
    local b = d.nseg % (#pts // 2) + 1
    local bx, bz = pts[b * 2 - 1], pts[b * 2]
    local vx, vz = bx - d.nx, bz - d.nz
    local dist = m.sqrt(vx * vx + vz * vz)
    if dist < NPC_SPEED * DT * 2 then
      d.nseg = b
    else
      d.nx = d.nx + vx / dist * NPC_SPEED * DT
      d.nz = d.nz + vz / dist * NPC_SPEED * DT
      local target = m.atan2(vx, vz)
      local turn = m.atan2(m.sin(target - d.nyaw), m.cos(target - d.nyaw))
      d.nyaw = d.nyaw + turn * NPC_TURN
      d.nphase = (d.nphase + NPC_SPEED * DT / STRIDE) % 1
    end
  end
end

-- ---- rendering (render-class: reads sim, never writes it) ----

local vbuf = pal.buf("rc.explore3d.vb", 1 << 21)
local terrcache -- rebuild the terrain mesh when the doc changes
local dyn = pal.buf("rc.explore3d.dyn", 1 << 20)

local function terrain_bytes()
  if terrcache and terrcache.doc == world.doc then return terrcache end
  -- a FRESH baked atlas (stamp matches the paint state) draws textured;
  -- otherwise live vertex colors — exactly the 3d map window's rule
  local atex
  if (world.doc.stamp or 0) ~= 0
     and world.doc.stamp == terr3.mat_hash(world.doc) then
    local ok, t = pcall(gfx.texture,
                        root .. "/" .. terr3.atlas_path("world.terr"))
    if ok and t then atex = t.id end
  end
  local out = {}
  local n = terr3.emit_terrain(out, world.doc, { atlas = atex ~= nil })
  local wout = {}
  local wn = terr3.emit_water(wout, world.doc)
  local bytes = table.concat(out) .. table.concat(wout)
  vbuf:setstr(0, bytes)
  terrcache = { doc = world.doc, n = n, wn = wn, atex = atex }
  return terrcache
end

local function figure_pose(name, t)
  local c = clips and clips[name]
  if not (c and #c.keys > 0) then return {} end
  return fig.cycle(c.keys, t)
end

function game.draw()
  refresh_assets()
  local W, H = input.game_size()
  pal.begin_frame(0.62, 0.72, 0.85, 1)
  local doc = world.doc
  gb.sun, gb.ambient = doc.sun, doc.amb

  local d = state.doc
  -- the camera position derives from the rig's orbit state (openworld)
  local py = terr3.ground(doc, d.x, d.z)
  local view = rig.view(cam, d.knobs.cam)
  local proj = m4.persp(FOVY, W / H, ZN, ZF)
  local fog = doc.fog
  pal.x_view3d{ mvp = m4.mul(proj, view), fog_on = fog.on,
                fog_start = fog.s, fog_end = fog.e, fog = fog.col }

  -- the world, straight from the file (terrain + props + water)
  local tc = terrain_bytes()
  pal.x_tris(tc.atex or 0, vbuf, tc.n, 0, tc.atex and 2 or 0)
  local cam_yaw = cam:f32(0)
  local segs = terr3.emit_props(doc, {
    cam_yaw = cam_yaw,
    tex = function(path)
      local l = path:lower()
      local target = l:find("%.png$") and path
                     or (l:find("%.spr$") and path:gsub("%.spr$", ".png"))
      if not target then return nil end
      local ok, t = pcall(gfx.texture, root .. "/" .. target)
      return ok and t and t.id or nil
    end,
    mesh = function(path)
      local ok, rec = pcall(function()
        local mdoc = mesh.decode(pal.read_file(root .. "/" .. path))
        return { doc = mdoc, groups = mesh.bake_groups(mdoc) }
      end)
      return ok and rec or nil
    end,
  })
  local off = 0
  for _, s in ipairs(segs) do
    dyn:setstr(off, s.bytes)
    pal.x_tris(s.tex or 0, dyn, s.ntris, off, s.flags)
    off = off + #s.bytes
  end

  -- you + the friend (the SAME .fig file, posed by its clips)
  if figure then
    local out = {}
    local moving = input.down("left") or input.down("right")
                   or input.down("up") or input.down("down")
    local pose = figure_pose(moving and "walk" or "idle",
                             moving and d.phase or (state.frame() / 240) % 1)
    local rootm = m4.mul(m4.translate(d.x, py, d.z), m4.roty(d.yaw))
    local n = fig.emit(out, figure, rootm, pose)
    local ny = terr3.ground(doc, d.nx, d.nz)
    local npose = figure_pose("walk", d.nphase)
    local nroot = m4.mul(m4.translate(d.nx, ny, d.nz), m4.roty(d.nyaw))
    n = n + fig.emit(out, figure, nroot, npose)
    dyn:setstr(off, table.concat(out))
    pal.x_tris(0, dyn, n, off, 0)
  end

  -- water tints whatever sank below it (blend, last)
  pal.x_tris(0, vbuf, tc.wn, tc.n * 72, 4)

  text.draw(3, 3, "__NAME__  -  wasd walk - arrows/drag look - c centers")
  text.draw(3, H - 10, "edit world.terr in the 3d map window; Ctrl+S "
            .. "reloads this game live")
end

return game
