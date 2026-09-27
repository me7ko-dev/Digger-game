// Земя: суха почва отгоре, тъмна изкопана пръст там, където е копано или сипано (COLOR.r = 0),
// и по стръмните места. Текстурите се повтарят по света; голям шум разчупва повторението.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D soil_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_rough : hint_roughness_r, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D macro : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float tile = 0.35;        // повторения на метър
uniform float dirt_tile = 0.5;

varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

void fragment() {
	vec2 uv = wpos.xz * tile;
	vec2 uv_d = wpos.xz * dirt_tile + vec2(0.37, 0.61);
	float m = texture(macro, wpos.xz * 0.013).r;
	float m2 = texture(macro, wpos.xz * 0.05 + 0.5).r;
	float slope = 1.0 - clamp(normalize(wnorm).y, 0.0, 1.0);
	float d = clamp(1.0 - COLOR.r + smoothstep(0.25, 0.5, slope) * 0.6, 0.0, 1.0);
	vec3 soil = texture(soil_albedo, uv).rgb * mix(0.78, 1.15, m) * mix(0.9, 1.05, m2);
	vec3 dirt = texture(dirt_albedo, uv_d).rgb * mix(0.85, 1.1, m2);
	ALBEDO = mix(soil, dirt, d);
	NORMAL_MAP = mix(texture(soil_normal, uv).rgb, texture(dirt_normal, uv_d).rgb, d);
	NORMAL_MAP_DEPTH = 1.2;
	ROUGHNESS = mix(texture(soil_rough, uv).r, 0.88, d);
}
