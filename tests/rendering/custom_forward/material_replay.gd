extends SceneTree

var rd: RenderingDevice
var evidence: String
var resources: Array[RID] = []

func _initialize() -> void:
	call_deferred("run")

func keep(rid: RID) -> RID:
	assert(rid.is_valid())
	resources.append(rid)
	return rid

func tex(width: int, height: int, format: int, data: PackedByteArray, levels: int = 1, target: bool = false) -> RID:
	var f := RDTextureFormat.new()
	f.width = width
	f.height = height
	f.format = format
	f.mipmaps = levels
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	if target:
		f.usage_bits |= RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT
	return keep(rd.texture_create(f, RDTextureView.new(), [] if data.is_empty() else [data]))

func dds(name: String, format: int, levels: int = 1) -> RID:
	var bytes := FileAccess.get_file_as_bytes(evidence.path_join(name + ".dds"))
	var data := bytes.slice(148 if bytes.slice(84, 88).get_string_from_ascii() == "DX10" else 128)
	for mip in range(1, levels):
		data.append_array(FileAccess.get_file_as_bytes(evidence.path_join(name + "-mip%d.dds" % mip)).slice(148))
	return tex(bytes.decode_u32(16), bytes.decode_u32(12), format, data, levels)

func sampler(anisotropic: bool, wrap: bool) -> RID:
	var s := RDSamplerState.new()
	s.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	# Original vkCreateSampler: min/mag LINEAR, mipmapMode NEAREST even with anisotropy.
	s.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	s.use_anisotropy = anisotropic
	s.anisotropy_max = 8
	s.max_lod = 1000
	s.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT if wrap else RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	s.repeat_v = s.repeat_u
	s.repeat_w = s.repeat_u
	return keep(rd.sampler_create(s))

func buffer(name: String) -> RID:
	var b := FileAccess.get_file_as_bytes(evidence.path_join(name))
	return keep(rd.storage_buffer_create(b.size(), b))

func run() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--evidence="):
			evidence = a.trim_prefix("--evidence=")
	assert(not evidence.is_empty())
	rd = RenderingServer.create_local_rendering_device()
	assert(rd != null)
	var src := RDShaderSource.new()
	src.source_vertex = FileAccess.get_file_as_string("res://material_replay.vert")
	src.source_fragment = FileAccess.get_file_as_string("res://material_replay.frag")
	var shared_path := ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/custom_forward/materials/character_lighting.gdshaderinc")
	src.source_fragment = src.source_fragment.replace("// CHARACTER_LIGHTING_SHARED", FileAccess.get_file_as_string(shared_path))
	var spv := rd.shader_compile_spirv_from_source(src)
	assert(spv.compile_error_vertex.is_empty(), spv.compile_error_vertex)
	assert(spv.compile_error_fragment.is_empty(), spv.compile_error_fragment)
	var shader := keep(rd.shader_create_from_spirv(spv))
	var wrap := sampler(true, true)
	var clamp_aniso := sampler(true, false)
	var clamp_linear := sampler(false, false)
	var textures: Array[RID] = [
		dds("texture-185716", RenderingDevice.DATA_FORMAT_BC7_SRGB_BLOCK, 11),
		dds("texture-172496", RenderingDevice.DATA_FORMAT_BC7_SRGB_BLOCK),
		dds("texture-186593", RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM),
		tex(2560, 1440, RenderingDevice.DATA_FORMAT_R8_UNORM, FileAccess.get_file_as_bytes(evidence.path_join("e674-mask.bin"))),
		dds("fresh-e674-173764", RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	]
	var uniforms: Array[RDUniform] = []
	for binding in range(10):
		var u := RDUniform.new()
		u.binding = binding
		if binding >= 1 and binding <= 5:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			u.add_id(wrap if binding == 1 else (clamp_aniso if binding == 2 else clamp_linear))
			u.add_id(textures[binding - 1])
		else:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			var names := {0: "e674-postvs-vertex.bin", 6: "e674-cb2.bin", 7: "e674-cb0.bin", 8: "e674-record0-transform.bin", 9: "e674-light-binning.bin"}
			u.add_id(buffer(names[binding]))
		uniforms.append(u)
	var set := keep(rd.uniform_set_create(uniforms, shader, 0))
	var output := tex(2560, 1440, RenderingDevice.DATA_FORMAT_B10G11R11_UFLOAT_PACK32, PackedByteArray(), 1, true)
	var raw := tex(2560, 1440, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, PackedByteArray(), 1, true)
	var base := tex(2560, 1440, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, PackedByteArray(), 1, true)
	var uv_dx := tex(2560, 1440, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, PackedByteArray(), 1, true)
	var dy_primitive := tex(2560, 1440, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, PackedByteArray(), 1, true)
	var fb := keep(rd.framebuffer_create([output, raw, base, uv_dx, dy_primitive]))
	var raster := RDPipelineRasterizationState.new()
	raster.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	var blend := RDPipelineColorBlendState.new()
	for i in 5:
		blend.attachments.append(RDPipelineColorBlendStateAttachment.new())
	var pipeline := keep(rd.render_pipeline_create(shader, rd.framebuffer_get_format(fb), -1, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, raster, RDPipelineMultisampleState.new(), RDPipelineDepthStencilState.new(), blend))
	var index := keep(rd.index_buffer_create(1356, RenderingDevice.INDEX_BUFFER_FORMAT_UINT16, FileAccess.get_file_as_bytes(evidence.path_join("e674-postvs-index.bin"))))
	var index_array := keep(rd.index_array_create(index, 0, 1356))
	var clear := PackedColorArray()
	for i in 5:
		clear.append(Color(0, 0, 0, 0))
	var list := rd.draw_list_begin(fb, RenderingDevice.DRAW_CLEAR_COLOR_ALL, clear)
	rd.draw_list_bind_render_pipeline(list, pipeline)
	rd.draw_list_bind_uniform_set(list, set, 0)
	rd.draw_list_bind_index_array(list, index_array)
	rd.draw_list_draw(list, true, 1)
	rd.draw_list_end()
	rd.submit()
	rd.sync()
	for pair in [["e674-gpu-hdr.bin", output], ["e674-gpu-float.bin", raw], ["e674-gpu-base.bin", base], ["e674-gpu-uv-dx.bin", uv_dx], ["e674-gpu-dy-primitive.bin", dy_primitive]]:
		var filename: String = pair[0]
		FileAccess.open(evidence.path_join(filename), FileAccess.WRITE).store_buffer(rd.texture_get_data(pair[1], 0))
	resources.reverse()
	for rid in resources:
		rd.free_rid(rid)
	rd.free()
	print("E674_GPU_REPLAY_OK")
	quit(0)
