extends SceneTree

# Material reconstruction is intentionally per draw. Unverified variants show
# base color only; E674 and E689 use their separate reconstructed materials.
var evidence := ""
var keep_open := false
var albedo_only := false
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
		if event in [674, 689]:
			var pose := FileAccess.get_file_as_bytes(evidence.path_join("e%d-record0-transform.bin" % event))
			placement = Transform3D(Basis(v3(pose, 0), v3(pose, 16), v3(pose, 32)).transposed(),
				Vector3(pose.decode_float(12), pose.decode_float(28), pose.decode_float(44)) - origin)
		var inverse := placement.affine_inverse()
		var vb := FileAccess.get_file_as_bytes(evidence.path_join("e%d-postvs-vertex.bin" % event))
		var ib := FileAccess.get_file_as_bytes(evidence.path_join("e%d-postvs-index.bin" % event))
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()
		for i in int(part.vertex_count):
			var offset := int(part.vertex_offset) + i * int(part.vertex_stride)
			vertices.append(inverse * (v3(vb, offset + 32) - origin))
			normals.append((placement.basis.inverse() * v3(vb, offset + 48)).normalized())
			uvs.append(Vector2(vb.decode_float(offset + 16), vb.decode_float(offset + 20)))
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
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := ShaderMaterial.new()
		material.shader = (validated if event == 674 else face_shader) if event in [674, 689] and not albedo_only else diagnostic
		var base_texture := texture(int(part.base_texture))
		assert(base_texture != null)
		material.set_shader_parameter("base_map", base_texture)
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
			original.set_shader_parameter("local_light_count", 0)
			original.set_shader_parameter("main_energy", 1.6243867874)
			original.set_shader_parameter("environment_strength", 0.28772246837615967)
			counts[instance.name]["lighting_response"] = "SDF sides, AO, blackout, modes 0/1/3 passed"
		instance.visible = false
	for instance in instances:
		instance.visible = true
	var front := await snapshot()
	var prefix := "character-full-albedo" if albedo_only else "character-full"
	assert(front.save_png(evidence.path_join(prefix + "-front.png")) == OK)
	camera.position = all_bounds.get_center() + Vector3(2, 0.3, 2)
	camera.look_at(all_bounds.get_center())
	var side := await snapshot()
	assert(side.save_png(evidence.path_join(prefix + "-three-quarter.png")) == OK)
	assert(front.get_data() != side.get_data())
	var report := {"parts": 8, "triangles": total_triangles, "isolated_pixels": counts,
		"mode": "base_color_only" if albedo_only else "e674_and_e689_plus_base_color_diagnostics",
		"status": "passed", "scope": "Posed geometry/UV/texture integration, not full material parity"}
	FileAccess.open(evidence.path_join(prefix + "-validation.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("FULL_CHARACTER_OK " + JSON.stringify(report))
	if keep_open:
		var label := Label.new()
		label.text = "Captured posed mesh: 8 parts\n" + ("Base-color diagnostics only" if albedo_only else "E674 + E689 lighting; other parts: base color") + "\nOther material variants are not yet reconstructed"
		label.position = Vector2(12, 12)
		root.add_child(label)
	else:
		quit(0)
