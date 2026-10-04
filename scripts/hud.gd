class_name GameHud
extends Control
## In-game UI shared by desktop, web and touch: status panel, context prompt, charge bar,
## Pause/Home buttons and the title / pause / complete / rotate overlays.
## Everything is anchored to screen edges so it follows window resizes.

signal start_pressed
signal restart_pressed
signal pause_pressed
signal resume_pressed
signal home_pressed
signal explore_pressed

const INK := Color(0.95, 0.91, 0.84)
const AMBER := Color(0.97, 0.7, 0.3)
const NIGHT := Color(0.05, 0.06, 0.11)

const PC_CONTROLS := "이동 WASD·방향키   달리기 Shift   점프 Space 길게 눌렀다 떼기\n편지 E   고양이 교체 Tab   길 안내 Q   복귀 R   일시정지 Esc\n시점: 게임 화면 클릭 후 마우스 (또는 오른쪽 버튼 드래그)\n패드: 왼쪽 스틱 이동 · A 점프 · X 편지 · Y 교체 · LB 달리기 · RB 길 안내"
const TOUCH_CONTROLS := "왼쪽 아래: 이동 스틱   RUN: 달리기 켜기/끄기\nJUMP 길게 눌렀다 떼기   LETTER 편지   CAT 교체   ROUTE 길 안내\n오른쪽 빈 곳을 드래그하면 시점이 돌아가요"

var touch_mode := false
var cat_label: Label
var objective_label: Label
var prompt_label: Label
var prompt_panel: PanelContainer
var toast_label: Label
var charge_bar: ProgressBar
var pause_btn: Button
var home_btn: Button
var title_overlay: Control
var title_start_btn: Button
var title_restart_btn: Button
var title_controls: Label
var pause_overlay: Control
var pause_hint: Label
var complete_overlay: Control
var rotate_overlay: Control
var top_left: PanelContainer
var top_right: HBoxContainer

var _buttons: Array[Button] = []
var _toast_left := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	theme = _make_theme()
	_build_status()
	_build_overlays()
	set_touch_mode(false)


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 22
	var normal := _box(Color(0.94, 0.9, 0.83), 12)
	var hover := _box(Color(1.0, 0.86, 0.6), 12)
	var pressed := _box(AMBER, 12)
	for s in [normal, hover, pressed]:
		s.content_margin_left = 18
		s.content_margin_right = 18
		s.content_margin_top = 8
		s.content_margin_bottom = 8
	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		t.set_color(c, "Button", Color(0.1, 0.1, 0.14))
	t.set_color("font_color", "Label", INK)
	t.set_color("font_outline_color", "Label", Color(0, 0, 0, 0.85))
	t.set_constant("outline_size", "Label", 5)
	t.set_stylebox("panel", "PanelContainer", _box(Color(NIGHT, 0.78), 14, 14))
	return t


func _box(color: Color, radius: int, margin := 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	if margin > 0:
		s.content_margin_left = margin + 4
		s.content_margin_right = margin + 4
		s.content_margin_top = margin
		s.content_margin_bottom = margin
	return s


func _label(text: String, font_size: int, color := INK) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	_buttons.append(b)
	return b


func _build_status() -> void:
	top_left = PanelContainer.new()
	top_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_left.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 16)
	add_child(top_left)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_left.add_child(v)
	cat_label = _label("", 22, AMBER)
	v.add_child(cat_label)
	objective_label = _label("", 20)
	objective_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	objective_label.custom_minimum_size = Vector2(400, 0)
	v.add_child(objective_label)

	top_right = HBoxContainer.new()
	top_right.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	top_right.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	top_right.add_theme_constant_override("separation", 12)
	top_right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top_right)
	pause_btn = _button("일시정지", func(): pause_pressed.emit())
	home_btn = _button("홈", func(): home_pressed.emit())
	top_right.add_child(pause_btn)
	top_right.add_child(home_btn)

	prompt_panel = PanelContainer.new()
	prompt_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prompt_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 34)
	prompt_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	prompt_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(prompt_panel)
	prompt_label = _label("", 22, AMBER)
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_panel.add_child(prompt_label)
	prompt_panel.visible = false

	charge_bar = ProgressBar.new()
	charge_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	charge_bar.show_percentage = false
	charge_bar.max_value = 1.0
	charge_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	charge_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	charge_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	charge_bar.offset_left = -110
	charge_bar.offset_right = 110
	charge_bar.offset_top = -108
	charge_bar.offset_bottom = -96
	charge_bar.add_theme_stylebox_override("background", _box(Color(NIGHT, 0.7), 6))
	charge_bar.add_theme_stylebox_override("fill", _box(AMBER, 6))
	charge_bar.visible = false
	add_child(charge_bar)

	toast_label = _label("", 26, INK)
	toast_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 104)
	toast_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.visible = false
	add_child(toast_label)


func _overlay() -> Array:
	var root := ColorRect.new()
	root.color = Color(0.02, 0.025, 0.05, 0.74)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.visible = false
	add_child(root)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _box(Color(0.07, 0.08, 0.14, 0.94), 18, 28))
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.custom_minimum_size = Vector2(620, 0)
	card.add_child(v)
	return [root, v]


func _row(buttons: Array) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", 16)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for b in buttons:
		h.add_child(b)
	return h


func _build_overlays() -> void:
	var o := _overlay()
	title_overlay = o[0]
	var v: VBoxContainer = o[1]
	var t := _label("Midnight Cat Delivery", 46, INK)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var sub := _label("밤, 고양이의 또 다른 하루", 24, AMBER)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	var goal := _label("우체통 옆 편지를 물고 상자 → 담장 → 실외기 → 난간 → 간판을 건너\n302호 창문까지 배달하세요.", 20)
	goal.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(goal)
	title_start_btn = _button("시작", func(): start_pressed.emit())
	title_restart_btn = _button("처음부터", func(): restart_pressed.emit())
	v.add_child(_row([title_start_btn, title_restart_btn]))
	title_controls = _label("", 17, Color(INK, 0.85))
	title_controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title_controls)

	o = _overlay()
	pause_overlay = o[0]
	v = o[1]
	var pt := _label("일시정지", 38, INK)
	pt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(pt)
	pause_hint = _label("", 18, Color(INK, 0.85))
	pause_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(pause_hint)
	v.add_child(_row([
		_button("계속하기", func(): resume_pressed.emit()),
		_button("처음부터", func(): restart_pressed.emit()),
		_button("홈", func(): home_pressed.emit()),
	]))

	o = _overlay()
	complete_overlay = o[0]
	v = o[1]
	var ct := _label("배달 완료!", 42, AMBER)
	ct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(ct)
	var cb := _label("302호 창문에 불이 켜졌어요.\n“작은 발걸음이 누군가의 하루를 바꿀지도 몰라.”", 20)
	cb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(cb)
	v.add_child(_row([
		_button("다시 하기", func(): restart_pressed.emit()),
		_button("골목 둘러보기", func(): explore_pressed.emit()),
	]))

	o = _overlay()
	rotate_overlay = o[0]
	rotate_overlay.color = Color(0.02, 0.025, 0.05, 0.96)
	v = o[1]
	v.custom_minimum_size = Vector2(0, 0)
	var rt := _label("휴대폰을 가로로 돌려주세요", 44, AMBER)
	rt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(rt)
	var rs := _label("이 게임은 가로 화면에서 플레이해요.\n돌린 뒤 계속하기를 누르면 이어서 할 수 있어요.", 30)
	rs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(rs)


## Buttons that touch input may press (only the visible ones are considered).
func get_touch_buttons() -> Array:
	# The rotate notice covers everything: nothing behind it may be pressed.
	if rotate_overlay != null and rotate_overlay.visible:
		return []
	return _buttons


func set_touch_mode(on: bool) -> void:
	touch_mode = on
	# ~48 CSS px tall on a 390 px-high phone (viewport is 720 logical px high there).
	var big := Vector2(200, 92) if on else Vector2(170, 54)
	var small := Vector2(136, 90) if on else Vector2(116, 50)
	for b in _buttons:
		b.custom_minimum_size = big
		b.add_theme_font_size_override("font_size", 28 if on else 22)
	pause_btn.custom_minimum_size = small
	home_btn.custom_minimum_size = small
	title_controls.text = TOUCH_CONTROLS if on else PC_CONTROLS
	pause_hint.text = "계속하기를 누르면 이어서 할 수 있어요." if on \
		else "계속하기를 누른 뒤 게임 화면을 클릭하면 마우스로 시점을 돌릴 수 있어요.\n(Esc로 마우스 고정 해제)"
	_update_rotate()


func set_state(state: StringName, has_progress: bool) -> void:
	title_overlay.visible = state == &"title"
	pause_overlay.visible = state == &"paused"
	complete_overlay.visible = state == &"complete"
	var playing := state == &"playing"
	top_right.visible = playing
	prompt_panel.visible = prompt_panel.visible and playing
	charge_bar.visible = false
	title_start_btn.text = "계속하기" if has_progress else "시작"
	title_restart_btn.visible = has_progress
	_update_rotate()


func set_status(cat_text: String, objective: String) -> void:
	cat_label.text = cat_text
	objective_label.text = objective


func set_prompt(text: String) -> void:
	prompt_label.text = text
	prompt_panel.visible = text != "" and top_right.visible


func set_charge(on: bool, value: float) -> void:
	charge_bar.visible = on and not touch_mode and top_right.visible
	charge_bar.value = value


func toast(text: String, seconds := 2.2) -> void:
	toast_label.text = text
	toast_label.visible = true
	_toast_left = seconds


func is_portrait_blocked() -> bool:
	return rotate_overlay.visible


func _update_rotate() -> void:
	if rotate_overlay == null:
		return
	rotate_overlay.visible = touch_mode and size.y > size.x


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_rotate()


func _process(delta: float) -> void:
	if _toast_left > 0.0:
		_toast_left -= delta
		if _toast_left <= 0.0:
			toast_label.visible = false
