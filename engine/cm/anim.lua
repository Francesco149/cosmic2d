-- cm.anim — the animation CLIP evaluator: a pure function of (clip data, an
-- integer elapsed) → frame index, plus the on-disk .anim clip-table codec.
-- M10 Phase 4, D040, STUDIO.md §7. The engine MECHANISM; the cartridge owns the
-- POLICY (which clip a state plays, where the playhead is anchored) — mirroring
-- D030/D035. cm.anim adds NO sim state of its own: it is a pure evaluator over
-- data + an integer tick count.
--
-- Determinism class: the evaluator (frame_at/duration) is pure integer math —
-- no float, no libm, no hidden state — so it is safe to call from sim code (a
-- controller reading its own t0_frame) AND from render code (a cosmetic idle bob
-- off the frame counter). The two timing anchors (STUDIO.md §7):
--   cosmetic  — elapsed = state.frame() - t0, recomputed each draw, zero stored
--               state, never snapshotted.
--   sim-bound — the controller keeps t0_frame in its OWN named buffer (already
--               snapshotted sim state) and reads the same evaluator.
-- The studio's wall-clock PREVIEW is dev-only and may use a real clock; that
-- never reaches the sim (STUDIO.md §1).
--
-- A clip:
--   { name = "idle", loop = "loop"|"once"|"pingpong",
--     frames = { {frame=<index>, dur=<ticks≥1>}, … } }   -- dur in 1/60 s ticks
--
-- The .anim file is the clip ARRAY as canonical doc bytes (cm.state.canon, like
-- knobs.dat) — authoring order preserved, the runtime loader reads it.

local M = select(2, ...) or {}

local floor, max, min = math.floor, math.max, math.min

-- the effective entry sequence to walk. "pingpong" bounces by appending the
-- reverse of the interior frames (Aseprite model: A,B,C → A,B,C,B looped), so
-- the endpoints aren't held an extra beat; ≤2 frames degenerate to a plain loop.
local function sequence(clip)
  local fr = clip.frames
  if clip.loop ~= "pingpong" or #fr <= 2 then return fr end
  local s = {}
  for i = 1, #fr do s[i] = fr[i] end
  for i = #fr - 1, 2, -1 do s[#s + 1] = fr[i] end
  return s
end

-- total ticks of ONE forward play-through (the intuitive "clip length"); the
-- pingpong bounce is longer but this is what a length readout wants. ≥0.
function M.duration(clip)
  local t = 0
  if clip and clip.frames then
    for _, e in ipairs(clip.frames) do t = t + max(1, floor(e.dur or 1)) end
  end
  return t
end

-- the frame index to show at `elapsed` ticks into `clip` (elapsed ≥ 0; floored).
-- Empty clip → 0; single frame → that frame. loop modes:
--   loop      wrap forever (elapsed mod total)
--   once      play through, then HOLD the final frame
--   pingpong  bounce forever over the extended sequence
-- Pure + deterministic: integer arithmetic only.
function M.frame_at(clip, elapsed)
  local fr = clip and clip.frames
  if not fr or #fr == 0 then return 0 end
  if #fr == 1 then return fr[1].frame end
  elapsed = floor(elapsed or 0)
  if elapsed < 0 then elapsed = 0 end

  local s = sequence(clip)
  local total = 0
  for _, e in ipairs(s) do total = total + max(1, floor(e.dur or 1)) end
  if total <= 0 then return s[1].frame end

  local e
  if clip.loop == "once" then
    e = min(elapsed, total - 1) -- hold the last frame past the end
  else
    e = elapsed % total -- loop / pingpong repeat the (extended) sequence
  end

  local acc = 0
  for _, ent in ipairs(s) do
    acc = acc + max(1, floor(ent.dur or 1))
    if e < acc then return ent.frame end
  end
  return s[#s].frame -- unreachable (e < total), a guard
end

-- find a clip by name in a clip array (the runtime's policy lookup), or nil.
function M.find(clips, name)
  if clips then
    for _, c in ipairs(clips) do if c.name == name then return c end end
  end
  return nil
end

-- ---- the .anim clip table (canonical doc bytes; dev/asset class) ----

local LOOPS = { loop = true, once = true, pingpong = true }

-- normalize a clip array to a plain doc tree (integers floored, loop validated)
-- so canon accepts it and the bytes are stable. Shared by encode + sanitize.
local function normalize(clips)
  local t = {}
  for i, c in ipairs(clips or {}) do
    if type(c) == "table" then
      local fr = {}
      for _, e in ipairs(c.frames or {}) do
        if type(e) == "table" then
          fr[#fr + 1] = { frame = max(0, floor(e.frame or 0)),
                          dur = max(1, floor(e.dur or 1)) }
        end
      end
      t[#t + 1] = {
        name = tostring(c.name or ("clip" .. i)),
        loop = LOOPS[c.loop] and c.loop or "loop",
        frames = fr,
      }
    end
  end
  return t
end

function M.encode(clips)
  return cm.require("cm.state").canon(normalize(clips))
end

function M.decode(bytes)
  local t = cm.require("cm.state").parse(bytes)
  return normalize(type(t) == "table" and t or {})
end

-- write / read the .anim sidecar (dev/asset class: boot-time-or-explicit, never
-- sim input — the same rule as knobs.dat / map.dat). Atomic replacement keeps
-- a compatibility caller from truncating the last usable sidecar.
function M.save(path, clips, fail)
  local ok, err = pal.write_file_atomic(path, M.encode(clips), fail)
  if not ok then return nil, "write animation sidecar " .. path .. " failed: " .. tostring(err) end
  return true
end

function M.load(path)
  local bytes = pal.read_file(path)
  if not bytes then return nil end
  local ok, clips = pcall(M.decode, bytes)
  if not ok then return nil end
  return clips
end

return M
