# cosmic3d — status

Living handoff doc. Update at session/milestone end. (Reset at the fork;
cosmic2d's own status history lives in the upstream repo and
`history/STATUS-2026-07.md`.)

## 2026-07-17 (round 18 playtest) — sheets become assets; four verdicts in

Human played rovale: **"exactly the vibe we would want"**, with four
fixes, all landed. (1) **Sprite sheets are PERMANENT assets now**:
spr.lua writes RLE-packed `.spx` files (committed, ~205KB each,
projects/rovale/spr/) on first rasterize and boots load them instantly;
`game.rebake_sprites()` re-rasterizes + rewrites (SPR_STAMP invalidates
other checkouts; the suite's read-only store falls back to rasterizing).
(2) **The shimmering diagonal west of the map**: the apron's corner
strips overlapped coplanar and z-fought — rebuilt as four
NON-overlapping bands on one TILE-step lattice (ring seams and the mesh
edge share vertices exactly; W.terrain_h clamp went 0.01-inset -> exact
bounds for the same reason). (3) **Billboards fully face the camera**
(they foreshortened under pitch): quads now span camera right x camera
up, feet-anchored — full size at any pitch, verified at pitch 1.15.
(4) **Click sfx on the press EDGE only** — held-repeat re-commands
silently (the sfx moved from player.command to main's edge path; demo
clicks still tick). Trace verify PASS unregenerated through all four;
both pixels re-shot (deliberate: billboards changed); the RO_BUDGET
honesty cmp re-proven. Suite ALL GREEN.

## 2026-07-17 (round 18) — rovale: demo 3, the RO vale

Two human verdicts opened the round: **the streaming demo "feels
great"**, and the direction — **the RO-style demo now, then distil all
three demos into engine ergonomics** (recorded as COSMIC3D.md §8f; the
distillation phase begins when demo 3's slice is approved). Sketch
first (§11 + a measured soak: bake ~4.8µs/texel, heap A* ~2.9ms
worst-case, pick ray ~60µs), then **projects/rovale** (D3D-026): the
proto ro2 look in-engine. The signature move: every tile gets a UNIQUE
34×34 gutter-baked blended texture (grass/dirt/sand feathered over
noisy bands, prop shadows on the authentic 8×8 lattice) packed into one
1088×1088 atlas — baked in draw under a budget knob behind a loading
bar (render-class end to end; the tour pixel re-shot under
_G.RO_BUDGET=32 is BYTE-IDENTICAL). **Click-to-move is sim input**:
pick ray → walk-grid snap (64×64 1u cells, GAT scale) → heap A* → cell
chain; demo(1) tours by synthesizing clicks through the real pipeline.
**The figure→sprite bake went live** (spr.lua, ~0.25s/variant): the
mascot + three color variants rasterized to 8-yaw×7-row sheets by a
tiny Lua rasterizer, drawn as recipe billboards (nearest+alphatest,
0.7+0.3·shadow tint, water after sprites at 144/255). Plaza deck slabs
are walkable props (W.ground override — §4's answer in miniature);
path ford + border apron round out the vale. Three NPCs amble and
greet with baked wave rows + typed lines. Goldens: rovale_tour.ctrace
(1000f: ford wade, deck stand, two greets) drift-proven + two pixels +
the honesty cmp. Suite ALL GREEN; 3 shots on the feed.

## Exact next step

1. R18 verdict landed: **"exactly the vibe we would want"** (the four
   playtest fixes above are in). Feed questions still open
   (non-blocking): R17's and earlier (see round 17's list below).
2. **rovale grows on verdicts**; ungated candidates: cliff tiles (the
   GND sharp-edge model — forces the sprite depth-pull question),
   water texture cycle + vertex wave (recipe constants ready), a
   monster (hopping poring species via a new tiny figure + bake),
   paper-doll layers (hat/held-item sheets with anchors), 8-frame
   walks. Or, if the human calls demo 3 sufficient: **the distillation
   phase begins** (§8f) — candidates logged in D3D-026 (cm.spr, the
   terrain-bake module + editor button, cm.walk pick/A*, billboards
   into cm.gb).
3. proto3d can adopt the look knobs on its next touch (unchanged).

Post-upstream-merge queue (unchanged): PAL relative-mouse API + input
record v2. Parked (unchanged): PS1-preset extras; figure EDITOR until
the human unparks.

## 2026-07-17 (round 17) — bigworld: the streaming world + the glider

The §8e directive, sketch-first (COSMIC3D.md §10: design + a headless
lavapipe measurement soak — chunk gen ~1ms/16x16, ground sample
~3.7us, slot update ~0.66us, submit ceiling ~50k tris/frame) then
**projects/bigworld** (D3D-025). The decisive move: **ground is a
pure function** (cm.terr grew T.sample_fn + world-lattice ox/oz on
emit; openworld byte-identical, suite proved it unregenerated) — the
sim holds ZERO terrain state, so chunks exist only as render-class
rc.bw.c<id> buffers paged nearest-first under a 1-chunk/frame budget,
and prop colliders derive from per-chunk pure streams on demand.
2048x2048u world (fbm + continental octave: plains, ~30u mountains,
lakes). **~2500 entities in ONE buffer**: far = closed-form
(route,phase) — zero cost, exact at any frame gap, schedule-
independent by construction; near (20u/24u hysteresis, bw.near is sim
state) promotes into the full greet/wave/queue/solid kernel; far draw
= 18-tri totem LODs. **The glider**: air jump deploys (26u/s, gentle
sink, slow steering), press drops, touchdown stows; demo(2) hop-
glides a probed heading forever (~800u/2400f soaked), demo(1) laps a
probed hexagon. Goldens: bigworld_tour.ctrace (900f) +
bigworld_glide.ctrace (1500f, ~25 chunk crossings) + two pixels, all
drift-proven; the honesty proofs — traces verify under _G.BW_RES/
BW_BUDGET overrides, and the glide pixel re-shot under BW_BUDGET=6 is
BYTE-IDENTICAL (paging is a pop-in transient only). Suite ALL GREEN;
3 shots on the feed. PAL verdict: nothing needed at this scale;
retained-GPU-geometry stays deferred (bites past ~100k tris/frame).

## Exact next step

1. Feed questions open (non-blocking): R17's (glide speed/read?
   totem->figure pop ok at 320x240 or want a mid LOD? world variety?
   entity density — 2467 of a 4000 cap?); R15/16's (walk-up greet
   beat, wanderer palette, solid-feel), R13's (star read, completion
   beat, persist collection?), R12's (exchange read, dialog tone,
   text box vs HUD line), R11's (splash listen, swim read, jump read,
   band colors + fog, eye size).
2. **bigworld grows on verdicts**; ungated candidates: entity density
   up (accept retry or higher per-chunk draw), a mid LOD (simple
   figure, no clips) to soften the totem pop, glide polish (bank into
   turns, a deploy puff sfx, camera pull-back while soaring), chunk
   content variety (band-specific props: snow rocks, lake reeds), or
   the RO demo 3 pivot if the human calls streaming sufficient.
3. proto3d can adopt the look knobs on its next touch (unchanged).

Post-upstream-merge queue (unchanged): PAL relative-mouse API + input
record v2. Parked (unchanged): PS1-preset extras; figure EDITOR until
the human unparks.

## 2026-07-17 (round 16) — solid NPCs + the streaming-world directive

Two human messages landed. **"make the npcs solid so I can't walk
through them"** (D3D-024): npc.boxes() derives D3D-011 AABBs from the
sim buffers each step (boxes ride the wanderer), player.step grew a
dyncol param, and all three collision passes run { world.colliders,
dyncol } — NPCs clamp flush like trunks, a jump clears them, heads
are perches (box-top rule). Both ways: a walker that would close
inside stop_r on the player WAITS (direction-aware) — queues, never
plows. Headless proofs: pinned at exactly hw+npc_hw, drop settles at
ground+ch, blocked wanderer parks at stop_r. knobs.npc grew
cw/ch/stop_r -> all five openworld traces re-recorded + drift-proven;
no golden route touches a box, so all five pixels passed
UNREGENERATED. Suite ALL GREEN; totem shot on the feed. (Process
lesson in D3D-024: sed the drift probe off, never git-checkout a
file carrying uncommitted work.)

Second: **the open-world demo is sufficient for now** — next up is
engine-ergonomics territory: **streaming a huge world with entities
everywhere** (efficient update-or-don't scheduling for far entities),
stress-tested via **a glider fast-travel**. Recorded as COSMIC3D.md
§8e; demo 2 pivots from content rounds to the streaming stress demo.

## Exact next step (done — see round 17 above)

1. **The streaming-world stress demo** (human direction, §8e). Sketch
   before code: chunked cm.terr paging (deterministic per-chunk gen,
   named buffers per chunk vs regenerate-on-load), entity population
   at scale (thousands; the NPC-list pattern won't iterate them all
   per frame), an update-scheduling pattern that stays sim-legal
   (distance rings? fixed round-robin budget? never hash-order), the
   glider (fast lateral speed + slow fall; stresses chunk load rate),
   and what a golden trace even pins across chunk boundaries. Expect
   PAL questions (buffer count/size ceilings, upload throughput) —
   measure first with a headless soak.
2. Feed questions open (non-blocking): R15/16's (walk-up greet beat,
   wanderer palette, solid-feel ok?), R13's (star read, completion
   beat, persist collection?), R12's (exchange read, dialog tone,
   text box vs HUD line), R11's (splash listen, swim read, jump read,
   band colors + fog, eye size).
3. proto3d can adopt the look knobs on its next touch (unchanged).

Post-upstream-merge queue (unchanged): PAL relative-mouse API + input
record v2. Parked (unchanged): PS1-preset extras; figure EDITOR until
the human unparks.

## 2026-07-17 (round 15) — the meadow wanderer: a second NPC, walking

Autonomous round (no new feed verdicts; water polish + exchange depth
stay gated). The ungated pick — after R14's "fewer boulders" verdict,
more LIFE beat more clutter: **npc.lua becomes a list of instances**
(D3D-023) and the second one walks. The lavender/moss **meadow
wanderer** laps a six-leg loop through the flower meadow on the tour's
south ring leg (probed headlessly first: h 0.50..1.32, >=1.2u clear of
every collider) — walk clip on a distance phase like the player, greet
edges (start AND end, frame+1) in the buffer so the wave blends in and
back out as pure functions; a greet HOLDS it for k.hold frames (stop,
face you, wave, line) and then it walks on — re-greet arms only past
exit_r, one hello per lap. Its bell is the greet preset a fourth up
(audio.sfx note override, no new .ins). The watcher is instance 1,
behavior unchanged. demo(6) = walk the verified east corridor, stand
in the flowers, and the wanderer walks INTO frame for the beat (it
starts far-side on purpose — the first draft greeted mid-corridor,
back to camera). Goldens: openworld_meet.ctrace (900f, drift-proven) +
.png (f690 face-to-face wave, full line); all four openworld traces
re-recorded (knobs.npc + ow.npc layout) + pixels re-shot (the wanderer
stands in the stars framing). Suite ALL GREEN; 3 shots on the feed.

## Exact next step (done — see round 16 above)

1. Feed questions open (non-blocking): R15's (does the walk-up greet
   beat land? wanderer palette read at 320x240? should walkers dodge
   the player or keep plowing their route?); R13's (star read,
   completion beat, persist collection?), R12's (exchange read, dialog
   tone, text box vs bare HUD line) and R11's (splash in-game listen,
   half-sunk swim read, jump read, band colors + fog, eye size).
2. **Demo 2 grows** (menu, minus stars + props + second NPC): water
   polish (shoreline read, swim-out splash) and exchange depth
   (multi-line dialog pages, star-count-aware lines) stay gated;
   ungated: a third NPC species-variant elsewhere (snow band?), prop
   shadows (trees/boulders cast nothing today), or route variety for
   the wanderer (pause-and-sniff-a-flower beats). Figure EDITOR stays
   parked until the human unparks.
3. proto3d can adopt the look knobs on its next touch (unchanged).

Post-upstream-merge queue (unchanged): PAL relative-mouse API + input
record v2. Parked (unchanged): PS1-preset extras.

## 2026-07-17 (round 14 playtest 2) — boulder tops are solid

Human: **"if i jump on top of a boulder sometimes I can phase into
it"** — otherwise good. Root cause: openworld's vertical pass only
knew the heightfield; the side clamps rightly ignore squeezed
overlaps (D3D-009), so a fall entering a collider through its TOP
face never clamped anywhere. Fix = the bounce box-top rule ported
into the landing plane: g raises to any collider top under the feet
(feet-at-or-above pre-move, EPS on every f32 test per D3D-010);
walking off the top exceeds k.snap and becomes an ordinary fall.
Drop test settles exactly at the box top; boulders (and stumps) are
now standable perches. All 11 traces + 12 pixels replayed
unregenerated (no golden route ever crosses a collider top
airborne). Suite ALL GREEN; perch shot on the feed.

## 2026-07-17 (round 14 playtest) — boulders cut to ten, dirt only

Human on round 14: **"lower the amount of boulders. put them on dirt
patches only and only place down like 10"** — otherwise "it looks
good". Applied: the boulder scatter accepts only the dirt/rock band
(h 4.2..6.5, the gray-brown ground — no more upper-grass rocks) and
caps at TEN (42 -> 10; same stream, draws still precede the accept
test). Flowers/pebbles untouched. Colliders 137 -> 105, still all off
the verified routes: all 7 traces replayed unregenerated; the four
openworld pngs re-shot (distant boulders sat in every hill framing).
Suite ALL GREEN; verdict shot on the feed.

## 2026-07-17 (round 14) — props: the bands become places

Autonomous round (no new feed verdicts; water polish + exchange depth
stay gated). **First props beyond trees** (D3D-022, all in world.lua):
42 boulders (rotated squat prisms, rock-band gray one shade up) on the
high bands ONLY (h >= 3.8 — every verified route leg stays <= 3.3, so
their D3D-011 bounds-box colliders can't touch a golden trace), 52
pebbles + 95 flowers as collider-free grass clutter. Flowers grow in
2-4 clumps per patch (uniform scatter read as lone lollipops at
320x240); head = tiny 2-cone diamond lathe on a 3-gon stem, 4 petal
colors. Three NEW xs32 streams — the tree stream (and its trace-locked
trunk colliders) byte-identical. ~2.5k static tris. **All 7 traces
replayed unregenerated** (no knob/doc/snd change — the round's proof of
the render-class/sim split); the four openworld pngs re-shot
deliberately. Suite ALL GREEN; 3 shots on the feed. (Note: one suite
run tripped a transient selftest fail — concurrent /tmp/cosmic_selftest
collision with another repo's suite on this machine; clean on re-run.)

## Exact next step (done — see round 15 above)

1. Feed questions open (non-blocking): R14 answered ("looks good"
   after the boulder cut — see the playtest entry above). Still open:
   R13's (star read, completion beat, persist collection?), R12's
   (exchange read, dialog tone, text box vs bare HUD line) and R11's
   (splash in-game listen, half-sunk swim read, jump read, band
   colors + fog, eye size).
2. **Demo 2 grows** (menu, minus stars + first props): water polish
   (shoreline read, swim-out splash), more exchange depth (the NPC
   walking its own little route, multi-line dialog pages,
   star-count-aware lines), a second NPC elsewhere, or MORE props
   (band-specific species: snow rocks, sand shells, prop shadows).
   Figure EDITOR stays parked until the human unparks.
3. proto3d can adopt the look knobs on its next touch (unchanged).

Post-upstream-merge queue (unchanged): PAL relative-mouse API + input
record v2. Parked (unchanged): PS1-preset extras.

## 2026-07-17 (round 13) — stars: the wander gets a goal

Autonomous round (no new feed verdicts; water polish + exchange depth
stay gated). **projects/openworld/stars.lua** (D3D-021): ten gold
stars — the mascot's antenna species mark as a spinning, bobbing
G.ball — on verified spots (seven ring waypoints, both swim banks, one
FLOATING mid-pond as the swim reward, one beside the pond watcher).
Bounce's pickups pattern: ow.stars timer buffer, stays-collected, pop
ghosts, coin sfx (bounce preset, new slot), all ten = bell-triad
fanfare + fading ALL THE STARS banner; stars n/10 HUD counter. Rest
height DERIVED per use (module tables reassign on hot reload — never
bake). demo(5) = the star sweep over verified legs, ending on the
watcher's star so fanfare + greet + dialog land in one beat. Goldens:
openworld_stars.ctrace (1900f, drift-proven) + .png (f1740 banner);
all three openworld traces re-recorded (knobs.stars + snd.bank) and
re-shot (stars in every framing). Suite ALL GREEN; 3 shots on the
feed.

## Exact next step (done — see round 14 above)

1. Feed questions open (non-blocking): do the stars read at 320x240
   (size/color vs the grass)? does the completion beat land (fanfare
   + banner over the greet)? should collection persist across
   sessions (it resets with the doc today)? Plus round 12's (exchange
   read, dialog tone, text box vs bare HUD line) and round 11's
   (splash in-game listen, half-sunk swim read, jump read, band
   colors + fog, eye size).
2. **Demo 2 grows** (menu, minus stars): water polish (shoreline
   read, swim-out splash), more exchange depth (the NPC walking its
   own little route, multi-line dialog pages, star-count-aware
   lines), a second NPC elsewhere, or first props beyond trees
   (rocks/flowers on the bands). Figure EDITOR stays parked until the
   human unparks.
3. proto3d can adopt the look knobs on its next touch (unchanged).

Post-upstream-merge queue (unchanged): PAL relative-mouse API + input
record v2. Parked (unchanged): PS1-preset extras.

## 2026-07-17 (round 12) — the pond watcher: first NPC + the exchange

Demo 2's Zelda-ish beat (D3D-020). **cm.mascot.build(overrides)** casts
color variants of the locked-in mascot (figure goldens verified
byte-pure through the refactor) and **cm.mascot.wave** is the greeting
clip (mitt sweeping ABOVE the head silhouette — the first draft read as
an ear). **The pond watcher** (openworld/npc.lua): a coral/teal variant
on the pond's east bank; inside greet_r it eases its facing to you,
waves, rings bounce's fm-bell (new snd slot), and a dialog line types
out on the HUD (3 lines rotating per greet); past exit_r (hysteresis)
it settles back toward the pond. Sim state = ONE buffer (ow.npc: yaw,
greet-start frame+1, greet count); wave/dialog are pure functions of
(buffer, frame). demo(4) = walk from the spawn bowl and STAND for the
exchange (route holds at its last waypoint, hop suppressed while held).
Goldens: openworld_npc.ctrace (480f) + .png (f311, out-sweep + full
line); tour/swim re-recorded (knobs.npc + snd.bank) and re-shot (new
world content + the HUD tris counter). Suite ALL GREEN; 3 shots on the
feed (exchange wide, wave close, the greet framing).

## Exact next step (done — see round 13 above)

1. Feed questions open (non-blocking): does the exchange beat land
   (turn + wave + chime + typewriter)? dialog tone ok? does the NPC
   want a real text box/name tag instead of the bare HUD line? Plus
   round 11's: splash in-game listen, half-sunk swim read, jump read,
   band colors + fog at 320x240, eye size at 320x240.
2. **Demo 2 grows** (unchanged menu, minus the NPC): scatter
   props/collectibles to give the wander a goal, water polish
   (shoreline read, swim-out splash), more exchange depth (the NPC
   walking its own little route, multi-line dialog pages), or a second
   NPC elsewhere. Figure EDITOR stays parked until the human unparks.
3. proto3d can adopt the look knobs on its next touch (unchanged).

Post-upstream-merge queue (unchanged): PAL relative-mouse API + input
record v2. Parked (unchanged): PS1-preset extras.

## 2026-07-17 (round 11 playtest, second pass) — breaststroke

Human on the crawl draft: **"the arms move together front to back and
the legs open to closed"** looks better. cm.mascot.swim reworked as a
breaststroke: mitts reach forward together / sweep back low / recover
under, boots OPEN on the pull and snap CLOSED on the frog kick, surge
on the glide stretch, roll gone (symmetric). Draw-only data change —
all traces verified untouched, only openworld_swim.png re-shot. Suite
ALL GREEN; coiled-key shot on the feed.

## 2026-07-17 (round 11 playtest) — the stroke clip + the splash sizzle

Human on round 11: **"the physics of being in the water feel
reasonable"**, worth a swim animation; the splash "feels like a low
pitch laser", wants sizzle. Both in: **cm.mascot.swim** — alternate
mitt strokes (reach near the surface / pull back low) over a boot
flutter, rolling (rz) into each stroke, glide stretch between, antenna
trailing; the player swaps walk->swim on the same distance phase while
the regime holds (still zero animation state; base rx stays clear for
the paddle tilt). **sfx-splash rebuilt**: the laser was a NOTE-CLOCKED
short LFSR at note 48 under a lowpass with a -9st sweep; now two
FIXED-CLOCK noise carriers — 12kHz long-LFSR hiss + 2.8kHz plosh —
through the hp sizzle filter, no sweep. A/B'd headlessly via
pal.x_snd_tap (zcr 0.001 -> 0.157/sample, ~7.5kHz effective). Lesson
banked in the goldens commit: **snd.bank is a named sim buffer — an
.ins edit re-records every trace of that cartridge** (the suite caught
it at frame 1). Both openworld traces re-recorded + drift-proven,
swim png re-shot (stroke pose), tour png byte-identical. Suite ALL
GREEN; stroke shot on the feed (splash needs an in-game listen).

## 2026-07-17 (round 11) — deep water swims + the guy pinned opposite

Two human verdicts landed and both are in. **The box guy stays** in the
figure showcase, now pinned exactly opposite the ring mascot: one
shared anim.ring_rate replaces the drifting per-walker rates, the guy's
angle is mascot + pi by construction — overlap is impossible.
figure_show goldens re-recorded/re-shot (knob schema + guy position).
**Deep water swims** (D3D-019): the fbm floored at -1.0 so no real deep
water existed — the noise's deepest basin (42,64) is carved into a
2.8u pond (quartic scoop, untouched outside R=9; the tour trajectory
diffed byte-identical). The swim regime is DERIVED, never stored (no
new player-buffer field): deep water under the feet + feet below the
surface → buoyancy spring to the float line with water drag (a small
surface bob), swim-tuned move numbers, buffered jump = paddle hop,
entry splash on the derived edge (new sfx-splash.ins), forward paddle
tilt + neutral scale on the mascot, shore exit = the ordinary landing
snap. Shallower water stays wading (the round-10 question answered as
allow-with-a-floor). demo(3) = the pond-crossing ring. Goldens:
openworld_swim.ctrace (900f, drift-proven) + openworld_swim.png (f300
mid-pond); openworld_tour re-recorded (doc grew the swim knobs) +
re-shot (the pond entered the f1290 framing). Suite ALL GREEN; 3 shots
on the feed (swim Q: does the half-sunk float read?).

## Exact next step (done — see round 12 above)

1. Feed questions open (non-blocking): the splash sizzle needs an
   in-game listen, the half-sunk swim read, jump read, band colors +
   fog at 320x240, eye size at 320x240.
2. **Demo 2 grows** (unchanged menu): a first NPC (cm.fig guy or a
   second mascot) with a proximity exchange (the Zelda-ish beat), more
   mascot clips (turn/hop/wave for the exchange), water polish
   (shoreline read, swim-out splash), or scatter props/collectibles to
   give the wander a goal. Figure EDITOR stays parked until the human
   unparks it.
3. proto3d can adopt the look knobs on its next touch (unchanged).

Post-upstream-merge queue (unchanged): PAL relative-mouse API + input
record v2. Parked (unchanged): PS1-preset extras.

## 2026-07-17 (round 10 playtest) — verdicts + the backwards-camera fix

Human played openworld: **"the mascot reads well and the openworld demo
feels smooth"** — round 10's two big questions (mascot jump/walk read,
terrain feel) land positive. One bug: **"the camera is vibrating when i
walk backwards"** — the yaw-follow pole (D3D-018). Reproduced with the
new openworld demo(2) backup soak (cam yaw alternated 3.18/3.20 every
frame), fixed in BOTH rig copies (bounce too — same latent bug, present
in the godot original as well): yaw-follow now holds inside
kc.back_cone (0.35 rad) of straight-into-the-camera; sideways circling
untouched. bounce_tour.png re-shot (deliberate — the tour's reversal
leg enters the cone, framing rotated; sim path byte-identical, still
pins the ferry). Suite ALL GREEN. Still open on the feed: band
colors/fog at 320x240, deep-water wading, eye size, keep the guy.

## 2026-07-17 (round 10) — openworld: cm.terr + the mascot goes playable

On the lock-in verdict, demo 2 proper began. **cm.terr** (D3D-017) is
the heightfield ground: per-vertex height grid, banded jittered vertex
colors + detail mottle + unlit water plane (proto scene_openworld
verbatim-ish; the proto sky constants turned out ABGR — the openworld
sky is BLUE), T.sample triangle-exact against T.emit's diagonal so the
sim walks the rendered mesh, T.vnoise integer-hash noise (no libm).
**cm.mascot**: the mascot def + clips promoted engine-side on their
second user (figure re-exports; its goldens verified byte-identical).
**projects/openworld**: the mascot runs/jumps over the heightfield with
bounce's feel-approved kernel (terrain landings, k.snap downhill glue,
tree-trunk AABBs under the D3D-009/010 clamp rules), walk clip on a
DISTANCE phase (sim f32, no foot slide), idle->walk blended by ground
speed with live squash/stretch multiplied into the clip's body scale,
slope-tilted blob shadow, the bounce follow camera. demo(1) walks a
verified grass-band waypoint ring around the spawn bowl. Goldens:
openworld_tour.ctrace (1000f, verify PASS, drift-proven) +
openworld_tour.png (f1290, the pond crossing). Full suite ALL GREEN
from the committed tree; 3 shots on llm-feed.

## Exact next step (done — see round 11 above)

1. Feed questions open (non-blocking): jump read on the mascot, band
   colors + fog at 320x240, block-or-allow deep-water wading; plus
   round 9's leftovers (eye size, keep the guy in the showcase).
2. **Demo 2 grows**: pick from — a first NPC (cm.fig guy or a second
   mascot) with a proximity exchange (the Zelda-ish beat), more mascot
   clips (turn/hop/wave for the exchange), water polish (swim-or-block
   + shoreline read), or scatter props/collectibles to give the wander
   a goal. Figure EDITOR stays parked until the human unparks it.
3. proto3d can adopt the look knobs on its next touch (unchanged).

Post-upstream-merge queue (unchanged): PAL relative-mouse API + input
record v2. Parked (unchanged): PS1-preset extras.

## 2026-07-17 (round 9) — cm.fig: the figure runtime + the mascot live

The human-chosen direction (see verdicts below): demo 2's character
work. **cm.fig** (D3D-016) is the D3D-005 model as an engine module:
figures are DATA (joint-tree parts, each a list of cm.gb shapes), poses
are sparse per-part channel arrays (euler Ry Rx Rz + translation for
floating parts + scale for squash), clips are key-pose lists lerped by
fig.cycle — emission is a pure function of (figure, root, pose), zero
animation state (the movers precedent). Two transform chains keep
lighting honest: positions inherit scale down the tree, normals ride a
rigid twin into gb's new nrmxf. **cm.gb promoted out of bounce**
(second user, the cm.m4 precedent) and grew G.ball (proto's 6-point
chunky ball). **projects/figure** is demo 2's seed: the approved mascot
(teardrop lathe, style-B eyes, floating mitts/boots, antenna star —
eyeballed faithful vs proto/out/mascot.png) idles on a stage while a
second mascot waddles the ring against the box guy walking proto's
verbatim 4-key clip; N64 presentation on; slow orbit camera; no input
anywhere. Goldens: figure_show.ctrace (300f, verify PASS) +
figure_show.png (f430). Full suite ALL GREEN from the committed tree;
3 shots on llm-feed (mascot close-up, the ring golden, guy mid-stride).

## Verdict landed (2026-07-17, human): the mascot is locked in

**"it looks good. the stylized design helps the bounce and animations
feel more natural"** — the stylized mascot design is the ENGINE MASCOT
now (recorded in COSMIC3D.md §8d). Animation read approved. Still open,
non-blocking: eye size at 320x240, keep the box guy in the showcase.

## Exact next step (done — see round 10 above)

1. **Demo 2 continues** (human direction 2026-07-17): grow the figure
   vocabulary toward the Zelda-ish open world — more mascot clips
   (turn, hop, wave), a first NPC exchange, or Body-Harvest-style
   vertex-color terrain (D3D-004) as the openworld ground. Figure
   EDITOR (vertex pushing) stays parked with the rest of editor
   distillation until the human unparks it.
2. proto3d can adopt the look knobs on its next touch.

Post-upstream-merge queue (unchanged): PAL relative-mouse API + input
record v2. Parked (unchanged): PS1-preset extras.

## 2026-07-17 (round 8) — the N64 presentation lands (D3D-015)

Autonomous round (playtest verdicts still pending; course polish stays
gated on them, so the round took the one human-approved verdict-free
item): the **VI-soft presentation + 5551 grade** — the D3D-003 adopted
default look, parked since the fork, now in the PAL (pal 0/api16).
`pal.x_grade{quant=n}` = Bayer-4 dithered n-bit quantize appended to
the grade post-pass (internal res, bakes into the target — goldens see
it, like the real console framebuffer); `pal.x_soft(on)` = the
game-layer present blit resamples bilinearly + smears [1,2,1]/4 one
dest px horizontally (blit_soft.frag + a linear sampler; composite
only — internal target/goldens untouched, ui/ig stay sharp). Both are
per-frame render-class opt-ins reset at begin_frame; proto r3d.c
fb_write_png --soft is the reference math. Sharp defaults byte-stable:
inherited suite passed unregenerated before bounce opted in.

bounce adopts both via **doc.knobs.look = {quant=5, soft=1}** (live
knobs, armed in draw). The three bounce pixel goldens re-shot on pinned
lavapipe (deliberate look change — the internal frame now carries the
dither; trace goldens replay untouched). New: **bounce_soft.png, the
suite's first composite golden** (--win 960x720, f150) pinning the soft
blit end to end; byte-stable across runs. Verified: full suite ALL
GREEN from the committed tree; 3 shots on llm-feed (soft composite,
dither before/after zoom, re-shot ferry golden) with a softness-level
question.

## Verdicts landed (2026-07-17, human)

All open feel questions resolved positive in one pass: rounds 4–7
gameplay **"the feel is good. moving platform and all"** and the round-8
presentation **"the soft filter looks correct"**. No change requests.
Demo 1's two stated goals (movement feel + level aesthetic) are both
human-approved. Direction chosen by the human for the next round (asked
directly, 2026-07-17): **figures + mascot — start demo 2's character
work** (over deepening demo 1 or unparking the editor).

## Exact next step (done — see round 9 above)

1. **The rigid-part figure runtime** (D3D-005): joint tree + rigid part
   meshes + per-joint euler keyframes (lerp/stepped), root-only
   translation, evaluated per frame into x_tris buffers via m4 rigid
   transforms. New files (merge-clean); the SM64 technique.
2. **The mascot as its first character** (approved direction: lathe
   teardrop body, Rayman floating mitts/boots, antenna star, eye style
   B): port proto draw_mascot geometry, idle + walk cycles, a showcase
   cartridge with orbit camera → goldens + feed shots.
3. proto3d can adopt the look knobs on its next touch (no golden
   depends on it).

Post-upstream-merge queue (unchanged): PAL relative-mouse API + input
record v2 for captured-cursor mouse look. Parked (unchanged): the
PS1-preset extras (affine wobble + vertex snap).

## 2026-07-17 (round 7) — moving platforms + the reload-pattern bug (superseded — see above)

Autonomous round (playtest verdicts still pending): first the flagged
proto3d latent issue (texids/sky → rc., money shot re-verified), then
**movers** — the course's first kinematic colliders (D3D-013).
movers.lua platforms shuttle between endpoints as PURE FUNCTIONS of the
sim frame (no state buffer; step collides frame+1 = what draw emits);
riders are carried by the frame delta (glued both directions), movers
land/clamp/mantle like level boxes. Course: the **tower lift** (docks
at mantle height, rises flush with the round-tower top — the alternate
lap: lift → dome shoulder → SW-rim leap → goal star) and the **wall
ferry** (keep roof NW ↔ curtain wall east, flush docks). Two new gems
reward the rides. demo(4) = the mover tour driving all of it (waypoint
routes grew wait predicates + doc.demo_hold so a mover can carry the
standing demo); it laps ~f840, ferries ~f1800, walks the wall, wraps.

En route, **a real engine-discipline bug (D3D-014)**: bounce modules
opened with `local L = {}` instead of the boot.lua reload pattern
`select(2, ...) or {}` — on any bundle restore (trace verify after
source drift!) re-run closures write a fresh table nobody else holds;
verify crashed on a comment-only change. All bounce + proto3d modules
now comply; both old traces re-recorded with compliant bundles and
PROVEN to survive deliberate drift. Reminder that bit: pixel goldens
shoot on pinned lavapipe (VK_DRIVER_FILES=$COSMIC_LVP_ICD), never the
WSL default driver.

New goldens: bounce_tour.ctrace (1000f — lift wait, vertical carry,
shaft gem, dome hops, star lap) + bounce_tour.png (f1920 ferry
mid-crossing, pinning horizontal carry). bounce_demo/lap pixels re-shot
look-equivalent (+88 tris; routes and HUD byte-identical at the golden
frames). Verified: full suite ALL GREEN; 4 shots on llm-feed.

## Exact next step (rolled into round 8's list above)

## 2026-07-16 (round 6) — playtest fixes + the lap demo (superseded — see above)

Human playtest verdicts landed: gem timed-respawn read as a bug and the
round-tower dome could be jumped INTO from the goal tower. Fixed both:
**gems stay collected until a goal-star lap** (encoding: 0 present,
k.pop..1 pop-ghost countdown, -1 collected; only the star returns on
goal.respawn so laps repeat; ghost timing frame-identical, pixel golden
untouched) and **lathes grew a col flag** — stacked AABB per profile
ring (half = upper ring radius * chord apothem, boxes inside the round
visual per D3D-011, degenerate tip skipped). Drop tests: dome cap 6.94,
shoulder 6.30; the goal-tower leap lands ON the dome. Then STATUS item
2: **demo(3), the lap route** — waypoint steering (world-space wish, no
camera; index = doc.demo_wp sim state) runs stairs > keep roof > three
platforms > goal star > walk-off home, forever (laps f=326/f=950). New
goldens: bounce_lap.ctrace (1000f, two star touches + lap gem respawn)
+ bounce_lap.png (f346: CLEAR banner, HUD, cube atop the goal tower).
bounce_demo.ctrace re-recorded (it covered the old timed respawn —
deliberate change). Verified: full suite ALL GREEN from the committed
tree; 3 shots on llm-feed (dome cap/shoulder stands, lap banner).

## Exact next step (rolled into round 7's list above)

## 2026-07-16 (round 5) — the goal loop + first bounce goldens

Demo 1 is a GAME now (D3D-012): **pickups.lua** — gold diamond gems
(2-cone lathe) hover along the course, pickup = coin sfx + score + an
expanding pop ghost, timed respawn keeps autoplay worlds alive; the
ice-white **goal star** atop the accent tower = bell fanfare + lap +
fading COURSE CLEAR banner + all gems respawn (fresh lap). Knobs under
doc.knobs.goal; audio.lua = the demo cartridge's SFX pattern + its .ins
presets (jump/land/kill-respawn hooks in player.lua too). Engine
(surgical): the **"rc." render-class buffer domain** — PAL resource ids
+ per-draw scratch named "rc.*" are excluded from snapshots/traces/
goldens like "ed." (texids are session-dependent; --verify never
draws). bounce renamed texids/dyn/sky into it; proto3d.texids has the
latent issue, rename on next touch. **First bounce goldens are in the
suite and green**: a 900-frame demo(1) trace (pickups, mantle stairs,
kill-plane reset, live snd bank — replay PASS) and the suite's first 3D
pixel golden (frame 150, pinned lavapipe). Verified: full suite ALL
GREEN via nix run .#test; 3 shots on llm-feed with feel questions.

## Exact next step (done — see the entry above)

## 2026-07-16 (round 4) — the primitive vocabulary: prisms + lathes

gb.lua now speaks the round half of the proto vocabulary: **G.prism**
(extruded n-gon, cap fans) and **G.lathe** (revolved {r,y} profile,
smooth ring normals) — ports of proto draw_prism/draw_lathe — plus G.tri
and rigid-xf support; all emitters return tri counts (no more
hand-counted segments). level.lua grew PRISMS (12-gon round tower, hex
keep + wood cone roof, octagon pillar), LATHES (the proto dome on the
tower), DECO (y-rotated accent monoliths by the goal tower). Collider
rule (D3D-011): **colliders stay AABB, only visuals rotate** — prisms
take the apothem box (facets flush, corners overhang), rotated deco its
world-bounds box. Also: kill-plane respawn (move.kill_y knob) — the
autoplay trace fell off the world forever; now demo(1) loops the course
indefinitely (future golden material). Verified: facet/monolith walk
soaks clamp at predicted planes, 2D goldens ALL GREEN, 2 shots on
llm-feed (hex keep + cone roof; tower + dome + monoliths).

## Exact next step (done — see the entry above)

## 2026-07-16 (later still) — demo 1's movement slice is playable

**projects/bounce**: the bouncy cube runs/jumps around an axis-aligned
graybox playground, all from Lua — no baked dump. gb.lua ports the proto
material checkers + pre-lit gbox emitters; level.lua's ONE box list is
both visuals and colliders; player.lua = camera-relative run + D029
fixed-apex jump (coyote/buffer/fall_mul) + landing squash / air stretch /
lean straight from draw_bouncy_cube + blob-shadow landing cue; pull-string
follow camera as sim state (input is camera-relative — smoke.cam
precedent). Every feel value lives under doc.knobs (move/cam/feel).
game.demo(1) = autoplay loop (stairs → keep → arc left) for screenshots
and a future golden. ADR: D3D-008. Also: cm.m4 (m4 promoted to the engine
+ transform helpers, proto3d byte-identical), PAL_DBG_3D seg dump.
Verified: 2D goldens green; 4 autoplay shots pushed to llm-feed (stair
run, air stretch + shadow, squash, face portrait). NOT yet human
feel-checked — asked via the feed note.

## 2026-07-16 (playtest round) — teleports fixed, the godot camera ported

Human played bounce: "feels pretty good", but walking at the stairs /
jumping could TELEPORT. Root cause: the collision clamp face came from
the velocity sign, which zeroes on the first hit — a second overlapping
box (the 0.7u stair/keep pocket vs the 0.9u player) clamped to its far
face. Fixed: **clamp face from the pre-move side; squeezed overlaps clamp
nothing; land/bonk only from feet-above/head-below** + level rule: no
pockets narrower than the player (stairs now flush with the keep).
ADR: D3D-009. Verified: wall-charge + wall-jump clamp flush, goldens
green, shots on llm-feed.

Camera (human request): ported their godot cosmic project's FollowCamera
(F:\Documents\cosmic = /mnt/f/Documents/cosmic, src/camera/ — the feel
reference for all camera work): orbit yaw/pitch/dist + smoothed focus,
yaw-follow circling behind the heading, **mouse-drag look + wheel zoom +
c recenter**, manual steering pauses yaw-follow. Knobs mirror
CameraTuning under doc.knobs.cam. Captured-cursor mouse look (their
EnableMouseLook) is DEFERRED: needs a PAL relative-mouse API + input
record v2 — record v1 is frozen and engine-shared (merge-sensitive).

## 2026-07-16 (playtest round 2) — phase-through fixed, mantle, wasd

Human: "feels better", but diagonal stair walks PHASED THROUGH and one
pillar was solid on one axis. Root cause (frame-exact _G.DBG trace): a
side clamp stores face-hw in the f32 buffer; (face-hw)+hw can round past
the face, the exact side test reads flush as "squeezed", and the player
slides in. **All side tests now carry EPS=1e-3** (rule in D3D-010: any
geometry test against f32-stored sim state needs an epsilon). Plus two
human requests: **mantle** (steps ≤ move.step_h lift you instead of
blocking — demo(2) walks the whole stair run jumpless; grounded-only,
headroom-checked) and **wasd move / arrows camera** (yaw + pitch, pausing
yaw-follow; drag/wheel/c unchanged). Soak harness kept in-cartridge:
game.demo(2) walk + _G.DBG=n telemetry. Captured-cursor mouse look
re-confirmed as post-merge work (PAL relative-mouse API + record v2).

## Exact next step (done — see the entry above)

Playtest round 3 verdict: **"that feels good"** (after flipping arrow-cam
yaw to the stick convention — godot HandleManualRotation signs; pitch and
drag already matched). The movement slice is feel-approved.

Next: **grow the primitive vocabulary**: prism/lathe emitters in gb.lua
(ports of proto draw_prism/draw_lathe) so the playground escapes
axis-aligned boxes — colliders stay AABB, deco rotates. After that: the
level stops being a hand-typed table — first editor-primitive
distillation step (still parked until gameplay is polished, human
directive 2026-07-16). Post-upstream-merge queue: PAL relative-mouse API
+ input record v2 for captured-cursor mouse look.

Parked (unchanged): VI-soft bilinear presentation + 5551/dither grade pass
(the adopted default presentation — not yet in the PAL blit).

## 2026-07-16 (later) — the PAL 3D pipeline is live

**pal 0/api15**: `pal.x_view3d{mvp, fog_start, fog_end, fog, fog_on}` +
`pal.x_tris(tex, buf, count, off, flags)` (flags: 1 alphatest, 2 nearest,
4 blend/no-depth-write) — retro.vert/frag in pal/shaders/, D16 depth
target, opaque+blend pipelines, same batch/segment model as quads. 3D is
a pre-pass owning the clear; 2D LOADs over it (HUD on top). All lazily
created; the frame path without 3D is byte-identical — **inherited 2D
goldens green, unregenerated**. Views append (≤64/frame): sky NDC pass =
no-arg x_view3d. ADR: D3D-007. `frame_stats` grew tris/segs3d.

**projects/proto3d**: the graybox scene (proto dump, now a committed
scene asset) at 60fps from Lua — parse .c3dd, named buffers p3d.*, Lua
camera math (m4.lua), orbit/zoom controls, HUD text over 3D. Frame 0 =
the money-shot framing; ~0.8ms/frame headless lavapipe. Verified by eye
against proto/out/graybox.png + pushed to llm-feed (2 shots). Also fixed:
proto --dump kept dangling pointers to stack-local textures (segfault on
graybox/mascot dumps) — registry copies the struct now.

## Exact next step (done — see the entry above)

**Demo 1's movement slice** (the roadmap's gameplay-first directive):
bouncy-cube run/jump/squash-stretch in proto3d or a new cartridge —
colliders + walk surface from simple box/prism data (start axis-aligned),
camera follow, feel knobs in the doc tree like smoke's KNOBS. Squash/
stretch = nonuniform scale on the cube verts before submit (CPU-side,
like the prototype's draw_bouncy_cube). Then grow the Lua-side primitive
vocabulary (gbox/prism/lathe emitters into vertex buffers) so the scene
stops being a baked dump and becomes editable gameplay space.

Parked (unchanged): editor-primitive distillation until gameplay is
polished; VI-soft bilinear presentation + 5551/dither grade pass (the
adopted default presentation — not yet in the PAL blit).

## 2026-07-16 — the fork exists; planning + prototype imported

**Where we are.** Forked from cosmic2d @ f791824 (git remote `upstream`,
push-disabled). The 2D engine is untouched and must stay green. A full
scoping phase (done in /opt/src/cosmic3d-planning, imported here) settled
the design — read **docs/COSMIC3D.md**; the short form:

- **Renderer**: one fixed GPU retro pipeline in the PAL (SDL_GPU, additive
  next to the quad pipeline): depth-tested triangles, pre-lit vertex colors,
  3-point/nearest filtering in the frag shader, fog, alpha-test, blend
  decals; low-res internal target; **VI-soft bilinear upscale is the adopted
  default presentation** (sharp selectable); dither/5551 in the grade pass.
  proto/gpu_proto.c + proto/retro.{vert,frag} are the working draft; the
  software rasterizer (proto/r3d.c) defines intended pixels.
- **Demo roadmap** (human-set): 1) N64 platformer with the bouncy-cube
  character — movement feel first (look: proto/out/graybox*.png);
  2) Zelda-ish open world — figures/animation showcase
  (proto/out/openworld.png); 3) RO-style — blended terrain + chibi
  billboards (proto/out/ro2.png, the most human-iterated look; authentic
  client constants in docs/research-3d/ro-render-recipe.md).
- **Characters**: rigid-part figures, no skinning ever; vertex pushing in the
  figure editor from day one; mascot direction approved (lathe teardrop body,
  floating mitts/boots, antenna star, eye style B = bigger round pupils).
- **Terrain**: per-corner-height tiles + splat-painted material weights +
  bake step (unique per-tile blended textures, 1-texel gutters, baked prop
  shadows, corner-smoothed normals); water as a level plane (opacity
  144/255, drawn after sprites); walk grid at 2× (GAT-style). Rule from the
  v6 iteration: **ground materials blend; architecture is crisp-edged props**.
- **Assets**: license-verified packs staged in assets/ (gitignored, see
  assets/README.md); Kushnariova chibi pack (CC-BY) proven in the RO scenes.

**Suite state**: inherited cosmic2d suite untouched since fork (expected
green; run `nix run .#test` before the first engine change to baseline).

## Exact next step (done — see the entry above)

**The PAL 3D pipeline** (mirror proto/gpu_proto.c into pal/src/gfx.c the
cosmic2d way): `pal.x_view3d{...}` (mvp + fog uniforms), `pal.x_tris(tex,
buf, count)` bulk path over named buffers, per-segment state
(filter/alphatest/blend), a depth target on the internal target,
retro.vert/frag compiled into pal/shaders/. Then a minimal `projects/proto3d`
cartridge drawing the graybox scene from Lua at 60fps, headless-screenshot
verified against the prototype look. After that: **demo 1's movement slice**
(bouncy cube: run/jump/squash-stretch on colliders + walk grid) — gameplay
feel before any editor work.

Parked until gameplay is polished (human directive 2026-07-16): distilling
each demo into editor primitives — terrain window (splat brushes + bake),
figure window (vertex pushing + pose keys + face strips), billboard /
paper-doll sprite system.

## Session hygiene contract (same as cosmic2d)

STATUS current at session end; commits in logical units with model-slug
trailers; knowledge in-repo, never in agent memory; llm-feed for anything
visual (human is the taste check); goldens never regenerated to paper over
a break; 2D suite stays green through 3D work.
