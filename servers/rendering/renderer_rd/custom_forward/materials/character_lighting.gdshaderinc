// Shared by the scene material and the independent captured GPU regression.
// E674 specialization: opaque dielectric, no probe/rim/volume-light branch.
float character_sat(float x) {
	return clamp(x, 0.0, 1.0);
}

float character_luminance(vec3 c) {
	return dot(c, vec3(0.2126729041337967, 0.7151522040367126, 0.07217500358819962));
}

vec3 character_to_srgb(vec3 c) {
	return mix(1.055 * pow(abs(c), vec3(1.0 / 2.4)) - 0.055, 12.92 * c, lessThanEqual(c, vec3(0.0031308)));
}

vec3 character_grade(sampler2D lut_map, vec3 base) {
	vec3 c = clamp(character_to_srgb(base), 0.0, 1.0);
	float z = c.z * 31.0;
	vec2 p = (c.xy * 31.0 + 0.5) / vec2(1024.0, 32.0) + vec2(floor(z) / 32.0, 0.0);
	return mix(textureLod(lut_map, p, 0.0).rgb, textureLod(lut_map, p + vec2(1.0 / 32.0, 0.0), 0.0).rgb, fract(z));
}

vec3 character_surface(vec3 base, vec3 graded, float shadow_strength, vec4 ramp, vec4 view_ramp) {
	vec3 k = graded * 0.96 * shadow_strength;
	vec3 dark = mix(vec3(character_luminance(k * 0.65)), k * 0.65, 1.2);
	dark = mix(dark, k, character_sat(view_ramp.a + ramp.a));
	vec3 color = mix(dark, base * 0.96, min(1.0, ramp.a));
	float spread = max(ramp.r, max(ramp.g, ramp.b)) - min(ramp.r, min(ramp.g, ramp.b));
	vec3 tinted = color * (1.0 - spread + ramp.rgb * spread);
	return tinted * clamp(character_luminance(color) / max(character_luminance(tinted), 0.001), 0.0, 1.5);
}

vec3 character_main(vec3 color, vec3 normal, float ramp_alpha, vec3 main_light, vec3 environment_color,
		vec3 environment_direction, vec3 environment_curve, float environment_strength, float exposure) {
	float a = min(1.0, ramp_alpha);
	vec3 flat_n = normalize(vec3(normal.x, 0.0001, normal.z));
	float h = character_sat(dot(flat_n, environment_direction) + environment_curve.x) * environment_curve.y + environment_curve.z;
	vec3 environment = h * mix(environment_color, vec3(1.0), a);
	vec3 irradiance = (mix(vec3(character_luminance(main_light)), main_light, a) + environment * clamp(environment_strength, 0.0, 1.5)) * exposure;
	vec3 result = irradiance * color;
	float y = character_luminance(result);
	return mix(vec3(y), result, 1.0 + pow(clamp(y - 0.5, 0.0, 0.5), 2.0));
}

float character_attenuation(float distance_squared, float inverse_range, float power) {
	float q = distance_squared * inverse_range * inverse_range;
	return power < 0.0 ? pow(character_sat(1.0 - q * q), 2.0) / (distance_squared + 1.0) : pow(1.0 - character_sat(q), power);
}

vec3 character_local_zero(vec3 light_color, float attenuation, float ndl, float bias, float weight, vec3 surface_color) {
	float compression = 1.0 / max(1.0, max(light_color.r, max(light_color.g, light_color.b)) * attenuation * 0.75);
	vec3 c = light_color * mix(1.0, compression, weight);
	return c * mix(0.25 * bias, 1.0, character_sat(ndl + 0.5)) * attenuation * surface_color;
}

vec3 character_local_one(vec3 light_color, float attenuation, float ndl, float bias, float weight,
		float shadow, vec3 graded, vec3 base) {
	return light_color * attenuation * mix(graded * 0.96 * weight, base * 0.96, character_sat(ndl + bias) * shadow);
}
