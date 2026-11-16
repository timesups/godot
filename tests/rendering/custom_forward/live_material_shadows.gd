extends "res://live_character.gd"

func live_material(source: ShaderMaterial) -> ShaderMaterial:
	var material := source.duplicate() as ShaderMaterial
	var shader := Shader.new()
	shader.code = "#define CHARACTER_ENGINE_SHADOWS\n" + source.shader.code
	material.shader = shader
	return material

func bind_scene(instances: Array, shared: Node) -> void:
	for instance in instances:
		var event := int(instance.get_meta("capture_event"))
		if event not in [669,679,684,689,694]:
			continue
		instance.material_override = live_material(instance.material_override)
		var bridge = shared.get_script().new()
		bridge.target = instance
		bridge.face_layout = event == 689
		bridge.main_light = shared.main_light
		bridge.local_lights = shared.local_lights
		shared.get_parent().add_child(bridge)

func run_materials(tree: SceneTree, instances: Array, camera: Camera3D, evidence: String) -> bool:
	var old_transform := camera.transform
	var old_projection := camera.projection
	var old_size := camera.size
	var old_viewport := tree.root.size
	camera.position = Vector3(0,0,3)
	camera.look_at(Vector3.ZERO)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	tree.root.size = Vector2i(256,256)
	var script := GDScript.new()
	script.source_code = FileAccess.get_file_as_string("res://../../../servers/rendering/renderer_rd/custom_forward/materials/character_light_binding.gd")
	if not check(script.reload()==OK,"Material light bridge failed"):
		return false
	var report := {}
	for instance in instances:
		var event := int(instance.get_meta("capture_event"))
		if event not in [669,679,684,689,694]:
			continue
		var patch := MeshInstance3D.new()
		patch.mesh = QuadMesh.new()
		patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := live_material(instance.material_override)
		patch.material_override = material
		tree.root.add_child(patch)
		material.set_shader_parameter("environment_strength",0.0)
		material.set_shader_parameter("ambient_exposure",0.0)
		material.set_shader_parameter("emission_strength",0.0)
		material.set_shader_parameter("reflection_strength",0.0)
		var bridge = script.new()
		bridge.target = patch
		bridge.face_layout = event == 689
		tree.root.add_child(bridge)
		var sun := DirectionalLight3D.new()
		tree.root.add_child(sun)
		sun.rotation_degrees.y = 45
		sun.shadow_enabled = true
		sun.shadow_normal_bias = 0
		bridge.main_light = sun
		var caster := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(8,8,0.5)
		caster.mesh = box
		caster.position = Vector3(1,0,1)
		caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		tree.root.add_child(caster)
		caster.hide()
		var lit_image := await capture(tree)
		var lit := energy(lit_image)
		var engine_shader := material.shader
		material.shader = instance.material_override.shader
		var captured_path := await capture(tree)
		material.shader = engine_shader
		if not check(lit_image.get_data()==captured_path.get_data(),"Unoccluded live material changed captured shading"):
			return false
		caster.show()
		var blocked_image := await capture(tree)
		var blocked := energy(blocked_image)
		blocked_image.save_png(evidence.path_join("e%d-engine-directional-blocked.png" % event))
		if not check(lit>1 and blocked<lit*0.01,"E%d directional shadow failed %f/%f" % [event,blocked,lit]):
			return false
		sun.shadow_opacity = 0
		var zero := energy(await capture(tree))
		sun.shadow_opacity = 1
		sun.shadow_enabled = false
		var disabled := energy(await capture(tree))
		sun.shadow_enabled = true
		caster.position.x = 20
		var moved := energy(await capture(tree))
		caster.position.x = 1
		if not check(absf(zero-lit)<lit*0.02 and absf(disabled-lit)<lit*0.02 and absf(moved-lit)<lit*0.02,"E%d directional release failed" % event):
			return false
		if event == 689:
			# Half opacity must equal half direct light, not its square; SDF stays
			# in the ramp. Exercise both SDF orientations and preserve environment.
			for angle in [-45,45]:
				sun.rotation_degrees.y = angle
				sun.shadow_opacity = 0.5
				var half_shadow := await capture(tree)
				sun.shadow_opacity = 0
				sun.light_energy = 0.5
				var half_light := await capture(tree)
				if not check(half_shadow.get_data()==half_light.get_data(),"Face SDF/directional visibility applied twice"):
					return false
				sun.light_energy = 1
			material.set_shader_parameter("environment_strength",0.4)
			sun.shadow_opacity = 1
			var ambient_shadow := await capture(tree)
			sun.light_energy = 0
			var ambient_only := await capture(tree)
			if not check(energy(ambient_only)>1 and ambient_shadow.get_data()==ambient_only.get_data(),"Face main shadow darkened environment"):
				return false
			material.set_shader_parameter("environment_strength",0.0)
		if event == 694:
			# Emission stays outside the main shadow path.
			material.set_shader_parameter("emission_strength",2.0)
			var shadow_emission := await capture(tree)
			sun.light_energy = 0
			var emission_only := await capture(tree)
			if not check(energy(emission_only)>1 and shadow_emission.get_data()==emission_only.get_data(),"Clothes main shadow attenuated emission"):
				return false
			material.set_shader_parameter("emission_strength",0.0)
		sun.free()
		var local_report := {}
		for kind in ["omni","spot"]:
			var light: Light3D = OmniLight3D.new() if kind=="omni" else SpotLight3D.new()
			tree.root.add_child(light)
			light.position = Vector3(2,0,2)
			light.look_at(Vector3.ZERO)
			light.set_param(Light3D.PARAM_RANGE,8)
			light.light_energy = 5
			light.shadow_enabled = true
			light.shadow_normal_bias = 0
			bridge.local_lights = [light] as Array[Light3D]
			for mode in ([0,1,3] if event==689 else [0,1,3,4]):
				patch.rotation_degrees.y = 20 if mode==3 else 0
				light.set_meta("character_mode",mode)
				# A nonzero shadow-side floor and forced face SDF highlight must
				# not bypass engine visibility in mode 1.
				light.set_meta("character_parameters",Vector4(4,0.5,1,2))
				caster.hide()
				var visible := await capture(tree)
				caster.show()
				var occluded := await capture(tree)
				var v := energy(visible)
				var o := energy(occluded)
				if event==679 and mode==3:
					if not check(v==0 and o==0,"E679 captured mode 3 must remain zero"):
						return false
					local_report[kind+str(mode)] = {"visible":v,"blocked":o}
					continue
				if not check(v>1 and (visible.get_data()==occluded.get_data() if mode in [0,4] else o<v*0.01),"E%d %s mode %d shadow failed %f/%f" % [event,kind,mode,o,v]):
					return false
				local_report[kind+str(mode)] = {"visible":v,"blocked":o}
				light.shadow_opacity = 0
				var released := energy(await capture(tree))
				light.shadow_opacity = 1
				if not check(absf(released-v)<v*0.02,"Local zero-opacity failed"):
					return false
				light.shadow_enabled = false
				var no_shadow := energy(await capture(tree))
				light.shadow_enabled = true
				if not check(absf(no_shadow-v)<v*0.02,"Local disabled shadow failed"):
					return false
			# Coincident second light has an independent RID and no shadow.
			light.set_meta("character_mode",1)
			patch.rotation = Vector3.ZERO
			caster.hide()
			var identity_visible := energy(await capture(tree))
			caster.show()
			var other: Light3D = OmniLight3D.new() if kind=="omni" else SpotLight3D.new()
			tree.root.add_child(other)
			other.transform = light.transform
			other.set_param(Light3D.PARAM_RANGE,8)
			other.light_energy = 5
			other.set_meta("character_mode",1)
			other.set_meta("character_parameters",Vector4(4,0.5,1,2))
			bridge.local_lights = [other] as Array[Light3D]
			var identity := energy(await capture(tree))
			if not check(absf(identity-identity_visible)<identity_visible*0.02,"Material shadow RID alias"):
				return false
			other.free()
			light.free()
		patch.rotation = Vector3.ZERO
		# Layout-specific cap, mode 4 rejection on face, hiding and freed lights.
		var many: Array[Light3D] = []
		for i in 17:
			var light := OmniLight3D.new()
			tree.root.add_child(light)
			many.append(light)
		bridge.local_lights = many
		await capture(tree)
		if not check(material.get_shader_parameter("local_light_count")== (8 if event==689 else 16),"Material light cap failed"):
			return false
		if event==689:
			for light in many:
				light.set_meta("character_mode",4)
			await capture(tree)
			if not check(material.get_shader_parameter("local_light_count")==0,"Face accepted unsupported mode 4"):
				return false
		for light in many:
			light.free()
		await capture(tree)
		if not check(material.get_shader_parameter("local_light_count")==0,"Deleted material lights left stale slots"):
			return false
		report[str(event)] = {"directional_visible":lit,"directional_blocked":blocked,"local":local_report,"unoccluded_capture_match":true,"face_sdf_half_visibility_and_ambient":event==689,"clothes_emission_preserved":event==694}
		bridge.free()
		caster.free()
		patch.free()
	camera.transform = old_transform
	camera.projection = old_projection
	camera.size = old_size
	tree.root.size = old_viewport
	FileAccess.open(evidence.path_join("face-clothes-engine-shadow-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("FACE_CLOTHES_ENGINE_SHADOWS_OK "+JSON.stringify(report))
	return true
