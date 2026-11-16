// E679 active iris specialization. Requires character_lighting.gdshaderinc.
vec2 iris_uv(vec2 uv, vec3 view, vec3 normal, vec4 tangent, float parallax) {
    float inv_length = 1.0 / length(normal);
    vec3 t = tangent.xyz * inv_length;
    vec3 b = cross(normal,tangent.xyz) * (tangent.w>0.0?1.0:-1.0) * inv_length;
    vec3 v = normalize(view * mat3(t,b,normal*inv_length));
    vec2 d = fract(uv)-vec2(0.5);
    // Defined equivalent of the captured reversed-edge smoothstep.
    float weight = 1.0-smoothstep(0.05,0.25,dot(d,d));
    return uv-v.xy*parallax*vec2(1.0,0.25)*weight;
}
void iris_normals(vec2 uv, vec3 normal, vec4 tangent, float curvature,
        out vec3 diffuse_normal, out vec3 matcap_normal, out float outside) {
    vec2 d = fract(uv)*2.0-vec2(1.0);
    outside = step(1.0,dot(d,d));
    vec3 sphere = vec3(-d*curvature,sqrt(1.0-clamp(dot(d,d),0.0,1.0)));
    mat3 basis = mat3(tangent.xyz,cross(normal,tangent.xyz)*tangent.w,normal);
    diffuse_normal = normalize(basis*mix(sphere*vec3(-0.125,-0.125,1.0),vec3(0.0,0.0,1.0),outside));
    matcap_normal = basis*sphere;
}
vec3 iris_main(sampler2D ramp_map, vec4 base, vec4 matcap, vec3 n, vec3 camera_axis,
        vec3 projected_direction, vec3 main_color, vec3 main_tint, vec3 environment_color,
        vec3 environment_direction, vec3 environment_curve, float environment_strength,
        float exposure, float shadow_strength, float ambient_exposure, float shadow,
        vec3 iris_tint, vec3 outside_tint, float outside, vec4 matcap_tint,
        float alternate_value, float alternate_saturation, float matcap_strength,
        out vec3 surface, out vec3 diffuse, out vec3 alternate) {
    diffuse = base.rgb*0.96;
    vec3 graded = base.rgb*alternate_value;
    alternate = mix(vec3(character_luminance(graded)),graded,alternate_saturation)*0.96;
    vec3 tinted_base = diffuse*mix(vec3(1.0),outside_tint,outside)*mix(vec3(1.0),iris_tint,base.a);
    vec4 ramp = textureLod(ramp_map,vec2(0.5+0.5*clamp(dot(n,projected_direction),-1.0,1.0),0.5),0.0);
    float facing = textureLod(ramp_map,vec2(0.5+0.5*dot(n,camera_axis),0.5),0.0).a;
    vec3 low = alternate*shadow_strength;
    vec3 dark = mix(vec3(character_luminance(low*0.65)),low*0.65,1.2);
    dark = mix(dark,low,character_sat(facing+ramp.a));
    vec3 lit = mix(dark,tinted_base,ramp.a);
    float spread = max(ramp.r,max(ramp.g,ramp.b))-min(ramp.r,min(ramp.g,ramp.b));
    vec3 tinted = lit*(1.0-spread+ramp.rgb*spread);
    tinted *= clamp(character_luminance(lit)/max(character_luminance(tinted),0.001),0.0,1.5);
    surface = mix(mix(low,tinted_base,facing),tinted,shadow);
    float h = character_sat(dot(normalize(vec3(n.x,0.0001,n.z)),environment_direction)+environment_curve.x)*environment_curve.y+environment_curve.z;
    vec3 env = h*mix(environment_color,vec3(1.0),ramp.a);
    vec3 direct = (mix(vec3(character_luminance(main_color)),main_color,ramp.a)+env*clamp(environment_strength,0.0,1.5)*main_tint)*exposure;
    vec3 ambient = env*min(mix(0.65,1.0,environment_strength),1.5)*ambient_exposure;
    vec3 irradiance = mix(ambient,direct,shadow);
    float a = mix(facing,ramp.a,shadow);
    vec3 specular = (matcap.rgb*matcap_tint.a+matcap_tint.rgb*matcap.a)*irradiance*(0.5+0.5*a)*mix(shadow_strength,1.0,a);
    vec3 result = irradiance*surface+specular*matcap_strength;
    float y = character_luminance(result);
    return mix(vec3(y),result,1.0+pow(clamp(y-0.5,0.0,0.5),2.0));
}
vec3 iris_local(vec3 color, float attenuation, float ndl, int mode, vec4 parameters,
        float shadow, float main_shadow, vec3 surface, vec3 diffuse, vec3 alternate) {
    if(mode==0) {
        float compression = 1.0/max(1.0,max(color.r,max(color.g,color.b))*attenuation*mix(0.5,0.75,main_shadow));
        return color*mix(1.0,compression,parameters.y)*mix(0.25*parameters.x,1.0,character_sat(ndl+0.5))*attenuation*surface;
    }
    if(mode==1) return color*attenuation*mix(alternate*parameters.y,diffuse,character_sat(ndl+parameters.x)*shadow);
    // Captured E679 explicitly sets the mode-3 final attenuation to zero.
    return vec3(0.0);
}
