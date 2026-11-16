// E694 dry specialization. Requires character_lighting and clothes_surface.
// Wetness, snow, probe volumes and fog are not part of these material functions.
float clothes_distribution(float nh, float alpha) {
	float a2 = alpha * alpha;
	float d = (nh * a2 - nh) * nh + 1.0;
	float d2 = d * d;
	return a2 != d2 ? a2 / d2 : 1.0;
}

float clothes_specular_lobe(float nh, float nv, float alpha) {
	float distribution = clothes_distribution(nh, alpha);
	float visibility = 0.5 / (2.0 * nv + alpha * ((1.0 + nv) - nv) + 0.0001);
	return clamp(distribution * visibility - 0.0001, 0.0, 20.0);
}

vec3 clothes_environment_brdf(vec3 f0, float roughness, float nv) {
	float r2 = roughness * roughness;
	float nv2 = nv * nv;
	float nv3 = nv2 * nv;
	vec2 v2 = vec2(1.0, nv);
	vec2 r = vec2(1.0, r2);
	vec3 r3 = vec3(1.0, r2, r2 * r2 * r2);
	float scale = dot(mat2(vec2(0.0365463011,9.0632),vec2(3.32707,-9.04756)) * v2, r) /
			dot(mat3(vec3(1.0,9.04401,5.56589),vec3(3.59685,-16.3174,19.7886),vec3(-1.36772,9.22949,-20.2123)) * vec3(1.0,nv2,nv3), r3);
	float bias = dot(mat2(vec2(0.99044,1.29678),vec2(-1.28514,-0.755907)) * v2, r) /
			dot(mat3(vec3(1.0,20.3225,121.563),vec3(2.92338,-27.0302,626.130),vec3(59.4188,222.592,316.627)) * vec3(1.0,nv,nv3), r3);
	vec3 single = f0 * scale + vec3(bias);
	return single + (f0 * ((1.0 - (scale + bias)) / (scale + bias))) * single;
}

vec3 clothes_main(sampler2D ramp_map, sampler2D specular_map, samplerCube reflection_map,
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
	float distribution = clothes_distribution(nh,alpha);
	float lookup_x = distribution / min(1.0/(alpha*alpha+0.0001),65504.0);
	vec3 lookup = textureLod(specular_map,vec2(lookup_x,roughness*(1.0-parameters.r)),0.0).rgb;
	vec3 f0 = clothes_f0(base,parameters);
	specular_color = f0 * lookup;
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

vec3 clothes_local(vec3 color, float attenuation, vec3 light_direction, vec3 n, vec3 view,
		vec3 camera_forward, int mode, vec4 parameters, float shadow, float main_shadow,
		vec3 surface, vec3 diffuse, vec3 alternate, vec3 specular_color, float roughness, float specular_strength) {
	float ndl = dot(n,light_direction);
	float weight = character_sat(ndl);
	vec3 low = surface;
	vec3 high = surface;
	if (mode == 0) {
		float compression = 1.0/max(1.0,max(color.r,max(color.g,color.b))*attenuation*mix(0.5,0.75,main_shadow));
		color *= mix(1.0,compression,parameters.y)*mix(0.25*parameters.x,1.0,character_sat(ndl+0.5));
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
