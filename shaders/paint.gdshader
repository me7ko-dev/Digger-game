// Боя и метал с мръсотия: петна от шум (в координатите на детайла, за да не „плуват“),
// прах по горните повърхности и изтъркан метал (за кофата и зъбите).
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 color : source_color = vec4(0.95, 0.66, 0.07, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.35;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float grime : hint_range(0.0, 1.0) = 0.3;   // петна мръсотия
uniform float dust : hint_range(0.0, 1.0) = 0.5;    // прах по хоризонталните повърхности
uniform float wear : hint_range(0.0, 1.0) = 0.0;    // изтъркана боя до метал
uniform float scale = 1.0;
uniform vec4 dirt_color : source_color = vec4(0.40, 0.32, 0.23, 1.0);
uniform sampler2D grime_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

varying vec3 lpos;
varying vec3 lnorm;
varying vec3 wnorm;

void vertex() {
	lpos = VERTEX * scale;
	lnorm = NORMAL;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float tri(vec3 p, vec3 n, float s) {
	vec3 b = pow(abs(n), vec3(4.0));
	b /= (b.x + b.y + b.z);
	return texture(grime_tex, p.zy * s).r * b.x + texture(grime_tex, p.xz * s).r * b.y + texture(grime_tex, p.xy * s).r * b.z;
}

void fragment() {
	float g1 = tri(lpos, lnorm, 0.35);
	float g2 = tri(lpos + 7.3, lnorm, 1.9);
	float up = clamp(normalize(wnorm).y, 0.0, 1.0);
	float dust_m = smoothstep(0.4, 0.95, up) * dust * smoothstep(0.25, 0.75, g1 * 0.7 + g2 * 0.3);
	float grime_m = grime * smoothstep(0.5, 0.85, g1 * 0.55 + g2 * 0.45);
	vec3 col = color.rgb;
	float rough = roughness;
	float metal = metallic;
	float w = wear * smoothstep(0.5, 0.75, g2);
	col = mix(col, vec3(0.5, 0.5, 0.52), w);
	metal = mix(metal, 0.9, w);
	rough = mix(rough, 0.4, w);
	float d = clamp(grime_m + dust_m, 0.0, 0.9);
	col = mix(col, dirt_color.rgb * mix(0.75, 1.15, g2), d);
	ALBEDO = col;
	ROUGHNESS = mix(rough, 0.95, d);
	METALLIC = mix(metal, 0.0, d);
}
