// W4 PRNG: xoshiro256++ in JS, two ways.
//  A) BigInt with 64-bit masking — direct port, arbitrary-precision cost.
//  B) u32-pair (hi/lo) — the realistic port: >>> / | / ^ are exact 32-bit ops.
// Both must reproduce cm.rand's exact stream (ref line printed by w_prng.lua).
"use strict";
const M64 = 0xffffffffffffffffn;

// ---- A: BigInt ----
let S0, S1, S2, S3;
function rotlB(x, k) { return ((x << k) | (x >> (64n - k))) & M64; }
function splitmixB(z) {
  z = (z + 0x9e3779b97f4a7c15n) & M64;
  let r = z;
  r = ((r ^ (r >> 30n)) * 0xbf58476d1ce4e5b9n) & M64;
  r = ((r ^ (r >> 27n)) * 0x94d049bb133111ebn) & M64;
  return [z, r ^ (r >> 31n)];
}
function seedB(n) {
  let out;
  [n, out] = splitmixB(n); S0 = out;
  [n, out] = splitmixB(n); S1 = out;
  [n, out] = splitmixB(n); S2 = out;
  [n, out] = splitmixB(n); S3 = out;
}
function u64B() {
  const result = (rotlB((S0 + S3) & M64, 23n) + S0) & M64;
  const t = (S1 << 17n) & M64;
  S2 = S2 ^ S0;
  S3 = S3 ^ S1;
  S1 = S1 ^ S2;
  S0 = S0 ^ S3;
  S2 = S2 ^ t;
  S3 = rotlB(S3, 45n);
  return result;
}

seedB(12345n);
let refs = [];
for (let i = 0; i < 4; i++) refs.push(u64B().toString(16).padStart(16, "0"));
emit("w_prng bigint ref: " + refs.join(" "));

const N = 2000000;
seedB(12345n);
let accB = 0n;
let t0 = now();
for (let i = 0; i < N; i++) accB ^= u64B();
let dt = now() - t0;
emit(`w_prng js-bigint u64: ${(dt / N).toFixed(1)} ns/draw  (acc ${accB.toString(16).padStart(16, "0")})`);

seedB(12345n);
let faccB = 0.0;
t0 = now();
for (let i = 0; i < N; i++) faccB += Number(u64B() >> 11n) * 2 ** -53;
dt = now() - t0;
emit(`w_prng js-bigint float: ${(dt / N).toFixed(1)} ns/draw  (facc ${(faccB / N).toFixed(6)})`);

// ---- B: u32 pairs ----
// state as 8 u32s; ops built from >>> ^ | & and >>> 0 normalization
let h0, l0, h1, l1, h2, l2, h3, l3;

function seedP(n) {
  // seeding is cold — reuse the BigInt splitmix, split into pairs
  seedB(n);
  h0 = Number(S0 >> 32n) >>> 0; l0 = Number(S0 & 0xffffffffn) >>> 0;
  h1 = Number(S1 >> 32n) >>> 0; l1 = Number(S1 & 0xffffffffn) >>> 0;
  h2 = Number(S2 >> 32n) >>> 0; l2 = Number(S2 & 0xffffffffn) >>> 0;
  h3 = Number(S3 >> 32n) >>> 0; l3 = Number(S3 & 0xffffffffn) >>> 0;
}

// returns [hi, lo] via out params trick: module-level temps (no tuple alloc)
let RH = 0, RL = 0;
function add64(ah, al, bh, bl) {
  const lo = (al + bl) >>> 0;                 // al+bl < 2^33, exact in double
  const carry = lo < al ? 1 : 0;              // wrapped iff lo < either addend
  RH = (ah + bh + carry) >>> 0; RL = lo;
}
function rotl64(ah, al, k) {
  if (k === 32) { RH = al; RL = ah; return; }
  if (k > 32) { const j = k - 32; const t = ah; ah = al; al = t; k = j; }
  RH = ((ah << k) | (al >>> (32 - k))) >>> 0;
  RL = ((al << k) | (ah >>> (32 - k))) >>> 0;
}
function u64P() {
  // result = rotl(s0 + s3, 23) + s0
  add64(h0, l0, h3, l3);
  rotl64(RH, RL, 23);
  add64(RH, RL, h0, l0);
  const rh = RH, rl = RL;
  // t = s1 << 17
  const th = ((h1 << 17) | (l1 >>> 15)) >>> 0;
  const tl = (l1 << 17) >>> 0;
  h2 = (h2 ^ h0) >>> 0; l2 = (l2 ^ l0) >>> 0;
  h3 = (h3 ^ h1) >>> 0; l3 = (l3 ^ l1) >>> 0;
  h1 = (h1 ^ h2) >>> 0; l1 = (l1 ^ l2) >>> 0;
  h0 = (h0 ^ h3) >>> 0; l0 = (l0 ^ l3) >>> 0;
  h2 = (h2 ^ th) >>> 0; l2 = (l2 ^ tl) >>> 0;
  rotl64(h3, l3, 45); h3 = RH; l3 = RL;
  RH = rh; RL = rl;
}

function hex8(v) { return v.toString(16).padStart(8, "0"); }
seedP(12345n);
refs = [];
for (let i = 0; i < 4; i++) { u64P(); refs.push(hex8(RH) + hex8(RL)); }
emit("w_prng u32pair ref: " + refs.join(" "));

seedP(12345n);
let aH = 0, aL = 0;
t0 = now();
for (let i = 0; i < N; i++) { u64P(); aH = (aH ^ RH) >>> 0; aL = (aL ^ RL) >>> 0; }
dt = now() - t0;
emit(`w_prng js-u32pair u64: ${(dt / N).toFixed(1)} ns/draw  (acc ${hex8(aH)}${hex8(aL)})`);

seedP(12345n);
let faccP = 0.0;
t0 = now();
for (let i = 0; i < N; i++) {
  u64P();
  // u64 >> 11 == hi * 2^21 + (lo >>> 11): 53 bits, exact in a double
  faccP += (RH * 2097152 + (RL >>> 11)) * 2 ** -53;
}
dt = now() - t0;
emit(`w_prng js-u32pair float: ${(dt / N).toFixed(1)} ns/draw  (facc ${(faccP / N).toFixed(6)})`);
