class_name CatPlayer
extends CharacterBody3D
## Cat controller: camera-relative movement, press-charge-release jump with coyote time
## and jump buffer, low third-person SpringArm camera and a blob shadow for judging jumps.
## The visible cat lives in a separate child (CatVisual) so it can be swapped for a GLB.

signal jumped(strength: float)
signal landed(impact_speed: float)

const WORLD_MASK := 1
const PLAYER_LAYER := 2
const CAPSULE_RADIUS := 0.15
const CAPSULE_HEIGHT := 0.36
const CAMERA_HEIGHT := 0.36

@export var walk_speed := 2.2
@export var run_speed := 3.7
@export var crouch_speed_factor := 0.5
@export var ground_accel := 14.0
@export var air_accel := 4.5
@export var gravity := 15.0
@export var max_fall_speed := 20.0
@export var jump_velocity_min := 3.6
@export var jump_velocity_max := 6.6
## Forward leap speed applied along the input direction on take-off (cats pounce).
@export var leap_speed_min := 1.0
@export var leap_speed_max := 2.2
@export var charge_time := 0.65
@export var coyote_time := 0.12
@export var jump_buffer_time := 0.12
@export var turn_speed := 12.0
@export var mouse_sensitivity := 0.0025
@export var drag_sensitivity := 0.006
@export var stick_camera_speed := 2.6
@export var camera_distance := 1.55

## Set by world.gd. Provides stick_vector, jump_held, run_on (may be null).
var touch: Node = null
var visual: CatVisual
var camera: Camera3D
var input_enabled := true

var cam_yaw := 0.0
var cam_pitch := -0.17
var charging := false
var charge := 0.0
var facing_yaw := 0.0
var move_state: StringName = &"idle"
var jump_count := 0

var _jump_prev := false
var _jump_tap_pending := false
var _jump_needs_release := false
var _buffer := 0.0
var _coyote := 0.0
var _was_on_floor := false
var _land_timer := 0.0
var _pre_move_vy := 0.0
var _rig: Node3D
var _pitch_node: Node3D
var _spring: SpringArm3D
var _rig_pos := Vector3.ZERO
var _shadow: MeshInstance3D


func _ready() -> void:
	collision_layer = PLAYER_LAYER
	collision_mask = WORLD_MASK
	floor_snap_length = 0.12
	floor_max_angle = deg_to_rad(50.0)
	var shape := CapsuleShape3D.new()
	shape.radius = CAPSULE_RADIUS
	shape.height = CAPSULE_HEIGHT
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = CAPSULE_HEIGHT * 0.5
	add_child(col)

	visual = CatVisual.new()
	visual.name = "CatVisual"
	add_child(visual)

	_rig = Node3D.new()
	_rig.name = "CameraRig"
	_rig.top_level = true
	_rig.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_rig)
	_pitch_node = Node3D.new()
	_rig.add_child(_pitch_node)
	_spring = SpringArm3D.new()
	_spring.spring_length = camera_distance
	_spring.collision_mask = WORLD_MASK
	_spring.margin = 0.05
	var probe := SphereShape3D.new()
	probe.radius = 0.12
	_spring.shape = probe
	_spring.add_excluded_object(get_rid())
	_pitch_node.add_child(_spring)
	camera = Camera3D.new()
	camera.fov = 68.0
	camera.near = 0.05
	camera.far = 160.0
	camera.current = true
	_spring.add_child(camera)

	_shadow = MeshInstance3D.new()
	_shadow.top_level = true
	var quad := PlaneMesh.new()
	quad.size = Vector2(0.5, 0.5)
	_shadow.mesh = quad
	var grad := Gradient.new()
	grad.set_color(0, Color(0, 0, 0, 0.55))
	grad.set_color(1, Color(0, 0, 0, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	var smat := StandardMaterial3D.new()
	smat.albedo_texture = tex
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shadow.material_override = smat
	_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_shadow)
	snap_camera()


func set_kind(kind: StringName) -> void:
	visual.set_kind(kind)


## Teleport used only for respawn/reset (never for route traversal).
func respawn(pos: Vector3, yaw: float) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	facing_yaw = yaw
	cam_yaw = yaw
	visual.rotation.y = yaw
	reset_inputs()
	_was_on_floor = false
	reset_physics_interpolation()
	snap_camera()


func snap_camera() -> void:
	_rig_pos = global_position + Vector3(0, CAMERA_HEIGHT, 0)
	if _rig:
		_rig.global_position = _rig_pos
		_apply_camera_rotation()


## Drops any held/charged/buffered jump. After this the jump button must be
## released before it can start a new jump, so nothing fires on resume.
func reset_inputs() -> void:
	charging = false
	charge = 0.0
	_buffer = 0.0
	_jump_tap_pending = false
	_jump_prev = false
	_jump_needs_release = true


func rotate_camera(dyaw: float, dpitch: float) -> void:
	cam_yaw = wrapf(cam_yaw + dyaw, -PI, PI)
	cam_pitch = clampf(cam_pitch + dpitch, deg_to_rad(-65.0), deg_to_rad(30.0))


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			rotate_camera(-mm.relative.x * mouse_sensitivity, -mm.relative.y * mouse_sensitivity)
		elif mm.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_LEFT):
			rotate_camera(-mm.relative.x * drag_sensitivity, -mm.relative.y * drag_sensitivity)
	elif event.is_action_pressed("jump"):
		_jump_tap_pending = true


## Called by touch controls so a very short tap is never lost between physics frames.
func queue_jump_tap() -> void:
	if input_enabled:
		_jump_tap_pending = true


func _read_move() -> Vector2:
	var move := Input.get_vector("left", "right", "forward", "back")
	if touch:
		move += touch.stick_vector
	return move.limit_length(1.0)


func _physics_process(delta: float) -> void:
	var on_floor := is_on_floor()
	var move := Vector2.ZERO
	var held := false
	var run := false
	if input_enabled:
		move = _read_move()
		held = Input.is_action_pressed("jump") or (touch != null and touch.jump_held)
		run = Input.is_action_pressed("sprint") or (touch != null and touch.run_on)
	else:
		charging = false
		charge = 0.0
		_buffer = 0.0
		_jump_tap_pending = false
	var tap := _jump_tap_pending
	_jump_tap_pending = false
	if _jump_needs_release:
		if held:
			held = false
			tap = false
		else:
			_jump_needs_release = false

	var pressed_edge := (held and not _jump_prev) or tap
	var released := not held
	_jump_prev = held

	if on_floor:
		_coyote = coyote_time
	else:
		_coyote = maxf(_coyote - delta, 0.0)
	if pressed_edge:
		_buffer = jump_buffer_time

	var dir := Basis(Vector3.UP, cam_yaw) * Vector3(move.x, 0.0, move.y)

	# Jump: press -> crouch/charge -> release -> exactly one leap.
	if charging:
		if _coyote <= 0.0:
			charging = false
			charge = 0.0
		elif released:
			_do_jump(dir)
		else:
			charge = minf(charge + delta / charge_time, 1.0)
	elif _buffer > 0.0 and _coyote > 0.0:
		if held:
			charging = true
			charge = 0.0
			_buffer = 0.0
		else:
			_do_jump(dir)
	_buffer = maxf(_buffer - delta, 0.0)

	var speed := run_speed if run else walk_speed
	if charging:
		speed *= crouch_speed_factor
	var target := dir * speed
	var hv := Vector3(velocity.x, 0.0, velocity.z)
	hv = hv.move_toward(target, (ground_accel if on_floor else air_accel) * delta)
	velocity.x = hv.x
	velocity.z = hv.z
	if not on_floor:
		velocity.y = maxf(velocity.y - gravity * delta, -max_fall_speed)
	_pre_move_vy = velocity.y
	move_and_slide()

	var now_floor := is_on_floor()
	if now_floor and not _was_on_floor:
		_land_timer = 0.16
		visual.play_land(-_pre_move_vy)
		landed.emit(-_pre_move_vy)
	_was_on_floor = now_floor
	_land_timer = maxf(_land_timer - delta, 0.0)

	var flat_speed := Vector2(velocity.x, velocity.z).length()
	if flat_speed > 0.12 and not (charging and move == Vector2.ZERO):
		var want := atan2(-velocity.x, -velocity.z)
		facing_yaw = lerp_angle(facing_yaw, want, 1.0 - exp(-turn_speed * delta))
	visual.rotation.y = facing_yaw

	if charging:
		move_state = &"crouch"
	elif not now_floor:
		move_state = &"air"
	elif _land_timer > 0.0:
		move_state = &"land"
	elif flat_speed > walk_speed + 0.35:
		move_state = &"run"
	elif flat_speed > 0.15:
		move_state = &"walk"
	else:
		move_state = &"idle"
	visual.set_motion(move_state, flat_speed, charge, velocity.y)
	_update_shadow()


func _do_jump(dir: Vector3) -> void:
	var strength := charge
	velocity.y = lerpf(jump_velocity_min, jump_velocity_max, strength)
	if dir.length() > 0.1:
		var d := dir.normalized()
		var along := Vector3(velocity.x, 0.0, velocity.z).dot(d)
		var leap := maxf(along, lerpf(leap_speed_min, leap_speed_max, strength) * minf(dir.length(), 1.0))
		var side := Vector3(velocity.x, 0.0, velocity.z) - d * along
		velocity.x = d.x * leap + side.x * 0.5
		velocity.z = d.z * leap + side.z * 0.5
	charging = false
	charge = 0.0
	_buffer = 0.0
	_coyote = 0.0
	jump_count += 1
	jumped.emit(strength)


func _update_shadow() -> void:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3(0, 0.2, 0)
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3(0, -30, 0), WORLD_MASK, [get_rid()])
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		_shadow.visible = false
		return
	_shadow.visible = true
	var h: float = global_position.y - hit.position.y
	var s := clampf(1.0 - h / 6.0, 0.4, 1.0)
	_shadow.global_transform = Transform3D(Basis().scaled(Vector3(s, 1, s)), hit.position + Vector3(0, 0.012, 0))


func _process(delta: float) -> void:
	if input_enabled:
		var look := Input.get_vector("look_left", "look_right", "look_up", "look_down")
		if look != Vector2.ZERO:
			rotate_camera(-look.x * stick_camera_speed * delta, -look.y * stick_camera_speed * 0.7 * delta)
	var target := get_global_transform_interpolated().origin + Vector3(0, CAMERA_HEIGHT, 0)
	_rig_pos.x = target.x
	_rig_pos.z = target.z
	_rig_pos.y = lerpf(_rig_pos.y, target.y, 1.0 - exp(-10.0 * delta))
	_rig.global_position = _rig_pos
	_apply_camera_rotation()


func _apply_camera_rotation() -> void:
	_rig.rotation = Vector3(0.0, cam_yaw, 0.0)
	_pitch_node.rotation = Vector3(cam_pitch, 0.0, 0.0)
