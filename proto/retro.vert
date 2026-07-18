#version 450
/* cosmic3d retro pipeline — vertex: MVP + fog factor from view depth.
 * Lighting is per-vertex CPU-side (mechanism-not-policy: the shader stays
 * dumb and freezable; sun/ambient policy lives upstream). */
layout(location=0) in vec3 a_pos;
layout(location=1) in vec2 a_uv;
layout(location=2) in vec4 a_col;

layout(set=1, binding=0) uniform VUBO {
  mat4 mvp;
  vec4 fog;     /* x=start y=end z=on */
} u;

layout(location=0) out vec2 v_uv;
layout(location=1) out vec4 v_col;
layout(location=2) out float v_fog;

void main(){
  gl_Position = u.mvp * vec4(a_pos, 1.0);
  v_uv = a_uv;
  v_col = a_col;
  float d = gl_Position.w;
  v_fog = u.fog.z > 0.5 ? clamp((d - u.fog.x) / (u.fog.y - u.fog.x), 0.0, 1.0) : 0.0;
}
