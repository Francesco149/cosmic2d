#version 450
// VI-soft present blit (pal.x_soft): the game target sampled BILINEARLY (the
// N64 VI resample) plus a mild 3-tap horizontal smear ([1,2,1]/4) at
// destination resolution — proto r3d.c fb_write_png --soft is the reference
// math. Presentation only: the internal target (readback/goldens) never sees
// this. The sharp path keeps quad.frag (bit-identical).

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;

layout(location = 0) out vec4 o_color;

layout(set = 2, binding = 0) uniform sampler2D u_tex;
layout(set = 3, binding = 0) uniform Soft {
  vec4 px; // x = one destination pixel in uv (1 / blit-rect width px)
} s;

void main() {
  vec2 dx = vec2(s.px.x, 0.0);
  vec3 a = texture(u_tex, v_uv - dx).rgb;
  vec4 b = texture(u_tex, v_uv);
  vec3 c = texture(u_tex, v_uv + dx).rgb;
  o_color = vec4((a + 2.0 * b.rgb + c) * 0.25, b.a) * v_color;
}
