// W3 UI immediate-mode churn — literal translation of w_ui.lua.
// Retained state in a Map keyed by id string (the idiomatic JS equivalent).
"use strict";
const floor = Math.floor;
const NW = 300, FRAMES = 240;

const state = new Map();
let path = "root";

function widget(label, i, f, mx, my) {
  const id = path + "/" + label + i;
  let st = state.get(id);
  if (!st) { st = { scroll: 0, open: false, t: 0 }; state.set(id, st); }
  const x = (i % 3) * 130 + 8;
  const y = floor(i / 3) * 22 + 30 - st.scroll;
  const w = 120, h = 18;
  const hot = mx >= x && mx < x + w && my >= y && my < y + h;
  if (hot) st.t = st.t + 1;
  rect(x, y, w, h, hot ? 0x3a3a52 : 0x2a2a3a);
  rect(x + 2, y + 2, w - 4, h - 4, 0x1a1a24);
  const txt = label + i + ": " + (st.t * 0.1).toFixed(1);
  let tw = 0;
  for (let k = 0; k < txt.length; k++) tw += (txt.charCodeAt(k) < 128) ? 6 : 8;
  st.scroll = (st.scroll + (hot ? 1 : 0)) % 40;
  return tw;
}

const times = new Array(FRAMES);
let acc0 = 0;
for (let f = 1; f <= FRAMES; f++) {
  const t0 = now();
  const mx = (f * 3) % 400;
  const my = (f * 2) % 300;
  let acc = 0;
  for (let i = 0; i < NW; i++) {
    if (i % 50 === 0) path = "root/panel" + floor(i / 50);
    acc += widget("w", i, f, mx, my);
  }
  path = "root";
  times[f - 1] = now() - t0;
  if (f === 1) acc0 = acc;
}

times.sort((a, b) => a - b);
let sum = 0;
for (let i = 0; i < FRAMES; i++) sum += times[i];
emit(`w_ui ${NW} widgets: avg ${(sum / FRAMES / 1000).toFixed(1)} us  p50 ${(times[floor(FRAMES / 2) - 1] / 1000).toFixed(1)}  p99 ${(times[floor(FRAMES * 0.99) - 1] / 1000).toFixed(1)}  max ${(times[FRAMES - 1] / 1000).toFixed(1)}`);
