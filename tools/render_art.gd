extends SceneTree
## Renders SLOT's pictures: a HOBBY ROOM with a slot-car layout on a big wooden table. The layout is a
## real (low-poly, 3D) slot track -- four lanes of plastic road with their slots and copper braids on a
## green baseboard, the current glowing in the braids behind every car under power -- raced by the
## game's own car models; round it, a plank floor and a rug, panelled walls, shelves of boxed sets and
## trophies, a window on the night, lamps hung low over the table, and the four hand
## controllers wired to their power base at the start line.
##
## Writes (into res://art/):
##   splash.png       1920x1080, no lettering  -- the boot splash
##   menu_bg.png      1920x1080, no title      -- the title screen (and help / settings)
##   bg_garage.png    the start line and its gantry, low and calm  -- car select
##   bg_tracks.png    the whole layout from high above            -- track select
##   icon_render.png  a car on its lane, on transparent -- tools/make_icons.py makes the icons from it
##
## Needs a real renderer (not --headless):
##   godot --path . --script res://tools/render_art.gd
## Deterministic: the same pictures every time.

const W := 1920
const H := 1080
const LANES := [-60.0, -20.0, 20.0, 60.0]
const HALF := 84.0             # road half width (the game's SlotTrack.ROAD_HALF)
const BORDER := 12.0
const TRACK_H := 4.0           # the plastic's thickness on the board
const CAR_SCALE := 1.7
const STEP := 6.0              # path sampling
const BEND_R := 330.0
## The table top (world y) the layout sits on, and the board's extent in the layout's own XZ.
const TABLE_Y := 300.0
const BOARD := Rect2(-210, -540, 1080, 1600)
## The room, in world XZ (the table is in the middle of it), and its height.
const ROOM := Rect2(-1000, -1400, 2660, 3300)
const ROOM_H := 1000.0

var _vp: SubViewport
var _world: Node3D
## Where new geometry goes: the room itself, or the table top (the layout is built in its own frame).
var _parent: Node3D
var _table: Node3D
var _camera: Camera3D
var _path := PackedVector2Array()
var _nrm := PackedVector2Array()
var _mats := {}


func _init() -> void:
	await process_frame
	_build_path()
	# ART_TRY=1: render camera candidates for the key art into build/ and stop.
	if OS.get_environment("ART_TRY") != "":
		_new_stage(960, 540, false)
		_build_room()
		_build_layout()
		_race_cars()
		var tries := [
			[Vector3(1350, 720, -1100), Vector3(300, 300, 300)],
			[Vector3(1150, 520, -820), Vector3(240, 330, 60)],
			[Vector3(560, 380, -560), Vector3(260, 310, -250)],
			[Vector3(700, 640, -1250), Vector3(100, 420, 900)],
			[Vector3(-820, 620, -300), Vector3(600, 380, 400)],
			[Vector3(-120, 400, -700), Vector3(320, 360, 600)],
		]
		for k in tries.size():
			_camera.position = tries[k][0]
			_camera.look_at(tries[k][1], Vector3.UP)
			var img := await _grab()
			img.save_png(ProjectSettings.globalize_path("res://build/art_try_%d.png" % k))
		quit()
		return
	if OS.get_environment("ART_ICON_ONLY") == "":
		# The key art: the hobby room, the pack coming out of the bend, one car leaving the slot.
		_new_stage(W, H, false)
		_build_room()
		_build_layout()
		_race_cars()
		_key_camera()
		# No lettering in any picture: the splash is the same scene as the title screen's background.
		await _save("res://art/splash.png")
		await _save("res://art/menu_bg.png")

		# Car select: by the controllers and the start line, the grid empty but for one car waiting.
		_new_stage(W, H, true)
		_build_room()
		_build_layout()
		_car("sport", Color(0.15, 0.42, 0.92), _index_at(-0.03), 20.0, 0.0, false)
		_build_vignette()
		_garage_camera()
		await _save("res://art/bg_garage.png")

		# Track select: the whole table from up in the corner of the room.
		_new_stage(W, H, true)
		_build_room()
		_build_layout()
		_race_cars()
		_build_vignette()
		_tracks_camera()
		await _save("res://art/bg_tracks.png")

	# The icon: one car on a short piece of lane, current glowing, on transparent.
	_new_stage(1024, 1024, false, true)
	_icon_piece()
	_camera.fov = 30.0
	_camera.position = Vector3(58, 120, 118)
	_camera.look_at(Vector3(10, 8, -12), Vector3.UP)
	var icon := await _grab()
	icon.save_png(ProjectSettings.globalize_path("res://art/icon_render.png"))
	print("art: wrote splash.png, menu_bg.png, bg_garage.png, bg_tracks.png, icon_render.png")
	quit()


func _key_camera() -> void:
	_camera.position = Vector3(560, 380, -560)
	_camera.look_at(Vector3(260, 310, -250), Vector3.UP)


func _garage_camera() -> void:
	_camera.position = Vector3(-820, 620, -300)
	_camera.look_at(Vector3(600, 380, 400), Vector3.UP)


func _tracks_camera() -> void:
	_camera.position = Vector3(1350, 720, -1100)
	_camera.look_at(Vector3(300, 300, 300), Vector3.UP)


func _grab() -> Image:
	for i in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	return _vp.get_texture().get_image()


func _save(path: String) -> void:
	var img := await _grab()
	img.save_png(ProjectSettings.globalize_path(path))
	print("wrote ", path)


# ---------------------------------------------------------------- the stage

func _new_stage(w: int, h: int, night: bool, transparent: bool = false) -> void:
	if _vp != null:
		_vp.queue_free()
	_vp = SubViewport.new()
	_vp.size = Vector2i(w, h)
	_vp.own_world_3d = true
	_vp.transparent_bg = transparent
	_vp.msaa_3d = Viewport.MSAA_8X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_vp)
	_world = Node3D.new()
	_vp.add_child(_world)
	_parent = _world
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR if transparent else Environment.BG_COLOR
	env.background_color = Color(0.035, 0.032, 0.045)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.72, 0.85)
	env.ambient_light_color = Color(1.0, 0.86, 0.72)
	env.ambient_light_energy = 0.30 if night else 0.42
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_bloom = 0.08
	env.glow_hdr_threshold = 1.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.2
	env.adjustment_contrast = 1.06
	var we := WorldEnvironment.new()
	we.environment = env
	_parent.add_child(we)
	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.9, 0.78)
	key.light_energy = 0.25 if night else 0.35
	key.shadow_enabled = false
	key.directional_shadow_max_distance = 1600.0
	_parent.add_child(key)
	key.look_at_from_position(Vector3(-200, 400, 300), Vector3.ZERO, Vector3.UP)
	_camera = Camera3D.new()
	_camera.fov = 50.0
	_camera.near = 2.0
	_camera.far = 6000.0
	_parent.add_child(_camera)
	_mats.clear()


# ---------------------------------------------------------------- the layout

## The centreline, in the board's XZ plane: a straight towards -Z, a long 180-degree right-hander,
## a straight back, and a tighter bend to close the loop.
func _build_path() -> void:
	_path = PackedVector2Array()
	var z := 520.0
	while z > 0.0:
		_path.append(Vector2(0, z))
		z -= STEP
	var arc := int(PI * BEND_R / STEP)
	for k in arc:
		var a := PI + PI * float(k) / float(arc)
		_path.append(Vector2(BEND_R, 0) + Vector2(cos(a), sin(a)) * BEND_R)
	z = 0.0
	while z < 520.0:
		_path.append(Vector2(BEND_R * 2.0, z))
		z += STEP
	for k in arc:
		var a := float(k) / float(arc) * PI
		_path.append(Vector2(BEND_R, 520) + Vector2(cos(a), sin(a)) * BEND_R)
	_nrm = PackedVector2Array()
	var n := _path.size()
	for i in n:
		var d := (_path[(i + 1) % n] - _path[posmod(i - 1, n)]).normalized()
		_nrm.append(Vector2(-d.y, d.x))


func _index_at(u: float) -> int:
	return posmod(int(round(u * float(_path.size()))), _path.size())


func _p3(i: int, off: float, y: float) -> Vector3:
	var p := _path[posmod(i, _path.size())] + _nrm[posmod(i, _path.size())] * off
	return Vector3(p.x, y, p.y)


func _build_layout() -> void:
	# The baseboard: green, like the game's ground, painted on the table top.
	_box(Vector3(BOARD.size.x, 10, BOARD.size.y), Vector3(BOARD.get_center().x, -5, BOARD.get_center().y),
			_mat("board", Color(0.20, 0.40, 0.18), 0.9))
	_controllers()
	var n := _path.size()
	var all := range(n + 1)
	# Plastic road: sides, the white border, the road, kerbs on the outside of the bends.
	_ribbon(all, -HALF - BORDER, HALF + BORDER, TRACK_H - 0.3, _mat("edge", Color(0.92, 0.92, 0.92), 0.5))
	_wall(all, -HALF - BORDER)
	_wall(all, HALF + BORDER)
	_ribbon(all, -HALF, HALF, TRACK_H, _mat("road", Color(0.16, 0.16, 0.18), 0.55))
	var red := _mat("kerb", Color(0.85, 0.16, 0.12), 0.5)
	for i in n:
		if (i / 4) % 2 == 0 and _bend_side(i) != 0.0:
			var s := _bend_side(i)
			_ribbon([i, i + 1], s * HALF if s > 0 else -HALF - BORDER, s * (HALF + BORDER) if s > 0 else -HALF, TRACK_H - 0.1, red)
	# Piece joints.
	for i in range(0, n, 40):
		_ribbon([i, i + 1], -HALF, HALF, TRACK_H + 0.05, _mat("joint", Color(0.10, 0.10, 0.11), 0.8), 0.25)
	# Each lane: the slot, a braid either side.
	var braid := _mat("braid", Color(0.80, 0.58, 0.38), 0.3, 0.85)
	var slot := _mat("slot", Color(0.02, 0.02, 0.025), 1.0)
	for off in LANES:
		_ribbon(all, off - 1.6, off + 1.6, TRACK_H + 0.08, slot)
		for side in [-1.0, 1.0]:
			_ribbon(all, off + side * 4.2, off + side * 6.2, TRACK_H + 0.12, braid)
	_start_line()
	_scenery()


## +1 / -1 for which side the outside of the bend at `i` is on; 0 on a straight.
func _bend_side(i: int) -> float:
	var n := _path.size()
	var a := (_path[(i + 3) % n] - _path[i]).angle()
	var b := (_path[i] - _path[posmod(i - 3, n)]).angle()
	var turn := wrapf(a - b, -PI, PI)
	if absf(turn) < 0.01:
		return 0.0
	return -signf(turn)


func _start_line() -> void:
	var i := _index_at(0.0) + 10
	var cols := 14
	var cell := HALF * 2.0 / float(cols)
	var white := _mat("chk_w", Color(0.95, 0.95, 0.95), 0.5)
	var black := _mat("chk_b", Color(0.05, 0.05, 0.05), 0.5)
	for r in 2:
		for c in cols:
			var off := -HALF + cell * c
			_ribbon([i + r, i + r + 1], off, off + cell, TRACK_H + 0.15, white if (r + c) % 2 == 0 else black)
	# The gantry over the line, with the name on it.
	var post := _mat("gantry", Color(0.12, 0.12, 0.14), 0.4, 0.5)
	var a := _p3(i, -HALF - 34, 0)
	var b := _p3(i, HALF + 34, 0)
	_box(Vector3(6, 110, 6), a + Vector3(0, 55, 0), post)
	_box(Vector3(6, 110, 6), b + Vector3(0, 55, 0), post)
	var across := b - a
	var beam := _box(Vector3(across.length() + 6, 24, 6), (a + b) * 0.5 + Vector3(0, 110, 0), post)
	beam.rotation.y = atan2(-across.z, across.x)
	# The side of the line the cameras look at (-Z): the lap counter's digits face it.
	var face := across.cross(Vector3.UP).normalized()
	if face.z > 0.0:
		face = -face
	# The lap counter tower beside the line, its digits lit.
	var tower := _box(Vector3(40, 90, 26), _p3(i, HALF + 80, 45), post)
	var digits := Label3D.new()
	digits.text = "LAP
3/8"
	digits.font_size = 64
	digits.pixel_size = 0.14
	digits.modulate = Color(0.35, 1.0, 0.45)
	digits.double_sided = false
	_parent.add_child(digits)
	digits.position = tower.position + Vector3(0, 18, 0) + face * 13.4
	digits.rotation.y = atan2(face.x, face.z)
	# A lamp over the line.
	var lamp := SpotLight3D.new()
	lamp.light_color = Color(1.0, 0.88, 0.68)
	lamp.light_energy = 8.0
	lamp.spot_range = 700.0
	lamp.spot_angle = 34.0
	lamp.shadow_enabled = true
	_parent.add_child(lamp)
	var over := (a + b) * 0.5
	lamp.position = over + Vector3(0, 380, -60)
	lamp.look_at(_parent.to_global(over), Vector3.FORWARD)


## Trackside: white plastic barriers round the outside of the bends, some low blocks of scenery.
func _scenery() -> void:
	var fence := _mat("fence", Color(0.93, 0.93, 0.95), 0.4)
	var n := _path.size()
	for i in range(0, n, 3):
		var s := _bend_side(i)
		if s == 0.0:
			continue
		var p := _p3(i, s * (HALF + BORDER + 26), 6)
		var q := _p3(i + 3, s * (HALF + BORDER + 26), 6)
		var m := _box(Vector3(2.5, 12, p.distance_to(q) + 0.5), (p + q) * 0.5, fence)
		m.look_at(_parent.to_global(q), Vector3.UP)
	var block := _mat("house", Color(0.55, 0.42, 0.36), 0.8)
	var roof := _mat("roof", Color(0.32, 0.22, 0.2), 0.8)
	for spot in [Vector3(BEND_R, 0, 300), Vector3(BEND_R - 90, 0, 200), Vector3(BEND_R + 110, 0, 240)]:
		_box(Vector3(60, 40, 46), spot + Vector3(0, 20, 0), block)
		_box(Vector3(64, 8, 50), spot + Vector3(0, 44, 0), roof)
	var tree := _mat("tree", Color(0.14, 0.32, 0.14), 0.9)
	for k in 14:
		var x := -260.0 + float(k % 7) * 30.0 + float(k / 7) * 15.0
		var zz := -120.0 + float(k / 7) * 160.0 + float(k % 3) * 20.0
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 16.0
		cone.height = 46.0
		var mi := MeshInstance3D.new()
		mi.mesh = cone
		mi.material_override = tree
		_parent.add_child(mi)
		mi.position = Vector3(x, 23, zz)


# ---------------------------------------------------------------- cars

## The race: four cars coming out of the big bend, the current lit behind each, and one leaving the slot.
func _race_cars() -> void:
	_car("f1", Color(0.86, 0.12, 0.12), _index_at(0.30), LANES[0], 0.18, true)
	_car("sport", Color(0.15, 0.42, 0.92), _index_at(0.285), LANES[1], 0.14, true)
	_car("gt", Color(0.12, 0.40, 0.26), _index_at(0.33), LANES[2], 0.10, true)
	# The Rally has lost it: out of its lane, up on its side, over the outside of the bend.
	var i := _index_at(0.245)
	var off := LANES[3] + 70.0
	var holder := _car("rally", Color(0.95, 0.95, 0.95), i, off, 0.0, false)
	holder.position.y = 26.0
	holder.rotate_object_local(Vector3.UP, 0.9)
	holder.rotate_object_local(Vector3(1, 0, 0), 1.1)
	_sparks(_p3(i, LANES[3] + 20.0, TRACK_H + 2), 14)
	# Four lanes, four cars: the Rally WAS the fourth lane's car -- nobody else is in it.


## One car: the game's model, at path index `i`, `off` across the road, its tail swung out by `tail`
## (into the bend), and -- `powered` -- the current glowing in its braids behind it.
func _car(style: String, body: Color, i: int, off: float, tail: float, powered: bool) -> Node3D:
	var stripe := Color(1, 1, 1, 0.9)
	for c in CarCatalog.CARS:
		if c["style"] == style:
			stripe = c["stripe"]
	var builder := CarModel3D.new()
	root.add_child(builder)
	builder.build(style, body, stripe)
	var model := builder.detach_model()
	builder.queue_free()
	var holder := Node3D.new()
	_parent.add_child(holder)
	var d := _path[(i + 1) % _path.size()] - _path[i]
	holder.position = _p3(i, off, TRACK_H)
	holder.rotation.y = atan2(-d.y, d.x) - tail * -_bend_side(i)
	model.rotation = Vector3.ZERO
	model.scale = Vector3.ONE * CAR_SCALE
	holder.add_child(model)
	if powered:
		_current(i, off)
	return holder


## The braids behind a car under power: two glowing lines fading back from the guide, and a small light.
func _current(i: int, off: float) -> void:
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(0.5, 0.85, 1.0)
	glow.emission_enabled = true
	glow.emission = Color(0.45, 0.85, 1.0)
	glow.emission_energy_multiplier = 4.0
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var length := 34
	# On a short open piece (the icon) the glow must not wrap round to the far end.
	var from := i - length if _path.size() > 100 else maxi(i - length, 0)
	for side in [-1.0, 1.0]:
		_ribbon(range(from, i + 4), off + side * 4.4, off + side * 6.0, TRACK_H + 0.25, glow)
	var l := OmniLight3D.new()
	l.light_color = Color(0.45, 0.8, 1.0)
	l.light_energy = 1.6
	l.omni_range = 60.0
	_parent.add_child(l)
	l.position = _p3(i, off, TRACK_H + 6)


func _sparks(at: Vector3, count: int) -> void:
	var hot := StandardMaterial3D.new()
	hot.albedo_color = Color(0.8, 0.95, 1.0)
	hot.emission_enabled = true
	hot.emission = Color(0.6, 0.9, 1.0)
	hot.emission_energy_multiplier = 6.0
	hot.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for k in count:
		var m := _box(Vector3(0.8, 0.8, rng.randf_range(5, 12)), at + Vector3(rng.randf_range(-14, 14),
				rng.randf_range(0, 16), rng.randf_range(-14, 14)), hot)
		m.rotation = Vector3(rng.randf_range(-1, 1), rng.randf_range(-PI, PI), 0)


## The icon's set piece: a short straight of two lanes, a red Formula on one, its braids alight.
func _icon_piece() -> void:
	var save_path := _path
	var save_nrm := _nrm
	_path = PackedVector2Array()
	_nrm = PackedVector2Array()
	for k in 30:
		_path.append(Vector2(-90.0 + 6.0 * k, 0))
		_nrm.append(Vector2(0, 1))
	var idx := range(29)
	_ribbon(idx, -34, 34, TRACK_H - 0.3, _mat("edge", Color(0.92, 0.92, 0.92), 0.5))
	_wall(idx, -34)
	_wall(idx, 34)
	_ribbon(idx, -28, 28, TRACK_H, _mat("road", Color(0.16, 0.16, 0.18), 0.55))
	var braid := _mat("braid", Color(0.80, 0.58, 0.38), 0.3, 0.85)
	for off in [-12.0, 12.0]:
		_ribbon(idx, off - 1.6, off + 1.6, TRACK_H + 0.08, _mat("slot", Color(0.02, 0.02, 0.025), 1.0))
		for side in [-1.0, 1.0]:
			_ribbon(idx, off + side * 4.2, off + side * 6.2, TRACK_H + 0.12, braid)
	_car("f1", Color(0.86, 0.12, 0.12), 17, -12.0, 0.0, true)
	_path = save_path
	_nrm = save_nrm


# ---------------------------------------------------------------- overlays

func _build_vignette() -> void:
	var grad := Gradient.new()
	grad.set_color(0, Color(0, 0, 0, 0.1))
	grad.set_color(1, Color(0, 0, 0, 0.7))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.05, 1.05)
	tex.width = 256
	tex.height = 256
	var shade := TextureRect.new()
	shade.texture = tex
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.size = Vector2(W, H)
	_vp.add_child(shade)


# ---------------------------------------------------------------- geometry

func _mat(key: String, c: Color, rough: float, metal: float = 0.0) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	_mats[key] = m
	return m


func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = b
	mi.material_override = mat
	_parent.add_child(mi)
	mi.position = pos
	return mi


## A flat band along the path through `indices`, from `a` to `b` across it, at height `y`. With
## `length` < 1, each segment is only that share of its step long (the piece joints).
func _ribbon(indices: Array, a: float, b: float, y: float, mat: Material, length: float = 1.0) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	for k in indices.size() - 1:
		var i: int = indices[k]
		var j: int = indices[k + 1]
		var pa := _p3(i, a, y)
		var pb := _p3(i, b, y)
		var qa := _p3(j, a, y)
		var qb := _p3(j, b, y)
		if length < 1.0:
			qa = pa.lerp(qa, length)
			qb = pb.lerp(qb, length)
		st.add_vertex(pa)
		st.add_vertex(qa)
		st.add_vertex(qb)
		st.add_vertex(pa)
		st.add_vertex(qb)
		st.add_vertex(pb)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	_parent.add_child(mi)


## The side of the plastic, from the board up to the road, at `off` across the path.
func _wall(indices: Array, off: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in indices.size() - 1:
		var i: int = indices[k]
		var j: int = indices[k + 1]
		var a0 := _p3(i, off, 0)
		var a1 := _p3(i, off, TRACK_H)
		var b0 := _p3(j, off, 0)
		var b1 := _p3(j, off, TRACK_H)
		st.add_vertex(a0)
		st.add_vertex(b0)
		st.add_vertex(b1)
		st.add_vertex(a0)
		st.add_vertex(b1)
		st.add_vertex(a1)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := _mat("wall", Color(0.82, 0.82, 0.84), 0.5)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	_parent.add_child(mi)


# ---------------------------------------------------------------- the room

## The hobby room round the table, in world coordinates, then the table frame the layout is built in:
## after this, `_parent` is the table top.
func _build_room() -> void:
	_parent = _world
	var r := ROOM
	var cx := r.get_center().x
	var cz := r.get_center().y
	# A plank floor, a rug under the table.
	var x := r.position.x
	var k := 0
	while x < r.end.x:
		var even := k % 2 == 0
		_box(Vector3(78, 4, r.size.y), Vector3(x + 40, -2, cz), _mat("plank_a" if even else "plank_b",
				Color(0.46, 0.30, 0.18) if even else Color(0.40, 0.26, 0.15), 0.7))
		x += 80.0
		k += 1
	_box(Vector3(1760, 3, 2240), Vector3(330, 1.5, 260), _mat("rug", Color(0.38, 0.10, 0.10), 0.95))
	_box(Vector3(1640, 3.5, 2120), Vector3(330, 1.8, 260), _mat("rug_in", Color(0.52, 0.17, 0.14), 0.95))
	# Four walls: wood panelling to the dado rail, striped wallpaper above. And a ceiling.
	var paper := _mat("paper", Color(0.25, 0.33, 0.31), 0.9)
	var stripe := _mat("stripe", Color(0.29, 0.38, 0.35), 0.9)
	var panel := _mat("panel", Color(0.36, 0.22, 0.13), 0.6)
	var rail := _mat("rail", Color(0.27, 0.16, 0.09), 0.5)
	for w in [
		[Vector3(cx, 0, r.end.y), Vector3(1, 0, 0), r.size.x, Vector3(0, 0, -1)],
		[Vector3(cx, 0, r.position.y), Vector3(1, 0, 0), r.size.x, Vector3(0, 0, 1)],
		[Vector3(r.position.x, 0, cz), Vector3(0, 0, 1), r.size.y, Vector3(1, 0, 0)],
		[Vector3(r.end.x, 0, cz), Vector3(0, 0, 1), r.size.y, Vector3(-1, 0, 0)],
	]:
		var at: Vector3 = w[0]
		var dir: Vector3 = w[1]
		var len: float = w[2]
		var inward: Vector3 = w[3]
		_box(_wall_size(dir, len, 20.0, ROOM_H), at + Vector3(0, ROOM_H * 0.5, 0) - inward * 10.0, paper)
		var s := -len * 0.5 + 45.0
		while s < len * 0.5:
			_box(_wall_size(dir, 30.0, 2.0, ROOM_H - 380.0),
					at + dir * s + Vector3(0, 380.0 + (ROOM_H - 380.0) * 0.5, 0) + inward * 1.0, stripe)
			s += 110.0
		_box(_wall_size(dir, len, 8.0, 360.0), at + Vector3(0, 180, 0) + inward * 4.0, panel)
		_box(_wall_size(dir, len, 14.0, 16.0), at + Vector3(0, 368, 0) + inward * 7.0, rail)
		_box(_wall_size(dir, len, 12.0, 24.0), at + Vector3(0, 12, 0) + inward * 6.0, rail)
	_box(Vector3(r.size.x, 20, r.size.y), Vector3(cx, ROOM_H + 10, cz), _mat("ceiling", Color(0.20, 0.18, 0.16), 0.9))
	_shelves()
	_window()
	_lamps()
	_furniture()
	_build_table()


## A box `along` long in the wall's direction `dir`, `thick` deep, `h` high.
static func _wall_size(dir: Vector3, along: float, thick: float, h: float) -> Vector3:
	return Vector3(along, h, thick) if dir.x != 0.0 else Vector3(thick, h, along)


## The table the layout sits on: a thick top with a lip round the board, an apron, four legs.
func _build_table() -> void:
	var wood := _mat("table", Color(0.50, 0.32, 0.18), 0.55)
	var c := Vector3(BOARD.get_center().x, 0, BOARD.get_center().y)
	_box(Vector3(BOARD.size.x + 60, 24, BOARD.size.y + 60), c + Vector3(0, TABLE_Y - 22, 0), wood)
	_box(Vector3(BOARD.size.x - 40, 60, BOARD.size.y - 40), c + Vector3(0, TABLE_Y - 64, 0),
			_mat("apron", Color(0.40, 0.25, 0.14), 0.6))
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(Vector3(50, TABLE_Y - 34, 50), c + Vector3(sx * (BOARD.size.x * 0.5 - 40), (TABLE_Y - 34) * 0.5,
					sz * (BOARD.size.y * 0.5 - 40)), wood)
	_table = Node3D.new()
	_table.position = Vector3(0, TABLE_Y, 0)
	_world.add_child(_table)
	_parent = _table


## Shelves on the back wall: boxed slot sets, trophies, a couple of cars from the collection.
func _shelves() -> void:
	var z := ROOM.end.y - 70.0
	var wood := _mat("shelf", Color(0.44, 0.28, 0.16), 0.6)
	var box_cols := [Color(0.85, 0.15, 0.12), Color(0.15, 0.35, 0.80), Color(0.95, 0.75, 0.15),
			Color(0.20, 0.55, 0.25), Color(0.90, 0.45, 0.10)]
	var lid := _mat("lid", Color(0.95, 0.95, 0.92), 0.6)
	var gold := _mat("gold", Color(0.95, 0.75, 0.25), 0.25, 0.9)
	var styles := ["gt", "f1", "rally", "kart", "sport"]
	var car_cols := [Color(0.12, 0.40, 0.26), Color(0.86, 0.12, 0.12), Color(0.95, 0.95, 0.95),
			Color(0.35, 0.78, 0.22), Color(0.15, 0.42, 0.92)]
	for row in 3:
		var y := 520.0 + 160.0 * row
		_box(Vector3(1100, 12, 130), Vector3(-260, y, z), wood)
		var x := -760.0
		var k := row * 2
		while x < 220.0:
			match (k + row) % 4:
				0, 1:
					var w := 150.0 + 30.0 * float(k % 3)
					var h := 100.0 + 20.0 * float((k + 1) % 2)
					_box(Vector3(w, h, 90), Vector3(x + w * 0.5, y + 6 + h * 0.5, z),
							_mat("set%d" % (k % 5), box_cols[k % 5], 0.6))
					_box(Vector3(w, 16, 92), Vector3(x + w * 0.5, y + 6 + h - 20, z), lid)
					x += w + 20.0
				2:
					var cup := CylinderMesh.new()
					cup.top_radius = 26.0
					cup.bottom_radius = 12.0
					cup.height = 50.0
					var mi := MeshInstance3D.new()
					mi.mesh = cup
					mi.material_override = gold
					_parent.add_child(mi)
					mi.position = Vector3(x + 30, y + 46, z)
					_box(Vector3(36, 16, 36), Vector3(x + 30, y + 14, z), _mat("plinth", Color(0.12, 0.1, 0.1), 0.5))
					_box(Vector3(6, 20, 6), Vector3(x + 30, y + 30, z), gold)
					x += 80.0
				_:
					_show_car(styles[k % 5], car_cols[k % 5], Vector3(x + 60, y + 6, z), PI * 0.85, 2.4)
					x += 140.0
			k += 1


## A window on the right wall: the night outside, a frame, half-lowered blinds, and its cool light.
func _window() -> void:
	var x := ROOM.end.x - 8.0
	var z := 300.0
	var frame := _mat("winframe", Color(0.88, 0.86, 0.80), 0.5)
	var night := StandardMaterial3D.new()
	night.albedo_color = Color(0.06, 0.10, 0.22)
	night.emission_enabled = true
	night.emission = Color(0.10, 0.18, 0.40)
	night.emission_energy_multiplier = 0.8
	_box(Vector3(6, 420, 560), Vector3(x, 620, z), frame)
	_box(Vector3(4, 390, 530), Vector3(x - 4, 620, z), night)
	_box(Vector3(8, 390, 14), Vector3(x - 7, 620, z), frame)
	_box(Vector3(8, 14, 530), Vector3(x - 7, 620, z), frame)
	var slat := _mat("slat", Color(0.92, 0.90, 0.84), 0.6)
	for k in 9:
		_box(Vector3(10, 8, 540), Vector3(x - 14, 820 - 16.0 * k, z), slat)
	var moon := OmniLight3D.new()
	moon.light_color = Color(0.55, 0.65, 1.0)
	moon.light_energy = 1.2
	moon.omni_range = 1200.0
	_parent.add_child(moon)
	moon.position = Vector3(x - 120, 620, z)


## Two lamps hung low over the table, and a standard lamp in the corner.
func _lamps() -> void:
	var shade := _mat("shade", Color(0.10, 0.28, 0.20), 0.35, 0.6)
	shade.cull_mode = BaseMaterial3D.CULL_DISABLED
	var bulb := StandardMaterial3D.new()
	bulb.albedo_color = Color(1.0, 0.9, 0.7)
	bulb.emission_enabled = true
	bulb.emission = Color(1.0, 0.85, 0.6)
	bulb.emission_energy_multiplier = 6.0
	var cord := _mat("cord", Color(0.05, 0.05, 0.05), 0.8)
	for z in [-20.0, 560.0]:
		var at := Vector3(330, 780, z)
		_box(Vector3(3, ROOM_H - at.y, 3), Vector3(at.x, (ROOM_H + at.y) * 0.5, at.z), cord)
		var cone := CylinderMesh.new()
		cone.top_radius = 20.0
		cone.bottom_radius = 85.0
		cone.height = 80.0
		var mi := MeshInstance3D.new()
		mi.mesh = cone
		mi.material_override = shade
		_parent.add_child(mi)
		mi.position = at
		var sph := SphereMesh.new()
		sph.radius = 16.0
		sph.height = 32.0
		var b := MeshInstance3D.new()
		b.mesh = sph
		b.material_override = bulb
		_parent.add_child(b)
		b.position = at + Vector3(0, -30, 0)
		var s := SpotLight3D.new()
		s.light_color = Color(1.0, 0.84, 0.62)
		s.light_energy = 14.0
		s.spot_range = 1400.0
		s.spot_angle = 58.0
		s.spot_attenuation = 0.6
		s.shadow_enabled = true
		_parent.add_child(s)
		s.look_at_from_position(at + Vector3(0, -32, 0), Vector3(at.x, 0, at.z), Vector3.FORWARD)
	# The standard lamp, back left.
	var corner := Vector3(ROOM.position.x + 120, 0, ROOM.end.y - 140)
	_box(Vector3(60, 10, 60), corner + Vector3(0, 5, 0), cord)
	_box(Vector3(8, 620, 8), corner + Vector3(0, 310, 0), cord)
	var cyl := CylinderMesh.new()
	cyl.top_radius = 50.0
	cyl.bottom_radius = 75.0
	cyl.height = 90.0
	var lm := MeshInstance3D.new()
	lm.mesh = cyl
	var warm := StandardMaterial3D.new()
	warm.albedo_color = Color(0.95, 0.85, 0.65)
	warm.emission_enabled = true
	warm.emission = Color(1.0, 0.75, 0.45)
	warm.emission_energy_multiplier = 1.4
	lm.material_override = warm
	_parent.add_child(lm)
	lm.position = corner + Vector3(0, 650, 0)
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.75, 0.5)
	glow.light_energy = 2.5
	glow.omni_range = 1100.0
	_parent.add_child(glow)
	glow.position = corner + Vector3(60, 640, -60)


## A chair pulled up to the table.
func _furniture() -> void:
	var wood := _mat("chair", Color(0.30, 0.18, 0.10), 0.6)
	var c := Vector3(BOARD.position.x - 260, 0, 520)
	_box(Vector3(170, 18, 170), c + Vector3(0, 190, 0), wood)
	_box(Vector3(18, 230, 170), c + Vector3(-80, 300, 0), wood)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(Vector3(16, 190, 16), c + Vector3(sx * 72, 95, sz * 72), wood)
	_box(Vector3(150, 10, 150), c + Vector3(6, 203, 0), _mat("cushion", Color(0.55, 0.14, 0.12), 0.9))


# ---------------------------------------------------------------- the controllers

## The four hand controllers stood at the table edge beside the start line, one per lane colour, wired
## to the power base, which is wired to the track.
func _controllers() -> void:
	var lane_cols := [Color(0.92, 0.22, 0.20), Color(0.25, 0.52, 0.96), Color(0.96, 0.82, 0.20), Color(0.30, 0.80, 0.36)]
	var body := _mat("ctl_body", Color(0.15, 0.15, 0.17), 0.45)
	var red := _mat("ctl_trigger", Color(0.86, 0.16, 0.12), 0.4)
	var cable := _mat("ctl_cable", Color(0.06, 0.06, 0.07), 0.7)
	var base := Vector3(-160, 0, 720)
	for k in 4:
		var at := Vector3(-160, 0, 300.0 + 75.0 * k)
		# Upright, facing the track (+X): grip, head, red trigger, a lane-coloured band.
		_box(Vector3(18, 46, 16), at + Vector3(-4, 23, 0), body)
		_box(Vector3(52, 18, 20), at + Vector3(6, 54, 0), body)
		_box(Vector3(9, 26, 10), at + Vector3(22, 34, 0), red)
		_box(Vector3(52.5, 5, 20.5), at + Vector3(6, 60, 0), _mat("lane%d" % k, lane_cols[k], 0.5))
		_wire(at + Vector3(-4, 2, 0), base + Vector3(-20, 2, -10 + 8.0 * k), cable, 2.2)
	# The power base: a box with a lit switch.
	_box(Vector3(70, 30, 54), base + Vector3(0, 15, 0), _mat("psu", Color(0.12, 0.12, 0.14), 0.5))
	var led := StandardMaterial3D.new()
	led.albedo_color = Color(1.0, 0.25, 0.15)
	led.emission_enabled = true
	led.emission = Color(1.0, 0.25, 0.15)
	led.emission_energy_multiplier = 5.0
	_box(Vector3(8, 6, 8), base + Vector3(20, 31, -14), led)
	# Two leads from the base to the track's side, at the start line.
	_wire(base + Vector3(36, 4, 8), _p3(14, -HALF - BORDER, 2), cable, 2.6)
	_wire(base + Vector3(36, 4, -8), _p3(20, -HALF - BORDER, 2), cable, 2.6)


## A cable lying on the board: a gentle S of short segments from `a` to `b`.
func _wire(a: Vector3, b: Vector3, mat: Material, r: float) -> void:
	var pts := []
	var n := 12
	var side := (b - a).cross(Vector3.UP).normalized() * a.distance_to(b) * 0.12
	for k in n + 1:
		var u := float(k) / float(n)
		pts.append(a.lerp(b, u) + side * sin(u * TAU))
	for k in n:
		var p: Vector3 = pts[k]
		var q: Vector3 = pts[k + 1]
		if p.distance_to(q) < 0.01:
			continue
		var seg := _box(Vector3(r * 2.0, r * 2.0, p.distance_to(q) + r), (p + q) * 0.5, mat)
		seg.look_at(_parent.to_global(q), Vector3.UP)


## A car model set down somewhere off the track (on a shelf), at `scale`.
func _show_car(style: String, body: Color, at: Vector3, yaw: float, scale: float) -> void:
	var stripe := Color(1, 1, 1, 0.9)
	for c in CarCatalog.CARS:
		if c["style"] == style:
			stripe = c["stripe"]
	var builder := CarModel3D.new()
	root.add_child(builder)
	builder.build(style, body, stripe)
	var model := builder.detach_model()
	builder.queue_free()
	var holder := Node3D.new()
	_parent.add_child(holder)
	holder.position = at
	holder.rotation.y = yaw
	model.rotation = Vector3.ZERO
	model.scale = Vector3.ONE * scale
	holder.add_child(model)
