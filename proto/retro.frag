#version 450
/* cosmic3d retro pipeline — fragment: N64 three-point / nearest sampling
 * (manual, wrap-repeat via texelFetch), alpha test, fog mix. */
layout(location=0) in vec2 v_uv;
layout(location=1) in vec4 v_col;
layout(location=2) in float v_fog;

layout(set=2, binding=0) uniform sampler2D tex;
layout(set=3, binding=0) uniform FUBO {
  vec4 mode;    /* x: 0=nearest 1=threepoint, y: alpha test */
  vec4 fogcol;
} u;

layout(location=0) out vec4 o_col;

vec4 fetch(ivec2 ts, ivec2 p){
  p = ((p % ts) + ts) % ts;
  return texelFetch(tex, p, 0);
}

void main(){
  ivec2 ts = textureSize(tex, 0);
  vec2 tuv = v_uv * vec2(ts);
  vec4 t;
  if(u.mode.x < 0.5){
    t = fetch(ts, ivec2(floor(tuv)));
  }else{
    vec2 c = tuv - 0.5;
    ivec2 p0 = ivec2(floor(c));
    vec2 f = c - vec2(p0);
    if(f.x + f.y < 1.0)
      t = (1.0-f.x-f.y)*fetch(ts,p0) + f.x*fetch(ts,p0+ivec2(1,0)) + f.y*fetch(ts,p0+ivec2(0,1));
    else
      t = (f.x+f.y-1.0)*fetch(ts,p0+ivec2(1,1)) + (1.0-f.y)*fetch(ts,p0+ivec2(1,0)) + (1.0-f.x)*fetch(ts,p0+ivec2(0,1));
  }
  if(u.mode.y > 0.5 && t.a < 0.5) discard;
  vec3 c = v_col.rgb * t.rgb;
  c = mix(c, u.fogcol.rgb, v_fog);
  o_col = vec4(c, v_col.a * t.a);
}
