-- cm.tween — the tween/effect slice of A5 (D094). Named decaying effect
-- counters on any plain table, with the eased presentation math the demos
-- hand-rolled: swarm's hit pause / shake / death flash triple (three doc
-- counters plus draw-side offset/alpha math re-deriving the lifetime),
-- the platformer's squash/stretch timers (ease over t/t0 in player.lua),
-- and cellar's sin bobs — the standing PAIN(effect) votes; §2's
-- "easing/tweens, hit pause, flashes" line.
--
-- An effect is plain data: play() arms an integer frame countdown that
-- REMEMBERS its lifetime (the t0 the flash math needs) on o.tw of any doc
-- table — an actor, the doc root, your own table. Canon, snapshots,
-- traces, rewind, and hot reload carry effects by construction. No module
-- state, no buffers, no callbacks.
--
--   local tween = cm.require("cm.tween")
--   tween.play(d, "flash", 14, 0.55)   -- arm: 14 frames, strength 0.55
--   tween.play(d, "pause", 2)          -- the hit-pause counter
--   -- each step:
--   tween.tick(d)                      -- ONCE per step, top of step
--   if tween.on(d, "pause") then return end   -- world frozen, effects run
--   -- in draw:
--   local a = tween.flash(d, "flash")          -- 0.55 fading to 0 (policy-aware)
--   local sx, sy = tween.wobble(d, "shake")    -- the screen-shake offset
--
-- Semantics, pinned by KATs:
--   * play(o, name, frames [, mag]) arms (or REPLACES — the camera.shake
--     rule) effect `name`: o.tw[name] = { t = frames, t0 = frames, mag }.
--     frames is an integer >= 0; 0 stops the effect. mag is one optional
--     number stored for val/wobble (their default strength).
--   * tick(o) — once per step, top of step — decrements every effect
--     independently (hash order cannot matter), removes each one tick
--     AFTER it reaches 0, and drops the empty o.tw. The zero frame
--     therefore exists: play(n) keeps the effect present for exactly n
--     ticks, so `if tween.on(d, "pause") then return end` after tick(d)
--     freezes the world for exactly n steps — and the tween table keeps
--     ticking through its own freeze (arm effects, skip the world).
--   * k(o, name) -> t/t0: the remaining fraction, 1 at the armed frame's
--     own draw, 0 on the zero frame and when idle. All the presentation
--     math is pure functions of it — deterministic, safe anywhere,
--     though wobble output belongs to draw by policy (camera.offset's
--     rule: sim results must never read the shake).
--   * val(o, name [, curve]) -> mag * curve(k) — the decay envelope
--     (curve default "linear", resolved by name through cm.ease so it can
--     live beside the counters in doc; mag default 1). Idle -> 0.
--   * mix(o, name, from, to [, curve]) -> to + (from - to) * curve(k):
--     `from` at full, easing to the rest value `to`; idle -> to. The
--     explicit-endpoints form (slide-ins, color washes).
--   * wobble(o, name) -> ox, oy: the render-only shake offset, amplitude
--     mag * k with the fixed incommensurate sin pair off the remaining
--     count — exactly cm.camera.offset for tables that are not cameras
--     (swarm has no camera). Never the PRNG. Idle -> 0, 0. Scaled by the
--     player's reduce-shake accessibility policy (D129), which is why it
--     belongs to draw: the counters are recorded, the offset is per-player.
--   * flash(o, name [, curve]) -> val scaled by the reduce-flash policy
--     (D129): draw flash-overlay alphas through this door and players who
--     asked for fewer flashes get an attenuated wash. Render-only like
--     wobble; val/k/mix stay pure for sim reads (hit pause).
--   * bob(frame, period, amp) -> the pure looping wobble (cellar's item
--     bobs): amp * sin(frame * tau / period). Not an effect — just the
--     idiom, off the sim frame count, render-only by convention.
--   * reserved: the host table's `tw` key. stop(o, name) ends one effect
--     now; clear(o) ends them all (the reset/room-swap door).
--
-- Deliberately NOT here (absorb the demonstrated pain, no more):
-- sequences/chains, per-field auto-writing tweens, callbacks/events,
-- springs, wall-clock time, particles (the demo's fx.lua pool is buffer
-- craft, not counters). Later slices earn those from real demo pain.

local M = select(2, ...) or {}
local m = cm.require("cm.math")
local ease = cm.require("cm.ease")

-- play(o, name, frames [, mag]): arm/replace an effect. frames 0 stops.
function M.play(o, name, frames, mag)
  if type(name) ~= "string" then
    error("tween.play: name must be a string", 2)
  end
  if math.type(frames) ~= "integer" or frames < 0 then
    error("tween.play: frames must be an integer >= 0", 2)
  end
  if mag ~= nil and type(mag) ~= "number" then
    error("tween.play: mag must be a number", 2)
  end
  if frames == 0 then return M.stop(o, name) end
  local tw = o.tw
  if tw == nil then tw = {}; o.tw = tw end
  tw[name] = { t = frames, t0 = frames, mag = mag }
end

-- stop(o, name): end one effect now (idle immediately)
function M.stop(o, name)
  local tw = o.tw
  if tw == nil then return end
  tw[name] = nil
  if next(tw) == nil then o.tw = nil end
end

-- clear(o): end every effect — the reset/room-swap door
function M.clear(o)
  o.tw = nil
end

-- tick(o): once per step, top of step. Decrements each effect
-- independently; an effect leaves the table one tick after reaching 0
-- (the zero frame exists — see the header).
function M.tick(o)
  local tw = o.tw
  if tw == nil then return end
  for name, e in pairs(tw) do
    if e.t > 0 then e.t = e.t - 1 else tw[name] = nil end
  end
  if next(tw) == nil then o.tw = nil end
end

-- on(o, name): the effect is present (counting or on its zero frame)
function M.on(o, name)
  local tw = o.tw
  return tw ~= nil and tw[name] ~= nil
end

-- k(o, name) -> the remaining fraction t/t0 (0 when idle)
function M.k(o, name)
  local tw = o.tw
  local e = tw and tw[name]
  if e == nil then return 0.0 end
  return e.t / e.t0
end

-- val(o, name [, curve]) -> mag * curve(k): the decay envelope (0 idle)
function M.val(o, name, curve)
  local tw = o.tw
  local e = tw and tw[name]
  if e == nil then return 0.0 end
  return (e.mag or 1.0) * ease.get(curve or "linear")(e.t / e.t0)
end

-- mix(o, name, from, to [, curve]) -> eased between from (full) and the
-- rest value to (idle)
function M.mix(o, name, from, to, curve)
  local tw = o.tw
  local e = tw and tw[name]
  if e == nil then return to end
  return to + (from - to) * ease.get(curve or "linear")(e.t / e.t0)
end

-- wobble(o, name) -> ox, oy: the render-only shake offset, amplitude
-- mag * k off the remaining count (cm.camera.offset's exact idiom —
-- never the PRNG), scaled by the player's reduce-shake policy (D129).
-- Sim results must never read it — val/k stay the pure sim-legal reads.
function M.wobble(o, name)
  local tw = o.tw
  local e = tw and tw[name]
  if e == nil then return 0.0, 0.0 end
  local a = (e.mag or 1.0) * e.t / e.t0
        * cm.require("cm.view").shake_scale()
  if a == 0 then return 0.0, 0.0 end
  return m.sin(e.t * 2.7) * a, m.sin(e.t * 3.1 + 2) * a
end

-- flash(o, name [, curve]) -> val scaled by the player's reduce-flash
-- policy (D129): THE door for flash-overlay alphas — a full-screen wash
-- drawn at flash() attenuates for players who asked for fewer flashes,
-- while val() stays pure for sim reads (hit pause, gameplay timers).
-- Render-only by the wobble rule: sim results must never read it.
function M.flash(o, name, curve)
  return M.val(o, name, curve) * cm.require("cm.view").flash_scale()
end

-- bob(frame, period, amp): the pure looping wobble — amp * sin over a
-- period in frames (cellar's items, breathing idles). period > 0.
function M.bob(frame, period, amp)
  if type(period) ~= "number" or period <= 0 then
    error("tween.bob: period must be a number > 0", 2)
  end
  return (amp or 1.0) * m.sin(frame * (m.tau / period))
end

return M
