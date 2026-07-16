/* winres.c -- project-owned Explorer identity for in-editor Windows exports.
 *
 * The exported root launcher is a private copy of the carried GUI engine.
 * Updating that completed sibling temp needs no compiler or SDK at runtime;
 * Win32's resource updater replaces its icon and VERSIONINFO before the ZIP
 * writer reads the bytes. The engine/editor copies under bin/ stay untouched.
 */
#include "pal.h"

#include <stdarg.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>

typedef struct {
  uint8_t *p;
  size_t n, cap;
  bool ok;
} Bytes;

static bool grow(Bytes *b, size_t add) {
  if (!b->ok || add > SIZE_MAX - b->n) return b->ok = false;
  size_t need = b->n + add;
  if (need <= b->cap) return true;
  size_t cap = b->cap ? b->cap : 512;
  while (cap < need) {
    if (cap > SIZE_MAX / 2) return b->ok = false;
    cap *= 2;
  }
  void *p = SDL_realloc(b->p, cap);
  if (!p) return b->ok = false;
  b->p = p; b->cap = cap;
  return true;
}

static void raw(Bytes *b, const void *p, size_t n) {
  if (!grow(b, n)) return;
  memcpy(b->p + b->n, p, n); b->n += n;
}
static void u16(Bytes *b, uint16_t v) { raw(b, &v, 2); }
static void align4(Bytes *b) { while (b->n & 3) { uint8_t z = 0; raw(b, &z, 1); } }
static void patch16(Bytes *b, size_t at, uint16_t v) {
  if (at + 2 <= b->n) memcpy(b->p + at, &v, 2); else b->ok = false;
}

static WCHAR *wide(const char *utf8) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, NULL, 0);
  if (n <= 0) return NULL;
  WCHAR *out = SDL_malloc((size_t)n * sizeof *out);
  if (!out) return NULL;
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, out, n)) {
    SDL_free(out); return NULL;
  }
  return out;
}

static void wraw(Bytes *b, const WCHAR *s) {
  raw(b, s, (wcslen(s) + 1) * sizeof *s);
}

static size_t block_begin(Bytes *b, const WCHAR *key, uint16_t value_len,
                          uint16_t type) {
  size_t start = b->n;
  u16(b, 0); u16(b, value_len); u16(b, type); wraw(b, key); align4(b);
  return start;
}

static void block_end(Bytes *b, size_t start) {
  size_t len = b->n - start;
  if (len > 0xffff) b->ok = false;
  else patch16(b, start, (uint16_t)len);
}

static void string_block(Bytes *b, const WCHAR *key, const WCHAR *value) {
  size_t chars = wcslen(value) + 1;
  if (chars > 0xffff) { b->ok = false; return; }
  size_t at = block_begin(b, key, (uint16_t)chars, 1);
  wraw(b, value); align4(b); block_end(b, at);
}

static void version_numbers(const char *version, uint16_t out[4]) {
  int at = 0;
  const unsigned char *p = (const unsigned char *)version;
  while (*p && at < 4) {
    while (*p && (*p < '0' || *p > '9')) p++;
    if (!*p) break;
    unsigned long value = 0;
    while (*p >= '0' && *p <= '9') {
      value = value * 10 + (unsigned long)(*p++ - '0');
      if (value > 65535) value = 65535;
    }
    out[at++] = (uint16_t)value;
  }
  while (at < 4) out[at++] = 0;
}

static bool build_version(const char *title8, const char *version8,
                          const char *author8, const char *slug8, Bytes *b) {
  WCHAR *title = wide(title8), *version = wide(version8);
  WCHAR *author = wide(author8 && *author8 ? author8 : title8);
  WCHAR *slug = wide(slug8);
  size_t fn = strlen(slug8) + 5;
  char *filename8 = SDL_malloc(fn);
  if (filename8) SDL_snprintf(filename8, fn, "%s.exe", slug8);
  WCHAR *filename = filename8 ? wide(filename8) : NULL;
  SDL_free(filename8);
  if (!title || !version || !author || !slug || !filename) {
    SDL_free(title); SDL_free(version); SDL_free(author); SDL_free(slug);
    SDL_free(filename); return false;
  }
  uint16_t nums[4]; version_numbers(version8, nums);
  VS_FIXEDFILEINFO fixed = {
      .dwSignature = VS_FFI_SIGNATURE, .dwStrucVersion = 0x00010000,
      .dwFileVersionMS = ((uint32_t)nums[0] << 16) | nums[1],
      .dwFileVersionLS = ((uint32_t)nums[2] << 16) | nums[3],
      .dwProductVersionMS = ((uint32_t)nums[0] << 16) | nums[1],
      .dwProductVersionLS = ((uint32_t)nums[2] << 16) | nums[3],
      .dwFileFlagsMask = VS_FFI_FILEFLAGSMASK, .dwFileFlags = VS_FF_PRERELEASE,
      .dwFileOS = VOS_NT_WINDOWS32, .dwFileType = VFT_APP,
      .dwFileSubtype = VFT2_UNKNOWN,
  };
  size_t top = block_begin(b, L"VS_VERSION_INFO", sizeof fixed, 0);
  raw(b, &fixed, sizeof fixed); align4(b);
  size_t sfi = block_begin(b, L"StringFileInfo", 0, 1);
  size_t table = block_begin(b, L"040904b0", 0, 1);
  string_block(b, L"CompanyName", author);
  string_block(b, L"FileDescription", title);
  string_block(b, L"FileVersion", version);
  string_block(b, L"InternalName", slug);
  string_block(b, L"OriginalFilename", filename);
  string_block(b, L"ProductName", title);
  string_block(b, L"ProductVersion", version);
  block_end(b, table); block_end(b, sfi);
  size_t vfi = block_begin(b, L"VarFileInfo", 0, 1);
  size_t trans = block_begin(b, L"Translation", 4, 0);
  u16(b, 0x0409); u16(b, 1200); align4(b); block_end(b, trans);
  block_end(b, vfi); block_end(b, top);
  SDL_free(title); SDL_free(version); SDL_free(author); SDL_free(slug);
  SDL_free(filename);
  return b->ok;
}

static void seterr(char *err, size_t cap, const char *where) {
  SDL_snprintf(err, cap, "%s failed (Windows error %lu)", where,
               (unsigned long)GetLastError());
}

/* BeginUpdateResource rewrites the image and may discard a trailing COFF
 * symbol table, but it leaves the original pointer/count in mingw's file
 * header. Windows ignores those development-only fields; PE inspectors quite
 * correctly reject the now-out-of-range pointer. Clear both on the private
 * player copy after the resource transaction. */
static bool clear_coff_symbols(const char *path, char *err, size_t errcap) {
  SDL_IOStream *io = SDL_IOFromFile(path, "r+b");
  if (!io) {
    SDL_snprintf(err, errcap, "open branded launcher failed: %s", SDL_GetError());
    return false;
  }
  uint8_t dos[64], pe[4], file_header[20];
  bool ok = SDL_ReadIO(io, dos, sizeof dos) == sizeof dos
         && dos[0] == 'M' && dos[1] == 'Z';
  uint32_t off = 0;
  if (ok) memcpy(&off, dos + 0x3c, 4);
  if (ok) ok = SDL_SeekIO(io, off, SDL_IO_SEEK_SET) >= 0
               && SDL_ReadIO(io, pe, sizeof pe) == sizeof pe
               && pe[0] == 'P' && pe[1] == 'E' && pe[2] == 0 && pe[3] == 0
               && SDL_ReadIO(io, file_header, sizeof file_header)
                    == sizeof file_header;
  uint16_t sections = 0, optional_size = 0;
  if (ok) {
    memcpy(&sections, file_header + 2, 2);
    memcpy(&optional_size, file_header + 16, 2);
    memset(file_header + 8, 0, 8); /* symbol-table pointer + symbol count */
    ok = sections > 0 && sections < 128
      && SDL_SeekIO(io, (Sint64)off + 4, SDL_IO_SEEK_SET) >= 0
      && SDL_WriteIO(io, file_header, sizeof file_header) == sizeof file_header;
  }
  /* Debug sections use slash+offset names backed by the COFF string table we
   * just removed. They are not loader-visible; give those sections local
   * eight-byte names so PE inspectors do not need vanished development data. */
  Sint64 section_table = (Sint64)off + 24 + optional_size;
  for (uint16_t i = 0; ok && i < sections; i++) {
    uint8_t name[8];
    Sint64 at = section_table + (Sint64)i * 40;
    ok = SDL_SeekIO(io, at, SDL_IO_SEEK_SET) >= 0
      && SDL_ReadIO(io, name, sizeof name) == sizeof name;
    if (ok && name[0] == '/') {
      memset(name, 0, sizeof name);
      SDL_snprintf((char *)name, sizeof name, ".dbg%02u", (unsigned)i);
      ok = SDL_SeekIO(io, at, SDL_IO_SEEK_SET) >= 0
        && SDL_WriteIO(io, name, sizeof name) == sizeof name;
    }
  }
  if (!SDL_CloseIO(io)) ok = false;
  if (!ok) SDL_snprintf(err, errcap, "repair branded PE header failed: %s",
                        SDL_GetError());
  return ok;
}

bool pal_windows_exe_identity(const char *path, const void *png, size_t png_len,
                              int width, int height, const char *title,
                              const char *version, const char *author,
                              const char *slug, char *err, size_t errcap) {
  if (!path || !png || png_len < 24 || width < 1 || height < 1) {
    SDL_snprintf(err, errcap, "invalid Windows identity input");
    return false;
  }
  WCHAR *wpath = wide(path);
  if (!wpath) {
    SDL_snprintf(err, errcap, "launcher path is not valid UTF-8");
    return false;
  }
  Bytes ver = {.ok = true};
  if (!build_version(title, version, author, slug, &ver)) {
    SDL_free(wpath); SDL_free(ver.p);
    SDL_snprintf(err, errcap, "could not encode Windows version metadata");
    return false;
  }
  uint8_t group[20] = {0};
  group[2] = 1; group[4] = 1; /* reserved=0, type=1, count=1 */
  group[6] = width >= 256 ? 0 : (uint8_t)width;
  group[7] = height >= 256 ? 0 : (uint8_t)height;
  group[10] = 1; group[12] = 32; /* planes=1, bitcount=32 */
  uint32_t plen = (uint32_t)png_len;
  memcpy(group + 14, &plen, 4);
  group[18] = 1; /* resource id 1 */

  HANDLE update = BeginUpdateResourceW(wpath, FALSE);
  SDL_free(wpath);
  if (!update) {
    seterr(err, errcap, "BeginUpdateResource"); SDL_free(ver.p); return false;
  }
  WORD lang = MAKELANGID(LANG_ENGLISH, SUBLANG_ENGLISH_US);
  bool ok = UpdateResourceW(update, MAKEINTRESOURCEW(3), MAKEINTRESOURCEW(1), lang,
                            (void *)png, (DWORD)png_len)
         && UpdateResourceW(update, MAKEINTRESOURCEW(14), MAKEINTRESOURCEW(101), lang,
                            group, sizeof group)
         && UpdateResourceW(update, MAKEINTRESOURCEW(16), MAKEINTRESOURCEW(1), lang,
                            ver.p, (DWORD)ver.n);
  if (!ok) seterr(err, errcap, "UpdateResource");
  if (!EndUpdateResourceW(update, ok ? FALSE : TRUE)) {
    if (ok) seterr(err, errcap, "EndUpdateResource");
    ok = false;
  }
  SDL_free(ver.p);
  if (ok) ok = clear_coff_symbols(path, err, errcap);
  return ok;
}

#else

bool pal_windows_exe_identity(const char *path, const void *png, size_t png_len,
                              int width, int height, const char *title,
                              const char *version, const char *author,
                              const char *slug, char *err, size_t errcap) {
  (void)path; (void)png; (void)png_len; (void)width; (void)height;
  (void)title; (void)version; (void)author; (void)slug;
  SDL_snprintf(err, errcap, "Windows executable identity is unavailable on Linux");
  return false;
}

#endif
