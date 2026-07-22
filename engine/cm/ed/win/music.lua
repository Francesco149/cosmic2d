-- cm.ed.win.music — the music editor (R9d, AUDIO.md §10): binds .song
-- (CSNG), a full windowkit asset citizen.
--
-- The model (round 7 — the human): a two-level ARRANGEMENT + drill-in
-- editor. The **arrangement strip** shows the whole song — clips
-- (patterns placed on tracks). **Click a clip to DRILL into its
-- pattern** in the piano roll below; press empty stamps a NEW clip
-- (each clip owns its OWN pattern — no accidental sharing); drag moves
-- a clip, right-edge resizes it, and a clip **LOOPS its pattern to
-- fill** when resized longer (the "auto loop"). The **track rail**
-- (left) binds instruments (drag an .ins on), mixes volume + stereo pan,
-- mutes, deletes ("del"), and adds tracks; selecting a CLIPLESS track
-- auto-creates a one-bar pattern + a clip at the song start (round 11
-- — the roll must edit what the selected track actually plays).
--
-- Roll grammar (round 9 — the human): press empty = ADD (last-used
-- length, grid-snapped) — holding sustains the AUDITION until
-- release (the synth piano model) while the note keeps its length,
-- and a drag sets the length with its end COVERING the cursor
-- (rounds 10-12); press a note = SELECT it (never
-- moves or deletes — moves go by grid STEPS so an off-grid note keeps
-- its offset) and it RINGS while held, the voice following the pitch
-- as the move drags (round 13); drag moves the selection, right-edge
-- resizes it;
-- selected notes hit-test first and draw on top translucent so an
-- overlap stays visible and fixable; RIGHT-CLICK deletes a note;
-- ctrl+up/down steps the selection an octave. shift = marquee/toggle
-- select; CTRL+drag = duplicate; Ctrl+C/X copy/cut; Ctrl+V arms a
-- GHOST paste riding the mouse — click places it (pan/zoom stay
-- live), Esc or right-click cancels. A velocity lane + a scrub ruler
-- under it. A PIANO KEYS column sits on the roll's left edge (round
-- 10): click/drag auditions pitches, and the row under the cursor
-- highlights. A pattern's length GROWS to fit content but never
-- auto-shrinks (clips loop it).
--
-- Preview playback rides the EDITOR BANK (render-only — composing
-- never touches the sim): a wall-clock mini-sequencer over the
-- flatten. The GAME plays the same file via cm.snd.music — sim state,
-- recorded, rewound. One finished gesture = one journal entry.

local M = select(2, ...) or {}
local song = cm.require("cm.song")
local snd = cm.require("cm.snd")

M.kind = "music"
M.help = "win-music"
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
  return { path = "", pat = 1, trk = 1, grid = 4,
           tpp = 0.5, lownote = 45, tick0 = 0, -- the roll's view
           arh = 60, ar_tpp = 0.14, ar_t0 = 0, ar_sy = 0, -- the arrangement's
           cursor = 0 } -- the scrub-bar position (pattern ticks)
end

local LANE_H = 15 -- arrangement track lane height (logical px): fixed + a
                  -- reasonable size, vertical-scrolls when tracks overflow

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
  p.nsels = nil -- the note selection holds TABLE REFS into the old doc
end

-- a pattern's length GROWS to fit its notes but never auto-shrinks
-- (round 6 — the human: clips loop a short pattern to fill, so a
-- pattern that's longer than its content is fine; auto-shrinking it
-- fought resizing). song.fit_pattern is the shared grow-only core.
local function fit_pattern(doc, pt)
  song.fit_pattern(doc, pt)
end

local A = cm.require("cm.ed.kit").asset {
  gkey = "muw", field = "song", jcap = M.JCAP,
  fresh = function() return song.encode(song.fresh()) end,
  adopt = decode_into,
  encode = song.encode,
  write = function(ed, path, a, p)
    -- `_save_fail` exists only as the focused durability-test seam. Keeping
    -- it on ephemeral plumbing means it can never enter session state.
    return song.save(p.doc, ed.root .. "/" .. path, p._save_fail)
  end,
}

local plumb, working, open_asset, commit =
  A.plumb, A.working, A.open_asset, A.commit
M.open_win = A.open_win
M.seed = A.seed -- the stock window's open-a-copy door (D147)
M.dirty, M.save, M.undo, M.redo, M.revert =
  A.dirty, A.save, A.undo, A.redo, A.revert

-- group edit math (velocity + note length; human, round 8): CTRL snaps
-- every selected value to `target`; otherwise OFFSET each `base` by the
-- grabbed note's delta (target - gbase), keeping their relative spread,
-- clamped to [lo, hi]. Pure — KAT'd (t_song).
function M.group_val(base, gbase, target, ctrl, lo, hi)
  if ctrl then return target end
  return math.max(lo, math.min(hi, base + (target - gbase)))
end

-- clamp a pitch DELTA so every pitch in the set stays 0..127 — the
-- whole set moves by ONE delta so intervals never squash (the paste
-- ghost placement; the octave steps refuse outright when the clamp
-- bites — all or nothing). Pure — KAT'd (t_song).
function M.clamp_dp(pitches, dp)
  for _, q in ipairs(pitches) do
    if q + dp > 127 then dp = 127 - q end
  end
  for _, q in ipairs(pitches) do
    if q + dp < 0 then dp = -q end
  end
  return dp
end

-- resolve a rail y to its track row. `rows` is the contiguous band
-- list draw records each frame ({y0, y1} per track) — the selected
-- row's band is TALLER (it carries the mix panel), which is exactly
-- why a fixed row height can't resolve a drop (round 10: .ins drops
-- landed a row off below the selection). nil = outside every band
-- (the caller falls back to the selected track). Pure — KAT'd
-- (t_song).
function M.rail_hit(rows, y)
  for ti, r in ipairs(rows) do
    if y >= r.y0 and y < r.y1 then return ti end
  end
end

-- ---- the editor-bank preview (render-only, wall clock) ----

local function preview_stop(p)
  if not p then return end
  local voices = {}
  for _, h in pairs(p.pheld or {}) do voices[h] = true end
  for v in pairs(p.blips or {}) do voices[v] = true end
  -- This window owns editor voices 8..31. Walk the fixed range so cleanup is
  -- deterministic and a voice present in both tables is released only once.
  for v = 8, 31 do
    if voices[v] then pal.x_snd_ed_off(v) end
  end
  p.pheld, p.blips, p.playing = {}, nil, false
end

-- Window lifecycle hook: once draw stops running, nobody remains to advance
-- the sequencer or expire audition blips. Release them before wm forgets the
-- window (the horror-hollow opening drone made this ownership hole obvious).
function M.on_close(win, ed)
  local p = ed.g.muw and ed.g.muw[win.path]
  if p then preview_stop(p) end
end

local function preview_slots(ed, win, p)
  local doc = p.doc
  local kit = cm.require("cm.ed.kit")
  p.pslots = p.pslots or {}
  for ti, tr in ipairs(doc.tracks) do
    if not p.pslots[ti] then
      local slot = kit.snd_alloc(ed, 0)
      p.pslots[ti] = slot
    end
    -- slot ownership (D147 addendum): a long session's allocator wraps
    -- past 64 and another window's upload replaces ours — a lost claim
    -- forces the re-send ("two breaks-alley windows play differently")
    if not kit.snd_claim(ed, p.pslots[ti], "song:" .. win.path .. ":" .. ti) then
      p.pins_sent = nil
    end
    if tr.ins ~= "" and p.pins_sent ~= true then
      local bytes = pal.read_file(ed.root .. "/" .. tr.ins)
                    or pal.read_file(tr.ins)
      if bytes then
        local ok, idoc = pcall(cm.require("cm.ins").decode, bytes)
        if ok then
          -- bake the TRACK gain/pan into the patch, same as the sim
          -- sequencer (cm.snd.seq) — else the preview ignores the volume
          -- panel (the human: "track volume seems to have no effect")
          idoc.patch.gain = snd.track_gain(idoc.patch.gain, tr.gain)
          idoc.patch.pan = snd.track_pan(idoc.patch.pan, tr.pan)
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
  -- start at the scrub cursor (the ruler; pattern ticks == song ticks
  -- for a clip anchored at 0, the dominant case). After the song end
  -- it wraps to 0 — the cursor is the entry point, then the whole song
  -- loops.
  p.pstart = snd.seq.samples_at(math.max(0, win.cursor or 0), p.doc.bpm)
  p.ppos = p.pstart -- samples consumed (song space)
  p.pvoice = p.pvoice or 8 -- round-robin base; editor voices 8..31
end

-- one editor frame of preview: emit ons/offs for the wall-clock window
local function preview_step(ed, win, p)
  if not p.playing then return end
  local doc = p.doc
  if not doc then preview_stop(p); return end
  p.flat = p.flat or song.flatten(doc) -- rebuilt if an edit invalidated
                                        -- it mid-preview (the crash fix)
  local L = song.length(doc)
  local SL = snd.seq.samples_at(L, doc.bpm)
  if SL <= 0 then
    preview_stop(p)
    return
  end
  local elapsed = (pal.time_ns() - p.pt0) * 48000 // 1000000000
  local s0, s1 = p.ppos, (p.pstart or 0) + elapsed
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
            local v
            v, p.pvoice = M.preview_voice(p.pheld, p.blips, p.pvoice)
            pal.x_snd_ed_on(v, p.pslots[ti], n.pitch, n.vel)
            p.pheld[ti .. ":" .. n.tick .. ":" .. n.pitch .. ":"
                    .. (n.tick + n.dur)] = v
          end
        end
      end
    end
  end
end

-- pick a preview voice (8..31) that is NOT still holding a note or
-- ringing a blip. The old blind round-robin killed a long chord the
-- moment ~24 busy-percussion events had passed — x_snd_ed_on with an
-- explicit index OVERWRITES the voice, so a pad dragged across bars
-- died after ~one bar of beat (the D147 dunes report). Steals the
-- round-robin voice only when all 24 are genuinely held. Pure over
-- (pheld, blips, pvoice) — KAT'd.
function M.preview_voice(pheld, blips, pvoice)
  pvoice = pvoice or 8
  local used = {}
  for _, hv in pairs(pheld or {}) do used[hv] = true end
  for bv in pairs(blips or {}) do used[bv] = true end
  for k = 0, 23 do
    local v = 8 + (pvoice - 8 + k) % 24
    if not used[v] then return v, 8 + (v - 8 + 1) % 24 end
  end
  local v = 8 + (pvoice - 8) % 24 -- every voice held: steal in order
  return v, 8 + (v - 8 + 1) % 24
end

-- a one-note audition blip (add/drag feedback)
local function blip(ed, win, p, pitch, vel)
  preview_slots(ed, win, p)
  local slot = p.pslots[win.trk or 1]
  if not slot then return end
  local v
  v, p.pvoice = M.preview_voice(p.pheld, p.blips, p.pvoice)
  pal.x_snd_ed_on(v, slot, pitch, vel or 100)
  p.blips = p.blips or {}
  p.blips[v] = 10
end

-- a HELD audition (round 11): the voice turns on once and stays ringing
-- while the gesture refreshes it each frame — you HEAR the note you're
-- sustaining. It rides p.blips with a 2-frame fuse, so the moment the
-- gesture stops refreshing (release, Esc, window close) every existing
-- cleanup path releases it.
local function blip_hold(ed, win, p, g, pitch, vel)
  if not g.voice then
    preview_slots(ed, win, p)
    local slot = p.pslots[win.trk or 1]
    if not slot then return end
    g.voice, p.pvoice = M.preview_voice(p.pheld, p.blips, p.pvoice)
    pal.x_snd_ed_on(g.voice, slot, pitch, vel or 100)
    p.blips = p.blips or {}
  end
  p.blips[g.voice] = 2
end

-- allocate a fresh one-bar pattern + a clip playing it — the shared
-- core of the arrangement's press-empty stamp and the rail's
-- auto-create on selecting a clipless track (round 11). Mutates doc;
-- returns the new pattern id. KAT'd (t_song).
function M.stamp_fresh(doc, lane, tick, bar)
  local nid = 0
  for id in pairs(doc.patterns) do if id > nid then nid = id end end
  local pid = nid + 1
  doc.patterns[pid] = { id = pid, len = bar, notes = {} }
  doc.clips[#doc.clips + 1] = {
    track = math.tointeger(lane), pattern = pid,
    tick = math.tointeger((tick // bar) * bar), len = bar,
  }
  return pid
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
  { key = "del", hint = "delete", when = bound,
    fn = function(win, ed)
      local _, p = open_asset(ed, win.path)
      if not p.doc then return end
      if p.nsels and next(p.nsels) then -- the note selection first
        local pt = p.doc.patterns[win.pat or 1]
        if pt then
          local keep = {}
          for _, n in ipairs(pt.notes) do
            if not p.nsels[n] then keep[#keep + 1] = n end
          end
          pt.notes = keep
          p.nsels = {}
          p.nsel = nil
          fit_pattern(p.doc, pt)
          p.flat = nil
          commit(ed, win.path)
        end
      elseif p.csel and p.doc.clips[p.csel] then
        table.remove(p.doc.clips, p.csel)
        p.csel = nil
        p.flat = nil
        commit(ed, win.path)
      end
    end },
}

-- clipboard (human, round 4): C copies the selection (relative to its
-- earliest tick), V pastes anchored at the SCRUB CURSOR, X cuts. The
-- clipboard lives on ed.g so it crosses patterns + windows.
local function selected_notes(p, win)
  local pt = p.doc and p.doc.patterns[win.pat or 1]
  local out = {}
  if pt and p.nsels then
    for _, n in ipairs(pt.notes) do
      if p.nsels[n] then out[#out + 1] = n end
    end
  end
  return out, pt
end

local function copy_sel(ed, win, p)
  local sel = selected_notes(p, win)
  if #sel == 0 then return false end
  local t0 = math.huge
  for _, n in ipairs(sel) do t0 = math.min(t0, n.tick) end
  local clip = {}
  for _, n in ipairs(sel) do
    clip[#clip + 1] = { dtick = n.tick - t0, pitch = n.pitch,
                        dur = n.dur, vel = n.vel }
  end
  ed.g.musicclip = clip
  return true
end

-- Ctrl+C arrives through the SHELL's clipboard tier (kind_call("copy")
-- — the D156 convention), which consumes the chord BEFORE kit hotkeys:
-- a kit-level ctrl+c entry here was dead-shadowed (found by the D157
-- tape). M.copy on the kind is the working door.
function M.copy(win, ed)
  if win.path == "" then return end
  local _, p = open_asset(ed, win.path)
  copy_sel(ed, win, p)
end
M.hotkeys[#M.hotkeys + 1] = {
  key = "ctrl+x", when = bound,
  fn = function(win, ed)
    local _, p = open_asset(ed, win.path)
    local sel, pt = selected_notes(p, win)
    if #sel == 0 or not pt then return end
    copy_sel(ed, win, p)
    local keep = {}
    for _, n in ipairs(pt.notes) do
      if not p.nsels[n] then keep[#keep + 1] = n end
    end
    pt.notes = keep
    p.nsels, p.nsel = {}, nil
    fit_pattern(p.doc, pt)
    p.flat = nil
    commit(ed, win.path)
  end }
-- Ctrl+V ARMS a ghost paste instead of pasting at the scrub cursor
-- (round 9): the cursor lives in SONG space, so inside a pattern whose
-- clip doesn't start the song it pointed at nothing. The ghost rides
-- the mouse over the roll (anchored at the clip's earliest note),
-- placement snaps like ADD, a click places it as one journal entry,
-- and Esc / right-click cancels — pan and zoom stay live while armed.
M.hotkeys[#M.hotkeys + 1] = {
  key = "ctrl+v",
  when = function(win) return win.path ~= "" end,
  fn = function(win, ed)
    local _, p = open_asset(ed, win.path)
    local clip = ed.g.musicclip
    if not (p.doc and clip and #clip > 0) then return end
    local bp -- the anchor pitch: the earliest note's (ties keep the first)
    for _, c in ipairs(clip) do
      if c.dtick == 0 then bp = c.pitch; break end
    end
    p.paste = { clip = clip, bp = bp or clip[1].pitch }
    ed.touch()
  end }

-- ctrl+up/down: step the selection by one octave. All or nothing — a
-- set that would clip at either end refuses, so intervals survive.
local function octave(dp)
  return function(win, ed)
    local _, p = open_asset(ed, win.path)
    if not p.doc then return end
    local sel = selected_notes(p, win)
    if #sel == 0 then return end
    local pitches = {}
    for si, n in ipairs(sel) do pitches[si] = n.pitch end
    if M.clamp_dp(pitches, dp) ~= dp then return end
    for _, n in ipairs(sel) do n.pitch = n.pitch + dp end
    blip(ed, win, p, sel[1].pitch, sel[1].vel)
    p.flat = nil
    commit(ed, win.path)
  end
end
M.hotkeys[#M.hotkeys + 1] = { key = "ctrl+up", hint = "octave",
                              when = bound, fn = octave(12) }
M.hotkeys[#M.hotkeys + 1] = { key = "ctrl+down",
                              when = bound, fn = octave(-12) }

for i2 = 1, 6 do
  M.hotkeys[#M.hotkeys + 1] = {
    key = tostring(i2), when = bound,
    fn = function(win, ed)
      -- the subdivision is the PLACEMENT grid only (human, round 2):
      -- note length stays last-used — resize a note to change it
      win.grid = i2
      ed.touch()
    end }
end

function M.escape(win, ed)
  local p = ed.g.muw and ed.g.muw[win.path]
  if p and p.paste then -- an armed paste cancels first
    p.paste = nil
    ed.touch()
    return true
  end
  if p and p.nsels and next(p.nsels) then -- selection clears first
    p.nsels = {}
    ed.touch()
    return true
  end
  if p and p.playing then
    preview_stop(p)
    return true
  end
  return false
end

-- the right button is OURS while bound (cm.ed takes_right): a claimed
-- press must reach draw's note-delete / paste-cancel instead of arming
-- the spawn menu (the D127 rule; sprite/tmap precedent).
function M.takes_right(win)
  return win.path ~= ""
end

-- ---- draw helpers ----

local function is_black(pitch)
  local d = pitch % 12
  return d == 1 or d == 3 or d == 6 or d == 8 or d == 10
end

-- Exact roll feedback for authored recipes (HELPDOCS H8). The keys column
-- labels the Cs, but named notes away from C and off-beat ticks otherwise
-- require counting tiny rows/lines by eye. Keep the formatter pure so the
-- selftest can pin the same zero-ambiguity address the draw shows. The tick
-- is the snapped placement tick for empty space or the stored tick for n.
local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F",
                     "F#", "G", "G#", "A", "A#", "B" }

function M.note_name(pitch)
  pitch = math.max(0, math.min(127, math.tointeger(pitch) or 0))
  return NOTE_NAMES[pitch % 12 + 1] .. tostring(pitch // 12 - 1)
end

function M.roll_status(tick, pitch, beats_per_bar, n)
  tick = math.max(0, math.tointeger(tick) or 0)
  local bar_ticks = PPQ * math.max(1, math.tointeger(beats_per_bar) or 4)
  local bar = tick // bar_ticks + 1
  local inbar = tick % bar_ticks
  local beat = inbar // PPQ + 1
  local sub = inbar % PPQ
  local pos = ("bar %d beat %d"):format(bar, beat)
  if sub ~= 0 then pos = pos .. "+" .. sub end
  local out = pos .. " · " .. M.note_name(pitch) .. " · tick " .. tick
  if n then
    out = out .. " · dur " .. tostring(n.dur or 0)
          .. " · vel " .. tostring(n.vel or 100)
  end
  return out
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
    if not next(p.blips) then p.blips = nil end
    ctx.touch()
  end

  -- ---- geometry ----
  local RAIL = math.min(120 * z, ctx.cw * 0.22)
  local TR_H = px * 1.9   -- transport row
  local AR_H = math.max(24 * z, (win.arh or 60) * z) -- arrangement (resizable)
  local RULER_H = 15 * z  -- the scrub ruler (pattern space, roll-aligned)
  local VEL_H = 30 * z    -- velocity lane
  local x0, y0 = ctx.cx, ctx.cy
  local rx, rw = x0 + RAIL, ctx.cw - RAIL
  local ruler_y = y0 + TR_H + AR_H + 2 * z
  local roll_y = ruler_y + RULER_H + 2 * z
  local roll_h = ctx.ch - TR_H - AR_H - RULER_H - VEL_H - 12 * z
  local vel_y = roll_y + roll_h + 2 * z
  local tpp = (win.tpp or 0.5) * z -- px per tick
  local row_h = math.max(4, 7 * z)
  local grid = GRIDS[win.grid or 4]
  local pat = doc.patterns[win.pat or 1]

  -- ---- the track rail ----
  pal.x_ig_rect_fill(x0, y0, RAIL - 4 * z, ctx.ch - 4 * z, COL.rail, 3 * z)
  local ty = y0 + 4 * z
  -- the row bands, recorded for M.drop (and the in-flight .ins drag
  -- highlight): contiguous world-coord strips whose heights the DRAW
  -- owns — the selected row's band carries its mix panel. Re-deriving
  -- this in drop() is how the drop target drifted a row off (round
  -- 10: hardcoded z=1 math + no panel).
  local bands = {}
  p.rdrop = p.rdrop or {}
  p.rdrop[win.id] = { x0 = x0, x1 = x0 + RAIL - 4 * z, rows = bands }
  local adrag = ed.g.adrag
  local ins_drag = adrag and adrag.moved and adrag.path
                   and adrag.path:lower():find("%.ins$")
  for ti, tr in ipairs(doc.tracks) do
    local sel = (win.trk or 1) == ti
    local band_h = px * 2.8 + (sel and (px * 3.45 + 3 * z) or 0)
    bands[ti] = { y0 = ty - 2 * z, y1 = ty - 2 * z + band_h }
    local hov = ctx.hot and i.wx >= x0 and i.wx < x0 + RAIL - 8 * z
                and i.wy >= ty and i.wy < ty + px * 2.4
    if sel then
      pal.x_ig_rect_fill(x0 + 2 * z, ty - 2 * z, RAIL - 10 * z,
                         px * 2.5, COL.btn_on, 3 * z)
    end
    -- an .ins drag in flight outlines the row it would bind, so the
    -- drop target is visible BEFORE release (the human's report was a
    -- drop landing on the track above — now you see it coming)
    if ins_drag and i.wx >= x0 and i.wx < x0 + RAIL - 4 * z
       and i.wy >= bands[ti].y0 and i.wy < bands[ti].y1 then
      pal.x_ig_rect(x0 + 2 * z, ty - 2 * z, RAIL - 10 * z, px * 2.5,
                    COL.accent, math.max(1, 1 * z), 3 * z)
      ctx.touch() -- the highlight follows the drag
    end
    pal.x_ig_text(x0 + 6 * z, ty, px * 0.95,
                  (hov or sel) and COL.hot or COL.text, tr.name, 0)
    local insname = tr.ins ~= "" and (tr.ins:match("([^/]+)%.ins$") or tr.ins)
                    or "(drag an .ins here)"
    pal.x_ig_text(x0 + 6 * z, ty + px * 1.1, px * 0.8,
                  tr.ins ~= "" and COL.accent or COL.dim, insname, 0)
    -- the mute dot (line 1, right) + the delete × (line 2, right; only
    -- when there's more than one track — can't delete the last)
    local mx = x0 + RAIL - 18 * z
    pal.x_ig_circle_fill(mx, ty + px * 0.5, 3.5 * z,
                         tr.mute and COL.err or COL.btn)
    local dx = x0 + RAIL - 20 * z
    local dhov = #doc.tracks > 1 and ctx.hot and i.wx >= dx - 3 * z
                 and i.wx < dx + 10 * z and i.wy >= ty + px * 0.9
                 and i.wy < ty + px * 2.1
    if #doc.tracks > 1 then
      pal.x_ig_text(dx, ty + px * 1.15, px * 0.9,
                    dhov and COL.err or COL.dim, "del", 0)
    end
    if ctx.hot and i.clicked[1] then
      if i.wx >= mx - 5 * z and i.wx < mx + 5 * z
         and i.wy >= ty and i.wy < ty + px then
        tr.mute = not tr.mute
        p.flat = nil
        commit(ed, win.path)
      elseif dhov then
        -- delete this track: drop it + its clips, reindex higher tracks
        table.remove(doc.tracks, ti)
        local keep = {}
        for _, c in ipairs(doc.clips) do
          if c.track ~= ti - 1 then
            if c.track > ti - 1 then c.track = c.track - 1 end
            keep[#keep + 1] = c
          end
        end
        doc.clips = keep
        win.trk = math.max(1, math.min(win.trk or 1, #doc.tracks))
        p.csel, p.nsels, p.flat = nil, {}, nil
        commit(ed, win.path)
        ctx.touch()
        return -- the doc changed under the loop; next frame redraws
      elseif hov then
        win.trk = ti
        -- drill into this track's first clip (the roll follows) — or
        -- AUTO-CREATE one (round 11 — the human: selecting a clipless
        -- track left the roll on the OLD pattern while auditions used
        -- the NEW track's instrument; a fresh one-bar pattern + a clip
        -- at the song start makes the roll edit what this track plays)
        local found
        for ci, c in ipairs(doc.clips) do
          if c.track == ti - 1 then
            p.csel = ci
            win.pat = c.pattern
            win.cursor = 0
            p.nsels = {}
            found = true
            break
          end
        end
        if not found then
          local bar = PPQ * (doc.beats_per_bar or 4)
          win.pat = M.stamp_fresh(doc, ti - 1, 0, bar)
          p.csel = #doc.clips
          win.cursor = 0
          p.nsels = {}
          p.flat = nil
          commit(ed, win.path)
        end
        ctx.touch()
      end
    end
    -- The selected track expands a two-row MIX panel: volume and stereo pan,
    -- each with a mouse slider + type-in field. One journal entry per drag /
    -- per submit. Pan is an offset from the instrument patch (-64 L..+64 R).
    if sel then
      local PANEL_H = px * 3.45
      local py = ty + px * 2.4
      pal.x_ig_rect_fill(x0 + 2 * z, py, RAIL - 10 * z, PANEL_H, COL.well, 3 * z)
      local function mix_row(key, label, lo, hi, def, y, centered)
        local value = tr[key]
        if value == nil then value = def end
        local lx = x0 + 6 * z
        pal.x_ig_text(lx, y + px * 0.22, px * 0.78, COL.dim, label, 0)
        local sbx = lx + pal.x_ig_text_size(label, px * 0.78, 0) + 5 * z
        local fx = x0 + RAIL - 10 * z - 32 * z
        local sbw = math.max(10 * z, fx - sbx - 3 * z)
        local sby = y + px * 0.36
        local sbh = math.max(3, px * 0.5)
        local f = (value - lo) / (hi - lo)
        pal.x_ig_rect_fill(sbx, sby, sbw, sbh, COL.btn, 2 * z)
        if centered then
          local mid = sbx + sbw * 0.5
          local vx = sbx + sbw * f
          pal.x_ig_rect_fill(math.min(mid, vx), sby, math.abs(vx - mid), sbh,
                             COL.accent, 2 * z)
          pal.x_ig_line(mid, sby - 2 * z, mid, sby + sbh + 2 * z,
                        COL.dim, 1)
        else
          pal.x_ig_rect_fill(sbx, sby, sbw * f, sbh, COL.accent, 2 * z)
        end
        pal.x_ig_rect_fill(sbx + sbw * f - 1.5 * z, sby - 1.5 * z, 3 * z,
                           sbh + 3 * z, COL.hot, 1 * z)
        local sover = ctx.hot and i.wx >= sbx - 3 * z
                      and i.wx < sbx + sbw + 3 * z
                      and i.wy >= sby - 4 * z and i.wy < sby + sbh + 4 * z
        local gesture = "tmix_" .. key
        if sover and i.clicked[1] and not p.g then
          p.g = { t = gesture, ti = ti }
        end
        if p.g and p.g.t == gesture and p.g.ti == ti then
          if i.buttons[1] then
            local nf = math.max(0, math.min(1, (i.wx - sbx) / sbw))
            local nv = math.floor(lo + nf * (hi - lo) + 0.5)
            if centered and math.abs(nv) <= 2 then nv = 0 end
            if nv ~= tr[key] then
              tr[key], p.g.changed = nv, true
              p.pins_sent = nil -- re-bake the live track mix into the preview
              if p.playing or p.blips then preview_slots(ed, win, p) end
              ctx.touch()
            end
          else
            if p.g.changed then commit(ed, win.path) end
            p.g = nil
          end
        end
        if ctx.occluded then
          pal.x_ig_text(fx, y + px * 0.14, px * 0.78, COL.text,
                        tostring(value), 1)
        else
          local text, _, _, st = pal.x_ig_edit {
            id = gesture .. win.id .. "_" .. ti, x = fx, y = y + px * 0.08,
            w = 30 * z, h = px * 1.15, text = tostring(value), px = px * 0.78,
            font = 1, enter = true, multiline = false,
          }
          if st and st.submit and tonumber(text) then
            local nv = math.max(lo, math.min(hi, math.floor(tonumber(text))))
            if nv ~= tr[key] then
              tr[key], p.pins_sent = nv, nil
              if p.playing or p.blips then preview_slots(ed, win, p) end
              commit(ed, win.path)
            end
          end
        end
      end
      mix_row("gain", "vol", 0, 255, 128, py + px * 0.16, false)
      mix_row("pan", "pan", -64, 64, 0, py + px * 1.72, true)
      ty = ty + PANEL_H + 3 * z
    end
    ty = ty + px * 2.8
  end
  do -- + track (its clips get stamped in the arrangement below)
    local hov = ctx.hot and i.wx >= x0 and i.wx < x0 + 60 * z
                and i.wy >= ty and i.wy < ty + px * 1.4
    pal.x_ig_text(x0 + 6 * z, ty, px, hov and COL.hot or COL.dim,
                  "+ track", 0)
    if hov and i.clicked[1] and #doc.tracks < 16 then
      doc.tracks[#doc.tracks + 1] = { name = "track " .. (#doc.tracks + 1),
                                      ins = "", gain = 128, pan = 0,
                                      mute = false }
      win.trk = #doc.tracks
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
    win.grid = (win.grid or 4) % 6 + 1 -- placement grid only (round 2)
    ctx.touch()
  end
  -- (no pattern chips — round 7: each clip owns its pattern; you pick
  -- what the roll edits by clicking a clip in the arrangement)

  -- ---- the arrangement strip: its OWN view (win.ar_tpp px/tick, win.ar_t0
  -- left tick, win.ar_sy vertical scroll) — MMB pans, wheel zooms, height
  -- win.arh resizes, and each lane keeps a FIXED reasonable height that
  -- scrolls vertically when there are many tracks (the human's ask) ----
  local ay = y0 + TR_H
  local bar = PPQ * (doc.beats_per_bar or 4)
  local atpp = math.max(0.02, win.ar_tpp or 0.14) * z -- px per tick (own zoom)
  local ar_t0 = win.ar_t0 or 0
  local lane_h = LANE_H * z
  local content_h = #doc.tracks * lane_h
  local ar_max_sy = math.max(0, content_h - AR_H)
  local ar_sy = math.max(0, math.min(win.ar_sy or 0, ar_max_sy))
  win.ar_sy = ar_sy
  pal.x_ig_rect_fill(rx, ay, rw, AR_H, COL.well, 3 * z)
  pal.x_ig_clip_push(rx, ay, rw, AR_H)
  local L = math.max(song.length(doc), bar * 16)
  do
    local t = math.tointeger(ar_t0 // bar) * bar
    while t <= L do
      local lx = rx + (t - ar_t0) * atpp
      if lx > rx + rw then break end
      if lx >= rx then pal.x_ig_line(lx, ay, lx, ay + AR_H, COL.gridln, 1) end
      t = t + bar
    end
  end
  -- lane bands + track labels (scroll under ar_sy; the active track highlit)
  for ti = 1, #doc.tracks do
    local ly = ay + (ti - 1) * lane_h - ar_sy
    if ly + lane_h > ay and ly < ay + AR_H then
      if (win.trk or 1) == ti then
        pal.x_ig_rect_fill(rx, ly, rw, lane_h, 0x7fd8a814, 0)
      end
      pal.x_ig_line(rx, ly + lane_h - 1, rx + rw, ly + lane_h - 1, COL.gridln, 1)
      pal.x_ig_text(rx + 3 * z, ly + (lane_h - px * 0.7) * 0.5, px * 0.7,
                    COL.dim, doc.tracks[ti].name or ("t" .. ti), 0)
    end
  end
  -- clips sharing the SELECTED clip's pattern glow together (round 8)
  local sel_pat = p.csel and doc.clips[p.csel] and doc.clips[p.csel].pattern
  for ci, c in ipairs(doc.clips) do
    local cx0 = rx + (c.tick - ar_t0) * atpp
    local cw0 = c.len * atpp
    local cy0 = ay + c.track * lane_h - ar_sy
    if cx0 < rx + rw and cx0 + cw0 > rx and cy0 + lane_h > ay
       and cy0 < ay + AR_H then
      local vis_l, vis_r = math.max(cx0, rx), math.min(cx0 + cw0, rx + rw)
      local hov = ctx.hot and i.wx >= cx0 and i.wx < cx0 + cw0
                  and i.wy >= cy0 and i.wy < cy0 + lane_h
      local kin = sel_pat and c.pattern == sel_pat and p.csel ~= ci
      pal.x_ig_rect_fill(vis_l, cy0 + 1, vis_r - vis_l, lane_h - 3,
                         (p.csel == ci or hov) and COL.clip_hot
                         or kin and COL.note_dim or COL.clip, 2 * z)
      local edge_hot = hov and (cx0 + cw0 - i.wx) < 6 * z
      pal.x_ig_rect_fill(vis_r - (edge_hot and 3 or 1.5) * z, cy0 + 1,
                         (edge_hot and 3 or 1.5) * z, lane_h - 3,
                         edge_hot and COL.hot or 0xffffff30,
                         edge_hot and 1 * z or 0)
      pal.x_ig_text(cx0 + 2 * z, cy0 + 1, px * 0.68, COL.dim,
                    "p" .. c.pattern, 0)
    end
  end
  -- the preview playhead
  if p.playing then
    local SL = snd.seq.samples_at(song.length(doc), doc.bpm)
    if SL > 0 then
      local phx = rx + (snd.seq.ticks_at(p.ppos % SL, doc.bpm) - ar_t0) * atpp
      if phx >= rx and phx <= rx + rw then
        pal.x_ig_line(phx, ay, phx, ay + AR_H, COL.head, math.max(1, 1.2 * z))
      end
    end
  end
  -- a vertical scrollbar hint when the tracks overflow the panel
  if ar_max_sy > 0 then
    local th = math.max(8 * z, AR_H * AR_H / content_h)
    local tyv = ay + (AR_H - th) * (ar_sy / ar_max_sy)
    pal.x_ig_rect_fill(rx + rw - 2.5 * z, tyv, 2 * z, th, 0xffffff40, 1)
  end
  pal.x_ig_clip_pop()
  -- the resize handle: drag the panel's bottom edge to grow / shrink it
  local rh_y = ay + AR_H
  local rh_hot = ctx.hot and i.wx >= rx and i.wx < rx + rw
                 and i.wy >= rh_y - 3 * z and i.wy < rh_y + 2 * z
  pal.x_ig_rect_fill(rx + rw * 0.5 - 12 * z, rh_y - 1 * z, 24 * z, 2 * z,
                     (rh_hot or (p.g and p.g.t == "arh")) and COL.hot
                     or COL.gridln, 1)
  if ctx.hot and i.clicked[1] and rh_hot and not p.g then p.g = { t = "arh" } end
  if p.g and p.g.t == "arh" then
    if i.buttons[1] then
      win.arh = math.max(24, math.min(240, (i.wy - ay) / z))
      ctx.touch()
    else p.g = nil end
  end

  local over_arr = i.wx >= rx and i.wx < rx + rw and i.wy >= ay
                   and i.wy < ay + AR_H
  -- MMB pans the arrangement on both axes (focused only, like the roll)
  if ctx.focused and i.clicked[2] and over_arr then
    p.arpan = { mx = i.wx, my = i.wy, t0 = ar_t0, sy = ar_sy }
  end
  if p.arpan then
    if i.buttons[2] then
      win.ar_t0 = math.max(0, p.arpan.t0 - (i.wx - p.arpan.mx) / atpp)
      win.ar_sy = math.max(0, math.min(ar_max_sy,
        p.arpan.sy - (i.wy - p.arpan.my)))
      ar_t0, ar_sy = win.ar_t0, win.ar_sy
      ctx.touch()
    else p.arpan = nil end
  end

  -- arrangement gestures: press empty = stamp; press clip = move; right edge =
  -- resize a clip. CTRL = REUSE (round 8) — ctrl+drag a clip duplicates it
  -- LINKED, ctrl+press on empty stamps the ACTIVE pattern linked (edit one, all
  -- follow). Layout anchors (event tapes / hit-tests + M.wheel read p.arr).
  p.arr = { x = rx, y = ay, w = rw, h = AR_H, atpp = atpp, t0 = ar_t0,
            sy = ar_sy, lane_h = lane_h, bar = bar }
  if ctx.hot and i.clicked[1] and over_arr and not p.g and not rh_hot then
    local tick = ar_t0 + (i.wx - rx) / atpp
    local lane = math.min(#doc.tracks - 1, math.max(0,
      math.tointeger((i.wy - ay + ar_sy) // lane_h)))
    local hit, edge
    for ci, c in ipairs(doc.clips) do
      if c.track == lane and tick >= c.tick and tick < c.tick + c.len then
        hit = ci
        edge = (c.tick + c.len - tick) * atpp < 6 * z
      end
    end
    if ed.g.ctrl and hit then
      -- LINKED DUPLICATE: a copy that SHARES the clip's pattern; drag it
      -- into place (the original stays). Editing either updates both.
      local src = doc.clips[hit]
      doc.clips[#doc.clips + 1] = { track = src.track, pattern = src.pattern,
                                    tick = src.tick, len = src.len }
      p.csel = #doc.clips
      win.pat, win.trk, win.cursor = src.pattern, src.track + 1, 0
      p.nsels = {}
      p.g = { t = "clipmove", ci = #doc.clips, dt = tick - src.tick,
              moved = false, dup = true }
      p.flat = nil
    elseif hit then
      p.csel = hit
      local c = doc.clips[hit]
      -- DRILL DOWN (the human, round 7): clicking a clip shows ITS
      -- pattern in the roll below, and playback starts at the clip
      win.pat = c.pattern
      win.trk = c.track + 1
      win.cursor = 0
      p.nsels = {} -- the roll's selection was for the old pattern
      p.g = { t = edge and "clipsize" or "clipmove", ci = hit,
              dt = tick - c.tick, moved = false }
    else
      -- stamp: CTRL reuses the ACTIVE pattern (win.pat) LINKED — the
      -- fill length rounds up to the pattern's whole bars so it plays in
      -- full; a plain press makes a FRESH one-bar pattern (round 7,
      -- through the shared stamp_fresh core since round 11).
      local pid
      if ed.g.ctrl and win.pat and doc.patterns[win.pat] then
        pid = win.pat
        local plen = math.max(bar,
          ((doc.patterns[pid].len + bar - 1) // bar) * bar)
        doc.clips[#doc.clips + 1] = {
          track = math.tointeger(lane), pattern = pid,
          tick = math.tointeger((tick // bar) * bar),
          len = math.tointeger(plen),
        }
      else
        pid = M.stamp_fresh(doc, lane, tick, bar)
      end
      p.csel = #doc.clips
      win.pat = pid -- drill into the stamped pattern
      win.trk = math.tointeger(lane) + 1
      win.cursor = 0
      p.nsels = {}
      p.flat = nil
      commit(ed, win.path)
    end
    ctx.touch()
  end
  if p.g and (p.g.t == "clipmove" or p.g.t == "clipsize") then
    local c = doc.clips[p.g.ci]
    if i.buttons[1] and c then
      local tick = ar_t0 + (i.wx - rx) / atpp
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
      if p.g.moved or p.g.dup then -- a linked copy commits even if unmoved
        p.flat = nil
        commit(ed, win.path)
      end
      p.g = nil
    end
  end

  -- ---- the piano keys column (round 10 — the human): a playable
  -- keyboard on the roll's left edge. Ruler, roll, and velocity lane
  -- all start to its right through this ONE shift, so their tick axes
  -- stay aligned; the arrangement above keeps the full width. The
  -- keys themselves draw after the roll (they read the panned view).
  local KEYS_W = math.min(18 * z, rw * 0.14)
  local keys_x = rx
  rx, rw = rx + KEYS_W, rw - KEYS_W

  -- ---- the scrub ruler (human, round 4): a roll-aligned bar ruler
  -- (pattern ticks, win.tpp/tick0). Click/drag sets win.cursor — the
  -- SCRUB start (space plays from here) AND the paste anchor (Ctrl+V).
  -- Snaps to the grid; a live playhead rides it while previewing. ----
  do
    local rtick0 = win.tick0 or 0
    local function r2x(t) return rx + (t - rtick0) * tpp end
    pal.x_ig_rect_fill(rx, ruler_y, rw, RULER_H, COL.rail, 3 * z)
    local bar = PPQ * (doc.beats_per_bar or 4)
    for t = (math.tointeger(rtick0 // bar) or 0) * bar, math.huge, bar do
      local lx = r2x(t)
      if lx > rx + rw then break end
      if lx >= rx then
        pal.x_ig_line(lx, ruler_y, lx, ruler_y + RULER_H, COL.gridln, 1)
        pal.x_ig_text(lx + 2 * z, ruler_y + 1 * z, px * 0.7, COL.dim,
                      tostring(math.tointeger(t // bar) + 1), 0)
      end
    end
    -- the cursor (a downward tab + line)
    local cx = r2x(win.cursor or 0)
    if cx >= rx - 4 * z and cx <= rx + rw + 4 * z then
      pal.x_ig_rect_fill(cx - 3 * z, ruler_y, 6 * z, RULER_H * 0.5,
                         COL.accent, 1 * z)
      pal.x_ig_line(cx, ruler_y, cx, roll_y + roll_h, COL.accent,
                    math.max(1, 1 * z))
    end
    -- the live playhead
    if p.playing then
      local SL = snd.seq.samples_at(song.length(doc), doc.bpm)
      if SL > 0 then
        local phx = r2x(snd.seq.ticks_at((p.ppos or 0) % SL, doc.bpm))
        pal.x_ig_line(phx, ruler_y, phx, ruler_y + RULER_H, COL.head,
                      math.max(1, 1.4 * z))
      end
    end
    -- gesture: set the cursor (grid-snapped; drag scrubs)
    local over = i.wx >= rx and i.wx < rx + rw and i.wy >= ruler_y
                 and i.wy < ruler_y + RULER_H
    if ctx.hot and i.clicked[1] and over and not p.g then
      p.g = { t = "scrub" }
    end
    if p.g and p.g.t == "scrub" then
      if i.buttons[1] then
        local t = rtick0 + (i.wx - rx) / tpp
        win.cursor = math.max(0, math.tointeger((t // grid) * grid))
        ctx.touch()
      else
        p.g = nil
      end
    end
  end

  -- ---- the piano roll (a scrolled/zoomed view: win.tick0 = the left
  -- edge in ticks, win.lownote = the bottom pitch (fractional rows),
  -- win.tpp = px per tick — MMB pans, the wheel zooms, focused only,
  -- the map window's view-lock model) ----
  pal.x_ig_rect_fill(rx, roll_y, rw, roll_h, COL.well, 3 * z)
  pal.x_ig_clip_push(rx, roll_y, rw, roll_h)
  local lowf = win.lownote or 45
  local low = math.floor(lowf)
  local suby = (lowf - low) * row_h
  local tick0 = win.tick0 or 0
  local nrows = math.tointeger(roll_h // row_h) or 0
  local function t2x(t) return rx + (t - tick0) * tpp end
  local function x2t(x) return tick0 + (x - rx) / tpp end
  local function y2pitch(y)
    return low + nrows
           - (math.tointeger((y - roll_y + suby) // row_h) or 0)
  end
  p.view = { rx = rx, ry = roll_y, rw = rw, rh = roll_h,
             row_h = row_h } -- the wheel hook reads this
  if not pat then
    pal.x_ig_text(rx + 8 * z, roll_y + 8 * z, px, COL.dim,
                  "no pattern selected", 0)
    pal.x_ig_clip_pop()
    return
  end

  -- MMB pans the roll — focused only (focus is the one gate); the content
  -- follows the mouse on both axes. Not when the press was over the
  -- arrangement (it has its own MMB pan above).
  if ctx.focused and i.clicked[2] and not over_arr then
    p.pan = { mx = i.wx, my = i.wy, t0 = tick0, lf = lowf }
  end
  if p.pan then
    if i.buttons[2] then
      win.tick0 = math.max(0, p.pan.t0 - (i.wx - p.pan.mx) / tpp)
      win.lownote = math.max(0, math.min(127 - nrows,
        p.pan.lf + (i.wy - p.pan.my) / row_h))
      ctx.touch()
      lowf = win.lownote
      low = math.floor(lowf)
      suby = (lowf - low) * row_h
      tick0 = win.tick0
    else
      p.pan = nil
    end
  end

  -- rows (black-key tint) + grid lines
  for r = -1, nrows do
    local ry2 = roll_y + r * row_h - suby
    local pitch = low + nrows - r
    if is_black(pitch) then
      pal.x_ig_rect_fill(rx, ry2, rw, row_h, COL.black_row)
    end
    if pitch % 12 == 0 then
      -- (the octave label moved onto the keys column, round 10)
      pal.x_ig_line(rx, ry2, rx + rw, ry2, COL.beatln, 1)
    end
  end
  for t = (math.tointeger(tick0 // grid) or 0) * grid, pat.len, grid do
    local lx = t2x(t)
    if lx > rx + rw then break end
    if lx >= rx then
      pal.x_ig_line(lx, roll_y, lx, roll_y + roll_h,
                    t % PPQ == 0 and COL.beatln or COL.gridln, 1)
    end
  end
  pal.x_ig_line(t2x(pat.len), roll_y, t2x(pat.len),
                roll_y + roll_h, COL.accent, 1.2 * z)
  -- the scrub cursor, faint, through the roll (the paste anchor)
  do
    local cx = t2x(win.cursor or 0)
    if cx >= rx and cx <= rx + rw then
      pal.x_ig_line(cx, roll_y, cx, roll_y + roll_h, 0x7fd8a866,
                    math.max(1, 1 * z))
    end
  end
  -- notes (selection = a set of note TABLE REFS — stable across
  -- commits, cleared by decode_into on undo/adopt)
  p.nsels = p.nsels or {}
  local function note_rect(n)
    local nx = t2x(n.tick)
    local ny = roll_y + (low + nrows - n.pitch) * row_h - suby
    return nx, ny, math.max(2, n.dur * tpp), row_h
  end
  -- hit-test: the topmost note under (tick, pitch), SELECTED notes
  -- first — a drag grabs what you selected even under an overlap
  local function note_hit(tick, pitch)
    local hit, hit_sel
    for ni, n in ipairs(pat.notes) do
      if pitch == n.pitch and tick >= n.tick and tick < n.tick + n.dur then
        hit = ni
        if p.nsels[n] then hit_sel = ni end
      end
    end
    return hit_sel or hit
  end
  local roll_hot = ctx.hot and i.wx >= rx and i.wx < rx + rw
                   and i.wy >= roll_y and i.wy < roll_y + roll_h
  for ni, n in ipairs(pat.notes) do -- unselected notes first
    if not (p.nsel == ni or p.nsels[n]) then
      local nx, ny, nw, nh = note_rect(n)
      pal.x_ig_rect_fill(nx, ny + 1, nw - 1, nh - 2, COL.note, 2)
    end
  end
  -- selected notes draw LAST and slightly translucent: an overlapped
  -- note stays visible THROUGH the selection, so the overlap can be
  -- seen and fixed (round 9)
  for ni, n in ipairs(pat.notes) do
    if p.nsel == ni or p.nsels[n] then
      local nx, ny, nw, nh = note_rect(n)
      pal.x_ig_rect_fill(nx, ny + 1, nw - 1, nh - 2, 0xE8E4FFc8, 2)
      pal.x_ig_rect(nx, ny + 1, nw - 1, nh - 2, COL.hot,
                    math.max(1, 1 * z), 2)
    end
  end
  -- resize handle: a bright bar when hovering the right edge of the
  -- note a press would grab, so the resize zone is discoverable (the
  -- human — hoverable handles)
  if roll_hot and not p.g and not p.paste then
    local hi = note_hit(x2t(i.wx), y2pitch(i.wy))
    local n = hi and pat.notes[hi]
    if n then
      local nx, ny, nw, nh = note_rect(n)
      if (nx + nw - i.wx) < 4 * z then
        pal.x_ig_rect_fill(nx + nw - 2 * z, ny + 1, 2.5 * z, nh - 2,
                           COL.head, 1 * z)
      end
    end
  end
  -- the roll grammar (+ selection, round 3: shift+drag = marquee,
  -- shift+click toggles, dragging a selected note moves the whole set)
  local over_roll = i.wx >= rx and i.wx < rx + rw and i.wy >= roll_y
                    and i.wy < roll_y + roll_h
  -- placement snaps to the grid. (CTRL is DUPLICATE in the roll now,
  -- round 4 — superseding the D058 fine-tick inversion; the finer
  -- grids + zoom give precision.)
  local function snap(t)
    return math.tointeger(math.max(0, (t // grid) * grid))
  end
  local function snapd(d) -- a MOVE delta -> the nearest grid step (signed)
    return math.tointeger(((d + grid / 2) // grid) * grid)
  end
  local function note_commit()
    fit_pattern(doc, pat) -- the end line follows the content
    p.flat = nil
    commit(ed, win.path)
  end
  if ctx.hot and i.clicked[1] and over_roll and not p.g and not p.paste then
    local tick = x2t(i.wx)
    local pitch = y2pitch(i.wy)
    local hit = note_hit(tick, pitch)
    local edge = false
    if hit then
      local n = pat.notes[hit]
      edge = (n.tick + n.dur - tick) * tpp < 4 * z
    end
    if ed.g.ctrl and hit then -- DUPLICATE (round 4): ctrl+drag copies
      -- the selection (or just this note), you drag the copies where
      -- you want; the originals stay put
      local hn = pat.notes[hit]
      local src = {}
      if p.nsels[hn] then
        for _, n in ipairs(pat.notes) do
          if p.nsels[n] then src[#src + 1] = n end
        end
      else
        src = { hn }
      end
      p.nsels = {}
      local base, grab = {}, nil
      for _, n in ipairs(src) do
        local c = { tick = n.tick, dur = n.dur, pitch = n.pitch, vel = n.vel }
        pat.notes[#pat.notes + 1] = c
        p.nsels[c] = true
        base[#base + 1] = { n = c, tick = c.tick, pitch = c.pitch }
        if n == hn then grab = c end
      end
      grab = grab or base[1].n
      p.nsel = nil
      p.g = { t = "selmove", grab = grab, gt = grab.tick, gp = grab.pitch,
              dt = tick - grab.tick, dp = pitch - grab.pitch, base = base,
              moved = false, dup = true }
      blip_hold(ed, win, p, p.g, grab.pitch, grab.vel)
    elseif ed.g.shift then -- selection: toggle a note / start a marquee
      if hit then
        local n = pat.notes[hit]
        p.nsels[n] = not p.nsels[n] or nil
      else
        p.g = { t = "marquee", x0 = i.wx, y0 = i.wy }
      end
    elseif hit then -- SELECT (round 9): a press never moves or deletes
      -- — an unselected note REPLACES the selection, then the group
      -- gesture arms over the selection; a motionless release just
      -- keeps it (delete moved to right-click)
      local n = pat.notes[hit]
      if not p.nsels[n] then p.nsels = { [n] = true } end
      p.nsel = nil
      local base = {}
      if edge then -- GROUP RESIZE: drag the edge, the whole set follows
        for sel in pairs(p.nsels) do
          base[#base + 1] = { n = sel, dur = sel.dur }
        end
        p.g = { t = "selsize", grab = n, gd = n.dur, lnd = n.dur,
                base = base, moved = false }
      else -- GROUP MOVE — the grabbed note rings while held (the
        -- synth piano model, round 13: press = hear the note, drag
        -- glissandos with the move)
        for sel in pairs(p.nsels) do
          base[#base + 1] = { n = sel, tick = sel.tick, pitch = sel.pitch }
        end
        p.g = { t = "selmove", grab = n, gt = n.tick, gp = n.pitch,
                dt = tick - n.tick, dp = pitch - n.pitch, base = base,
                moved = false }
        blip_hold(ed, win, p, p.g, n.pitch, n.vel)
      end
    else -- ADD at the last-used length, snapped; it becomes the
      -- selection. Holding sustains the AUDITION indefinitely (the
      -- synth piano model, round 12); dragging sets the length (ceil
      -- — the end covers the cursor); a plain click keeps the
      -- last-used length.
      local n = { tick = snap(tick), dur = p.lastdur or grid,
                  pitch = math.max(0, math.min(127, pitch)), vel = 100 }
      pat.notes[#pat.notes + 1] = n
      p.nsels = { [n] = true }
      p.nsel = nil
      p.g = { t = "selsize", grab = n, gd = n.dur, lnd = n.dur,
              base = { { n = n, dur = n.dur } },
              moved = false, added = true, ax = i.wx }
      blip_hold(ed, win, p, p.g, n.pitch, n.vel)
    end
    ctx.touch()
  end
  if p.g and p.g.t == "marquee" then
    if i.buttons[1] then
      local x0, x1 = math.min(p.g.x0, i.wx), math.max(p.g.x0, i.wx)
      local y0, y1 = math.min(p.g.y0, i.wy), math.max(p.g.y0, i.wy)
      pal.x_ig_rect(x0, y0, x1 - x0, y1 - y0, COL.accent,
                    math.max(1, 1 * z), 2 * z)
      ctx.touch()
    else -- select everything the rect touches
      local t0, t1 = x2t(math.min(p.g.x0, i.wx)), x2t(math.max(p.g.x0, i.wx))
      local phi = y2pitch(math.min(p.g.y0, i.wy))
      local plo = y2pitch(math.max(p.g.y0, i.wy))
      for _, n in ipairs(pat.notes) do
        if n.tick < t1 and n.tick + n.dur > t0
           and n.pitch >= plo and n.pitch <= phi then
          p.nsels[n] = true
        end
      end
      p.nsel = nil
      p.g = nil
      ctx.touch()
    end
  end
  if p.g and p.g.t == "selmove" then
    if i.buttons[1] then
      local tick = x2t(i.wx)
      local pitch = y2pitch(i.wy)
      -- the DELTA snaps (round 9): the set moves in grid STEPS, so an
      -- off-grid note keeps its offset instead of being yanked onto
      -- the line by the first pixel of drag
      local ndt = snapd(tick - p.g.dt - p.g.gt)
      local ndp = math.max(-127, math.min(127, (pitch - p.g.dp) - p.g.gp))
      if ndt ~= (p.g.ldt or 0) or ndp ~= (p.g.ldp or 0) then
        -- clamp the delta so the whole set stays in range
        for _, b in ipairs(p.g.base) do
          if b.tick + ndt < 0 then ndt = -b.tick end
        end
        for _, b in ipairs(p.g.base) do
          if b.pitch + ndp > 127 then ndp = 127 - b.pitch end
          if b.pitch + ndp < 0 then ndp = -b.pitch end
        end
        for _, b in ipairs(p.g.base) do
          b.n.tick, b.n.pitch = b.tick + ndt, b.pitch + ndp
        end
        if ndp ~= (p.g.ldp or 0) then
          p.g.voice = nil -- glissando: the held voice follows the pitch
        end
        p.g.ldt, p.g.ldp = ndt, ndp
        p.g.moved = true
        ctx.touch()
      end
      -- the grabbed note rings while held (round 13), moving or not
      blip_hold(ed, win, p, p.g,
                p.g.gp + (p.g.ldp or 0), p.g.grab and p.g.grab.vel)
      ctx.touch() -- the fuse refresh needs the frame loop alive
    else
      -- a duplicate/add always commits (the notes exist even if not
      -- dragged); a plain selection-move commits only if it moved,
      -- else it just keeps the selection
      if p.g.moved or p.g.dup or p.g.added then note_commit() end
      p.g = nil
      ctx.touch()
    end
  end
  -- GROUP RESIZE (human, round 8): drag a selected note's right edge and
  -- the whole selection resizes — OFFSET each by the grabbed note's delta
  -- (relative lengths kept), or CTRL = snap them all to the SAME length.
  if p.g and p.g.t == "selsize" then
    local n = p.g.grab
    if i.buttons[1] and n then
      local nd
      if p.g.added then
        -- the fresh-add hold (round 12 — the human's vote): holding
        -- sustains the AUDITION indefinitely (the synth piano model)
        -- while the note itself keeps the last-used length; only a
        -- real drag sets the length, with CEIL snapping so the end
        -- covers the cursor (round 10's nearest-line snap read as
        -- "too short"). Round 11's musical-time growth is gone.
        if not p.g.live and math.abs(i.wx - p.g.ax) > 3 * z then
          p.g.live = true
        end
        nd = p.g.live and math.max(grid, math.tointeger(
          ((x2t(i.wx) - n.tick + grid - 1) // grid) * grid)) or p.g.lnd
        blip_hold(ed, win, p, p.g, n.pitch, n.vel)
        ctx.touch() -- the fuse refresh needs the frame loop alive
      else
        nd = math.max(grid, math.tointeger(
          ((x2t(i.wx) - n.tick + grid / 2) // grid) * grid))
      end
      if nd ~= p.g.lnd then
        for _, b in ipairs(p.g.base) do
          b.n.dur = M.group_val(b.dur, p.g.gd, nd, ed.g.ctrl, 1, 1 << 30)
        end
        p.g.lnd, p.g.moved = nd, true
        ctx.touch()
      end
    elseif not i.buttons[1] then
      -- an added note commits even unmoved (it exists); a sustain that
      -- moved becomes the new last-used length
      if p.g.moved or p.g.added then
        if n and p.g.moved then p.lastdur = n.dur end
        note_commit()
      end
      p.g = nil
      ctx.touch()
    end
  end
  -- right click DELETES the note under the cursor (round 9 — the old
  -- motionless-release delete is gone: a click SELECTS now)
  if ctx.hot and i.clicked[3] and over_roll and not p.g and not p.paste then
    local hit = note_hit(x2t(i.wx), y2pitch(i.wy))
    if hit then
      local n = table.remove(pat.notes, hit)
      p.nsels[n] = nil
      p.nsel = nil
      note_commit()
      ctx.touch()
    end
  end
  -- the ARMED PASTE ghost (round 9): rides the mouse over the roll
  -- (anchor = the clip's earliest note; the pitch delta clamps as a
  -- SET so intervals survive), a click places it as one journal entry
  -- and the pasted notes become the selection; right-click / Esc
  -- cancels. MMB pan + wheel zoom stay live while armed.
  if p.paste and p.paste.clip and #p.paste.clip > 0 then
    local clip = p.paste.clip
    local at = snap(x2t(i.wx))
    local pitches = {}
    for ci2, c in ipairs(clip) do pitches[ci2] = c.pitch end
    local dp = M.clamp_dp(pitches, y2pitch(i.wy) - p.paste.bp)
    if roll_hot then
      for _, c in ipairs(clip) do
        local gx, gy, gw, gh = note_rect { tick = at + c.dtick,
                                           pitch = c.pitch + dp,
                                           dur = c.dur }
        pal.x_ig_rect_fill(gx, gy + 1, gw - 1, gh - 2, 0x7fd8a866, 2)
      end
    end
    pal.x_ig_text(rx + 8 * z, roll_y + 4 * z, px * 0.85, COL.accent,
                  "paste: click places · esc cancels", 0)
    if ctx.hot then ctx.touch() end -- the ghost follows the mouse
    if ctx.hot and i.clicked[1] and over_roll and not p.g then
      p.nsels = {}
      for _, c in ipairs(clip) do
        local n = { tick = math.tointeger(at + c.dtick),
                    pitch = c.pitch + dp, dur = c.dur, vel = c.vel }
        pat.notes[#pat.notes + 1] = n
        p.nsels[n] = true
      end
      p.nsel = nil
      p.paste = nil
      note_commit()
    elseif ctx.hot and i.clicked[3] then
      p.paste = nil
      ctx.touch()
    end
  end
  pal.x_ig_clip_pop()

  -- ---- the piano keys (the strip the shift above reserved) ----
  pal.x_ig_clip_push(keys_x, roll_y, KEYS_W, roll_h)
  pal.x_ig_rect_fill(keys_x, roll_y, KEYS_W, roll_h, COL.rail)
  local over_keys = i.wx >= keys_x and i.wx < keys_x + KEYS_W
                    and i.wy >= roll_y and i.wy < roll_y + roll_h
  local hovp -- the highlighted pitch: the audition in flight, else hover
  if p.g and p.g.t == "keys" then
    hovp = p.g.kp
  elseif ctx.hot and (over_keys or roll_hot) and not p.paste then
    hovp = y2pitch(i.wy)
  end
  for r = -1, nrows do
    local ky = roll_y + r * row_h - suby
    local pitch = low + nrows - r
    if pitch >= 0 and pitch <= 127 then
      pal.x_ig_rect_fill(keys_x, ky, KEYS_W - 1 * z, row_h, 0xcfc9e8ff)
      if is_black(pitch) then
        pal.x_ig_rect_fill(keys_x, ky, KEYS_W * 0.62, row_h, 0x211d33ff)
      elseif pitch % 12 == 0 or pitch % 12 == 5 then
        -- the B|C and E|F seams (the pairs with no black key between)
        pal.x_ig_line(keys_x, ky + row_h, keys_x + KEYS_W - 1 * z,
                      ky + row_h, 0x211d33aa, 1)
      end
      if pitch == hovp then
        pal.x_ig_rect_fill(keys_x, ky, KEYS_W - 1 * z, row_h, 0x7fd8a860)
      end
      if pitch % 12 == 0 and row_h >= 6 then
        pal.x_ig_text(keys_x + KEYS_W * 0.3,
                      ky + (row_h - px * 0.62) * 0.5, px * 0.62,
                      0x141220ff, "C" .. (pitch // 12 - 1), 0)
      end
    end
  end
  pal.x_ig_clip_pop()
  -- press a key = audition that pitch on the active track's
  -- instrument, HELD until release (the synth piano model, round 12);
  -- dragging glissandos row to row (the old voice's fuse tails off,
  -- the new pitch holds)
  if ctx.hot and i.clicked[1] and over_keys and not p.g and not p.paste then
    local kp = math.max(0, math.min(127, y2pitch(i.wy)))
    p.g = { t = "keys", kp = kp }
    blip_hold(ed, win, p, p.g, kp, 100)
    ctx.touch()
  end
  if p.g and p.g.t == "keys" then
    if i.buttons[1] then
      local kp = math.max(0, math.min(127, y2pitch(i.wy)))
      if kp ~= p.g.kp then
        p.g.kp, p.g.voice = kp, nil -- abandon the old voice to its fuse
      end
      blip_hold(ed, win, p, p.g, kp, 100)
      ctx.touch() -- the fuse refresh needs the frame loop alive
    else
      p.g = nil
      ctx.touch()
    end
  end

  -- Pointer address / stored-note detail in the free right side of the
  -- transport row. Empty roll space reports the tick ADD would snap to;
  -- hovering a note reports its actual tick/duration/velocity. The keys use
  -- the same pitch naming while auditioning. This is observer-only state.
  do
    local status
    if p.g and p.g.t == "keys" then
      status = "audition " .. M.note_name(p.g.kp)
    elseif ctx.hot and over_keys and not p.paste then
      status = "audition " .. M.note_name(y2pitch(i.wy))
    elseif roll_hot and not p.paste then
      local pitch = y2pitch(i.wy)
      local hit = note_hit(x2t(i.wx), pitch)
      local n = hit and pat.notes[hit]
      status = M.roll_status(n and n.tick or snap(x2t(i.wx)),
                             n and n.pitch or pitch,
                             doc.beats_per_bar, n)
    end
    if status then
      local spx = px * 0.72
      local sw = pal.x_ig_text_size(status, spx, 0)
      local sx = ctx.cx + ctx.cw - sw - 6 * z
      -- Very narrow windows keep the transport chips authoritative instead
      -- of drawing text through them.
      if sx > s.x + 4 * z then
        pal.x_ig_text(sx, y0 + (TR_H - spx) * 0.42, spx, COL.accent,
                      status, 0)
      end
    end
  end

  -- ---- the velocity lane ----
  p.vlane = { x = rx, y = vel_y, w = rw, h = VEL_H, tpp = tpp,
              tick0 = tick0 } -- event tapes read this
  pal.x_ig_rect_fill(rx, vel_y, rw, VEL_H, COL.well, 3 * z)
  pal.x_ig_clip_push(rx, vel_y, rw, VEL_H)
  for ni, n in ipairs(pat.notes) do
    local nx = t2x(n.tick)
    local vh = (n.vel / 127) * (VEL_H - 4 * z)
    pal.x_ig_rect_fill(nx, vel_y + VEL_H - 2 * z - vh, math.max(2, 3 * z),
                       vh, (p.nsel == ni or p.nsels[n]) and COL.hot or COL.vel)
  end
  local over_vel = i.wx >= rx and i.wx < rx + rw and i.wy >= vel_y
                   and i.wy < vel_y + VEL_H
  local function vel_near(x)
    local tick = x2t(x)
    local best, bd
    for ni, n in ipairs(pat.notes) do
      local d = math.abs(n.tick - tick)
      if d * tpp < 8 * z and (not bd or d < bd) then best, bd = ni, d end
    end
    return best
  end
  local function vel_at(y)
    return math.max(1, math.min(127, math.floor(
      (1 - (y - vel_y - 2 * z) / (VEL_H - 4 * z)) * 127 + 0.5)))
  end
  if ctx.hot and i.clicked[1] and over_vel and not p.g then
    -- double-click a bar = reset to the natural strength (100 — the
    -- add default; human, round 2). The clock arms on a MOTIONLESS
    -- release only, so a drag never counts as the first click.
    local best = vel_near(i.wx)
    local now = pal.time_ns()
    if best and p.vclick and p.vclick.ni == best
       and now - p.vclick.t < 350e6 then
      if pat.notes[best].vel ~= 100 then
        pat.notes[best].vel = 100
        p.nsel = best
        p.flat = nil
        commit(ed, win.path)
      end
      p.vclick = nil
    else
      -- GROUP mode (human, round 8): pressing a SELECTED bar with a live
      -- selection drags the WHOLE set — the grabbed bar tracks the cursor,
      -- the rest OFFSET by the same delta (relative dynamics kept), or
      -- CTRL snaps them all to the SAME value. Else the single-bar drag.
      local grp
      if best and p.nsels[pat.notes[best]] and next(p.nsels) then
        grp = {}
        for _, n in ipairs(pat.notes) do
          if p.nsels[n] then grp[#grp + 1] = { n = n, base = n.vel } end
        end
      end
      p.g = { t = "vel", moved = false, my0 = i.wy, pressni = best,
              group = grp, gbase = best and pat.notes[best].vel }
    end
    ctx.touch()
  end
  if p.g and p.g.t == "vel" then
    if i.buttons[1] then
      if p.g.group then
        local vcur, any = vel_at(i.wy), false
        for _, e in ipairs(p.g.group) do
          local nv = M.group_val(e.base, p.g.gbase or 0, vcur, ed.g.ctrl, 1, 127)
          if e.n.vel ~= nv then e.n.vel, any = nv, true end
        end
        if any then p.g.changed = true; ctx.touch() end
        if math.abs(i.wy - p.g.my0) > 3 * z then p.g.moved = true end
      else
        local best = vel_near(i.wx)
        if best then
          local nv = vel_at(i.wy)
          if pat.notes[best].vel ~= nv then
            pat.notes[best].vel = nv
            p.nsel = best
            if math.abs(i.wy - (p.g.my0 or i.wy)) > 3 * z then
              p.g.moved = true
            end
            p.g.changed = true
            ctx.touch()
          end
        end
      end
    else
      if p.g.changed then
        p.flat = nil
        commit(ed, win.path)
      end
      p.vclick = not p.g.moved and p.g.pressni
                 and { ni = p.g.pressni, t = pal.time_ns() } or nil
      p.g = nil
    end
  end
  pal.x_ig_clip_pop()
end

-- ---- the view lock (§12.7 — the map window's contract): a bound,
-- FOCUSED music window owns the wheel (roll zoom at the cursor) and
-- middle-drag (the pan in draw); unfocused = inert, the canvas takes
-- everything. The roll's axes are ticks x pitch rows, so the zoom is
-- horizontal (tpp) with the tick under the cursor pinned. ----

function M.own_view(win)
  return (win.path or "") ~= ""
end

function M.wheel(win, ed, dy)
  if win.path == "" or ed.doc.focus ~= win.id then return false end
  local p = ed.g.muw and ed.g.muw[win.path]
  if not (p and p.doc) then return false end
  local i = cm.require("cm.ui").inp
  local z = cm.require("cm.ed.cam").screen_zoom(ed.doc.cam)
  -- over the arrangement? zoom ITS time axis (its own view), pinning the tick
  local ar = p.arr
  if ar and i.wx >= ar.x and i.wx < ar.x + ar.w and i.wy >= ar.y
     and i.wy < ar.y + ar.h then
    local old = win.ar_tpp or 0.14
    local new = math.max(0.02, math.min(4, old * (dy > 0 and 1.2 or 1 / 1.2)))
    if new ~= old then
      local at = (win.ar_t0 or 0) + (i.wx - ar.x) / (old * z)
      win.ar_t0 = math.max(0, at - (i.wx - ar.x) / (new * z))
      win.ar_tpp = new
      ed.touch()
    end
    return true
  end
  local r = p.view
  if not r then return false end
  local ax = i.wx
  if ax < r.rx or ax >= r.rx + r.rw then ax = r.rx + r.rw * 0.5 end
  local old = win.tpp or 0.5
  local new = math.max(0.05, math.min(8, old * (dy > 0 and 1.2 or 1 / 1.2)))
  if new ~= old then
    -- pin the tick under the cursor (screen-space tpp carries the
    -- canvas zoom; win.tpp is the captured world value)
    local z = cm.require("cm.ed.cam").screen_zoom(ed.doc.cam)
    local at = (win.tick0 or 0) + (ax - r.rx) / (old * z)
    win.tick0 = math.max(0, at - (ax - r.rx) / (new * z))
    win.tpp = new
    ed.touch()
  end
  return true
end

function M.takes_middle(win, ed)
  return (win.path or "") ~= "" and ed ~= nil and ed.doc.focus == win.id
end

-- drag an .ins from the assets window onto a track row = bind it
-- resolve any .ins path to a PROJECT-RELATIVE binding. A path already
-- under the project binds as-is; an external one (a stock preset the
-- synth carried, or an absolute path) is copied into the project's
-- ins/ so the .song stays self-contained (AUDIO.md §4.1). Returns the
-- project-relative path, or nil if unreadable.
function M.resolve_ins(ed, path)
  if pal.read_file(ed.root .. "/" .. path) then return path end
  local bytes = pal.read_file(path) -- cwd-relative (stock) or absolute
  if not bytes then return nil end
  local rel = "ins/" .. (path:match("([^/]+)$") or "instrument.ins")
  if not pal.read_file(ed.root .. "/" .. rel) then -- reuse an existing copy
    pal.mkdir(ed.root .. "/ins")
    local ok, err = pal.write_file_atomic(ed.root .. "/" .. rel, bytes,
                                          ed.g and ed.g._ins_import_fail)
    if not ok then
      pal.log(("[ed] preset import FAILED: %s (%s)"):format(rel, tostring(err)))
      if ed.summon_console then ed.summon_console() end
      return nil
    end
    cm.require("cm.ed.win.assets").invalidate(ed)
    cm.require("cm.trace").note_import(rel, #bytes) -- the A7 tray marker
    pal.log("[ed] imported preset -> " .. rel)
  end
  return rel
end

function M.drop(win, ed, path, wx, wy)
  if not path:lower():find("%.ins$") or win.path == "" then return false end
  local _, p = open_asset(ed, win.path)
  local doc = p.doc
  if not doc then return false end
  local rel = M.resolve_ins(ed, path)
  if not rel then return false end
  -- the target row comes from the bands the DRAW recorded this frame
  -- (the layout is the draw's: zoom-scaled rows + the selected row's
  -- taller mix-panel band). Outside the rail, or past the last row,
  -- the drop binds the selected track.
  local rd = p.rdrop and p.rdrop[win.id]
  local ti = rd and wx >= rd.x0 and wx < rd.x1 and M.rail_hit(rd.rows, wy)
  if not ti or ti < 1 or ti > #doc.tracks then
    ti = math.min(win.trk or 1, #doc.tracks)
  end
  doc.tracks[ti].ins = rel
  p.pins_sent = nil
  p.flat = nil
  commit(ed, win.path)
  pal.log("[ed] bound " .. rel .. " -> " .. doc.tracks[ti].name)
  return true
end

return M
