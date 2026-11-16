#version 450
layout(location=0) in vec2 uv;
layout(location=1) in vec3 normal;
layout(location=2) in vec4 tangent;
layout(location=3) in vec3 world;
layout(location=0) out vec4 hdr;
layout(location=1) out vec4 raw_hdr;
layout(location=2) out vec4 surface_out;
layout(location=3) out vec4 specular_out;
layout(location=4) out vec4 normal_out;
layout(set=0,binding=1) uniform sampler2D base_map;
layout(set=0,binding=2) uniform sampler2D normal_map;
layout(set=0,binding=4) uniform sampler2D pixel_mask;
layout(set=0,binding=5) uniform sampler2D captured_depth;
layout(set=0,binding=6,std430) readonly buffer Globals { vec4 g[]; };
layout(set=0,binding=7,std430) readonly buffer Lights { vec4 lights[]; };
layout(set=0,binding=8,std430) readonly buffer Bins { uint bins[]; };
layout(set=0,binding=9) uniform sampler2D screen_map;
layout(set=0,binding=10) uniform sampler2D ramp_map;
layout(set=0,binding=11) uniform sampler2D specular_map;
layout(set=0,binding=14) uniform sampler2D shadow_atlas;
layout(set=0,binding=15,std430) readonly buffer Shadows { vec4 shadows[]; };
// CHARACTER_LIGHTING_SHARED
// CLOTHES_SURFACE_SHARED
// CLOTHES_LIGHTING_SHARED
// SKIN_LIGHTING_SHARED
// FACE_SHADOW_SHARED
void main() {
    vec4 base=texture(base_map,uv,g[108].x);
    vec3 graded=character_grade(specular_map,base.rgb);
    vec4 parameters=vec4(0.0,0.454,base.a,0.258);
    vec3 tn=clothes_tangent_normal(texture(normal_map,uv,g[108].x),1.0);
    vec3 n=clothes_world_normal(normal,tangent,tn,gl_FrontFacing,0.0);
    vec3 geometric=normalize(normal)*(gl_FrontFacing?1.0:-1.0);
    ivec2 pixel=ivec2(gl_FragCoord.xy);
    if(texelFetch(pixel_mask,pixel,0).r<0.5) discard;
    if(abs(gl_FragCoord.z-texelFetch(captured_depth,pixel,0).r)>5e-8) discard;
    vec2 screen=texelFetch(screen_map,pixel,0).rg;
    vec3 V=normalize(g[44].xyz-world);
    vec3 surface,specular_color,analytic,diffuse;
    vec3 result=skin_main(ramp_map,base,graded,parameters,n,V,g[6].xyz,
        g[200].xyz,g[193].rgb*lights[3].w,g[192].rgb,g[195].xyz,g[196].xyz,
        g[111].x,g[189].y,g[189].z,g[189].w,screen,1.0,g[193].rgb,
        vec3(0.381326109,0.124771841,0.138431624),0.85,surface,specular_color,analytic,diffuse);
    uint tile=(uint(pixel.y)/32u)*80u+uint(pixel.x)/32u;
    uint depth_bin=uint(clamp(floor(1.0/gl_FragCoord.w-0.1),0.0,2047.0));
    for(uint word=0u;word<8u;word++) {
      uint mask=bins[tile*8u+word]&bins[28800u+depth_bin*8u+word];
      while(mask!=0u) {
        uint bit=uint(findLSB(mask));mask&=mask-1u;
        uint id=32u*word+bit,offset=6u+8u*id;
        vec4 lc=lights[offset],pos=lights[offset+1u],packed=lights[offset+2u],parms=lights[offset+4u];
        int mode=int(floatBitsToUint(lights[offset+3u].w));
        if(lc.w>=1.5||mode==16)continue;
        vec3 delta=pos.xyz-world;
        float d2=dot(delta,delta);
        vec3 L=delta*inversesqrt(d2);
        float power=mode==4?max(2.0*parms.y,0.1):lights[offset+6u].w;
        float attenuation=character_attenuation(d2,pos.w,power);
        if(lc.w<0.5) {
            float x=0.5+0.5*packed.y-abs(packed.x),y=packed.y-x;
            float z=max(1.0-abs(x)-abs(y),0.0005)*(packed.x>=0.0?1.0:-1.0);
            vec3 axis=normalize(vec3(x,y,z));
            attenuation*=pow(character_sat((dot(L,-axis)-packed.z)*packed.w),2.0);
        }
        if(attenuation<=0.0001)continue;
        if(mode==4) {
            result=mix(result,lc.rgb,attenuation*parms.x*mix(1.0,smoothstep(-0.5,0.5,dot(geometric,L)),parms.w));
            continue;
        }
        float shadow=1.0;
        if(mode!=0) {
            int index=lc.w<0.5?int(lights[offset+3u].x):-1;
            if(index>=0) {
                int m=64+4*index;
                shadow=face_shadow_atlas(shadow_atlas,mat4(shadows[m],shadows[m+1],shadows[m+2],shadows[m+3]),
                    shadows[344+index],shadows[288+index],world,geometric,pos.xyz);

            } else {
                vec3 radial=normalize(vec3(world.x+299.972351074,0.0001,world.z+299.976745605));
                shadow=character_sat(dot(radial,L)+1.0);
            }
        }
        result+=skin_local(lc.rgb,attenuation,L,n,V,g[6].xyz,mode,parms,shadow,screen.r,
            surface,diffuse,graded*0.96,specular_color,clothes_roughness(parameters),lights[offset+7u].z);
      }
    }
    hdr=vec4(result,1.0);
    raw_hdr=hdr;
    surface_out=vec4(surface,1.0);
    specular_out=vec4(analytic,1.0);
    normal_out=vec4(n,float(gl_PrimitiveID));
    // SKIN_DIAGNOSTICS
}
