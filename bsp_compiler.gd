# SPDX-License-Identifier: MIT
# Copyright (c) 2026 McMarius11
class_name BSPCompiler
## Compiles .map files to .bsp using ericw-tools qbsp.
## Usage:
##   var result := BSPCompiler.compile("res://maps/mymap.map")
##   if result.ok:
##       print("BSP at: ", result.bsp_path)

# NOTE: ericw-tools qbsp is GPL-licensed. Do not distribute the binary — users must provide their own.
const QBSP_PATH := "res://tools/ericw-tools/qbsp"
const TOOLS_DIR := "res://tools/ericw-tools/"


## Result of a compilation attempt.
class CompileResult:
	var ok: bool = false
	var bsp_path: String = ""
	var output: String = ""
	var error: String = ""


## Compile a .map file to .bsp. Returns CompileResult.
## If the .bsp already exists and is newer than the .map, returns cached result
## unless force is true.
static func compile(map_path: String, force: bool = false) -> CompileResult:
	var result := CompileResult.new()

	# Resolve to absolute filesystem paths
	var abs_map := ProjectSettings.globalize_path(map_path) if map_path.begins_with("res://") else map_path
	if not FileAccess.file_exists(abs_map):
		result.error = "Map file not found: %s" % abs_map
		return result

	# Determine output .bsp path (same directory, same basename)
	var bsp_path := abs_map.get_basename() + ".bsp"

	# Cache check: skip if .bsp is newer than .map
	if not force and FileAccess.file_exists(bsp_path):
		var map_mod := FileAccess.get_modified_time(abs_map)
		var bsp_mod := FileAccess.get_modified_time(bsp_path)
		if bsp_mod > map_mod:
			result.ok = true
			result.bsp_path = bsp_path
			result.output = "Cached (bsp newer than map)"
			return result

	# Fix WAD paths in the map before compiling
	_fix_wad_paths(abs_map)

	# Resolve qbsp binary path
	var abs_qbsp := ProjectSettings.globalize_path(QBSP_PATH)
	var abs_tools_dir := ProjectSettings.globalize_path(TOOLS_DIR)

	if not FileAccess.file_exists(abs_qbsp):
		result.error = "qbsp binary not found: %s" % abs_qbsp
		return result

	# Build command with LD_LIBRARY_PATH for shared libs
	var output: Array = []
	var args := PackedStringArray([abs_map])

	# Set LD_LIBRARY_PATH so qbsp can find its shared libraries
	# We use a wrapper shell command for this
	var shell_cmd := "LD_LIBRARY_PATH=\"%s\":$LD_LIBRARY_PATH \"%s\" \"%s\"" % [
		abs_tools_dir, abs_qbsp, abs_map
	]

	var exit_code := OS.execute("bash", PackedStringArray(["-c", shell_cmd]), output, true)

	var stdout_text: String = output[0] if output.size() > 0 else ""

	if exit_code != 0:
		result.error = "qbsp failed (exit %d):\n%s" % [exit_code, stdout_text]
		result.output = stdout_text
		return result

	if not FileAccess.file_exists(bsp_path):
		result.error = "qbsp succeeded but .bsp not found at: %s" % bsp_path
		result.output = stdout_text
		return result

	result.ok = true
	result.bsp_path = bsp_path
	result.output = stdout_text
	return result


## Fix WAD paths in worldspawn. Quake maps often have absolute Windows paths
## for the "wad" key. We rewrite them to point at res://textures/wads/.
static func _fix_wad_paths(abs_map_path: String) -> void:
	var f := FileAccess.open(abs_map_path, FileAccess.READ)
	if not f:
		return
	var content := f.get_as_text()
	f.close()

	# Find "wad" key in worldspawn (first entity block)
	var regex := RegEx.new()
	regex.compile("\"wad\"\\s+\"([^\"]+)\"")
	var m := regex.search(content)
	if not m:
		return

	var old_wad := m.get_string(1)
	# Extract just the filenames from the potentially multi-path wad value
	# WAD paths can be semicolon-separated, with full absolute paths
	var wad_parts := old_wad.replace("\\", "/").split(";", false)
	var new_parts: PackedStringArray = []
	var wads_dir := ProjectSettings.globalize_path("res://textures/wads/")

	for part in wad_parts:
		var filename := part.get_file()
		if filename.is_empty():
			continue
		var local_path := wads_dir.path_join(filename)
		if FileAccess.file_exists(local_path):
			new_parts.append(local_path)
		else:
			# Keep original if we can't find it locally — qbsp may still find it
			new_parts.append(part)

	var new_wad := ";".join(new_parts)
	if new_wad == old_wad:
		return

	content = content.replace("\"wad\" \"%s\"" % old_wad, "\"wad\" \"%s\"" % new_wad)

	var fw := FileAccess.open(abs_map_path, FileAccess.WRITE)
	if fw:
		fw.store_string(content)
		fw.close()
		print("BSPCompiler: Fixed WAD paths in %s" % abs_map_path)
