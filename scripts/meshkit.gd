extends RefCounted
## Помощни функции за меши от код: изтеглен профил (стрела, кофа, кабина), завъртян профил (гуми, конуси),
## многоъгълници с фаски и сливане на много меши в един (по-малко draw calls).

const SMOOTH_ANGLE := 0.82  ## cos на ъгъла, под който ръбовете се изглаждат (~35°)


## Профил в равнината (z, y), изтеглен по X от -width/2 до width/2.
static func extrude_x(poly: PackedVector2Array, width: float) -> ArrayMesh:
	return _extrude(poly, width, func(a: Vector2, t: float) -> Vector3: return Vector3(t, a.y, a.x), Vector3.RIGHT)


## Профил в равнината (x, z), изтеглен нагоре по Y от 0 до height.
static func extrude_y(poly: PackedVector2Array, height: float) -> ArrayMesh:
	return _extrude(poly, height, func(a: Vector2, t: float) -> Vector3: return Vector3(a.x, t + height / 2.0, a.y), Vector3.UP)


## Профил Vector2(радиус, x), завъртян около оста X (гуми, джанти, ролки). UV: u по обиколката, v по профила.
static func lathe(profile: PackedVector2Array, segments: int, v_from := 0.0, v_to := 1.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var total := 0.0
	var lens: Array[float] = [0.0]
	for i in range(1, profile.size()):
		total += profile[i].distance_to(profile[i - 1])
		lens.append(total)
	for s in segments:
		var a0 := TAU * s / segments
		var a1 := TAU * (s + 1) / segments
		for i in profile.size() - 1:
			var p0 := profile[i]
			var p1 := profile[i + 1]
			var q := [_rev(p0, a0), _rev(p1, a0), _rev(p1, a1), _rev(p0, a1)]
			var v0 := lerpf(v_from, v_to, lens[i] / total)
			var v1 := lerpf(v_from, v_to, lens[i + 1] / total)
			var uv := [Vector2(float(s) / segments, v0), Vector2(float(s) / segments, v1),
				Vector2(float(s + 1) / segments, v1), Vector2(float(s + 1) / segments, v0)]
			# нормала от профила (изгладена по обиколката)
			var d := p1 - p0
			var n2 := Vector2(d.y, -d.x).normalized()   # навън, ако профилът върви от -x към +x по външната страна
			var ns := [_rev_n(n2, a0), _rev_n(n2, a0), _rev_n(n2, a1), _rev_n(n2, a1)]
			_quad(st, q, ns, uv)
	st.index()   # с индекси, за да се слива с кутиите и цилиндрите на Godot
	st.generate_tangents()
	return st.commit()


static func _rev(p: Vector2, a: float) -> Vector3:
	return Vector3(p.y, p.x * cos(a), p.x * sin(a))


static func _rev_n(n: Vector2, a: float) -> Vector3:
	return Vector3(n.y, n.x * cos(a), n.x * sin(a)).normalized()


## Правоъгълник с отрязани ъгли, центриран.
static func chamfer_rect(w: float, h: float, c: float) -> PackedVector2Array:
	var x := w / 2.0
	var y := h / 2.0
	return PackedVector2Array([
		Vector2(-x + c, -y), Vector2(x - c, -y), Vector2(x, -y + c), Vector2(x, y - c),
		Vector2(x - c, y), Vector2(-x + c, y), Vector2(-x, y - c), Vector2(-x, -y + c)])


static func rounded_rect(w: float, h: float, r: float, seg := 4) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var cx := w / 2.0 - r
	var cy := h / 2.0 - r
	for corner in [[cx, cy, 0.0], [-cx, cy, PI / 2], [-cx, -cy, PI], [cx, -cy, PI * 1.5]]:
		for i in seg + 1:
			var a: float = corner[2] + PI / 2 * i / seg
			pts.append(Vector2(corner[0] + cos(a) * r, corner[1] + sin(a) * r))
	return pts


static func arc(center: Vector2, r: float, a0: float, a1: float, seg: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in seg + 1:
		var a := lerpf(a0, a1, float(i) / seg)
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	return pts


## Затворен многоъгълник около начупена линия с различна дебелина (half[i]) във всяка точка.
## Краищата са заоблени (за стрелата и рамото около болтовете).
static func thick_line(pts: PackedVector2Array, half: PackedFloat32Array, round_ends := true) -> PackedVector2Array:
	var top := PackedVector2Array()
	var bottom := PackedVector2Array()
	var count := pts.size()
	for i in count:
		var d := Vector2.ZERO
		if i > 0:
			d += (pts[i] - pts[i - 1]).normalized()
		if i < count - 1:
			d += (pts[i + 1] - pts[i]).normalized()
		d = d.normalized()
		var n := Vector2(-d.y, d.x)
		top.append(pts[i] + n * half[i])
		bottom.append(pts[i] - n * half[i])
	var poly := PackedVector2Array()
	if round_ends:
		var d0 := (pts[1] - pts[0]).normalized()
		var a0 := atan2(d0.y, d0.x)
		poly.append_array(arc(pts[0], half[0], a0 - PI / 2, a0 - PI * 1.5, 8))
	else:
		poly.append(bottom[0])
	poly.append_array(top)
	if round_ends:
		var d1 := (pts[count - 1] - pts[count - 2]).normalized()
		var a1 := atan2(d1.y, d1.x)
		poly.append_array(arc(pts[count - 1], half[count - 1], a1 + PI / 2, a1 - PI / 2, 8))
	else:
		poly.append(top[count - 1])
	bottom.reverse()
	poly.append_array(bottom)
	return _dedupe(poly)


## Слива всички MeshInstance3D деца на parent с еднакъв материал в по-малко меши.
static func merge_children(parent: Node3D) -> void:
	var groups := {}
	for c in parent.get_children():
		if c is MeshInstance3D and c.get_child_count() == 0 and c.material_override != null:
			var mat: Material = c.material_override
			if not groups.has(mat):
				groups[mat] = []
			groups[mat].append(c)
	for mat in groups:
		var list: Array = groups[mat]
		if list.size() < 2:
			continue
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for mi in list:
			for s in mi.mesh.get_surface_count():
				st.append_from(mi.mesh, s, mi.transform)
		var merged := MeshInstance3D.new()
		merged.mesh = st.commit()
		merged.material_override = mat
		parent.add_child(merged)
		for mi in list:
			parent.remove_child(mi)
			mi.queue_free()


# --- вътрешни ---

static func _extrude(poly: PackedVector2Array, depth: float, map: Callable, axis: Vector3) -> ArrayMesh:
	poly = _dedupe(poly)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := poly.size()
	var h := depth / 2.0
	# капаци
	var tris := Geometry2D.triangulate_polygon(poly)
	for side in [-1.0, 1.0]:
		var nrm: Vector3 = axis * side
		for i in range(0, tris.size(), 3):
			var a: Vector3 = map.call(poly[tris[i]], side * h)
			var b: Vector3 = map.call(poly[tris[i + 1]], side * h)
			var c: Vector3 = map.call(poly[tris[i + 2]], side * h)
			_tri(st, [a, b, c], [nrm, nrm, nrm], [poly[tris[i]], poly[tris[i + 1]], poly[tris[i + 2]]])
	# стени: нормалите навън; гладки там, където ъгълът е малък
	var ccw := _area(poly) > 0.0
	var edge_n: Array[Vector3] = []
	var origin: Vector3 = map.call(Vector2.ZERO, 0.0)
	for i in n:
		var e2 := (poly[(i + 1) % n] - poly[i]).normalized()
		var o2 := Vector2(e2.y, -e2.x) if ccw else Vector2(-e2.y, e2.x)
		edge_n.append((map.call(o2, 0.0) - origin).normalized())
	var along := 0.0
	for i in n:
		var j := (i + 1) % n
		var ni := edge_n[i]
		var n_start := ni
		var n_end := ni
		var prev := edge_n[(i - 1 + n) % n]
		var next := edge_n[j]
		if prev.dot(ni) > SMOOTH_ANGLE:
			n_start = (prev + ni).normalized()
		if next.dot(ni) > SMOOTH_ANGLE:
			n_end = (next + ni).normalized()
		var len := poly[i].distance_to(poly[j])
		var q := [map.call(poly[i], -h), map.call(poly[j], -h), map.call(poly[j], h), map.call(poly[i], h)]
		var uv := [Vector2(along, 0), Vector2(along + len, 0), Vector2(along + len, depth), Vector2(along, depth)]
		_quad_outward(st, q, [n_start, n_end, n_end, n_start], uv, ni)
		along += len
	st.index()   # с индекси, за да се слива с кутиите и цилиндрите на Godot
	st.generate_tangents()
	return st.commit()


static func _quad(st: SurfaceTool, q: Array, ns: Array, uv: Array) -> void:
	var face: Vector3 = (q[1] - q[0]).cross(q[2] - q[0])
	var want: Vector3 = ns[0] + ns[1] + ns[2] + ns[3]
	_quad_outward(st, q, ns, uv, want if want.length() > 0.0001 else face)


static func _quad_outward(st: SurfaceTool, q: Array, ns: Array, uv: Array, out: Vector3) -> void:
	_tri(st, [q[0], q[1], q[2]], [ns[0], ns[1], ns[2]], [uv[0], uv[1], uv[2]], out)
	_tri(st, [q[0], q[2], q[3]], [ns[0], ns[2], ns[3]], [uv[0], uv[2], uv[3]], out)


## Добавя триъгълник, подреден така, че лицето да гледа към out (Godot: по часовника = лице).
static func _tri(st: SurfaceTool, p: Array, ns: Array, uv: Array, out := Vector3.ZERO) -> void:
	if out == Vector3.ZERO:
		out = ns[0]
	var order := [0, 1, 2]
	if (p[1] - p[0]).cross(p[2] - p[0]).dot(out) > 0.0:
		order = [0, 2, 1]
	for k in order:
		st.set_normal(ns[k])
		st.set_uv(uv[k])
		st.add_vertex(p[k])


static func _area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return a / 2.0


static func _dedupe(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in poly:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 0.001:
			out.append(p)
	if out.size() > 2 and out[0].distance_to(out[out.size() - 1]) < 0.001:
		out.remove_at(out.size() - 1)
	return out
