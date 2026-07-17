-- figure main.lua — demo 2's seed: the cm.fig rigid-part figure showcase.
-- The approved mascot (idle on the stage + one walking the ring) and the
-- box guy (the joint-tree walk) circle a graybox stage forever; the camera
-- slow-orbits the whole scene. Everything animates as a PURE FUNCTION of
-- the sim frame (the movers precedent): no input, no animation state — a
-- trace of this cartridge is just the frame counter marching.
--
-- Look: the N64 presentation (knobs.look, D3D-015) over cm.gb graybox
-- materials — same sun/sky/fog as bounce so the family reads as one world.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local text = cm.require("cm.text")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local fig = cm.require("cm.fig")
local chars = cm.require("chars")

local W, H = pal.gfx_size()
local FOVY, ZN, ZF = 52, 0.3, 120

local game = select(2, ...) or {}

local KNOBS = {
  cam = { -- the slow showcase orbit (render-class read, but knobs live in
          -- the doc so the console can tune them like every cartridge)
    dist = 9.0, height = 3.4, look_h = 1.0,
    rate = 0.0035, -- orbit, rad/frame
  },
  anim = {
    ring_r = 4.6,      -- walkers' circle radius
    guy_rate = 0.008,  -- rad/frame around the ring
    mascot_rate = 0.007,
    guy_walk_f = 32,   -- frames per walk cycle
    mascot_walk_f = 36,
    idle_f = 120,      -- frames per idle breath cycle
  },
  look = { -- the N64 presentation (D3D-003/015, render-class)
    quant = 5,
    soft = 1,
  },
}

local FOG = { on = true, s = 28, e = 62, col = { 0.62, 0.70, 0.85 } }
local SKY_TOP = { 86 / 255, 154 / 255, 232 / 255 }
local SKY_BOT = { 171 / 255, 213 / 255, 242 / 255 }
local WHITE = { 1, 1, 1 }

local STAGE_R, STAGE_H = 2.4, 0.35

local tex, vbuf, segs, dyn, skybuf

local function build_sky()
  skybuf = pal.buf("rc.fig.sky", 6 * 24)
  local function sv(x, y, c)
    return string.pack("<fffffBBBB", x, y, 0.9999, 0, 0,
                       (c[1] * 255) // 1, (c[2] * 255) // 1,
                       (c[3] * 255) // 1, 255)
  end
  local v0, v1 = sv(-1, 1, SKY_TOP), sv(1, 1, SKY_TOP)
  local v2, v3 = sv(1, -1, SKY_BOT), sv(-1, -1, SKY_BOT)
  skybuf:setstr(0, v0 .. v1 .. v2 .. v0 .. v2 .. v3)
end

local function build_level()
  local out, sg, off = {}, {}, 0
  local function flush(mat, ntris)
    sg[#sg + 1] = { tex = tex[mat], count = ntris, off = off }
    off = off + ntris * 72
  end
  -- ground: 5-unit grass tiles (subdivided so per-vertex fog behaves)
  local n = 0
  for gz = -15, 10, 5 do
    for gx = -15, 10, 5 do
      n = n + gb.quad(out, { gx, 0, gz, 0, 0 }, { gx + 5, 0, gz, 2.5, 0 },
                      { gx + 5, 0, gz + 5, 2.5, 2.5 },
                      { gx, 0, gz + 5, 0, 2.5 }, WHITE, 0, 1, 0)
    end
  end
  flush("grass", n)
  -- the stage: a low 16-gon stone rostrum for the idle mascot
  flush("stone", gb.prism(out, nil, 16, STAGE_R, STAGE_R, STAGE_H, WHITE, 1))
  local bytes = table.concat(out)
  local ok, vb = pcall(pal.buf, "rc.fig.level", #bytes)
  if not ok then -- level geometry changed size across a hot reload
    pal.buf_free("rc.fig.level")
    vb = pal.buf("rc.fig.level", #bytes)
  end
  vb:setstr(0, bytes)
  vbuf, segs = vb, sg
end

function game.init()
  local d = state.doc
  d.knobs = d.knobs or {}
  for group, defaults in pairs(KNOBS) do
    d.knobs[group] = d.knobs[group] or {}
    for key, v in pairs(defaults) do
      if d.knobs[group][key] == nil then d.knobs[group][key] = v end
    end
    for key in pairs(d.knobs[group]) do
      if defaults[key] == nil then d.knobs[group][key] = nil end
    end
  end
  tex = gb.load_textures("rc.fig.texids")
  build_level()
  build_sky()
  -- dyn: per-frame figure verts (render-class scratch, rebuilt in draw)
  local ok, db = pcall(pal.buf, "rc.fig.dyn", 2200 * 72)
  if not ok then
    pal.buf_free("rc.fig.dyn")
    db = pal.buf("rc.fig.dyn", 2200 * 72)
  end
  dyn = db
end

function game.step()
  -- nothing: the whole showcase is a pure function of the frame counter
end

-- a walker's root on the ring: angle a, facing the tangent (+z forward)
local function ring_root(a, r)
  return m4.mul(m4.translate(m.sin(a) * r, 0, m.cos(a) * r),
                m4.roty(a + m.pi / 2))
end

function game.draw()
  pal.begin_frame(0, 0, 0, 1)

  local d = state.doc
  local kl = d.knobs.look
  if kl.quant > 0 then pal.x_grade{ quant = kl.quant } end
  if kl.soft > 0 then pal.x_soft(1) end

  -- sky: NDC passthrough gradient (fog off)
  pal.x_view3d()
  pal.x_tris(0, skybuf, 2, 0, 0)

  local f = state.frame()
  local kc, ka = d.knobs.cam, d.knobs.anim

  local yaw = f * kc.rate
  local ex = m.sin(yaw) * kc.dist
  local ez = m.cos(yaw) * kc.dist
  local view = m4.lookat(ex, kc.height, ez, 0, kc.look_h, 0, 0, 1, 0)
  local proj = m4.persp(FOVY, W / H, ZN, ZF)
  pal.x_view3d{
    mvp = m4.mul(proj, view),
    fog_start = FOG.s, fog_end = FOG.e, fog = FOG.col, fog_on = FOG.on,
  }

  for _, s in ipairs(segs) do
    pal.x_tris(s.tex, vbuf, s.count, s.off, 0)
  end

  -- the figures (untextured pre-lit, tex 0)
  local out, n = {}, 0
  -- idle mascot on the stage
  local idle = fig.cycle(chars.mascot_idle, f / ka.idle_f)
  n = n + fig.emit(out, chars.mascot,
                   m4.mul(m4.translate(0, STAGE_H, 0), m4.roty(-0.2)), idle)
  -- walking mascot + guy sharing the ring, half a turn apart
  local am = f * ka.mascot_rate
  n = n + fig.emit(out, chars.mascot, ring_root(am, ka.ring_r),
                   fig.cycle(chars.mascot_walk, f / ka.mascot_walk_f))
  local ag = f * ka.guy_rate + m.pi
  n = n + fig.emit(out, chars.guy, ring_root(ag, ka.ring_r),
                   fig.cycle(chars.guy_walk, f / ka.guy_walk_f))
  dyn:setstr(0, table.concat(out))
  pal.x_tris(0, dyn, n, 0, 0)

  local st = pal.frame_stats()
  text.draw(3, 3, ("figure  %d tris  frame %d"):format(st.tris or 0, f))
  text.draw(3, H - 11, "cm.fig: the mascot + the guy (D3D-005)")
end

return game
