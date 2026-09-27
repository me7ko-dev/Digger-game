extends Node3D
## Земя, която се копае: решетка от височини (heightmap). Центърът на решетката е в позицията на възела.
## carve() сваля земята (кофата гребе), deposit() добавя пръст (изсипана), а свличането поддържа
## естествен наклон (repose). Изкопаните/насипани места са по-тъмни (цвят на върховете: r = 0).
## Мешът и сблъсъкът (HeightMapShape3D) са на парчета (CHUNK клетки); обновяват се само променените.
## Вътрешно височините са в „клетки“ (метри / cell), за да съвпаднат със сблъсъка без мащабиране по Y.

const CHUNK := 32

@export var cells_x := 192
@export var cells_z := 192
@export var cell := 0.25
@export var repose := 0.8          ## най-голям наклон (височина / разстояние), преди пръстта да се свлече
@export var min_height := -3.0     ## по-надолу е скала
@export var closed := false        ## пръстта не излиза през краищата (коша на камиона)
@export var with_collision := true
@export var hide_empty := false    ## клетки с нулева височина се скриват под пода (коша)
@export var fixed_border := 2      ## колко клетки по края не се пипат (за да се слее с околната земя)

var material: Material
var nx: int
var nz: int
var _h: PackedFloat32Array        ## височини в клетки
var _dug: PackedFloat32Array      ## 0..1 колко е разровено (за цвета)
var _chunks := {}                 ## Vector2i -> MeshInstance3D
var _dirty := {}                  ## Vector2i -> true
var _active := Rect2i()           ## област, в която пръстта още се свлича
var _shapes := {}                 ## Vector2i -> HeightMapShape3D
var _shape_dirty := {}            ## Vector2i -> true
var _shape_timer := 0.0


func setup(height_func: Callable = Callable()) -> void:
	nx = cells_x + 1
	nz = cells_z + 1
	_h.resize(nx * nz)
	_dug.resize(nx * nz)
	for j in nz:
		for i in nx:
			var h := 0.0
			if height_func.is_valid():
				h = height_func.call(global_position + _local(i, j))
			_h[j * nx + i] = h / cell
	for cz in ceili(float(cells_z) / CHUNK):
		for cx in ceili(float(cells_x) / CHUNK):
			var mi := MeshInstance3D.new()
			mi.material_override = material
			add_child(mi)
			_chunks[Vector2i(cx, cz)] = mi
			_dirty[Vector2i(cx, cz)] = true
	if with_collision:
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		add_child(body)
		for c in _chunks:
			var w := mini(CHUNK, cells_x - c.x * CHUNK) + 1
			var d := mini(CHUNK, cells_z - c.y * CHUNK) + 1
			var shape := HeightMapShape3D.new()
			shape.map_width = w
			shape.map_depth = d
			var cs := CollisionShape3D.new()
			cs.shape = shape
			cs.scale = Vector3.ONE * cell
			cs.position = _local(c.x * CHUNK, c.y * CHUNK) + Vector3((w - 1) * cell / 2.0, 0, (d - 1) * cell / 2.0)
			body.add_child(cs)
			_shapes[c] = shape
			_update_shape(c)
	while not _dirty.is_empty():
		_rebuild_some(100)


## Височина на земята в световна точка (метри). Извън решетката: 0 (или NAN при closed).
func height_at(p: Vector3) -> float:
	var l := p - global_position
	var fx := l.x / cell + cells_x / 2.0
	var fz := l.z / cell + cells_z / 2.0
	if fx < 0.0 or fz < 0.0 or fx > cells_x or fz > cells_z:
		return NAN if closed else 0.0
	var i := mini(int(fx), cells_x - 1)
	var j := mini(int(fz), cells_z - 1)
	var tx := fx - i
	var tz := fz - j
	var a := lerpf(_h[j * nx + i], _h[j * nx + i + 1], tx)
	var b := lerpf(_h[(j + 1) * nx + i], _h[(j + 1) * nx + i + 1], tx)
	return global_position.y + lerpf(a, b, tz) * cell


func contains(p: Vector3) -> bool:
	var l := p - global_position
	return absf(l.x) < cells_x * cell / 2.0 and absf(l.z) < cells_z * cell / 2.0


## Общ обем на пръстта над нулата (м³).
func total_volume() -> float:
	var s := 0.0
	for v in _h:
		s += maxf(v, 0.0)
	return s * cell * cell * cell


## Сваля земята до височината на p.y в кръг с радиус r. Връща махнатия обем (м³), не повече от max_volume.
func carve(p: Vector3, r: float, max_volume: float) -> float:
	if max_volume <= 0.0:
		return 0.0
	var target := maxf(p.y - global_position.y, min_height) / cell
	var cells := _cells_in(p, r)
	var total := 0.0
	for k in cells:
		total += maxf(0.0, _h[k] - target)
	var vol := total * cell * cell * cell
	if vol <= 0.0:
		return 0.0
	var f := minf(1.0, max_volume / vol)
	for k in cells:
		if _h[k] > target:
			_h[k] -= (_h[k] - target) * f
			_dug[k] = 1.0
	for k in _cells_in(p, r + 0.35):   # мек преход на цвета около изкопа
		_dug[k] = maxf(_dug[k], 0.45)
	_touch(p, r + 0.35)
	return vol * f


## Добавя обем пръст (м³) около p в кръг с радиус r (повече в средата).
func deposit(p: Vector3, volume: float, r := 0.3) -> void:
	var cells := _cells_in(p, r)
	if cells.is_empty():
		return
	var l := p - global_position
	var weights: Array[float] = []
	var sum := 0.0
	for k in cells:
		var i := k % nx
		var j := k / nx
		var d := Vector2(_local(i, j).x - l.x, _local(i, j).z - l.z).length()
		var w := maxf(0.05, 1.0 - d / r)
		weights.append(w)
		sum += w
	var dh := volume / (cell * cell * cell)
	for n in cells.size():
		var k: int = cells[n]
		_h[k] += dh * weights[n] / sum
		_dug[k] = maxf(_dug[k], 0.85)
	_touch(p, r)


func _physics_process(dt: float) -> void:
	if _active.size != Vector2i.ZERO:
		_relax()
	_rebuild_some(3)
	if not _shape_dirty.is_empty():
		_shape_timer -= dt
		if _shape_timer <= 0.0:
			for c in _shape_dirty:
				_update_shape(c)
			_shape_dirty.clear()
			_shape_timer = 0.15


# --- вътрешни ---

func _local(i: int, j: int) -> Vector3:
	return Vector3((i - cells_x / 2.0) * cell, 0.0, (j - cells_z / 2.0) * cell)


func _cells_in(p: Vector3, r: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var l := p - global_position
	var ci := l.x / cell + cells_x / 2.0
	var cj := l.z / cell + cells_z / 2.0
	var rr := r / cell
	var b := 0 if closed else fixed_border
	for j in range(maxi(b, floori(cj - rr)), mini(nz - b, ceili(cj + rr) + 1)):
		for i in range(maxi(b, floori(ci - rr)), mini(nx - b, ceili(ci + rr) + 1)):
			if Vector2(i - ci, j - cj).length() <= rr:
				out.append(j * nx + i)
	return out


func _touch(p: Vector3, r: float) -> void:
	var l := p - global_position
	var ci := int(l.x / cell + cells_x / 2.0)
	var cj := int(l.z / cell + cells_z / 2.0)
	var rr := ceili(r / cell) + 2
	var rect := Rect2i(ci - rr, cj - rr, rr * 2 + 1, rr * 2 + 1)
	_active = rect if _active.size == Vector2i.ZERO else _active.merge(rect)
	_active = _active.intersection(Rect2i(0, 0, nx, nz))
	_mark_dirty(rect)


func _mark_dirty(rect: Rect2i) -> void:
	for cz in range(maxi(0, (rect.position.y - 1) / CHUNK), mini(ceili(float(cells_z) / CHUNK), (rect.end.y + 1) / CHUNK + 1)):
		for cx in range(maxi(0, (rect.position.x - 1) / CHUNK), mini(ceili(float(cells_x) / CHUNK), (rect.end.x + 1) / CHUNK + 1)):
			_dirty[Vector2i(cx, cz)] = true
			if _shapes.has(Vector2i(cx, cz)):
				_shape_dirty[Vector2i(cx, cz)] = true


## Една стъпка свличане: пръстта тече от по-високата към по-ниската клетка, ако наклонът е по-голям от repose.
func _relax() -> void:
	var max_d := repose        # в клетки: височина/разстояние * cell / cell
	var b := 0 if closed else fixed_border
	var x0 := maxi(b, _active.position.x)
	var z0 := maxi(b, _active.position.y)
	var x1 := mini(nx - b, _active.end.x)
	var z1 := mini(nz - b, _active.end.y)
	var changed := Rect2i()
	var any := false
	for j in range(z0, z1):
		for i in range(x0, x1):
			var k := j * nx + i
			var hk := _h[k]
			for o in 4:
				var ni := i + (1 if o == 0 else (-1 if o == 1 else 0))
				var nj := j + (1 if o == 2 else (-1 if o == 3 else 0))
				if ni < b or nj < b or ni >= nx - b or nj >= nz - b:
					continue
				var kn := nj * nx + ni
				var diff := hk - _h[kn]
				if diff > max_d + 0.01:
					var move := (diff - max_d) * 0.4
					hk -= move
					_h[kn] += move
					_dug[kn] = maxf(_dug[kn], _dug[k] * 0.9)
					var r := Rect2i(mini(i, ni), mini(j, nj), 2, 2)
					changed = r if not any else changed.merge(r)
					any = true
			_h[k] = hk
	if any:
		changed = changed.grow(1).intersection(Rect2i(0, 0, nx, nz))
		_active = changed
		_mark_dirty(changed)
	else:
		_active = Rect2i()


func _update_shape(c: Vector2i) -> void:
	var shape: HeightMapShape3D = _shapes[c]
	var data := PackedFloat32Array()
	data.resize(shape.map_width * shape.map_depth)
	var n := 0
	for j in range(c.y * CHUNK, c.y * CHUNK + shape.map_depth):
		for i in range(c.x * CHUNK, c.x * CHUNK + shape.map_width):
			data[n] = _h[j * nx + i]
			n += 1
	shape.map_data = data


func _rebuild_some(count: int) -> void:
	var keys := _dirty.keys()
	for n in mini(count, keys.size()):
		var c: Vector2i = keys[n]
		_dirty.erase(c)
		_build_chunk(c)


func _build_chunk(c: Vector2i) -> void:
	var i0 := c.x * CHUNK
	var j0 := c.y * CHUNK
	var w := mini(CHUNK, cells_x - i0) + 1
	var d := mini(CHUNK, cells_z - j0) + 1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	verts.resize(w * d)
	norms.resize(w * d)
	cols.resize(w * d)
	uvs.resize(w * d)
	var n := 0
	for j in range(j0, j0 + d):
		for i in range(i0, i0 + w):
			var k := j * nx + i
			var hk := _h[k]
			var p := _local(i, j)
			p.y = hk * cell
			if hide_empty and hk * cell < 0.005:
				p.y = -0.06
			verts[n] = p
			var hl := _h[k - 1] if i > 0 else hk
			var hr := _h[k + 1] if i < nx - 1 else hk
			var hd := _h[k - nx] if j > 0 else hk
			var hu := _h[k + nx] if j < nz - 1 else hk
			norms[n] = Vector3(hl - hr, 2.0, hd - hu).normalized()
			cols[n] = Color(1.0 - _dug[k], 1, 1)
			uvs[n] = Vector2(p.x, p.z)
			n += 1
	var idx := PackedInt32Array()
	idx.resize((w - 1) * (d - 1) * 6)
	n = 0
	for j in d - 1:
		for i in w - 1:
			var a := j * w + i
			idx[n] = a
			idx[n + 1] = a + 1
			idx[n + 2] = a + w
			idx[n + 3] = a + 1
			idx[n + 4] = a + w + 1
			idx[n + 5] = a + w
			n += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_chunks[c].mesh = mesh
