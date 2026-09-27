extends Node3D
## Строителната площадка: земя, купчина пясък, камион, багер, камера и HUD.
## Етап 1: гребеш пясък с кофата и го изсипваш в камиона, докато се напълни.

const Excavator := preload("res://scripts/excavator.gd")
const Cam := preload("res://scripts/cam.gd")
const Hud := preload("res://scripts/hud.gd")

@export var truck_goal := 100   ## колко буци пясък пълнят камиона (~5 кофи)
@export var max_sand := 350     ## най-много буци пясък наведнъж (старите извън камиона изчезват)

## Купчините пясък: [център, радиус, височина]
const HEAPS := [
	[Vector3(0, 0, -8.5), 3.6, 1.9],
	[Vector3(2.6, 0, -7.2), 2.2, 1.2],
	[Vector3(-2.5, 0, -9.8), 2.5, 1.35],
]
const TRUCK_POS := Vector3(6.8, 0, -0.4)

const KEYS := {
	"drive_fwd": [KEY_W], "drive_back": [KEY_S], "turn_left": [KEY_A], "turn_right": [KEY_D],
	"swing_left": [KEY_LEFT], "swing_right": [KEY_RIGHT],
	"boom_up": [KEY_UP], "boom_down": [KEY_DOWN],
	"stick_out": [KEY_Q], "stick_in": [KEY_E],
	"bucket_curl": [KEY_Z], "bucket_dump": [KEY_X],
	"camera": [KEY_V], "restart": [KEY_R],
}

var excavator: CharacterBody3D
var cam: Camera3D
var hud: CanvasLayer
var sand_balls: Array[RigidBody3D] = []
var in_truck := {}    ## буци в коша -> кога са влезли (s)
var truck_sand := 0  ## буци, които вече са се слели с пясъка в коша
var done := false

var _sand_mat: StandardMaterial3D
var _ball_mesh: SphereMesh
var _ball_shape: SphereShape3D
var _ball_phys: PhysicsMaterial
var _truck_sand_mesh: MeshInstance3D
var _truck_sand_mound: MeshInstance3D
var _truck_sand_col: CollisionShape3D
var _time := 0.0


func _ready() -> void:
	_setup_input()
	_build_environment()
	_build_ground()
	_build_heaps()
	_build_truck()

	excavator = Excavator.new()
	excavator.heap_height = heap_height_at
	excavator.sand_dropped.connect(_spawn_sand)
	add_child(excavator)

	cam = Cam.new()
	cam.target = excavator
	add_child(cam)
	cam.snap()

	hud = Hud.new()
	add_child(hud)
	hud.set_truck(0, truck_goal)
	hud.show_message("Напълни камиона с пясък!")

	if "--autotest" in OS.get_cmdline_user_args():
		add_child(preload("res://scripts/autotest.gd").new())


func _physics_process(dt: float) -> void:
	_time += dt
	# буците, които са спрели в коша, се сливат с пясъка там (по-красиво и по-леко)
	var merged := false
	for b in in_truck.keys():
		if b.sleeping or _time - in_truck[b] > 2.5:
			in_truck.erase(b)
			sand_balls.erase(b)
			b.queue_free()
			truck_sand += 1
			merged = true
	if merged:
		_update_truck()


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("restart"):
		get_tree().reload_current_scene()
	if Input.is_action_just_pressed("camera"):
		cam.toggle_view()
	hud.set_bucket(excavator.fill)


## Височина на пясъка в точката p (0 = земя).
func heap_height_at(p: Vector3) -> float:
	var h := 0.0
	for heap in HEAPS:
		var d := Vector2(p.x - heap[0].x, p.z - heap[0].z).length()
		if d < heap[1]:
			h = maxf(h, heap[2] * sqrt(1.0 - (d / heap[1]) ** 2))
	return h


func truck_amount() -> int:
	return truck_sand + in_truck.size()


# --- Пясък ---

func _spawn_sand(pos: Vector3, vel: Vector3) -> void:
	var b := RigidBody3D.new()
	b.collision_layer = 8             # слой 4: пясък
	b.collision_mask = 1 | 2 | 4 | 8
	b.mass = 0.4
	b.physics_material_override = _ball_phys
	b.angular_damp = 4.0
	b.linear_damp = 0.2
	var cs := CollisionShape3D.new()
	cs.shape = _ball_shape
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = _ball_mesh
	mi.material_override = _sand_mat
	mi.scale = Vector3(randf_range(0.9, 1.3), randf_range(0.6, 0.9), randf_range(0.9, 1.3))
	b.add_child(mi)
	add_child(b)
	b.global_position = pos
	b.rotation.y = randf() * TAU
	b.linear_velocity = vel
	sand_balls.append(b)
	if sand_balls.size() > max_sand:
		for i in sand_balls.size():
			var old := sand_balls[i]
			if not in_truck.has(old):
				sand_balls.remove_at(i)
				old.queue_free()
				break


func _on_truck_body_entered(body: Node3D) -> void:
	if body is RigidBody3D and not body.is_queued_for_deletion():
		in_truck[body] = _time
		_update_truck()


func _on_truck_body_exited(body: Node3D) -> void:
	if in_truck.erase(body):
		_update_truck()


func _update_truck() -> void:
	hud.set_truck(truck_amount(), truck_goal)
	# пясъкът в коша се надига
	var k := minf(1.0, float(truck_sand) / truck_goal)
	var h := 0.02 + 0.8 * k
	_truck_sand_mesh.scale.y = h
	_truck_sand_mesh.position.y = 1.425 + h / 2.0
	_truck_sand_col.position.y = 1.425 + h - 0.5
	_truck_sand_mound.visible = truck_sand > 0
	_truck_sand_mound.position.y = 1.425 + h
	_truck_sand_mound.scale = Vector3(1.0, 0.3 + 0.7 * k, 1.8)
	if not done and truck_amount() >= truck_goal:
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
	# Панорамна снимка (HDRI) за небе и отражения по боята
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = load("res://env/sky.hdr")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.9
	env.glow_enabled = true
	env.fog_enabled = true
	env.fog_light_color = Color(0.78, 0.76, 0.72)
	env.fog_density = 0.004
	env.fog_sky_affect = 0.0
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	if OS.has_feature("mobile"):
		Engine.max_fps = 60
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		sun.directional_shadow_max_distance = 30.0
	add_child(sun)


func _build_ground() -> void:
	# пясъчна текстура от шум (без файлове)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.03
	noise.fractal_octaves = 5
	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.seamless = true
	tex.width = 512
	tex.height = 512
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.42, 0.33, 0.22))
	ramp.set_color(1, Color(0.62, 0.51, 0.36))
	tex.color_ramp = ramp
	var nor := NoiseTexture2D.new()
	nor.noise = noise
	nor.seamless = true
	nor.width = 512
	nor.height = 512
	nor.as_normal_map = true
	nor.bump_strength = 4.0
	_sand_mat = StandardMaterial3D.new()
	_sand_mat.albedo_texture = tex
	_sand_mat.normal_enabled = true
	_sand_mat.normal_texture = nor
	_sand_mat.roughness = 1.0
	_sand_mat.uv1_triplanar = true
	_sand_mat.uv1_scale = Vector3.ONE * 0.25

	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	cs.shape = box
	cs.position.y = -0.5
	ground.add_child(cs)
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = _sand_mat
	ground.add_child(mi)
	add_child(ground)

	# буците пясък, които падат от кофата
	_ball_mesh = SphereMesh.new()
	_ball_mesh.radius = 0.17
	_ball_mesh.height = 0.34
	_ball_mesh.radial_segments = 8
	_ball_mesh.rings = 4
	_ball_shape = SphereShape3D.new()
	_ball_shape.radius = 0.15
	_ball_phys = PhysicsMaterial.new()
	_ball_phys.friction = 1.0
	_ball_phys.rough = true
	_ball_phys.bounce = 0.0


func _build_heaps() -> void:
	for heap in HEAPS:
		var mesh := SphereMesh.new()
		mesh.radius = heap[1]
		mesh.height = heap[2] * 2.0
		mesh.radial_segments = 48
		mesh.rings = 24
		var body := StaticBody3D.new()
		body.collision_layer = 2
		body.position = heap[0]
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = _sand_mat
		body.add_child(mi)
		var cs := CollisionShape3D.new()
		cs.shape = mesh.create_convex_shape()
		body.add_child(cs)
		add_child(body)


func _build_truck() -> void:
	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color(0.12, 0.28, 0.62)
	paint.roughness = 0.3
	paint.clearcoat_enabled = true
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.3, 0.31, 0.32)
	steel.metallic = 0.7
	steel.roughness = 0.55
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.06, 0.06, 0.06)
	dark.roughness = 0.8
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.04, 0.06, 0.07)
	glass.metallic = 0.6
	glass.roughness = 0.04

	var truck := StaticBody3D.new()
	truck.collision_layer = 2
	truck.position = TRUCK_POS
	add_child(truck)
	# [размер, позиция, материал, има ли сблъсък]
	for part in [
		[Vector3(1.3, 0.4, 7.4), Vector3(0, 0.85, -0.6), dark, true],       # рама
		[Vector3(2.5, 2.1, 1.9), Vector3(0, 2.1, -3.35), paint, true],      # кабина
		[Vector3(2.3, 0.9, 0.05), Vector3(0, 2.55, -4.31), glass, false],   # предно стъкло
		[Vector3(2.52, 0.7, 1.2), Vector3(0, 2.55, -3.5), glass, false],    # странични стъкла
		[Vector3(2.5, 0.15, 4.6), Vector3(0, 1.35, 0.0), steel, true],      # под на коша
		[Vector3(0.12, 1.0, 4.6), Vector3(-1.19, 1.92, 0.0), steel, true],  # стени на коша
		[Vector3(0.12, 1.0, 4.6), Vector3(1.19, 1.92, 0.0), steel, true],
		[Vector3(2.5, 1.4, 0.12), Vector3(0, 2.12, -2.24), steel, true],
		[Vector3(2.5, 1.0, 0.12), Vector3(0, 1.92, 2.24), steel, true],
		[Vector3(2.6, 0.3, 0.3), Vector3(0, 0.75, -4.3), dark, false],      # броня
	]:
		var mesh := BoxMesh.new()
		mesh.size = part[0]
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = part[2]
		mi.position = part[1]
		truck.add_child(mi)
		if part[3]:
			var cs := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = part[0]
			cs.shape = box
			cs.position = part[1]
			truck.add_child(cs)
	for z in [-3.3, 0.4, 1.7]:
		for x in [-1.05, 1.05]:
			var wheel := CylinderMesh.new()
			wheel.top_radius = 0.52
			wheel.bottom_radius = 0.52
			wheel.height = 0.4
			var mi := MeshInstance3D.new()
			mi.mesh = wheel
			mi.material_override = dark
			mi.position = Vector3(x, 0.52, z)
			mi.rotation.z = PI / 2
			truck.add_child(mi)

	# пясъкът в коша (надига се, докато се пълни)
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(2.26, 1.0, 4.36)
	_truck_sand_mesh = MeshInstance3D.new()
	_truck_sand_mesh.mesh = box_mesh
	_truck_sand_mesh.material_override = _sand_mat
	_truck_sand_mesh.scale.y = 0.02
	_truck_sand_mesh.position.y = 1.435
	truck.add_child(_truck_sand_mesh)
	var mound := SphereMesh.new()
	mound.radius = 1.1
	mound.height = 0.7
	_truck_sand_mound = MeshInstance3D.new()
	_truck_sand_mound.mesh = mound
	_truck_sand_mound.material_override = _sand_mat
	_truck_sand_mound.visible = false
	truck.add_child(_truck_sand_mound)
	_truck_sand_col = CollisionShape3D.new()
	var sand_box := BoxShape3D.new()
	sand_box.size = Vector3(2.26, 1.0, 4.36)
	_truck_sand_col.shape = sand_box
	_truck_sand_col.position.y = 1.425 - 0.5
	truck.add_child(_truck_sand_col)

	# брои буците пясък в коша
	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = 8
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.26, 1.6, 4.36)
	cs.shape = box
	cs.position = Vector3(0, 2.2, 0.0)
	area.add_child(cs)
	area.body_entered.connect(_on_truck_body_entered)
	area.body_exited.connect(_on_truck_body_exited)
	truck.add_child(area)
