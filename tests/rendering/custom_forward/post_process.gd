extends SceneTree

# Runs the production shaders on the captured HDR input, without scene differences.
# Usage: --script res://post_process.gd -- --evidence=<MCP export directory>
var rd: RenderingDevice
var evidence: String
var sampler: RID
var allocated: Array[RID] = []

func _initialize() -> void:
	call_deferred("run")

func texture(size: Vector2i, format: int, data: PackedByteArray = PackedByteArray()) -> RID:
	var f := RDTextureFormat.new()
	f.width = size.x
	f.height = size.y
	f.format = format
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var t := rd.texture_create(f, RDTextureView.new(), [] if data.is_empty() else [data])
	allocated.append(t)
	return t

func dds(name: String) -> RID:
	var bytes := FileAccess.get_file_as_bytes(evidence.path_join(name + ".dds"))
	assert(bytes.size() > 148)
	var size := Vector2i(bytes.decode_u32(16), bytes.decode_u32(12))
	var dx10 := bytes.slice(84, 88).get_string_from_ascii() == "DX10"
	var dxgi := bytes.decode_u32(128) if dx10 else 28
	var format := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT if dxgi == 10 else RenderingDevice.DATA_FORMAT_B10G11R11_UFLOAT_PACK32
	if dxgi == 28:
		format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	var data := bytes.slice(148 if dx10 else 128)
	if name == "lut":
		var lut_image := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBAH, data)
		lut_image.save_exr(evidence.path_join("lut.exr"))
		assert(ResourceSaver.save(lut_image, evidence.path_join("lut.res")) == OK)
		var packer := PCKPacker.new()
		assert(packer.pck_start(evidence.path_join("lut-test.pck")) == OK)
		assert(packer.add_file("res://capture_lut.res", evidence.path_join("lut.res")) == OK)
		assert(packer.flush() == OK)
	return texture(size, format, data)

func shader(source: String) -> RID:
	var s := RDShaderSource.new()
	s.source_compute = source
	var spirv := rd.shader_compile_spirv_from_source(s)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		quit(1)
		return RID()
	var result := rd.shader_create_from_spirv(spirv)
	allocated.append(result)
	return result

func dispatch(sh: RID, inputs: Array[RID], output: RID, size: Vector2i, push: PackedFloat32Array) -> void:
	var uniforms: Array[RDUniform] = []
	for i in inputs.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u.binding = i
		u.add_id(sampler)
		u.add_id(inputs[i])
		uniforms.append(u)
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = inputs.size()
	u.add_id(output)
	uniforms.append(u)
	var uniform_set := rd.uniform_set_create(uniforms, sh, 0)
	var pipeline := rd.compute_pipeline_create(sh)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, push.to_byte_array(), push.size() * 4)
	rd.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	rd.free_rid(uniform_set)
	rd.free_rid(pipeline)

func save_raw(name: String, tex: RID) -> void:
	FileAccess.open(evidence.path_join(name + ".bin"), FileAccess.WRITE).store_buffer(rd.texture_get_data(tex, 0))

func run() -> void:
	var root_dir := ProjectSettings.globalize_path("res://../../..")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence="):
			evidence = arg.trim_prefix("--evidence=")
	assert(not evidence.is_empty())
	rd = RenderingServer.create_local_rendering_device()
	assert(rd != null)
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler = rd.sampler_create(state)
	var source := dds("hdr-input")
	var lut := dds("lut")
	var bloom_source := FileAccess.get_file_as_string(root_dir.path_join("servers/rendering/renderer_rd/shaders/custom_forward/custom_bloom.glsl")).replace("#[compute]", "")
	var shaders: Array[RID] = []
	for mode in ["MODE_PREFILTER", "MODE_DOWNSAMPLE", "MODE_UPSAMPLE"]:
		shaders.append(shader(bloom_source.replace("#VERSION_DEFINES", "#define " + mode)))
	var down: Array[RID] = []
	var sizes: Array[Vector2i] = []
	for i in 9:
		var divisor := pow(2.0, i + 1)
		var size := Vector2i(maxi(1, int(floor(2560.0 / divisor + 0.5))), maxi(1, int(floor(1440.0 / divisor + 0.5))))
		sizes.append(size)
		down.append(texture(size, RenderingDevice.DATA_FORMAT_B10G11R11_UFLOAT_PACK32))
		var push := PackedFloat32Array([size.x, size.y, 1.0 / size.x, 1.0 / size.y, 0.5225216150283813, 0.2612507939338684, 0.5225416421890259, 0.9568615555763245, 1, 0.77, 1, 0])
		var input := source if i == 0 else down[i - 1]
		dispatch(shaders[0 if i == 0 else 1], [input, input], down[i], size, push)
		if i < 2:
			save_raw("candidate-prefilter" if i == 0 else "candidate-down", down[i])
	var bloom := down[8]
	for i in range(7, -1, -1):
		var size := sizes[i]
		var dest := texture(size, RenderingDevice.DATA_FORMAT_B10G11R11_UFLOAT_PACK32)
		dispatch(shaders[2], [bloom, down[i]], dest, size, PackedFloat32Array([size.x, size.y, 1.0 / size.x, 1.0 / size.y, 0, 0, 0, 0, 1, 0.77, 1, 0]))
		bloom = dest
	save_raw("candidate-bloom", bloom)
	var grade_source := FileAccess.get_file_as_string(root_dir.path_join("servers/rendering/renderer_rd/shaders/custom_forward/custom_grade_inc.glsl"))
	var grade := shader("#version 450\n" + grade_source + "\nlayout(local_size_x=8,local_size_y=8) in;\nlayout(rgba8,set=0,binding=3) uniform writeonly image2D dst;\nvoid main(){ivec2 p=ivec2(gl_GlobalInvocationID.xy);if(any(greaterThanEqual(p,imageSize(dst))))return;vec2 uv=(vec2(p)+0.5)/vec2(imageSize(dst));imageStore(dst,p,vec4(encode_output(grade(uv),uv),1));}")
	var result := texture(Vector2i(2560,1440), RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	var push := PackedFloat32Array([1, 0.3660402297973633, 0.3, 1, 0.9000000358, 1.2999999523, 2.0499999523, 1, 0.0666666701, 0.0671745762, 0.0745098069, 0])
	dispatch(grade, [source, bloom, lut], result, Vector2i(2560,1440), push)
	save_raw("candidate-post", result)
	Image.create_from_data(2560,1440,false,Image.FORMAT_RGBA8,rd.texture_get_data(result,0)).save_png(evidence.path_join("candidate-post.png"))
	dispatch(grade, [source, dds("bloom-reference"), lut], result, Vector2i(2560,1440), push)
	save_raw("candidate-grade-only", result)
	# Shader deletion also releases its dependent GPU objects.
	for rid in allocated:
		rd.free_rid(rid)
	rd.free_rid(sampler)
	rd.free()
	print("CUSTOM_POST_GPU_OK")
	quit(0)
