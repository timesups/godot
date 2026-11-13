shader_type spatial;
render_mode custom_character, cull_disabled;

#include "character_lighting.gdshaderinc"

uniform sampler2D base_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_lut : source_color, filter_linear, repeat_disable;
uniform sampler2D ramp_map : filter_linear, repeat_disable;
uniform vec4 base_tint : source_color = vec4(1.0);
uniform float mip_bias = 0.0;
uniform vec3 main_direction = vec3(-0.14726211, 0.52991927, 0.83516431);
uniform vec3 main_color = vec3(1.6243867874);
uniform float ramp_bias = 0.0;
uniform float shadow_strength = 0.55;
uniform vec3 environment_color = vec3(0.8490771, 0.8957686, 1.150923);
uniform vec3 environment_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 environment_curve = vec3(0.15, 1.5, 0.5);
uniform float environment_strength = 0.28772246837615967;
uniform float character_exposure = 1.0;
// Explicit world-space point lights. Godot scene lights are not automatically mapped.
// position.w = inverse range; color.w = E674 mode (0 or 1).
// parameters = (bias, weight, distance power, unused).
uniform int local_light_count : hint_range(0, 8) = 0;
uniform vec4 local_positions[8];
uniform vec4 local_colors[8];
uniform vec4 local_parameters[8];

varying vec3 character_world;
varying vec3 character_normal;
varying vec3 character_projected;

void vertex() {
	character_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	character_normal = MODEL_NORMAL_MATRIX * NORMAL;
	// Project the light onto the object's horizontal plane, then return to world space.
	vec3 local_direction = inverse(mat3(MODEL_MATRIX)) * main_direction;
	local_direction.y = 0.0;
	if (dot(local_direction, local_direction) < 0.000001) {
		local_direction = vec3(1.0, 0.0, 0.0);
	}
	character_projected = normalize(mat3(MODEL_MATRIX) * local_direction);
}

void fragment() {
	vec3 n = normalize(character_normal);
	vec3 base = texture(base_map, UV, mip_bias).rgb * base_tint.rgb;
	vec3 graded = character_grade(material_lut, base);
	vec4 ramp = textureLod(ramp_map, vec2(0.5 + 0.5 * clamp(dot(n, normalize(character_projected)) + ramp_bias, -1.0, 1.0), 0.5), 0.0);
	vec4 view_ramp = textureLod(ramp_map, vec2(0.5 + 0.5 * dot(n, INV_VIEW_MATRIX[2].xyz), 0.5), 0.0);
	vec3 surface_color = character_surface(base, graded, shadow_strength, ramp, view_ramp);
	vec3 result = character_main(surface_color, n, ramp.a, main_color, environment_color,
			environment_direction, environment_curve, environment_strength, character_exposure);
	for (int i = 0; i < min(local_light_count, 8); i++) {
		vec3 delta = local_positions[i].xyz - character_world;
		float d2 = max(dot(delta, delta), 0.000001);
		vec3 l = delta * inversesqrt(d2);
		float attenuation = character_attenuation(d2, local_positions[i].w, local_parameters[i].z);
		if (attenuation <= 0.0001) { continue; }
		float ndl = dot(n, l);
		int mode = int(local_colors[i].w);
		if (mode == 0) {
			result += character_local_zero(local_colors[i].rgb, attenuation, ndl, local_parameters[i].x, local_parameters[i].y, surface_color);
		} else if (mode == 1) {
			vec3 radial = normalize(vec3(character_world.x - NODE_POSITION_WORLD.x, 0.0001, character_world.z - NODE_POSITION_WORLD.z));
			float shadow = character_sat(dot(radial, l) + 1.0);
			result += character_local_one(local_colors[i].rgb, attenuation, ndl, local_parameters[i].x, local_parameters[i].y, shadow, graded, base);
		}
	}
	ALBEDO = base;
	EMISSION = result;
}
