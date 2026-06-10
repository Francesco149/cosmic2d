/* buf.c — C-owned typed buffers ("console RAM"). Named buffers survive Lua
 * VM reboots and are the snapshot unit (docs/ARCHITECTURE.md "State model");
 * anonymous buffers are Lua-GC-owned scratch. */
#include "pal.h"

#include <stdlib.h>
#include <string.h>

PalBuf *pal_buf_get(const char *name, size_t size, const char **err) {
  *err = NULL;
  for (PalBuf *b = G.bufs; b; b = b->next) {
    if (b->alive && b->name && strcmp(b->name, name) == 0) {
      if (b->size != size) {
        *err = "size mismatch with existing buffer (pal.buf_free it first)";
        return NULL;
      }
      return b;
    }
  }
  PalBuf *b = calloc(1, sizeof *b);
  b->name = SDL_strdup(name);
  b->data = calloc(1, size ? size : 1);
  b->size = size;
  b->alive = true;
  b->next = G.bufs;
  G.bufs = b;
  return b;
}

PalBuf *pal_buf_anon(size_t size) {
  PalBuf *b = calloc(1, sizeof *b);
  b->data = calloc(1, size ? size : 1);
  b->size = size;
  b->alive = true;
  return b;
}

bool pal_buf_free_named(const char *name) {
  for (PalBuf *b = G.bufs; b; b = b->next) {
    if (b->alive && b->name && strcmp(b->name, name) == 0) {
      /* keep the husk so existing views error instead of dangling */
      free(b->data);
      b->data = NULL;
      b->alive = false;
      return true;
    }
  }
  return false;
}

void pal_buf_destroy(PalBuf *b) {
  free(b->data);
  free(b);
}

uint64_t pal_buf_hash(const uint8_t *p, size_t len) {
  uint64_t h = 0xcbf29ce484222325u; /* fnv1a-64 */
  for (size_t i = 0; i < len; i++) {
    h ^= p[i];
    h *= 0x100000001b3u;
  }
  return h;
}
