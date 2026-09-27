extends Camera3D
## Камера, която следи кабината на багера. Два изгледа (V): зад кабината и отстрани (за дълбочината на кофата).

@export var distance := 8.0
@export var height := 6.5
@export var side_offset := 2.0    ## вляво от стрелата, за да не скрива кофата
@export var look_ahead := 6.5     ## гледа към точка пред кабината
@export var side_distance := 13.0
@export var turn_smoothing := 3.0

var target: Node3D   ## багерът
var side_view := false
var _yaw := 0.0


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF  # местим я сами всеки кадър
	fov = 62.0


func toggle_view() -> void:
	side_view = not side_view


func snap() -> void:
	if target:
		_yaw = _turret_yaw()
		_place(1.0)


func _process(delta: float) -> void:
	if target == null:
		return
	var want := _turret_yaw()
	_yaw += angle_difference(_yaw, want) * (1.0 - exp(-turn_smoothing * delta))
	_place(1.0 - exp(-8.0 * delta))


func _turret_yaw() -> float:
	var t: Transform3D = target.turret.get_global_transform_interpolated()
	var f := -t.basis.z
	return atan2(-f.x, -f.z)


func _place(k: float) -> void:
	var origin: Vector3 = target.get_global_transform_interpolated().origin
	var fwd := Vector3(-sin(_yaw), 0, -cos(_yaw))
	var left := Vector3(fwd.z, 0, -fwd.x)
	var focus := origin + fwd * look_ahead + Vector3.UP * 0.8
	var pos: Vector3
	if side_view:
		focus = origin + fwd * 5.0 + Vector3.UP * 2.0
		pos = focus + left * side_distance + Vector3.UP * 2.0
	else:
		pos = origin - fwd * distance + left * side_offset + Vector3.UP * height
	global_position = global_position.lerp(pos, k)
	look_at(focus)
