#version 450
layout(location=0) in vec2 uv;
layout(location=1) in vec3 normal;
layout(location=2) in vec4 tangent;
layout(location=0) out vec4 base_out;
layout(location=1) out vec4 normal_out;
layout(location=2) out vec4 parameters_out;
layout(location=3) out vec4 diffuse_out;
layout(location=4) out vec4 f0_out;
layout(set=0,binding=1) uniform sampler2D base_map;
layout(set=0,binding=2) uniform sampler2D normal_map;
layout(set=0,binding=3) uniform sampler2D parameters_map;
layout(set=0,binding=4) uniform sampler2D pixel_mask;
layout(set=0,binding=5) uniform sampler2D captured_depth;
// CLOTHES_SURFACE_SHARED
void main() {
    vec4 base=texture(base_map,uv,-1.0);
    vec4 packed=texture(normal_map,uv,-1.0);
    vec4 parameters=texture(parameters_map,uv,-1.0);
    vec3 n=clothes_world_normal(normal,tangent,clothes_tangent_normal(packed,1.0),gl_FrontFacing,0.0);
    // Visibility isolation for the fixture only; evaluate implicit derivatives first.
    ivec2 pixel=ivec2(gl_FragCoord.xy);
    if(texelFetch(pixel_mask,pixel,0).r<0.5) discard;
    if(abs(gl_FragCoord.z-texelFetch(captured_depth,pixel,0).r)>5e-8) discard;
    base_out=vec4(base.rgb,1.0);
    normal_out=vec4(clothes_octahedral_normal(n),0.0,0.0);
    parameters_out=vec4(parameters.rgb,clothes_roughness(parameters));
    diffuse_out=vec4(clothes_diffuse(base.rgb,parameters.r),1.0);
    f0_out=vec4(clothes_f0(base.rgb,parameters),float(gl_PrimitiveID));
}
