-- cm.ed.win.music — the music editor (R9d, AUDIO.md §10): binds .song
-- (CSNG), a full windowkit asset citizen. Three zones: the track rail
-- (left — drag an .ins from the assets window onto a row to bind it),
-- the arrangement strip (bar timeline — press empty stamps the current
-- pattern, drag moves by bars, the right edge resizes; content loops
-- to fill), and the piano roll (the wstudio four-rule mouse grammar:
-- press empty = ADD a note at the last-used length, grid-snapped;
-- motionless release on a note = DELETE it; press-drag = MOVE in
-- pitch + time; right-edge drag = RESIZE. CTRL while dragging = fine
-- ticks — the one deliberate D058 grammar inversion: the roll's grid
-- is its ground state, CTRL means "the precise variant"). A velocity
-- lane sits under the roll (drag bars).
--
-- The roll edits PATTERNS (selected via the transport chips); the
-- arrangement stamps them — editing a pattern updates every placement
-- (the pattern/tracker model; per-clip copy-on-write can grow later).
--
-- Preview playback rides the EDITOR BANK (render-only — composing
-- never touches the sim): a wall-clock mini-sequencer over the same
-- flatten. The GAME plays the same file via cm.snd.music — sim state,
-- recorded, rewound. One finished gesture = one journal entry.

local M = select(2, ...) or {}
local song = cm.require("cm.song")
local snd = cm.require("cm.snd")

M.kind = "music"
M.menu = "music"
M.exts = { "song" }
M.DEF_W, M.DEF_H = 720, 440
M.JCAP = 512

local PPQ = song.PPQ
local COL = {
  rail = 0x1a1728ff, well = 0x141220ff, btn = 0x262238ff,
  btn_on = 0x4a4370ff, text = 0xd8d2f2ff, dim = 0x8a84b0ff,
  hot = 0xE8E4FFff, accent = 0x7fd8a8ff, note = 0x7fd8a8ff,
  note_dim = 0x4a8a6cff, gridln = 0x2a263caa, beatln = 0x38334fee,
  clip = 0x4a4370ff, clip_hot = 0x5a5390ff, head = 0xE8E4FFff,
  vel = 0x7fb8f0ff, black_row = 0xffffff06, err = 0xf07a7aff,
}
local GRIDS = { PPQ * 4, PPQ * 2, PPQ, PPQ // 2, PPQ // 4, PPQ // 8 }
local GRID_LABEL = { "1/1", "1/2", "1/4", "1/8", "1/16", "1/32" }

function M.defaults()
  return { path = "", pat = 1, trk = 1, grid = 4, tpp = 0.5, lownote = 45 }
end

function M.title(win)
  return win.path:match("([^/]+)$") or "music"
end

function M.accepts(win, path)
  return path:lower():find("%.song$") ~= nil
end

function M.rebind(win, ed, path)
  win.path = path
  ed.touch()
end

-- ---- the asset citizen ----

local function decode_into(p, bytes)
  local ok, doc = pcall(song.decode, bytes)
  if ok then
    p.doc = doc
    p.err = nil
  else
    p.doc = nil
    p.err = tostring(doc)
  end
  p.flat = nil -- preview cache
end

local A = cm.require("cm.ed.kit").asset {
  gkey = "muw", field = "song", jcap = M.JCAP,
  fresh = function() return song.encode(song.fresh()) end,
  adopt = decode_into,
  encode = song.encode,
}

local plumb, working, open_asset, commit =
  A.plumb, A.working, A.open_asset, A.commit
M.open_win = A.open_win
M.dirty, M.save, M.undo, M.redo, M.revert =
  A.dirty, A.save, A.undo, A.redo, A.revert

-- ---- the editor-bank preview (render-only, wall clock) ----

local function preview_stop(p)
  if not p.playing then return end
  for _, h in pairs(p.pheld or {}) do pal.x_snd_ed_off(h) end
  p.pheld, p.playing = {}, false
end

local function preview_slots(ed, win, p)
  local doc = p.doc
  p.pslots = p.pslots or {}
  for ti, tr in ipairs(doc.tracks) do
    if not p.pslots[ti] then
      local slot = cm.require("cm.ed.kit").snd_alloc(ed, 0)
      p.pslots[ti] = slot
    end
    if tr.ins ~= "" and p.pins_sent ~= true then
      local bytes = pal.read_file(ed.root .. "/" .. tr.ins)
                    or pal.read_file(tr.ins)
      if bytes then
        local ok, idoc = pcall(cm.require("cm.ins").decode, bytes)
        if ok then
          cm.require("cm.ins").upload(idoc, p.pslots[ti], "ed",
                                      "m" .. win.id .. "t" .. ti)
        end
      end
    end
  end
  p.pins_sent = true
end

local function preview_start(ed, win, p)
  preview_stop(p)
  preview_slots(ed, win, p)
  p.flat = p.flat or song.flatten(p.doc)
  p.playing = true
  p.pheld = {}
  p.pt0 = pal.time_ns()
  p.ppos = 0 -- samples consumed (song space)
  p.pvoice = p.pvoice or 8 -- round-robin base; editor voices 8..31
end

-- one editor frame of preview: emit ons/offs for the wall-clock window
local function preview_step(ed, win, p)
  if not p.playing then return end
  local doc = p.doc
  local L = song.length(doc)
  local SL = snd.seq.samples_at(L, doc.bpm)
  if SL <= 0 then
    preview_stop(p)
    return
  end
  local now = (pal.time_ns() - p.pt0) * 48000 // 1000000000
  local s0, s1 = p.ppos, now
  if s1 <= s0 then return end
  if s1 - s0 > 48000 then s0 = s1 - 4800 end -- a stall skips, no burst
  p.ppos = s1
  local w0, w1 = s0 % SL, nil
  local spans
  if (s1 - s0) >= SL then
    spans = { { 0, SL } } -- degenerate: the whole song at once
  elseif w0 + (s1 - s0) <= SL then
    spans = { { w0, w0 + (s1 - s0) } }
  else
    spans = { { w0, SL }, { 0, w0 + (s1 - s0) - SL } }
  end
  for _, sp in ipairs(spans) do
    local t0 = snd.seq.ticks_at(sp[1], doc.bpm)
    local t1 = snd.seq.ticks_at(sp[2], doc.bpm)
    if sp[2] >= SL then t1 = L end
    for key, h in pairs(p.pheld) do
      local off = tonumber(key:match(":(%d+)$"))
      if off >= t0 and (off < t1 or (off == t1 and t1 == L)) then
        pal.x_snd_ed_off(h)
        p.pheld[key] = nil
      end
    end
    for ti, lane in ipairs(p.flat) do
      local tr = doc.tracks[ti]
      if not (tr and tr.mute) and p.pslots[ti] then
        for _, n in ipairs(lane) do
          if n.tick >= t1 then break end
          if n.tick >= t0 then
            local v = 8 + (p.pvoice % 24)
            p.pvoice = p.pvoice + 1
            pal.x_snd_ed_on(v, p.pslots[ti], n.pitch, n.vel)
            p.pheld[ti .. ":" .. n.tick .. ":" .. n.pitch .. ":"
                    .. (n.tick + n.dur)] = v
          end
        end
      end
    end
  end
end

-- a one-note audition blip (add/drag feedback)
local function blip(ed, win, p, pitch, vel)
  preview_slots(ed, win, p)
  local slot = p.pslots[win.trk or 1]
  if not slot then return end
  local v = 8 + ((p.pvoice or 8) % 24)
  p.pvoice = (p.pvoice or 8) + 1
  pal.x_snd_ed_on(v, slot, pitch, vel or 100)
  p.blips = p.blips or {}
  p.blips[v] = 10
end

-- ---- hotkeys ----

local bound = function(win) return win.path ~= "" end
M.hotkeys = {
  { key = "space", hint = "play/stop", when = bound,
    fn = function(win, ed)
      local _, p = open_asset(ed, win.path)
      if p.playing then preview_stop(p) else preview_start(ed, win, p) end
      ed.touch()
    end },
  { key = "del", hint = "del clip", when = bound,
    fn = function(win, ed)
      local _, p = open_asset(ed, win.path)
      if p.csel and p.doc and p.doc.clips[p.csel] then
        table.remove(p.doc.clips, p.csel)
        p.csel = nil
        p.flat = nil
        commit(ed, win.path)
      end
    end },
}
for i2 = 1, 6 do
  M.hotkeys[#M.hotkeys + 1] = {
    key = tostring(i2), when = bound,
    fn = function(win, ed)
      win.grid = i2
      ed.touch()
    end }
end

function M.escape(win, ed)
  local p = ed.g.muw and ed.g.muw[win.path]
  if p and p.playing then
    preview_stop(p)
    return true
  end
  return false
end

-- ---- draw helpers ----

local function is_black(pitch)
  local d = pitch % 12
  return d == 1 or d == 3 or d == 6 or d == 8 or d == 10
end

-- ---- draw ----

function M.draw(win, ctx)
  local z = ctx.z
  local px = math.max(4, 10 * z)
  local ed = ctx.ed
  if win.path == "" then
    -- the kit's new-file prompt (forced .song, overwrite-aware)
    A.pathfield(win, ed, ctx, { ext = "song", default = "sound/",
                                label = "new song path:" })
    return
  end
  local a, p = open_asset(ed, win.path)
  if p.err then
    pal.x_ig_text(ctx.cx + 6 * z, ctx.cy + 6 * z, px, COL.err,
                  "bad .song: " .. p.err, 0)
    return
  end
  local doc = p.doc
  if not doc then return end
  local i = cm.require("cm.ui").inp

  preview_step(ed, win, p)
  if p.playing then ctx.touch() end
  if p.blips then -- release audition blips
    for v, left in pairs(p.blips) do
      if left <= 0 then
        pal.x_snd_ed_off(v)
        p.blips[v] = nil
      else
        p.blips[v] = left - 1
      end
    end
    ctx.touch()
  end

  -- ---- geometry ----
  local RAIL = math.min(120 * z, ctx.cw * 0.22)
  local TR_H = px * 1.9  -- transport row
  local AR_H = 30 * z    -- arrangement strip
  local VEL_H = 30 * z   -- velocity lane
  local x0, y0 = ctx.cx, ctx.cy
  local rx, rw = x0 + RAIL, ctx.cw - RAIL
  local roll_y = y0 + TR_H + AR_H + 4 * z
  local roll_h = ctx.ch - TR_H - AR_H - VEL_H - 10 * z
  local vel_y = roll_y + roll_h + 2 * z
  local tpp = (win.tpp or 0.5) * z -- px per tick
  local row_h = math.max(4, 7 * z)
  local grid = GRIDS[win.grid or 4]
  local pat = doc.patterns[win.pat or 1]

  -- ---- the track rail ----
  pal.x_ig_rect_fill(x0, y0, RAIL - 4 * z, ctx.ch - 4 * z, COL.rail, 3 * z)
  local ty = y0 + 4 * z
  for ti, tr in ipairs(doc.tracks) do
    local sel = (win.trk or 1) == ti
    local hov = ctx.hot and i.wx >= x0 and i.wx < x0 + RAIL - 8 * z
                and i.wy >= ty and i.wy < ty + px * 2.4
    if sel then
      pal.x_ig_rect_fill(x0 + 2 * z, ty - 2 * z, RAIL - 10 * z,
                         px * 2.5, COL.btn_on, 3 * z)
    end
    pal.x_ig_text(x0 + 6 * z, ty, px * 0.95,
                  (hov or sel) and COL.hot or COL.text, tr.name, 0)
    local insname = tr.ins ~= "" and (tr.ins:match("([^/]+)%.ins$") or tr.ins)
                    or "(drag an .ins here)"
    pal.x_ig_text(x0 + 6 * z, ty + px * 1.1, px * 0.8,
                  tr.ins ~= "" and COL.accent or COL.dim, insname, 0)
    -- the mute dot
    local mx = x0 + RAIL - 18 * z
    pal.x_ig_circle_fill(mx, ty + px * 0.5, 3.5 * z,
                         tr.mute and COL.err or COL.btn)
    if ctx.hot and i.clicked[1] then
      if i.wx >= mx - 5 * z and i.wx < mx + 5 * z
         and i.wy >= ty and i.wy < ty + px then
        tr.mute = not tr.mute
        p.flat = nil
        commit(ed, win.path)
      elseif hov then
        win.trk = ti
        ctx.touch()
      end
    end
    ty = ty + px * 2.8
  end
  do -- + track
    local hov = ctx.hot and i.wx >= x0 and i.wx < x0 + 60 * z
                and i.wy >= ty and i.wy < ty + px * 1.4
    pal.x_ig_text(x0 + 6 * z, ty, px, hov and COL.hot or COL.dim,
                  "+ track", 0)
    if hov and i.clicked[1] and #doc.tracks < 16 then
      doc.tracks[#doc.tracks + 1] = { name = "track " .. (#doc.tracks + 1),
                                      ins = "", gain = 128, pan = 0,
                                      mute = false }
      commit(ed, win.path)
    end
  end

  -- ---- transport ----
  local s = { x = rx, used = 0 }
  local function tchip(label, on)
    local w = pal.x_ig_text_size(label, px * 0.95, 0) + 12 * z
    local hov = ctx.hot and i.wx >= s.x and i.wx < s.x + w
                and i.wy >= y0 and i.wy < y0 + TR_H
    pal.x_ig_rect_fill(s.x, y0 + 1 * z, w, TR_H - 4 * z,
                       on and COL.btn_on or COL.btn, 3 * z)
    pal.x_ig_text(s.x + 6 * z, y0 + (TR_H - px) * 0.4, px * 0.95,
                  (hov or on) and COL.hot or COL.dim, label, 0)
    s.x = s.x + w + 4 * z
    return hov and i.clicked[1]
  end
  if tchip(p.playing and "stop" or "play", p.playing) then
    if p.playing then preview_stop(p) else preview_start(ed, win, p) end
  end
  if tchip("bpm " .. doc.bpm, false) then
    doc.bpm = doc.bpm >= 200 and 60 or doc.bpm + 10
    p.flat = nil
    commit(ed, win.path)
  end
  if tchip(GRID_LABEL[win.grid or 4], false) then
    win.grid = (win.grid or 4) % 6 + 1
    ctx.touch()
  end
  -- pattern chips
  local ids = {}
  for id in pairs(doc.patterns) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    if tchip("p" .. id, (win.pat or 1) == id) then
      win.pat = id
      ctx.touch()
    end
  end
  if tchip("+p", false) then
    local nid = (ids[#ids] or 0) + 1
    doc.patterns[nid] = { id = nid, len = 4 * PPQ * 4, notes = {} }
    win.pat = nid
    commit(ed, win.path)
  end

  -- ---- the arrangement strip ----
  local ay = y0 + TR_H
  pal.x_ig_rect_fill(rx, ay, rw, AR_H, COL.well, 3 * z)
  local bar = PPQ * (doc.beats_per_bar or 4)
  local atpp = tpp * 0.25 -- the strip is 4x denser than the roll
  local L = math.max(song.length(doc), bar * 16)
  for t = 0, L, bar do
    local lx = rx + t * atpp
    if lx > rx + rw then break end
    pal.x_ig_line(lx, ay, lx, ay + AR_H, COL.gridln, 1)
  end
  local lane_h = AR_H / math.max(1, #doc.tracks)
  for ci, c in ipairs(doc.clips) do
    local cx0 = rx + c.tick * atpp
    local cw0 = c.len * atpp
    local cy0 = ay + (c.track) * lane_h
    if cx0 < rx + rw then
      local hov = ctx.hot and i.wx >= cx0 and i.wx < cx0 + cw0
                  and i.wy >= cy0 and i.wy < cy0 + lane_h
      pal.x_ig_rect_fill(cx0, cy0 + 1, math.min(cw0, rx + rw - cx0),
                         lane_h - 2,
                         (p.csel == ci or hov) and COL.clip_hot or COL.clip,
                         2 * z)
      pal.x_ig_text(cx0 + 2 * z, cy0 + 1, px * 0.7, COL.dim,
                    "p" .. c.pattern, 0)
    end
  end
  -- the preview playhead
  if p.playing then
    local SL = snd.seq.samples_at(song.length(doc), doc.bpm)
    if SL > 0 then
      local ptick = snd.seq.ticks_at(p.ppos % SL, doc.bpm)
      pal.x_ig_line(rx + ptick * atpp, ay, rx + ptick * atpp, ay + AR_H,
                    COL.head, math.max(1, 1.2 * z))
    end
  end
  -- arrangement gestures: press empty = stamp; press clip = move;
  -- right edge = resize
  local over_arr = i.wx >= rx and i.wx < rx + rw and i.wy >= ay
                   and i.wy < ay + AR_H
  if ctx.hot and i.clicked[1] and over_arr and not p.g then
    local tick = (i.wx - rx) / atpp
    local lane = math.min(#doc.tracks - 1,
                          math.max(0, (i.wy - ay) // lane_h))
    local hit, edge
    for ci, c in ipairs(doc.clips) do
      if c.track == lane and tick >= c.tick and tick < c.tick + c.len then
        hit = ci
        edge = (c.tick + c.len - tick) * atpp < 6 * z
      end
    end
    if hit then
      p.csel = hit
      local c = doc.clips[hit]
      p.g = { t = edge and "clipsize" or "clipmove", ci = hit,
              dt = tick - c.tick, moved = false }
    else
      local pt = doc.patterns[win.pat or 1]
      if pt then
        doc.clips[#doc.clips + 1] = {
          track = math.tointeger(lane), pattern = win.pat or 1,
          tick = math.tointeger((tick // bar) * bar), len = pt.len,
        }
        p.csel = #doc.clips
        p.flat = nil
        commit(ed, win.path)
      end
    end
    ctx.touch()
  end
  if p.g and (p.g.t == "clipmove" or p.g.t == "clipsize") then
    local c = doc.clips[p.g.ci]
    if i.buttons[1] and c then
      local tick = (i.wx - rx) / atpp
      if p.g.t == "clipmove" then
        local nt = math.max(0, ((tick - p.g.dt + bar / 2) // bar) * bar)
        nt = math.tointeger(nt)
        if nt ~= c.tick then
          c.tick = nt
          p.g.moved = true
          ctx.touch()
        end
      else
        local nl = math.max(bar, ((tick - c.tick + bar / 2) // bar) * bar)
        nl = math.tointeger(nl)
        if nl ~= c.len then
          c.len = nl
          p.g.moved = true
          ctx.touch()
        end
      end
    elseif not i.buttons[1] then
      if p.g.moved then
        p.flat = nil
        commit(ed, win.path)
      end
      p.g = nil
    end
  end

  -- ---- the piano roll ----
  pal.x_ig_rect_fill(rx, roll_y, rw, roll_h, COL.well, 3 * z)
  pal.x_ig_clip_push(rx, roll_y, rw, roll_h)
  local low = win.lownote or 45
  local nrows = math.tointeger(roll_h // row_h) or 0
  if not pat then
    pal.x_ig_text(rx + 8 * z, roll_y + 8 * z, px, COL.dim,
                  "no pattern selected", 0)
    pal.x_ig_clip_pop()
    return
  end
  -- rows (black-key tint) + grid lines
  for r = 0, nrows do
    local pitch = low + nrows - r
    if is_black(pitch) then
      pal.x_ig_rect_fill(rx, roll_y + r * row_h, rw, row_h, COL.black_row)
    end
    if pitch % 12 == 0 then
      pal.x_ig_line(rx, roll_y + r * row_h, rx + rw, roll_y + r * row_h,
                    COL.beatln, 1)
      pal.x_ig_text(rx + 2 * z, roll_y + r * row_h - px * 0.55, px * 0.7,
                    COL.dim, "C" .. (pitch // 12 - 1), 0)
    end
  end
  for t = 0, pat.len, grid do
    local lx = rx + t * tpp
    if lx > rx + rw then break end
    pal.x_ig_line(lx, roll_y, lx, roll_y + roll_h,
                  t % PPQ == 0 and COL.beatln or COL.gridln, 1)
  end
  pal.x_ig_line(rx + pat.len * tpp, roll_y, rx + pat.len * tpp,
                roll_y + roll_h, COL.accent, 1.2 * z)
  -- notes
  local function note_rect(n)
    local nx = rx + n.tick * tpp
    local ny = roll_y + (low + nrows - n.pitch) * row_h
    return nx, ny, math.max(2, n.dur * tpp), row_h
  end
  for ni, n in ipairs(pat.notes) do
    local nx, ny, nw, nh = note_rect(n)
    pal.x_ig_rect_fill(nx, ny + 1, nw - 1, nh - 2,
                       p.nsel == ni and COL.hot or COL.note, 2)
  end
  -- the roll grammar
  local over_roll = i.wx >= rx and i.wx < rx + rw and i.wy >= roll_y
                    and i.wy < roll_y + roll_h
  local function snap(t)
    local g2 = ed.g.ctrl and 1 or grid -- CTRL = fine ticks (D058)
    return math.tointeger(math.max(0, math.min(pat.len - 1, (t // g2) * g2)))
  end
  if ctx.hot and i.clicked[1] and over_roll and not p.g then
    local tick = (i.wx - rx) / tpp
    local pitch = low + nrows - math.tointeger((i.wy - roll_y) // row_h)
    local hit, edge
    for ni, n in ipairs(pat.notes) do
      if pitch == n.pitch and tick >= n.tick and tick < n.tick + n.dur then
        hit = ni
        edge = (n.tick + n.dur - tick) * tpp < 4 * z
      end
    end
    if hit then
      p.nsel = hit
      local n = pat.notes[hit]
      p.g = { t = edge and "nsize" or "nmove", ni = hit, moved = false,
              dt = tick - n.tick, dp = pitch - n.pitch }
    else -- ADD at the last-used length, snapped
      local n = { tick = snap(tick), dur = p.lastdur or grid,
                  pitch = math.max(0, math.min(127, pitch)), vel = 100 }
      pat.notes[#pat.notes + 1] = n
      p.nsel = #pat.notes
      p.g = { t = "nmove", ni = #pat.notes, added = true, moved = false,
              dt = tick - n.tick, dp = 0 }
      blip(ed, win, p, n.pitch, n.vel)
    end
    ctx.touch()
  end
  if p.g and (p.g.t == "nmove" or p.g.t == "nsize") then
    local n = pat.notes[p.g.ni]
    if i.buttons[1] and n then
      local tick = (i.wx - rx) / tpp
      local pitch = low + nrows - math.tointeger((i.wy - roll_y) // row_h)
      if p.g.t == "nmove" then
        local nt = snap(tick - p.g.dt)
        local np = math.max(0, math.min(127, pitch - p.g.dp))
        if nt ~= n.tick or np ~= n.pitch then
          if np ~= n.pitch then blip(ed, win, p, np, n.vel) end
          n.tick, n.pitch = nt, np
          p.g.moved = true
          ctx.touch()
        end
      else
        local g2 = ed.g.ctrl and 1 or grid
        local nd = math.max(g2, math.tointeger(
          ((tick - n.tick + g2 / 2) // g2) * g2))
        if nd ~= n.dur then
          n.dur = nd
          p.g.moved = true
          ctx.touch()
        end
      end
    elseif not i.buttons[1] then
      if not p.g.moved and not p.g.added then -- motionless release = DELETE
        table.remove(pat.notes, p.g.ni)
        p.nsel = nil
        p.flat = nil
        commit(ed, win.path)
      elseif p.g.moved or p.g.added then
        if n then p.lastdur = n.dur end
        p.flat = nil
        commit(ed, win.path)
      end
      p.g = nil
      ctx.touch()
    end
  end
  pal.x_ig_clip_pop()

  -- ---- the velocity lane ----
  pal.x_ig_rect_fill(rx, vel_y, rw, VEL_H, COL.well, 3 * z)
  pal.x_ig_clip_push(rx, vel_y, rw, VEL_H)
  for ni, n in ipairs(pat.notes) do
    local nx = rx + n.tick * tpp
    local vh = (n.vel / 127) * (VEL_H - 4 * z)
    pal.x_ig_rect_fill(nx, vel_y + VEL_H - 2 * z - vh, math.max(2, 3 * z),
                       vh, p.nsel == ni and COL.hot or COL.vel)
  end
  local over_vel = i.wx >= rx and i.wx < rx + rw and i.wy >= vel_y
                   and i.wy < vel_y + VEL_H
  if ctx.hot and (i.clicked[1] or (p.g and p.g.t == "vel")) and over_vel then
    if not p.g and i.clicked[1] then p.g = { t = "vel", moved = false } end
  end
  if p.g and p.g.t == "vel" then
    if i.buttons[1] then
      local tick = (i.wx - rx) / tpp
      local best, bd
      for ni, n in ipairs(pat.notes) do
        local d = math.abs(n.tick - tick)
        if d * tpp < 8 * z and (not bd or d < bd) then best, bd = ni, d end
      end
      if best then
        local nv = math.max(1, math.min(127, math.floor(
          (1 - (i.wy - vel_y - 2 * z) / (VEL_H - 4 * z)) * 127 + 0.5)))
        if pat.notes[best].vel ~= nv then
          pat.notes[best].vel = nv
          p.nsel = best
          p.g.moved = true
          ctx.touch()
        end
      end
    else
      if p.g.moved then
        p.flat = nil
        commit(ed, win.path)
      end
      p.g = nil
    end
  end
  pal.x_ig_clip_pop()
end

-- drag an .ins from the assets window onto a track row = bind it
function M.drop(win, ed, path, wx, wy)
  if not path:lower():find("%.ins$") or win.path == "" then return false end
  local _, p = open_asset(ed, win.path)
  local doc = p.doc
  if not doc then return false end
  -- row math mirrors the rail draw (world coords -> track index)
  local z = 1 -- world units: win.y + HDR + pad
  local py = wy - (win.y + 24 + 4) - 4
  local px10 = 10 -- px at z1
  local ti = math.tointeger(py // (px10 * 2.8)) + 1
  if ti < 1 or ti > #doc.tracks then ti = win.trk or 1 end
  doc.tracks[ti].ins = path
  p.pins_sent = nil
  p.flat = nil
  commit(ed, win.path)
  pal.log("[ed] bound " .. path .. " -> " .. doc.tracks[ti].name)
  return true
end

return M
