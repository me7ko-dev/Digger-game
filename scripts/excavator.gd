extends CharacterBody3D
## Багерът: вериги (плочи, които се движат), кабина, която се върти, стрела, рамо, кофа с лостове (H-връзка).
## Предницата на веригите е към -Z. Моделът е направен от код в _build_*() с помощта на meshkit.gd.
## Кофата гребе, когато върхът ѝ е в земята и се движи към отвора (реже земята от terrain.gd).
## Изсипва се, когато отворът ѝ гледа надолу: пуска буци пръст (soil_dropped) с обем.

signal soil_dropped(pos: Vector3, vel: Vector3, volume: float)

const Kit := preload("res://scripts/meshkit.gd")
const PAINT := preload("res://shaders/paint.gdshader")

@export var drive_speed := 2.2    ## м/с
@export var turn_speed := 0.55    ## рад/с (завой на място)
@export var swing_speed := 0.8    ## въртене на кабината, рад/с
@export var boom_speed := 0.5
@export var stick_speed := 0.7
@export var bucket_speed := 1.1
@export var joint_accel := 3.0    ## колко бързо тръгват и спират ставите (1/с)
@export var capacity := 0.6       ## обем на кофата, м³
@export var clumps_per_bucket := 100
@export var dig_depth := 0.4      ## колко може кофата да влезе в земята, без да гребе

const BOOM_MIN := -0.55
const BOOM_MAX := 1.05
const STICK_MIN := -2.6
const STICK_MAX := -0.45
const BUCKET_MIN := -2.3
const BUCKET_MAX := 0.8
const GROUND_LIMIT := -0.15   ## извън земята, която се копае

# вериги
const TRACK_X := 1.0
const AXLE_Y := 0.47
const AXLE_Z := 1.55
const LOOP_R := 0.4
const SHOES := 46

# лостове на кофата (в равнината z, y)
const LINK_A := Vector2(-2.25, 0.2)    ## на рамото
const LINK_B := Vector2(0.15, 0.2)     ## на кофата
const LINK_L1 := 0.55
const LINK_L2 := 0.65

## Земята (terrain.gd); задава се от main.gd
var terrain: Node3D
## Автотест: целеви ъгли на ставите ("swing", "boom", "stick", "bucket") и "drive"/"turn" (-1..1)
var auto := {}
## Колко е пълна кофата (0..1)
var fill := 0.0

var chassis: Node3D
var turret: Node3D
var boom: Node3D
var stick: Node3D
var bucket: Node3D
var tip: Node3D
var _tip_edge: Array[Node3D] = []
var _check_points: Array[Node3D] = []
var _mouth: Node3D
var _soil_mesh: MeshInstance3D
var _soil_shown := -1.0
var _bucket_profile := PackedVector2Array()
var _rams := []
var _jv := {"drive": 0.0, "turn": 0.0, "swing": 0.0, "boom": 0.0, "stick": 0.0, "bucket": 0.0}
var _drop_acc := 0.0
var _last_tip := Vector3.ZERO
var _track_offset := [0.0, 0.0]
var _track_mm: Array[MultiMesh] = []
var _spinners := [[], []]       ## колела на веригите по страни: [Node3D, радиус]
var _link_side: Node3D
var _link_h: Node3D
var _link_c := Vector2(-2.0, 0.7)
var _link_c_marker: Node3D
var _tilt := Basis()

var m_yellow: ShaderMaterial
var m_black: ShaderMaterial
var m_shoe: ShaderMaterial
var m_bucket: ShaderMaterial
var m_teeth: ShaderMaterial
var m_metal: ShaderMaterial
var m_chrome: StandardMaterial3D
var m_glass: StandardMaterial3D
var m_interior: StandardMaterial3D
var m_rubber: StandardMaterial3D
var m_lamp: StandardMaterial3D
var m_red: StandardMaterial3D
var m_soil: Material


func _ready() -> void:
	collision_layer = 4          # слой 3: багер
	collision_mask = 1 | 2       # земя и препятствия
	floor_max_angle = deg_to_rad(38)
	floor_snap_length = 0.3
	_make_materials()
	_build()
	_update_linkage()
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
	var v := drive * drive_speed
	_move_tracks(v - turn * turn_speed * TRACK_X, v + turn * turn_speed * TRACK_X, dt)
	_tilt_to_ground(dt)

	# --- Кабина и ръка ---
	var swing_in := _control("swing", "swing_right", "swing_left")
	turret.rotation.y = wrapf(turret.rotation.y + _smooth("swing", swing_in, swing_speed, dt) * dt, -PI, PI)
	_move_joint(boom, "boom", _control("boom", "boom_down", "boom_up"), boom_speed, BOOM_MIN, BOOM_MAX, dt)
	_move_joint(stick, "stick", _control("stick", "stick_in", "stick_out"), stick_speed, STICK_MIN, STICK_MAX, dt)
	_move_joint(bucket, "bucket", _control("bucket", "bucket_curl", "bucket_dump"), bucket_speed, BUCKET_MIN, BUCKET_MAX, dt)
	_dig()
	_keep_above_ground()
	_last_tip = tip.global_position
	_pour(dt)
	_update_linkage()
	_update_rams()
	_update_soil_look()


## Колко нагоре гледа отворът на кофата: 1 = право нагоре (държи пръст), -1 = надолу.
func bucket_opening_up() -> float:
	return (-bucket.global_basis.y).normalized().y


## Колко е потънал върхът на кофата в земята (м); за прах при копане.
func tip_depth() -> float:
	if terrain == null:
		return 0.0
	return terrain.height_at(tip.global_position) - tip.global_position.y


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


## Кофата не минава през земята: ако влезе по-дълбоко от dig_depth (без да гребе),
## стрелата се повдига малко и кофата се плъзга по земята.
func _keep_above_ground() -> void:
	var tries := 0
	while _penetration() > dig_depth and boom.rotation.x < BOOM_MAX and tries < 40:
		boom.rotation.x = minf(boom.rotation.x + 0.004, BOOM_MAX)
		tries += 1
	if tries > 0 and _jv.boom < 0.0:
		_jv.boom = 0.0


func _penetration() -> float:
	var worst := -INF
	for p in _check_points:
		var gp := p.global_position
		var ground := GROUND_LIMIT
		if terrain and terrain.contains(gp):
			ground = terrain.height_at(gp)
		worst = maxf(worst, ground - gp.y)
	return worst


# --- Пръст ---

func _dig() -> void:
	if terrain == null or fill >= 1.0:
		return
	var moved := tip.global_position - _last_tip
	# гребе, когато върхът се движи към отвора на кофата (и тя не е обърната надолу)
	var scoop := moved.dot((-bucket.global_basis.y).normalized())
	if scoop <= 0.0005 or bucket_opening_up() < -0.6:
		return
	var room := (1.0 - fill) * capacity
	var got := 0.0
	for p in _tip_edge:
		got += terrain.carve(p.global_position, 0.2, room - got)
	fill = minf(1.0, fill + got / capacity)


func _pour(dt: float) -> void:
	var up := bucket_opening_up()
	# докато кофата е в земята, пръстта не пада (земята я държи вътре)
	if fill <= 0.0 or up > -0.1 or tip_depth() > -0.05:
		return
	# колкото по-обърната е кофата, толкова по-бързо пада пръстта
	var rate := lerpf(0.4, 1.8, clampf((-0.1 - up) / 0.7, 0.0, 1.0))
	var amount := minf(fill, rate * dt)
	fill -= amount
	_drop_acc += amount * clumps_per_bucket
	var clump_vol := capacity / clumps_per_bucket
	while _drop_acc >= 1.0:
		_drop_acc -= 1.0
		var p := _mouth.global_position
		p += bucket.global_basis.x.normalized() * randf_range(-0.42, 0.42) + bucket.global_basis.z.normalized() * randf_range(-0.3, 0.3)
		soil_dropped.emit(p, Vector3(randf_range(-0.25, 0.25), randf_range(-0.8, 0.0), randf_range(-0.25, 0.25)), clump_vol)
	if fill <= 0.001:
		if _drop_acc > 0.05:
			soil_dropped.emit(_mouth.global_position, Vector3.ZERO, clump_vol * _drop_acc)
		fill = 0.0
		_drop_acc = 0.0


## Пръстта в кофата: сечение на профила на кофата до нивото на пълнене.
func _update_soil_look() -> void:
	if absf(fill - _soil_shown) < 0.03 and not (fill == 0.0 and _soil_shown != 0.0):
		return
	_soil_shown = fill
	if fill < 0.02:
		_soil_mesh.visible = false
		return
	var level := lerpf(0.12, -0.62, fill)
	var cut := PackedVector2Array([Vector2(-2, level), Vector2(2, level), Vector2(2, 2), Vector2(-2, 2)])
	var parts := Geometry2D.intersect_polygons(_bucket_profile, cut)
	if parts.is_empty():
		_soil_mesh.visible = false
		return
	var poly: PackedVector2Array = parts[0]
	_soil_mesh.mesh = Kit.extrude_x(poly, 0.94)
	_soil_mesh.visible = true


# --- Вериги ---

func _move_tracks(v_left: float, v_right: float, dt: float) -> void:
	var speeds := [v_left, v_right]
	for side in 2:
		if absf(speeds[side]) < 0.0001:
			continue
		_track_offset[side] = fposmod(_track_offset[side] + speeds[side] * dt, _loop_length())
		_place_shoes(side)
		for s in _spinners[side]:
			s[0].rotation.x = -_track_offset[side] / s[1]


func _loop_length() -> float:
	return 4.0 * AXLE_Z + TAU * LOOP_R


## Точка и посока навън по контура на веригата (в равнината z, y), s = разстояние по контура.
func _loop_point(s: float) -> Array:
	var straight := 2.0 * AXLE_Z
	var half := PI * LOOP_R
	s = fposmod(s, _loop_length())
	if s < straight:   # долу, назад
		return [Vector2(-AXLE_Z + s, AXLE_Y - LOOP_R), Vector2(0, -1)]
	s -= straight
	if s < half:       # отзад нагоре
		var a := -PI / 2 + s / LOOP_R
		var n := Vector2(cos(a), sin(a))
		return [Vector2(AXLE_Z, AXLE_Y) + n * LOOP_R, n]
	s -= half
	if s < straight:   # горе, напред
		return [Vector2(AXLE_Z - s, AXLE_Y + LOOP_R), Vector2(0, 1)]
	s -= straight
	var a2 := PI / 2 + s / LOOP_R
	var n2 := Vector2(cos(a2), sin(a2))
	return [Vector2(-AXLE_Z, AXLE_Y) + n2 * LOOP_R, n2]


func _place_shoes(side: int) -> void:
	var mm := _track_mm[side]
	var pitch := _loop_length() / SHOES
	for i in SHOES:
		var lp: Array = _loop_point(i * pitch + _track_offset[side])
		var pos: Vector2 = lp[0]
		var n: Vector2 = lp[1]
		var y := Vector3(0, -n.y, -n.x)          # плочата гледа навън с -Y
		var x := Vector3.RIGHT
		var z := x.cross(y)
		mm.set_instance_transform(i, Transform3D(Basis(x, y, z), Vector3(0, pos.y, pos.x)))


## Наклон на багера според земята под веригите (само картината; сблъсъкът е прав).
func _tilt_to_ground(dt: float) -> void:
	if terrain == null:
		return
	var b := global_basis
	var o := global_position
	var fl: float = terrain.height_at(o + b * Vector3(-TRACK_X, 0, -1.6))
	var fr: float = terrain.height_at(o + b * Vector3(TRACK_X, 0, -1.6))
	var rl: float = terrain.height_at(o + b * Vector3(-TRACK_X, 0, 1.6))
	var rr: float = terrain.height_at(o + b * Vector3(TRACK_X, 0, 1.6))
	var pitch := atan2(((fl + fr) - (rl + rr)) / 2.0, 3.2)
	var roll := atan2(((fl + rl) - (fr + rr)) / 2.0, TRACK_X * 2.0)
	var target := Basis.from_euler(Vector3(pitch, 0, -roll))
	_tilt = _tilt.slerp(target, 1.0 - exp(-6.0 * dt))
	chassis.basis = _tilt
	var lowest := minf(minf(fl, fr), minf(rl, rr))
	var highest := maxf(maxf(fl, fr), maxf(rl, rr))
	chassis.position.y = clampf((lowest + highest) / 2.0 - o.y, -0.5, 0.0)


# --- Лостове и цилиндри ---

func _update_linkage() -> void:
	# B (на кофата) в координатите на рамото
	var bp := bucket.position + bucket.basis * Vector3(0, LINK_B.y, LINK_B.x)
	var a := LINK_A
	var b := Vector2(bp.z, bp.y)
	var d := a.distance_to(b)
	d = clampf(d, absf(LINK_L1 - LINK_L2) + 0.001, LINK_L1 + LINK_L2 - 0.001)
	var along := (LINK_L1 * LINK_L1 - LINK_L2 * LINK_L2 + d * d) / (2.0 * d)
	var h := sqrt(maxf(0.0, LINK_L1 * LINK_L1 - along * along))
	var dir := (b - a).normalized()
	var m := a + dir * along
	var perp := Vector2(-dir.y, dir.x)
	var c1 := m + perp * h
	var c2 := m - perp * h
	_link_c = c1 if c1.y > c2.y else c2
	_link_c_marker.position = Vector3(0, _link_c.y, _link_c.x)
	_orient_link(_link_side, a, _link_c)
	_orient_link(_link_h, _link_c, b)


func _orient_link(node: Node3D, from: Vector2, to: Vector2) -> void:
	node.position = Vector3(0, from.y, from.x)
	var dvec := to - from
	node.rotation.x = atan2(dvec.y, -dvec.x)


func _add_ram(a: Node3D, b: Node3D, r: float) -> void:
	var holder := Node3D.new()
	add_child(holder)
	var barrel := _mi(holder, _cyl_mesh(r, 1.0), m_yellow)
	var cap := _mi(holder, _cyl_mesh(r * 1.15, 0.12), m_yellow)
	var rod := _mi(holder, _cyl_mesh(r * 0.55, 1.0), m_chrome)
	_rams.append([a, b, holder, barrel, rod, cap])


func _update_rams() -> void:
	var to_z := Basis(Vector3.RIGHT, -PI / 2)
	for ram in _rams:
		var pa: Vector3 = ram[0].global_position
		var pb: Vector3 = ram[1].global_position
		var l := pa.distance_to(pb)
		var dir := (pb - pa) / l
		var up := Vector3.UP if absf(dir.y) < 0.95 else Vector3.FORWARD
		ram[2].global_transform = Transform3D(Basis.looking_at(dir, up), pa)
		# цилиндърът е по Y; завъртаме го към -Z и го разтягаме по дължината
		ram[3].transform = Transform3D(to_z * Basis.from_scale(Vector3(1, l * 0.62, 1)), Vector3(0, 0, -l * 0.31))
		ram[5].transform = Transform3D(to_z, Vector3(0, 0, -l * 0.62))
		ram[4].transform = Transform3D(to_z * Basis.from_scale(Vector3(1, l * 0.5, 1)), Vector3(0, 0, -l * 0.75))


# --- Модел ---

func _make_materials() -> void:
	var grime: Texture2D = load("res://textures/grime.png")
	m_yellow = _paint(Color(0.93, 0.6, 0.05), 0.3, 0.0, 0.35, 0.6, 0.0, grime)
	m_black = _paint(Color(0.06, 0.06, 0.065), 0.55, 0.1, 0.7, 0.9, 0.0, grime)
	m_shoe = _paint(Color(0.16, 0.15, 0.14), 0.6, 0.5, 0.85, 0.9, 0.35, grime)
	m_bucket = _paint(Color(0.07, 0.07, 0.07), 0.5, 0.2, 0.6, 0.8, 0.7, grime)
	m_teeth = _paint(Color(0.3, 0.29, 0.27), 0.45, 0.8, 0.4, 0.5, 0.9, grime)
	m_metal = _paint(Color(0.22, 0.22, 0.23), 0.45, 0.6, 0.5, 0.6, 0.2, grime)
	m_chrome = _std(Color(0.9, 0.9, 0.92), 1.0, 0.1)
	m_glass = _std(Color(0.1, 0.13, 0.14, 0.35), 0.2, 0.02)
	m_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m_glass.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	m_interior = _std(Color(0.1, 0.1, 0.11), 0.0, 0.8)
	m_rubber = _std(Color(0.03, 0.03, 0.03), 0.0, 0.7)
	m_lamp = _std(Color(1, 0.97, 0.9), 0.0, 0.1)
	m_lamp.emission_enabled = true
	m_lamp.emission = Color(1, 0.95, 0.85)
	m_lamp.emission_energy_multiplier = 1.5
	m_red = _std(Color(0.7, 0.05, 0.03), 0.0, 0.2)
	m_red.emission_enabled = true
	m_red.emission = Color(0.6, 0.02, 0.0)
	var soil := StandardMaterial3D.new()
	soil.albedo_texture = load("res://textures/dirt_diff.jpg")
	soil.normal_enabled = true
	soil.normal_texture = load("res://textures/dirt_nor.jpg")
	soil.uv1_triplanar = true
	soil.uv1_scale = Vector3.ONE * 0.8
	soil.roughness = 0.95
	m_soil = soil


func _paint(color: Color, rough: float, metal: float, grime: float, dust: float, wear: float, tex: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PAINT
	m.set_shader_parameter("color", color)
	m.set_shader_parameter("roughness", rough)
	m.set_shader_parameter("metallic", metal)
	m.set_shader_parameter("grime", grime)
	m.set_shader_parameter("dust", dust)
	m.set_shader_parameter("wear", wear)
	m.set_shader_parameter("grime_tex", tex)
	return m


func _std(color: Color, metal: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metal
	m.roughness = rough
	return m


func _build() -> void:
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.6, 0.85, 3.8)
	col.shape = box
	col.position = Vector3(0, 0.5, 0)
	add_child(col)
	var col2 := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 1.45
	cyl.height = 1.5
	col2.shape = cyl
	col2.position = Vector3(0, 1.9, 0.2)
	add_child(col2)

	chassis = Node3D.new()
	add_child(chassis)
	_build_undercarriage()
	turret = Node3D.new()
	turret.position = Vector3(0, 1.05, 0)
	chassis.add_child(turret)
	_build_upper()
	_build_arm()
	for n in [chassis, turret, boom, stick, bucket]:
		Kit.merge_children(n)


func _build_undercarriage() -> void:
	var shoe_poly := PackedVector2Array([
		Vector2(-0.092, 0.02), Vector2(0.092, 0.02), Vector2(0.092, -0.015), Vector2(0.03, -0.02),
		Vector2(0.018, -0.07), Vector2(-0.018, -0.07), Vector2(-0.03, -0.02), Vector2(-0.092, -0.015)])
	var shoe_mesh := Kit.extrude_x(shoe_poly, 0.6)
	var sprocket_poly := PackedVector2Array()
	for i in 22:
		var a := TAU * i / 22.0
		var r := 0.37 if i % 2 == 0 else 0.31
		sprocket_poly.append(Vector2(cos(a), sin(a)) * r)
	for side in 2:
		var sx := -TRACK_X if side == 0 else TRACK_X
		# плочи на веригата (MultiMesh)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = shoe_mesh
		mm.instance_count = SHOES
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = m_shoe
		mmi.position.x = sx
		chassis.add_child(mmi)
		_track_mm.append(mm)
		_place_shoes(side)
		# рама на веригата
		var frame := PackedVector2Array([
			Vector2(-1.35, 0.3), Vector2(1.35, 0.3), Vector2(1.45, 0.45), Vector2(1.3, 0.72),
			Vector2(-1.3, 0.72), Vector2(-1.45, 0.45)])
		_mi(chassis, Kit.extrude_x(frame, 0.34), m_black, Vector3(sx, 0, 0))
		_mi(chassis, Kit.extrude_x(Kit.chamfer_rect(2.2, 0.12, 0.04), 0.42), m_black, Vector3(sx, 0.78, 0))
		# задвижващо колело (отзад), обтяжно колело (отпред), ролки
		var sprocket := _spinner(side, Vector3(sx, AXLE_Y, AXLE_Z), 0.37)
		_mi(sprocket, Kit.extrude_x(sprocket_poly, 0.12), m_metal)
		_mi(sprocket, _wheel_mesh(0.22, 0.5), m_black)
		var idler := _spinner(side, Vector3(sx, AXLE_Y, -AXLE_Z), 0.36)
		_mi(idler, _wheel_mesh(0.36, 0.22), m_metal)
		_mi(idler, _wheel_mesh(0.2, 0.5), m_black)
		for i in 6:
			var roller := _spinner(side, Vector3(sx, AXLE_Y - LOOP_R + 0.12, -1.05 + i * 0.42), 0.1)
			_mi(roller, _wheel_mesh(0.1, 0.34), m_metal)
		for z in [-0.6, 0.6]:
			var carrier := _spinner(side, Vector3(sx, AXLE_Y + LOOP_R - 0.1, z), 0.08)
			_mi(carrier, _wheel_mesh(0.08, 0.2), m_metal)
	# средна част и лагер на въртене
	_mi(chassis, Kit.extrude_x(Kit.chamfer_rect(2.2, 0.5, 0.12), 1.7), m_black, Vector3(0, 0.62, 0), Vector3(0, PI / 2, 0))
	_mi(chassis, _wheel_mesh(0.95, 0.18), m_metal, Vector3(0, 0.95, 0), Vector3(0, 0, PI / 2))


func _build_upper() -> void:
	# плоча и противотежест (отзад е закръглена)
	var deck := PackedVector2Array([Vector2(-1.25, -1.55), Vector2(1.25, -1.55)])
	deck.append_array(_rear_arc(2.2, 1.25))
	_mi(turret, Kit.extrude_y(deck, 0.28), m_black)
	var cw := PackedVector2Array([Vector2(-1.25, 1.15), Vector2(1.25, 1.15)])
	cw.append_array(_rear_arc(2.2, 1.25))
	_mi(turret, Kit.extrude_y(cw, 0.95), m_yellow, Vector3(0, 0.28, 0))
	var cw_top := PackedVector2Array([Vector2(-1.2, 1.2), Vector2(1.2, 1.2)])
	cw_top.append_array(_rear_arc(2.14, 1.2))
	_mi(turret, Kit.extrude_y(cw_top, 0.06), m_yellow, Vector3(0, 1.23, 0))
	for x in [-0.95, 0.95]:
		_mi(turret, _box_mesh(Vector3(0.18, 0.08, 0.05)), m_red, Vector3(x, 0.95, sqrt(2.2 * 2.2 - x * x) - 0.01))
	# капак на двигателя с решетки
	var hood := PackedVector2Array([Vector2(-0.05, 0.28), Vector2(1.2, 0.28), Vector2(1.2, 1.2),
		Vector2(1.1, 1.32), Vector2(0.05, 1.32), Vector2(-0.05, 1.22)])
	_mi(turret, Kit.extrude_x(hood, 2.46), m_yellow)
	for sx in [-1.235, 1.235]:
		for i in 7:
			_mi(turret, _box_mesh(Vector3(0.02, 0.05, 0.9)), m_black, Vector3(sx, 0.55 + i * 0.09, 0.6))
	_mi(turret, _box_mesh(Vector3(1.6, 0.03, 0.8)), m_black, Vector3(0.2, 1.33, 0.62))
	for i in 9:
		_mi(turret, _box_mesh(Vector3(1.5, 0.035, 0.03)), m_metal, Vector3(0.2, 1.35, 0.26 + i * 0.09))
	# ауспух и въздушен филтър
	_mi(turret, _cyl_mesh(0.07, 0.55), m_metal, Vector3(0.85, 1.58, 0.95))
	_mi(turret, _cyl_mesh(0.09, 0.05), m_black, Vector3(0.85, 1.87, 0.95), Vector3(0.3, 0, 0))
	_mi(turret, _cyl_mesh(0.13, 0.3), m_black, Vector3(0.45, 1.47, 0.35))
	# парапети
	_rail(turret, [Vector3(1.15, 1.32, 0.1), Vector3(1.15, 1.72, 0.2), Vector3(1.15, 1.72, 1.0), Vector3(1.15, 1.32, 1.1)])
	# резервоар / кутия вдясно отпред, стъпала
	var tank := PackedVector2Array([Vector2(-1.55, 0.28), Vector2(-0.1, 0.28), Vector2(-0.1, 1.15),
		Vector2(-0.22, 1.27), Vector2(-1.4, 1.27), Vector2(-1.55, 1.12)])
	_mi(turret, Kit.extrude_x(tank, 0.92), m_yellow, Vector3(0.79, 0, 0))
	for i in 3:
		_mi(turret, _box_mesh(Vector3(0.5, 0.03, 0.18)), m_metal, Vector3(0.95, 0.35 + i * 0.3, -1.6))
	_rail(turret, [Vector3(1.2, 1.27, -1.45), Vector3(1.2, 1.62, -1.35), Vector3(1.2, 1.62, -0.3), Vector3(1.2, 1.27, -0.2)])
	# основа на стрелата
	var foot := PackedVector2Array([Vector2(-1.55, 0.28), Vector2(-0.8, 0.28), Vector2(-0.95, 1.05),
		Vector2(-1.2, 1.25), Vector2(-1.45, 1.2), Vector2(-1.6, 0.9)])
	for x in [-0.25, 0.35]:
		_mi(turret, Kit.extrude_x(foot, 0.08), m_black, Vector3(x, 0, 0))
	_build_cab()


func _build_cab() -> void:
	var cx := -0.775
	var w := 0.95
	var prof := PackedVector2Array([Vector2(0.0, 0.3), Vector2(0.0, 1.95), Vector2(-0.18, 2.03),
		Vector2(-1.18, 2.02), Vector2(-1.36, 1.9), Vector2(-1.47, 1.1), Vector2(-1.5, 0.3)])
	_mi(turret, Kit.extrude_x(prof, w), m_glass, Vector3(cx, 0, 0))
	# покрив
	var roof := Kit.thick_line(PackedVector2Array([Vector2(0.03, 1.96), Vector2(-0.18, 2.05), Vector2(-1.18, 2.04), Vector2(-1.39, 1.9)]),
		PackedFloat32Array([0.04, 0.04, 0.04, 0.04]), false)
	_mi(turret, Kit.extrude_x(roof, w + 0.04), m_yellow, Vector3(cx, 0, 0))
	# долна част (ламарина)
	var low := PackedVector2Array([Vector2(0.01, 0.28), Vector2(0.01, 0.78), Vector2(-1.51, 0.78), Vector2(-1.51, 0.28)])
	_mi(turret, Kit.extrude_x(low, w + 0.02), m_yellow, Vector3(cx, 0, 0))
	# колони
	var front_edge := PackedVector2Array([Vector2(-1.49, 0.78), Vector2(-1.47, 1.1), Vector2(-1.36, 1.9), Vector2(-1.18, 2.02)])
	var pillar := Kit.thick_line(front_edge, PackedFloat32Array([0.035, 0.035, 0.035, 0.035]), false)
	var rear_edge := Kit.thick_line(PackedVector2Array([Vector2(-0.02, 0.78), Vector2(-0.02, 1.97)]), PackedFloat32Array([0.04, 0.04]), false)
	for sx in [cx - w / 2.0, cx + w / 2.0]:
		_mi(turret, Kit.extrude_x(pillar, 0.05), m_black, Vector3(sx, 0, 0))
		_mi(turret, Kit.extrude_x(rear_edge, 0.05), m_black, Vector3(sx, 0, 0))
	_mi(turret, _box_mesh(Vector3(0.04, 1.2, 0.05)), m_black, Vector3(cx - w / 2.0, 1.38, -0.62))   # врата
	_mi(turret, _box_mesh(Vector3(0.02, 0.03, 0.15)), m_chrome, Vector3(cx - w / 2.0 - 0.02, 1.2, -0.55))
	_mi(turret, _box_mesh(Vector3(0.02, 0.6, 0.02)), m_black, Vector3(cx + 0.1, 1.5, -1.43), Vector3(0.12, 0, 0.5))  # чистачка
	# вътре: седалка, конзоли, джойстици, екран
	_mi(turret, _box_mesh(Vector3(0.5, 0.12, 0.5)), m_interior, Vector3(cx, 0.75, -0.45))
	_mi(turret, _box_mesh(Vector3(0.5, 0.65, 0.12)), m_interior, Vector3(cx, 1.1, -0.18), Vector3(-0.15, 0, 0))
	for sx in [-0.34, 0.34]:
		_mi(turret, _box_mesh(Vector3(0.14, 0.3, 0.55)), m_interior, Vector3(cx + sx, 0.62, -0.55))
		_mi(turret, _cyl_mesh(0.02, 0.18), m_metal, Vector3(cx + sx, 0.85, -0.72))
	_mi(turret, _box_mesh(Vector3(0.22, 0.15, 0.03)), m_interior, Vector3(cx + 0.3, 1.2, -1.3), Vector3(-0.3, 0, 0))
	# фарове на покрива, огледало
	for sx in [-0.25, 0.25]:
		_mi(turret, _box_mesh(Vector3(0.14, 0.1, 0.08)), m_black, Vector3(cx + sx, 2.12, -1.1))
		_mi(turret, _box_mesh(Vector3(0.11, 0.07, 0.01)), m_lamp, Vector3(cx + sx, 2.12, -1.145))
	_mi(turret, _box_mesh(Vector3(0.03, 0.03, 0.4)), m_black, Vector3(cx - w / 2.0 - 0.02, 1.1, -1.55), Vector3(0, 0.3, 0))
	_mi(turret, _box_mesh(Vector3(0.04, 0.22, 0.15)), m_black, Vector3(cx - w / 2.0 - 0.1, 1.2, -1.72))


func _build_arm() -> void:
	# Стрела (извита, кутия с различна височина)
	boom = Node3D.new()
	boom.position = Vector3(0.05, 1.0, -1.25)
	boom.rotation.x = 0.35
	turret.add_child(boom)
	var boom_pts := PackedVector2Array([Vector2(0, 0), Vector2(-1.2, 0.62), Vector2(-2.5, 0.95), Vector2(-3.6, 0.55), Vector2(-4.6, 0)])
	var boom_half := PackedFloat32Array([0.3, 0.36, 0.4, 0.3, 0.22])
	_mi(boom, Kit.extrude_x(Kit.thick_line(boom_pts, boom_half), 0.5), m_yellow)
	var boom_plate := Kit.thick_line(PackedVector2Array([Vector2(-1.0, 0.56), Vector2(-2.5, 0.95), Vector2(-3.5, 0.58)]),
		PackedFloat32Array([0.28, 0.32, 0.24]), false)
	_mi(boom, Kit.extrude_x(boom_plate, 0.54), m_yellow)
	_mi(boom, _wheel_mesh(0.2, 0.6), m_metal)
	_mi(boom, _wheel_mesh(0.07, 0.72), m_chrome)
	_mi(boom, _wheel_mesh(0.18, 0.52), m_metal, Vector3(0, 0, -4.6))
	_mi(boom, _wheel_mesh(0.06, 0.66), m_chrome, Vector3(0, 0, -4.6))
	for sx in [-0.3, 0.3]:
		_mi(boom, _wheel_mesh(0.1, 0.1), m_metal, Vector3(sx, 0.45, -2.1))
	_mi(boom, Kit.extrude_x(PackedVector2Array([Vector2(-1.75, 1.05), Vector2(-2.05, 1.05), Vector2(-2.0, 1.3), Vector2(-1.8, 1.3)]), 0.3), m_yellow)
	# маркучи по стрелата
	var hose := Kit.thick_line(PackedVector2Array([Vector2(-0.3, 0.42), Vector2(-1.2, 1.02), Vector2(-2.5, 1.39), Vector2(-3.6, 0.9), Vector2(-4.3, 0.45)]),
		PackedFloat32Array([0.025, 0.025, 0.025, 0.025, 0.025]), false)
	for sx in [-0.1, 0.1]:
		_mi(boom, Kit.extrude_x(hose, 0.05), m_rubber, Vector3(sx, 0, 0))
	_mi(boom, _box_mesh(Vector3(0.16, 0.1, 0.1)), m_black, Vector3(0.18, 0.72, -1.3))
	_mi(boom, _box_mesh(Vector3(0.12, 0.07, 0.01)), m_lamp, Vector3(0.18, 0.72, -1.36))

	# Рамо
	stick = Node3D.new()
	stick.position = Vector3(0, 0, -4.6)
	stick.rotation.x = -1.6
	boom.add_child(stick)
	var stick_pts := PackedVector2Array([Vector2(0.55, 0.4), Vector2(0.0, 0.08), Vector2(-1.3, 0.02), Vector2(-2.6, 0.0)])
	_mi(stick, Kit.extrude_x(Kit.thick_line(stick_pts, PackedFloat32Array([0.16, 0.3, 0.25, 0.17])), 0.42), m_yellow)
	_mi(stick, Kit.extrude_x(PackedVector2Array([Vector2(-0.1, 0.3), Vector2(-0.45, 0.3), Vector2(-0.4, 0.5), Vector2(-0.15, 0.5)]), 0.24), m_yellow)
	_mi(stick, _wheel_mesh(0.14, 0.5), m_metal, Vector3(0, 0, -2.6))
	_mi(stick, _wheel_mesh(0.12, 0.52), m_metal, Vector3(0, LINK_A.y, LINK_A.x))
	var stick_hose := Kit.thick_line(PackedVector2Array([Vector2(0.3, 0.55), Vector2(-0.2, 0.36), Vector2(-1.5, 0.3), Vector2(-2.1, 0.28)]),
		PackedFloat32Array([0.022, 0.022, 0.022, 0.022]), false)
	_mi(stick, Kit.extrude_x(stick_hose, 0.04), m_rubber, Vector3(0.12, 0, 0))

	# Лостове: странични (две плочи) и H-връзка
	_link_side = Node3D.new()
	stick.add_child(_link_side)
	for sx in [-0.25, 0.25]:
		_mi(_link_side, Kit.extrude_x(Kit.thick_line(PackedVector2Array([Vector2(0, 0), Vector2(-LINK_L1, 0)]), PackedFloat32Array([0.08, 0.08])), 0.04), m_black, Vector3(sx, 0, 0))
	_link_h = Node3D.new()
	stick.add_child(_link_h)
	_mi(_link_h, Kit.extrude_x(Kit.thick_line(PackedVector2Array([Vector2(0, 0), Vector2(-LINK_L2, 0)]), PackedFloat32Array([0.09, 0.08])), 0.36), m_yellow)
	_mi(_link_h, _wheel_mesh(0.07, 0.6), m_chrome)
	_link_c_marker = Node3D.new()
	stick.add_child(_link_c_marker)

	# Кофа: С-образен профил, отворът е към -Y, зъбите към -Z
	bucket = Node3D.new()
	bucket.position = Vector3(0, 0, -2.6)
	bucket.rotation.x = -0.6
	stick.add_child(bucket)
	var shell := PackedVector2Array([Vector2(0.1, -0.58), Vector2(0.14, -0.22), Vector2(0.05, 0.04),
		Vector2(-0.35, 0.12), Vector2(-0.75, 0.0), Vector2(-0.98, -0.3), Vector2(-1.04, -0.62)])
	_bucket_profile = shell
	_mi(bucket, Kit.extrude_x(Kit.thick_line(shell, PackedFloat32Array([0.025, 0.03, 0.03, 0.03, 0.03, 0.03, 0.03]), false), 1.0), m_bucket)
	for sx in [-0.51, 0.51]:
		_mi(bucket, Kit.extrude_x(shell, 0.035), m_bucket, Vector3(sx, 0, 0))
	# режещ ръб и зъби
	_mi(bucket, Kit.extrude_x(Kit.thick_line(PackedVector2Array([Vector2(-1.02, -0.5), Vector2(-1.05, -0.68)]), PackedFloat32Array([0.035, 0.03]), false), 1.04), m_teeth)
	var tooth := PackedVector2Array([Vector2(-1.0, -0.6), Vector2(-1.1, -0.6), Vector2(-1.1, -0.72), Vector2(-1.085, -0.8), Vector2(-1.06, -0.8), Vector2(-1.0, -0.7)])
	for i in 5:
		_mi(bucket, Kit.extrude_x(tooth, 0.085), m_teeth, Vector3(-0.4 + i * 0.2, 0, 0))
	# уши за рамото и лостовете
	var ear := PackedVector2Array([Vector2(0.24, -0.05), Vector2(0.28, 0.2), Vector2(0.18, 0.32), Vector2(-0.12, 0.3), Vector2(-0.32, 0.1)])
	for sx in [-0.23, 0.23]:
		_mi(bucket, Kit.extrude_x(ear, 0.05), m_bucket, Vector3(sx, 0, 0))
	_mi(bucket, _wheel_mesh(0.06, 0.62), m_chrome, Vector3(0, LINK_B.y, LINK_B.x))
	_mi(bucket, _wheel_mesh(0.06, 0.6), m_chrome)
	_soil_mesh = MeshInstance3D.new()
	_soil_mesh.material_override = m_soil
	_soil_mesh.visible = false
	var soil_holder := Node3D.new()   # отделно, за да не се слее с кофата
	bucket.add_child(soil_holder)
	soil_holder.add_child(_soil_mesh)

	tip = _marker(bucket, Vector3(0, -0.8, -1.08))
	for i in 5:
		_tip_edge.append(_marker(bucket, Vector3(-0.44 + i * 0.22, -0.74, -1.07)))
	_mouth = _marker(bucket, Vector3(0, -0.45, -0.47))
	# само зъбите опират в земята; тялото на кофата влиза в пръстта, докато гребе
	_check_points = [tip, _tip_edge[0], _tip_edge[4]]

	# Хидравлични цилиндри
	for sx in [-0.33, 0.33]:
		_add_ram(_marker(turret, Vector3(0.05 + sx, 0.5, -1.72)), _marker(boom, Vector3(sx, 0.45, -2.1)), 0.11)
	_add_ram(_marker(boom, Vector3(0, 1.22, -1.9)), _marker(stick, Vector3(0, 0.4, 0.55)), 0.11)
	_add_ram(_marker(stick, Vector3(0, 0.45, -0.28)), _link_c_marker, 0.09)


func _rear_arc(r: float, half_w: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var a0 := asin(half_w / r)
	for i in 13:
		var a := lerpf(a0, -a0, float(i) / 12.0)
		pts.append(Vector2(sin(a) * r, cos(a) * r))
	return pts


func _rail(parent: Node3D, pts: Array) -> void:
	for i in pts.size() - 1:
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[i + 1]
		var mi := _mi(parent, _cyl_mesh(0.022, a.distance_to(b)), m_yellow, (a + b) / 2.0)
		var d := (b - a).normalized()
		var up := Vector3.RIGHT if absf(d.x) < 0.9 else Vector3.FORWARD
		mi.basis = Basis.looking_at(d, up) * Basis(Vector3.RIGHT, PI / 2)


func _spinner(side: int, pos: Vector3, radius: float) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	chassis.add_child(n)
	_spinners[side].append([n, radius])
	return n


func _marker(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n


func _mi(parent: Node3D, mesh: Mesh, mat: Material, pos := Vector3.ZERO, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


func _box_mesh(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


func _cyl_mesh(r: float, h: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = r
	m.bottom_radius = r
	m.height = h
	m.radial_segments = 16
	m.rings = 1
	return m


## Колело/болт по оста X: цилиндър с фаска.
func _wheel_mesh(r: float, width: float) -> ArrayMesh:
	var c := minf(0.02, r * 0.2)
	var w := width / 2.0
	return Kit.lathe(PackedVector2Array([Vector2(0.0, -w), Vector2(r - c, -w), Vector2(r, -w + c),
		Vector2(r, w - c), Vector2(r - c, w), Vector2(0.0, w)]), 20)
