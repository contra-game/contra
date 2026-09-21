shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform vec4 rim_color : source_color = vec4(0.32, 0.30, 0.27, 1.0);
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float angle = atan(p.y, p.x);
	float edge = 0.74 + sin(angle * 11.0) * 0.06 + sin(angle * 19.0) * 0.03;
	float radius = length(p);
	if (radius > edge) { discard; }
	float hole = smoothstep(0.28, 0.46, radius);
	float cracks = step(0.94, sin(angle * 13.0 + radius * 5.0));
	ALBEDO = mix(vec3(0.014, 0.012, 0.01), rim_color.rgb, hole) * (1.0 - cracks * 0.6);
	ALPHA = (1.0 - smoothstep(edge - 0.1, edge, radius)) * 0.94;
}
