#version 450
// Captured E674 specialization, not a general-purpose character shader.
layout(location=0) in vec2 uv;
layout(location=1) in vec3 world;
layout(location=2) in vec3 normal;
layout(location=0) out vec4 hdr;
layout(location=1) out vec4 raw_hdr;
layout(location=2) out vec4 sampled_base;
layout(location=3) out vec4 uv_dx;
layout(location=4) out vec4 dy_primitive;
layout(set=0,binding=1) uniform sampler2D base_map;
layout(set=0,binding=2) uniform sampler2D lut_map;
layout(set=0,binding=3) uniform sampler2D ramp_map;
layout(set=0,binding=4) uniform sampler2D pixel_mask;
layout(set=0,binding=5) uniform sampler2D captured_depth;
layout(set=0,binding=6,std430) readonly buffer Globals { vec4 g[]; };
layout(set=0,binding=7,std430) readonly buffer Lights { vec4 lights[]; };
layout(set=0,binding=8,std430) readonly buffer Transform { vec4 transform[]; };
layout(set=0,binding=9,std430) readonly buffer Bins { uint bins[]; };
// CHARACTER_LIGHTING_SHARED
void main() {
    ivec2 pixel=ivec2(gl_FragCoord.xy);
    vec3 N=normalize(normal);
    vec3 base=texture(base_map,uv,g[108].x).rgb;
    uv_dx=vec4(uv,dFdx(uv));
    dy_primitive=vec4(dFdy(uv),float(gl_PrimitiveID),1);
    // Preserve implicit texture derivatives before applying the test-only mask.
    // This isolates a captured subset and is not scene visibility reconstruction.
    if(texelFetch(pixel_mask,pixel,0).r<0.5) discard;
    if(abs(gl_FragCoord.z-texelFetch(captured_depth,pixel,0).r)>5e-8) discard;
    vec3 graded=character_grade(lut_map,base);
    mat3 matrix=mat3(transform[0].xyz,transform[1].xyz,transform[2].xyz);
    vec3 projected=normalize(matrix*g[200].xyz); projected.y=0.0;
    projected=normalize(projected*matrix);
    vec3 camera_axis=g[6].xyz;
    vec4 r=textureLod(ramp_map,vec2(0.5+0.5*clamp(dot(N,projected)+g[200].w*g[201].x,-1.0,1.0),0.5),0.0);
    vec4 v=textureLod(ramp_map,vec2(0.5+0.5*dot(N,camera_axis),0.5),0.0);
    vec3 color=character_surface(base,graded,g[189].z,r,v);
    vec3 result=character_main(color,N,r.a,vec3(lights[3].w),g[191].rgb,g[195].xyz,g[196].xyz,0.28772246837615967,g[189].y);
    uint tile=(uint(pixel.y)/32u)*80u+uint(pixel.x)/32u;
    uint depth_bin=uint(clamp(floor(1.0/gl_FragCoord.w-0.1),0.0,2047.0));
    uint mask=bins[tile*8u]&bins[28800u+depth_bin*8u];
    vec3 origin=vec3(transform[0].w,transform[1].w,transform[2].w);
    for(uint id=0u;id<6u;id++) {
        if((mask&(1u<<id))==0u) continue;
        uint offset=6u+8u*id;
        vec4 lc=lights[offset], pos=lights[offset+1u], parms=lights[offset+4u];
        uint mode=floatBitsToUint(lights[offset+3u].w);
        if(mode==3u) continue; // E674 _2141 selects zero final weight.
        vec3 delta=pos.xyz-world; float d2=dot(delta,delta);
        vec3 L=delta*inversesqrt(d2); float ndl=dot(N,L);
        float power=lights[offset+6u].w;
        float attenuation=character_attenuation(d2,pos.w,power);
        if(attenuation<=0.0001) continue;
        if(mode==0u) {
            result+=character_local_zero(lc.rgb,attenuation,ndl,parms.x,parms.y,color);
        } else if(mode==1u) {
            vec3 radial=normalize(vec3(world.x-origin.x,0.0001,world.z-origin.z));
            float shadow=character_sat(dot(radial,L)+1.0);
            result+=character_local_one(lc.rgb,attenuation,ndl,parms.x,parms.y,shadow,graded,base);
        }
    }
    hdr=vec4(result,1);
    raw_hdr=hdr;
    sampled_base=vec4(base,1);
}
