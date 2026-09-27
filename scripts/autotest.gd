extends Node
## Автоматичен тест: пуска се с `-- --autotest`.
## Багерът сам гребе от купчината, завърта се към камиона и изсипва, докато камионът се напълни.
## Накрая пише RESULT: PASS/FAIL. Снимките са в _autotest/ (само ако има екран).

const MAX_CYCLES := 9

## Позите за един цикъл: [име, цели за ставите, време (s), трябва ли да се стигне точно]
## Кофата опира в купчината при спускане и гребане, затова там позата не се стига докрай.
const CYCLE := [
	["ready", {"swing": 0.0, "boom": 0.8, "stick": -1.0, "bucket": 0.2}, 8.0, true],
	["lower", {"swing": 0.0, "boom": 0.15, "stick": -1.1, "bucket": 0.2}, 3.0, false],
	["drag", {"swing": 0.0, "boom": 0.1, "stick": -2.0, "bucket": -1.0}, 3.5, false],
	["curl", {"swing": 0.0, "boom": 0.6, "stick": -2.0, "bucket": -2.1}, 4.0, false],
	["lift", {"swing": 0.0, "boom": 0.9, "stick": -1.3, "bucket": -2.1}, 8.0, true],
	["swing", {"swing": -PI / 2, "boom": 0.9, "stick": -1.3, "bucket": -2.1}, 8.0, true],
	["dump", {"swing": -PI / 2, "boom": 0.9, "stick": -1.1, "bucket": 0.7}, 8.0, true],
	["back", {"swing": 0.0, "boom": 0.9, "stick": -1.3, "bucket": 0.2}, 8.0, true],
]

var main: Node3D
var ex: CharacterBody3D
var _shots := false
var _dig_spot := Vector3.ZERO
var _dig_start := 0.0
var _worst_physics := 0.0
var _frames := 0
var _sum_ms := 0.0
var _slow := 0


func _ready() -> void:
	main = get_parent()
	ex = main.excavator
	_shots = DisplayServer.get_name() != "headless"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_autotest"))
	_run()


func _run() -> void:
	var ok := true
	await _wait(1.0)
	_dig_spot = Vector3(0, 0, -7.3)
	_dig_start = main.terrain.height_at(_dig_spot)
	await _shot("00_start")
	await _closeups("0")
	for cycle in MAX_CYCLES:
		for step in CYCLE:
			if cycle == 0 and step[0] == "dump" and _shots:
				ex.auto = step[1].duplicate()
				await _wait(1.7)
				await _look_at_bucket("01_pouring", Vector3(3.5, 2.5, 3.5))
			var reached := await _pose(step[1], step[2])
			if not reached and step[3]:
				print("  цикъл %d: '%s' не стигна позата (стрела %.2f рамо %.2f кофа %.2f)" % [cycle + 1, step[0], ex.boom.rotation.x, ex.stick.rotation.x, ex.bucket.rotation.x])
			if step[0] == "lower":
				var t: Vector3 = ex.tip.global_position
				print("  цикъл %d: върхът на кофата %s, земята там %.2f" % [cycle + 1, t, main.terrain.height_at(t)])
			if step[0] == "curl":
				print("  цикъл %d: кофата е пълна %.0f%%" % [cycle + 1, ex.fill * 100])
				if ex.fill < 0.9:
					ok = false
				if cycle == 0:
					await _look_at_bucket("01_bucket_full", Vector3(-3.0, 1.2, 2.2))
			if cycle == 0:
				await _shot("01_%s" % step[0])
			if step[0] == "dump":
				await _wait(1.5)
				if cycle == 0:
					await _shot("02_after_dump")
		print("  цикъл %d: в камиона %.2f/%.2f м³" % [cycle + 1, main.truck_amount(), main.truck_goal])
		if main.done:
			break
	await _wait(2.0)
	await _shot("03_end")
	# изглед отстрани
	main.cam.toggle_view()
	await _wait(1.5)
	print("  багер %s, камера %s" % [ex.global_position, main.cam.global_position])
	await _shot("04_side")
	main.cam.toggle_view()

	await _closeups("9")
	if main.terrain.height_at(_dig_spot) > _dig_start - 0.3:
		print("  купчината не е изкопана")
		ok = false

	# кара напред и назад
	var start := ex.global_position
	ex.auto = {"drive": -1.0}
	await _wait(2.0)
	ex.auto = {"drive": 0.0, "turn": 1.0}
	await _wait(2.0)
	ex.auto = {}
	var moved := start.distance_to(ex.global_position)
	print("  кара: премина %.1f м, завъртя се до %.0f°" % [moved, rad_to_deg(ex.rotation.y)])
	if moved < 2.0:
		ok = false

	if not main.done:
		ok = false
	print("камион: %.2f/%.2f м³, купчината сега %.2f м (беше %.2f)" % [main.truck_amount(), main.truck_goal, main.terrain.height_at(_dig_spot), _dig_start])
	print("физика: средно %.2f ms, най-бавно %.1f ms, над 8 ms: %d от %d кадъра" % [_sum_ms / maxi(1, _frames), _worst_physics, _slow, _frames])
	print("RESULT: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit()


func _pose(targets: Dictionary, timeout: float) -> bool:
	ex.auto = targets.duplicate()
	var t := 0.0
	while t < timeout:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		var ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		_worst_physics = maxf(_worst_physics, ms)
		_frames += 1
		_sum_ms += ms
		if ms > 8.0:
			_slow += 1
		var err := absf(angle_difference(ex.turret.rotation.y, targets.swing))
		err = maxf(err, absf(ex.boom.rotation.x - targets.boom))
		err = maxf(err, absf(ex.stick.rotation.x - targets.stick))
		err = maxf(err, absf(ex.bucket.rotation.x - targets.bucket))
		if err < 0.03:
			return true
	return false


## Снимки отблизо: камерата се мести ръчно.
func _closeups(prefix: String) -> void:
	if not _shots:
		return
	var cam: Camera3D = main.cam
	var target: Node3D = cam.target
	cam.target = null
	for view in [["excavator", Vector3(-5.5, 3.2, 4.5), Vector3(0, 1.6, -1.0)],
			["truck", Vector3(1.5, 2.6, -7.5), Vector3(6.8, 1.6, -1.0)],
			["hole", Vector3(-4.5, 5.0, -3.5), Vector3(0, 0.5, -8.0)]]:
		cam.global_position = view[1]
		cam.look_at(view[2])
		await _wait(0.3)
		await _shot("%s_%s" % [prefix, view[0]])
	cam.target = target
	cam.snap()


## Снимка отблизо на кофата (камерата стои до нея за миг).
func _look_at_bucket(name: String, offset: Vector3) -> void:
	var cam: Camera3D = main.cam
	var target: Node3D = cam.target
	cam.target = null
	var b: Vector3 = ex.bucket.global_position
	cam.global_position = b + offset
	cam.look_at(b + Vector3(0, -0.8, 0))
	await _shot(name)
	cam.target = target


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, true).timeout


func _shot(name: String) -> void:
	if not _shots:
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("res://_autotest/%s.png" % name))
