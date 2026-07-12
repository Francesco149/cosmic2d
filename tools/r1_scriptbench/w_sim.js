// W1 sim tick — literal translation of w_sim.lua
"use strict";
const floor = Math.floor, max = Math.max, min = Math.min;
const DT = 1 / 60;
const NE = 200;
const FRAMES = 600;
const STRIDE = 32;

const RW = 50, RH = 22, TS = 8;
const sol = new Array(RW * RH).fill(0);
for (let tx = 0; tx < RW; tx++) { sol[(RH - 1) * RW + tx] = 1; sol[tx] = 1; }
for (let ty = 0; ty < RH; ty++) { sol[ty * RW] = 1; sol[ty * RW + RW - 1] = 1; }
for (let tx = 10; tx <= 18; tx++) sol[15 * RW + tx] = 1;
for (let tx = 24; tx <= 32; tx++) sol[11 * RW + tx] = 1;
for (let tx = 36; tx <= 44; tx++) sol[7 * RW + tx] = 1;

function solid_at(px, py) {
  const tx = floor(px / TS), ty = floor(py / TS);
  if (tx < 0 || tx >= RW || ty < 0 || ty >= RH) return true;
  return sol[ty * RW + tx] === 1;
}

function approach(v, target, step) {
  if (v < target) return min(v + step, target);
  return max(v - step, target);
}

for (let e = 0; e < NE; e++) {
  const b = e * STRIDE;
  buf.f32(b + 0, 40 + (e % 40) * 8);
  buf.f32(b + 1, 24 + floor(e / 40) * 16);
  buf.f32(b + 4, 1);
}

const W = 6, H = 10;
const walk_speed = 90, walk_accel = 900, fric = 1200;
const g_rise = 1800, g_fall = 2200, v0 = -210, vmax = 260;
const coyote_n = 6, jbuf_n = 5;

function step_entity(e, f) {
  const b = e * STRIDE;
  let x = buf.f32(b + 0), y = buf.f32(b + 1);
  let vx = buf.f32(b + 2), vy = buf.f32(b + 3);
  let facing = buf.f32(b + 4);
  let grounded = buf.f32(b + 5) === 1;
  let coyote = buf.f32(b + 6), jbuf = buf.f32(b + 7);
  let hop_cd = buf.f32(b + 8);
  let flutter_t = buf.f32(b + 9);
  let tp_cd = buf.f32(b + 10);
  let attack_t = buf.f32(b + 11);
  let squash_t = buf.f32(b + 12), stretch_t = buf.f32(b + 13);

  const ph = f + e * 7;
  const dir = (floor(ph / 16) % 3) - 1;
  let press = (ph % 37) === 0;

  if (dir !== 0) facing = dir;
  if (grounded) {
    if (dir !== 0) vx = approach(vx, dir * walk_speed, walk_accel * DT);
    else vx = approach(vx, 0, fric * DT);
    coyote = coyote_n;
  } else {
    if (dir !== 0) vx = approach(vx, dir * walk_speed, walk_accel * 0.6 * DT);
    coyote = max(coyote - 1, 0);
  }

  if (press) jbuf = jbuf_n; else jbuf = max(jbuf - 1, 0);
  if (jbuf > 0 && coyote > 0) {
    vy = v0; jbuf = 0; coyote = 0; grounded = false;
    stretch_t = 0.12;
  }

  vy = min(vy + (vy < 0 ? g_rise : g_fall) * DT, vmax);

  let nx = x + vx * DT;
  if (vx > 0) {
    if (solid_at(nx + W, y) || solid_at(nx + W, y + H - 1)) {
      nx = floor((nx + W) / TS) * TS - W - 0.001; vx = 0;
    }
  } else if (vx < 0) {
    if (solid_at(nx, y) || solid_at(nx, y + H - 1)) {
      nx = (floor(nx / TS) + 1) * TS + 0.001; vx = 0;
    }
  }
  x = nx;
  let ny = y + vy * DT;
  const was = grounded;
  grounded = false;
  if (vy > 0) {
    if (solid_at(x, ny + H) || solid_at(x + W, ny + H)) {
      ny = floor((ny + H) / TS) * TS - H - 0.001;
      vy = 0; grounded = true;
      if (!was) squash_t = 0.10;
    }
  } else if (vy < 0) {
    if (solid_at(x, ny) || solid_at(x + W, ny)) {
      ny = (floor(ny / TS) + 1) * TS + 0.001; vy = 0;
    }
  }
  y = ny;

  hop_cd = max(hop_cd - DT, 0);
  tp_cd = max(tp_cd - DT, 0);
  attack_t = max(attack_t - DT, 0);
  squash_t = max(squash_t - DT, 0);
  stretch_t = max(stretch_t - DT, 0);
  flutter_t = grounded ? 0 : max(flutter_t - DT, 0);

  buf.f32(b + 0, x); buf.f32(b + 1, y);
  buf.f32(b + 2, vx); buf.f32(b + 3, vy);
  buf.f32(b + 4, facing);
  buf.f32(b + 5, grounded ? 1 : 0);
  buf.f32(b + 6, coyote); buf.f32(b + 7, jbuf);
  buf.f32(b + 8, hop_cd); buf.f32(b + 9, flutter_t);
  buf.f32(b + 10, tp_cd); buf.f32(b + 11, attack_t);
  buf.f32(b + 12, squash_t); buf.f32(b + 13, stretch_t);
}

for (let f = 1; f <= 60; f++) for (let e = 0; e < NE; e++) step_entity(e, f);

const times = new Array(FRAMES);
for (let f = 1; f <= FRAMES; f++) {
  const t0 = now();
  for (let e = 0; e < NE; e++) step_entity(e, f);
  times[f - 1] = now() - t0;
}

times.sort((a, b) => a - b);
let sum = 0;
for (let i = 0; i < FRAMES; i++) sum += times[i];
let chk = 0;
for (let e = 0; e < NE; e++) chk += buf.f32(e * STRIDE) + buf.f32(e * STRIDE + 1);
emit(`w_sim ${NE} entities: avg ${(sum / FRAMES / 1000).toFixed(1)} us  p50 ${(times[floor(FRAMES / 2) - 1] / 1000).toFixed(1)}  p99 ${(times[floor(FRAMES * 0.99) - 1] / 1000).toFixed(1)}  max ${(times[FRAMES - 1] / 1000).toFixed(1)}  (chk ${chk.toFixed(3)})`);
