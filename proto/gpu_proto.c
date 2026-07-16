/* gpu_proto — renders a .c3dd scene dump through SDL_GPU with a fixed
 * "retro pipeline": depth-tested triangles, per-vertex color (pre-lit),
 * fog in the vertex shader, N64 three-point / nearest filtering in the
 * fragment shader, alpha-test cutouts, alpha-blended decals.
 * Headless: no window; renders to an offscreen target, downloads, PNG.
 * Mirrors cosmic2d's PAL patterns (gfx.c) so the integration cost is honest.
 *
 * usage: gpu_proto scene.c3dd out.png
 */
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "r3d.h" /* fb_t + fb_write_png for the same quantize/upscale output */

typedef struct { float pos[3], uv[2]; uint8_t col[4]; } dvtx;
typedef struct { int32_t tex; uint32_t flags; dvtx v[3]; } dtri;

static SDL_GPUDevice *dev;

static SDL_GPUShader *load_shader(const char *path, SDL_GPUShaderStage stage,
                                  Uint32 nsamp, Uint32 nuni){
  size_t len=0;
  void *code = SDL_LoadFile(path,&len);
  if(!code){ fprintf(stderr,"shader %s: %s\n",path,SDL_GetError()); exit(1); }
  SDL_GPUShaderCreateInfo ci = {
    .code_size=len, .code=code, .entrypoint="main",
    .format=SDL_GPU_SHADERFORMAT_SPIRV, .stage=stage,
    .num_samplers=nsamp, .num_uniform_buffers=nuni,
  };
  SDL_GPUShader *sh = SDL_CreateGPUShader(dev,&ci);
  SDL_free(code);
  if(!sh){ fprintf(stderr,"shader %s: %s\n",path,SDL_GetError()); exit(1); }
  return sh;
}

static SDL_GPUGraphicsPipeline *make_pipeline(SDL_GPUShader *vs, SDL_GPUShader *fs,
                                              int blend, int depth_write){
  SDL_GPUVertexBufferDescription vbd = {
    .slot=0, .pitch=sizeof(dvtx), .input_rate=SDL_GPU_VERTEXINPUTRATE_VERTEX,
  };
  SDL_GPUVertexAttribute attrs[3] = {
    {.location=0,.buffer_slot=0,.format=SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,.offset=0},
    {.location=1,.buffer_slot=0,.format=SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,.offset=12},
    {.location=2,.buffer_slot=0,.format=SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM,.offset=20},
  };
  SDL_GPUColorTargetDescription ct = {
    .format=SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
    .blend_state={
      .enable_blend=blend?true:false,
      .src_color_blendfactor=SDL_GPU_BLENDFACTOR_SRC_ALPHA,
      .dst_color_blendfactor=SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
      .color_blend_op=SDL_GPU_BLENDOP_ADD,
      .src_alpha_blendfactor=SDL_GPU_BLENDFACTOR_ONE,
      .dst_alpha_blendfactor=SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
      .alpha_blend_op=SDL_GPU_BLENDOP_ADD,
    },
  };
  SDL_GPUGraphicsPipelineCreateInfo ci = {
    .vertex_shader=vs, .fragment_shader=fs,
    .primitive_type=SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
    .rasterizer_state={.fill_mode=SDL_GPU_FILLMODE_FILL,
                       .cull_mode=SDL_GPU_CULLMODE_NONE},
    .multisample_state={.sample_count=SDL_GPU_SAMPLECOUNT_1},
    .depth_stencil_state={
      .compare_op=SDL_GPU_COMPAREOP_LESS_OR_EQUAL,
      .enable_depth_test=true,
      .enable_depth_write=depth_write?true:false,
    },
    .target_info={
      .color_target_descriptions=&ct, .num_color_targets=1,
      .depth_stencil_format=SDL_GPU_TEXTUREFORMAT_D16_UNORM,
      .has_depth_stencil_target=true,
    },
  };
  ci.vertex_input_state.vertex_buffer_descriptions=&vbd;
  ci.vertex_input_state.num_vertex_buffers=1;
  ci.vertex_input_state.vertex_attributes=attrs;
  ci.vertex_input_state.num_vertex_attributes=3;
  SDL_GPUGraphicsPipeline *p = SDL_CreateGPUGraphicsPipeline(dev,&ci);
  if(!p){ fprintf(stderr,"pipeline: %s\n",SDL_GetError()); exit(1); }
  return p;
}

static SDL_GPUTexture *tex_create(const void *pixels, int w, int h){
  SDL_GPUTexture *t = SDL_CreateGPUTexture(dev,&(SDL_GPUTextureCreateInfo){
    .type=SDL_GPU_TEXTURETYPE_2D,
    .format=SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
    .usage=SDL_GPU_TEXTUREUSAGE_SAMPLER,
    .width=(Uint32)w,.height=(Uint32)h,.layer_count_or_depth=1,.num_levels=1});
  Uint32 bytes=(Uint32)(w*h*4);
  SDL_GPUTransferBuffer *tb = SDL_CreateGPUTransferBuffer(dev,
    &(SDL_GPUTransferBufferCreateInfo){.usage=SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,.size=bytes});
  void *p = SDL_MapGPUTransferBuffer(dev,tb,false);
  memcpy(p,pixels,bytes);
  SDL_UnmapGPUTransferBuffer(dev,tb);
  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(dev);
  SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(cmd);
  SDL_UploadToGPUTexture(cp,
    &(SDL_GPUTextureTransferInfo){.transfer_buffer=tb,.pixels_per_row=(Uint32)w,.rows_per_layer=(Uint32)h},
    &(SDL_GPUTextureRegion){.texture=t,.w=(Uint32)w,.h=(Uint32)h,.d=1}, false);
  SDL_EndGPUCopyPass(cp);
  SDL_SubmitGPUCommandBuffer(cmd);
  SDL_ReleaseGPUTransferBuffer(dev,tb);
  return t;
}

static void rd(void *dst, size_t sz, size_t n, FILE *fp){
  if(fread(dst,sz,n,fp)!=n){ fprintf(stderr,"truncated dump\n"); exit(1); }
}

int main(int argc, char **argv){
  if(argc<3){ fprintf(stderr,"usage: gpu_proto scene.c3dd out.png\n"); return 1; }
  FILE *fp=fopen(argv[1],"rb");
  if(!fp){ fprintf(stderr,"can't open %s\n",argv[1]); return 1; }
  uint32_t magic,ver; rd(&magic,4,1,fp); rd(&ver,4,1,fp);
  if(magic!=0x44443343u){ fprintf(stderr,"bad magic\n"); return 1; }
  int32_t wh[4]; rd(wh,4,4,fp);
  int W=wh[0],H=wh[1],scale=wh[2],quant=wh[3];
  float view[16],proj[16]; rd(view,4,16,fp); rd(proj,4,16,fp);
  float fog[6]; rd(fog,4,6,fp);
  uint32_t sky[2]; rd(sky,4,2,fp);
  uint32_t ntex; rd(&ntex,4,1,fp);
  struct { int32_t w,h; void *px; } texs[32];
  for(uint32_t i=0;i<ntex;i++){
    rd(&texs[i].w,4,1,fp); rd(&texs[i].h,4,1,fp);
    texs[i].px=malloc((size_t)texs[i].w*texs[i].h*4);
    rd(texs[i].px,4,(size_t)texs[i].w*texs[i].h,fp);
  }
  uint32_t ntri; rd(&ntri,4,1,fp);
  dtri *tris=malloc(sizeof(dtri)*ntri);
  rd(tris,sizeof(dtri),ntri,fp);
  fclose(fp);

  if(!SDL_Init(SDL_INIT_VIDEO)){ fprintf(stderr,"sdl: %s\n",SDL_GetError()); return 1; }
  dev = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_SPIRV, true, NULL);
  if(!dev){ fprintf(stderr,"gpu device: %s\n",SDL_GetError()); return 1; }
  fprintf(stderr,"gpu driver: %s\n", SDL_GetGPUDeviceDriver(dev));

  SDL_GPUShader *vs = load_shader("retro.vert.spv", SDL_GPU_SHADERSTAGE_VERTEX, 0, 1);
  SDL_GPUShader *fs = load_shader("retro.frag.spv", SDL_GPU_SHADERSTAGE_FRAGMENT, 1, 1);
  SDL_GPUGraphicsPipeline *pipe_opaque = make_pipeline(vs,fs,0,1);
  SDL_GPUGraphicsPipeline *pipe_blend  = make_pipeline(vs,fs,1,0);

  SDL_GPUTexture *target = SDL_CreateGPUTexture(dev,&(SDL_GPUTextureCreateInfo){
    .type=SDL_GPU_TEXTURETYPE_2D,
    .format=SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
    .usage=SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
    .width=(Uint32)W,.height=(Uint32)H,.layer_count_or_depth=1,.num_levels=1});
  SDL_GPUTexture *depth = SDL_CreateGPUTexture(dev,&(SDL_GPUTextureCreateInfo){
    .type=SDL_GPU_TEXTURETYPE_2D,
    .format=SDL_GPU_TEXTUREFORMAT_D16_UNORM,
    .usage=SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
    .width=(Uint32)W,.height=(Uint32)H,.layer_count_or_depth=1,.num_levels=1});

  uint32_t white=0xffffffffu;
  SDL_GPUTexture *tex_white = tex_create(&white,1,1);
  SDL_GPUTexture *gputex[33];
  gputex[0]=tex_white;
  for(uint32_t i=0;i<ntex;i++) gputex[i+1]=tex_create(texs[i].px,texs[i].w,texs[i].h);
  SDL_GPUSampler *sampler = SDL_CreateGPUSampler(dev,&(SDL_GPUSamplerCreateInfo){
    .min_filter=SDL_GPU_FILTER_NEAREST,.mag_filter=SDL_GPU_FILTER_NEAREST,
    .address_mode_u=SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
    .address_mode_v=SDL_GPU_SAMPLERADDRESSMODE_REPEAT});

  /* vertex data: sky quad (NDC, fog off, white tex) + scene tris in submit
   * order, split into segments on state change (texture, flags) */
  size_t nverts = 6 + (size_t)ntri*3;
  dvtx *verts = malloc(nverts*sizeof(dvtx));
  /* sky: full-screen quad at far depth, gradient via vertex colors */
  uint8_t *st=(uint8_t*)&sky[0], *sb=(uint8_t*)&sky[1];
  dvtx sv[4]={
    {{-1, 1, 0.9999f},{0,0},{st[0],st[1],st[2],255}},
    {{ 1, 1, 0.9999f},{0,0},{st[0],st[1],st[2],255}},
    {{ 1,-1, 0.9999f},{0,0},{sb[0],sb[1],sb[2],255}},
    {{-1,-1, 0.9999f},{0,0},{sb[0],sb[1],sb[2],255}},
  };
  verts[0]=sv[0]; verts[1]=sv[1]; verts[2]=sv[2];
  verts[3]=sv[0]; verts[4]=sv[2]; verts[5]=sv[3];
  typedef struct { uint32_t first, count; int32_t tex; uint32_t flags; } seg_t;
  seg_t *segs=malloc(sizeof(seg_t)*(ntri+1)); int nsegs=0;
  uint32_t vi=6;
  for(uint32_t i=0;i<ntri;i++){
    dtri *t=&tris[i];
    if(!nsegs || segs[nsegs-1].tex!=t->tex || segs[nsegs-1].flags!=t->flags){
      segs[nsegs++] = (seg_t){vi,0,t->tex,t->flags};
    }
    verts[vi++]=t->v[0]; verts[vi++]=t->v[1]; verts[vi++]=t->v[2];
    segs[nsegs-1].count+=3;
  }

  SDL_GPUBuffer *vbuf = SDL_CreateGPUBuffer(dev,&(SDL_GPUBufferCreateInfo){
    .usage=SDL_GPU_BUFFERUSAGE_VERTEX,.size=(Uint32)(nverts*sizeof(dvtx))});
  SDL_GPUTransferBuffer *tb = SDL_CreateGPUTransferBuffer(dev,
    &(SDL_GPUTransferBufferCreateInfo){.usage=SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                                       .size=(Uint32)(nverts*sizeof(dvtx))});
  void *mp=SDL_MapGPUTransferBuffer(dev,tb,false);
  memcpy(mp,verts,nverts*sizeof(dvtx));
  SDL_UnmapGPUTransferBuffer(dev,tb);

  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(dev);
  SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(cmd);
  SDL_UploadToGPUBuffer(cp,
    &(SDL_GPUTransferBufferLocation){.transfer_buffer=tb},
    &(SDL_GPUBufferRegion){.buffer=vbuf,.size=(Uint32)(nverts*sizeof(dvtx))}, false);
  SDL_EndGPUCopyPass(cp);

  /* mvp = proj * view (column major) */
  float mvp[16];
  for(int c=0;c<4;c++)for(int r=0;r<4;r++){
    float s=0; for(int k=0;k<4;k++) s+=proj[k*4+r]*view[c*4+k];
    mvp[c*4+r]=s;
  }
  float ident[16]={1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};

  SDL_GPUColorTargetInfo cti = {
    .texture=target, .clear_color={0,0,0,1},
    .load_op=SDL_GPU_LOADOP_CLEAR, .store_op=SDL_GPU_STOREOP_STORE,
  };
  SDL_GPUDepthStencilTargetInfo dsti = {
    .texture=depth, .clear_depth=1.0f,
    .load_op=SDL_GPU_LOADOP_CLEAR, .store_op=SDL_GPU_STOREOP_DONT_CARE,
  };
  SDL_GPURenderPass *rp = SDL_BeginGPURenderPass(cmd,&cti,1,&dsti);

  struct { float mvp[16]; float fog[4]; } vubo;
  struct { float mode[4]; float fogcol[4]; } fubo;
  memcpy(fubo.fogcol,(float[]){fog[3],fog[4],fog[5],1},16);

  /* sky segment: identity mvp, fog off, white texture, nearest */
  SDL_BindGPUGraphicsPipeline(rp,pipe_opaque);
  SDL_BindGPUVertexBuffers(rp,0,&(SDL_GPUBufferBinding){.buffer=vbuf},1);
  memcpy(vubo.mvp,ident,64);
  memcpy(vubo.fog,(float[]){0,1,0,0},16);
  SDL_PushGPUVertexUniformData(cmd,0,&vubo,sizeof vubo);
  memcpy(fubo.mode,(float[]){0,0,0,0},16);
  SDL_PushGPUFragmentUniformData(cmd,0,&fubo,sizeof fubo);
  SDL_BindGPUFragmentSamplers(rp,0,&(SDL_GPUTextureSamplerBinding){.texture=tex_white,.sampler=sampler},1);
  SDL_DrawGPUPrimitives(rp,6,1,0,0);

  /* scene segments */
  memcpy(vubo.mvp,mvp,64);
  memcpy(vubo.fog,(float[]){fog[1],fog[2],fog[0],0},16);
  SDL_PushGPUVertexUniformData(cmd,0,&vubo,sizeof vubo);
  int cur_blend=-1;
  for(int i=0;i<nsegs;i++){
    seg_t *s=&segs[i];
    int blend = (s->flags&4)?1:0;
    if(blend!=cur_blend){
      SDL_BindGPUGraphicsPipeline(rp, blend?pipe_blend:pipe_opaque);
      SDL_BindGPUVertexBuffers(rp,0,&(SDL_GPUBufferBinding){.buffer=vbuf},1);
      SDL_PushGPUVertexUniformData(cmd,0,&vubo,sizeof vubo); /* rebind after pipeline switch */
      cur_blend=blend;
    }
    float filt = (s->flags&2)?0.0f:1.0f;     /* nearest : threepoint */
    float atest = (s->flags&1)?1.0f:0.0f;
    memcpy(fubo.mode,(float[]){filt,atest,0,0},16);
    SDL_PushGPUFragmentUniformData(cmd,0,&fubo,sizeof fubo);
    SDL_GPUTexture *t = (s->tex<0)? tex_white : gputex[s->tex+1];
    SDL_BindGPUFragmentSamplers(rp,0,&(SDL_GPUTextureSamplerBinding){.texture=t,.sampler=sampler},1);
    SDL_DrawGPUPrimitives(rp,s->count,1,s->first,0);
  }
  SDL_EndGPURenderPass(rp);

  /* readback */
  SDL_GPUTransferBuffer *rb = SDL_CreateGPUTransferBuffer(dev,
    &(SDL_GPUTransferBufferCreateInfo){.usage=SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
                                       .size=(Uint32)(W*H*4)});
  SDL_GPUCopyPass *cp2 = SDL_BeginGPUCopyPass(cmd);
  SDL_DownloadFromGPUTexture(cp2,
    &(SDL_GPUTextureRegion){.texture=target,.w=(Uint32)W,.h=(Uint32)H,.d=1},
    &(SDL_GPUTextureTransferInfo){.transfer_buffer=rb,.pixels_per_row=(Uint32)W,.rows_per_layer=(Uint32)H});
  SDL_EndGPUCopyPass(cp2);
  SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
  SDL_WaitForGPUFences(dev,true,&fence,1);
  SDL_ReleaseGPUFence(dev,fence);

  void *pix = SDL_MapGPUTransferBuffer(dev,rb,false);
  /* reuse the software path's quantize+integer-upscale PNG output */
  fb_t *out = fb_new(W,H);
  memcpy(out->color,pix,(size_t)W*H*4);
  SDL_UnmapGPUTransferBuffer(dev,rb);
  fb_write_png(out,argv[2],scale,quant);
  return 0;
}
