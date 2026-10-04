class_name TouchControls
extends Control
## Multi-touch overlay: floating move stick (left), camera drag (empty right side),
## JUMP / LETTER / CAT / ROUTE buttons (right), RUN toggle next to the stick.
## Every touch index keeps the role it started with until it is released or cancelled,
## so a finger that starts on JUMP never turns into a camera finger.
## Touch positions and button areas are both in this viewport's canvas coordinates
## (the same space as Control.get_global_rect()), never in OS/screen pixels.

signal touch_mode_changed(enabled: bool)

const STICK_RADIUS := 120.0
const KNOB_RADIUS := 50.0
const STICK_DEADZONE := 0.12
const CAMERA_SENSITIVITY := 0.0055
const MARGIN := 28.0
const BUTTON_ORDER: Array[StringName] = [&"jump", &"letter", &"cat", &"route", &"run"]
const BUTTON_ACTIONS := {&"letter": &"interact", &"cat": &"switch_cat", &"route": &"sense"}

## Touch UI shown (a touch was seen, or the browser reports a coarse pointer).
var enabled := false
## World sets this: true only while actually playing (not paused / menus).
var gameplay_active := false
var stick_vector := Vector2.ZERO
var jump_held := false
var run_on := false
var player: CatPlayer
## Returns the HUD Buttons that touches may press (Pause, Home, menu buttons...).
var ui_buttons: Callable

var _touches := {}
var _stick_index := -1
var _jump_index := -1
var _stick_origin := Vector2.ZERO
var _stick_home := Vector2.ZERO
var _layout := {}
var _font: Font


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	_font = get_theme_default_font()
	resized.connect(_on_resized)


func set_enabled(on: bool) -> void:
	if enabled == on:
		return
	enabled = on
	if not on:
		reset_touches()
	queue_redraw()
	touch_mode_changed.emit(on)


func _on_resized() -> void:
	reset_touches()
	_compute_layout()
	queue_redraw()


## Forget every tracked finger and release everything they were holding.
## A jump that was being charged is cancelled instead of fired.
func reset_touches() -> void:
	var had_jump := jump_held
	_touches.clear()
	_stick_index = -1
	_jump_index = -1
	stick_vector = Vector2.ZERO
	jump_held = false
	run_on = false
	if had_jump and player:
		player.reset_inputs()
	queue_redraw()


## Browser touchcancel (OS gesture, alert, call...): drop all touches without acting.
func cancel_all() -> void:
	reset_touches()


func get_layout() -> Dictionary:
	_compute_layout()
	var out := {}
	for id in _layout:
		var b: Dictionary = _layout[id]
		out[String(id)] = [b.c.x, b.c.y, b.r]
	out["stick_home"] = [_stick_home.x, _stick_home.y, STICK_RADIUS]
	return out


func _compute_layout() -> void:
	var w := size.x
	var h := size.y
	var jump := Vector2(w - MARGIN - 100.0, h - MARGIN - 100.0)
	_layout = {
		&"jump": {"c": jump, "r": 88.0, "label": "JUMP"},
		&"cat": {"c": jump + Vector2(-182.0, 24.0), "r": 56.0, "label": "CAT"},
		&"letter": {"c": jump + Vector2(-146.0, -132.0), "r": 56.0, "label": "LETTER"},
		&"route": {"c": jump + Vector2(6.0, -192.0), "r": 56.0, "label": "ROUTE"},
		&"run": {"c": Vector2(MARGIN + 345.0, h - MARGIN - 64.0), "r": 54.0, "label": "RUN"},
	}
	_stick_home = Vector2(MARGIN + 155.0, h - MARGIN - 155.0)


func _find_ui_button(p: Vector2) -> Button:
	if not ui_buttons.is_valid():
		return null
	for b: Button in ui_buttons.call():
		if b.is_visible_in_tree() and not b.disabled and b.get_global_rect().has_point(p):
			return b
	return null


func _fire_action(action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_on_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_on_drag(event as InputEventScreenDrag)
	elif enabled and _touches.is_empty():
		# A real keyboard or mouse click means the player switched to PC controls.
		if (event is InputEventKey and event.pressed) or (event is InputEventMouseButton and event.pressed):
			set_enabled(false)


func _on_touch(e: InputEventScreenTouch) -> void:
	var vp := get_viewport()
	if e.pressed:
		if not enabled:
			set_enabled(true)
		_compute_layout()
		if _touches.has(e.index):
			_release(e.index, e.position)
		var p := e.position
		var b := _find_ui_button(p)
		if b:
			_touches[e.index] = {"role": &"ui", "button": b}
		elif not gameplay_active:
			_touches[e.index] = {"role": &"none"}
		else:
			var role: StringName = &"camera"
			for id in BUTTON_ORDER:
				var bd: Dictionary = _layout[id]
				if p.distance_to(bd.c) <= bd.r * 1.12:
					role = id
					break
			if role == &"camera" and p.x < size.x * 0.45 and p.y > size.y * 0.22 and _stick_index == -1:
				role = &"stick"
			_touches[e.index] = {"role": role, "last": p}
			match role:
				&"jump":
					# One finger owns JUMP; extra fingers on the button are ignored (role "none").
					if _jump_index == -1:
						_jump_index = e.index
						jump_held = true
						if player:
							player.queue_jump_tap()
					else:
						_touches[e.index] = {"role": &"none"}
				&"run":
					run_on = not run_on
				&"stick":
					_stick_index = e.index
					_stick_origin = Vector2(
						clampf(p.x, STICK_RADIUS * 0.6, size.x * 0.45),
						clampf(p.y, size.y * 0.3, size.y - STICK_RADIUS * 0.6))
					_update_stick(p)
				_:
					if BUTTON_ACTIONS.has(role):
						_fire_action(BUTTON_ACTIONS[role])
		vp.set_input_as_handled()
		queue_redraw()
	else:
		if _touches.has(e.index):
			_release(e.index, e.position)
			vp.set_input_as_handled()
			queue_redraw()


func _release(index: int, pos: Vector2) -> void:
	var t: Dictionary = _touches[index]
	_touches.erase(index)
	match t.role:
		&"ui":
			var b: Button = t.button
			if is_instance_valid(b) and b.is_visible_in_tree() and not b.disabled and b.get_global_rect().has_point(pos):
				b.pressed.emit()
		&"jump":
			_jump_index = -1
			jump_held = false
		&"stick":
			_stick_index = -1
			stick_vector = Vector2.ZERO


func _on_drag(e: InputEventScreenDrag) -> void:
	if not _touches.has(e.index):
		return
	var t: Dictionary = _touches[e.index]
	match t.role:
		&"stick":
			_update_stick(e.position)
		&"camera":
			var d: Vector2 = e.position - t.last
			t.last = e.position
			if player and gameplay_active:
				player.rotate_camera(-d.x * CAMERA_SENSITIVITY, -d.y * CAMERA_SENSITIVITY)
	get_viewport().set_input_as_handled()
	queue_redraw()


func _update_stick(p: Vector2) -> void:
	var v := (p - _stick_origin) / STICK_RADIUS
	v = v.limit_length(1.0)
	stick_vector = Vector2.ZERO if v.length() < STICK_DEADZONE else v


func _process(_delta: float) -> void:
	if enabled and gameplay_active:
		queue_redraw()


func _draw() -> void:
	if not enabled or not gameplay_active:
		return
	if _layout.is_empty():
		_compute_layout()
	var ink := Color(0.94, 0.9, 0.82, 0.85)
	var fill := Color(0.05, 0.06, 0.11, 0.42)
	var hot := Color(0.95, 0.64, 0.22, 0.85)
	var origin := _stick_origin if _stick_index != -1 else _stick_home
	draw_circle(origin, STICK_RADIUS, fill)
	draw_arc(origin, STICK_RADIUS, 0.0, TAU, 48, Color(ink, 0.5), 3.0, true)
	draw_circle(origin + stick_vector * STICK_RADIUS, KNOB_RADIUS, Color(ink, 0.55 if _stick_index != -1 else 0.3))
	for id in BUTTON_ORDER:
		var b: Dictionary = _layout[id]
		var active := false
		for t in _touches.values():
			if t.role == id:
				active = true
		if id == &"run" and run_on:
			active = true
		draw_circle(b.c, b.r, hot if active else fill)
		draw_arc(b.c, b.r, 0.0, TAU, 40, ink, 3.0, true)
		var fs := 26 if id == &"jump" else 20
		draw_string(_font, b.c + Vector2(-b.r, fs * 0.35), b.label, HORIZONTAL_ALIGNMENT_CENTER, b.r * 2.0, fs, ink)
	if player and player.charging:
		var jb: Dictionary = _layout[&"jump"]
		draw_arc(jb.c, jb.r + 9.0, -PI / 2.0, -PI / 2.0 + TAU * player.charge, 48, hot, 9.0, true)
