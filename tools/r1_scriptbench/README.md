# r1_scriptbench — the R1 script-engine spike harness (D047/D048)

The evidence behind ADRs **D047 + D048** (QuickJS vs Lua 5.4 — stay on
Lua). Kept re-runnable so the decision's revisit triggers can be re-tested
against a future QuickJS. D047 tested the nixpkgs pin (2025-09-13); D048
re-ran against upstream 2026-06-04 (fetch the tarball from
bellard.org/quickjs directly if nixpkgs lags again) — D048 has the current
numbers table.

## What it is

`host.c` is a dual-host: one binary embedding BOTH the vendored Lua 5.4.7
and QuickJS, exposing an identical native surface shaped like the engine's
hot paths (`buf:f32` named-buffer views, `quad`/`draw_quads`, `rect`,
monotonic `now`). Each workload exists as a `.lua` and a `.js` that are
literal translations of each other:

- `w_sim` — distilled player.step: buffer-backed entity physics, branches,
  tile collision (200 entities; the `chk` value doubles as a cross-VM
  float bit-exactness check — it must match between the two hosts).
- `w_quad` — quad-batch prep, 5000 quads/frame: A per-call, B bulk buffer
  writes, C (JS only) Float32Array direct writes.
- `w_ui` — immediate-mode churn: id-path strings, per-id retained state,
  hit tests, 2 rects + a formatted label per widget (garbage-heavy; GC
  pauses show in p99/max).
- `w_prng` — cm.rand's xoshiro256++: Lua 5.4 integer ops verbatim vs JS
  BigInt vs JS u32-pairs. All three must print the same ref stream.
- `det` — determinism audit (standalone interpreters): integer semantics,
  iteration order, NaN bits, float-chain bit patterns, GC observability.

## Reproduce

```sh
# 1. fetch + build QuickJS (bellard upstream; nixpkgs pins the release)
nix build nixpkgs#quickjs.src -o qjs-src && mkdir qjs && tar xf qjs-src -C qjs
cd qjs/quickjs-* && nix develop /opt/src/cosmic2d -c bash -c '
  V=$(cat VERSION)
  # -std=gnu11: releases >= 2026-06-04 use inline asm (Atomics.pause)
  for f in quickjs cutils libregexp libunicode dtoa; do
    cc -O2 -g -std=gnu11 -D_GNU_SOURCE -DCONFIG_VERSION=\"$V\" -fwrapv \
       -msse2 -mfpmath=sse -c -o $f.o $f.c
  done
  ar rcs libquickjs.a quickjs.o cutils.o libregexp.o libunicode.o dtoa.o
  make qjs'   # the standalone interpreter, for det.js

# 2. build the dual host (Lua objects come from the engine build: make -C pal)
cc -O2 -g -std=c11 -I<engine>/pal/vendor/lua/src -I<qjsdir> -o host host.c \
   <engine>/pal/build/lua_*.o <qjsdir>/libquickjs.a -lm -lpthread -ldl

# 3. run
for w in sim quad ui prng; do ./host lua w_$w.lua; ./host qjs w_$w.js; done
<engine>/pal/vendor/lua/... # det.lua runs under any Lua 5.4; det.js under qjs --std
```

The D047/D048 numbers were taken on a Ryzen 9 5900X under WSL2 (QuickJS
2025-09-13 and 2026-06-04 respectively), both VMs at `-O2`, Lua with the
pinned string-hash seed (the shipping configuration).
