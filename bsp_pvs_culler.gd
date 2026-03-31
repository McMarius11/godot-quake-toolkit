# SPDX-License-Identifier: MIT
# Copyright (c) 2026 McMarius11
extends Node3D
## Runtime VIS/PVS occlusion culler for Quake BSP maps.
## Attach to the map root. Call setup() after BSP loading.
## Toggles visibility of per-leaf mesh nodes based on camera position.

const Q2G := 0.03125  # Quake unit to Godot meter

var _nodes: Array = []
var _leaves: Array = []
var _planes: Array = []
var _vis_data: PackedByteArray
var _num_leafs: int = 0
var _leaf_nodes: Array = []  # Array[Node3D] — per-leaf mesh nodes to show/hide
var _last_leaf: int = -1
var _enabled: bool = false


func setup(bsp_reader) -> void:
	"""Initialize PVS culler from BSP reader data."""
	if not bsp_reader.has_method("has_vis_data") or not bsp_reader.has_vis_data():
		print("PVS Culler: No VIS data available — culling disabled")
		return

	_nodes = bsp_reader.get_bsp_nodes()
	_leaves = bsp_reader.get_bsp_leaves()
	_planes = bsp_reader.get_planes()
	_vis_data = bsp_reader.get_vis_data()
	_num_leafs = bsp_reader.get_num_leafs()

	if _nodes.is_empty() or _leaves.is_empty():
		print("PVS Culler: No node/leaf data — culling disabled")
		return

	_enabled = true
	print("PVS Culler: Initialized with %d nodes, %d leaves, %d bytes VIS data" % [
		_nodes.size(), _num_leafs, _vis_data.size()])


func register_leaf_meshes(meshes: Array) -> void:
	"""Register per-leaf MeshInstance3D nodes for visibility toggling.
	meshes[i] corresponds to leaf index i. null entries are skipped."""
	_leaf_nodes = meshes


func _physics_process(_delta: float) -> void:
	if not _enabled:
		return
	var cam := get_viewport().get_camera_3d()
	if not cam:
		return

	var leaf_idx := point_in_leaf(cam.global_position)
	if leaf_idx == _last_leaf:
		return  # Same leaf — no update needed
	_last_leaf = leaf_idx
	_update_visibility(leaf_idx)


func point_in_leaf(godot_pos: Vector3) -> int:
	"""Find which BSP leaf contains the given Godot world position."""
	# Convert Godot coords (x, y, z) back to Quake coords (x, -z, y) / Q2G
	var qx: float = godot_pos.x / Q2G
	var qy: float = -godot_pos.z / Q2G
	var qz: float = godot_pos.y / Q2G

	var node_idx: int = 0  # Start at root
	while node_idx >= 0:
		if node_idx >= _nodes.size():
			break
		var node = _nodes[node_idx]
		var plane = _planes[node.plane_id]
		# plane.normal is in Quake coords, plane.dist is Quake distance
		var d: float = qx * plane.normal.x + qy * plane.normal.y + qz * plane.normal.z - plane.dist
		if d >= 0.0:
			node_idx = node.front
		else:
			node_idx = node.back
	# node_idx is negative: leaf index = -(node_idx + 1)
	return -(node_idx + 1)


func _update_visibility(leaf_idx: int) -> void:
	"""Update leaf mesh visibility based on PVS from the current leaf."""
	if leaf_idx < 0 or leaf_idx >= _num_leafs:
		# Outside map — show everything
		for mi in _leaf_nodes:
			if mi is Node3D:
				mi.visible = true
		return

	if leaf_idx < 0 or leaf_idx >= _leaves.size():
		return

	var leaf = _leaves[leaf_idx]
	var pvs := _decompress_vis(leaf.visofs)

	# Toggle visibility for each leaf mesh
	for li in range(_leaf_nodes.size()):
		var mi = _leaf_nodes[li]
		if not (mi is Node3D):
			continue
		if li == leaf_idx:
			mi.visible = true  # Always show current leaf
			continue
		# PVS bit i corresponds to leaf i+1 (leaf 0 = outside solid)
		var pvs_bit: int = li - 1
		if pvs_bit < 0:
			mi.visible = false  # Leaf 0 is never visible
		elif pvs_bit < _num_leafs - 1:
			@warning_ignore("integer_division")
			var byte_idx: int = pvs_bit >> 3
			var bit_idx: int = pvs_bit & 7
			if byte_idx < pvs.size():
				mi.visible = (pvs[byte_idx] & (1 << bit_idx)) != 0
			else:
				mi.visible = true  # Safety: show if out of range
		else:
			mi.visible = true


func _decompress_vis(vis_offset: int) -> PackedByteArray:
	"""Decompress RLE-encoded PVS data for a leaf."""
	@warning_ignore("integer_division")
	var row: int = (_num_leafs + 7) >> 3
	var out := PackedByteArray()
	out.resize(row)

	if vis_offset < 0 or _vis_data.is_empty():
		# No vis data — everything visible
		out.fill(0xFF)
		return out

	var i: int = vis_offset
	var o: int = 0
	while o < row:
		if i >= _vis_data.size():
			break
		if _vis_data[i] != 0:
			out[o] = _vis_data[i]
			i += 1
			o += 1
		else:
			# Zero byte: next byte = count of zero bytes
			if i + 1 >= _vis_data.size():
				break
			var count: int = _vis_data[i + 1]
			i += 2
			for _c in range(count):
				if o < row:
					out[o] = 0
					o += 1

	return out


func get_current_leaf() -> int:
	"""Returns the leaf index the camera is currently in."""
	return _last_leaf


func is_leaf_visible(leaf_idx: int) -> bool:
	"""Check if a specific leaf is currently visible from the camera's leaf."""
	if not _enabled or _last_leaf < 0:
		return true
	if leaf_idx == _last_leaf:
		return true
	var leaf = _leaves[_last_leaf]
	var pvs := _decompress_vis(leaf.visofs)
	var pvs_bit: int = leaf_idx - 1
	if pvs_bit < 0:
		return false
	@warning_ignore("integer_division")
	var byte_idx: int = pvs_bit >> 3
	var bit_idx: int = pvs_bit & 7
	if byte_idx < pvs.size():
		return (pvs[byte_idx] & (1 << bit_idx)) != 0
	return true
