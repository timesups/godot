shader_type spatial;
render_mode custom_character, cull_disabled;

#ifdef CHARACTER_ENGINE_SHADOWS
render_mode custom_character_shadows;
uniform bool engine_directional_shadows_enabled = true;
uniform bool engine_local_shadows_enabled = true;
uniform uint main_shadow_id_low = 0u;
uniform uint main_shadow_id_high = 0u;
uniform uint local_shadow_id_low[16];
uniform uint local_shadow_id_high[16];
uniform bool local_shadow_is_spot[16];
#endif


#include "character_lighting.gdshaderinc"
#include "iris_lighting.gdshaderinc"
#include "face_shadow.gdshaderinc"

uniform sampler2D base_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D matcap_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ramp_map : filter_linear, repeat_disable;
uniform vec4 base_tint = vec4(vec3(0.704253137),1.0);
uniform float parallax_strength = 0.01;
uniform float iris_curvature = 1.5;
uniform vec3 iris_tint = vec3(2.0);
uniform vec3 outside_tint = vec3(1.4980392);
uniform vec4 matcap_tint = vec4(0.0083189,0.0131716,0.02357023,1.0);
uniform float matcap_strength = 1.0;
uniform float alternate_value = 0.55;
uniform float alternate_saturation = 1.4;
uniform float mip_bias = -1.0;
uniform vec3 main_direction = vec3(-0.14726211,0.52991927,0.83516431);
uniform vec3 main_color = vec3(1.0);
uniform float main_energy = 1.6243867874;
uniform vec3 environment_color = vec3(0.8490771,0.8957686,1.150923);
uniform vec3 environment_direction = vec3(0.0,1.0,0.0);
uniform vec3 environment_curve = vec3(0.15,1.5,0.5);
uniform float environment_strength = 0.2877224684;
uniform float character_exposure = 1.05;
uniform float shadow_strength = 0.55;
uniform float ambient_exposure = 0.9;
// Explicit defaults; CHARACTER_ENGINE_SHADOWS enables the live Light3D bridge.
// The captured iris ignores screen AO; only x is used, without face SDF.
uniform vec2 screen_shadow_ao = vec2(1.0);
uniform int local_light_count : hint_range(0,16) = 0;
uniform vec4 local_positions[16]; // xyz position, w inverse range
uniform vec4 local_colors[16]; // rgb linear color, w mode 0/1/3/4
uniform vec4 local_parameters[16]; // bias, weight, unused, mode-4 normal blend
uniform vec4 local_attenuation[16]; // power, spot cutoff, spot scale, shadow
uniform vec3 local_directions[16]; // spot emission direction
uniform vec3 radial_origin = vec3(0.0);
uniform bool shadow_atlas_enabled = false;
uniform sampler2D shadow_atlas : filter_nearest, repeat_disable;
uniform bool local_shadow_enabled[16];
uniform mat4 local_shadow_matrices[16];
uniform vec4 local_shadow_rects[16];
uniform vec4 local_shadow_bias[16];

varying vec3 iris_projected;
varying vec3 iris_world;
varying vec3 iris_normal;
varying vec4 iris_tangent;

void vertex() {
    vec3 local_direction = inverse(mat3(MODEL_MATRIX))*main_direction;
    local_direction.y = 0.0;
    if(dot(local_direction,local_direction)<0.000001) { local_direction=vec3(1.0,0.0,0.0); }
    iris_projected = normalize(mat3(MODEL_MATRIX)*local_direction);
	iris_world = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz;
	iris_normal = MODEL_NORMAL_MATRIX * NORMAL;
	vec3 t = (MODEL_MATRIX * vec4(TANGENT,0.0)).xyz;
	vec3 b = (MODEL_MATRIX * vec4(BINORMAL,0.0)).xyz;
	iris_tangent = vec4(t,dot(cross(iris_normal,t),b)>=0.0?1.0:-1.0);
}

void fragment() {
    vec3 view = normalize(CAMERA_POSITION_WORLD-iris_world);
    vec2 shifted = iris_uv(UV,view,iris_normal,iris_tangent,parallax_strength);
    vec4 base = texture(base_map,shifted,mip_bias)*base_tint;
    vec3 n, matcap_normal;
    float outside;
    iris_normals(UV,iris_normal,iris_tangent,iris_curvature,n,matcap_normal,outside);
    // Godot's view forward is -Z; MatCap uses only XY, unchanged by that convention.
    vec2 matcap_uv = normalize(mat3(VIEW_MATRIX)*matcap_normal).xy*0.5+0.5;
    vec4 matcap = texture(matcap_map,matcap_uv,mip_bias);
    vec3 geometric = normalize(iris_normal)*(FRONT_FACING?1.0:-1.0);
    vec3 camera_axis = INV_VIEW_MATRIX[2].xyz;
	vec2 main_screen = screen_shadow_ao;
#ifdef CHARACTER_ENGINE_SHADOWS
	if (engine_directional_shadows_enabled) {
		main_screen.x *= custom_forward_directional_shadow(uvec2(main_shadow_id_low,main_shadow_id_high),
				(VIEW_MATRIX*vec4(iris_world,1.0)).xyz,normalize(mat3(VIEW_MATRIX)*geometric));
	}
#endif
    vec3 surface, diffuse, alternate;
    vec3 result = iris_main(ramp_map,base,matcap,n,camera_axis,normalize(iris_projected),
            main_color*main_energy,main_color,environment_color,environment_direction,environment_curve,
            environment_strength,character_exposure,shadow_strength,ambient_exposure,main_screen.x,
            iris_tint,outside_tint,outside,matcap_tint,alternate_value,alternate_saturation,matcap_strength,
            surface,diffuse,alternate);
	for (int i=0;i<min(local_light_count,16);i++) {
		vec3 delta = local_positions[i].xyz-iris_world;
		float d2 = max(dot(delta,delta),0.000001);
		vec3 l = delta*inversesqrt(d2);
		int mode = int(local_colors[i].w);
		vec4 a = local_attenuation[i];
		float power = mode==4?max(2.0*local_parameters[i].y,0.1):a.x;
		float attenuation = character_attenuation(d2,local_positions[i].w,power);
		if (a.z>0.0) {
			attenuation *= pow(character_sat((dot(l,-local_directions[i])-a.y)*a.z),2.0);
		}
		if (attenuation<=0.0001) { continue; }
		if (mode==4) {
			result = mix(result,local_colors[i].rgb,attenuation*local_parameters[i].x*
					mix(1.0,smoothstep(-0.5,0.5,dot(geometric,l)),local_parameters[i].w));
			continue;
		}
		float shadow = a.w;
		// Apply external visibility once to the complete local contribution,
		// including the artistic shadow-side floor. Keep manual replay unchanged.
		float engine_visibility = 1.0;
#ifdef CHARACTER_ENGINE_SHADOWS
		if (mode!=0 && engine_local_shadows_enabled) {
			engine_visibility = custom_forward_local_shadow(uvec2(local_shadow_id_low[i],local_shadow_id_high[i]),
					local_shadow_is_spot[i],(VIEW_MATRIX*vec4(iris_world,1.0)).xyz,
					normalize(mat3(VIEW_MATRIX)*geometric));
		} else
#endif
		if (mode!=0 && shadow_atlas_enabled && local_shadow_enabled[i]) {
			shadow *= face_shadow_atlas(shadow_atlas,local_shadow_matrices[i],local_shadow_rects[i],
					local_shadow_bias[i],iris_world,geometric,local_positions[i].xyz);
		} else if (mode!=0) {
			vec3 radial = normalize(vec3(iris_world.x-radial_origin.x,0.0001,iris_world.z-radial_origin.z));
			shadow *= character_sat(dot(radial,l)+1.0);
		}
        result += engine_visibility*iris_local(local_colors[i].rgb,attenuation,dot(n,l),mode,
                local_parameters[i],shadow,main_screen.x,surface,diffuse,alternate);
	}
	ALBEDO = base.rgb;
	EMISSION = result;
}
