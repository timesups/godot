shader_type spatial;
render_mode custom_character, cull_disabled;

#include "character_lighting.gdshaderinc"
#include "face_lighting.gdshaderinc"

uniform sampler2D base_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_lut : source_color, filter_linear, repeat_disable;
uniform sampler2D face_mask : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D face_sdf : filter_linear, repeat_disable;
uniform sampler2D face_specular : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D face_ramp : filter_linear, repeat_disable;
uniform float mip_bias = -1.0;
uniform vec3 main_direction = vec3(-0.14726211, 0.52991927, 0.83516431);
uniform vec3 main_color = vec3(1.0, 0.9136826, 0.91132075);
uniform float main_energy = 1.6243867874;
uniform vec3 environment_color = vec3(0.8490771, 0.8957686, 1.150923);
uniform vec3 environment_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 environment_curve = vec3(0.15, 1.5, 0.5);
uniform float environment_strength = 0.28772246837615967;
uniform float character_exposure = 1.05;
uniform float shadow_strength = 0.55;
uniform vec3 rim_tint = vec3(0.3813261, 0.12477182, 0.13843161);
uniform vec2 rim_strength = vec2(0.85, 1.0);
uniform vec2 specular_view_offset = vec2(0.03, 0.0);
// Scene adapter input; capture screen-space AO is only bound by the replay test.
uniform float face_ao : hint_range(0.0, 1.0) = 1.0;
uniform int local_light_count : hint_range(0, 8) = 0;
// xyz position/world direction; position.w inverse range; color.w mode (0/1/3).
uniform vec4 local_positions[8];
uniform vec4 local_colors[8];
// (bias, weight, mode-1 normal bias, mode-1 SDF threshold).
uniform vec4 local_parameters[8];
// (distance power, spot cos cutoff, spot scale, shadow factor).
// spot scale=0 selects a point light. Defaults require caller initialization.
uniform vec4 local_attenuation[8];
uniform vec3 local_directions[8];

varying vec3 face_world;
varying vec3 face_normal;

void vertex() {
	face_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	face_normal = MODEL_NORMAL_MATRIX * NORMAL;
}

void fragment() {
	vec3 n = normalize(face_normal);
	vec3 view = normalize(CAMERA_POSITION_WORLD - face_world);
	vec3 camera_axis = INV_VIEW_MATRIX[2].xyz;
	mat3 basis = mat3(MODEL_MATRIX);
	mat3 inverse_basis = inverse(basis);
	vec3 local_light = inverse_basis * main_direction;
	local_light = normalize(vec3(local_light.x, 0.0001, local_light.z));
	vec2 local_camera = (inverse_basis * camera_axis).xz;
	float camera_z = local_camera.y / max(length(local_camera), 0.000001);
	vec3 radial = normalize(vec3(face_world.x - NODE_POSITION_WORLD.x, 0.0001, face_world.z - NODE_POSITION_WORLD.z));
	vec4 base = texture(base_map, UV, mip_bias);
	vec4 mask = texture(face_mask, UV, mip_bias);
	vec2 sdf_uv = vec2(local_light.x > 0.0 ? UV.x : 1.0 - UV.x, UV.y);
	vec4 sdf = textureLod(face_sdf, sdf_uv, 0.0);
	float face_ndl = face_sdf_light((sdf.r + sdf.g) * 0.5, local_light.z);
	float ramp_u = 0.5 + 0.5 * mix(face_ndl, clamp(dot(n, main_direction), -1.0, 1.0), mask.g);
	vec4 ramp = textureLod(face_ramp, vec2(ramp_u, 0.5), 0.0);
	vec3 graded = character_grade(material_lut, base.rgb);
	vec3 surface_color;
	vec3 light_normal;
	vec3 diffuse_base;
	vec2 specular_uv = UV + (inverse_basis * view).xy * specular_view_offset;
	vec3 result = face_lighting(base, graded, mask, sdf, ramp, texture(face_specular, specular_uv, mip_bias).rgb,
			n, view, radial, camera_z, local_light, basis, face_ao, main_color * main_energy, environment_color,
			environment_direction, environment_curve, environment_strength, character_exposure,
			shadow_strength, rim_tint, rim_strength, surface_color, light_normal, diffuse_base);
	for (int i = 0; i < min(local_light_count, 8); i++) {
		vec3 delta = local_positions[i].xyz - face_world;
		float d2 = max(dot(delta, delta), 0.000001);
		vec3 l = delta * inversesqrt(d2);
		vec4 attenuation_parameters = local_attenuation[i];
		float attenuation = character_attenuation(d2, local_positions[i].w, attenuation_parameters.x);
		if (attenuation_parameters.z > 0.0) {
			attenuation *= pow(character_sat((dot(l, -local_directions[i]) - attenuation_parameters.y) * attenuation_parameters.z), 2.0);
		}
		if (attenuation <= 0.0001) { continue; }
		int mode = int(local_colors[i].w);
		vec4 p = local_parameters[i];
		float shadow = attenuation_parameters.w;
		if (mode == 0) {
			result += face_local_zero(local_colors[i].rgb, attenuation, l, radial, light_normal, mask.g, p.x, p.y, surface_color);
		} else if (mode == 1) {
			shadow *= character_sat(dot(radial, l) + 1.0);
			result += face_local_one(local_colors[i].rgb, attenuation, dot(light_normal, l), p, shadow, mask.g, sdf.a, graded, diffuse_base);
		} else if (mode == 3) {
			result += face_local_three(local_colors[i].rgb, attenuation, l, view, camera_axis, light_normal, camera_z, mask.a, p.x, p.y, shadow, diffuse_base);
		}
	}
	ALBEDO = base.rgb;
	EMISSION = result;
}
