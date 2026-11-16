extends SceneTree

var rd: RenderingDevice
var evidence: String
var diagnostics := false
var resources: Array[RID] = []

func _initialize() -> void:
	call_deferred("run")

func keep(rid: RID) -> RID:
	if not rid.is_valid():
		push_error("E699 HDR replay resource creation failed")
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
		elif a == "--diagnostics":
			diagnostics = true
	assert(not evidence.is_empty())
	rd = RenderingServer.create_local_rendering_device()
	assert(rd != null)
	var src := RDShaderSource.new()
	src.source_vertex = FileAccess.get_file_as_string("res://ear_replay.vert")
	src.source_fragment = FileAccess.get_file_as_string("res://ear_replay.frag")
	var shared_path := ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/custom_forward/materials/clothes_surface.gdshaderinc")
	src.source_fragment = src.source_fragment.replace("// CLOTHES_SURFACE_SHARED", FileAccess.get_file_as_string(shared_path))
	for pair in [["// CHARACTER_LIGHTING_SHARED", "character_lighting.gdshaderinc"], ["// CLOTHES_LIGHTING_SHARED", "clothes_lighting.gdshaderinc"], ["// EAR_LIGHTING_SHARED", "ear_lighting.gdshaderinc"], ["// FACE_SHADOW_SHARED", "face_shadow.gdshaderinc"]]:
		src.source_fragment = src.source_fragment.replace(pair[0], FileAccess.get_file_as_string(shared_path.get_base_dir().path_join(pair[1])))
	if diagnostics:
		src.source_fragment = src.source_fragment.replace("// EAR_DIAGNOSTICS", "surface_out=vec4(base,1); specular_out=parameters; reflection_out=vec4(n,float(gl_PrimitiveID));")
	var spv := rd.shader_compile_spirv_from_source(src)
	assert(spv.compile_error_vertex.is_empty(), spv.compile_error_vertex)
	assert(spv.compile_error_fragment.is_empty(), spv.compile_error_fragment)
	var shader := keep(rd.shader_create_from_spirv(spv))
	var wrap := sampler(true, true)
	var clamp_linear := sampler(false, false)
	var textures := {
		1: dds("e704-texture-185700", RenderingDevice.DATA_FORMAT_BC7_SRGB_BLOCK, 11),
		11: dds("e699-texture-184121", RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM),
		3: dds("e704-texture-187392", RenderingDevice.DATA_FORMAT_BC7_UNORM_BLOCK, 11),
		4: tex(2560,1440,RenderingDevice.DATA_FORMAT_R8_UNORM,FileAccess.get_file_as_bytes(evidence.path_join("e699-mask.bin"))),
		5: dds("e689-texture-173764",RenderingDevice.DATA_FORMAT_R32_SFLOAT),
		9: dds("e689-texture-173767",RenderingDevice.DATA_FORMAT_R8G8_UNORM),
		10: dds("e699-texture-188148",RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM),
		12: cube(),
		14: dds("e689-shadow-atlas",RenderingDevice.DATA_FORMAT_R16_UNORM)
	}
	var nearest_state := RDSamplerState.new()
	nearest_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	nearest_state.repeat_v = nearest_state.repeat_u
	var nearest := keep(rd.sampler_create(nearest_state))
	var uniforms: Array[RDUniform] = []
	for binding in [0,1,3,4,5,6,7,8,9,10,11,12,14,15]:
		var u := RDUniform.new()
		u.binding = binding
		if textures.has(binding):
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			u.add_id(nearest if binding==5 else wrap if binding in [1,2,3] else clamp_linear)
			u.add_id(textures[binding])
		else:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			var names := {0: "e699-postvs-vertex.bin", 6: "e684-cb2.bin", 7: "e684-cb0.bin", 8: "e674-light-binning.bin", 15: "e684-cb1.bin"}
			u.add_id(buffer(names[binding]))
		uniforms.append(u)
	var set := keep(rd.uniform_set_create(uniforms, shader, 0))
	var output := tex(2560, 1440, RenderingDevice.DATA_FORMAT_B10G11R11_UFLOAT_PACK32, PackedByteArray(), 1, true)
	var raw := tex(2560, 1440, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, PackedByteArray(), 1, true)
	var base := tex(2560, 1440, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, PackedByteArray(), 1, true)
	var uv_dx := tex(2560, 1440, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, PackedByteArray(), 1, true)
	var dy_primitive := tex(2560, 1440, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, PackedByteArray(), 1, true)
	var depth_format := RDTextureFormat.new()
	depth_format.width = 2560
	depth_format.height = 1440
	depth_format.format = RenderingDevice.DATA_FORMAT_D32_SFLOAT
	depth_format.usage_bits = RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT
	var depth := keep(rd.texture_create(depth_format, RDTextureView.new()))
	var fb := keep(rd.framebuffer_create([output, raw, base, uv_dx, dy_primitive, depth]))
	var raster := RDPipelineRasterizationState.new()
	raster.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	raster.front_face = RenderingDevice.POLYGON_FRONT_FACE_COUNTER_CLOCKWISE
	var blend := RDPipelineColorBlendState.new()
	for i in 5:
		blend.attachments.append(RDPipelineColorBlendStateAttachment.new())
	var depth_state := RDPipelineDepthStencilState.new()
	depth_state.enable_depth_test = true
	depth_state.enable_depth_write = true
	depth_state.depth_compare_operator = RenderingDevice.COMPARE_OP_GREATER_OR_EQUAL
	var pipeline := keep(rd.render_pipeline_create(shader, rd.framebuffer_get_format(fb), -1, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, raster, RDPipelineMultisampleState.new(), depth_state, blend))
	var index := keep(rd.index_buffer_create(2862, RenderingDevice.INDEX_BUFFER_FORMAT_UINT32, FileAccess.get_file_as_bytes(evidence.path_join("e699-postvs-index.bin"))))
	var index_array := keep(rd.index_array_create(index, 0, 2862))
	var clear := PackedColorArray()
	for i in 5:
		clear.append(Color(0, 0, 0, 0))
	var list := rd.draw_list_begin(fb, RenderingDevice.DRAW_CLEAR_COLOR_ALL | RenderingDevice.DRAW_CLEAR_DEPTH, clear, 0.0)
	rd.draw_list_bind_render_pipeline(list, pipeline)
	rd.draw_list_bind_uniform_set(list, set, 0)
	rd.draw_list_bind_index_array(list, index_array)
	rd.draw_list_draw(list, true, 1)
	rd.draw_list_end()
	rd.submit()
	rd.sync()
	for pair in [["e699-hdr-hdr.bin", output], ["e699-hdr-float.bin", raw], ["e699-hdr-surface.bin", base], ["e699-hdr-specular.bin", uv_dx], ["e699-hdr-reflection.bin", dy_primitive]]:
		FileAccess.open(evidence.path_join(pair[0].replace("e699-hdr-", "e699-hdr-diagnostic-") if diagnostics else pair[0]), FileAccess.WRITE).store_buffer(rd.texture_get_data(pair[1], 0))
	resources.reverse()
	for rid in resources:
		rd.free_rid(rid)
	rd.free()
	print("E699_HDR_REPLAY_OK")
	quit(0)

func cube() -> RID:
	var layers: Array[PackedByteArray] = []
	for face in range(6):
		var data := PackedByteArray()
		for mip in range(8):
			var bytes := FileAccess.get_file_as_bytes(evidence.path_join("e694-cube8600-face%d-mip%d.dds" % [face, mip]))
			assert(bytes.decode_u32(128) == 95)
			data.append_array(bytes.slice(148))
		layers.append(data)
	var f := RDTextureFormat.new()
	f.texture_type = RenderingDevice.TEXTURE_TYPE_CUBE
	f.width = 128
	f.height = 128
	f.array_layers = 6
	f.mipmaps = 8
	f.format = RenderingDevice.DATA_FORMAT_BC6H_UFLOAT_BLOCK
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return keep(rd.texture_create(f, RDTextureView.new(), layers))
