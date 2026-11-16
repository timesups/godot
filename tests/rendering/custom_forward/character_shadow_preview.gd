extends RefCounted

# Only for the isolated, roughly two-unit posed-character preview at distance 3.
# Orthographic directional cascades use camera.far, not shadow_max_distance.
static func configure(camera: Camera3D, sun: DirectionalLight3D) -> void:
	camera.far = 6.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = false
	sun.directional_shadow_max_distance = 6.0
	sun.directional_shadow_pancake_size = 2.0
	sun.shadow_bias = 0.05
	sun.shadow_normal_bias = 1.0
	sun.light_angular_distance = 2.0
	RenderingServer.directional_shadow_atlas_set_size(2048, false)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
