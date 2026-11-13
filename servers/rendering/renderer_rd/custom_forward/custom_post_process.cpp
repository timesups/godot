#include "custom_post_process.h"

#include "core/config/project_settings.h"
#include "core/io/image.h"
#include "core/io/resource_loader.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/texture_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

CustomPostProcess::CustomPostProcess() {
	GLOBAL_DEF("rendering/custom_forward/post_process/enabled", false);
	GLOBAL_DEF(PropertyInfo(Variant::STRING, "rendering/custom_forward/post_process/lut_path", PROPERTY_HINT_FILE, "*.res,*.tres,*.exr"), "");
	GLOBAL_DEF(PropertyInfo(Variant::FLOAT, "rendering/custom_forward/post_process/exposure", PROPERTY_HINT_RANGE, "0,32,0.01,or_greater"), 1.0);
	GLOBAL_DEF(PropertyInfo(Variant::FLOAT, "rendering/custom_forward/post_process/bloom_intensity", PROPERTY_HINT_RANGE, "0,4,0.001,or_greater"), 0.3660402297973633);
	GLOBAL_DEF(PropertyInfo(Variant::FLOAT, "rendering/custom_forward/post_process/bloom_scatter", PROPERTY_HINT_RANGE, "0,1,0.001"), 0.77);
	GLOBAL_DEF(PropertyInfo(Variant::FLOAT, "rendering/custom_forward/post_process/bloom_threshold", PROPERTY_HINT_RANGE, "0,8,0.001,or_greater"), 0.5225216150283813);
	GLOBAL_DEF(PropertyInfo(Variant::FLOAT, "rendering/custom_forward/post_process/sharpness", PROPERTY_HINT_RANGE, "0,1,0.01"), 0.3);
	GLOBAL_DEF("rendering/custom_forward/post_process/vignette", true);
}

void CustomPostProcess::initialize() {
	Vector<String> modes;
	modes.push_back("\n#define MODE_PREFILTER\n");
	modes.push_back("\n#define MODE_DOWNSAMPLE\n");
	modes.push_back("\n#define MODE_UPSAMPLE\n");
	bloom_shader.initialize(modes);
	bloom_version = bloom_shader.version_create();
	for (int i = 0; i < 3; i++) {
		bloom_pipelines[i] = RD::get_singleton()->compute_pipeline_create(bloom_shader.version_get_shader(bloom_version, i));
	}
	modes.clear();
	modes.push_back("");
	grade_shader.initialize(modes);
	grade_version = grade_shader.version_create();
	grade_pipeline.setup(grade_shader.version_get_shader(grade_version, 0), RD::RENDER_PRIMITIVE_TRIANGLES, RD::PipelineRasterizationState(), RD::PipelineMultisampleState(), RD::PipelineDepthStencilState(), RD::PipelineColorBlendState::create_disabled(), 0);
	initialized = true;
}

CustomPostProcess::~CustomPostProcess() {
	if (lut.is_valid()) {
		RD::get_singleton()->free_rid(lut);
	}
	if (initialized) {
		grade_pipeline.clear();
		bloom_shader.version_free(bloom_version);
		grade_shader.version_free(grade_version);
	}
}

bool CustomPostProcess::process(const Ref<RenderSceneBuffersRD> &rb) {
	if (!bool(GLOBAL_GET("rendering/custom_forward/post_process/enabled"))) {
		return false;
	}
	TextureStorage *textures = TextureStorage::get_singleton();
	RID target = rb->get_render_target();
	// This first reconstruction targets the capture's SDR single-view output.
	// Fall back before changing any resources for unsupported output modes.
	bool spatial_scale = rb->get_scaling_3d_mode() == RSE::VIEWPORT_SCALING_3D_MODE_OFF || rb->get_scaling_3d_mode() == RSE::VIEWPORT_SCALING_3D_MODE_BILINEAR || rb->get_scaling_3d_mode() == RSE::VIEWPORT_SCALING_3D_MODE_NEAREST;
	if (!spatial_scale || rb->get_view_count() != 1 || rb->get_internal_size() != rb->get_target_size() || textures->render_target_is_using_hdr(target) || textures->render_target_get_msaa(target) != RSE::VIEWPORT_MSAA_DISABLED || rb->get_screen_space_aa() != RSE::VIEWPORT_SCREEN_SPACE_AA_DISABLED) {
		WARN_PRINT_ONCE("Custom bloom/LUT requires single-view SDR, 100% render scale, no screen-space AA and no 2D MSAA. Using standard post-processing for this viewport.");
		return false;
	}
	String path = GLOBAL_GET("rendering/custom_forward/post_process/lut_path");
	if (path != loaded_path) {
		if (lut.is_valid()) {
			RD::get_singleton()->free_rid(lut);
			lut = RID();
		}
		loaded_path = path;
		// Image resources (.res/.tres) are remapped and packaged by the exporter.
		// Raw EXR is also accepted for external capture-analysis assets.
		Ref<Image> image;
		if (path.get_extension().to_lower() == "exr" && !path.begins_with("res://")) {
			image = Image::load_from_file(path);
		} else {
			image = ResourceLoader::load(path, "Image");
		}
		if (image.is_valid() && image->get_height() >= 2 && image->get_width() == image->get_height() * image->get_height()) {
			image->convert(Image::FORMAT_RGBAH);
			RD::TextureFormat format;
			format.width = image->get_width();
			format.height = image->get_height();
			format.format = RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
			format.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT;
			Vector<Vector<uint8_t>> data;
			data.push_back(image->get_data());
			lut = RD::get_singleton()->texture_create(format, RD::TextureView(), data);
		}
	}
	if (lut.is_null()) {
		WARN_PRINT_ONCE("Custom bloom/LUT needs a linear Image resource (.res/.tres), or an external EXR, of size N*N by N. Set rendering/custom_forward/post_process/lut_path. Using standard post-processing.");
		return false;
	}
	if (!initialized) {
		initialize();
	}
	RD *rd = RD::get_singleton();
	if (!rd->texture_is_format_supported_for_usage(RD::DATA_FORMAT_B10G11R11_UFLOAT_PACK32, RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT)) {
		WARN_PRINT_ONCE("Custom bloom requires R11G11B10 storage images. Using standard post-processing.");
		return false;
	}
	RID sampler = MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	float exposure = MAX(0.0f, float(GLOBAL_GET("rendering/custom_forward/post_process/exposure")));
	float threshold = MAX(0.0f, float(GLOBAL_GET("rendering/custom_forward/post_process/bloom_threshold")));
	float scatter = CLAMP(float(GLOBAL_GET("rendering/custom_forward/post_process/bloom_scatter")), 0.0f, 1.0f);
	float knee = threshold * 0.5f;
	struct Push {
		float size[4];
		float threshold[4];
		float controls[4];
	} push = {};
	push.threshold[0] = threshold;
	push.threshold[1] = threshold - knee - 0.00001f;
	push.threshold[2] = 2.0f * knee + 0.00002f;
	push.threshold[3] = 0.25f / (knee + 0.00001f);
	push.controls[0] = exposure;
	push.controls[1] = scatter;
	push.controls[2] = rb->get_luminance_multiplier();
	RID down[9];
	Size2i sizes[9];
	Size2i full = rb->get_internal_size();
	uint32_t usage = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
	for (int i = 0; i < 9; i++) {
		// Round the full-resolution division independently (45 -> 23 -> 11).
		float divisor = float(1 << (i + 1));
		sizes[i] = Size2i(MAX(1, int(Math::floor(full.x / divisor + 0.5f))), MAX(1, int(Math::floor(full.y / divisor + 0.5f))));
		down[i] = rb->create_texture(SNAME("custom_post_process"), StringName("down_" + itos(i)), RD::DATA_FORMAT_B10G11R11_UFLOAT_PACK32, usage, RD::TEXTURE_SAMPLES_1, sizes[i], 1);
	}
	auto dispatch = [&](int mode, RID source, RID high, RID dest, Size2i size) {
		push.size[0] = size.x;
		push.size[1] = size.y;
		push.size[2] = 1.0f / size.x;
		push.size[3] = 1.0f / size.y;
		RD::Uniform u_source(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ sampler, source }));
		RD::Uniform u_high(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>({ sampler, high }));
		RD::Uniform u_dest(RD::UNIFORM_TYPE_IMAGE, 2, dest);
		RID shader = bloom_shader.version_get_shader(bloom_version, mode);
		RID set = UniformSetCacheRD::get_singleton()->get_cache(shader, 0, u_source, u_high, u_dest);
		RD::ComputeListID list = rd->compute_list_begin();
		rd->compute_list_bind_compute_pipeline(list, bloom_pipelines[mode]);
		rd->compute_list_bind_uniform_set(list, set, 0);
		rd->compute_list_set_push_constant(list, &push, sizeof(push));
		rd->compute_list_dispatch_threads(list, size.x, size.y, 1);
		rd->compute_list_end();
	};
	rd->draw_command_begin_label("Custom Capture Bloom + LUT");
	dispatch(0, rb->get_internal_texture(), rb->get_internal_texture(), down[0], sizes[0]);
	for (int i = 1; i < 9; i++) {
		dispatch(1, down[i - 1], down[i - 1], down[i], sizes[i]);
	}
	RID bloom = down[8];
	for (int i = 7; i >= 0; i--) {
		RID dest = rb->create_texture(SNAME("custom_post_process"), StringName("up_" + itos(i)), RD::DATA_FORMAT_B10G11R11_UFLOAT_PACK32, usage, RD::TEXTURE_SAMPLES_1, sizes[i], 1);
		dispatch(2, bloom, down[i], dest, sizes[i]);
		bloom = dest;
	}
	float grade_push[12] = { exposure, MAX(0.0f, float(GLOBAL_GET("rendering/custom_forward/post_process/bloom_intensity"))), CLAMP(float(GLOBAL_GET("rendering/custom_forward/post_process/sharpness")), 0.0f, 1.0f), rb->get_luminance_multiplier(), 0.9000000358f, 1.2999999523f, 2.0499999523f, bool(GLOBAL_GET("rendering/custom_forward/post_process/vignette")) ? 1.0f : 0.0f, 0.0666666701f, 0.0671745762f, 0.0745098069f, 0.0f };
	RID shader = grade_shader.version_get_shader(grade_version, 0);
	RD::Uniform u_source(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ sampler, rb->get_internal_texture() }));
	RD::Uniform u_bloom(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>({ sampler, bloom }));
	RD::Uniform u_lut(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, Vector<RID>({ sampler, lut }));
	RID set = UniformSetCacheRD::get_singleton()->get_cache(shader, 0, u_source, u_bloom, u_lut);
	RID framebuffer = textures->render_target_get_rd_framebuffer(target);
	RD::DrawListID list = rd->draw_list_begin(framebuffer);
	rd->draw_list_bind_render_pipeline(list, grade_pipeline.get_render_pipeline(RD::INVALID_ID, rd->framebuffer_get_format(framebuffer), false, rd->draw_list_get_current_pass()));
	rd->draw_list_bind_uniform_set(list, set, 0);
	rd->draw_list_set_push_constant(list, grade_push, sizeof(grade_push));
	rd->draw_list_draw(list, false, 1, 3);
	rd->draw_list_end();
	textures->render_target_disable_clear_request(target);
	rd->draw_command_end_label();
	return true;
}
