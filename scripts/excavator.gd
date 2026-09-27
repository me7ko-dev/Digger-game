extends CharacterBody3D
## Багерът: вериги (кара се като танк), кабина, която се върти, стрела, рамо и кофа.
## Предницата на веригите е към -Z. Моделът е направен от прости форми в _build().
## Кофата се пълни, когато върхът ѝ е в пясъка и я свиваш; изсипва се, когато отворът ѝ гледа надолу.

signal sand_dropped(pos: Vector3, vel: Vector3)

@export var drive_speed := 2.5    ## м/с
@export var turn_speed := 0.6     ## рад/с (завой на място)
@export var swing_speed := 0.8    ## въртене на кабината, рад/с
@export var boom_speed := 0.5
@export var stick_speed := 0.7
@export var bucket_speed := 1.1
@export var joint_accel := 3.0    ## колко бързо тръгват и спират ставите (1/с)
@export var scoop_length := 0.5   ## колко метра гребане в пясъка пълнят кофата
@export var balls_per_bucket := 22

const BOOM_MIN := -0.55
const BOOM_MAX := 1.05
const STICK_MIN := -2.6
const STICK_MAX := -0.45
const BUCKET_MIN := -2.3
const BUCKET_MAX := 0.8
const GROUND_LIMIT := -0.15  ## колко може кофата да влезе под земята

## (Vector3) -> височина на пясъка под точката; задава се от main.gd
var heap_height: Callable
## Автотест: целеви ъгли на ставите ("swing", "boom", "stick", "bucket") и "drive"/"turn" (-1..1)
var auto := {}
## Колко е пълна кофата (0..1)
var fill := 0.0

var turret: Node3D
var boom: Node3D
var stick: Node3D
var bucket: Node3D
var tip: Node3D
var _check_points: Array[Node3D] = []
var _mouth: Node3D
var _sand: MeshInstance3D
var _mound: MeshInstance3D
var _rams := []
var _jv := {"drive": 0.0, "turn": 0.0, "swing": 0.0, "boom": 0.0, "stick": 0.0, "bucket": 0.0}
var _drop_acc := 0.0
var _last_tip := Vector3.ZERO

var _paint: StandardMaterial3D
var _dark: StandardMaterial3D
var _steel: StandardMaterial3D
var _chrome: StandardMaterial3D
var _glass: StandardMaterial3D


func _ready() -> void:
	collision_layer = 4          # слой 3: багер
	collision_mask = 1 | 2       # земя и препятствия (пясъкът не го спира)
	floor_max_angle = deg_to_rad(40)
	_build()
	_update_rams()
	_last_tip = tip.global_position


func _physics_process(dt: float) -> void:
	# --- Вериги ---
	var drive := _smooth("drive", _control("drive", "drive_back", "drive_fwd"), 1.0, dt)
	var turn := _smooth("turn", _control("turn", "turn_right", "turn_left"), 1.0, dt)
	rotation.y += turn * turn_speed * dt
	var fwd := -global_basis.z
	velocity.x = fwd.x * drive * drive_speed
	velocity.z = fwd.z * drive * drive_speed
	velocity.y = -1.0 if is_on_floor() else velocity.y - 9.8 * dt
	move_and_slide()

	# --- Кабина и ръка ---
	var swing_in := _control("swing", "swing_right", "swing_left")
	turret.rotation.y = wrapf(turret.rotation.y + _smooth("swing", swing_in, swing_speed, dt) * dt, -PI, PI)
	var boom_in := _control("boom", "boom_down", "boom_up")
	_move_joint(boom, "boom", boom_in, boom_speed, BOOM_MIN, BOOM_MAX, dt)
	var stick_in := _control("stick", "stick_in", "stick_out")
	_move_joint(stick, "stick", stick_in, stick_speed, STICK_MIN, STICK_MAX, dt)
	var bucket_in := _control("bucket", "bucket_curl", "bucket_dump")
	_move_joint(bucket, "bucket", bucket_in, bucket_speed, BUCKET_MIN, BUCKET_MAX, dt)

	_dig()
	_pour(dt)
	_update_rams()


## Колко нагоре гледа отворът на кофата: 1 = право нагоре (държи пясък), -1 = надолу.
func bucket_opening_up() -> float:
	return (-bucket.global_basis.y).normalized().y


func get_speed() -> float:
	return absf(_jv.drive) * drive_speed


# --- Управление ---

func _control(joint: String, neg: String, pos: String) -> float:
	if auto.has(joint):
		match joint:
			"drive", "turn":
				return auto[joint]
			"swing":
				return clampf(angle_difference(turret.rotation.y, auto.swing) * 3.0, -1.0, 1.0)
			_:
				var node: Node3D = {"boom": boom, "stick": stick, "bucket": bucket}[joint]
				return clampf((auto[joint] - node.rotation.x) * 4.0, -1.0, 1.0)
	return Input.get_axis(neg, pos)


## Плавно тръгване и спиране: връща текущата скорост на ставата.
func _smooth(joint: String, input: float, max_speed: float, dt: float) -> float:
	_jv[joint] = move_toward(_jv[joint], input * max_speed, max_speed * joint_accel * dt)
	return _jv[joint]


func _move_joint(node: Node3D, joint: String, input: float, max_speed: float, lo: float, hi: float, dt: float) -> void:
	var target := node.rotation.x + _smooth(joint, input, max_speed, dt) * dt
	var clamped := clampf(target, lo, hi)
	if clamped != target:
		_jv[joint] = 0.0
	node.rotation.x = clamped
	_keep_above_ground()


## Кофата не минава през земята: ако опре, стрелата се повдига малко и кофата се плъзга по земята.
func _keep_above_ground() -> void:
	var tries := 0
	while _lowest_point() < GROUND_LIMIT and boom.rotation.x < BOOM_MAX and tries < 40:
		boom.rotation.x = minf(boom.rotation.x + 0.004, BOOM_MAX)
		tries += 1
	if tries > 0 and _jv.boom < 0.0:
		_jv.boom = 0.0


func _lowest_point() -> float:
	var y := INF
	for p in _check_points:
		y = minf(y, p.global_position.y)
	return y


# --- Пясък ---

func _dig() -> void:
	var t := tip.global_position
	var moved := t - _last_tip
	_last_tip = t
	if fill >= 1.0 or not heap_height.is_valid():
		return
	# пълни се, когато върхът е в пясъка и се движи към отвора на кофата (гребе);
	# ако отворът гледа надолу, пясъкът не остава в кофата
	if t.y < heap_height.call(t) - 0.05 and bucket_opening_up() > 0.0:
		var scoop := moved.dot((-bucket.global_basis.y).normalized())
		if scoop > 0.0:
			fill = minf(1.0, fill + scoop / scoop_length)
			_update_sand_look()


func _pour(dt: float) -> void:
	var up := bucket_opening_up()
	if fill <= 0.0 or up > 0.0:
		return
	# колкото по-обърната е кофата, толкова по-бързо пада пясъкът
	var rate := lerpf(0.5, 2.0, clampf(-up / 0.8, 0.0, 1.0))
	var amount := minf(fill, rate * dt)
	fill -= amount
	_drop_acc += amount * balls_per_bucket
	while _drop_acc >= 1.0:
		_drop_acc -= 1.0
		var p := _mouth.global_position
		p += bucket.global_basis.x * randf_range(-0.35, 0.35) + bucket.global_basis.z * randf_range(-0.3, 0.3)
		sand_dropped.emit(p, Vector3(randf_range(-0.3, 0.3), -0.5, randf_range(-0.3, 0.3)))
	if fill <= 0.001:
		fill = 0.0
		_drop_acc = 0.0
	_update_sand_look()


func _update_sand_look() -> void:
	_sand.visible = fill > 0.01
	_sand.scale.y = maxf(fill, 0.01)
	_sand.position.y = -0.275 * fill
	_mound.visible = fill > 0.6
	_mound.position.y = -0.55 * fill
	_mound.scale = Vector3.ONE * clampf((fill - 0.6) / 0.4, 0.2, 1.0)


# --- Модел ---

func _build() -> void:
	_paint = _mat(Color(0.95, 0.66, 0.07), 0.0, 0.38)
	_paint.clearcoat_enabled = true
	_paint.clearcoat = 0.5
	_dark = _mat(Color(0.07, 0.07, 0.075), 0.0, 0.75)
	_steel = _mat(Color(0.32, 0.33, 0.35), 0.8, 0.45)
	_chrome = _mat(Color(0.92, 0.92, 0.94), 1.0, 0.12)
	_glass = _mat(Color(0.04, 0.06, 0.07), 0.6, 0.04)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.6, 0.9, 3.6)
	col.shape = box
	col.position = Vector3(0, 0.5, 0)
	add_child(col)
	var col2 := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 1.45
	cyl.height = 1.6
	col2.shape = cyl
	col2.position = Vector3(0, 1.85, 0.2)
	add_child(col2)

	# Долна част: вериги
	for s in [-1.0, 1.0]:
		var x: float = s * 1.0
		_box(self, Vector3(0.55, 0.8, 2.8), Vector3(x, 0.4, 0), _dark)
		for z in [-1.4, 1.4]:
			_cyl(self, 0.4, 0.55, Vector3(x, 0.4, z), _dark, Vector3(0, 0, PI / 2))
			_cyl(self, 0.26, 0.6, Vector3(x, 0.4, z), _steel, Vector3(0, 0, PI / 2))
		for i in 13:  # грайфери отгоре
			_box(self, Vector3(0.57, 0.05, 0.08), Vector3(x, 0.81, -1.2 + i * 0.2), _dark)
		for i in 4:  # ролки отстрани
			_cyl(self, 0.13, 0.57, Vector3(x, 0.22, -0.75 + i * 0.5), _steel, Vector3(0, 0, PI / 2))
		_box(self, Vector3(0.1, 0.35, 2.4), Vector3(x + s * 0.26, 0.45, 0), _paint)  # рама на веригата
	_box(self, Vector3(1.5, 0.45, 2.2), Vector3(0, 0.6, 0), _steel)
	_cyl(self, 0.95, 0.2, Vector3(0, 0.95, 0), _steel)

	# Горна част: кабина, двигател, противотежест
	turret = Node3D.new()
	turret.position = Vector3(0, 1.05, 0)
	add_child(turret)
	_box(turret, Vector3(2.5, 0.3, 3.4), Vector3(0, 0.15, 0.2), _steel)
	_box(turret, Vector3(2.5, 0.9, 1.5), Vector3(0, 0.75, 1.0), _paint)       # капак на двигателя
	_box(turret, Vector3(2.5, 1.0, 0.5), Vector3(0, 0.7, 1.95), _paint)       # противотежест
	_box(turret, Vector3(2.4, 0.06, 1.4), Vector3(0, 1.22, 1.0), _dark)       # решетка отгоре
	_box(turret, Vector3(0.9, 0.7, 1.3), Vector3(0.8, 0.65, -0.5), _paint)    # кутия за инструменти
	_cyl(turret, 0.06, 0.55, Vector3(0.9, 1.45, 0.8), _dark)                  # ауспух
	# кабина
	_box(turret, Vector3(0.95, 1.45, 1.5), Vector3(-0.75, 1.05, -0.6), _glass)
	_box(turret, Vector3(1.05, 0.1, 1.62), Vector3(-0.75, 1.8, -0.6), _paint)
	_box(turret, Vector3(1.0, 0.25, 1.55), Vector3(-0.75, 0.42, -0.6), _paint)
	for px in [-0.27, -1.23]:
		for pz in [0.15, -1.35]:
			_box(turret, Vector3(0.08, 1.45, 0.08), Vector3(px, 1.05, pz), _dark)
	_box(turret, Vector3(0.5, 0.6, 0.5), Vector3(0.05, 0.75, -1.1), _dark)     # основа на стрелата

	# Стрела (извита)
	boom = Node3D.new()
	boom.position = Vector3(0.05, 1.0, -1.25)
	boom.rotation.x = 0.35
	turret.add_child(boom)
	var bend := Vector3(0, 0.95, -2.5)
	var boom_end := Vector3(0, 0, -4.6)
	_beam(boom, Vector3.ZERO, bend, 0.45, 0.55, _paint)
	_beam(boom, bend, boom_end, 0.42, 0.5, _paint)
	_cyl(boom, 0.34, 0.47, bend, _paint, Vector3(0, 0, PI / 2))
	_cyl(boom, 0.16, 0.62, Vector3.ZERO, _steel, Vector3(0, 0, PI / 2))
	_cyl(boom, 0.16, 0.55, boom_end, _steel, Vector3(0, 0, PI / 2))

	# Рамо
	stick = Node3D.new()
	stick.position = boom_end
	stick.rotation.x = -1.6
	boom.add_child(stick)
	var stick_tail := Vector3(0, 0.35, 0.55)
	var stick_end := Vector3(0, 0, -2.6)
	_beam(stick, stick_tail, stick_end, 0.36, 0.45, _paint)
	_cyl(stick, 0.14, 0.5, stick_end, _steel, Vector3(0, 0, PI / 2))

	# Кофа: отворът е към -Y, зъбите са в края към -Z
	bucket = Node3D.new()
	bucket.position = stick_end
	bucket.rotation.x = -0.6
	stick.add_child(bucket)
	_box(bucket, Vector3(1.0, 0.06, 1.0), Vector3(0, 0, -0.5), _dark)          # дъно
	_box(bucket, Vector3(1.0, 0.6, 0.06), Vector3(0, -0.3, 0), _dark)          # задна стена
	_box(bucket, Vector3(1.0, 0.6, 0.06), Vector3(0, -0.3, -1.0), _dark)       # предна стена
	for sx in [-0.5, 0.5]:
		_box(bucket, Vector3(0.06, 0.6, 1.06), Vector3(sx, -0.3, -0.5), _dark)
	for sx in [-0.16, 0.16]:
		_box(bucket, Vector3(0.06, 0.3, 0.45), Vector3(sx, 0.14, -0.12), _dark)  # уши към рамото
	for i in 5:
		_box(bucket, Vector3(0.08, 0.16, 0.1), Vector3(-0.4 + i * 0.2, -0.66, -1.0), _steel)
	var sand_mat := _mat(Color(0.74, 0.6, 0.4), 0.0, 1.0)
	_sand = _box(bucket, Vector3(0.92, 0.55, 0.92), Vector3(0, 0, -0.5), sand_mat)
	var mound_mesh := SphereMesh.new()
	mound_mesh.radius = 0.46
	mound_mesh.height = 0.4
	_mound = MeshInstance3D.new()
	_mound.mesh = mound_mesh
	_mound.material_override = sand_mat
	_mound.position = Vector3(0, -0.55, -0.5)
	bucket.add_child(_mound)
	tip = _marker(bucket, Vector3(0, -0.66, -1.0))
	_mouth = _marker(bucket, Vector3(0, -0.4, -0.5))
	_check_points = [tip, _marker(bucket, Vector3(0, 0, -1.0)), _marker(bucket, Vector3(0, -0.6, 0)), bucket]
	_update_sand_look()

	# Хидравлични цилиндри
	for sx in [-0.3, 0.3]:
		_add_ram(_marker(turret, Vector3(0.05 + sx, 0.45, -1.75)), _marker(boom, Vector3(sx, -0.15, -2.1)), 0.11)
	_add_ram(_marker(boom, Vector3(0, 0.75, -1.9)), _marker(stick, stick_tail), 0.11)
	_add_ram(_marker(stick, Vector3(0, 0.3, -0.2)), _marker(bucket, Vector3(0, 0.3, 0.12)), 0.09)


func _add_ram(a: Node3D, b: Node3D, r: float) -> void:
	var holder := Node3D.new()
	add_child(holder)
	var barrel := _cyl(holder, r, 1.0, Vector3.ZERO, _paint)
	var rod := _cyl(holder, r * 0.55, 1.0, Vector3.ZERO, _chrome)
	_rams.append([a, b, holder, barrel, rod])


func _update_rams() -> void:
	for ram in _rams:
		var pa: Vector3 = ram[0].global_position
		var pb: Vector3 = ram[1].global_position
		var l := pa.distance_to(pb)
		var dir := (pb - pa) / l
		var up := Vector3.UP if absf(dir.y) < 0.95 else Vector3.FORWARD
		ram[2].global_transform = Transform3D(Basis.looking_at(dir, up), pa)
		# цилиндърът е по Y; завъртаме го към -Z и го разтягаме по дължината
		var to_z := Basis(Vector3.RIGHT, -PI / 2)
		ram[3].transform = Transform3D(to_z * Basis.from_scale(Vector3(1, l * 0.6, 1)), Vector3(0, 0, -l * 0.3))
		ram[4].transform = Transform3D(to_z * Basis.from_scale(Vector3(1, l * 0.6, 1)), Vector3(0, 0, -l * 0.7))


func _mat(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = roughness
	return m


func _marker(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _cyl(parent: Node3D, radius: float, height: float, pos: Vector3, mat: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 20
	mesh.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


## Кутия между две точки в равнината YZ (за стрелата и рамото).
func _beam(parent: Node3D, a: Vector3, b: Vector3, w: float, h: float, mat: Material) -> MeshInstance3D:
	var mi := _box(parent, Vector3(w, h, a.distance_to(b)), (a + b) / 2.0, mat)
	var d := b - a
	mi.rotation.x = atan2(d.y, -d.z)
	return mi
