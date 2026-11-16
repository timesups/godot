#version 450
layout(set=0,binding=0,std430) readonly buffer Vertices { vec4 v[]; };
layout(location=0) out vec2 uv;
layout(location=1) out vec3 normal;
layout(location=2) out vec4 tangent;
layout(location=3) out vec3 world;
void main() {
    uint i=uint(gl_VertexIndex)*8u;
    gl_Position=v[i];
    uv=v[i+1u].xy;
    world=v[i+2u].xyz;
    normal=v[i+3u].xyz;
    tangent=vec4(1,0,0,1);
}
