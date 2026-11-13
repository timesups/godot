// E689 captured specialization. Include character_lighting.gdshaderinc first.
// Wetness, snow, makeup, probe lighting and analytic specular were inactive.
float face_sdf_light(float sdf_average, float light_z) {
	float half_z = light_z * 0.5;
	float threshold = clamp(0.5 - half_z, 0.001, 0.999);
	float response = smoothstep(max(2.0 * threshold - 1.0, 0.0), min(2.0 * threshold, 1.0), sdf_average);
	return mix(-1.0, 1.0, abs(-response - half_z * ceil(half_z)));
}

vec3 face_lighting(vec4 base, vec3 graded, vec4 mask, vec4 sdf, vec4 ramp, vec3 specular_stamp,
		vec3 normal, vec3 view, vec3 radial, float camera_local_z, vec3 local_light,
		mat3 object_basis, float screen_ao, vec3 main_color, vec3 environment_color,
		vec3 environment_direction, vec3 environment_curve, float environment_strength,
		float exposure, float shadow_strength, vec3 rim_tint, vec2 rim_strength,
		out vec3 surface_color, out vec3 light_normal, out vec3 diffuse_base) {
	float mask_weight = mask.r * mix(character_sat(camera_local_z + 0.5), 1.0, mask.g);
	float rim = character_sat((1.0 - character_sat(character_sat(dot(normal, view)) * 0.85 + 0.15)) * mask_weight * mix(rim_strength.y, rim_strength.x, mask.b));
	diffuse_base = base.rgb * mix(vec3(1.0), rim_tint, rim) * 0.96;
	vec3 flat_n = normalize(vec3(normal.x, 0.0001, normal.z));
	vec3 env_n = normalize(mix(radial, flat_n, mask.g));
	float h = character_sat(dot(env_n, environment_direction) + environment_curve.x) * environment_curve.y + environment_curve.z;
	// Reversed-edge smoothstep in SPIR-V, written with defined GLSL semantics.
	float ao_weight = max(mask.g, mask.b * (1.0 - smoothstep(0.25, 0.75, camera_local_z)));
	float ao = mix(1.0, screen_ao, ao_weight);
	float a = min(min(ao, base.a), ramp.a);
	vec3 k = graded * 0.96 * shadow_strength;
	vec3 dark = mix(vec3(character_luminance(k * 0.65)), k * 0.65, 1.2);
	dark = mix(dark, k, character_sat(base.a * mix(1.0, ao, mask.g) + ramp.a));
	vec3 color = mix(dark, diffuse_base, a);
	float spread = max(ramp.r, max(ramp.g, ramp.b)) - min(ramp.r, min(ramp.g, ramp.b));
	vec3 tinted = color * (1.0 - spread + ramp.rgb * spread);
	surface_color = tinted * clamp(character_luminance(color) / max(character_luminance(tinted), 0.001), 0.0, 1.5);
	vec3 environment = h * mix(environment_color, vec3(1.0), a);
	// E689 C12.y=1: the character main-light tint also modulates environment.
	vec3 tint = vec3(1.0, 0.9136826, 0.91132075);
	vec3 irradiance = (mix(vec3(character_luminance(main_color)), main_color, a) + environment * clamp(environment_strength, 0.0, 1.5) * tint) * exposure;
	vec3 result = irradiance * surface_color;
	result += specular_stamp * irradiance * (0.5 + 0.5 * a) * mix(shadow_strength, 1.0, a);
	float y = character_luminance(result);
	result = mix(vec3(y), result, 1.0 + pow(clamp(y - 0.5, 0.0, 0.5), 2.0));
	float side = local_light.x > 0.0 ? 1.0 : 0.0;
	float sdf_x = mix(1.0 - 2.0 * sdf.b, 2.0 * sdf.b - 1.0, side);
	vec3 sdf_normal = normalize(object_basis * normalize(vec3(sdf_x, 0.0001, 1.0 - abs(sdf_x))));
	light_normal = normalize(mix(sdf_normal, normal, mask.g));
	return result;
}

vec3 face_local_zero(vec3 color, float attenuation, vec3 direction, vec3 radial,
		vec3 light_normal, float normal_weight, float bias, float weight, vec3 surface_color) {
	vec3 n = normalize(mix(vec3(radial.x, 0.0001, radial.z), light_normal, normal_weight));
	float compression = 1.0 / max(1.0, max(color.r, max(color.g, color.b)) * attenuation * 0.75);
	return color * mix(1.0, compression, weight) * mix(0.5 * bias, 1.0, character_sat(dot(n, direction) + 0.5)) * attenuation * surface_color;
}

vec3 face_local_one(vec3 color, float attenuation, float ndl, vec4 parameters,
		float shadow, float mask_green, float sdf_alpha, vec3 graded, vec3 diffuse_base) {
	float response = smoothstep(0.0, mix(0.1, 1.0, mask_green), clamp(ndl + parameters.x, -1.0, 1.0) + parameters.z * (1.0 - mask_green)) * shadow;
	response = max(1.0 - smoothstep(-0.2, 0.0, sdf_alpha - parameters.w), response);
	return color * attenuation * mix(graded * 0.96 * parameters.y, diffuse_base, response);
}

vec3 face_local_three(vec3 color, float attenuation, vec3 direction, vec3 view,
		vec3 camera_axis, vec3 light_normal, float camera_local_z, float mask_alpha,
		float bias, float weight, float shadow, vec3 diffuse_base) {
	vec3 projected = -cross(camera_axis, cross(camera_axis, direction));
	float projected_length = dot(projected, projected);
	if (projected_length < 0.000000000001) {
		return vec3(0.0);
	}
	projected *= inversesqrt(projected_length);
	float ndl = character_sat(dot(light_normal, projected));
	float facing = smoothstep(0.9, 1.0, abs(camera_local_z));
	float edge = 1.0 - abs(dot(view, light_normal));
	float rim = smoothstep(mix(0.8, 0.2, bias), mix(0.9, 0.5, bias), edge) * facing;
	float alternate = max(facing, dot(camera_axis, projected) < -0.01 ? 1.0 : 0.0) * mask_alpha;
	rim = mix(rim, alternate, character_sat(bias * 10.0 - 3.0));
	return color * attenuation * rim * shadow * mix(vec3(0.5), diffuse_base, weight) * ndl;
}
