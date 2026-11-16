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

// Mirrors the dynamic directional shadow path; baked shadow masks are not part
// of the character bridge. Keep cascade filtering in sync with the scene shader.
float custom_directional_shadow(uint i, vec3 vertex, vec3 geo_normal) {
	float shadow = 1.0;
#ifndef SHADOWS_DISABLED
	if (directional_lights.data[i].shadow_opacity > 0.001) {
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
				pssm_coord /= pssm_coord.w;

				float range_pos = dot(directional_lights.data[i].direction, v.xyz);
				float range_begin = directional_lights.data[i].shadow_range_begin.x;
				float test_radius = (range_pos - range_begin) * directional_lights.data[i].softshadow_angle;
				vec2 tex_scale = directional_lights.data[i].uv_scale1 * test_radius;
				shadow = sample_directional_soft_shadow(directional_shadow_atlas, pssm_coord.xyz, tex_scale * directional_lights.data[i].soft_shadow_scale, scene_data_block.data.taa_frame_count);
				blend_count++;
			}

			if (blend_count < blend_max && splits.y > splits.x && depth_z < splits.y) {
				vec4 v = vec4(vertex, 1.0);

				CUSTOM_DIRECTIONAL_BIAS(v, 1)

				vec4 pssm_coord = (directional_lights.data[i].shadow_matrix2 * v);
				pssm_coord /= pssm_coord.w;

				float range_pos = dot(directional_lights.data[i].direction, v.xyz);
				float range_begin = directional_lights.data[i].shadow_range_begin.y;
				float test_radius = (range_pos - range_begin) * directional_lights.data[i].softshadow_angle;
				vec2 tex_scale = directional_lights.data[i].uv_scale2 * test_radius;
				float s = sample_directional_soft_shadow(directional_shadow_atlas, pssm_coord.xyz, tex_scale * directional_lights.data[i].soft_shadow_scale, scene_data_block.data.taa_frame_count);

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
				pssm_coord /= pssm_coord.w;

				float range_pos = dot(directional_lights.data[i].direction, v.xyz);
				float range_begin = directional_lights.data[i].shadow_range_begin.z;
				float test_radius = (range_pos - range_begin) * directional_lights.data[i].softshadow_angle;
				vec2 tex_scale = directional_lights.data[i].uv_scale3 * test_radius;
				float s = sample_directional_soft_shadow(directional_shadow_atlas, pssm_coord.xyz, tex_scale * directional_lights.data[i].soft_shadow_scale, scene_data_block.data.taa_frame_count);

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
				pssm_coord /= pssm_coord.w;

				float range_pos = dot(directional_lights.data[i].direction, v.xyz);
				float range_begin = directional_lights.data[i].shadow_range_begin.w;
				float test_radius = (range_pos - range_begin) * directional_lights.data[i].softshadow_angle;
				vec2 tex_scale = directional_lights.data[i].uv_scale4 * test_radius;
				float s = sample_directional_soft_shadow(directional_shadow_atlas, pssm_coord.xyz, tex_scale * directional_lights.data[i].soft_shadow_scale, scene_data_block.data.taa_frame_count);

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
				blur_factor = 1.0;
			} else if (depth_z < directional_lights.data[i].shadow_split_offsets.y) {
				vec4 v = vec4(vertex, 1.0);

				CUSTOM_DIRECTIONAL_BIAS(v, 1)

				pssm_coord = (directional_lights.data[i].shadow_matrix2 * v);
				// Adjust shadow blur with reference to the first split to reduce discrepancy between shadow splits.
				blur_factor = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.y;
			} else if (depth_z < directional_lights.data[i].shadow_split_offsets.z) {
				vec4 v = vec4(vertex, 1.0);

				CUSTOM_DIRECTIONAL_BIAS(v, 2)

				pssm_coord = (directional_lights.data[i].shadow_matrix3 * v);
				// Adjust shadow blur with reference to the first split to reduce discrepancy between shadow splits.
				blur_factor = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.z;
			} else {
				vec4 v = vec4(vertex, 1.0);

				CUSTOM_DIRECTIONAL_BIAS(v, 3)

				pssm_coord = (directional_lights.data[i].shadow_matrix4 * v);
				// Adjust shadow blur with reference to the first split to reduce discrepancy between shadow splits.
				blur_factor = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.w;
			}

			pssm_coord /= pssm_coord.w;

			shadow = sample_directional_pcf_shadow(directional_shadow_atlas, scene_data_block.data.directional_shadow_pixel_size * directional_lights.data[i].soft_shadow_scale * (blur_factor + (1.0 - blur_factor) * float(directional_lights.data[i].blend_splits)), pssm_coord, scene_data_block.data.taa_frame_count);

			if (directional_lights.data[i].blend_splits) {
				float pssm_blend;
				float blur_factor2;

				if (depth_z < directional_lights.data[i].shadow_split_offsets.x) {
					vec4 v = vec4(vertex, 1.0);
					CUSTOM_DIRECTIONAL_BIAS(v, 1)
					pssm_coord = (directional_lights.data[i].shadow_matrix2 * v);
					pssm_blend = smoothstep(directional_lights.data[i].shadow_split_offsets.x - directional_lights.data[i].shadow_split_offsets.x * 0.1, directional_lights.data[i].shadow_split_offsets.x, depth_z);
					// Adjust shadow blur with reference to the first split to reduce discrepancy between shadow splits.
					blur_factor2 = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.y;
				} else if (splits.z > splits.y && depth_z < splits.y) {
					vec4 v = vec4(vertex, 1.0);
					CUSTOM_DIRECTIONAL_BIAS(v, 2)
					pssm_coord = (directional_lights.data[i].shadow_matrix3 * v);
					pssm_blend = smoothstep(directional_lights.data[i].shadow_split_offsets.y - directional_lights.data[i].shadow_split_offsets.y * 0.1, directional_lights.data[i].shadow_split_offsets.y, depth_z);
					// Adjust shadow blur with reference to the first split to reduce discrepancy between shadow splits.
					blur_factor2 = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.z;
				} else if (splits.w > splits.z && depth_z < splits.z) {
					vec4 v = vec4(vertex, 1.0);
					CUSTOM_DIRECTIONAL_BIAS(v, 3)
					pssm_coord = (directional_lights.data[i].shadow_matrix4 * v);
					pssm_blend = smoothstep(directional_lights.data[i].shadow_split_offsets.z - directional_lights.data[i].shadow_split_offsets.z * 0.1, directional_lights.data[i].shadow_split_offsets.z, depth_z);
					// Adjust shadow blur with reference to the first split to reduce discrepancy between shadow splits.
					blur_factor2 = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.w;
				} else {
					pssm_blend = 0.0; //if no blend, same coord will be used (divide by z will result in same value, and already cached)
					blur_factor2 = 1.0;
				}

				pssm_coord /= pssm_coord.w;

				float shadow2 = sample_directional_pcf_shadow(directional_shadow_atlas, scene_data_block.data.directional_shadow_pixel_size * directional_lights.data[i].soft_shadow_scale * (blur_factor2 + (1.0 - blur_factor2) * float(directional_lights.data[i].blend_splits)), pssm_coord, scene_data_block.data.taa_frame_count);
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
