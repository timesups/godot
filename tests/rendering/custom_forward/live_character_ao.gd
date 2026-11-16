extends "res://live_character.gd"

func material_variant(source: ShaderMaterial, event: int) -> ShaderMaterial:
	var material := source.duplicate() as ShaderMaterial
	var shader := Shader.new()
	shader.code = ("#define HAIR_REALTIME_DEPTH\n" if event==704 else "#define CHARACTER_ENGINE_SHADOWS\n") + source.shader.code
	material.shader = shader
	return material

func run_ao(tree: SceneTree, instances: Array, camera: Camera3D, environment: Environment, evidence: String) -> bool:
	var old_transform := camera.transform
	var old_projection := camera.projection
	var old_camera_size := camera.size
	var old_size := tree.root.size
	var old_msaa := tree.root.msaa_3d
	var old_scale := tree.root.scaling_3d_scale
	var old_enabled := environment.ssao_enabled
	var old_radius := environment.ssao_radius
	var old_intensity := environment.ssao_intensity
	var old_power := environment.ssao_power
	environment.ssao_enabled = true
	environment.ssao_radius = 0.8
	environment.ssao_intensity = 2.0
	environment.ssao_power = 1.5
	var blocker := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.5,2,0.5)
	blocker.mesh = box
	blocker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var black := StandardMaterial3D.new()
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	black.albedo_color = Color.BLACK
	blocker.material_override = black
	tree.root.add_child(blocker)
	var report := {}
	for instance in instances:
		var event := int(instance.get_meta("capture_event"))
		if event not in [669,684,689,694,699,704]:
			continue
		var patch := MeshInstance3D.new()
		patch.mesh = QuadMesh.new()
		patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := material_variant(instance.material_override,event)
		patch.material_override = material
		material.set_shader_parameter("local_light_count",0)
		tree.root.add_child(patch)
		var cases := {}
		for mode in ["orthogonal","perspective","msaa4","resized","scaled"]:
			tree.root.scaling_3d_scale = 0.75 if mode=="scaled" else 1.0
			camera.position = Vector3(0,0,3)
			camera.look_at(Vector3.ZERO)
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL if mode=="orthogonal" else Camera3D.PROJECTION_PERSPECTIVE
			camera.size = 2
			tree.root.msaa_3d = Viewport.MSAA_4X if mode=="msaa4" else Viewport.MSAA_DISABLED
			tree.root.size = Vector2i(320,240) if mode=="resized" else Vector2i(256,256)
			if mode=="resized":
				camera.position = Vector3(0.1,0.05,2.8)
				camera.look_at(Vector3.ZERO)
			blocker.position = Vector3(0.65,0,0.2)
			material.set_shader_parameter("engine_screen_ao_enabled",false)
			var off_image := await capture(tree)
			var off := energy(off_image)
			material.set_shader_parameter("engine_screen_ao_enabled",true)
			var on_image := await capture(tree)
			var on := energy(on_image)
			if not check(off>1 and on<off*0.999,"E%d AO contact failed %s on=%f off=%f" % [event,mode,on,off]):
				return false
			on_image.save_png(evidence.path_join("e%d-live-ao-%s.png" % [event,mode]))
			environment.ssao_enabled = false
			var environment_off := await capture(tree)
			if not check(environment_off.get_data()==off_image.get_data(),"Disabled SSAO sampled stale buffer E%d %s" % [event,mode]):
				return false
			environment.ssao_enabled = true
			blocker.position.x = 3
			var moved := energy(await capture(tree))
			material.set_shader_parameter("engine_screen_ao_enabled",false)
			var moved_off := energy(await capture(tree))
			material.set_shader_parameter("engine_screen_ao_enabled",true)
			if not check(absf(moved-moved_off)<moved_off*0.005,"Moving AO blocker did not release contact"):
				return false
			cases[mode] = {"on":on,"off":off,"moved":moved,"moved_off":moved_off}
		tree.root.scaling_3d_scale = 1.0
		# The stronger manual AO wins. Multiplication would double-darken it.
		blocker.position = Vector3(0.65,0,0.2)
		material.set_shader_parameter("face_ao",0.01)
		material.set_shader_parameter("screen_shadow_ao",Vector2(0.4,0.01))
		material.set_shader_parameter("engine_screen_ao_enabled",true)
		var combined := await capture(tree)
		material.set_shader_parameter("engine_screen_ao_enabled",false)
		var manual := await capture(tree)
		if not check(combined.get_data()==manual.get_data(),"E%d AO multiplied into manual AO or main shadow" % event):
			return false
		# Inspect independent inputs with an actual half-opacity main shadow.
		var sun := DirectionalLight3D.new()
		tree.root.add_child(sun)
		sun.rotation_degrees.y = 45
		sun.shadow_enabled = true
		sun.shadow_opacity = 0.5
		sun.directional_shadow_max_distance = 20
		var caster := MeshInstance3D.new()
		var caster_box := BoxMesh.new()
		caster_box.size = Vector3(8,8,0.5)
		caster.mesh = caster_box
		caster.position = Vector3(1,0,1)
		caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		tree.root.add_child(caster)
		var light_id := sun.get_light_rid().get_id()
		material.set_shader_parameter("main_shadow_id_low",light_id & 0xffffffff)
		material.set_shader_parameter("main_shadow_id_high",(light_id >> 32) & 0xffffffff)
		material.set_shader_parameter("face_ao",1.0)
		material.set_shader_parameter("screen_shadow_ao",Vector2.ONE)
		var lighting_shader := material.shader
		var inputs_shader := Shader.new()
		var inputs := "vec3(main_visibility,screen_ao,face_ndl*0.5+0.5)" if event==689 else "vec3(main_screen,0.0)"
		inputs_shader.code = lighting_shader.code.replace("EMISSION = result;","EMISSION = "+inputs+";")
		material.shader = inputs_shader
		material.set_shader_parameter("engine_screen_ao_enabled",true)
		var inputs_on := await capture(tree)
		material.set_shader_parameter("engine_screen_ao_enabled",false)
		var inputs_off := await capture(tree)
		var green_on := 0.0
		var green_off := 0.0
		for y in inputs_on.get_height():
			for x in inputs_on.get_width():
				var a := inputs_on.get_pixel(x,y)
				var b := inputs_off.get_pixel(x,y)
				if not check(a.r==b.r and a.b==b.b,"AO changed main visibility or face SDF"):
					return false
				green_on += a.g
				green_off += b.g
		if not check(green_on<green_off*0.99,"AO independence diagnostic had no contact"):
			return false
		material.set_shader_parameter("engine_directional_shadows_enabled",false)
		var shadow_off := await capture(tree)
		if not check(shadow_off.get_data()!=inputs_off.get_data(),"AO independence test had no engine main shadow"):
			return false
		sun.free()
		caster.free()
		material.shader = lighting_shader
		# Read the engine AO directly using the same pass as the real material.
		var diagnostic := Shader.new()
		diagnostic.code = material.shader.code.replace("EMISSION = result;","EMISSION = vec3(custom_forward_screen_ao(SCREEN_UV));")
		material.shader = diagnostic
		var raw_contact := energy(await capture(tree))
		environment.ssao_enabled = false
		var raw_clear := energy(await capture(tree))
		environment.ssao_enabled = true
		if not check(raw_contact<raw_clear*0.99,"Raw screen AO missing in material pass"):
			return false
		report[str(event)] = {"cases":cases,"manual_min_exact":true,"main_shadow_sdf_independent":true,"raw_contact":raw_contact,"raw_clear":raw_clear}
		patch.free()
	blocker.free()
	camera.transform = old_transform
	camera.projection = old_projection
	camera.size = old_camera_size
	tree.root.size = old_size
	tree.root.msaa_3d = old_msaa
	tree.root.scaling_3d_scale = old_scale
	environment.ssao_enabled = old_enabled
	environment.ssao_radius = old_radius
	environment.ssao_intensity = old_intensity
	environment.ssao_power = old_power
	FileAccess.open(evidence.path_join("character-screen-ao-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("CHARACTER_SCREEN_AO_OK "+JSON.stringify(report))
	return true
