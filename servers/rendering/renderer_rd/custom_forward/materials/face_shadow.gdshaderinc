// E689 reversed-depth shadow atlas. Nine bilinear comparisons implement the
// captured 5x5 tent filter. Manual comparisons also work in spatial shaders.
float face_shadow_compare(sampler2D atlas, vec2 uv, float depth) {
	ivec2 size = textureSize(atlas, 0);
	vec2 pixel = uv * vec2(size) - 0.5;
	ivec2 base = ivec2(floor(pixel));
	vec2 f = fract(pixel);
	float a = step(texelFetch(atlas, clamp(base, ivec2(0), size - 1), 0).r, depth);
	float b = step(texelFetch(atlas, clamp(base + ivec2(1, 0), ivec2(0), size - 1), 0).r, depth);
	float c = step(texelFetch(atlas, clamp(base + ivec2(0, 1), ivec2(0), size - 1), 0).r, depth);
	float d = step(texelFetch(atlas, clamp(base + ivec2(1, 1), ivec2(0), size - 1), 0).r, depth);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void face_shadow_tent_axis(float delta, out vec3 weights, out vec3 offsets) {
	float square = (delta + 0.5) * (delta + 0.5);
	float low_delta = min(delta, 0.0);
	float high_delta = max(delta, 0.0);
	vec3 low = vec3(0.16 * (0.5 * square - delta), 0.16 * (2.0 - delta - low_delta * low_delta), 0.16 * (delta + 1.0));
	vec3 high = vec3(0.16 * (1.0 - delta), 0.16 * (2.0 + delta - high_delta * high_delta), 0.08 * square);
	weights = low + high;
	offsets = high / weights + vec3(-2.5, -0.5, 1.5);
}

float face_shadow_atlas(sampler2D atlas, mat4 world_to_shadow, vec4 atlas_rect,
		vec4 bias, vec3 world_position, vec3 normal, vec3 light_position) {
	vec3 radial = world_position - light_position;
	radial *= inversesqrt(max(dot(radial, radial), 0.000000000001));
	vec3 biased = world_position - radial * bias.x + normal * (bias.y * 5.0);
	vec4 clip = world_to_shadow * vec4(biased, 1.0);
	if (abs(clip.w) < 0.000000000001) {
		return 1.0;
	}
	vec3 projected = clip.xyz / clip.w;
	if (any(lessThanEqual(projected, vec3(0.0))) || any(greaterThanEqual(projected, vec3(1.0)))) {
		return 1.0;
	}
	vec2 uv = mix(atlas_rect.xy, atlas_rect.zw, projected.xy);
	vec2 size = vec2(textureSize(atlas, 0));
	vec2 center = floor(uv * size + 0.5);
	vec2 delta = uv * size - center;
	vec3 wx;
	vec3 wy;
	vec3 ox;
	vec3 oy;
	face_shadow_tent_axis(delta.x, wx, ox);
	face_shadow_tent_axis(delta.y, wy, oy);
	float result = 0.0;
	for (int y = 0; y < 3; y++) {
		for (int x = 0; x < 3; x++) {
			result += wx[x] * wy[y] * face_shadow_compare(atlas, (center + vec2(ox[x], oy[y])) / size, projected.z);
		}
	}
	return mix(1.0, result, bias.w);
}
