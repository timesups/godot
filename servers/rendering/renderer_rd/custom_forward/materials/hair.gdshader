shader_type spatial;
render_mode custom_character, cull_disabled;
#ifdef HAIR_REALTIME_DEPTH
// Depth prepass keeps opaque hair in the copied depth, although screen reads
// schedule its color pass after opaque geometry. Alpha remains one.
render_mode depth_prepass_alpha, custom_character_shadows;
uniform sampler2D hair_scene_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform bool realtime_rim_enabled = true;
uniform bool engine_local_shadows_enabled = true;
render_mode custom_character_ao;
// Read SSAO only for live, depth-writing characters; combine with manual AO by min.
uniform bool engine_screen_ao_enabled = true;
uniform bool engine_directional_shadows_enabled = true;
uniform uint main_shadow_id_low = 0u;
uniform uint main_shadow_id_high = 0u;
uniform uint local_shadow_id_low[16];
uniform uint local_shadow_id_high[16];
uniform bool local_shadow_is_spot[16];
#endif

#include "character_lighting.gdshaderinc"
#include "hair_lighting.gdshaderinc"
#include "face_shadow.gdshaderinc"

uniform sampler2D base_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_map : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D parameters_map : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_lut : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D noise_map : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ramp_map : filter_linear, repeat_disable;
uniform sampler2D specular_map : filter_linear, repeat_disable;

uniform float mip_bias = -1.0;
uniform vec3 main_direction = vec3(-0.14726211,0.52991927,0.83516431);
uniform vec3 main_color = vec3(1.0);
uniform float main_energy = 1.6243867874;
uniform vec3 environment_color = vec3(0.849077106,0.895768583,1.150923014);
uniform vec3 environment_direction = vec3(0.0,1.0,0.0);
uniform vec3 environment_curve = vec3(0.15,1.5,0.5);
uniform float environment_strength = 0.2877224684;
uniform float character_exposure = 1.05;
uniform float shadow_strength = 0.55;
uniform float ambient_exposure = 0.9;
uniform float specular_strength = 1.0;
uniform vec4 specular_shape = vec4(0.468,0.498,1.5,1.37);
uniform vec4 strand_shape = vec4(0.41,0.02,0.5,0.85);
uniform vec3 secondary_tint = vec3(0.258182913,0.0063984147,0.0);
// Manual/default mode 3 accepts a per-light screen-depth rim mask.
// HAIR_REALTIME_DEPTH computes it from the scene depth prepass instead.
uniform float local_rim_visibility[16];
// Explicit inputs, optionally updated by character_light_binding.gd.
// Live hair applies engine main visibility and combines explicit AO with SSAO separately.
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

varying vec3 hair_world;
varying vec3 hair_normal;
varying vec4 hair_tangent;

void vertex() {
	hair_world = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz;
	hair_normal = MODEL_NORMAL_MATRIX * NORMAL;
	vec3 t = (MODEL_MATRIX * vec4(TANGENT,0.0)).xyz;
	vec3 b = (MODEL_MATRIX * vec4(BINORMAL,0.0)).xyz;
	hair_tangent = vec4(t,dot(cross(hair_normal,t),b)>=0.0?1.0:-1.0);
}

void fragment() {
	vec2 main_screen = screen_shadow_ao;
#ifdef HAIR_REALTIME_DEPTH
	if (engine_screen_ao_enabled) {
		main_screen.y = min(main_screen.y,custom_forward_screen_ao(SCREEN_UV));
	}
	if (engine_directional_shadows_enabled) {
		main_screen.x *= custom_forward_directional_shadow(uvec2(main_shadow_id_low,main_shadow_id_high),
				(VIEW_MATRIX*vec4(hair_world,1.0)).xyz,
				normalize(mat3(VIEW_MATRIX)*hair_normal)*(FRONT_FACING?1.0:-1.0));
	}
#endif
	vec3 base = texture(base_map,UV,mip_bias).rgb;
	vec4 parameters = texture(parameters_map,UV,mip_bias);
	vec4 normals = texture(normal_map,UV,mip_bias);
	mat3 tbn = mat3(hair_tangent.xyz,cross(hair_normal,hair_tangent.xyz)*hair_tangent.w,hair_normal);
	vec3 n = normalize(tbn*hair_decode_normal(normals.rg))*(FRONT_FACING?1.0:-1.0);
	vec3 secondary = normalize(tbn*hair_decode_normal(normals.ba));
	vec3 geometric = normalize(hair_normal)*(FRONT_FACING?1.0:-1.0);
	vec3 view = normalize(CAMERA_POSITION_WORLD-hair_world);
	vec3 camera_axis = INV_VIEW_MATRIX[2].xyz;
	mat3 world_to_object = inverse(mat3(MODEL_MATRIX));
	vec3 graded = character_grade(material_lut,base);
	vec3 surface;
	vec3 specular_irradiance;
	vec3 diffuse_result = hair_diffuse(ramp_map,base,graded,parameters,n,camera_axis,main_direction,
			main_color*main_energy,environment_color,environment_direction,environment_curve,
			environment_strength,character_exposure,shadow_strength,ambient_exposure,main_screen,
			surface,specular_irradiance);
	vec3 strand;
	vec3 primary_axis;
	float view_weight;
	float multiplier;
	hair_frame(secondary,hair_tangent,world_to_object,view,parameters.r,specular_shape,strand_shape,
			strand,primary_axis,view_weight);
	vec3 specular = hair_main_specular(specular_map,secondary,strand,primary_axis,view_weight,
			world_to_object,view,main_direction,main_screen.x,parameters,texture(noise_map,UV*vec2(8.0,1.0)).r,
			specular_shape,strand_shape,secondary_tint,specular_irradiance,specular_strength,multiplier);
	vec3 result = hair_finish(diffuse_result,specular,multiplier);
	vec3 diffuse = base*0.96;
	for (int i=0;i<min(local_light_count,16);i++) {
		vec3 delta = local_positions[i].xyz-hair_world;
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
#ifdef HAIR_REALTIME_DEPTH
		if (mode!=0 && engine_local_shadows_enabled) {
			shadow *= custom_forward_local_shadow(uvec2(local_shadow_id_low[i],local_shadow_id_high[i]),
					local_shadow_is_spot[i],(VIEW_MATRIX*vec4(hair_world,1.0)).xyz,
					normalize(mat3(VIEW_MATRIX)*geometric));
		} else
#endif
		if (mode!=0 && shadow_atlas_enabled && local_shadow_enabled[i]) {
			shadow *= face_shadow_atlas(shadow_atlas,local_shadow_matrices[i],local_shadow_rects[i],
					local_shadow_bias[i],hair_world,geometric,local_positions[i].xyz);
		} else if (mode!=0) {
			vec3 radial = normalize(vec3(hair_world.x-radial_origin.x,0.0001,hair_world.z-radial_origin.z));
			shadow *= character_sat(dot(radial,l)+1.0);
		}
		float rim_visibility = clamp(local_rim_visibility[i],0.0,1.0);
#ifdef HAIR_REALTIME_DEPTH
		if (mode==3 && realtime_rim_enabled) {
			vec3 view_normal = mat3(VIEW_MATRIX)*n;
			vec2 direction = view_normal.xy/max(length(view_normal.xy),0.000001);
			direction.x *= VIEWPORT_SIZE.y/VIEWPORT_SIZE.x;
			// RD projection flips Y: view-space up is decreasing SCREEN_UV.y.
			direction.y = -direction.y;
			vec2 rim_uv = clamp(SCREEN_UV+direction*local_parameters[i].x*0.006,
					1.0/VIEWPORT_SIZE,vec2(1.0)-1.0/VIEWPORT_SIZE);
			float depth = textureLod(hair_scene_depth,rim_uv,0.0).r;
			vec4 position = INV_PROJECTION_MATRIX*vec4(rim_uv*2.0-1.0,depth,1.0);
			float linear_depth = -position.z/position.w;
			float fragment_depth = -(VIEW_MATRIX*vec4(hair_world,1.0)).z;
			rim_visibility = smoothstep(0.1,0.2,linear_depth-fragment_depth);
		}
#endif
		result += hair_local(specular_map,local_colors[i].rgb,attenuation,l,n,view,camera_axis,mode,
				local_parameters[i],shadow,main_screen.x,rim_visibility,surface,
				diffuse,graded*0.96,primary_axis,view_weight,parameters.g,specular_shape.z,
				local_specular_strength[i]*specular_strength);
	}
	ALBEDO = base;
	EMISSION = result;
}
