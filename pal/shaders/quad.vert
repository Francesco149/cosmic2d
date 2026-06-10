#version 450
// scene quads: positions in internal-target pixels, top-left origin

layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

// xy = scale, zw = offset (pixel -> NDC)
layout(set = 1, binding = 0) uniform UBO { vec4 proj; } u;

void main() {
  gl_Position = vec4(in_pos * u.proj.xy + u.proj.zw, 0.0, 1.0);
  v_uv = in_uv;
  v_color = in_color;
}
