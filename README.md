# Godot Quake Toolkit

**The first complete Quake 1 asset pipeline for Godot 4.**

Load BSP levels, MDL models, SPR sprites, WAD textures, and PAK archives at runtime — entirely in GDScript, zero native dependencies.

## Features

| Reader | Format | What it does |
|--------|--------|-------------|
| **PAK Reader** | PACK (.pak) | Extract files from Quake PAK archives |
| **BSP Reader** | BSP29 (.bsp) | Load complete levels with geometry, collision, lightmaps, entities |
| **MDL Reader** | IDPO v6 (.mdl) | Load models with frame-based animation and VAT shader support |
| **SPR Reader** | IDSP v1/v2 (.spr) | Load sprite sheets (explosions, torches, particle effects) |
| **WAD Reader** | WAD2 (.wad) | Load texture archives used by BSP maps |
| **BSP Compiler** | .map to .bsp | Compile TrenchBroom maps via ericw-tools |
| **PVS Culler** | BSP VIS data | Potentially Visible Set culling for performance |
| **Palette** | 256-color LUT | Shared color palette for all format decoders |
| **Lightmap Animator** | BSP light styles | Animated lights (flicker, pulse, strobe — 12 patterns) |
| **Collision Layers** | — | Named physics layer constants (WORLD, PLAYER, ENEMY, etc.) |
| **VAT Shader** | GLSL | GPU vertex animation for smooth MDL model interpolation |

## What makes this different

- **Runtime loading** — load Quake assets at runtime from PAK files, not just editor import
- **Full lightmaps** — static and animated light styles, atlas-based, all 12 Quake light patterns
- **PVS/VIS culling** — real BSP visibility optimization, not just brute-force rendering
- **VAT animation** — GPU-accelerated Vertex Animation Textures for smooth MDL interpolation
- **Entity data** — parsed and ready for your entity spawning system
- **Pure GDScript** — no GDExtension, no C++, no native dependencies. Drop in and go.

## Quick Start

### Load a PAK file and extract a sound
```gdscript
var pak := PAKReader.new()
pak.open("path/to/id1/pak0.pak")

var wav_data := pak.read_entry("sound/weapons/guncock.wav")
```

### Load a BSP level
```gdscript
var reader := BSPReader.new()
var level_root := reader.read_bsp("path/to/e1m1.bsp")
add_child(level_root)

# Entity data is available as metadata
var entities: Array = level_root.get_meta("entities")
for ent in entities:
    print(ent["classname"])  # "info_player_start", "monster_ogre", etc.
```

### Load an MDL model with animation
```gdscript
var mdl := MDLReader.new()
var pak_data := pak.read_entry("progs/soldier.mdl")

# Option A: Individual frame meshes
var result := mdl.read_mdl(pak_data)
# result.mesh       — ArrayMesh (first frame)
# result.texture    — ImageTexture (skin)
# result.frame_names — PackedStringArray

# Option B: VAT for GPU-interpolated animation
var vat := mdl.read_mdl_vat(pak_data)
# vat.mesh          — ArrayMesh with UV2 vertex indices
# vat.vat_texture   — ImageTexture (vertex positions encoded as pixels)
# vat.frame_names   — animation frame names
```

### Load a sprite
```gdscript
var spr := SPRReader.new()
var spr_data := pak.read_entry("progs/s_explod.spr")
var result := spr.read_spr(spr_data)
# result.frames — Array of ImageTexture (animation frames)
# result.type   — sprite orientation type
```

### Load WAD textures
```gdscript
var wad := WADReader.new()
wad.open("path/to/medieval.wad")

var tex_names := wad.get_texture_names()
var texture := wad.get_texture("brick_wall")  # returns ImageTexture
```

## File Overview

```
godot-quake-toolkit/
    pak_reader.gd          — PAK archive reading
    bsp_reader.gd          — BSP29 level loading (geometry, lightmaps, PVS, entities)
    mdl_reader.gd          — MDL model loading (meshes, skins, animations, VAT)
    spr_reader.gd          — SPR sprite loading (Quake 1 + Half-Life formats)
    wad_reader.gd          — WAD2 texture archive loading
    bsp_compiler.gd        — .map to BSP compilation wrapper (requires ericw-tools)
    bsp_pvs_culler.gd      — Runtime PVS visibility culling
    quake_palette.gd       — Shared 256-color palette for format decoders
    lightmap_animator.gd   — Animated lightmap styles (flicker, pulse, strobe)
    collision_layers.gd    — Named physics collision layer constants
    mdl_vat.gdshader       — GPU vertex animation shader for MDL models
    LICENSE                — MIT License
    NOTICE                 — Legal notices and attribution
```

## Requirements

- **Godot 4.2+**
- No plugins, no GDExtension, no native libraries
- For BSP compilation only: [ericw-tools](https://github.com/ericwa/ericw-tools) (users must provide their own copy)

## Setup Notes

The BSP Reader looks for optional loose textures at `res://textures/lq/` and a palette file at `res://textures/palette.lmp`. These paths are configurable in the source.

For WAD texture support (maps referencing external WAD files), set the `wad_texture_loader` callback before loading:

```gdscript
var reader := BSPReader.new()
reader.wad_texture_loader = func(wad_path: String, tex_name: String) -> ImageTexture:
    # Your WAD loading logic here
    var wad := WADReader.new()
    wad.open(wad_path)
    return wad.get_texture(tex_name)
var level := reader.read_bsp("path/to/map.bsp")
```

Without this callback, the BSP Reader decodes textures from the embedded miptex data in the BSP file — which works for most maps.

## Supported Formats

| Format | Version | Read | Write |
|--------|---------|------|-------|
| PAK (PACK) | Quake 1 | Yes | — |
| BSP (BSP29) | Quake 1 | Yes | Via ericw-tools |
| MDL (IDPO) | Version 6 | Yes | — |
| SPR (IDSP) | v1 (Quake 1), v2/v32 (Half-Life) | Yes | — |
| WAD | WAD2 (Quake), WAD3 (Half-Life) | Yes | — |

## How it works

All readers take raw binary data (`PackedByteArray`) or file paths and produce Godot-native objects:

- BSP maps become a **Node3D** scene tree with MeshInstance3D, StaticBody3D, and CollisionShape3D nodes
- MDL models become **ArrayMesh** with **ImageTexture** skins
- SPR sprites become arrays of **ImageTexture** frames
- WAD textures become **ImageTexture** instances
- All coordinate conversion (Quake Z-up to Godot Y-up) is handled automatically

The palette is sourced from LibreQuake (BSD 3-Clause). When loading original Quake assets, the palette is read from the user's own PAK file for correct colors.

## Asset Loading Architecture

This toolkit does **not** bundle any proprietary game assets. The intended usage is:

1. User provides their own Quake `id1/` directory (or LibreQuake)
2. Your game loads assets at runtime via PAK Reader
3. BSP Reader builds the level geometry
4. Your entity system spawns gameplay objects from BSP entity data

This is the same architecture used by OpenMW, Daggerfall Unity, and other engine reimplementations.

## License

MIT License. See [LICENSE](LICENSE) for details.

The embedded color palette is from the [LibreQuake](https://github.com/lavenderdotpet/LibreQuake) project (BSD 3-Clause License).

## Credits

Built with [Godot Engine](https://godotengine.org) (MIT License).
