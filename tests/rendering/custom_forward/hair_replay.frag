#version 450
layout(location=0) in vec2 uv;
layout(location=1) in vec3 normal;
layout(location=2) in vec4 tangent;
layout(location=3) in vec3 world;
layout(location=0) out vec4 hdr;
layout(location=1) out vec4 raw_hdr;
layout(location=2) out vec4 surface_out;
layout(location=3) out vec4 specular_out;
layout(location=4) out vec4 secondary_out;
layout(set=0,binding=1) uniform sampler2D base_map;
layout(set=0,binding=2) uniform sampler2D normal_map;
layout(set=0,binding=3) uniform sampler2D parameters_map;
layout(set=0,binding=4) uniform sampler2D pixel_mask;
layout(set=0,binding=5) uniform sampler2D captured_depth;
layout(set=0,binding=6,std430) readonly buffer Globals { vec4 g[]; };
layout(set=0,binding=7,std430) readonly buffer Lights { vec4 lights[]; };
layout(set=0,binding=8,std430) readonly buffer Bins { uint bins[]; };
layout(set=0,binding=9) uniform sampler2D screen_map;
layout(set=0,binding=10) uniform sampler2D ramp_map;
layout(set=0,binding=11) uniform sampler2D specular_map;
layout(set=0,binding=12) uniform sampler2D material_lut;
layout(set=0,binding=13) uniform sampler2D noise_map;
layout(set=0,binding=16,std430) readonly buffer Transform { vec4 transform[]; };
layout(set=0,binding=14) uniform sampler2D shadow_atlas;
layout(set=0,binding=15,std430) readonly buffer Shadows { vec4 shadows[]; };
// CHARACTER_LIGHTING_SHARED
// HAIR_LIGHTING_SHARED
// FACE_SHADOW_SHARED
void main() {
    vec3 base=texture(base_map,uv,g[108].x).rgb;
    vec4 parameters=texture(parameters_map,uv,g[108].x);
    vec4 normals=texture(normal_map,uv,g[108].x);
    float noise=texture(noise_map,uv*vec2(8,1)).r;
    mat3 tbn=mat3(tangent.xyz,cross(normal,tangent.xyz)*tangent.w,normal);
    vec3 n=normalize(tbn*hair_decode_normal(normals.rg))*(gl_FrontFacing?1.0:-1.0);
    vec3 secondary=normalize(tbn*hair_decode_normal(normals.ba));
    vec3 geometric=normalize(normal)*(gl_FrontFacing?1.0:-1.0);
    ivec2 pixel=ivec2(gl_FragCoord.xy);
    if(texelFetch(pixel_mask,pixel,0).r<0.5) discard;
    if(abs(gl_FragCoord.z-texelFetch(captured_depth,pixel,0).r)>5e-8) discard;
    vec2 screen=texelFetch(screen_map,pixel,0).rg;
    vec3 V=normalize(g[44].xyz-world);
    mat3 world_to_object=mat3(transform[0].xyz,transform[1].xyz,transform[2].xyz);
    vec3 graded=character_grade(material_lut,base);
    vec3 surface,specular_irradiance;
    vec3 diffuse_result=hair_diffuse(ramp_map,base,graded,parameters,n,g[6].xyz,g[200].xyz,
        g[194].rgb*lights[3].w,g[191].rgb,g[195].xyz,g[196].xyz,g[111].x,g[189].y,g[189].z,g[189].w,
        screen,surface,specular_irradiance);
    vec4 spec_shape=vec4(0.468,0.498,1.5,1.37);
    vec4 strand_shape=vec4(0.41,0.02,0.5,0.85);
    vec3 strand,primary_axis;
    float view_weight,multiplier;
    hair_frame(secondary,tangent,world_to_object,V,parameters.r,spec_shape,strand_shape,strand,primary_axis,view_weight);
    vec3 specular=hair_main_specular(specular_map,secondary,strand,primary_axis,view_weight,world_to_object,
        V,g[200].xyz,screen.r,parameters,noise,spec_shape,strand_shape,vec3(0.258182913,0.0063984147,0),
        specular_irradiance,1.0,multiplier);
    vec3 result=hair_finish(diffuse_result,specular,multiplier);
    vec3 diffuse=base*0.96;
    vec3 view_normal=mat3(g[0].xyz,g[1].xyz,g[2].xyz)*n;
    vec2 rim_direction=normalize(view_normal.xy)*vec2(1440.0/2560.0,1.0);
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
                vec3 radial=normalize(vec3(world.x-transform[0].w,0.0001,world.z-transform[2].w));
                shadow=character_sat(dot(radial,L)+1.0);
            }
        }
        vec2 rim_uv=clamp(gl_FragCoord.xy*g[82].zw+rim_direction*parms.x*0.006,g[87].zw-1.0,2.0-g[87].zw);
        // Source sampler is point-clamp: linear filtering leaks background depth into hair edges.
        float rim_depth=textureLod(captured_depth,rim_uv,0.0).r;
        float rim_visibility=smoothstep(0.1,0.2,1.0/(g[84].z*rim_depth+g[84].w)-1.0/gl_FragCoord.w);
        result+=hair_local(specular_map,lc.rgb,attenuation,L,n,V,g[6].xyz,mode,parms,shadow,screen.r,rim_visibility,
            surface,diffuse,graded*0.96,primary_axis,view_weight,parameters.g,spec_shape.z,lights[offset+7u].z);
      }
    }
    hdr=vec4(result,1.0);
    raw_hdr=hdr;
    surface_out=vec4(surface,1.0);
    specular_out=vec4(specular,1.0);
    secondary_out=vec4(secondary,float(gl_PrimitiveID));
    // HAIR_DIAGNOSTICS
}
