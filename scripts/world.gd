class_name AlleyWorld
extends Node3D
## First alley of Midnight Cat Delivery: level geometry, letter pickup/delivery,
## checkpoints and fall recovery, game flow (title / playing / paused / complete),
## focus & pointer-capture handling, and the optional ?qa=1 read-only diagnostics on web.

const SPAWN := Vector3(0.0, 0.0, 2.2)
const LETTER_POS := Vector3(-2.2, 0.0, -0.4)
const DELIVERY_POS := Vector3(3.32, 4.3, -15.5)
const PICKUP_RANGE := 0.85
const DELIVER_RANGE := 0.9
const FALL_LIMIT_Y := -4.0
const ACTIONS: Array[StringName] = [&"left", &"right", &"forward", &"back", &"jump", &"sprint",
	&"interact", &"switch_cat", &"sense", &"reset", &"pause", &"look_left", &"look_right", &"look_up", &"look_down"]

## Route platforms in play order. "top" is where the cat stands; "spawn" is the safe point.
const ROUTE := [
	{"id": "box", "name": "낮은 상자", "center": Vector3(1.75, 0.25, -3.2), "size": Vector3(0.9, 0.5, 0.9), "spawn": Vector3(1.75, 0.5, -3.2)},
	{"id": "wall", "name": "담장", "center": Vector3(2.55, 0.65, -6.4), "size": Vector3(0.5, 1.3, 6.0), "spawn": Vector3(2.55, 1.3, -4.2)},
	{"id": "ac", "name": "실외기", "center": Vector3(3.325, 1.8, -8.0), "size": Vector3(0.55, 0.6, 0.85), "spawn": Vector3(3.33, 2.1, -8.0)},
	{"id": "ledge", "name": "좁은 난간", "center": Vector3(3.425, 2.825, -11.0), "size": Vector3(0.35, 0.15, 4.0), "spawn": Vector3(3.43, 2.9, -9.4)},
	{"id": "sign", "name": "간판", "center": Vector3(3.0, 3.35, -13.75), "size": Vector3(1.2, 0.5, 0.6), "spawn": Vector3(3.15, 3.6, -13.75)},
	{"id": "sill", "name": "302호 창턱", "center": Vector3(3.3, 4.225, -15.6), "size": Vector3(0.6, 0.15, 2.2), "spawn": Vector3(3.3, 4.3, -14.9)},
]

const CATS := {
	&"cheese": "치즈 · 따뜻하고 용감한 배달부",
	&"tuxedo": "턱시도 · 조용하지만 호기심 많은 탐험가",
}

enum State { TITLE, PLAYING, PAUSED, COMPLETE }

var state := State.TITLE
var player: CatPlayer
var hud: GameHud
var touch: TouchControls
var cat_kind: StringName = &"cheese"
var has_letter := false
var delivered := false
var started := false
var safe_point := SPAWN
var platform_index := -1
var smoke_test := false
var qa_mode := false

var _letter: Node3D
var _letter_light: OmniLight3D
var _window_glass: StandardMaterial3D
var _window_light: OmniLight3D
var _room_label: Label3D
var _markers: Array[Node3D] = []
var _beam: MeshInstance3D
var _marker_left := 0.0
var _was_captured := false
var _last_toggle_ms := -10000
var _js_callbacks: Array = []
var _font: Font
var _grime: ImageTexture
var _mats := {}
var _moon: DirectionalLight3D
var _env: Environment


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	smoke_test = OS.get_cmdline_user_args().has("--smoke-test")
	_font = load("res://assets/fonts/ui_font.ttf")
	_build_environment()
	_build_level()
	_build_letter_and_window()
	_build_route_markers()

	player = CatPlayer.new()
	player.name = "Player"
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(player)
	player.respawn(SPAWN, 0.0)
	player.landed.connect(_on_player_landed)

	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	touch = TouchControls.new()
	touch.name = "TouchControls"
	layer.add_child(touch)
	hud = GameHud.new()
	hud.name = "Hud"
	layer.add_child(hud)
	touch.player = player
	touch.ui_buttons = hud.get_touch_buttons
	player.touch = touch
	touch.touch_mode_changed.connect(_on_touch_mode_changed)
	hud.start_pressed.connect(_on_start)
	hud.restart_pressed.connect(_on_restart)
	hud.pause_pressed.connect(func(): pause_game())
	hud.resume_pressed.connect(resume_game)
	hud.home_pressed.connect(go_home)
	hud.explore_pressed.connect(resume_game)
	get_viewport().size_changed.connect(_on_viewport_resized)

	var coarse := OS.has_feature("mobile")
	if OS.has_feature("web"):
		_setup_web()
		coarse = coarse or bool(JavaScriptBridge.eval("window.matchMedia('(pointer: coarse)').matches", true))
	touch.set_enabled(coarse)
	_on_touch_mode_changed(touch.enabled)
	player.set_kind(cat_kind)
	_update_status()

	# The web shell already shows the title/start screen, so the web build starts playing.
	if OS.has_feature("web") or smoke_test:
		_start_new()
	else:
		_set_state(State.TITLE)
	if smoke_test:
		var t: Node = load("res://scripts/qa/smoke_test.gd").new()
		t.name = "SmokeTest"
		add_child(t)


# ---------------------------------------------------------------- level building

func _mat(key: String, color: Color, roughness := 0.9, grime := true) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	if grime:
		m.albedo_texture = _grime
		m.uv1_triplanar = true
		m.uv1_scale = Vector3(0.45, 0.45, 0.45)
	_mats[key] = m
	return m


func _glow(color: Color, energy := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if energy != 1.0:
		m.albedo_color = Color(color.r * energy, color.g * energy, color.b * energy)
	return m


func _mesh_box(center: Vector3, size: Vector3, mat: Material, parent: Node = self) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = center
	parent.add_child(mi)
	return mi


## Static box with collision on layer 1 (world).
func _solid(center: Vector3, size: Vector3, mat: Material, meta := {}) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = center
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	for k in meta:
		body.set_meta(k, meta[k])
	add_child(body)
	_mesh_box(Vector3.ZERO, size, mat, body)
	return body


func _cyl(pos: Vector3, radius: float, height: float, mat: Material, parent: Node = self) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 10
	cm.rings = 1
	mi.mesh = cm
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _make_grime() -> ImageTexture:
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.frequency = 0.06
	noise.fractal_octaves = 3
	var img := noise.get_seamless_image(128, 128)
	img.convert(Image.FORMAT_RGB8)
	for y in img.get_height():
		for x in img.get_width():
			var v := img.get_pixel(x, y).r
			var g := 0.72 + v * 0.28
			img.set_pixel(x, y, Color(g, g, g))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _build_environment() -> void:
	_grime = _make_grime()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.02, 0.03, 0.08)
	sky_mat.sky_horizon_color = Color(0.13, 0.13, 0.22)
	sky_mat.ground_horizon_color = Color(0.1, 0.09, 0.14)
	sky_mat.ground_bottom_color = Color(0.03, 0.03, 0.05)
	sky_mat.sky_energy_multiplier = 0.9
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.32, 0.36, 0.55)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.09, 0.1, 0.17)
	env.fog_density = 0.012
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	_env = env
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_moon = DirectionalLight3D.new()
	_moon.light_color = Color(0.62, 0.7, 1.0)
	_moon.light_energy = 0.45
	_moon.rotation = Vector3(deg_to_rad(-52.0), deg_to_rad(-35.0), 0.0)
	_moon.directional_shadow_max_distance = 24.0
	_moon.shadow_enabled = false
	add_child(_moon)

	var moon := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 4.0
	sm.height = 8.0
	moon.mesh = sm
	moon.material_override = _glow(Color(1.0, 0.92, 0.72), 1.3)
	moon.position = Vector3(-34.0, 36.0, -95.0)
	add_child(moon)


func _build_level() -> void:
	var asphalt := _mat("asphalt", Color(0.13, 0.135, 0.15))
	var plaster_r := _mat("plaster_r", Color(0.42, 0.37, 0.33))
	var plaster_l := _mat("plaster_l", Color(0.33, 0.3, 0.3))
	var concrete := _mat("concrete", Color(0.48, 0.46, 0.43))
	var crate := _mat("crate", Color(0.55, 0.36, 0.2))
	var ac := _mat("ac", Color(0.8, 0.8, 0.77), 0.6)
	var metal := _mat("metal", Color(0.36, 0.37, 0.4), 0.5)
	var dark := _mat("dark", Color(0.08, 0.08, 0.1), 0.8, false)

	# Ground, buildings, closed back end. The far end opens onto the city (fall-out zone).
	_solid(Vector3(0.0, -0.25, -7.5), Vector3(7.2, 0.5, 23.0), asphalt, {"spawn": SPAWN, "route_index": -1})
	_solid(Vector3(6.8, 3.4, -7.5), Vector3(6.4, 6.8, 23.0), plaster_r)
	_solid(Vector3(-6.5, 3.75, -7.5), Vector3(7.0, 7.5, 23.0), plaster_l)
	_solid(Vector3(0.0, 1.5, 4.3), Vector3(7.2, 3.0, 0.6), concrete)
	_solid(Vector3(0.0, 0.2, -19.15), Vector3(7.2, 0.4, 0.3), concrete)
	_mesh_box(Vector3(0.0, 0.02, -7.5), Vector3(0.25, 0.02, 22.0), _mat("drain", Color(0.09, 0.09, 0.1), 0.8, false))

	# Route platforms (collision + checkpoints).
	for i in ROUTE.size():
		var r: Dictionary = ROUTE[i]
		var mat: Material = concrete
		match r.id:
			"box":
				mat = crate
			"ac":
				mat = ac
			"ledge":
				mat = metal
			"sign":
				mat = _glow(Color(0.2, 0.75, 0.8), 0.9)
			"sill":
				mat = concrete
		_solid(r.center, r.size, mat, {"spawn": r.spawn, "route_index": i})

	# Platform details.
	_mesh_box(Vector3(1.75, 0.505, -3.2), Vector3(0.92, 0.01, 0.08), dark)
	var fan := _cyl(Vector3(3.04, 1.82, -8.0), 0.2, 0.02, dark)
	fan.rotation = Vector3(0, 0, PI / 2)
	_mesh_box(Vector3(2.38, 3.35, -13.75), Vector3(0.02, 0.36, 0.45), _glow(Color(0.95, 0.4, 0.55), 1.1))
	var sign_text := Label3D.new()
	sign_text.font = _font
	sign_text.text = "달빛 세탁"
	sign_text.font_size = 64
	sign_text.pixel_size = 0.0028
	sign_text.modulate = Color(0.08, 0.1, 0.16)
	sign_text.outline_size = 0
	sign_text.position = Vector3(3.0, 3.35, -13.43)
	add_child(sign_text)
	var sign_light := OmniLight3D.new()
	sign_light.light_color = Color(0.4, 0.85, 0.9)
	sign_light.light_energy = 0.9
	sign_light.omni_range = 3.2
	sign_light.position = Vector3(2.7, 3.2, -13.0)
	add_child(sign_light)
	# Railing posts along the ledge.
	for z in [-9.2, -10.6, -12.0]:
		_mesh_box(Vector3(3.58, 2.65, z), Vector3(0.04, 0.3, 0.04), metal)

	# Street furniture.
	_mesh_box(Vector3(-2.82, 0.35, -0.4), Vector3(0.08, 0.7, 0.08), metal)
	_mesh_box(Vector3(-2.82, 0.95, -0.4), Vector3(0.36, 0.5, 0.3), _mat("mailbox", Color(0.72, 0.15, 0.13), 0.6, false))
	_mesh_box(Vector3(-2.63, 1.05, -0.4), Vector3(0.01, 0.04, 0.2), dark)
	_mesh_box(Vector3(-2.97, 1.0, 0.8), Vector3(0.06, 2.0, 0.95), _mat("door", Color(0.22, 0.17, 0.14), 0.7, false))
	for p in [Vector3(-2.6, 0, -3.5), Vector3(-2.65, 0, -11.5)]:
		_lamp_post(p)
	_wall_lamp(Vector3(-2.95, 2.3, -0.4))
	_wall_lamp(Vector3(3.55, 2.0, -2.0), true)
	for p in [Vector3(-2.5, 0.0, -7.8), Vector3(-2.4, 0.0, -16.5), Vector3(1.0, 0.0, 3.3)]:
		_plant(p)
	for p in [Vector3(-2.6, 0.18, -5.6), Vector3(-2.3, 0.15, -5.3), Vector3(2.0, 0.16, -17.8)]:
		var bag := MeshInstance3D.new()
		var s := SphereMesh.new()
		s.radius = 0.22
		s.height = 0.36
		bag.mesh = s
		bag.material_override = _mat("bag", Color(0.06, 0.06, 0.07), 0.4, false)
		bag.position = p
		add_child(bag)
	# Utility pole and wires (silhouettes against the sky).
	_mesh_box(Vector3(-2.7, 3.2, -9.4), Vector3(0.18, 6.4, 0.18), dark)
	_mesh_box(Vector3(-2.7, 5.8, -9.4), Vector3(1.2, 0.08, 0.08), dark)
	for i in 3:
		var w := _mesh_box(Vector3(0.45, 5.6 - i * 0.18, -9.4 - i * 0.2), Vector3(6.4, 0.02, 0.02), dark)
		w.rotation.y = 0.12 + i * 0.05

	_build_windows()
	_build_city()


func _lamp_post(base: Vector3) -> void:
	var dark := _mat("dark", Color(0.08, 0.08, 0.1), 0.8, false)
	_cyl(base + Vector3(0, 1.6, 0), 0.05, 3.2, dark)
	_mesh_box(base + Vector3(0.3, 3.2, 0), Vector3(0.7, 0.06, 0.06), dark)
	_mesh_box(base + Vector3(0.6, 3.12, 0), Vector3(0.24, 0.1, 0.18), _glow(Color(1.0, 0.82, 0.55), 1.4))
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.72, 0.42)
	l.light_energy = 1.9
	l.omni_range = 7.5
	l.omni_attenuation = 1.2
	l.position = base + Vector3(0.6, 2.95, 0)
	add_child(l)


func _wall_lamp(pos: Vector3, right_side := false) -> void:
	_mesh_box(pos, Vector3(0.12, 0.14, 0.2), _glow(Color(1.0, 0.85, 0.6), 1.3))
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.75, 0.45)
	l.light_energy = 1.2
	l.omni_range = 4.0
	l.position = pos + Vector3(-0.35 if right_side else 0.35, -0.1, 0)
	add_child(l)


func _plant(p: Vector3) -> void:
	_cyl(p + Vector3(0, 0.15, 0), 0.17, 0.3, _mat("pot", Color(0.45, 0.25, 0.18), 0.8, false))
	var leaf := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.28
	s.height = 0.45
	leaf.mesh = s
	leaf.material_override = _mat("leaf", Color(0.14, 0.27, 0.15), 0.9, false)
	leaf.position = p + Vector3(0, 0.48, 0)
	add_child(leaf)


## Lit/unlit windows on both facades as two MultiMeshes (2 draw calls).
func _build_windows() -> void:
	var lit: Array[Transform3D] = []
	var unlit: Array[Transform3D] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 302
	for side in [-1, 1]:
		var x := -2.99 if side < 0 else 3.59
		var yaw := PI / 2 if side < 0 else -PI / 2
		for z in range(1, 19):
			var zz := 2.0 - z * 1.15
			for y in [1.3, 3.0, 4.9, 6.4]:
				if side > 0 and y > 6.2:
					continue
				if side > 0 and zz < -7.0 and zz > -17.0 and y < 5.6:
					continue  # keep the climbing route readable (302 has its own window)
				if side > 0 and absf(zz + 2.0) < 0.7 and y < 2.0:
					continue
				var t := Transform3D(Basis(Vector3.UP, yaw), Vector3(x, y, zz))
				if rng.randf() < 0.42:
					lit.append(t)
				else:
					unlit.append(t)
	_multimesh(lit, Vector2(0.62, 0.8), _glow(Color(1.0, 0.76, 0.45), 1.0))
	_multimesh(unlit, Vector2(0.62, 0.8), _mat("glass", Color(0.07, 0.08, 0.11), 0.2, false))


func _multimesh(xforms: Array[Transform3D], size: Vector2, mat: Material) -> void:
	var q := QuadMesh.new()
	q.size = size
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = q
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


## Distant city below the end of the alley (decoration only, no collision).
func _build_city() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var dark := _mat("city", Color(0.05, 0.055, 0.08), 1.0, false)
	var lights: Array[Transform3D] = []
	for i in 34:
		var x := rng.randf_range(-45.0, 45.0)
		var z := rng.randf_range(-32.0, -95.0)
		var w := rng.randf_range(4.0, 9.0)
		var top := rng.randf_range(-14.0, 4.0)
		var h := top + 40.0
		_mesh_box(Vector3(x, top - h * 0.5, z), Vector3(w, h, w), dark)
		for k in 7:
			var ly := top - rng.randf_range(1.0, 14.0)
			var lx := x + rng.randf_range(-w * 0.4, w * 0.4)
			lights.append(Transform3D(Basis(), Vector3(lx, ly, z + w * 0.5 + 0.05)))
	_multimesh(lights, Vector2(0.9, 1.1), _glow(Color(1.0, 0.78, 0.5), 1.2))


func _build_letter_and_window() -> void:
	_letter = Node3D.new()
	add_child(_letter)
	var paper := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.24, 0.012, 0.16)
	paper.mesh = bm
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.97, 0.93, 0.82)
	pm.emission_enabled = true
	pm.emission = Color(0.55, 0.48, 0.3)
	pm.emission_energy_multiplier = 0.6
	paper.material_override = pm
	_letter.add_child(paper)
	var seal := MeshInstance3D.new()
	var sb := BoxMesh.new()
	sb.size = Vector3(0.045, 0.016, 0.045)
	seal.mesh = sb
	seal.material_override = _glow(Color(0.8, 0.2, 0.22))
	seal.position = Vector3(0, 0.004, 0)
	_letter.add_child(seal)
	_letter_light = OmniLight3D.new()
	_letter_light.light_color = Color(1.0, 0.9, 0.65)
	_letter_light.light_energy = 0.8
	_letter_light.omni_range = 1.6
	_letter_light.position = Vector3(0, 0.35, 0)
	_letter.add_child(_letter_light)

	# 302 window: frame, glass that lights up after delivery, room light, number plate, plant.
	var frame := _mat("frame", Color(0.75, 0.72, 0.66), 0.7, false)
	_mesh_box(Vector3(3.585, 4.95, -15.5), Vector3(0.05, 1.22, 1.32), frame)
	_window_glass = StandardMaterial3D.new()
	_window_glass.albedo_color = Color(0.06, 0.07, 0.1)
	_window_glass.roughness = 0.15
	_window_glass.emission_enabled = true
	_window_glass.emission = Color(1.0, 0.72, 0.4)
	_window_glass.emission_energy_multiplier = 0.0
	_mesh_box(Vector3(3.56, 4.95, -15.5), Vector3(0.02, 1.08, 1.18), _window_glass)
	_mesh_box(Vector3(3.55, 4.95, -15.5), Vector3(0.025, 1.08, 0.04), frame)
	_window_light = OmniLight3D.new()
	_window_light.light_color = Color(1.0, 0.72, 0.42)
	_window_light.light_energy = 0.0
	_window_light.omni_range = 4.5
	_window_light.position = Vector3(3.2, 4.95, -15.5)
	add_child(_window_light)
	_room_label = Label3D.new()
	_room_label.font = _font
	_room_label.text = "302"
	_room_label.font_size = 64
	_room_label.pixel_size = 0.004
	_room_label.modulate = Color(0.9, 0.85, 0.7)
	_room_label.position = Vector3(3.57, 5.75, -15.5)
	_room_label.rotation.y = -PI / 2
	add_child(_room_label)
	_plant(Vector3(3.35, 4.3, -16.35))


func _build_route_markers() -> void:
	var mat := _glow(Color(1.0, 0.75, 0.3), 1.6)
	for i in 3:
		var paw := Node3D.new()
		for j in 5:
			var pad := MeshInstance3D.new()
			var c := CylinderMesh.new()
			var big := j == 0
			c.top_radius = 0.045 if big else 0.02
			c.bottom_radius = c.top_radius
			c.height = 0.006
			c.radial_segments = 10
			pad.mesh = c
			pad.material_override = mat
			pad.position = Vector3.ZERO if big else Vector3((j - 2.5) * 0.028, 0, -0.06 + absf(j - 2.5) * 0.012)
			paw.add_child(pad)
		paw.visible = false
		add_child(paw)
		_markers.append(paw)
	_beam = MeshInstance3D.new()
	var bc := CylinderMesh.new()
	bc.top_radius = 0.02
	bc.bottom_radius = 0.12
	bc.height = 2.5
	_beam.mesh = bc
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(1.0, 0.75, 0.3, 0.28)
	bmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_beam.material_override = bmat
	_beam.visible = false
	add_child(_beam)


# ---------------------------------------------------------------- game flow

func _set_state(s: State) -> void:
	state = s
	var playing := s == State.PLAYING
	get_tree().paused = not playing
	player.input_enabled = playing
	player.reset_inputs()
	touch.gameplay_active = playing
	touch.queue_redraw()
	var names := {State.TITLE: &"title", State.PLAYING: &"playing", State.PAUSED: &"paused", State.COMPLETE: &"complete"}
	hud.set_state(names[s], started and not delivered)
	if not playing:
		_release_inputs()
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_was_captured = false
	_last_toggle_ms = Time.get_ticks_msec()


func _release_inputs() -> void:
	for a in ACTIONS:
		if InputMap.has_action(a):
			Input.action_release(a)
	touch.reset_touches()
	player.reset_inputs()


func _start_new() -> void:
	started = true
	has_letter = false
	delivered = false
	platform_index = -1
	safe_point = SPAWN
	_letter.visible = true
	_letter.position = LETTER_POS + Vector3(0, 0.03, 0)
	_letter.rotation = Vector3(0, 0.4, 0)
	_letter_light.visible = true
	_window_glass.emission_energy_multiplier = 0.0
	_window_glass.albedo_color = Color(0.06, 0.07, 0.1)
	_window_light.light_energy = 0.0
	_window_light.visible = false
	_room_label.modulate = Color(0.9, 0.85, 0.7)
	_marker_left = 0.0
	player.visual.set_carrying(false)
	player.respawn(SPAWN, 0.0)
	_update_status()
	_set_state(State.PLAYING)
	hud.toast("편지를 받아 302호에 배달하세요")


func _on_start() -> void:
	if started and not delivered:
		resume_game()
	else:
		_start_new()


func _on_restart() -> void:
	_start_new()


func pause_game() -> void:
	if state == State.PLAYING:
		_set_state(State.PAUSED)


func resume_game() -> void:
	if hud.is_portrait_blocked():
		return
	if state != State.PLAYING:
		_set_state(State.PLAYING)


func go_home() -> void:
	_set_state(State.TITLE)


func _toggle_pause() -> void:
	if Time.get_ticks_msec() - _last_toggle_ms < 350:
		return
	if state == State.PLAYING:
		pause_game()
	elif state == State.PAUSED:
		resume_game()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_on_focus_lost()


func _on_focus_lost() -> void:
	if player == null:
		return
	_release_inputs()
	if state == State.PLAYING:
		pause_game()


func _on_viewport_resized() -> void:
	touch.reset_touches()
	if hud.is_portrait_blocked() and state == State.PLAYING:
		pause_game()


func _on_touch_mode_changed(on: bool) -> void:
	hud.set_touch_mode(on)
	# Phones: skip the dynamic shadow map and the glow passes.
	_moon.shadow_enabled = not on
	_env.glow_enabled = not on
	_update_status()
	if hud.is_portrait_blocked() and state == State.PLAYING:
		pause_game()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		_toggle_pause()
		get_viewport().set_input_as_handled()
		return
	if state != State.PLAYING:
		if event.is_action_pressed("ui_accept"):
			if state == State.TITLE:
				_on_start()
			elif state == State.PAUSED:
				resume_game()
			elif state == State.COMPLETE:
				resume_game()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# Capture only from a click on the game itself (HUD buttons consume their clicks first).
		if not touch.enabled and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("interact"):
		_interact()
	elif event.is_action_pressed("switch_cat"):
		_switch_cat()
	elif event.is_action_pressed("sense"):
		_show_route()
	elif event.is_action_pressed("reset"):
		_respawn("마지막 안전한 곳으로 돌아왔어요")


# ---------------------------------------------------------------- gameplay

func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func can_pickup() -> bool:
	var p := player.global_position
	return not has_letter and not delivered and _flat_dist(p, LETTER_POS) < PICKUP_RANGE and absf(p.y - LETTER_POS.y) < 0.6


func can_deliver() -> bool:
	var p := player.global_position
	return has_letter and not delivered and _flat_dist(p, DELIVERY_POS) < DELIVER_RANGE and absf(p.y - DELIVERY_POS.y) < 0.45


func _interact() -> void:
	if can_pickup():
		has_letter = true
		_letter.visible = false
		player.visual.set_carrying(true)
		hud.toast("편지를 물었다! 302호 창문으로 가요")
	elif can_deliver():
		_deliver()
	elif not has_letter and not delivered:
		hud.toast("편지가 없어요. 우체통 옆에서 편지를 먼저 받으세요", 1.8)
	elif has_letter:
		hud.toast("302호 창문 앞에서 전달할 수 있어요", 1.8)
	_update_status()


func _deliver() -> void:
	has_letter = false
	delivered = true
	player.visual.set_carrying(false)
	_letter.visible = true
	_letter_light.visible = false
	_letter.position = Vector3(3.45, 4.31, -15.15)
	_letter.rotation = Vector3(0, -0.3, 0)
	_window_light.visible = true
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_window_glass, "emission_energy_multiplier", 1.6, 1.2)
	tw.tween_property(_window_glass, "albedo_color", Color(0.85, 0.6, 0.35), 1.2)
	tw.tween_property(_window_light, "light_energy", 2.6, 1.2)
	tw.tween_property(_room_label, "modulate", Color(1.0, 0.8, 0.45), 1.2)
	hud.toast("배달 완료! 302호에 불이 켜졌어요", 3.0)
	_update_status()
	if not smoke_test:
		get_tree().create_timer(2.2, false).timeout.connect(func():
			if state == State.PLAYING and delivered:
				_set_state(State.COMPLETE))


func _switch_cat() -> void:
	cat_kind = &"tuxedo" if cat_kind == &"cheese" else &"cheese"
	player.set_kind(cat_kind)
	hud.toast("턱시도로 교체" if cat_kind == &"tuxedo" else "치즈로 교체", 1.2)
	_update_status()


func _respawn(message: String) -> void:
	var yaw := player.cam_yaw
	player.respawn(safe_point, yaw)
	hud.toast(message, 1.8)


func _on_player_landed(_impact: float) -> void:
	_update_checkpoint()


func _update_checkpoint() -> void:
	var c := player_floor_collider()
	if c and c.has_meta("spawn"):
		safe_point = c.get_meta("spawn")
		platform_index = c.get_meta("route_index")


func player_floor_collider() -> Object:
	if not player.is_on_floor():
		return null
	for i in player.get_slide_collision_count():
		var col := player.get_slide_collision(i)
		if col.get_normal().y > 0.7:
			return col.get_collider()
	return null


func _next_target() -> Dictionary:
	if delivered:
		return {}
	if not has_letter:
		return {"pos": LETTER_POS, "name": "편지"}
	var i := clampi(platform_index + 1, 0, ROUTE.size() - 1)
	if platform_index >= ROUTE.size() - 1:
		return {"pos": DELIVERY_POS, "name": "302호 창문"}
	var r: Dictionary = ROUTE[i]
	return {"pos": r.spawn, "name": r.name}


func _show_route() -> void:
	var t := _next_target()
	if t.is_empty():
		hud.toast("오늘 배달은 끝났어요", 1.5)
		return
	var target: Vector3 = t.pos
	var from := player.global_position
	for i in _markers.size():
		var k := float(i + 1) / float(_markers.size())
		var p := from.lerp(target, k)
		p.y = target.y + 0.01 if i == _markers.size() - 1 else lerpf(from.y, target.y, k) + 0.01
		_markers[i].position = p
		_markers[i].rotation.y = atan2(-(target.x - from.x), -(target.z - from.z))
		_markers[i].visible = i == _markers.size() - 1
	_beam.position = target + Vector3(0, 1.25, 0)
	_beam.visible = true
	_marker_left = 5.0
	hud.toast("길 안내: 다음은 %s" % t.name, 2.0)


func _update_status() -> void:
	if hud == null:
		return
	var obj := ""
	if delivered:
		obj = "배달 완료! 302호에 불이 켜졌어요"
	elif has_letter:
		obj = "목표: 302호 창문까지 편지를 배달하세요"
	else:
		obj = "목표: 우체통 옆 편지를 물어오세요"
	hud.set_status(CATS[cat_kind], obj)


func _physics_process(_delta: float) -> void:
	if state != State.PLAYING:
		return
	if player.global_position.y < FALL_LIMIT_Y:
		_respawn("떨어졌어요! 안전한 곳으로 돌아왔어요")
	elif player.is_on_floor():
		_update_checkpoint()


func _process(delta: float) -> void:
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if captured:
		_was_captured = true
	elif _was_captured:
		# Esc / browser released pointer lock: pause, and never grab the pointer back by itself.
		_was_captured = false
		if state == State.PLAYING:
			pause_game()

	if state == State.PLAYING:
		if _letter.visible and not delivered:
			_letter.position.y = LETTER_POS.y + 0.03 + absf(sin(Time.get_ticks_msec() * 0.003)) * 0.04
		var prompt := ""
		var key := "LETTER" if touch.enabled else "[E]"
		if can_pickup():
			prompt = "%s 편지 물기" % key
		elif can_deliver():
			prompt = "%s 편지 전달하기" % key
		hud.set_prompt(prompt)
		hud.set_charge(player.charging, player.charge)
		if _marker_left > 0.0:
			_marker_left -= delta
			var blink := fmod(_marker_left, 0.6) > 0.15
			for i in _markers.size():
				_markers[i].visible = _marker_left > 0.0 and (i == _markers.size() - 1 or blink)
			_beam.visible = _marker_left > 0.0
	if qa_mode:
		_publish_qa()


# ---------------------------------------------------------------- web integration

func _setup_web() -> void:
	var window := JavaScriptBridge.get_interface("window")
	var document := JavaScriptBridge.get_interface("document")
	if window == null or document == null:
		return
	var on_blur := JavaScriptBridge.create_callback(func(_args): _on_focus_lost())
	var on_visibility := JavaScriptBridge.create_callback(func(_args):
		if str(document.visibilityState) == "hidden":
			_on_focus_lost())
	var on_cancel := JavaScriptBridge.create_callback(func(_args): touch.cancel_all())
	_js_callbacks = [on_blur, on_visibility, on_cancel]
	window.addEventListener("blur", on_blur)
	document.addEventListener("visibilitychange", on_visibility)
	var canvas = document.getElementById("canvas")
	if canvas:
		canvas.addEventListener("touchcancel", on_cancel, true)
	qa_mode = bool(JavaScriptBridge.eval("new URLSearchParams(window.location.search).has('qa')", true))


## Read-only snapshot for browser tests (only with ?qa=1). Never changes game state.
func _publish_qa() -> void:
	var p := player.global_position
	var v := player.velocity
	var btns := {}
	for b: Button in hud.get_touch_buttons():
		if b.is_visible_in_tree():
			var r := b.get_global_rect()
			btns[b.text] = [r.position.x, r.position.y, r.size.x, r.size.y]
	var vp := get_viewport().get_visible_rect().size
	var data := {
		"state": ["title", "playing", "paused", "complete"][state],
		"pos": [p.x, p.y, p.z], "vel": [v.x, v.y, v.z], "on_floor": player.is_on_floor(),
		"move_state": String(player.move_state), "charging": player.charging, "charge": player.charge,
		"jumps": player.jump_count, "cat": String(cat_kind), "has_letter": has_letter,
		"carrying_visible": player.visual.is_carrying(), "delivered": delivered,
		"window_light": _window_light.light_energy, "platform": platform_index,
		"cam_yaw": player.cam_yaw, "cam_pitch": player.cam_pitch,
		"captured": Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "touch": touch.enabled,
		"stick": [touch.stick_vector.x, touch.stick_vector.y], "jump_held": touch.jump_held, "run_on": touch.run_on,
		"vp": [vp.x, vp.y], "touch_layout": touch.get_layout(), "hud_buttons": btns,
		"prompt": hud.prompt_label.text if hud.prompt_panel.visible else "",
		"portrait_blocked": hud.is_portrait_blocked(), "fps": Engine.get_frames_per_second(),
		"frame": Engine.get_process_frames(), "physics_frame": Engine.get_physics_frames(),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
	}
	var window := JavaScriptBridge.get_interface("window")
	if window:
		window.mcdQA = JSON.stringify(data)
