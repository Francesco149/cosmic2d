/* snd_dec.c — audio file decoders (R9b, docs/AUDIO.md §2.6): wav/mp3/ogg
 * -> interleaved i16 resampled to 48 kHz. Editor/dev class (x_ prefix):
 * file bytes are never sim input (the D028 rule) — sim-bank sample PCM
 * arrives via named buffers the engine fills from these results.
 * Vendored single-header decoders (dr_libs + stb_vorbis) live in this
 * one TU so snd.c stays the kernel. */
#include "pal.h"

#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"

#define DR_WAV_IMPLEMENTATION
#define DRWAV_NO_STDIO_SECURE
#include "dr_libs/dr_wav.h"
#define DR_MP3_IMPLEMENTATION
#include "dr_libs/dr_mp3.h"
#include "stb/stb_vorbis.c"
/* stb_vorbis leaks channel-position macros that eat `lua_State *L` */
#undef L
#undef R
#undef C

#define DEC_RATE 48000

/* linear resample interleaved i16 (frames_in @ rate -> DEC_RATE); the
 * returned buffer is malloc'd, caller frees. */
static int16_t *resample(const int16_t *in, uint64_t frames_in, int ch,
                         uint32_t rate, uint64_t *frames_out) {
  if (rate == DEC_RATE) {
    int16_t *out = malloc(frames_in * ch * sizeof(int16_t));
    if (out) memcpy(out, in, frames_in * ch * sizeof(int16_t));
    *frames_out = frames_in;
    return out;
  }
  uint64_t n = frames_in * DEC_RATE / rate;
  if (n == 0) n = 1;
  int16_t *out = malloc(n * ch * sizeof(int16_t));
  if (!out) return NULL;
  uint64_t step = ((uint64_t)rate << 32) / DEC_RATE; /* src frames, 32.32 */
  uint64_t pos = 0;
  for (uint64_t i = 0; i < n; i++) {
    uint64_t idx = pos >> 32;
    int32_t fr = (int32_t)((pos >> 16) & 0xffff);
    if (idx + 1 >= frames_in) idx = frames_in > 1 ? frames_in - 2 : 0;
    for (int c = 0; c < ch; c++) {
      int32_t s0 = in[idx * ch + c];
      int32_t s1 = in[(idx + 1 < frames_in ? idx + 1 : idx) * ch + c];
      out[i * ch + c] = (int16_t)(s0 + ((s1 - s0) * fr >> 16));
    }
    pos += step;
  }
  *frames_out = n;
  return out;
}

static const char *ext_of(const char *path) {
  const char *dot = strrchr(path, '.');
  return dot ? dot + 1 : "";
}

/* pal.x_snd_decode(path) -> pcm (i16 interleaved string), channels,
 * rate (always 48000), frames — or nil, err. >2 channels downmix to 2. */
static int l_x_snd_decode(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  const char *ext = ext_of(path);
  int16_t *pcm = NULL;
  uint64_t frames = 0;
  uint32_t ch = 0, rate = 0;

  if (SDL_strcasecmp(ext, "wav") == 0) {
    unsigned int c, r;
    drwav_uint64 f;
    pcm = drwav_open_file_and_read_pcm_frames_s16(path, &c, &r, &f, NULL);
    ch = c; rate = r; frames = f;
  } else if (SDL_strcasecmp(ext, "mp3") == 0) {
    drmp3_config cfg;
    drmp3_uint64 f;
    pcm = drmp3_open_file_and_read_pcm_frames_s16(path, &cfg, &f, NULL);
    ch = cfg.channels; rate = cfg.sampleRate; frames = f;
  } else if (SDL_strcasecmp(ext, "ogg") == 0) {
    int c, r;
    short *out;
    int f = stb_vorbis_decode_filename(path, &c, &r, &out);
    if (f > 0) { pcm = out; ch = (uint32_t)c; rate = (uint32_t)r; frames = (uint64_t)f; }
  } else {
    lua_pushnil(L);
    lua_pushstring(L, "unsupported extension (wav/mp3/ogg)");
    return 2;
  }

  if (!pcm || frames == 0 || ch == 0 || rate == 0) {
    if (pcm) free(pcm);
    lua_pushnil(L);
    lua_pushstring(L, "decode failed");
    return 2;
  }

  if (ch > 2) { /* downmix extra channels away (average into stereo) */
    int16_t *two = malloc(frames * 2 * sizeof(int16_t));
    if (!two) { free(pcm); return luaL_error(L, "oom"); }
    for (uint64_t i = 0; i < frames; i++) {
      int32_t l = 0, r = 0;
      for (uint32_t c = 0; c < ch; c++) {
        if (c % 2 == 0) l += pcm[i * ch + c]; else r += pcm[i * ch + c];
      }
      two[i * 2] = (int16_t)(l / (int32_t)((ch + 1) / 2));
      two[i * 2 + 1] = (int16_t)(r / (int32_t)(ch / 2 ? ch / 2 : 1));
    }
    free(pcm);
    pcm = two;
    ch = 2;
  }

  uint64_t out_frames = 0;
  int16_t *out = resample(pcm, frames, (int)ch, rate, &out_frames);
  free(pcm);
  if (!out) return luaL_error(L, "oom");

  lua_pushlstring(L, (const char *)out, out_frames * ch * sizeof(int16_t));
  free(out);
  lua_pushinteger(L, ch);
  lua_pushinteger(L, DEC_RATE);
  lua_pushinteger(L, (lua_Integer)out_frames);
  return 4;
}

static const luaL_Reg dec_funcs[] = {{"x_snd_decode", l_x_snd_decode},
                                     {NULL, NULL}};

void pal_snd_dec_lua_register(lua_State *L) {
  luaL_setfuncs(L, dec_funcs, 0);
}
