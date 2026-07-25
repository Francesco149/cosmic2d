-- cm.ed.win.music — the music editor (R9d, AUDIO.md §10): binds .song
-- (CSNG), a full windowkit asset citizen.
--
-- The model (round 7 — the human): a two-level ARRANGEMENT + drill-in
-- editor. The **arrangement strip** shows the whole song — clips
-- (patterns placed on tracks). **Click a clip to DRILL into its
-- pattern** in the piano roll below; +pat creates a named pattern and
-- pressing empty places the active pattern (deliberate linked reuse);
-- drag moves a clip/selection, Shift-drag duplicates, Ctrl marquee
-- selects, Alt bypasses beat snap, right-click erases, and a clip
-- **LOOPS its pattern to fill** when resized longer. The **track rail**
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
-- Ctrl marquee selects (Ctrl+Shift adds); Shift-drag duplicates with
-- pitch locked; Ctrl+A/D, nudges, spacing, octave, copy/cut, and the
-- fixed-pitch Ctrl+V GHOST cover keyboard editing. A velocity lane +
-- a pattern-local scrub/play ruler sit below a separate song ruler.
-- A PIANO KEYS column sits on the roll's left edge (round
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
  return { path = "", pat = 1, trk = 1, grid = 3,
           tpp = 0.5, lownote = 45, tick0 = 0, -- the roll's view
           row_h = 14,
           arh = 60, ar_tpp = 0.14, ar_t0 = 0, ar_sy = 0, -- the arrangement's
           cursor = 0, song_cursor = 0, play_scope = "clip" }
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
  p.csels, p.csel = nil, nil -- clip selections hold refs/indices too
  p.solo_restore = nil
  -- Slots can be reused, but their per-track identity cannot: undo/reload may
  -- replace or reorder every track while leaving this path-level plumbing
  -- alive. The next preview validates and uploads each new assignment.
  p.pkeys, p.pready = {}, {}
end

-- A note edit grows its pattern through the codec's shared whole-bar rule.
-- If the clip being edited still EXACTLY fitted the old pattern, grow that
-- clip too: otherwise the newly-authored bar exists in bytes but is silently
-- truncated in the arrangement until a later manual resize. A deliberately
-- shorter or longer clip is authored intent and never moves here. Returns
-- true when the clip followed. Pure document mutation, KAT'd in t_song.
function M.fit_pattern_clip(doc, pt, clip)
  if not pt then return false end
  local old = pt.len or song.bar_ticks(doc)
  song.fit_pattern(doc, pt)
  if clip and clip.pattern == pt.id and clip.len == old and pt.len > old then
    clip.len = pt.len
    return true
  end
  return false
end

-- Compact, exact loop-span text for the permanent transport readout. Current
-- authoring grows in whole bars with a one-bar floor, but the codec can still
-- open an older/arbitrary tick length, so describe those bytes honestly too.
function M.loop_span(len, time)
  len = math.max(1, math.tointeger(len) or 1)
  local doc = type(time) == "table" and time
              or { beats_per_bar = time, beat_unit = 4 }
  local bar = song.bar_ticks(doc)
  local beat = song.beat_ticks(doc)
  if len % bar == 0 then
    local n = len // bar
    return tostring(n) .. (n == 1 and " bar" or " bars")
  elseif len % beat == 0 then
    local n = len // beat
    return tostring(n) .. (n == 1 and " beat" or " beats")
  end
  return tostring(len) .. " ticks"
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

-- The cache key is the sound the track UI says it owns. Keeping this per
-- track—rather than one global "all presets sent" bit—is what makes deletion,
-- reindexing, undo, mix edits, and rebinding safe.
function M.preview_patch_key(tr)
  if not tr or not tr.ins or tr.ins == "" then return false end
  return tr.ins .. "\0" .. tostring(tr.gain or 128)
         .. "\0" .. tostring(tr.pan or 0)
end

-- Pure decision seam for the intermittent wrong-preset regression. `claimed`
-- says the editor-bank slot still contains our upload. `usable` is false
-- while an empty/unreadable track deliberately owns no playable patch.
function M.preview_patch_decision(cached_key, ready, tr, claimed)
  local key = M.preview_patch_key(tr)
  if not key then return false, false, false end
  local upload = not claimed or cached_key ~= key
  return upload, not upload and ready == true, key
end

function M.invalidate_preview_track(p, ti)
  p.pkeys, p.pready = p.pkeys or {}, p.pready or {}
  p.pkeys[ti], p.pready[ti] = false, false
end

local function preview_slots(ed, win, p)
  local doc = p.doc
  local kit = cm.require("cm.ed.kit")
  local ins = cm.require("cm.ins")
  p.pslots, p.pkeys, p.pready =
    p.pslots or {}, p.pkeys or {}, p.pready or {}
  for ti, tr in ipairs(doc.tracks) do
    if not p.pslots[ti] then
      local slot = kit.snd_alloc(ed, 0)
      p.pslots[ti] = slot
    end
    -- slot ownership (D147 addendum): a long session's allocator wraps
    -- past 64 and another window's upload replaces ours — a lost claim
    -- forces the re-send ("two breaks-alley windows play differently")
    local claimed = kit.snd_claim(
      ed, p.pslots[ti], "song:" .. win.path .. ":" .. ti)
    local upload, usable, key =
      M.preview_patch_decision(p.pkeys[ti], p.pready[ti], tr, claimed)
    if not key then
      -- A blank track must be silent even when its slot previously belonged
      -- to another track/window. This was one direct route to hearing a
      -- preset different from the assignment displayed in the rail.
      p.pkeys[ti], p.pready[ti] = false, false
    elseif upload then
      local bytes = pal.read_file(ed.root .. "/" .. tr.ins)
                    or pal.read_file(tr.ins)
      if bytes then
        local ok, idoc = pcall(ins.decode, bytes)
        if ok then
          -- bake the TRACK gain/pan into the patch, same as the sim
          -- sequencer (cm.snd.seq) — else the preview ignores the volume
          -- panel (the human: "track volume seems to have no effect")
          idoc.patch.gain = snd.track_gain(idoc.patch.gain, tr.gain)
          idoc.patch.pan = snd.track_pan(idoc.patch.pan, tr.pan)
          local sent = pcall(ins.upload, idoc, p.pslots[ti], "ed",
                             "m" .. win.id .. "t" .. ti)
          if sent then
            p.pkeys[ti], p.pready[ti] = key, true
            usable = true
          end
        end
      end
      if not usable then
        -- Remember this exact failed assignment so a live preview does not
        -- reread a broken source every frame. A rebind/mix/undo or a lost
        -- slot claim changes the decision and retries.
        p.pkeys[ti], p.pready[ti] = key, false
      end
    end
  end
  -- A shorter document must not leave a later add inheriting a deleted
  -- track's cached patch.
  for ti = #p.pslots, #doc.tracks + 1, -1 do
    p.pslots[ti], p.pkeys[ti], p.pready[ti] = nil, nil, nil
  end
end

-- Explicit preview scopes resolve the ambiguity between the arrangement and
-- the drilled-in pattern. "song" loops the whole arrangement from its own
-- cursor. "clip" loops the last-clicked clip's exact song span, including the
-- other tracks sounding under it, from the pattern-local cursor.
function M.preview_range(doc, win, p, scope)
  if scope == "clip" then
    local c = p.csel and doc.clips[p.csel]
    if c and c.len > 0 then
      local r0, r1 = c.tick, c.tick + c.len
      local local_at = math.max(0, math.tointeger(win.cursor or 0) or 0)
      return r0, r1, r0 + (local_at % c.len)
    end
  end
  local r0, r1 = 0, song.length(doc)
  return r0, r1,
    (math.max(0, math.tointeger(win.song_cursor or 0) or 0) % r1)
end

local function preview_start(ed, win, p, scope)
  preview_stop(p)
  -- A new transport run is a cheap, explicit refresh point: it also picks up
  -- a preset that was saved in place under the same displayed path.
  p.pkeys, p.pready = {}, {}
  preview_slots(ed, win, p)
  p.flat = p.flat or song.flatten(p.doc)
  -- Space follows the last explicit scope, but "clip" only exists when an
  -- arrangement instance is selected. With nothing drilled, fall back to the
  -- whole song and light the matching transport instead of pretending an
  -- invisible clip loop is running.
  if scope == "song" or not (p.csel and p.doc.clips[p.csel]) then
    scope = "song"
  else
    scope = "clip"
  end
  local r0, r1, start = M.preview_range(p.doc, win, p, scope)
  p.playing = true
  win.play_scope = scope
  p.play_scope = scope
  p.pheld = {}
  p.pt0 = pal.time_ns()
  p.pr0, p.pr1 = r0, r1
  p.pstart = snd.seq.samples_at(start, p.doc.bpm)
  p.ppos = p.pstart -- samples consumed (song space)
  p.pvoice = p.pvoice or 8 -- round-robin base; editor voices 8..31
end

function M.preview_tick(p, doc)
  local r0, r1 = p.pr0 or 0, p.pr1 or song.length(doc)
  local s0 = snd.seq.samples_at(r0, doc.bpm)
  local span = snd.seq.samples_at(r1, doc.bpm) - s0
  if span <= 0 then return r0 end
  local at = s0 + (((p.ppos or s0) - s0) % span)
  return snd.seq.ticks_at(at, doc.bpm)
end

-- one editor frame of preview: emit ons/offs for the wall-clock window
local function preview_step(ed, win, p)
  if not p.playing then return end
  local doc = p.doc
  if not doc then preview_stop(p); return end
  -- Ownership can be stolen by any of the editor's other audio windows after
  -- transport starts. Claims are cheap; files are reread only on a lost or
  -- changed assignment.
  preview_slots(ed, win, p)
  p.flat = p.flat or song.flatten(doc) -- rebuilt if an edit invalidated
                                        -- it mid-preview (the crash fix)
  local r0, r1 = p.pr0 or 0, p.pr1 or song.length(doc)
  local RS0 = snd.seq.samples_at(r0, doc.bpm)
  local RS1 = snd.seq.samples_at(r1, doc.bpm)
  local SL = RS1 - RS0
  if SL <= 0 then
    preview_stop(p)
    return
  end
  local elapsed = (pal.time_ns() - p.pt0) * 48000 // 1000000000
  local s0, s1 = p.ppos, (p.pstart or 0) + elapsed
  if s1 <= s0 then return end
  if s1 - s0 > 48000 then s0 = s1 - 4800 end -- a stall skips, no burst
  p.ppos = s1
  local w0 = RS0 + ((s0 - RS0) % SL)
  local spans
  if (s1 - s0) >= SL then
    spans = { { RS0, RS1 } } -- degenerate: the whole range at once
  elseif w0 + (s1 - s0) <= RS1 then
    spans = { { w0, w0 + (s1 - s0) } }
  else
    spans = { { w0, RS1 }, { RS0, RS0 + w0 + (s1 - s0) - RS1,
                              reset = true } }
  end
  for _, sp in ipairs(spans) do
    if sp.reset then
      for key, h in pairs(p.pheld) do
        pal.x_snd_ed_off(h)
        p.pheld[key] = nil
      end
    end
    local t0 = snd.seq.ticks_at(sp[1], doc.bpm)
    local t1 = snd.seq.ticks_at(sp[2], doc.bpm)
    if sp[2] >= RS1 then t1 = r1 end
    for key, h in pairs(p.pheld) do
      local off = tonumber(key:match(":(%d+)$"))
      if off >= t0 and off <= t1 then
        pal.x_snd_ed_off(h)
        p.pheld[key] = nil
      end
    end
    for ti, lane in ipairs(p.flat) do
      local tr = doc.tracks[ti]
      if not (tr and tr.mute) and p.pready[ti] and p.pslots[ti] then
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
  if not slot or not p.pready[win.trk or 1] then return end
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
    if not slot or not p.pready[win.trk or 1] then return end
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
  local pid = M.new_pattern(doc, bar)
  doc.clips[#doc.clips + 1] = {
    track = math.tointeger(lane), pattern = pid,
    tick = math.tointeger((tick // bar) * bar), len = bar,
  }
  return pid
end

function M.new_pattern(doc, bar)
  local nid = 0
  for id in pairs(doc.patterns) do if id > nid then nid = id end end
  local pid = nid + 1
  doc.patterns[pid] = { id = pid, name = song.default_pattern_name(pid),
                        len = bar, notes = {} }
  return pid
end

-- Signed nearest-step snap used by group moves. Keeping it explicit avoids
-- Lua floor-division's asymmetric result for small negative deltas.
function M.snap_delta(delta, step)
  step = math.max(1, math.tointeger(step) or 1)
  if delta < 0 then
    return -math.tointeger(((-delta + step / 2) // step) * step)
  end
  return math.tointeger(((delta + step / 2) // step) * step)
end

-- One delta moves the entire clip selection. Horizontal movement snaps to a
-- beat unless Alt is held; vertical movement always remains whole tracks.
-- Clamp the group as a group so its relative lane layout cannot squash.
function M.clip_move_delta(base, raw_tick, raw_track, beat, precise, ntracks)
  local dt = precise and math.tointeger(math.floor(raw_tick + 0.5))
             or M.snap_delta(raw_tick, beat)
  local dtrack = math.tointeger(raw_track) or 0
  local min_track, max_track = math.huge, -math.huge
  for _, b in ipairs(base or {}) do
    min_track = math.min(min_track, b.track)
    max_track = math.max(max_track, b.track)
  end
  if min_track == math.huge then return dt, 0 end
  dtrack = math.max(-min_track,
                    math.min((ntracks or 1) - 1 - max_track, dtrack))
  local min_tick = math.huge
  for _, b in ipairs(base) do min_tick = math.min(min_tick, b.tick) end
  dt = math.max(-min_tick, dt)
  return dt, dtrack
end

function M.delete_selected_clips(doc, selection)
  local keep, removed = {}, 0
  for _, c in ipairs(doc.clips or {}) do
    if selection and selection[c] then
      removed = removed + 1
    else
      keep[#keep + 1] = c
    end
  end
  if removed > 0 then doc.clips = keep end
  return removed
end

function M.toggle_solo(doc, p, ti)
  if p.solo_track == ti and p.solo_restore then
    for i2, tr in ipairs(doc.tracks) do
      tr.mute = p.solo_restore[i2] or false
    end
    p.solo_track, p.solo_restore = nil, nil
    return false
  end
  if not p.solo_restore then
    p.solo_restore = {}
    for i2, tr in ipairs(doc.tracks) do p.solo_restore[i2] = tr.mute end
  end
  for i2, tr in ipairs(doc.tracks) do tr.mute = i2 ~= ti end
  p.solo_track = ti
  return true
end

-- Remove the selected note refs from a pattern in one pass. Both Delete and
-- Ctrl+X use this path so their document maintenance cannot drift apart.
-- Returns the number removed; pure document mutation, KAT'd in t_song.
function M.delete_selected_notes(doc, pt, selection)
  if not (doc and pt and selection) then return 0 end
  local keep, removed = {}, 0
  for _, n in ipairs(pt.notes or {}) do
    if selection[n] then
      removed = removed + 1
    else
      keep[#keep + 1] = n
    end
  end
  if removed > 0 then
    pt.notes = keep
    song.fit_pattern(doc, pt)
  end
  return removed
end

function M.nudge_selected_notes(pt, selection, dt, dp)
  local min_tick, min_pitch, max_pitch = math.huge, 127, 0
  local count = 0
  for _, n in ipairs(pt.notes or {}) do
    if selection and selection[n] then
      min_tick = math.min(min_tick, n.tick)
      min_pitch, max_pitch = math.min(min_pitch, n.pitch),
                             math.max(max_pitch, n.pitch)
      count = count + 1
    end
  end
  if count == 0 then return 0, 0 end
  dt = math.max(-min_tick, math.tointeger(dt) or 0)
  dp = math.max(-min_pitch, math.min(127 - max_pitch,
                                     math.tointeger(dp) or 0))
  for _, n in ipairs(pt.notes) do
    if selection[n] then
      n.tick, n.pitch = n.tick + dt, n.pitch + dp
    end
  end
  return dt, dp
end

function M.double_note_spacing(pt, selection)
  local anchor, selected = math.huge, {}
  for _, n in ipairs(pt.notes or {}) do
    if selection and selection[n] then
      anchor = math.min(anchor, n.tick)
      selected[#selected + 1] = n
    end
  end
  if #selected < 2 then return false, 0 end
  for _, n in ipairs(selected) do n.tick = anchor + (n.tick - anchor) * 2 end
  local keep, overwritten = {}, 0
  for _, n in ipairs(pt.notes) do
    if selection[n] then
      keep[#keep + 1] = n
    else
      local collide = false
      for _, s2 in ipairs(selected) do
        if n.pitch == s2.pitch and n.tick < s2.tick + s2.dur
           and n.tick + n.dur > s2.tick then
          collide = true
          break
        end
      end
      if collide then overwritten = overwritten + 1
      else keep[#keep + 1] = n end
    end
  end
  pt.notes = keep
  return true, overwritten
end

function M.set_step(pt, tick, pitch, dur, on)
  local hit
  for ni, n in ipairs(pt.notes or {}) do
    if n.tick == tick and n.pitch == pitch then hit = ni; break end
  end
  if on then
    if hit then return pt.notes[hit], false end
    local n = { tick = math.tointeger(tick), pitch = math.tointeger(pitch),
                dur = math.max(1, math.tointeger(dur)), vel = 100 }
    pt.notes[#pt.notes + 1] = n
    return n, true
  elseif hit then
    return table.remove(pt.notes, hit), true
  end
  return nil, false
end

-- ---- hotkeys ----

local bound = function(win) return win.path ~= "" end
M.hotkeys = {
  { key = "space", hint = "play/stop", when = bound,
    fn = function(win, ed)
      local _, p = open_asset(ed, win.path)
      if p.playing then
        preview_stop(p)
      else
        preview_start(ed, win, p, win.play_scope)
      end
      ed.touch()
    end },
  { key = "del", hint = "delete", when = bound,
    fn = function(win, ed)
      local _, p = open_asset(ed, win.path)
      if not p.doc then return end
      if p.nsels and next(p.nsels) then -- the note selection first
        local pt = p.doc.patterns[win.pat or 1]
        if pt and M.delete_selected_notes(p.doc, pt, p.nsels) > 0 then
          p.nsels = {}
          p.nsel = nil
          p.flat = nil
          commit(ed, win.path)
        end
      elseif p.csels and next(p.csels)
             and M.delete_selected_clips(p.doc, p.csels) > 0 then
        p.csels, p.csel = {}, nil
        p.flat = nil
        commit(ed, win.path)
      elseif p.csel and p.doc.clips[p.csel] then
        table.remove(p.doc.clips, p.csel)
        p.csel, p.csels = nil, {}
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

local function finish_note_edit(ed, win, p, pt)
  local clip = p.csel and p.doc.clips[p.csel]
  M.fit_pattern_clip(p.doc, pt, clip)
  p.flat = nil
  commit(ed, win.path)
end

local function nudge_notes(dt, dp)
  return function(win, ed)
    local _, p = open_asset(ed, win.path)
    local sel, pt = selected_notes(p, win)
    if #sel == 0 or not pt then return end
    local adt, adp = M.nudge_selected_notes(pt, p.nsels, dt(p.doc), dp)
    if adt == 0 and adp == 0 then return end
    if adp ~= 0 then blip(ed, win, p, sel[1].pitch, sel[1].vel) end
    finish_note_edit(ed, win, p, pt)
  end
end

M.hotkeys[#M.hotkeys + 1] = {
  key = "ctrl+a", hint = "select all", when = bound,
  fn = function(win, ed)
    local _, p = open_asset(ed, win.path)
    local pt = p.doc and p.doc.patterns[win.pat or 1]
    if not pt then return end
    p.nsels = {}
    for _, n in ipairs(pt.notes) do p.nsels[n] = true end
    p.nsel = nil
    ed.touch()
  end }
M.hotkeys[#M.hotkeys + 1] = {
  key = "ctrl+d", hint = "deselect", when = bound,
  fn = function(win, ed)
    local _, p = open_asset(ed, win.path)
    p.nsels, p.nsel = {}, nil
    ed.touch()
  end }
M.hotkeys[#M.hotkeys + 1] = {
  key = "shift+left", rep = true, when = bound,
  fn = nudge_notes(function() return -GRIDS[#GRIDS] end, 0) }
M.hotkeys[#M.hotkeys + 1] = {
  key = "shift+right", rep = true, hint = "nudge", when = bound,
  fn = nudge_notes(function() return GRIDS[#GRIDS] end, 0) }
M.hotkeys[#M.hotkeys + 1] = {
  key = "shift+up", rep = true, when = bound,
  fn = nudge_notes(function() return 0 end, 1) }
M.hotkeys[#M.hotkeys + 1] = {
  key = "shift+down", rep = true, when = bound,
  fn = nudge_notes(function() return 0 end, -1) }
M.hotkeys[#M.hotkeys + 1] = {
  key = "ctrl+left", rep = true, when = bound,
  fn = nudge_notes(function(doc) return -song.beat_ticks(doc) end, 0) }
M.hotkeys[#M.hotkeys + 1] = {
  key = "ctrl+right", rep = true, hint = "beat nudge", when = bound,
  fn = nudge_notes(function(doc) return song.beat_ticks(doc) end, 0) }
for _, scroll in ipairs({ { "up", 4 }, { "down", -4 } }) do
  local key, delta = scroll[1], scroll[2]
  M.hotkeys[#M.hotkeys + 1] = {
    key = key, rep = true, hint = key == "up" and "scroll" or nil,
    when = bound,
    fn = function(win, ed)
      win.lownote_target = math.max(0, math.min(127,
        (win.lownote_target or win.lownote or 45) + delta))
      ed.touch()
    end }
end
M.hotkeys[#M.hotkeys + 1] = {
  key = "ctrl+alt+right", hint = "double spacing", when = bound,
  fn = function(win, ed)
    local _, p = open_asset(ed, win.path)
    local _, pt = selected_notes(p, win)
    if not pt then return end
    if M.double_note_spacing(pt, p.nsels) then
      finish_note_edit(ed, win, p, pt)
    end
  end }
M.hotkeys[#M.hotkeys + 1] = {
  key = "ctrl+b", hint = "duplicate", when = bound,
  fn = function(win, ed)
    local _, p = open_asset(ed, win.path)
    local sel, pt = selected_notes(p, win)
    if #sel == 0 or not pt then return end
    local first, last = math.huge, 0
    for _, n in ipairs(sel) do
      first, last = math.min(first, n.tick), math.max(last, n.tick + n.dur)
    end
    local dt = math.max(GRIDS[win.grid or 3], last - first)
    local copies = {}
    for _, n in ipairs(sel) do
      local copy = { tick = n.tick + dt, dur = n.dur,
                     pitch = n.pitch, vel = n.vel }
      pt.notes[#pt.notes + 1] = copy
      copies[copy] = true
    end
    p.nsels, p.nsel = copies, nil
    finish_note_edit(ed, win, p, pt)
  end }

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
    M.delete_selected_notes(p.doc, pt, p.nsels)
    p.nsels, p.nsel = {}, nil
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

function M.roll_status(tick, pitch, time, n)
  tick = math.max(0, math.tointeger(tick) or 0)
  local doc = type(time) == "table" and time
              or { beats_per_bar = time, beat_unit = 4 }
  local bar_ticks = song.bar_ticks(doc)
  local beat_ticks = song.beat_ticks(doc)
  local bar = tick // bar_ticks + 1
  local inbar = tick % bar_ticks
  local beat = inbar // beat_ticks + 1
  local sub = inbar % beat_ticks
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
  local SONG_RULER_H = 12 * z -- whole-arrangement cursor, above the clips
  local AR_H = math.max(24 * z, (win.arh or 60) * z) -- arrangement (resizable)
  local RULER_H = 15 * z  -- the scrub ruler (pattern space, roll-aligned)
  local VEL_H = 30 * z    -- velocity lane
  local x0, y0 = ctx.cx, ctx.cy
  local rx, rw = x0 + RAIL, ctx.cw - RAIL
  local ruler_y = y0 + TR_H + SONG_RULER_H + AR_H + 2 * z
  local roll_y = ruler_y + RULER_H + 2 * z
  local roll_h = ctx.ch - TR_H - SONG_RULER_H - AR_H
                 - RULER_H - VEL_H - 12 * z
  local vel_y = roll_y + roll_h + 2 * z
  local tpp = (win.tpp or 0.5) * z -- px per tick
  local row_h = math.max(4 * z, math.min(32 * z, (win.row_h or 14) * z))
  local grid = GRIDS[win.grid or 3]
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
                         p.solo_track == ti and COL.accent
                         or tr.mute and COL.err or COL.btn)
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
        if ed.g.ctrl then
          M.toggle_solo(doc, p, ti)
        else
          p.solo_track, p.solo_restore = nil, nil
          tr.mute = not tr.mute
        end
        p.flat = nil
        commit(ed, win.path)
      elseif dhov then
        -- delete this track: drop it + its clips, reindex higher tracks
        preview_stop(p)
        table.remove(doc.tracks, ti)
        local caches = { p.pslots, p.pkeys, p.pready }
        for ci2 = 1, 3 do
          local cache = caches[ci2]
          if cache and cache[ti] ~= nil then table.remove(cache, ti) end
        end
        local keep = {}
        for _, c in ipairs(doc.clips) do
          if c.track ~= ti - 1 then
            if c.track > ti - 1 then c.track = c.track - 1 end
            keep[#keep + 1] = c
          end
        end
        doc.clips = keep
        p.solo_track, p.solo_restore = nil, nil
        win.trk = math.max(1, math.min(win.trk or 1, #doc.tracks))
        p.csel, p.csels, p.nsels, p.flat = nil, {}, {}, nil
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
            p.csels = { [c] = true }
            win.pat = c.pattern
            win.cursor = 0
            p.nsels = {}
            found = true
            break
          end
        end
        if not found then
          local bar = song.bar_ticks(doc)
          win.pat = M.stamp_fresh(doc, ti - 1, 0, bar)
          p.csel = #doc.clips
          p.csels = { [doc.clips[p.csel]] = true }
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
              M.invalidate_preview_track(p, ti)
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
              tr[key] = nv
              M.invalidate_preview_track(p, ti)
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
                                      mute = p.solo_track ~= nil }
      if p.solo_restore then p.solo_restore[#doc.tracks] = false end
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
  local song_playing = p.playing and p.play_scope == "song"
  if tchip(song_playing and "song stop" or "song play", song_playing) then
    if song_playing then
      preview_stop(p)
    else
      win.play_scope = "song"
      preview_start(ed, win, p, "song")
    end
  end
  local function tfield(id, label, value, width)
    local lw = pal.x_ig_text_size(label, px * 0.72, 0)
    pal.x_ig_text(s.x, y0 + (TR_H - px * 0.72) * 0.42,
                  px * 0.72, COL.dim, label, 0)
    s.x = s.x + lw + 2 * z
    local out, st
    if ctx.occluded then
      pal.x_ig_text(s.x, y0 + (TR_H - px * 0.78) * 0.42,
                    px * 0.78, COL.text, tostring(value), 1)
    else
      out, _, _, st = pal.x_ig_edit {
        id = id .. win.id, x = s.x, y = y0 + 1 * z,
        w = width, h = TR_H - 4 * z, text = tostring(value),
        px = px * 0.78, font = 1, enter = true, multiline = false,
      }
    end
    s.x = s.x + width + 4 * z
    return st and st.submit and out or nil
  end
  local bpm_text = tfield("music_bpm_", "bpm", doc.bpm, 34 * z)
  if bpm_text and tonumber(bpm_text) then
    local bpm = math.max(1, math.min(999, math.floor(tonumber(bpm_text))))
    if bpm ~= doc.bpm then
      local scope = p.playing and p.play_scope
      doc.bpm = bpm
      commit(ed, win.path)
      if scope then preview_start(ed, win, p, scope) end
    end
  end
  local sig = tostring(doc.beats_per_bar or 4) .. "/"
              .. tostring(doc.beat_unit or 4)
  local sig_text = tfield("music_sig_", "time", sig, 34 * z)
  if sig_text then
    local beats, unit = sig_text:match("^%s*(%d+)%s*/%s*(%d+)%s*$")
    beats, unit = tonumber(beats), tonumber(unit)
    local vb, vu = song.time_signature(beats, unit)
    if beats == vb and unit == vu
       and (vb ~= doc.beats_per_bar or vu ~= doc.beat_unit) then
      doc.beats_per_bar, doc.beat_unit = vb, vu
      commit(ed, win.path)
    end
  end
  if tchip(GRID_LABEL[win.grid or 3], false) then
    win.grid = (win.grid or 3) % 6 + 1 -- placement grid only
    ctx.touch()
  end
  if tchip("+ pat", false) then
    win.pat = M.new_pattern(doc, song.bar_ticks(doc))
    win.cursor, win.play_scope = 0, "clip"
    p.csel, p.csels, p.nsels, p.flat = nil, {}, {}, nil
    commit(ed, win.path)
    ctx.touch()
  end
  if tchip(win.edit_mode == "steps" and "piano" or "steps",
           win.edit_mode == "steps") then
    win.edit_mode = win.edit_mode == "steps" and "piano" or "steps"
    ctx.touch()
  end
  -- Permanent pattern-period feedback. This makes a grow from one to two bars
  -- visible without hunting for the thin end line, and makes the one-bar
  -- authoring floor explicit before somebody expects a one-beat phrase to
  -- repeat four times per bar. The pointer address bay uses the remaining
  -- right-side space and yields first in a narrow window.
  if pat then
    local pname = tfield("music_pat_name_", "p" .. tostring(pat.id),
                         pat.name or song.default_pattern_name(pat.id), 76 * z)
    if pname then
      pname = pname:match("^%s*(.-)%s*$"):sub(1, 255)
      if pname ~= "" and pname ~= pat.name then
        pat.name = pname
        commit(ed, win.path)
      end
    end
    local label = "loop " .. M.loop_span(pat.len, doc)
    local lw = pal.x_ig_text_size(label, px * 0.68, 0)
    pal.x_ig_text(s.x, y0 + (TR_H - px * 0.68) * 0.42, px * 0.68,
                  COL.dim, label, 0)
    s.x = s.x + lw + 6 * z
  end
  -- (no pattern chips — round 7: each clip owns its pattern; you pick
  -- what the roll edits by clicking a clip in the arrangement)

  -- ---- the arrangement strip: its OWN view (win.ar_tpp px/tick, win.ar_t0
  -- left tick, win.ar_sy vertical scroll) — MMB pans, wheel zooms, height
  -- win.arh resizes, and each lane keeps a FIXED reasonable height that
  -- scrolls vertically when there are many tracks (the human's ask) ----
  local ay = y0 + TR_H + SONG_RULER_H
  local bar = song.bar_ticks(doc)
  local beat = song.beat_ticks(doc)
  local atpp = math.max(0.02, win.ar_tpp or 0.14) * z -- px per tick (own zoom)
  local ar_t0 = win.ar_t0 or 0
  local lane_h = LANE_H * z
  local content_h = #doc.tracks * lane_h
  local ar_max_sy = math.max(0, content_h - AR_H)
  local ar_sy = math.max(0, math.min(win.ar_sy or 0, ar_max_sy))
  win.ar_sy = ar_sy
  -- The whole-song scrub is visually attached to the arrangement, not the
  -- drilled pattern. It has an independent cursor and makes song scope
  -- explicit before playback.
  local song_ruler_y = y0 + TR_H
  pal.x_ig_rect_fill(rx, song_ruler_y, rw, SONG_RULER_H, COL.rail, 2 * z)
  do
    local t = math.tointeger((ar_t0 // beat) * beat)
    while true do
      local lx = rx + (t - ar_t0) * atpp
      if lx > rx + rw then break end
      if lx >= rx then
        pal.x_ig_line(lx, song_ruler_y, lx, song_ruler_y + SONG_RULER_H,
                      t % bar == 0 and COL.beatln or COL.gridln, 1)
        if t % bar == 0 then
          pal.x_ig_text(lx + 2 * z, song_ruler_y, px * 0.62, COL.dim,
                        tostring(t // bar + 1), 0)
        end
      end
      t = t + beat
    end
    local cursor_x = rx + ((win.song_cursor or 0) - ar_t0) * atpp
    if cursor_x >= rx and cursor_x <= rx + rw then
      pal.x_ig_rect_fill(cursor_x - 2 * z, song_ruler_y, 4 * z,
                         SONG_RULER_H * 0.55, COL.accent, 1 * z)
    end
    if p.playing then
      local phx = rx + (M.preview_tick(p, doc) - ar_t0) * atpp
      if phx >= rx and phx <= rx + rw then
        pal.x_ig_line(phx, song_ruler_y, phx, song_ruler_y + SONG_RULER_H,
                      COL.head, math.max(1, 1.2 * z))
      end
    end
    local over = i.wx >= rx and i.wx < rx + rw
                 and i.wy >= song_ruler_y
                 and i.wy < song_ruler_y + SONG_RULER_H
    if ctx.hot and i.clicked[1] and over and not p.g then
      p.g = { t = "song_scrub" }
      win.play_scope = "song"
    end
    if p.g and p.g.t == "song_scrub" then
      if i.buttons[1] then
        local raw = ar_t0 + (i.wx - rx) / atpp
        -- Arrangement time snaps to the nearest beat. Besides matching clip
        -- movement, this avoids a grid-line click landing one beat early when
        -- the screen-to-tick division produces 767.999999 instead of 768.
        win.song_cursor = math.max(0, M.snap_delta(raw, beat))
        ctx.touch()
      else
        p.g = nil
      end
    end
  end
  pal.x_ig_rect_fill(rx, ay, rw, AR_H, COL.well, 3 * z)
  pal.x_ig_clip_push(rx, ay, rw, AR_H)
  local L = math.max(song.length(doc), bar * 16)
  do
    local t = math.tointeger(ar_t0 // beat) * beat
    while t <= L do
      local lx = rx + (t - ar_t0) * atpp
      if lx > rx + rw then break end
      if lx >= rx then
        pal.x_ig_line(lx, ay, lx, ay + AR_H,
                      t % bar == 0 and COL.beatln or COL.gridln, 1)
      end
      t = t + beat
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
  p.csels = p.csels or {}
  -- Clips in the selected set are unmistakable; other placements sharing the
  -- active pattern retain the linked-family glow.
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
      local selected = p.csels[c] or p.csel == ci
      pal.x_ig_rect_fill(vis_l, cy0 + 1, vis_r - vis_l, lane_h - 3,
                         (selected or hov) and COL.clip_hot
                         or kin and COL.note_dim or COL.clip, 2 * z)
      if selected then
        pal.x_ig_rect(vis_l, cy0 + 1, vis_r - vis_l, lane_h - 3,
                      COL.hot, math.max(1, 1 * z), 2 * z)
      end
      local edge_hot = hov and (cx0 + cw0 - i.wx) < 6 * z
      pal.x_ig_rect_fill(vis_r - (edge_hot and 3 or 1.5) * z, cy0 + 1,
                         (edge_hot and 3 or 1.5) * z, lane_h - 3,
                         edge_hot and COL.hot or 0xffffff30,
                         edge_hot and 1 * z or 0)
      local cpat = doc.patterns[c.pattern]
      local label = cpat and cpat.name or song.default_pattern_name(c.pattern)
      pal.x_ig_text(cx0 + 2 * z, cy0 + 1, px * 0.68,
                    selected and COL.hot or COL.dim, label, 0)
    end
  end
  -- the preview playhead
  if p.playing then
    local phx = rx + (M.preview_tick(p, doc) - ar_t0) * atpp
    if phx >= rx and phx <= rx + rw then
      pal.x_ig_line(phx, ay, phx, ay + AR_H, COL.head, math.max(1, 1.2 * z))
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

  -- Arrangement grammar follows the Playlist conventions: plain click places
  -- the active named pattern or moves a clip/selection; Shift-drag duplicates
  -- linked placements; Ctrl drags a marquee, Ctrl+Shift extends it; Alt
  -- temporarily bypasses beat snapping; right-click erases.
  p.arr = { x = rx, y = ay, w = rw, h = AR_H, atpp = atpp, t0 = ar_t0,
            sy = ar_sy, lane_h = lane_h, bar = bar, beat = beat }
  local function arr_pos()
    local tick = ar_t0 + (i.wx - rx) / atpp
    local lane = math.min(#doc.tracks - 1, math.max(0,
      math.tointeger((i.wy - ay + ar_sy) // lane_h)))
    return tick, lane
  end
  local function arr_hit(tick, lane)
    local hit, edge
    for ci, c in ipairs(doc.clips) do
      if c.track == lane and tick >= c.tick and tick < c.tick + c.len then
        hit = ci
        edge = (c.tick + c.len - tick) * atpp < 6 * z
      end
    end
    return hit, edge
  end
  local function drill(ci)
    local c = doc.clips[ci]
    if not c then return end
    p.csel = ci
    win.pat, win.trk = c.pattern, c.track + 1
    win.cursor, win.song_cursor, win.play_scope = 0, c.tick, "clip"
    p.nsels = {}
  end
  local function move_base(selection)
    local out = {}
    for _, c in ipairs(doc.clips) do
      if selection[c] then
        out[#out + 1] = { c = c, tick = c.tick, track = c.track }
      end
    end
    return out
  end
  if ctx.hot and i.clicked[1] and over_arr and not p.g and not rh_hot then
    local tick, lane = arr_pos()
    local hit, edge = arr_hit(tick, lane)
    if ed.g.ctrl then
      p.g = { t = "clipmarquee", x0 = i.wx, y0 = i.wy,
              hit = hit and doc.clips[hit], hit_i = hit,
              add = ed.g.shift, moved = false }
    elseif hit then
      local c = doc.clips[hit]
      if not p.csels[c] then p.csels = { [c] = true } end
      drill(hit)
      if ed.g.shift and not edge then
        local sources = move_base(p.csels)
        local copies, active
        copies = {}
        p.csels = {}
        for _, b in ipairs(sources) do
          local copy = { track = b.c.track, pattern = b.c.pattern,
                         tick = b.c.tick, len = b.c.len }
          doc.clips[#doc.clips + 1] = copy
          p.csels[copy] = true
          copies[#copies + 1] = { c = copy, tick = copy.tick,
                                  track = copy.track }
          if b.c == c then active = #doc.clips end
        end
        drill(active or #doc.clips)
        p.g = { t = "clipmove", base = copies, press_tick = tick,
                press_lane = lane, moved = false, dup = true }
        p.flat = nil
      elseif edge then
        p.g = { t = "clipsize", c = c, len = c.len, moved = false }
      else
        p.g = { t = "clipmove", base = move_base(p.csels),
                press_tick = tick, press_lane = lane, moved = false }
      end
    else
      local pid = win.pat
      if not (pid and doc.patterns[pid]) then
        pid = M.new_pattern(doc, bar)
      end
      local at = ed.g.alt and math.max(0, math.tointeger(math.floor(tick + 0.5)))
                 or math.max(0, M.snap_delta(tick, beat))
      local placed = { track = lane, pattern = pid, tick = at,
                       len = math.max(1, doc.patterns[pid].len) }
      doc.clips[#doc.clips + 1] = placed
      p.csel = #doc.clips
      p.csels = { [placed] = true }
      drill(p.csel)
      p.flat = nil
      commit(ed, win.path)
    end
    ctx.touch()
  end
  if p.g and (p.g.t == "clipmove" or p.g.t == "clipsize") then
    if i.buttons[1] then
      local tick, lane = arr_pos()
      if p.g.t == "clipmove" then
        local dt, dtrack = M.clip_move_delta(
          p.g.base, tick - p.g.press_tick, lane - p.g.press_lane,
          beat, ed.g.alt, #doc.tracks)
        if dt ~= (p.g.dt or 0) or dtrack ~= (p.g.dtrack or 0) then
          for _, b in ipairs(p.g.base) do
            b.c.tick, b.c.track = b.tick + dt, b.track + dtrack
          end
          local active = p.csel and doc.clips[p.csel]
          if active then
            win.trk, win.song_cursor = active.track + 1, active.tick
          end
          p.g.dt, p.g.dtrack = dt, dtrack
          p.g.moved = true
          ctx.touch()
        end
      else
        local c = p.g.c
        local raw = tick - c.tick
        local nl = ed.g.alt and math.max(1, math.tointeger(math.floor(raw + 0.5)))
                   or math.max(beat, M.snap_delta(raw, beat))
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
  if p.g and p.g.t == "clipmarquee" then
    if i.buttons[1] then
      if math.abs(i.wx - p.g.x0) > 3 * z
         or math.abs(i.wy - p.g.y0) > 3 * z then
        p.g.moved = true
      end
      if p.g.moved then
        local x1, x2 = math.min(p.g.x0, i.wx), math.max(p.g.x0, i.wx)
        local y1, y2 = math.min(p.g.y0, i.wy), math.max(p.g.y0, i.wy)
        pal.x_ig_rect(x1, y1, x2 - x1, y2 - y1, COL.accent,
                      math.max(1, 1 * z), 2 * z)
      end
      ctx.touch()
    else
      if p.g.moved then
        local x1, x2 = math.min(p.g.x0, i.wx), math.max(p.g.x0, i.wx)
        local y1, y2 = math.min(p.g.y0, i.wy), math.max(p.g.y0, i.wy)
        local sel = p.g.add and p.csels or {}
        local active
        for ci, c in ipairs(doc.clips) do
          local cx1 = rx + (c.tick - ar_t0) * atpp
          local cx2 = cx1 + c.len * atpp
          local cy1 = ay + c.track * lane_h - ar_sy
          local cy2 = cy1 + lane_h
          if cx1 < x2 and cx2 > x1 and cy1 < y2 and cy2 > y1 then
            sel[c], active = true, ci
          end
        end
        p.csels = sel
        if active then drill(active) elseif not p.g.add then p.csel = nil end
      elseif p.g.hit then
        if p.g.add then
          p.csels[p.g.hit] = not p.csels[p.g.hit] or nil
        else
          p.csels = { [p.g.hit] = true }
        end
        if p.csels[p.g.hit] then drill(p.g.hit_i) end
      elseif not p.g.add then
        p.csels, p.csel = {}, nil
      end
      p.g = nil
      ctx.touch()
    end
  end
  if ctx.hot and i.clicked[3] and over_arr and not p.g then
    local tick, lane = arr_pos()
    local hit = arr_hit(tick, lane)
    if hit then
      local dead = table.remove(doc.clips, hit)
      p.csels[dead] = nil
      p.csel = nil
      p.flat = nil
      commit(ed, win.path)
      ctx.touch()
    end
  end

  -- ---- channel-rack step sequencer ---------------------------------------
  -- A compact one-bar percussion door across tracks. Each row edits the
  -- pattern playing on that track near the song cursor (falling back to its
  -- first clip); left adds, right erases, and "roll" drills into the same
  -- bytes in the detailed piano editor.
  if win.edit_mode == "steps" then
    p.view, p.vlane = nil, nil
    local sy0 = ruler_y
    local sh = math.max(24 * z, vel_y + VEL_H - sy0)
    local head_h, step_row_h = 16 * z, 18 * z
    local label_w = math.min(120 * z, rw * 0.28)
    local subdivisions = 4
    local step_tick = math.max(1, song.beat_ticks(doc) // subdivisions)
    local nsteps = math.max(1, song.bar_ticks(doc) // step_tick)
    local at = win.song_cursor or 0
    local bar_at = math.tointeger((at // bar) * bar)
    local function track_clip(ti)
      if p.csel then
        local c = doc.clips[p.csel]
        if c and c.track == ti - 1 then return p.csel, c end
      end
      local fallback
      for ci, c in ipairs(doc.clips) do
        if c.track == ti - 1 then
          fallback = fallback or ci
          if at >= c.tick and at < c.tick + c.len then return ci, c end
        end
      end
      return fallback, fallback and doc.clips[fallback]
    end
    pal.x_ig_rect_fill(rx, sy0, rw, sh, COL.well, 3 * z)
    pal.x_ig_text(rx + 5 * z, sy0 + 2 * z, px * 0.72, COL.dim,
                  "steps · left add · right erase · roll opens piano", 0)
    local visible = math.max(1, math.tointeger((sh - head_h) // step_row_h))
    local first = math.max(1, math.min(
      math.max(1, #doc.tracks - visible + 1), (win.trk or 1) - 1))
    local last = math.min(#doc.tracks, first + visible - 1)
    p.step_pitch = p.step_pitch or {}
    for ti = first, last do
      local row_y = sy0 + head_h + (ti - first) * step_row_h
      local ci, c = track_clip(ti)
      local pt = c and doc.patterns[c.pattern]
      local pid = pt and pt.id
      local pitch = pid and p.step_pitch[pid]
      if not pitch then
        pitch = pt and pt.notes[1] and pt.notes[1].pitch or 60
        if pid then p.step_pitch[pid] = pitch end
      end
      local selected = (win.trk or 1) == ti
      if selected then
        pal.x_ig_rect_fill(rx, row_y, rw, step_row_h - 1,
                           0x7fd8a814, 2 * z)
      end
      local roll_w = 26 * z
      local roll_x = rx + label_w - roll_w - 3 * z
      local roll_hov = c and ctx.hot and i.wx >= roll_x
                       and i.wx < roll_x + roll_w
                       and i.wy >= row_y + 2 * z
                       and i.wy < row_y + step_row_h - 2 * z
      local name = pt and pt.name or (doc.tracks[ti].name or ("track " .. ti))
      pal.x_ig_text(rx + 4 * z, row_y + 3 * z, px * 0.7,
                    selected and COL.hot or COL.text, name, 0)
      pal.x_ig_rect_fill(roll_x, row_y + 2 * z, roll_w,
                         step_row_h - 4 * z, COL.btn, 2 * z)
      pal.x_ig_text(roll_x + 3 * z, row_y + 3 * z, px * 0.62,
                    roll_hov and COL.hot or COL.dim, "roll", 0)
      if roll_hov and i.clicked[1] then
        p.csels = { [c] = true }
        drill(ci)
        win.edit_mode = "piano"
        ctx.touch()
        return
      end
      local step_x = rx + label_w
      local step_w = math.max(3 * z, (rw - label_w - 4 * z) / nsteps)
      for si = 1, nsteps do
        local sx = step_x + (si - 1) * step_w
        local st = (si - 1) * step_tick
        local note
        if pt then
          for _, n in ipairs(pt.notes) do
            if n.tick == st and n.pitch == pitch then note = n; break end
          end
        end
        local hov = ctx.hot and i.wx >= sx + 1
                    and i.wx < sx + step_w - 1
                    and i.wy >= row_y + 3 * z
                    and i.wy < row_y + step_row_h - 3 * z
        local base_col = ((si - 1) // subdivisions) % 2 == 0
                         and COL.btn or 0x302b48ff
        pal.x_ig_rect_fill(sx + 1, row_y + 3 * z,
                           math.max(1, step_w - 2), step_row_h - 6 * z,
                           note and (hov and COL.hot or COL.accent)
                           or hov and COL.btn_on or base_col, 2 * z)
        if hov and (i.clicked[1] or i.clicked[3]) then
          if not pt and i.clicked[1] then
            local newpid = M.stamp_fresh(doc, ti - 1, bar_at, bar)
            ci, c = #doc.clips, doc.clips[#doc.clips]
            pt, pid = doc.patterns[newpid], newpid
            pitch, p.step_pitch[pid] = 60, 60
          end
          if pt then
            local changed_note, changed =
              M.set_step(pt, st, pitch, step_tick, i.clicked[1])
            if changed then
              p.csel, p.csels = ci, { [c] = true }
              win.pat, win.trk, win.play_scope = pt.id, ti, "clip"
              p.nsels = changed_note and i.clicked[1]
                        and { [changed_note] = true } or {}
              p.flat = nil
              commit(ed, win.path)
              ctx.touch()
              return
            end
          end
        end
      end
      pal.x_ig_line(rx, row_y + step_row_h - 1, rx + rw,
                    row_y + step_row_h - 1, COL.gridln, 1)
    end
    return
  end

  -- ---- the piano keys column (round 10 — the human): a playable
  -- keyboard on the roll's left edge. Ruler, roll, and velocity lane
  -- all start to its right through this ONE shift, so their tick axes
  -- stay aligned; the arrangement above keeps the full width. The
  -- keys themselves draw after the roll (they read the panned view).
  local KEYS_W = math.min(18 * z, rw * 0.14)
  local keys_x = rx
  rx, rw = rx + KEYS_W, rw - KEYS_W

  -- The drilled clip has its own explicit transport. It loops the exact
  -- last-clicked clip span in song context, so backing tracks remain audible.
  local clip_playing = p.playing and p.play_scope == "clip"
  do
    local enabled = p.csel and doc.clips[p.csel]
    local hov = enabled and ctx.hot and i.wx >= keys_x
                and i.wx < keys_x + KEYS_W and i.wy >= ruler_y
                and i.wy < ruler_y + RULER_H
    pal.x_ig_rect_fill(keys_x, ruler_y, KEYS_W - 2 * z, RULER_H,
                       clip_playing and COL.btn_on or COL.btn, 2 * z)
    pal.x_ig_text(keys_x + 2 * z, ruler_y + 1 * z, px * 0.62,
                  (hov or clip_playing) and COL.hot or COL.dim,
                  clip_playing and "stop" or "clip", 0)
    if hov and i.clicked[1] then
      if clip_playing then
        preview_stop(p)
      else
        win.play_scope = "clip"
        preview_start(ed, win, p, "clip")
      end
      ctx.touch()
    end
  end

  -- ---- the pattern-local scrub ruler: click/drag sets the selected clip's
  -- local entry point. Song scrubbing lives above the arrangement. ----
  do
    local rtick0 = win.tick0 or 0
    local function r2x(t) return rx + (t - rtick0) * tpp end
    pal.x_ig_rect_fill(rx, ruler_y, rw, RULER_H, COL.rail, 3 * z)
    local bar = song.bar_ticks(doc)
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
    if clip_playing and p.csel and doc.clips[p.csel] then
      local phx = r2x(M.preview_tick(p, doc) - doc.clips[p.csel].tick)
      pal.x_ig_line(phx, ruler_y, phx, ruler_y + RULER_H, COL.head,
                    math.max(1, 1.4 * z))
    end
    -- gesture: set the cursor (grid-snapped; drag scrubs)
    local over = i.wx >= rx and i.wx < rx + rw and i.wy >= ruler_y
                 and i.wy < ruler_y + RULER_H
    if ctx.hot and i.clicked[1] and over and not p.g then
      p.g = { t = "scrub" }
      win.play_scope = "clip"
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
  local nrows = math.tointeger(roll_h // row_h) or 0
  local max_low = math.max(0, 127 - nrows)
  local lowf = math.max(0, math.min(max_low, win.lownote or 45))
  win.lownote = lowf
  if win.lownote_target then
    win.lownote_target = math.max(0, math.min(max_low, win.lownote_target))
    local d = win.lownote_target - lowf
    if math.abs(d) > 0.02 then
      lowf = lowf + d * 0.34
      win.lownote = lowf
      ctx.touch()
    else
      lowf, win.lownote = win.lownote_target, win.lownote_target
    end
  end
  local low = math.floor(lowf)
  local suby = (lowf - low) * row_h
  local tick0 = win.tick0 or 0
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

  -- MMB on the keyboard changes vertical note scale; MMB in the roll pans.
  -- This mirrors a piano-roll zoom gesture without stealing ordinary audition.
  local middle_keys = i.wx >= keys_x and i.wx < keys_x + KEYS_W
                      and i.wy >= roll_y and i.wy < roll_y + roll_h
  if ctx.focused and i.clicked[2] and not over_arr then
    if middle_keys then
      p.rowzoom = { my = i.wy, row_h = win.row_h or 14 }
    else
      p.pan = { mx = i.wx, my = i.wy, t0 = tick0, lf = lowf }
    end
  end
  if p.rowzoom then
    if i.buttons[2] then
      win.row_h = math.max(5, math.min(32,
        p.rowzoom.row_h + (p.rowzoom.my - i.wy) / (4 * z)))
      win.lownote_target = nil
      ctx.touch()
    else
      p.rowzoom = nil
    end
  end
  if p.pan then
    if i.buttons[2] then
      win.tick0 = math.max(0, p.pan.t0 - (i.wx - p.pan.mx) / tpp)
      win.lownote = math.max(0, math.min(127 - nrows,
        p.pan.lf + (i.wy - p.pan.my) / row_h))
      win.lownote_target = nil
      ctx.touch()
      lowf = win.lownote
      low = math.floor(lowf)
      suby = (lowf - low) * row_h
      tick0 = win.tick0
    else
      p.pan = nil
    end
  end

  -- Holding either a piano key or a stored/added note lights the entire pitch
  -- row, tying audition feedback to the editable lane.
  local held_pitch
  if i.buttons[1] and p.g then
    if p.g.t == "keys" then held_pitch = p.g.kp
    elseif (p.g.t == "selmove" or p.g.t == "selsize") and p.g.grab then
      held_pitch = p.g.grab.pitch
    end
  end
  if held_pitch then
    local hy = roll_y + (low + nrows - held_pitch) * row_h - suby
    pal.x_ig_rect_fill(rx, hy, rw, row_h, 0x7fd8a824)
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
                    t % beat == 0 and COL.beatln or COL.gridln, 1)
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
  local function resize_hit(tick, pitch)
    local inset = GRIDS[#GRIDS] / 2
    local outside = 4 * z / tpp
    local hit, hit_sel, best, best_sel
    for ni, n in ipairs(pat.notes) do
      local edge = n.tick + n.dur
      if pitch == n.pitch and tick >= math.max(n.tick, edge - inset)
         and tick <= edge + outside then
        local d = math.abs(tick - edge)
        if p.nsels[n] then
          if not best_sel or d < best_sel then hit_sel, best_sel = ni, d end
        elseif not best or d < best then
          hit, best = ni, d
        end
      end
    end
    return hit_sel or hit
  end
  local roll_hot = ctx.hot and i.wx >= rx and i.wx < rx + rw
                   and i.wy >= roll_y and i.wy < roll_y + roll_h
  local function draw_note(n, selected)
    local nx, ny, nw, nh = note_rect(n)
    pal.x_ig_rect_fill(nx, ny + 1, nw - 1, nh - 2,
                       selected and 0xE8E4FFc8 or COL.note, 2)
    if selected then
      pal.x_ig_rect(nx, ny + 1, nw - 1, nh - 2, COL.hot,
                    math.max(1, 1 * z), 2)
    end
    local label, lpx = M.note_name(n.pitch), math.min(px * 0.66, nh * 0.58)
    if nh >= 7 * z and nw >= pal.x_ig_text_size(label, lpx, 0) + 4 * z then
      pal.x_ig_text(nx + 2 * z, ny + (nh - lpx) * 0.42, lpx,
                    selected and COL.rail or COL.well, label, 0)
    end
  end
  for ni, n in ipairs(pat.notes) do -- unselected notes first
    if not (p.nsel == ni or p.nsels[n]) then
      draw_note(n, false)
    end
  end
  -- selected notes draw LAST and slightly translucent: an overlapped
  -- note stays visible THROUGH the selection, so the overlap can be
  -- seen and fixed (round 9)
  for ni, n in ipairs(pat.notes) do
    if p.nsel == ni or p.nsels[n] then
      draw_note(n, true)
    end
  end
  -- resize handle: a bright bar when hovering the right edge of the
  -- note a press would grab, so the resize zone is discoverable (the
  -- human — hoverable handles)
  if roll_hot and not p.g and not p.paste then
    local hi = resize_hit(x2t(i.wx), y2pitch(i.wy))
    local n = hi and pat.notes[hi]
    if n then
      local nx, ny, nw, nh = note_rect(n)
      pal.x_ig_rect_fill(nx + nw - 2 * z, ny + 1, 2.5 * z, nh - 2,
                         COL.head, 1 * z)
    end
  end
  -- A separate selection handle stretches timing and durations together,
  -- equivalent to FL's score stretch handle. Ordinary note-edge resize below
  -- still offsets only lengths across the selected set.
  local stretch_hot, stretch_info = false, nil
  do
    local count, tmin, tend = 0, math.huge, 0
    local pmin, pmax = 127, 0
    for _, n in ipairs(pat.notes) do
      if p.nsels[n] then
        count = count + 1
        tmin, tend = math.min(tmin, n.tick), math.max(tend, n.tick + n.dur)
        pmin, pmax = math.min(pmin, n.pitch), math.max(pmax, n.pitch)
      end
    end
    if count >= 2 and tend > tmin then
      local hx = t2x(tend) + 6 * z
      local hy1 = roll_y + (low + nrows - pmax) * row_h - suby
      local hy2 = roll_y + (low + nrows - pmin + 1) * row_h - suby
      local cy = (hy1 + hy2) * 0.5
      stretch_hot = ctx.hot and i.wx >= hx - 5 * z and i.wx <= hx + 5 * z
                    and i.wy >= hy1 and i.wy <= hy2
      pal.x_ig_line(t2x(tend), cy, hx, cy, COL.hot, 1)
      pal.x_ig_rect_fill(hx - 2 * z, cy - 7 * z, 4 * z, 14 * z,
                         stretch_hot and COL.head or COL.hot, 1 * z)
      stretch_info = { anchor = tmin, span = tend - tmin }
    end
  end
  -- the roll grammar: Ctrl marquee/replace, Ctrl+Shift add/toggle,
  -- Shift-drag pitch-locked duplicate, plain selected drag moves the set
  local over_roll = i.wx >= rx and i.wx < rx + rw and i.wy >= roll_y
                    and i.wy < roll_y + roll_h
  -- placement snaps to the grid; the 1/32 grid + zoom provide precision.
  local function snap(t)
    return math.tointeger(math.max(0, (t // grid) * grid))
  end
  local function snapd(d) -- a MOVE delta -> the nearest grid step (signed)
    return M.snap_delta(d, grid)
  end
  local function note_commit()
    local clip = p.csel and doc.clips[p.csel]
    M.fit_pattern_clip(doc, pat, clip) -- end line + untouched clip follow
    p.flat = nil
    commit(ed, win.path)
  end
  if ctx.hot and i.clicked[1] and over_roll and not p.g and not p.paste then
    local tick = x2t(i.wx)
    local pitch = y2pitch(i.wy)
    local edge_hit = resize_hit(tick, pitch)
    local hit = edge_hit or note_hit(tick, pitch)
    local edge = edge_hit ~= nil
    if stretch_hot and stretch_info then
      local base = {}
      for n in pairs(p.nsels) do
        base[#base + 1] = { n = n, tick = n.tick, dur = n.dur }
      end
      p.g = { t = "selstretch", anchor = stretch_info.anchor,
              span = stretch_info.span, last = stretch_info.span,
              base = base, moved = false }
    elseif ed.g.shift and not ed.g.ctrl and hit then
      -- in-place note duplicate; horizontal
      -- drag can place the copies in time, while pitch deliberately stays put.
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
              moved = false, dup = true, pitch_lock = true }
      blip_hold(ed, win, p, p.g, grab.pitch, grab.vel)
    elseif ed.g.ctrl then -- standard selection: Ctrl replaces, Ctrl+Shift adds
      p.g = { t = "marquee", x0 = i.wx, y0 = i.wy,
              hit = hit and pat.notes[hit], add = ed.g.shift,
              moved = false }
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
      if math.abs(i.wx - p.g.x0) > 3 * z
         or math.abs(i.wy - p.g.y0) > 3 * z then
        p.g.moved = true
      end
      if p.g.moved then
        local x0, x1 = math.min(p.g.x0, i.wx), math.max(p.g.x0, i.wx)
        local y0, y1 = math.min(p.g.y0, i.wy), math.max(p.g.y0, i.wy)
        pal.x_ig_rect(x0, y0, x1 - x0, y1 - y0, COL.accent,
                      math.max(1, 1 * z), 2 * z)
      end
      ctx.touch()
    else
      if p.g.moved then
        local t0, t1 = x2t(math.min(p.g.x0, i.wx)),
                       x2t(math.max(p.g.x0, i.wx))
        local phi = y2pitch(math.min(p.g.y0, i.wy))
        local plo = y2pitch(math.max(p.g.y0, i.wy))
        local sel = p.g.add and p.nsels or {}
        for _, n in ipairs(pat.notes) do
          if n.tick < t1 and n.tick + n.dur > t0
             and n.pitch >= plo and n.pitch <= phi then
            sel[n] = true
          end
        end
        p.nsels = sel
      elseif p.g.hit then
        if p.g.add then
          p.nsels[p.g.hit] = not p.nsels[p.g.hit] or nil
        else
          p.nsels = { [p.g.hit] = true }
        end
      elseif not p.g.add then
        p.nsels = {}
      end
      p.nsel = nil
      p.g = nil
      ctx.touch()
    end
  end
  if p.g and p.g.t == "selstretch" then
    if i.buttons[1] then
      local raw = x2t(i.wx) - p.g.anchor
      local span = ed.g.alt and math.max(1, math.tointeger(math.floor(raw + 0.5)))
                   or math.max(grid, M.snap_delta(raw, grid))
      if span ~= p.g.last then
        local scale = span / p.g.span
        for _, b in ipairs(p.g.base) do
          b.n.tick = p.g.anchor
                     + math.floor((b.tick - p.g.anchor) * scale + 0.5)
          b.n.dur = math.max(1, math.floor(b.dur * scale + 0.5))
        end
        p.g.last, p.g.moved = span, true
        ctx.touch()
      end
    else
      if p.g.moved then note_commit() end
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
      local ndp = p.g.pitch_lock and 0
                  or math.max(-127, math.min(127,
                    (pitch - p.g.dp) - p.g.gp))
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
  -- (time anchor = the clip's earliest note; original pitches stay fixed),
  -- a click places it as one journal entry
  -- and the pasted notes become the selection; right-click / Esc
  -- cancels. MMB pan + wheel zoom stay live while armed.
  if p.paste and p.paste.clip and #p.paste.clip > 0 then
    local clip = p.paste.clip
    local at = snap(x2t(i.wx))
    local dp = 0
    if roll_hot then
      for _, c in ipairs(clip) do
        local gx, gy, gw, gh = note_rect { tick = at + c.dtick,
                                           pitch = c.pitch + dp,
                                           dur = c.dur }
        pal.x_ig_rect_fill(gx, gy + 1, gw - 1, gh - 2, 0x7fd8a866, 2)
      end
    end
    pal.x_ig_text(rx + 8 * z, roll_y + 4 * z, px * 0.85, COL.accent,
                  "paste: time follows · pitch stays · esc cancels", 0)
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
                             doc, n)
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

-- Alt is normally the canvas/window grammar. The focused arrangement claims
-- an Alt-press over its own pixels so it can provide the DAW-standard
-- temporary snap bypass without also moving the editor window.
function M.takes_alt(win, ed)
  if win.path == "" or not ed or ed.doc.focus ~= win.id then return false end
  local p = ed.g.muw and ed.g.muw[win.path]
  local ar = p and p.arr
  local i = cm.require("cm.ui").inp
  return ar and i.wx >= ar.x and i.wx < ar.x + ar.w
         and i.wy >= ar.y and i.wy < ar.y + ar.h
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
  M.invalidate_preview_track(p, ti)
  if p.playing or p.blips then preview_slots(ed, win, p) end
  p.flat = nil
  commit(ed, win.path)
  pal.log("[ed] bound " .. rel .. " -> " .. doc.tracks[ti].name)
  return true
end

return M
