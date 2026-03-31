# SPDX-License-Identifier: MIT
# Copyright (c) 2026 McMarius11
class_name WADReader
## Reads Quake WAD2 texture archive files at runtime.
## WAD2 format: "WAD2" header (12 bytes), directory of 32-byte entries,
## miptex lumps with embedded palettes after pixel data.
##
## Usage:
##   var wad := WADReader.new()
##   if wad.open("/path/to/gfx.wad"):
##       var tex := wad.get_texture("bricks", palette)

const LUMP_TYPE_PALETTE := 0x40  # '@'
const LUMP_TYPE_BITMAP := 0x42   # 'B'
const LUMP_TYPE_MIPTEX := 0x44   # 'D'
const LUMP_TYPE_FONT := 0x45     # 'E'


class WADEntry:
	var name: String
	var offset: int
	var dsize: int      # disk size
	var size: int        # uncompressed size
	var type: int
	var compression: int


var _entries: Array[WADEntry] = []
var _wad_path: String = ""
var _entry_map: Dictionary = {}  # lowercase name -> WADEntry


## Open a WAD2 file and read its header + directory. Returns true on success.
func open(path: String) -> bool:
	_entries.clear()
	_entry_map.clear()
	_wad_path = path

	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		push_error("WADReader: Cannot open %s" % path)
		return false

	# Header: 12 bytes
	if f.get_length() < 12:
		push_error("WADReader: File too small: %s" % path)
		return false

	var magic := f.get_buffer(4)
	var magic_str := magic.get_string_from_ascii()
	if magic_str != "WAD2":
		push_error("WADReader: Not a WAD2 file (got '%s'): %s" % [magic_str, path])
		return false

	var numlumps: int = f.get_32()
	var diroffset: int = f.get_32()

	if diroffset + numlumps * 32 > f.get_length():
		push_error("WADReader: Directory extends past end of file: %s" % path)
		return false

	# Read directory: 32 bytes per entry
	f.seek(diroffset)
	_entries.resize(numlumps)

	for i in numlumps:
		var entry := WADEntry.new()
		entry.offset = f.get_32()
		entry.dsize = f.get_32()
		entry.size = f.get_32()
		entry.type = f.get_8()
		entry.compression = f.get_8()
		f.get_buffer(2)  # padding

		# Name: 16 bytes, null-terminated
		var name_bytes := f.get_buffer(16)
		var null_pos := 16
		for j in 16:
			if name_bytes[j] == 0:
				null_pos = j
				break
		entry.name = name_bytes.slice(0, null_pos).get_string_from_ascii()

		_entries[i] = entry
		_entry_map[entry.name.to_lower()] = entry

	f.close()
	# WADReader: Opened %s (%d lumps)
	return true


## Get all texture names in the WAD.
func get_texture_names() -> PackedStringArray:
	var result := PackedStringArray()
	for e in _entries:
		if e.type == LUMP_TYPE_MIPTEX:
			result.append(e.name)
	return result


## Check if a texture exists in the WAD (case-insensitive).
func has_texture(name: String) -> bool:
	var key := name.to_lower()
	if key not in _entry_map:
		return false
	return _entry_map[key].type == LUMP_TYPE_MIPTEX


## Read a miptex lump and convert to an ImageTexture.
## Uses the embedded palette if present, otherwise falls back to the provided palette.
## Returns null on failure.
func get_texture(name: String, palette: PackedByteArray = PackedByteArray()) -> ImageTexture:
	var key := name.to_lower()
	if key not in _entry_map:
		push_warning("WADReader: Texture not found: %s" % name)
		return null

	var entry: WADEntry = _entry_map[key]
	if entry.type != LUMP_TYPE_MIPTEX:
		push_warning("WADReader: Entry '%s' is not a miptex (type 0x%02X)" % [name, entry.type])
		return null

	if entry.compression != 0:
		push_warning("WADReader: Compressed lumps not supported: %s" % name)
		return null

	var f := FileAccess.open(_wad_path, FileAccess.READ)
	if not f:
		return null

	f.seek(entry.offset)
	var data := f.get_buffer(entry.dsize)
	f.close()

	if data.size() < 40:
		push_warning("WADReader: Miptex data too small for '%s'" % name)
		return null

	return _parse_miptex(data, palette)


## Read raw bytes of any lump entry by name.
func read_entry(name: String) -> PackedByteArray:
	var key := name.to_lower()
	if key not in _entry_map:
		return PackedByteArray()

	var entry: WADEntry = _entry_map[key]

	var f := FileAccess.open(_wad_path, FileAccess.READ)
	if not f:
		return PackedByteArray()

	f.seek(entry.offset)
	var data := f.get_buffer(entry.dsize)
	f.close()
	return data


## Parse a miptex lump into an ImageTexture.
## Miptex header: name(16) + width(4) + height(4) + offset1-4(16) = 40 bytes.
## After mip4 pixel data: 2 bytes palette count + 768 bytes RGB palette (embedded).
static func _parse_miptex(data: PackedByteArray, fallback_palette: PackedByteArray = PackedByteArray()) -> ImageTexture:
	if data.size() < 40:
		return null

	# Skip 16-byte name in the miptex header
	var width: int = data.decode_u32(16)
	var height: int = data.decode_u32(20)
	var offset1: int = data.decode_u32(24)
	# offset2 at 28, offset3 at 32, offset4 at 36

	if width <= 0 or height <= 0 or width > 4096 or height > 4096:
		push_warning("WADReader: Invalid miptex dimensions %dx%d" % [width, height])
		return null

	var pixel_count := width * height
	if offset1 + pixel_count > data.size():
		push_warning("WADReader: Miptex pixel data extends past lump (offset=%d, pixels=%d, size=%d)" % [offset1, pixel_count, data.size()])
		return null

	var pixels := data.slice(offset1, offset1 + pixel_count)

	# Try to find embedded palette after the last mip level.
	# Mip4 offset is at byte 36 in the header, mip4 size = (width/8) * (height/8).
	var palette := _try_extract_embedded_palette(data, width, height)
	if palette.is_empty() and fallback_palette.size() >= 768:
		palette = fallback_palette
	if palette.is_empty():
		palette = QuakePalette.get_palette()

	# Convert palette-indexed pixels to RGBA8
	var img_data := PackedByteArray()
	img_data.resize(pixel_count * 4)

	for i in pixel_count:
		var idx: int = pixels[i]
		var r: int = palette[idx * 3] if idx * 3 + 2 < palette.size() else 0
		var g: int = palette[idx * 3 + 1] if idx * 3 + 2 < palette.size() else 0
		var b: int = palette[idx * 3 + 2] if idx * 3 + 2 < palette.size() else 0
		# Index 255 is transparent in Quake textures (used for '{' prefix textures)
		var a: int = 0 if idx == 255 else 255
		img_data[i * 4] = r
		img_data[i * 4 + 1] = g
		img_data[i * 4 + 2] = b
		img_data[i * 4 + 3] = a

	var img := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, img_data)
	var tex := ImageTexture.create_from_image(img)
	return tex


## Try to extract the embedded palette from after the last mip level.
## Returns 768-byte PackedByteArray or empty if not found.
static func _try_extract_embedded_palette(data: PackedByteArray, width: int, height: int) -> PackedByteArray:
	# Mip level 4 offset is stored at byte 36
	if data.size() < 40:
		return PackedByteArray()

	var offset4: int = data.decode_u32(36)
	@warning_ignore("INTEGER_DIVISION")
	var mip4_size: int = (width / 8) * (height / 8)
	var palette_start: int = offset4 + mip4_size

	# After mip4 data: 2 bytes for palette count, then 256*3 bytes of RGB
	if palette_start + 2 + 768 > data.size():
		return PackedByteArray()

	var palette_count: int = data.decode_u16(palette_start)
	if palette_count != 256:
		# Not a standard 256-color palette — might not be embedded
		return PackedByteArray()

	return data.slice(palette_start + 2, palette_start + 2 + 768)
