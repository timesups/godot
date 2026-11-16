extends SceneTree

# Independent visibility fixture: partial coverage exposes PCF/PCSS and split edges.
# Reference uses the ordinary light() ATTENUATION, including on stock Forward+.
var output := ""
var reference := false
var camera: Camera3D
var sun: DirectionalLight3D
var receiver: MeshInstance3D
var caster: MeshInstance3D
var records: Array = []

func _initialize() -> void:
	call_deferred("run")

func capture() -> Image:
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func sample_case(label: String, depth: float, gap: float = 1.0) -> void:
	camera.position = Vector3(0,0,depth)
	# Keep the physical shadow edge centered while varying blocker distance.
	caster.position = Vector3(-4.0+tan(deg_to_rad(20.0))*gap,0,gap)
	var img := await capture()
	if img.save_png(output.path_join(label+".png")) != OK:
		push_error("Could not save shadow quality evidence")
		quit(1)
		return
	records.append({"name":label,"depth":depth,"gap":gap,"mode":sun.directional_shadow_mode,
		"blend":sun.directional_shadow_blend_splits,"angle":sun.light_angular_distance,
		"opacity":sun.shadow_opacity,"normal_bias":sun.shadow_normal_bias})

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output=arg.trim_prefix("--output=")
		if arg=="--reference": reference=true
	if output.is_empty() or (not reference and RenderingServer.get_current_rendering_method()!="custom_forward"):
		push_error("Specify --output and use Custom Forward for character visibility")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	root.size=Vector2i(256,256)
	root.use_taa=false
	RenderingServer.directional_shadow_atlas_set_size(2048,false)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode=Environment.BG_COLOR
	env.background_color=Color.BLACK
	env.ambient_light_source=Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode=Environment.TONE_MAPPER_LINEAR
	env_node.environment=env
	root.add_child(env_node)
	camera=Camera3D.new()
	camera.fov=30.0
	camera.near=0.05
	camera.far=30.0
	root.add_child(camera)
	camera.current=true
	sun=DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(0,20,0)
	sun.shadow_enabled=true
	sun.shadow_bias=0.02
	sun.shadow_normal_bias=0.0
	sun.directional_shadow_max_distance=20.0
	sun.directional_shadow_split_1=0.2
	sun.directional_shadow_split_2=0.4
	sun.directional_shadow_split_3=0.6
	root.add_child(sun)
	receiver=MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size=Vector2(20,20)
	receiver.mesh=quad
	receiver.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	if reference:
		shader.code="shader_type spatial; render_mode ambient_light_disabled; void fragment(){ALBEDO=vec3(1.0); ROUGHNESS=1.0;} void light(){DIFFUSE_LIGHT=vec3(ATTENUATION);}"
	else:
		shader.code="shader_type spatial; render_mode custom_character,custom_character_shadows; uniform uint lo; uniform uint hi; void fragment(){EMISSION=vec3(custom_forward_directional_shadow(uvec2(lo,hi),VERTEX,NORMAL));}"
	mat.shader=shader
	var id := sun.get_light_rid().get_id()
	mat.set_shader_parameter("lo",id & 0xffffffff)
	mat.set_shader_parameter("hi",(id >> 32) & 0xffffffff)
	receiver.material_override=mat
	root.add_child(receiver)
	caster=MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size=Vector3(8,20,0.02)
	caster.mesh=box
	caster.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	root.add_child(caster)
	for mode in [0,1,2]:
		sun.directional_shadow_mode=mode
		for blend in [false,true]:
			sun.directional_shadow_blend_splits=blend
			for angle in [0.0,5.0]:
				sun.light_angular_distance=angle
				for depth in [3.98,4.0,4.02,7.98,8.0,8.02,11.98,12.0,12.02,18.0,19.0,21.0]:
					await sample_case("m%d_b%d_a%d_d%.2f" % [mode,int(blend),int(angle),depth],depth)
	sun.directional_shadow_mode=2
	sun.directional_shadow_blend_splits=true
	for quality in [RenderingServer.SHADOW_QUALITY_SOFT_LOW,RenderingServer.SHADOW_QUALITY_SOFT_HIGH]:
		RenderingServer.directional_soft_shadow_filter_set_quality(quality)
		for angle in [0.0,2.0,5.0]:
			sun.light_angular_distance=angle
			for gap in [0.5,2.0]:
				await sample_case("q%d_a%d_gap%.1f" % [quality,int(angle),gap],6.0,gap)
	await sample_case("stable_a",6.0,2.0)
	await sample_case("stable_b",6.0,2.0)
	sun.shadow_opacity=0.5
	await sample_case("half_opacity",6.0,2.0)
	sun.shadow_opacity=1.0
	sun.shadow_normal_bias=1.0
	await sample_case("normal_bias",6.0,2.0)
	FileAccess.open(output.path_join("cases.json"),FileAccess.WRITE).store_string(JSON.stringify(records,"\t"))
	print("DIRECTIONAL_SHADOW_QUALITY_CAPTURE_OK cases=%d reference=%s renderer=%s" % [records.size(),reference,RenderingServer.get_current_rendering_method()])
	quit(0)
