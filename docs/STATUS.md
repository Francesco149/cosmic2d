# status — living handoff

> Updated at session and milestone boundaries. Detailed July 2026 session
> history is archived verbatim in `history/STATUS-2026-07.md`.

## Current handoff — A4/A5/A6 closed; A7 (rewind/replay product UI) is the open gate; the timeline information layer (activity digest D100 + presented-frame previews D101) is in (2026-07-17)

The active release program is `ALPHA.md`; the original M-series in
`PLAN.md` and the R-series in `REVAMP.md` are historical context. The
runtime, infinite-canvas editor, deterministic rewind core, audio stack,
two-room platformer demo, and clean Windows/Linux distributions are working.
**A0–A4 are complete.** A3's full promise holds:
from a fresh archive a user can create (from four starter templates),
import, rename, relocate, duplicate, archive, delete, edit, play, and
export projects entirely through the shipped UI. Real SDL controllers
drive games deterministically (D082 record + D083 discovery), every
action is player-rebindable across keyboard and pads (D084) — the human
has since confirmed a physical Switch Pro controller through native
win32 SDL drives games and rebinding correctly — the Esc menu is the
full player options surface (D085), games have real player saves
(D086), and the all-inputs determinism proof plus the walked exit
checklist closed the gate (D087). **A5 and A6 are also complete**
(D088–D099): the shared runtime slices shipped against real demo pain,
and the three-family demo matrix — demo (side-view), cellar (top-down),
swarm (arcade) — ships in the public archives with READMEs, thumbnails,
and export proofs. The complete rewind product UI (A7) and the
release-candidate pass (A8) are the open alpha gates.

**D101 fills the rewind tray's PREVIEWS lane: presented-frame
previews (`THMB`).** The film lane read "NO PRESENTED-FRAME PREVIEWS
IN THIS HISTORY"; now it draws small game-FOV thumbnails across the
whole tray, one per segment, seek target in hand. Every primitive
already existed, so this is a Lua-only observer packet (no PAL API
bump): about once per `M.thumb_period` recorded frames (default one
per minute at 60 Hz), `thumb_pump` — called from `M.tick` **after
present**, so the game FOV holds the finished frame — point-samples
`pal.read_pixels` down to a height-46 thumbnail (`thumb_dims`
normalizes height, caps width at 128) and stores it two ways,
mirroring the D100 digest's discipline: `seg.thumb = {frame,w,h,png}`
on the open segment (the in-RAM index the tray draws from — it
survives `demote`, dies with the segment on eviction, and a rewind
truncation clears it past the cut; one slot per segment, which any
sane cadence ≫ the 60-frame segment fills with exactly one preview),
and a durable `THMB` chunk that rides the segment blob for a future
cross-session scan. Like `FSAV`/`MARK`, `THMB` is stripped from
exported `.ctrace` clips and ignored by reconstruction and `verify`,
so **no recorded byte moved**. `ring_thumbs(from,to,max)` returns
in-range previews decimated evenly by frame (RAM-index only, never
decodes a blob, so adopted cross-session history shows none while its
D100 activity digest still draws); the tray's `draw_previews` decodes
one GPU texture per *visible* frame into a small per-frame cache,
skips overlaps, and frees textures that leave the set (and all on
close) so the texture pool can't exhaust. Previews ride their own
`M.ring.thumbs` flag (set to `not args.headless` beside `spill`), not
`spill` itself — so a capture/soak harness can enable previews
without disk writes, and every headless path (goldens, traces,
`--verify`, `--frames`) reads no pixel by construction. Linux
selftest **24,008** / native Windows **24,010** on PAL API 19 (11 new
KATs in `t_timeline_thumbs`); `nix run .#test` ALL GREEN with every
historical trace and pixel/audio golden byte-identical. Inspected
capture on llm-feed: the tray over a ~320-frame `smoke --edit`
session with the PREVIEWS lane populated by one game-FOV thumbnail
per segment. Adopted cross-session previews and multi-resolution
sub-segment previews stay the packaging packet's job (the durable
`THMB` chunk is the forward hook), logged.

**D100 lands the first A7 information-layer packet: the persisted
timeline summary index.** The rewind tray's activity/event lanes read
only resident chunk streams, so demoted/spilled/adopted history drew
blank ("OLDER LEGACY ACTIVITY HAS NO SUMMARY INDEX"), the files lane
was dead, and only input/code/eval/session events existed. Now every
closed segment carries a coarse observer-only digest —
`{ sim, editor, files, events }`: the max single-frame changed bytes
for named sim buffers+doc / editor doc / project files (asset saves +
code epochs) and the OR of its event bits. `summarize_segment` folds
the chunk stream at spill (and after a rewind truncation); it persists
twice inside the existing atomic segment+manifest pair — a `SUMM`
chunk in the segment blob and four extra manifest fields — so
cross-session **adoption reads digests from the manifest alone, never
touching a spilled blob**. Manifest parsing became per-line and
tolerates legacy 4-field lines (they read back as an honest missing
gap, now the ONLY thing `missing` means). `ring_timeline` composes:
resident segments render exactly from chunks (per-frame maxes, precise
event frames), chunk-less segments coarsely from the digest (max
envelope across the segment's width, event bits at its leading bin);
seeking an old segment materializes its chunks and silently upgrades
it to exact. Two tiny observer chunks carry the events the stream did
not already hold: `FSAV` (an editor asset save — path + published byte
size; `cm.ed.kit`'s save door emits it) lights the files lane + a
**save** marker, and `MARK` carries a lifecycle bit — `enter_error`
marks **error** before the crash flush, `reset_game` marks **restart**.
Both are ignored by state reconstruction and `verify`, and are stripped
from exported `.ctrace` clips. The tray gained the three markers (red
error, amber restart, teal save) with a hover tooltip naming a bin's
events, and the files lane now draws. Everything is observer-only, so
**no sim/doc byte moved**: Linux selftest **23,997** on PAL API 19 (6
new KATs in `t_timeline_summary`), `nix run .#test` ALL GREEN with
every historical trace and pixel/audio golden byte-identical.
`FSAV` stores only the byte length for now (the content-addressed blob
store is the §14 packaging packet) and the digest is single-resolution
per segment (multi-resolution buckets deferred, logged). Inspected
capture on llm-feed: the tray over a 210-frame session with the
populated files lane and save/error/restart markers.

**D099 closes A6 with the bundling packet — no sim-visible byte
moved.** Every bundled demo carries the A6 welcome note (controls,
concepts, file tour, modification prompts, starter-template
provenance: demo↔platformer, cellar↔top-down, swarm↔arcade). cellar
and swarm carry full picker/player metadata — author/version/
description, gameplay-cut 128px icons, CONTROLS/CREDITS/LICENSE —
validated through the real player-bundle door; project.lua is not in
the code bundle, so all three committed traces verify un-recut
(proven on both platforms). `editor.txt` stages both demos; the
manifest test asserts every shipped demo arrives complete, proves
both export through the real play-archive path, and gains the
missing perfgauge absent-guard. Root launchers stay demo-only (the
picker is the front door). One boot-frame pixel golden per promoted
demo (cellar 90, swarm 175, pinned lavapipe) keeps smoke honest —
the committed traces stay the deep state net. The shipped guide
gained "Recipe: a puzzle or board game", and the gap audit built the
recipe verbatim as a scratch project — it ran first try, so **no
fourth demo** (the D096 menu/transition deferrals stay the only open
cuts). Clean-machine matrices on Debian 13 and native Windows PASS
with new-member checks; cellar and swarm packaged as full player
archives on both hosts. Selftest 23,991 Linux / 23,993 native
Windows; `nix run .#test` ALL GREEN. Picker-with-thumbnails and
gridtoy captures inspected on llm-feed.

**D098 closes A5 with the performance-envelope audit.** The vehicle
is `projects/perfgauge` (dev-tree only, never bundled): a
swarm-shaped cm.actor world held at a staircase of populations
(100..8,000) around a deterministic bouncing bot, with a rotating
8-way shooter keeping projectiles and hit queries in frame —
everything in doc, so the always-on ring recorder pays its real
cost. Observation is dev-side module-local `pal.time_ns()` rings
(step / post / draw / tick, avg/p50/p95/max per level); the sim
stays bit-deterministic. The measured truth on the Ryzen 9 5900X
reference desktop (Linux and native Windows within noise, luaheap
byte-identical): game logic is not the limit — cm.actor steps 8,000
chasers with overlap queries in under 3 ms — but record_frame's
whole-doc hash+canon on any changed frame costs ~9 µs per small doc
table, so 500 moving doc actors is ~5 ms/frame (comfortable), 1,000
is the edge (p95 ~15 ms, max ~27), and 2,000 breaks the 16.7 ms
budget; the in-RAM ring retains a canon copy per changed frame
(1.1 GB heap at n=8,000), so memory follows the same rule. The
shipped guide gained "The performance envelope" before the
determinism checklist: **~500 live moving doc-carried actors** is
the supported alpha envelope, cost tracks total doc size (not
motion), bulk numeric state belongs in named buffers (C-side
deltas), flourish stays render-only, F3 is the self-serve gauge.
Revisit trigger logged: a real game needing more votes for a
recorder-side per-subtree delta, then perfgauge re-runs and the
envelope rises honestly. With this, **A5 is closed** — every §2
slice shipped or honestly deferred (transition, D096).

**D097 lands the movement-input slice: cm.move.** The audit counted
the copies honestly: swarm's PAIN(move) aim/axis dance, cellar's
byte-identical stick-wins-else-digital block, the top-down starter's
digital half — and the old handoff's "three starter templates' naive
pad readers" no longer exist (D084 already replaced them with real
default bindings). cm.move is policy over recorded input plus pure
math, nothing touching doc: `stick` (quantized axes over 127, exact),
`keys` (digital -1/0/1 from action names, opposites cancel), `dir`
(the merged unit-scale vector — analog verbatim when deflected, else
keys with diagonals scaled by the demos' exact shared DIAG literal;
callers multiply their own speed), `face8` (per-axis-sign facing,
keep-last fallback; nested calls are the aim priority chain), and
`unit8` (even 8-way shot speed). 34 KATs (Linux 23,991 / native
Windows 23,993). Both retrofits are bit-exact — the unit-scale
reorder only commutes IEEE multiplies and sign flips — so BOTH
committed goldens stand un-recut: swarm_runs (1,346 frames) and
cellar_clear (556 frames) verify byte-exact on Linux and native
Windows with no doc bytes moved. The starter templates keep their
naive digital readers as contrast. The shipped guide gained a
movement section beside Gamepads. With this, every §2 A5 slice is
shipped (box, actor, camera, tween, depth, hud, move) or honestly
deferred (transition, per D096); A5's remaining line is the
performance-envelope audit.

**D096 lands the runtime-UI slice — cm.hud — and honestly defers the
transition slice.** The ordered pain-first audit found the demos'
transitions are three instant cuts (cellar's d.room swap, the demo's
cm.camera.center portal cut, the top-down starter's single room) with
no hand-rolled fade/wipe/hold anywhere — a pattern, not boilerplate —
so the transition slice waits for its first real vote, logged in the
ADR. The votes were in runtime UI: six sites of margin/centering
arithmetic against pal.gfx_size() (the demo's (W - measure) // 2
title dance; the arcade starter's brittle hand-tuned W/2 - 70) and
four copies of the pad-else-key label dance. cm.hud is render-only —
`place` (pure nine-anchor math, inward insets, floored centering),
`text` (place over gfx_size + cm.text.measure, per-line alignment
for multi-line blocks, returns the resolved top-left), and `label`
(input.label flavored by pad-1 connectivity, the D084 contract
live). Panels/bars (one vote), menus, dialogue, and pause screens
(zero votes) stay future cuts; the guide documents the pause idiom
as a doc flag + early return + hud.text("c"). 23 KATs (Linux
23,957 / native Windows 23,959). Two pixel-identical retrofit
proofs, both draw-only with both goldens standing un-recut
(frame-300 byte compares + cellar_clear/demo_camtour verifying
byte-exact on Linux and native Windows): the demo's three
HUD lines became three hud.text calls and cellar's message line +
label sites became hud.text("bl") + hud.label. Swarm and the
starter templates keep their naive copies as contrast. The shipped
guide gained a HUD/prompts section beside depth sorting.

**D095 lands the layer/depth slice: cm.depth.** Pure stable
draw-order sorting over plain tables, nothing touching doc:
`push(l, key, item)` takes an explicit finite sort key (the
feet/base y; NaN refused) with any non-nil item passing through
untouched, `sort` ascends by key with equal keys keeping push order
— the seq decoration makes the comparator a TOTAL order, so the
result is unique under any sort algorithm and hash order can never
draw — `each` walks back-to-front yielding the key too, `clear`
reuses, and `ysort(items[, field])` is the stable in-place
one-liner for arrays already carrying a numeric field. No scene
graph, no z properties, no callbacks, no culling. 20 KATs (Linux
23,934 / native Windows 23,936). Cellar is the retrofit proof (the
only vote): the PAIN(depth) comparator + rebuilt list became
push/sort/each, pixel-identical (frame-300 byte compare) and
draw-only — no doc bytes moved, so the committed golden stands
un-recut, verifying byte-exact on Linux and native Windows.
PAIN(actor) stays marked in cellar, PAIN(move) in swarm. The
shipped guide gained a depth-sorting section; the llm-feed montage
shows the same pillar hiding then revealing the player across its
base line.

**D094 lands the tween/effect slice: cm.tween.** Named decaying
effects on any plain doc table (the reserved `tw` key): `play` arms
an integer frame countdown that remembers its lifetime (t0 and an
optional stored strength), `tick` — once per step — decrements each
independently with the zero frame making `play(n)` gate exactly n
post-tick steps (`if tween.on(d, "pause") then return end` IS the
hit-pause idiom; the tween table ticks through its own freeze while
the skipped actor.tick freezes world timers for free), and all
presentation math is pure functions of the remaining fraction k:
`val` (mag * curve(k), cm.ease curves by name), `mix` (explicit
endpoints), `wobble` (cm.camera.offset's exact sin pair for screens
without a camera — never the PRNG), and the pure looping `bob`. 36
KATs (Linux 23,914 / native Windows 23,916). Swarm is the retrofit
proof: the hit pause / shake / death flash counter triple became
three plays, one tick, and two draw lines, timing-exact (the stored
mags 2.4/7.2 are the old t0 * 0.4). The golden was honestly re-cut
by replaying its own 1,346 input records through a real virtual pad
against a fresh boot (exact quantize_axis preimages; record stream
byte-identical to the old trace; the fight reproduces — 120, instant
pad restart, short second life, best retained; the inert driver-arm
EVAL stripped, the D093 input-only idiom) and verifies byte-exact on
Linux and native Windows. Cellar and the demo keep their naive
counters as contrast; PAIN(move) and PAIN(depth) stay marked. The
shipped guide gained a juice section beside cm.camera.

**D093 lands per-layer map parallax (LAYR v2) — the human's "backdrop
doesn't parallax" report.** Map layers carry `par_x`/`par_y` factors
(nil = 1); `draw_places` draws each layer at its own `cm.gfx.layer`
depth culled by the layer-effective camera, restoring the world layer
after — and never touches gfx.layer for an all-world-speed map. The
FLGS idiom governs the codec: LAYR v2 (the pair after each name) is
written only when some factor differs from 1, so every parallax-free
map keeps exact v1 bytes and no historical canon or trace moved
(pinned by KATs + the green suite). The map window's layer panel
gained a journaled **par** row; parallax is presentation-only
(colliders/markers/refs stay world-space) and the guide documents it.
The demo retrofit puts both backdrops at par_x 0.5 (par_y 1 — shallow
rooms, horizon authored against the room bottom), and demo_camtour
was honestly re-cut by replaying its own 2,068 input records against
a fresh boot (old SNAP doc == fresh-boot doc byte-for-byte; the one
recorded EVAL was the inert driver-arm, absent from the input-only
re-cut) — verified byte-exact on Linux and native Windows (23,878 /
23,880). On the way, a latent trap fell: bundle re-execution of a
`local M = {}` project module split-brains its state (functions
write a table nobody reads — verify crashed instead of diverging);
all five demo modules now adopt the loader's table
(`select(2, ...)`), and the scripting guide pins that idiom as the
module contract. Known cost: editing a project's sources still
invalidates its committed traces (bundle hash drift) — the idiom
makes that an honest divergence report, not a crash.

**D092 lands the camera slice: cm.camera.** Math over one plain doc
table (extra fields pass through — the demo parks its smoothed
lookahead there): follow easing the view center with per-axis lerp +
deadzone and ox/oy lookahead offsets, world bounds clamping every
motion door (small rooms center instead of jittering), `center` as
the cut for init/room swaps/respawns, shake as integer doc counters
ticked once per step with the render-only sin wobble off the
remaining count (the swarm idiom — never the PRNG), world<->screen
conversion through the unshaken camera (mouse aim stays
deterministic while the view wobbles), and `apply` handing the
shaken top-left to cm.gfx's parallax layers (`gfx.pixel_snap` keeps
rasterization policy). 37 KATs (Linux 23,873 / native Windows
23,875). The platformer demo is the retrofit proof: its f32-buffer
camera and both hand-rolled snap sites collapsed into
bounds/center/follow with identical knobs, the spike pit arms a real
shake, and the retrofit is sim-identical — the A4 route bot still
completes at the exact frame 2688. The committed
`tests/traces/demo_camtour.ctrace` (2,068 frames by virtual pad:
town run with lookahead, an up-jump chain through the y deadzone,
the portal cut, a deliberate spike dive with shake + warp, recovery,
the proper pit jump) verifies byte-exact on Linux and native
Windows. Known cost logged for a future recorder packet: the camera
moving in doc re-canons the demo's whole doc per frame (~3.5KB/frame
vs ~1KB before); swarm/cellar already pay this. Guide section
shipped beside cm.box/cm.actor.

**D091 lands the actor/world slice: cm.actor.** Bookkeeping over one
plain doc subtree — ascending never-reused ids over a single id-sorted
list (get is a binary search; no id map to rebuild, no hash order
anywhere near iteration), spawn-order iteration with mark-now/
sweep-at-tick despawn (safe inside your own loop), one string tag as
the group key, first-in-spawn-order strict-edge `hit` (cm.box
semantics), and integer frame timers on the world or any actor with an
exact expiry frame. No module state, no buffers, no participant, no
callbacks: snapshots, canon, traces, and rewind carry worlds by
construction — and it is deliberately NOT an ECS (§2's composable-
module rule). 41 KATs (Linux 23,836 / native Windows 23,838). Swarm is
the retrofit proof: pools, overlap loops, and countdowns collapsed into
the slice with the visible rules unchanged; iteration is now pinned to
spawn order where swap-remove order was incidental, so the golden was
honestly re-cut rather than claimed bit-identical — 1,346 frames driven
by a virtual twin-stick pad (a three-wave fight to 120, death with the
hiscore write, an instant pad restart, a short second life, best
retained) verifying byte-exact on Linux and native Windows. Cellar and
the demo keep their naive actor tables as contrast; PAIN(effect) and
PAIN(move) stay marked for their slices. The shipped guide documents
the module beside cm.box.

**D090 lands the first A5 slice: cm.box.** Pure AABB ergonomics over
plain keyed rects — strict-edge overlap (rect + 8-number forms),
centered-square `touch` pickups, `contains`, `expand` reach, ordered
`hit`/`hits` list queries, and the axis-at-a-time `slide` with
cancelled axes reported — exactly the semantics the four hand-rolled
copies agreed on. Pure = trivially deterministic; sweeping/layers/
circles/raycasts stay future cuts (fast movers keep `cm.collide`'s
world mover, tunneling documented). 28 KATs (Linux 23,795 / native
Windows 23,797); the cellar retrofit is the ergonomics proof with
bit-identical behavior (bot clears at the same frame) and a re-cut
golden that verifies on both platforms; swarm and the demo keep their
naive copies as contrast. Guide section shipped beside the map mover.

**D089 completes the naive family set.** `projects/swarm` is the
one-file arcade mini-demo: a twin-stick arena shooter — PRNG edge
waves, 8-way stick/keys movement, right-stick aim-implies-fire, two
swap-remove actor pools, hit pause / shake / death flash as doc
counters with render-only offsets, instant fire-restart, and a high
score persisted through both D086 doors (absent-fill boot read, pure-
output write on death; a live windowed pair proved the read against
the real store across a restart). The AABB overlap loop is on copy
FOUR — the A5 query slice's case is made. Committed
`tests/traces/swarm_runs.ctrace` (1,306 frames, two lives, best
retained across the restart) verifies on Linux and native Windows.
All three A6 families now have naive bundled proofs: demo (side-view),
cellar (top-down), swarm (arcade).

**D088 opens A5/A6 the pain-first way.** A5's rule is naive demos
before slices, and two of the three family proofs didn't exist. The
first is in: `projects/cellar`, the one-file top-down action mini-demo
— analog + digital movement with wall sliding, touch pickups, the
key-gated act-press door (the pickup persists across rooms in doc), a
latching pressure plate opening the vault gate, deterministic y-sorted
drawing, and doorway transitions. Every hand-rolled block carries a
`PAIN(actor|query|depth|move)` marker naming the A5 slice that should
absorb it (the AABB overlap loop is now on its third copy in the repo —
that's the evidence). Dev-tree only until the A6 bundling packet;
`tests/traces/cellar_clear.ctrace` (556 frames, a full clear driven by
a virtual pad's analog stick) verifies on Linux and native Windows, the
suite is ALL GREEN, and boot/vault/win captures are on llm-feed.

**D087 closes A4 with the exit proof.** `projects/inputproof` is the
committed all-inputs fixture: keyboard action bits (with pad-button and
pad-axis bindings ORed into the same v1 bits), the v1 mouse fields,
the PAD extension, and both D086 save doors in one sim. A render-side
driver — armed by a recorded eval, inert under verify — fed synthetic
key/mouse events through the real `cm.input.feed` door, drove a real
virtual SDL pad, triggered recorded save loads, and walked a scrub
rewind/resume mid-session; since `trace.rewind` stops a `--record` pin
by design, the committed artifact is the ring export ("save what just
happened"), which spans the rewind seam gaplessly.
`tests/traces/inputproof_a4exit.ctrace` (258 frames from a real
windowed WSLg session) carries sub-frame key and pad taps, clicks and
wheel, hot-plug cycles, a threshold-contrast axis sweep, three saves
(one via the pad-bound action), and two recorded loads — and verifies
byte-exact on Linux and the staged native Windows executable, where no
saves, pads, or history exist. The exit checklist walked honestly: the
bundled demo gained real pad default bindings (documented in
CONTROLS.md), scripted route bots completed it through the real loop by
keyboard AND by virtual controller — all 7 coins, both rooms, the spike
pit, up-jump chains, a flash-jump gap dash — at the identical
deterministic frame 2688 on Linux and native Windows; a
`jump -> key:44 + pad:north` rebind override and the recorded session's
save slot both survived fresh real boots byte-for-byte.

**D087 proof:** Linux selftest **23,767** checks and the staged native
Windows executable **23,769** on PAL API 19 (no new KATs — the proof is
the committed trace plus the walked checklist). `nix run .#test` is ALL
GREEN with the new trace beside every historical trace and all
pixel/audio goldens; native Windows re-verified inputproof, padtest,
and kitcheck. `tools/build-windows.sh` refreshed the stage (4 durable
entries preserved) and Start Menu shortcut. Inspected capture on
llm-feed: the fixture at the trace's final state, every domain tally
nonzero.

**D086 closes the player-storage packet, the fifth A4 line.** `cm.save`
keeps saves at `<pal.user_path()>saves/<save_id>/<profile>/slot<n>.sav`
— outside the install and project folder, so exports/archives/
duplicates/moves cannot carry another machine's progress by
construction. `save_id` is the stable namespace key (the project name
is mutable): a validated grammar in project.lua, boot-checked,
scaffolded from the project name for every new project, and editable as
a draft-legal identity field on the settings general tab. The store is
input.dat-class — bound only in interactive windowed sessions; headless
/ --frames / --verify answer every door with a named reason — plus the
new statement for reads: writes are pure outputs, and reads feed the
sim only through idempotent init (the trace SNAP carries the result) or
`save.load(slot)`, which queues the exact post-migration bytes through
the recorded console-eval channel (D022) so replays carry their own
payload. Slots are atomic `{ schema, data }` canon envelopes: a failed
write preserves the previous save byte-for-byte, reads migrate old
schemas stepwise (`save.schema`/`save.migrate`) and refuse newer ones
honestly, malformed files are named-but-untouched, `erase`/`wipe` are
the explicit resets, and profiles share the save_id grammar. The
shipped scripting guide documents the whole contract.

**D086 proof:** Linux selftest passes **23,767 checks** and the staged
native Windows executable **23,769** on PAL API 19 (56 new KATs across
grammar/slug/settings round-trip, disabled-store refusals, the exact
plain-tree round trip, injected-failure byte-preservation, schema
migration and refusals, listing/erase/wipe, and the recorded load door
including verify-path re-exec). `nix run .#test` is ALL GREEN — every
historical trace and all pixel/audio goldens unchanged. The live WSLg
fixture proved the end-to-end: run one wrote level 1 to the real
per-user store and applied a mid-session load; run two read it back
across a real boot, bumped it, and recorded a 90-frame trace — which
then verified byte-exact with the saves **deleted** (disabled store,
recorded EVAL carrying the payload) on Linux AND on the staged native
Windows executable where no saves exist. `tools/build-windows.sh`
refreshed the Windows stage (4 durable entries preserved) and Start
Menu shortcut. Inspected capture on llm-feed: the settings general tab
with the save id field.

**D085 closes the options packet, the fourth A4 line.** Volume is a
device-output affair: PAL API 19's `x_snd_gain(master, music, sfx)`
generalizes the editor-mute split into per-category gains on the DEVICE
copy of the sim mix (music slots 32..47, sfx 0..31, 48..63 master-only)
while master scales the whole callback output, editor bank included —
the hashed full mix is untouched by construction, so every audio golden
and trace is byte-identical under any volume, and `x_snd_dev_tap` is
the headless KAT seam that proves the math exactly. Window-size buttons
now derive from `x_display_size` through the pure
`cm.view.size_candidates`: ladder-filling multiples of the project's
FOV families that actually fit the desktop (largest eight, 1x fallbacks
for tiny displays, the classic static four without a display). The
controls page gained the two stick knobs D082/D084 reserved — deadzone
and axis press threshold, percent views over exact raw ints — riding
input.dat additively with defaults omitted and every load resetting
first. `video.dat` became the per-project machine-local options store
proper via `cm.view.video_contrib`; `cm.options` contributes the volume
percents and the new `custom` table backing `cm.options.add{...}` —
project-declared toggle/slider/choice settings rendered under "game
options", persisted per machine, undeclared stored ids inert (the
input.dat rule), documented in the shipped guide as LIVE presentation
policy (sim-read settings belong in `state.doc`). Slider gestures apply
live but persist once on release. Volumes apply on adoption, before the
first audible frame.

**D085 proof:** Linux selftest passes **23,711 checks** and the staged
native Windows executable **23,713** on PAL API 19 (56 new KATs: gain
clamps/category selection/half-gain-exactness/hashed-mix purity through
the dev-tap seam, knob setter clamps, the retuned-threshold sampling
boundary exact at quantized 80, the input.dat knob ride, size
candidates across 1080p/laptop/4K/tiny/no-display and the 960x540
family, options.add validation, set_vol clamps, the real video.dat
round-trip with inert foreign custom ids, redeclaration fallback).
`nix run .#test` is ALL GREEN — every historical trace and all
pixel/audio goldens unchanged. A live windowed WSLg fixture proved the
end-to-end: run one set volumes, a custom option, and both stick knobs
through the API doors; run two's real interactive boot adopted all of
them from the published stores with master honestly at its untouched
default. `tools/build-windows.sh` refreshed the Windows stage and Start
Menu shortcut. Inspected captures on llm-feed: the main page (volumes,
six display-fitted sizes, game options) and the controls page (stick
knobs at their exact default percents).

**D084 closes the rebind UI/API packet, the third A4 line.** An action
now holds a list of bindings — `key:<scancode>`, pad-1 buttons
(`pad:south`), stick/trigger directions past the live `axis_threshold`
(`pad:lx-`), and `pad2..4:` pins — all ORed into the same frozen v1
action bit at `sample()` time. Bindings are pure live policy, exactly as
D082 planned: the recorded bits stay authoritative, so rebinding can
never invalidate a trace. Code-declared maps are the defaults; the
player's per-action overrides live in the machine-local, never-exported
`<project>/input.dat` (atomic saves, malformed data ignored, overrides
for undefined actions kept inert across hot reloads/version skew).
Conflicts are legal API state surfaced by `conflicts()`; the Esc menu's
new **controls page** lists binding chips per action (`*` = overridden,
red = shared), captures the next key/pad-button/strong-deflection through
the real event stream, steals the input from other actions with an
honest note, offers del-to-remove and defaults, and saves on every
change (failures name themselves, summon the console, keep the live
rebind). `ui.capture_pads()` extends the menu's key rule to pads. HUD
strings come from `input.bind_label`/`input.label` (host scancode names
+ the positional pad vocabulary); the starter templates dropped their
hardcoded pad readers for real default bindings and device-flavored
`input.label` HUD lines. The shipped scripting guide documents it all.

**D084 proof:** Linux selftest passes **23,655 checks** and the staged
native Windows executable **23,657** on PAL API 18 (49 new KATs: every
descriptor form and refusal, pad-button/sticky-tap/threshold-exact-axis/
pinned-pad sampling into the v1 bits, conflicts, labels, capture
normalization boundaries, and the store's load/win/round-trip/injected-
failure/malformed-fallback contract). `nix run .#test` is ALL GREEN —
every historical trace and all pixel/audio goldens unchanged, proving
bindings changed no recorded byte — and both Linux-recorded traces
(`smoke_kitcheck` 830 frames, `padtest_drive` 600 frames) verify
byte-exactly on native Windows. A scripted SDL virtual pad drove the
REAL capture path headlessly: an armed capture on the scaffolded
platformer bound `pad:north` to jump and persisted it to `input.dat`,
and a second run rebinding reset stole `pad:south` from jump with the
honest "moved from jump" note. `tools/build-windows.sh` refreshed the
Windows stage (4 durable entries preserved) and Start Menu shortcut.
Inspected captures on llm-feed: options main page, the controls page
with the jump override, the armed prompt, red conflict marks, the steal
result, and the pad-flavored template HUD.

**D083 closes the SDL gamepad discovery/hot-plug packet, the second A4
line.** The split follows the PAL boundary: PAL API 18 owns device
lifetime — `SDL_INIT_GAMEPAD` at process start (non-fatal where absent),
gamepads opened/closed on hot-plug events in the pump so devices survive
VM reboots like the window, and device-level `gpad`/`gpadbtn`/`gpadaxis`
events keyed by SDL instance id — while `cm.input` owns policy:
first-connected claims the lowest free slot 1..4, a fifth device is
ignored until a slot frees, reconnect resets its slot in place, and
unassigned-device events drop. `pal.pad_list()` reports what is attached
right now, and `pad_sync()` at project boot resets then adopts it in
connect order, so a fresh session never inherits the previous latch while
a still-plugged controller claims its slot before frame one. The editor's
`filter_events` extends the key rule to pads: hot-plug always passes,
button downs gate on game-window focus (releases always pass), and axes
gate on focus with `pad_neutralize()` zeroing live axes on the focus-loss
edge. Virtual SDL gamepads (`pal.x_pad_virtual*` + `pal.x_events_pump`)
are the headless test vehicle riding the exact physical event path. The
three non-blank starter templates read pad 1 naively (dpad/left stick,
south, start) beside their key maps — hardcoded until the rebind packet —
and the shipped scripting guide now documents the pad readers. The new
dev-tree `projects/padtest` fixture consumes axes/edges/connectivity into
`state.doc` and anchors the committed gamepad trace.

**D083 proof:** Linux selftest passes **23,606 checks** and the staged
native Windows executable **23,608** on PAL API 18 (new KATs: the whole
slot policy plus the real SDL path via a virtual pad — attach event,
`pad_list`, SDL-numbered button/axis readback, release edges, `pad_sync`
adoption, detach). `nix run .#test` is ALL GREEN including the new
600-frame `padtest_drive` gamepad trace (two mid-recording hot-plug
cycles, partial/full deflections, a sticky sub-frame tap), and that
Linux-recorded trace plus a 294-frame live windowed WSLg recording both
verify byte-exactly on native Windows. A virtual controller drove a
freshly scaffolded platformer template through the real loop from spawn
to the far wall. One SDL quirk worth remembering: virtual-pad state
changes become events only at the next pump, so a sub-frame tap needs a
pump between down and up (real hardware always delivers both events).
`tools/build-windows.sh` refreshed the Windows stage (4 durable entries
preserved) and Start Menu shortcut. Inspected captures on llm-feed: the
padtest fixture after the committed drive and the pad-driven platformer.

**D082 closes the input-record-v2 design packet, the first A4 line.** The
input record is now self-describing and additive: the first 10 bytes stay
exactly the frozen v1 unit, followed by zero or more `u8 tag, u8 len,
payload` extensions — so a bare v1 record is a valid v2 record, every
historical trace replays unchanged, and record lengths mix freely inside
one trace. `apply()` skips unknown tags and rejects malformed framing
loudly. Tag 1 = PAD carries the complete per-frame gamepad state: up to
four canonical ascending slots of u32 SDL3-numbered buttons plus six i8
quantized axes. Deadzone (default 8000, a future options knob) and
quantization to ±127 happen live-side only in exact integer math; the
recorded value is authoritative, so replay/cross-platform verify never
re-derive axis math and retuning deadzones or rebinding can never
invalidate a trace. Applied pad state lives in the new 96-byte
`cm.input.pad` buffer (cur/prev buttons/axes/connected per slot, edges
snapshot-consistent), created only by PAD-carrying records or pad readers.
apply() touches pad state iff the extension is present; a live-side latch
keeps the extension coming (n=0 when empty) once the domain activates so
held buttons always meet their release edge, while keyboard-only sessions
stay byte-identical to v1. Pad buttons get the same sticky-tap guarantee
as keys; readers are `pad_down/pressed/released`, `pad_axis`,
`pad_connected` with SDL-numbered constants. Device identity and hot-plug
are live-only: connect/disconnect is entry presence at a frame boundary.
The timeline's input-transition marker now also sees pad slot+button words
(never axes).

**D082 proof:** Linux selftest passes **23,585 checks** and the staged
native Windows executable **23,587** on PAL API 17 (44 new KATs:
quantization vectors/monotonicity/symmetry, v1 purity, latch semantics,
canonical encodings, edges/taps/disconnects, every malformed-record
rejection, snapshot edge restoration, pad_reset). `nix run .#test` is
ALL GREEN — every historical trace verifies byte-exactly and all
pixel/audio goldens match — and the Linux-recorded 830-frame
`smoke_kitcheck` trace verifies byte-exactly on native Windows through
the new apply path. `tools/build-windows.sh` refreshed the full Windows
stage (4 durable state entries preserved) and Start Menu shortcut. No
visual surface changed, so there are no new captures.

**D081 closes the starter-template packet and with it A3.**
`cm.project.TEMPLATES` registers blank/platformer/top-down/arcade; blank
stays the embedded `MAIN_TMPL` and the other three are readable one-file
games under `engine/stock/templates/` — deliberately naive (A5 wants the
pain visible), deterministic (`state.doc` only, `cm.math` trig off the sim
frame, `cm.rand` arcade spawns, ASCII HUD), and resolution-relative. The
scaffold resolves the template source before any filesystem effect and
keeps the main-first/`project.lua`-last rollback; name substitution goes
through a gsub table with quote/backslash escaping so `%` and hostile-but-
legal folder names cannot corrupt the generated Lua. Non-blank projects
carry "started from the <label> starter template" as their draft
description. The picker's "+ New project" tile (click or Enter) opens a
D080-grammar chooser: a focused editable name prefilled by `cm.words`
(D077 validation plus a memoized existence check), one row of the four
starters with chosen-fill vs cursor-ring, the selection's note, and
create/cancel with create as the safe Enter default. `M.scaffold(template,
name)` remains the scripted door. The top-down starter also fixed a
spawn-inside-wall defect and every template's HUD dropped non-ASCII glyphs
the shipped pixel font lacks (the blank template shared that latent bug).

**D081 proof:** Linux selftest passes **23,541 checks** and the staged
native Windows executable **23,543** on PAL API 17; `nix run .#test` is
ALL GREEN across release manifests, every historical trace, and all
pixel/audio goldens. Selftest pins the registry, blank identity,
substitutable stock sources, read-failure-before-mkdir, tricky-name
round-trips, provenance metadata that passes boot validation, and a
120-frame per-template boot smoke (input records zeroed, doc/action state
restored, arcade held to spawn-clock accounting). Autopilot bots completed
each game through the real sim: the platformer's four-jump staircase to
the flag, all six top-down gems, arcade score 100. A checksum-verified
fresh public Linux archive in stock Debian 13 (spaced/π path, uid 65534)
created all four starters through the picker door without a terminal,
booted each, and showed all four provenance-labeled tiles in a fresh
picker process. `tools/build-windows.sh` refreshed the full Windows stage
(3 durable state entries preserved) and Start Menu shortcut. Inspected
captures on llm-feed: the chooser (default, arcade-selected, 300% fixed
chrome, fresh-archive, native Windows) and the three completed/mid-run
starters. One dev-tree-only flake: a single local selftest run failed
"atomic: flush preserves destination" once with stale
`/tmp/cosmic_selftest_*` leftovers from an earlier aborted run present;
it passed on every clean rerun and in the hermetic suite — if it recurs
on a clean /tmp, investigate before trusting the flush KATs.

**D080 closes the picker navigation/scale packet.** The list model and grid
math live in the pure module `cm.pick` (plain-text case-insensitive search
over name/path/author, stable name sort beside recents-first order, clamped
column-preserving grid cursor movement, scroll clamp + smallest-change
ensure-visible). The picker consumes it: the tile grid clips under a
two-row header (search field, recent/name sort toggle, an honest "N of M
projects" count) and scrolls by wheel, draggable scrollbar with page jumps,
and PgUp/PgDn. Arrows move a cursor ring with "+ New project" as the last
grid cell, Enter opens the editor (Shift+Enter plays; on a broken recent
tile Enter opens the repair chooser), `.` opens the `...` folder menu, Del
opens the confirmed delete door, `/` or Ctrl+F focuses search, and Esc
clears the filter. Every modal button row cycles with arrows/Tab + Enter on
a safe default, text fields keep Enter as their own submit without
double-firing a button, and the search field goes inert while a modal owns
the keys. Declared project icons draw as tile thumbnails through
`cm.gfx`'s memoized texture cache with per-path failure memoization;
refresh forces one re-read. Everything stays ephemeral render/dev state —
no new persistent state beyond what recents/`editor.dat` already own — and
the whole surface works at 100–300% fixed chrome.

**D080 proof:** Linux selftest passes **23,496 checks** and the staged
native Windows executable **23,498** on PAL API 17; `nix run .#test` is
ALL GREEN across release manifests, every historical trace, and all
pixel/audio goldens. Selftest KATs pin the filter (case folding, plain
text never patterns, exact UTF-8 bytes, order preservation, empty
results), the name sort's path tiebreak and non-mutation, every cursor
clamp/landing rule including degenerate grids, scroll clamping, and
ensure-visible. Inspected 1280×800 captures on llm-feed show the
39-project scrolled grid with clipped tiles and scrollbar, live search
with the count line, 300% fixed chrome as a single scrollable column with
the complete header, the folder menu and delete modals with their keyboard
selection rings, mixed thumbnail/plain tiles, and the staged native
Windows picker. `tools/build-windows.sh` refreshed the full Windows stage
(3 durable state entries preserved) and Start Menu shortcut.

**D079 closes the archive/delete packet, completing the A3 project-actions
line.** Every ready recent tile's `...` menu now offers **archive** and
**delete** beside reveal/rename/move/duplicate. Archive streams the saved
project — the same `.ed`/dot-state and `video.dat` omission and link refusal
as duplicate — through the shared `cm.archive` stored-block writer (extracted
byte-identically from `cm.export`, plus explicit directory members) into a
dot-prefixed temp beside a user-chosen parent, published by one atomic
no-replace rename under the derived name `<folder> <date>[ (n)]`; same-day
backups take the first free suffix and a race cannot overwrite one. Every
failure or cancel removes the temp and the source is never written. The
success state stays open and offers delete with that archive named as the
safety net.

Delete is triple-anchored: the exact folder name must be typed (or arrives
pre-armed from the just-made archive as the two-step path), the source must
hold a recent tile — which remains visible as the recovery handle until the
whole tree is gone — and the active editor root, aliases, and links anywhere
in the tree are refused before the first removal. PAL API 17's
`x_list_dir_all` (the unpruned `list_dir` twin, sanctioned only for
read-to-delete) enumerates `.ed` journals and dot tool state. `project.lua`
is removed first so no interrupted delete leaves a bootable half-project;
validity is deliberately not required and broken-but-present recent tiles
keep a delete door, so a partial delete is always finishable from the picker.
The root removal and atomic recents removal share the final unyielding step;
a recents failure afterwards names the honest missing tile. Esc/outside
clicks on a running job can only request cancellation, and a cancelled delete
reports that already-removed files are gone. All modals stay usable at 300%
fixed chrome.

**D079 proof:** Linux selftest passes **23,478 checks** and the staged native
Windows executable **23,480** on PAL API 17; `nix run .#test` is ALL GREEN
across release manifests, every historical trace, and all pixel/audio
goldens. Fake-fs KATs pin every refusal, dated unique naming, machine-state
omission, injected append/publish/remove/recents failures, cancel,
project.lua-first ordering, and half-tree retry; real-PAL runs decode the
published tar.gz/ZIP containers byte-exactly and prove partial-delete honesty
plus the pruned/unpruned listing contract, and a selftest pin keeps
`cm.export` (still host-loadable without the `cm` global) mirroring the
shared ZIP32 limits. A checksum-verified fresh public Linux archive in stock
Debian 13 archived the external `projet π original` from a spaced source area
into `destination était ici`, proved machine state stayed out, re-imported
the extracted archive through open folder, survived an injected publish
failure with nothing published, kept an honest repairable tile through an
injected partial delete, finished that delete through the broken-tile door on
retry, deleted the original through the typed door with the archive
surviving, and — from a read-only install — still archived while delete
refused honestly without a recents tile. The fresh public Windows ZIP
repeated the matrix natively over spaced/π `C:` paths with a legacy backslash
recents spelling. Inspected captures on llm-feed: the six-action menu, typed
delete confirmation, 3,000-file mid-archive progress with cancel, the
success/safety-net and armed-delete states, the 300% delete modal, and the
native Windows public-build menu.

**D078 closes the duplicate packet.** Every ready recent tile's `...` menu now
offers **duplicate**: the native folder dialog chooses an existing destination
parent, a modal edits the folder name (default `<source> copy`) under D077's
grammar with live validation, and a cancellable coroutine job copies the saved
project one file per step with a progress bar. Machine/editor state never
enters a duplicate: `.ed` (and other dot-directory tool state) is excluded by
`pal.list_dir`'s pruning contract and machine-local `video.dat` by name. The
copy lands in a unique dot-prefixed staging sibling that neither the picker
scan nor the copy walk can observe, the staged root must revalidate through
the exact boot contract, and the only authoritative transition is PAL API 16's
atomic no-replace rename followed by an atomic recents note. Preflight refuses
the active editor root, self-nesting, collisions, aliases, links, invalid
sources, and unwritable parents before any write; every failure or cancel
cleans staging, publishes nothing, and never writes the source. Esc/outside
clicks on a running job can only request cancellation. A recents failure after
publication names the exact new root for **open folder** repair, and the
shared `remove_tree`/staged-copy shape is reserved for the later
cross-filesystem move. The compacted duplicate modal stays fully usable at
300% fixed chrome.

**D078 proof:** Linux selftest passes **23,446 checks** and the staged native
Windows executable **23,448** on PAL API 16; `nix run .#test` is ALL GREEN
across release manifests, every historical trace, and all pixel/audio goldens.
Fake-fs KATs pin every preflight refusal, machine-state omission, recents
ordering, injected read/write/publish/recents failures, and mid-copy cancel
with a byte-identical source and no staging leftovers; real-PAL runs prove
spaced/UTF-8 duplication plus injected atomic-write and publish failures
against real staged files. A checksum-verified fresh public Linux archive in
stock Debian 13 duplicated the external `projet π original` from a spaced
source area into `destination était ici/projet π copie` through the real
post-dialog accept path, omitted `.ed`/`video.dat`, kept recents pointing at
both roots, booted both independently, and showed both tiles in a fresh picker
process (a read-only-install variant also exercised the honest post-publication
recents-failure report, which named the exact published root). The fresh
public Windows ZIP repeated the flow natively over spaced/π `C:` paths with a
legacy backslash parent spelling, booted both roots, and restarted into a
picker showing both. Inspected menu, ready-modal, 3,000-file mid-copy,
completion, 300%, and both archive-restart captures are on llm-feed. A
mid-copy duplicate of a 3,000-file fixture streams at ~12 files per rendered
frame with honest per-file progress.

**D077 closes the first project-location packet.** Every ready recent tile now
has a `...` menu for **reveal**, **rename folder**, and **move folder**. Rename
edits the final directory component without changing project metadata; move
chooses an existing parent through the asynchronous native folder dialog. The
picker refuses active-editor ownership, aliases, invalid projects, unsafe
names, descendant moves, missing/unwritable parents, and collisions before any
filesystem transition. The action overlays remain usable at 300% fixed-chrome
scale.

PAL API 16 makes the authoritative directory transition atomic and
no-replace: Linux uses `renameat2(RENAME_NOREPLACE)` and Windows uses UTF-16
`MoveFileExW` without replacement. This packet deliberately refuses
cross-filesystem/volume moves until recursive transactional copy exists.
Recents change only after the native move succeeds. A native failure therefore
leaves the source and its tile untouched; a recents-only failure reports the
exact new root and retains the stale tile as an explicit repair handle. Reveal
hands Linux a percent-encoded UTF-8 `file:` URI and Explorer the original
UTF-16 path, including spaced/non-ASCII names.

**D077 proof:** Linux selftest passes **23,430 checks** and the staged native
Windows executable passes **23,432** on PAL API 16. `nix run .#test` is ALL
GREEN across release manifests, every historical trace, and all pixel/audio
goldens; the corrected native Windows clean-machine archive matrix also
passes. Fresh public Linux and Windows editor archives each moved an external
project through spaced/non-ASCII source and destination paths, renamed it,
persisted the replacement recent, restarted, and directly reopened the new
root. The Windows ZIP additionally launched Explorer for that Unicode root and
the proof identified exactly one matching native window. That archive check
exposed and closed Windows' unreliable percent-encoded-file-URI behavior by
moving Explorer to the UTF-16 native handoff. Inspected 100%, focused-rename,
300%, and native-Windows picker captures are on llm-feed.

**D076 closes the external-project entry/return packet.** PAL API 15 exposes
SDL's asynchronous native folder chooser through a process-owned, pollable
mailbox whose callback never enters Lua. The picker can now **open folder** for
an arbitrary project in place, validate its `project.lua` through the exact
boot contract, publish it newest-first to recents before switching, and
**refresh** without a restart. Missing or invalid recent roots stay visible
with explicit **repair** and **remove** actions; repair atomically promotes the
validated replacement, while removal never touches project files. Legacy
Windows separators, trailing slashes, and `./` aliases collapse to one entry.

The editor's fixed **← projects** action is a recovery boundary, not a raw
reboot. It refuses an active export, restores the live present when rewind is
parked, closes pending text gestures into journals, atomically saves the
session, tears down ephemeral owners, stops explicit recording, and drains the
history tail before the one-shot project carrier reboots into picker mode. The
carrier now outranks the original command line, so this also works after a
direct `--edit` launch.

**D076 proof:** focused Linux selftest passes **23,412 checks** and the staged
native Windows executable passes **23,414** on PAL API 15. `nix run .#test` is
ALL GREEN across release manifests, every historical trace, and all
pixel/audio goldens; native Windows also verifies the 830-frame
`smoke_kitcheck` trace. A checksum-verified fresh public Linux archive ran in
stock Debian 13, registered and opened the spaced external root
`/external project`, showed it first in a new picker process, and reopened it
from the persisted recent entry. Inspected public-Linux and native-Windows
picker/editor captures are on llm-feed. `tools/build-windows.sh` refreshed the
complete Windows stage and Start Menu shortcut while preserving three durable
state entries.

**D075 closes the in-editor player-export packet.** PAL API 14 adds exact
SHA-256/rolling CRC-32, link-aware path inspection, atomic new/explicit-replace
publication, and Windows player-launcher identity. `cm.export` uses those
primitives to stream the saved currently-open project with the matching runtime
already in the public editor: Linux emits `.tar.gz`, Windows emits `.zip`, and
selecting the other host explains which download is required. It needs no Nix,
shell archive tool, compiler, or source-tree project. Both formats carry the
canonical player README/icon/launcher, runtime notices, extracted-tree
`SHA256SUMS`, and a sibling archive `.sha256`; `.ed`, `video.dat`, links, unsafe
paths, and unsupported ZIP32 sizes/counts cannot enter.

Project settings now has a third **build/export** tab with target, output
folder, explicit atomic replacement, saved-state preflight, per-file progress,
cancel, result path/hash, and in-window/console failure. Unsaved settings, code,
sprite, map, tilemap, palette, instrument, or song bytes name the file to save
and block the build. Job state is ephemeral. Tab switches preserve progress;
Alt+right-click close, Esc, and F4 rewind cannot discard an active job; cancel
removes its sibling temp and publishes nothing.

**D075 proof:** Linux selftest passes **23,401 checks** and native Windows
passes **23,403** on PAL API 14. A writable copy of the public Linux tree opened
`/tmp/cosmic A3 external project` and completed the UI job in 3.6 seconds,
publishing a verified 30.5 MiB archive. The freshly staged native Windows editor
opened an external `C:/Users/...` project and published a project-branded,
verified 38.9 MiB ZIP through the same surface. Both sibling hashes and every
extracted `SHA256SUMS` entry pass; completed UI captures are on llm-feed. The
full `nix run .#test` matrix is ALL GREEN: release manifests, every historical
trace verification, and all pixel/audio goldens are unchanged. Fresh editor and
demo archives also pass the complete Debian 13 and native-Windows read-only,
spaced/non-ASCII-path clean-machine matrices.

**D074 closes the rewind-rate and editor-legibility packet.** Rewind playback
is now presentation-clocked against the fixed 60 Hz trace period: 1× consumes
the original wall time regardless of render refresh, while explicit 2×/4×/8×
rates advance faster. Late draws drop intermediate presented states and restore
the newest due frame, so transport time does not drift; A/B still holds A for a
complete first draw and presents inclusive B before wrapping.

The editor's adjacent **Aa** control independently sizes **canvas windows**
(content and fonts) and **fixed chrome** (HUD, menus, launcher, drag ghost, and
rewind tray) from 75–300%. Auto keeps ordinary 1080p at 100% and follows SDL
display scale or high-resolution window density for DPI/4K defaults. Both are
machine-local, per-user `editor.dat` policy shared by the picker and every
project, and the picker consumes the fixed-chrome value too. The captured
logical camera, editor session, history, traces, verification, and project
output are untouched. Missing/old settings enter auto mode safely.

**D074 proof:** clock-injected KATs pin no early advance, exact 1× steps,
inclusive A/B wrap, and deliberate faster-rate skipping; camera/chrome KATs pin
scaled transforms, fit, and matching pointer coordinates; viewport KATs pin
1080p/DPI/4K policy, persistence, and invalid-data rejection. Linux selftest
and the native Windows `.exe` pass at **23,351 checks** on PAL API 13, and `nix
run .#test` is ALL GREEN with every historical trace and pixel/audio golden
unchanged. Inspected 100%/150% editor and 4K picker captures cover the canvas,
Aa panel, launcher, scaled rewind tray, and first-run project tiles. The
refreshed Windows stage contains no `.ed/history` or project `video.dat`, and
the per-user root has no pre-existing `editor.dat`,
while valid sessions/journals remain preserved; its Start Menu shortcut targets
the new `cosmic2d-editor.exe`.

**D073 closes the native live-history stability report.** Closed rewind
segments no longer serialize or durably write from `record_frame`: render/dev
maintenance submits segment + cumulative-index transactions to PAL API 13's
bounded background atomic writer, while quit/crash and structural timeline
changes remain explicit durability barriers. Pending segments stay pinned in
RAM and injected segment/index failures retain the prior authority. Editor
park/unpark now invokes resource-owner teardown hooks before dropping caches;
sprite and animation previews release their raw deferred GPU textures, so A/B
playback cannot consume one finite texture slot per seek.

**Stability proof:** the original disposable native-Windows repro fell from a
92.6 ms frame-60 trace close (89.8 ms synchronous NTFS write) to **0.254 ms**;
render-side serialization/enqueue took 0.266 ms and later closes were
0.219–0.274 ms. A real sprite-window A/B stress completed **1,463 seeks** with
textures flat at 5 (formerly failed near the 256-slot ceiling). Linux and
native Windows selftests pass at **23,338 checks** on PAL API 13; `nix run
.#test` is ALL GREEN with every historical trace and pixel/audio golden
unchanged. The Windows tree is staged at `C:\Users\headpats\cosmic2d-win` and
the per-user **cosmic2d editor** Start Menu shortcut is refreshed.

**A3 settings packets 1–2 are complete (D071/D072).** `cm.project` is the one
declarative authority for boot, picker metadata, player packaging, and editor
settings. Its empty-environment/plain-data codec, runtime/settings/D070
validators, deterministic encoder, and field merge preserve extension keys.
The referenced-byte contract now also lives there behind injected file I/O, so
the PAL-backed editor and host packager apply the same icon/text rules.

The project-settings canvas window has **general** and **player files** tabs.
The new tab edits project-local icon, controls, credits, and an ordered license
list through typed paths plus fuzzy choosers (including extensionless legal
names). Every row reports live mtime-cached file/content validation; chooser
candidates with invalid dimensions/content remain visible and disabled. An
entirely empty packet stays a saveable draft, but once one reference is present
the complete D070 schema and all saved bytes must validate before Ctrl+S can
atomically publish `project.lua`. **clear release** explicitly returns to draft.
Fresh projects can therefore become export-metadata-complete without editing
Lua, while missing/unsafe/empty/wrong-type selections cannot cross the settings
save boundary.

**A7's foundation remains complete (D065/D066/D074).** The persistent four-lane
rewind tray owns the live camera, zoom/pan, click seek, wall-clocked
1×/2×/4×/8× inclusive A/B playback, and two-step Esc grammar. Generic state
participants flush/rebuild runtime facades at every capture/restore boundary;
`cm.map` proves maps, placements, markers, collision, and active selection
rewind coherently. The timeline information layer landed since (activity/event
digest D100, presented-frame previews D101); the disk budget/retention surface,
standalone clip packages, and immutable replay/crash sources remain later A7
packets.

**Proof:** focused KATs cover draft/partial policy, normalized content, missing
files, binary text, bad icon type/shape, extensionless legal candidates, picker
mutation, live validation, and save refusal without disk mutation. Host release
fixtures reject the same wrong-type selections. `nix run .#test` is ALL GREEN at
23,330 checks with every trace and pixel/audio golden matching; fresh Linux and
Windows demo exports both build. Inspected 1280×800 captures show the complete
release tab and chooser at 100% canvas zoom.

**Exact next packet:** **A7 — the rewind/replay product UI, continued.**
The foundation (persistent tray, scrub grammar, wall-clocked
transport: D065/D066/D074), the store's durability rework (D073), and
the whole **timeline information layer** are now done: the persisted
per-segment activity/event digest (D100 — the sim/editor/files
envelope + save/error/restart/session markers draw the whole retained
window including adopted cross-session history) and the
presented-frame previews (D101 — the PREVIEWS lane draws game-FOV
thumbnails, one per segment). The natural next packet is the
**disk budget / retention surface**: the tray already shows
`used / budget · N segments`, so make it a *control* — visible
disk use with pause/clear and retention knobs, and a bounded,
understandable long session (`ALPHA.md` §A7 line 4; `cm.ed.clear_cache`
+ the budget-eviction path already exist to build on). After that:
immutable timeline sources with drag-in replay files, the standalone
clip package (the content-addressed project-blob generalization,
which extends `FSAV` to carry a blob hash and folds in the D101
`THMB` durable chunks + D100 digest for adopted/cross-session
recovery), atomic clip export to `replays/`, and crash-report drops
(the ERROR marker + ring locator are already in place). Standing
revisit triggers: >500 rich doc actors votes the recorder per-subtree
delta (D098, re-run perfgauge); a game needing per-frame detail in
adopted history votes multi-resolution sub-segment digest buckets
(D100); a sub-second preview cadence votes a per-segment preview list
(D101); a hand-rolled fade/wipe/hold votes the transition slice in
(D096); a sim/doc-moving demo retrofit re-cuts its golden with
`tools/trace/replay-driver.lua` + `dump.lua` + `strip-eval.lua`
(usage in the headers and PROCESS.md).

**Native Windows developer handoff is now automatic.** The canonical
`tools/build-windows.sh` path cross-builds the complete development tree,
publishes it to the Windows user's stable `cosmic2d-win` directory without
discarding durable editor sessions/journals or machine-local state (derived
history cache is rebuilt), and idempotently installs a per-user **cosmic2d
editor** Start Menu shortcut. Repository agent protocol now requires that
handoff after built engine/editor changes, eliminating stale Windows snapshots
as a source of false visual reports.

**A0 is complete.** The former 3,112-line STATUS diary is archived verbatim;
the live handoff and docs index are compact; active and historical roadmaps are
unambiguous; all local documentation/help links resolve; obsolete graybox help
is gone; and distribution plus persistent-undo claims match their current
pre-alpha guarantees. The shipped scripting page is now a task/API guide for
project lifecycle, deterministic state, input, rendering, maps/collision,
animation, and audio, with unsupported gamepad/query/export paths named.

**Proof:** implementation-signature and local-link checks pass. `nix run
.#test` is ALL GREEN: 23,287 self-checks, every trace verify, and all pixel
goldens.

**A1 packet 1 is complete.** PAL API v9 adds `pal.write_file_atomic`: a unique
same-directory temp is fully written, flushed, OS-synced, closed, and only then
atomically replaces the destination. It returns `true` or `nil,error`. Injected
failures at open, partial write, flush, sync, close, and rename each preserve a
known-good destination byte-for-byte and clean the temp; success and empty-file
replacement plus a natural missing-directory failure are also covered. Linux
and Windows builds compile; `nix run .#test` is ALL GREEN with 23,129
self-checks, every trace verify, and all pixel goldens.

**A1 packet 2 is complete.** Editor `session.dat` and engine-root
`.recent.dat` now use atomic replacement. Every successful editor save also
atomically maintains `session.dat.good`; corrupt live metadata restores that
copy, while double corruption starts fresh with an explicit recovery notice.
Session/recent write failures are logged and open the console rather than
silently continuing. Focused tests inject failures into the recovery and live
replacement steps, prove the previous files survive, cover single/double
corruption, and pin recents ordering. `nix run .#test` is ALL GREEN: 23,139
self-checks, every trace verify, and all pixel goldens.

**A1 packet 3 is complete.** Journal full rewrites now atomically publish both
`<asset>.jrn.good` and the live append stream; ordinary edits retain the cheap
single-chunk append path. A corrupt or missing live journal restores and
repairs the latest checkpoint. The session's newer working bytes then pass
through the existing adoption path, so current unsaved work survives even if
post-checkpoint undo steps do not. Checkpoint, live-publish, and recovery-write
failures are visible in the console. Injected-failure tests prove no partial
file becomes authoritative, corrupt/missing live recovery, valid-checkpoint
adoption after a failed repair, and safe fresh fallback after double
corruption. The A1 last-known-good session/journal roadmap item is proven
complete. `nix run .#test` is ALL GREEN: 23,145 self-checks, every trace
verify, and all pixel goldens.

**A1 packet 4 is complete.** Sprite saves now encode the full `.spr` plus
`.png`/`.anim`/`.meta` generation before publication, durably record it in an
atomic `.spr.txn` recovery manifest, atomically publish runtime outputs then
source, and only then clear the manifest and claim success. Load and the next
save finish interrupted generations idempotently. PAL API v10 adds in-memory
`png_encode`; empty clip tables now replace stale `.anim` files. Named errors
flow through the editor save console while dirty bytes remain. Injected tests
cover manifest creation, all four output boundaries, manifest cleanup, and
matching recovery. `nix run .#test` is ALL GREEN: 23,176 self-checks, every
trace verify, and all pixel goldens. Linux and cross-built Windows packages
both compile.

**A1 packet 5 is complete.** `.ed/owner.dat` (`CEDO` schema 1) now records
that the directory is engine-owned but not wholly disposable: session and
journal files are working recovery that may contain the only copy of unsaved
work, while rewind history is derived cache. Missing markers adopt the legacy
layout. Corrupt markers rebuild only history and report recovery; foreign or
newer markers preserve everything and refuse the older editor. The explicit
`cm.ed.clear_cache()` operation opts into a derived-history rebuild without
ever deleting session/journals. Ownership is checked before boot reads rewind
history. Focused tests cover legacy, corrupt, newer, explicit-clear, and
marker-publication failure paths. `nix run .#test` is ALL GREEN: 23,185
self-checks, every trace verify, and all pixel goldens.

The export contract is now explicit in `ALPHA.md`: shipped games include the
engine, editor/tooling, source project, and assets for curious players. The
normal named launcher remains locked directly to play mode via D052; “play
only” describes that default entrance, not a stripped artifact.

**A1 packet 6 is complete.** `.map` source saves now use the PAL atomic-write
primitive through a map-specific save API and the real map-window write hook.
An injected replacement failure preserves the previous valid map byte-for-byte,
keeps the newer working document dirty, reports the named failure, and summons
the editor console; a retry publishes a complete decodable generation. `nix
run .#test` is ALL GREEN: 23,191 self-checks, every trace verify, and all pixel
goldens.

**A1 packet 7 is complete.** `.tm` source saves now use the PAL atomic-write
primitive through a tilemap-specific save API and the real tilemap-window write
hook. An injected replacement failure preserves the previous valid tilemap
byte-for-byte, keeps the newer working document dirty, reports the named
failure, and summons the editor console; retry publishes a complete decodable
generation and clears dirty state. `nix run .#test` is ALL GREEN: 23,198
self-checks, every trace verify, and all pixel goldens.

**A1 packet 8 is complete.** `.pal` source saves now use the PAL atomic-write
primitive through a palette-specific save API and the real palette-window write
hook. An injected replacement failure preserves the previous valid palette
byte-for-byte, keeps the newer working document dirty, emits the named palette
failure, and summons the editor console; retry publishes a complete decodable
generation and clears dirty state. `nix run .#test` is ALL GREEN: 23,205
self-checks, every trace verify, and all pixel goldens.

**A1 packet 9 is complete.** `.ins` source saves now use the PAL atomic-write
primitive through an instrument-specific save API and the real synth-window
write hook. An injected replacement failure preserves the previous valid CINS
source byte-for-byte, including its embedded-PCM contract, keeps the newer
working instrument dirty, emits the named instrument failure, and summons the
editor console; retry publishes a complete decodable generation and clears
dirty state. `nix run .#test` is ALL GREEN: 23,212 self-checks, every trace
verify, and all pixel goldens.

**A1 packet 10 is complete.** `.song` source saves now use the PAL atomic-write
primitive through a song-specific save API and the real music-window write
hook. An injected replacement failure preserves the previous valid CSNG
arrangement byte-for-byte, keeps the newer working song dirty, emits the named
song failure, and summons the editor console; retry publishes a complete
decodable generation and clears dirty state. `nix run .#test` is ALL GREEN:
23,219 self-checks, every trace verify, and all pixel goldens.

**A1 packet 11 is complete.** Code/text-window source saves (`.lua`, `.md`,
`.txt`, `.json`, `.glsl`) now use atomic replacement. Injected rename failures
for every routed extension preserve the previous file byte-for-byte, keep the
newer working text dirty, emit the named path and failure, and summon the
console; retry publishes the complete source and clears dirty state. `nix run
.#test` is ALL GREEN: 23,239 self-checks, every trace verify, and all pixel
goldens.

**A1 packet 12 is complete.** Editor-created and imported assets now publish
with atomic replacement: raw and converted OS drops, map graybox `.tm`
generation, stock-instrument copies bound into songs, and sound-to-sampler
`.ins` creation. Image conversion encodes to memory before publication.
Failures name the target and cause, summon the console, publish no partial new
asset, preserve any previous valid generation, and leave map state unchanged
when its generated tilemap cannot be committed. Focused injected rename
failures cover all four paths. `nix run .#test` is ALL GREEN: 23,247
self-checks, every trace verify, and all pixel goldens.

**A1 packet 13 is complete.** `.ctrace` exports, rewind-history segment
containers, append-equivalent history index updates, and adoption-time index
compaction now use atomic replacement. A segment becomes authoritative only
after both its container and index entry are durable; an index failure removes
the unreachable orphan, retains the RAM generation, and disables further
spilling for the session. Errors include paths and causes. Injected failures
prove an interrupted trace export preserves its previous valid file, segment
failure publishes nothing, and index failure preserves the prior manifest;
corrupt indexed tails are rejected and removed. `nix run .#test` is ALL GREEN:
23,251 self-checks, every trace verify, and all pixel goldens.

**A1 packet 14 is complete.** Machine-local viewport/options `video.dat` and
explicit runtime snapshot saves now use atomic replacement and return named
errors. Video-setting failures are logged with their path and cause; snapshot
callers receive a `write snapshot failed` error suitable for their UI. Injected
rename failures prove both paths preserve the previous valid generation and a
retry publishes complete canonical settings/snapshot bytes. The persistence
audit found only intentional journal appends, explicit screenshot output,
compatibility sidecar helpers, and the current picker's project-creation paths
outside the atomic primitive. `nix run .#test` is ALL GREEN: 23,255
self-checks, every trace verify, and all pixel goldens.

**A1 packet 15 is complete, closing A1.** Standalone `.anim` and `.meta`
compatibility sidecar helpers now replace atomically and return errors naming
their target. Picker recents pruning uses the shared atomic recents API.
Project scaffolding moved to `cm.project`: it atomically publishes `main.lua`
first and the discoverability/authority file `project.lua` last, rolling back
all earlier output on either failure and never launching a partial project.
Injected rename failures prove prior sidecars and recents survive byte-for-byte,
both scaffold boundaries leave no partial project, and retries publish complete
decodable/discoverable results. The final write-site audit leaves only designed
journal appends, explicit user-requested screenshots, test/bootstrap fixture
writes, and player storage reserved for A4. `nix run .#test` is ALL GREEN:
23,264 self-checks, every trace verify, and all pixel goldens.

**A2 packet 1 is complete.** Dev/test, editor-release, and default-play trees
are now staged from explicit allowlist manifests. The public editor contains
only the picker and intentional `demo`; play exports contain the picker and
selected editable project. Both retain the engine/editor tooling, while the
named game launcher remains locked to play and a deliberate editor launcher is
available. A clean staging fixture proves `selftest`, `smoke`, `igcanvas`, and
`uigallery` cannot leak into either release shape and remain present in dev.
Linux and Windows dev/editor packages all build; `nix run .#test` is ALL GREEN:
23,264 self-checks, every trace verify, and all pixel goldens.

**A2 packet 2 is complete.** Linux editor and play trees now carry SDL3's
non-glibc runtime closure plus the Vulkan loader in `lib/`; every ELF resolves
through an `$ORIGIN`-relative RPATH and uses the standard x86_64 glibc loader,
with a build-time rejection for Nix-store RPATH/interpreter metadata. The
portable target builds its own SDL3 variant, restoring upstream Vulkan and X11
soname lookups instead of nixpkgs' absolute Nix-store `dlopen` substitutions.
The Linux packager consumes that portable tree and emits a 13 MiB demo tarball.
`tests/linux-portable-smoke.sh` extracts the archive as the only host input in
a stock Debian 13 container, verifies `ldd` resolves nothing from `/nix/store`,
makes the install tree read-only, and boots one headless frame under software
Vulkan/Xvfb with writable state confined to `/tmp`. Debian 13's Lavapipe
manifest is `lvp_icd.json`; using that clean-machine path completes the launch
with SDL's Vulkan GPU backend. The archive build, dependency checks, read-only
install check, and clean-container boot all pass.

**A2 packet 3 is complete.** The Windows object tree now links into two explicit
entrances: normal `cosmic.exe`, editor, and named-game launchers use the Windows
GUI subsystem and therefore do not create a terminal on double-click;
`bin/cosmic-console.exe` retains the console subsystem for diagnostics,
stdout/stderr, headless runs, and CI. Both dev and public-editor distributions
contain the pair, and Windows play packaging retains the console executable
while deriving its game/editor launchers from the GUI executable. Build-time PE
header checks reject either subsystem being wrong. The dev and editor cross
packages build, and a fresh demo Windows archive contains all three intended
entrances. `nix run .#test` is ALL GREEN: 23,264 self-checks, every trace
verify, and all pixel goldens.

**A2 packet 4 is complete.** The repository now carries one canonical cosmic2d
application mark as a 256 px PNG and a documented Windows ICO with 256, 128,
64, 48, 32, 24, and 16 px entries. `windres` binds the icon and English
`VERSIONINFO` into both GUI and console executables; copied editor/demo and
renamed play launchers retain it. A root `VERSION` supplies the shared
`0.1-alpha` derivation/resource string. Cross-build fixup rejects missing icon
group/version resources, incorrect strings, or subsystem regressions on every
staged entrance. Windows dev/editor builds, a fresh play archive inspection,
the Linux portable build, and `nix run .#test` all pass; the suite is ALL GREEN
at 23,287 self-checks with every trace and pixel golden matching.

**A2 packet 5 is complete.** PAL API v11 provides the fixed platform-native
per-user root and interactive process logs. `cm.crash` atomically publishes the
versioned `CCRP` report envelope; the C parachute and contained-error boundary
both feed it. Durable history has an exact atomic `CHST` stream identity that
survives adoption and rotates with the derived generation. KATs cover path,
codec, publication failure, identity creation/adoption/rotation/failure, and
durable lookup. Linux and native Windows selftests pass at 23,300 checks; the
complete deterministic suite, Windows dev build, and portable Linux build pass.

**A2 packet 6 is complete.** All artifact shapes carry exact pinned dependency
notices plus final extracted-tree and archive checksums under D068's explicit
unsigned-alpha policy. Packaging KATs, Linux/Windows dev and editor builds,
portable Linux, both play archives, a read-only portable boot, and the full
23,300-check deterministic suite pass.

**A2 packet 7 is complete.** Final editor and play archives now pass the
clean-machine Unicode/read-only/external-diagnostics matrix in Debian 13 and
native Windows 11. The proof runs with a restricted Unix identity and an NTFS
mutation-deny ACL, and it closed Linux execute-bit/root-RPATH defects plus the
Windows narrow-character self-location defect. Native selftests and the full
deterministic suite remain green at 23,300 checks.

**A2 packet 8 is complete, closing A2 (D070).** Validated project metadata now
generates the play archive's player README, quick start, root icon, and legal
links. Root Linux/Windows entrances boot the locked game; Windows exposes
project PE identity and Unicode delegation while PAL API v12 owns the live
window icon. Both fresh clean-machine matrices and the deterministic suite pass
at 23,302 self-checks.
