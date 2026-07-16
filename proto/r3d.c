#include "r3d.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdio.h>

#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "vendor/stb_image.h"
#include "vendor/stb_image_write.h"

/* ---------------- math ---------------- */
m4 m4_ident(void){ m4 r={{0}}; r.m[0]=r.m[5]=r.m[10]=r.m[15]=1; return r; }
m4 m4_mul(m4 a, m4 b){
  m4 r;
  for(int c=0;c<4;c++) for(int i=0;i<4;i++){
    float s=0; for(int k=0;k<4;k++) s+=a.m[k*4+i]*b.m[c*4+k];
    r.m[c*4+i]=s;
  }
  return r;
}
m4 m4_translate(float x,float y,float z){ m4 r=m4_ident(); r.m[12]=x;r.m[13]=y;r.m[14]=z; return r; }
m4 m4_scale(float x,float y,float z){ m4 r=m4_ident(); r.m[0]=x;r.m[5]=y;r.m[10]=z; return r; }
m4 m4_rotx(float a){ m4 r=m4_ident(); float c=cosf(a),s=sinf(a); r.m[5]=c;r.m[6]=s;r.m[9]=-s;r.m[10]=c; return r; }
m4 m4_roty(float a){ m4 r=m4_ident(); float c=cosf(a),s=sinf(a); r.m[0]=c;r.m[2]=-s;r.m[8]=s;r.m[10]=c; return r; }
m4 m4_rotz(float a){ m4 r=m4_ident(); float c=cosf(a),s=sinf(a); r.m[0]=c;r.m[1]=s;r.m[4]=-s;r.m[5]=c; return r; }
m4 m4_persp(float fovy_deg, float aspect, float zn, float zf){
  float f = 1.0f/tanf(fovy_deg*(3.14159265f/180.f)*0.5f);
  m4 r={{0}};
  r.m[0]=f/aspect; r.m[5]=f;
  r.m[10]=(zf+zn)/(zn-zf); r.m[11]=-1;
  r.m[14]=(2*zf*zn)/(zn-zf);
  return r;
}
v3 v3_sub(v3 a, v3 b){ return (v3){a.x-b.x,a.y-b.y,a.z-b.z}; }
float v3_dot(v3 a, v3 b){ return a.x*b.x+a.y*b.y+a.z*b.z; }
v3 v3_cross(v3 a, v3 b){ return (v3){a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x}; }
v3 v3_norm(v3 a){ float l=sqrtf(v3_dot(a,a)); if(l<1e-20f) return (v3){0,0,0}; return (v3){a.x/l,a.y/l,a.z/l}; }
m4 m4_lookat(v3 eye, v3 at, v3 up){
  v3 f=v3_norm(v3_sub(at,eye));
  v3 s=v3_norm(v3_cross(f,up));
  v3 u=v3_cross(s,f);
  m4 r=m4_ident();
  r.m[0]=s.x; r.m[4]=s.y; r.m[8]=s.z;
  r.m[1]=u.x; r.m[5]=u.y; r.m[9]=u.z;
  r.m[2]=-f.x;r.m[6]=-f.y;r.m[10]=-f.z;
  r.m[12]=-v3_dot(s,eye); r.m[13]=-v3_dot(u,eye); r.m[14]=v3_dot(f,eye);
  return r;
}
v4 m4_mulv(m4 m, v4 v){
  return (v4){
    m.m[0]*v.x+m.m[4]*v.y+m.m[8]*v.z+m.m[12]*v.w,
    m.m[1]*v.x+m.m[5]*v.y+m.m[9]*v.z+m.m[13]*v.w,
    m.m[2]*v.x+m.m[6]*v.y+m.m[10]*v.z+m.m[14]*v.w,
    m.m[3]*v.x+m.m[7]*v.y+m.m[11]*v.z+m.m[15]*v.w };
}

/* ---------------- framebuffer ---------------- */
fb_t *fb_new(int w, int h){
  fb_t *f = calloc(1, sizeof *f);
  f->w=w; f->h=h;
  f->color = calloc((size_t)w*h, 4);
  f->depth = calloc((size_t)w*h, sizeof(float));
  f->sun_dir = v3_norm((v3){-0.5f,-1.0f,-0.35f});
  f->sun_color = (v3){1,1,1};
  f->ambient = (v3){0.35f,0.35f,0.4f};
  f->fog_color = (v3){0.6f,0.7f,0.8f};
  f->fog_start=20; f->fog_end=60; f->fog_on=0;
  f->filter = FILT_3POINT;
  return f;
}
void fb_clear(fb_t *f, uint32_t rgba){
  for(int i=0;i<f->w*f->h;i++) f->color[i]=rgba;
  memset(f->depth, 0, (size_t)f->w*f->h*sizeof(float));
}
void fb_clear_gradient(fb_t *f, uint32_t top, uint32_t bot){
  uint8_t *t=(uint8_t*)&top, *b=(uint8_t*)&bot;
  for(int y=0;y<f->h;y++){
    float k=(float)y/(float)(f->h-1);
    uint8_t c[4];
    for(int i=0;i<4;i++) c[i]=(uint8_t)(t[i]+(b[i]-t[i])*k+0.5f);
    uint32_t v; memcpy(&v,c,4);
    for(int x=0;x<f->w;x++) f->color[y*f->w+x]=v;
  }
  memset(f->depth, 0, (size_t)f->w*f->h*sizeof(float));
}

/* ---------------- texture sampling ---------------- */
static inline void tex_fetch(const tex_t *t, int x, int y, float out[4]){
  /* repeat wrap */
  x &= (t->w-1) ? 0x7fffffff : 0; /* placeholder to keep -Wall quiet */
  x = ((x % t->w) + t->w) % t->w;
  y = ((y % t->h) + t->h) % t->h;
  const uint8_t *p = t->px + 4*((size_t)y*t->w + x);
  out[0]=p[0]*(1/255.f); out[1]=p[1]*(1/255.f); out[2]=p[2]*(1/255.f); out[3]=p[3]*(1/255.f);
}
static void tex_sample(const tex_t *t, float u, float v, int filter, float out[4]){
  float tu = u * t->w, tv = v * t->h;
  if(filter == FILT_NEAREST){
    tex_fetch(t, (int)floorf(tu), (int)floorf(tv), out);
    return;
  }
  tu -= 0.5f; tv -= 0.5f;
  int x0=(int)floorf(tu), y0=(int)floorf(tv);
  float fu=tu-x0, fv=tv-y0;
  float t00[4],t10[4],t01[4],t11[4];
  if(filter == FILT_3POINT){
    /* N64 three-point: triangle of nearest texels */
    if(fu+fv < 1.0f){
      tex_fetch(t,x0,y0,t00); tex_fetch(t,x0+1,y0,t10); tex_fetch(t,x0,y0+1,t01);
      float w0=1-fu-fv;
      for(int i=0;i<4;i++) out[i]=w0*t00[i]+fu*t10[i]+fv*t01[i];
    }else{
      tex_fetch(t,x0+1,y0+1,t11); tex_fetch(t,x0+1,y0,t10); tex_fetch(t,x0,y0+1,t01);
      float w0=fu+fv-1;
      for(int i=0;i<4;i++) out[i]=w0*t11[i]+(1-fv)*t10[i]+(1-fu)*t01[i];
    }
    return;
  }
  /* full bilinear */
  tex_fetch(t,x0,y0,t00); tex_fetch(t,x0+1,y0,t10);
  tex_fetch(t,x0,y0+1,t01); tex_fetch(t,x0+1,y0+1,t11);
  for(int i=0;i<4;i++){
    float a=t00[i]+(t10[i]-t00[i])*fu, b=t01[i]+(t11[i]-t01[i])*fu;
    out[i]=a+(b-a)*fv;
  }
}

/* ---------------- triangle pipeline ---------------- */
typedef struct { /* post-transform vertex */
  float sx, sy;      /* screen px */
  float invw;        /* 1/clip.w */
  float u_w, v_w;    /* u/w, v/w (or plain u,v when affine) */
  v3 col_w;          /* lit color / w (or plain when affine) */
  float fog;         /* 0..1 fog factor (affine-interpolated, fine) */
  float zview;
} rvtx;

void (*r3d_capture)(fb_t *f, vtx_t a, vtx_t b, vtx_t c, const tex_t *t) = NULL;

/* per-vertex directional light, world space; model rotates the normal */
static v3 light_vertex(fb_t *f, const m4 *model, v3 c, v3 n){
  if(n.x==0 && n.y==0 && n.z==0) return c;
  if(model){
    v4 nn = m4_mulv(*model, (v4){n.x,n.y,n.z,0});
    n = v3_norm((v3){nn.x,nn.y,nn.z});
  }
  float d = -v3_dot(n, f->sun_dir); if(d<0) d=0;
  c.x *= f->ambient.x + f->sun_color.x*d;
  c.y *= f->ambient.y + f->sun_color.y*d;
  c.z *= f->ambient.z + f->sun_color.z*d;
  if(c.x>1)c.x=1; if(c.y>1)c.y=1; if(c.z>1)c.z=1;
  return c;
}

static int xform(fb_t *f, const m4 *model, vtx_t in, rvtx *out, v4 *clip){
  v4 wp = (v4){in.pos.x, in.pos.y, in.pos.z, 1};
  if(model) wp = m4_mulv(*model, wp);
  v3 c = light_vertex(f, model, in.col, in.nrm);
  v4 vp = m4_mulv(f->view, wp);
  v4 cp = m4_mulv(f->proj, vp);
  *clip = cp;
  if(cp.w <= 0.001f) return 0; /* behind camera; prototype: reject whole tri via caller clip */
  float iw = 1.0f/cp.w;
  out->sx = (cp.x*iw*0.5f+0.5f)*f->w;
  out->sy = (0.5f-cp.y*iw*0.5f)*f->h;
  if(f->vsnap){ out->sx = floorf(out->sx)+0.5f; out->sy = floorf(out->sy)+0.5f; }
  out->invw = iw;
  if(f->affine){ out->u_w=in.u; out->v_w=in.v; out->col_w=c; }
  else{ out->u_w=in.u*iw; out->v_w=in.v*iw; out->col_w=(v3){c.x*iw,c.y*iw,c.z*iw}; }
  float zv = -vp.z;
  out->zview = zv;
  float fog=0;
  if(f->fog_on){
    fog = (zv - f->fog_start)/(f->fog_end - f->fog_start);
    if(fog<0)fog=0; if(fog>1)fog=1;
  }
  out->fog=fog;
  return 1;
}

/* clip a polygon against the near plane in clip space (w >= eps) */
typedef struct { vtx_t v; v4 clip; } cvert;
static int clip_near(cvert *in, int n, cvert *out){
  const float eps = 0.01f;
  int m=0;
  for(int i=0;i<n;i++){
    cvert a=in[i], b=in[(i+1)%n];
    int ain = a.clip.w >= eps, bin = b.clip.w >= eps;
    if(ain) out[m++]=a;
    if(ain != bin){
      float t = (eps - a.clip.w)/(b.clip.w - a.clip.w);
      cvert c;
      c.v.pos.x = a.v.pos.x + (b.v.pos.x-a.v.pos.x)*t;
      c.v.pos.y = a.v.pos.y + (b.v.pos.y-a.v.pos.y)*t;
      c.v.pos.z = a.v.pos.z + (b.v.pos.z-a.v.pos.z)*t;
      c.v.u = a.v.u+(b.v.u-a.v.u)*t; c.v.v = a.v.v+(b.v.v-a.v.v)*t;
      c.v.col.x=a.v.col.x+(b.v.col.x-a.v.col.x)*t;
      c.v.col.y=a.v.col.y+(b.v.col.y-a.v.col.y)*t;
      c.v.col.z=a.v.col.z+(b.v.col.z-a.v.col.z)*t;
      c.v.nrm.x=a.v.nrm.x+(b.v.nrm.x-a.v.nrm.x)*t;
      c.v.nrm.y=a.v.nrm.y+(b.v.nrm.y-a.v.nrm.y)*t;
      c.v.nrm.z=a.v.nrm.z+(b.v.nrm.z-a.v.nrm.z)*t;
      c.clip.x=a.clip.x+(b.clip.x-a.clip.x)*t;
      c.clip.y=a.clip.y+(b.clip.y-a.clip.y)*t;
      c.clip.z=a.clip.z+(b.clip.z-a.clip.z)*t;
      c.clip.w=eps;
      out[m++]=c;
    }
  }
  return m;
}

static void raster(fb_t *f, rvtx A, rvtx B, rvtx C, const tex_t *t){
  float minx=A.sx, maxx=A.sx, miny=A.sy, maxy=A.sy;
  if(B.sx<minx)minx=B.sx; if(B.sx>maxx)maxx=B.sx;
  if(C.sx<minx)minx=C.sx; if(C.sx>maxx)maxx=C.sx;
  if(B.sy<miny)miny=B.sy; if(B.sy>maxy)maxy=B.sy;
  if(C.sy<miny)miny=C.sy; if(C.sy>maxy)maxy=C.sy;
  int x0=(int)floorf(minx), x1=(int)ceilf(maxx);
  int y0=(int)floorf(miny), y1=(int)ceilf(maxy);
  if(x0<0)x0=0; if(y0<0)y0=0; if(x1>f->w)x1=f->w; if(y1>f->h)y1=f->h;
  if(x0>=x1||y0>=y1) return;
  float area = (B.sx-A.sx)*(C.sy-A.sy)-(B.sy-A.sy)*(C.sx-A.sx);
  if(area == 0) return;
  /* no backface cull (double-sided; terrain walls need it, keeps authoring forgiving) */
  float ia = 1.0f/area;
  for(int y=y0;y<y1;y++){
    for(int x=x0;x<x1;x++){
      float px=x+0.5f, py=y+0.5f;
      float w0=((B.sx-A.sx)*(py-A.sy)-(B.sy-A.sy)*(px-A.sx))*ia;   /* weight for C */
      float w1=((C.sx-B.sx)*(py-B.sy)-(C.sy-B.sy)*(px-B.sx))*ia;   /* weight for A */
      float w2=1.0f-w0-w1;                                          /* weight for B */
      if(w0<0||w1<0||w2<0) continue;
      /* barycentric: wA=w1, wB=w2, wC=w0 */
      float invw = w1*A.invw + w2*B.invw + w0*C.invw;
      float *dz = &f->depth[y*f->w+x];
      if(invw <= *dz) continue;
      float u,v; v3 col;
      if(f->affine){
        u = w1*A.u_w + w2*B.u_w + w0*C.u_w;
        v = w1*A.v_w + w2*B.v_w + w0*C.v_w;
        col.x = w1*A.col_w.x + w2*B.col_w.x + w0*C.col_w.x;
        col.y = w1*A.col_w.y + w2*B.col_w.y + w0*C.col_w.y;
        col.z = w1*A.col_w.z + w2*B.col_w.z + w0*C.col_w.z;
      }else{
        float rw = 1.0f/invw;
        u = (w1*A.u_w + w2*B.u_w + w0*C.u_w)*rw;
        v = (w1*A.v_w + w2*B.v_w + w0*C.v_w)*rw;
        col.x = (w1*A.col_w.x + w2*B.col_w.x + w0*C.col_w.x)*rw;
        col.y = (w1*A.col_w.y + w2*B.col_w.y + w0*C.col_w.y)*rw;
        col.z = (w1*A.col_w.z + w2*B.col_w.z + w0*C.col_w.z)*rw;
      }
      float texel[4]={1,1,1,1};
      if(t) tex_sample(t, u, v, f->filter, texel);
      if(f->alpha_test && texel[3] < 0.5f) continue;
      float r = col.x*texel[0], g = col.y*texel[1], b = col.z*texel[2];
      float fog = w1*A.fog + w2*B.fog + w0*C.fog;
      if(fog>0){
        r += (f->fog_color.x-r)*fog;
        g += (f->fog_color.y-g)*fog;
        b += (f->fog_color.z-b)*fog;
      }
      if(r>1)r=1; if(g>1)g=1; if(b>1)b=1;
      if(r<0)r=0; if(g<0)g=0; if(b<0)b=0;
      uint8_t *pc = (uint8_t*)&f->color[y*f->w+x];
      if(f->blend > 0){
        float a = f->blend * texel[3];
        pc[0]=(uint8_t)(pc[0]+(r*255.f-pc[0])*a);
        pc[1]=(uint8_t)(pc[1]+(g*255.f-pc[1])*a);
        pc[2]=(uint8_t)(pc[2]+(b*255.f-pc[2])*a);
        /* blended decals don't write depth */
      }else{
        pc[0]=(uint8_t)(r*255.f+0.5f);
        pc[1]=(uint8_t)(g*255.f+0.5f);
        pc[2]=(uint8_t)(b*255.f+0.5f);
        pc[3]=255;
        *dz = invw;
      }
    }
  }
}

void tri(fb_t *f, const m4 *model, vtx_t a, vtx_t b, vtx_t c, const tex_t *t){
  if(r3d_capture){
    vtx_t s[3]={a,b,c};
    for(int i=0;i<3;i++){
      v4 wp=(v4){s[i].pos.x,s[i].pos.y,s[i].pos.z,1};
      if(model) wp=m4_mulv(*model,wp);
      s[i].col = light_vertex(f, model, s[i].col, s[i].nrm);
      s[i].pos = (v3){wp.x,wp.y,wp.z};
      s[i].nrm = (v3){0,0,0};
    }
    r3d_capture(f, s[0], s[1], s[2], t);
    return;
  }
  /* transform to clip first to near-clip as polygon */
  cvert poly[8], clipped[8];
  vtx_t src[3]={a,b,c};
  for(int i=0;i<3;i++){
    v4 wp=(v4){src[i].pos.x,src[i].pos.y,src[i].pos.z,1};
    if(model) wp=m4_mulv(*model, wp);
    v4 vp=m4_mulv(f->view, wp);
    poly[i].clip = m4_mulv(f->proj, vp);
    poly[i].v = src[i];
    poly[i].v.pos = (v3){wp.x,wp.y,wp.z}; /* world space now; model applied */
  }
  int n = clip_near(poly, 3, clipped);
  if(n < 3) return;
  /* re-run full xform (lighting/fog/screen) on clipped verts, model=NULL */
  m4 save_model = m4_ident(); (void)save_model;
  rvtx rv[8]; v4 cp;
  /* note: normals were interpolated by clip; lighting on clipped verts */
  for(int i=0;i<n;i++){
    if(!xform(f, model? NULL: NULL, clipped[i].v, &rv[i], &cp)) return;
  }
  for(int i=1;i+1<n;i++) raster(f, rv[0], rv[i], rv[i+1], t);
}

void quad(fb_t *f, const m4 *model, vtx_t a, vtx_t b, vtx_t c, vtx_t d, const tex_t *t){
  tri(f, model, a, b, c, t);
  tri(f, model, a, c, d, t);
}

void billboard(fb_t *f, v3 pos, float w, float h,
               float u0, float v0, float u1, float v1,
               v3 tint, const tex_t *t){
  /* camera right/up from view matrix rows */
  v3 right = (v3){f->view.m[0], f->view.m[4], f->view.m[8]};
  v3 up    = (v3){f->view.m[1], f->view.m[5], f->view.m[9]};
  /* RO-style: lock up to world Y so sprites stand on the ground plane?
   * classic RO tilts sprites toward camera; we use camera-up (full billboard) */
  v3 p=pos;
  vtx_t A={{p.x - right.x*w/2 + up.x*h, p.y - right.y*w/2 + up.y*h, p.z - right.z*w/2 + up.z*h}, u0,v0, tint, {0,0,0}};
  vtx_t B={{p.x + right.x*w/2 + up.x*h, p.y + right.y*w/2 + up.y*h, p.z + right.z*w/2 + up.z*h}, u1,v0, tint, {0,0,0}};
  vtx_t C={{p.x + right.x*w/2, p.y + right.y*w/2, p.z + right.z*w/2}, u1,v1, tint, {0,0,0}};
  vtx_t D={{p.x - right.x*w/2, p.y - right.y*w/2, p.z - right.z*w/2}, u0,v1, tint, {0,0,0}};
  /* sprites are pixel art: always nearest, always cutout */
  int at = f->alpha_test, fi = f->filter;
  f->alpha_test = 1; f->filter = FILT_NEAREST;
  quad(f, NULL, A, B, C, D, t);
  f->alpha_test = at; f->filter = fi;
}

/* ---------------- output ---------------- */
static const int bayer4[16] = { 0,8,2,10, 12,4,14,6, 3,11,1,9, 15,7,13,5 };

int r3d_soft_upscale = 0;

void fb_write_png(fb_t *f, const char *path, int scale, int quant5551){
  int W=f->w*scale, H=f->h*scale;
  /* quantize/dither in place-copy first (both output modes share it) */
  uint8_t *src = malloc((size_t)f->w*f->h*4);
  for(int y=0;y<f->h;y++)for(int x=0;x<f->w;x++){
    uint8_t c[4]; memcpy(c, &f->color[y*f->w+x], 4);
    if(quant5551){
      float d = (bayer4[(y&3)*4+(x&3)]/16.0f - 0.5f) * (255.0f/31.0f);
      for(int i=0;i<3;i++){
        float v = c[i] + d;
        if(v<0)v=0; if(v>255)v=255;
        int q = (int)(v/255.f*31.f+0.5f);
        c[i] = (uint8_t)(q*255/31);
      }
    }
    c[3]=255;
    memcpy(src + 4*((size_t)y*f->w+x), c, 4);
  }
  uint8_t *out = malloc((size_t)W*H*4);
  if(!r3d_soft_upscale){
    for(int y=0;y<f->h;y++)for(int x=0;x<f->w;x++)
      for(int sy=0;sy<scale;sy++){
        uint8_t *row = out + ((size_t)(y*scale+sy)*W + x*scale)*4;
        for(int sx=0;sx<scale;sx++) memcpy(row+sx*4, src+4*((size_t)y*f->w+x), 4);
      }
  }else{
    /* bilinear upscale (the VI resample look) */
    for(int Y=0;Y<H;Y++)for(int X=0;X<W;X++){
      float fx=(X+0.5f)/scale-0.5f, fy=(Y+0.5f)/scale-0.5f;
      int x0=(int)floorf(fx), y0=(int)floorf(fy);
      float ux=fx-x0, uy=fy-y0;
      uint8_t *o = out + 4*((size_t)Y*W+X);
      for(int i=0;i<4;i++){
        int x1=x0+1, y1=y0+1;
        int cx0=x0<0?0:(x0>=f->w?f->w-1:x0), cx1=x1<0?0:(x1>=f->w?f->w-1:x1);
        int cy0=y0<0?0:(y0>=f->h?f->h-1:y0), cy1=y1<0?0:(y1>=f->h?f->h-1:y1);
        float a=src[4*((size_t)cy0*f->w+cx0)+i], b=src[4*((size_t)cy0*f->w+cx1)+i];
        float c=src[4*((size_t)cy1*f->w+cx0)+i], d=src[4*((size_t)cy1*f->w+cx1)+i];
        o[i]=(uint8_t)((a+(b-a)*ux)*(1-uy)+(c+(d-c)*ux)*uy);
      }
    }
    /* mild horizontal 3-tap (the VI's extra smear) */
    for(int Y=0;Y<H;Y++)for(int X=1;X<W-1;X++){
      uint8_t *o = out + 4*((size_t)Y*W+X);
      for(int i=0;i<3;i++)
        o[i]=(uint8_t)((o[i-4]+2*o[i]+o[i+4])>>2);
    }
  }
  stbi_write_png(path, W, H, 4, out, W*4);
  free(out); free(src);
  fprintf(stderr, "wrote %s (%dx%d%s)\n", path, W, H, r3d_soft_upscale?" soft":"");
}

/* ---------------- textures ---------------- */
tex_t tex_load(const char *path){
  tex_t t={0};
  int n;
  t.px = stbi_load(path, &t.w, &t.h, &n, 4);
  if(!t.px){ fprintf(stderr, "tex_load failed: %s\n", path); exit(1); }
  return t;
}
tex_t tex_new(int w, int h){
  tex_t t={w,h,calloc((size_t)w*h,4)};
  return t;
}
uint32_t xs32(uint32_t *s){ uint32_t x=*s; x^=x<<13; x^=x>>17; x^=x<<5; return *s=x; }
