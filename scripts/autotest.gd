extends Node
## Автоматичен тест: пуска се с `-- --autotest`.
## Багерът сам гребе от купчината, завърта се към камиона и изсипва, докато камионът се напълни.
## Накрая пише RESULT: PASS/FAIL. Снимките са в _autotest/ (само ако има екран).

const MAX_CYCLES := 8
const STEP_TIMEOUT := 8.0

## Позите за един цикъл: [име, цели за ставите]
const CYCLE := [
	["ready", {"swing": 0.0, "boom": 0.35, "stick": -1.2, "bucket": 0.4}],
	["lower", {"swing": 0.0, "boom": 0.3, "stick": -1.35, "bucket": 0.4}],
	["drag", {"swing": 0.0, "boom": 0.3, "stick": -1.9, "bucket": -0.9}],
	["curl", {"swing": 0.0, "boom": 0.5, "stick": -2.0, "bucket": -2.1}],
	["lift", {"swing": 0.0, "boom": 0.85, "stick": -1.3, "bucket": -2.1}],
	["swing", {"swing": -PI / 2, "boom": 0.85, "stick": -1.3, "bucket": -2.1}],
	["dump", {"swing": -PI / 2, "boom": 0.85, "stick": -1.1, "bucket": 0.7}],
	["back", {"swing": 0.0, "boom": 0.85, "stick": -1.3, "bucket": 0.4}],
]

var main: Node3D
var ex: CharacterBody3D
var _shots := false


func _ready() -> void:
	main = get_parent()
	ex = main.excavator
	_shots = DisplayServer.get_name() != "headless"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_autotest"))
	_run()


func _run() -> void:
	var ok := true
	await _wait(1.0)
	_shot("00_start")
	for cycle in MAX_CYCLES:
		for step in CYCLE:
			var reached := await _pose(step[1])
			if not reached:
				print("  цикъл %d: '%s' не стигна позата (стрела %.2f рамо %.2f кофа %.2f)" % [cycle + 1, step[0], ex.boom.rotation.x, ex.stick.rotation.x, ex.bucket.rotation.x])
			if step[0] == "lower":
				var t: Vector3 = ex.tip.global_position
				print("  цикъл %d: върхът на кофата %s, пясък там %.2f" % [cycle + 1, t, main.heap_height_at(t)])
			if step[0] == "curl":
				print("  цикъл %d: кофата е пълна %.0f%%" % [cycle + 1, ex.fill * 100])
				if ex.fill < 0.9:
					ok = false
			if cycle == 0:
				_shot("01_%s" % step[0])
			if step[0] == "dump":
				await _wait(1.5)
				if cycle == 0:
					_shot("02_after_dump")
		print("  цикъл %d: в камиона %d/%d" % [cycle + 1, main.truck_amount(), main.truck_goal])
		if main.done:
			break
	await _wait(2.0)
	_shot("03_end")
	# изглед отстрани
	main.cam.toggle_view()
	await _wait(1.5)
	print("  багер %s, камера %s" % [ex.global_position, main.cam.global_position])
	_shot("04_side")
	main.cam.toggle_view()

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
	print("камион: %d/%d" % [main.truck_amount(), main.truck_goal])
	print("RESULT: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit()


func _pose(targets: Dictionary) -> bool:
	ex.auto = targets.duplicate()
	var t := 0.0
	while t < STEP_TIMEOUT:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		var err := absf(angle_difference(ex.turret.rotation.y, targets.swing))
		err = maxf(err, absf(ex.boom.rotation.x - targets.boom))
		err = maxf(err, absf(ex.stick.rotation.x - targets.stick))
		err = maxf(err, absf(ex.bucket.rotation.x - targets.bucket))
		if err < 0.03:
			return true
	return false


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, true).timeout


func _shot(name: String) -> void:
	if not _shots:
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("res://_autotest/%s.png" % name))
