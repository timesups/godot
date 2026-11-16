shader_type spatial;
render_mode custom_character, cull_disabled;

#ifdef CHARACTER_ENGINE_SHADOWS
render_mode custom_character_shadows;
render_mode custom_character_ao;
// Read SSAO only for live, depth-writing characters; combine with manual AO by min.
uniform bool engine_screen_ao_enabled = true;
uniform bool engine_directional_shadows_enabled = true;
uniform bool engine_local_shadows_enabled = true;
uniform uint main_shadow_id_low = 0u;
uniform uint main_shadow_id_high = 0u;
uniform uint local_shadow_id_low[16];
uniform uint local_shadow_id_high[16];
uniform bool local_shadow_is_spot[16];
#endif


#include "character_lighting.gdshaderinc"
#include "clothes_surface.gdshaderinc"
#include "clothes_lighting.gdshaderinc"
#include "skin_lighting.gdshaderinc"
#include "face_shadow.gdshaderinc"

uniform sampler2D base_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_map : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ramp_map : filter_linear, repeat_disable;
uniform sampler2D material_lut : source_color, filter_linear, repeat_disable;
uniform vec4 skin_parameters = vec4(0.0,0.454,1.0,0.258); // metallic, F0 scale, reserved, smoothness
uniform float normal_strength = 1.0;
uniform vec3 rim_tint = vec3(0.381326109,0.124771841,0.138431624);
uniform float rim_strength = 0.85;
uniform float mip_bias = -1.0;
uniform vec3 main_direction = vec3(-0.14726211,0.52991927,0.83516431);
uniform vec3 main_color = vec3(1.0,0.9136826,0.91132075);
uniform float main_energy = 1.6243867874;
uniform vec3 environment_color = vec3(1.260404348,0.739595652,0.739595652);
uniform vec3 environment_direction = vec3(0.0,1.0,0.0);
uniform vec3 environment_curve = vec3(0.15,1.5,0.5);
uniform float environment_strength = 0.2877224684;
uniform float character_exposure = 1.05;
uniform float shadow_strength = 0.55;
uniform float ambient_exposure = 0.9;
uniform float analytic_strength = 1.0;
// Explicit defaults; CHARACTER_ENGINE_SHADOWS enables the live Light3D bridge.
// Manual AO remains available; live SSAO combines with it without multiplication.
uniform vec2 screen_shadow_ao = vec2(1.0);
uniform int local_light_count : hint_range(0,16) = 0;
uniform vec4 local_positions[16]; // xyz position, w inverse range
uniform vec4 local_colors[16]; // rgb linear color, w mode 0/1/3/4
uniform vec4 local_parameters[16]; // bias, weight, unused, mode-4 normal blend
uniform vec4 local_attenuation[16]; // power, spot cutoff, spot scale, shadow
uniform vec3 local_directions[16]; // spot emission direction
uniform float local_specular_strength[16];
uniform vec3 radial_origin = vec3(0.0);
uniform bool shadow_atlas_enabled = false;
uniform sampler2D shadow_atlas : filter_nearest, repeat_disable;
uniform bool local_shadow_enabled[16];
uniform mat4 local_shadow_matrices[16];
uniform vec4 local_shadow_rects[16];
uniform vec4 local_shadow_bias[16];

varying vec3 skin_world;
varying vec3 skin_normal;
varying vec4 skin_tangent;

void vertex() {
	skin_world = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz;
	skin_normal = MODEL_NORMAL_MATRIX * NORMAL;
	vec3 t = (MODEL_MATRIX * vec4(TANGENT,0.0)).xyz;
	vec3 b = (MODEL_MATRIX * vec4(BINORMAL,0.0)).xyz;
	skin_tangent = vec4(t,dot(cross(skin_normal,t),b)>=0.0?1.0:-1.0);
}

void fragment() {
	vec4 base = texture(base_map,UV,mip_bias);
	vec3 graded = character_grade(material_lut,base.rgb);
	vec4 parameters = skin_parameters;
	vec3 tn = clothes_tangent_normal(texture(normal_map,UV,mip_bias),normal_strength);
	vec3 n = clothes_world_normal(skin_normal,skin_tangent,tn,FRONT_FACING,0.0);
	vec3 geometric = normalize(skin_normal)*(FRONT_FACING?1.0:-1.0);
	vec3 view = normalize(CAMERA_POSITION_WORLD-skin_world);
	vec3 camera_axis = INV_VIEW_MATRIX[2].xyz;
	vec2 main_screen = screen_shadow_ao;
#ifdef CHARACTER_ENGINE_SHADOWS
	if (engine_screen_ao_enabled) {
		main_screen.y = min(main_screen.y,custom_forward_screen_ao(SCREEN_UV));
	}
	if (engine_directional_shadows_enabled) {
		main_screen.x *= custom_forward_directional_shadow(uvec2(main_shadow_id_low,main_shadow_id_high),
				(VIEW_MATRIX*vec4(skin_world,1.0)).xyz,normalize(mat3(VIEW_MATRIX)*geometric));
	}
#endif
	vec3 surface;
	vec3 specular_color;
	vec3 analytic;
	vec3 diffuse;
	vec3 result = skin_main(ramp_map,base,graded,parameters,n,view,camera_axis,
			main_direction,main_color*main_energy,environment_color,environment_direction,environment_curve,
			environment_strength,character_exposure,shadow_strength,ambient_exposure,main_screen,
			analytic_strength,main_color,rim_tint,rim_strength,surface,specular_color,analytic,diffuse);
	for (int i=0;i<min(local_light_count,16);i++) {
		vec3 delta = local_positions[i].xyz-skin_world;
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
					local_shadow_is_spot[i],(VIEW_MATRIX*vec4(skin_world,1.0)).xyz,
					normalize(mat3(VIEW_MATRIX)*geometric));
		} else
#endif
		if (mode!=0 && shadow_atlas_enabled && local_shadow_enabled[i]) {
			shadow *= face_shadow_atlas(shadow_atlas,local_shadow_matrices[i],local_shadow_rects[i],
					local_shadow_bias[i],skin_world,geometric,local_positions[i].xyz);
		} else if (mode!=0) {
			vec3 radial = normalize(vec3(skin_world.x-radial_origin.x,0.0001,skin_world.z-radial_origin.z));
			shadow *= character_sat(dot(radial,l)+1.0);
		}
		result += engine_visibility * skin_local(local_colors[i].rgb,attenuation,l,n,view,camera_axis,mode,
				local_parameters[i],shadow,main_screen.x,surface,diffuse,clothes_diffuse(graded,parameters.r),
				specular_color,clothes_roughness(parameters),local_specular_strength[i]*analytic_strength);
	}
	ALBEDO = base.rgb;
	EMISSION = result;
}
