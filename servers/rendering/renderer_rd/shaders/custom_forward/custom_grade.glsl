#[vertex]
#version 450
#VERSION_DEFINES
layout(location = 0) out vec2 uv;
void main() {
	vec2 p = gl_VertexIndex == 0 ? vec2(-1, -1) : (gl_VertexIndex == 1 ? vec2(-1, 3) : vec2(3, -1));
	gl_Position = vec4(p, 0, 1);
	uv = (p + 1.0) * 0.5;
}
#[fragment]
#version 450
#VERSION_DEFINES
#include "custom_grade_inc.glsl"
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 out_color;
void main() {
	out_color = vec4(encode_output(grade(uv), uv), textureLod(source_color, uv, 0.0).a);
}
