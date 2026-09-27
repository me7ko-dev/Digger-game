extends StaticBody3D
## Самосвал: кабина, три оси (отзад двойни гуми), кош. Предницата е към -Z.
## Пръстта в коша е малка земя (terrain.gd) — трупа се и се свлича като купчина.
## Вътрешността на коша: x ±1.1, z ±2.3, подът е на y = BED_Y (в координатите на камиона).

const Kit := preload("res://scripts/meshkit.gd")
const Terrain := preload("res://scripts/terrain.gd")
const PAINT := preload("res://shaders/paint.gdshader")

const BED_Y := 1.45
const BED_HALF := Vector2(1.1, 2.3)   ## половин ширина (x) и дължина (z) на вътрешността
const WALL_TOP := 2.5

var bed: Node3D   ## terrain.gd в коша
var soil_material: Material   ## същият материал като земята; задава се от main.gd преди add_child
var _grime: Texture2D


func _ready() -> void:
	collision_layer = 2
	collision_mask = 0
	_grime = load("res://textures/grime.png")
	_build()


## Колко пръст има в коша (м³).
func load_volume() -> float:
	return bed.total_volume()


## Височината на пръстта в коша под точка p (свят) или NAN, ако p не е над коша.
func bed_height(p: Vector3) -> float:
	var l := to_local(p)
	if absf(l.x) > BED_HALF.x or absf(l.z) > BED_HALF.y:
		return NAN
	return bed.height_at(p)


## Горната част на камиона (кабина, стени, рама) под p, или NAN извън камиона.
func solid_top(p: Vector3) -> float:
	var l := to_local(p)
	if absf(l.x) > 1.27 or l.z < -4.2 or l.z > 2.5:
		return NAN
	if l.z < -2.4:
		return to_global(Vector3(0, 3.35, 0)).y      # кабина
	return to_global(Vector3(0, WALL_TOP, 0)).y       # ръбовете на коша


func deposit(p: Vector3, volume: float) -> void:
	bed.deposit(p, volume, 0.35)


# --- Модел ---

func _paint(color: Color, rough: float, metal: float, grime: float, dust: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PAINT
	m.set_shader_parameter("color", color)
	m.set_shader_parameter("roughness", rough)
	m.set_shader_parameter("metallic", metal)
	m.set_shader_parameter("grime", grime)
	m.set_shader_parameter("dust", dust)
	m.set_shader_parameter("grime_tex", _grime)
	return m


func _std(color: Color, metal: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metal
	m.roughness = rough
	return m


func _build() -> void:
	var cab_paint := _paint(Color(0.86, 0.86, 0.84), 0.28, 0.0, 0.3, 0.55)
	var body_paint := _paint(Color(0.32, 0.33, 0.34), 0.5, 0.5, 0.65, 0.85)
	var dark := _paint(Color(0.05, 0.05, 0.05), 0.6, 0.1, 0.6, 0.8)
	var metal := _paint(Color(0.45, 0.46, 0.47), 0.35, 0.8, 0.4, 0.6)
	var glass := _std(Color(0.08, 0.11, 0.12, 0.45), 0.2, 0.03)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var interior := _std(Color(0.12, 0.12, 0.13), 0.0, 0.8)
	var lamp := _std(Color(1, 0.98, 0.92), 0.0, 0.05)
	lamp.emission_enabled = true
	lamp.emission = Color(1, 0.96, 0.85)
	lamp.emission_energy_multiplier = 1.2
	var amber := _std(Color(1.0, 0.55, 0.05), 0.0, 0.1)
	amber.emission_enabled = true
	amber.emission = Color(1.0, 0.45, 0.0)
	var red := _std(Color(0.7, 0.04, 0.03), 0.0, 0.2)
	red.emission_enabled = true
	red.emission = Color(0.5, 0.0, 0.0)
	var rubber := _std(Color(0.035, 0.035, 0.035), 0.0, 0.85)
	rubber.normal_enabled = true
	rubber.normal_texture = load("res://textures/tread_nor.png")
	rubber.normal_scale = 1.4

	# --- рама ---
	for x in [-0.45, 0.45]:
		_mi(_box(Vector3(0.12, 0.3, 7.6)), dark, Vector3(x, 1.0, -0.35))
	for z in [-3.0, -1.2, 0.6, 2.4]:
		_mi(_box(Vector3(0.9, 0.12, 0.12)), dark, Vector3(0, 1.0, z))

	# --- гуми: предна ос единични, задни две оси двойни ---
	# грайферът е само по търкалящата се част; страните са гладки
	var tread := Kit.lathe(PackedVector2Array([Vector2(0.505, -0.16), Vector2(0.52, -0.1), Vector2(0.52, 0.1), Vector2(0.505, 0.16)]), 36)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for prof in [[Vector2(0.3, -0.19), Vector2(0.45, -0.19), Vector2(0.505, -0.16)], [Vector2(0.505, 0.16), Vector2(0.45, 0.19), Vector2(0.3, 0.19)]]:
		st.append_from(Kit.lathe(PackedVector2Array(prof), 36), 0, Transform3D())
	var sidewall := st.commit()
	var side_rubber := _std(Color(0.04, 0.04, 0.04), 0.0, 0.8)
	var rim := Kit.lathe(PackedVector2Array([Vector2(0.0, 0.14), Vector2(0.12, 0.14), Vector2(0.16, 0.1),
		Vector2(0.27, 0.1), Vector2(0.31, 0.16), Vector2(0.31, -0.16)]), 24)
	var hub := Kit.lathe(PackedVector2Array([Vector2(0.0, 0.2), Vector2(0.08, 0.2), Vector2(0.1, 0.14)]), 12)
	for axle in [[-3.0, false], [1.0, true], [2.3, true]]:
		var z: float = axle[0]
		for side in [-1.0, 1.0]:
			var xs := [1.03] if not axle[1] else [1.03, 0.63]
			for xo in xs:
				var x: float = side * xo
				var flip := Vector3(0, 0, 0) if side > 0 else Vector3(0, PI, 0)
				_mi(tread, rubber, Vector3(x, 0.52, z), flip)
				_mi(sidewall, side_rubber, Vector3(x, 0.52, z), flip)
				if xo == 1.03:
					_mi(rim, metal, Vector3(x, 0.52, z), flip)
					_mi(hub, dark, Vector3(x, 0.52, z), flip)
					for i in 8:
						var a := TAU * i / 8.0
						_mi(_cyl(0.02, 0.05), metal, Vector3(x + side * 0.155, 0.52 + cos(a) * 0.13, z + sin(a) * 0.13), Vector3(0, 0, PI / 2))
				else:
					_mi(rim, dark, Vector3(x, 0.52, z), flip)
		_mi(_cyl(0.07, 2.0), dark, Vector3(0, 0.52, z), Vector3(0, 0, PI / 2))
	# калници
	for side in [-1.0, 1.0]:
		var arc := Kit.arc(Vector2(-3.0, 0.52), 0.66, PI * 0.05, PI * 0.95, 12)
		var fender := Kit.thick_line(arc, _repeat(0.03, arc.size()), false)
		_mi(Kit.extrude_x(fender, 0.45), dark, Vector3(side * 1.03, 0, 0))
		_mi(_box(Vector3(0.45, 0.04, 2.3)), dark, Vector3(side * 0.85, 1.12, 1.65))
		_mi(_box(Vector3(0.5, 0.45, 0.02)), dark, Vector3(side * 0.85, 0.85, 2.95))   # калобран

	# --- кабина ---
	var cab := PackedVector2Array([Vector2(-2.35, 1.05), Vector2(-2.35, 3.2), Vector2(-2.5, 3.33), Vector2(-3.78, 3.33),
		Vector2(-3.98, 3.15), Vector2(-4.08, 2.2), Vector2(-4.12, 1.05)])
	_mi(Kit.extrude_x(cab, 2.44), cab_paint)
	# стъкла: предно и странични
	var ws := Kit.thick_line(PackedVector2Array([Vector2(-4.07, 2.18), Vector2(-3.99, 3.05)]), PackedFloat32Array([0.012, 0.012]), false)
	_mi(Kit.extrude_x(ws, 2.2), glass, Vector3(0, 0, 0), Vector3.ZERO, Vector3(0, 0, -0.012))
	for side in [-1.0, 1.0]:
		var sw := PackedVector2Array([Vector2(-2.55, 2.2), Vector2(-2.55, 3.1), Vector2(-3.85, 3.1), Vector2(-3.95, 2.2)])
		_mi(Kit.extrude_x(sw, 0.02), glass, Vector3(side * 1.225, 0, 0))
		_mi(_box(Vector3(0.02, 1.05, 0.03)), dark, Vector3(side * 1.23, 1.65, -2.75))   # линия на вратата
		_mi(_box(Vector3(0.03, 0.03, 0.18)), metal, Vector3(side * 1.235, 1.95, -2.9))
		for i in 2:
			_mi(_box(Vector3(0.3, 0.04, 0.22)), metal, Vector3(side * 1.08, 0.6 + i * 0.3, -2.25))
		# огледала
		_mi(_cyl(0.015, 0.45), dark, Vector3(side * 1.4, 2.95, -3.9), Vector3(0, 0, PI / 2))
		_mi(_box(Vector3(0.06, 0.42, 0.2)), dark, Vector3(side * 1.63, 2.75, -3.9))
		_mi(_box(Vector3(0.01, 0.36, 0.16)), _std(Color(0.6, 0.65, 0.7), 1.0, 0.02), Vector3(side * 1.63, 2.75, -3.79))
	# вътре
	_mi(_box(Vector3(2.2, 0.35, 0.5)), interior, Vector3(0, 2.0, -3.7))
	_mi(_cyl(0.2, 0.04), interior, Vector3(-0.55, 2.35, -3.55), Vector3(-1.1, 0, 0))
	for x in [-0.55, 0.55]:
		_mi(_box(Vector3(0.55, 0.12, 0.55)), interior, Vector3(x, 1.75, -2.9))
		_mi(_box(Vector3(0.55, 0.8, 0.12)), interior, Vector3(x, 2.2, -2.6))
	# сенник, решетка, броня, фарове, мигач на покрива
	_mi(_box(Vector3(2.3, 0.05, 0.3)), dark, Vector3(0, 3.18, -4.12), Vector3(0.25, 0, 0))
	_mi(_box(Vector3(1.8, 0.7, 0.04)), dark, Vector3(0, 1.72, -4.12))
	for i in 5:
		_mi(_box(Vector3(1.75, 0.05, 0.03)), metal, Vector3(0, 1.45 + i * 0.13, -4.145))
	_mi(_box(Vector3(2.5, 0.35, 0.3)), metal, Vector3(0, 1.0, -4.15))
	for side in [-1.0, 1.0]:
		_mi(_box(Vector3(0.36, 0.14, 0.02)), lamp, Vector3(side * 0.95, 1.05, -4.31))
		_mi(_box(Vector3(0.1, 0.1, 0.02)), amber, Vector3(side * 1.15, 1.25, -4.31))
		_mi(_box(Vector3(0.16, 0.08, 0.02)), red, Vector3(side * 0.95, 1.1, 2.97))
	_mi(_cyl(0.07, 0.12), amber, Vector3(0.7, 3.4, -3.0))
	_mi(_cyl(0.07, 0.12), amber, Vector3(-0.7, 3.4, -3.0))
	# зад кабината: ауспух, резервоар, въздушни бутилки
	_mi(_cyl(0.07, 1.6), metal, Vector3(0.95, 2.5, -2.25))
	_mi(_cyl(0.28, 1.1), metal, Vector3(1.0, 0.9, -1.6), Vector3(PI / 2, 0, 0))
	_mi(_cyl(0.14, 0.9), dark, Vector3(-0.95, 0.85, -1.6), Vector3(PI / 2, 0, 0))

	# --- кош ---
	var floor_top := BED_Y
	var hx := BED_HALF.x
	var hz := BED_HALF.y
	_mi(_box(Vector3(hx * 2 + 0.2, 0.12, hz * 2 + 0.2)), body_paint, Vector3(0, floor_top - 0.06, 0))
	for x in [-0.5, 0.5]:
		_mi(_box(Vector3(0.14, 0.2, hz * 2)), dark, Vector3(x, floor_top - 0.22, 0))
	for side in [-1.0, 1.0]:
		_mi(_box(Vector3(0.08, WALL_TOP - floor_top, hz * 2 + 0.2)), body_paint, Vector3(side * (hx + 0.06), (WALL_TOP + floor_top) / 2.0, 0))
		_mi(_box(Vector3(0.14, 0.1, hz * 2 + 0.25)), body_paint, Vector3(side * (hx + 0.08), WALL_TOP, 0))
		for i in 6:
			_mi(_box(Vector3(0.07, WALL_TOP - floor_top, 0.1)), body_paint, Vector3(side * (hx + 0.12), (WALL_TOP + floor_top) / 2.0, -hz + 0.35 + i * 0.8))
	# предна стена с козирка над кабината
	_mi(_box(Vector3(hx * 2 + 0.2, WALL_TOP + 0.35 - floor_top, 0.1)), body_paint, Vector3(0, (WALL_TOP + 0.35 + floor_top) / 2.0, -hz - 0.05))
	_mi(_box(Vector3(hx * 2 + 0.2, 0.06, 0.75)), body_paint, Vector3(0, WALL_TOP + 0.33, -hz - 0.4), Vector3(-0.08, 0, 0))
	# задна врата с панти
	_mi(_box(Vector3(hx * 2 + 0.2, WALL_TOP - floor_top, 0.08)), body_paint, Vector3(0, (WALL_TOP + floor_top) / 2.0, hz + 0.06))
	for i in 3:
		_mi(_box(Vector3(hx * 2 + 0.2, 0.06, 0.06)), body_paint, Vector3(0, floor_top + 0.2 + i * 0.35, hz + 0.12))
	_mi(_cyl(0.04, hx * 2 + 0.3), metal, Vector3(0, WALL_TOP, hz + 0.1), Vector3(0, 0, PI / 2))
	Kit.merge_children(self)

	# пръстта в коша
	bed = Terrain.new()
	bed.cells_x = 11
	bed.cells_z = 23
	bed.cell = 0.2
	bed.closed = true
	bed.with_collision = false
	bed.hide_empty = true
	bed.repose = 0.7
	bed.min_height = 0.0
	bed.material = soil_material
	bed.position = Vector3(0, floor_top, 0)
	add_child(bed)
	bed.setup()

	# сблъсък: кабина, кош, рама с колела
	for part in [[Vector3(2.5, 2.3, 1.9), Vector3(0, 2.2, -3.25)], [Vector3(2.5, 0.9, 7.3), Vector3(0, 0.9, -0.6)],
			[Vector3(2.5, WALL_TOP - floor_top + 0.1, hz * 2 + 0.3), Vector3(0, (WALL_TOP + floor_top) / 2.0, 0)]]:
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = part[0]
		cs.shape = box
		cs.position = part[1]
		add_child(cs)


func _repeat(v: float, n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a


func _mi(mesh: Mesh, mat: Material, pos := Vector3.ZERO, rot := Vector3.ZERO, offset := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos + offset
	mi.rotation = rot
	add_child(mi)
	return mi


func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


func _cyl(r: float, h: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = r
	m.bottom_radius = r
	m.height = h
	m.radial_segments = 16
	m.rings = 1
	return m
