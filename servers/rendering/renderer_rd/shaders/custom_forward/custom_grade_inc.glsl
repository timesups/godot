// Frame 37917 E986: sharpening, bloom compression, vignette, LogC strip LUT.
// The LUT stores linear RGB. Apply the output transfer function exactly once.
layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(set = 0, binding = 1) uniform sampler2D bloom_color;
layout(set = 0, binding = 2) uniform sampler2D color_lut;
layout(push_constant, std430) uniform Params {
	vec4 controls; // Exposure, bloom intensity, sharpness, input normalization.
	vec4 vignette; // Intensity, roundness power, falloff power, enabled.
	vec4 vignette_color;
}
params;

vec3 grade(vec2 uv) {
	vec2 texel = 1.0 / vec2(textureSize(source_color, 0));
	vec3 c = textureLod(source_color, uv, 0.0).rgb * params.controls.w;
	vec3 n = textureLod(source_color, uv + vec2(0, texel.y), 0.0).rgb * params.controls.w;
	vec3 s = textureLod(source_color, uv - vec2(0, texel.y), 0.0).rgb * params.controls.w;
	vec3 w = textureLod(source_color, uv - vec2(texel.x, 0), 0.0).rgb * params.controls.w;
	vec3 e = textureLod(source_color, uv + vec2(texel.x, 0), 0.0).rgb * params.controls.w;
	vec3 luma = vec3(0.5, 1.0, 0.5);
	float lc = dot(c, luma), ln = dot(n, luma), ls = dot(s, luma), lw = dot(w, luma), le = dot(e, luma);
	float contrast = max(max(lc, ln), max(ls, max(lw, le))) - min(min(lc, ln), min(ls, min(lw, le)));
	float noise = clamp(abs(0.25 * (ln + ls + lw + le) - lc) / max(contrast, 1e-6), 0.0, 1.0);
	vec3 lo = min(min(n, s), min(w, e)), hi = max(max(n, s), max(w, e));
	vec3 denominator = 4.0 * lo - 4.0;
	denominator = mix(denominator, vec3(-1e-6), lessThan(abs(denominator), vec3(1e-6)));
	vec3 hit = max(-lo * 0.25 / max(hi, vec3(1e-6)), (1.0 - hi) / denominator);
	float sharp = clamp(max(hit.r, max(hit.g, hit.b)), -0.1875, 0.0) * params.controls.z * (1.0 - 0.5 * noise);
	c = (c + sharp * (n + s + w + e)) / (1.0 + 4.0 * sharp) * params.controls.x;
	vec3 bloom = textureLod(bloom_color, uv, 0.0).rgb;
	bloom = mix(bloom, 1.4938 * pow(max(bloom, vec3(0)), vec3(0.33)) - 0.7, greaterThan(bloom, vec3(0.3)));
	c += bloom * params.controls.y * 0.9999998807907104;
	vec2 d = abs(uv - 0.5) * params.vignette.x;
	// Captured roundness/aspect switches are zero: no aspect correction.
	d = pow(clamp(d, 0.0, 1.0), vec2(params.vignette.y));
	float v = pow(clamp(1.0 - dot(d, d), 0.0, 1.0), params.vignette.z);
	c *= mix(vec3(1), mix(params.vignette_color.rgb, vec3(1), v), params.vignette.w);
	vec3 log_color = clamp(0.244161 * (log2(max(5.555556 * c + 0.047996, vec3(1e-10))) * 0.30102999566) + 0.386036, 0.0, 1.0);
	float size = float(textureSize(color_lut, 0).y);
	vec3 p = log_color * (size - 1.0);
	float slice = floor(p.z);
	vec2 lut_uv = (p.xy + 0.5) / vec2(size * size, size);
	lut_uv.x += slice / size;
	vec3 a = textureLod(color_lut, lut_uv, 0.0).rgb;
	vec3 b = textureLod(color_lut, lut_uv + vec2(1.0 / size, 0), 0.0).rgb;
	return mix(a, b, p.z - slice);
}

vec3 encode_output(vec3 c, vec2 uv) {
	c = mix(1.055 * pow(abs(c), vec3(1.0 / 2.4)) - 0.055, c * 12.92, lessThanEqual(c, vec3(0.0031308)));
	float seed = dot(uv * vec2(textureSize(source_color, 0)), vec2(171, 231));
	return c + (fract(seed * vec3(0.009677419, 0.014084507, 0.010309278)) - 0.5) * (0.35 / 255.0);
}
