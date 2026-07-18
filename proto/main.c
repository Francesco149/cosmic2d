/* cosmic3d prototype scenes — headless aesthetic tests.
 * usage: proto <scene> [out.png]
 * scenes: filters, n64, ro, chars
 */
#include "r3d.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>

/* ================= procedural textures (deterministic) =================
 * goal: "hand-painted low-res" look — big readable shapes, limited ramp,
 * slight value noise, dark outlines. 32x32 / 64x64 like real N64 TMEM budgets.
 */

typedef struct { uint8_t r,g,b; } rgb8;

static void px(tex_t *t, int x, int y, rgb8 c){
  if(x<0||y<0||x>=t->w||y>=t->h) return;
  uint8_t *p = t->px + 4*((size_t)y*t->w+x);
  p[0]=c.r; p[1]=c.g; p[2]=c.b; p[3]=255;
}
static rgb8 lerp8(rgb8 a, rgb8 b, float t){
  return (rgb8){ (uint8_t)(a.r+(b.r-a.r)*t), (uint8_t)(a.g+(b.g-a.g)*t), (uint8_t)(a.b+(b.b-a.b)*t) };
}

/* value noise on a small lattice, tileable */
static float vnoise(uint32_t seed, int x, int y, int period, int cell){
  int gx0 = (x/cell) % (period/cell), gy0 = (y/cell) % (period/cell);
  int n = period/cell;
  float fx = (x%cell)/(float)cell, fy = (y%cell)/(float)cell;
  #define H(ix,iy) ({ uint32_t s = seed ^ (uint32_t)(((ix)%n)*374761393u) ^ (uint32_t)(((iy)%n)*668265263u); s^=s<<13; s^=s>>17; s^=s<<5; (s&0xffff)/65535.0f; })
  float a=H(gx0,gy0), b=H(gx0+1,gy0), c=H(gx0,gy0+1), d=H(gx0+1,gy0+1);
  float u = fx*fx*(3-2*fx), v = fy*fy*(3-2*fy);
  return a+(b-a)*u+(c-a)*v+(a-b-c+d)*u*v;
  #undef H
}
static float fbm(uint32_t seed, int x, int y, int period){
  return 0.55f*vnoise(seed,x,y,period,period/4)
       + 0.30f*vnoise(seed*7+1,x,y,period,period/8)
       + 0.15f*vnoise(seed*13+2,x,y,period,period/16);
}

/* quantize a value 0..1 into an n-step ramp between two colors (painted look) */
static rgb8 ramp(rgb8 lo, rgb8 hi, float v, int steps){
  int q = (int)(v*steps); if(q>=steps) q=steps-1; if(q<0) q=0;
  return lerp8(lo, hi, q/(float)(steps-1));
}

static tex_t tx_grass(void){
  tex_t t = tex_new(64,64);
  rgb8 lo={ 58,102, 48}, hi={130,168, 82};
  for(int y=0;y<64;y++)for(int x=0;x<64;x++){
    /* chunkier painted blobs: bigger lattice cells than default fbm */
    float v = 0.6f*vnoise(101,x,y,64,32) + 0.3f*vnoise(707,x,y,64,16) + 0.1f*vnoise(909,x,y,64,8);
    rgb8 c = ramp(lo,hi,v,4);
    /* sparse blade flecks */
    uint32_t s = (uint32_t)(x*73856093u ^ y*19349663u ^ 555u); s^=s<<13;s^=s>>17;s^=s<<5;
    if((s&255) > 250) c = (rgb8){168,196,110};
    if((s&255) < 3)   c = (rgb8){ 44, 80, 40};
    px(&t,x,y,c);
  }
  return t;
}
static tex_t tx_dirt(void){
  tex_t t = tex_new(64,64);
  rgb8 lo={ 96, 70, 46}, hi={168,132, 92};
  for(int y=0;y<64;y++)for(int x=0;x<64;x++){
    float v = fbm(202,x,y,64);
    rgb8 c = ramp(lo,hi,v,5);
    uint32_t s = (uint32_t)(x*83492791u ^ y*29349673u ^ 99u); s^=s<<13;s^=s>>17;s^=s<<5;
    if((s&255) > 249) c = (rgb8){186,158,118}; /* pebbles */
    px(&t,x,y,c);
  }
  return t;
}
static tex_t tx_cliff(void){
  tex_t t = tex_new(64,64);
  rgb8 lo={ 84, 74, 78}, hi={158,146,140};
  for(int y=0;y<64;y++)for(int x=0;x<64;x++){
    /* horizontal strata + noise */
    float strata = 0.5f + 0.5f*sinf(y*0.55f + 2.2f*fbm(303,x,y,64));
    float v = 0.6f*fbm(304,x,y,64) + 0.4f*strata;
    rgb8 c = ramp(lo,hi,v,5);
    /* crack lines */
    float cr = vnoise(305,x,y,64,16);
    if(cr > 0.46f && cr < 0.5f) c = lerp8(c,(rgb8){40,36,40},0.55f);
    px(&t,x,y,c);
  }
  return t;
}
static tex_t tx_stone(void){ /* stone brick, dungeon-ish */
  tex_t t = tex_new(64,64);
  rgb8 mortar={ 70, 66, 72}, lo={110,104,110}, hi={164,158,158};
  int bh=16, bw=32;
  for(int y=0;y<64;y++)for(int x=0;x<64;x++){
    int row = y/bh;
    int xo = (row&1)? bw/2 : 0;
    int bx = (x+xo)%bw, by = y%bh;
    if(bx<2 || by<2){ px(&t,x,y,mortar); continue; }
    float v = fbm(404 + (uint32_t)row*17 + (uint32_t)((x+xo)/bw)*31, x,y,64);
    rgb8 c = ramp(lo,hi,v,4);
    if(bx<4 || by<4) c=lerp8(c,hi,0.25f);          /* top-left bevel light */
    if(bx>bw-3 || by>bh-3) c=lerp8(c,mortar,0.4f); /* bottom-right bevel dark */
    px(&t,x,y,c);
  }
  return t;
}
static tex_t tx_water(void){
  tex_t t = tex_new(64,64);
  rgb8 lo={ 38, 84,132}, hi={ 96,160,196};
  for(int y=0;y<64;y++)for(int x=0;x<64;x++){
    float v = fbm(505,x,y,64);
    float band = 0.5f+0.5f*sinf((x+y)*0.35f + 5.0f*v);
    rgb8 c = ramp(lo,hi,0.65f*v+0.35f*band,4);
    if(band>0.93f) c=(rgb8){208,232,240};
    px(&t,x,y,c);
  }
  return t;
}
static tex_t tx_shadow(void){ /* radial blob, alpha = softness */
  tex_t t = tex_new(32,32);
  for(int y=0;y<32;y++)for(int x=0;x<32;x++){
    float dx=(x-15.5f)/15.5f, dy=(y-15.5f)/15.5f;
    float d = sqrtf(dx*dx+dy*dy);
    float a = d>1? 0 : (1-d)*(1-d)*1.8f; if(a>1)a=1;
    uint8_t *p = t.px + 4*((size_t)y*32+x);
    p[0]=p[1]=p[2]=12; p[3]=(uint8_t)(a*255);
  }
  return t;
}
/* ---- graybox material family: "checkerboards that feel like materials" ----
 * style-neutral placeholders that keep the N64 read: every material is a
 * checker at heart, but check scale, palette, noise and streaks give each a
 * distinct material identity without committing the user to an art style. */
static tex_t tx_gb(uint32_t seed, rgb8 A, rgb8 B, int check, float noise_amt,
                   int grain /*0 none, 1 horizontal, 2 vertical*/){
  tex_t t = tex_new(64,64);
  for(int y=0;y<64;y++)for(int x=0;x<64;x++){
    int k = ((x/check)^(y/check))&1;
    rgb8 c = k? A : B;
    float v = fbm(seed,x,y,64)-0.5f;
    float amt = noise_amt;
    if(grain==1) amt *= 0.6f+0.8f*(0.5f+0.5f*sinf(y*0.9f+fbm(seed*3+1,x,y,64)*3));
    if(grain==2) amt *= 0.6f+0.8f*(0.5f+0.5f*sinf(x*0.9f+fbm(seed*3+1,x,y,64)*3));
    float m = 1.0f + v*amt;
    c.r=(uint8_t)(c.r*m>255?255:(c.r*m<0?0:c.r*m));
    c.g=(uint8_t)(c.g*m>255?255:(c.g*m<0?0:c.g*m));
    c.b=(uint8_t)(c.b*m>255?255:(c.b*m<0?0:c.b*m));
    /* dark seam on check borders: makes it read as tiles/blocks, not wallpaper */
    if(x%check==0 || y%check==0){ c.r=c.r*3/4; c.g=c.g*3/4; c.b=c.b*3/4; }
    px(&t,x,y,c);
  }
  return t;
}
enum { GB_GRASS=0, GB_STONE, GB_WOOD, GB_DIRT, GB_METAL, GB_ACCENT, GB_MAX };
static tex_t g_gb[GB_MAX];
static void load_graybox_textures(void){
  g_gb[GB_GRASS] = tx_gb(11,(rgb8){ 92,140, 72},(rgb8){ 74,120, 60},16,0.55f,0);
  g_gb[GB_STONE] = tx_gb(22,(rgb8){138,134,142},(rgb8){112,108,118},16,0.40f,0);
  g_gb[GB_WOOD]  = tx_gb(33,(rgb8){168,124, 82},(rgb8){146,104, 66}, 8,0.50f,1);
  g_gb[GB_DIRT]  = tx_gb(44,(rgb8){150,116, 82},(rgb8){128, 96, 66},16,0.60f,0);
  g_gb[GB_METAL] = tx_gb(55,(rgb8){130,140,156},(rgb8){104,114,132},32,0.25f,2);
  g_gb[GB_ACCENT]= tx_gb(66,(rgb8){222,150, 64},(rgb8){190,116, 44}, 8,0.30f,0);
}

static tex_t tx_checker(void){
  tex_t t = tex_new(32,32);
  for(int y=0;y<32;y++)for(int x=0;x<32;x++){
    int k = ((x/8)^(y/8))&1;
    px(&t,x,y, k? (rgb8){200,200,208} : (rgb8){96,96,120});
  }
  return t;
}
/* simple 8-direction-ish RO sprite: a little adventurer drawn procedurally.
 * 32x48, big head (RO proportion), dark outline, 3-tone shading. */
static tex_t tx_sprite(void){
  tex_t t = tex_new(32,48); /* alpha=0 default */
  rgb8 skin={236,188,150}, skin_d={198,146,112};
  rgb8 hair={220,140, 60}, hair_d={170, 96, 40};
  rgb8 tun ={ 70,110,180}, tun_d ={ 48, 76,140};
  rgb8 pants={90, 70, 60}, outline={30,26,34};
  /* body regions via simple shapes: head r=8 at (16,12), torso, legs */
  for(int y=0;y<48;y++)for(int x=0;x<32;x++){
    int dx=x-16, dy=y-12;
    rgb8 c; int on=0;
    if(dx*dx+dy*dy < 81){ c = (y<14 || (dx*dx > 25 && y<18))? ((dx<-2)?hair_d:hair) : ((dx<-2)?skin_d:skin); on=1; }
    if(y>=20 && y<34 && x>=10 && x<22){ c = (x<14)?tun_d:tun; on=1; }             /* torso */
    if(y>=22 && y<31 && (x==9 || x==22)){ c = skin; on=1; }                        /* arms */
    if(y>=34 && y<44 && ((x>=11&&x<15)||(x>=17&&x<21))){ c = pants; on=1; }        /* legs */
    if(y>=44 && y<46 && ((x>=10&&x<16)||(x>=16&&x<22))){ c = outline; on=1; }      /* boots */
    if(on) px(&t,x,y,c);
  }
  /* eyes */
  px(&t,13,13,outline); px(&t,19,13,outline);
  /* outline pass: any opaque pixel adjacent to transparent -> dark edge */
  tex_t o = tex_new(32,48);
  memcpy(o.px, t.px, (size_t)32*48*4);
  for(int y=0;y<48;y++)for(int x=0;x<32;x++){
    uint8_t *p = t.px + 4*((size_t)y*32+x);
    if(p[3]==0) continue;
    int edge=0;
    for(int k=0;k<4;k++){
      int nx=x+(k==0)-(k==1), ny=y+(k==2)-(k==3);
      if(nx<0||ny<0||nx>=32||ny>=48){ edge=1; break; }
      if(t.px[4*((size_t)ny*32+nx)+3]==0){ edge=1; break; }
    }
    if(edge){ uint8_t *q=o.px+4*((size_t)y*32+x); q[0]=outline.r;q[1]=outline.g;q[2]=outline.b; }
  }
  free(t.px);
  return o;
}

/* ================= terrain: RO/GND-style per-corner-height tile grid ===== */

#define TW 24
#define TH 24
typedef struct {
  float h[4];      /* corner heights: 0=NW 1=NE 2=SW 3=SE (x+,z+ = E,S) */
  uint8_t top;     /* texture id for top face */
} tile_t;

typedef struct {
  tile_t t[TH][TW];
  float tile_size;
} terrain_t;

enum { T_GRASS=0, T_DIRT, T_CLIFF, T_STONE, T_WATER, T_MAX };

static float terr_h(terrain_t *T, int x, int z, int corner){
  return T->t[z][x].h[corner];
}

/* editing primitives — exactly what the editor would expose */
static void terr_raise_vertex(terrain_t *T, int vx, int vz, float dh){
  /* a "vertex" (vx,vz) touches up to 4 tiles' corners; keeps surface continuous */
  if(vx>0 && vz>0)   T->t[vz-1][vx-1].h[3]+=dh;
  if(vx<TW && vz>0)  T->t[vz-1][vx  ].h[2]+=dh;
  if(vx>0 && vz<TH)  T->t[vz  ][vx-1].h[1]+=dh;
  if(vx<TW && vz<TH) T->t[vz  ][vx  ].h[0]+=dh;
}
static void terr_set_tile_flat(terrain_t *T, int x, int z, float h){
  for(int i=0;i<4;i++) T->t[z][x].h[i]=h; /* cliff edges appear vs neighbors */
}
static void terr_paint(terrain_t *T, int x, int z, uint8_t tex){
  T->t[z][x].top = tex;
}

static terrain_t *terr_demo(void){
  terrain_t *T = calloc(1,sizeof *T);
  T->tile_size = 2.0f;
  /* rolling ground via smooth noise (continuous heights = slopes) */
  for(int z=0;z<TH;z++)for(int x=0;x<TW;x++){
    float h = 2.2f*fbm(777, x*4, z*4, 128) - 1.1f;
    tile_t *t=&T->t[z][x];
    /* continuous surface: sample noise at each corner */
    t->h[0]=2.2f*fbm(777, x*4,     z*4,     128)-1.1f;
    t->h[1]=2.2f*fbm(777,(x+1)*4,  z*4,     128)-1.1f;
    t->h[2]=2.2f*fbm(777, x*4,    (z+1)*4,  128)-1.1f;
    t->h[3]=2.2f*fbm(777,(x+1)*4, (z+1)*4,  128)-1.1f;
    t->top = T_GRASS;
    (void)h;
  }
  /* a raised stone plateau with sharp cliffs (RO style) */
  for(int z=4;z<10;z++)for(int x=13;x<20;x++){
    terr_set_tile_flat(T,x,z, 3.0f);
    terr_paint(T,x,z, T_STONE);
  }
  /* ramp tiles up to the plateau (south side) */
  for(int x=15;x<18;x++){
    tile_t *t=&T->t[10][x];
    t->h[0]=3.0f; t->h[1]=3.0f;                    /* north edge meets plateau */
    /* south edge stays at ground: fetch neighbors below */
    t->h[2]=T->t[11][x].h[0]; t->h[3]=T->t[11][x].h[1];
    t->top=T_DIRT;
  }
  /* dirt path winding through the grass (walk the curve continuously) */
  for(float fz=10.5f; fz<TH; fz+=0.25f){
    int cx = (int)(16.0f + 3.5f*sinf(fz*0.5f));
    int z = (int)fz;
    terr_paint(T,cx,z,T_DIRT); terr_paint(T,cx+1,z,T_DIRT);
  }
  /* sunken water pool */
  for(int z=16;z<21;z++)for(int x=3;x<9;x++){
    terr_set_tile_flat(T,x,z,-1.6f);
    terr_paint(T,x,z,T_WATER);
  }
  return T;
}

/* per-corner ambient occlusion: corners tucked below their neighborhood get
 * darker — the "painted vertex shading" that sells the era look. AO is baked
 * into vertex color; the editor would expose this as a bake + hand-paint. */
static float terr_ao(terrain_t *T, int x, int z, int corner){
  /* corner world grid position */
  int vx = x + (corner==1||corner==3? 1:0);
  int vz = z + (corner==2||corner==3? 1:0);
  float h = T->t[z][x].h[corner];
  float occ = 0;
  for(int dz=-1;dz<=1;dz++)for(int dx=-1;dx<=1;dx++){
    int nx=vx+dx, nz=vz+dz;
    if(nx<0||nz<0||nx>=TW||nz>=TH) continue;
    /* neighbor tile's NW corner approximates the vertex height there */
    float nh = T->t[nz][nx].h[0];
    if(nh > h) occ += (nh-h);
  }
  float ao = 1.0f - 0.10f*occ;
  return ao < 0.55f ? 0.55f : ao;
}

static void terr_draw(fb_t *f, terrain_t *T, tex_t *texs){
  float s = T->tile_size;
  /* border skirt: the map edge reads as an island cliff, not a void */
  const float SKIRT=-7.0f;
  v3 white={1,1,1}, wbot={0.60f,0.60f,0.66f};
  for(int x=0;x<TW;x++){
    tile_t *tn=&T->t[0][x], *ts=&T->t[TH-1][x];
    float x0=x*s, x1=(x+1)*s;
    vtx_t A={{x0,tn->h[0],0},0,0,white,(v3){0,0,-1}}, B={{x1,tn->h[1],0},1,0,white,(v3){0,0,-1}};
    vtx_t C={{x1,SKIRT,0},1,3,white,(v3){0,0,-1}},  D={{x0,SKIRT,0},0,3,white,(v3){0,0,-1}};
    quad(f,NULL,A,B,C,D,&texs[T_CLIFF]);
    vtx_t E={{x0,ts->h[2],TH*s},0,0,white,(v3){0,0,1}}, F={{x1,ts->h[3],TH*s},1,0,white,(v3){0,0,1}};
    vtx_t G={{x1,SKIRT,TH*s},1,3,white,(v3){0,0,1}},  H={{x0,SKIRT,TH*s},0,3,white,(v3){0,0,1}};
    quad(f,NULL,E,F,G,H,&texs[T_CLIFF]);
  }
  for(int z=0;z<TH;z++){
    tile_t *tw=&T->t[z][0], *te=&T->t[z][TW-1];
    float z0=z*s, z1=(z+1)*s;
    vtx_t A={{0,tw->h[0],z0},0,0,white,(v3){-1,0,0}}, B={{0,tw->h[2],z1},1,0,white,(v3){-1,0,0}};
    vtx_t C={{0,SKIRT,z1},1,3,white,(v3){-1,0,0}},   D={{0,SKIRT,z0},0,3,white,(v3){-1,0,0}};
    quad(f,NULL,A,B,C,D,&texs[T_CLIFF]);
    vtx_t E={{TW*s,te->h[1],z0},0,0,white,(v3){1,0,0}}, F={{TW*s,te->h[3],z1},1,0,white,(v3){1,0,0}};
    vtx_t G={{TW*s,SKIRT,z1},1,3,white,(v3){1,0,0}},   H={{TW*s,SKIRT,z0},0,3,white,(v3){1,0,0}};
    quad(f,NULL,E,F,G,H,&texs[T_CLIFF]);
  }
  for(int z=0;z<TH;z++)for(int x=0;x<TW;x++){
    tile_t *t=&T->t[z][x];
    float x0=x*s, x1=(x+1)*s, z0=z*s, z1=(z+1)*s;
    /* top face; normal approx from corner heights; AO in vertex color */
    v3 n = v3_norm((v3){ (t->h[0]+t->h[2]-t->h[1]-t->h[3])/(2*s), 1,
                         (t->h[0]+t->h[1]-t->h[2]-t->h[3])/(2*s) });
    float a0=terr_ao(T,x,z,0), a1=terr_ao(T,x,z,1), a2=terr_ao(T,x,z,2), a3=terr_ao(T,x,z,3);
    vtx_t a={{x0,t->h[0],z0},0,0,{a0,a0,a0},n}, b={{x1,t->h[1],z0},1,0,{a1,a1,a1},n};
    vtx_t c={{x1,t->h[3],z1},1,1,{a3,a3,a3},n}, d={{x0,t->h[2],z1},0,1,{a2,a2,a2},n};
    quad(f,NULL,a,b,c,d,&texs[t->top]);
    /* auto cliff walls: where east/south neighbor's shared edge differs */
    if(x+1<TW){
      tile_t *e=&T->t[z][x+1];
      float d0=t->h[1]-e->h[0], d1=t->h[3]-e->h[2];
      if(d0>0.01f||d1>0.01f){
        v3 wn={1,0,0};
        float v0 = (t->h[1]-e->h[0])/s, v1=(t->h[3]-e->h[2])/s;
        vtx_t A={{x1,t->h[1],z0},0,0,white,wn}, B={{x1,t->h[3],z1},1,0,white,wn};
        vtx_t C={{x1,e->h[2],z1},1,v1<0?0:v1,wbot,wn}, D={{x1,e->h[0],z0},0,v0<0?0:v0,wbot,wn};
        quad(f,NULL,A,B,C,D,&texs[T_CLIFF]);
      }
      if(d0<-0.01f||d1<-0.01f){
        v3 wn={-1,0,0};
        float v0 = (e->h[0]-t->h[1])/s, v1=(e->h[2]-t->h[3])/s;
        vtx_t A={{x1,e->h[0],z0},0,0,white,wn}, B={{x1,e->h[2],z1},1,0,white,wn};
        vtx_t C={{x1,t->h[3],z1},1,v1<0?0:v1,wbot,wn}, D={{x1,t->h[1],z0},0,v0<0?0:v0,wbot,wn};
        quad(f,NULL,A,B,C,D,&texs[T_CLIFF]);
      }
    }
    if(z+1<TH){
      tile_t *sn=&T->t[z+1][x];
      float d0=t->h[2]-sn->h[0], d1=t->h[3]-sn->h[1];
      if(d0>0.01f||d1>0.01f){
        v3 wn={0,0,1};
        float v0=(t->h[2]-sn->h[0])/s, v1=(t->h[3]-sn->h[1])/s;
        vtx_t A={{x0,t->h[2],z1},0,0,white,wn}, B={{x1,t->h[3],z1},1,0,white,wn};
        vtx_t C={{x1,sn->h[1],z1},1,v1<0?0:v1,wbot,wn}, D={{x0,sn->h[0],z1},0,v0<0?0:v0,wbot,wn};
        quad(f,NULL,A,B,C,D,&texs[T_CLIFF]);
      }
      if(d0<-0.01f||d1<-0.01f){
        v3 wn={0,0,-1};
        float v0=(sn->h[0]-t->h[2])/s, v1=(sn->h[1]-t->h[3])/s;
        vtx_t A={{x0,sn->h[0],z1},0,0,white,wn}, B={{x1,sn->h[1],z1},1,0,white,wn};
        vtx_t C={{x1,t->h[3],z1},1,v1<0?0:v1,wbot,wn}, D={{x0,t->h[2],z1},0,v0<0?0:v0,wbot,wn};
        quad(f,NULL,A,B,C,D,&texs[T_CLIFF]);
      }
    }
  }
}

/* height at world x,z (bilinear in tile) for placing things on ground */
static float terr_sample(terrain_t *T, float wx, float wz){
  float s=T->tile_size;
  int x=(int)(wx/s), z=(int)(wz/s);
  if(x<0)x=0; if(z<0)z=0; if(x>=TW)x=TW-1; if(z>=TH)z=TH-1;
  tile_t *t=&T->t[z][x];
  float fx=wx/s-x, fz=wz/s-z;
  float top = t->h[0]+(t->h[1]-t->h[0])*fx;
  float bot = t->h[2]+(t->h[3]-t->h[2])*fx;
  return top+(bot-top)*fz;
}

/* ================= rigid-part character (Mario64 model) ================= */
/* a "part" = box mesh with size, pivot offset from parent joint, base rotation.
 * pose = per-part euler rotation added on top. NO skinning. */

typedef struct part {
  const char *name;
  int parent;              /* index or -1 */
  v3 joint;                /* joint position relative to parent joint */
  v3 size;                 /* box dimensions */
  v3 offset;               /* box center relative to own joint */
  v3 color;
} part_t;

/* a tiny guy: proportions matter for the aesthetic — big head, chunky */
static part_t GUY[] = {
  /* name      parent joint(rel)        size              offset(center)   color */
  {"pelvis",   -1, { 0, 0.95f, 0},      {0.44f,0.28f,0.30f}, {0, 0.06f, 0},  {0.30f,0.42f,0.72f}},
  {"torso",     0, { 0, 0.20f, 0},      {0.52f,0.50f,0.34f}, {0, 0.25f, 0},  {0.86f,0.30f,0.24f}},
  {"head",      1, { 0, 0.55f, 0},      {0.56f,0.52f,0.50f}, {0, 0.30f, 0},  {0.95f,0.78f,0.62f}},
  /* limbs overlap upward past their joint so rotation never opens a gap */
  {"arm_l",     1, {-0.34f,0.44f,0},    {0.20f,0.56f,0.20f}, {0,-0.20f,0},   {0.70f,0.22f,0.18f}},
  {"arm_r",     1, { 0.34f,0.44f,0},    {0.20f,0.56f,0.20f}, {0,-0.20f,0},   {0.70f,0.22f,0.18f}},
  {"leg_l",     0, {-0.14f,0.0f,0},     {0.22f,0.60f,0.24f}, {0,-0.24f,0},   {0.28f,0.26f,0.34f}},
  {"leg_r",     0, { 0.14f,0.0f,0},     {0.22f,0.60f,0.24f}, {0,-0.24f,0},   {0.28f,0.26f,0.34f}},
};
#define NPARTS 7

static void draw_box(fb_t *f, m4 xf, v3 size, v3 center, v3 col, const tex_t *t){
  float hx=size.x/2, hy=size.y/2, hz=size.z/2;
  v3 c=center;
  v3 P[8]={
    {c.x-hx,c.y-hy,c.z-hz},{c.x+hx,c.y-hy,c.z-hz},{c.x+hx,c.y+hy,c.z-hz},{c.x-hx,c.y+hy,c.z-hz},
    {c.x-hx,c.y-hy,c.z+hz},{c.x+hx,c.y-hy,c.z+hz},{c.x+hx,c.y+hy,c.z+hz},{c.x-hx,c.y+hy,c.z+hz}};
  static const int F[6][4]={{0,1,2,3},{5,4,7,6},{4,0,3,7},{1,5,6,2},{3,2,6,7},{4,5,1,0}};
  static const v3 N[6]={{0,0,-1},{0,0,1},{-1,0,0},{1,0,0},{0,1,0},{0,-1,0}};
  for(int i=0;i<6;i++){
    vtx_t v[4];
    for(int k=0;k<4;k++){
      v[k].pos=P[F[i][k]];
      v[k].u=(k==1||k==2)?1:0; v[k].v=(k>=2)?1:0;
      v[k].col=col; v[k].nrm=N[i];
    }
    quad(f,&xf,v[0],v[1],v[2],v[3],t);
  }
}

typedef struct { v3 rot[NPARTS]; } pose_t;

static pose_t pose_lerp(pose_t a, pose_t b, float t){
  pose_t r;
  for(int i=0;i<NPARTS;i++){
    r.rot[i].x=a.rot[i].x+(b.rot[i].x-a.rot[i].x)*t;
    r.rot[i].y=a.rot[i].y+(b.rot[i].y-a.rot[i].y)*t;
    r.rot[i].z=a.rot[i].z+(b.rot[i].z-a.rot[i].z)*t;
  }
  return r;
}

/* keyframed walk: 4 keys, lerped — the whole animation asset is ~10 numbers */
static pose_t walk_key(int k){
  pose_t p; memset(&p,0,sizeof p);
  float s = (k==0||k==2)? 0 : (k==1? 1 : -1);
  p.rot[5].x =  0.7f*s;   /* leg_l swing */
  p.rot[6].x = -0.7f*s;
  p.rot[3].x = -0.6f*s;   /* arms counter-swing */
  p.rot[4].x =  0.6f*s;
  p.rot[1].y =  0.08f*s;  /* torso twist */
  p.rot[2].x = (k==1||k==3)? 0.06f : -0.02f; /* head bob */
  return p;
}
static pose_t walk_pose(float t){ /* t = cycle 0..1 */
  float ft = t*4; int k=(int)ft; float fr=ft-k;
  return pose_lerp(walk_key(k&3), walk_key((k+1)&3), fr);
}

static void draw_guy(fb_t *f, m4 root, pose_t pose, const tex_t *t){
  m4 world[NPARTS];
  for(int i=0;i<NPARTS;i++){
    part_t *p=&GUY[i];
    m4 local = m4_translate(p->joint.x,p->joint.y,p->joint.z);
    local = m4_mul(local, m4_roty(pose.rot[i].y));
    local = m4_mul(local, m4_rotx(pose.rot[i].x));
    local = m4_mul(local, m4_rotz(pose.rot[i].z));
    world[i] = (p->parent<0)? m4_mul(root,local) : m4_mul(world[p->parent],local);
    draw_box(f, world[i], p->size, p->offset, p->color, t);
  }
  /* face: eyes as flat dark boxes on the head's +z face (era games texture-swap
   * a face texture; boxes stand in for the prototype) */
  v3 dark={0.10f,0.08f,0.12f};
  draw_box(f, world[2], (v3){0.07f,0.13f,0.02f}, (v3){-0.12f,0.32f,0.25f}, dark, NULL);
  draw_box(f, world[2], (v3){0.07f,0.13f,0.02f}, (v3){ 0.12f,0.32f,0.25f}, dark, NULL);
  /* hair: cap + back panel */
  v3 hair={0.55f,0.32f,0.16f};
  draw_box(f, world[2], (v3){0.60f,0.18f,0.54f}, (v3){0,0.52f,0}, hair, NULL);
  draw_box(f, world[2], (v3){0.60f,0.42f,0.10f}, (v3){0,0.36f,-0.24f}, hair, NULL);
}

/* ================= the mascot (stock character study) =====================
 * goal: a stock 3D character that does NOT read as a Minecraft cube-person.
 * recipe: lathe (round) body — no boxes in the silhouette — with Rayman-style
 * FLOATING mitten hands and boots (solves joint gaps outright, trivially
 * animatable: hands/feet are just positioned spheres), big anime eyes, and a
 * bobbing antenna star ("cosmic" branding hook). */

static void draw_lathe(fb_t *f, m4 xf, const float *prof, int npts, int n, v3 col, const tex_t *t);
static void draw_prism(fb_t *f, m4 xf, int n, float r0, float r1, float h, v3 col, const tex_t *t, int caps);

static void draw_ball(fb_t *f, m4 xf, float R, v3 col, int n){
  float pr[12]={0,-R, 0.62f*R,-0.78f*R, 0.95f*R,-0.20f*R,
                0.95f*R,0.20f*R, 0.62f*R,0.78f*R, 0,R};
  draw_lathe(f, xf, pr, 6, n, col, NULL);
}

typedef struct {
  float bob;        /* body height offset */
  float squash;     /* 1 = rest; <1 landing, >1 stretch */
  v3 hand_l, hand_r;/* offsets from body center (pre-yaw) */
  v3 foot_l, foot_r;
  float lean;       /* z-axis lean */
  float ant;        /* antenna sway */
} mpose_t;

/* eye style: sizes in body units; glint = white highlight ball on the pupil */
typedef struct { float eye_w, eye_h, pup_w, pup_h; int glint; } mstyle_t;
/* default = style B from the pupil study (bigger + rounder, human-picked) */
static mstyle_t g_mstyle = {0.17f,0.24f, 0.11f,0.13f, 0};

static void draw_mascot(fb_t *f, v3 at, float yaw, mpose_t p){
  v3 body_c={0.28f,0.60f,0.62f};   /* deep teal */
  v3 belly_c={0.94f,0.90f,0.78f};  /* cream */
  v3 mitt_c={0.95f,0.52f,0.38f};   /* coral */
  v3 dark={0.10f,0.09f,0.13f}, white={0.97f,0.97f,0.95f};
  v3 star_c={1.00f,0.85f,0.35f};
  m4 root = m4_mul(m4_translate(at.x, at.y+0.95f+p.bob, at.z), m4_roty(yaw));
  root = m4_mul(root, m4_rotz(p.lean));
  m4 body = m4_mul(root, m4_scale(1.0f/sqrtf(p.squash), p.squash, 1.0f/sqrtf(p.squash)));
  /* body: teardrop lathe, fatter at the bottom */
  {
    float pr[14]={0,-0.95f, 0.55f,-0.80f, 0.82f,-0.38f, 0.80f,0.10f,
                  0.60f,0.55f, 0.30f,0.85f, 0,0.98f};
    draw_lathe(f, body, pr, 7, 12, body_c, NULL);
  }
  /* belly patch: small flattened ball, low, mostly tucked under */
  draw_ball(f, m4_mul(body, m4_mul(m4_translate(0,-0.48f,0.20f), m4_scale(0.46f,0.38f,0.50f))),
            1.0f, belly_c, 10);
  /* eyes: white ovals + pupils, style-driven (symmetric, slight right glance) */
  mstyle_t st = g_mstyle;
  draw_ball(f, m4_mul(body, m4_mul(m4_translate(-0.26f,0.28f,0.62f), m4_scale(st.eye_w,st.eye_h,0.10f))), 1.0f, white, 8);
  draw_ball(f, m4_mul(body, m4_mul(m4_translate( 0.26f,0.28f,0.62f), m4_scale(st.eye_w,st.eye_h,0.10f))), 1.0f, white, 8);
  draw_ball(f, m4_mul(body, m4_mul(m4_translate(-0.23f,0.26f,0.74f), m4_scale(st.pup_w,st.pup_h,0.05f))), 1.0f, dark, 6);
  draw_ball(f, m4_mul(body, m4_mul(m4_translate( 0.29f,0.26f,0.74f), m4_scale(st.pup_w,st.pup_h,0.05f))), 1.0f, dark, 6);
  if(st.glint){
    draw_ball(f, m4_mul(body, m4_mul(m4_translate(-0.27f,0.33f,0.81f), m4_scale(0.050f,0.065f,0.02f))), 1.0f, white, 5);
    draw_ball(f, m4_mul(body, m4_mul(m4_translate( 0.25f,0.33f,0.81f), m4_scale(0.050f,0.065f,0.02f))), 1.0f, white, 5);
  }
  /* mouth: small dark oval, clear of the belly */
  draw_ball(f, m4_mul(body, m4_mul(m4_translate(0,0.02f,0.80f), m4_scale(0.13f,0.05f,0.04f))), 1.0f, dark, 6);
  /* floating mitten hands + boots (positioned per pose, parented to root) */
  draw_ball(f, m4_mul(root, m4_translate(p.hand_l.x,p.hand_l.y,p.hand_l.z)), 0.22f, mitt_c, 8);
  draw_ball(f, m4_mul(root, m4_translate(p.hand_r.x,p.hand_r.y,p.hand_r.z)), 0.22f, mitt_c, 8);
  draw_ball(f, m4_mul(root, m4_mul(m4_translate(p.foot_l.x,p.foot_l.y,p.foot_l.z), m4_scale(1.1f,0.72f,1.35f))), 0.24f, mitt_c, 8);
  draw_ball(f, m4_mul(root, m4_mul(m4_translate(p.foot_r.x,p.foot_r.y,p.foot_r.z), m4_scale(1.1f,0.72f,1.35f))), 0.24f, mitt_c, 8);
  /* antenna: thin stalk + star-ball, swaying */
  m4 ant = m4_mul(body, m4_mul(m4_translate(0,0.90f,0), m4_rotz(p.ant)));
  draw_prism(f, ant, 5, 0.035f,0.025f,0.45f, dark, NULL, 0);
  draw_ball(f, m4_mul(ant, m4_translate(0,0.55f,0)), 0.16f, star_c, 6);
}

static mpose_t mascot_idle(void){
  mpose_t p={0};
  p.squash=1.0f;
  p.hand_l=(v3){-0.88f,-0.42f,0.12f}; p.hand_r=(v3){0.88f,-0.42f,0.12f};
  p.foot_l=(v3){-0.34f,-0.90f,0.18f}; p.foot_r=(v3){0.34f,-0.90f,0.18f};
  p.ant=0.10f;
  return p;
}

/* ================= the bouncy cube (demo-1 character) =====================
 * a cube with a face and squash & stretch: personality from eyes + motion,
 * zero modeling. squash: s<1 lands fat, s>1 stretches in flight. */
static void draw_bouncy_cube(fb_t *f, v3 at, float yaw, float squash,
                             float lean, v3 col){
  float sy=squash, sxz=1.0f/sqrtf(squash); /* volume-ish preserving */
  m4 root = m4_mul(m4_translate(at.x,at.y,at.z), m4_roty(yaw));
  root = m4_mul(root, m4_rotz(lean));
  root = m4_mul(root, m4_scale(sxz,sy,sxz));
  draw_box(f, root, (v3){1.0f,1.0f,1.0f},(v3){0,0.5f,0}, col, NULL);
  /* face on +z: white eyes + pupils, cheeky offset brows */
  v3 white={0.95f,0.95f,0.92f}, dark={0.08f,0.07f,0.10f};
  draw_box(f, root, (v3){0.20f,0.30f,0.03f},(v3){-0.20f,0.62f,0.50f}, white, NULL);
  draw_box(f, root, (v3){0.20f,0.30f,0.03f},(v3){ 0.20f,0.62f,0.50f}, white, NULL);
  draw_box(f, root, (v3){0.10f,0.16f,0.03f},(v3){-0.17f,0.58f,0.52f}, dark, NULL);
  draw_box(f, root, (v3){0.10f,0.16f,0.03f},(v3){ 0.17f,0.58f,0.52f}, dark, NULL);
  draw_box(f, root, (v3){0.26f,0.05f,0.03f},(v3){ 0.0f,0.30f,0.51f}, dark, NULL); /* mouth */
}

/* ================= graybox primitives (beyond axis-aligned boxes) =========
 * quick low-poly structure vocabulary: extruded n-gons (towers, pillars,
 * cones), lathes (domes, bulged towers), arc bridges, spiral steps — all a
 * few numbers each, all freely rotated. This is the shape language that keeps
 * grayboxes from reading as "axis-aligned cubes". */

/* box with uv scaled by face size — keeps checker texel density consistent
 * on walls/slabs of any proportion (the graybox structural unit) */
static void draw_gbox(fb_t *f, m4 xf, v3 size, v3 center, v3 col,
                      const tex_t *t, float uvs){
  float hx=size.x/2, hy=size.y/2, hz=size.z/2;
  v3 c=center;
  v3 P[8]={
    {c.x-hx,c.y-hy,c.z-hz},{c.x+hx,c.y-hy,c.z-hz},{c.x+hx,c.y+hy,c.z-hz},{c.x-hx,c.y+hy,c.z-hz},
    {c.x-hx,c.y-hy,c.z+hz},{c.x+hx,c.y-hy,c.z+hz},{c.x+hx,c.y+hy,c.z+hz},{c.x-hx,c.y+hy,c.z+hz}};
  static const int F[6][4]={{0,1,2,3},{5,4,7,6},{4,0,3,7},{1,5,6,2},{3,2,6,7},{4,5,1,0}};
  static const v3 N[6]={{0,0,-1},{0,0,1},{-1,0,0},{1,0,0},{0,1,0},{0,-1,0}};
  static const int FD[6][2]={{0,1},{0,1},{2,1},{2,1},{0,2},{0,2}}; /* u,v axes per face: 0=x 1=y 2=z */
  float dim[3]={size.x,size.y,size.z};
  for(int i=0;i<6;i++){
    float uw=dim[FD[i][0]]*uvs, vh=dim[FD[i][1]]*uvs;
    vtx_t v[4];
    for(int k=0;k<4;k++){
      v[k].pos=P[F[i][k]];
      v[k].u=(k==1||k==2)?uw:0; v[k].v=(k>=2)?vh:0;
      v[k].col=col; v[k].nrm=N[i];
    }
    quad(f,&xf,v[0],v[1],v[2],v[3],t);
  }
}

/* extruded regular n-gon: r0 bottom radius, r1 top radius, height h.
 * caps: bit0 = top, bit1 = bottom. uv wraps around the perimeter. */
static void draw_prism(fb_t *f, m4 xf, int n, float r0, float r1, float h,
                       v3 col, const tex_t *t, int caps){
  for(int i=0;i<n;i++){
    float a0=i*6.2831853f/n, a1=(i+1)*6.2831853f/n;
    float c0=cosf(a0),s0=sinf(a0),c1=cosf(a1),s1=sinf(a1);
    v3 nrm = v3_norm((v3){c0+c1, 0, s0+s1});
    float u0=(float)i/n*4.0f, u1=(float)(i+1)/n*4.0f, vv=h/2;
    vtx_t A={{r1*c0,h,r1*s0},u0,0,col,nrm}, B={{r1*c1,h,r1*s1},u1,0,col,nrm};
    vtx_t C={{r0*c1,0,r0*s1},u1,vv,col,nrm}, D={{r0*c0,0,r0*s0},u0,vv,col,nrm};
    quad(f,&xf,A,B,C,D,t);
    if((caps&1) && r1>0.001f){
      vtx_t P={{0,h,0},0.5f,0.5f,col,(v3){0,1,0}};
      vtx_t Q={{r1*c0,h,r1*s0},0.5f+0.4f*c0,0.5f+0.4f*s0,col,(v3){0,1,0}};
      vtx_t R={{r1*c1,h,r1*s1},0.5f+0.4f*c1,0.5f+0.4f*s1,col,(v3){0,1,0}};
      tri(f,&xf,P,Q,R,t);
    }
    if(caps&2){
      vtx_t P={{0,0,0},0.5f,0.5f,col,(v3){0,-1,0}};
      vtx_t Q={{r0*c1,0,r0*s1},0.5f+0.4f*c1,0.5f+0.4f*s1,col,(v3){0,-1,0}};
      vtx_t R={{r0*c0,0,r0*s0},0.5f+0.4f*c0,0.5f+0.4f*s0,col,(v3){0,-1,0}};
      tri(f,&xf,P,Q,R,t);
    }
  }
}

/* lathe: revolve a profile of (radius, y) pairs around Y. npts>=2. */
static void draw_lathe(fb_t *f, m4 xf, const float *prof, int npts, int n,
                       v3 col, const tex_t *t){
  for(int j=0;j+1<npts;j++){
    float ra=prof[j*2], ya=prof[j*2+1], rb=prof[j*2+2], yb=prof[j*2+3];
    for(int i=0;i<n;i++){
      float a0=i*6.2831853f/n, a1=(i+1)*6.2831853f/n;
      float c0=cosf(a0),s0=sinf(a0),c1=cosf(a1),s1=sinf(a1);
      /* slope normal in the profile plane */
      float dy=yb-ya, dr=rb-ra, len=sqrtf(dy*dy+dr*dr);
      float nr = len>1e-6f? dy/len : 1, ny = len>1e-6f? -dr/len : 0;
      v3 nA={nr*c0,ny,nr*s0}, nB={nr*c1,ny,nr*s1};
      float u0=(float)i/n*4.0f, u1=(float)(i+1)/n*4.0f;
      float v0=(float)j/(npts-1)*2.0f, v1=(float)(j+1)/(npts-1)*2.0f;
      vtx_t A={{rb*c0,yb,rb*s0},u0,v1,col,nA}, B={{rb*c1,yb,rb*s1},u1,v1,col,nB};
      vtx_t C={{ra*c1,ya,ra*s1},u1,v0,col,nB}, D={{ra*c0,ya,ra*s0},u0,v0,col,nA};
      quad(f,&xf,A,B,C,D,t);
    }
  }
}

/* arc bridge: deck of segments along a vertical arc spanning length L,
 * rising 'rise' at the middle, deck width w, thickness th. */
static void draw_arc_bridge(fb_t *f, m4 xf, float L, float rise, float w,
                            float th, int segs, v3 col, const tex_t *t){
  for(int i=0;i<segs;i++){
    float t0=(float)i/segs, t1=(float)(i+1)/segs;
    float x0=(t0-0.5f)*L, x1=(t1-0.5f)*L;
    float y0=rise*sinf(t0*3.14159265f), y1=rise*sinf(t1*3.14159265f);
    /* one deck slab per segment: top, bottom, and side faces */
    float u0=t0*6, u1=t1*6;
    v3 up={0,1,0}, dn={0,-1,0};
    vtx_t A={{x0,y0,-w/2},u0,0,col,up}, B={{x1,y1,-w/2},u1,0,col,up};
    vtx_t C={{x1,y1, w/2},u1,1,col,up}, D={{x0,y0, w/2},u0,1,col,up};
    quad(f,&xf,A,B,C,D,t);
    vtx_t E={{x0,y0-th,-w/2},u0,0,col,dn}, F={{x1,y1-th,-w/2},u1,0,col,dn};
    vtx_t G={{x1,y1-th, w/2},u1,1,col,dn}, H={{x0,y0-th, w/2},u0,1,col,dn};
    quad(f,&xf,E,F,G,H,t);
    v3 sn={0,0,-1};
    vtx_t I={{x0,y0,-w/2},u0,0,col,sn}, J={{x1,y1,-w/2},u1,0,col,sn};
    vtx_t K={{x1,y1-th,-w/2},u1,0.4f,col,sn}, M={{x0,y0-th,-w/2},u0,0.4f,col,sn};
    quad(f,&xf,I,J,K,M,t);
    v3 sp={0,0,1};
    vtx_t N={{x0,y0,w/2},u0,0,col,sp}, O={{x1,y1,w/2},u1,0,col,sp};
    vtx_t P={{x1,y1-th,w/2},u1,0.4f,col,sp}, Q={{x0,y0-th,w/2},u0,0.4f,col,sp};
    quad(f,&xf,N,O,P,Q,t);
  }
}

/* ================= tiny OBJ loader (static props from CC0 packs) ========= */
typedef struct {
  float *pos; float *uv;      /* xyz / uv arrays */
  int *tri;                    /* per tri: 3x (pos idx, uv idx) = 6 ints */
  int npos, nuv, ntri;
} obj_t;

static obj_t obj_load(const char *path){
  obj_t o={0};
  FILE *fp=fopen(path,"rb");
  if(!fp){ fprintf(stderr,"obj_load: %s missing\n",path); exit(1); }
  size_t cp=0,cu=0,ct=0;
  char line[512];
  while(fgets(line,sizeof line,fp)){
    if(line[0]=='v'&&line[1]==' '){
      if((size_t)o.npos*3+3 > cp){ cp=cp?cp*2:3072; o.pos=realloc(o.pos,cp*4); }
      sscanf(line+2,"%f %f %f",&o.pos[o.npos*3],&o.pos[o.npos*3+1],&o.pos[o.npos*3+2]);
      o.npos++;
    }else if(line[0]=='v'&&line[1]=='t'){
      if((size_t)o.nuv*2+2 > cu){ cu=cu?cu*2:2048; o.uv=realloc(o.uv,cu*4); }
      sscanf(line+3,"%f %f",&o.uv[o.nuv*2],&o.uv[o.nuv*2+1]);
      o.uv[o.nuv*2+1] = 1.0f - o.uv[o.nuv*2+1]; /* obj v-up -> our v-down */
      o.nuv++;
    }else if(line[0]=='f'&&line[1]==' '){
      int vi[8],ti[8],n=0;
      char *tok=strtok(line+2," \t\r\n");
      while(tok && n<8){
        int v=0,t=0;
        if(sscanf(tok,"%d/%d",&v,&t)<1) break;
        vi[n]=v<0? o.npos+v : v-1;
        ti[n]=t? (t<0? o.nuv+t : t-1) : -1;
        n++; tok=strtok(NULL," \t\r\n");
      }
      for(int k=1;k+1<n;k++){
        if((size_t)(o.ntri+1)*6 > ct){ ct=ct?ct*2:6144; o.tri=realloc(o.tri,ct*4); }
        int *d=&o.tri[o.ntri*6];
        d[0]=vi[0];d[1]=ti[0]; d[2]=vi[k];d[3]=ti[k]; d[4]=vi[k+1];d[5]=ti[k+1];
        o.ntri++;
      }
    }
  }
  fclose(fp);
  fprintf(stderr,"obj %s: %d verts %d tris\n",path,o.npos,o.ntri);
  return o;
}

static void obj_draw(fb_t *f, obj_t *o, m4 xf, v3 tint, const tex_t *t){
  for(int i=0;i<o->ntri;i++){
    int *d=&o->tri[i*6];
    vtx_t v[3];
    for(int k=0;k<3;k++){
      float *p=&o->pos[d[k*2]*3];
      v[k].pos=(v3){p[0],p[1],p[2]};
      if(d[k*2+1]>=0){ v[k].u=o->uv[d[k*2+1]*2]; v[k].v=o->uv[d[k*2+1]*2+1]; }
      else { v[k].u=v[k].v=0; }
      v[k].col=tint;
    }
    /* flat face normal (era look: no smoothing groups) */
    v3 e1={v[1].pos.x-v[0].pos.x,v[1].pos.y-v[0].pos.y,v[1].pos.z-v[0].pos.z};
    v3 e2={v[2].pos.x-v[0].pos.x,v[2].pos.y-v[0].pos.y,v[2].pos.z-v[0].pos.z};
    v3 n=v3_norm(v3_cross(e1,e2));
    v[0].nrm=v[1].nrm=v[2].nrm=n;
    tri(f,&xf,v[0],v[1],v[2],t);
  }
}

/* ================= scene dump (GPU-path comparison) =================
 * with --dump, scenes route through the capture hook and write a .c3dd file:
 * camera + fog + sky + textures + world-space lit triangle list. gpu_proto
 * renders the identical content through SDL_GPU. */

static const char *g_dump = NULL;
static uint32_t g_sky[2];
typedef struct { float pos[3], uv[2]; uint8_t col[4]; } dvtx;
typedef struct { int32_t tex; uint32_t flags; dvtx v[3]; } dtri;
static dtri *g_tris; static size_t g_ntris, g_captris;
static const tex_t *g_reg[32]; static int g_nreg;
/* value copies for finish(): scenes pass stack-local tex_t structs whose
 * lifetime ends with the scene function; px is heap and leaked on purpose */
static tex_t g_regcpy[32];

static int reg_tex(const tex_t *t){
  if(!t) return -1;
  for(int i=0;i<g_nreg;i++) if(g_reg[i]==t) return i;
  if(g_nreg>=32) return 0; /* registry full (per-tile-baked scenes don't dump) */
  g_reg[g_nreg]=t; g_regcpy[g_nreg]=*t; return g_nreg++;
}
static void cap_vtx(dvtx *d, vtx_t v, float alpha){
  d->pos[0]=v.pos.x; d->pos[1]=v.pos.y; d->pos[2]=v.pos.z;
  d->uv[0]=v.u; d->uv[1]=v.v;
  d->col[0]=(uint8_t)(v.col.x*255.f+0.5f);
  d->col[1]=(uint8_t)(v.col.y*255.f+0.5f);
  d->col[2]=(uint8_t)(v.col.z*255.f+0.5f);
  d->col[3]=(uint8_t)(alpha*255.f+0.5f);
}
static void cap_tri(fb_t *f, vtx_t a, vtx_t b, vtx_t c, const tex_t *t){
  if(g_ntris==g_captris){
    g_captris = g_captris? g_captris*2 : 4096;
    g_tris = realloc(g_tris, g_captris*sizeof *g_tris);
  }
  dtri *d = &g_tris[g_ntris++];
  d->tex = reg_tex(t);
  d->flags = (f->alpha_test?1u:0u)
           | (f->filter==FILT_NEAREST?2u:0u)
           | (f->blend>0?4u:0u);
  float alpha = f->blend>0? f->blend : 1.0f;
  cap_vtx(&d->v[0],a,alpha); cap_vtx(&d->v[1],b,alpha); cap_vtx(&d->v[2],c,alpha);
}
static void sky(fb_t *f, uint32_t top, uint32_t bot){
  g_sky[0]=top; g_sky[1]=bot;
  if(!g_dump) fb_clear_gradient(f, top, bot);
}
static void finish(fb_t *f, const char *out, int scale, int quant){
  if(!g_dump){ fb_write_png(f,out,scale,quant); return; }
  FILE *fp = fopen(g_dump,"wb");
  if(!fp){ fprintf(stderr,"can't write %s\n",g_dump); exit(1); }
  uint32_t magic=0x44443343u, ver=1; /* 'C3DD' */
  fwrite(&magic,4,1,fp); fwrite(&ver,4,1,fp);
  int32_t wh[4]={f->w,f->h,scale,quant};
  fwrite(wh,4,4,fp);
  fwrite(f->view.m,4,16,fp); fwrite(f->proj.m,4,16,fp);
  float fog[6]={(float)f->fog_on,f->fog_start,f->fog_end,f->fog_color.x,f->fog_color.y,f->fog_color.z};
  fwrite(fog,4,6,fp);
  fwrite(g_sky,4,2,fp);
  uint32_t n=(uint32_t)g_nreg;
  fwrite(&n,4,1,fp);
  for(int i=0;i<g_nreg;i++){
    int32_t d[2]={g_regcpy[i].w,g_regcpy[i].h};
    fwrite(d,4,2,fp);
    fwrite(g_regcpy[i].px,4,(size_t)g_regcpy[i].w*g_regcpy[i].h,fp);
  }
  n=(uint32_t)g_ntris;
  fwrite(&n,4,1,fp);
  fwrite(g_tris,sizeof *g_tris,g_ntris,fp);
  fclose(fp);
  fprintf(stderr,"wrote %s (%zu tris, %d textures)\n",g_dump,g_ntris,g_nreg);
}

static tex_t g_tex[T_MAX];
static void load_textures(void){
  g_tex[T_GRASS]=tx_grass(); g_tex[T_DIRT]=tx_dirt(); g_tex[T_CLIFF]=tx_cliff();
  g_tex[T_STONE]=tx_stone(); g_tex[T_WATER]=tx_water();
}

/* prop: a chunky low-poly tree (cone canopy on box trunk) */
static void draw_tree(fb_t *f, v3 at, float scale, uint32_t seed){
  uint32_t s=seed;
  float lean = ((xs32(&s)&255)/255.0f-0.5f)*0.15f;
  m4 root = m4_mul(m4_translate(at.x,at.y,at.z), m4_mul(m4_roty((xs32(&s)&255)/255.0f*6.28f), m4_rotz(lean)));
  root = m4_mul(root, m4_scale(scale,scale,scale));
  draw_box(f, root, (v3){0.35f,1.6f,0.35f},(v3){0,0.8f,0},(v3){0.45f,0.32f,0.22f}, NULL);
  /* canopy: 3 stacked shrinking boxes reads nicely at low res */
  v3 green={0.30f,0.55f,0.30f}, green2={0.36f,0.62f,0.32f};
  draw_box(f, root, (v3){1.7f,0.7f,1.7f},(v3){0,1.9f,0}, green, NULL);
  draw_box(f, root, (v3){1.2f,0.6f,1.2f},(v3){0,2.5f,0}, green2, NULL);
  draw_box(f, root, (v3){0.6f,0.5f,0.6f},(v3){0,3.0f,0}, green, NULL);
}

static void scene_common(fb_t *f, terrain_t *T){
  terr_draw(f, T, g_tex);
  /* trees scattered on grass */
  uint32_t s=42;
  for(int i=0;i<14;i++){
    float x = 2+ (xs32(&s)%440)/10.0f, z = 2+(xs32(&s)%440)/10.0f;
    int tx=(int)(x/T->tile_size), tz=(int)(z/T->tile_size);
    if(T->t[tz][tx].top!=T_GRASS) continue;
    draw_tree(f,(v3){x, terr_sample(T,x,z), z}, 0.8f+(xs32(&s)%40)/100.0f, s);
  }
}

static void scene_n64(const char *out){
  fb_t *f = fb_new(320,240);
  f->filter=FILT_3POINT; f->fog_on=1;
  f->fog_color=(v3){0.65f,0.72f,0.86f}; f->fog_start=26; f->fog_end=58;
  f->ambient=(v3){0.42f,0.42f,0.48f};
  f->sun_dir=v3_norm((v3){-0.45f,-1.0f,-0.3f});
  sky(f, 0xffe89a56u, 0xfff2d5abu);
  terrain_t *T=terr_demo();
  /* low third-person camera looking across the terrain at the character;
   * face the guy toward the camera so the face reads */
  v3 guy_at={33.0f, 0, 33.0f};
  guy_at.y = terr_sample(T,guy_at.x,guy_at.z);
  f->view = m4_lookat((v3){guy_at.x-7.5f, guy_at.y+4.2f, guy_at.z+9.0f},
                      (v3){guy_at.x, guy_at.y+1.4f, guy_at.z-2.0f}, (v3){0,1,0});
  f->proj = m4_persp(55, 320.0f/240.0f, 0.3f, 120);
  scene_common(f,T);
  m4 root=m4_mul(m4_translate(guy_at.x,guy_at.y,guy_at.z), m4_roty(2.6f));
  draw_guy(f, root, walk_pose(0.25f), NULL);
  finish(f,out,3,1);
  free(T);
}

/* neutral terrain detail texture: near-white mottle that multiplies the
 * vertex-color palette (Body Harvest keeps some texture on its terrain) */
static tex_t tx_detail(void){
  tex_t t=tex_new(64,64);
  for(int y=0;y<64;y++)for(int x=0;x<64;x++){
    float v = 0.86f + 0.14f*fbm(1201,x,y,64);
    uint32_t s=(uint32_t)(x*73856093u ^ y*19349663u ^ 777u); s^=s<<13;s^=s>>17;s^=s<<5;
    if((s&255)>249) v*=0.82f;          /* sparse dark flecks */
    if((s&255)<3)   v*=1.10f;
    uint8_t g=(uint8_t)(v*255>255?255:v*255);
    px(&t,x,y,(rgb8){g,g,g});
  }
  return t;
}

static void scene_openworld(const char *out){
  /* demo-2 target sketch: Body-Harvest-style ZERO-TEXTURE terrain — vertex
   * colors from a height-banded palette, per-vertex sun + fog, posterized
   * "painted" bands. No textures anywhere except nothing at all. */
  fb_t *f = fb_new(320,240);
  f->filter=FILT_NEAREST; f->fog_on=1;
  f->fog_color=(v3){0.72f,0.76f,0.88f}; f->fog_start=40; f->fog_end=110;
  f->ambient=(v3){0.42f,0.44f,0.50f};
  f->sun_dir=v3_norm((v3){-0.55f,-1.0f,-0.2f});
  sky(f, 0xffd89660u, 0xffeed8b8u);
  tex_t g_detail = tx_detail();
  const int N=72; const float s=2.0f;
  static float H[73][73];
  for(int z=0;z<=N;z++)for(int x=0;x<=N;x++){
    float base = 0.55f*vnoise(31,x*3,z*3,256,64)+0.30f*vnoise(37,x*3,z*3,256,32)
               + 0.15f*vnoise(41,x*3,z*3,256,16);
    float m = base*base;                    /* ridge-ish */
    H[z][x] = m*20.0f - 1.0f;
  }
  /* stand the figure on a grass hill near the intended spot */
  v3 guy_at = {58, 0, 96};
  {
    float best=1e9f;
    for(int z=40;z<58;z++)for(int x=22;x<34;x++){
      float h=H[z][x];
      if(h>1.2f && h<3.2f){
        float d=(x*s-58)*(x*s-58)+(z*s-96)*(z*s-96);
        if(d<best){ best=d; guy_at.x=x*s; guy_at.z=z*s; }
      }
    }
    guy_at.y = H[(int)(guy_at.z/s)][(int)(guy_at.x/s)];
    f->view = m4_lookat((v3){guy_at.x+5.5f, guy_at.y+3.6f, guy_at.z+8.5f},
                        (v3){guy_at.x-14.0f, guy_at.y+1.0f, guy_at.z-30.0f}, (v3){0,1,0});
    f->proj = m4_persp(55, 320.0f/240.0f, 0.3f, 160);
  }
  for(int z=0;z<N;z++)for(int x=0;x<N;x++){
    float hs[4]={H[z][x],H[z][x+1],H[z+1][x],H[z+1][x+1]};
    v3 cols[4];
    for(int k=0;k<4;k++){
      float h=hs[k];
      uint32_t sd=(uint32_t)((x+k%2)*73856093u ^ (z+k/2)*19349663u); sd^=sd<<13;sd^=sd>>17;sd^=sd<<5;
      float jit = ((sd&255)/255.0f-0.5f)*0.35f;
      h += jit;
      v3 c;
      if(h < 0.15f)      c=(v3){0.76f,0.70f,0.50f};  /* sand */
      else if(h < 2.2f)  c=(v3){0.36f,0.55f,0.28f};  /* grass */
      else if(h < 4.2f)  c=(v3){0.26f,0.43f,0.24f};  /* dark grass */
      else if(h < 6.5f)  c=(v3){0.47f,0.43f,0.41f};  /* rock */
      else               c=(v3){0.92f,0.93f,0.97f};  /* snow */
      cols[k]=c;
    }
    v3 n = v3_norm((v3){ (hs[0]+hs[2]-hs[1]-hs[3])/(2*s), 2.0f,
                         (hs[0]+hs[1]-hs[2]-hs[3])/(2*s) });
    float x0=x*s,x1=(x+1)*s,z0=z*s,z1=(z+1)*s;
    /* detail texture tiles once per tile, uv continuous in world space */
    vtx_t A={{x0,hs[0],z0},(float)x,(float)z,cols[0],n}, B={{x1,hs[1],z0},x+1.0f,(float)z,cols[1],n};
    vtx_t C={{x1,hs[3],z1},x+1.0f,z+1.0f,cols[3],n}, D={{x0,hs[2],z1},(float)x,z+1.0f,cols[2],n};
    quad(f,NULL,A,B,C,D,&g_detail);
  }
  /* water plane: blended, doesn't write depth, tints everything below 0 */
  f->blend=0.55f;
  for(int z=0;z<N;z+=8)for(int x=0;x<N;x+=8){
    float x0=x*s,x1=(x+8)*s,z0=z*s,z1=(z+8)*s;
    v3 wc={0.30f,0.48f,0.62f};
    vtx_t A={{x0,0,z0},0,0,wc,(v3){0,0,0}}, B={{x1,0,z0},0,0,wc,(v3){0,0,0}};
    vtx_t C={{x1,0,z1},0,0,wc,(v3){0,0,0}}, D={{x0,0,z1},0,0,wc,(v3){0,0,0}};
    quad(f,NULL,A,B,C,D,NULL);
  }
  f->blend=0;
  /* cone trees on the grass bands (untextured, flat color) */
  uint32_t sd=99;
  for(int i=0;i<160;i++){
    float tx=(xs32(&sd)%(N*20))/10.0f, tz=(xs32(&sd)%(N*20))/10.0f;
    int ix=(int)(tx/s), iz=(int)(tz/s);
    float h=H[iz][ix];
    if(h<0.4f||h>3.8f) continue;
    float ddx=tx-guy_at.x, ddz=tz-guy_at.z;
    if(ddx*ddx+ddz*ddz < 36.0f) continue; /* keep the figure's stage clear */
    float sc=0.7f+(xs32(&sd)%50)/100.0f;
    m4 xf=m4_translate(tx,h,tz);
    draw_prism(f, xf, 5, 0.14f*sc,0.14f*sc,0.7f*sc, (v3){0.42f,0.30f,0.22f}, NULL, 0);
    m4 xf2=m4_translate(tx,h+0.6f*sc,tz);
    draw_prism(f, xf2, 6, 0.85f*sc,0.0f,2.2f*sc, (v3){0.22f,0.42f,0.26f}, NULL, 0);
  }
  /* the figure on a foreground ridge */
  {
    int gx=(int)(guy_at.x/s), gz=(int)(guy_at.z/s);
    guy_at.y = H[gz][gx];
    m4 root=m4_mul(m4_translate(guy_at.x,guy_at.y,guy_at.z), m4_roty(2.9f));
    draw_guy(f, root, walk_pose(0.6f), NULL);
  }
  finish(f,out,3,1);
}

static void scene_graybox(const char *out){
  /* demo-1 target: platformer graybox — non-axis-aligned composition from the
   * primitive vocabulary, "material checkers" everywhere, N64 preset, bouncy
   * cube protagonist. No art assets at all. */
  fb_t *f = fb_new(320,240);
  f->filter=FILT_3POINT; f->fog_on=1;
  f->fog_color=(v3){0.62f,0.70f,0.85f}; f->fog_start=28; f->fog_end=62;
  f->ambient=(v3){0.44f,0.44f,0.50f};
  f->sun_dir=v3_norm((v3){-0.5f,-1.0f,-0.25f});
  sky(f, 0xffe89a56u, 0xfff2d5abu);
  load_graybox_textures();
  v3 w={1,1,1};
  f->view = m4_lookat((v3){-2.0f,7.0f,26.0f},(v3){18.0f,4.0f,10.0f},(v3){0,1,0});
  f->proj = m4_persp(52, 320.0f/240.0f, 0.3f, 120);

  /* ground: subdivided so per-vertex fog behaves */
  for(int gz=0;gz<14;gz++)for(int gx=0;gx<14;gx++){
    float x0=-8+gx*5.0f, z0=-8+gz*5.0f;
    vtx_t A={{x0,0,z0},0,0,w,(v3){0,1,0}}, B={{x0+5,0,z0},2.5f,0,w,(v3){0,1,0}};
    vtx_t C={{x0+5,0,z0+5},2.5f,2.5f,w,(v3){0,1,0}}, D={{x0,0,z0+5},0,2.5f,w,(v3){0,1,0}};
    quad(f,NULL,A,B,C,D,&g_gb[GB_GRASS]);
  }
  /* hexagonal keep + wood cone roof + entry ramp */
  draw_prism(f, m4_translate(20,0,8), 6, 5.0f,4.4f,9.0f, w, &g_gb[GB_STONE], 1);
  draw_prism(f, m4_translate(20,9,8), 6, 5.4f,0.0f,4.2f, w, &g_gb[GB_WOOD], 0);
  /* stone stairs up to the keep (4 chunky steps, rotated toward the door) */
  for(int i=0;i<4;i++){
    m4 sx = m4_mul(m4_translate(14.2f+i*0.95f,0,12.6f-i*0.75f), m4_roty(0.65f));
    draw_gbox(f, sx, (v3){3.2f,0.55f+i*0.55f,1.2f},(v3){0,(0.55f+i*0.55f)/2,0},
              w, &g_gb[GB_STONE], 0.5f);
  }
  /* round tower with lathe dome, connected by a diagonal wall */
  draw_prism(f, m4_translate(34,0,16), 12, 2.6f,2.3f,6.5f, w, &g_gb[GB_STONE], 1);
  {
    float dome[8]={2.5f,0.0f, 2.2f,1.0f, 1.4f,1.8f, 0.0f,2.2f};
    draw_lathe(f, m4_translate(34,6.5f,16), dome, 4, 12, w, &g_gb[GB_METAL]);
  }
  /* diagonal curtain walls (rotated slabs, not axis-aligned) */
  draw_gbox(f, m4_mul(m4_translate(27.2f,0,12.2f), m4_roty(-0.5f)),
            (v3){10.0f,3.4f,0.8f},(v3){0,1.7f,0}, w, &g_gb[GB_STONE], 0.5f);
  draw_gbox(f, m4_mul(m4_translate(12.0f,0,3.0f), m4_roty(0.6f)),
            (v3){9.0f,2.6f,0.8f},(v3){0,1.3f,0}, w, &g_gb[GB_STONE], 0.5f);
  /* arc bridge from the keep ledge over the gap toward the platforms */
  draw_arc_bridge(f, m4_mul(m4_translate(13.5f,4.2f,7.0f), m4_roty(0.35f)),
                  10.0f, 1.4f, 2.2f, 0.5f, 8, w, &g_gb[GB_WOOD]);
  /* ascending floating platforms leading to the bridge, rotated off-axis */
  float px_[3]={5.0f,7.2f,8.6f}, pz_[3]={21.5f,17.5f,13.5f};
  float ph_[3]={1.8f,2.7f,3.5f};
  for(int i=0;i<3;i++){
    draw_gbox(f, m4_mul(m4_translate(px_[i],ph_[i],pz_[i]), m4_roty(0.6f+0.35f*i)),
              (v3){3.0f,0.6f,3.0f},(v3){0,-0.3f,0}, w,
              &g_gb[i%2? GB_ACCENT: GB_METAL], 0.5f);
  }
  /* pillars scattered for depth */
  draw_prism(f, m4_translate(4,0,4), 8, 0.9f,0.7f,5.0f, w, &g_gb[GB_STONE], 1);
  draw_prism(f, m4_translate(41,0,26), 8, 1.1f,0.8f,3.6f, w, &g_gb[GB_STONE], 1);
  /* the bouncy cube: mid-leap between platforms, stretched, with blob shadow */
  {
    tex_t shadow = tx_shadow();
    v3 at={7.2f, ph_[1]+1.5f, 17.5f};
    f->blend=0.5f;
    float sy_=ph_[1]+0.05f;
    vtx_t A={{at.x-0.8f,sy_,at.z-0.8f},0,0,w,(v3){0,0,0}};
    vtx_t B={{at.x+0.8f,sy_,at.z-0.8f},1,0,w,(v3){0,0,0}};
    vtx_t C={{at.x+0.8f,sy_,at.z+0.8f},1,1,w,(v3){0,0,0}};
    vtx_t D={{at.x-0.8f,sy_,at.z+0.8f},0,1,w,(v3){0,0,0}};
    quad(f,NULL,A,B,C,D,&shadow);
    f->blend=0;
    draw_bouncy_cube(f, at, -0.5f, 1.30f, 0.12f, (v3){0.92f,0.34f,0.30f});
  }
  finish(f,out,3,1);
}

static int file_exists(const char *p);
static tex_t tex_crop(const tex_t *t, int x0, int y0, int w, int h);

/* rounder, bigger tree for the RO look: prism trunk + stacked lathe canopy */
static void draw_tree_round(fb_t *f, v3 at, float sc, uint32_t seed){
  uint32_t s=seed;
  float yaw=(xs32(&s)&255)/255.0f*6.28f;
  m4 root=m4_mul(m4_translate(at.x,at.y,at.z), m4_roty(yaw));
  v3 trunk={0.42f,0.30f,0.20f};
  v3 g1={0.24f,0.44f,0.26f}, g2={0.30f,0.52f,0.28f};
  draw_prism(f, root, 6, 0.30f*sc,0.20f*sc,1.7f*sc, trunk, NULL, 0);
  draw_ball(f, m4_mul(root, m4_translate(0,2.1f*sc,0)), 1.20f*sc, g1, 9);
  draw_ball(f, m4_mul(root, m4_translate(0.55f*sc,1.75f*sc,0.3f*sc)), 0.75f*sc, g2, 8);
  draw_ball(f, m4_mul(root, m4_translate(-0.5f*sc,1.9f*sc,-0.25f*sc)), 0.70f*sc, g2, 8);
  draw_ball(f, m4_mul(root, m4_translate(0,2.9f*sc,0)), 0.65f*sc, g2, 8);
}

/* RO-scene terrain: multi-level plateau, a river with a bridge crossing,
 * winding path — composed, not minecraft-flat */
static terrain_t *terr_demo_ro(void){
  terrain_t *T = calloc(1,sizeof *T);
  T->tile_size = 2.0f;
  for(int z=0;z<TH;z++)for(int x=0;x<TW;x++){
    tile_t *t=&T->t[z][x];
    t->h[0]=2.2f*fbm(777, x*4,     z*4,     128)-1.1f;
    t->h[1]=2.2f*fbm(777,(x+1)*4,  z*4,     128)-1.1f;
    t->h[2]=2.2f*fbm(777, x*4,    (z+1)*4,  128)-1.1f;
    t->h[3]=2.2f*fbm(777,(x+1)*4, (z+1)*4,  128)-1.1f;
    t->top = T_GRASS;
  }
  /* two-level plateau with a landmark spot on top */
  for(int z=3;z<10;z++)for(int x=12;x<20;x++){ terr_set_tile_flat(T,x,z,3.0f);  terr_paint(T,x,z,T_STONE); }
  for(int z=4;z<8;z++) for(int x=14;x<18;x++){ terr_set_tile_flat(T,x,z,5.4f);  terr_paint(T,x,z,T_STONE); }
  /* ramps: ground->L1 (south), L1->L2 (south) */
  for(int x=15;x<18;x++){
    tile_t *t=&T->t[10][x];
    t->h[0]=3.0f; t->h[1]=3.0f;
    t->h[2]=T->t[11][x].h[0]; t->h[3]=T->t[11][x].h[1];
    t->top=T_DIRT;
  }
  for(int x=15;x<17;x++){
    tile_t *t=&T->t[8][x];
    t->h[0]=5.4f; t->h[1]=5.4f; t->h[2]=3.0f; t->h[3]=3.0f;
    t->top=T_DIRT;
  }
  /* river across the south, under the path (bridge goes on top) */
  for(int z=14;z<16;z++)for(int x=0;x<TW;x++){
    terr_set_tile_flat(T,x,z,-1.7f);
    terr_paint(T,x,z,T_WATER);
  }
  /* winding dirt path (skips the river tiles) */
  for(float fz=10.5f; fz<TH; fz+=0.25f){
    int z=(int)fz;
    if(z>=14&&z<16) continue;
    int cx=(int)(16.0f + 3.5f*sinf(fz*0.5f));
    terr_paint(T,cx,z,T_DIRT); terr_paint(T,cx+1,z,T_DIRT);
  }
  return T;
}

static void scene_rochibi(const char *out){
  /* demo-3 aesthetic test: the RO scene with REAL anime-chibi sprites
   * (Kushnariova CC-BY 24x32, RMXP-style: 3x4 walk sheet, rows D/L/R/U) */
  fb_t *f = fb_new(480,270);
  f->filter=FILT_3POINT; f->fog_on=1;
  f->fog_color=(v3){0.70f,0.76f,0.88f}; f->fog_start=95; f->fog_end=170;
  f->ambient=(v3){0.5f,0.5f,0.55f};
  sky(f, 0xffe0a866u, 0xfff0d8b0u);
  terrain_t *T=terr_demo_ro();
  v3 focus={30,0,21}; focus.y=terr_sample(T,focus.x,focus.z)+1.5f;
  float dist=95.0f, pitch=0.88f, cyaw=0.5f; /* yawed: grid off screen-axis */
  v3 eye={focus.x+dist*sinf(cyaw)*cosf(pitch), focus.y+dist*sinf(pitch),
          focus.z+dist*cosf(cyaw)*cosf(pitch)};
  f->view = m4_lookat(eye, focus, (v3){0,1,0});
  f->proj = m4_persp(15, 480.0f/270.0f, 1.0f, 220);
  terr_draw(f, T, g_tex);
  /* landmark tower on the upper plateau (village anchor, not a cube) */
  {
    v3 w2={1,1,1};
    m4 tw = m4_translate(32,5.4f,12);
    draw_prism(f, tw, 8, 2.4f,2.05f,4.6f, w2, &g_tex[T_STONE], 1);
    draw_prism(f, m4_translate(32,10.0f,12), 8, 2.9f,0.0f,2.9f,
               (v3){0.62f,0.30f,0.24f}, NULL, 0);
  }
  /* wooden arc bridge where the path crosses the river */
  load_graybox_textures();
  draw_arc_bridge(f, m4_mul(m4_translate(38.5f,1.1f,30.0f), m4_roty(1.5708f)),
                  9.0f, 1.0f, 2.6f, 0.45f, 8, (v3){1,1,1}, &g_gb[GB_WOOD]);
  /* big round trees in clusters on the grass */
  {
    uint32_t s=77;
    for(int i=0;i<26;i++){
      float x=2+(xs32(&s)%440)/10.0f, z=2+(xs32(&s)%440)/10.0f;
      int tx=(int)(x/T->tile_size), tz=(int)(z/T->tile_size);
      if(T->t[tz][tx].top!=T_GRASS) continue;
      float dfx=x-focus.x, dfz=z-focus.z;
      if(dfx*dfx+dfz*dfz < 30.0f) continue; /* keep the stage clear */
      draw_tree_round(f,(v3){x,terr_sample(T,x,z),z},
                      1.1f+(xs32(&s)%60)/100.0f, s);
    }
  }
  const char *dir="../assets/kushnariova-chibi/24x32-characters-big-pack-by-Svetlana-Kushnariova";
  const char *who[7][2]={
    {"Heroes/Fighter-M-01.png","0"},{"Heroes/Mage-F-01.png","0"},
    {"Heroes/Healer-M-01.png","2"},{"Heroes/Ranger-F-01.png","1"},
    {"Heroes/Fighter-F-01.png","3"},{"NPC/Townfolk-Adult-M-006.png","0"},
    {"NPC/Townfolk-Old-M-001.png","2"}};
  tex_t shadow = tx_shadow();
  v3 w={1,1,1};
  float ox[7]={-4.0f,-1.8f,0.4f,2.6f,4.8f,-3.0f,1.6f};
  float oz[7]={-2.0f,0.8f,-2.5f,0.5f,-1.5f,3.2f,3.0f};
  for(int i=0;i<7;i++){
    float x=focus.x+ox[i], z=focus.z+oz[i];
    float y=terr_sample(T,x,z);
    f->blend=0.55f;
    vtx_t A={{x-0.8f,y+0.04f,z-0.6f},0,0,w,(v3){0,0,0}};
    vtx_t B={{x+0.8f,y+0.04f,z-0.6f},1,0,w,(v3){0,0,0}};
    vtx_t C={{x+0.8f,y+0.04f,z+0.6f},1,1,w,(v3){0,0,0}};
    vtx_t D={{x-0.8f,y+0.04f,z+0.6f},0,1,w,(v3){0,0,0}};
    quad(f,NULL,A,B,C,D,&shadow);
    f->blend=0;
    char sp[512];
    snprintf(sp,sizeof sp,"%s/%s",dir,who[i][0]);
    if(!file_exists(sp)) continue;
    tex_t sheet = tex_load(sp);
    /* RMXP sheets use a solid key color, not alpha: key on the corner pixel */
    uint8_t k0=sheet.px[0],k1=sheet.px[1],k2=sheet.px[2];
    for(size_t px_=0;px_<(size_t)sheet.w*sheet.h;px_++){
      uint8_t *p=sheet.px+px_*4;
      if(p[0]==k0&&p[1]==k1&&p[2]==k2) p[3]=0;
    }
    int row = who[i][1][0]-'0';                 /* 0=down 1=left 2=right 3=up */
    tex_t *fr = malloc(sizeof *fr);
    *fr = tex_crop(&sheet, 24, row*32, 24, 32); /* middle column = standing */
    free(sheet.px);
    float h=3.0f, wq=h*24.0f/32.0f;
    billboard(f,(v3){x,y,z},wq,h, 0,0,1,1,(v3){1,1,1},fr);
    if(!g_dump){ free(fr->px); free(fr); }
  }
  finish(f,out,2,1);
  free(T);
}

/* ================= ro2: the blended-terrain RO study ======================
 * what the references show that the tile scene lacked:
 *  - materials blend into each other with ragged organic borders (we bake a
 *    UNIQUE 32x32 texture per tile, sampling materials in continuous world
 *    space and mixing by noisy weights — no seams, no tile look);
 *  - smooth heightmap; water is a level plane the ground dips under, so the
 *    shoreline follows the height contour;
 *  - baked shadow pockets under trees (lightmap feel) multiplied into the
 *    tile bake;
 *  - dense prop dressing; structures placed diagonally. */

#define R2N 32
static float r2_h[R2N+1][R2N+1];
static const float R2S = 2.0f;
static float r2_height(float wx, float wz){
  float fx=wx/R2S, fz=wz/R2S;
  int x=(int)fx, z=(int)fz;
  if(x<0)x=0; if(z<0)z=0; if(x>R2N-1)x=R2N-1; if(z>R2N-1)z=R2N-1;
  float ux=fx-x, uz=fz-z;
  float a=r2_h[z][x], b=r2_h[z][x+1], c=r2_h[z+1][x], d=r2_h[z+1][x+1];
  return (a+(b-a)*ux)*(1-uz) + (c+(d-c)*ux)*uz;
}
/* the path curve: x as a function of z (world coords) */
static float r2_path_x(float wz){ return 34.0f + 9.0f*sinf(wz*0.12f); }

/* prop registry so the shadow bake can see the trees */
typedef struct { float x,z,r; } r2shadow_t;
static r2shadow_t r2_sh[128]; static int r2_nsh;

static float r2_shadow(float wx, float wz){
  /* sample on the authentic 8x8-per-tile lightmap grid (4 texels per world
   * unit at tile size 2): soft but slightly chunky, like the real thing */
  wx = floorf(wx*4.0f)/4.0f + 0.125f;
  wz = floorf(wz*4.0f)/4.0f + 0.125f;
  float s=1.0f;
  for(int i=0;i<r2_nsh;i++){
    float dx=wx-r2_sh[i].x, dz=wz-r2_sh[i].z;
    float d2=dx*dx+dz*dz, r2=r2_sh[i].r*r2_sh[i].r;
    if(d2<r2){
      float k=1.0f-d2/r2;           /* 1 center -> 0 edge */
      float dark = 0.58f*k;          /* deep pockets like the reference */
      s *= 1.0f-dark;
    }
  }
  return s<0.34f? 0.34f : s;
}

/* gazebo placement (diagonal!) — the plaza pattern bakes in THIS frame */
static const float R2GX=40.0f, R2GZ=22.0f, R2GROT=0.55f;

/* continuous world-space material samples (16 texels per world unit) */
static rgb8 r2_mat(int mat, float wx, float wz){
  if(mat==3){
    /* pavement pattern must match the gazebo's orientation, not the world
     * axes: rotate into the gazebo frame before the grid lookup */
    float dx=wx-R2GX, dz=wz-R2GZ;
    wx = R2GX + dx*cosf(-R2GROT)-dz*sinf(-R2GROT);
    wz = R2GZ + dx*sinf(-R2GROT)+dz*cosf(-R2GROT);
  }
  int px_=(int)(wx*16), pz=(int)(wz*16);
  switch(mat){
    case 0:{ /* grass */
      float v=0.6f*vnoise(901,px_,pz,1024,48)+0.4f*vnoise(902,px_,pz,1024,12);
      rgb8 c=ramp((rgb8){ 74,122, 58},(rgb8){138,176, 86},v,5);
      uint32_t s=(uint32_t)(px_*73856093u ^ pz*19349663u); s^=s<<13;s^=s>>17;s^=s<<5;
      if((s&255)>251) c=(rgb8){170,200,108};
      return c;
    }
    case 1:{ /* dirt path */
      float v=0.6f*vnoise(903,px_,pz,1024,32)+0.4f*vnoise(904,px_,pz,1024,8);
      rgb8 c=ramp((rgb8){140,106, 72},(rgb8){190,152,108},v,5);
      uint32_t s=(uint32_t)(px_*83492791u ^ pz*29349673u); s^=s<<13;s^=s>>17;s^=s<<5;
      if((s&255)>250) c=(rgb8){206,174,130};
      return c;
    }
    case 2:{ /* sand (shore) */
      float v=0.55f*vnoise(905,px_,pz,1024,24)+0.45f*vnoise(906,px_,pz,1024,6);
      return ramp((rgb8){188,166,112},(rgb8){228,206,150},v,4);
    }
    default:{ /* stone pavement (under the gazebo) */
      int bx=((px_%20)+20)%20, bz=((pz%20)+20)%20;
      float v=0.5f*vnoise(907,px_,pz,1024,16)+0.5f;
      rgb8 c=ramp((rgb8){120,114,116},(rgb8){168,160,158},v-0.5f+0.5f,4);
      if(bx<2||bz<2) c=(rgb8){ 92, 88, 92};
      return c;
    }
  }
}

static float sstep01(float t){ if(t<0)t=0; if(t>1)t=1; return t*t*(3-2*t); }

static void r2_weights(float wx, float wz, float h, float w[4]){
  /* noisy borders: perturb the classifier inputs, then FEATHER over a band
   * (smoothstep) — gradients, not splotches */
  float n  = (fbm(555,(int)(wx*8),(int)(wz*8),512)-0.5f);
  float n2 = (vnoise(556,(int)(wx*24),(int)(wz*24),1024,10)-0.5f);
  float wn = n*1.1f + n2*0.55f;
  /* sand where low: full below threshold, feathers out over ~1.0 height */
  float sand = sstep01(((0.30f+wn) - h)/1.0f + 0.5f);
  /* dirt near the path: solid core, ~1.6-unit feather */
  float pd = fabsf(wx - r2_path_x(wz));
  float dirt = sstep01(((1.5f+wn*1.2f) - pd)/1.6f + 0.5f);
  /* around the gazebo: circular uneven trampled-dirt blend (the pavement
   * itself is a crisp PROP slab aligned with the structure, not a bake) */
  float gdx=wx-R2GX, gdz=wz-R2GZ;
  float gd = sqrtf(gdx*gdx+gdz*gdz);
  float around = sstep01(((6.4f+wn*1.6f) - gd)/2.0f + 0.5f);
  if(around>dirt) dirt=around;
  /* priority compositing: dirt > sand > grass */
  w[3]=0; w[1]=dirt; w[2]=sand*(1-w[1]);
  w[0]=1.0f-w[1]-w[2];
}

static tex_t r2_bake_tile(int tx, int tz){
  /* 34x34 with a 1-texel gutter continuing into the neighbors (the RO atlas
   * border trick) so filtering never wraps at tile seams */
  tex_t t=tex_new(34,34);
  for(int py=0;py<34;py++)for(int px2=0;px2<34;px2++){
    float wx=(tx + (px2-1+0.5f)/32.0f)*R2S;
    float wz=(tz + (py-1+0.5f)/32.0f)*R2S;
    float h=r2_height(wx,wz);
    float w[4]; r2_weights(wx,wz,h,w);
    float r=0,g=0,b=0;
    for(int m=0;m<4;m++){
      if(w[m]<=0) continue;
      rgb8 c=r2_mat(m,wx,wz);
      r+=w[m]*c.r; g+=w[m]*c.g; b+=w[m]*c.b;
    }
    float sh=r2_shadow(wx,wz);
    /* underwater ground darkens + cools slightly (reads through the water) */
    if(h<-0.35f){ sh*=0.80f; b*=1.08f; }
    uint8_t cc[3]={(uint8_t)(r*sh>255?255:r*sh),(uint8_t)(g*sh>255?255:g*sh),(uint8_t)(b*sh>255?255:b*sh)};
    px(&t,px2,py,(rgb8){cc[0],cc[1],cc[2]});
  }
  return t;
}

static void scene_ro2(const char *out){
  fb_t *f = fb_new(480,270);
  f->filter=FILT_3POINT; f->fog_on=1;
  f->fog_color=(v3){0.74f,0.80f,0.88f}; f->fog_start=110; f->fog_end=190;
  f->ambient=(v3){0.55f,0.55f,0.58f};
  f->sun_dir=v3_norm((v3){-0.45f,-1.0f,-0.35f});
  sky(f, 0xffe0a866u, 0xfff0d8b0u);
  /* heights: smooth rolling + a lobed, domain-warped pond + gazebo knoll */
  for(int z=0;z<=R2N;z++)for(int x=0;x<=R2N;x++){
    float wx=x*R2S, wz=z*R2S;
    float h = 2.6f*fbm(881, x*5, z*5, 256) - 0.9f;
    /* domain warp: wobble the sample point so basin edges meander */
    float wxp = wx + 5.0f*(fbm(661,x*6,z*6,256)-0.5f);
    float wzp = wz + 5.0f*(fbm(662,x*6,z*6,256)-0.5f);
    /* three overlapping lobes -> a lake, not a circle */
    const float L[3][3]={{14,40,10.5f},{24,47,7.5f},{9,50,6.5f}};
    float dip=0;
    for(int i=0;i<3;i++){
      float dx=wxp-L[i][0], dz=wzp-L[i][1];
      float d2=(dx*dx+dz*dz)/(L[i][2]*L[i][2]);
      if(d2<1){ float k=(1-d2)*(1-d2)*2.8f; if(k>dip) dip=k; }
    }
    h -= dip;
    float gdx=wx-R2GX, gdz=wz-R2GZ;                /* gazebo knoll */
    float gd2=(gdx*gdx+gdz*gdz)/(9.0f*9.0f);
    if(gd2<1) h = h*(gd2) + 1.6f*(1-gd2);
    r2_h[z][x]=h;
  }
  /* flatten the plaza proper */
  for(int z=0;z<=R2N;z++)for(int x=0;x<=R2N;x++){
    float wx=x*R2S, wz=z*R2S;
    float dx=wx-R2GX, dz=wz-R2GZ;
    float rx= dx*cosf(-R2GROT)-dz*sinf(-R2GROT), rz= dx*sinf(-R2GROT)+dz*cosf(-R2GROT);
    if(fabsf(rx)<5.0f && fabsf(rz)<5.0f) r2_h[z][x]=1.6f;
  }
  /* place trees/bushes first: the shadow bake needs them */
  typedef struct { float x,z,sc; int bush; } prop_t;
  prop_t props[128]; int nprops=0;
  uint32_t s=1234;
  for(int i=0;i<250 && nprops<120;i++){
    float x=2+(xs32(&s)%600)/10.0f, z=2+(xs32(&s)%600)/10.0f;
    float h=r2_height(x,z);
    if(h<-0.1f) continue;                          /* not in the pond */
    if(fabsf(x-r2_path_x(z))<2.6f) continue;       /* not on the path */
    float dx=x-R2GX, dz=z-R2GZ;
    if(dx*dx+dz*dz<42.0f) continue;                /* not on the plaza */
    int bush = (xs32(&s)&3)==0? 0 : 1;             /* mostly bushes: lush */
    float sc = bush? 0.5f+(xs32(&s)%40)/100.0f : 1.2f+(xs32(&s)%70)/100.0f;
    props[nprops++] = (prop_t){x,z,sc,bush};
    if(!bush && r2_nsh<128) r2_sh[r2_nsh++] = (r2shadow_t){x,z,2.6f*sc};
    else if(bush && r2_nsh<128) r2_sh[r2_nsh++] = (r2shadow_t){x,z,1.2f*sc};
  }
  /* gazebo shadow */
  if(r2_nsh<128) r2_sh[r2_nsh++] = (r2shadow_t){R2GX,R2GZ,4.6f};
  /* bake + draw the terrain (unique blended texture per tile) */
  v3 w={1,1,1};
  /* RO closeup framing: lower camera, shallower pitch */
  v3 focus={28,0,32}; focus.y=r2_height(focus.x,focus.z)+1.2f;
  float dist=66.0f, pitch=0.70f, cyaw=0.45f;
  v3 eye={focus.x+dist*sinf(cyaw)*cosf(pitch), focus.y+dist*sinf(pitch),
          focus.z+dist*cosf(cyaw)*cosf(pitch)};
  f->view = m4_lookat(eye, focus, (v3){0,1,0});
  f->proj = m4_persp(15, 480.0f/270.0f, 1.0f, 260);
  /* corner-smoothed normals (RO's getSmoothNormal): central differences at
   * each grid vertex — kills the per-tile shading seams on smooth ground */
  #define R2NRM(vx,vz) ({ \
    int _x=(vx),_z=(vz); \
    int _xm=_x>0?_x-1:_x, _xp=_x<R2N?_x+1:_x; \
    int _zm=_z>0?_z-1:_z, _zp=_z<R2N?_z+1:_z; \
    v3_norm((v3){(r2_h[_z][_xm]-r2_h[_z][_xp])/((_xp-_xm)*R2S), 1.0f, \
                 (r2_h[_zm][_x]-r2_h[_zp][_x])/((_zp-_zm)*R2S)}); })
  for(int tz=0;tz<R2N;tz++)for(int tx=0;tx<R2N;tx++){
    tex_t bt = r2_bake_tile(tx,tz);
    float x0=tx*R2S, x1=(tx+1)*R2S, z0=tz*R2S, z1=(tz+1)*R2S;
    float h00=r2_h[tz][tx],h10=r2_h[tz][tx+1],h01=r2_h[tz+1][tx],h11=r2_h[tz+1][tx+1];
    const float e0=1.0f/34, e1=33.0f/34; /* interior of the gutter bake */
    vtx_t A={{x0,h00,z0},e0,e0,w,R2NRM(tx,tz)},   B={{x1,h10,z0},e1,e0,w,R2NRM(tx+1,tz)};
    vtx_t C={{x1,h11,z1},e1,e1,w,R2NRM(tx+1,tz+1)}, D={{x0,h01,z1},e0,e1,w,R2NRM(tx,tz+1)};
    quad(f,NULL,A,B,C,D,&bt);
    free(bt.px);
  }
  #undef R2NRM
  /* water plane at -0.35: milky teal, shoreline = the height contour.
   * opacity 0.5625 = 144/255, the authentic client value */
  f->blend=0.5625f;
  for(int tz=0;tz<R2N;tz+=4)for(int tx=0;tx<R2N;tx+=4){
    float x0=tx*R2S,x1=(tx+4)*R2S,z0=tz*R2S,z1=(tz+4)*R2S;
    v3 wc={0.42f,0.72f,0.66f};
    vtx_t A={{x0,-0.35f,z0},0,0,wc,(v3){0,0,0}}, B={{x1,-0.35f,z0},0,0,wc,(v3){0,0,0}};
    vtx_t C={{x1,-0.35f,z1},0,0,wc,(v3){0,0,0}}, D={{x0,-0.35f,z1},0,0,wc,(v3){0,0,0}};
    quad(f,NULL,A,B,C,D,NULL);
  }
  f->blend=0;
  /* gazebo: stone deck + wood posts + shingle pyramid roof, DIAGONAL */
  load_graybox_textures();
  {
    m4 g = m4_mul(m4_translate(R2GX,1.6f,R2GZ), m4_roty(R2GROT));
    v3 wood={0.36f,0.26f,0.20f};
    /* deck: clean pavement texture aligned to the deck's own axes */
    tex_t pave = tex_new(64,64);
    for(int py=0;py<64;py++)for(int qx=0;qx<64;qx++){
      int bx=qx%32, bz=py%32;
      float v=0.5f*vnoise(907,qx,py,64,16)+0.25f;
      rgb8 c=ramp((rgb8){126,120,122},(rgb8){170,162,160},v,4);
      if(bx<3||bz<3) c=(rgb8){ 94, 90, 94};
      px(&pave,qx,py,c);
    }
    /* plaza: a crisp pavement slab PROP aligned with the gazebo */
    draw_gbox(f, g, (v3){9.4f,0.22f,9.4f},(v3){0,0.11f,0}, w, &pave, 0.35f);
    draw_gbox(f, g, (v3){5.6f,0.5f,5.6f},(v3){0,0.25f,0}, w, &pave, 0.35f);
    for(int i=0;i<4;i++){
      float px_=(i&1)?2.1f:-2.1f, pz=(i&2)?2.1f:-2.1f;
      draw_prism(f, m4_mul(g,m4_translate(px_,0.5f,pz)), 6, 0.22f,0.18f,2.6f, wood, NULL, 0);
    }
    /* roof: 4-gon corners sit at 0/90/180/270 — pre-rotate 45 deg so the
     * corners land over the posts (which sit on the diagonals) */
    tex_t shingle = tx_gb(88,(rgb8){152,74,58},(rgb8){118,52,44},8,0.35f,1);
    m4 roof = m4_mul(g, m4_mul(m4_translate(0,3.1f,0), m4_roty(0.7854f)));
    draw_prism(f, roof, 4, 3.6f,0.25f,2.0f, w, &shingle, 0);
    draw_ball(f, m4_mul(g,m4_translate(0,5.3f,0)), 0.28f, wood, 6);
  }
  /* trees + bushes */
  for(int i=0;i<nprops;i++){
    float y=r2_height(props[i].x,props[i].z);
    if(props[i].bush){
      v3 g1={0.24f,0.46f,0.24f}, g2={0.32f,0.55f,0.28f};
      m4 b=m4_translate(props[i].x,y,props[i].z);
      draw_ball(f, m4_mul(b,m4_mul(m4_translate(0,0.35f*props[i].sc,0),m4_scale(1.4f,0.8f,1.4f))), 0.9f*props[i].sc, g1, 8);
      draw_ball(f, m4_mul(b,m4_mul(m4_translate(0.5f*props[i].sc,0.30f*props[i].sc,0.3f*props[i].sc),m4_scale(1.2f,0.7f,1.2f))), 0.6f*props[i].sc, g2, 7);
    }else{
      draw_tree_round(f,(v3){props[i].x,y,props[i].z}, props[i].sc, 100+i);
    }
  }
  /* fence posts along the path's west side (diagonal run) */
  {
    v3 wood={0.42f,0.30f,0.22f};
    for(float wz=44; wz<58; wz+=2.5f){
      float wx=r2_path_x(wz)-3.0f;
      float y=r2_height(wx,wz);
      draw_prism(f, m4_translate(wx,y,wz), 4, 0.16f,0.13f,1.2f, wood, NULL, 1);
    }
  }
  /* chibi sprites near the plaza + on the path */
  {
    const char *dir="../assets/kushnariova-chibi/24x32-characters-big-pack-by-Svetlana-Kushnariova";
    const char *who[5][2]={
      {"Heroes/Fighter-M-01.png","0"},{"Heroes/Mage-F-01.png","1"},
      {"Heroes/Healer-M-01.png","0"},{"NPC/Townfolk-Adult-M-006.png","2"},
      {"Heroes/Ranger-F-01.png","3"}};
    float sxz[5][2]={{36.5f,27.5f},{40,27},{33.5f,34},{31,40},{35,44}};
    tex_t shadow=tx_shadow();
    for(int i=0;i<5;i++){
      float x=sxz[i][0], z=sxz[i][1];
      float y=r2_height(x,z);
      f->blend=0.5f;
      vtx_t A={{x-0.8f,y+0.05f,z-0.6f},0,0,w,(v3){0,0,0}};
      vtx_t B={{x+0.8f,y+0.05f,z-0.6f},1,0,w,(v3){0,0,0}};
      vtx_t C={{x+0.8f,y+0.05f,z+0.6f},1,1,w,(v3){0,0,0}};
      vtx_t D={{x-0.8f,y+0.05f,z+0.6f},0,1,w,(v3){0,0,0}};
      quad(f,NULL,A,B,C,D,&shadow);
      f->blend=0;
      char sp[512];
      snprintf(sp,sizeof sp,"%s/%s",dir,who[i][0]);
      if(!file_exists(sp)) continue;
      tex_t sheet=tex_load(sp);
      uint8_t k0=sheet.px[0],k1=sheet.px[1],k2=sheet.px[2];
      for(size_t q=0;q<(size_t)sheet.w*sheet.h;q++){
        uint8_t *p=sheet.px+q*4;
        if(p[0]==k0&&p[1]==k1&&p[2]==k2) p[3]=0;
      }
      tex_t fr=tex_crop(&sheet,24,(who[i][1][0]-'0')*32,24,32);
      free(sheet.px);
      /* authentic: sprites are unlit but tinted by the ground shadow under
       * their feet, with only ~30% of the swing (Rebuild's env formula) */
      float sh = 0.7f + 0.3f*r2_shadow(x,z);
      billboard(f,(v3){x,y,z},3.0f*24/32,3.0f, 0,0,1,1,(v3){sh,sh,sh},&fr);
      free(fr.px);
    }
  }
  finish(f,out,2,1);
}

static void scene_dungeon(const char *out){
  /* N64 preset + real CC0 assets (KayKit Dungeon Remastered, 4-unit grid) */
  fb_t *f = fb_new(320,240);
  f->filter=FILT_3POINT; f->fog_on=1;
  f->fog_color=(v3){0.10f,0.08f,0.14f}; f->fog_start=9; f->fog_end=26;
  f->ambient=(v3){0.40f,0.33f,0.36f};
  f->sun_color=(v3){1.0f,0.82f,0.55f}; /* warm torch-ish key */
  f->sun_dir=v3_norm((v3){-0.4f,-1.0f,-0.55f});
  sky(f, 0xff140812u, 0xff2a1020u);
  f->view = m4_lookat((v3){3.0f,5.2f,14.0f},(v3){5.5f,0.9f,1.5f},(v3){0,1,0});
  f->proj = m4_persp(55, 320.0f/240.0f, 0.3f, 60);

  const char *dir="../assets/kaykit-dungeon";
  char p[512];
  #define LOAD(name) ({ snprintf(p,sizeof p,"%s/obj/%s.obj",dir,name); obj_load(p); })
  snprintf(p,sizeof p,"%s/texture/dungeon_texture.png",dir);
  tex_t atlas = tex_load(p);
  obj_t floor_ = LOAD("floor_tile_large");
  obj_t wall   = LOAD("wall");
  obj_t wallc  = LOAD("wall_corner");
  obj_t doorway= LOAD("wall_doorway");
  obj_t column = LOAD("column");
  obj_t barrel = LOAD("barrel_large");
  obj_t crates = LOAD("crates_stacked");
  obj_t chest  = LOAD("chest_gold");
  obj_t chestl = LOAD("chest_gold_lid");
  obj_t torch  = LOAD("torch_mounted");
  obj_t stairs = LOAD("stairs_wide");
  obj_t coins  = LOAD("coin_stack_large");
  #undef LOAD
  v3 w={1,1,1};
  /* floor 4x3 tiles of 4 units */
  for(int z=0;z<3;z++)for(int x=0;x<4;x++)
    obj_draw(f,&floor_, m4_translate(x*4.0f, 0, z*4.0f), w, &atlas);
  /* north wall (z=-2): wall pieces face +z by default */
  for(int x=0;x<4;x++){
    if(x==1) obj_draw(f,&doorway, m4_translate(x*4.0f,0,-2.0f), w, &atlas);
    else     obj_draw(f,&wall,    m4_translate(x*4.0f,0,-2.0f), w, &atlas);
  }
  /* west wall: rotate 90 */
  for(int z=0;z<3;z++)
    obj_draw(f,&wall, m4_mul(m4_translate(-2.0f,0,z*4.0f), m4_roty(1.5708f)), w, &atlas);
  obj_draw(f,&wallc, m4_translate(-2.0f,0,-2.0f), w, &atlas);
  /* columns + torches */
  obj_draw(f,&column, m4_translate(2.0f,0,2.0f), w, &atlas);
  obj_draw(f,&column, m4_translate(10.0f,0,2.0f), w, &atlas);
  obj_draw(f,&torch, m4_translate(4.0f,1.6f,-1.8f), w, &atlas);
  obj_draw(f,&torch, m4_translate(12.0f,1.6f,-1.8f), w, &atlas);
  /* prop dressing */
  obj_draw(f,&barrel, m4_translate(-0.9f,0,4.5f), w, &atlas);
  obj_draw(f,&crates, m4_mul(m4_translate(-0.6f,0,7.0f), m4_roty(0.4f)), w, &atlas);
  obj_draw(f,&chest,  m4_mul(m4_translate(8.6f,0,3.4f), m4_roty(-0.75f)), w, &atlas);
  obj_draw(f,&chestl, m4_mul(m4_translate(8.6f,0,3.4f), m4_roty(-0.75f)), w, &atlas);
  obj_draw(f,&coins,  m4_translate(9.7f,0,4.6f), w, &atlas);
  obj_draw(f,&stairs, m4_mul(m4_translate(14.0f,0,4.0f), m4_roty(-1.5708f)), w, &atlas);
  /* our figure walking toward the chest */
  m4 root=m4_mul(m4_translate(4.6f,0,6.0f), m4_roty(2.45f));
  draw_guy(f, root, walk_pose(0.55f), NULL);
  finish(f,out,3,1);
}

static void scene_mascot(const char *out){
  /* stock-character study: idle, wave, jump, land — on a graybox stage */
  fb_t *f = fb_new(480,270);
  f->fog_on=0; f->filter=FILT_3POINT;
  f->ambient=(v3){0.46f,0.46f,0.52f};
  f->sun_dir=v3_norm((v3){-0.4f,-1.0f,-0.45f});
  sky(f, 0xffc89058u, 0xffe8d0a8u);
  load_graybox_textures();
  f->view = m4_lookat((v3){0,2.4f,8.2f},(v3){0,1.15f,0},(v3){0,1,0});
  f->proj = m4_persp(42, 480.0f/270.0f, 0.3f, 60);
  v3 w={1,1,1};
  for(int gz=0;gz<4;gz++)for(int gx=0;gx<8;gx++){
    float x0=-10+gx*2.5f, z0=-4+gz*2.5f;
    vtx_t A={{x0,0,z0},0,0,w,(v3){0,1,0}}, B={{x0+2.5f,0,z0},1.25f,0,w,(v3){0,1,0}};
    vtx_t C={{x0+2.5f,0,z0+2.5f},1.25f,1.25f,w,(v3){0,1,0}}, D={{x0,0,z0+2.5f},0,1.25f,w,(v3){0,1,0}};
    quad(f,NULL,A,B,C,D,&g_gb[GB_STONE]);
  }
  tex_t shadow = tx_shadow();
  float sx_[4]={-4.5f,-1.5f,1.5f,4.5f};
  for(int i=0;i<4;i++){
    f->blend=0.5f;
    vtx_t A={{sx_[i]-0.75f,0.03f,-0.75f},0,0,w,(v3){0,0,0}};
    vtx_t B={{sx_[i]+0.75f,0.03f,-0.75f},1,0,w,(v3){0,0,0}};
    vtx_t C={{sx_[i]+0.75f,0.03f,0.75f},1,1,w,(v3){0,0,0}};
    vtx_t D={{sx_[i]-0.75f,0.03f,0.75f},0,1,w,(v3){0,0,0}};
    quad(f,NULL,A,B,C,D,&shadow);
    f->blend=0;
  }
  /* idle */
  draw_mascot(f,(v3){sx_[0],0,0}, 0.15f, mascot_idle());
  /* wave */
  {
    mpose_t p=mascot_idle();
    p.hand_r=(v3){0.95f,0.85f,0.15f};
    p.lean=-0.08f; p.ant=-0.18f;
    draw_mascot(f,(v3){sx_[1],0,0}, -0.2f, p);
  }
  /* jump (stretched, everything flung up) */
  {
    mpose_t p=mascot_idle();
    p.squash=1.22f; p.bob=0.85f;
    p.hand_l=(v3){-0.85f,0.55f,0.1f}; p.hand_r=(v3){0.85f,0.55f,0.1f};
    p.foot_l=(v3){-0.30f,-1.05f,-0.15f}; p.foot_r=(v3){0.30f,-0.85f,0.20f};
    p.ant=0.35f;
    draw_mascot(f,(v3){sx_[2],0,0}, 0.3f, p);
  }
  /* landing squash */
  {
    mpose_t p=mascot_idle();
    p.squash=0.74f; p.bob=-0.16f;
    p.hand_l=(v3){-1.05f,-0.05f,0.2f}; p.hand_r=(v3){1.05f,-0.05f,0.2f};
    p.foot_l=(v3){-0.42f,-0.72f,0.1f}; p.foot_r=(v3){0.42f,-0.72f,0.1f};
    p.ant=-0.45f;
    draw_mascot(f,(v3){sx_[3],0,0}, -0.1f, p);
  }
  finish(f,out,2,1);
}

static void scene_mascoteyes(const char *out){
  /* pupil-size study: nudging cute vs uncanny. left→right:
   * A current small ovals · B bigger+rounder · C big round + glint ·
   * D huge Kirby-fill + glint */
  fb_t *f = fb_new(480,270);
  f->fog_on=0; f->filter=FILT_3POINT;
  f->ambient=(v3){0.48f,0.48f,0.54f};
  f->sun_dir=v3_norm((v3){-0.35f,-1.0f,-0.5f});
  sky(f, 0xffc89058u, 0xffe8d0a8u);
  load_graybox_textures();
  f->view = m4_lookat((v3){0,1.9f,9.2f},(v3){0,1.15f,0},(v3){0,1,0});
  f->proj = m4_persp(38, 480.0f/270.0f, 0.3f, 60);
  v3 w={1,1,1};
  for(int gz=0;gz<3;gz++)for(int gx=0;gx<8;gx++){
    float x0=-10+gx*2.5f, z0=-3+gz*2.5f;
    vtx_t A={{x0,0,z0},0,0,w,(v3){0,1,0}}, B={{x0+2.5f,0,z0},1.25f,0,w,(v3){0,1,0}};
    vtx_t C={{x0+2.5f,0,z0+2.5f},1.25f,1.25f,w,(v3){0,1,0}}, D={{x0,0,z0+2.5f},0,1.25f,w,(v3){0,1,0}};
    quad(f,NULL,A,B,C,D,&g_gb[GB_STONE]);
  }
  mstyle_t styles[4]={
    {0.16f,0.24f, 0.07f,0.12f, 0},   /* A: current */
    {0.17f,0.24f, 0.11f,0.13f, 0},   /* B: bigger + rounder */
    {0.18f,0.25f, 0.13f,0.15f, 1},   /* C: big round + glint */
    {0.19f,0.27f, 0.16f,0.21f, 1},   /* D: Kirby-fill + glint */
  };
  float sx_[4]={-4.2f,-1.4f,1.4f,4.2f};
  for(int i=0;i<4;i++){
    g_mstyle = styles[i];
    draw_mascot(f,(v3){sx_[i],0,0}, 0.0f, mascot_idle());
  }
  g_mstyle = (mstyle_t){0.17f,0.24f,0.11f,0.13f,0};
  finish(f,out,2,1);
}

static void scene_ps1(const char *out){
  /* same content as n64, PS1 rules: nearest, affine, vertex snap, harder dither */
  fb_t *f = fb_new(320,240);
  f->filter=FILT_NEAREST; f->affine=1; f->vsnap=1; f->fog_on=1;
  f->fog_color=(v3){0.65f,0.72f,0.86f}; f->fog_start=20; f->fog_end=45;
  f->ambient=(v3){0.42f,0.42f,0.48f};
  f->sun_dir=v3_norm((v3){-0.45f,-1.0f,-0.3f});
  sky(f, 0xffe89a56u, 0xfff2d5abu);
  terrain_t *T=terr_demo();
  v3 guy_at={33.0f, 0, 33.0f};
  guy_at.y = terr_sample(T,guy_at.x,guy_at.z);
  f->view = m4_lookat((v3){guy_at.x-7.5f, guy_at.y+4.2f, guy_at.z+9.0f},
                      (v3){guy_at.x, guy_at.y+1.4f, guy_at.z-2.0f}, (v3){0,1,0});
  f->proj = m4_persp(55, 320.0f/240.0f, 0.3f, 120);
  scene_common(f,T);
  m4 root=m4_mul(m4_translate(guy_at.x,guy_at.y,guy_at.z), m4_roty(2.6f));
  draw_guy(f, root, walk_pose(0.25f), NULL);
  finish(f,out,3,1);
  free(T);
}

/* ---- figure -> sprite bake: the "model once, use as 3D or billboard" loop.
 * renders the rigid-part guy from a given yaw into a small transparent target
 * (the RO pre-rendered-sprite recipe). */
static tex_t bake_guy_sprite(pose_t pose, float yaw){
  /* the bake must really rasterize even in --dump capture mode */
  void (*cap)(fb_t*,vtx_t,vtx_t,vtx_t,const tex_t*) = r3d_capture;
  r3d_capture = NULL;
  fb_t *b = fb_new(40,52);
  b->filter=FILT_NEAREST; b->fog_on=0;
  b->ambient=(v3){0.52f,0.52f,0.56f};
  b->sun_dir=v3_norm((v3){-0.4f,-1.0f,-0.5f});
  fb_clear(b, 0x00000000u);
  /* camera slightly above, RO-style 3/4 view; figure ~2.1 units tall */
  b->view = m4_lookat((v3){0,2.6f,6.2f},(v3){0,0.95f,0},(v3){0,1,0});
  b->proj = m4_persp(22, 40.0f/52.0f, 0.5f, 20);
  m4 root = m4_roty(yaw);
  draw_guy(b, root, pose, NULL);
  tex_t t = tex_new(b->w,b->h);
  memcpy(t.px, b->color, (size_t)b->w*b->h*4);
  free(b->color); free(b->depth); free(b);
  r3d_capture = cap;
  return t;
}

/* crop a texture to its opaque bounding box (sprite frames ship with padding) */
static tex_t tex_crop_alpha(tex_t t){
  int x0=t.w,y0=t.h,x1=0,y1=0;
  for(int y=0;y<t.h;y++)for(int x=0;x<t.w;x++)
    if(t.px[4*((size_t)y*t.w+x)+3]>16){
      if(x<x0)x0=x; if(x>x1)x1=x; if(y<y0)y0=y; if(y>y1)y1=y;
    }
  if(x0>x1) return t;
  tex_t o=tex_new(x1-x0+1,y1-y0+1);
  for(int y=0;y<o.h;y++)
    memcpy(o.px+4*(size_t)y*o.w, t.px+4*((size_t)(y+y0)*t.w+x0), (size_t)o.w*4);
  free(t.px);
  return o;
}
static int file_exists(const char *p){ FILE *f=fopen(p,"rb"); if(f){fclose(f);return 1;} return 0; }

static tex_t tex_crop(const tex_t *t, int x0, int y0, int w, int h){
  tex_t o=tex_new(w,h);
  for(int y=0;y<h;y++)
    memcpy(o.px+4*(size_t)y*w, t->px+4*((size_t)(y+y0)*t->w+x0), (size_t)w*4);
  return o;
}

static void scene_ro(const char *out){
  fb_t *f = fb_new(480,270);
  f->filter=FILT_3POINT; f->fog_on=1;
  f->fog_color=(v3){0.70f,0.76f,0.88f}; f->fog_start=95; f->fog_end=170;
  f->ambient=(v3){0.5f,0.5f,0.55f};
  sky(f, 0xffe0a866u, 0xfff0d8b0u);
  terrain_t *T=terr_demo();
  /* RO camera: narrow FOV (~15 deg) so perspective reads near-orthographic,
   * pitch ~55 deg, camera pulled far back — the authentic RO recipe */
  v3 focus={30,0,26}; focus.y=terr_sample(T,focus.x,focus.z);
  float dist=76.0f, pitch=0.96f; /* ~55 deg */
  v3 eye={focus.x, focus.y+dist*sinf(pitch), focus.z+dist*cosf(pitch)};
  f->view = m4_lookat(eye, focus, (v3){0,1,0});
  f->proj = m4_persp(15, 480.0f/270.0f, 1.0f, 220);
  scene_common(f,T);
  /* billboard characters: sprites BAKED from the rigid-part figure at varied
   * facings + poses — the "model once, use as 3D or billboard" pipeline.
   * (a CC0 OGA 8-direction sheet also renders fine through the same path;
   * style-mismatched for RO, so the baked figures are the hero shot.) */
  (void)file_exists; (void)tex_crop_alpha;
  tex_t shadow = tx_shadow();
  float yaws[5]={0.0f, 0.8f, 2.4f, 3.14f, -0.7f};
  for(int i=0;i<5;i++){
    float x=focus.x-4+i*2.2f, z=focus.z-2+ (i%2)*2.8f;
    float y=terr_sample(T,x,z);
    f->blend=0.55f;
    vtx_t A={{x-0.65f,y+0.04f,z-0.5f},0,0,(v3){1,1,1},(v3){0,0,0}};
    vtx_t B={{x+0.65f,y+0.04f,z-0.5f},1,0,(v3){1,1,1},(v3){0,0,0}};
    vtx_t C={{x+0.65f,y+0.04f,z+0.5f},1,1,(v3){1,1,1},(v3){0,0,0}};
    vtx_t D={{x-0.65f,y+0.04f,z+0.5f},0,1,(v3){1,1,1},(v3){0,0,0}};
    quad(f,NULL,A,B,C,D,&shadow);
    f->blend=0;
    pose_t pose; memset(&pose,0,sizeof pose);
    if(i==1||i==3) pose = walk_pose(0.3f+0.2f*i);
    /* heap tex per bake: the dump registry keys textures by pointer and reads
     * their pixels at finish(), so each sprite needs a distinct live tex_t */
    tex_t *st = malloc(sizeof *st);
    *st = tex_crop_alpha(bake_guy_sprite(pose, yaws[i]));
    float h = 2.05f, wq = h*st->w/st->h;
    billboard(f,(v3){x,y,z},wq,h, 0,0,1,1,(v3){1,1,1},st);
    if(!g_dump){ free(st->px); free(st); }
  }
  finish(f,out,2,1);
  free(T);
}

static void scene_filters(const char *out){
  /* three tilted textured quads: nearest vs 3-point vs bilinear; plus
   * affine vs perspective-correct on a floor plane */
  fb_t *f = fb_new(480,270);
  fb_clear(f, 0xff302838u);
  f->fog_on=0;
  f->view = m4_lookat((v3){0,2.2f,6.5f},(v3){0,0.8f,0},(v3){0,1,0});
  f->proj = m4_persp(50, 480.0f/270.0f, 0.3f, 100);
  tex_t chk = tx_checker();
  const char *labels[3]={"nearest","3point","bilinear"};(void)labels;
  for(int i=0;i<3;i++){
    f->filter=i==0?FILT_NEAREST:(i==1?FILT_3POINT:FILT_BILINEAR);
    float x=-3.2f+i*3.2f;
    m4 mm = m4_mul(m4_translate(x,1.35f,0), m4_roty(0.5f));
    vtx_t a={{-1.2f, 1.2f,0},0,0,{1,1,1},{0,0,0}};
    vtx_t b={{ 1.2f, 1.2f,0},1,0,{1,1,1},{0,0,0}};
    vtx_t c={{ 1.2f,-1.2f,0},1,1,{1,1,1},{0,0,0}};
    vtx_t d={{-1.2f,-1.2f,0},0,1,{1,1,1},{0,0,0}};
    quad(f,&mm,a,b,c,d,&g_tex[T_STONE]);
    (void)chk;
  }
  /* floor: left half affine (PS1 warp), right half perspective-correct */
  f->filter=FILT_NEAREST;
  for(int half=0;half<2;half++){
    f->affine = (half==0);
    float x0=half? 0.2f : -8.0f, x1=half? 8.0f : -0.2f;
    vtx_t a={{x0,0,-8},0,0,{1,1,1},{0,0,0}};
    vtx_t b={{x1,0,-8},4,0,{1,1,1},{0,0,0}};
    vtx_t c={{x1,0, 4},4,6,{1,1,1},{0,0,0}};
    vtx_t d={{x0,0, 4},0,6,{1,1,1},{0,0,0}};
    quad(f,NULL,a,b,c,d,&chk);
  }
  f->affine=0;
  finish(f,out,2,0);
}

static void scene_chars(const char *out){
  /* character sheet: guy at 4 walk phases + one big posed, no fog */
  fb_t *f = fb_new(480,270);
  f->fog_on=0;
  f->filter=FILT_3POINT;
  f->ambient=(v3){0.45f,0.45f,0.5f};
  sky(f, 0xffb08858u, 0xffd8c8a8u);
  f->view = m4_lookat((v3){0,2.2f,7.5f},(v3){0,1.1f,0},(v3){0,1,0});
  f->proj = m4_persp(45, 480.0f/270.0f, 0.3f, 100);
  /* ground slab */
  vtx_t a={{-8,0,-4},0,0,{1,1,1},{0,1,0}}, b={{8,0,-4},8,0,{1,1,1},{0,1,0}};
  vtx_t c={{8,0,4},8,4,{1,1,1},{0,1,0}},  d={{-8,0,4},0,4,{1,1,1},{0,1,0}};
  quad(f,NULL,a,b,c,d,&g_tex[T_STONE]);
  for(int i=0;i<4;i++){
    m4 root=m4_mul(m4_translate(-4.5f+i*2.1f,0,0.5f), m4_roty(0.6f));
    draw_guy(f,root,walk_pose(i/4.0f),NULL);
  }
  m4 root=m4_mul(m4_translate(3.9f,0,1.2f), m4_mul(m4_roty(-0.5f), m4_scale(1.35f,1.35f,1.35f)));
  pose_t wave; memset(&wave,0,sizeof wave);
  wave.rot[4].z=-2.4f; wave.rot[4].x=-0.3f; wave.rot[2].z=0.15f;
  draw_guy(f,root,wave,NULL);
  finish(f,out,2,1);
}

int main(int argc, char **argv){
  const char *scene = argc>1? argv[1] : "n64";
  char path[256];
  snprintf(path,sizeof path,"out/%s.png",scene);
  const char *out = argc>2? argv[2] : path;
  for(int i=3;i<argc;i++){
    if(!strcmp(argv[i],"--dump") && i+1<argc){ g_dump = argv[++i]; r3d_capture = cap_tri; }
    else if(!strcmp(argv[i],"--soft")) r3d_soft_upscale = 1;
  }
  load_textures();
  if(!strcmp(scene,"bench")){
    /* per-frame software raster cost: RO scene content, 60 frames */

    fb_t *f = fb_new(480,270);
    f->filter=FILT_3POINT; f->fog_on=1;
    f->fog_color=(v3){0.70f,0.76f,0.88f}; f->fog_start=95; f->fog_end=170;
    terrain_t *T=terr_demo();
    v3 focus={30,0,26}; focus.y=terr_sample(T,focus.x,focus.z);
    float dist=76.0f, pitch=0.96f;
    f->view = m4_lookat((v3){focus.x,focus.y+dist*sinf(pitch),focus.z+dist*cosf(pitch)},focus,(v3){0,1,0});
    f->proj = m4_persp(15, 480.0f/270.0f, 1.0f, 220);
    struct timespec t0,t1;
    clock_gettime(CLOCK_MONOTONIC,&t0);
    for(int i=0;i<60;i++){
      fb_clear_gradient(f, 0xffe0a866u, 0xfff0d8b0u);
      scene_common(f,T);
      m4 root=m4_mul(m4_translate(focus.x,focus.y,focus.z), m4_roty(i*0.1f));
      draw_guy(f,root,walk_pose((i%20)/20.0f),NULL);
    }
    clock_gettime(CLOCK_MONOTONIC,&t1);
    double ms = ((t1.tv_sec-t0.tv_sec)*1e9 + (t1.tv_nsec-t0.tv_nsec))/1e6/60.0;
    fprintf(stderr,"bench: %.2f ms/frame at 480x270 (RO scene)\n", ms);
    return 0;
  }
  if(!strcmp(scene,"n64")) scene_n64(out);
  else if(!strcmp(scene,"ps1")) scene_ps1(out);
  else if(!strcmp(scene,"dungeon")) scene_dungeon(out);
  else if(!strcmp(scene,"graybox")) scene_graybox(out);
  else if(!strcmp(scene,"openworld")) scene_openworld(out);
  else if(!strcmp(scene,"mascot")) scene_mascot(out);
  else if(!strcmp(scene,"rochibi")) scene_rochibi(out);
  else if(!strcmp(scene,"mascoteyes")) scene_mascoteyes(out);
  else if(!strcmp(scene,"ro2")) scene_ro2(out);
  else if(!strcmp(scene,"ro")) scene_ro(out);
  else if(!strcmp(scene,"filters")) scene_filters(out);
  else if(!strcmp(scene,"chars")) scene_chars(out);
  else { fprintf(stderr,"unknown scene %s\n",scene); return 1; }
  return 0;
}
