/* hash.c -- small release-integrity hashes used by the in-editor exporter.
 *
 * SHA-256 is deliberately local instead of delegated to a platform crypto
 * API: exported trees and sibling checksums must have identical semantics on
 * Linux and Windows.  This is ordinary dev/io work, never simulation state.
 */
#include "pal.h"

#include <string.h>

typedef struct {
  uint32_t h[8];
  uint64_t bytes;
  uint8_t block[64];
  size_t used;
} Sha256;

static const uint32_t K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

static uint32_t ror(uint32_t x, unsigned n) {
  return (x >> n) | (x << (32u - n));
}

static uint32_t be32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
       | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void put_be32(uint8_t *p, uint32_t x) {
  p[0] = (uint8_t)(x >> 24); p[1] = (uint8_t)(x >> 16);
  p[2] = (uint8_t)(x >> 8);  p[3] = (uint8_t)x;
}

static void sha_block(Sha256 *s, const uint8_t block[64]) {
  uint32_t w[64];
  for (int i = 0; i < 16; i++) w[i] = be32(block + i * 4);
  for (int i = 16; i < 64; i++) {
    uint32_t a = w[i - 15], b = w[i - 2];
    uint32_t s0 = ror(a, 7) ^ ror(a, 18) ^ (a >> 3);
    uint32_t s1 = ror(b, 17) ^ ror(b, 19) ^ (b >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = s->h[0], b = s->h[1], c = s->h[2], d = s->h[3];
  uint32_t e = s->h[4], f = s->h[5], g = s->h[6], h = s->h[7];
  for (int i = 0; i < 64; i++) {
    uint32_t s1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25);
    uint32_t ch = (e & f) ^ (~e & g);
    uint32_t t1 = h + s1 + ch + K[i] + w[i];
    uint32_t s0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22);
    uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    uint32_t t2 = s0 + maj;
    h = g; g = f; f = e; e = d + t1;
    d = c; c = b; b = a; a = t1 + t2;
  }
  s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d;
  s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}

static void sha_init(Sha256 *s) {
  *s = (Sha256){
      .h = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
            0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u}};
}

static void sha_update(Sha256 *s, const void *data, size_t len) {
  const uint8_t *p = data;
  s->bytes += len;
  while (len) {
    size_t n = 64 - s->used;
    if (n > len) n = len;
    memcpy(s->block + s->used, p, n);
    s->used += n; p += n; len -= n;
    if (s->used == 64) {
      sha_block(s, s->block);
      s->used = 0;
    }
  }
}

static void sha_final(Sha256 *s, uint8_t out[32]) {
  uint64_t bits = s->bytes * 8;
  s->block[s->used++] = 0x80;
  if (s->used > 56) {
    memset(s->block + s->used, 0, 64 - s->used);
    sha_block(s, s->block);
    s->used = 0;
  }
  memset(s->block + s->used, 0, 56 - s->used);
  for (int i = 0; i < 8; i++) s->block[63 - i] = (uint8_t)(bits >> (i * 8));
  sha_block(s, s->block);
  for (int i = 0; i < 8; i++) put_be32(out + i * 4, s->h[i]);
}

void pal_sha256(const void *data, size_t len, uint8_t out[32]) {
  Sha256 s;
  sha_init(&s);
  sha_update(&s, data, len);
  sha_final(&s, out);
}

bool pal_sha256_file(const char *path, uint8_t out[32], char *err,
                     size_t errcap) {
  SDL_IOStream *io = SDL_IOFromFile(path, "rb");
  if (!io) {
    SDL_snprintf(err, errcap, "open: %s", SDL_GetError());
    return false;
  }
  Sha256 s;
  sha_init(&s);
  uint8_t block[64 * 1024];
  bool ok = true;
  for (;;) {
    size_t n = SDL_ReadIO(io, block, sizeof block);
    if (n) sha_update(&s, block, n);
    if (n < sizeof block) {
      SDL_IOStatus status = SDL_GetIOStatus(io);
      if (status == SDL_IO_STATUS_ERROR) {
        SDL_snprintf(err, errcap, "read: %s", SDL_GetError());
        ok = false;
      }
      break;
    }
  }
  if (!SDL_CloseIO(io) && ok) {
    SDL_snprintf(err, errcap, "close: %s", SDL_GetError());
    ok = false;
  }
  if (!ok) return false;
  sha_final(&s, out);
  return true;
}

uint32_t pal_crc32(uint32_t prior, const void *data, size_t len) {
  uint32_t crc = ~prior;
  const uint8_t *p = data;
  while (len--) {
    crc ^= *p++;
    for (int bit = 0; bit < 8; bit++)
      crc = (crc >> 1) ^ (0xedb88320u & (uint32_t)-(int32_t)(crc & 1));
  }
  return ~crc;
}
