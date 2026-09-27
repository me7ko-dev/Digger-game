extends Node3D
## Обзавеждане на строителната площадка: ограда от мрежени пана, конуси, бетонни тръби,
## фургон (офис) и палети с тухли. Всичко е от прости форми; сблъсък на слой 2 (препятствия).

const Kit := preload("res://scripts/meshkit.gd")
const PAINT := preload("res://shaders/paint.gdshader")

var ground: Callable      ## (Vector3) -> височина на земята
var _grime: Texture2D


func build(fence_rect: Rect2, gap_center: float, gap_width: float) -> void:
	_grime = load("res://textures/grime.png")
	_fence(fence_rect, gap_center, gap_width)
	for p in [Vector3(3.5, 0, 4.2), Vector3(5.0, 0, 4.6), Vector3(9.5, 0, 4.4), Vector3(10.6, 0, -5.4), Vector3(3.8, 0, -6.2)]:
		_cone(p)
	_pipes(Vector3(-12.0, 0, -19.0))
	_office(Vector3(-15.5, 0, 9.0), 0.3)
	_pallet(Vector3(13.0, 0, -15.0), 0.4)
	_pallet(Vector3(14.6, 0, -13.6), 0.1)


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


func _y(p: Vector3) -> Vector3:
	return Vector3(p.x, ground.call(p) if ground.is_valid() else 0.0, p.z)


# --- ограда ---

func _fence(r: Rect2, gap_center: float, gap_width: float) -> void:
	const W := 3.5
	var mesh_tex := _wire_texture()
	var wire := StandardMaterial3D.new()
	wire.albedo_texture = mesh_tex
	wire.albedo_color = Color(0.75, 0.76, 0.78)
	wire.metallic = 0.8
	wire.roughness = 0.4
	wire.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	wire.cull_mode = BaseMaterial3D.CULL_DISABLED
	wire.uv1_scale = Vector3(W / 0.2, 2.0 / 0.2, 1)
	var frame_mat := _paint(Color(0.7, 0.71, 0.72), 0.35, 0.8, 0.4, 0.3)
	var foot_mat := _paint(Color(0.55, 0.54, 0.5), 0.9, 0.0, 0.6, 0.7)

	var quad := QuadMesh.new()
	quad.size = Vector2(W, 1.9)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part in [[Vector3(-W / 2, 1.0, 0), 2.0, 0.0], [Vector3(W / 2, 1.0, 0), 2.0, 0.0], [Vector3(0, 1.97, 0), W, PI / 2], [Vector3(0, 0.05, 0), W, PI / 2]]:
		var c := CylinderMesh.new()
		c.top_radius = 0.02
		c.bottom_radius = 0.02
		c.height = part[1]
		c.radial_segments = 8
		st.append_from(c, 0, Transform3D(Basis(Vector3.BACK, part[2]), part[0]))
	var frame := st.commit()
	var foot := Kit.extrude_x(Kit.chamfer_rect(0.3, 0.16, 0.04), 0.65)

	var xforms: Array[Transform3D] = []
	var sides := [[r.position, Vector2(r.end.x, r.position.y)], [Vector2(r.end.x, r.position.y), r.end],
		[r.end, Vector2(r.position.x, r.end.y)], [Vector2(r.position.x, r.end.y), r.position]]
	for s in sides:
		var a: Vector2 = s[0]
		var b: Vector2 = s[1]
		var len := a.distance_to(b)
		var dir := (b - a) / len
		var count := ceili(len / W)
		var basis := Basis(Vector3.UP, atan2(-dir.y, dir.x))
		for i in count:
			var c2 := a + dir * (i + 0.5) * (len / count)
			# вход за камиона (на страната с най-голямо z)
			if absf(a.y - r.end.y) < 0.01 and absf(b.y - r.end.y) < 0.01 and absf(c2.x - gap_center) < gap_width / 2.0:
				continue
			var p := _y(Vector3(c2.x, 0, c2.y))
			xforms.append(Transform3D(basis * Basis.from_scale(Vector3(len / count / W, 1, 1)), p))
		var body := StaticBody3D.new()
		body.collision_layer = 2
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(len, 2.0, 0.3)
		cs.shape = box
		body.add_child(cs)
		body.transform = Transform3D(basis, Vector3((a.x + b.x) / 2.0, 1.0, (a.y + b.y) / 2.0))
		if not (absf(a.y - r.end.y) < 0.01 and absf(b.y - r.end.y) < 0.01):
			add_child(body)
	for m in [[quad, wire, Vector3(0, 1.0, 0)], [frame, frame_mat, Vector3.ZERO], [foot, foot_mat, Vector3(-W / 2, 0.08, 0)]]:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = m[0]
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i] * Transform3D(Basis(), m[2]))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = m[1]
		add_child(mmi)


func _wire_texture() -> ImageTexture:
	var n := 32
	var img := Image.create(n, n, true, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	for i in n:
		for t in 2:
			img.set_pixel(i, t, Color.WHITE)
			img.set_pixel(t, i, Color.WHITE)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# --- конус ---

func _cone(p: Vector3) -> void:
	var orange := _paint(Color(0.95, 0.3, 0.02), 0.45, 0.0, 0.3, 0.6)
	var white := _paint(Color(0.92, 0.92, 0.9), 0.3, 0.0, 0.3, 0.5)
	var black := _paint(Color(0.04, 0.04, 0.04), 0.8, 0.0, 0.5, 0.8)
	var node := Node3D.new()
	node.position = _y(p)
	node.rotation.y = randf() * TAU
	add_child(node)
	var up := Basis(Vector3.BACK, PI / 2)   # профилът е по X, конусът трябва да е изправен
	var body := Kit.lathe(PackedVector2Array([Vector2(0.16, -0.36), Vector2(0.03, 0.36)]), 20)
	var band := Kit.lathe(PackedVector2Array([Vector2(0.105, -0.07), Vector2(0.079, 0.07)]), 20)
	_mi(node, body, orange, Vector3(0, 0.4, 0), up)
	_mi(node, band, white, Vector3(0, 0.45, 0), up, 1.02)
	var base := BoxMesh.new()
	base.size = Vector3(0.42, 0.04, 0.42)
	_mi(node, base, black, Vector3(0, 0.02, 0), Basis())
	_collider(node, Vector3(0.35, 0.8, 0.35), Vector3(0, 0.4, 0))


# --- бетонни тръби ---

func _pipes(p: Vector3) -> void:
	var concrete := _paint(Color(0.62, 0.61, 0.58), 0.95, 0.0, 0.55, 0.7)
	concrete.set_shader_parameter("scale", 2.0)
	var node := Node3D.new()
	node.position = _y(p)
	node.rotation.y = 0.4
	add_child(node)
	var r := 0.6
	var tube := Kit.lathe(PackedVector2Array([Vector2(r - 0.1, 1.0), Vector2(r - 0.1, -1.0), Vector2(r, -1.0), Vector2(r, 1.0), Vector2(r - 0.1, 1.0)]), 28)
	for pos in [Vector3(0, r, -r * 1.02), Vector3(0, r, r * 1.02), Vector3(0, r * 2.72, 0)]:
		_mi(node, tube, concrete, pos, Basis())
	_collider(node, Vector3(2.0, 2.4 * r + r, 2.4 * r), Vector3(0, 1.2 * r + 0.3, 0))


# --- фургон ---

func _office(p: Vector3, rot: float) -> void:
	var wall := _paint(Color(0.24, 0.36, 0.5), 0.5, 0.3, 0.45, 0.6)
	var trim := _paint(Color(0.85, 0.85, 0.83), 0.4, 0.2, 0.4, 0.5)
	var dark := _paint(Color(0.06, 0.06, 0.06), 0.6, 0.2, 0.5, 0.7)
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.1, 0.13, 0.15)
	glass.metallic = 0.6
	glass.roughness = 0.05
	var node := Node3D.new()
	node.position = _y(p)
	node.rotation.y = rot
	add_child(node)
	var L := 6.0
	var W := 2.45
	var H := 2.6
	_mi(node, _box(Vector3(W, H, L)), wall, Vector3(0, H / 2 + 0.15, 0), Basis())
	for i in 25:   # ребра на ламарината
		_mi(node, _box(Vector3(W + 0.04, H - 0.3, 0.05)), wall, Vector3(0, H / 2 + 0.15, -L / 2 + 0.3 + i * 0.225), Basis())
	for z in [-L / 2, L / 2]:
		_mi(node, _box(Vector3(W + 0.1, 0.15, 0.12)), trim, Vector3(0, 0.1, z), Basis())
		_mi(node, _box(Vector3(W + 0.1, 0.15, 0.12)), trim, Vector3(0, H + 0.2, z), Basis())
	_mi(node, _box(Vector3(W + 0.1, 0.12, L + 0.1)), trim, Vector3(0, H + 0.2, 0), Basis())
	for z in [-1.5, 1.2]:
		_mi(node, _box(Vector3(0.05, 0.9, 1.1)), glass, Vector3(W / 2 + 0.03, 1.8, z), Basis())
		_mi(node, _box(Vector3(0.07, 1.0, 1.2)), trim, Vector3(W / 2 + 0.02, 1.8, z), Basis())
	_mi(node, _box(Vector3(0.05, 2.0, 0.9)), trim, Vector3(W / 2 + 0.03, 1.2, -0.1), Basis())   # врата
	_mi(node, _box(Vector3(0.9, 0.05, 0.9)), dark, Vector3(W / 2 + 0.5, 0.2, -0.1), Basis())     # стъпало
	_collider(node, Vector3(W + 0.2, H + 0.3, L + 0.2), Vector3(0, H / 2 + 0.15, 0))


# --- палет с тухли ---

func _pallet(p: Vector3, rot: float) -> void:
	var wood := _paint(Color(0.55, 0.42, 0.27), 0.85, 0.0, 0.5, 0.6)
	var brick := _paint(Color(0.55, 0.22, 0.13), 0.9, 0.0, 0.45, 0.6)
	brick.set_shader_parameter("scale", 3.0)
	var node := Node3D.new()
	node.position = _y(p)
	node.rotation.y = rot
	add_child(node)
	for x in [-0.5, 0.0, 0.5]:
		_mi(node, _box(Vector3(0.1, 0.1, 1.2)), wood, Vector3(x, 0.05, 0), Basis())
	for z in range(-5, 6, 2):
		_mi(node, _box(Vector3(1.2, 0.025, 0.09)), wood, Vector3(0, 0.113, z * 0.11), Basis())
	for layer in 6:
		for row in 4:
			for col in 3:
				var off := 0.02 if (layer + row) % 2 == 0 else -0.02
				_mi(node, _box(Vector3(0.24, 0.07, 0.36)), brick,
					Vector3(-0.38 + col * 0.38 + off, 0.165 + layer * 0.075, -0.4 + row * 0.27), Basis())
	Kit.merge_children(node)
	_collider(node, Vector3(1.2, 0.65, 1.2), Vector3(0, 0.33, 0))


# --- общи ---

func _mi(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, basis: Basis, scale := 1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = Transform3D(basis * Basis.from_scale(Vector3.ONE * scale), pos)
	parent.add_child(mi)
	return mi


func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


func _collider(parent: Node3D, size: Vector3, pos: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.position = pos
	body.add_child(cs)
	parent.add_child(body)
