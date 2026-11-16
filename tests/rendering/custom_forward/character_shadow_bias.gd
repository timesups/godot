extends SceneTree

# Visibility/normal/mask diagnostics on self-casting geometry and contact gaps.
var output := ""
var evidence := ""
var reference := false
var contact := false
var camera: Camera3D
var sun: DirectionalLight3D
var material: ShaderMaterial
var receiver: MeshInstance3D
var blocker: MeshInstance3D
var records: Array = []
var character_parts: Array[MeshInstance3D] = []

func _initialize() -> void:
	call_deferred("run")

func capture() -> Image:
	for i in 5: await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func sample_case(name: String, kind: String, gap: float = 0.0) -> void:
	var img := await capture()
	if img.save_png(output.path_join(name+".png")) != OK:
		push_error("Cannot save bias evidence")
		quit(1)
	records.append({"name":name,"kind":kind,"gap":gap,"bias":sun.shadow_bias,
		"normal_bias":sun.shadow_normal_bias,"angle":sun.light_angular_distance,
		"far":camera.far,"projection":camera.projection,
		"pancake":sun.directional_shadow_pancake_size,"blend":sun.directional_shadow_blend_splits})

func v3(bytes: PackedByteArray, offset: int) -> Vector3:
	return Vector3(bytes.decode_float(offset),bytes.decode_float(offset+4),bytes.decode_float(offset+8))

func load_character() -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(evidence.path_join("character-manifest.json")))
	var origin := Vector3(manifest.coordinate_origin[0],manifest.coordinate_origin[1],manifest.coordinate_origin[2])
	for part in manifest.parts:
		var vb := FileAccess.get_file_as_bytes(evidence.path_join("e%d-postvs-vertex.bin" % int(part.event)))
		var ib := FileAccess.get_file_as_bytes(evidence.path_join("e%d-postvs-index.bin" % int(part.event)))
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var indices := PackedInt32Array()
		for i in int(part.vertex_count):
			var offset := int(part.vertex_offset)+i*int(part.vertex_stride)
			vertices.append(v3(vb,offset+32)-origin)
			normals.append(v3(vb,offset+48).normalized())
		for i in int(part.index_count):
			var offset := int(part.index_offset)+i*int(part.index_stride)
			indices.append(ib.decode_u16(offset) if int(part.index_stride)==2 else ib.decode_u32(offset))
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX]=vertices
		arrays[Mesh.ARRAY_NORMAL]=normals
		arrays[Mesh.ARRAY_INDEX]=preload("res://character_mesh.gd").godot_indices(indices)
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
		var instance := MeshInstance3D.new()
		instance.mesh=mesh
		instance.set_meta("capture_event",int(part.event))
		instance.material_override=material
		instance.visible=false
		root.add_child(instance)
		character_parts.append(instance)

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output=arg.trim_prefix("--output=")
		if arg.begins_with("--evidence="): evidence=arg.trim_prefix("--evidence=")
		if arg=="--reference": reference=true
		if arg=="--contact": contact=true
	var expected_renderer := "forward_plus" if reference else "custom_forward"
	if output.is_empty() or not FileAccess.file_exists(evidence.path_join("character-manifest.json")) or RenderingServer.get_current_rendering_method()!=expected_renderer:
		push_error("Specify --output, --evidence and a supported renderer")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	root.size=Vector2i(320,320)
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
	camera.position=Vector3(0,0,3)
	camera.fov=40
	camera.near=0.05
	camera.far=10
	root.add_child(camera)
	camera.current=true
	sun=DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(0,60,0)
	sun.shadow_enabled=true
	sun.directional_shadow_max_distance=6
	sun.directional_shadow_mode=2
	sun.directional_shadow_blend_splits=true
	root.add_child(sun)
	material=ShaderMaterial.new()
	var shader := Shader.new()
	if reference:
		shader.code="shader_type spatial; render_mode cull_disabled,ambient_light_disabled; uniform bool orientation=false; void fragment(){ALBEDO=vec3(1); NORMAL=normalize(NORMAL);} void light(){DIFFUSE_LIGHT=vec3(ATTENUATION,0.5+0.5*dot(NORMAL,orientation?VIEW:LIGHT),1.0);}"
	else:
		shader.code="shader_type spatial; render_mode cull_disabled,custom_character,custom_character_shadows; uniform uint lo; uniform uint hi; uniform vec3 light_direction; uniform bool orientation=false; varying vec3 wn; void vertex(){wn=MODEL_NORMAL_MATRIX*NORMAL;} void fragment(){vec3 n=normalize(wn)*(FRONT_FACING?1.0:-1.0); vec3 vn=normalize(mat3(VIEW_MATRIX)*n); EMISSION=vec3(custom_forward_directional_shadow(uvec2(lo,hi),VERTEX,vn),0.5+0.5*(orientation?dot(vn,normalize(-VERTEX)):dot(n,light_direction)),1.0);}"
	material.shader=shader
	var id := sun.get_light_rid().get_id()
	material.set_shader_parameter("lo",id & 0xffffffff)
	material.set_shader_parameter("hi",(id >> 32) & 0xffffffff)
	material.set_shader_parameter("light_direction",sun.global_basis.z)
	receiver=MeshInstance3D.new()
	receiver.material_override=material
	root.add_child(receiver)
	blocker=MeshInstance3D.new()
	blocker.material_override=material
	blocker.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	root.add_child(blocker)
	blocker.hide()
	var sphere := SphereMesh.new()
	sphere.radius=0.5
	sphere.height=1.0
	sphere.radial_segments=128
	sphere.rings=64
	var presets := [[0.0,0.0],[0.02,0.0],[0.02,0.5],[0.1,1.0],[1.0,4.0]]
	for shape in ["sphere","ellipsoid"]:
		receiver.mesh=sphere
		receiver.scale=Vector3.ONE if shape=="sphere" else Vector3(0.65,1.4,0.7)
		receiver.rotation_degrees=Vector3(0,0,0) if shape=="sphere" else Vector3(0,25,15)
		for preset in range(presets.size()):
			sun.shadow_bias=presets[preset][0]
			sun.shadow_normal_bias=presets[preset][1]
			for angle in [0.0,2.0]:
				sun.light_angular_distance=angle
				await sample_case("%s_p%d_a%d" % [shape,preset,int(angle)],shape)
	receiver.transform=Transform3D.IDENTITY
	var quad := QuadMesh.new()
	quad.size=Vector2(3,3)
	receiver.mesh=quad
	receiver.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sheet := QuadMesh.new()
	sheet.size=Vector2(0.8,1.0)
	blocker.mesh=sheet
	blocker.show()
	for back in [false,true]:
		blocker.rotation_degrees.y=180 if back else 0
		for preset in range(presets.size()):
			sun.shadow_bias=presets[preset][0]
			sun.shadow_normal_bias=presets[preset][1]
			for angle in [0.0,2.0]:
				sun.light_angular_distance=angle
				for gap in [0.002,0.01,0.05]:
					blocker.position=Vector3(tan(deg_to_rad(60.0))*gap,0,gap)
					await sample_case("sheet_b%d_p%d_a%d_g%.3f" % [int(back),preset,int(angle),gap],"sheet",gap)
	blocker.hide()
	receiver.hide()
	load_character()
	for part in character_parts: part.show()
	var bounds := character_parts[0].get_aabb()
	for part in character_parts: bounds=bounds.merge(part.get_aabb())
	camera.position=bounds.get_center()+Vector3(0,0,2.7)
	camera.look_at(bounds.get_center())
	for preset in range(presets.size()):
		sun.shadow_bias=presets[preset][0]
		sun.shadow_normal_bias=presets[preset][1]
		for angle in [0.0,2.0]:
			sun.light_angular_distance=angle
			await sample_case("character_p%d_a%d" % [preset,int(angle)],"character")
	await sample_case("character_stable","character")
	# Reproduce the orthographic preview's default far plane, then fit its range.
	for part in character_parts: part.hide()
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	camera.size=2.2
	camera.position=Vector3(0,0,3)
	camera.rotation=Vector3.ZERO
	for far_plane in [4000.0,6.0,5.0]:
		camera.far=far_plane
		sun.directional_shadow_pancake_size=2.0 if far_plane==5.0 else 20.0
		for preset in [[0.1,2.0],[0.02,0.5],[0.05,1.0]]:
			sun.shadow_bias=preset[0]
			sun.shadow_normal_bias=preset[1]
			for angle in [0.0,2.0]:
				sun.light_angular_distance=angle
				receiver.show()
				receiver.mesh=sphere
				receiver.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				await sample_case("ortho_f%d_b%.2f_n%.1f_a%d_sphere" % [int(far_plane),preset[0],preset[1],int(angle)],"ortho_sphere")
				receiver.mesh=quad
				receiver.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				blocker.show()
				for gap in [0.002,0.01,0.05]:
					blocker.position=Vector3(tan(deg_to_rad(60.0))*gap,0,gap)
					await sample_case("ortho_f%d_b%.2f_n%.1f_a%d_g%.3f" % [int(far_plane),preset[0],preset[1],int(angle),gap],"ortho_sheet",gap)
				blocker.hide()
				receiver.hide()
				for part in character_parts: part.show()
				camera.position=bounds.get_center()+Vector3(0,0,3)
				await sample_case("ortho_f%d_b%.2f_n%.1f_a%d_character" % [int(far_plane),preset[0],preset[1],int(angle)],"ortho_character")
				for part in character_parts: part.hide()
				camera.position=Vector3(0,0,3)
	preload("res://character_shadow_preview.gd").configure(camera,sun)
	for shape in ["sphere","ellipsoid"]:
		receiver.show()
		receiver.mesh=sphere
		receiver.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		receiver.scale=Vector3.ONE if shape=="sphere" else Vector3(0.65,1.4,0.7)
		receiver.rotation_degrees=Vector3.ZERO if shape=="sphere" else Vector3(0,25,15)
		await sample_case("preview_"+shape,"preview_curve")
	receiver.transform=Transform3D.IDENTITY
	receiver.mesh=quad
	receiver.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	blocker.show()
	for back in [false,true]:
		blocker.rotation_degrees.y=180 if back else 0
		for gap in [0.002,0.01,0.05]:
			blocker.position=Vector3(tan(deg_to_rad(60.0))*gap,0,gap)
			await sample_case("preview_sheet_b%d_g%.3f" % [int(back),gap],"preview_sheet",gap)
	blocker.hide()
	receiver.hide()
	for part in character_parts: part.show()
	for side in [false,true]:
		camera.position=bounds.get_center()+(Vector3(2,0.3,2) if side else Vector3(0,0,3))
		camera.look_at(bounds.get_center())
		await sample_case("preview_character_side%d" % int(side),"preview_character")
	await sample_case("preview_stable","preview_character")
	material.set_shader_parameter("orientation",true)
	await sample_case("preview_orientation","preview_character")
	if contact:
		material.set_shader_parameter("orientation",false)
		for part in character_parts: part.hide()
		camera.position=Vector3(0,0,3)
		camera.rotation=Vector3.ZERO
		receiver.show()
		receiver.mesh=quad
		blocker.rotation=Vector3.ZERO
		for yaw in [0,30,60,75]:
			sun.rotation_degrees=Vector3(0,yaw,0)
			material.set_shader_parameter("light_direction",sun.global_basis.z)
			for angle in [0.0,2.0]:
				sun.light_angular_distance=angle
				blocker.hide()
				receiver.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				await sample_case("contact_y%d_a%d_clear" % [yaw,int(angle)],"contact_clear")
				receiver.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				blocker.show()
				for gap in [0.002,0.004,0.008,0.016,0.032]:
					blocker.position=Vector3(tan(deg_to_rad(float(yaw)))*gap,0,gap)
					await sample_case("contact_y%d_a%d_g%.3f" % [yaw,int(angle),gap],"contact_sheet",gap)
		# Straddle the near-grazing fallback; contact must fade rather than pop.
		sun.light_angular_distance=2.0
		for yaw in [83.9,84.1,84.2,84.3,84.4,84.6]:
			sun.rotation_degrees=Vector3(0,yaw,0)
			material.set_shader_parameter("light_direction",sun.global_basis.z)
			blocker.position=Vector3(tan(deg_to_rad(yaw))*0.002,0,0.002)
			await sample_case("contact_grazing_y%.1f" % yaw,"contact_grazing",0.002)
		# Isolate the captured face under the actual preview light direction.
		# Aggregate whole-character coverage cannot detect cheek contact acne.
		receiver.hide()
		blocker.hide()
		for part in character_parts: part.visible=int(part.get_meta("capture_event"))==689
		sun.rotation_degrees=Vector3(-25,-35,0)
		material.set_shader_parameter("light_direction",sun.global_basis.z)
		for side in [false,true]:
			camera.position=bounds.get_center()+(Vector3(2,0.3,2) if side else Vector3(0,0,3))
			camera.look_at(bounds.get_center())
			await sample_case("contact_face_side%d" % int(side),"contact_face")
	FileAccess.open(output.path_join("cases.json"),FileAccess.WRITE).store_string(JSON.stringify(records,"\t"))
	print("CHARACTER_SHADOW_BIAS_CAPTURE_OK cases=%d reference=%s" % [records.size(),reference])
	quit(0)
