// E694 dry surface decode. Lighting, weather and reflection probes are separate.
// The normal texture is linear; BC5 returns alpha=1. Do not apply normal-map
// importer swizzles or flip green. Source uses alpha*red and green.
vec3 clothes_tangent_normal(vec4 packed_normal, float strength) {
	vec2 xy = vec2(packed_normal.a * packed_normal.r, packed_normal.g) * 2.0 - 1.0;
	float z = sqrt(1.0 - clamp(dot(xy, xy), 0.0, 1.0));
	return vec3(xy * strength, z);
}

vec3 clothes_world_normal(vec3 n, vec4 tangent, vec3 tangent_normal, bool front_facing, float backface_normal) {
	vec3 bitangent = cross(n, tangent.xyz) * tangent.w;
	return normalize(mat3(tangent.xyz, bitangent, n) * tangent_normal) * (front_facing ? 1.0 : 2.0 * backface_normal - 1.0);
}

vec3 clothes_diffuse(vec3 base, float metallic) {
	return base * (0.96 - metallic * 0.96);
}

vec3 clothes_f0(vec3 base, vec4 parameters) {
	return mix(vec3(0.04 * parameters.g), base, vec3(parameters.r));
}

float clothes_roughness(vec4 parameters) {
	return 1.0 - parameters.a;
}

vec2 clothes_octahedral_normal(vec3 normal) {
	vec3 n = normalize(normal);
	vec2 oct = n.xz / (abs(n.x) + abs(n.y) + abs(n.z));
	if (n.y <= 0.0) {
		oct = (vec2(1.0) - abs(oct.yx)) * vec2(oct.x >= 0.0 ? 1.0 : -1.0, oct.y >= 0.0 ? 1.0 : -1.0);
	}
	return oct * 0.5 + 0.5;
}
