// determinism audit, QuickJS side (run with qjs — has print)
"use strict";
function bits(v) {
  const b = new ArrayBuffer(8);
  new Float64Array(b)[0] = v;
  const u = new Uint32Array(b);
  return u[1].toString(16).padStart(8, "0") + u[0].toString(16).padStart(8, "0");
}

print("== integer semantics ==");
print("2^53+1 exact:", 9007199254740993 === 9007199254740992 ? "COLLAPSES" : "EXACT",
      9007199254740993);
print("64-bit wrap: n/a — Number rounds silently; BigInt needed");
print("bitwise is 32-bit: (2**32+1)|0 =", (2 ** 32 + 1) | 0);
print("trunc div: Math.trunc(-7/3) =", Math.trunc(-7 / 3), "  mod: -7 % 3 =", -7 % 3);
print("int/float distinct:", typeof 3, typeof 3.0, 3 === 3.0, "(no integer subtype)");
print("String: 3 ->", String(3), "  3.0 ->", String(3.0), "(3.0 collapses to '3')");

print("== iteration order ==");
const t = {};
t.zebra = 1; t.alpha = 2; t[2] = 3; t[1] = 4; t.mid = 5;
print("Object keys:", Object.keys(t).join(","),
      "(spec: int-like ascending, then insertion)");
const m = new Map([["zebra", 1], ["alpha", 2], [2, 3], [1, 4], ["mid", 5]]);
print("Map keys:", [...m.keys()].join(","), "(spec: pure insertion order)");

print("== NaN / float bits ==");
const nan = 0 / 0;
print("NaN !== NaN:", nan !== nan);
print("NaN bits via typed array:", bits(nan));
// payload preservation: write a non-canonical NaN pattern, read back
{
  const b = new ArrayBuffer(8);
  const u = new Uint32Array(b);
  u[1] = 0x7ff80000; u[0] = 0xdeadbeef;      // NaN with payload
  const v = new Float64Array(b)[0];
  const b2 = new ArrayBuffer(8);
  new Float64Array(b2)[0] = v;                // round-trip through a JS value
  const u2 = new Uint32Array(b2);
  print("NaN payload round-trip:",
        u2[1].toString(16) + u2[0].toString(16),
        (u2[1] === 0x7ff80000 && u2[0] === 0xdeadbeef) ? "PRESERVED" : "CANONICALIZED");
}
print("0.1+0.2 bits:", bits(0.1 + 0.2));
print("1e16+1 bits:", bits(1e16 + 1));
let x = 0.1;
for (let i = 1; i <= 100; i++) x = x * 1.0000001 + 0.001;
print("chain bits:", bits(x));
print("sqrt(2) bits:", bits(Math.sqrt(2)));

print("== GC observability ==");
let acc = 0;
for (let i = 1; i <= 100000; i++) {
  const tt = [i, i * 2];
  acc = acc + tt[0] + tt[1];
  if (i === 50000) std.gc();
}
print("alloc loop acc (GC forced mid-way):", acc);
