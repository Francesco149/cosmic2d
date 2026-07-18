/* r3d — tiny deterministic software rasterizer for cosmic3d aesthetic tests.
 * Headless: renders scenes to RGBA8 buffers, written out as PNG.
 * Everything float32 + integer; no libm transcendentals in scene code paths
 * (we allow them here in the prototype for camera setup; a real engine port
 * would route through cm.math equivalents).
 */
#ifndef R3D_H
#define R3D_H
#include <stdint.h>
#include <stddef.h>

typedef struct { float x, y, z; } v3;
typedef struct { float x, y, z, w; } v4;
typedef struct { float m[16]; } m4; /* column-major */

typedef struct {
  int w, h;
  uint8_t *px;      /* RGBA8 */
} tex_t;

/* texture filter / mapping modes */
enum { FILT_NEAREST = 0, FILT_3POINT = 1, FILT_BILINEAR = 2 };

typedef struct {
  int w, h;
  uint32_t *color;  /* RGBA packed LE bytes r,g,b,a */
  float *depth;     /* 1/w depth, larger = closer; cleared to 0 */
  /* render state */
  m4 view, proj;
  v3 fog_color; float fog_start, fog_end; int fog_on;
  v3 sun_dir;   v3 sun_color; v3 ambient;  /* per-vertex directional light */
  int filter;       /* FILT_* */
  int affine;       /* 1 = PS1-style affine uv interpolation */
  int vsnap;        /* 1 = PS1-style integer vertex snapping (the wobble) */
  int alpha_test;   /* discard texel alpha < 128 (cutout billboards) */
  float blend;      /* 0 = opaque write; >0 = src-over with this alpha (shadows etc) */
  float texel_snap; /* 0 = off; else snap uv to texel grid * this (unused) */
} fb_t;

/* one vertex through the pipeline */
typedef struct {
  v3 pos;    /* model/world space */
  float u, v;
  v3 col;    /* vertex color 0..1 */
  v3 nrm;    /* normal for lighting; pass zero to skip lighting */
} vtx_t;

/* --- setup --- */
fb_t *fb_new(int w, int h);
void fb_clear(fb_t *f, uint32_t rgba);
void fb_clear_gradient(fb_t *f, uint32_t top, uint32_t bottom);

/* --- math --- */
m4 m4_ident(void);
m4 m4_mul(m4 a, m4 b);
m4 m4_translate(float x, float y, float z);
m4 m4_rotx(float a); m4 m4_roty(float a); m4 m4_rotz(float a);
m4 m4_scale(float x, float y, float z);
m4 m4_persp(float fovy_deg, float aspect, float znear, float zfar);
m4 m4_lookat(v3 eye, v3 at, v3 up);
v4 m4_mulv(m4 m, v4 v);
v3 v3_norm(v3 a);
v3 v3_cross(v3 a, v3 b);
float v3_dot(v3 a, v3 b);

/* capture hook: when set, tri() applies model transform + vertex lighting and
 * hands the world-space lit triangle here instead of rasterizing — used to
 * dump identical scene content for the GPU-path comparison. */
extern void (*r3d_capture)(fb_t *f, vtx_t a, vtx_t b, vtx_t c, const tex_t *t);

/* --- drawing --- */
/* tri in world space; mtx = model matrix applied first (NULL = identity).
 * tex NULL = solid (vertex colors only). */
void tri(fb_t *f, const m4 *model, vtx_t a, vtx_t b, vtx_t c, const tex_t *t);
void quad(fb_t *f, const m4 *model, vtx_t a, vtx_t b, vtx_t c, vtx_t d, const tex_t *t);
/* camera-facing quad at world pos, size w,h (world units), uv rect */
void billboard(fb_t *f, v3 pos, float w, float h,
               float u0, float v0, float u1, float v1,
               v3 tint, const tex_t *t);

/* --- output --- */
/* integer-upscale, optional RGBA5551 quantize + 4x4 bayer dither first.
 * r3d_soft_upscale=1 switches to bilinear upscale + mild horizontal blur —
 * the N64 VI / emulator "soft" look (user-selectable, off = sharp pixels). */
extern int r3d_soft_upscale;
void fb_write_png(fb_t *f, const char *path, int scale, int quant5551);

/* --- textures --- */
tex_t tex_load(const char *path);
tex_t tex_new(int w, int h);
uint32_t xs32(uint32_t *s); /* xorshift PRNG for procedural textures */

#endif
