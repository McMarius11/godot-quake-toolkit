# SPDX-License-Identifier: MIT
# Copyright (c) 2026 McMarius11
class_name PAKReader
## Reads Quake .pak archive files and extracts entries.
## PAK format: "PACK" header (4 bytes), dir_offset (int32), dir_size (int32).
## Directory: array of 64-byte entries (56-byte filename + offset + size).

class PAKEntry:
	var name: String
	var offset: int
	var size: int


var _entries: Array[PAKEntry] = []
var _pak_path: String = ""


## Open a .pak file and read its directory. Returns true on success.
func open(path: String) -> bool:
	_entries.clear()
	_pak_path = path

	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		push_error("PAKReader: Cannot open %s" % path)
		return false

	# Header
	var magic := f.get_buffer(4)
	if magic != PackedByteArray([0x50, 0x41, 0x43, 0x4B]):  # "PACK"
		push_error("PAKReader: Not a PAK file: %s" % path)
		return false

	var dir_offset := f.get_32()
	var dir_size := f.get_32()
	@warning_ignore("INTEGER_DIVISION")
	var num_entries: int = dir_size / 64

	# Read directory
	f.seek(dir_offset)
	_entries.resize(num_entries)
	for i in num_entries:
		var entry := PAKEntry.new()
		var name_bytes := f.get_buffer(56)
		# Find null terminator
		var null_pos := 56
		for j in 56:
			if name_bytes[j] == 0:
				null_pos = j
				break
		entry.name = name_bytes.slice(0, null_pos).get_string_from_ascii()
		entry.offset = f.get_32()
		entry.size = f.get_32()
		_entries[i] = entry

	f.close()
	return true


## List all entries in the PAK.
func list_entries() -> PackedStringArray:
	var result := PackedStringArray()
	for e in _entries:
		result.append(e.name)
	return result


## List only .bsp map files.
func list_maps() -> PackedStringArray:
	var result := PackedStringArray()
	for e in _entries:
		if e.name.ends_with(".bsp") and e.name.begins_with("maps/"):
			# Skip model BSPs (b_*.bsp are item/ammo box models)
			var basename := e.name.get_file().get_basename()
			if not basename.begins_with("b_"):
				result.append(basename)
	return result


## Find an entry by name. Returns null if not found.
func find_entry(name: String) -> PAKEntry:
	for e in _entries:
		if e.name == name:
			return e
	return null


## Extract a file from the PAK to a destination path. Returns true on success.
func extract(entry_name: String, dest_path: String) -> bool:
	var entry := find_entry(entry_name)
	if not entry:
		push_error("PAKReader: Entry not found: %s" % entry_name)
		return false

	var f := FileAccess.open(_pak_path, FileAccess.READ)
	if not f:
		return false

	f.seek(entry.offset)
	var data := f.get_buffer(entry.size)
	f.close()

	# Ensure destination directory exists
	var dir := dest_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var out := FileAccess.open(dest_path, FileAccess.WRITE)
	if not out:
		push_error("PAKReader: Cannot write to %s" % dest_path)
		return false

	out.store_buffer(data)
	out.close()
	return true


## Extract a BSP map by map name (e.g. "lq_e1m1") to the cache directory.
## Returns the absolute path to the extracted .bsp, or "" on failure.
func extract_map(map_name: String, cache_dir: String = "user://bsp_cache/") -> String:
	var entry_name := "maps/%s.bsp" % map_name
	var entry := find_entry(entry_name)
	if not entry:
		push_error("PAKReader: Map not found in PAK: %s" % entry_name)
		return ""

	var dest := cache_dir.path_join("%s.bsp" % map_name)
	var abs_dest := ProjectSettings.globalize_path(dest)

	# Check cache: if extracted file exists and has correct size, skip
	if FileAccess.file_exists(abs_dest):
		var existing := FileAccess.open(abs_dest, FileAccess.READ)
		if existing:
			var existing_size := existing.get_length()
			existing.close()
			if existing_size == entry.size:
				return abs_dest

	if extract(entry_name, abs_dest):
		@warning_ignore("INTEGER_DIVISION")
		print("PAKReader: Extracted %s (%d KB)" % [entry_name, entry.size / 1024])
		return abs_dest

	return ""


## Read raw bytes of an entry without extracting to disk.
func read_entry(entry_name: String) -> PackedByteArray:
	var entry := find_entry(entry_name)
	if not entry:
		return PackedByteArray()

	var f := FileAccess.open(_pak_path, FileAccess.READ)
	if not f:
		return PackedByteArray()

	f.seek(entry.offset)
	var data := f.get_buffer(entry.size)
	f.close()
	return data
