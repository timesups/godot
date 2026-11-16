extends SceneTree

# Material reconstruction is intentionally per draw. Unverified variants show
# base color only; E674, E689, E694 and E704 use separate reconstructed materials.
var evidence := ""
var keep_open := false
var albedo_only := false
var clothes_surface := false
var live_lights := false
var instances: Array[MeshInstance3D] = []
var textures := {}

func _initialize() -> void:
	call_deferred("run")

func v3(bytes: PackedByteArray, offset: int) -> Vector3:
	return Vector3(bytes.decode_float(offset), bytes.decode_float(offset + 4), bytes.decode_float(offset + 8))

func texture(id: int) -> ImageTexture:
	if textures.has(id):
		return textures[id]
	# RenderDoc DX10 DDS exports are not accepted by Godot's image file loader.
	# Preserve original compressed BC7 blocks instead of round-tripping through PNG.
	var bytes := FileAccess.get_file_as_bytes(evidence.path_join(("e689-texture-%d.dds" if id in [37722, 4874, 37745, 53468] else "texture-%d.dds") % id))
	assert(bytes.size() >= 148)
	var dx10 := bytes.slice(84, 88).get_string_from_ascii() == "DX10"
	assert(not dx10 or bytes.decode_u32(128) in [98, 99])
	var payload := bytes.slice(148 if dx10 else 128)
	var levels := 11 if id == 185716 else (9 if id == 37722 else (10 if id == 37745 else 1))
	for mip in range(1, levels):
		var name := "texture-185716-mip%d.dds" % mip if id == 185716 else "e689-texture-%d-mip%d.dds" % [id, mip]
		payload.append_array(FileAccess.get_file_as_bytes(evidence.path_join(name)).slice(148))
	var image := Image.create_from_data(bytes.decode_u32(16), bytes.decode_u32(12), levels > 1,
		Image.FORMAT_BPTC_RGBA if dx10 else Image.FORMAT_RGBA8, payload)
	assert(image != null and not image.is_empty(), "Missing captured texture %d" % id)
	var result := ImageTexture.create_from_image(image)
	textures[id] = result
	return result

func snapshot() -> Image:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence="):
			evidence = arg.trim_prefix("--evidence=")
		elif arg == "--keep-open":
			keep_open = true
		elif arg == "--clothes-surface":
			clothes_surface = true
		elif arg == "--live-lights":
			live_lights = true
		elif arg == "--albedo-only":
			albedo_only = true
	assert(not evidence.is_empty())
	assert(RenderingServer.get_current_rendering_method() == "custom_forward")
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(evidence.path_join("character-manifest.json")))
	assert(manifest.parts.size() == 8)
	root.size = Vector2i(640, 960)
	var origin := Vector3(manifest.coordinate_origin[0], manifest.coordinate_origin[1], manifest.coordinate_origin[2])
	var directory := ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/custom_forward/materials")
	var validated := Shader.new()
	validated.code = FileAccess.get_file_as_string(directory.path_join("character.gdshader")).replace('#include "character_lighting.gdshaderinc"', FileAccess.get_file_as_string(directory.path_join("character_lighting.gdshaderinc")))
	var face_shader := Shader.new()
	face_shader.code = FileAccess.get_file_as_string(directory.path_join("face.gdshader")).replace('#include "character_lighting.gdshaderinc"', FileAccess.get_file_as_string(directory.path_join("character_lighting.gdshaderinc"))).replace('#include "face_lighting.gdshaderinc"', FileAccess.get_file_as_string(directory.path_join("face_lighting.gdshaderinc")))
	face_shader.code = face_shader.code.replace('#include "face_shadow.gdshaderinc"', FileAccess.get_file_as_string(directory.path_join("face_shadow.gdshaderinc")))
	var clothes_shader := Shader.new()
	clothes_shader.code = FileAccess.get_file_as_string(directory.path_join("clothes_surface.gdshader" if clothes_surface else "clothes.gdshader"))
	for include in ["character_lighting", "clothes_surface", "clothes_lighting", "face_shadow"]:
		clothes_shader.code = clothes_shader.code.replace('#include "%s.gdshaderinc"' % include, FileAccess.get_file_as_string(directory.path_join(include + ".gdshaderinc")))
	var skin_shader := Shader.new()
	skin_shader.code = FileAccess.get_file_as_string(directory.path_join("skin.gdshader"))
	for include in ["character_lighting","clothes_surface","clothes_lighting","skin_lighting","face_shadow"]:
		skin_shader.code = skin_shader.code.replace('#include "%s.gdshaderinc"' % include,FileAccess.get_file_as_string(directory.path_join(include+".gdshaderinc")))
	var hair_shader := Shader.new()
	hair_shader.code = FileAccess.get_file_as_string(directory.path_join("hair.gdshader"))
	for include in ["character_lighting", "hair_lighting", "face_shadow"]:
		hair_shader.code = hair_shader.code.replace('#include "%s.gdshaderinc"' % include, FileAccess.get_file_as_string(directory.path_join(include + ".gdshaderinc")))
	var diagnostic := Shader.new()
	diagnostic.code = "shader_type spatial; render_mode custom_character, cull_disabled; uniform sampler2D base_map : source_color, filter_linear, repeat_enable; void fragment() { ALBEDO = texture(base_map, UV).rgb; EMISSION = ALBEDO; }"
	var silhouette := Shader.new()
	silhouette.code = "shader_type spatial; render_mode custom_character, cull_disabled; void fragment() { EMISSION = vec3(1.0); }"
	var silhouette_material := ShaderMaterial.new()
	silhouette_material.shader = silhouette
	var all_bounds := AABB()
	var total_triangles := 0
	for part in manifest.parts:
		var event := int(part.event)
		var placement := Transform3D.IDENTITY
		if event in [674, 689, 704]:
			var pose := FileAccess.get_file_as_bytes(evidence.path_join("e%d-record0-transform.bin" % event))
			placement = Transform3D(Basis(v3(pose, 0), v3(pose, 16), v3(pose, 32)).transposed(),
				Vector3(pose.decode_float(12), pose.decode_float(28), pose.decode_float(44)) - origin)
		var inverse := placement.affine_inverse()
		var vb := FileAccess.get_file_as_bytes(evidence.path_join("e%d-postvs-vertex.bin" % event))
		var ib := FileAccess.get_file_as_bytes(evidence.path_join("e%d-postvs-index.bin" % event))
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()
		var tangents := PackedFloat32Array()
		for i in int(part.vertex_count):
			var offset := int(part.vertex_offset) + i * int(part.vertex_stride)
			vertices.append(inverse * (v3(vb, offset + 32) - origin))
			normals.append((placement.basis.inverse() * v3(vb, offset + 48)).normalized())
			uvs.append(Vector2(vb.decode_float(offset + 16), vb.decode_float(offset + 20)))
			if event in [669, 694, 704] and not albedo_only:
				var t := placement.basis.inverse() * v3(vb, offset + 64)
				tangents.append_array([t.x, t.y, t.z, vb.decode_float(offset + 76)])
		var indices := PackedInt32Array()
		for i in int(part.index_count):
			var offset := int(part.index_offset) + i * int(part.index_stride)
			indices.append(ib.decode_u16(offset) if int(part.index_stride) == 2 else ib.decode_u32(offset))
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_INDEX] = indices
		if not tangents.is_empty():
			arrays[Mesh.ARRAY_TANGENT] = tangents
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := ShaderMaterial.new()
		material.shader = (validated if event == 674 else face_shader) if event in [674, 689] and not albedo_only else diagnostic
		var base_texture := texture(int(part.base_texture))
		assert(base_texture != null)
		material.set_shader_parameter("base_map", base_texture)
		if event == 669 and not albedo_only:
			material.shader = skin_shader
			material.set_shader_parameter("base_map",skin_texture(185721))
			material.set_shader_parameter("normal_map",skin_texture(185726))
			material.set_shader_parameter("material_lut",texture(172496))
			material.set_shader_parameter("ramp_map",texture(186593))
			material.set_shader_parameter("radial_origin",placement.origin)
		if event == 674 and not albedo_only:
			material.set_shader_parameter("material_lut", texture(172496))
			material.set_shader_parameter("ramp_map", texture(186593))
			material.set_shader_parameter("mip_bias", -1.0)
			material.set_shader_parameter("character_exposure", 1.05)
		if event == 689 and not albedo_only:
			material.set_shader_parameter("material_lut", texture(172496))
			material.set_shader_parameter("face_mask", texture(37722))
			material.set_shader_parameter("face_sdf", texture(4874))
			material.set_shader_parameter("face_specular", texture(37745))
			material.set_shader_parameter("face_ramp", texture(53468))
		if event == 694 and not albedo_only:
			material.shader = clothes_shader
			for pair in [["base_map", 187399], ["normal_map", 187429], ["parameters_map", 187402]]:
				material.set_shader_parameter(pair[0], clothes_texture(pair[1]))
			if not clothes_surface:
				for pair in [["emission_map", 185914], ["ramp_map", 118829], ["specular_map", 39217]]:
					material.set_shader_parameter(pair[0], clothes_texture(pair[1]))
				material.set_shader_parameter("reflection_map", clothes_cube())
				material.set_shader_parameter("radial_origin", Vector3(0.027648926, 0, 0.023254395))
		if event == 704 and not albedo_only:
			material.shader = hair_shader
			for pair in [["base_map",185700], ["normal_map",186605], ["parameters_map",187392], ["ramp_map",188148], ["specular_map",186747], ["material_lut",173100], ["noise_map",37600]]:
				material.set_shader_parameter(pair[0], hair_texture(pair[1]))
			material.set_shader_parameter("radial_origin", placement.origin)
		var instance := MeshInstance3D.new()
		instance.name = "E%d_%s" % [event, part.name]
		instance.mesh = mesh
		instance.transform = placement
		instance.material_override = material
		instance.set_meta("capture_event", event)
		instance.set_meta("material_status", part.material_status)
		root.add_child(instance)
		var world_bounds := placement * mesh.get_aabb()
		all_bounds = world_bounds if instances.is_empty() else all_bounds.merge(world_bounds)
		instances.append(instance)
		total_triangles += indices.size() / 3
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color.BLACK
	root.add_child(environment)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = all_bounds.size.y * 1.12
	camera.position = all_bounds.get_center() + Vector3(0, 0, 3)
	camera.look_at(all_bounds.get_center())
	camera.make_current()
	# Verify every draw independently, including pieces occluded in the assembled view.
	var counts := {}
	for instance in instances:
		instance.visible = false
	for instance in instances:
		instance.visible = true
		var original := instance.material_override
		instance.material_override = silhouette_material
		var isolated := await snapshot()
		var count := 0
		for y in isolated.get_height():
			for x in isolated.get_width():
				if isolated.get_pixel(x, y).r > 0.5:
					count += 1
		assert(count > 3, "Missing or degenerate captured part: " + instance.name)
		counts[instance.name] = count
		instance.material_override = original
		var textured := await snapshot()
		var palette := {}
		for y in textured.get_height():
			for x in textured.get_width():
				var color := textured.get_pixel(x, y)
				if maxf(color.r, maxf(color.g, color.b)) > 0.02:
					palette[color.to_rgba32() >> 8] = true
		assert(palette.size() > 8, "Missing texture variation or collapsed UVs: " + instance.name)
		counts[instance.name] = {"silhouette_pixels": count, "textured_colors": palette.size()}
		if int(instance.get_meta("capture_event")) == 669 and not albedo_only:
			for parameter in ["normal_strength","rim_strength","analytic_strength"]:
				var saved: Variant = original.get_shader_parameter(parameter)
				original.set_shader_parameter(parameter,0.0)
				var changed := await snapshot()
				assert(changed.get_data()!=textured.get_data(),"E669 parameter had no effect: "+parameter)
				original.set_shader_parameter(parameter,saved)
			original.set_shader_parameter("screen_shadow_ao",Vector2(1,0))
			assert((await snapshot()).get_data()!=textured.get_data(),"E669 AO had no effect")
			original.set_shader_parameter("screen_shadow_ao",Vector2.ONE)
			counts[instance.name]["lighting_response"] = "BC5 normal, rim tint, analytic specular and AO passed"
		if int(instance.get_meta("capture_event")) == 694 and not albedo_only and not clothes_surface:
			for parameter in ["analytic_strength", "reflection_strength"]:
				original.set_shader_parameter(parameter, 0.0)
				var disabled := await snapshot()
				assert(disabled.get_data() != textured.get_data(), "E694 " + parameter + " did not respond")
				original.set_shader_parameter(parameter, 1.0)
			original.set_shader_parameter("screen_shadow_ao", Vector2(0, 0))
			var occluded := await snapshot()
			assert(occluded.get_data() != textured.get_data(), "E694 screen shadow/AO did not respond")
			original.set_shader_parameter("screen_shadow_ao", Vector2.ONE)
			original.set_shader_parameter("main_energy", 0.0)
			original.set_shader_parameter("environment_strength", 0.0)
			original.set_shader_parameter("ambient_exposure", 0.0)
			original.set_shader_parameter("emission_strength", 0.0)
			var unlit := await snapshot()
			var black := Image.create(unlit.get_width(), unlit.get_height(), false, unlit.get_format())
			black.fill(Color.BLACK)
			assert(unlit.get_data() == black.get_data(), "E694 must use its own lighting")
			var center := (instance.transform * instance.mesh.get_aabb()).get_center()
			original.set_shader_parameter("local_light_count", 1)
			original.set_shader_parameter("local_positions", PackedVector4Array([Vector4(center.x+0.5, center.y, center.z+0.5, 0.5)]))
			original.set_shader_parameter("local_parameters", PackedVector4Array([Vector4(0.7, 0.5, 0, 0)]))
			original.set_shader_parameter("local_attenuation", PackedVector4Array([Vector4(1, 0, 0, 1)]))
			original.set_shader_parameter("local_specular_strength", PackedFloat32Array([1.0]))
			for mode in [0, 1, 3, 4]:
				original.set_shader_parameter("local_colors", PackedVector4Array([Vector4(2, 1, 0.5, mode)]))
				var local := await snapshot()
				assert(local.get_data() != unlit.get_data(), "E694 local light mode %d did not respond" % mode)
			original.set_shader_parameter("local_colors", PackedVector4Array([Vector4(2, 1, 0.5, 3)]))
			var depth_image := Image.create(4, 4, false, Image.FORMAT_RF)
			depth_image.fill(Color(1, 0, 0))
			var depth_texture := ImageTexture.create_from_image(depth_image)
			original.set_shader_parameter("shadow_atlas", depth_texture)
			original.set_shader_parameter("shadow_atlas_enabled", true)
			original.set_shader_parameter("local_shadow_enabled", [true])
			original.set_shader_parameter("local_shadow_matrices", [Projection(Vector4.ZERO, Vector4.ZERO, Vector4.ZERO, Vector4(0.5,0.5,0.5,1))])
			original.set_shader_parameter("local_shadow_rects", PackedVector4Array([Vector4(0,0,1,1)]))
			original.set_shader_parameter("local_shadow_bias", PackedVector4Array([Vector4(0,0,0,1)]))
			var blocked := await snapshot()
			assert(blocked.get_data() == unlit.get_data(), "E694 atlas did not block the rim light")
			depth_image.fill(Color(0, 0, 0))
			depth_texture.update(depth_image)
			var visible := await snapshot()
			assert(visible.get_data() != blocked.get_data(), "E694 atlas did not release the rim light")
			depth_image.fill(Color(1, 0, 0))
			depth_texture.update(depth_image)
			original.set_shader_parameter("local_shadow_bias", PackedVector4Array([Vector4(0,0,0,0)]))
			var zero_strength := await snapshot()
			assert(zero_strength.get_data() == visible.get_data(), "E694 zero shadow strength must preserve visibility")
			original.set_shader_parameter("shadow_atlas_enabled", false)
			original.set_shader_parameter("local_light_count", 0)
			original.set_shader_parameter("main_energy", 1.6243867874)
			original.set_shader_parameter("environment_strength", 0.2877224684)
			original.set_shader_parameter("ambient_exposure", 0.9)
			original.set_shader_parameter("emission_strength", 2.0)
			counts[instance.name]["lighting_response"] = "analytic specular, reflection, shadow/AO, blackout, modes 0/1/3/4, shadow atlas passed"
		if int(instance.get_meta("capture_event")) == 704 and not albedo_only:
			for parameter in ["specular_strength"]:
				original.set_shader_parameter(parameter, 0.0)
				var disabled := await snapshot()
				assert(disabled.get_data() != textured.get_data(), "E704 " + parameter + " did not respond")
				original.set_shader_parameter(parameter, 1.0)
			original.set_shader_parameter("screen_shadow_ao", Vector2(0, 0))
			var occluded := await snapshot()
			assert(occluded.get_data() != textured.get_data(), "E704 screen shadow/AO did not respond")
			original.set_shader_parameter("screen_shadow_ao", Vector2.ONE)
			original.set_shader_parameter("main_energy", 0.0)
			original.set_shader_parameter("environment_strength", 0.0)
			original.set_shader_parameter("ambient_exposure", 0.0)
			var unlit := await snapshot()
			var black := Image.create(unlit.get_width(), unlit.get_height(), false, unlit.get_format())
			black.fill(Color.BLACK)
			assert(unlit.get_data() == black.get_data(), "E704 must use its own lighting")
			var center := (instance.transform * instance.mesh.get_aabb()).get_center()
			original.set_shader_parameter("local_light_count", 1)
			original.set_shader_parameter("local_positions", PackedVector4Array([Vector4(center.x+0.5, center.y, center.z+0.5, 0.5)]))
			original.set_shader_parameter("local_parameters", PackedVector4Array([Vector4(0.7, 0.5, 0, 0)]))
			original.set_shader_parameter("local_attenuation", PackedVector4Array([Vector4(1, 0, 0, 1)]))
			original.set_shader_parameter("local_specular_strength", PackedFloat32Array([1.0]))
			original.set_shader_parameter("local_rim_visibility", PackedFloat32Array([1.0]))
			for mode in [0, 1, 3, 4]:
				original.set_shader_parameter("local_colors", PackedVector4Array([Vector4(2, 1, 0.5, mode)]))
				var local := await snapshot()
				assert(local.get_data() != unlit.get_data(), "E704 local light mode %d did not respond" % mode)
			original.set_shader_parameter("local_colors", PackedVector4Array([Vector4(2, 1, 0.5, 3)]))
			original.set_shader_parameter("local_rim_visibility", PackedFloat32Array([0.0]))
			var no_rim := await snapshot()
			assert(no_rim.get_data() == unlit.get_data(), "E704 depth rim mask must suppress mode 3")
			original.set_shader_parameter("local_rim_visibility", PackedFloat32Array([1.0]))
			var depth_image := Image.create(4, 4, false, Image.FORMAT_RF)
			depth_image.fill(Color(1, 0, 0))
			var depth_texture := ImageTexture.create_from_image(depth_image)
			original.set_shader_parameter("shadow_atlas", depth_texture)
			original.set_shader_parameter("shadow_atlas_enabled", true)
			original.set_shader_parameter("local_shadow_enabled", [true])
			original.set_shader_parameter("local_shadow_matrices", [Projection(Vector4.ZERO, Vector4.ZERO, Vector4.ZERO, Vector4(0.5,0.5,0.5,1))])
			original.set_shader_parameter("local_shadow_rects", PackedVector4Array([Vector4(0,0,1,1)]))
			original.set_shader_parameter("local_shadow_bias", PackedVector4Array([Vector4(0,0,0,1)]))
			var blocked := await snapshot()
			assert(blocked.get_data() == unlit.get_data(), "E704 atlas did not block the rim light")
			depth_image.fill(Color(0, 0, 0))
			depth_texture.update(depth_image)
			var visible := await snapshot()
			assert(visible.get_data() != blocked.get_data(), "E704 atlas did not release the rim light")
			depth_image.fill(Color(1, 0, 0))
			depth_texture.update(depth_image)
			original.set_shader_parameter("local_shadow_bias", PackedVector4Array([Vector4(0,0,0,0)]))
			var zero_strength := await snapshot()
			assert(zero_strength.get_data() == visible.get_data(), "E704 zero shadow strength must preserve visibility")
			original.set_shader_parameter("shadow_atlas_enabled", false)
			original.set_shader_parameter("local_light_count", 0)
			original.set_shader_parameter("main_energy", 1.6243867874)
			original.set_shader_parameter("environment_strength", 0.2877224684)
			original.set_shader_parameter("ambient_exposure", 0.9)
			counts[instance.name]["lighting_response"] = "dual-lobe specular, shadow/AO, blackout, modes 0/1/3/4, shadow atlas passed"
		if int(instance.get_meta("capture_event")) == 689 and not albedo_only:
			original.set_shader_parameter("main_direction", Vector3(1, 0, 0))
			var right := await snapshot()
			original.set_shader_parameter("main_direction", Vector3(-1, 0, 0))
			var left := await snapshot()
			assert(right.get_data() != left.get_data(), "E689 SDF left/right lighting did not respond")
			original.set_shader_parameter("main_direction", Vector3(-0.14726211, 0.52991927, 0.83516431))
			original.set_shader_parameter("face_ao", 0.0)
			var occluded := await snapshot()
			assert(occluded.get_data() != textured.get_data(), "E689 face AO did not respond")
			original.set_shader_parameter("face_ao", 1.0)
			original.set_shader_parameter("main_energy", 0.0)
			original.set_shader_parameter("environment_strength", 0.0)
			var unlit := await snapshot()
			var black := Image.create(unlit.get_width(), unlit.get_height(), false, unlit.get_format())
			black.fill(Color.BLACK)
			assert(unlit.get_data() == black.get_data(), "E689 must use its own lighting")
			var center := (instance.transform * instance.mesh.get_aabb()).get_center()
			original.set_shader_parameter("local_light_count", 1)
			original.set_shader_parameter("local_positions", PackedVector4Array([Vector4(center.x + 0.15, center.y, center.z + 0.15, 1)]))
			original.set_shader_parameter("local_parameters", PackedVector4Array([Vector4(1, 0.5, 0, 0)]))
			original.set_shader_parameter("local_attenuation", PackedVector4Array([Vector4(1, 0, 0, 1)]))
			for mode in [0, 1, 3]:
				original.set_shader_parameter("local_colors", PackedVector4Array([Vector4(2, 1, 0.5, mode)]))
				var local := await snapshot()
				assert(local.get_data() != unlit.get_data(), "E689 local light mode %d did not respond" % mode)
			var depth_image := Image.create(4, 4, false, Image.FORMAT_RF)
			depth_image.fill(Color(1, 0, 0))
			var depth_texture := ImageTexture.create_from_image(depth_image)
			original.set_shader_parameter("shadow_atlas", depth_texture)
			original.set_shader_parameter("shadow_atlas_enabled", true)
			original.set_shader_parameter("local_shadow_enabled", [true])
			original.set_shader_parameter("local_shadow_matrices", [Projection(Vector4.ZERO, Vector4.ZERO, Vector4.ZERO, Vector4(0.5, 0.5, 0.5, 1))])
			original.set_shader_parameter("local_shadow_rects", PackedVector4Array([Vector4(0, 0, 1, 1)]))
			original.set_shader_parameter("local_shadow_bias", PackedVector4Array([Vector4(0, 0, 0, 1)]))
			var blocked := await snapshot()
			assert(blocked.get_data() == unlit.get_data(), "E689 reversed-depth atlas did not block the rim light")
			depth_image.fill(Color(0, 0, 0))
			depth_texture.update(depth_image)
			var lit := await snapshot()
			assert(lit.get_data() != blocked.get_data(), "E689 reversed-depth atlas did not release the rim light")
			# Mode 1 must not switch to radial fallback when atlas strength is zero.
			original.set_shader_parameter("local_colors", PackedVector4Array([Vector4(2, 1, 0.5, 1)]))
			var mode_one_visible := await snapshot()
			depth_image.fill(Color(1, 0, 0))
			depth_texture.update(depth_image)
			original.set_shader_parameter("local_shadow_bias", PackedVector4Array([Vector4(0, 0, 0, 0)]))
			var zero_strength := await snapshot()
			assert(zero_strength.get_data() == mode_one_visible.get_data(), "Zero atlas strength must preserve full visibility in mode 1")
			original.set_shader_parameter("shadow_atlas_enabled", false)
			original.set_shader_parameter("local_light_count", 0)
			original.set_shader_parameter("main_energy", 1.6243867874)
			original.set_shader_parameter("environment_strength", 0.28772246837615967)
			counts[instance.name]["lighting_response"] = "SDF sides, AO, blackout, modes 0/1/3, shadow atlas passed"
		if instance.get_meta("capture_event") == 694 and clothes_surface and not albedo_only:
			var surface_material: ShaderMaterial = instance.material_override
			var views: Array[PackedByteArray] = []
			for view in range(5):
				surface_material.set_shader_parameter("surface_view", view)
				var surface_image := await snapshot()
				assert(not views.has(surface_image.get_data()), "E694 surface views must differ")
				views.append(surface_image.get_data())
				assert(surface_image.save_png(evidence.path_join("e694-scene-surface-%d.png" % view)) == OK)
			surface_material.set_shader_parameter("surface_view", 0)
			counts[instance.name]["surface_views"] = "base, world normal, parameters, F0, diffuse passed"
		instance.visible = false
	if live_lights and not albedo_only:
		var hair: MeshInstance3D
		for instance in instances:
			instance.visible = false
			if int(instance.get_meta("capture_event")) == 704:
				hair = instance
		var ao_test = preload("res://live_character_ao.gd").new()
		if not clothes_surface and not await ao_test.run_ao(self,instances,camera,environment.environment,evidence):
			quit(1)
			return
		var material_test = preload("res://live_material_shadows.gd").new()
		if not clothes_surface and not await material_test.run_materials(self,instances,camera,evidence):
			quit(1)
			return
		var live_test = preload("res://live_character.gd").new()
		if not await live_test.run(self,hair,camera,evidence,keep_open):
			quit(1)
			return
		if not clothes_surface:
			material_test.bind_scene(instances,live_test.scene_bridge)
			environment.environment.ssao_enabled = true
	for instance in instances:
		instance.visible = true
	var front := await snapshot()
	var prefix := "character-full-live" if live_lights and not albedo_only else "character-full-albedo" if albedo_only else ("character-full-clothes-surface" if clothes_surface else "character-full")
	assert(front.save_png(evidence.path_join(prefix + "-front.png")) == OK)
	camera.position = all_bounds.get_center() + Vector3(2, 0.3, 2)
	camera.look_at(all_bounds.get_center())
	var side := await snapshot()
	assert(side.save_png(evidence.path_join(prefix + "-three-quarter.png")) == OK)
	assert(front.get_data() != side.get_data())
	var report := {"parts": 8, "triangles": total_triangles, "isolated_pixels": counts,
		"mode": "live_e669_e689_e694_e704_shadows_ao" if live_lights and not albedo_only else "base_color_only" if albedo_only else ("e694_surface_diagnostics" if clothes_surface else "e669_e674_e689_e694_e704_lighting_plus_base_color_diagnostics"),
		"status": "passed", "scope": "Posed geometry/UV/texture integration, not full material parity"}
	FileAccess.open(evidence.path_join(prefix + "-validation.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("FULL_CHARACTER_OK " + JSON.stringify(report))
	if keep_open:
		var label := Label.new()
		label.text = "Captured posed mesh: 8 parts\n" + ("E669/E689/E694/E704 live shadows + screen AO" if live_lights and not albedo_only else "Base-color diagnostics only" if albedo_only else ("E674 + E689 + E704 lighting; E694 surface inspection" if clothes_surface else "E669 + E674 + E689 + E694 + E704 lighting; other parts: base color")) + "\nOther material variants are not yet reconstructed"
		label.position = Vector2(12, 12)
		root.add_child(label)
	else:
		quit(0)

func clothes_texture(id: int) -> ImageTexture:
	var bytes := FileAccess.get_file_as_bytes(evidence.path_join("e694-texture-%d.dds" % id))
	var payload := PackedByteArray()
	var levels := 12 if id in [187399,187402,187429] else (11 if id == 185914 else 1)
	for mip in range(levels):
		var data := bytes if mip == 0 else FileAccess.get_file_as_bytes(evidence.path_join("e694-texture-%d-mip%d.dds" % [id, mip]))
		assert(data.size() >= 128 and data.slice(0, 4).get_string_from_ascii() == "DDS ")
		payload.append_array(data.slice(148 if data.slice(84, 88).get_string_from_ascii() == "DX10" else 128))
	var image := Image.create_from_data(bytes.decode_u32(16), bytes.decode_u32(12), levels > 1,
		Image.FORMAT_RGTC_RG if id == 187429 else (Image.FORMAT_RGBA8 if id in [118829,39217] else Image.FORMAT_BPTC_RGBA), payload)
	assert(image != null and not image.is_empty())
	return ImageTexture.create_from_image(image)

func clothes_cube() -> Cubemap:
	var faces: Array[Image] = []
	for face in range(6):
		var payload := PackedByteArray()
		for mip in range(8):
			var bytes := FileAccess.get_file_as_bytes(evidence.path_join("e694-cube8600-face%d-mip%d.dds" % [face,mip]))
			assert(bytes.decode_u32(128) == 95)
			payload.append_array(bytes.slice(148))
		faces.append(Image.create_from_data(128,128,true,Image.FORMAT_BPTC_RGBFU,payload))
	var result := Cubemap.new()
	assert(result.create_from_images(faces) == OK)
	return result

func hair_texture(id: int) -> ImageTexture:
	var bytes := FileAccess.get_file_as_bytes(evidence.path_join("e704-texture-%d.dds" % id))
	var payload := PackedByteArray()
	var levels := 1 if id in [188148,186747] else (10 if id == 37600 else 11)
	for mip in range(levels):
		var data := bytes if mip == 0 else FileAccess.get_file_as_bytes(evidence.path_join("e704-texture-%d-mip%d.dds" % [id,mip]))
		assert(data.size() >= 128 and data.slice(0,4).get_string_from_ascii() == "DDS ")
		payload.append_array(data.slice(148 if data.slice(84,88).get_string_from_ascii() == "DX10" else 128))
	var image := Image.create_from_data(bytes.decode_u32(16),bytes.decode_u32(12),levels > 1,
		Image.FORMAT_RGBA8 if id in [188148,186747] else Image.FORMAT_BPTC_RGBA,payload)
	assert(image != null and not image.is_empty())
	return ImageTexture.create_from_image(image)

func skin_texture(id: int) -> Texture2D:
	var bytes := FileAccess.get_file_as_bytes(evidence.path_join("e669-texture-%d.dds" % id))
	var data := bytes.slice(148 if bytes.slice(84,88).get_string_from_ascii()=="DX10" else 128)
	for mip in range(1,11):
		var mip_bytes := FileAccess.get_file_as_bytes(evidence.path_join("e669-texture-%d-mip%d.dds" % [id,mip]))
		data.append_array(mip_bytes.slice(148 if mip_bytes.slice(84,88).get_string_from_ascii()=="DX10" else 128))
	return ImageTexture.create_from_image(Image.create_from_data(bytes.decode_u32(16),bytes.decode_u32(12),true,Image.FORMAT_BPTC_RGBA if id==185721 else Image.FORMAT_RGTC_RG,data))
