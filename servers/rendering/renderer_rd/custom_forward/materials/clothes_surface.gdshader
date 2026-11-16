shader_type spatial;
render_mode custom_character, cull_disabled;

// Surface inspection only. This is not the final E694 lighting material.
// 0=base, 1=world normal, 2=metallic/AO/roughness, 3=F0, 4=diffuse.
uniform int surface_view : hint_range(0, 4) = 0;
uniform sampler2D base_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_map : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D parameters_map : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float mip_bias = -1.0;
varying vec3 surface_normal;
varying vec4 surface_tangent;

#include "clothes_surface.gdshaderinc"

void vertex() {
	surface_normal = MODEL_NORMAL_MATRIX * NORMAL;
	vec3 t = (MODEL_MATRIX * vec4(TANGENT, 0.0)).xyz;
	vec3 b = (MODEL_MATRIX * vec4(BINORMAL, 0.0)).xyz;
	surface_tangent = vec4(t, dot(cross(surface_normal, t), b) >= 0.0 ? 1.0 : -1.0);
}

void fragment() {
	vec3 base = texture(base_map, UV, mip_bias).rgb;
	vec4 parameters = texture(parameters_map, UV, mip_bias);
	vec3 tn = clothes_tangent_normal(texture(normal_map, UV, mip_bias), 1.0);
	vec3 n = clothes_world_normal(surface_normal, surface_tangent, tn, FRONT_FACING, 0.0);
	ALBEDO = base;
	EMISSION = base;
	if (surface_view == 1) {
		EMISSION = n * 0.5 + 0.5;
	} else if (surface_view == 2) {
		EMISSION = vec3(parameters.r, parameters.b, clothes_roughness(parameters));
	} else if (surface_view == 3) {
		EMISSION = clothes_f0(base, parameters);
	} else if (surface_view == 4) {
		EMISSION = clothes_diffuse(base, parameters.r);
	}
}
