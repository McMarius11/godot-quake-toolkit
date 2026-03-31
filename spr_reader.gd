# SPDX-License-Identifier: MIT
# Copyright (c) 2026 McMarius11
class_name SPRReader
## Reads Quake 1 SPR (version 1, "IDSP") binary data and produces
## an array of Godot ImageTexture frames suitable for rendering sprites.
## Supports single frames and frame groups.

## Sprite orientation types
enum SprType {
	VP_PARALLEL_UPRIGHT = 0,
	FACING_UPRIGHT = 1,
	VP_PARALLEL = 2,
	ORIENTED = 3,
	VP_PARALLEL_ORIENTED = 4,
}

## Sprite texture format types
enum SprTexFormat {
	SPR_NORMAL = 0,
	SPR_ADDITIVE = 1,
	SPR_INDEXALPHA = 2,
	SPR_ALPHTEST = 3,
}


## Read an SPR file from raw bytes. Returns:
## {"frames": Array[ImageTexture], "type": int, "tex_format": int, "width": int, "height": int}
## or an empty Dictionary on failure.
static func read_spr(data: PackedByteArray, palette: PackedByteArray = PackedByteArray()) -> Dictionary:
	if data.size() < 40:
		push_warning("SPRReader: Data too small for header (%d bytes)" % data.size())
		return {}

	# --- Header (40 bytes) ---
	var ident := data.slice(0, 4).get_string_from_ascii()
	if ident != "IDSP":
		push_warning("SPRReader: Bad ident '%s' (expected IDSP)" % ident)
		return {}

	var version := data.decode_s32(4)
	if version != 1 and version != 2 and version != 32:
		push_warning("SPRReader: Unsupported version %d (expected 1, 2, or 32)" % version)
		return {}

	var spr_type := data.decode_s32(8)
	var tex_format := data.decode_s32(12)
	# boundingradius (16) — skip
	var maxwidth := data.decode_s32(20)
	var maxheight := data.decode_s32(24)
	var numframes := data.decode_s32(28)
	# beamlength (32), synctype (36) — skip

	# ident(4)+version(4)+type(4)+texFormat(4)+boundingradius(4)+maxwidth(4)+maxheight(4)+numframes(4)+beamlength(4)+synctype(4) = 40 bytes
	var pos := 40

	# Version 2/32 (Half-Life style): embedded palette after header
	if version == 2 or version == 32:
		if data.size() >= pos + 2:
			var pal_size := data.decode_u16(pos)
			pos += 2
			if pal_size > 0 and data.size() >= pos + pal_size * 3:
				palette = data.slice(pos, pos + pal_size * 3)
				pos += pal_size * 3

	if numframes <= 0:
		return {}

	if palette.is_empty():
		palette = QuakePalette.get_palette()

	var frames: Array[ImageTexture] = []

	for _i in numframes:
		if pos + 4 > data.size():
			push_warning("SPRReader: Unexpected end of data at frame %d" % _i)
			return {}

		var frame_type := data.decode_s32(pos)
		pos += 4

		if frame_type == 0:
			# Single frame
			var result := _read_single_frame(data, pos, palette, tex_format)
			if result.is_empty():
				return {}
			frames.append(result["texture"])
			pos = result["next_pos"]
		else:
			# Frame group — read all sub-frames, keep the first one
			if pos + 4 > data.size():
				push_warning("SPRReader: Unexpected end of data in frame group")
				return {}
			var num_in_group := data.decode_s32(pos)
			pos += 4

			# Skip interval floats
			pos += num_in_group * 4

			for j in num_in_group:
				var result := _read_single_frame(data, pos, palette, tex_format)
				if result.is_empty():
					return {}
				# Keep all sub-frames as individual frames
				frames.append(result["texture"])
				pos = result["next_pos"]

	return {
		"frames": frames,
		"type": spr_type,
		"tex_format": tex_format,
		"width": maxwidth,
		"height": maxheight,
	}


## Read a single frame's data starting at the given position.
## Returns {"texture": ImageTexture, "next_pos": int} or empty dict on failure.
static func _read_single_frame(data: PackedByteArray, pos: int, palette: PackedByteArray, tex_format: int) -> Dictionary:
	if pos + 16 > data.size():
		push_warning("SPRReader: Unexpected end of data in single frame header")
		return {}

	var _origin_x := data.decode_s32(pos)
	var _origin_y := data.decode_s32(pos + 4)
	var width := data.decode_s32(pos + 8)
	var height := data.decode_s32(pos + 12)
	pos += 16

	var pixel_count := width * height
	if pos + pixel_count > data.size():
		push_warning("SPRReader: Unexpected end of data in frame pixels (need %d, have %d)" % [pixel_count, data.size() - pos])
		return {}

	var pixel_data := data.slice(pos, pos + pixel_count)
	pos += pixel_count

	var texture := _build_sprite_texture(pixel_data, width, height, palette, tex_format)
	return {"texture": texture, "next_pos": pos}


## Convert palette-indexed sprite pixel data to an ImageTexture.
static func _build_sprite_texture(pixel_data: PackedByteArray, width: int, height: int, palette: PackedByteArray, tex_format: int) -> ImageTexture:
	var img_data := PackedByteArray()
	img_data.resize(width * height * 4)

	for i in pixel_data.size():
		var idx: int = pixel_data[i]
		var r: int = palette[idx * 3] if idx * 3 + 2 < palette.size() else 0
		var g: int = palette[idx * 3 + 1] if idx * 3 + 2 < palette.size() else 0
		var b: int = palette[idx * 3 + 2] if idx * 3 + 2 < palette.size() else 0
		var a: int = 255

		match tex_format:
			SprTexFormat.SPR_ALPHTEST:
				# Index 255 = fully transparent
				if idx == 255:
					a = 0
			SprTexFormat.SPR_ADDITIVE:
				# Alpha based on pixel brightness
				@warning_ignore("INTEGER_DIVISION")
				a = clampi((r + g + b) / 3, 0, 255)
			SprTexFormat.SPR_INDEXALPHA:
				# Index value IS the alpha, color is white
				a = idx
				r = 255
				g = 255
				b = 255

		img_data[i * 4] = r
		img_data[i * 4 + 1] = g
		img_data[i * 4 + 2] = b
		img_data[i * 4 + 3] = a

	var img := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, img_data)
	return ImageTexture.create_from_image(img)
