extends Node

## Scene bridge for E669/E679/E684/E694/E699/E704 (16 lights) and E689 (8 lights, face_layout).
## E674 remains unsupported.
## Each target needs its own ShaderMaterial. This owns main/local light uniforms,
## Live variants resolve engine directional/local shadows by RID; physical intensity/baked lights are not mapped.
@export var face_layout := false
@export var target: MeshInstance3D
@export var main_light: DirectionalLight3D
@export var local_lights: Array[Light3D] = []

func _process(_delta: float) -> void:
	sync_lights()

func affects(light: Light3D) -> bool:
	return is_instance_valid(light) and light.is_inside_tree() and light.is_visible_in_tree() \
		and (light.light_cull_mask & target.layers) != 0

func sync_lights() -> void:
	if not is_instance_valid(target) or not target.is_inside_tree():
		return
	var material := target.material_override as ShaderMaterial
	if material == null:
		return
	var energy := 0.0
	var main_id := 0
	if is_instance_valid(main_light) and affects(main_light):
		main_id = main_light.get_light_rid().get_id()
		energy = main_light.light_energy * (-1.0 if main_light.light_negative else 1.0)
		material.set_shader_parameter("main_direction", main_light.global_basis.z.normalized())
		material.set_shader_parameter("main_color", Vector3(main_light.light_color.srgb_to_linear().r,
			main_light.light_color.srgb_to_linear().g, main_light.light_color.srgb_to_linear().b))
	material.set_shader_parameter("main_energy", energy)
	material.set_shader_parameter("main_shadow_id_low", main_id & 0xffffffff)
	material.set_shader_parameter("main_shadow_id_high", (main_id >> 32) & 0xffffffff)
	# Slots change as lights hide or disappear; old external atlas slots cannot
	# safely be reused for this list. Godot shadow-atlas binding is a separate adapter.
	material.set_shader_parameter("shadow_atlas_enabled", false)
	var positions := PackedVector4Array()
	var colors := PackedVector4Array()
	var parameters := PackedVector4Array()
	var attenuation := PackedVector4Array()
	var directions := PackedVector3Array()
	var specular := PackedFloat32Array()
	var shadow_low := PackedInt32Array()
	var shadow_high := PackedInt32Array()
	var shadow_spot: Array[bool] = []
	var camera := target.get_viewport().get_camera_3d()
	for light in local_lights:
		if not is_instance_valid(light) or not affects(light) or not (light is OmniLight3D or light is SpotLight3D):
			continue
		var radius := light.get_param(Light3D.PARAM_RANGE)
		if radius <= 0.0:
			continue
		var mode := int(light.get_meta("character_mode", 0))
		if mode not in [0, 1, 3, 4] or (face_layout and mode == 4):
			continue
		var custom_parameters: Variant = light.get_meta("character_parameters", Vector4(1,0.5,0,0))
		if not custom_parameters is Vector4:
			continue
		var fade := 1.0
		if light.distance_fade_enabled and camera != null:
			var distance := camera.global_position.distance_to(light.global_position)
			fade = 1.0 - smoothstep(light.distance_fade_begin,
				light.distance_fade_begin + maxf(light.distance_fade_length, 0.0001), distance)
		var power := light.light_energy * fade * (-1.0 if light.light_negative else 1.0)
		if is_zero_approx(power):
			continue
		var color := light.light_color.srgb_to_linear() * power
		var position := light.global_position
		positions.append(Vector4(position.x, position.y, position.z, 1.0/radius))
		colors.append(Vector4(color.r, color.g, color.b, mode))
		# Captured mode parameters remain artistic controls, separate from Godot falloff.
		parameters.append(custom_parameters)
		var cutoff := cos(deg_to_rad(light.get_param(Light3D.PARAM_SPOT_ANGLE))) if light is SpotLight3D else 0.0
		attenuation.append(Vector4(light.get_param(Light3D.PARAM_ATTENUATION), cutoff,
			1.0/maxf(1.0-cutoff,0.0001) if light is SpotLight3D else 0.0, 1.0))
		directions.append(-light.global_basis.z.normalized())
		specular.append(light.light_specular)
		var rid_id := light.get_light_rid().get_id()
		shadow_low.append(rid_id & 0xffffffff)
		shadow_high.append((rid_id >> 32) & 0xffffffff)
		shadow_spot.append(light is SpotLight3D)
		if positions.size() == (8 if face_layout else 16):
			break
	material.set_shader_parameter("local_light_count", positions.size())
	# Zero count invalidates stale arrays; do not upload empty uniform arrays.
	if not positions.is_empty():
		material.set_shader_parameter("local_positions", positions)
		material.set_shader_parameter("local_colors", colors)
		material.set_shader_parameter("local_parameters", parameters)
		material.set_shader_parameter("local_attenuation", attenuation)
		material.set_shader_parameter("local_directions", directions)
		material.set_shader_parameter("local_specular_strength", specular)
		material.set_shader_parameter("local_shadow_id_low", shadow_low)
		material.set_shader_parameter("local_shadow_id_high", shadow_high)
		material.set_shader_parameter("local_shadow_is_spot", shadow_spot)
