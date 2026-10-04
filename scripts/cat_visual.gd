class_name CatVisual
extends Node3D
## Procedural placeholder cat (Cheese / Tuxedo) built from primitive meshes.
##
## The controller (player.gd) only talks to this node through the methods below,
## so a rigged GLB + AnimationTree can replace it later by implementing the same API:
##   set_kind(kind: StringName)
##   set_motion(state: StringName, speed: float, charge: float, vertical_speed: float)
##   set_carrying(on: bool)
##   play_land(impact_speed: float)
## Local forward is -Z, feet are at y = 0.

const KINDS := {
	&"cheese": {
		"base": Color(0.86, 0.52, 0.2),
		"stripe": Color(0.6, 0.29, 0.08),
		"stripe_strength": 0.9,
		"white": Color(0.96, 0.93, 0.87),
		"blaze": false,
	},
	&"tuxedo": {
		"base": Color(0.045, 0.045, 0.055),
		"stripe": Color(0.045, 0.045, 0.055),
		"stripe_strength": 0.0,
		"white": Color(0.95, 0.94, 0.91),
		"blaze": true,
	},
}

const FUR_SHADER := """
shader_type spatial;
uniform vec3 base_color : source_color = vec3(0.86, 0.52, 0.2);
uniform vec3 stripe_color : source_color = vec3(0.6, 0.29, 0.08);
uniform vec3 under_color : source_color = vec3(0.96, 0.93, 0.87);
uniform float stripe_strength = 0.0;
uniform float stripe_freq = 14.0;
uniform vec3 stripe_axis = vec3(0.0, 1.0, 0.0);
uniform vec3 up_axis = vec3(0.0, 0.0, -1.0);
uniform float under_threshold = -2.0;
uniform float stripe_top_only = 1.0;
varying vec3 lp;
varying vec3 ln;
void vertex() {
	lp = VERTEX;
	ln = NORMAL;
}
void fragment() {
	float up = dot(normalize(ln), up_axis);
	float t = dot(lp, stripe_axis) * stripe_freq;
	float wobble = sin(dot(lp, up_axis) * 40.0 + t * 1.7) * 0.18;
	float s = smoothstep(0.35, 0.8, 0.5 + 0.5 * sin((t + wobble) * 6.2831));
	float top = mix(1.0, smoothstep(-0.25, 0.3, up), stripe_top_only);
	vec3 col = mix(base_color, stripe_color, s * stripe_strength * top);
	float under = 1.0 - smoothstep(under_threshold - 0.12, under_threshold + 0.12, up);
	ALBEDO = mix(col, under_color, under);
	ROUGHNESS = 0.9;
	SPECULAR = 0.25;
}
"""

var kind: StringName = &"cheese"
var _shader: Shader
var _fur_materials: Array[ShaderMaterial] = []
var _white_mat: StandardMaterial3D
var _base_mat: StandardMaterial3D
var _blaze: MeshInstance3D

var _rig: Node3D
var _torso: Node3D
var _head: Node3D
var _legs := {}
var _tail: Array[Node3D] = []
var _letter: Node3D

var _state: StringName = &"idle"
var _speed := 0.0
var _charge := 0.0
var _vspeed := 0.0
var _phase := 0.0
var _time := 0.0
var _squash := 0.0
var _air_blend := 0.0


func _ready() -> void:
	_shader = Shader.new()
	_shader.code = FUR_SHADER
	_white_mat = _std(Color(0.96, 0.93, 0.87), 0.9)
	_base_mat = _std(Color(0.86, 0.52, 0.2), 0.9)
	_build()
	set_kind(kind)


func _std(color: Color, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	return m


func _fur(stripe_axis: Vector3, up_axis: Vector3, under_threshold: float, freq: float, top_only: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("stripe_axis", stripe_axis)
	m.set_shader_parameter("up_axis", up_axis)
	m.set_shader_parameter("under_threshold", under_threshold)
	m.set_shader_parameter("stripe_freq", freq)
	m.set_shader_parameter("stripe_top_only", top_only)
	_fur_materials.append(m)
	return m


func _mesh(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, rot := Vector3.ZERO, scl := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	mi.scale = scl
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 16
	s.rings = 8
	return s


func _capsule(r: float, h: float) -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = h
	c.radial_segments = 14
	c.rings = 4
	return c


func _node(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n


func _build() -> void:
	_rig = _node(self, Vector3.ZERO)
	_torso = _node(_rig, Vector3(0, 0.2, 0))
	# Long adult-cat torso lying along Z (capsule axis Y rotated onto Z).
	var torso_mat := _fur(Vector3(0, 1, 0), Vector3(0, 0, -1), -0.3, 14.0, 1.0)
	_mesh(_torso, _capsule(0.085, 0.44), torso_mat, Vector3.ZERO, Vector3(PI / 2, 0, 0), Vector3(0.92, 1.0, 1.0))
	# Chest / shoulders and haunches give the silhouette some shape.
	var chest_mat := _fur(Vector3(1, 0, 0), Vector3(0, 1, 0), -0.15, 10.0, 1.0)
	_mesh(_torso, _sphere(0.088), chest_mat, Vector3(0, 0.0, -0.13), Vector3.ZERO, Vector3(0.95, 1.0, 1.0))
	# Unrotated parts need their own "up" axis for the white-underside mask.
	var haunch_mat := _fur(Vector3(0, 0, 1), Vector3(0, 1, 0), -0.3, 14.0, 1.0)
	_mesh(_torso, _sphere(0.092), haunch_mat, Vector3(0, 0.005, 0.13), Vector3.ZERO, Vector3(1.0, 0.98, 1.05))
	# White bib on the chest (both cats).
	_mesh(_torso, _sphere(0.06), _white_mat, Vector3(0, -0.035, -0.19), Vector3.ZERO, Vector3(0.95, 1.15, 0.7))

	_head = _node(_rig, Vector3(0, 0.305, -0.235))
	var head_mat := _fur(Vector3(1, 0, 0), Vector3(0, 1, 0), -0.55, 38.0, 1.0)
	_mesh(_head, _sphere(0.072), head_mat, Vector3.ZERO, Vector3.ZERO, Vector3(1.05, 0.92, 0.95))
	# Cheeks + muzzle (white), nose (pink), tuxedo blaze.
	_mesh(_head, _sphere(0.034), _white_mat, Vector3(-0.022, -0.026, -0.052), Vector3.ZERO, Vector3(1.0, 0.8, 0.9))
	_mesh(_head, _sphere(0.034), _white_mat, Vector3(0.022, -0.026, -0.052), Vector3.ZERO, Vector3(1.0, 0.8, 0.9))
	_mesh(_head, _sphere(0.02), _white_mat, Vector3(0, -0.045, -0.05), Vector3.ZERO, Vector3(1.0, 0.7, 1.0))
	_blaze = _mesh(_head, _sphere(0.022), _white_mat, Vector3(0, 0.012, -0.06), Vector3(-0.35, 0, 0), Vector3(0.6, 1.7, 0.55))
	var nose := _std(Color(0.93, 0.6, 0.64), 0.6)
	_mesh(_head, _sphere(0.011), nose, Vector3(0, -0.012, -0.083), Vector3.ZERO, Vector3(1.3, 0.8, 0.8))
	var eye := _std(Color(0.66, 0.72, 0.18), 0.25)
	eye.emission_enabled = true
	eye.emission = Color(0.5, 0.58, 0.1)
	eye.emission_energy_multiplier = 0.35
	var pupil := _std(Color(0.02, 0.02, 0.02), 0.2)
	for sx in [-1.0, 1.0]:
		_mesh(_head, _sphere(0.015), eye, Vector3(0.03 * sx, 0.014, -0.058), Vector3.ZERO, Vector3(1.0, 0.95, 0.7))
		_mesh(_head, _sphere(0.008), pupil, Vector3(0.03 * sx, 0.014, -0.069), Vector3.ZERO, Vector3(0.45, 1.2, 0.5))
		var ear := CylinderMesh.new()
		ear.top_radius = 0.002
		ear.bottom_radius = 0.03
		ear.height = 0.065
		ear.radial_segments = 4
		_mesh(_head, ear, _base_mat, Vector3(0.042 * sx, 0.06, 0.0), Vector3(-0.1, PI / 4, 0.32 * sx), Vector3(1.0, 1.0, 0.55))
		var inner := CylinderMesh.new()
		inner.top_radius = 0.001
		inner.bottom_radius = 0.018
		inner.height = 0.045
		inner.radial_segments = 4
		_mesh(_head, inner, nose, Vector3(0.042 * sx, 0.056, -0.012), Vector3(-0.1, PI / 4, 0.32 * sx), Vector3(1.0, 1.0, 0.35))

	# Legs: pivots at shoulders / hips, white paws.
	var leg_mat := _fur(Vector3(0, 1, 0), Vector3(0, 0, -1), -2.0, 30.0, 0.0)
	var defs := {
		&"fl": Vector3(-0.05, 0.17, -0.17), &"fr": Vector3(0.05, 0.17, -0.17),
		&"bl": Vector3(-0.055, 0.18, 0.16), &"br": Vector3(0.055, 0.18, 0.16),
	}
	for key in defs:
		var pivot := _node(_rig, defs[key])
		var hind: bool = String(key).begins_with("b")
		if hind:
			_mesh(pivot, _sphere(0.048), haunch_mat, Vector3(0, -0.02, 0.0), Vector3.ZERO, Vector3(0.8, 1.1, 1.1))
		_mesh(pivot, _capsule(0.021, 0.18), leg_mat, Vector3(0, -0.085, 0))
		_mesh(pivot, _sphere(0.025), _white_mat, Vector3(0, -0.163, -0.008), Vector3.ZERO, Vector3(1.0, 0.65, 1.3))
		_legs[key] = pivot

	# Tail: chain of segments that curls upward.
	var tail_mat := _fur(Vector3(0, 1, 0), Vector3(0, 0, -1), -2.0, 32.0, 0.0)
	var parent: Node3D = _node(_rig, Vector3(0, 0.235, 0.24))
	for i in 6:
		var seg := _node(parent, Vector3.ZERO if i == 0 else Vector3(0, 0.055, 0))
		_mesh(seg, _capsule(0.018 - i * 0.0012, 0.07), tail_mat, Vector3(0, 0.028, 0))
		_tail.append(seg)
		parent = seg

	# Letter carried in the mouth.
	_letter = _node(_head, Vector3(0.0, -0.05, -0.085))
	var paper := _std(Color(0.95, 0.91, 0.8), 0.8)
	var env := BoxMesh.new()
	env.size = Vector3(0.12, 0.006, 0.08)
	_mesh(_letter, env, paper, Vector3(0.025, 0, -0.01), Vector3(0.25, 0.35, 0.1))
	var seal := BoxMesh.new()
	seal.size = Vector3(0.022, 0.008, 0.022)
	_mesh(_letter, seal, _std(Color(0.78, 0.18, 0.2), 0.5), Vector3(0.03, 0.003, -0.012), Vector3(0.25, 1.1, 0.1))
	_letter.visible = false


func set_kind(new_kind: StringName) -> void:
	if not KINDS.has(new_kind):
		return
	kind = new_kind
	if _fur_materials.is_empty():
		return
	var k: Dictionary = KINDS[kind]
	for m in _fur_materials:
		m.set_shader_parameter("base_color", k.base)
		m.set_shader_parameter("stripe_color", k.stripe)
		m.set_shader_parameter("stripe_strength", k.stripe_strength)
		m.set_shader_parameter("under_color", k.white)
	_base_mat.albedo_color = k.base
	_white_mat.albedo_color = k.white
	_blaze.visible = k.blaze


func set_carrying(on: bool) -> void:
	if _letter:
		_letter.visible = on


func is_carrying() -> bool:
	return _letter != null and _letter.visible


func set_motion(state: StringName, speed: float, charge: float, vertical_speed: float) -> void:
	_state = state
	_speed = speed
	_charge = charge
	_vspeed = vertical_speed


func play_land(impact_speed: float) -> void:
	_squash = clampf(impact_speed / 9.0, 0.25, 1.0)


func _process(delta: float) -> void:
	_time += delta
	var moving := _state == &"walk" or _state == &"run" or (_state == &"crouch" and _speed > 0.2)
	var in_air := _state == &"air"
	_air_blend = move_toward(_air_blend, 1.0 if in_air else 0.0, delta * 8.0)
	if moving:
		_phase += delta * (5.0 + _speed * 3.2)
	var stride := clampf(_speed / 3.7, 0.0, 1.0) if moving else 0.0
	var gallop := clampf((_speed - 2.6) / 1.0, 0.0, 1.0)
	var s := sin(_phase)
	var c := sin(_phase + PI)
	# Diagonal walk blending into a bounding run.
	var amp := 0.25 + 0.35 * stride
	var fl := lerpf(s, s, gallop) * amp * stride
	var fr := lerpf(c, s, gallop) * amp * stride
	var bl := lerpf(c, c, gallop) * amp * stride
	var br := lerpf(s, c, gallop) * amp * stride
	# Air pose: reach forward with front legs, push back with hind legs.
	var rising := clampf(_vspeed / 4.0, -1.0, 1.0)
	var air_front := lerpf(0.35, 0.85, maxf(rising, 0.0)) if rising > -0.2 else 0.25
	var air_back := lerpf(-0.2, -0.9, maxf(rising, 0.0))
	_legs[&"fl"].rotation.x = lerpf(fl, air_front, _air_blend)
	_legs[&"fr"].rotation.x = lerpf(fr, air_front, _air_blend)
	_legs[&"bl"].rotation.x = lerpf(bl, air_back, _air_blend)
	_legs[&"br"].rotation.x = lerpf(br, air_back, _air_blend)

	var bob := absf(sin(_phase)) * 0.012 * stride
	var crouch := _charge if _state == &"crouch" else 0.0
	_squash = move_toward(_squash, 0.0, delta * 6.0)
	_rig.position.y = bob - crouch * 0.055 - _squash * 0.035
	_rig.scale = Vector3(1.0 + _squash * 0.06, 1.0 - _squash * 0.12, 1.0 + _squash * 0.04)
	var pitch := lerpf(0.0, rising * 0.25, _air_blend) + crouch * 0.08
	_rig.rotation.x = lerp_angle(_rig.rotation.x, pitch, 1.0 - exp(-delta * 12.0))
	# Breathing when idle.
	var breathe := 0.0 if moving or in_air else sin(_time * 2.2) * 0.012
	_torso.scale = Vector3(1.0, 1.0 + breathe, 1.0)
	_head.rotation.x = -0.08 + crouch * 0.12 + sin(_time * 0.9) * 0.03 * (1.0 - stride)
	_head.rotation.y = sin(_time * 0.55) * 0.12 * (1.0 - stride) * (1.0 - _air_blend)

	# Tail: J-curve hanging back when idle, raised when walking, straight back in the air,
	# fast flick while charging. Rotation is about X: 0 = straight up, PI/2 = straight back.
	var sway_speed := 1.4 + crouch * 9.0
	var sway := sin(_time * sway_speed) * (0.16 + crouch * 0.14)
	var base := lerpf(lerpf(2.1, 0.45, stride) + crouch * 0.35, 1.45, _air_blend)
	var curl := lerpf(lerpf(-0.25, -0.08, stride), -0.03, _air_blend)
	for i in _tail.size():
		var seg: Node3D = _tail[i]
		if i == 0:
			seg.rotation = Vector3(base, sway, 0.0)
		else:
			seg.rotation = Vector3(curl, sway * 0.35, 0.0)
