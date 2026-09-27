extends Node3D
## Строителната площадка: земя, която се копае (с купчини пръст), самосвал, багер, камера и HUD.
## Етап 1: гребеш пръст с кофата и я изсипваш в камиона, докато се напълни.
## Изсипаната пръст пада на буци (свои, без физика) и там, където падне, става част от земята или от товара.

const Excavator := preload("res://scripts/excavator.gd")
const Truck := preload("res://scripts/truck.gd")
const Terrain := preload("res://scripts/terrain.gd")
const Site := preload("res://scripts/site.gd")
const Cam := preload("res://scripts/cam.gd")
const Hud := preload("res://scripts/hud.gd")

@export var truck_goal := 3.6   ## м³ пръст, за да е пълен камионът (~6 кофи)

## Купчините пръст: [център, радиус, височина]
const HEAPS := [
	[Vector3(0, 0, -8.8), 4.2, 2.0],
	[Vector3(2.9, 0, -7.4), 2.6, 1.2],
	[Vector3(-2.9, 0, -10.2), 3.0, 1.4],
]
const TERRAIN_CENTER := Vector3(0, 0, -4)
const TRUCK_POS := Vector3(6.8, 0, -0.4)
const MAX_CLUMPS := 700
const MAX_DUST := 160

const KEYS := {
	"drive_fwd": [KEY_W], "drive_back": [KEY_S], "turn_left": [KEY_A], "turn_right": [KEY_D],
	"swing_left": [KEY_LEFT], "swing_right": [KEY_RIGHT],
	"boom_up": [KEY_UP], "boom_down": [KEY_DOWN],
	"stick_out": [KEY_Q], "stick_in": [KEY_E],
	"bucket_curl": [KEY_Z], "bucket_dump": [KEY_X],
	"camera": [KEY_V], "restart": [KEY_R],
}

var terrain: Node3D
var truck: StaticBody3D
var excavator: CharacterBody3D
var cam: Camera3D
var hud: CanvasLayer
var done := false

var _soil_mat: ShaderMaterial
var _noise := FastNoiseLite.new()
var _clumps: Array = []          ## [позиция, скорост, обем, завъртане]
var _clump_mm: MultiMesh
var _dust: Array = []            ## [позиция, скорост, възраст, живот, размер]
var _dust_mm: MultiMesh
var _dust_timer := 0.0
var _last_fill := 0.0


func _ready() -> void:
	_setup_input()
	_build_environment()
	_build_ground()
	_build_hills()

	truck = Truck.new()
	truck.soil_material = _soil_mat
	add_child(truck)
	truck.position = TRUCK_POS

	var site := Site.new()
	site.ground = terrain.height_at
	add_child(site)
	site.build(Rect2(-22, -26, 44, 44), TRUCK_POS.x, 9.0)

	excavator = Excavator.new()
	excavator.terrain = terrain
	excavator.soil_dropped.connect(_spawn_clump)
	add_child(excavator)
	_build_particles()

	cam = Cam.new()
	cam.target = excavator
	cam.ground = terrain.height_at
	add_child(cam)
	cam.snap()

	hud = Hud.new()
	add_child(hud)
	hud.set_truck(0.0)
	hud.show_message("Напълни камиона с пръст!")

	if "--autotest" in OS.get_cmdline_user_args():
		add_child(preload("res://scripts/autotest.gd").new())


func _physics_process(dt: float) -> void:
	_update_clumps(dt)
	_update_dust(dt)
	# прах, докато кофата копае
	_dust_timer -= dt
	if excavator.fill > _last_fill + 0.001 and _dust_timer <= 0.0:
		_spawn_dust(excavator.tip.global_position + Vector3(0, 0.2, 0), 0.8, Color(0.55, 0.47, 0.37, 0.5))
		_dust_timer = 0.12
	elif excavator.fill < _last_fill - 0.001 and _dust_timer <= 0.0:   # изсипва
		_spawn_dust(excavator.tip.global_position - Vector3(0, 0.3, 0), 0.9, Color(0.58, 0.5, 0.4, 0.4))
		_dust_timer = 0.15
	_last_fill = excavator.fill
	# прах зад веригите
	if excavator.get_real_velocity().length() > 0.8 and randf() < dt * 6.0:
		var back: Vector3 = excavator.global_basis.z * 1.9
		var side: Vector3 = excavator.global_basis.x * (1.0 if randf() < 0.5 else -1.0)
		_spawn_dust(excavator.global_position + back + side + Vector3(0, 0.2, 0), 1.0, Color(0.6, 0.52, 0.42, 0.35))


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("restart"):
		get_tree().reload_current_scene()
	if Input.is_action_just_pressed("camera"):
		cam.toggle_view()
	hud.set_bucket(excavator.fill)


func truck_amount() -> float:
	return truck.load_volume()


# --- Буци пръст (падат от кофата) ---

func _spawn_clump(pos: Vector3, vel: Vector3, volume: float) -> void:
	if _clumps.size() >= MAX_CLUMPS:
		return
	var rot := Basis.from_euler(Vector3(randf() * TAU, randf() * TAU, randf() * TAU))
	var s := pow(volume / 0.008, 1.0 / 3.0) * randf_range(0.7, 1.3)
	_clumps.append([pos, vel, volume, rot.scaled(Vector3(s, s * randf_range(0.6, 0.9), s))])


func _update_clumps(dt: float) -> void:
	var landed := 0
	var i := 0
	while i < _clumps.size():
		var c: Array = _clumps[i]
		c[1].y -= 9.8 * dt
		c[0] += c[1] * dt
		var p: Vector3 = c[0]
		var bed: float = truck.bed_height(p)
		var hit := false
		if not is_nan(bed):
			if p.y <= bed:
				truck.deposit(p, c[2])
				hit = true
		else:
			var top: float = truck.solid_top(p)
			if not is_nan(top) and p.y <= top and p.y > top - 0.6:
				hit = true   # падна върху кабината или ръба; търкулва се встрани (губи се)
			elif p.y <= terrain.height_at(p):
				terrain.deposit(p, c[2], 0.3)
				hit = true
		if hit:
			if landed % 5 == 0:
				_spawn_dust(p + Vector3(0, 0.15, 0), 0.7, Color(0.55, 0.47, 0.37, 0.45))
			landed += 1
			_clumps.remove_at(i)
		else:
			i += 1
	var n := _clumps.size()
	for k in n:
		_clump_mm.set_instance_transform(k, Transform3D(_clumps[k][3], _clumps[k][0]))
	_clump_mm.visible_instance_count = n
	if landed > 0:
		_update_truck()


# --- Прах ---

func _spawn_dust(pos: Vector3, size: float, color: Color) -> void:
	if _dust.size() >= MAX_DUST:
		_dust.remove_at(0)
	var vel := Vector3(randf_range(-0.3, 0.3), randf_range(0.2, 0.5), randf_range(-0.3, 0.3))
	_dust.append([pos, vel, 0.0, randf_range(1.8, 3.0), size, color])


func _update_dust(dt: float) -> void:
	var i := 0
	while i < _dust.size():
		var d: Array = _dust[i]
		d[2] += dt
		if d[2] >= d[3]:
			_dust.remove_at(i)
			continue
		d[0] += d[1] * dt
		d[1] *= 1.0 - 0.8 * dt
		i += 1
	for k in _dust.size():
		var d: Array = _dust[k]
		var t: float = d[2] / d[3]
		var s: float = d[4] * (0.6 + t * 1.6)
		_dust_mm.set_instance_transform(k, Transform3D(Basis.from_scale(Vector3.ONE * s), d[0]))
		var col: Color = d[5]
		col.a *= (1.0 - t) * minf(1.0, t * 6.0)
		_dust_mm.set_instance_color(k, col)
	_dust_mm.visible_instance_count = _dust.size()


func _build_particles() -> void:
	var rock := SphereMesh.new()
	rock.radius = 0.1
	rock.height = 0.2
	rock.radial_segments = 7
	rock.rings = 4
	_clump_mm = MultiMesh.new()
	_clump_mm.transform_format = MultiMesh.TRANSFORM_3D
	_clump_mm.mesh = rock
	_clump_mm.instance_count = MAX_CLUMPS
	_clump_mm.visible_instance_count = 0
	_clump_mm.custom_aabb = AABB(Vector3(-60, -10, -60), Vector3(120, 40, 120))   # иначе се скрива, когато е празен
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _clump_mm
	mmi.material_override = excavator.m_soil
	mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	mmi.extra_cull_margin = 200.0
	add_child(mmi)

	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 64
	tex.height = 64
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	_dust_mm = MultiMesh.new()
	_dust_mm.transform_format = MultiMesh.TRANSFORM_3D
	_dust_mm.use_colors = true
	_dust_mm.mesh = quad
	_dust_mm.instance_count = MAX_DUST
	_dust_mm.visible_instance_count = 0
	_dust_mm.custom_aabb = AABB(Vector3(-60, -10, -60), Vector3(120, 40, 120))
	var dmi := MultiMeshInstance3D.new()
	dmi.multimesh = _dust_mm
	dmi.material_override = mat
	dmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	dmi.extra_cull_margin = 200.0
	dmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(dmi)


func _update_truck() -> void:
	var v := truck_amount()
	hud.set_truck(v / truck_goal)
	if not done and v >= truck_goal:
		done = true
		hud.show_message("Браво! Камионът е пълен.\nR: отначало", true)


# --- Свят ---

func _setup_input() -> void:
	for action in KEYS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in KEYS[action]:
			var e := InputEventKey.new()
			e.physical_keycode = key
			InputMap.action_add_event(action, e)


func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.26, 0.45, 0.78)
	sky_mat.sky_horizon_color = Color(0.68, 0.76, 0.86)
	sky_mat.ground_horizon_color = Color(0.62, 0.62, 0.6)
	sky_mat.ground_bottom_color = Color(0.3, 0.27, 0.23)
	sky_mat.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.4
	env.fog_enabled = true
	env.fog_light_color = Color(0.7, 0.75, 0.82)
	env.fog_density = 0.0018
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.05
	env.adjustment_contrast = 1.05
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 38, 0)
	sun.light_energy = 1.6
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.shadow_enabled = true
	sun.shadow_blur = 1.5
	sun.directional_shadow_max_distance = 60.0
	if OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios"):
		Engine.max_fps = 60
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		sun.directional_shadow_max_distance = 30.0
	add_child(sun)


## Височина на земята в началото: леки неравности и купчини пръст; равно под камиона и багера.
func _start_height(p: Vector3) -> float:
	var h := _noise.get_noise_2d(p.x, p.z) * 0.12 + _noise.get_noise_2d(p.x * 4.0, p.z * 4.0) * 0.03
	var flat := 1.0
	flat *= smoothstep(4.0, 6.0, Vector2(p.x, p.z).length())                       # под багера
	var tl := p - TRUCK_POS
	flat *= smoothstep(0.5, 2.0, maxf(absf(tl.x) - 1.3, maxf(-tl.z - 4.4, tl.z - 3.1)))   # под камиона
	var l := p - TERRAIN_CENTER
	flat *= smoothstep(0.0, 2.0, 24.0 - maxf(absf(l.x), absf(l.z)) - 0.5)            # към ръба
	h *= flat
	for heap in HEAPS:
		var d: float = Vector2(p.x - heap[0].x, p.z - heap[0].z).length() / heap[1]
		if d < 1.0:
			var bump := _noise.get_noise_2d(p.x * 2.5 + 40.0, p.z * 2.5) * 0.12
			h = maxf(h, heap[2] * (1.0 - smoothstep(0.0, 1.0, d)) + bump * (1.0 - d))
	return h


func _build_ground() -> void:
	_noise.seed = 3
	_noise.frequency = 0.05
	var macro := NoiseTexture2D.new()
	var mn := FastNoiseLite.new()
	mn.frequency = 0.01
	mn.fractal_octaves = 4
	macro.noise = mn
	macro.seamless = true
	macro.width = 256
	macro.height = 256
	_soil_mat = ShaderMaterial.new()
	_soil_mat.shader = preload("res://shaders/terrain.gdshader")
	_soil_mat.set_shader_parameter("soil_albedo", load("res://textures/soil_diff.jpg"))
	_soil_mat.set_shader_parameter("soil_normal", load("res://textures/soil_nor.jpg"))
	_soil_mat.set_shader_parameter("soil_rough", load("res://textures/soil_rough.jpg"))
	_soil_mat.set_shader_parameter("dirt_albedo", load("res://textures/dirt_diff.jpg"))
	_soil_mat.set_shader_parameter("dirt_normal", load("res://textures/dirt_nor.jpg"))
	_soil_mat.set_shader_parameter("macro", macro)

	terrain = Terrain.new()
	terrain.cells_x = 192
	terrain.cells_z = 192
	terrain.cell = 0.25
	terrain.material = _soil_mat
	terrain.position = TERRAIN_CENTER
	add_child(terrain)
	terrain.setup(_start_height)

	# равна земя около площадката (с дупка за земята, която се копае)
	var half := 24.0
	var big := 300.0
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	add_child(ground)
	for r in [Rect2(-big, -big, big * 2, big - half), Rect2(-big, half, big * 2, big - half),
			Rect2(-big, -half, big - half, half * 2), Rect2(half, -half, big - half, half * 2)]:
		var center := Vector3(r.get_center().x, 0, r.get_center().y) + TERRAIN_CENTER
		var plane := PlaneMesh.new()
		plane.size = r.size
		var mi := MeshInstance3D.new()
		mi.mesh = plane
		mi.material_override = _soil_mat
		mi.position = center
		ground.add_child(mi)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(r.size.x, 1, r.size.y)
		cs.shape = box
		cs.position = center - Vector3(0, 0.5, 0)
		ground.add_child(cs)


## Хълмове в далечината (само картина).
func _build_hills() -> void:
	var n := FastNoiseLite.new()
	n.seed = 11
	n.frequency = 0.012
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 96
	var rings := [80.0, 110.0, 150.0, 200.0, 260.0]
	var pts := []
	for ri in rings.size():
		var row := []
		for s in seg:
			var a := TAU * s / seg
			var r: float = rings[ri]
			var p := Vector3(cos(a) * r, 0, sin(a) * r)
			var t := float(ri) / (rings.size() - 1)
			p.y = (0.0 if ri == 0 else (n.get_noise_2d(p.x, p.z) * 0.5 + 0.6) * 40.0 * t) - 0.3
			row.append(p)
		pts.append(row)
	for ri in rings.size() - 1:
		for s in seg:
			var s2 := (s + 1) % seg
			var q: Array = [pts[ri][s], pts[ri][s2], pts[ri + 1][s2], pts[ri + 1][s]]
			for tri in [[0, 2, 1], [0, 3, 2]]:
				for k in tri:
					st.set_uv(Vector2(q[k].x, q[k].z) * 0.05)
					st.add_vertex(q[k])
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.44, 0.3)
	mat.albedo_texture = load("res://textures/soil_diff.jpg")
	mat.roughness = 1.0
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
