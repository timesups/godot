// E704 dry opaque hair specialization. Requires character_lighting.gdshaderinc.
// Primary RG and secondary BA channels encode different tangent-space normals.
vec3 hair_decode_normal(vec2 sample_xy) {
	vec2 xy = sample_xy * 2.0 - 1.0;
	return vec3(xy,sqrt(1.0-clamp(dot(xy,xy),0.0,1.0)));
}

vec3 hair_safe_normalize(vec3 v) {
	return v * inversesqrt(max(dot(v,v),0.0001));
}

vec3 hair_diffuse(sampler2D ramp_map, vec3 base, vec3 graded, vec4 parameters,
		vec3 n, vec3 camera_forward, vec3 main_direction, vec3 main_color,
		vec3 environment_color, vec3 environment_direction, vec3 environment_curve,
		float environment_strength, float exposure, float shadow_strength,
		float ambient_exposure, vec2 screen, out vec3 surface, out vec3 specular_irradiance) {
	vec3 diffuse = base * 0.96;
	vec3 alternate = graded * 0.96;
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
	specular_irradiance = irradiance * (0.5 + 0.5 * weight) * specular_weight;
	return irradiance * surface;
}

// spec_shape=(primary shift, secondary shift, intensity, view exponent);
// strand_shape=(secondary width, flow tilt, stripe shift, stripe width).
vec3 hair_primary(sampler2D specular_map, vec3 axis, vec3 half_vector, float view_weight,
		float mask, float intensity, out float peak) {
	float d = dot(axis,half_vector);
	float lobe = clamp(pow(max(sqrt(max(1.0-d*d,0.0)),0.0001),200.0)*mask,0.0,1.0);
	vec3 stamp = textureLod(specular_map,vec2(lobe,(d>0.0?1.0:0.0)*view_weight*view_weight),0.0).rgb;
	vec3 shaped = lobe * stamp * view_weight;
	peak = max(shaped.r,max(shaped.g,shaped.b));
	return shaped * (0.04*mask) * intensity * 5.0;
}

void hair_frame(vec3 secondary_normal, vec4 tangent, mat3 world_to_object,
		vec3 view, float tangent_blend, vec4 spec_shape, vec4 strand_shape,
		out vec3 strand, out vec3 primary_axis, out float view_weight) {
	vec3 flow = normalize(vec3(strand_shape.y,1.0,0.0)*world_to_object);
	vec3 t = mix(cross(secondary_normal,flow),tangent.xyz,tangent_blend);
	strand = cross(secondary_normal,t)*mix(1.0,tangent.w,tangent_blend);
	primary_axis = normalize(strand+secondary_normal*(spec_shape.x*2.0-1.0));
	vec3 local_n = world_to_object*secondary_normal;
	vec3 local_v = world_to_object*view;
	vec2 nxz = local_n.xz/max(length(local_n.xz),0.000001);
	vec2 vxz = local_v.xz/max(length(local_v.xz),0.000001);
	view_weight = pow(character_sat(dot(nxz,vxz)),spec_shape.w);
}

vec3 hair_main_specular(sampler2D specular_map, vec3 secondary_normal,
		vec3 strand, vec3 primary_axis, float view_weight, mat3 world_to_object,
		vec3 view, vec3 main_direction, float main_shadow, vec4 parameters,
		float stripe_noise, vec4 spec_shape, vec4 strand_shape, vec3 secondary_tint,
		vec3 specular_irradiance, float specular_strength, out float diffuse_multiplier) {
	vec3 local_view = world_to_object*view;
	vec3 directional = vec3(local_view.x,mix(0.5,main_direction.y,main_shadow),local_view.z)*world_to_object;
	vec3 light = normalize(main_direction*main_shadow+directional*2.0);
	vec3 h = hair_safe_normalize(light+view);
	float peak;
	vec3 first = hair_primary(specular_map,primary_axis,h,view_weight,parameters.g,spec_shape.z,peak);
	vec3 axis2 = normalize(strand+secondary_normal*(spec_shape.y*2.0-1.0));
	float d2 = dot(axis2,h);
	float power2 = float(int(200.0*max(1.0-strand_shape.x,0.0)));
	vec3 second = pow(max(sqrt(max(1.0-d2*d2,0.0)),0.0001),power2)*view_weight*secondary_tint*parameters.a;
	vec3 stripe_axis = normalize(strand+secondary_normal*(strand_shape.z*2.0-1.0));
	float ds = dot(stripe_axis,h);
	float stripe_power = float(int(200.0*max(1.0-strand_shape.w,0.0)));
	float stripe = clamp(pow(max(sqrt(max(1.0-ds*ds,0.0)),0.0001),stripe_power),0.0,1.0);
	float coverage = mix(0.75,1.0,1.0-stripe_noise); // Captured stripe amount=0.25, noise selection=1.
	coverage = mix(coverage,1.0,peak);
	diffuse_multiplier = mix(1.0,mix(1.0,coverage,stripe),parameters.g);
	return (first+mix(second,vec3(0.0),peak))*specular_irradiance*specular_strength;
}

vec3 hair_finish(vec3 diffuse, vec3 specular, float diffuse_multiplier) {
	vec3 color = diffuse*diffuse_multiplier;
	float saturation = mix(1.3,1.0,diffuse_multiplier);
	color = mix(vec3(character_luminance(color)),color,saturation)+specular;
	float y = character_luminance(color);
	return mix(vec3(y),color,1.0+pow(clamp(y-0.5,0.0,0.5),2.0));
}

vec3 hair_local(sampler2D specular_map, vec3 color, float attenuation, vec3 l,
		vec3 n, vec3 view, vec3 camera_forward, int mode, vec4 parameters,
		float shadow, float main_shadow, float rim_visibility, vec3 surface,
		vec3 diffuse, vec3 alternate, vec3 primary_axis, float view_weight,
		float specular_mask, float intensity, float specular_strength) {
	float ndl = dot(n,l);
	float weight = character_sat(ndl);
	vec3 low = surface;
	vec3 high = surface;
	if (mode==0) {
		float compression = 1.0/max(1.0,max(color.r,max(color.g,color.b))*attenuation*mix(0.5,0.75,main_shadow));
		color *= mix(1.0,compression,parameters.y)*mix(parameters.x*0.25,1.0,character_sat(ndl+0.5));
	} else if (mode==1) {
		weight = character_sat(ndl+parameters.x)*shadow;
		low = alternate*parameters.y;
		high = diffuse;
	} else if (mode==3) {
		vec3 projected = cross(camera_forward,cross(camera_forward,l));
		if (dot(projected,projected)<1e-12) { return vec3(0.0); }
		weight = character_sat(dot(n,-normalize(projected)));
		return color*attenuation*rim_visibility*shadow*mix(vec3(0.5),diffuse,parameters.y)*weight;
	} else { return vec3(0.0); }
	float peak;
	vec3 specular = hair_primary(specular_map,primary_axis,hair_safe_normalize(l+view),
			view_weight,specular_mask,intensity,peak)*specular_strength;
	return color*attenuation*(mix(low,high,weight)+specular*weight);
}
