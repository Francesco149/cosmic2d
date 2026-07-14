#version 450
// present blit WITH a color grade (pal.x_grade) — used only when a grade is
// active; the ungraded path keeps quad.frag (bit-identical). Render/dev only
// (D036): the grade lives on the final game-target blit, never in the sim.

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;

layout(location = 0) out vec4 o_color;

layout(set = 2, binding = 0) uniform sampler2D u_tex;
layout(set = 3, binding = 0) uniform Grade {
  vec4 bcs;  // brightness (add), contrast, saturation, (pad)
  vec4 tint; // rgb multiply, (pad)
} g;

void main() {
  vec4 s = texture(u_tex, v_uv);
  vec3 c = s.rgb;
  c += g.bcs.x;                                   // brightness
  c = (c - 0.5) * g.bcs.y + 0.5;                  // contrast (pivot 0.5)
  float l = dot(c, vec3(0.299, 0.587, 0.114));    // luma
  c = mix(vec3(l), c, g.bcs.z);                   // saturation
  c *= g.tint.rgb;                                // tint (warm/cool multiply)
  o_color = vec4(clamp(c, 0.0, 1.0), s.a) * v_color;
}
