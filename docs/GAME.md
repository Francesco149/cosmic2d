# cosmic — game design bible

The flagship game the engine is built around. This file is the design source
of truth; `PLAN.md` sequences the work, `DECISIONS.md` records the binding
calls (game identity D034, movement D035, narrative direction D042). The
**narrative layer** — story spine, cast, tone, and per-map quest design — lives
in **`STORY.md`** + **`docs/maps/`**. Where this doc proposes something not yet
ratified by the human it is marked **(proposal)** — those are the open questions
at the bottom.

> Status: design pass 1 (2026-06-27). Identity and the movement spec are
> ratified; the fiction spine, progression details and area list are proposals
> pending the human. Nothing here is implemented yet — the stock cartridge is
> still the old M3 platformer sandbox.

## 1. Identity

**cosmic** is a single-player 2D action-exploration game: cute, cozy, and
laced with occasional **cosmic dread**. You play the **antagonist mecha girl**
of the `cosmic` universe — this game is a spin-off / prequel (a villain-origin)
so the main `cosmic` project's story stays untouched and can run its own longer
cycle. The world is built MapleStory-style: **self-contained maps connected by
portals** (press Up to enter), an earth-side hub and regions plus one or two
areas **off-earth**.

The three things it wants to be, in priority:

1. **A movement toy.** The MapleStory-derived moveset (§4) is fun *by itself*.
   Just being in the hub chaining flash-jumps, hops and grapples should be
   addicting before a single enemy or quest exists.
2. **Power-fantasy spectacle.** Slice through excessive hordes of trash enemies
   in a satisfying way; knock over and throw physics props; break things.
   Bosses are the rare real challenge.
3. **Forgiving exploration.** A main questline you follow at your own pace, or
   ignore to explore; secrets and collectibles behind hidden portals, hard
   movement challenges, and maps you'd otherwise skip — but if you don't want
   to hunt, a radar ability later finds them for you.

On top sits a **Garry's-Mod-flavored physics sandbox** (§7): grab/float/
constrain/throw props you've unlocked by discovering them.

## 2. Fiction spine

A unifying concept so the systems read as one game instead of a pile of
mechanics. **The mecha girl's tech bends local reality**, and every system is a
facet of that one power:

- **Traversal** is reality-skipping: the flash-jump *sonic boom*, the
  appearance-shifting *teleport*, the *grapple* that reels space toward her.
- **The sandbox** is matter manipulation: the grab/float/constrain "tool" is
  her telekinetic/gravity field. **Prop-spawning unlocks in an area only after
  you finish its questlines** because she has stabilized that region's reality
  enough to reshape it freely (a diegetic reason, not a gate for its own sake).
- **The dread** is the cost and origin of that power — what she is becoming.
  The villain-origin arc *is* the escalation of the tech.

This makes the sandbox an expression of the protagonist rather than a bolt-on,
and gives the hub ("where she is strongest, reality is hers") its role as
permanent playground + testbed. **Ratified 2026-06-27.**

## 3. The gameplay loop

**Moment-to-moment (the verbs).** Movement is the core toy; mastery is
trajectory control — fine-tuning an arc with a late up-jump, a hop, a grapple
yank, a momentum-dumping teleport. Layered on top: hold-to-slice continuous
attack carving through hordes, and physics props to knock, throw, and break.
The loop is *flow*: traverse → slice → traverse, never stopping.

**Per-map (the session).** Enter a map by portal. It offers, in parallel:
a main-quest beat (optional, at your pace) and **exploration** — hidden
portals, movement-gated nooks, collectibles, breakables, hordes. Forgiveness
is a design rule: skip it all and a later **radar** ability surfaces what you
missed.

**Macro (progression).** The main questline threads through the areas (§9) at
the player's pace; boss fights are the challenge spikes between slice-through
trash. Finishing an area's questlines unlocks **prop-spawning** there (§7).
Collectibles/secrets and the sheer joy of movement drive replay and revisits.

**The hub.** A cozy MapleStory-style town: home base, permanent sandbox
playground, and the **testbed** where we (dev) and the player try new
mechanics/effects as they're added. It must be fun to simply exist in.

## 4. Movement — the heart  *(spec; see D035)*

Heavily inspired by MapleStory and **deliberately unconventional**: no precise
air control, you commit to arcs and fine-tune them. This wholesale replaces the
old platformer controller (variable-height jump + air-dive, D029/D030). It is
**pure cartridge controller policy** — no engine/PAL change — built on the
existing tilemap mover and one-way platforms (D024). Every value below is a
live knob under `doc.knobs.move` (persisted per D028, tunable in the inspector).
The **whole moveset is available from the start** — it's the toy; progression
gates *areas, auxiliary abilities and the sandbox* (§8), never the moves.

### Units & feel calibration

Distances are expressed in **character widths (CW)** and **character heights
(CH)** so they survive sprite/zoom recalibration. The anchor the art must hit:

- **6 CW ≈ ⅓ of the screen width** (the reach of an apex flash-jump). At the
  480 px reference FOV that's ~160 px, so **CW ≈ 26 px** — pick sprite size +
  zoom to match. CH is set by the character art (a humanoid ≈ 1.6–1.8 CW).
- **1 CH = jump apex height.**
- **~5 CH = a perfectly-timed jump → up-jump chain.**
- **1 vertical screenful = max grapple range.**

These are *relationships*; exact pixel knobs get calibrated once the real
sprite exists (a M-movement task). Timers are integer **frames** (60/s).

### The moveset

| # | Move | Trigger | Effect | Key knobs | Limits / VFX |
|---|------|---------|--------|-----------|--------------|
| 1 | **Walk** | hold ←/→ grounded | slow ground move, **~3 CW/s** | `walk_speed` | — / footstep dust |
| 2 | **Jump** | Jump, grounded | fixed apex **≈1 CH** (not variable-height), **airtime ≈ ⅔ s** (*M7 feel pass 3*); **hold Jump auto-repeats** on landing | `jump_h`, `jump_apex_t` | / takeoff puff |
| 3 | **Flash jump** | Jump again, airborne | upright forward dash; from apex lands **≈6 CW** forward. **Once per airtime** (re-arms on landing — *revised from "repeatable" during M7 feel testing*, 2026-06-28): the staple is now jump→flash→land→repeat. Minimal air control: holding the opposite dir right after only trims **~1 CW** | `fj_vx`, `fj_vy`, `air_accel` | **once per airtime**; blocked after an up-jump / **sonic-boom ring** |
| 4 | **Up jump** | hold Up + Jump, airborne | vertical boost (old double-jump, but up). **Fixed height** `upjump_h` (height-based, so it survives gravity retunes) — no extra height from holding; time it for less. Chain ≈ 5 CH total | `upjump_h` | **once per airtime**; **locks out flash-jump until landing** |
| 5 | **Hop** | E | diagonal up-forward boost (`hop_vx` forward, `hop_h` rise — height-based). Chains anywhere (before/after FJ or up-jump, or grounded) — the trajectory fine-tuner | `hop_vx`, `hop_h` | **once per airtime** (unless on flutter cooldown) / hop puff |
| 6 | **Flutter** | hold E after a hop, **into the fall** | **rhythmic hover** (*M7 feel pass 4*, 2026-06-28 — replaces the old slow-fall glide): once you've started FALLING (past the hop's apex) and you're still holding, a **small UPWARD mini-hop every `flutter_interval`** (≈ 2/s; a height-based up-kick `flutter_h` sized to **roughly HOLD altitude** with a gentle bob), **`flutter_boosts` times**, then **`hop_cd`**. Carried momentum is **cancelled** at hover-start (a flash-jump doesn't launch you far); each boost is a slight **up-forward diagonal** (`flutter_vx` « the vertical kick → <45° from up) so you drift forward a little — air drag keeps it gentle; hold a dir to steer. **A plain hop never triggers the cooldown** — released before you fall, it's a clean hop (the "must be falling" gate *is* the tap guard). `flutter_h` ↑ = more lift, ↓ = a gentle descent | `flutter_interval`(30f≈2/s), `flutter_boosts`(4), `flutter_h`(11), `flutter_vx`(30), `hop_cd`(600f) | cd persists / boost puffs + hover shimmer |
| 7 | **Grapple** | `q` (the spec's \` is the dev console) | the hook **EXTENDS** to a standable top above at ~1 screenful/s **under gravity**, then **reels** you in from the velocity you connect with (a jump-into-grapple has fallen to downward velocity, damping the reel). **Starting a grapple zeroes horizontal momentum.** *M7 feel pass 3*: the reel **stops ~`grapple_stop_ch` CH short** so the residual coasts up under gravity (a `grapple_min_t` floor keeps very-short grapples a small launch); the launch height is capped by **`grapple_vmax`** (≈ vmax²/2g). Max range ≈ 1 screenful; **prefers a target beyond ½ a screenful**. Jump **cancels** either phase; **arrows + teleport are locked out** during a grapple (a committed vertical move). Chains anywhere | `grapple_range_max/_min_pref`, `grapple_extend`, `grapple_accel`, `grapple_vmax`, `grapple_stop_ch`, `grapple_min_t`, `grapple_cd`(180f) | **once per airtime**; **3 s cd** / beam + pull |
| 8 | **Teleport** | R | blink **≈5 CW**, **lose all momentum**; direction **ALTERNATES forward/back** each blink (*revised from "forward" during M7 feel testing*, 2026-06-28) — tied to the A↔B flip. Max **2/s** (hold to spam). **Persistent A↔B mode**, flips each teleport, resets only on **map change**: **mode A forward + solid, mode B back + phases** through hazards / enemies / thin walls — appearance reflects the mode | `tp_dist`, `tp_min_interval`(30f) | clamps at solid walls, passes one-ways / **afterimage trail** + mode swap |
| 9 | **Continuous attack** | hold D | slice through enemies continuously as you move. Jump / flash-jump / up-jump allowed; **hop is disabled** while attacking | `attack_interval`, `attack_reach` | / slash particle trail + enemy death anim |

### Targeting & determinism

- **Grapple targeting** (deterministic, cartridge-side, the D030 pattern of
  reading the map through tilemap primitives): scan standable tops above the
  player within `[0, range_max]`; pick the **lowest** that is at least
  `range_min_pref` above; if none qualify, fall back to the **highest** within
  range so a close platform still works when nothing higher exists.
- **State**: per-airtime flags (hop used, up-jumped→FJ-locked, grapple used)
  reset on landing; the **teleport mode bit**, **hop cooldown timer**, and
  **grapple cooldown timer** persist (mode resets on map change) — all live in
  a player named buffer or `doc.knobs`, never the Lua heap.
- Determinism class is identical to the current controller: integer-frame
  timers, pure-IEEE tilemap scans, engine PRNG only, no wall clock, no libm.
  Re-cut the attract demo + goldens against the new moveset (D025).

### Platforms

Most platforms are **jump-through** (one-way, no solid sides) so you never
snag. Only the map **bottom and top** are solid (rare exceptions), and the
bottom is usually **flat**. This is exactly the engine's existing one-way
tilemap (D024) — bottom/top rows solid, interior rows one-way.

## 5. Combat & spectacle

- **Trash enemies are slice-through**: low HP, spawned in excess, destroyed in
  a satisfying pop. The feel target is a *mix* of slash particle trails (the
  continuous attack, #9) and a juicy **death animation** (dissolve / scatter
  into procedural particles). This is the power-fantasy core.
- **Game feel**: micro-hitstop on a kill, screen shake/flash, and a sense of
  building momentum/combo as you carve a line through a crowd. Every parameter
  a knob.
- **Breakables & rigid-body props**: knock them over, throw them, smash them —
  needs the rotational-physics milestone (M-physics).
- **Drops**: trash drops **currency** and **farmables** — slicing a horde *is*
  farming, closing the spectacle→reward loop (§8). Drops roll on the engine
  PRNG (deterministic).
- **Bosses are the real fight**: **~3–5 hand-crafted set-pieces** (not a
  bestiary) at major story beats, telegraphed patterns, actual difficulty — the
  deliberate contrast to trash. HP + natural regen exist; a boss is **cheese-
  able** by farming potions that out-regen the natural rate, for players who'd
  rather skip the challenge (the forgiveness pillar, §8).

## 6. The hub

Central cozy town. Home base + portal nexus to the areas + **permanent
sandbox** (prop-spawning always on here) + **the testbed** for new
mechanics/effects. Designed to reward just messing around. This is also where
*we* dogfood every new system as it lands (it replaces the old M3/M4 "platformer
sandbox" as the stock cartridge).

**Two hubs for now**: one on earth, one at the cosmic finale (§9). Hubs are the
**respawn points** — death returns you to the nearest one (§8).

## 7. Sandbox — 2D Garry's Mod *(scope: a few deep mechanics, not Minecraft)*

A "tool" / ability, framed (§2) as the mecha girl's matter field. Like gmod,
there's **no hold animation** — you grab a thing and it **floats**:

- **Grab / float / move / rotate / throw** a prop.
- **Constrain** props together — a small set of joint types (weld, axle/hinge,
  rope, maybe spring). The 2D fuse of gmod + Tears-of-the-Kingdom Ultrahand.
- **Prop discovery → unlock**: interact with a prop in the world and it becomes
  a **spawnable** prop.
- **Where you can spawn**: the hub always; any other area only after you've
  **completed all its questlines** (§2's diegetic reason).

Depends on the rotational-physics solver (M-physics). Guardrail per the human:
keep it to a few simple, satisfying mechanics — addicting, not a survival game.

## 8. Forgiveness, economy & navigation

The pillar: **as forgiving as you want it to be.** Everything that smooths the
game is *optional* and *dual-sourced* — earn it by playing, or buy it early by
farming; never required either way.

**Secrets.** Collectibles and secrets hide behind hidden portals, movement
challenges, and maps you skip during the main story. Revisiting a cleared map
stays fun on movement + sandbox alone.

**The optional economy.** Trash enemies drop **currency** and **farmables**, so
slicing a horde *is* farming (the spectacle→reward loop, §5). Farming is **100%
optional** — every purchasable is *also* earned naturally through the story and
side quests; the shop just lets you get things **early**. You spend on:

- **Auxiliary abilities & upgrades** — a layer *on top of* the always-available
  moveset (§4): the **radar** (reveals nearby missables/secrets, for players
  who don't want to hunt), **extended flutter range** (reach areas otherwise
  unreachable), and more as we design them. These gate *optional* areas — a
  light, opt-out metroidvania layer — never the core toy.
- **Cheese consumables** — HP + natural regen exist; **potions that out-regen
  the natural rate** let you trivialize a boss you'd rather not fight. Farming
  to skip challenge is a legitimate, intended path.

**Death & respawn.** Dying returns you to the **nearest hub** (for now: earth +
cosmic finale, §6/§9). **No progress rollback** — currency, unlocks, quest
progress and found secrets all persist (the save is persistent + autosaved).
The **walk back** to where you died is intended gameplay: movement + spectacle
make traversal the "penalty," and it's *fun*. But it's **opt-out** — the world
map offers **fast-travel** to any map you've already visited.

**Navigation.** A **world map** (visited maps + fast-travel) and a **helper
arrow** pointing toward the objective of your **currently-selected quest** — the
"follow the story at your pace, or wander off" aid for a non-linear world.

**Stats & verifiable challenge runs** *(later)*. Track per-save stats — mobs
killed, currency farmed, deaths, secrets found, time — so players can flex
challenge playthroughs (no-death, no-farm, low%). Determinism is a gift here: a
recorded trace replays byte-exact, so a challenge run can be **provable**, not
just claimed — the engine's regression infra doubles as an anti-cheat oracle.

## 9. Areas & story

- **Earth-side hub + regions**, plus a **cosmic finale** area off-earth where
  the dread peaks (the title's namesake). **Two hubs**: earth and the cosmic
  finale (the respawn points, §6/§8). Reachable via portals + the world map.
- **Main story = a big questline** you follow at your pace or set aside to
  explore. Villain-origin arc tracking the escalation of the reality tech (§2).
- Per-map: a main-quest beat + optional secrets/challenges/hordes.
- Content is authored **with the human**: the human makes sprites; the agent
  designs map layouts and stylish scenery from simple primitives and writes the
  story / quests / challenges. This is the long tail (M-content), interleaved
  once the hub + movement exist.

**First arc drafted (2026-06-29, D042):** the story/cast bible is **`STORY.md`**;
the opening maps + quests are one-pagers in **`docs/maps/`** — **Rim Hub**
("First Survey": hub + tutorial) → **South Trail** ("The Long Light": first
hordes + Gemma's debut) → **Whisper Gulch** ("The Whisper Below": grapple gym +
the first cosmic-dread beat). Protagonist **Vesper** is written as a *tsundere
villain-origin*; **Gemma** (chuuni succubus-cosplaying rival architect) is a
recurring comedic antagonist; **Lumi** is the human hub idol (+ an early
side-quest); mobs are reality-leak **cosmic creatures**.

## 10. Art direction

Target style: **Wadanohara-like** (refs: `F:\Pictures\pixel-art-ref`) — cute,
cozy, soft — **minus the gore/horror**, with the occasional touch of cosmic
dread from the plot. Everything is pixel art.

- **Coloring is simple**; the most sophisticated technique is **gradients**
  (some lines and fills are gradients). The in-engine **sprite editor** must
  comfortably author character **sprites and portraits** with gradients — its
  design + build plan is **STUDIO.md** (M10, ADR D040), with non-destructive
  gradient fills as a first-class feature.
- **Procedural sprites** for particles, liquids, and dust (the M-art procgen:
  noise/shape/gradient/bevel/blend) — feeds slash trails, the teleport
  afterimage, sonic-boom rings, death scatter, liquids.
- **LUT color grading** (M-look) tunes each area's mood without re-drawing
  sprites — warm cozy hub vs. cool luminous dread out in space.
- **Pipeline**: GPT image-gen → reference/placeholder → the human hand-pixels
  the real art in the Wadanohara style. Character refs already exist for the
  antagonist / companion / architect / bunny-girl.

### GPT reference-prompt suggestions

GPT output isn't the final pixel art — these prompts aim for *style, mood, and
composition* the human then pixels. Generic suffix to append: *"flat
orthographic side view, neutral background, simple readable shapes that
translate to pixel art, pastel palette with one cool accent color, soft cel
shading with gentle gradients."*

- **Protagonist (mecha girl)**: "Full-body character reference of a cute
  teenage 'mecha girl' antagonist: sleek white-and-gold mechanical bodysuit
  with subtle glowing cyan accents, soft rounded anime proportions, calm
  melancholy expression, faint constellation etchings in the armor; cozy but a
  quiet uncanny/cosmic-dread undertone. Front + 3/4 + back."
- **Hub town**: "Cozy 2D side-scrolling fantasy town at dusk: layered parallax
  (foreground platforms, mid buildings with warm windows, distant hills), soft
  gradient sky, floating lanterns; Wadanohara-like cute-cozy mood."
- **Cosmic-dread area**: "An eerie-beautiful otherworldly region adrift in
  space: pale alien flora, drifting geometric ruins, a vast quiet watching
  presence in a gradient star-field sky; cute-translatable shapes but a calm
  cosmic-dread atmosphere, no gore; cool desaturated palette, one luminous
  accent."
- **Trash enemy**: "Small cute 'corrupted' creature for a 2D action game,
  simple readable silhouette, soft rounded shapes, single accent glow, designed
  to pop satisfyingly when destroyed."

## 11. Resolved & still-open (2026-06-27)

**Ratified this session** (D034): the fiction spine (§2); **earth + a cosmic
finale**, two hubs (§9); **~3–5 hand-crafted bosses** (§5); the **full moveset
from the start** (§4); the teleport's **phase-shift** modes (§4 #8, mode A
solid / mode B phases through hazards-enemies-thin-walls); and the **hub-respawn
+ optional-economy** forgiveness model (§8) — currency/farmable drops, dual-
sourced abilities (radar, flutter-range), cheese consumables, world map + quest
arrow, no-rollback death, verifiable challenge stats.

**Still open — deferred to their milestones, not blocking:**

- Exact **ability/upgrade roster** + currency/farmable economy specifics (M13
  economy; M12 combat). Radar and flutter-range are the seeds.
- The **boss roster** — who the ~3–5 are and their mechanics (M12).
- **HP / regen / damage** tuning — knobs dialed at M12 with feel sign-off.
- Hub/area **count growth** beyond the first two as the world expands.
