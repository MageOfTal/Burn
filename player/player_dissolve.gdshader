shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

// Base color for the player mesh.
uniform vec4 albedo_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
// Driven by player_camera.gd: 1.0 = fully visible, 0.0 = fully invisible.
uniform float alpha_fade : hint_range(0.0, 1.0) = 1.0;

// 4x4 Bayer ordered dithering matrix.
// Produces a screen-door transparency effect that stays in the opaque render
// pass — no depth sorting issues, works correctly with shadows, SSAO, etc.
// At typical game resolutions the pattern is barely noticeable.
float bayer4x4(vec2 screen_pos) {
	ivec2 p = ivec2(screen_pos) % 4;
	int idx = p.x + p.y * 4;
	// Threshold values 0/16 through 15/16
	float thresholds[16] = float[16](
		 0.0,  8.0,  2.0, 10.0,
		12.0,  4.0, 14.0,  6.0,
		 3.0, 11.0,  1.0,  9.0,
		15.0,  7.0, 13.0,  5.0
	);
	return thresholds[idx] / 16.0;
}

void fragment() {
	ALBEDO = albedo_color.rgb;

	// Dithered dissolve: discard pixels whose Bayer threshold exceeds alpha_fade.
	// When alpha_fade == 1.0 no pixels are discarded (fully opaque).
	// When alpha_fade == 0.0 all pixels are discarded (fully invisible).
	float threshold = bayer4x4(FRAGCOORD.xy);
	if (alpha_fade < threshold + 0.001) {
		discard;
	}
}
