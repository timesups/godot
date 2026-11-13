extends SceneTree

class SpecularProbe extends CompositorEffect:
	var observed := false
	var mutex := Mutex.new()

	func _init() -> void:
		needs_separate_specular = true
		effect_callback_type = EFFECT_CALLBACK_TYPE_POST_OPAQUE

	func _render_callback(_type: int, data: RenderData) -> void:
		var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
		mutex.lock()
		observed = observed or buffers.has_texture(&"custom_forward", &"specular")
		mutex.unlock()

# Genuine scene rendering: captured posed geometry, no pixel mask or captured depth.
# Run from this test project with -- --evidence=<gbuffer-materials directory>.
var evidence := ""
var keep_open := false

func _initialize() -> void:
	call_deferred("run")

func vec3_at(bytes: PackedByteArray, offset: int) -> Vector3:
	return Vector3(bytes.decode_float(offset), bytes.decode_float(offset + 4), bytes.decode_float(offset + 8))

func captured_texture(name: String, format: Image.Format, levels: int = 1) -> ImageTexture:
	var bytes := FileAccess.get_file_as_bytes(evidence.path_join(name + ".dds"))
	assert(bytes.size() > 148)
	var header := 148 if bytes.slice(84, 88).get_string_from_ascii() == "DX10" else 128
	var data := bytes.slice(header)
	for mip in range(1, levels):
		data.append_array(FileAccess.get_file_as_bytes(evidence.path_join(name + "-mip%d.dds" % mip)).slice(148))
	var image := Image.create_from_data(bytes.decode_u32(16), bytes.decode_u32(12), levels > 1, format, data)
	assert(image != null and not image.is_empty())
	return ImageTexture.create_from_image(image)

func snapshot() -> Image:
	for frame in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence="):
			evidence = arg.trim_prefix("--evidence=")
		elif arg == "--keep-open":
			keep_open = true
	assert(not evidence.is_empty())
	assert(RenderingServer.get_current_rendering_method() == "custom_forward")
	assert(RenderingServer.get_rendering_device() != null)
	var directory := ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/custom_forward/materials")
	var code := FileAccess.get_file_as_string(directory.path_join("character.gdshader"))
	code = code.replace('#include "character_lighting.gdshaderinc"', FileAccess.get_file_as_string(directory.path_join("character_lighting.gdshaderinc")))
	var shader := Shader.new()
	shader.code = code
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("base_map", captured_texture("texture-185716", Image.FORMAT_BPTC_RGBA, 11))
	material.set_shader_parameter("material_lut", captured_texture("texture-172496", Image.FORMAT_BPTC_RGBA))
	material.set_shader_parameter("ramp_map", captured_texture("texture-186593", Image.FORMAT_RGBA8))
	material.set_shader_parameter("mip_bias", -1.0)
	material.set_shader_parameter("character_exposure", 1.05)

	var pose := FileAccess.get_file_as_bytes(evidence.path_join("e674-record0-transform.bin"))
	var basis := Basis(vec3_at(pose, 0), vec3_at(pose, 16), vec3_at(pose, 32)).transposed()
	var origin := Vector3(pose.decode_float(12), pose.decode_float(28), pose.decode_float(44))
	var transform := Transform3D(basis, origin)
	var inverse := transform.affine_inverse()
	var data := FileAccess.get_file_as_bytes(evidence.path_join("e674-postvs-vertex.bin"))
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	assert(data.size() == 398 * 128)
	for i in 398:
		vertices.append(inverse * vec3_at(data, i * 128 + 32))
		normals.append((basis.inverse() * vec3_at(data, i * 128 + 48)).normalized())
		uvs.append(Vector2(data.decode_float(i * 128 + 16), data.decode_float(i * 128 + 20)))
	var index_data := FileAccess.get_file_as_bytes(evidence.path_join("e674-postvs-index.bin"))
	var indices := PackedInt32Array()
	assert(index_data.size() == 1356 * 2)
	for i in 1356:
		indices.append(index_data.decode_u16(i * 2))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.transform = transform
	root.add_child(instance)
	var camera := Camera3D.new()
	root.add_child(camera)
	var center := transform * mesh.get_aabb().get_center()
	camera.position = center + Vector3(0, 0, 0.22)
	camera.near = 0.001
	camera.look_at(center)
	camera.make_current()
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color.BLACK
	env.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	root.add_child(env)

	var baseline := await snapshot()
	assert(baseline.save_png(evidence.path_join("character-scene.png")) == OK)
	var probe := SpecularProbe.new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [probe]
	env.compositor = compositor
	var separated := await snapshot()
	probe.mutex.lock()
	var specular_observed := probe.observed
	probe.mutex.unlock()
	assert(specular_observed, "Separate-specular render target was not exercised")
	assert(separated.get_data() == baseline.get_data(), "Character output changed in the separate-specular pass")
	env.compositor = null
	material.set_shader_parameter("main_color", Vector3.ZERO)
	material.set_shader_parameter("environment_strength", 0.0)
	var dark := await snapshot()
	var lit_pixels := 0
	var dark_max := 0.0
	for y in baseline.get_height():
		for x in baseline.get_width():
			var c := baseline.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) > 0.05:
				lit_pixels += 1
			var d := dark.get_pixel(x, y)
			dark_max = maxf(dark_max, maxf(d.r, maxf(d.g, d.b)))
	assert(lit_pixels > 100, "Captured scene geometry did not render")
	assert(dark_max < 0.01, "Character path must use its own lighting, not ALBEDO or stock lighting")
	material.set_shader_parameter("local_light_count", 1)
	material.set_shader_parameter("local_positions", PackedVector4Array([Vector4(center.x, center.y, center.z + 0.1, 1.0)]))
	material.set_shader_parameter("local_colors", PackedVector4Array([Vector4(2, 1, 0.5, 0)]))
	material.set_shader_parameter("local_parameters", PackedVector4Array([Vector4(1, 1, 1, 0)]))
	var local := await snapshot()
	assert(local.get_data() != dark.get_data(), "Mode 0 point light did not affect the character")
	material.set_shader_parameter("local_colors", PackedVector4Array([Vector4(2, 1, 0.5, 1)]))
	var mode_one := await snapshot()
	assert(mode_one.get_data() != dark.get_data(), "Mode 1 point light did not affect the character")
	assert(mode_one.get_data() != local.get_data(), "Local light modes must remain distinct")
	print("CHARACTER_SCENE_OK vertices=398 triangles=452 lit_pixels=%d dark_max=%f modes=0,1 separate_specular=identical" % [lit_pixels, dark_max])
	if keep_open:
		material.set_shader_parameter("local_light_count", 0)
		material.set_shader_parameter("main_color", Vector3.ONE * 1.6243867874)
		material.set_shader_parameter("environment_strength", 0.28772246837615967)
	else:
		quit(0)
