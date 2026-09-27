extends CanvasLayer
## Камион (колко е пълен), кофа, съобщения и тъч бутони (показват се само на тъч екран).

const BTN := 110.0
const MARGIN := 24.0
const GAP := 12.0

var force_touch := false  ## Показва тъч бутоните и на PC (за тест).

var _truck: Label
var _bucket: Label
var _fps: Label
var _message: Label
var _buttons := {}
var _tween: Tween


func _ready() -> void:
	_truck = _label("", 34)
	_truck.anchor_left = 1.0
	_truck.anchor_right = 1.0
	_truck.offset_left = -420.0
	_truck.offset_right = -24.0
	_truck.offset_top = 12.0
	add_child(_truck)
	_bucket = _label("", 22)
	_bucket.anchor_left = 1.0
	_bucket.anchor_right = 1.0
	_bucket.offset_left = -420.0
	_bucket.offset_right = -24.0
	_bucket.offset_top = 58.0
	add_child(_bucket)
	_fps = _centered(_label("", 16), 8.0)
	_message = _centered(_label("", 44), 90.0)

	if not (force_touch or DisplayServer.is_touchscreen_available()):
		var hint := _label("W/S/A/D: вериги   стрелки наляво/надясно: кабина   нагоре/надолу: стрела\nQ/E: рамо навън/навътре   Z: кофата гребе   X: кофата изсипва   V: камера   R: отначало", 16)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		hint.position = Vector2(16, 12)
		add_child(hint)
		return  # на PC няма тъч бутони

	var tex := _square_texture(0.22)
	var tex_pressed := _square_texture(0.5)
	for def in [
		["drive_fwd", "напред"], ["drive_back", "назад"], ["turn_left", "завой\nляво"], ["turn_right", "завой\nдясно"],
		["swing_left", "кабина\nналяво"], ["swing_right", "кабина\nнадясно"],
		["boom_up", "стрела\nгоре"], ["boom_down", "стрела\nдолу"],
		["stick_out", "рамо\nнавън"], ["stick_in", "рамо\nнавътре"],
		["bucket_curl", "кофа\nгребе"], ["bucket_dump", "кофа\nизсипва"],
		["restart", "отначало"], ["camera", "камера"],
	]:
		var b := TouchScreenButton.new()
		b.texture_normal = tex
		b.texture_pressed = tex_pressed
		var shape := RectangleShape2D.new()
		shape.size = Vector2(BTN, BTN)
		b.shape = shape
		b.shape_centered = true
		b.action = def[0]
		b.passby_press = true
		b.visibility_mode = TouchScreenButton.VISIBILITY_ALWAYS
		var l := _label(def[1], 22)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.size = Vector2(BTN, BTN)
		b.add_child(l)
		add_child(b)
		_buttons[def[0]] = b
	for small in ["restart", "camera"]:
		_buttons[small].scale = Vector2(0.6, 0.6)
		_buttons[small].get_child(0).add_theme_font_size_override("font_size", 26)

	get_viewport().size_changed.connect(_layout)
	_layout()


## Надпис в горната част. Ако stay е true, остава, докато не се смени.
func show_message(text: String, stay := false) -> void:
	if _tween:
		_tween.kill()
	_message.text = text
	_message.modulate.a = 1.0
	if not stay:
		_tween = create_tween()
		_tween.tween_interval(2.0)
		_tween.tween_property(_message, "modulate:a", 0.0, 0.5)


## part: колко е пълен камионът (0..1)
func set_truck(part: float) -> void:
	_truck.text = "Камион: %d%%" % mini(100, roundi(100.0 * part))


func set_bucket(fill: float) -> void:
	_bucket.text = "Кофа: %d%%" % roundi(fill * 100.0)


func _process(_delta: float) -> void:
	_fps.text = "%d FPS" % Engine.get_frames_per_second()


func _layout() -> void:
	if _buttons.is_empty():
		return
	var vp := get_viewport().get_visible_rect().size
	var s := BTN + GAP
	var bottom := vp.y - MARGIN - BTN
	# вляво: вериги (кръст) и въртене на кабината над тях
	_buttons.drive_fwd.position = Vector2(MARGIN + s, bottom - s)
	_buttons.drive_back.position = Vector2(MARGIN + s, bottom)
	_buttons.turn_left.position = Vector2(MARGIN, bottom)
	_buttons.turn_right.position = Vector2(MARGIN + 2 * s, bottom)
	_buttons.swing_left.position = Vector2(MARGIN, bottom - 2.2 * s)
	_buttons.swing_right.position = Vector2(MARGIN + 2 * s, bottom - 2.2 * s)
	# вдясно: стрела, рамо, кофа (по двойки)
	var right := vp.x - MARGIN - BTN
	for i in 3:
		var pair: Array = [["boom_up", "boom_down"], ["stick_out", "stick_in"], ["bucket_curl", "bucket_dump"]][i]
		_buttons[pair[0]].position = Vector2(right - s, bottom - (2 - i) * s)
		_buttons[pair[1]].position = Vector2(right, bottom - (2 - i) * s)
	_buttons.restart.position = Vector2(MARGIN, MARGIN + 70)
	_buttons.camera.position = Vector2(MARGIN + BTN * 0.6 + GAP, MARGIN + 70)


func _centered(l: Label, top: float) -> Label:
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.anchor_left = 0.5
	l.anchor_right = 0.5
	l.offset_left = -400.0
	l.offset_right = 400.0
	l.offset_top = top
	add_child(l)
	return l


func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	return l


func _square_texture(alpha: float) -> ImageTexture:
	var n := int(BTN)
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, alpha))
	var border := Color(1, 1, 1, minf(1.0, alpha + 0.4))
	img.fill_rect(Rect2i(0, 0, n, 3), border)
	img.fill_rect(Rect2i(0, n - 3, n, 3), border)
	img.fill_rect(Rect2i(0, 0, 3, n), border)
	img.fill_rect(Rect2i(n - 3, 0, 3, n), border)
	return ImageTexture.create_from_image(img)
