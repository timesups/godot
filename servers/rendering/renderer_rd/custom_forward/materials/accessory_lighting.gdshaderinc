// E684 dry accessory specialization: no specular lookup or emission.
// Reuses character_lighting, clothes_surface and clothes_lighting BRDF/local helpers.
vec3 accessory_main(sampler2D ramp_map, samplerCube reflection_map,
		vec3 base, vec4 parameters, vec3 n, vec3 view, vec3 camera_forward,
		vec3 main_direction, vec3 main_color, vec3 environment_color,
		vec3 environment_direction, vec3 environment_curve, float environment_strength,
		float exposure, float shadow_strength, float ambient_exposure, vec2 screen,
		float analytic_strength, float reflection_strength,
		out vec3 surface, out vec3 specular_color, out vec3 analytic, out vec3 reflection) {
	vec3 diffuse = clothes_diffuse(base, parameters.r);
	vec3 alternate = diffuse * 0.5;
	float roughness = clothes_roughness(parameters);
	float alpha = max(roughness * roughness, 0.0078125);
	float nv = character_sat(dot(n, view));
	float shadow = screen.r;
	float ao = screen.g;
	vec4 ramp = textureLod(ramp_map,vec2(0.5 + 0.5 * clamp(dot(n,main_direction),-1.0,1.0),0.5),0.0);
	float view_ramp = textureLod(ramp_map,vec2(0.5 + 0.5 * dot(n,camera_forward),0.5),0.0).a;
	float a = min(min(ao,parameters.b),ramp.a);
	float b = view_ramp * parameters.b * ao;
	vec3 k = alternate * shadow_strength;
	vec3 dark = mix(vec3(character_luminance(k * 0.65)),k * 0.65,1.2);
	dark = mix(dark,k,character_sat(b + ramp.a));
	vec3 lit_surface = mix(dark,diffuse,a);
	float spread = max(ramp.r,max(ramp.g,ramp.b)) - min(ramp.r,min(ramp.g,ramp.b));
	vec3 tinted = lit_surface * (1.0 - spread + ramp.rgb * spread);
	tinted *= clamp(character_luminance(lit_surface)/max(character_luminance(tinted),0.001),0.0,1.5);
	vec3 saturated = mix(vec3(character_luminance(diffuse)),diffuse,1.2);
	surface = mix(mix(k,saturated,b),tinted,shadow);
	float h = character_sat(dot(n,environment_direction)+environment_curve.x)*environment_curve.y+environment_curve.z;
	vec3 environment = h * mix(environment_color,vec3(1.0),a);
	vec3 lit_irradiance = (mix(vec3(character_luminance(main_color)),main_color,a) +
			environment * clamp(environment_strength,0.0,1.5)) * exposure;
	vec3 unlit_irradiance = environment * min(mix(0.65,1.0,environment_strength),1.5) * ambient_exposure;
	vec3 irradiance = mix(unlit_irradiance,lit_irradiance,shadow);
	float weight = mix(b,a,shadow);
	float specular_weight = mix(shadow_strength,1.0,weight);
	vec3 specular_irradiance = irradiance * (0.5 + 0.5 * weight) * specular_weight;
	vec3 vertical = normalize(vec3(camera_forward.x,mix(0.5,main_direction.y,shadow),camera_forward.z));
	vec3 half_vector = normalize(main_direction * shadow + vertical * 2.0 + view * (2.0 + shadow));
	float nh = dot(n,half_vector);
	vec3 f0 = clothes_f0(base,parameters);
	specular_color = f0;
	analytic = specular_color * clothes_specular_lobe(nh,nv,alpha) * specular_irradiance * analytic_strength;
	vec3 color = irradiance * surface + analytic;
	float y = character_luminance(color);
	color = mix(vec3(y),color,1.0+pow(clamp(y-0.5,0.0,0.5),2.0));
	float lod = 5.0 + 1.2 * log2(max(roughness,0.001));
	// Capture sampler uses nearest mip selection, independently of project defaults.
	vec3 cube = textureLod(reflection_map,reflect(-view,n),floor(lod+0.5)).rgb;
	reflection = cube * clothes_environment_brdf(f0,roughness,nv) *
			(clamp(environment_strength,0.5,1.5)*ambient_exposure*specular_weight)*environment_color*reflection_strength;
	return color + reflection;
}
