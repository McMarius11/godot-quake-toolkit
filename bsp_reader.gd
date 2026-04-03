# SPDX-License-Identifier: MIT
# Copyright (c) 2026 McMarius11
class_name BSPReader
## Reads BSP29 (Quake 1) files and generates a Godot scene tree with
## visual meshes, collision, and parsed entity data.
##
## Usage:
##   var reader := BSPReader.new()
##   var root := reader.read_bsp("res://maps/mymap.bsp")
##   add_child(root)

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

const BSP_VERSION := 29
const SCALE := 0.03125  # 1/32 — same Q2G used throughout the project

# Lump indices
const LUMP_ENTITIES    := 0
const LUMP_PLANES      := 1
const LUMP_MIPTEX      := 2
const LUMP_VERTICES    := 3
const LUMP_VIS         := 4
const LUMP_NODES       := 5
const LUMP_TEXINFO     := 6
const LUMP_FACES       := 7
const LUMP_LIGHTING    := 8
const LUMP_CLIPNODES   := 9
const LUMP_LEAVES      := 10
const LUMP_MARKSURFACES := 11
const LUMP_EDGES       := 12
const LUMP_SURFEDGES   := 13
const LUMP_MODELS      := 14
const NUM_LUMPS        := 15

# Invisible texture prefixes — skip these faces visually
const SKIP_TEXTURE_NAMES: PackedStringArray = [
	"trigger", "clip", "skip", "hint", "null",
	"origin", "aaatrigger",
]

# --------------------------------------------------------------------------- #
# Internal data structures
# --------------------------------------------------------------------------- #

var _lumps: Array[Dictionary] = []  # [{offset, size}, ...]

var _vertices: PackedVector3Array = PackedVector3Array()
var _edges: Array[Vector2i] = []  # pairs of vertex indices
var _surfedges: PackedInt32Array = PackedInt32Array()

# Face struct
class BSPFace:
	var plane_id: int
	var side: int
	var surfedge_start: int
	var surfedge_count: int
	var texinfo_id: int
	var styles: PackedByteArray
	var lightmap_offset: int

var _faces: Array[BSPFace] = []

# Texinfo struct
class BSPTexinfo:
	var s_vec: Vector3
	var s_offset: float
	var t_vec: Vector3
	var t_offset: float
	var miptex_index: int
	var flags: int

var _texinfos: Array[BSPTexinfo] = []

# Plane struct
class BSPPlane:
	var normal: Vector3
	var dist: float
	var type: int

var _planes: Array[BSPPlane] = []

# Model struct
class BSPModel:
	var mins: Vector3
	var maxs: Vector3
	var origin: Vector3
	var headnodes: PackedInt32Array  # 4 entries
	var visleafs: int
	var firstface: int
	var numfaces: int

var _models: Array[BSPModel] = []

# Miptex
class BSPMiptex:
	var name: String
	var width: int
	var height: int
	var pixels: PackedByteArray  # raw indexed pixels (mip 0 only)

var _miptextures: Array[BSPMiptex] = []

# Node struct (BSP tree)
class BSPNode:
	var plane_id: int
	var front: int    # positive = node index, negative = -(leaf_index + 1)
	var back: int

# Leaf struct (BSP tree)
class BSPLeaf:
	var contents: int
	var visofs: int
	var first_marksurface: int
	var num_marksurfaces: int

# Entities parsed from the entity lump
var _entities: Array[Dictionary] = []

# Material cache: texture name -> StandardMaterial3D
var _material_cache: Dictionary = {}

# Quake palette for decoding miptex pixel data
var _quake_palette: PackedByteArray = PackedByteArray()

## Optional WAD texture loader callback.
## Signature: func(wad_path: String, tex_name: String) -> ImageTexture
## Set this before calling read_bsp() if you want WAD texture support.
## If null, textures are decoded from BSP embedded miptex data instead.
var wad_texture_loader: Callable = Callable()

# VIS/PVS data structures
var _bsp_nodes: Array = []
var _bsp_leaves: Array = []
var _marksurfaces: PackedInt32Array = PackedInt32Array()
var _vis_data: PackedByteArray = PackedByteArray()
var _num_leafs: int = 0

# Lightmap data from LUMP_LIGHTING
var _lighting_data: PackedByteArray = PackedByteArray()

# Shared lightmap shader (lazy-initialized)
var _lightmap_shader: Shader = null
var _lightmap_anim_shader: Shader = null  # Shader for animated textures with lightmaps
var _anim_shader: Shader = null           # Shader for animated textures without lightmaps

# Last atlas build result (for animator setup)
var _last_atlas_result: Dictionary = {}

# Per-face computed geometry (populated by _build_model_mesh(0) for leaf mesh building)
var _face_geometry: Array = []  # Per-face: {verts, uvs, uv2s, normals, surf_key} or null

# Atlas references for reuse by build_leaf_meshes()
var _last_static_atlas: ImageTexture = null
var _last_anim_atlas: ImageTexture = null

# Lightmap info per face (used during mesh building)
class FaceLightInfo:
	var lm_width: int
	var lm_height: int
	var texmins_s: float
	var texmins_t: float
	var atlas_x: int = 0
	var atlas_y: int = 0

## BSP29 standard light animation patterns (styles 0-11).
## Each character maps to a brightness level: 'a'=dark, 'm'=normal, 'z'=bright.
## These patterns are part of the BSP29 format specification — maps reference
## styles by index, so correct rendering requires matching pattern data.
const LIGHT_STYLE_PATTERNS: Array[String] = [
	"m",
	"mmnmmommommnonmmonqnmmo",
	"abcdefghijklmnopqrstuvwxyzyxwvutsrqponmlkjihgfedcba",
	"mmmmmaaaaammmmmaaaaaabcdefgabcdefg",
	"mamamamamama",
	"jklmnopqrstuvwxyzyxwvutsrqponmlkj",
	"nmonqnmomnmomomno",
	"mmmaaaabcdefgmmmmaaaammmaamm",
	"mmmaaammmaaammmabcdefaaaammmmabcdefmmmaaaa",
	"aaaaaaaazzzzzzzz",
	"mmamammmmammamamaaamammma",
	"abcdefghijklmnopqrrqponmlkjihgfedcba",
]


# --------------------------------------------------------------------------- #
# Coordinate conversion
# --------------------------------------------------------------------------- #

static func q2g(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y) * SCALE


## Get the AABB center in Quake coordinates for a brush model.
## Used to center brush entity geometry at the node origin so that
## moving the node (e.g. func_door) moves the geometry correctly.
func _get_model_center_quake(model_idx: int) -> Vector3:
	if model_idx <= 0 or model_idx >= _models.size():
		return Vector3.ZERO
	var model := _models[model_idx]
	return (model.mins + model.maxs) * 0.5


# --------------------------------------------------------------------------- #
# Public API
# --------------------------------------------------------------------------- #

## Main entry point. Reads a .bsp file and returns a Node3D tree.
## The returned node contains:
##   - Child "worldspawn": MeshInstance3D + StaticBody3D for model 0
##   - Children for each brush entity model (1..N)
##   - entity_data property with the parsed entity array
func read_bsp(path: String) -> Node3D:
	var abs_path := path
	if path.begins_with("res://"):
		abs_path = ProjectSettings.globalize_path(path)

	var f := FileAccess.open(abs_path, FileAccess.READ)
	if not f:
		push_error("BSPReader: Cannot open file: %s" % abs_path)
		return null

	# Read header
	if not _read_header(f):
		push_error("BSPReader: Invalid BSP header in %s" % abs_path)
		return null

	# Read all lumps
	_read_vertices(f)
	_read_edges(f)
	_read_surfedges(f)
	_read_planes(f)
	_read_texinfo(f)
	_read_miptex(f)
	_read_faces(f)
	_read_lighting(f)
	_read_models(f)
	_read_entities(f)
	_read_nodes(f)
	_read_leaves(f)
	_read_marksurfaces(f)
	_read_vis(f)

	f.close()

	# Pre-populate texture directory cache to avoid frame hitch on first lookup
	_populate_texture_dir_cache()

	# Build scene tree
	var root := Node3D.new()
	root.name = path.get_file().get_basename()

	# Model 0 = worldspawn geometry
	var world_mesh := _build_model_mesh(0)
	if world_mesh:
		world_mesh.name = "worldspawn_mesh"
		root.add_child(world_mesh)
		world_mesh.owner = root

		# Animated lightmaps for worldspawn
		if not _last_atlas_result.is_empty():
			var anim_faces: Array[Dictionary] = _last_atlas_result.get("animated_faces", [])
			if anim_faces.size() > 0:
				var animator := Node.new()
				animator.name = "LightmapAnimator"
				animator.set_script(load("res://scripts/lightmap_animator.gd"))
				root.add_child(animator)
				animator.owner = root
				animator.setup(
					_last_atlas_result.atlas_image,
					_last_atlas_result.atlas,
					anim_faces
				)

		# Collision for worldspawn
		var world_body := StaticBody3D.new()
		world_body.name = "worldspawn_collision"
		world_body.collision_layer = CollisionLayers.WORLD
		world_body.collision_mask = 0
		root.add_child(world_body)
		world_body.owner = root

		var trimesh := _build_model_collision_trimesh(0)
		if trimesh:
			var col_shape := CollisionShape3D.new()
			col_shape.shape = trimesh
			col_shape.name = "col"
			world_body.add_child(col_shape)
			col_shape.owner = root

		# Build liquid volumes (Area3D for water/lava/slime detection)
		_build_liquid_volumes(0, root)

	# Brush entity models (model 1..N)
	# These are referenced by brush entities via their "model" key ("*1", "*2", etc.)
	# First, build a map of model_key -> entity dict for spawnflag filtering
	var _model_to_entity: Dictionary = {}
	for ent in _entities:
		var model_key: String = ent.get("model", "")
		if model_key.begins_with("*"):
			_model_to_entity[model_key] = ent

	var brush_models: Dictionary = {}  # model_index -> Node3D
	var skipped_sp := 0
	for i in range(1, _models.size()):
		# Quake difficulty filtering: remove entities not meant for singleplayer
		# Bits 8/9/10 (256/512/1024) = NOT_ON_EASY/NORMAL/HARD
		var model_key := "*%d" % i
		if model_key in _model_to_entity:
			var ent: Dictionary = _model_to_entity[model_key]
			var sf := int(ent.get("spawnflags", "0"))
			# For singleplayer normal (skill 1): remove if bit 9 (512) is set
			if sf & 512:
				skipped_sp += 1
				continue

		var model_node := _build_brush_entity_node(i, root)
		if model_node:
			brush_models[i] = model_node
			root.add_child(model_node)
			model_node.owner = root
			_set_owner_recursive(model_node, root)

	if skipped_sp > 0:
		print("BSPReader: Skipped %d brush models (not in singleplayer normal)" % skipped_sp)

	# Filter point entities by difficulty spawnflags (singleplayer normal = skill 1)
	var filtered_entities: Array[Dictionary] = []
	var skipped_point := 0
	for ent in _entities:
		var sf := int(ent.get("spawnflags", "0"))
		# Bit 9 (512) = NOT_ON_NORMAL → skip for singleplayer
		if sf & 512:
			# But keep worldspawn (entity 0) always
			if ent.get("classname", "") != "worldspawn":
				skipped_point += 1
				continue
		filtered_entities.append(ent)
	_entities = filtered_entities
	if skipped_point > 0:
		print("BSPReader: Filtered %d point entities (not in singleplayer normal)" % skipped_point)

	# Store parsed data for the entity spawner
	root.set_meta("entities", _entities)
	root.set_meta("brush_models", brush_models)

	var total_faces := _faces.size()
	var total_verts := _vertices.size()
	var total_models := _models.size()
	print("BSPReader: Loaded %s — %d vertices, %d faces, %d models, %d entities" % [
		path.get_file(), total_verts, total_faces, total_models, _entities.size()
	])

	return root


## Access parsed entities after read_bsp().
func get_entities() -> Array[Dictionary]:
	return _entities


## PVS data accessors — used by external PVS culler scripts.
func get_bsp_nodes() -> Array: return _bsp_nodes
func get_bsp_leaves() -> Array: return _bsp_leaves
func get_marksurfaces() -> PackedInt32Array: return _marksurfaces
func get_vis_data() -> PackedByteArray: return _vis_data
func get_num_leafs() -> int: return _num_leafs
func get_planes() -> Array: return _planes
func has_vis_data() -> bool: return not _vis_data.is_empty()


# --------------------------------------------------------------------------- #
# Header
# --------------------------------------------------------------------------- #

func _read_header(f: FileAccess) -> bool:
	var version := f.get_32()
	if version != BSP_VERSION:
		push_error("BSPReader: Expected version %d, got %d" % [BSP_VERSION, version])
		return false

	_lumps.clear()
	for i in NUM_LUMPS:
		var offset := f.get_32()
		var size := f.get_32()
		_lumps.append({offset = offset, size = size})

	return true


# --------------------------------------------------------------------------- #
# Lump readers
# --------------------------------------------------------------------------- #

func _read_vertices(f: FileAccess) -> void:
	var lump := _lumps[LUMP_VERTICES]
	f.seek(lump.offset)
	var count: int = lump.size / 12  # 3 floats x 4 bytes
	_vertices.resize(count)
	for i in count:
		var x := f.get_float()
		var y := f.get_float()
		var z := f.get_float()
		_vertices[i] = Vector3(x, y, z)


func _read_edges(f: FileAccess) -> void:
	var lump := _lumps[LUMP_EDGES]
	f.seek(lump.offset)
	var count: int = lump.size / 4  # 2 x uint16
	_edges.resize(count)
	for i in count:
		var v0 := f.get_16() & 0xFFFF  # unsigned uint16
		var v1 := f.get_16() & 0xFFFF
		_edges[i] = Vector2i(v0, v1)


func _read_surfedges(f: FileAccess) -> void:
	var lump := _lumps[LUMP_SURFEDGES]
	f.seek(lump.offset)
	var count: int = lump.size / 4  # int32
	_surfedges.resize(count)
	for i in count:
		_surfedges[i] = _get_int32(f)


func _read_planes(f: FileAccess) -> void:
	var lump := _lumps[LUMP_PLANES]
	f.seek(lump.offset)
	var count: int = lump.size / 20  # 3 floats + 1 float + 1 int32
	_planes.resize(count)
	for i in count:
		var p := BSPPlane.new()
		p.normal = Vector3(f.get_float(), f.get_float(), f.get_float())
		p.dist = f.get_float()
		p.type = _get_int32(f)
		_planes[i] = p


func _read_texinfo(f: FileAccess) -> void:
	var lump := _lumps[LUMP_TEXINFO]
	f.seek(lump.offset)
	var count: int = lump.size / 40
	_texinfos.resize(count)
	for i in count:
		var ti := BSPTexinfo.new()
		ti.s_vec = Vector3(f.get_float(), f.get_float(), f.get_float())
		ti.s_offset = f.get_float()
		ti.t_vec = Vector3(f.get_float(), f.get_float(), f.get_float())
		ti.t_offset = f.get_float()
		ti.miptex_index = f.get_32()
		ti.flags = f.get_32()
		_texinfos[i] = ti


func _read_faces(f: FileAccess) -> void:
	var lump := _lumps[LUMP_FACES]
	f.seek(lump.offset)
	var count: int = lump.size / 20
	_faces.resize(count)
	for i in count:
		var face := BSPFace.new()
		face.plane_id = f.get_16() & 0xFFFF
		face.side = f.get_16() & 0xFFFF
		face.surfedge_start = _get_int32(f)
		face.surfedge_count = f.get_16() & 0xFFFF
		face.texinfo_id = f.get_16() & 0xFFFF
		face.styles = PackedByteArray()
		face.styles.resize(4)
		for s in 4:
			face.styles[s] = f.get_8()
		face.lightmap_offset = _get_int32(f)
		_faces[i] = face


func _read_models(f: FileAccess) -> void:
	var lump := _lumps[LUMP_MODELS]
	f.seek(lump.offset)
	var count: int = lump.size / 64
	_models.resize(count)
	for i in count:
		var m := BSPModel.new()
		m.mins = Vector3(f.get_float(), f.get_float(), f.get_float())
		m.maxs = Vector3(f.get_float(), f.get_float(), f.get_float())
		m.origin = Vector3(f.get_float(), f.get_float(), f.get_float())
		m.headnodes = PackedInt32Array()
		m.headnodes.resize(4)
		for h in 4:
			m.headnodes[h] = _get_int32(f)
		m.visleafs = _get_int32(f)
		m.firstface = _get_int32(f)
		m.numfaces = _get_int32(f)
		_models[i] = m


func _read_miptex(f: FileAccess) -> void:
	var lump := _lumps[LUMP_MIPTEX]
	if lump.size == 0:
		return
	f.seek(lump.offset)
	var nummiptex := _get_int32(f)
	var offsets: PackedInt32Array = PackedInt32Array()
	offsets.resize(nummiptex)
	for i in nummiptex:
		offsets[i] = _get_int32(f)

	_miptextures.resize(nummiptex)
	for i in nummiptex:
		var mt := BSPMiptex.new()
		if offsets[i] < 0:
			# Invalid offset — external texture
			mt.name = ""
			mt.width = 64
			mt.height = 64
			_miptextures[i] = mt
			continue

		var tex_offset: int = lump.offset + offsets[i]
		f.seek(tex_offset)

		# Read name (16 bytes, null-terminated)
		var name_bytes := f.get_buffer(16)
		var null_pos := 16
		for j in 16:
			if name_bytes[j] == 0:
				null_pos = j
				break
		mt.name = name_bytes.slice(0, null_pos).get_string_from_ascii()

		mt.width = f.get_32()
		mt.height = f.get_32()

		# 4 mip offsets
		var mip_offsets: PackedInt32Array = PackedInt32Array()
		mip_offsets.resize(4)
		for m in 4:
			mip_offsets[m] = f.get_32()

		# Read mip level 0 pixel data if offset is valid
		if mip_offsets[0] > 0 and mt.width > 0 and mt.height > 0:
			f.seek(tex_offset + mip_offsets[0])
			var pixel_count: int = mt.width * mt.height
			mt.pixels = f.get_buffer(pixel_count)
		else:
			mt.pixels = PackedByteArray()

		_miptextures[i] = mt


func _read_entities(f: FileAccess) -> void:
	var lump := _lumps[LUMP_ENTITIES]
	f.seek(lump.offset)
	var raw := f.get_buffer(lump.size)
	# Strip trailing null bytes
	var text := raw.get_string_from_ascii()
	_entities = _parse_entity_lump(text)


func _read_lighting(f: FileAccess) -> void:
	var lump := _lumps[LUMP_LIGHTING]
	if lump.size == 0:
		_lighting_data = PackedByteArray()
		return
	f.seek(lump.offset)
	_lighting_data = f.get_buffer(lump.size)
	print("BSPReader: Lighting lump: %d bytes" % _lighting_data.size())


func _read_nodes(f: FileAccess) -> void:
	var lump := _lumps[LUMP_NODES]
	f.seek(lump.offset)
	@warning_ignore("INTEGER_DIVISION")
	var count: int = lump.size / 24
	_bsp_nodes.resize(count)
	for i in count:
		var n := BSPNode.new()
		n.plane_id = _get_int32(f)
		var front_raw: int = f.get_16()
		var back_raw: int = f.get_16()
		# BSP29: if >= 0x8000 (bit 15 set), it's a leaf: -(value - 0x10000) - 1
		if front_raw >= 0x8000:
			n.front = -(0x10000 - front_raw)
		else:
			n.front = front_raw
		if back_raw >= 0x8000:
			n.back = -(0x10000 - back_raw)
		else:
			n.back = back_raw
		f.get_buffer(12)  # skip bbox (6 x int16)
		f.get_16()  # skip face_id
		f.get_16()  # skip face_num
		_bsp_nodes[i] = n


func _read_leaves(f: FileAccess) -> void:
	var lump := _lumps[LUMP_LEAVES]
	f.seek(lump.offset)
	@warning_ignore("INTEGER_DIVISION")
	var count: int = lump.size / 28
	_bsp_leaves.resize(count)
	_num_leafs = count
	for i in count:
		var l := BSPLeaf.new()
		l.contents = _get_int32(f)
		l.visofs = _get_int32(f)
		f.get_buffer(12)  # skip bbox
		l.first_marksurface = f.get_16() & 0xFFFF
		l.num_marksurfaces = f.get_16() & 0xFFFF
		f.get_buffer(4)   # skip ambient levels
		_bsp_leaves[i] = l


func _read_marksurfaces(f: FileAccess) -> void:
	var lump := _lumps[LUMP_MARKSURFACES]
	f.seek(lump.offset)
	@warning_ignore("INTEGER_DIVISION")
	var count: int = lump.size / 2
	_marksurfaces.resize(count)
	for i in count:
		_marksurfaces[i] = f.get_16() & 0xFFFF


func _read_vis(f: FileAccess) -> void:
	var lump := _lumps[LUMP_VIS]
	if lump.size == 0:
		_vis_data = PackedByteArray()
		return
	f.seek(lump.offset)
	_vis_data = f.get_buffer(lump.size)


# --------------------------------------------------------------------------- #
# Entity lump parser
# --------------------------------------------------------------------------- #

static func _parse_entity_lump(text: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var i := 0
	var length := text.length()

	while i < length:
		# Find opening brace
		var open := text.find("{", i)
		if open < 0:
			break
		var close := text.find("}", open)
		if close < 0:
			break

		var block := text.substr(open + 1, close - open - 1)
		var ent := _parse_entity_block(block)
		result.append(ent)
		i = close + 1

	return result


static func _parse_entity_block(block: String) -> Dictionary:
	var ent: Dictionary = {}
	var regex := RegEx.new()
	regex.compile("\"([^\"]+)\"\\s+\"([^\"]*)\"")
	var matches := regex.search_all(block)
	for m in matches:
		ent[m.get_string(1)] = m.get_string(2)
	return ent


# --------------------------------------------------------------------------- #
# Face vertex extraction (Quake space)
# --------------------------------------------------------------------------- #

func _get_face_vertices_raw(face: BSPFace) -> PackedVector3Array:
	var verts := PackedVector3Array()
	for se_i in range(face.surfedge_start, face.surfedge_start + face.surfedge_count):
		if se_i >= _surfedges.size():
			continue
		var se := _surfedges[se_i]
		var vert_idx: int
		if se >= 0:
			if se < _edges.size():
				vert_idx = _edges[se].x
			else:
				continue
		else:
			var neg_se := -se
			if neg_se < _edges.size():
				vert_idx = _edges[neg_se].y
			else:
				continue
		if vert_idx < _vertices.size():
			verts.append(_vertices[vert_idx])
	return verts


# --------------------------------------------------------------------------- #
# Mesh generation (with lightmap support)
# --------------------------------------------------------------------------- #

func _build_model_mesh(model_idx: int) -> MeshInstance3D:
	if model_idx >= _models.size():
		return null

	var model := _models[model_idx]

	# For brush entities (model > 0), center geometry at AABB midpoint
	# so the node position can be used to move the entity correctly.
	var center_offset: Vector3 = _get_model_center_quake(model_idx)

	# Phase 1: Build ONE combined atlas, then split animated faces into a second small atlas
	var face_lm: Dictionary = {}
	var static_atlas_tex: ImageTexture = null
	var anim_atlas_tex: ImageTexture = null
	var static_atlas_w := 0
	var anim_atlas_w := 0
	var anim_face_lm: Dictionary = {}  # fi -> FaceLightInfo (in animated atlas coords)

	_last_atlas_result = {}
	if _lighting_data.size() > 0:
		var full_result := _build_lightmap_atlas(model_idx)
		if not full_result.is_empty():
			face_lm = full_result.face_info
			static_atlas_tex = full_result.atlas
			static_atlas_w = full_result.atlas_size
			var animated_faces: Array[Dictionary] = full_result.get("animated_faces", [])

			# Build a SMALL separate atlas for animated faces only
			if animated_faces.size() > 0:
				var anim_result := _build_animated_sub_atlas(animated_faces, full_result.atlas_image, face_lm)
				if not anim_result.is_empty():
					anim_atlas_tex = anim_result.atlas
					anim_atlas_w = anim_result.atlas_size
					anim_face_lm = anim_result.face_info
					_last_atlas_result = anim_result

	# Store atlas references for build_leaf_meshes()
	if model_idx == 0:
		_last_static_atlas = static_atlas_tex
		_last_anim_atlas = anim_atlas_tex

	# Safe UV2
	var static_safe_uv := Vector2.ZERO
	if static_atlas_tex and static_atlas_w > 0:
		static_safe_uv = Vector2(
			(float(static_atlas_w) - 0.5) / float(static_atlas_w),
			(float(static_atlas_w) - 0.5) / float(static_atlas_w)
		)
	var anim_safe_uv := Vector2.ZERO
	if anim_atlas_tex and anim_atlas_w > 0:
		anim_safe_uv = Vector2(
			(float(anim_atlas_w) - 0.5) / float(anim_atlas_w),
			(float(anim_atlas_w) - 0.5) / float(anim_atlas_w)
		)

	# Phase 2: Group faces by texture + animated flag
	var surfaces: Dictionary = {}

	for fi in range(model.firstface, model.firstface + model.numfaces):
		if fi >= _faces.size():
			continue

		var face := _faces[fi]
		var ti := face.texinfo_id
		if ti >= _texinfos.size():
			continue

		var texinfo := _texinfos[ti]
		var miptex_idx := texinfo.miptex_index

		var tex_name := ""
		var tex_width := 64
		var tex_height := 64
		if miptex_idx < _miptextures.size():
			tex_name = _miptextures[miptex_idx].name
			tex_width = _miptextures[miptex_idx].width
			tex_height = _miptextures[miptex_idx].height
		if tex_name.is_empty():
			tex_name = "__unnamed_%d" % miptex_idx

		if _is_skip_texture(tex_name):
			continue
		if tex_width <= 0:
			tex_width = 64
		if tex_height <= 0:
			tex_height = 64

		var face_verts := _get_face_vertices_raw(face)
		if face_verts.size() < 3:
			continue

		var normal := Vector3.UP
		if face.plane_id < _planes.size():
			normal = _planes[face.plane_id].normal
			if face.side != 0:
				normal = -normal
		var godot_normal := q2g(normal).normalized()

		# Determine which atlas this face uses
		var is_anim := fi in anim_face_lm
		var lm_info = anim_face_lm.get(fi) if is_anim else face_lm.get(fi)
		var cur_atlas_w: int = anim_atlas_w if is_anim else static_atlas_w
		var cur_safe_uv: Vector2 = anim_safe_uv if is_anim else static_safe_uv
		var surf_key := ("A:" if is_anim else "S:") + tex_name

		if surf_key not in surfaces:
			surfaces[surf_key] = {
				verts = PackedVector3Array(),
				uvs = PackedVector2Array(),
				uv2s = PackedVector2Array(),
				normals = PackedVector3Array(),
			}

		var surf: Dictionary = surfaces[surf_key]

		for i in range(1, face_verts.size() - 1):
			var tri_verts: Array[Vector3] = [face_verts[0], face_verts[i], face_verts[i + 1]]
			for v_quake in tri_verts:
				surf.verts.append(q2g(v_quake - center_offset))
				surf.normals.append(godot_normal)

				# UVs use original world-space coordinates (not centered)
				var u: float = v_quake.dot(texinfo.s_vec) + texinfo.s_offset
				var v: float = v_quake.dot(texinfo.t_vec) + texinfo.t_offset
				surf.uvs.append(Vector2(u / float(tex_width), v / float(tex_height)))

				if lm_info and cur_atlas_w > 0:
					var ls: float = (u - lm_info.texmins_s) / 16.0
					var lt: float = (v - lm_info.texmins_t) / 16.0
					surf.uv2s.append(Vector2(
						(float(lm_info.atlas_x) + ls + 0.5) / float(cur_atlas_w),
						(float(lm_info.atlas_y) + lt + 0.5) / float(cur_atlas_w)  # Atlas is always square
					))
				else:
					surf.uv2s.append(cur_safe_uv)

		# Store per-face geometry for later leaf mesh building
		if model_idx == 0:
			var face_data := {
				"verts": PackedVector3Array(),
				"uvs": PackedVector2Array(),
				"uv2s": PackedVector2Array(),
				"normals": PackedVector3Array(),
				"surf_key": surf_key,
			}
			# Re-extract the triangles we just added (they're the last N*3 entries in surf)
			var tri_count: int = (face_verts.size() - 2)
			var vert_count: int = tri_count * 3
			var start: int = surf.verts.size() - vert_count
			for vi in range(start, surf.verts.size()):
				face_data.verts.append(surf.verts[vi])
				face_data.uvs.append(surf.uvs[vi])
				face_data.uv2s.append(surf.uv2s[vi])
				face_data.normals.append(surf.normals[vi])
			# Grow _face_geometry to fit
			while _face_geometry.size() <= fi:
				_face_geometry.append(null)
			_face_geometry[fi] = face_data

	if surfaces.is_empty():
		return null

	# Phase 3: Build ArrayMesh
	var mesh := ArrayMesh.new()
	for surf_key in surfaces:
		var surf: Dictionary = surfaces[surf_key]
		if surf.verts.size() == 0:
			continue

		var tex_name: String = surf_key.substr(2)
		var is_anim_surf: bool = surf_key.begins_with("A:")
		var cur_atlas: ImageTexture = anim_atlas_tex if is_anim_surf else static_atlas_tex

		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = surf.verts
		arrays[Mesh.ARRAY_NORMAL] = surf.normals
		arrays[Mesh.ARRAY_TEX_UV] = surf.uvs
		if cur_atlas:
			arrays[Mesh.ARRAY_TEX_UV2] = surf.uv2s

		var surface_idx := mesh.get_surface_count()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

		if _is_sky_texture(tex_name):
			mesh.surface_set_material(surface_idx, _get_sky_material(tex_name))
		elif _is_liquid_texture(tex_name):
			mesh.surface_set_material(surface_idx, _get_liquid_material(tex_name))
		elif cur_atlas:
			mesh.surface_set_material(surface_idx, _get_lightmapped_material(tex_name, cur_atlas))
		else:
			mesh.surface_set_material(surface_idx, _get_material(tex_name))

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


# --------------------------------------------------------------------------- #
# Per-leaf mesh building (for PVS occlusion culling)
# --------------------------------------------------------------------------- #

## Build per-leaf MeshInstance3D nodes for PVS culling.
## Must be called AFTER _build_model_mesh(0) which populates _face_geometry.
## Returns an Array where index = leaf index, value = MeshInstance3D or null.
func build_leaf_meshes() -> Array:
	if _bsp_leaves.is_empty() or _marksurfaces.is_empty() or _face_geometry.is_empty():
		return []

	var model := _models[0]  # Worldspawn
	var result: Array = []
	result.resize(_num_leafs)

	for li in range(_num_leafs):
		var leaf = _bsp_leaves[li]
		if leaf.contents == -2:  # Solid
			result[li] = null
			continue
		if leaf.num_marksurfaces == 0:
			result[li] = null
			continue

		# Collect face data for this leaf, grouped by surf_key
		var leaf_surfs: Dictionary = {}  # surf_key -> {verts, uvs, uv2s, normals}

		for ms_i in range(leaf.first_marksurface, leaf.first_marksurface + leaf.num_marksurfaces):
			if ms_i >= _marksurfaces.size():
				continue
			var face_idx: int = _marksurfaces[ms_i]
			# Only worldspawn faces
			if face_idx < model.firstface or face_idx >= model.firstface + model.numfaces:
				continue
			if face_idx >= _face_geometry.size() or _face_geometry[face_idx] == null:
				continue

			var fd: Dictionary = _face_geometry[face_idx]
			var sk: String = fd.surf_key
			if sk not in leaf_surfs:
				leaf_surfs[sk] = {
					"verts": PackedVector3Array(),
					"uvs": PackedVector2Array(),
					"uv2s": PackedVector2Array(),
					"normals": PackedVector3Array(),
				}
			var ls: Dictionary = leaf_surfs[sk]
			ls.verts.append_array(fd.verts)
			ls.uvs.append_array(fd.uvs)
			ls.uv2s.append_array(fd.uv2s)
			ls.normals.append_array(fd.normals)

		if leaf_surfs.is_empty():
			result[li] = null
			continue

		# Build ArrayMesh for this leaf
		var mesh := ArrayMesh.new()
		for sk in leaf_surfs:
			var ls: Dictionary = leaf_surfs[sk]
			if ls.verts.is_empty():
				continue

			var tex_name: String = sk.substr(2)
			var is_anim_surf: bool = sk.begins_with("A:")

			var arrays: Array = []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = ls.verts
			arrays[Mesh.ARRAY_NORMAL] = ls.normals
			arrays[Mesh.ARRAY_TEX_UV] = ls.uvs
			if ls.uv2s.size() == ls.verts.size():
				arrays[Mesh.ARRAY_TEX_UV2] = ls.uv2s

			var surface_idx := mesh.get_surface_count()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

			# Assign same material as worldspawn uses
			var mat: Material = null
			var cur_atlas: ImageTexture = _last_anim_atlas if is_anim_surf else _last_static_atlas
			if _is_sky_texture(tex_name):
				mat = _get_sky_material(tex_name)
			elif _is_liquid_texture(tex_name):
				mat = _get_liquid_material(tex_name)
			elif cur_atlas:
				mat = _get_lightmapped_material(tex_name, cur_atlas)
			else:
				mat = _get_material(tex_name)
			if mat:
				mesh.surface_set_material(surface_idx, mat)

		if mesh.get_surface_count() == 0:
			result[li] = null
			continue

		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.name = "leaf_%d" % li
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		result[li] = mi

	return result


# --------------------------------------------------------------------------- #
# Collision generation (trimesh from visual faces)
# --------------------------------------------------------------------------- #

func _build_model_collision_trimesh(model_idx: int) -> ConcavePolygonShape3D:
	if model_idx >= _models.size():
		return null

	var model := _models[model_idx]
	var center_offset: Vector3 = _get_model_center_quake(model_idx)
	var all_verts := PackedVector3Array()

	for fi in range(model.firstface, model.firstface + model.numfaces):
		if fi >= _faces.size():
			continue

		var face := _faces[fi]

		# Skip liquid and sky faces — they shouldn't be solid
		var ti := face.texinfo_id
		if ti < _texinfos.size():
			var mi := _texinfos[ti].miptex_index
			if mi < _miptextures.size():
				if _is_liquid_texture(_miptextures[mi].name):
					continue
				if _is_sky_texture(_miptextures[mi].name):
					continue

		# Include all other faces for collision (trigger/clip are collision volumes)
		var face_verts := PackedVector3Array()
		for se_i in range(face.surfedge_start, face.surfedge_start + face.surfedge_count):
			if se_i >= _surfedges.size():
				continue
			var se := _surfedges[se_i]
			var vert_idx: int
			if se >= 0:
				if se < _edges.size():
					vert_idx = _edges[se].x
				else:
					continue
			else:
				var neg_se := -se
				if neg_se < _edges.size():
					vert_idx = _edges[neg_se].y
				else:
					continue
			if vert_idx < _vertices.size():
				face_verts.append(_vertices[vert_idx])

		if face_verts.size() < 3:
			continue

		# Fan-triangulate
		for i in range(1, face_verts.size() - 1):
			all_verts.append(q2g(face_verts[0] - center_offset))
			all_verts.append(q2g(face_verts[i] - center_offset))
			all_verts.append(q2g(face_verts[i + 1] - center_offset))

	if all_verts.is_empty():
		return null

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(all_verts)
	return shape


# --------------------------------------------------------------------------- #
# Liquid volume generation (water/lava/slime Area3D triggers)
# --------------------------------------------------------------------------- #

func _build_liquid_volumes(model_idx: int, root: Node3D) -> void:
	if model_idx >= _models.size():
		return

	var model := _models[model_idx]
	# Group liquid face vertices by type
	var liquid_verts: Dictionary = {}  # "water"/"lava"/"slime" -> PackedVector3Array

	for fi in range(model.firstface, model.firstface + model.numfaces):
		if fi >= _faces.size():
			continue
		var face := _faces[fi]
		var ti := face.texinfo_id
		if ti >= _texinfos.size():
			continue
		var mi := _texinfos[ti].miptex_index
		if mi >= _miptextures.size():
			continue
		var tex_name: String = _miptextures[mi].name
		if not _is_liquid_texture(tex_name):
			continue

		# Determine liquid type
		var ltype := "water"
		var lower := tex_name.to_lower()
		if "lava" in lower:
			ltype = "lava"
		elif "slime" in lower:
			ltype = "slime"

		if ltype not in liquid_verts:
			liquid_verts[ltype] = PackedVector3Array()

		# Collect face vertices
		var face_verts := PackedVector3Array()
		for se_i in range(face.surfedge_start, face.surfedge_start + face.surfedge_count):
			if se_i >= _surfedges.size():
				continue
			var se := _surfedges[se_i]
			var vert_idx: int
			if se >= 0:
				if se < _edges.size():
					vert_idx = _edges[se].x
				else:
					continue
			else:
				var neg_se := -se
				if neg_se < _edges.size():
					vert_idx = _edges[neg_se].y
				else:
					continue
			if vert_idx < _vertices.size():
				face_verts.append(_vertices[vert_idx])

		if face_verts.size() < 3:
			continue

		# Fan-triangulate and add to pool
		var pool: PackedVector3Array = liquid_verts[ltype]
		for i in range(1, face_verts.size() - 1):
			pool.append(q2g(face_verts[0]))
			pool.append(q2g(face_verts[i]))
			pool.append(q2g(face_verts[i + 1]))
		liquid_verts[ltype] = pool

	# Create Area3D for each liquid type
	var vol_idx := 0
	for ltype in liquid_verts:
		var verts: PackedVector3Array = liquid_verts[ltype]
		if verts.is_empty():
			continue

		# Build AABB from all vertices and use box shape (more reliable than trimesh on Area3D)
		var aabb := AABB(verts[0], Vector3.ZERO)
		for v in verts:
			aabb = aabb.expand(v)
		# Extend downward to create a volume (liquid surfaces are flat, volume extends below)
		aabb.position.y -= 2.0
		aabb.size.y += 2.0

		var area := Area3D.new()
		area.name = "liquid_%s_%d" % [ltype, vol_idx]
		area.collision_layer = CollisionLayers.WATER
		area.collision_mask = 0
		area.set_meta("liquid_type", ltype)
		area.add_to_group("liquid_volumes")

		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = aabb.size
		col.shape = box
		col.position = aabb.get_center()
		area.add_child(col)

		root.add_child(area)
		vol_idx += 1

	if vol_idx > 0:
		print("BSPReader: Created %d liquid volumes" % vol_idx)


# --------------------------------------------------------------------------- #
# Lightmap atlas building
# --------------------------------------------------------------------------- #

## Classify which faces have animated light styles (style != 0).
func _classify_animated_faces(model_idx: int) -> Dictionary:
	var result: Dictionary = {}  # fi -> true
	var model := _models[model_idx]
	for fi in range(model.firstface, model.firstface + model.numfaces):
		if fi >= _faces.size():
			continue
		var face := _faces[fi]
		if face.lightmap_offset < 0 or face.styles[0] == 255:
			continue
		for s in 4:
			if face.styles[s] == 255:
				break
			if face.styles[s] != 0:
				result[fi] = true
				break
	return result


## Build a lightmap atlas for faces in a model.
## animated_set: Dictionary of animated face indices.
## animated_only: if true, include ONLY animated faces; if false, EXCLUDE animated faces.
func _build_lightmap_atlas(model_idx: int, animated_set: Dictionary = {}, animated_only: bool = false) -> Dictionary:
	var model := _models[model_idx]
	var face_infos: Dictionary = {}  # face_idx -> FaceLightInfo

	for fi in range(model.firstface, model.firstface + model.numfaces):
		if fi >= _faces.size():
			continue
		var face := _faces[fi]

		# Filter by animated/static
		if not animated_set.is_empty():
			var is_anim := fi in animated_set
			if animated_only and not is_anim:
				continue
			if not animated_only and is_anim:
				continue

		# Skip faces without lighting
		if face.lightmap_offset < 0 or face.styles[0] == 255:
			continue

		var ti := face.texinfo_id
		if ti >= _texinfos.size():
			continue
		var texinfo := _texinfos[ti]

		# Skip invisible textures and sky (sky has no lightmap data)
		var miptex_idx := texinfo.miptex_index
		if miptex_idx < _miptextures.size():
			if _is_skip_texture(_miptextures[miptex_idx].name):
				continue
			if _is_sky_texture(_miptextures[miptex_idx].name):
				continue

		var face_verts := _get_face_vertices_raw(face)
		if face_verts.size() < 3:
			continue

		# Project vertices into texture space, find min/max
		var min_s := INF
		var max_s := -INF
		var min_t := INF
		var max_t := -INF

		for v in face_verts:
			var s: float = v.dot(texinfo.s_vec) + texinfo.s_offset
			var t: float = v.dot(texinfo.t_vec) + texinfo.t_offset
			min_s = min(min_s, s)
			max_s = max(max_s, s)
			min_t = min(min_t, t)
			max_t = max(max_t, t)

		# Quantize to 16-unit lightmap grid (matches BSP29 16-unit lightmap grid)
		var bmins_s := int(floor(min_s / 16.0))
		var bmaxs_s := int(ceil(max_s / 16.0))
		var bmins_t := int(floor(min_t / 16.0))
		var bmaxs_t := int(ceil(max_t / 16.0))

		var info := FaceLightInfo.new()
		info.lm_width = bmaxs_s - bmins_s + 1
		info.lm_height = bmaxs_t - bmins_t + 1
		info.texmins_s = float(bmins_s) * 16.0
		info.texmins_t = float(bmins_t) * 16.0

		# Sanity check
		if info.lm_width <= 0 or info.lm_height <= 0:
			continue
		if info.lm_width > 64 or info.lm_height > 64:
			push_warning("BSP: Lightmap too large (%dx%d) for face %d, skipping" % [info.lm_width, info.lm_height, fi])
			continue

		face_infos[fi] = info

	if face_infos.is_empty():
		return {}

	# Sort by height descending for better shelf packing
	var sorted_keys := face_infos.keys()
	sorted_keys.sort_custom(func(a, b): return face_infos[a].lm_height > face_infos[b].lm_height)

	# Estimate atlas size from total area
	var total_area := 0
	for fi in sorted_keys:
		var info: FaceLightInfo = face_infos[fi]
		total_area += (info.lm_width + 1) * (info.lm_height + 1)

	var atlas_size := 64
	while atlas_size * atlas_size < total_area * 2:
		atlas_size *= 2
		if atlas_size > 4096:
			break

	# Row-based shelf packing
	var row_x := 0
	var row_y := 0
	var row_h := 0

	for fi in sorted_keys:
		var info: FaceLightInfo = face_infos[fi]
		if row_x + info.lm_width > atlas_size:
			row_y += row_h + 1
			row_x = 0
			row_h = 0
		if row_y + info.lm_height > atlas_size:
			push_warning("BSPReader: Lightmap atlas overflow at %dx%d" % [atlas_size, atlas_size])
			break
		info.atlas_x = row_x
		info.atlas_y = row_y
		row_x += info.lm_width + 1
		row_h = max(row_h, info.lm_height)

	# Create atlas image — L8 format (1 byte/pixel, 3x smaller upload than RGB8)
	var atlas_img := Image.create(atlas_size, atlas_size, false, Image.FORMAT_L8)
	atlas_img.fill(Color(0.5, 0.5, 0.5))

	# Blit each face's lightmap into the atlas + collect animated face data
	var animated_faces: Array[Dictionary] = []

	for fi in face_infos:
		_blit_face_lightmap(atlas_img, fi, face_infos[fi])

		# Check if this face has any animated styles (not just style 0)
		var face := _faces[fi]
		var has_animated := false
		var num_styles := 0
		for s in 4:
			if face.styles[s] == 255:
				break
			if face.styles[s] != 0:
				has_animated = true
			num_styles += 1
		if not has_animated or num_styles == 0:
			continue

		# Store raw lightmap data for each style layer
		var info: FaceLightInfo = face_infos[fi]
		var lm_size := info.lm_width * info.lm_height
		var style_data: Array[Dictionary] = []

		for s_idx in num_styles:
			var data_offset: int = face.lightmap_offset + s_idx * lm_size
			if data_offset + lm_size > _lighting_data.size():
				break
			style_data.append({
				style = face.styles[s_idx],
				data = _lighting_data.slice(data_offset, data_offset + lm_size),
			})

		if style_data.size() > 0:
			animated_faces.append({
				atlas_x = info.atlas_x,
				atlas_y = info.atlas_y,
				lm_width = info.lm_width,
				lm_height = info.lm_height,
				styles = style_data,
			})

	var atlas_tex := ImageTexture.create_from_image(atlas_img)

	if model_idx == 0:
		var label := "animated" if animated_only else "static"
		print("BSPReader: %s lightmap atlas %dx%d (%d faces)" % [
			label, atlas_size, atlas_size, face_infos.size()])

	return {
		atlas = atlas_tex,
		atlas_image = atlas_img,
		face_info = face_infos,
		atlas_size = atlas_size,
		animated_faces = animated_faces,
	}


## Build a small L8 atlas containing only animated face lightmaps.
## Copies pixel data from the full atlas and repacks into a smaller texture.
func _build_animated_sub_atlas(animated_faces: Array[Dictionary], full_atlas_img: Image, full_face_lm: Dictionary) -> Dictionary:
	# Calculate total area needed
	var total_area := 0
	for af in animated_faces:
		total_area += (af.lm_width + 1) * (af.lm_height + 1)

	var atlas_size := 64
	while atlas_size * atlas_size < total_area * 2:
		atlas_size *= 2
		if atlas_size > 2048:
			break

	# Shelf-pack animated faces into new atlas
	var row_x := 0
	var row_y := 0
	var row_h := 0
	var new_face_lm: Dictionary = {}  # face_idx -> FaceLightInfo (new atlas coords)

	# We need to map animated_faces back to face indices.
	# animated_faces have atlas_x/y from the FULL atlas — we need the original face index.
	# Since animated_faces don't store face_idx, we match by atlas position in full_face_lm.
	var pos_to_fi: Dictionary = {}  # "ax,ay" -> fi
	for fi in full_face_lm:
		var info: FaceLightInfo = full_face_lm[fi]
		pos_to_fi["%d,%d" % [info.atlas_x, info.atlas_y]] = fi

	for af in animated_faces:
		var w: int = af.lm_width
		var h: int = af.lm_height
		if row_x + w > atlas_size:
			row_y += row_h + 1
			row_x = 0
			row_h = 0
		if row_y + h > atlas_size:
			break

		# Store new atlas position in the animated_face dict (for animator)
		var old_ax: int = af.atlas_x
		var old_ay: int = af.atlas_y
		af["anim_atlas_x"] = row_x
		af["anim_atlas_y"] = row_y

		# Create FaceLightInfo for the new atlas coords
		var key := "%d,%d" % [old_ax, old_ay]
		if key in pos_to_fi:
			var fi: int = pos_to_fi[key]
			var orig: FaceLightInfo = full_face_lm[fi]
			var new_info := FaceLightInfo.new()
			new_info.lm_width = orig.lm_width
			new_info.lm_height = orig.lm_height
			new_info.texmins_s = orig.texmins_s
			new_info.texmins_t = orig.texmins_t
			new_info.atlas_x = row_x
			new_info.atlas_y = row_y
			new_face_lm[fi] = new_info

		row_x += w + 1
		row_h = max(row_h, h)

	# Create L8 atlas image and copy pixels from full atlas
	var anim_img := Image.create(atlas_size, atlas_size, false, Image.FORMAT_L8)
	anim_img.fill(Color(0.5, 0.5, 0.5))

	for af in animated_faces:
		if "anim_atlas_x" not in af:
			continue
		var src_rect := Rect2i(af.atlas_x, af.atlas_y, af.lm_width, af.lm_height)
		var dst_pos := Vector2i(af.anim_atlas_x, af.anim_atlas_y)
		# Copy region from full atlas (which is also L8)
		anim_img.blit_rect(full_atlas_img, src_rect, dst_pos)
		# Update atlas_x/y in animated_face data for the animator
		af.atlas_x = af.anim_atlas_x
		af.atlas_y = af.anim_atlas_y

	var atlas_tex := ImageTexture.create_from_image(anim_img)
	print("BSPReader: animated lightmap sub-atlas %dx%d (%d faces)" % [
		atlas_size, atlas_size, animated_faces.size()])

	return {
		atlas = atlas_tex,
		atlas_image = anim_img,
		face_info = new_face_lm,
		atlas_size = atlas_size,
		animated_faces = animated_faces,
	}


## Blit a single face's lightmap data into the atlas image.
func _blit_face_lightmap(atlas: Image, face_idx: int, info: FaceLightInfo) -> void:
	var face := _faces[face_idx]
	var offset := face.lightmap_offset
	if offset < 0 or offset >= _lighting_data.size():
		return

	var size := info.lm_width * info.lm_height

	# Count active light styles
	var num_styles := 0
	for s in 4:
		if face.styles[s] == 255:
			break
		num_styles += 1
	if num_styles == 0:
		return

	# Combine all light styles into a single brightness map
	var combined := PackedFloat32Array()
	combined.resize(size)
	combined.fill(0.0)

	for s_idx in num_styles:
		var style: int = face.styles[s_idx]
		var data_offset: int = offset + s_idx * size
		if data_offset + size > _lighting_data.size():
			break

		# Scale factor: default brightness for this style
		# Style 0 pattern "m" → ('m'-'a')/12 = 1.0
		var scale := 1.0
		if style < LIGHT_STYLE_PATTERNS.size():
			var pattern: String = LIGHT_STYLE_PATTERNS[style]
			scale = float(pattern.unicode_at(0) - 97) / 12.0  # 'a'=97, 'm'=1.0
		elif style >= 32:
			# Switchable lights: default ON
			scale = 1.0

		for i in size:
			combined[i] += float(_lighting_data[data_offset + i]) * scale

	# Write to atlas
	for y in info.lm_height:
		for x in info.lm_width:
			var idx := y * info.lm_width + x
			var brightness := clampf(combined[idx] / 255.0, 0.0, 1.0)
			atlas.set_pixel(
				info.atlas_x + x, info.atlas_y + y,
				Color(brightness, brightness, brightness)
			)


# --------------------------------------------------------------------------- #
# Brush entity node builder
# --------------------------------------------------------------------------- #

## Build a Node3D for brush entity models (model index 1+).
## Returns the node with mesh + collision children, but no script yet —
## the entity spawner will attach scripts.
func _build_brush_entity_node(model_idx: int, _scene_root: Node3D) -> Node3D:
	var _model := _models[model_idx]
	var mesh_inst := _build_model_mesh(model_idx)
	var center_godot: Vector3 = q2g(_get_model_center_quake(model_idx))

	# Determine if this model is used by a trigger/area entity
	var is_trigger := _is_model_trigger(model_idx)

	if is_trigger:
		# Triggers are Area3D with invisible collision
		var area := Area3D.new()
		area.name = "brush_model_%d" % model_idx
		area.position = center_godot
		area.collision_layer = 0
		area.collision_mask = CollisionLayers.PLAYER

		var trimesh := _build_model_collision_trimesh(model_idx)
		if trimesh:
			var col := CollisionShape3D.new()
			col.shape = trimesh
			col.name = "col"
			area.add_child(col)

		# No visual mesh for triggers
		return area
	else:
		# Solid brush entity: AnimatableBody3D (for doors, plats, trains, etc.)
		var body := AnimatableBody3D.new()
		body.name = "brush_model_%d" % model_idx
		body.position = center_godot
		body.collision_layer = CollisionLayers.WORLD
		body.collision_mask = 0

		if mesh_inst:
			mesh_inst.name = "mesh"
			body.add_child(mesh_inst)

		var trimesh := _build_model_collision_trimesh(model_idx)
		if trimesh:
			var col := CollisionShape3D.new()
			col.shape = trimesh
			col.name = "col"
			body.add_child(col)

		return body


## Check if a model index is used by a trigger-type entity.
func _is_model_trigger(model_idx: int) -> bool:
	var model_key := "*%d" % model_idx
	for ent in _entities:
		if ent.get("model", "") == model_key:
			var classname: String = ent.get("classname", "")
			if classname.begins_with("trigger_"):
				return true
	return false


# --------------------------------------------------------------------------- #
# Material / texture loading
# --------------------------------------------------------------------------- #

func _get_material(tex_name: String) -> Material:
	tex_name = tex_name.to_lower()
	if tex_name in _material_cache:
		return _material_cache[tex_name]

	# Animated texture sequence (+0name, +1name, ...)
	if _is_animated_texture(tex_name):
		var anim_frames := _collect_anim_frames(tex_name)
		if anim_frames.size() > 1:
			var amat := ShaderMaterial.new()
			amat.shader = _get_anim_shader()
			for i in mini(anim_frames.size(), 5):
				amat.set_shader_parameter("frame%d" % i, anim_frames[i])
			amat.set_shader_parameter("frame_count", mini(anim_frames.size(), 5))
			_material_cache[tex_name] = amat
			return amat

	var mat := StandardMaterial3D.new()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	var texture := _load_texture(tex_name)
	if texture:
		mat.albedo_texture = texture
	else:
		# Fallback: assign a color based on name hash
		var hash_val := tex_name.hash()
		mat.albedo_color = Color(
			fmod(abs(float(hash_val & 0xFF)) / 255.0 * 0.6 + 0.2, 1.0),
			fmod(abs(float((hash_val >> 8) & 0xFF)) / 255.0 * 0.6 + 0.2, 1.0),
			fmod(abs(float((hash_val >> 16) & 0xFF)) / 255.0 * 0.6 + 0.2, 1.0),
		)

	_material_cache[tex_name] = mat
	return mat


var _texture_cache: Dictionary = {}  # tex_name -> Texture2D (loaded result cache)
var _texture_dir_cache: Dictionary = {}  # lowercase name -> actual path

func _load_texture(tex_name: String) -> Texture2D:
	# Check cache first
	if tex_name in _texture_cache:
		return _texture_cache[tex_name]

	var result: Texture2D = null

	# Try exact path
	var path := "res://textures/lq/%s.png" % tex_name
	if ResourceLoader.exists(path):
		result = load(path)

	# Try lowercase
	if not result:
		path = "res://textures/lq/%s.png" % tex_name.to_lower()
		if ResourceLoader.exists(path):
			result = load(path)

	# Try case-insensitive directory scan (lazy-built cache)
	if not result:
		result = _find_texture_case_insensitive(tex_name)

	# Try stripping animated texture prefix (+0, +1, +a, *0 etc.)
	if not result and tex_name.length() > 2:
		var first := tex_name[0]
		if first == "+" or first == "*":
			# Strip prefix char + frame digit: "+0name" -> "name"
			var stripped := tex_name.substr(2)
			path = "res://textures/lq/%s.png" % stripped
			if ResourceLoader.exists(path):
				result = load(path)
			if not result:
				path = "res://textures/lq/%s.png" % stripped.to_lower()
				if ResourceLoader.exists(path):
					result = load(path)

	# Fallback: generate from embedded miptex data
	if not result:
		result = _generate_texture_from_miptex(tex_name)

	# Fallback: look up texture from WAD files referenced in worldspawn "_wad" key
	if not result:
		result = _load_texture_from_wad(tex_name)

	_texture_cache[tex_name] = result
	return result


func _populate_texture_dir_cache() -> void:
	if not _texture_dir_cache.is_empty():
		return
	var dir := DirAccess.open("res://textures/lq/")
	if dir:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if file_name.ends_with(".png"):
				var base := file_name.get_basename()
				_texture_dir_cache[base.to_lower()] = "res://textures/lq/" + file_name
			file_name = dir.get_next()


func _find_texture_case_insensitive(tex_name: String) -> Texture2D:
	_populate_texture_dir_cache()
	var key := tex_name.to_lower()
	if key in _texture_dir_cache:
		return load(_texture_dir_cache[key])
	return null


func _generate_texture_from_miptex(tex_name: String) -> ImageTexture:
	# Case-insensitive miptex name matching
	var lower := tex_name.to_lower()
	for mt in _miptextures:
		if mt.name.to_lower() == lower and mt.pixels.size() > 0:
			return _miptex_to_image_texture(mt)
	return null


var _wad_paths_cache: Array = []  # Cached WAD file paths from worldspawn "_wad" key
var _wad_paths_parsed: bool = false


## Load a texture from WAD files referenced by worldspawn entity's "_wad" key.
## Returns null if not found in any WAD.
func _load_texture_from_wad(tex_name: String) -> ImageTexture:
	if not _wad_paths_parsed:
		_wad_paths_parsed = true
		_wad_paths_cache = _parse_worldspawn_wad_paths()

	if _wad_paths_cache.is_empty():
		return null

	if not wad_texture_loader.is_valid():
		return null

	for wad_path in _wad_paths_cache:
		var tex: ImageTexture = wad_texture_loader.call(wad_path, tex_name)
		if tex:
			return tex

	return null


## Parse WAD file paths from worldspawn entity's "_wad" key.
## Quake stores this as a semicolon-separated list of paths like:
##   "\quake\id1\gfx.wad;\quake\id1\medieval.wad"
## We extract just the filenames and return them.
func _parse_worldspawn_wad_paths() -> Array:
	if _entities.is_empty():
		return []

	var worldspawn: Dictionary = _entities[0]
	# The key can be "_wad" or "wad"
	var wad_str: String = worldspawn.get("_wad", worldspawn.get("wad", ""))
	if wad_str.is_empty():
		return []

	var paths: Array = []
	# Split by semicolons (Quake convention)
	var parts := wad_str.split(";", false)
	for part in parts:
		var p: String = part.strip_edges()
		if p.is_empty():
			continue
		# Convert backslashes to forward slashes
		p = p.replace("\\", "/")
		# Extract just the filename (e.g. "gfx.wad" from "/quake/id1/gfx.wad")
		var filename := p.get_file()
		if not filename.is_empty():
			paths.append(filename)

	if not paths.is_empty():
		print("BSPReader: WAD files from worldspawn: %s" % str(paths))
	return paths


var _fullbright_cache: Dictionary = {}  # tex_name -> ImageTexture or null

func _miptex_to_image_texture(mt: BSPMiptex) -> ImageTexture:
	if mt.pixels.size() < mt.width * mt.height:
		return null

	_ensure_quake_palette()

	var img := Image.create(mt.width, mt.height, false, Image.FORMAT_RGB8)
	var fb_img := Image.create(mt.width, mt.height, false, Image.FORMAT_RGB8)
	var pixel_count: int = mt.width * mt.height
	var has_fullbright := false

	for i in pixel_count:
		var palette_idx: int = mt.pixels[i]
		var pi3: int = palette_idx * 3
		var r: int = _quake_palette[pi3] if pi3 + 2 < _quake_palette.size() else 0
		var g: int = _quake_palette[pi3 + 1] if pi3 + 2 < _quake_palette.size() else 0
		var b: int = _quake_palette[pi3 + 2] if pi3 + 2 < _quake_palette.size() else 0
		var x: int = i % mt.width
		@warning_ignore("INTEGER_DIVISION")
		var y: int = i / mt.width
		img.set_pixel(x, y, Color8(r, g, b))
		# Fullbright: palette indices 224-255 glow independent of lightmap
		if palette_idx >= 224:
			fb_img.set_pixel(x, y, Color8(r, g, b))
			has_fullbright = true
		else:
			fb_img.set_pixel(x, y, Color8(0, 0, 0))

	if has_fullbright:
		_fullbright_cache[mt.name.to_lower()] = ImageTexture.create_from_image(fb_img)
	else:
		_fullbright_cache[mt.name.to_lower()] = null

	var tex := ImageTexture.create_from_image(img)
	return tex


func _ensure_quake_palette() -> void:
	if _quake_palette.size() > 0:
		return
	# Try loading palette from file
	var palette_path := "res://textures/palette.lmp"
	if FileAccess.file_exists(palette_path):
		var f := FileAccess.open(palette_path, FileAccess.READ)
		if f:
			_quake_palette = f.get_buffer(768)
			f.close()
			return
	_quake_palette = QuakePalette.get_palette()



# --------------------------------------------------------------------------- #
# Lightmap shader + materials
# --------------------------------------------------------------------------- #

func _get_lightmap_shader() -> Shader:
	if _lightmap_shader:
		return _lightmap_shader
	_lightmap_shader = Shader.new()
	_lightmap_shader.code = """shader_type spatial;
render_mode unshaded;

uniform sampler2D albedo_tex : source_color, filter_nearest;
uniform sampler2D lightmap_tex : filter_linear;
uniform sampler2D fullbright_tex : filter_nearest;
uniform bool has_fullbright = false;

void fragment() {
	vec3 albedo = texture(albedo_tex, UV).rgb;
	float light = texture(lightmap_tex, UV2).r;
	vec3 lit = albedo * light * 2.8;
	if (has_fullbright) {
		vec3 fb = texture(fullbright_tex, UV).rgb;
		float fb_mask = max(fb.r, max(fb.g, fb.b));
		ALBEDO = mix(lit, fb, fb_mask);
	} else {
		ALBEDO = lit;
	}
}
"""
	return _lightmap_shader


## Shader for animated textures (+0name, +1name, ...) with lightmaps.
## Supports up to 10 frames, cycles at 5 fps (Quake standard).
func _get_lightmap_anim_shader() -> Shader:
	if _lightmap_anim_shader:
		return _lightmap_anim_shader
	_lightmap_anim_shader = Shader.new()
	_lightmap_anim_shader.code = """shader_type spatial;
render_mode unshaded;

uniform sampler2D frame0 : source_color, filter_nearest;
uniform sampler2D frame1 : source_color, filter_nearest;
uniform sampler2D frame2 : source_color, filter_nearest;
uniform sampler2D frame3 : source_color, filter_nearest;
uniform sampler2D frame4 : source_color, filter_nearest;
uniform int frame_count = 1;
uniform sampler2D lightmap_tex : filter_linear;
uniform sampler2D fullbright_tex : filter_nearest;
uniform bool has_fullbright = false;

void fragment() {
	int frame = int(mod(TIME * 5.0, float(frame_count)));
	vec3 albedo;
	if (frame == 0) albedo = texture(frame0, UV).rgb;
	else if (frame == 1) albedo = texture(frame1, UV).rgb;
	else if (frame == 2) albedo = texture(frame2, UV).rgb;
	else if (frame == 3) albedo = texture(frame3, UV).rgb;
	else albedo = texture(frame4, UV).rgb;

	float light = texture(lightmap_tex, UV2).r;
	vec3 lit = albedo * light * 2.8;
	if (has_fullbright) {
		vec3 fb = texture(fullbright_tex, UV).rgb;
		float fb_mask = max(fb.r, max(fb.g, fb.b));
		ALBEDO = mix(lit, fb, fb_mask);
	} else {
		ALBEDO = lit;
	}
}
"""
	return _lightmap_anim_shader


## Shader for animated textures without lightmaps.
func _get_anim_shader() -> Shader:
	if _anim_shader:
		return _anim_shader
	_anim_shader = Shader.new()
	_anim_shader.code = """shader_type spatial;
render_mode unshaded;

uniform sampler2D frame0 : source_color, filter_nearest;
uniform sampler2D frame1 : source_color, filter_nearest;
uniform sampler2D frame2 : source_color, filter_nearest;
uniform sampler2D frame3 : source_color, filter_nearest;
uniform sampler2D frame4 : source_color, filter_nearest;
uniform int frame_count = 1;

void fragment() {
	int frame = int(mod(TIME * 5.0, float(frame_count)));
	vec3 albedo;
	if (frame == 0) albedo = texture(frame0, UV).rgb;
	else if (frame == 1) albedo = texture(frame1, UV).rgb;
	else if (frame == 2) albedo = texture(frame2, UV).rgb;
	else if (frame == 3) albedo = texture(frame3, UV).rgb;
	else albedo = texture(frame4, UV).rgb;
	ALBEDO = albedo;
}
"""
	return _anim_shader


## Check if a texture name is an animated sequence (+0name, +1name, etc.)
static func _is_animated_texture(tex_name: String) -> bool:
	return tex_name.length() > 2 and tex_name[0] == "+"


var _anim_frames_cache: Dictionary = {}  # base_name (lowercase) -> Array[Texture2D]

## Collect all frames of an animated texture sequence.
## Given "+0button", returns [tex_for_+0, tex_for_+1, ...] (only existing frames).
## Uses embedded miptex data directly since each frame has unique pixel data.
func _collect_anim_frames(tex_name: String) -> Array[Texture2D]:
	if tex_name.length() < 3:
		return []
	var base := tex_name.substr(2).to_lower()  # strip "+N" prefix, normalize case
	if base in _anim_frames_cache:
		return _anim_frames_cache[base]
	var frames: Array[Texture2D] = []
	# Quake uses +0 through +9 for normal animation
	# Try embedded miptex first (fastest, no WAD/file I/O)
	for i in range(10):
		var frame_name := "+%d%s" % [i, base]
		var tex := _generate_texture_from_miptex(frame_name)
		if tex:
			frames.append(tex)
		else:
			break
	# If miptex had nothing, try PNG files on disk
	if frames.size() <= 1:
		frames.clear()
		for i in range(10):
			var frame_name := "+%d%s" % [i, base]
			var path := "res://textures/lq/%s.png" % frame_name
			if ResourceLoader.exists(path):
				frames.append(load(path) as Texture2D)
			else:
				path = "res://textures/lq/%s.png" % frame_name.to_lower()
				if ResourceLoader.exists(path):
					frames.append(load(path) as Texture2D)
				else:
					break
	# Still only 0-1 frames? Fall back to normal single texture
	if frames.size() <= 1:
		frames.clear()
		var tex := _load_texture(tex_name)
		if tex:
			frames.append(tex)
	_anim_frames_cache[base] = frames
	return frames


func _get_lightmapped_material(tex_name: String, atlas: ImageTexture) -> ShaderMaterial:
	tex_name = tex_name.to_lower()
	var mat := ShaderMaterial.new()

	# Animated texture sequence (+0name, +1name, ...)
	if _is_animated_texture(tex_name):
		var anim_frames := _collect_anim_frames(tex_name)
		if anim_frames.size() > 1:
			mat.shader = _get_lightmap_anim_shader()
			for i in mini(anim_frames.size(), 5):
				mat.set_shader_parameter("frame%d" % i, anim_frames[i])
			mat.set_shader_parameter("frame_count", mini(anim_frames.size(), 5))
			mat.set_shader_parameter("lightmap_tex", atlas)
			var fb_tex_anim = _fullbright_cache.get(tex_name.to_lower())
			if fb_tex_anim:
				mat.set_shader_parameter("has_fullbright", true)
				mat.set_shader_parameter("fullbright_tex", fb_tex_anim)
			return mat

	mat.shader = _get_lightmap_shader()

	var albedo_tex := _load_texture(tex_name)
	if albedo_tex:
		mat.set_shader_parameter("albedo_tex", albedo_tex)
	else:
		# Fallback: solid color texture
		var hash_val := tex_name.hash()
		var col := Color(
			fmod(abs(float(hash_val & 0xFF)) / 255.0 * 0.6 + 0.2, 1.0),
			fmod(abs(float((hash_val >> 8) & 0xFF)) / 255.0 * 0.6 + 0.2, 1.0),
			fmod(abs(float((hash_val >> 16) & 0xFF)) / 255.0 * 0.6 + 0.2, 1.0),
		)
		var img := Image.create(1, 1, false, Image.FORMAT_RGB8)
		img.set_pixel(0, 0, col)
		mat.set_shader_parameter("albedo_tex", ImageTexture.create_from_image(img))

	mat.set_shader_parameter("lightmap_tex", atlas)

	# Fullbright: palette indices 224-255 glow at full brightness
	var fb_tex = _fullbright_cache.get(tex_name.to_lower())
	if fb_tex:
		mat.set_shader_parameter("has_fullbright", true)
		mat.set_shader_parameter("fullbright_tex", fb_tex)

	return mat


## Sky material — Quake-style scrolling two-layer dome projection.
## Quake sky textures are 256x128: right half = background, left half = foreground (index 0 = transparent).
func _get_sky_material(tex_name: String) -> ShaderMaterial:
	tex_name = tex_name.to_lower()
	var cache_key := "sky:" + tex_name
	if cache_key in _material_cache:
		return _material_cache[cache_key]

	var sky_back: ImageTexture = null
	var sky_front: ImageTexture = null

	# Try to split from loaded texture (PNG with alpha, or raw miptex)
	var texture := _load_texture(tex_name)
	if texture:
		var img := texture.get_image()
		if img and img.get_width() >= 256 and img.get_height() >= 128:
			# Ensure RGBA8 format before any blit_rect calls
			img.convert(Image.FORMAT_RGBA8)

			# Right half = background (solid)
			var back_img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
			back_img.blit_rect(img, Rect2i(128, 0, 128, 128), Vector2i.ZERO)
			sky_back = ImageTexture.create_from_image(back_img)

			# Left half = foreground (use alpha channel directly)
			var front_img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
			front_img.blit_rect(img, Rect2i(0, 0, 128, 128), Vector2i.ZERO)

			# Check if foreground has any opaque pixels at all
			var has_opaque := false
			for y in 128:
				if has_opaque:
					break
				for x in 128:
					if front_img.get_pixel(x, y).a > 0.5:
						has_opaque = true
						break
			if has_opaque:
				sky_front = ImageTexture.create_from_image(front_img)
			# else: sky_front stays null = no foreground layer
		else:
			sky_back = texture

	# Fallback: try BSP miptex data with exact palette index 0 transparency
	if not sky_back:
		var split := _split_sky_from_miptex(tex_name)
		if not split.is_empty():
			sky_back = split.back
			sky_front = split.front

	# Last resort: use texture as-is for background only
	if not sky_back and texture:
		sky_back = texture

	var mat := ShaderMaterial.new()
	mat.shader = _get_sky_shader()
	if sky_back:
		mat.set_shader_parameter("sky_back", sky_back)
	if sky_front:
		mat.set_shader_parameter("sky_front", sky_front)
		mat.set_shader_parameter("has_front", true)
	else:
		mat.set_shader_parameter("has_front", false)

	_material_cache[cache_key] = mat
	return mat


## Split sky texture from raw BSP miptex data using exact palette indices.
## Palette index 0 in the foreground half = transparent (no guessing needed).
func _split_sky_from_miptex(tex_name: String) -> Dictionary:
	var lower := tex_name.to_lower()
	for mt in _miptextures:
		if mt.name.to_lower() == lower and mt.pixels.size() > 0:
			if mt.width >= 256 and mt.height >= 128:
				_ensure_quake_palette()
				var back_img := Image.create(128, 128, false, Image.FORMAT_RGB8)
				var front_img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
				for y in 128:
					for x in 128:
						# Right half = background (solid)
						var back_idx: int = mt.pixels[y * mt.width + x + 128]
						var bi3: int = back_idx * 3
						var br: int = _quake_palette[bi3] if bi3 + 2 < _quake_palette.size() else 0
						var bg: int = _quake_palette[bi3 + 1] if bi3 + 2 < _quake_palette.size() else 0
						var bb: int = _quake_palette[bi3 + 2] if bi3 + 2 < _quake_palette.size() else 0
						back_img.set_pixel(x, y, Color8(br, bg, bb))
						# Left half = foreground (index 0 = transparent)
						var front_idx: int = mt.pixels[y * mt.width + x]
						if front_idx == 0:
							front_img.set_pixel(x, y, Color(0, 0, 0, 0))
						else:
							var fi3: int = front_idx * 3
							var fr: int = _quake_palette[fi3] if fi3 + 2 < _quake_palette.size() else 0
							var fg: int = _quake_palette[fi3 + 1] if fi3 + 2 < _quake_palette.size() else 0
							var fb: int = _quake_palette[fi3 + 2] if fi3 + 2 < _quake_palette.size() else 0
							front_img.set_pixel(x, y, Color8(fr, fg, fb))
				return {
					"back": ImageTexture.create_from_image(back_img),
					"front": ImageTexture.create_from_image(front_img),
				}
	return {}


var _sky_shader: Shader = null

func _get_sky_shader() -> Shader:
	if _sky_shader:
		return _sky_shader
	_sky_shader = Shader.new()
	_sky_shader.code = """shader_type spatial;
render_mode unshaded, cull_back;

uniform sampler2D sky_back : filter_nearest, repeat_enable;
uniform sampler2D sky_front : filter_nearest, repeat_enable;
uniform bool has_front = false;

void fragment() {
	// Direction from camera to fragment in world space
	// Godot: Y=up, Quake: Z=up — so flatten Y, use X/Z for UVs
	vec3 dir = (INV_VIEW_MATRIX * vec4(VERTEX, 0.0)).xyz;

	// Quake dome: flatten vertical axis by 3x (dome curvature at zenith)
	dir.y *= 3.0;

	// Normalize and scale (Quake: 6 * 63 = 378)
	float len = length(dir);
	len = 378.0 / len;

	// UV from horizontal plane (X, Z in Godot = X, Y in Quake)
	float dx = dir.x * len;
	float dz = dir.z * len;

	// Background layer: scrolls at speed 8
	vec2 uv_back = vec2(
		(TIME * 8.0 + dx) / 128.0,
		(TIME * 8.0 + dz) / 128.0
	);

	vec3 color = texture(sky_back, uv_back).rgb;

	// Foreground layer: scrolls at speed 16 (2x faster), composited on top
	if (has_front) {
		vec2 uv_front = vec2(
			(TIME * 16.0 + dx) / 128.0,
			(TIME * 16.0 + dz) / 128.0
		);
		vec4 front = texture(sky_front, uv_front);
		color = mix(color, front.rgb, front.a);
	}

	ALBEDO = color;
}
"""
	return _sky_shader


var _liquid_shader: Shader = null

func _get_liquid_shader() -> Shader:
	if _liquid_shader:
		return _liquid_shader
	_liquid_shader = Shader.new()
	_liquid_shader.code = """shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_always, cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_nearest;
uniform float alpha : hint_range(0.0, 1.0) = 0.5;
uniform float scroll_speed : hint_range(0.0, 2.0) = 0.3;

void fragment() {
	vec2 uv = UV;
	uv.x += sin(uv.y * 4.0 + TIME * scroll_speed) * 0.03;
	uv.y += cos(uv.x * 4.0 + TIME * scroll_speed * 0.8) * 0.03;
	ALBEDO = texture(albedo_tex, uv).rgb;
	ALPHA = alpha;
}
"""
	return _liquid_shader


func _get_liquid_material(tex_name: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _get_liquid_shader()
	mat.render_priority = -1  # Render behind opaque

	var albedo_tex := _load_texture(tex_name)
	if albedo_tex:
		mat.set_shader_parameter("albedo_tex", albedo_tex)
	else:
		# Fallback: tinted color based on liquid type
		var col := Color(0.2, 0.3, 0.5)  # Default: water blue
		@warning_ignore("CONFUSABLE_LOCAL_DECLARATION")
		var lower := tex_name.to_lower()
		if "lava" in lower:
			col = Color(0.8, 0.3, 0.0)
		elif "slime" in lower:
			col = Color(0.2, 0.6, 0.1)
		var img := Image.create(1, 1, false, Image.FORMAT_RGB8)
		img.set_pixel(0, 0, col)
		mat.set_shader_parameter("albedo_tex", ImageTexture.create_from_image(img))

	# Lava is more opaque
	var lower := tex_name.to_lower()
	if "lava" in lower:
		mat.set_shader_parameter("alpha", 0.8)
	else:
		mat.set_shader_parameter("alpha", 0.5)

	return mat


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

static func _is_skip_texture(tex_name: String) -> bool:
	var lower := tex_name.to_lower()
	for skip in SKIP_TEXTURE_NAMES:
		if lower == skip or lower.begins_with(skip):
			return true
	return false


## Check if texture is a sky texture (fullbright, no collision)
static func _is_sky_texture(tex_name: String) -> bool:
	return tex_name.to_lower().begins_with("sky")


## Check if texture is a liquid (*water, *lava, *slime, etc.)
static func _is_liquid_texture(tex_name: String) -> bool:
	return tex_name.begins_with("*")


## Read a signed 32-bit integer from FileAccess.
static func _get_int32(f: FileAccess) -> int:
	var val := f.get_32()
	if val >= 0x80000000:
		val -= 0x100000000
	return val


func _set_owner_recursive(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_set_owner_recursive(child, owner)
