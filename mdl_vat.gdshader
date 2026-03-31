// SPDX-License-Identifier: MIT
// Copyright (c) 2026 McMarius11
shader_type spatial;
// cull_disabled: matches Quake — low-poly MDL models have edge-on triangles
// that flip between front/back facing during rotation, causing visual twist.
render_mode cull_disabled, unshaded;

// Albedo texture (original MDL skin)
uniform sampler2D albedo_tex : source_color, filter_nearest;

// VAT position texture: width = num_frames, height = num_verts, FORMAT_RGBAF
// NO source_color — float position data must not be gamma-converted
uniform sampler2D vat_tex : filter_nearest, repeat_disable;

// Animation uniforms — updated from GDScript each frame
uniform int frame_a = 0;
uniform int frame_b = 0;
uniform float lerp_frac = 0.0;

void vertex() {
	// Vertex index encoded in UV2.x by MDL loader
	int vert_id = int(UV2.x + 0.5);
	vec3 pos_a = texelFetch(vat_tex, ivec2(frame_a, vert_id), 0).rgb;
	vec3 pos_b = texelFetch(vat_tex, ivec2(frame_b, vert_id), 0).rgb;

	VERTEX = mix(pos_a, pos_b, lerp_frac);
}

void fragment() {
	vec4 col = texture(albedo_tex, UV);
	if (col.a < 0.5) discard;
	ALBEDO = col.rgb;
}
