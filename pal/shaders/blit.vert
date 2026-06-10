#version 450
// present blit: 6 verts forming the letterboxed quad, no vertex input

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

// rect = x0,y0 (top-left) .. x1,y1 (bottom-right) in NDC
layout(set = 1, binding = 0) uniform UBO { vec4 rect; } u;

void main() {
  int corner[6] = int[6](0, 1, 2, 2, 1, 3);
  int c = corner[gl_VertexIndex];
  vec2 t = vec2(float(c & 1), float(c >> 1)); // (0,0) (1,0) (0,1) (1,1)
  v_uv = t;
  v_color = vec4(1.0);
  gl_Position = vec4(mix(u.rect.xy, u.rect.zw, t), 0.0, 1.0);
}
