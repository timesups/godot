// Custom Forward character bridge. Shadow evaluation mirrors the engine local-light path.
float custom_omni_shadow(uint idx, vec3 vertex, hvec3 normal) {
	vec3 light_rel_vec = omni_lights.data[idx].position - vertex;
	float light_length = max(length(light_rel_vec), 0.000001);
	hvec3 light_rel_vec_norm = hvec3(light_rel_vec / light_length);
	float taa_frame_count = scene_data_block.data.taa_frame_count;
	half shadow = half(1.0);
#ifndef SHADOWS_DISABLED
	// Omni light shadow.
	if (omni_lights.data[idx].shadow_opacity > 0.001) {
		// there is a shadowmap
		vec2 texel_size = scene_data_block.data.shadow_atlas_pixel_size;
		vec4 base_uv_rect = omni_lights.data[idx].atlas_rect;
		base_uv_rect.xy += texel_size;
		base_uv_rect.zw -= texel_size * 2.0;

		// Omni lights use direction.xy to store to store the offset between the two paraboloid regions
		vec2 flip_offset = omni_lights.data[idx].direction.xy;

		vec3 local_vert = (omni_lights.data[idx].shadow_matrix * vec4(vertex, 1.0)).xyz;

		float shadow_len = length(local_vert); //need to remember shadow len from here
		vec3 shadow_dir = normalize(local_vert);

		vec3 local_normal = normalize(mat3(omni_lights.data[idx].shadow_matrix) * vec3(normal));
		vec3 normal_bias = local_normal * omni_lights.data[idx].shadow_normal_bias * (1.0 - abs(dot(local_normal, shadow_dir)));

		if (sc_use_light_soft_shadows() && omni_lights.data[idx].soft_shadow_size > 0.0) {
			//soft shadow

			//find blocker

			float blocker_count = 0.0;
			float blocker_average = 0.0;

			mat2 disk_rotation;
			{
				float r = quick_hash(gl_FragCoord.xy + vec2(taa_frame_count * 5.588238)) * 2.0 * M_PI;
				float sr = sin(r);
				float cr = cos(r);
				disk_rotation = mat2(vec2(cr, -sr), vec2(sr, cr));
			}

			vec3 basis_normal = shadow_dir;
			vec3 v0 = abs(basis_normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
			vec3 tangent = normalize(cross(v0, basis_normal));
			vec3 bitangent = normalize(cross(tangent, basis_normal));
			float z_norm = 1.0 - shadow_len * omni_lights.data[idx].inv_radius;

			tangent *= omni_lights.data[idx].soft_shadow_size * omni_lights.data[idx].soft_shadow_scale;
			bitangent *= omni_lights.data[idx].soft_shadow_size * omni_lights.data[idx].soft_shadow_scale;

			SPEC_CONSTANT_LOOP_ANNOTATION
			for (uint i = 0; i < sc_penumbra_shadow_samples(); i++) {
				vec2 disk = disk_rotation * scene_data_block.data.penumbra_shadow_kernel[i].xy;

				vec3 pos = local_vert + tangent * disk.x + bitangent * disk.y;

				pos = normalize(pos);

				vec4 uv_rect = base_uv_rect;

				if (pos.z >= 0.0) {
					uv_rect.xy += flip_offset;
				}

				pos.z = 1.0 + abs(pos.z);
				pos.xy /= pos.z;

				pos.xy = pos.xy * 0.5 + 0.5;
				pos.xy = uv_rect.xy + pos.xy * uv_rect.zw;

				float d = textureLod(sampler2D(shadow_atlas, SAMPLER_LINEAR_CLAMP), pos.xy, 0.0).r;
				if (d > z_norm) {
					blocker_average += d;
					blocker_count += 1.0;
				}
			}

			if (blocker_count > 0.0) {
				//blockers found, do soft shadow
				blocker_average /= blocker_count;
				float penumbra = (-z_norm + blocker_average) / (1.0 - blocker_average);
				tangent *= penumbra;
				bitangent *= penumbra;

				z_norm += omni_lights.data[idx].inv_radius * omni_lights.data[idx].shadow_bias;

				shadow = half(0.0);

				SPEC_CONSTANT_LOOP_ANNOTATION
				for (uint i = 0; i < sc_penumbra_shadow_samples(); i++) {
					vec2 disk = disk_rotation * scene_data_block.data.penumbra_shadow_kernel[i].xy;
					vec3 pos = local_vert + tangent * disk.x + bitangent * disk.y;

					pos = normalize(pos);
					pos = normalize(pos + normal_bias);

					vec4 uv_rect = base_uv_rect;

					if (pos.z >= 0.0) {
						uv_rect.xy += flip_offset;
					}

					pos.z = 1.0 + abs(pos.z);
					pos.xy /= pos.z;

					pos.xy = pos.xy * 0.5 + 0.5;
					pos.xy = uv_rect.xy + pos.xy * uv_rect.zw;
					shadow += half(textureProj(sampler2DShadow(shadow_atlas, shadow_sampler), vec4(pos.xy, z_norm, 1.0)));
				}

				shadow /= half(sc_penumbra_shadow_samples());
				shadow = mix(half(1.0), shadow, half(omni_lights.data[idx].shadow_opacity));

			} else {
				//no blockers found, so no shadow
				shadow = half(1.0);
			}
		} else {
			vec4 uv_rect = base_uv_rect;

			vec3 shadow_sample = normalize(shadow_dir + normal_bias);
			if (shadow_sample.z >= 0.0) {
				uv_rect.xy += flip_offset;
				flip_offset *= -1.0;
			}

			shadow_sample.z = 1.0 + abs(shadow_sample.z);
			vec2 pos = shadow_sample.xy / shadow_sample.z;
			float depth = shadow_len - omni_lights.data[idx].shadow_bias;
			depth *= omni_lights.data[idx].inv_radius;
			depth = 1.0 - depth;
			shadow = mix(half(1.0), sample_omni_pcf_shadow(shadow_atlas, omni_lights.data[idx].soft_shadow_scale / shadow_sample.z, pos, uv_rect, flip_offset, depth, taa_frame_count), half(omni_lights.data[idx].shadow_opacity));
		}
	}
#endif

	return float(shadow);
}

float custom_spot_shadow(uint idx, vec3 vertex, hvec3 normal) {
	vec3 light_rel_vec = spot_lights.data[idx].position - vertex;
	float light_length = max(length(light_rel_vec), 0.000001);
	hvec3 light_rel_vec_norm = hvec3(light_rel_vec / light_length);
	float taa_frame_count = scene_data_block.data.taa_frame_count;
	vec3 spot_dir = spot_lights.data[idx].direction;
	half shadow = half(1.0);
#ifndef SHADOWS_DISABLED
	// Spot light shadow.
	if (spot_lights.data[idx].shadow_opacity > 0.001) {
		vec3 normal_bias = vec3(normal) * light_length * spot_lights.data[idx].shadow_normal_bias * (1.0 - abs(dot(normal, light_rel_vec_norm)));

		//there is a shadowmap
		vec4 v = vec4(vertex + normal_bias, 1.0);

		vec4 splane = (spot_lights.data[idx].shadow_matrix * v);
		splane.z += spot_lights.data[idx].shadow_bias;
		splane /= splane.w;

		if (sc_use_light_soft_shadows() && spot_lights.data[idx].soft_shadow_size > 0.0) {
			//soft shadow

			//find blocker
			float z_norm = dot(spot_dir, -light_rel_vec) * spot_lights.data[idx].inv_radius;

			vec2 shadow_uv = splane.xy * spot_lights.data[idx].atlas_rect.zw + spot_lights.data[idx].atlas_rect.xy;

			float blocker_count = 0.0;
			float blocker_average = 0.0;

			mat2 disk_rotation;
			{
				float r = quick_hash(gl_FragCoord.xy + vec2(taa_frame_count * 5.588238)) * 2.0 * M_PI;
				float sr = sin(r);
				float cr = cos(r);
				disk_rotation = mat2(vec2(cr, -sr), vec2(sr, cr));
			}

			float uv_size = spot_lights.data[idx].soft_shadow_size * z_norm * spot_lights.data[idx].soft_shadow_scale;
			vec2 clamp_max = spot_lights.data[idx].atlas_rect.xy + spot_lights.data[idx].atlas_rect.zw;

			SPEC_CONSTANT_LOOP_ANNOTATION
			for (uint i = 0; i < sc_penumbra_shadow_samples(); i++) {
				vec2 suv = shadow_uv + (disk_rotation * scene_data_block.data.penumbra_shadow_kernel[i].xy) * uv_size;
				suv = clamp(suv, spot_lights.data[idx].atlas_rect.xy, clamp_max);
				float d = textureLod(sampler2D(shadow_atlas, SAMPLER_LINEAR_CLAMP), suv, 0.0).r;
				if (d > splane.z) {
					blocker_average += d;
					blocker_count += 1.0;
				}
			}

			if (blocker_count > 0.0) {
				//blockers found, do soft shadow
				blocker_average /= blocker_count;
				float penumbra = (-z_norm + blocker_average) / (1.0 - blocker_average);
				uv_size *= penumbra;

				shadow = half(0.0);

				SPEC_CONSTANT_LOOP_ANNOTATION
				for (uint i = 0; i < sc_penumbra_shadow_samples(); i++) {
					vec2 suv = shadow_uv + (disk_rotation * scene_data_block.data.penumbra_shadow_kernel[i].xy) * uv_size;
					suv = clamp(suv, spot_lights.data[idx].atlas_rect.xy, clamp_max);
					shadow += half(textureProj(sampler2DShadow(shadow_atlas, shadow_sampler), vec4(suv, splane.z, 1.0)));
				}

				shadow /= half(sc_penumbra_shadow_samples());
				shadow = mix(half(1.0), shadow, half(spot_lights.data[idx].shadow_opacity));

			} else {
				//no blockers found, so no shadow
				shadow = half(1.0);
			}
		} else {
			//hard shadow
			vec3 shadow_uv = vec3(splane.xy * spot_lights.data[idx].atlas_rect.zw + spot_lights.data[idx].atlas_rect.xy, splane.z);
			shadow = mix(half(1.0), sample_pcf_shadow(shadow_atlas, spot_lights.data[idx].soft_shadow_scale * scene_data_block.data.shadow_atlas_pixel_size, shadow_uv, taa_frame_count), half(spot_lights.data[idx].shadow_opacity));
		}
	}
#endif // SHADOWS_DISABLED

	return float(shadow);
}

float custom_forward_local_shadow(uvec2 light_id, bool is_spot, vec3 vertex, vec3 normal) {
	// Only search the current cluster: unused or stale buffer entries cannot match.
	uvec2 cluster_pos = uvec2(gl_FragCoord.xy) >> implementation_data.cluster_shift;
	uint offset = (implementation_data.cluster_width * cluster_pos.y + cluster_pos.x) * (implementation_data.max_cluster_element_count_div_32 + 32);
	if (is_spot) { offset += implementation_data.cluster_type_size; }
	uint z = uint(clamp((-vertex.z / scene_data_block.data.z_far) * 32.0, 0.0, 31.0));
	uint item_min, item_max, item_from, item_to;
	cluster_get_item_range(offset + implementation_data.max_cluster_element_count_div_32 + z, item_min, item_max, item_from, item_to);
	for (uint word = item_from; word < item_to; word++) {
		uint mask = cluster_buffer.data[offset + word] & cluster_get_range_clip_mask(word, item_min, item_max);
		while (mask != 0u) {
			uint bit = uint(findLSB(mask));
			mask &= mask - 1u;
			uint idx = word * 32u + bit;
			LightData light = is_spot ? spot_lights.data[idx] : omni_lights.data[idx];
			uvec2 candidate = uvec2(floatBitsToUint(light.pad[0]), floatBitsToUint(light.pad[1]));
			if (all(equal(candidate, light_id)) && (light.mask & instances.data[instance_index_interp].layer_mask) != 0u) {
				return is_spot ? custom_spot_shadow(idx, vertex, hvec3(normal)) : custom_omni_shadow(idx, vertex, hvec3(normal));
			}
		}
	}
	return 1.0;
}

#ifndef SHADOWS_DISABLED
// PCSS blocker search must not mistake the sloped receiver for an occluder.
// Keep raw blocker averages and the original filtering for actual occluders.
half custom_directional_soft_shadow(texture2D shadow, vec3 pssm_coord, vec2 tex_scale, float taa_frame_count, mat4 shadow_matrix, vec3 vertex, vec3 light_dir, float bias, vec3 dx, vec3 dy) {
	vec3 x = (shadow_matrix * vec4(dx, 0.0)).xyz;
	vec3 y = (shadow_matrix * vec4(dy, 0.0)).xyz;
	float det = x.x * y.y - x.y * y.x;
	vec3 plane_normal = cross(dx, dy);
	bool valid_plane = bias > 0.0 && abs(det) > 1e-12 && abs(dot(plane_normal, light_dir)) > 0.1 * length(plane_normal);
	vec2 gradient = valid_plane ? vec2(x.z * y.y - y.z * x.y, y.z * x.x - x.z * y.x) / det : vec2(0.0);
	vec3 plane = (shadow_matrix * vec4(vertex + light_dir * bias, 1.0)).xyz;
	//find blocker
	float blocker_count = 0.0;
	float blocker_average = 0.0;

	mat2 disk_rotation;
	{
		float r = quick_hash(gl_FragCoord.xy + vec2(taa_frame_count * 5.588238)) * 2.0 * M_PI;
		float sr = sin(r);
		float cr = cos(r);
		disk_rotation = mat2(vec2(cr, -sr), vec2(sr, cr));
	}

	SPEC_CONSTANT_LOOP_ANNOTATION
	for (uint i = 0; i < sc_directional_penumbra_shadow_samples(); i++) {
		vec2 suv = pssm_coord.xy + (disk_rotation * scene_data_block.data.directional_penumbra_shadow_kernel[i].xy) * tex_scale;
		float d = textureLod(sampler2D(shadow, SAMPLER_LINEAR_CLAMP), suv, 0.0).r;
		// Reject the receiver itself without changing accepted blocker depths or
		// the final PCF comparisons. Fade the rejection near grazing incidence.
		float plane_weight = valid_plane ? smoothstep(0.1, 0.2, abs(dot(plane_normal, light_dir)) / length(plane_normal)) : 0.0;
		float receiver_depth = mix(pssm_coord.z, max(pssm_coord.z, plane.z + dot(suv - plane.xy, gradient)), plane_weight);
		bool receiver_sample = false;
		if (d > pssm_coord.z && d <= receiver_depth) {
			// A bilinear sample crossing a caster silhouette and clear depth can
			// accidentally look coplanar. Only reject a fully covered footprint.
			ivec2 size = textureSize(sampler2D(shadow, SAMPLER_LINEAR_CLAMP), 0);
			ivec2 base = ivec2(floor(suv * vec2(size) - 0.5));
			receiver_sample = true;
			for (int sy = 0; sy < 2; sy++) {
				for (int sx = 0; sx < 2; sx++) {
					ivec2 pixel = clamp(base + ivec2(sx, sy), ivec2(0), size - 1);
					float stored = texelFetch(sampler2D(shadow, SAMPLER_LINEAR_CLAMP), pixel, 0).r;
					vec2 center = (vec2(pixel) + 0.5) / vec2(size);
					receiver_sample = receiver_sample && stored > 0.0 && stored <= plane.z + dot(center - plane.xy, gradient);
				}
			}
		}
		if (d > pssm_coord.z && !receiver_sample) {
			blocker_average += d;
			blocker_count += 1.0;
		}
	}

	if (blocker_count > 0.0) {
		//blockers found, do soft shadow
		blocker_average /= blocker_count;
		float penumbra = (-pssm_coord.z + blocker_average) / (1.0 - blocker_average);
		tex_scale *= penumbra;

		float s = 0.0;

		SPEC_CONSTANT_LOOP_ANNOTATION
		for (uint i = 0; i < sc_directional_penumbra_shadow_samples(); i++) {
			vec2 suv = pssm_coord.xy + (disk_rotation * scene_data_block.data.directional_penumbra_shadow_kernel[i].xy) * tex_scale;
			s += textureProj(sampler2DShadow(shadow, shadow_sampler), vec4(suv, pssm_coord.z, 1.0));
		}

		return half(s / float(sc_directional_penumbra_shadow_samples()));

	} else {
		//no blockers found, so no shadow
		return half(1.0);
	}
}

// A short receiver-plane contact query complements the biased PCF/PCSS result.
// It never substitutes for distant/soft shadows and does not consume AO.
float custom_directional_contact(mat4 shadow_matrix, vec3 vertex, vec3 light_dir, float bias, vec3 dx, vec3 dy) {
	vec3 plane_normal = cross(dx, dy);
	float normal_length = length(plane_normal);
	// Keep the explicitly zero-bias path unchanged and avoid unstable grazing planes.
	if (bias <= 0.0 || normal_length < 1e-12 || abs(dot(plane_normal, light_dir)) < 0.1 * normal_length) {
		return 1.0;
	}
	vec3 x = (shadow_matrix * vec4(dx, 0.0)).xyz;
	vec3 y = (shadow_matrix * vec4(dy, 0.0)).xyz;
	float det = x.x * y.y - x.y * y.x;
	if (abs(det) < 1e-12) { return 1.0; }
	vec2 gradient = vec2(x.z * y.y - y.z * x.y, y.z * x.x - x.z * y.x) / det;
	ivec2 size = textureSize(sampler2D(directional_shadow_atlas, SAMPLER_LINEAR_CLAMP), 0);
	// Limit the extra occlusion to eight texels along the receiver normal. Fade the
	// outer half so camera/cascade resolution changes do not make a hard cutoff.
	float xy_scale = length(vec3(shadow_matrix[0].x, shadow_matrix[1].x, shadow_matrix[2].x));
	float z_scale = length(vec3(shadow_matrix[0].z, shadow_matrix[1].z, shadow_matrix[2].z));
	float texel_world_size = 1.0 / (float(size.x) * xy_scale);
	float reach = 8.0 * texel_world_size * z_scale / (abs(dot(plane_normal, light_dir)) / normal_length);
	// Plane-corrected point comparisons need only a small rasterization margin;
	// using the broad PCF depth bias here would erase the contact again.
	float contact_bias = min(bias, texel_world_size * 0.25);
	vec3 coord = (shadow_matrix * vec4(vertex + light_dir * contact_bias, 1.0)).xyz;
	vec2 texel = coord.xy * vec2(size) - 0.5;
	ivec2 base = ivec2(floor(texel));
	// Require a coherent blocker over the footprint; isolated neighboring
	// surface samples must not turn into contact acne on detailed geometry.
	float occlusion = 1.0;
	for (int y_index = 0; y_index < 2; y_index++) {
		for (int x_index = 0; x_index < 2; x_index++) {
			ivec2 pixel = base + ivec2(x_index, y_index);
			if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, size))) { return 1.0; }
			vec2 center = (vec2(pixel) + 0.5) / vec2(size);
			float receiver = coord.z + dot(center - coord.xy, gradient);
			float stored = texelFetch(sampler2D(directional_shadow_atlas, SAMPLER_LINEAR_CLAMP), pixel, 0).r;
			float separation = stored - receiver;
			float blocked = separation > 0.0 && stored > 0.0 ? 1.0 - smoothstep(reach * 0.5, reach, separation) : 0.0;
			occlusion = min(occlusion, blocked);
		}
	}
	return 1.0 - occlusion * smoothstep(0.1, 0.2, abs(dot(plane_normal, light_dir)) / normal_length);
}

#endif

// Mirrors the dynamic directional shadow path; baked shadow masks are not part
// of the character bridge. Keep cascade filtering in sync with the scene shader.
float custom_directional_shadow(uint i, vec3 vertex, vec3 geo_normal) {
	float shadow = 1.0;
#ifndef SHADOWS_DISABLED
	if (directional_lights.data[i].shadow_opacity > 0.001) {
		vec3 receiver_dx = dFdx(vertex);
		vec3 receiver_dy = dFdy(vertex);
		float contact_shadow = 1.0;
		float depth_z = -vertex.z;
		// Unused splits repeat the last distance, but their matrices/atlas regions
		// are not valid. Never blend into them (notably two-split PCSS).
		vec4 splits = directional_lights.data[i].shadow_split_offsets;
		if (depth_z >= splits.w) {
			return 1.0;
		}
		vec3 light_dir = directional_lights.data[i].direction;
		vec3 base_normal_bias = geo_normal * (1.0 - max(0.0, dot(light_dir, -geo_normal)));

#define CUSTOM_DIRECTIONAL_BIAS(m_var, m_idx)                                                                 \
		m_var.xyz += light_dir * directional_lights.data[i].shadow_bias[m_idx];                     \
		vec3 normal_bias = base_normal_bias * directional_lights.data[i].shadow_normal_bias[m_idx]; \
		normal_bias -= light_dir * dot(light_dir, normal_bias);                                     \
		m_var.xyz += normal_bias;

		//version with soft shadows, more expensive
		if (sc_use_directional_soft_shadows() && directional_lights.data[i].softshadow_angle > 0) {
			uint blend_count = 0;
			const uint blend_max = directional_lights.data[i].blend_splits ? 2 : 1;

			if (depth_z < directional_lights.data[i].shadow_split_offsets.x) {
				vec4 v = vec4(vertex, 1.0);

				CUSTOM_DIRECTIONAL_BIAS(v, 0)

				vec4 pssm_coord = (directional_lights.data[i].shadow_matrix1 * v);
				contact_shadow = custom_directional_contact(directional_lights.data[i].shadow_matrix1, vertex, light_dir, directional_lights.data[i].shadow_bias[0], receiver_dx, receiver_dy);
				pssm_coord /= pssm_coord.w;

				float range_pos = dot(directional_lights.data[i].direction, v.xyz);
				float range_begin = directional_lights.data[i].shadow_range_begin.x;
				float test_radius = (range_pos - range_begin) * directional_lights.data[i].softshadow_angle;
				vec2 tex_scale = directional_lights.data[i].uv_scale1 * test_radius;
				shadow = custom_directional_soft_shadow(directional_shadow_atlas, pssm_coord.xyz, tex_scale * directional_lights.data[i].soft_shadow_scale, scene_data_block.data.taa_frame_count, directional_lights.data[i].shadow_matrix1, vertex, light_dir, directional_lights.data[i].shadow_bias[0], receiver_dx, receiver_dy);
				shadow = min(shadow, contact_shadow);
				blend_count++;
			}

			if (blend_count < blend_max && splits.y > splits.x && depth_z < splits.y) {
				vec4 v = vec4(vertex, 1.0);

				CUSTOM_DIRECTIONAL_BIAS(v, 1)

				vec4 pssm_coord = (directional_lights.data[i].shadow_matrix2 * v);
				contact_shadow = custom_directional_contact(directional_lights.data[i].shadow_matrix2, vertex, light_dir, directional_lights.data[i].shadow_bias[1], receiver_dx, receiver_dy);
				pssm_coord /= pssm_coord.w;

				float range_pos = dot(directional_lights.data[i].direction, v.xyz);
				float range_begin = directional_lights.data[i].shadow_range_begin.y;
				float test_radius = (range_pos - range_begin) * directional_lights.data[i].softshadow_angle;
				vec2 tex_scale = directional_lights.data[i].uv_scale2 * test_radius;
				float s = custom_directional_soft_shadow(directional_shadow_atlas, pssm_coord.xyz, tex_scale * directional_lights.data[i].soft_shadow_scale, scene_data_block.data.taa_frame_count, directional_lights.data[i].shadow_matrix2, vertex, light_dir, directional_lights.data[i].shadow_bias[1], receiver_dx, receiver_dy);
				s = min(s, contact_shadow);

				if (blend_count == 0) {
					shadow = s;
				} else {
					//blend
					float blend = smoothstep(0.0, directional_lights.data[i].shadow_split_offsets.x, depth_z);
					shadow = mix(shadow, s, blend);
				}

				blend_count++;
			}

			if (blend_count < blend_max && splits.z > splits.y && depth_z < splits.z) {
				vec4 v = vec4(vertex, 1.0);

				CUSTOM_DIRECTIONAL_BIAS(v, 2)

				vec4 pssm_coord = (directional_lights.data[i].shadow_matrix3 * v);
				contact_shadow = custom_directional_contact(directional_lights.data[i].shadow_matrix3, vertex, light_dir, directional_lights.data[i].shadow_bias[2], receiver_dx, receiver_dy);
				pssm_coord /= pssm_coord.w;

				float range_pos = dot(directional_lights.data[i].direction, v.xyz);
				float range_begin = directional_lights.data[i].shadow_range_begin.z;
				float test_radius = (range_pos - range_begin) * directional_lights.data[i].softshadow_angle;
				vec2 tex_scale = directional_lights.data[i].uv_scale3 * test_radius;
				float s = custom_directional_soft_shadow(directional_shadow_atlas, pssm_coord.xyz, tex_scale * directional_lights.data[i].soft_shadow_scale, scene_data_block.data.taa_frame_count, directional_lights.data[i].shadow_matrix3, vertex, light_dir, directional_lights.data[i].shadow_bias[2], receiver_dx, receiver_dy);
				s = min(s, contact_shadow);

				if (blend_count == 0) {
					shadow = s;
				} else {
					//blend
					float blend = smoothstep(directional_lights.data[i].shadow_split_offsets.x, directional_lights.data[i].shadow_split_offsets.y, depth_z);
					shadow = mix(shadow, s, blend);
				}

				blend_count++;
			}

			if (blend_count < blend_max && splits.w > splits.z) {
				vec4 v = vec4(vertex, 1.0);

				CUSTOM_DIRECTIONAL_BIAS(v, 3)

				vec4 pssm_coord = (directional_lights.data[i].shadow_matrix4 * v);
				contact_shadow = custom_directional_contact(directional_lights.data[i].shadow_matrix4, vertex, light_dir, directional_lights.data[i].shadow_bias[3], receiver_dx, receiver_dy);
				pssm_coord /= pssm_coord.w;

				float range_pos = dot(directional_lights.data[i].direction, v.xyz);
				float range_begin = directional_lights.data[i].shadow_range_begin.w;
				float test_radius = (range_pos - range_begin) * directional_lights.data[i].softshadow_angle;
				vec2 tex_scale = directional_lights.data[i].uv_scale4 * test_radius;
				float s = custom_directional_soft_shadow(directional_shadow_atlas, pssm_coord.xyz, tex_scale * directional_lights.data[i].soft_shadow_scale, scene_data_block.data.taa_frame_count, directional_lights.data[i].shadow_matrix4, vertex, light_dir, directional_lights.data[i].shadow_bias[3], receiver_dx, receiver_dy);
				s = min(s, contact_shadow);

				if (blend_count == 0) {
					shadow = s;
				} else {
					//blend
					float blend = smoothstep(directional_lights.data[i].shadow_split_offsets.y, directional_lights.data[i].shadow_split_offsets.z, depth_z);
					shadow = mix(shadow, s, blend);
				}
			}

		} else { //no soft shadows

			vec4 pssm_coord;
			float blur_factor;

			if (depth_z < directional_lights.data[i].shadow_split_offsets.x) {
				vec4 v = vec4(vertex, 1.0);

				CUSTOM_DIRECTIONAL_BIAS(v, 0)

				pssm_coord = (directional_lights.data[i].shadow_matrix1 * v);
				contact_shadow = custom_directional_contact(directional_lights.data[i].shadow_matrix1, vertex, light_dir, directional_lights.data[i].shadow_bias[0], receiver_dx, receiver_dy);
				blur_factor = 1.0;
			} else if (depth_z < directional_lights.data[i].shadow_split_offsets.y) {
				vec4 v = vec4(vertex, 1.0);

				CUSTOM_DIRECTIONAL_BIAS(v, 1)

				pssm_coord = (directional_lights.data[i].shadow_matrix2 * v);
				contact_shadow = custom_directional_contact(directional_lights.data[i].shadow_matrix2, vertex, light_dir, directional_lights.data[i].shadow_bias[1], receiver_dx, receiver_dy);
				// Adjust shadow blur with reference to the first split to reduce discrepancy between shadow splits.
				blur_factor = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.y;
			} else if (depth_z < directional_lights.data[i].shadow_split_offsets.z) {
				vec4 v = vec4(vertex, 1.0);

				CUSTOM_DIRECTIONAL_BIAS(v, 2)

				pssm_coord = (directional_lights.data[i].shadow_matrix3 * v);
				contact_shadow = custom_directional_contact(directional_lights.data[i].shadow_matrix3, vertex, light_dir, directional_lights.data[i].shadow_bias[2], receiver_dx, receiver_dy);
				// Adjust shadow blur with reference to the first split to reduce discrepancy between shadow splits.
				blur_factor = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.z;
			} else {
				vec4 v = vec4(vertex, 1.0);

				CUSTOM_DIRECTIONAL_BIAS(v, 3)

				pssm_coord = (directional_lights.data[i].shadow_matrix4 * v);
				contact_shadow = custom_directional_contact(directional_lights.data[i].shadow_matrix4, vertex, light_dir, directional_lights.data[i].shadow_bias[3], receiver_dx, receiver_dy);
				// Adjust shadow blur with reference to the first split to reduce discrepancy between shadow splits.
				blur_factor = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.w;
			}

			pssm_coord /= pssm_coord.w;

			shadow = sample_directional_pcf_shadow(directional_shadow_atlas, scene_data_block.data.directional_shadow_pixel_size * directional_lights.data[i].soft_shadow_scale * (blur_factor + (1.0 - blur_factor) * float(directional_lights.data[i].blend_splits)), pssm_coord, scene_data_block.data.taa_frame_count);
			shadow = min(shadow, contact_shadow);

			if (directional_lights.data[i].blend_splits) {
				float pssm_blend;
				float blur_factor2;

				if (depth_z < directional_lights.data[i].shadow_split_offsets.x) {
					vec4 v = vec4(vertex, 1.0);
					CUSTOM_DIRECTIONAL_BIAS(v, 1)
					pssm_coord = (directional_lights.data[i].shadow_matrix2 * v);
					contact_shadow = custom_directional_contact(directional_lights.data[i].shadow_matrix2, vertex, light_dir, directional_lights.data[i].shadow_bias[1], receiver_dx, receiver_dy);
					pssm_blend = smoothstep(directional_lights.data[i].shadow_split_offsets.x - directional_lights.data[i].shadow_split_offsets.x * 0.1, directional_lights.data[i].shadow_split_offsets.x, depth_z);
					// Adjust shadow blur with reference to the first split to reduce discrepancy between shadow splits.
					blur_factor2 = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.y;
				} else if (splits.z > splits.y && depth_z < splits.y) {
					vec4 v = vec4(vertex, 1.0);
					CUSTOM_DIRECTIONAL_BIAS(v, 2)
					pssm_coord = (directional_lights.data[i].shadow_matrix3 * v);
					contact_shadow = custom_directional_contact(directional_lights.data[i].shadow_matrix3, vertex, light_dir, directional_lights.data[i].shadow_bias[2], receiver_dx, receiver_dy);
					pssm_blend = smoothstep(directional_lights.data[i].shadow_split_offsets.y - directional_lights.data[i].shadow_split_offsets.y * 0.1, directional_lights.data[i].shadow_split_offsets.y, depth_z);
					// Adjust shadow blur with reference to the first split to reduce discrepancy between shadow splits.
					blur_factor2 = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.z;
				} else if (splits.w > splits.z && depth_z < splits.z) {
					vec4 v = vec4(vertex, 1.0);
					CUSTOM_DIRECTIONAL_BIAS(v, 3)
					pssm_coord = (directional_lights.data[i].shadow_matrix4 * v);
					contact_shadow = custom_directional_contact(directional_lights.data[i].shadow_matrix4, vertex, light_dir, directional_lights.data[i].shadow_bias[3], receiver_dx, receiver_dy);
					pssm_blend = smoothstep(directional_lights.data[i].shadow_split_offsets.z - directional_lights.data[i].shadow_split_offsets.z * 0.1, directional_lights.data[i].shadow_split_offsets.z, depth_z);
					// Adjust shadow blur with reference to the first split to reduce discrepancy between shadow splits.
					blur_factor2 = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.w;
				} else {
					pssm_blend = 0.0; //if no blend, same coord will be used (divide by z will result in same value, and already cached)
					blur_factor2 = 1.0;
				}

				pssm_coord /= pssm_coord.w;

				float shadow2 = sample_directional_pcf_shadow(directional_shadow_atlas, scene_data_block.data.directional_shadow_pixel_size * directional_lights.data[i].soft_shadow_scale * (blur_factor2 + (1.0 - blur_factor2) * float(directional_lights.data[i].blend_splits)), pssm_coord, scene_data_block.data.taa_frame_count);
				shadow2 = min(shadow2, contact_shadow);
				shadow = mix(shadow, shadow2, pssm_blend);
			}
		}
		shadow = mix(shadow, 1.0, smoothstep(directional_lights.data[i].fade_from, directional_lights.data[i].fade_to, vertex.z));
#undef CUSTOM_DIRECTIONAL_BIAS
	}
	shadow = mix(1.0, shadow, directional_lights.data[i].shadow_opacity);
#endif
	return shadow;
}

float custom_forward_directional_shadow(uvec2 light_id, vec3 vertex, vec3 normal) {
	for (uint i = 0u; i < scene_data_block.data.directional_light_count; i++) {
		if (all(equal(directional_lights.data[i].pad, light_id)) &&
				(directional_lights.data[i].mask & instances.data[instance_index_interp].layer_mask) != 0u) {
			return custom_directional_shadow(i, vertex, normal);
		}
	}
	return 1.0;
}
