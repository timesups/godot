// E669 captured dry skin: BC5 normal, LUT alternate color, rim tint and analytic dielectric specular.
// Requires character_lighting, clothes_surface and clothes_lighting for shared BRDF utilities.
vec3 skin_main(sampler2D ramp_map,
		vec4 base_sample, vec3 graded, vec4 parameters, vec3 n, vec3 view, vec3 camera_forward,
		vec3 main_direction, vec3 main_color, vec3 environment_color,
		vec3 environment_direction, vec3 environment_curve, float environment_strength,
		float exposure, float shadow_strength, float ambient_exposure, vec2 screen,
		float analytic_strength, vec3 main_tint, vec3 rim_tint, float rim_strength,
		out vec3 surface, out vec3 specular_color, out vec3 analytic, out vec3 diffuse) {
	float rim = character_sat((1.0-character_sat(character_sat(dot(n,view))*0.85+0.15))*rim_strength);
	vec3 base = base_sample.rgb*mix(vec3(1.0),rim_tint,rim);
	diffuse = clothes_diffuse(base, parameters.r);
	vec3 alternate = clothes_diffuse(graded, parameters.r);
	float roughness = clothes_roughness(parameters);
	float alpha = max(roughness * roughness, 0.0078125);
	float nv = character_sat(dot(n, view));
	float shadow = screen.r;
	float ao = screen.g;
	vec4 ramp = textureLod(ramp_map,vec2(0.5 + 0.5 * clamp(dot(n,main_direction),-1.0,1.0),0.5),0.0);

	float a = min(min(ao,base_sample.a),ramp.a);
	float b = base_sample.a * ao;
	vec3 k = alternate * shadow_strength;
	vec3 dark = mix(vec3(character_luminance(k * 0.65)),k * 0.65,1.2);
	dark = mix(dark,k,character_sat(b + ramp.a));
	vec3 lit_surface = mix(dark,diffuse,a);
	float spread = max(ramp.r,max(ramp.g,ramp.b)) - min(ramp.r,min(ramp.g,ramp.b));
	vec3 tinted = lit_surface * (1.0 - spread + ramp.rgb * spread);
	tinted *= clamp(character_luminance(lit_surface)/max(character_luminance(tinted),0.001),0.0,1.5);
	vec3 saturated = mix(vec3(character_luminance(diffuse)),diffuse,1.2);
	surface = mix(mix(k,saturated,b),tinted,shadow);
	float h = character_sat(dot(normalize(vec3(n.x,0.0001,n.z)),environment_direction)+environment_curve.x)*environment_curve.y+environment_curve.z;
	vec3 environment = h * mix(environment_color,vec3(1.0),a);
	vec3 lit_irradiance = (mix(vec3(character_luminance(main_color)),main_color,a) +
			environment * clamp(environment_strength,0.0,1.5) * main_tint) * exposure;
	vec3 unlit_irradiance = environment * min(mix(0.65,1.0,environment_strength),1.5) * ambient_exposure;
	vec3 irradiance = mix(unlit_irradiance,lit_irradiance,shadow);
	float weight = mix(b,a,shadow);
	float specular_weight = mix(shadow_strength,1.0,weight);
	vec3 specular_irradiance = irradiance * (0.5 + 0.5 * weight) * specular_weight;
	vec3 vertical = normalize(vec3(camera_forward.x,mix(0.5,main_direction.y,shadow),camera_forward.z));
	vec3 half_vector = normalize(main_direction * shadow + vertical * 2.0 + view * (2.0 + shadow));
	float nh = dot(n,half_vector);
	specular_color = clothes_f0(base,parameters);
	analytic = specular_color * clothes_specular_lobe(nh,nv,alpha) * specular_irradiance * analytic_strength;
	vec3 color = irradiance * surface + analytic;
	float y = character_luminance(color);
	color = mix(vec3(y),color,1.0+pow(clamp(y-0.5,0.0,0.5),2.0));
	return color;
}

vec3 skin_local(vec3 color, float attenuation, vec3 light_direction, vec3 n, vec3 view,
		vec3 camera_forward, int mode, vec4 parameters, float shadow, float main_shadow,
		vec3 surface, vec3 diffuse, vec3 alternate, vec3 specular_color, float roughness, float specular_strength) {
	float ndl = dot(n,light_direction);
	float weight = character_sat(ndl);
	vec3 low = surface;
	vec3 high = surface;
	if (mode == 0) {
		float compression = 1.0/max(1.0,max(color.r,max(color.g,color.b))*attenuation*mix(0.5,0.75,main_shadow));
		color *= mix(1.0,compression,parameters.y)*mix(0.5*parameters.x,1.0,character_sat(ndl+0.5));
	} else if (mode == 1) {
		weight = character_sat(ndl+parameters.x)*shadow;
		low = alternate*parameters.y;
		high = diffuse;
	} else if (mode == 3) {
		vec3 axis = cross(camera_forward,cross(camera_forward,light_direction));
		if (dot(axis,axis) < 1e-12) { return vec3(0.0); }
		weight = character_sat(dot(n,-normalize(axis)));
		float edge = 1.0-abs(dot(view,n));
		attenuation *= smoothstep(mix(0.8,0.2,parameters.x),mix(0.9,0.5,parameters.x),edge)*shadow;
		return color*attenuation*mix(vec3(0.5),diffuse,parameters.y)*weight;
	} else {
		return vec3(0.0);
	}
	float alpha = max(roughness*roughness,0.0078125);
	vec3 half_vector = normalize(light_direction+view);
	vec3 specular = specular_color * clothes_specular_lobe(dot(n,half_vector),character_sat(dot(n,view)),alpha)*specular_strength;
	return color*attenuation*(mix(low,high,weight)+specular*weight);
}
