extends SceneTree
## Writes the [input] section of project.godot (run once after changing bindings):
##   godot --headless --path . -s tools/setup_input_map.gd
## Keys use physical keycodes so WASD works on any keyboard layout.

func _key(physical: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.device = -1
	e.physical_keycode = physical
	return e


func _btn(b: JoyButton) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.device = -1
	e.button_index = b
	return e


func _axis(a: JoyAxis, v: float) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.device = -1
	e.axis = a
	e.axis_value = v
	return e


func _init() -> void:
	var map := {
		"left": [_key(KEY_A), _key(KEY_LEFT), _axis(JOY_AXIS_LEFT_X, -1.0)],
		"right": [_key(KEY_D), _key(KEY_RIGHT), _axis(JOY_AXIS_LEFT_X, 1.0)],
		"forward": [_key(KEY_W), _key(KEY_UP), _axis(JOY_AXIS_LEFT_Y, -1.0)],
		"back": [_key(KEY_S), _key(KEY_DOWN), _axis(JOY_AXIS_LEFT_Y, 1.0)],
		"jump": [_key(KEY_SPACE), _btn(JOY_BUTTON_A)],
		"sprint": [_key(KEY_SHIFT), _btn(JOY_BUTTON_LEFT_SHOULDER)],
		"interact": [_key(KEY_E), _btn(JOY_BUTTON_X)],
		"switch_cat": [_key(KEY_TAB), _btn(JOY_BUTTON_Y)],
		"sense": [_key(KEY_Q), _btn(JOY_BUTTON_RIGHT_SHOULDER)],
		"reset": [_key(KEY_R), _btn(JOY_BUTTON_BACK)],
		"pause": [_key(KEY_ESCAPE), _btn(JOY_BUTTON_START)],
		"look_left": [_axis(JOY_AXIS_RIGHT_X, -1.0)],
		"look_right": [_axis(JOY_AXIS_RIGHT_X, 1.0)],
		"look_up": [_axis(JOY_AXIS_RIGHT_Y, -1.0)],
		"look_down": [_axis(JOY_AXIS_RIGHT_Y, 1.0)],
	}
	for action in map:
		ProjectSettings.set_setting("input/" + action, {"deadzone": 0.2, "events": map[action]})
	var err := ProjectSettings.save()
	print("input map saved: ", error_string(err))
	quit(0 if err == OK else 1)
