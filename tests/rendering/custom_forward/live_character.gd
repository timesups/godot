extends RefCounted

var failure := ""
var scene_bridge: Node

func check(condition: bool, message: String) -> bool:
	if not condition:
		failure = message
		push_error(message)
	return condition

func capture(tree: SceneTree) -> Image:
	for i in 5:
		await tree.process_frame
	await RenderingServer.frame_post_draw
	return tree.root.get_texture().get_image()

func energy(image: Image) -> float:
	var total := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x,y)
			total += c.r+c.g+c.b
	return total

func run(tree: SceneTree, hair: MeshInstance3D, camera: Camera3D, evidence: String, keep_open: bool) -> bool:
	var directory := ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/custom_forward/materials")
	var binding_script := GDScript.new()
	binding_script.source_code = FileAccess.get_file_as_string(directory.path_join("character_light_binding.gd"))
	if not check(binding_script.reload() == OK, "Light bridge failed to compile"):
		return false
	var source := hair.material_override as ShaderMaterial
	var material := source.duplicate() as ShaderMaterial
	var shader := Shader.new()
	shader.code = "#define HAIR_REALTIME_DEPTH\n"+source.shader.code
	material.shader = shader
	material.set_shader_parameter("main_energy",0.0)
	material.set_shader_parameter("environment_strength",0.0)
	material.set_shader_parameter("ambient_exposure",0.0)
	material.set_shader_parameter("local_rim_visibility",PackedFloat32Array([0.0]))
	var patch := MeshInstance3D.new()
	patch.mesh = QuadMesh.new()
	patch.material_override = material
	tree.root.add_child(patch)
	var blocker := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(8,8)
	blocker.mesh = quad
	var black := ShaderMaterial.new()
	var black_shader := Shader.new()
	black_shader.code = "shader_type spatial; render_mode custom_character; void fragment(){EMISSION=vec3(0.0);}"
	black.shader = black_shader
	blocker.material_override = black
	tree.root.add_child(blocker)
	var light := OmniLight3D.new()
	tree.root.add_child(light)
	light.position = Vector3(2,0,2)
	light.omni_range = 8.0
	light.light_energy = 5.0
	light.set_meta("character_mode",3)
	light.set_meta("character_parameters",Vector4(4,0.5,0,0))
	var bridge = binding_script.new()
	scene_bridge = bridge
	bridge.target = patch
	bridge.local_lights = [light] as Array[Light3D]
	tree.root.add_child(bridge)
	var old_size := tree.root.size
	var old_transform := camera.transform
	var old_projection := camera.projection
	var old_camera_size := camera.size
	camera.position = Vector3(0,0,3)
	camera.look_at(Vector3.ZERO)
	camera.size = 2.0
	tree.root.size = Vector2i(320,320)
	var report := {}
	for mode in ["orthogonal","perspective","msaa4","resized"]:
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL if mode == "orthogonal" else Camera3D.PROJECTION_PERSPECTIVE
		tree.root.msaa_3d = Viewport.MSAA_4X if mode == "msaa4" else Viewport.MSAA_DISABLED
		if mode == "resized":
			tree.root.size = Vector2i(400,280)
			camera.position = Vector3(0.1,0.05,3.3)
			camera.look_at(Vector3.ZERO)
		blocker.position.z = -0.03
		var near_image := await capture(tree)
		blocker.position.z = -0.6
		var far_image := await capture(tree)
		var near_energy := energy(near_image)
		var far_energy := energy(far_image)
		if not check(near_energy < 0.01 and far_energy > 1.0,"Live depth rim failed: %s near=%f far=%f" % [mode,near_energy,far_energy]):
			return false
		# The hair itself must be present in copied depth: its interior stays dark.
		var center := far_image.get_region(Rect2i(far_image.get_width()*9/20,far_image.get_height()*9/20,
			far_image.get_width()/10,far_image.get_height()/10))
		if not check(energy(center)<0.01,"Hair self-depth missing: "+mode):
			return false
		report[mode] = {"near":near_energy,"far":far_energy,"interior":energy(center)}
		far_image.save_png(evidence.path_join("hair-live-rim-%s.png" % mode))
	# An upward view normal must reveal the TOP edge, not the bottom edge.
	# Total RGB alone cannot catch a screen-UV Y inversion.
	var original_normal: Texture2D = material.get_shader_parameter("normal_map")
	var normal_image := Image.create(2,2,false,Image.FORMAT_RGBAF)
	normal_image.fill(Color(0.5,0.9,0.5,0.9))
	material.set_shader_parameter("normal_map",ImageTexture.create_from_image(normal_image))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.position = Vector3(0,0,3)
	camera.look_at(Vector3.ZERO)
	tree.root.size = Vector2i(320,320)
	light.position = Vector3(0,2,2)
	var upward := await capture(tree)
	var top_energy := energy(upward.get_region(Rect2i(0,0,320,160)))
	var bottom_energy := energy(upward.get_region(Rect2i(0,160,320,160)))
	upward.save_png(evidence.path_join("hair-live-rim-upward.png"))
	if not check(top_energy>1.0 and bottom_energy<0.01,
		"View-to-screen rim Y inverted: top=%f bottom=%f" % [top_energy,bottom_energy]):
		return false
	report["upward_normal"] = {"top":top_energy,"bottom":bottom_energy}
	material.set_shader_parameter("normal_map",original_normal)
	light.position = Vector3(2,0,2)
	# Manual zero mask is the fallback only: disabling real depth removes the rim.
	material.set_shader_parameter("realtime_rim_enabled",false)
	if not check(energy(await capture(tree)) < 0.01,"Manual zero rim fallback failed"):
		return false
	material.set_shader_parameter("realtime_rim_enabled",true)
	light.hide()
	if not check(energy(await capture(tree)) < 0.01,"Hidden Light3D left stale lighting"):
		return false
	light.show()
	light.light_cull_mask = 2
	if not check(energy(await capture(tree)) < 0.01,"Light cull mask ignored"):
		return false
	light.light_cull_mask = 1
	light.set_meta("character_mode",0)
	var initial := await capture(tree)
	light.position = Vector3(-2,1,2)
	var moved := await capture(tree)
	if not check(initial.get_data() != moved.get_data(),"Moving OmniLight3D did not update lighting"):
		return false
	light.light_color = Color(0.25,0.5,1.0)
	var recolored := await capture(tree)
	if not check(recolored.get_data()!=moved.get_data(),"Light color did not update"):
		return false
	light.distance_fade_enabled = true
	light.distance_fade_begin = 0.0
	light.distance_fade_length = 0.01
	if not check(energy(await capture(tree))<0.01,"Light distance fade did not update"):
		return false
	light.distance_fade_enabled = false
	light.omni_range = 0.1
	if not check(energy(await capture(tree))<0.01,"Light range did not update"):
		return false
	light.omni_range = 8.0
	light.light_energy = 0.0
	if not check(energy(await capture(tree)) < 0.01,"Zero-energy Light3D left stale lighting"):
		return false
	var spot := SpotLight3D.new()
	tree.root.add_child(spot)
	spot.position = Vector3(0,0,2)
	spot.spot_range = 8
	spot.light_energy = 5
	bridge.local_lights = [spot] as Array[Light3D]
	var spot_lit := await capture(tree)
	spot.rotate_y(PI)
	var spot_away := await capture(tree)
	if not check(energy(spot_lit)>1.0 and energy(spot_away)<0.01,"SpotLight3D cone transform failed"):
		return false
	spot.free()
	if not check(energy(await capture(tree))<0.01 and material.get_shader_parameter("local_light_count")==0,
		"Deleted local light left stale data"):
		return false
	var many: Array[Light3D] = []
	for i in 17:
		var extra := OmniLight3D.new()
		tree.root.add_child(extra)
		many.append(extra)
	bridge.local_lights = many
	await capture(tree)
	if not check(material.get_shader_parameter("local_light_count")==16,"Light array cap failed"):
		return false
	for extra in many:
		extra.queue_free()
	bridge.local_lights = [] as Array[Light3D]
	var sun := DirectionalLight3D.new()
	tree.root.add_child(sun)
	bridge.main_light = sun
	var main_lit := await capture(tree)
	sun.hide()
	if not check(energy(main_lit)>1.0 and energy(await capture(tree))<0.01,"DirectionalLight3D visibility binding failed"):
		return false
	sun.show()
	sun.rotation_degrees = Vector3(0,110,0)
	if not check((await capture(tree)).get_data()!=main_lit.get_data(),"Directional light rotation ignored"):
		return false
	sun.free()
	if not check(energy(await capture(tree))<0.01,"Deleted directional light left stale data"):
		return false
	var shadow_report := await verify_engine_shadows(tree,bridge,patch,camera,evidence)
	if shadow_report.is_empty():
		return false
	report["engine_local_shadows"] = shadow_report
	var directional_report := await verify_directional_shadows(tree,bridge,patch,camera,evidence)
	if directional_report.is_empty():
		return false
	report["engine_directional_shadows"] = directional_report
	sun = DirectionalLight3D.new()
	tree.root.add_child(sun)
	bridge.main_light = sun
	sun.rotation_degrees = Vector3(-25,-35,0)
	sun.shadow_enabled = true
	bridge.target = hair
	hair.material_override = material
	material.set_shader_parameter("environment_strength",0.2877224684)
	material.set_shader_parameter("ambient_exposure",0.9)
	light.position = hair.global_position+Vector3(1,0,1)
	light.light_energy = 3
	light.shadow_enabled = true
	light.set_meta("character_mode",3)
	bridge.local_lights = [light] as Array[Light3D]
	patch.queue_free()
	blocker.queue_free()
	tree.root.msaa_3d = Viewport.MSAA_DISABLED
	tree.root.size = old_size
	camera.transform = old_transform
	camera.projection = old_projection
	camera.size = old_camera_size
	if keep_open:
		light.set_meta("character_parameters",Vector4(2,0.5,0,0))
	report["light_binding"] = "omni movement/color/energy/range/fade/visibility/cull mask, spot cone, directional visibility/rotation, deletion, 16-light cap passed"
	FileAccess.open(evidence.path_join("hair-live-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("CHARACTER_LIVE_OK "+JSON.stringify(report))
	return true

func verify_engine_shadows(tree: SceneTree, bridge: Node, patch: MeshInstance3D, camera: Camera3D, evidence: String) -> Dictionary:
	var material := patch.material_override as ShaderMaterial
	camera.position = Vector3(0,0,3)
	camera.look_at(Vector3.ZERO)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	var caster := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.8,0.8,0.8)
	caster.mesh = box
	caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	tree.root.add_child(caster)
	caster.position = Vector3(1,0,1)
	var result := {}
	for kind in ["omni","spot"]:
		var probe: Light3D = OmniLight3D.new() if kind == "omni" else SpotLight3D.new()
		tree.root.add_child(probe)
		if not check(probe.get_light_rid().is_valid(),"Light RID must be valid"):
			return {}
		probe.position = Vector3(2,0,2)
		probe.look_at(Vector3.ZERO)
		probe.set_param(Light3D.PARAM_RANGE,8.0)
		probe.light_energy = 5.0
		probe.shadow_enabled = true
		probe.shadow_bias = 0.02
		probe.shadow_normal_bias = 0.0
		probe.set_meta("character_mode",1)
		probe.set_meta("character_parameters",Vector4(0.7,0,0,0))
		bridge.local_lights = [probe] as Array[Light3D]
		caster.hide()
		var visible := await capture(tree)
		caster.show()
		var blocked := await capture(tree)
		var lit_energy := energy(visible)
		var blocked_energy := energy(blocked)
		visible.save_png(evidence.path_join("hair-shadow-%s-visible.png" % kind))
		blocked.save_png(evidence.path_join("hair-shadow-%s-blocked.png" % kind))
		if not check(lit_energy>1.0 and blocked_energy<lit_energy*0.8,
			"Engine %s shadow failed: visible=%f blocked=%f" % [kind,lit_energy,blocked_energy]):
			return {}
		caster.position.x = 4
		var moved_energy := energy(await capture(tree))
		if not check(absf(moved_energy-lit_energy)<lit_energy*0.02,"Moving caster did not release "+kind+" shadow"):
			return {}
		caster.position.x = 1
		probe.shadow_opacity = 0
		var zero_energy := energy(await capture(tree))
		if not check(absf(zero_energy-lit_energy)<lit_energy*0.02,"Zero opacity did not release "+kind+" shadow"):
			return {}
		probe.shadow_opacity = 1
		probe.shadow_enabled = false
		var disabled_energy := energy(await capture(tree))
		if not check(absf(disabled_energy-lit_energy)<lit_energy*0.02,"Disabled shadow left stale "+kind+" data"):
			return {}
		probe.shadow_enabled = true
		probe.set_meta("character_mode",3)
		probe.set_meta("character_parameters",Vector4(4,0.5,0,0))
		caster.show()
		var rim_blocked := energy(await capture(tree))
		caster.hide()
		var rim_visible := energy(await capture(tree))
		if not check(rim_visible>1.0 and rim_blocked<rim_visible*0.8,"Mode 3 did not receive "+kind+" shadows"):
			return {}
		caster.show()
		probe.set_meta("character_parameters",Vector4(0.7,0,0,0))
		# Mode 0 deliberately remains unshadowed, as in the captured material.
		probe.set_meta("character_mode",0)
		var mode0_blocked := await capture(tree)
		caster.hide()
		var mode0_visible := await capture(tree)
		if not check(mode0_blocked.get_data()==mode0_visible.get_data(),"Mode 0 incorrectly received "+kind+" shadows"):
			return {}
		# A coincident unshadowed light must not borrow the first light's atlas slot.
		var other: Light3D = OmniLight3D.new() if kind == "omni" else SpotLight3D.new()
		tree.root.add_child(other)
		other.transform = probe.transform
		other.set_param(Light3D.PARAM_RANGE,8.0)
		other.light_energy = 5.0
		other.set_meta("character_mode",1)
		other.set_meta("character_parameters",Vector4(0.7,0,0,0))
		bridge.local_lights = [other] as Array[Light3D]
		caster.show()
		var coincident_energy := energy(await capture(tree))
		if not check(absf(coincident_energy-lit_energy)<lit_energy*0.02,"Coincident lights aliased "+kind+" shadow IDs"):
			return {}
		probe.set_meta("character_mode",1)
		bridge.local_lights = [probe,other] as Array[Light3D]
		var order_a := energy(await capture(tree))
		bridge.local_lights = [other,probe] as Array[Light3D]
		var order_b := energy(await capture(tree))
		if not check(absf(order_a-order_b)<maxf(0.01,order_a*0.001),"Light reorder changed "+kind+" shadows"):
			return {}
		result[kind] = {"rim_visible":rim_visible,"rim_blocked":rim_blocked,"order_a":order_a,"order_b":order_b,"visible":lit_energy,"blocked":blocked_energy,"moved":moved_energy,"zero_opacity":zero_energy,"disabled":disabled_energy,"coincident":coincident_energy}
		probe.free()
		other.free()
	bridge.local_lights = [] as Array[Light3D]
	caster.queue_free()
	return result

func verify_directional_shadows(tree: SceneTree, bridge: Node, patch: MeshInstance3D, camera: Camera3D, evidence: String) -> Dictionary:
	# Isolate the external caster from precision-dependent quad self-shadowing.
	var old_casting := patch.cast_shadow
	patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := patch.material_override as ShaderMaterial
	var sun := DirectionalLight3D.new()
	tree.root.add_child(sun)
	sun.rotation_degrees = Vector3(0,45,0)
	sun.shadow_enabled = true
	sun.shadow_bias = 0.02
	sun.shadow_normal_bias = 0.0
	sun.directional_shadow_max_distance = 20.0
	sun.directional_shadow_split_1 = 0.2
	sun.directional_shadow_split_2 = 0.4
	sun.directional_shadow_split_3 = 0.6
	bridge.main_light = sun
	var caster := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(8,8,1)
	caster.mesh = box
	caster.position = Vector3(1,0,1)
	caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	tree.root.add_child(caster)
	caster.hide()
	var visible := await capture(tree)
	var lit := energy(visible)
	caster.show()
	var blocked := await capture(tree)
	var dark := energy(blocked)
	visible.save_png(evidence.path_join("hair-shadow-directional-visible.png"))
	blocked.save_png(evidence.path_join("hair-shadow-directional-blocked.png"))
	if not check(lit>1.0 and dark<lit*0.8,"Directional hair shadow failed: visible=%f blocked=%f" % [lit,dark]):
		return {}
	caster.position.x = 20
	var moved := energy(await capture(tree))
	if not check(absf(moved-lit)<lit*0.02,"Moving directional caster did not restore hair"):
		return {}
	caster.position.x = 1
	sun.shadow_opacity = 0.0
	var zero := energy(await capture(tree))
	sun.shadow_opacity = 1.0
	sun.shadow_enabled = false
	var disabled := energy(await capture(tree))
	sun.shadow_enabled = true
	material.set_shader_parameter("engine_directional_shadows_enabled",false)
	var fallback := energy(await capture(tree))
	material.set_shader_parameter("engine_directional_shadows_enabled",true)
	if not check(absf(zero-lit)<lit*0.02 and absf(disabled-lit)<lit*0.02 and absf(fallback-lit)<lit*0.02,"Directional opacity/disable/fallback failed lit=%f zero=%f disabled=%f fallback=%f" % [lit,zero,disabled,fallback]):
		return {}
	# Select the second, coincident direction explicitly, while the first casts shadows.
	var other := DirectionalLight3D.new()
	tree.root.add_child(other)
	other.transform = sun.transform
	bridge.main_light = other
	var second := energy(await capture(tree))
	if not check(absf(second-lit)<lit*0.02,"Directional RID selected the wrong sun"):
		return {}
	bridge.main_light = sun
	other.hide()
	await capture(tree)
	other.show()
	var reordered := energy(await capture(tree))
	if not check(absf(reordered-dark)<maxf(0.01,lit*0.02),"Directional visibility reorder changed identity"):
		return {}
	other.free()
	# Inspect visibility directly to isolate cascade selection from hair shading.
	var diagnostic := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode custom_character, custom_character_shadows; uniform uint main_shadow_id_low; uniform uint main_shadow_id_high; void fragment(){float s=custom_forward_directional_shadow(uvec2(main_shadow_id_low,main_shadow_id_high),VERTEX,NORMAL); EMISSION=vec3(s);}"
	diagnostic.shader = shader
	patch.material_override = diagnostic
	# Orthographic cameras deliberately use camera.far instead of shadow max distance.
	# Use perspective here so the configured 20-unit splits/fade are exercised.
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	var samples := []
	for mode in [DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,DirectionalLight3D.SHADOW_ORTHOGONAL]:
		sun.directional_shadow_mode = mode
		for blend in [false,true]:
			sun.directional_shadow_blend_splits = blend
			for depth in [3.8,4.0,4.2,7.8,8.0,8.2,11.8,12.0,12.2,16.0,18.0,19.0,21.0]:
				camera.position = Vector3(0,0,depth)
				caster.hide()
				var clear := energy(await capture(tree))
				caster.show()
				var occluded_image := await capture(tree)
				var occluded := energy(occluded_image)
				if not check(clear>1.0 and (occluded<clear*0.05 if depth<17.0 else (occluded>clear*0.1 and occluded<clear*0.98 if depth<20.0 else absf(occluded-clear)<clear*0.02)),"Cascade visibility failed mode=%d blend=%s depth=%f clear=%f blocked=%f" % [mode,blend,depth,clear,occluded]):
					return {}
				samples.append({"mode":mode,"blend":blend,"depth":depth,"visible":clear,"blocked":occluded})
	patch.material_override = material
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.position = Vector3(0,0,3)
	sun.free()
	caster.free()
	patch.cast_shadow = old_casting
	return {"visible":lit,"blocked":dark,"moved":moved,"zero_opacity":zero,"disabled":disabled,"fallback":fallback,"second_sun":second,"reordered":reordered,"cascades":samples}
