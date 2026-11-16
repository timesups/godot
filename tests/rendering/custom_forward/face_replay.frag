#version 450
// Captured E689 specialization, not a general-purpose character shader.
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
layout(set=0,binding=10) uniform sampler2D face_mask;
layout(set=0,binding=11) uniform sampler2D face_sdf;
layout(set=0,binding=12) uniform sampler2D face_specular;
layout(set=0,binding=13) uniform sampler2D screen_mask;
layout(set=0,binding=14) uniform sampler2D shadow_atlas;
layout(set=0,binding=15,std430) readonly buffer Shadows { vec4 shadows[]; };
// CHARACTER_LIGHTING_SHARED
// FACE_LIGHTING_SHARED
// FACE_SHADOW_SHARED
void main() {
    ivec2 pixel=ivec2(gl_FragCoord.xy);
    vec3 N=normalize(normal);
    vec4 base4=texture(base_map,uv,g[108].x);
    vec4 mask4=texture(face_mask,uv,g[108].x);
    mat3 matrix=mat3(transform[0].xyz,transform[1].xyz,transform[2].xyz);
    vec2 specular_uv=uv+(matrix*normalize(g[44].xyz-world)).xy*vec2(0.03,0.0);
    vec3 specular_stamp=texture(face_specular,specular_uv,g[108].x).rgb;
    vec3 base=base4.rgb;
    uv_dx=vec4(uv,dFdx(uv));
    dy_primitive=vec4(dFdy(uv),float(gl_PrimitiveID),1);
    // Preserve implicit texture derivatives before applying the test-only mask.
    // This isolates a captured subset and is not scene visibility reconstruction.
    if(texelFetch(pixel_mask,pixel,0).r<0.5) discard;
    if(abs(gl_FragCoord.z-texelFetch(captured_depth,pixel,0).r)>5e-8) discard;
    vec3 graded=character_grade(lut_map,base);
    vec3 local_light=normalize(vec3((matrix*g[200].xyz).x,0.0001,(matrix*g[200].xyz).z));
    vec2 sdf_uv=vec2(local_light.x>0.0?uv.x:1.0-uv.x,uv.y);
    vec4 sdf=textureLod(face_sdf,sdf_uv,0.0);
    float cam_z=normalize((matrix*g[6].xyz).xz).y;
    float face_ndl=face_sdf_light((sdf.r+sdf.g)*0.5,local_light.z);
    vec4 ramp=textureLod(ramp_map,vec2(0.5+0.5*mix(face_ndl,clamp(dot(N,g[200].xyz),-1.0,1.0),mask4.g),0.5),0.0);
    vec3 origin=vec3(transform[0].w,transform[1].w,transform[2].w);
    vec3 radial=normalize(vec3(world.x-origin.x,0.0001,world.z-origin.z));
    vec3 surface_color,light_normal,diffuse_base;
    vec3 result=face_lighting(base4,graded,mask4,sdf,ramp,specular_stamp,N,normalize(g[44].xyz-world),radial,cam_z,local_light,transpose(matrix),texelFetch(screen_mask,pixel,0).g,g[193].rgb*lights[3].w,g[192].rgb,g[195].xyz,g[196].xyz,0.28772246837615967,g[189].y,g[189].z,vec3(0.3813261,0.12477182,0.13843161),vec2(0.85,1.0),surface_color,light_normal,diffuse_base);
    uint tile=(uint(pixel.y)/32u)*80u+uint(pixel.x)/32u;
    uint depth_bin=uint(clamp(floor(1.0/gl_FragCoord.w-0.1),0.0,2047.0));
    uint mask=bins[tile*8u]&bins[28800u+depth_bin*8u];
    for(uint id=0u;id<6u;id++) {
        if((mask&(1u<<id))==0u) continue;
        uint offset=6u+8u*id;
        vec4 lc=lights[offset], pos=lights[offset+1u], parms=lights[offset+4u];
        uint mode=floatBitsToUint(lights[offset+3u].w);
        vec3 delta=pos.xyz-world; float d2=dot(delta,delta);
        vec3 L=delta*inversesqrt(d2); float ndl=dot(light_normal,L);
        float power=lights[offset+6u].w;
        float attenuation=character_attenuation(d2,pos.w,power);
        if(lc.w<0.5) {
            vec4 packed=lights[offset+2u];
            float x=0.5+0.5*packed.y-abs(packed.x),y=packed.y-x;
            float z=max(1.0-abs(x)-abs(y),0.0005)*(packed.x>=0.0?1.0:-1.0);
            vec3 axis=normalize(vec3(x,y,z));
            attenuation*=pow(character_sat((dot(L,-axis)-packed.z)*packed.w),2.0);
        }
        if(attenuation<=0.0001) continue;
        if(mode==0u) {
            result+=face_local_zero(lc.rgb,attenuation,L,radial,light_normal,mask4.g,parms.x,parms.y,surface_color);
        } else if(mode==1u) {
            vec3 radial=normalize(vec3(world.x-origin.x,0.0001,world.z-origin.z));
            float shadow=character_sat(dot(radial,L)+1.0);
            result+=face_local_one(lc.rgb,attenuation,ndl,parms,shadow,mask4.g,sdf.a,graded,diffuse_base);
        } else if(mode==3u) {
            int shadow_index=int(lights[offset+3u].x);
            int matrix_offset=64+4*shadow_index;
            mat4 shadow_matrix=mat4(shadows[matrix_offset],shadows[matrix_offset+1],shadows[matrix_offset+2],shadows[matrix_offset+3]);
            float shadow=face_shadow_atlas(shadow_atlas,shadow_matrix,shadows[344+shadow_index],shadows[288+shadow_index],world,N,pos.xyz);
            result+=face_local_three(lc.rgb,attenuation,L,normalize(g[44].xyz-world),g[6].xyz,light_normal,cam_z,mask4.a,parms.x,parms.y,shadow,diffuse_base);
        }
    }
    hdr=vec4(result,1);
    raw_hdr=hdr;
    sampled_base=vec4(base,1);
    // FACE_DIAGNOSTICS
}
