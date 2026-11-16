extends SceneTree

var rd: RenderingDevice
var evidence: String
var resources: Array[RID] = []

func _initialize() -> void:
	call_deferred("run")

func keep(rid: RID) -> RID:
	if not rid.is_valid():
		push_error("E694 surface replay resource creation failed")
		quit(1)
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
		var mip_bytes := FileAccess.get_file_as_bytes(evidence.path_join(name + "-mip%d.dds" % mip))
		data.append_array(mip_bytes.slice(148 if mip_bytes.slice(84, 88).get_string_from_ascii() == "DX10" else 128))
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
	src.source_vertex = FileAccess.get_file_as_string("res://clothes_surface_replay.vert")
	src.source_fragment = FileAccess.get_file_as_string("res://clothes_surface_replay.frag")
	var shared_path := ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/custom_forward/materials/clothes_surface.gdshaderinc")
	src.source_fragment = src.source_fragment.replace("// CLOTHES_SURFACE_SHARED", FileAccess.get_file_as_string(shared_path))
	var spv := rd.shader_compile_spirv_from_source(src)
	assert(spv.compile_error_vertex.is_empty(), spv.compile_error_vertex)
	assert(spv.compile_error_fragment.is_empty(), spv.compile_error_fragment)
	var shader := keep(rd.shader_create_from_spirv(spv))
	var wrap := sampler(true, true)
	var clamp_linear := sampler(false, false)
	var textures: Array[RID] = [
		dds("e694-texture-187399", RenderingDevice.DATA_FORMAT_BC7_SRGB_BLOCK, 12),
		dds("e694-texture-187429", RenderingDevice.DATA_FORMAT_BC5_UNORM_BLOCK, 12),
		dds("e694-texture-187402", RenderingDevice.DATA_FORMAT_BC7_UNORM_BLOCK, 12),
		tex(2560, 1440, RenderingDevice.DATA_FORMAT_R8_UNORM, FileAccess.get_file_as_bytes(evidence.path_join("e694-mask.bin"))),
		dds("e689-texture-173764", RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	]
	var uniforms: Array[RDUniform] = []
	for binding in range(6):
		var u := RDUniform.new()
		u.binding = binding
		if binding > 0:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			u.add_id(wrap if binding <= 3 else clamp_linear)
			u.add_id(textures[binding - 1])
		else:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.add_id(buffer("e694-postvs-vertex.bin"))
		uniforms.append(u)
	var set := keep(rd.uniform_set_create(uniforms, shader, 0))
	var output := tex(2560, 1440, RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB, PackedByteArray(), 1, true)
	var raw := tex(2560, 1440, RenderingDevice.DATA_FORMAT_A2B10G10R10_UNORM_PACK32, PackedByteArray(), 1, true)
	var base := tex(2560, 1440, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, PackedByteArray(), 1, true)
	var uv_dx := tex(2560, 1440, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, PackedByteArray(), 1, true)
	var dy_primitive := tex(2560, 1440, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, PackedByteArray(), 1, true)
	var fb := keep(rd.framebuffer_create([output, raw, base, uv_dx, dy_primitive]))
	var raster := RDPipelineRasterizationState.new()
	raster.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	raster.front_face = RenderingDevice.POLYGON_FRONT_FACE_COUNTER_CLOCKWISE
	var blend := RDPipelineColorBlendState.new()
	for i in 5:
		blend.attachments.append(RDPipelineColorBlendStateAttachment.new())
	var pipeline := keep(rd.render_pipeline_create(shader, rd.framebuffer_get_format(fb), -1, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, raster, RDPipelineMultisampleState.new(), RDPipelineDepthStencilState.new(), blend))
	var index := keep(rd.index_buffer_create(114840, RenderingDevice.INDEX_BUFFER_FORMAT_UINT16, FileAccess.get_file_as_bytes(evidence.path_join("e694-postvs-index.bin"))))
	var index_array := keep(rd.index_array_create(index, 0, 114840))
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
	for pair in [["e694-surface-base.bin", output], ["e694-surface-normal.bin", raw], ["e694-surface-parameters.bin", base], ["e694-surface-diffuse.bin", uv_dx], ["e694-surface-f0.bin", dy_primitive]]:
		FileAccess.open(evidence.path_join(pair[0]), FileAccess.WRITE).store_buffer(rd.texture_get_data(pair[1], 0))
	resources.reverse()
	for rid in resources:
		rd.free_rid(rid)
	rd.free()
	print("E694_SURFACE_REPLAY_OK")
	quit(0)
