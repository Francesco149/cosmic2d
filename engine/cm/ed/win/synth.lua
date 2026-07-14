-- cm.ed.win.synth — the instrument editor (R9c, AUDIO.md §9): binds
-- .ins (CINS), a full windowkit asset citizen — journal, dirty dot,
-- ctrl+Z/S, unsaved-persists, rewind bring-back. FM-synth'd sounds
-- open here (double-click an .ins anywhere); the unbound path field
-- creates a fresh one from the init patch.
--
-- Mouse-first, one screen: algorithm chips, feedback chips, gain/pan
-- sliders, 4 operator panels (wave chips, coarse/fine/level/detune
-- sliders, a draggable ADSR graph), the audition piano (two octaves;
-- per-window hotkeys give the tracker keyboard). Every edit re-sends
-- the patch to the EDITOR bank live — tweak while a note rings; one
-- finished gesture = one journal entry (the R8 gesture rule).
--
-- The preset strip (header chip) lists engine/stock/ins/* + the
-- project's own .ins files; click = load into the working bytes
-- (journaled, undoable).

local M = select(2, ...) or {}
local ins = cm.require("cm.ins")
local snd = cm.require("cm.snd")

M.kind = "synth"
M.menu = "synth"
M.exts = { "ins" }
M.DEF_W, M.DEF_H = 560, 512
M.JCAP = 512

local COL = {
  rail = 0x1a1728ff, well = 0x141220ff, btn = 0x262238ff,
  btn_on = 0x4a4370ff, text = 0xd8d2f2ff, dim = 0x8a84b0ff,
  hot = 0xE8E4FFff, accent = 0x7fd8a8ff, env = 0x7fd8a8ff,
  envfill = 0x7fd8a822, slider = 0x4a4370ff, knob = 0xd8d2f2ff,
  white = 0xd8d2f2ff, black = 0x262238ff, press = 0x7fd8a8ff,
}

local WAVE_CHIPS = { { "sine", "sin" }, { "square", "sq" },
                     { "pulse25", "p25" }, { "pulse12", "p12" },
                     { "saw", "saw" }, { "tri", "tri" },
                     { "noise", "ns" }, { "noise2", "ns2" } }

function M.defaults()
  return { path = "", oct = 4 }
end

function M.title(win)
  return win.path:match("([^/]+)$") or "synth"
end

function M.accepts(win, path)
  return path:lower():find("%.ins$") ~= nil
end

function M.rebind(win, ed, path)
  win.path = path
  ed.touch()
end

-- ---- the asset citizen (cm.ed.kit) ----

local function decode_into(p, bytes)
  local ok, doc = pcall(ins.decode, bytes)
  if ok then
    p.doc = doc
    p.err = nil
  else
    p.doc = nil
    p.err = tostring(doc)
  end
  p.send = true -- re-audition the adopted patch
end

local A = cm.require("cm.ed.kit").asset {
  gkey = "iw", field = "ins", jcap = M.JCAP,
  fresh = function(ed, path)
    local name = path:match("([^/]+)%.ins$") or "instrument"
    return ins.encode(ins.fresh(name))
  end,
  adopt = decode_into,
  encode = ins.encode,
}

local plumb, working, open_asset, commit =
  A.plumb, A.working, A.open_asset, A.commit

M.open_win = A.open_win
M.open_path = A.open_asset -- the music window binds tracks through
M.commit_path = A.commit   -- these doors (R9d)
M.dirty, M.save, M.undo, M.redo, M.revert =
  A.dirty, A.save, A.undo, A.redo, A.revert

-- ---- the editor-bank audition ----

local function audition(ed, win, p)
  if not p.doc then return end
  if not p.edslot then
    local slot, vbase = cm.require("cm.ed.kit").snd_alloc(ed, 4)
    p.edslot, p.vbase, p.vnext = slot, vbase, 0
    p.held = {}
  end
  if p.send then
    ins.upload(p.doc, p.edslot, "ed", "s" .. win.id)
    p.send = nil
  end
end

local function note_on(ed, win, note)
  local p = plumb(ed, win.path)
  if not p.doc then return end
  audition(ed, win, p)
  if p.held[note] then return end
  local v = p.vbase + p.vnext % 4
  p.vnext = p.vnext + 1
  pal.x_snd_ed_on(v, p.edslot, note, 110)
  p.held[note] = v
end

local function note_off(ed, win, note)
  local p = plumb(ed, win.path)
  if p.held and p.held[note] then
    pal.x_snd_ed_off(p.held[note])
    p.held[note] = nil
  end
end

-- the tracker keyboard (per-window hotkeys, §13): zsxdc… = the low
-- octave, q2w3e… = the octave above; ,/. shift the base octave
local KEYROW = { -- key name -> semitone offset from win.oct's C
  z = 0, s = 1, x = 2, d = 3, c = 4, v = 5, g = 6, b = 7, h = 8,
  n = 9, j = 10, m = 11,
  q = 12, ["2"] = 13, w = 14, ["3"] = 15, e = 16, r = 17, ["5"] = 18,
  t = 19, ["6"] = 20, y = 21, ["7"] = 22, u = 23, i = 24,
}
local bound = function(win) return win.path ~= "" end
M.hotkeys = {
  { key = ",", hint = "oct−", when = bound,
    fn = function(win, ed)
      win.oct = math.max(1, (win.oct or 4) - 1)
      ed.touch()
    end },
  { key = ".", hint = "oct+", when = bound,
    fn = function(win, ed)
      win.oct = math.min(7, (win.oct or 4) + 1)
      ed.touch()
    end },
}
for keyname, off in pairs(KEYROW) do
  M.hotkeys[#M.hotkeys + 1] = {
    key = keyname, when = bound,
    fn = function(win, ed)
      local note = 12 * ((win.oct or 4) + 1) + off
      note_on(ed, win, note)
      local p = plumb(ed, win.path)
      p.kdecay = p.kdecay or {}
      p.kdecay[note] = 12 -- frames until auto-release (no key-up
                          -- dispatch in the hotkey table — short blip)
    end }
end

function M.escape(win, ed) -- silence everything ringing
  local p = ed.g.iw and ed.g.iw[win.path]
  if p and p.held and next(p.held) then
    for note, v in pairs(p.held) do
      pal.x_snd_ed_off(v)
      p.held[note] = nil
    end
    return true
  end
  return false
end

-- ---- widgets ----

local function chiprow(p, ctx, x, y, w, h, items, cur, id)
  local i = cm.require("cm.ui").inp
  local px = math.max(4, 9 * ctx.z)
  local cw = w / #items
  local picked
  for n, item in ipairs(items) do
    local cx = x + (n - 1) * cw
    local on = cur == (item.value ~= nil and item.value or n - 1)
    local hov = ctx.hot and i.wx >= cx and i.wx < cx + cw - 2 * ctx.z
                and i.wy >= y and i.wy < y + h
    pal.x_ig_rect_fill(cx, y, cw - 2 * ctx.z, h,
                       on and COL.btn_on or COL.btn, 3 * ctx.z)
    pal.x_ig_text(cx + (cw - 2 * ctx.z - pal.x_ig_text_size(item.label, px, 0)) * 0.5,
                  y + (h - px) * 0.45, px,
                  (hov or on) and COL.hot or COL.dim, item.label, 0)
    if hov and i.clicked[1] then picked = item.value ~= nil and item.value or n - 1 end
  end
  return picked
end

-- a horizontal drag slider; returns the new value while dragging and
-- "done" (true) on release — the gesture-end journal hook
local function slider(p, ctx, id, x, y, w, h, val, lo, hi, label, fmt)
  local i = cm.require("cm.ui").inp
  local z = ctx.z
  local px = math.max(4, 8.5 * z)
  pal.x_ig_text(x, y, px, COL.dim, label, 0)
  local bx, bw = x + 34 * z, w - 70 * z
  local by, bh = y + px * 0.15, math.max(3, px * 0.7)
  pal.x_ig_rect_fill(bx, by, bw, bh, COL.well, 2 * z)
  local f = (val - lo) / (hi - lo)
  pal.x_ig_rect_fill(bx, by, bw * f, bh, COL.slider, 2 * z)
  pal.x_ig_rect_fill(bx + bw * f - 1.5 * z, by - 1 * z, 3 * z, bh + 2 * z,
                     COL.knob, 1 * z)
  pal.x_ig_text(bx + bw + 4 * z, y, px, COL.text,
                (fmt or "%d"):format(val), 0)
  local over = i.wx >= bx - 4 * z and i.wx < bx + bw + 4 * z
               and i.wy >= y - 2 * z and i.wy < y + bh + 4 * z
  if ctx.hot and i.clicked[1] and over and not p.drag then
    p.drag = id
  end
  if p.drag == id then
    if i.buttons[1] then
      local nf = math.max(0, math.min(1, (i.wx - bx) / bw))
      local nv = lo + nf * (hi - lo)
      if hi - lo > 2 then nv = math.floor(nv + 0.5) end
      return nv, false
    end
    p.drag = nil
    return val, true -- released: close the gesture
  end
  return nil, false
end

-- envelope time axis: LOGARITHMIC, so equal pixels = equal ratios. The
-- short-end feels (a plucky 2 ms vs a soft 30 ms vs a pad 300 ms attack)
-- spread across the whole axis instead of crowding the first few pixels
-- — and a long smooth attack is still reachable at the far right (the
-- human: tiny nudges made huge differences, distinct feels 1–2 px apart).
-- fx = 0 pins to 0 (instant). DRAW and DRAG share this mapping: the old
-- graph drew handles linearly (a/2000) but dragged them squared, so a
-- handle jumped the instant you grabbed it — the other half of the
-- awkwardness. Editor-only math; libm off the sim is fine.
local ENV_TMIN = 1 -- ms at the bottom of the log sweep
local function env_fx_to_ms(fx, tmax)
  if fx <= 0.0015 then return 0 end
  return math.floor(ENV_TMIN * (tmax / ENV_TMIN) ^ fx + 0.5)
end
local function env_ms_to_fx(ms, tmax)
  if ms <= ENV_TMIN then return 0 end
  return math.max(0, math.min(1,
    math.log(ms / ENV_TMIN) / math.log(tmax / ENV_TMIN)))
end
M.env_fx_to_ms, M.env_ms_to_fx = env_fx_to_ms, env_ms_to_fx -- KAT hooks
local A_MAX, D_MAX, R_MAX = 2000, 2000, 4000

-- the ADSR graph: three fixed thirds — attack | decay·sustain | release.
-- A/D/R drag horizontally within their third (log-mapped), sustain drags
-- vertically in the middle third. A value readout shows while dragging.
local function adsr(p, ctx, id, x, y, w, h, op)
  local i = cm.require("cm.ui").inp
  local z = ctx.z
  pal.x_ig_rect_fill(x, y, w, h, COL.well, 3 * z)
  local a, d, r = op.a or 5, op.d or 100, op.r or 80
  local s = (op.s or 200) / 255
  local third = w / 3
  local top, base = y + 2 * z, y + h - 2 * z
  local ax = x + third * env_ms_to_fx(a, A_MAX)
  local dx = x + third + third * env_ms_to_fx(d, D_MAX)
  local rex = x + 2 * third + third * env_ms_to_fx(r, R_MAX)
  local sy = y + h - h * s * 0.92 - h * 0.04
  -- faint stage-boundary guides so A | D·S | R read as regions
  pal.x_ig_line(x + third, y, x + third, y + h, 0xffffff10, 1)
  pal.x_ig_line(x + 2 * third, y, x + 2 * third, y + h, 0xffffff10, 1)
  -- 0 -> peak -> decay to sustain -> hold -> release to 0
  pal.x_ig_line(x, base, ax, top, COL.env, 1.5 * z)
  pal.x_ig_line(ax, top, dx, sy, COL.env, 1.5 * z)
  pal.x_ig_line(dx, sy, x + 2 * third, sy, COL.env, 1.5 * z)
  pal.x_ig_line(x + 2 * third, sy, rex, base, COL.env, 1.5 * z)
  -- hovered/dragged handle glows so the grab point is unmistakable
  local over = i.wx >= x and i.wx < x + w and i.wy >= y and i.wy < y + h
  local hpart = ctx.hot and over and ((i.wx - x) / w < 1 / 3 and "a"
                          or (i.wx - x) / w < 2 / 3 and "ds" or "r")
  local dragging = p.drag and p.drag:sub(1, #id) == id and p.drag:sub(#id + 1)
  for _, hk in ipairs({ { "a", ax, top }, { "ds", dx, sy }, { "r", rex, base } }) do
    local lit = dragging == hk[1] or (not p.drag and hpart == hk[1])
    pal.x_ig_circle_fill(hk[2], hk[3], (lit and 4 or 2.5) * z,
                         lit and COL.hot or COL.knob)
  end
  if ctx.hot and i.clicked[1] and over and not p.drag then
    p.drag = id .. hpart
  end
  local changed, label
  local function part_fx(base_x)
    return math.max(0, math.min(1, (i.wx - base_x) / third))
  end
  if dragging == "a" then
    if i.buttons[1] then
      op.a = env_fx_to_ms(part_fx(x), A_MAX)
      changed, label = "live", ("A %dms"):format(op.a)
    else p.drag = nil; changed = "done" end
  elseif dragging == "ds" then
    if i.buttons[1] then
      op.d = env_fx_to_ms(part_fx(x + third), D_MAX)
      op.s = math.floor(math.max(0, math.min(1,
        1 - (i.wy - y - h * 0.04) / (h * 0.92))) * 255 + 0.5)
      changed, label = "live", ("D %dms  S %d"):format(op.d, op.s)
    else p.drag = nil; changed = "done" end
  elseif dragging == "r" then
    if i.buttons[1] then
      op.r = env_fx_to_ms(part_fx(x + 2 * third), R_MAX)
      changed, label = "live", ("R %dms"):format(op.r)
    else p.drag = nil; changed = "done" end
  end
  if label then
    pal.x_ig_text(x + 3 * z, y + 2 * z, math.max(4, 8 * z), COL.hot, label, 0)
  end
  return changed
end

-- ---- the presets strip ----

-- stock lives at the ENGINE root — which is the process cwd by
-- construction (main.c fixup_cwd), never derived from ed.root (game
-- repos and scratch projects live anywhere)
local function preset_list(ed, p)
  if p.presets then return p.presets end
  local out = {}
  local dirs = { { "stock", "engine/stock/ins" },
                 { "project", ed.root .. "/ins" } }
  for _, d in ipairs(dirs) do
    local names = pal.list_dir(d[2]) or {}
    table.sort(names)
    for _, n in ipairs(names) do
      if n:lower():find("%.ins$") then
        out[#out + 1] = {
          label = n:gsub("%.ins$", ""), file = d[2] .. "/" .. n,
          from = d[1],
          -- the path a drag carries: project presets are already
          -- project-relative; stock stays engine-relative (the drop
          -- target copies it in — music.drop)
          drag = d[1] == "project" and ("ins/" .. n) or (d[2] .. "/" .. n),
        }
      end
    end
  end
  p.presets = out
  return out
end

-- ---- header ----

function M.header(win, ctx)
  if win.path == "" then return 0 end
  local s = cm.require("cm.ed.chips").strip(ctx)
  if s:chip("presets", win.pre or false) then
    win.pre = not win.pre
    ctx.ed.touch()
  end
  return s.used
end

-- ---- draw ----

function M.draw(win, ctx)
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  local ed = ctx.ed
  if win.path == "" then
    -- the kit's new-file prompt (forced .ins, overwrite-aware)
    A.pathfield(win, ed, ctx, { ext = "ins", default = "ins/",
                                label = "new instrument path:" })
    return
  end

  local a, p = open_asset(ed, win.path)
  if p.err then
    pal.x_ig_text(ctx.cx + 6 * z, ctx.cy + 6 * z, px, 0xf07a7aff,
                  "bad .ins: " .. p.err, 0)
    return
  end
  local doc = p.doc
  if not doc then return end
  audition(ed, win, p)

  -- auto-release tracker-key blips
  if p.kdecay then
    for note, left in pairs(p.kdecay) do
      if left <= 0 then
        note_off(ed, win, note)
        p.kdecay[note] = nil
      else
        p.kdecay[note] = left - 1
      end
      ctx.touch()
    end
  end

  local x0, y0 = ctx.cx + 4 * z, ctx.cy + 4 * z
  local cw = ctx.cw - 8 * z
  local patch = doc.patch
  local edited, closed -- live edit / gesture end

  -- presets rail (toggled): eats the left column
  if win.pre then
    local rw = math.min(130 * z, cw * 0.35)
    pal.x_ig_rect_fill(x0, y0, rw - 4 * z, ctx.ch - 12 * z, COL.rail, 3 * z)
    local i = cm.require("cm.ui").inp
    local ry = y0 + 4 * z
    for _, item in ipairs(preset_list(ed, p)) do
      if ry > y0 + ctx.ch - 24 * z then break end
      local hov = ctx.hot and i.wx >= x0 and i.wx < x0 + rw - 8 * z
                  and i.wy >= ry and i.wy < ry + px * 1.3
      pal.x_ig_text(x0 + 6 * z, ry, px * 0.92,
                    hov and COL.hot or COL.text, item.label, 0)
      pal.x_ig_text(x0 + rw - 40 * z, ry, px * 0.75, COL.dim, item.from, 0)
      -- press ARMS a click-or-drag on this row (resolved below): a
      -- click loads the preset; a drag carries it to a sequencer track
      if hov and i.clicked[1] then
        p.pdrag = { item = item, sx = i.wx, sy = i.wy }
      end
      ry = ry + px * 1.45
    end
    -- resolve the armed preset gesture (round 5, the human): moved past
    -- the threshold = a drag-out (the shell's g.adrag carries it — a
    -- music track's kind.drop binds it); released in place = a load
    if p.pdrag then
      local wmm = cm.require("cm.ed.wm")
      if i.buttons[1] then
        if math.abs(i.wx - p.pdrag.sx) > wmm.DRAG_PX
           or math.abs(i.wy - p.pdrag.sy) > wmm.DRAG_PX then
          ed.g.adrag = { path = p.pdrag.item.drag, sx = p.pdrag.sx,
                         sy = p.pdrag.sy, from = win.id }
          p.pdrag = nil
        end
      else
        local bytes = pal.read_file(p.pdrag.item.file)
        p.pdrag = nil
        if bytes then
          local ok, d2 = pcall(ins.decode, bytes)
          if ok then
            d2.name = doc.name -- keep the asset's own name
            p.doc = d2
            commit(ed, win.path) -- one journaled, undoable step
            p.send = true
          end
        end
      end
    end
    x0 = x0 + rw
    cw = cw - rw
  end

  -- top row: type-aware controls
  local y = y0
  if patch.type == "fm" or patch.type == nil then
    local alg = chiprow(p, ctx, x0, y, cw * 0.55, px * 1.6, {
      { label = "1" }, { label = "2" }, { label = "3" }, { label = "4" },
      { label = "5" }, { label = "6" }, { label = "7" }, { label = "8" },
    }, patch.alg or 0, "alg")
    if alg then
      patch.alg = alg
      edited, closed = true, true
    end
    local fb = chiprow(p, ctx, x0 + cw * 0.58, y, cw * 0.42, px * 1.6, {
      { label = "fb0" }, { label = "fb1" }, { label = "fb2" },
      { label = "fb3" }, { label = "fb4" }, { label = "fb5" },
      { label = "fb6" }, { label = "fb7" },
    }, patch.fb or 0, "fb")
    if fb then
      patch.fb = fb
      edited, closed = true, true
    end
    y = y + px * 2.0

    local nv, done = slider(p, ctx, "gain", x0, y, cw * 0.5, px * 1.4,
                            patch.gain or 128, 0, 255, "gain")
    if nv then patch.gain = nv; edited = true end
    closed = closed or done
    nv, done = slider(p, ctx, "pan", x0 + cw * 0.5, y, cw * 0.5, px * 1.4,
                      patch.pan or 0, -64, 64, "pan")
    if nv then patch.pan = nv; edited = true end
    closed = closed or done
    y = y + px * 1.6

    -- voice fx (R9f): a 1-pole filter (hp = the GB noise "sizzle") and a
    -- pitch sweep (dash / whoosh / kick-drop). off / 0 = bypass.
    local flt = chiprow(p, ctx, x0, y, cw * 0.30, px * 1.4, {
      { label = "flt", value = "off" }, { label = "lp", value = "lp" },
      { label = "hp", value = "hp" },
    }, patch.filter or "off", "flt")
    if flt then patch.filter = flt; edited, closed = true, true end
    nv, done = slider(p, ctx, "cut", x0 + cw * 0.32, y, cw * 0.68, px * 1.4,
                      patch.cutoff or 0, 0, 255, "cut")
    if nv then patch.cutoff = nv; edited = true end
    closed = closed or done
    y = y + px * 1.5
    nv, done = slider(p, ctx, "swp", x0, y, cw * 0.5, px * 1.4,
                      patch.sweep or 0, -48, 48, "swp")
    if nv then patch.sweep = nv; edited = true end
    closed = closed or done
    nv, done = slider(p, ctx, "swms", x0 + cw * 0.5, y, cw * 0.5, px * 1.4,
                      patch.sweep_ms or 0, 0, 1000, "sw ms")
    if nv then patch.sweep_ms = nv; edited = true end
    closed = closed or done
    y = y + px * 1.7

    -- 4 operator panels, 2x2
    local pw, ph = cw / 2 - 3 * z, (ctx.ch - (y - ctx.cy) - 60 * z) / 2 - 4 * z
    for o = 1, 4 do
      local ox = x0 + ((o - 1) % 2) * (pw + 6 * z)
      local oy = y + ((o - 1) // 2) * (ph + 6 * z)
      local op = patch.ops[o]
      pal.x_ig_rect_fill(ox, oy, pw, ph, COL.rail, 3 * z)
      pal.x_ig_text(ox + 4 * z, oy + 3 * z, px * 0.9, COL.accent,
                    "op" .. o, 0)
      local wv = chiprow(p, ctx, ox + 30 * z, oy + 2 * z, pw - 34 * z,
                         px * 1.4, (function()
        local items = {}
        for _, wc in ipairs(WAVE_CHIPS) do
          items[#items + 1] = { label = wc[2], value = wc[1] }
        end
        return items
      end)(), op.wave or "sine", "wv" .. o)
      if wv then
        op.wave = wv
        edited, closed = true, true
      end
      local sy = oy + px * 1.9
      local sh = px * 1.25
      nv, done = slider(p, ctx, "lv" .. o, ox + 4 * z, sy, pw - 8 * z, sh,
                        op.level or 0, 0, 255, "lvl")
      if nv then op.level = nv; edited = true end
      closed = closed or done
      nv, done = slider(p, ctx, "co" .. o, ox + 4 * z, sy + sh, pw - 8 * z,
                        sh, op.coarse or 1, 0, 15, "crs")
      if nv then op.coarse = nv; edited = true end
      closed = closed or done
      nv, done = slider(p, ctx, "fi" .. o, ox + 4 * z, sy + sh * 2,
                        pw - 8 * z, sh, op.fine or 0, -63, 63, "fin")
      if nv then op.fine = nv; edited = true end
      closed = closed or done
      local ch2 = adsr(p, ctx, "env" .. o, ox + 4 * z, sy + sh * 3 + 2 * z,
                       pw - 8 * z, math.max(10, ph - (sh * 3 + px * 2.4)),
                       op)
      if ch2 then
        edited = true
        closed = closed or ch2 == "done"
      end
    end
    y = y + 2 * (ph + 6 * z)
  else -- sample / stream instruments: fields + envelope
    pal.x_ig_text(x0, y, px, COL.dim,
                  ("sample · root %d · %s"):format(patch.root or 60,
                    patch.loop and "loop" or "one-shot"), 0)
    y = y + px * 1.5
    local nv, done = slider(p, ctx, "root", x0, y, cw * 0.5, px * 1.4,
                            patch.root or 60, 0, 127, "root")
    if nv then patch.root = nv; edited = true end
    closed = closed or done
    nv, done = slider(p, ctx, "gain", x0 + cw * 0.5, y, cw * 0.5, px * 1.4,
                      patch.gain or 128, 0, 255, "gain")
    if nv then patch.gain = nv; edited = true end
    closed = closed or done
    y = y + px * 1.8
    local ch2 = adsr(p, ctx, "senv", x0, y, cw, px * 6, patch)
    if ch2 then
      edited = true
      closed = closed or ch2 == "done"
    end
    y = y + px * 6.5
  end

  -- live audition of edits + the gesture-end journal entry. Upload
  -- p.doc, NOT the local — a preset click replaces p.doc mid-draw and
  -- the stale local made the sound lag one click behind the UI (human,
  -- morning round)
  if edited then p.send = true end
  if p.send then
    ins.upload(p.doc, p.edslot, "ed", "s" .. win.id)
    p.send = nil
    ctx.touch()
  end
  if closed then commit(ed, win.path) end

  -- ---- the piano (two octaves from win.oct) ----
  local kb_y = ctx.cy + ctx.ch - 44 * z
  local kb_h = 40 * z
  local white_n = 15 -- two octaves + the top C
  local kw = cw / white_n
  local i = cm.require("cm.ui").inp
  local base = 12 * ((win.oct or 4) + 1)
  local WHITE = { 0, 2, 4, 5, 7, 9, 11 }
  p.piano = p.piano or {}
  local hitnote
  for n = 0, white_n - 1 do
    local note = base + WHITE[n % 7 + 1] + 12 * (n // 7)
    local kx = x0 + n * kw
    local held = p.held and p.held[note]
    pal.x_ig_rect_fill(kx, kb_y, kw - 1 * z, kb_h,
                       held and COL.press or COL.white, 2 * z)
    if ctx.hot and i.wx >= kx and i.wx < kx + kw
       and i.wy >= kb_y and i.wy < kb_y + kb_h then
      hitnote = note
    end
  end
  for n = 0, white_n - 2 do
    local deg = n % 7
    if deg ~= 2 and deg ~= 6 then -- no black key after E and B
      local note = base + WHITE[deg + 1] + 1 + 12 * (n // 7)
      local kx = x0 + (n + 0.65) * kw
      local held = p.held and p.held[note]
      pal.x_ig_rect_fill(kx, kb_y, kw * 0.7, kb_h * 0.6,
                         held and COL.press or COL.black, 2 * z)
      if ctx.hot and i.wx >= kx and i.wx < kx + kw * 0.7
         and i.wy >= kb_y and i.wy < kb_y + kb_h * 0.6 then
        hitnote = note
      end
    end
  end
  pal.x_ig_text(x0 + 2 * z, kb_y - px * 1.3, px * 0.85, COL.dim,
                ("oct %d  (z-m / q-i keys, ,/. shift)"):format(win.oct or 4), 0)
  if hitnote and i.clicked[1] and not p.drag then
    note_on(ed, win, hitnote)
    p.pianodown = hitnote
    ctx.touch()
  end
  if p.pianodown and not i.buttons[1] then
    note_off(ed, win, p.pianodown)
    p.pianodown = nil
    ctx.touch()
  end
end

return M
