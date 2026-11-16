extends RefCounted

# Captured post-VS world-space triangles are counterclockwise with respect to
# their outward normals. Godot ArrayMesh front faces use clockwise winding.
# Convert once at the posed-mesh import boundary, not in material shading.
static func godot_indices(captured: PackedInt32Array) -> PackedInt32Array:
	assert(captured.size() % 3 == 0)
	var indices := captured.duplicate()
	for triangle in range(0, indices.size(), 3):
		var second := indices[triangle + 1]
		indices[triangle + 1] = indices[triangle + 2]
		indices[triangle + 2] = second
	return indices
