extends Node
## Headless engine test, started by world.gd when run with `-- --smoke-test`.
## Drives the real CatPlayer with real input actions (no teleporting along the route),
## checks the jump/charge rules, letter rules, cat switch, fall recovery, pause/focus
## input release and touch roles (touch via injected InputEventScreenTouch/Drag).
## Exits with code 1 on any failure or on timeout.

const TIMEOUT_MS := 240000

var world: AlleyWorld
var player: CatPlayer
var failures: Array[String] = []
var checks := 0
var _start_ms := 0
var _done := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	world = get_parent()
	player = world.player
	_start_ms = Time.get_ticks_msec()
	_run.call_deferred()


func _process(_delta: float) -> void:
	if not _done and Time.get_ticks_msec() - _start_ms > TIMEOUT_MS:
		failures.append("timeout after %d ms" % TIMEOUT_MS)
		_finish()


func _check(cond: bool, msg: String) -> bool:
	checks += 1
	if cond:
		print("  ok    ", msg)
	else:
		failures.append(msg)
		printerr("  FAIL  ", msg)
	return cond


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _real_wait(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await get_tree().process_frame


func _axis(neg: StringName, pos: StringName, value: float) -> void:
	if value > 0.001:
		Input.action_press(pos, value)
	else:
		Input.action_release(pos)
	if value < -0.001:
		Input.action_press(neg, -value)
	else:
		Input.action_release(neg)


## Push the move stick so the cat heads along a world direction (camera-relative input).
func _move_world(dir: Vector3, strength := 1.0) -> void:
	var v := Vector2.ZERO
	if dir.length() > 0.0001 and strength > 0.0:
		var local := Basis(Vector3.UP, player.cam_yaw).inverse() * dir.normalized()
		v = Vector2(local.x, local.z).normalized() * clampf(strength, 0.0, 1.0)
	_axis(&"left", &"right", v.x)
	_axis(&"forward", &"back", v.y)


func _stop() -> void:
	_move_world(Vector3.ZERO, 0.0)
	Input.action_release(&"sprint")


func _action(name: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = name
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := InputEventAction.new()
	up.action = name
	up.pressed = false
	Input.parse_input_event(up)
	await get_tree().process_frame
	await _frames(1)


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _hspeed() -> float:
	return Vector2(player.velocity.x, player.velocity.z).length()


func _platform_id() -> String:
	var c: Object = world.player_floor_collider()
	if c == null or not c.has_meta("route_index"):
		return "none"
	var i: int = c.get_meta("route_index")
	return "ground" if i < 0 else AlleyWorld.ROUTE[i].id


func _walk_to(target: Vector3, tol := 0.08, run := false, max_frames := 1200) -> bool:
	if run:
		Input.action_press(&"sprint")
	for i in max_frames:
		var d := target - player.global_position
		d.y = 0.0
		var dist := d.length()
		if dist < tol:
			break
		var want := minf(dist * 4.0, 1.0)
		_move_world(d, maxf(want, 0.42))
		await get_tree().physics_frame
	_stop()
	await _frames(20)
	return _flat(player.global_position, target) < tol * 2.5


## Charge while standing, then release while steering toward `target` with air control.
func _jump_to(target: Vector3, expect: String, hold_frames: int) -> bool:
	var jumps := player.jump_count
	Input.action_press(&"jump")
	await _frames(hold_frames)
	var d := target - player.global_position
	d.y = 0.0
	_move_world(d, 1.0)
	Input.action_release(&"jump")
	var left := false
	for i in 300:
		await get_tree().physics_frame
		if not player.is_on_floor():
			left = true
		d = target - player.global_position
		d.y = 0.0
		# Velocity-target steering: aim for a speed proportional to the remaining distance.
		var want := d * 3.0
		var steer := want - Vector3(player.velocity.x, 0.0, player.velocity.z)
		var s := clampf(want.length() / player.walk_speed, 0.0, 1.0)
		if steer.length() < 0.05 or d.length() < 0.04:
			_move_world(Vector3.ZERO, 0.0)
		else:
			_move_world(want if want.length() > 0.2 else steer, maxf(s, 0.45))
		if left and player.is_on_floor():
			break
	_stop()
	await _frames(20)
	var on := _platform_id()
	return _check(left and player.jump_count == jumps + 1 and on == expect,
		"leap to %s (landed on %s, pos %s)" % [expect, on, _v(player.global_position)])


func _v(p: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [p.x, p.y, p.z]


func _run() -> void:
	print("== Midnight Cat Delivery smoke test ==")
	# The headless display reports a 64x64 window; use a real 16:9 window for UI checks.
	get_tree().root.size = Vector2i(1280, 720)
	await _frames(10)
	print("viewport: ", get_viewport().get_visible_rect().size, "  touch overlay: ", world.touch.size, "  hud: ", world.hud.size)
	_check(world.touch.size == get_viewport().get_visible_rect().size and world.hud.size == world.touch.size,
		"HUD and touch overlay fill the viewport")
	_test_font()
	_check(world.state == AlleyWorld.State.PLAYING, "starts in playing state")
	_check(player.is_on_floor() and _platform_id() == "ground", "cat stands on the alley at spawn")
	_check(player.camera.global_position.distance_to(player.global_position) > 1.4,
		"SpringArm keeps camera behind the cat (does not hit own collider)")
	await _test_walk_stop()
	await _test_jump_rules()
	await _test_letter_rules()
	await _test_fall_recovery()
	await _test_route()
	await _test_restart()
	await _test_touch()
	_finish()


func _test_font() -> void:
	var font: FontFile = load("res://assets/fonts/ui_font.ttf")
	var missing := {}
	for path in ["res://scripts/world.gd", "res://scripts/hud.gd", "res://scripts/touch_controls.gd"]:
		var text := FileAccess.get_file_as_string(path)
		for ch in text:
			var code := ch.unicode_at(0)
			if code > 127 and not font.has_char(code):
				missing[ch] = true
	_check(missing.is_empty(), "UI font covers every UI character (missing: %s)" % "".join(missing.keys()))


func _test_walk_stop() -> void:
	print("-- walk / stop")
	var cam := player.cam_yaw
	_move_world(Basis(Vector3.UP, cam) * Vector3.FORWARD)
	await _frames(40)
	_check(absf(_hspeed() - player.walk_speed) < 0.15, "walk speed ~%.1f m/s (got %.2f)" % [player.walk_speed, _hspeed()])
	Input.action_press(&"sprint")
	await _frames(30)
	_check(absf(_hspeed() - player.run_speed) < 0.15, "run speed ~%.1f m/s (got %.2f)" % [player.run_speed, _hspeed()])
	_stop()
	await _frames(20)
	_check(_hspeed() < 0.02, "stops within 0.33 s after releasing input (%.3f m/s)" % _hspeed())
	var p := player.global_position
	await _frames(60)
	_check(player.global_position.distance_to(p) < 0.005, "no sliding / creeping after stop")
	await _walk_to(AlleyWorld.SPAWN)


func _test_jump_rules() -> void:
	print("-- jump rules")
	var jumps := player.jump_count
	Input.action_press(&"jump")
	await _frames(90)
	_check(player.jump_count == jumps and player.charging and is_equal_approx(player.charge, 1.0),
		"holding jump 1.5 s only charges (no jump yet, charge=%.2f)" % player.charge)
	_check(player.move_state == &"crouch", "visual state is crouch while charging")
	Input.action_release(&"jump")
	await _frames(2)
	_check(player.jump_count == jumps + 1 and player.velocity.y > 5.0, "release -> one full-charge leap (vy=%.2f)" % player.velocity.y)
	var peak := player.global_position.y
	var air_seen := false
	for i in 90:
		if i in [6, 7, 12, 13, 18]:
			Input.action_press(&"jump")
		else:
			Input.action_release(&"jump")
		await get_tree().physics_frame
		peak = maxf(peak, player.global_position.y)
		if player.move_state == &"air":
			air_seen = true
		if i > 25 and player.is_on_floor():
			break
	Input.action_release(&"jump")
	await _frames(20)
	_check(player.jump_count == jumps + 1, "mashing jump in the air does not jump again (jumps=%d)" % (player.jump_count - jumps))
	_check(air_seen, "visual state is air while airborne")
	_check(peak > 1.3 and peak < 1.6, "full charge apex %.2f m (expected ~1.45)" % peak)

	# Jump buffer: press shortly before landing and keep holding -> charge starts on landing.
	jumps = player.jump_count
	Input.action_press(&"jump")
	await _frames(1)
	Input.action_release(&"jump")
	await _frames(3)
	_check(player.jump_count == jumps + 1 and player.velocity.y > 3.0, "quick tap -> minimum hop")
	var buffered := false
	for i in 60:
		if not player.is_on_floor() and player.velocity.y < -2.5 and player.global_position.y < 0.12:
			Input.action_press(&"jump")
		await get_tree().physics_frame
		if player.is_on_floor() and player.charging:
			buffered = true
			break
	_check(buffered, "jump pressed just before landing is buffered into a charge")
	Input.action_release(&"jump")
	await _frames(40)
	_check(player.jump_count == jumps + 2, "buffered press releases into exactly one jump")
	await _frames(20)


func _test_letter_rules() -> void:
	print("-- letter rules")
	await _action(&"interact")
	_check(not world.has_letter, "cannot take the letter from far away")
	_check(not world.can_deliver(), "cannot deliver before receiving the letter")
	var near := AlleyWorld.LETTER_POS + Vector3(0.45, 0, 0.3)
	_check(await _walk_to(near), "walked to the letter")
	_check(world.can_pickup(), "pickup available next to the letter")
	await _action(&"interact")
	_check(world.has_letter and player.visual.is_carrying() and not world._letter.visible,
		"letter picked up and carried in the mouth")

	# Switch cats while moving: position / velocity / letter state must carry over.
	_move_world(Vector3(1, 0, -1))
	await _frames(25)
	var pos := player.global_position
	var vel := player.velocity
	var kind := world.cat_kind
	var ev := InputEventAction.new()
	ev.action = &"switch_cat"
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	var up := InputEventAction.new()
	up.action = &"switch_cat"
	Input.parse_input_event(up)
	await _frames(1)
	_check(world.cat_kind != kind and player.visual.kind == world.cat_kind, "switch cat (%s -> %s)" % [kind, world.cat_kind])
	_check(player.global_position.distance_to(pos) < 0.12 and player.velocity.distance_to(vel) < 0.3,
		"switch keeps position and velocity")
	_check(world.has_letter and player.visual.is_carrying(), "switch keeps the carried letter")
	_stop()
	await _action(&"switch_cat")
	await _frames(20)


func _test_fall_recovery() -> void:
	print("-- fall recovery")
	_check(await _walk_to(Vector3(0.0, 0.0, -18.4), 0.1, true), "ran to the end of the alley")
	Input.action_press(&"jump")
	await _frames(30)
	_move_world(Vector3(0, 0, -1))
	Input.action_release(&"jump")
	var respawned := false
	var fell_low := false
	for i in 400:
		await get_tree().physics_frame
		if player.global_position.y < -1.0:
			fell_low = true
		if fell_low and player.global_position.distance_to(AlleyWorld.SPAWN) < 0.3:
			respawned = true
			break
	_stop()
	await _frames(20)
	_check(fell_low and respawned, "falling off the alley end returns the cat to the last safe point")
	_check(world.has_letter and player.visual.is_carrying() and not world._letter.visible,
		"letter state stays consistent after the fall (still carried, not left in the air)")


func _test_route() -> void:
	print("-- route (real movement + jumps)")
	_check(await _walk_to(Vector3(1.75, 0.0, -2.2)), "approach the low box")
	_check(await _jump_to(Vector3(1.75, 0.5, -3.2), "box", 26), "box")
	_check(await _walk_to(Vector3(1.95, 0.5, -3.3)), "box edge next to the wall")
	_check(await _jump_to(Vector3(2.55, 1.3, -3.9), "wall", 30), "wall")
	_check(await _walk_to(Vector3(2.55, 1.3, -8.0), 0.08, false), "walk along the wall top")
	_check(_platform_id() == "wall", "still on the wall after walking along it")
	_check(await _jump_to(Vector3(3.33, 2.1, -8.0), "ac", 32), "AC unit")

	# Pause mid-route: no movement, no delivery, held jump must not fire on resume.
	await _action(&"pause")
	await _frames(3)
	_check(world.state == AlleyWorld.State.PAUSED and get_tree().paused, "Esc/pause action pauses the game")
	var p := player.global_position
	_move_world(Vector3(0, 0, -1))
	Input.action_press(&"jump")
	await _frames(30)
	_check(player.global_position.distance_to(p) < 0.001, "no movement while paused")
	_stop()
	await _real_wait(400)
	world.hud.resume_pressed.emit()
	await _frames(25)
	_check(world.state == AlleyWorld.State.PLAYING, "resume button resumes")
	_check(not player.charging, "jump held through pause does not charge")
	var jc := player.jump_count
	Input.action_release(&"jump")
	_stop()
	await _frames(20)
	_check(player.jump_count == jc, "releasing a jump held through pause does not jump")
	await _walk_to(Vector3(3.37, 2.1, -8.2))

	_check(await _jump_to(Vector3(3.43, 2.9, -9.5), "ledge", 34), "narrow ledge")
	_check(await _walk_to(Vector3(3.43, 2.9, -12.75), 0.08), "walk along the narrow ledge")
	_check(_platform_id() == "ledge", "still on the ledge after walking along it")

	# Focus loss while charging: pauses, releases input, no jump after resuming.
	Input.action_press(&"jump")
	await _frames(15)
	_check(player.charging, "charging on the ledge")
	jc = player.jump_count
	world.notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	await _frames(2)
	_check(world.state == AlleyWorld.State.PAUSED and not Input.is_action_pressed(&"jump"),
		"focus loss pauses and releases held inputs")
	await _real_wait(400)
	world.hud.resume_pressed.emit()
	await _frames(30)
	_check(player.jump_count == jc and not player.charging and _platform_id() == "ledge",
		"no pending jump fires after focus returns")

	_check(await _jump_to(Vector3(3.15, 3.6, -13.75), "sign", 28), "sign")
	_check(await _walk_to(Vector3(3.2, 3.6, -13.8)), "sign position")
	_check(await _jump_to(Vector3(3.3, 4.3, -15.0), "sill", 36), "302 window sill")

	_check(await _walk_to(Vector3(3.3, 4.3, -15.45)), "walk to the 302 window")
	_check(world.can_deliver(), "delivery available in front of 302")
	await _action(&"interact")
	await _frames(90)
	_check(world.delivered and not world.has_letter and not player.visual.is_carrying(), "letter delivered")
	_check(world._window_light.light_energy > 2.0 and world._letter.visible, "302 window lights up and the letter sits on the sill")
	await _action(&"reset")
	await _frames(5)
	_check(player.global_position.distance_to(world.safe_point) < 0.05 and _platform_id() in ["sill", "none"],
		"R returns to the last safe point (302 sill)")


func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	Input.parse_input_event(e)


func _drag(index: int, from: Vector2, to: Vector2, steps := 6) -> void:
	for i in steps:
		var e := InputEventScreenDrag.new()
		e.index = index
		e.position = from.lerp(to, float(i + 1) / steps)
		e.relative = (to - from) / steps
		Input.parse_input_event(e)
		await _frames(1)


func _btn_center(b: Button) -> Vector2:
	return b.get_global_rect().get_center()


func _test_touch() -> void:
	print("-- touch (engine-injected InputEventScreenTouch/Drag)")
	var t: TouchControls = world.touch
	var lay := t.get_layout()
	var home := Vector2(lay.stick_home[0], lay.stick_home[1])
	var jump := Vector2(lay.jump[0], lay.jump[1])
	var cat := Vector2(lay.cat[0], lay.cat[1])
	var cam_spot := Vector2(t.size.x * 0.72, t.size.y * 0.3)

	_touch(0, home, true)
	await _frames(1)
	_check(t.enabled, "first touch switches the UI to touch mode")
	await _drag(0, home, home + Vector2(0, -110))
	_check(t.stick_vector.y < -0.8, "stick finger pushes forward (stick=%s)" % t.stick_vector)
	var p0 := player.global_position
	await _frames(10)
	_check(player.global_position.distance_to(p0) > 0.15, "cat moves with the stick")
	# Second finger: charge on JUMP, slide off to the camera area, release there.
	var jc := player.jump_count
	var yaw := player.cam_yaw
	_touch(1, jump, true)
	await _frames(15)
	_check(t.jump_held and player.charging and t.stick_vector.y < -0.8, "stick + JUMP held at the same time (charging)")
	await _drag(1, jump, cam_spot)
	_check(is_equal_approx(player.cam_yaw, yaw), "JUMP finger moving away does not become a camera finger")
	_touch(1, cam_spot, false)
	await _frames(3)
	_check(player.jump_count == jc + 1 and not t.jump_held, "releasing the JUMP finger outside the button jumps once")
	await _frames(50)
	_touch(0, home + Vector2(0, -110), false)
	await _frames(20)
	_check(t.stick_vector == Vector2.ZERO and _hspeed() < 0.05, "lifting the stick finger stops the cat")

	_touch(2, cam_spot, true)
	await _drag(2, cam_spot, cam_spot + Vector2(-200, 0))
	_touch(2, cam_spot + Vector2(-200, 0), false)
	await _frames(2)
	_check(absf(angle_difference(yaw, player.cam_yaw)) > 0.8, "drag on empty right side turns the camera")

	var kind := world.cat_kind
	_touch(3, cat, true)
	_touch(3, cat, false)
	await _frames(3)
	_check(world.cat_kind != kind, "CAT button switches cats")

	# Cancel while charging: input is dropped without jumping.
	jc = player.jump_count
	_touch(4, jump, true)
	await _frames(12)
	t.cancel_all()
	_touch(4, jump, false)
	await _frames(20)
	_check(player.jump_count == jc and not player.charging and not t.jump_held, "touch cancel drops the charge without jumping")

	# Resize while holding the stick releases it.
	_touch(5, home, true)
	await _drag(5, home, home + Vector2(80, 0))
	t.size += Vector2(2, 0)
	await _frames(2)
	_check(t.stick_vector == Vector2.ZERO and t._touches.is_empty(), "resize clears tracked touches")
	_touch(5, home, false)
	t.size -= Vector2(2, 0)

	# HUD pause via touch, stick ignored while paused, resume via touch.
	_touch(6, _btn_center(world.hud.pause_btn), true)
	_touch(6, _btn_center(world.hud.pause_btn), false)
	await _frames(3)
	_check(world.state == AlleyWorld.State.PAUSED, "touching Pause pauses")
	_touch(7, home, true)
	await _drag(7, home, home + Vector2(0, -100))
	_check(t.stick_vector == Vector2.ZERO, "stick does nothing while paused")
	_touch(7, home, false)
	await _real_wait(400)
	var resume_btn: Button = null
	for b: Button in world.hud.get_touch_buttons():
		if b.is_visible_in_tree() and b.text == "계속하기":
			resume_btn = b
	_check(resume_btn != null and resume_btn.size.y >= 88.0, "Resume button is large enough for touch (%s)" % (resume_btn.size if resume_btn else Vector2.ZERO))
	if resume_btn:
		_touch(8, _btn_center(resume_btn), true)
		_touch(8, _btn_center(resume_btn), false)
		await _frames(3)
	_check(world.state == AlleyWorld.State.PLAYING, "touching Resume resumes")
	_test_touch_layout(t)


func _test_touch_layout(t: TouchControls) -> void:
	var real_size := t.size
	for s in [real_size, Vector2(1558, 720), Vector2(1280, 960), Vector2(1280, 720)]:
		t.size = s
		_check_layout(t, s)
	t.size = real_size


func _check_layout(t: TouchControls, at: Vector2) -> void:
	var lay := t.get_layout()
	var circles := []
	for k in ["jump", "letter", "cat", "route", "run", "stick_home"]:
		circles.append([k, Vector2(lay[k][0], lay[k][1]), float(lay[k][2])])
	var ok := true
	for i in circles.size():
		for j in range(i + 1, circles.size()):
			if circles[i][1].distance_to(circles[j][1]) < circles[i][2] + circles[j][2]:
				ok = false
				printerr("    overlap ", circles[i][0], " / ", circles[j][0])
	var rect := Rect2(Vector2.ZERO, t.size)
	for c in circles:
		if not rect.has_point(c[1] - Vector2(c[2], c[2])) or not rect.has_point(c[1] + Vector2(c[2], c[2]) - Vector2(1, 1)):
			ok = false
			printerr("    off-screen ", c[0])
	# Top bar (Pause/Home) is anchored top-right: its height is the same at every size.
	var bar_bottom := world.hud.top_right.get_global_rect().end.y
	for c in circles:
		if c[1].y - c[2] < bar_bottom + 8.0:
			ok = false
			printerr("    reaches the top bar ", c[0])
	_check(ok, "touch buttons at %s: no overlap with each other, the top bar or screen edges" % at)


func _test_restart() -> void:
	print("-- restart")
	world.hud.restart_pressed.emit()
	await _frames(5)
	_check(not world.has_letter and not world.delivered and world._letter.visible and world._window_light.light_energy == 0.0,
		"restart resets letter and window")
	_check(player.global_position.distance_to(AlleyWorld.SPAWN) < 0.2, "restart puts the cat at the start")


func _finish() -> void:
	if _done:
		return
	_done = true
	print("== %d checks, %d failed ==" % [checks, failures.size()])
	if failures.is_empty():
		print("SMOKE TEST PASSED")
	else:
		for f in failures:
			printerr("FAILED: ", f)
		printerr("SMOKE TEST FAILED")
	get_tree().quit(0 if failures.is_empty() else 1)
