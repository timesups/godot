extends SceneTree

# Run with a real display driver; --headless would only test the dummy renderer.
class BufferProbe extends CompositorEffect:
	var scope: StringName
	var calls := 0
	var buffers_valid := true
	var post_expected := false
	var mutex := Mutex.new()

	func _init(buffer_scope: StringName) -> void:
		scope = buffer_scope
		effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
		needs_normal_roughness = true
		needs_motion_vectors = true
		access_resolved_color = true
		access_resolved_depth = true

	func _render_callback(_callback_type: int, data: RenderData) -> void:
		var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
		var valid := buffers != null
		if valid:
			valid = buffers.get_color_texture().is_valid() \
				and buffers.get_depth_texture().is_valid() \
				and buffers.get_velocity_texture().is_valid() \
				and buffers.has_texture(scope, &"normal_roughness")
			if post_expected and calls > 2:
				valid = valid and buffers.has_texture(&"custom_post_process", &"up_0")
		mutex.lock()
		calls += 1
		buffers_valid = buffers_valid and valid
		mutex.unlock()

var probe: BufferProbe
var frame := 0
var rendering_method: String
var test_case := "baseline"
var output := ""
var post_lut := ""
var post_pack := ""
var keep_open := false

func _initialize() -> void:
	call_deferred("setup")

func setup() -> void:
	rendering_method = RenderingServer.get_current_rendering_method()
	if rendering_method not in ["forward_plus", "custom_forward"] or RenderingServer.get_rendering_device() == null:
		push_error("This test requires Forward+ or Custom Forward on a real GPU.")
		quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--case="):
			test_case = arg.trim_prefix("--case=")
		elif arg.begins_with("--output="):
			output = arg.trim_prefix("--output=")
		elif arg.begins_with("--post-lut="):
			post_lut = arg.trim_prefix("--post-lut=")
		elif arg.begins_with("--post-pack="):
			post_pack = arg.trim_prefix("--post-pack=")
		elif arg == "--keep-open":
			keep_open = true
	if not post_pack.is_empty():
		if not ProjectSettings.load_resource_pack(post_pack):
			push_error("Could not load the packaged LUT.")
			quit(1)
			return
	if not post_lut.is_empty():
		ProjectSettings.set_setting("rendering/custom_forward/post_process/lut_path", post_lut)
		ProjectSettings.set_setting("rendering/custom_forward/post_process/enabled", true)
	root.use_taa = test_case == "taa"
	root.msaa_3d = Viewport.MSAA_4X if test_case == "msaa" else Viewport.MSAA_DISABLED
	if test_case == "fsr2":
		root.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	if root.use_taa != (test_case == "taa"):
		push_error("TAA was rejected by the renderer.")
		quit(1)
		return

	var world := Node3D.new()
	root.add_child(world)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.08, 0.12, 0.2)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.5, 0.55, 0.65)
	environment.ambient_light_energy = 0.4
	environment.ssao_enabled = true
	environment.ssil_enabled = true
	environment.ssr_enabled = true
	environment.volumetric_fog_enabled = true
	environment.volumetric_fog_density = 0.01
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	probe = BufferProbe.new(&"custom_forward" if rendering_method == "custom_forward" else &"forward_clustered")
	probe.post_expected = not post_lut.is_empty() and rendering_method == "custom_forward" and test_case != "fsr2"
	var compositor := Compositor.new()
	compositor.compositor_effects = [probe]
	world_environment.compositor = compositor
	world.add_child(world_environment)

	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(3, 2.5, 5)
	camera.look_at(Vector3(0, 0.4, 0))
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -30, 0)
	light.shadow_enabled = true
	world.add_child(light)

	var ground := MeshInstance3D.new()
	ground.mesh = PlaneMesh.new()
	ground.mesh.size = Vector2(10, 10)
	world.add_child(ground)
	var sphere := MeshInstance3D.new()
	sphere.mesh = SphereMesh.new()
	sphere.position.y = 1.0
	world.add_child(sphere)
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	# Both renderers must preserve existing Forward+ material shader branches.
	material.shader.code = """
shader_type spatial;
void fragment() {
#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
	ALBEDO = vec3(0.7, 0.15, 0.05);
#else
	ALBEDO = vec3(0.0, 1.0, 0.0);
#endif
	ROUGHNESS = 0.35;
	METALLIC = 0.25;
}
"""
	sphere.material_override = material
	var transparent := MeshInstance3D.new()
	transparent.mesh = BoxMesh.new()
	transparent.position = Vector3(1.2, 0.5, 0)
	var glass := StandardMaterial3D.new()
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.albedo_color = Color(0.2, 0.5, 0.9, 0.5)
	transparent.material_override = glass
	world.add_child(transparent)

func _process(_delta: float) -> bool:
	if probe == null:
		return false
	frame += 1
	if frame == 120:
		finish.call_deferred()
	return false

func finish() -> void:
	await RenderingServer.frame_post_draw
	probe.mutex.lock()
	var valid := probe.buffers_valid and probe.calls > 0
	var calls := probe.calls
	probe.mutex.unlock()
	if not valid:
		push_error("Compositor callback or required render buffers are missing.")
		quit(1)
		return
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("Rendered image is empty.")
		quit(1)
		return
	if not output.is_empty() and image.save_png(output) != OK:
		push_error("Could not save rendered image.")
		quit(1)
		return
	print("RENDER_SMOKE_OK renderer=%s case=%s compositor_calls=%d" % [rendering_method, test_case, calls])
	if not keep_open:
		quit()
