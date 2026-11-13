#pragma once

#include "servers/rendering/renderer_rd/pipeline_cache_rd.h"
#include "servers/rendering/renderer_rd/shaders/custom_forward/custom_bloom.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/custom_forward/custom_grade.glsl.gen.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"

namespace RendererRD {

// Opt-in capture reconstruction. All shaders and render-buffer scopes are private
// to Custom Forward; the shared Godot effects remain untouched.
class CustomPostProcess {
	CustomBloomShaderRD bloom_shader;
	CustomGradeShaderRD grade_shader;
	RID bloom_version;
	RID grade_version;
	RID bloom_pipelines[3];
	PipelineCacheRD grade_pipeline;
	RID lut;
	String loaded_path;
	bool initialized = false;
	void initialize();

public:
	CustomPostProcess();
	~CustomPostProcess();
	bool process(const Ref<RenderSceneBuffersRD> &p_buffers);
};

} // namespace RendererRD
