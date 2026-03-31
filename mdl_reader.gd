# SPDX-License-Identifier: MIT
# Copyright (c) 2026 McMarius11
class_name MDLReader
## Reads Quake 1 MDL (version 6, "IDPO") binary data and produces
## a Godot ArrayMesh + ImageTexture suitable for rendering monsters.
## Supports multi-frame animation via read_mdl_all_frames().

const Q2G := 0.03125  # Quake units to Godot meters


## Read an MDL file from raw bytes. Returns {"mesh": ArrayMesh, "texture": ImageTexture}
## or an empty Dictionary on failure.
static func read_mdl(data: PackedByteArray) -> Dictionary:
	if data.size() < 84:
		push_warning("MDLReader: Data too small for header (%d bytes)" % data.size())
		return {}

	# --- Header (84 bytes) ---
	var ident := data.slice(0, 4).get_string_from_ascii()
	if ident != "IDPO":
		push_warning("MDLReader: Bad ident '%s' (expected IDPO)" % ident)
		return {}

	var version := data.decode_s32(4)
	if version != 6:
		push_warning("MDLReader: Unsupported version %d (expected 6)" % version)
		return {}

	var scale := Vector3(
		data.decode_float(8),
		data.decode_float(12),
		data.decode_float(16),
	)
	var origin := Vector3(
		data.decode_float(20),
		data.decode_float(24),
		data.decode_float(28),
	)
	# radius (32), eyeposition (36,40,44) — skip
	var numskins := data.decode_s32(48)
	var skinwidth := data.decode_s32(52)
	var skinheight := data.decode_s32(56)
	var numverts := data.decode_s32(60)
	var numtris := data.decode_s32(64)
	var numframes := data.decode_s32(68)
	# synctype (72), flags (76), size (80) — skip

	if numskins <= 0 or numverts <= 0 or numtris <= 0 or numframes <= 0:
		push_warning("MDLReader: Invalid counts skins=%d verts=%d tris=%d frames=%d" % [numskins, numverts, numtris, numframes])
		return {}

	var pos := 84

	# --- Skins ---
	# We only care about the first skin's pixel data.
	var skin_data := PackedByteArray()
	var skin_pixels := skinwidth * skinheight

	for i in numskins:
		if pos + 4 > data.size():
			push_warning("MDLReader: Unexpected end of data in skins")
			return {}
		var group := data.decode_s32(pos)
		pos += 4

		if group == 0:
			# Single skin
			if i == 0:
				skin_data = data.slice(pos, pos + skin_pixels)
			pos += skin_pixels
		else:
			# Skin group
			var num_in_group := data.decode_s32(pos)
			pos += 4
			pos += num_in_group * 4  # float intervals
			if i == 0:
				skin_data = data.slice(pos, pos + skin_pixels)
			pos += num_in_group * skin_pixels

	if skin_data.size() != skin_pixels:
		push_warning("MDLReader: Skin data size mismatch (%d vs %d)" % [skin_data.size(), skin_pixels])
		return {}

	# --- Texture Coordinates ---
	# numverts entries of (int32 onseam, int32 s, int32 t) = 12 bytes each
	var tc_onseam := PackedInt32Array()
	var tc_s := PackedInt32Array()
	var tc_t := PackedInt32Array()
	tc_onseam.resize(numverts)
	tc_s.resize(numverts)
	tc_t.resize(numverts)

	for i in numverts:
		if pos + 12 > data.size():
			push_warning("MDLReader: Unexpected end of data in texcoords")
			return {}
		tc_onseam[i] = data.decode_s32(pos)
		tc_s[i] = data.decode_s32(pos + 4)
		tc_t[i] = data.decode_s32(pos + 8)
		pos += 12

	# --- Triangles ---
	# numtris entries of (int32 facesfront, int32 v0, int32 v1, int32 v2) = 16 bytes each
	var tri_facesfront := PackedInt32Array()
	var tri_v := PackedInt32Array()  # flat array, 3 per triangle
	tri_facesfront.resize(numtris)
	tri_v.resize(numtris * 3)

	for i in numtris:
		if pos + 16 > data.size():
			push_warning("MDLReader: Unexpected end of data in triangles")
			return {}
		tri_facesfront[i] = data.decode_s32(pos)
		tri_v[i * 3] = data.decode_s32(pos + 4)
		tri_v[i * 3 + 1] = data.decode_s32(pos + 8)
		tri_v[i * 3 + 2] = data.decode_s32(pos + 12)
		pos += 16

	# --- Frames ---
	# Read only the first frame's vertex data.
	var raw_verts := PackedByteArray()  # numverts * 4 bytes (x, y, z, normalindex)

	for i in numframes:
		if pos + 4 > data.size():
			push_warning("MDLReader: Unexpected end of data in frames")
			return {}
		var frame_type := data.decode_s32(pos)
		pos += 4

		if frame_type == 0:
			# Simple frame: bboxmin(4) + bboxmax(4) + name(16) + verts(numverts*4)
			if pos + 24 + numverts * 4 > data.size():
				push_warning("MDLReader: Unexpected end of data in simple frame")
				return {}
			pos += 4  # bboxmin
			pos += 4  # bboxmax
			pos += 16 # name
			if i == 0:
				raw_verts = data.slice(pos, pos + numverts * 4)
			pos += numverts * 4
		else:
			# Frame group
			if pos + 4 > data.size():
				push_warning("MDLReader: Unexpected end of data in frame group header")
				return {}
			var num_in_group := data.decode_s32(pos)
			pos += 4
			pos += 4  # group bboxmin
			pos += 4  # group bboxmax
			pos += num_in_group * 4  # float intervals

			for j in num_in_group:
				# Each sub-frame: bboxmin(4) + bboxmax(4) + name(16) + verts(numverts*4)
				if pos + 24 + numverts * 4 > data.size():
					push_warning("MDLReader: Unexpected end of data in group sub-frame")
					return {}
				pos += 4  # bboxmin
				pos += 4  # bboxmax
				pos += 16 # name
				if i == 0 and j == 0:
					raw_verts = data.slice(pos, pos + numverts * 4)
				pos += numverts * 4

	if raw_verts.size() != numverts * 4:
		push_warning("MDLReader: Frame vertex data size mismatch")
		return {}

	# --- Decode vertex positions ---
	var positions := PackedVector3Array()
	positions.resize(numverts)
	for i in numverts:
		var qx: float = scale.x * float(raw_verts[i * 4]) + origin.x
		var qy: float = scale.y * float(raw_verts[i * 4 + 1]) + origin.y
		var qz: float = scale.z * float(raw_verts[i * 4 + 2]) + origin.z
		# Quake (X=forward, Y=left, Z=up) -> Godot (X=forward, Y=up, Z=left)
		positions[i] = Vector3(qx, qz, -qy) * Q2G

	# --- Build texture ---
	var texture := _build_texture(skin_data, skinwidth, skinheight)

	# --- Build mesh ---
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in numtris:
		var ff: int = tri_facesfront[i]
		# MDL winding is CW when viewed from outside;
		# Godot uses CCW front faces, so reverse the winding order.
		for k in [0, 2, 1]:
			var vi: int = tri_v[i * 3 + k]
			if vi < 0 or vi >= numverts:
				continue

			var s: float = float(tc_s[vi])
			var t: float = float(tc_t[vi])

			# If vertex is on seam and this triangle is back-facing, shift UV
			if tc_onseam[vi] != 0 and ff == 0:
				s += float(skinwidth) * 0.5

			var u: float = (s + 0.5) / float(skinwidth)
			var v: float = (t + 0.5) / float(skinheight)

			st.set_uv(Vector2(u, v))
			st.add_vertex(positions[vi])

	st.generate_normals()
	var mesh := st.commit()

	return {"mesh": mesh, "texture": texture}


## Read MDL with an explicit palette (from PAK's gfx/palette.lmp).
static func read_mdl_with_palette(data: PackedByteArray, palette: PackedByteArray) -> Dictionary:
	var result := read_mdl(data)
	if result.is_empty():
		return result
	# Re-build texture with the correct palette if we have one
	if palette.size() >= 768:
		# Re-parse just enough to get skin data for re-texturing
		var skin_tex := _rebuild_texture_from_mdl(data, palette)
		if skin_tex:
			result["texture"] = skin_tex
	return result


## Read ALL frames from an MDL file. Returns:
## {"frames": Array[ArrayMesh], "frame_names": PackedStringArray, "texture": ImageTexture}
## or an empty Dictionary on failure. Each frame mesh shares the same triangles/UVs but
## has different vertex positions. The palette is used for correct texture colors.
static func read_mdl_all_frames(data: PackedByteArray, palette: PackedByteArray = PackedByteArray()) -> Dictionary:
	if data.size() < 84:
		push_warning("MDLReader.all_frames: Data too small (%d bytes)" % data.size())
		return {}

	var ident := data.slice(0, 4).get_string_from_ascii()
	if ident != "IDPO":
		push_warning("MDLReader.all_frames: Bad ident '%s' (expected IDPO)" % ident)
		return {}
	var version := data.decode_s32(4)
	if version != 6:
		push_warning("MDLReader.all_frames: Unsupported version %d" % version)
		return {}

	var scale := Vector3(
		data.decode_float(8), data.decode_float(12), data.decode_float(16))
	var origin := Vector3(
		data.decode_float(20), data.decode_float(24), data.decode_float(28))

	var numskins := data.decode_s32(48)
	var skinwidth := data.decode_s32(52)
	var skinheight := data.decode_s32(56)
	var numverts := data.decode_s32(60)
	var numtris := data.decode_s32(64)
	var numframes := data.decode_s32(68)

	if numskins <= 0 or numverts <= 0 or numtris <= 0 or numframes <= 0:
		push_warning("MDLReader.all_frames: Invalid counts skins=%d verts=%d tris=%d frames=%d" % [numskins, numverts, numtris, numframes])
		return {}

	var pos := 84

	# --- Skip skins (but grab first skin data for texture) ---
	var skin_data := PackedByteArray()
	var skin_pixels := skinwidth * skinheight

	for i in numskins:
		if pos + 4 > data.size():
			return {}
		var group := data.decode_s32(pos)
		pos += 4
		if group == 0:
			if i == 0:
				skin_data = data.slice(pos, pos + skin_pixels)
			pos += skin_pixels
		else:
			var num_in_group := data.decode_s32(pos)
			pos += 4
			pos += num_in_group * 4
			if i == 0:
				skin_data = data.slice(pos, pos + skin_pixels)
			pos += num_in_group * skin_pixels

	if skin_data.size() != skin_pixels:
		push_warning("MDLReader.all_frames: Skin data mismatch (got %d, expected %d)" % [skin_data.size(), skin_pixels])
		return {}

	# --- Texture Coordinates ---
	var tc_onseam := PackedInt32Array()
	var tc_s := PackedInt32Array()
	var tc_t := PackedInt32Array()
	tc_onseam.resize(numverts)
	tc_s.resize(numverts)
	tc_t.resize(numverts)

	for i in numverts:
		if pos + 12 > data.size():
			return {}
		tc_onseam[i] = data.decode_s32(pos)
		tc_s[i] = data.decode_s32(pos + 4)
		tc_t[i] = data.decode_s32(pos + 8)
		pos += 12

	# --- Triangles ---
	var tri_facesfront := PackedInt32Array()
	var tri_v := PackedInt32Array()
	tri_facesfront.resize(numtris)
	tri_v.resize(numtris * 3)

	for i in numtris:
		if pos + 16 > data.size():
			return {}
		tri_facesfront[i] = data.decode_s32(pos)
		tri_v[i * 3] = data.decode_s32(pos + 4)
		tri_v[i * 3 + 1] = data.decode_s32(pos + 8)
		tri_v[i * 3 + 2] = data.decode_s32(pos + 12)
		pos += 16

	# --- Read ALL frames ---
	var all_frame_verts: Array[PackedByteArray] = []
	var frame_names := PackedStringArray()

	for i in numframes:
		if pos + 4 > data.size():
			return {}
		var frame_type := data.decode_s32(pos)
		pos += 4

		if frame_type == 0:
			# Simple frame
			if pos + 24 + numverts * 4 > data.size():
				return {}
			pos += 4  # bboxmin
			pos += 4  # bboxmax
			# Read 16-byte name (null-terminated)
			var name_bytes := data.slice(pos, pos + 16)
			var fname := name_bytes.get_string_from_ascii().strip_edges()
			pos += 16
			all_frame_verts.append(data.slice(pos, pos + numverts * 4))
			frame_names.append(fname)
			pos += numverts * 4
		else:
			# Frame group — expand all sub-frames
			if pos + 4 > data.size():
				return {}
			var num_in_group := data.decode_s32(pos)
			pos += 4
			pos += 4  # group bboxmin
			pos += 4  # group bboxmax
			pos += num_in_group * 4  # float intervals

			for j in num_in_group:
				if pos + 24 + numverts * 4 > data.size():
					return {}
				pos += 4  # bboxmin
				pos += 4  # bboxmax
				var name_bytes := data.slice(pos, pos + 16)
				var fname := name_bytes.get_string_from_ascii().strip_edges()
				pos += 16
				all_frame_verts.append(data.slice(pos, pos + numverts * 4))
				frame_names.append(fname)
				pos += numverts * 4

	if all_frame_verts.is_empty():
		push_warning("MDLReader.all_frames: No frames loaded (numframes=%d)" % numframes)
		return {}

	# --- Pre-compute UV data (shared across all frames) ---
	var uv_data: Array = []  # Array of [vi, u, v] per triangle vertex
	for i in numtris:
		var ff: int = tri_facesfront[i]
		for k in [0, 2, 1]:  # Reverse winding for Godot
			var vi: int = tri_v[i * 3 + k]
			if vi < 0 or vi >= numverts:
				uv_data.append([0, 0.0, 0.0])
				continue
			var s: float = float(tc_s[vi])
			var t: float = float(tc_t[vi])
			if tc_onseam[vi] != 0 and ff == 0:
				s += float(skinwidth) * 0.5
			var u: float = (s + 0.5) / float(skinwidth)
			var v: float = (t + 0.5) / float(skinheight)
			uv_data.append([vi, u, v])

	# --- Build an ArrayMesh for each frame ---
	var frames: Array = []  # Array of ArrayMesh

	for fi in all_frame_verts.size():
		var raw_verts := all_frame_verts[fi]
		if raw_verts.size() != numverts * 4:
			continue

		# Decode vertex positions
		var positions := PackedVector3Array()
		positions.resize(numverts)
		for vi in numverts:
			var qx: float = scale.x * float(raw_verts[vi * 4]) + origin.x
			var qy: float = scale.y * float(raw_verts[vi * 4 + 1]) + origin.y
			var qz: float = scale.z * float(raw_verts[vi * 4 + 2]) + origin.z
			positions[vi] = Vector3(qx, qz, -qy) * Q2G

		# Build mesh using SurfaceTool
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for entry in uv_data:
			var vi: int = entry[0]
			var u: float = entry[1]
			var v: float = entry[2]
			st.set_uv(Vector2(u, v))
			st.add_vertex(positions[vi])
		st.generate_normals()
		frames.append(st.commit())

	# --- Build texture ---
	var texture: ImageTexture
	if palette.size() >= 768:
		texture = _build_texture(skin_data, skinwidth, skinheight, palette)
	else:
		texture = _build_texture(skin_data, skinwidth, skinheight)

	return {"frames": frames, "frame_names": frame_names, "texture": texture}


## Re-parse the MDL just for skin data and rebuild the texture with a given palette.
static func _rebuild_texture_from_mdl(data: PackedByteArray, palette: PackedByteArray) -> ImageTexture:
	if data.size() < 84:
		return null
	var numskins := data.decode_s32(48)
	var skinwidth := data.decode_s32(52)
	var skinheight := data.decode_s32(56)
	if numskins <= 0 or skinwidth <= 0 or skinheight <= 0:
		return null

	var pos := 84
	var skin_pixels := skinwidth * skinheight
	var group := data.decode_s32(pos)
	pos += 4

	var skin_data: PackedByteArray
	if group == 0:
		skin_data = data.slice(pos, pos + skin_pixels)
	else:
		var num_in_group := data.decode_s32(pos)
		pos += 4
		pos += num_in_group * 4  # intervals
		skin_data = data.slice(pos, pos + skin_pixels)

	if skin_data.size() != skin_pixels:
		return null
	return _build_texture(skin_data, skinwidth, skinheight, palette)


## Convert palette-indexed skin data to an ImageTexture.
static func _build_texture(skin_data: PackedByteArray, width: int, height: int, palette: PackedByteArray = PackedByteArray()) -> ImageTexture:
	if palette.is_empty():
		palette = QuakePalette.get_palette()

	var img_data := PackedByteArray()
	img_data.resize(width * height * 4)

	for i in skin_data.size():
		var idx: int = skin_data[i]
		var r: int = palette[idx * 3] if idx * 3 + 2 < palette.size() else 0
		var g: int = palette[idx * 3 + 1] if idx * 3 + 2 < palette.size() else 0
		var b: int = palette[idx * 3 + 2] if idx * 3 + 2 < palette.size() else 0
		var a: int = 0 if idx == 255 else 255
		img_data[i * 4] = r
		img_data[i * 4 + 1] = g
		img_data[i * 4 + 2] = b
		img_data[i * 4 + 3] = a

	var img := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, img_data)
	return ImageTexture.create_from_image(img)


## Load palette from PAK ("gfx/palette.lmp"), or return empty if not found.
static func load_palette_from_pak(pak: PAKReader) -> PackedByteArray:
	if pak == null:
		return PackedByteArray()
	var data := pak.read_entry("gfx/palette.lmp")
	if data.size() >= 768:
		return data.slice(0, 768)
	return PackedByteArray()


## Build a VAT (Vertex Animation Texture) for GPU-based frame interpolation.
## Returns {"mesh": ArrayMesh, "vat_texture": ImageTexture, "albedo_texture": ImageTexture,
##          "frame_names": PackedStringArray, "num_frames": int, "num_verts": int}
## All frame vertex positions are stored in a float texture.
## The vertex shader uses VERTEX_ID to sample the correct column.
static func read_mdl_vat(data: PackedByteArray, palette: PackedByteArray = PackedByteArray()) -> Dictionary:
	if data.size() < 84: return {}
	var ident := data.slice(0, 4).get_string_from_ascii()
	if ident != "IDPO" or data.decode_s32(4) != 6: return {}

	var mdl_scale := Vector3(
		data.decode_float(8), data.decode_float(12), data.decode_float(16))
	var mdl_origin := Vector3(
		data.decode_float(20), data.decode_float(24), data.decode_float(28))
	var numskins := data.decode_s32(48)
	var skinwidth := data.decode_s32(52)
	var skinheight := data.decode_s32(56)
	var numverts := data.decode_s32(60)
	var numtris := data.decode_s32(64)
	var numframes := data.decode_s32(68)
	if numskins <= 0 or numverts <= 0 or numtris <= 0 or numframes <= 0: return {}

	var pos := 84

	# --- Skins (grab first for texture) ---
	var skin_data := PackedByteArray()
	var skin_pixels := skinwidth * skinheight
	for i in numskins:
		if pos + 4 > data.size(): return {}
		var group := data.decode_s32(pos); pos += 4
		if group == 0:
			if i == 0: skin_data = data.slice(pos, pos + skin_pixels)
			pos += skin_pixels
		else:
			var nig := data.decode_s32(pos); pos += 4; pos += nig * 4
			if i == 0: skin_data = data.slice(pos, pos + skin_pixels)
			pos += nig * skin_pixels
	if skin_data.size() != skin_pixels: return {}

	# --- Texture Coordinates ---
	var tc_onseam := PackedInt32Array(); tc_onseam.resize(numverts)
	var tc_s := PackedInt32Array(); tc_s.resize(numverts)
	var tc_t := PackedInt32Array(); tc_t.resize(numverts)
	for i in numverts:
		if pos + 12 > data.size(): return {}
		tc_onseam[i] = data.decode_s32(pos)
		tc_s[i] = data.decode_s32(pos + 4)
		tc_t[i] = data.decode_s32(pos + 8)
		pos += 12

	# --- Triangles ---
	var tri_ff := PackedInt32Array(); tri_ff.resize(numtris)
	var tri_v := PackedInt32Array(); tri_v.resize(numtris * 3)
	for i in numtris:
		if pos + 16 > data.size(): return {}
		tri_ff[i] = data.decode_s32(pos)
		tri_v[i * 3] = data.decode_s32(pos + 4)
		tri_v[i * 3 + 1] = data.decode_s32(pos + 8)
		tri_v[i * 3 + 2] = data.decode_s32(pos + 12)
		pos += 16

	# --- Read ALL frames ---
	var all_frame_verts: Array[PackedByteArray] = []
	var frame_names := PackedStringArray()
	for _fi in numframes:
		if pos + 4 > data.size(): return {}
		var ftype := data.decode_s32(pos); pos += 4
		if ftype == 0:
			if pos + 24 + numverts * 4 > data.size(): return {}
			pos += 8
			var fname := data.slice(pos, pos + 16).get_string_from_ascii().strip_edges()
			pos += 16
			all_frame_verts.append(data.slice(pos, pos + numverts * 4))
			frame_names.append(fname)
			pos += numverts * 4
		else:
			if pos + 4 > data.size(): return {}
			var nig := data.decode_s32(pos); pos += 4
			pos += 8 + nig * 4
			for _j in nig:
				if pos + 24 + numverts * 4 > data.size(): return {}
				pos += 8
				var fname := data.slice(pos, pos + 16).get_string_from_ascii().strip_edges()
				pos += 16
				all_frame_verts.append(data.slice(pos, pos + numverts * 4))
				frame_names.append(fname)
				pos += numverts * 4
	if all_frame_verts.is_empty(): return {}
	var total_frames := all_frame_verts.size()

	# --- Pre-compute expanded vertex list (triangle corners with UV) ---
	var expanded_count := numtris * 3
	# expand_vi[i] = original MDL vertex index for expanded vertex i
	var expand_vi := PackedInt32Array(); expand_vi.resize(expanded_count)
	var uv_arr := PackedVector2Array(); uv_arr.resize(expanded_count)
	var eidx := 0
	for i in numtris:
		var ff: int = tri_ff[i]
		for k in [0, 2, 1]:
			var vi: int = tri_v[i * 3 + k]
			if vi < 0 or vi >= numverts: vi = 0
			expand_vi[eidx] = vi
			var s: float = float(tc_s[vi])
			var t: float = float(tc_t[vi])
			if tc_onseam[vi] != 0 and ff == 0:
				s += float(skinwidth) * 0.5
			uv_arr[eidx] = Vector2((s + 0.5) / float(skinwidth), (t + 0.5) / float(skinheight))
			eidx += 1

	# --- Build VAT texture (RGBAF float): width=total_frames, height=expanded_count ---
	# Layout: column = frame index, row = vertex index (matches texelFetch(ivec2(frame, VERTEX_ID)))
	var img := Image.create(total_frames, expanded_count, false, Image.FORMAT_RGBAF)
	for fi in total_frames:
		var fpos := _decode_frame(all_frame_verts[fi], numverts, mdl_scale, mdl_origin)
		for ei in expanded_count:
			var p: Vector3 = fpos[expand_vi[ei]]
			img.set_pixel(fi, ei, Color(p.x, p.y, p.z, 1.0))
	var vat_tex := ImageTexture.create_from_image(img)

	# --- Build base mesh from frame 0 (vertex index in UV2.x for shader lookup) ---
	var pos0 := _decode_frame(all_frame_verts[0], numverts, mdl_scale, mdl_origin)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ei in expanded_count:
		st.set_uv(uv_arr[ei])
		st.set_uv2(Vector2(float(ei), 0.0))
		st.add_vertex(pos0[expand_vi[ei]])
	st.generate_normals()
	var mesh: ArrayMesh = st.commit()

	# --- Build skin texture ---
	var albedo_tex: ImageTexture
	if palette.size() >= 768:
		albedo_tex = _build_texture(skin_data, skinwidth, skinheight, palette)
	else:
		albedo_tex = _build_texture(skin_data, skinwidth, skinheight)

	return {
		"mesh": mesh,
		"vat_texture": vat_tex,
		"albedo_texture": albedo_tex,
		"frame_names": frame_names,
		"num_frames": total_frames,
		"num_verts": expanded_count,
	}


## Decode raw MDL frame vertex bytes into world-space positions.
static func _decode_frame(raw: PackedByteArray, numverts: int, mdl_scale: Vector3, mdl_origin: Vector3) -> PackedVector3Array:
	var p := PackedVector3Array(); p.resize(numverts)
	for vi in numverts:
		var qx: float = mdl_scale.x * float(raw[vi * 4]) + mdl_origin.x
		var qy: float = mdl_scale.y * float(raw[vi * 4 + 1]) + mdl_origin.y
		var qz: float = mdl_scale.z * float(raw[vi * 4 + 2]) + mdl_origin.z
		p[vi] = Vector3(qx, qz, -qy) * Q2G
	return p
