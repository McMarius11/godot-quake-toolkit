# SPDX-License-Identifier: MIT
# Copyright (c) 2026 McMarius11
extends Node
## Animates lightmap atlas regions for BSP29 light styles.
## Work is spread across multiple render frames to prevent spikes.

const ANIM_INTERVAL := 0.1  # 10fps animation rate
const FACES_PER_FRAME := 500  # Process this many faces per render frame

## BSP29 standard light animation patterns (styles 0-11).
## Each character maps to a brightness level: 'a'=dark, 'm'=normal, 'z'=bright.
const STYLE_PATTERNS: Array[String] = [
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

var _atlas_image: Image
var _atlas_texture: ImageTexture
var _atlas_width: int = 0
var _atlas_data: PackedByteArray
var _animated_faces: Array[Dictionary]
var _anim_time: float = 0.0
var _frame: int = 0

# Batch state: spread work across render frames
var _batch_cursor: int = 0
var _batch_target_frame: int = -1  # Which animation frame we're processing
var _needs_upload: bool = false


func setup(atlas_image: Image, atlas_texture: ImageTexture, animated_faces: Array[Dictionary]) -> void:
	_atlas_image = atlas_image
	_atlas_texture = atlas_texture
	_atlas_width = atlas_image.get_width()
	_atlas_data = atlas_image.get_data()
	_animated_faces = animated_faces


func _process(delta: float) -> void:
	if _animated_faces.is_empty():
		return

	# Advance animation clock
	_anim_time += delta
	if _anim_time >= ANIM_INTERVAL:
		_anim_time -= ANIM_INTERVAL
		_frame += 1

	# Start new batch only when previous one is complete
	if _batch_cursor >= _animated_faces.size() and _batch_target_frame != _frame:
		_batch_cursor = 0
		_batch_target_frame = _frame

	# Process a batch of faces (spread across render frames)
	if _batch_cursor < _animated_faces.size():
		var end := mini(_batch_cursor + FACES_PER_FRAME, _animated_faces.size())
		_update_batch(_batch_cursor, end)
		_batch_cursor = end
		_needs_upload = true

	# Upload once when batch is complete
	if _needs_upload and _batch_cursor >= _animated_faces.size():
		_needs_upload = false
		_atlas_image.set_data(_atlas_width, _atlas_image.get_height(), false, Image.FORMAT_L8, _atlas_data)
		_atlas_texture.update(_atlas_image)


func _update_batch(from: int, to: int) -> void:
	var stride: int = _atlas_width

	for face_idx in range(from, to):
		var face_data: Dictionary = _animated_faces[face_idx]
		var ax: int = face_data.atlas_x
		var ay: int = face_data.atlas_y
		var w: int = face_data.lm_width
		var h: int = face_data.lm_height
		var styles: Array = face_data.styles
		var num_s: int = styles.size()

		# Compute current scales for each style
		var scales := PackedFloat32Array()
		scales.resize(num_s)
		for i in num_s:
			var sid: int = styles[i].style
			if sid < STYLE_PATTERNS.size():
				var pattern: String = STYLE_PATTERNS[sid]
				var ch: int = pattern.unicode_at(_frame % pattern.length())
				scales[i] = float(ch - 97) / 12.0
			else:
				scales[i] = 1.0

		# Write L8 bytes
		for y in h:
			var row_off: int = (ay + y) * stride + ax
			for x in w:
				var idx: int = y * w + x
				var total := 0.0
				for i in num_s:
					total += float((styles[i].data as PackedByteArray)[idx]) * scales[i]
				_atlas_data[row_off + x] = clampi(int(total), 0, 255)
