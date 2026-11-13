#[compute]
#version 450
#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(set = 0, binding = 1) uniform sampler2D high_color;
layout(r11f_g11f_b10f, set = 0, binding = 2) uniform restrict writeonly image2D destination;
layout(push_constant, std430) uniform Params {
	vec4 size; // Destination dimensions and reciprocal dimensions.
	vec4 threshold;
	vec4 controls; // Exposure, scatter, input luminance normalization, unused.
}
params;

// Reconstructed from frame 37917, E902. The repeated (-1, 1) tap is
// intentional: it is present in the captured shader's constant array.
const vec3 taps[13] = vec3[](vec3(0, 0, 4), vec3(-2, -2, 1), vec3(2, -2, 1), vec3(2, 2, 1), vec3(-2, 2, 1), vec3(-2, 0, 2), vec3(2, 0, 2), vec3(0, 2, 2), vec3(0, -2, 2), vec3(-1, 1, 4), vec3(1, 1, 4), vec3(-1, -1, 4), vec3(-1, 1, 4));

#ifdef MODE_DOWNSAMPLE
shared vec3 cache[16 * 16];
shared vec3 horizontal[8 * 16];
vec3 half_round(vec3 v) {
	return vec3(unpackHalf2x16(packHalf2x16(v.xy)), unpackHalf2x16(packHalf2x16(vec2(v.z, 0))).x);
}
// E906 uses a separable 9-tap binomial kernel and half-precision sample cache.
const float weights[9] = float[](1.0 / 256.0, 8.0 / 256.0, 28.0 / 256.0, 56.0 / 256.0, 70.0 / 256.0, 56.0 / 256.0, 28.0 / 256.0, 8.0 / 256.0, 1.0 / 256.0);
#endif

vec3 bicubic(vec2 uv) {
	vec2 low_size = vec2(textureSize(source_color, 0));
	vec2 p = uv * low_size + 0.5;
	vec2 f = fract(p);
	p = floor(p);
	vec2 w0 = (1.0 - f) * (1.0 - f) * (1.0 - f) / 6.0;
	vec2 w1 = 2.0 / 3.0 + f * f * (0.5 * f - 1.0);
	vec2 w2 = 1.0 / 6.0 + f * (0.5 + f * (0.5 - 0.5 * f));
	vec2 w3 = 1.0 - w0 - w1 - w2;
	vec2 g0 = w0 + w1;
	vec2 g1 = w2 + w3;
	vec2 a = (p - 1.5 + w1 / g0) / low_size;
	vec2 b = (p + 0.5 + w3 / g1) / low_size;
	vec2 upper = 1.0 - params.size.zw;
	return (textureLod(source_color, min(a, upper), 0.0).rgb * g0.x + textureLod(source_color, min(vec2(b.x, a.y), upper), 0.0).rgb * g1.x) * g0.y +
			(textureLod(source_color, min(vec2(a.x, b.y), upper), 0.0).rgb * g0.x + textureLod(source_color, min(b, upper), 0.0).rgb * g1.x) * g1.y;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	vec2 uv = (vec2(pixel) + 0.5) * params.size.zw;
	vec3 result = vec3(0.0);
#ifdef MODE_DOWNSAMPLE
	// All threads must reach the barriers, including the partial edge groups.
	ivec2 local = ivec2(gl_LocalInvocationID.xy);
	ivec2 base = ivec2(gl_WorkGroupID.xy) * 8 + local * 2 - 4;
	for (int y = 0; y < 2; y++) {
		for (int x = 0; x < 2; x++) {
			cache[(local.y * 2 + y) * 16 + local.x * 2 + x] = half_round(textureLod(source_color, (vec2(base + ivec2(x, y)) + 0.5) * params.size.zw, 0.0).rgb);
		}
	}
	barrier();
	for (int y = 0; y < 2; y++) {
		vec3 sum = vec3(0.0);
		for (int i = 0; i < 9; i++) {
			sum += cache[(local.y * 2 + y) * 16 + local.x + i] * weights[i];
		}
		horizontal[(local.y * 2 + y) * 8 + local.x] = sum;
	}
	barrier();
	for (int i = 0; i < 9; i++) {
		result += horizontal[(local.y + i) * 8 + local.x] * weights[i];
	}
#elif defined(MODE_PREFILTER)
	float weight_sum = 0.0;
	for (int i = 0; i < 13; i++) {
		vec3 c = textureLod(source_color, uv + taps[i].xy / vec2(textureSize(source_color, 0)), 0.0).rgb * params.controls.z;
		float brightness = max(c.r, max(c.g, c.b));
		float soft = clamp(brightness - params.threshold.y, 0.0, params.threshold.z);
		c *= max(soft * soft * params.threshold.w, brightness - params.threshold.x) / max(brightness, 0.0001);
		c *= params.controls.x;
		float weight = taps[i].z / (1.0 + dot(c, vec3(0.2126729, 0.7151522, 0.0721750)));
		result += c * weight;
		weight_sum += weight;
	}
	result /= weight_sum;
#else
	result = mix(texelFetch(high_color, clamp(pixel, ivec2(0), ivec2(params.size.xy) - 1), 0).rgb, bicubic(uv), params.controls.y);
#endif
	if (all(lessThan(pixel, ivec2(params.size.xy)))) {
		imageStore(destination, pixel, vec4(result, 1.0));
	}
}
