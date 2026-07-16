#version 450
// present blit WITH a color grade (pal.x_grade) — used only when a grade is
// active; the ungraded path keeps quad.frag (bit-identical). Render/dev only
// (D036): the grade lives on the final game-target blit, never in the sim.

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;

layout(location = 0) out vec4 o_color;

layout(set = 2, binding = 0) uniform sampler2D u_tex;
layout(set = 3, binding = 0) uniform Grade {
  vec4 bcs;  // brightness (add), contrast, saturation, quant bits (0 = off)
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
  c = clamp(c, 0.0, 1.0);
  if (g.bcs.w >= 1.0) {
    // Bayer-4 dithered n-bit-per-channel quantize (quant=5 = the 5551
    // framebuffer grade) — proto r3d.c fb_write_png is the reference math.
    // This pass runs at internal res, so gl_FragCoord is the game pixel.
    const float bayer[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0,
                                      6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0,
                                      13.0, 5.0);
    float steps = exp2(g.bcs.w) - 1.0;
    int bi = (int(gl_FragCoord.y) & 3) * 4 + (int(gl_FragCoord.x) & 3);
    c = clamp(c + (bayer[bi] / 16.0 - 0.5) / steps, 0.0, 1.0);
    c = floor(c * steps + 0.5) / steps;
  }
  o_color = vec4(c, s.a) * v_color;
}
