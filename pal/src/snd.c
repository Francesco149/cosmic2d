/* snd.c — the audio core (R9b, docs/AUDIO.md §2 / ADR D058).
 *
 * Two banks over one fixed-point kernel:
 *
 * - The SIM bank: every byte of synth state lives in the named buffer
 *   "snd.bank" (created on first use), so snapshots/traces/rewind carry
 *   the mix like any sim state. pal.snd_* mutate it at call time
 *   (commands are frame-locked by construction — the sim emits them
 *   inside the step); pal.snd_render(), called once per sim step by
 *   cm.main, advances exactly SND_FRAME samples: PCM is a pure function
 *   of (bank bytes) frame to frame. Rendered PCM goes to the output
 *   FIFO when the device is up (live sessions) and into the FNV hash
 *   accumulator always (the PCM goldens). Headless never opens a
 *   device: goldens can't hear by construction. No bank buffer = a
 *   true no-op (pre-R9 projects and goldens are byte-identical).
 *
 * - The EDITOR bank (x_snd_ed_*): the audition path — C-static state
 *   rendered IN the audio callback (zero-latency key presses), fed by
 *   a lock-free SPSC command ring. Never a named buffer, never
 *   recorded, never snapshotted: render-only the way imgui is (D036).
 *
 * Kernel discipline (ARCHITECTURE.md determinism rules, applied to C):
 * integer/fixed-point only — u32 phase accumulators, the committed
 * SINE/NOTE_INC/RATIO/PAN tables (snd_tab.h; no libm at build or run
 * time), Q24 envelopes, i32 mixing. Bit-exact across platforms by
 * construction.
 *
 * The voice: 4 operators with selectable waveforms (sine / square /
 * pulse25 / pulse12.5 / saw / triangle / LFSR noise + short mode — a
 * single unmodulated op IS a gameboy channel), 8 OPN-style algorithms,
 * feedback on op 0; or a sampler voice (mono i16 named-buffer PCM,
 * root note, loop points, 32.32 stepping). 32 voices per bank,
 * deterministic stealing (oldest note-on frame).
 */
#include "pal.h"
#include "snd_tab.h"

#include <string.h>

#include "lauxlib.h"

/* ---- the frame lock (AUDIO.md §2.1) ---- */
#define SND_RATE 48000
#define SND_FRAME 800 /* samples per 60 Hz sim frame — exactly */
#define SND_PATCHES 64
#define SND_VOICES 32

/* tuning constants (one place; revisit by ear in R9c) */
#define SND_MOD_SHIFT 16 /* modulator output -> phase offset */
#define SND_MIX_SHIFT 2  /* master headroom before the clamp */

/* ---- the bank layout (versioned; snd.bank byte-for-byte) ---- */

#pragma pack(push, 1)
typedef struct { /* 16 bytes per operator */
  uint8_t wave;  /* 0 sine 1 square 2 pulse25 3 pulse12 4 saw 5 tri
                    6 noise 7 noise-short */
  uint8_t coarse;  /* freq ratio: 0 = x0.5, 1..15 = xN */
  int8_t fine;     /* +-63, x(1024+fine)/1024 */
  uint8_t level;   /* 0..255 output/mod level */
  uint16_t a_ms, d_ms, r_ms;
  uint8_t s;       /* sustain level 0..255 */
  int8_t detune;   /* +-63, x(16384+detune)/16384 */
  uint8_t opflags; /* bit0 = fixed frequency */
  uint8_t pad0;
  uint16_t fixed_hz;
} SndOp;

typedef struct { /* 80 bytes; the flat .ins param struct (AUDIO.md §4.1) */
  uint8_t type;   /* 0 = fm, 1 = sample, 2 = stream (stereo 1:1 pcm —
                     the sound player's voice; note is ignored) */
  uint8_t alg;    /* 0..7 */
  uint8_t fb;     /* 0..7, op 0 */
  uint8_t flags;
  int8_t pan;     /* -64..64 */
  uint8_t gain;   /* 0..255, 128 = unity */
  uint16_t pad0;
  union {
    SndOp op[4]; /* type 0 */
    struct {     /* type 1 — the sampler */
      char pcm[24]; /* named buffer: mono i16 @ 48 kHz */
      uint8_t root; /* midi note the PCM plays back 1:1 at */
      uint8_t sflags; /* bit0 = loop */
      uint16_t a_ms, d_ms, r_ms;
      uint8_t s;
      uint8_t pad1;
      uint32_t loop0, loop1; /* loop points, sample frames */
      uint8_t pad2[22]; /* union arm == op[4]'s 64 bytes exactly */
    } smp;
  } u;
  /* voice-wide effects (R9f): a 1-pole filter + a pitch sweep. Both are
   * bypass at 0 so every pre-R9f patch renders byte-identical (goldens
   * safe) — the .ins pad1 was zero, so an old file decodes to bypass. */
  uint8_t flt_type;  /* 0 off, 1 lowpass, 2 highpass */
  uint8_t flt_cut;   /* cutoff index 0..255 -> SND_FILT_A */
  int8_t sweep;      /* pitch sweep, semitones (signed); 0 = none */
  uint16_t sweep_ms; /* sweep reaches +sweep semis over this many ms */
  uint8_t pad1[3];
} SndPatch;

typedef struct { /* 16 bytes per operator */
  uint32_t phase;
  uint32_t env;   /* Q24, 0..1<<24 */
  uint8_t stage;  /* 0 attack 1 decay 2 sustain 3 release 4 off */
  uint8_t pad0;
  uint16_t lfsr;
  int16_t fb1, fb2; /* op 0: last two outputs (feedback) */
} SndOpState;

typedef struct { /* 96 bytes */
  uint8_t active; /* 0 free, 1 held, 2 released */
  uint8_t slot;
  uint8_t note, vel;
  uint32_t age; /* header frame counter at note-on (stealing) */
  SndOpState op[4];
  uint64_t spos; /* sampler position, 32.32 */
  int32_t flp;    /* R9f: 1-pole filter lowpass state (per voice) */
  uint32_t nsamp; /* R9f: samples since note-on (the sweep clock) */
  uint8_t pad[8];
} SndVoice;

typedef struct { /* 16-byte header */
  uint32_t magic;   /* 'CSND' */
  uint32_t version; /* 1 */
  uint32_t frame;   /* render counter (stealing ages; sim state) */
  uint32_t pad;
} SndHdr;
#pragma pack(pop)

#define SND_BANK_BYTES \
  (sizeof(SndHdr) + SND_PATCHES * sizeof(SndPatch) + \
   SND_VOICES * sizeof(SndVoice))
#define SND_MAGIC 0x444e5343u /* "CSND" LE */

typedef struct {
  SndHdr *hdr;
  SndPatch *patch;
  SndVoice *voice;
} SndBank;

/* _Static_assert keeps the layout honest across compilers */
_Static_assert(sizeof(SndOp) == 16, "SndOp layout");
_Static_assert(sizeof(SndPatch) == 80, "SndPatch layout");
_Static_assert(sizeof(SndOpState) == 16, "SndOpState layout");
_Static_assert(sizeof(SndVoice) == 96, "SndVoice layout");

/* ---- module state (C-side; NONE of it is sim state) ---- */

static struct {
  /* device + output fifo (sim-bank PCM, whole frames) */
  bool dev_up;
  SDL_AudioStream *stream;
  int16_t fifo[SND_FRAME * 2 * 8]; /* 8 frames ≈ 133 ms cap */
  SDL_AtomicInt fifo_r, fifo_w;    /* in frames */
  /* dev-only device-output mute of the sim bank by voice-slot category
   * (music = slots 32..47, sfx = 0..31). Live editor monitoring; the sim
   * bank + the PCM hash (goldens) are never touched — the full mix is still
   * what gets hashed, only the device push is filtered. */
  bool mute_music, mute_sfx;

  /* pcm-hash accumulator (test harness, not state) */
  uint64_t hash;
  uint64_t hashed_frames;
  int16_t tap[SND_FRAME * 2]; /* last rendered sim frame (x_snd_tap) */

  /* the editor bank (callback-owned once the device is up) */
  SndPatch ed_patch[SND_PATCHES];
  SndVoice ed_voice[SND_VOICES];
  uint32_t ed_frame;

  /* SPSC command ring: lua thread -> audio callback */
  struct {
    uint8_t kind; /* 1 on, 2 off, 3 patch */
    uint8_t voice, slot, note, vel;
    uint32_t pos; /* on: start offset, sample frames (player seek) */
    SndPatch patch;
  } edq[64];
  SDL_AtomicInt edq_r, edq_w;
} S;

/* ---- the kernel (shared by both banks) ---- */

static int32_t wave_sample(uint8_t wave, uint32_t ph, uint32_t oldph,
                           uint16_t *lfsr) {
  switch (wave) {
  default:
  case 0: return SND_SINE[(ph >> 21) & 2047];
  case 1: return (ph & 0x80000000u) ? -28000 : 28000;
  case 2: return ((ph >> 24) < 64) ? 28000 : -28000;
  case 3: return ((ph >> 24) < 32) ? 28000 : -28000;
  case 4: return (int32_t)(ph >> 16) - 32768;
  case 5: { /* triangle */
    uint32_t p = ph >> 16;
    int32_t v = p < 32768 ? (int32_t)p : 65535 - (int32_t)p;
    return v * 2 - 32768;
  }
  case 6:
  case 7: { /* LFSR noise, stepped on phase MSB toggles (freq-clocked) */
    if ((ph ^ oldph) & 0x80000000u) {
      uint16_t l = *lfsr ? *lfsr : 0x7fff;
      uint16_t bit = (l ^ (l >> 1)) & 1;
      l = (uint16_t)((l >> 1) | (bit << 14));
      if (wave == 7) l = (uint16_t)((l & ~0x40u) | (bit << 6)); /* short */
      *lfsr = l;
    }
    return (*lfsr & 1) ? 24000 : -24000;
  }
  }
}

/* per-alg modulation sources (bitmask of lower ops) + carriers */
static const uint8_t ALG_SRC[8][4] = {
  {0, 1, 2, 4}, {0, 0, 3, 4}, {0, 0, 2, 5}, {0, 1, 0, 6},
  {0, 1, 0, 4}, {0, 1, 1, 1}, {0, 1, 0, 0}, {0, 0, 0, 0},
};
static const uint8_t ALG_CAR[8] = {8, 8, 8, 8, 10, 14, 14, 15};

static uint32_t env_inc(uint16_t ms) {
  return ms ? (uint32_t)((1u << 24) / ((uint32_t)ms * 48u)) : (1u << 24);
}

/* op frequency: note/fixed, coarse ratio, fine + detune multipliers */
static uint32_t op_inc(const SndOp *op, uint8_t note) {
  uint64_t inc;
  if (op->opflags & 1) {
    inc = ((uint64_t)op->fixed_hz << 32) / SND_RATE;
  } else {
    inc = SND_NOTE_INC[note & 127];
    inc = op->coarse ? inc * op->coarse : inc >> 1;
  }
  inc = inc * (uint32_t)(1024 + op->fine) >> 10;
  inc = inc * (uint32_t)(16384 + op->detune) >> 14;
  return (uint32_t)inc; /* u32 wrap on extremes = chip-authentic alias */
}

/* render one voice into the stereo i32 accumulator. Reads/writes only
 * the passed structs (+ the sampler's named-buffer PCM) — pure over
 * its inputs, the determinism contract. */
static void voice_render(const SndPatch *p, SndVoice *v, int32_t *acc,
                         int n) {
  if (!v->active) return;

  /* envelope increments recomputed per render from the patch (patch
   * edits act live; nothing extra in voice state) */
  uint32_t ainc[4], dinc[4], rinc[4], sus[4], incs[4];
  uint8_t nops = p->type == 0 ? 4 : 1;
  for (int o = 0; o < nops; o++) {
    const SndOp *op;
    SndOp tmp;
    if (p->type == 0) {
      op = &p->u.op[o];
    } else { /* sampler/stream reuse op slot 0's envelope machinery */
      memset(&tmp, 0, sizeof tmp);
      tmp.a_ms = p->u.smp.a_ms;
      tmp.d_ms = p->u.smp.d_ms;
      tmp.r_ms = p->u.smp.r_ms;
      tmp.s = p->u.smp.s;
      op = &tmp;
    }
    ainc[o] = env_inc(op->a_ms);
    dinc[o] = env_inc(op->d_ms);
    rinc[o] = env_inc(op->r_ms);
    sus[o] = (uint32_t)op->s << 16;
    incs[o] = p->type == 0 ? op_inc(op, v->note) : 0;
  }

  /* pitch sweep (R9f): glide every op's increment from x1 toward
   * x2^(sweep/12) over sweep_ms, then hold. Per-frame granularity (one
   * multiplier for this render's n samples) — smooth for SFX. Reuses the
   * semitone ratio LUT; linear in the multiplier (punchy for kick drops).
   * FM only — a sampler's pitch is its resample step, left alone. */
  if (p->type == 0 && p->sweep != 0 && p->sweep_ms != 0) {
    uint32_t dur = (uint32_t)p->sweep_ms * (SND_RATE / 1000u);
    int ri = (int)p->sweep + 64;
    if (ri < 0) ri = 0; else if (ri > 128) ri = 128;
    uint32_t endr = SND_RATIO_Q16[ri]; /* Q16 target ratio (64 = unity) */
    uint32_t t = v->nsamp < dur ? v->nsamp : dur;
    int64_t mult = (int64_t)65536 +
                   ((int64_t)endr - 65536) * (int64_t)t / (int64_t)dur;
    for (int o = 0; o < nops; o++)
      incs[o] = (uint32_t)(((uint64_t)incs[o] * (uint64_t)mult) >> 16);
  }

  /* sampler/stream PCM (types 1/2): an i16 named buffer (mono for the
   * sampler, interleaved stereo for the stream), looked up per render */
  const int16_t *pcm = NULL;
  uint32_t pcm_n = 0; /* FRAMES (mono samples, or stereo pairs) */
  uint64_t sstep = 0, loop0 = 0, loop1 = 0;
  int pcm_ch = p->type == 2 ? 2 : 1;
  if (p->type == 1 || p->type == 2) {
    char name[25];
    memcpy(name, p->u.smp.pcm, 24);
    name[24] = 0;
    for (PalBuf *b = G.bufs; b; b = b->next)
      if (b->alive && b->name && strcmp(b->name, name) == 0) {
        pcm = (const int16_t *)b->data;
        pcm_n = (uint32_t)(b->size / (2 * pcm_ch));
        break;
      }
    if (p->type == 1) {
      int off = (int)v->note - (int)p->u.smp.root + 64;
      if (off < 0) off = 0;
      if (off > 128) off = 128;
      sstep = (uint64_t)SND_RATIO_Q16[off] << 16; /* Q16 -> 32.32 */
    } else {
      sstep = (uint64_t)1 << 32; /* stream: 1:1, note ignored */
    }
    loop0 = (uint64_t)p->u.smp.loop0 << 32;
    loop1 = (uint64_t)p->u.smp.loop1 << 32;
    if (!pcm || pcm_n == 0) { /* unbound PCM: the voice just dies */
      v->active = 0;
      return;
    }
  }

  int pi = (int)p->pan + 64; /* -64..64 -> 0..128 */
  if (pi < 0) pi = 0;
  if (pi > 128) pi = 128;
  int32_t pl = SND_PAN_Q14[pi], pr = SND_PAN_Q14[128 - pi];
  int32_t vel = (int32_t)v->vel + 1; /* 1..128 */
  int32_t gain = p->gain;

  for (int i = 0; i < n; i++) {
    int32_t out[4] = {0, 0, 0, 0};
    int32_t mix = 0;
    bool all_off = true;

    for (int o = 0; o < nops; o++) {
      SndOpState *os = &v->op[o];
      /* envelope */
      uint32_t env = os->env;
      switch (os->stage) {
      case 0:
        env += ainc[o];
        if (env >= (1u << 24)) { env = 1u << 24; os->stage = 1; }
        break;
      case 1:
        env = env > dinc[o] ? env - dinc[o] : 0;
        if (env <= sus[o]) { env = sus[o]; os->stage = 2; }
        break;
      case 2: break;
      case 3:
        env = env > rinc[o] ? env - rinc[o] : 0;
        if (env == 0) os->stage = 4;
        break;
      default: env = 0; break;
      }
      os->env = env;
      if (os->stage != 4) all_off = false;

      if (p->type == 1 || p->type == 2) { /* sampler / stream */
        uint64_t pos = v->spos;
        uint32_t idx = (uint32_t)(pos >> 32);
        if (idx + 1 >= pcm_n) {
          if ((p->u.smp.sflags & 1) && loop1 > loop0 && loop1 <= ((uint64_t)pcm_n << 32)) {
            pos = loop0 + (pos - loop1) % (loop1 - loop0);
            idx = (uint32_t)(pos >> 32);
          } else {
            os->stage = 4;
            os->env = 0;
            all_off = true;
            break;
          }
        }
        int32_t fr = (int32_t)((pos >> 16) & 0xffff);
        uint32_t i1 = idx + 1 < pcm_n ? idx + 1 : idx;
        if (p->type == 2) { /* stereo pairs, 1:1 — straight to acc with
                               env + gain (pan is a balance elsewhere) */
          int32_t l0 = pcm[idx * 2], l1 = pcm[i1 * 2];
          int32_t r0 = pcm[idx * 2 + 1], r1 = pcm[i1 * 2 + 1];
          int32_t sl = l0 + ((l1 - l0) * fr >> 16);
          int32_t sr = r0 + ((r1 - r0) * fr >> 16);
          sl = sl * (int32_t)(env >> 12) >> 12;
          sr = sr * (int32_t)(env >> 12) >> 12;
          acc[i * 2] += sl * gain >> 7;
          acc[i * 2 + 1] += sr * gain >> 7;
          mix = 0; /* already accumulated */
        } else {
          int32_t s0 = pcm[idx], s1 = pcm[i1];
          int32_t sm = s0 + ((s1 - s0) * fr >> 16);
          out[0] = sm * (int32_t)(env >> 12) >> 12;
          mix = out[0];
        }
        pos += sstep;
        if ((p->u.smp.sflags & 1) && loop1 > loop0 && pos >= loop1)
          pos = loop0 + (pos - loop1) % (loop1 - loop0);
        v->spos = pos;
      } else { /* fm op */
        const SndOp *op = &p->u.op[o];
        int32_t mod = 0;
        uint8_t src = ALG_SRC[p->alg & 7][o];
        for (int s2 = 0; s2 < o; s2++)
          if (src & (1 << s2)) mod += out[s2];
        if (o == 0 && p->fb)
          mod = ((int32_t)os->fb1 + os->fb2) >> (10 - (p->fb & 7));
        uint32_t oldph = os->phase;
        uint32_t ph = oldph + (uint32_t)((int64_t)mod << SND_MOD_SHIFT);
        int32_t w = wave_sample(op->wave, ph, oldph, &os->lfsr);
        int32_t oo = w * (int32_t)(os->env >> 12) >> 12;
        oo = oo * op->level >> 8;
        out[o] = oo;
        if (o == 0) { os->fb2 = os->fb1; os->fb1 = (int16_t)(oo > 32767 ? 32767 : oo < -32768 ? -32768 : oo); }
        os->phase = oldph + incs[o];
        if (ALG_CAR[p->alg & 7] & (1 << o)) mix += oo;
      }
    }

    if (all_off) {
      v->active = 0;
      return;
    }

    /* voice filter (R9f): one-pole. lp tracks mix at coeff a; a highpass
     * is mix-lp (the bright "sizzle" that lets GB noise cut through).
     * flt_type 0 bypasses entirely -> bit-identical to pre-R9f. */
    if (p->flt_type) {
      int32_t a = (int32_t)SND_FILT_A[p->flt_cut];
      v->flp += (int32_t)(((int64_t)(mix - v->flp) * a) >> 16);
      mix = p->flt_type == 2 ? mix - v->flp : v->flp;
    }

    mix = mix * vel >> 7;
    mix = mix * gain >> 7;
    acc[i * 2] += mix * pl >> 14;
    acc[i * 2 + 1] += mix * pr >> 14;
  }
  v->nsamp += (uint32_t)n; /* advance the sweep clock */
}

static void bank_render(SndBank *b, int32_t *acc, int n) {
  for (int i = 0; i < SND_VOICES; i++)
    if (b->voice[i].active)
      voice_render(&b->patch[b->voice[i].slot & 63], &b->voice[i], acc, n);
  b->hdr->frame++;
}

/* like bank_render, but renders each voice ONCE (voice state advances once)
 * into `full` (always — this is what gets hashed) and into `dev` (only when
 * that voice's slot category isn't muted). Used for the live device push when
 * a mute is on; `full` stays the true mix so the PCM golden is unchanged. */
static void bank_render_dev(SndBank *b, int32_t *full, int32_t *dev, int n,
                            bool mute_music, bool mute_sfx) {
  static int32_t scr[SND_FRAME * 2];
  for (int i = 0; i < SND_VOICES; i++) {
    if (!b->voice[i].active) continue;
    int slot = b->voice[i].slot & 63;
    memset(scr, 0, sizeof(int32_t) * (size_t)n * 2);
    voice_render(&b->patch[slot], &b->voice[i], scr, n);
    bool muted = (slot >= 32 && slot <= 47) ? mute_music
                 : (slot < 32 ? mute_sfx : false);
    for (int j = 0; j < n * 2; j++) {
      full[j] += scr[j];
      if (!muted) dev[j] += scr[j];
    }
  }
  b->hdr->frame++;
}

static int bank_note_on(SndBank *b, int slot, int note, int vel,
                        uint32_t pos_frames) {
  int pick = -1;
  for (int i = 0; i < SND_VOICES; i++)
    if (!b->voice[i].active) { pick = i; break; }
  if (pick < 0) { /* steal: released voices first, then the oldest
                     note-on — deterministic (frame ages, index ties) */
    uint64_t best = UINT64_MAX;
    for (int i = 0; i < SND_VOICES; i++) {
      uint64_t score = ((uint64_t)(b->voice[i].active == 1) << 32) |
                       b->voice[i].age;
      if (score < best) { best = score; pick = i; }
    }
  }
  SndVoice *v = &b->voice[pick];
  memset(v, 0, sizeof *v);
  v->active = 1;
  v->slot = (uint8_t)slot;
  v->note = (uint8_t)note;
  v->vel = (uint8_t)vel;
  v->age = b->hdr->frame;
  v->spos = (uint64_t)pos_frames << 32; /* sampler/stream start offset */
  for (int o = 0; o < 4; o++) v->op[o].lfsr = 0x7fff;
  return pick;
}

static void bank_note_off(SndBank *b, int voice) {
  if (voice < 0 || voice >= SND_VOICES) return;
  SndVoice *v = &b->voice[voice];
  if (!v->active) return;
  v->active = 2;
  for (int o = 0; o < 4; o++)
    if (v->op[o].stage < 3) v->op[o].stage = 3;
}

/* ---- the sim bank over the named buffer ---- */

static bool sim_bank(SndBank *out, bool create) {
  PalBuf *b = NULL;
  if (create) {
    const char *err;
    b = pal_buf_get("snd.bank", SND_BANK_BYTES, &err);
    if (!b) return false;
  } else {
    for (PalBuf *p = G.bufs; p; p = p->next)
      if (p->alive && p->name && strcmp(p->name, "snd.bank") == 0) {
        b = p;
        break;
      }
    if (!b || b->size != SND_BANK_BYTES) return false;
  }
  out->hdr = (SndHdr *)b->data;
  out->patch = (SndPatch *)(b->data + sizeof(SndHdr));
  out->voice =
      (SndVoice *)(b->data + sizeof(SndHdr) + SND_PATCHES * sizeof(SndPatch));
  if (out->hdr->magic != SND_MAGIC) {
    memset(b->data, 0, b->size);
    out->hdr->magic = SND_MAGIC;
    out->hdr->version = 1;
  }
  return true;
}

/* ---- fifo (sim thread -> callback; whole frames) ---- */

#define FIFO_FRAMES 8

static void fifo_push(const int16_t *pcm) {
  int r = SDL_GetAtomicInt(&S.fifo_r), w = SDL_GetAtomicInt(&S.fifo_w);
  if (w - r >= FIFO_FRAMES) return; /* full: drop (underrun-safe silence) */
  memcpy(&S.fifo[(w % FIFO_FRAMES) * SND_FRAME * 2], pcm,
         SND_FRAME * 2 * sizeof(int16_t));
  SDL_SetAtomicInt(&S.fifo_w, w + 1);
}

/* ---- the audio callback: fifo drain + the editor bank ---- */

static void ed_drain_commands(void) {
  int r = SDL_GetAtomicInt(&S.edq_r), w = SDL_GetAtomicInt(&S.edq_w);
  static SndHdr ed_hdr; /* frame counter for editor voice ages */
  SndBank eb = {&ed_hdr, S.ed_patch, S.ed_voice};
  while (r < w) {
    int i = r % 64;
    switch (S.edq[i].kind) {
    case 1: {
      int voice = S.edq[i].voice;
      if (voice < SND_VOICES) {
        SndVoice *v = &S.ed_voice[voice];
        memset(v, 0, sizeof *v);
        v->active = 1;
        v->slot = S.edq[i].slot;
        v->note = S.edq[i].note;
        v->vel = S.edq[i].vel;
        v->age = ed_hdr.frame;
        v->spos = (uint64_t)S.edq[i].pos << 32;
        for (int o = 0; o < 4; o++) v->op[o].lfsr = 0x7fff;
      }
      break;
    }
    case 2:
      bank_note_off(&eb, S.edq[i].voice);
      break;
    case 3:
      if (S.edq[i].slot < SND_PATCHES)
        S.ed_patch[S.edq[i].slot] = S.edq[i].patch;
      break;
    }
    r++;
  }
  SDL_SetAtomicInt(&S.edq_r, r);
}

static void SDLCALL audio_cb(void *ud, SDL_AudioStream *stream,
                             int additional, int total) {
  (void)ud;
  (void)total;
  int frames = additional / 4; /* stereo s16 */
  static int16_t out[1024 * 2];
  static int32_t acc[1024 * 2];
  static int fifo_pos = 0; /* samples consumed of the front fifo frame */

  ed_drain_commands();

  while (frames > 0) {
    int n = frames < 1024 ? frames : 1024;
    memset(acc, 0, (size_t)n * 2 * sizeof(int32_t));

    /* sim PCM from the fifo (silence on underrun) */
    int filled = 0;
    while (filled < n) {
      int r = SDL_GetAtomicInt(&S.fifo_r), w = SDL_GetAtomicInt(&S.fifo_w);
      if (r >= w) break;
      const int16_t *src = &S.fifo[(r % FIFO_FRAMES) * SND_FRAME * 2];
      int avail = SND_FRAME - fifo_pos;
      int take = avail < n - filled ? avail : n - filled;
      for (int i = 0; i < take * 2; i++)
        acc[filled * 2 + i] += src[fifo_pos * 2 + i];
      filled += take;
      fifo_pos += take;
      if (fifo_pos >= SND_FRAME) {
        fifo_pos = 0;
        SDL_SetAtomicInt(&S.fifo_r, r + 1);
      }
    }

    /* the editor bank renders live */
    for (int i = 0; i < SND_VOICES; i++)
      if (S.ed_voice[i].active)
        voice_render(&S.ed_patch[S.ed_voice[i].slot & 63], &S.ed_voice[i],
                     acc, n);

    for (int i = 0; i < n * 2; i++) {
      int32_t v = acc[i] >> SND_MIX_SHIFT;
      out[i] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
    }
    SDL_PutAudioStreamData(stream, out, n * 4);
    frames -= n;
  }
}

/* ---- lua: the sim-bank surface ---- */

static int l_snd_patch(lua_State *L) {
  int slot = (int)luaL_checkinteger(L, 1);
  size_t len;
  const char *bytes = luaL_checklstring(L, 2, &len);
  luaL_argcheck(L, slot >= 0 && slot < SND_PATCHES, 1, "slot 0..63");
  luaL_argcheck(L, len == sizeof(SndPatch), 2, "patch must be 80 bytes");
  SndBank b;
  if (!sim_bank(&b, true)) return luaL_error(L, "snd.bank unavailable");
  memcpy(&b.patch[slot], bytes, sizeof(SndPatch));
  return 0;
}

static int l_snd_on(lua_State *L) {
  int slot = (int)luaL_checkinteger(L, 1);
  int note = (int)luaL_checkinteger(L, 2);
  int vel = (int)luaL_optinteger(L, 3, 100);
  uint32_t pos = (uint32_t)luaL_optinteger(L, 4, 0);
  luaL_argcheck(L, slot >= 0 && slot < SND_PATCHES, 1, "slot 0..63");
  SndBank b;
  if (!sim_bank(&b, true)) return luaL_error(L, "snd.bank unavailable");
  lua_pushinteger(L, bank_note_on(&b, slot, note & 127, vel & 127, pos));
  return 1;
}

static int l_snd_off(lua_State *L) {
  SndBank b;
  if (!sim_bank(&b, false)) return 0;
  bank_note_off(&b, (int)luaL_checkinteger(L, 1));
  return 0;
}

/* pal.snd_render(): one sim frame of PCM from the bank — called once
 * per sim step by cm.main. A missing bank is a true no-op. */
static int l_snd_render(lua_State *L) {
  (void)L;
  SndBank b;
  if (!sim_bank(&b, false)) return 0;
  static int32_t acc[SND_FRAME * 2];
  memset(acc, 0, sizeof acc);
  /* a live device mute renders a category-filtered copy for the device only;
   * `acc` (hashed below) stays the full mix, so goldens are byte-identical. */
  bool split = S.dev_up && (S.mute_music || S.mute_sfx);
  static int32_t devacc[SND_FRAME * 2];
  if (split) {
    memset(devacc, 0, sizeof devacc);
    bank_render_dev(&b, acc, devacc, SND_FRAME, S.mute_music, S.mute_sfx);
  } else {
    bank_render(&b, acc, SND_FRAME);
  }
  for (int i = 0; i < SND_FRAME * 2; i++) {
    int32_t v = acc[i] >> SND_MIX_SHIFT;
    S.tap[i] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
  }
  if (S.hashed_frames == 0) S.hash = 0xcbf29ce484222325u; /* fnv1a-64 */
  const uint8_t *p = (const uint8_t *)S.tap;
  uint64_t h = S.hash;
  for (size_t i = 0; i < sizeof S.tap; i++) {
    h ^= p[i];
    h *= 0x100000001b3u;
  }
  S.hash = h;
  S.hashed_frames++;
  if (S.dev_up) {
    if (split) {
      static int16_t dtap[SND_FRAME * 2];
      for (int i = 0; i < SND_FRAME * 2; i++) {
        int32_t v = devacc[i] >> SND_MIX_SHIFT;
        dtap[i] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
      }
      fifo_push(dtap);
    } else {
      fifo_push(S.tap);
    }
  }
  return 0;
}

/* pal.x_snd_mute(music, sfx): dev-only device-output mute of the sim bank by
 * category (the editor's monitoring toggles). Booleans; never touches the sim
 * bank or the PCM hash, so it is render/dev, never sim. */
static int l_x_snd_mute(lua_State *L) {
  S.mute_music = lua_toboolean(L, 1);
  S.mute_sfx = lua_toboolean(L, 2);
  return 0;
}

/* pal.snd_hash() -> hash (i64), frames — the PCM golden accumulator */
static int l_snd_hash(lua_State *L) {
  lua_pushinteger(L, (lua_Integer)S.hash);
  lua_pushinteger(L, (lua_Integer)S.hashed_frames);
  return 2;
}

/* pal.x_snd_tap() -> the last rendered sim frame's PCM (debug/tests) */
static int l_x_snd_tap(lua_State *L) {
  lua_pushlstring(L, (const char *)S.tap, sizeof S.tap);
  return 1;
}

/* ---- lua: device + the editor bank (render/dev, x_ prefix) ---- */

static int l_x_snd_start(lua_State *L) {
  if (S.dev_up) {
    lua_pushboolean(L, 1);
    return 1;
  }
  if (G.headless) {
    lua_pushboolean(L, 0);
    return 1;
  }
  if (!SDL_Init(SDL_INIT_AUDIO)) {
    pal_log("snd: SDL audio init failed: %s", SDL_GetError());
    lua_pushboolean(L, 0);
    return 1;
  }
  SDL_AudioSpec spec = {SDL_AUDIO_S16LE, 2, SND_RATE};
  S.stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
                                       &spec, audio_cb, NULL);
  if (!S.stream) {
    pal_log("snd: open device failed: %s", SDL_GetError());
    lua_pushboolean(L, 0);
    return 1;
  }
  SDL_ResumeAudioStreamDevice(S.stream);
  S.dev_up = true;
  pal_log("snd: device up (48 kHz stereo s16, %d-frame fifo)", FIFO_FRAMES);
  lua_pushboolean(L, 1);
  return 1;
}

static bool edq_push(uint8_t kind, uint8_t voice, uint8_t slot, uint8_t note,
                     uint8_t vel, uint32_t pos, const void *patch) {
  int r = SDL_GetAtomicInt(&S.edq_r), w = SDL_GetAtomicInt(&S.edq_w);
  if (w - r >= 64) return false;
  int i = w % 64;
  S.edq[i].kind = kind;
  S.edq[i].voice = voice;
  S.edq[i].slot = slot;
  S.edq[i].note = note;
  S.edq[i].vel = vel;
  S.edq[i].pos = pos;
  if (patch) memcpy(&S.edq[i].patch, patch, sizeof(SndPatch));
  SDL_SetAtomicInt(&S.edq_w, w + 1);
  return true;
}

static int l_x_snd_ed_patch(lua_State *L) {
  int slot = (int)luaL_checkinteger(L, 1);
  size_t len;
  const char *bytes = luaL_checklstring(L, 2, &len);
  luaL_argcheck(L, slot >= 0 && slot < SND_PATCHES, 1, "slot 0..63");
  luaL_argcheck(L, len == sizeof(SndPatch), 2, "patch must be 80 bytes");
  if (!S.dev_up) { /* no device: apply directly (nothing renders anyway) */
    memcpy(&S.ed_patch[slot], bytes, sizeof(SndPatch));
    return 0;
  }
  edq_push(3, 0, (uint8_t)slot, 0, 0, 0, bytes);
  return 0;
}

static int l_x_snd_ed_on(lua_State *L) {
  int voice = (int)luaL_checkinteger(L, 1);
  int slot = (int)luaL_checkinteger(L, 2);
  int note = (int)luaL_checkinteger(L, 3);
  int vel = (int)luaL_optinteger(L, 4, 100);
  luaL_argcheck(L, voice >= 0 && voice < SND_VOICES, 1, "voice 0..31");
  luaL_argcheck(L, slot >= 0 && slot < SND_PATCHES, 2, "slot 0..63");
  uint32_t pos = (uint32_t)luaL_optinteger(L, 5, 0);
  if (!S.dev_up) { /* no device: apply directly (nothing renders; the
                      transport state stays honest for headless tapes) */
    SndVoice *v = &S.ed_voice[voice];
    memset(v, 0, sizeof *v);
    v->active = 1;
    v->slot = (uint8_t)slot;
    v->note = (uint8_t)(note & 127);
    v->vel = (uint8_t)(vel & 127);
    v->spos = (uint64_t)pos << 32;
    for (int o = 0; o < 4; o++) v->op[o].lfsr = 0x7fff;
    return 0;
  }
  edq_push(1, (uint8_t)voice, (uint8_t)slot, (uint8_t)(note & 127),
           (uint8_t)(vel & 127), pos, NULL);
  return 0;
}

static int l_x_snd_ed_off(lua_State *L) {
  int voice = (int)luaL_checkinteger(L, 1);
  luaL_argcheck(L, voice >= 0 && voice < SND_VOICES, 1, "voice 0..31");
  if (!S.dev_up) {
    S.ed_voice[voice].active = 0;
    return 0;
  }
  edq_push(2, (uint8_t)voice, 0, 0, 0, 0, NULL);
  return 0;
}

/* pal.x_snd_ed_pos(voice) -> sample frames, active — the player's
 * playhead (UI display; a racy-but-aligned read of callback state) */
static int l_x_snd_ed_pos(lua_State *L) {
  int voice = (int)luaL_checkinteger(L, 1);
  luaL_argcheck(L, voice >= 0 && voice < SND_VOICES, 1, "voice 0..31");
  lua_pushinteger(L, (lua_Integer)(S.ed_voice[voice].spos >> 32));
  lua_pushboolean(L, S.ed_voice[voice].active != 0);
  return 2;
}

/* ---- registration ---- */

static const luaL_Reg snd_funcs[] = {
    {"snd_patch", l_snd_patch},
    {"snd_on", l_snd_on},
    {"snd_off", l_snd_off},
    {"snd_render", l_snd_render},
    {"snd_hash", l_snd_hash},
    {"x_snd_mute", l_x_snd_mute},
    {"x_snd_tap", l_x_snd_tap},
    {"x_snd_start", l_x_snd_start},
    {"x_snd_ed_patch", l_x_snd_ed_patch},
    {"x_snd_ed_on", l_x_snd_ed_on},
    {"x_snd_ed_off", l_x_snd_ed_off},
    {"x_snd_ed_pos", l_x_snd_ed_pos},
    {NULL, NULL}};

void pal_snd_lua_register(lua_State *L) {
  luaL_setfuncs(L, snd_funcs, 0); /* into the pal table at the stack top */
}
