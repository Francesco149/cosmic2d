// W2 quad-batch prep — literal translation of w_quad.lua, plus
// C: Float32Array direct writes (the typed-array path Lua has no equivalent of)
"use strict";
const floor = Math.floor;
const NQ = 5000, FRAMES = 300;
const TW = 256, TH = 256;

function stats(times, label) {
  times.sort((a, b) => a - b);
  let sum = 0;
  for (let i = 0; i < times.length; i++) sum += times[i];
  emit(`${label}: avg ${(sum / times.length / 1000).toFixed(1)} us  p50 ${(times[floor(times.length / 2) - 1] / 1000).toFixed(1)}  p99 ${(times[floor(times.length * 0.99) - 1] / 1000).toFixed(1)}  max ${(times[times.length - 1] / 1000).toFixed(1)}`);
}

// A: per-call
let times = [];
for (let f = 1; f <= FRAMES; f++) {
  const t0 = now();
  const cam = f * 0.5;
  for (let i = 0; i < NQ; i++) {
    const tx = (i % 100) * 8 - cam;
    const ty = floor(i / 100) * 8;
    const u = (i % 32) * 8;
    quad(tx, ty, 8, 8, u / TW, 0, (u + 8) / TW, 8 / TH, 1, 1, 1, 1);
  }
  draw_quads(NQ);
  times.push(now() - t0);
}
stats(times, "w_quad A percall");

// B: bulk buffer writes via C call (same shape as Lua)
times = [];
for (let f = 1; f <= FRAMES; f++) {
  const t0 = now();
  const cam = f * 0.5;
  let o = 0;
  for (let i = 0; i < NQ; i++) {
    const tx = (i % 100) * 8 - cam;
    const ty = floor(i / 100) * 8;
    const u = (i % 32) * 8;
    buf.f32(o, tx);            buf.f32(o + 1, ty);
    buf.f32(o + 2, 8);         buf.f32(o + 3, 8);
    buf.f32(o + 4, u / TW);    buf.f32(o + 5, 0);
    buf.f32(o + 6, (u + 8) / TW); buf.f32(o + 7, 8 / TH);
    buf.f32(o + 8, 1); buf.f32(o + 9, 1); buf.f32(o + 10, 1); buf.f32(o + 11, 1);
    o += 12;
    if (o >= 60000) o = 0;
  }
  draw_quads(NQ);
  times.push(now() - t0);
}
stats(times, "w_quad B bufwrite");

// C: typed-array direct writes into the SAME scratch the C side owns
const s = new Float32Array(scratch_ab);
times = [];
for (let f = 1; f <= FRAMES; f++) {
  const t0 = now();
  const cam = f * 0.5;
  let o = 0;
  for (let i = 0; i < NQ; i++) {
    const tx = (i % 100) * 8 - cam;
    const ty = floor(i / 100) * 8;
    const u = (i % 32) * 8;
    s[o] = tx;            s[o + 1] = ty;
    s[o + 2] = 8;         s[o + 3] = 8;
    s[o + 4] = u / TW;    s[o + 5] = 0;
    s[o + 6] = (u + 8) / TW; s[o + 7] = 8 / TH;
    s[o + 8] = 1; s[o + 9] = 1; s[o + 10] = 1; s[o + 11] = 1;
    o += 12;
    if (o >= 60000) o = 0;
  }
  draw_quads(NQ);
  times.push(now() - t0);
}
stats(times, "w_quad C f32array");
