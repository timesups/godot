#version 450
layout(set=0,binding=0,std430) readonly buffer Vertices { vec4 v[]; };
layout(location=0) out vec2 uv;
layout(location=1) out vec3 normal;
layout(location=2) out vec4 tangent;
void main() {
    uint i=uint(gl_VertexIndex)*9u;
    gl_Position=v[i];
    uv=v[i+1u].xy;
    normal=v[i+3u].xyz;
    tangent=v[i+4u];
}
