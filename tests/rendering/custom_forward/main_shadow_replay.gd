extends SceneTree

var rd: RenderingDevice
var resources: Array[RID] = []

func keep(rid: RID) -> RID:
	assert(rid.is_valid())
	resources.append(rid)
	return rid

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var evidence := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence="):
			evidence = arg.trim_prefix("--evidence=")
	assert(not evidence.is_empty())
	# A failed run must not leave a previous result available to the comparator.
	if FileAccess.file_exists(evidence.path_join("main-shadow-replay.bin")):
		assert(DirAccess.remove_absolute(evidence.path_join("main-shadow-replay.bin")) == OK)
	rd = RenderingServer.create_local_rendering_device()
	assert(rd != null)
	var source := RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string("res://main_shadow_replay.glsl")
	var spirv := rd.shader_compile_spirv_from_source(source)
	assert(spirv.compile_error_compute.is_empty(), spirv.compile_error_compute)
	var shader := keep(rd.shader_create_from_spirv(spirv))
	var format := RDTextureFormat.new()
	format.width = 4096
	format.height = 2048
	format.format = RenderingDevice.DATA_FORMAT_R16_UNORM
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var atlas := keep(rd.texture_create(format, RDTextureView.new(), [FileAccess.get_file_as_bytes(evidence.path_join("e641-texture-187141.bin"))]))
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	var sampler := keep(rd.sampler_create(sampler_state))
	var uniforms: Array[RDUniform] = []
	var atlas_uniform := RDUniform.new()
	atlas_uniform.binding = 0
	atlas_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	atlas_uniform.add_id(sampler)
	atlas_uniform.add_id(atlas)
	uniforms.append(atlas_uniform)
	var names := ["camera.bin", "shadow.bin", "e641-texture-173764.bin", "e641-texture-173776.bin", "e641-texture-173782.bin", "e641-texture-173794.bin"]
	for index in range(names.size()):
		var data := FileAccess.get_file_as_bytes(evidence.path_join(names[index]))
		var uniform := RDUniform.new()
		uniform.binding = index + 1
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.add_id(keep(rd.storage_buffer_create(data.size(), data)))
		uniforms.append(uniform)
	format = RDTextureFormat.new()
	format.width = 2560
	format.height = 1440
	format.format = RenderingDevice.DATA_FORMAT_R8G8_UNORM
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var output := keep(rd.texture_create(format, RDTextureView.new()))
	var output_uniform := RDUniform.new()
	output_uniform.binding = 7
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_uniform.add_id(output)
	uniforms.append(output_uniform)
	var uniform_set := keep(rd.uniform_set_create(uniforms, shader, 0))
	var pipeline := keep(rd.compute_pipeline_create(shader))
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, 320, 180, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var file := FileAccess.open(evidence.path_join("main-shadow-replay.bin"), FileAccess.WRITE)
	assert(file != null)
	file.store_buffer(rd.texture_get_data(output, 0))
	file.close()
	resources.reverse()
	for rid in resources:
		rd.free_rid(rid)
	rd.free()
	print("MAIN_SHADOW_REPLAY_OK")
	quit()
