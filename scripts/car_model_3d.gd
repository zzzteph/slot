class_name CarModel3D
extends SubViewport
## A small, real 3D low-poly model of a car, rendered into this SubViewport's texture, which `Car._draw`
## paints in place of the flat 2D body -- the Total Annihilation look: a flat 2D world with 3D units.
##
## Everything is built in code from primitive meshes (boxes, cylinders, prisms, spheres), so the project
## still ships no asset files. One unit = one game pixel. The model is +X forward, +Y up, +Z to the car's
## RIGHT, which is exactly the game's screen axes (x right, y down) seen from above.
##
## The camera is ORTHOGRAPHIC and tilted CAMERA_TILT from straight down, fixed in screen space: the model
## is yawed by the car's heading inside the viewport, so the light and the viewing angle never turn with
## the car -- the roofs and the south-facing sides are always the lit, visible ones.
##
## Only created where something can actually be rendered (not in a headless run), so the test suite and
## the physics never see it. It never reads anything but the Car's public/visual state.

## World units covered by the viewport (square), and its pixel size: 2x supersampled at 1:1 screen scale.
const VIEW_UNITS := 56.0
const VIEW_PIXELS := 112
const CAMERA_TILT := 22.0          # degrees from straight down
const LEAN_ROLL := 0.16            # rad of body roll at full display lean
const LEAN_PITCH := 0.08           # rad of body pitch at full display pitch
const WHEEL_TRAVEL := 0.35         # units a wheel moves per px of suspension compression
const PIVOT_Y := 6.0               # height of the roll axis: a barrel roll turns about the body, not the road

var _yaw: Node3D = null            # heading
var _roll: Node3D = null           # roll / pitch pivot at the body's centre of mass (PIVOT_Y up)
var _center: Node3D = null         # everything visible, moved back down by PIVOT_Y
var _body_parts: Node3D = null
var _wheels: Array[Node3D] = []    # FL, FR, RL, RR (matches Car.WHEEL_LOCAL)
var _wheel_spin: Array[Node3D] = []
var _paint: StandardMaterial3D = null
var _base_paint: Color = Color.WHITE
var _spin_angle: float = 0.0
var _style: String = ""
var _q_damage: int = -1
var _camera: Camera3D = null
var _tyres: Array[MeshInstance3D] = []     # the rubber of each wheel (hidden when it has burst)
var _rims: Array[MeshInstance3D] = []      # the bare metal rim shown instead
var _dent_seq: int = 0
## SPEC 51: what is UNDER the panels. Built with the car, hidden, and shown the moment the panel over it
## is knocked off -- the bonnet goes and there is an engine in the hole, the roof goes and you see the
## seats and the cage. Keyed by name ("engine", "cabin", ...); a panel names what it covers in its
## "reveals" meta, and every inner piece carries an "inner" meta so it can never be knocked off itself.
var _inners: Dictionary = {}
## SPEC 67: a mesh set per PART, built hidden with the car and shown when that part is fitted -- a scoop
## and a big pipe for the turbo, twin pipes for the torque motor, vents for the lightweight engine,
## knobbles for all-terrains, white sidewalls for the hard compound, struts for the springs, a cage bar,
## and a rope drum. Keyed by part id.
var _part_models: Dictionary = {}
var _side_panels: Array = []
## The pose the texture currently shows, and how far each value may drift before it is re-rendered.
## A tenth of a degree of heading is invisible at this size; a whole degree is not.
const RENDER_ANGLE := 0.016            # rad (~0.9 deg): below this, a refresh is not worth a pass
## Past this the car is visibly turning, and waiting for a free slot in the budget would show: the
## texture would hold an old heading while the car drives on, which reads as the body sliding sideways
## (and, while a wheel is in the air, as the car floating). A big change never waits.
const RENDER_URGENT := 0.05            # rad (~2.9 deg)
## Perf round: an urgent rival now WAITS for a slot in the frame's budget like any other (SPEC 55 let
## it jump the queue, and a field of rivals all turning at once was a 3D pass per car per frame); past
## this much drift the texture would be visibly wrong, and it goes whatever the budget says. The
## player's model never waits at all.
const RENDER_FORCE := 0.15             # rad (~8.6 deg)
## SPEC 141: THE FIRST FRAMES ARE NOT TRUSTED. A model built during a scene change asks for its picture
## in the very frame it enters the tree -- measured: all five of a grid car's render requests land in
## that one frame -- and what the viewport produces then is NOT the pose it was given. `_accept_pose`
## had already recorded that pose as shown, so `pose()` saw no drift and never asked again: the whole
## countdown was drawn from a picture of the car facing the default way, and it only turned round when
## the car moved at GO. For this many frames after entering the tree or being rebuilt, every `pose()`
## renders, drift or not, budget or not; one of them lands after the scene has settled.
const SETTLE_FRAMES := 3
## How far the bonnet swings up when a non-stock engine is fitted (SPEC 68): enough to see the engine
## bay from above, not so far that the car stops reading as a car.
const BONNET_ANGLE := -1.05
const RENDER_OFFSET := 0.25            # px of suspension travel
const RENDER_SPIN := 0.35              # rad of wheel rotation
var _shown: Array = [INF, INF, INF, INF, INF, INF]   # heading, roll, pitch, roll_angle, steer, spin
var _shown_offsets := PackedFloat32Array([INF, INF, INF, INF])
var _shown_damage: float = -1.0
## SPEC 54 -- a budget on 3D passes. Every car owns a viewport, and a viewport costs a whole render pass
## whatever is in it: six passes a frame was most of the frame on a weak GPU. The player's car always
## refreshes the moment it changes; the rivals share `RENDERS_PER_FRAME` refreshes a frame between them,
## round robin, so a model is at worst a frame or two stale -- at 100 px across, nobody can tell.
static var renders_per_frame: int = 2
static var _budget_frame: int = -1
static var _budget_left: int = 0
## SPEC 128: WHAT THE CRASH DID, ON THE MODEL. `CarBody` has decided what has broken since SPEC 123 and
## the physics has read it ever since -- a wheel marked GONE lost its grip, added drag and pulled the car
## to that side -- but nothing ever told the 3D model, which is the thing the player is actually looking
## at. A car could be running on three wheels and a hub and still be drawn with four round tyres: damage
## you could feel and could not see.
##
## The states, mirrored here rather than applied once and forgotten, because `pose()` rewrites every
## wheel transform from its base each time it renders. Values are `CarBody.State`, named locally so this
## class keeps depending on nothing.
const ST_DENTED := 1
const ST_LOOSE := 2
const ST_GONE := 3
## How a wheel in each state sits: how far it leans (rad, top inward) and how far the corner drops. A
## LOOSE wheel is buckled -- cambered over and rubbing; a GONE one is not there, and the hub block inside
## it is what is left on the road, so the corner sits right down.
const WHEEL_CAMBER := [0.0, 0.0, 0.34, 0.0]
const WHEEL_SINK := [0.0, 0.0, 0.9, 2.5]
var _wheel_state := PackedInt32Array([0, 0, 0, 0])
var _burst := [false, false, false, false]
## Highest state already applied per component id, so a repeated push does nothing and a panel is never
## knocked off twice.
var _part_state: Dictionary = {}
## The player's car: never waits for the budget.
var priority: bool = false
var _pending: bool = false
## How many times this model has actually asked its viewport for a frame (SPEC 54). The cheapest honest
## measure of the work saved, and what the tests pin.
var renders_requested: int = 0
## SPEC 141: the process frame this model last asked its viewport for a picture, and the last frame of
## its settling window. `render_pending()` is what the car reads -- NOT `render_target_update_mode`,
## which Godot consumes inside the renderer and never resets on the node, so it reads UPDATE_ONCE
## forever after the first request (measured: 40 frames, never changed). SPEC 134 read that property,
## which is why every car had been redrawing itself sixty times a second for its entire life.
var last_render_frame: int = -1
var _settle_until: int = -1


func _init() -> void:
	size = Vector2i(VIEW_PIXELS, VIEW_PIXELS)
	transparent_bg = true
	own_world_3d = true
	disable_3d = false
	# SPEC 54 -- what this viewport costs. It used to run 4x MSAA and re-render EVERY frame, and there
	# is one of these per car: six 3D passes a frame, which is most of a weak GPU's budget. The model is
	# drawn at ~100 px across, where 4x MSAA is not worth a quarter of the frame, and it only has to be
	# re-rendered when the car actually looks different (`_needs_render`).
	msaa_3d = Viewport.MSAA_DISABLED
	render_target_update_mode = SubViewport.UPDATE_ONCE
	var cam := Camera3D.new()
	_camera = cam
	cam.name = "Camera"
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = VIEW_UNITS
	cam.near = 1.0
	cam.far = 400.0
	var t := deg_to_rad(CAMERA_TILT)
	# Screen up is -Z (the game's -y). Tilting the camera toward +Z shows the south-facing sides.
	add_child(cam)
	cam.look_at_from_position(Vector3(0.0, cos(t), sin(t)) * 150.0, Vector3.ZERO, Vector3(0.0, 0.0, -1.0))

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 1.25
	add_child(sun)
	sun.look_at_from_position(Vector3(-40.0, 90.0, -30.0), Vector3.ZERO, Vector3.UP)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.85)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_yaw = Node3D.new()
	_yaw.name = "Yaw"
	add_child(_yaw)
	_roll = Node3D.new()
	_roll.name = "Roll"
	_roll.position = Vector3(0.0, PIVOT_Y, 0.0)
	_yaw.add_child(_roll)
	_center = Node3D.new()
	_center.name = "Center"
	_center.position = Vector3(0.0, -PIVOT_Y, 0.0)
	_roll.add_child(_center)


## Rebuilds the model for a car style ("sport", "f1", "gt", "rally", "kart") and livery.
func build(style: String, body: Color, stripe: Color) -> void:
	_style = style
	_base_paint = body
	for c in _center.get_children():
		c.free()
	_wheels.clear()
	_wheel_spin.clear()
	_tyres.clear()
	_rims.clear()
	_inners.clear()
	_part_models.clear()
	_side_panels.clear()
	_dent_seq = 0
	_body_parts = Node3D.new()
	_body_parts.name = "Body"
	_center.add_child(_body_parts)
	_paint = _mat(body, 0.45, 0.25)
	var trim := _mat(stripe, 0.5)
	var glass := _mat(Color(0.10, 0.14, 0.20), 0.15, 0.4)
	var dark := _mat(Color(0.08, 0.08, 0.09), 0.8)
	var lamp := _mat(Color(1.0, 0.9, 0.45), 0.3)
	lamp.emission_enabled = true
	lamp.emission = Color(1.0, 0.85, 0.4)
	lamp.emission_energy_multiplier = 0.6
	var tail := _mat(Color(0.8, 0.08, 0.06), 0.4)
	match style:
		"f1":
			_build_f1(trim, dark)
		"gt":
			_build_gt(trim, glass, dark, lamp, tail)
		"rally":
			_build_rally(trim, glass, dark, lamp, tail)
		"kart":
			_build_kart(trim, dark)
		_:
			_build_sport(trim, glass, dark, lamp, tail)
	_q_damage = -1
	_dirty()
	settle()                            # SPEC 141: a rebuild's first renders are not trusted either


## Swings the bonnet up on its rear edge (SPEC 68) and shows the engine bay under it. A bonnet lost in
## a crash stays lost -- this only moves the one that is still on the car.
func _set_bonnet_open(open: bool) -> void:
	if _body_parts == null:
		return
	var lost := false
	for c in _body_parts.get_children():
		var mi := c as MeshInstance3D
		if mi == null or not mi.has_meta("reveals") or String(mi.get_meta("reveals")) != "engine":
			continue
		if mi.has_meta("lost"):
			lost = true
			continue
		if not mi.has_meta("shut_pos"):
			mi.set_meta("shut_pos", mi.position)
			mi.set_meta("shut_rot", mi.rotation)
		var shut_pos: Vector3 = mi.get_meta("shut_pos")
		var shut_rot: Vector3 = mi.get_meta("shut_rot")
		if open:
			# The hinge is the bonnet's rear edge, so it lifts at the nose like a real one.
			var half := (mi.mesh.get_aabb().size.x if mi.mesh != null else 9.0) * 0.5
			var pivot := shut_pos - Vector3(half, 0.0, 0.0)
			mi.position = pivot + (shut_pos - pivot).rotated(Vector3(0, 0, 1), BONNET_ANGLE)
			mi.rotation = shut_rot + Vector3(0.0, 0.0, BONNET_ANGLE)
		else:
			mi.position = shut_pos
			mi.rotation = shut_rot
	for piece in _inners.get("engine", []):
		(piece as MeshInstance3D).visible = open or lost


## True when the bonnet is standing open.
func is_bonnet_open() -> bool:
	if _body_parts == null:
		return false
	for c in _body_parts.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.has_meta("reveals") and String(mi.get_meta("reveals")) == "engine" 				and mi.has_meta("shut_rot"):
			return not is_equal_approx(mi.rotation.z, (mi.get_meta("shut_rot") as Vector3).z)
	return false


## True when this part has a mesh set of its own (SPEC 67).
func has_part_model(part_id: String) -> bool:
	return _part_models.has(part_id) and not (_part_models[part_id] as Array).is_empty()


## True when this part's meshes are the ones currently on the car.
func part_model_visible(part_id: String) -> bool:
	if not has_part_model(part_id):
		return false
	return ((_part_models[part_id] as Array)[0] as MeshInstance3D).visible


## Records a part's meshes and hides them until the part is fitted.
func _part_model(part_id: String, meshes: Array) -> void:
	for m in meshes:
		(m as MeshInstance3D).visible = false
	_part_models[part_id] = meshes


# ---------------------------------------------------------------- the five models

func _build_sport(trim: Material, glass: Material, dark: Material, lamp: Material, tail: Material) -> void:
	_box(Vector3(35, 5, 17), Vector3(0, 4.5, 0), _paint)                        # lower body
	_engine(11.0, 8.0)
	_cabin(-2.0, 6.5)
	_covers(_prism(Vector3(9, 3, 16), Vector3(12, 8.5, 0), _paint, true), "engine")   # bonnet
	_glass_over(_box(Vector3(15, 4.5, 14), Vector3(-2, 9.2, 0), glass), "cabin")  # cabin glass
	_covers(_box(Vector3(12, 1.2, 13), Vector3(-3, 11.8, 0), _paint), "cabin")  # roof
	_box(Vector3(30, 0.4, 3.2), Vector3(0, 12.6, 0), trim)                      # stripe over the roof
	_box(Vector3(6, 1.0, 17.2), Vector3(-15, 7.5, 0), dark)                     # rear spoiler
	_box(Vector3(3.0, 2.2, 17.4), Vector3(17.2, 5.4, 0), dark)                  # front bumper
	_box(Vector3(2.6, 2.2, 17.4), Vector3(-17.0, 5.4, 0), dark)                 # rear bumper
	for side in [-1.0, 1.0]:
		_box(Vector3(13, 3.4, 1.0), Vector3(-1, 6.2, side * 8.6), trim)         # door panels
		_box(Vector3(1.6, 1.0, 2.2), Vector3(5.5, 9.4, side * 8.4), dark)       # mirrors
	_box(Vector3(3.0, 1.2, 1.2), Vector3(-17.4, 3.6, -4.0), dark)               # exhaust
	_lamps(lamp, tail, 17.6, 6.5)
	_four_wheels(3.6, 3.2, 12.5, 8.6, dark)


func _build_f1(trim: Material, dark: Material) -> void:
	_box(Vector3(34, 3.5, 7), Vector3(0, 4.0, 0), _paint)                       # tub
	_prism(Vector3(10, 2.5, 5), Vector3(19, 3.5, 0), _paint, true)              # nose
	_box(Vector3(13, 3.5, 15), Vector3(-3, 4.0, 0), _paint)                     # sidepods
	_box(Vector3(3, 0.8, 22), Vector3(21, 2.0, 0), dark)                        # front wing
	_box(Vector3(4, 0.8, 16), Vector3(-17, 10.0, 0), dark)                      # rear wing
	_box(Vector3(2, 5, 1), Vector3(-17, 7.0, -4), dark)                         # wing posts
	_box(Vector3(2, 5, 1), Vector3(-17, 7.0, 4), dark)
	_engine(-9.0, 7.0)
	_covers(_box(Vector3(9, 4, 5), Vector3(-9, 7.5, 0), _paint), "engine")      # engine cover
	_box(Vector3(18, 0.4, 2.0), Vector3(2, 5.9, 0), trim)                       # centre stripe
	_box(Vector3(4.5, 3.5, 4.0), Vector3(-4.5, 9.0, 0), dark)                   # airbox over the driver
	for side in [-1.0, 1.0]:
		_box(Vector3(9, 1.0, 4.0), Vector3(-3, 6.2, side * 7.5), trim)          # sidepod tops
		_box(Vector3(5, 0.8, 3.0), Vector3(9, 3.2, side * 6.0), dark)           # turning vanes
	_sphere(2.6, Vector3(-1, 7.5, 0), trim)                                     # helmet
	_four_wheels(4.2, 4.0, 13.0, 10.0, dark)


func _build_gt(trim: Material, glass: Material, dark: Material, lamp: Material, tail: Material) -> void:
	_box(Vector3(38, 4.5, 18), Vector3(0, 4.2, 0), _paint)
	_engine(10.0, 7.2)
	_cabin(-6.0, 5.8)
	_covers(_prism(Vector3(14, 2.5, 17), Vector3(10, 7.6, 0), _paint, true), "engine")   # long bonnet
	_glass_over(_box(Vector3(12, 4, 14), Vector3(-6, 8.2, 0), glass), "cabin")
	_covers(_box(Vector3(10, 1.0, 13), Vector3(-7, 10.6, 0), _paint), "cabin")
	_box(Vector3(34, 0.4, 2.0), Vector3(0, 11.2, -2.6), trim)                   # twin stripes
	_box(Vector3(34, 0.4, 2.0), Vector3(0, 11.2, 2.6), trim)
	_box(Vector3(5.0, 1.0, 18.0), Vector3(-17.5, 9.6, 0), dark)                 # rear wing
	_box(Vector3(1.2, 3.0, 1.2), Vector3(-17.0, 7.4, -6.0), dark)               # wing posts
	_box(Vector3(1.2, 3.0, 1.2), Vector3(-17.0, 7.4, 6.0), dark)
	_box(Vector3(3.2, 2.4, 18.2), Vector3(18.6, 5.0, 0), dark)                  # splitter
	for side in [-1.0, 1.0]:
		_box(Vector3(12, 3.0, 1.2), Vector3(-4, 5.6, side * 9.1), trim)         # sill / door line
		_box(Vector3(2.4, 1.2, 1.2), Vector3(-18.4, 3.4, side * 5.0), dark)     # twin exhausts
	_lamps(lamp, tail, 19.1, 7.0)
	_four_wheels(3.8, 3.4, 13.5, 9.0, dark)


func _build_rally(trim: Material, glass: Material, dark: Material, lamp: Material, tail: Material) -> void:
	_box(Vector3(33, 6, 17), Vector3(0, 7.0, 0), _paint)                        # raised body
	_engine(11.0, 11.4)
	_cabin(-2.0, 10.0)
	_covers(_box(Vector3(11, 1.4, 15), Vector3(11, 10.6, 0), _paint), "engine")  # bonnet
	_box(Vector3(2.0, 0.8, 6.0), Vector3(9.0, 11.6, 0), _mat(Color(0.1, 0.1, 0.11), 0.9))  # bonnet scoop
	_glass_over(_box(Vector3(15, 6, 15), Vector3(-2, 13.0, 0), glass), "cabin")
	_covers(_box(Vector3(13, 1.2, 14), Vector3(-2, 16.4, 0), _paint), "cabin")
	_box(Vector3(33.2, 1.6, 17.2), Vector3(0, 5.0, 0), trim)                    # side band
	_box(Vector3(2, 1.4, 12), Vector3(5, 17.4, 0), dark)                        # roof light bar
	_cylinder(3.2, 0.4, Vector3(-4, 17.3, 0), _mat(Color(1, 1, 1)), true)       # number disc
	_box(Vector3(1, 4, 16), Vector3(-17, 4.0, 0), dark)                         # mud flaps
	_box(Vector3(3.0, 2.6, 17.4), Vector3(16.8, 6.4, 0), dark)                  # sump guard / bumper
	_cylinder(3.4, 1.6, Vector3(-14.0, 12.0, 0), dark, false)                   # spare wheel on the boot
	for side in [-1.0, 1.0]:
		_box(Vector3(2.0, 1.2, 1.2), Vector3(-17.6, 5.0, side * 4.0), dark)     # exhausts
	_lamps(lamp, tail, 16.6, 9.0)
	_four_wheels(4.0, 3.6, 12.5, 9.0, dark, 2.0)


func _build_kart(trim: Material, dark: Material) -> void:
	_box(Vector3(30, 1.2, 15), Vector3(0, 2.5, 0), dark)                        # chassis plate
	_box(Vector3(7, 1.5, 17), Vector3(15, 3.0, 0), _paint)                      # front bumper
	_box(Vector3(10, 3.5, 9), Vector3(10, 4.0, 0), _paint)                      # nose fairing
	_box(Vector3(2, 1.5, 19), Vector3(-15, 3.0, 0), _paint)                     # rear bumper
	_box(Vector3(7, 4, 8), Vector3(-3, 5.0, 0), trim)                           # seat
	_box(Vector3(5, 4, 4), Vector3(-10, 5.0, 5), dark)                          # engine
	_box(Vector3(1.2, 1.2, 4.0), Vector3(-13.0, 6.0, 5.0), dark)                # exhaust header
	_cylinder(1.6, 3.0, Vector3(-10.0, 4.0, -5.0), dark, false)                 # chain guard
	for side in [-1.0, 1.0]:
		_box(Vector3(9, 2.4, 1.6), Vector3(0, 3.4, side * 7.8), _paint)         # side pods
	_sphere(3.0, Vector3(-1, 9.5, 0), _mat(Color(0.95, 0.85, 0.2), 0.3))        # helmet
	_box(Vector3(4, 1.0, 1.0), Vector3(3, 7.0, 0), dark)                        # steering column
	_four_wheels(3.0, 3.2, 11.5, 8.5, dark)


# ---------------------------------------------------------------- per-frame pose

## Poses the model from the car's visual state. `wheel_offsets` are per-wheel suspension offsets (Car's
## compression minus rest), `steer` the front wheel angle, `distance` how far the car moved (wheel spin).
func pose(heading: float, roll_disp: float, pitch_disp: float, roll_angle: float, steer: float,
		wheel_offsets: PackedFloat32Array, distance: float, damage: float) -> void:
	_spin_angle = fmod(_spin_angle + distance / 3.6, TAU)
	var q := int(damage / 5.0)
	var repaint := q != _q_damage and _paint != null
	# SPEC 54: re-render the viewport only when the car actually looks different. A car sitting on the
	# grid, coasting in a straight line or waiting out a wreck costs nothing; one being thrown about
	# re-renders every frame, as it must.
	var drift := _pose_error(heading, roll_disp, pitch_disp, roll_angle, steer, wheel_offsets)
	# At most ONE forced render per frame: the viewport only renders once a frame however many times it
	# is asked, so a second request in the same frame is pure bookkeeping noise (the suite caught ten).
	var settling := is_settling() and last_render_frame != Engine.get_process_frames()
	if not (drift > RENDER_ANGLE or _pending or repaint or settling):
		return
	# Perf round: a rival waits for one of the frame's slots unless its texture would be visibly wrong
	# (`RENDER_FORCE`) or its paint has stepped; the player's never waits. And nothing below is written
	# until a pass is actually going to happen: sixteen Node3D transforms set for a texture that is not
	# refreshed are sixteen transforms thrown away.
	if not (priority or repaint or settling or drift > RENDER_FORCE or _take_slot()):
		_pending = true
		return
	_yaw.rotation = Vector3(0.0, -heading, 0.0)
	# +roll (load on the LEFT = -Z) leans the body down onto its left side: rotation about +X that lowers -Z.
	_roll.rotation = Vector3(roll_angle - roll_disp * LEAN_ROLL, 0.0, -pitch_disp * LEAN_PITCH)
	for i in _wheels.size():
		var w := _wheels[i]
		var base: Vector3 = w.get_meta("base")
		var off := wheel_offsets[i] if i < wheel_offsets.size() else 0.0
		# SPEC 128: a buckled corner leans and sits low, a missing one drops onto its hub.
		var st: int = _wheel_state[i] if i < _wheel_state.size() else 0
		w.position = base + Vector3(0.0, off * WHEEL_TRAVEL - float(WHEEL_SINK[st]), 0.0)
		w.rotation = Vector3(0.0, -steer if i < 2 else 0.0, 0.0)
		_wheel_spin[i].rotation = Vector3(float(WHEEL_CAMBER[st]) * signf(base.z), 0.0, -_spin_angle)
	if repaint:
		_q_damage = q
		_paint.albedo_color = _base_paint.lerp(Color(0.16, 0.14, 0.13), clampf(damage / 100.0, 0.0, 1.0) * 0.6)
	_accept_pose(heading, roll_disp, pitch_disp, roll_angle, steer, wheel_offsets)
	render_target_update_mode = SubViewport.UPDATE_ONCE
	renders_requested += 1
	last_render_frame = Engine.get_process_frames()
	_pending = false


## Marks the model as needing one more render (the viewport falls back to DISABLED after it). A rival's
## model waits for a free slot in this frame's budget; the player's never does, and neither does one
## whose pose has moved far enough that holding the old texture would be visible (`urgent`).
func _dirty(urgent: bool = true) -> void:
	if priority or urgent or _take_slot():
		render_target_update_mode = SubViewport.UPDATE_ONCE
		renders_requested += 1
		last_render_frame = Engine.get_process_frames()
		_pending = false
		_poke_host()
		return
	_pending = true


## SPEC 141: true while the car drawing this model must draw once more -- in the frame after a render
## was requested (the texture it draws is always the one rendered at the end of the frame before), and
## for the whole settling window. After that it is false, and a car that is not moving stops redrawing.
func render_pending() -> bool:
	var now := Engine.get_process_frames()
	return last_render_frame >= now or now <= _settle_until


func is_settling() -> bool:
	return Engine.get_process_frames() <= _settle_until


## Opens the settling window: the next SETTLE_FRAMES poses all render. Called on entering the tree and
## on every rebuild, which are the two moments a requested render has been seen not to land.
func settle() -> void:
	_settle_until = Engine.get_process_frames() + SETTLE_FRAMES
	_poke_host()


## A rebuild, a new livery or a part coming off happens outside the car's own `_draw`, and a car sitting
## still on the grid is not drawing -- so the model asks it to. `_request_redraw` only sets a flag the
## car's `_process` reads (SPEC 109: nothing here may `queue_redraw` from inside a draw or a tick).
func _poke_host() -> void:
	var host := get_parent()
	if host != null and host.has_method("_request_redraw"):
		host._request_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		settle()


## One of this frame's refreshes, if any are left.
static func _take_slot() -> bool:
	var frame := Engine.get_process_frames()
	if frame != _budget_frame:
		_budget_frame = frame
		_budget_left = maxi(renders_per_frame, 0)
	if _budget_left <= 0:
		return false
	_budget_left -= 1
	return true


## How far the pose has drifted from what the texture currently shows, in radians-equivalent: the biggest
## of the angles, with the suspension travel and the wheel spin scaled onto the same footing.
func _pose_error(heading: float, roll_disp: float, pitch_disp: float, roll_angle: float, steer: float,
		offsets: PackedFloat32Array) -> float:
	var e := absf(wrapf(heading - float(_shown[0]), -PI, PI))
	e = maxf(e, absf(roll_disp - float(_shown[1])) * 0.8)
	e = maxf(e, absf(pitch_disp - float(_shown[2])) * 0.8)
	e = maxf(e, absf(roll_angle - float(_shown[3])))
	e = maxf(e, absf(steer - float(_shown[4])))
	e = maxf(e, absf(wrapf(_spin_angle - float(_shown[5]), -PI, PI)) * (RENDER_ANGLE / RENDER_SPIN))
	for i in mini(offsets.size(), _shown_offsets.size()):
		e = maxf(e, absf(offsets[i] - _shown_offsets[i]) * (RENDER_ANGLE / RENDER_OFFSET))
	return e


## Records the pose the texture is about to show.
func _accept_pose(heading: float, roll_disp: float, pitch_disp: float, roll_angle: float, steer: float,
		offsets: PackedFloat32Array) -> void:
	var want := [heading, roll_disp, pitch_disp, roll_angle, steer, _spin_angle]
	for i in want.size():
		_shown[i] = want[i]
	for i in mini(offsets.size(), _shown_offsets.size()):
		_shown_offsets[i] = offsets[i]


# ---------------------------------------------------------------- mesh helpers

func _mat(c: Color, rough: float = 0.6, metal: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


func _add(mesh: Mesh, pos: Vector3, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	(parent if parent != null else _body_parts).add_child(mi)
	return mi


func _box(s: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var m := BoxMesh.new()
	m.size = s
	return _add(m, pos, mat)


## A wedge that is tall at the back and slopes down to the front (`forward_low`).
func _prism(s: Vector3, pos: Vector3, mat: Material, forward_low: bool) -> MeshInstance3D:
	var m := PrismMesh.new()
	m.size = Vector3(s.x, s.y, s.z)
	m.left_to_right = 0.0 if forward_low else 1.0
	return _add(m, pos, mat)


func _sphere(r: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.radial_segments = 10
	m.rings = 5
	return _add(m, pos, mat)


## A cylinder; `upright` stands it along Y, otherwise its axis runs along Z (an axle).
func _cylinder(r: float, h: float, pos: Vector3, mat: Material, upright: bool) -> MeshInstance3D:
	var m := CylinderMesh.new()
	m.top_radius = r
	m.bottom_radius = r
	m.height = h
	m.radial_segments = 8
	m.rings = 1
	var mi := _add(m, pos, mat)
	if not upright:
		mi.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	return mi


## Four wheels at (+-x, radius + lift, +-z), in Car.WHEEL_LOCAL order: FL, FR, RL, RR (left = -Z).
func _four_wheels(radius: float, width: float, x: float, z: float, tyre: Material, lift: float = 0.0) -> void:
	var hub := _mat(Color(0.62, 0.62, 0.66), 0.3, 0.6)
	var spots := [Vector3(x, 0, -z), Vector3(x, 0, z), Vector3(-x, 0, -z), Vector3(-x, 0, z)]
	for p in spots:
		var steer := Node3D.new()
		steer.position = Vector3(p.x, radius + lift, p.z)
		steer.set_meta("base", steer.position)
		_center.add_child(steer)
		var spin := Node3D.new()
		steer.add_child(spin)
		var t := CylinderMesh.new()
		t.top_radius = radius
		t.bottom_radius = radius
		t.height = width
		t.radial_segments = 8
		t.rings = 1
		var tire := MeshInstance3D.new()
		tire.mesh = t
		tire.material_override = tyre
		tire.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		spin.add_child(tire)
		_tyres.append(tire)
		# The rim under the tyre: smaller, bare metal, shown once the tyre has burst (SPEC 45).
		var rm := CylinderMesh.new()
		rm.top_radius = radius * 0.72
		rm.bottom_radius = radius * 0.72
		rm.height = width * 0.8
		rm.radial_segments = 8
		rm.rings = 1
		var rim := MeshInstance3D.new()
		rim.mesh = rm
		rim.material_override = _mat(Color(0.7, 0.68, 0.64), 0.25, 0.9)
		rim.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		rim.position = Vector3(0.0, -radius * 0.28, 0.0)   # sits down on the road
		rim.visible = false
		spin.add_child(rim)
		_rims.append(rim)
		# A hub block so the spin is visible.
		var h := BoxMesh.new()
		h.size = Vector3(radius * 1.1, radius * 0.5, width + 0.3)
		var hb := MeshInstance3D.new()
		hb.mesh = h
		hb.material_override = hub
		spin.add_child(hb)
		_wheels.append(steer)
		_wheel_spin.append(spin)


# ---------------------------------------------------------------- damage (SPEC 45)

## Wheel `i` has burst (or is new again): the rubber goes, the car sits on the bare rim.
func set_tyre_burst(i: int, burst: bool) -> void:
	if i < 0 or i >= _tyres.size() or bool(_burst[i]) == burst:
		return
	_burst[i] = burst
	_apply_wheel_look(i)
	_dirty()


## SPEC 128: wheel `i` is INTACT / LOOSE (buckled) / GONE, as `CarBody` sees it.
func set_wheel_state(i: int, st: int) -> void:
	if i < 0 or i >= _wheel_state.size() or _wheel_state[i] == st:
		return
	_wheel_state[i] = st
	_apply_wheel_look(i)
	_dirty()


func wheel_state(i: int) -> int:
	return _wheel_state[i] if i >= 0 and i < _wheel_state.size() else 0


## Rubber, rim and pose for one corner, from the two things that decide them: whether the tyre has burst
## and what state the wheel is in. They used to fight over `_tyres[i].visible` -- a burst tyre and a
## missing wheel are different words for the same mesh -- so one applier owns it.
func _apply_wheel_look(i: int) -> void:
	if i >= _tyres.size() or i >= _rims.size():
		return
	var st: int = _wheel_state[i]
	var gone: bool = st == ST_GONE
	_tyres[i].visible = not gone and not bool(_burst[i])
	_rims[i].visible = not gone and bool(_burst[i])
	# `pose()` may not run for a while (an unchanged pose skips the whole pass), so the corner is moved
	# here too, from the last suspension travel it was posed with.
	if i < _wheels.size() and _wheels[i].has_meta("base"):
		var base: Vector3 = _wheels[i].get_meta("base")
		var off: float = _shown_offsets[i] if i < _shown_offsets.size() else 0.0
		if not is_finite(off):
			off = 0.0
		_wheels[i].position = base + Vector3(0.0, off * WHEEL_TRAVEL - float(WHEEL_SINK[st]), 0.0)
		_wheel_spin[i].rotation = Vector3(float(WHEEL_CAMBER[st]) * signf(base.z), 0.0, -_spin_angle)


## SPEC 128: component `part_id`, which sits at car-local `local` (px, x forward, y right), has reached
## `st`. Dented and loose push the metal in around that point; gone takes the nearest loose piece off.
## Only ever escalates -- the same state pushed twice is free, which is what lets `Car` re-push the whole
## body every frame without keeping a diff of its own.
func set_part_state(part_id: String, local: Vector2, st: int) -> Dictionary:
	if st <= int(_part_state.get(part_id, 0)):
		return {}
	_part_state[part_id] = st
	if st >= ST_GONE:
		return detach_near(local)
	_dent_near(local, 0.5 if st == ST_DENTED else 1.0)
	return {}


## Everything back on and round: a repaired or re-gridded car. Panels already knocked off by a CRASH stay
## off (SPEC 68 marks them "lost"), which is the existing rule -- this undoes the component damage the
## body model applied, so the states and the picture start a race agreeing.
func restore_body() -> void:
	_part_state.clear()
	for i in _wheel_state.size():
		_wheel_state[i] = 0
		_apply_wheel_look(i)
	_dirty()


## The piece nearest a car-local point, knocked off. `detach_part` picks by SIDE, which is right for a
## zone ("something off the front"); a named component knows where it is, so it picks by distance.
func detach_near(local: Vector2) -> Dictionary:
	if _body_parts == null:
		return {}
	var want := Vector3(local.x, 0.0, local.y)
	var biggest := 0.0
	for c in _body_parts.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null and not mi.has_meta("inner"):
			var sz := mi.mesh.get_aabb().size
			biggest = maxf(biggest, sz.x * sz.y * sz.z)
	var best: MeshInstance3D = null
	var best_d := INF
	for c in _body_parts.get_children():
		var mi := c as MeshInstance3D
		if mi == null or not mi.visible or mi.mesh == null or mi.has_meta("inner"):
			continue
		var sz := mi.mesh.get_aabb().size
		if sz.x * sz.y * sz.z >= biggest * 0.6:
			continue                              # the shell stays on: a car without one is not a car
		var d := Vector3(mi.position.x, 0.0, mi.position.z).distance_to(want)
		if d < best_d:
			best_d = d
			best = mi
	if best == null:
		return {}
	return _lose(best)


## Metal pushed in AROUND a point, rather than across a whole side.
func _dent_near(local: Vector2, strength: float) -> void:
	if _body_parts == null:
		return
	var want := Vector3(local.x, 0.0, local.y)
	var inward := -want.normalized() if want.length() > 0.01 else Vector3.ZERO
	_dent_seq += 1
	for c in _body_parts.get_children():
		var mi := c as MeshInstance3D
		if mi == null or not mi.visible:
			continue
		if not mi.has_meta("base"):
			mi.set_meta("base", mi.position)
		var base: Vector3 = mi.get_meta("base")
		var w := clampf(1.0 - Vector3(mi.position.x, 0.0, mi.position.z).distance_to(want) / 11.0,
				0.0, 1.0) * strength
		if w <= 0.01:
			continue
		mi.position = base + ((mi.position + inward * 1.8 * w) - base).limit_length(4.0)
		var n := float(_dent_seq) * 1.7 + mi.position.x * 0.3
		mi.rotation += Vector3(sin(n) * 0.09, cos(n * 1.3) * 0.06, sin(n * 0.7) * 0.09) * w
	_dirty()


## A hit from the car-local direction `local` (x forward, y right) of `strength` 0..1: the panels on that
## side are pushed in and twisted a little -- they crumple, and stay crumpled.
func dent(local: Vector2, strength: float) -> void:
	if _body_parts == null:
		return
	var dir3 := Vector3(local.x, 0.0, local.y).normalized()
	_dent_seq += 1
	for c in _body_parts.get_children():
		var mi := c as MeshInstance3D
		if mi == null or not mi.visible:
			continue
		if not mi.has_meta("base"):
			mi.set_meta("base", mi.position)
		var base: Vector3 = mi.get_meta("base")
		var along := Vector3(mi.position.x, 0.0, mi.position.z).dot(dir3)
		if along < 1.5:
			continue                              # the far side of the car is untouched
		var w := clampf((along - 1.5) / 10.0, 0.0, 1.0) * strength
		var pushed := mi.position - dir3 * 1.6 * w
		mi.position = base + (pushed - base).limit_length(4.0)
		var n := float(_dent_seq) * 1.7 + mi.position.x * 0.3
		mi.rotation += Vector3(sin(n) * 0.08, cos(n * 1.3) * 0.05, sin(n * 0.7) * 0.08) * w
		mi.scale = mi.scale * Vector3(1.0 - 0.04 * w * absf(dir3.x), 1.0 - 0.05 * w, 1.0 - 0.04 * w * absf(dir3.z))
	_dirty()


## Knocks off one piece on the side `local` points at -- the most exposed, biggest-looking one there that is
## not the main body (a spoiler, a wing, a bumper before a lamp):
## it disappears from the model; returns its colour and footprint (px) for the debris, or {} if nothing
## is left to lose on that side.
func detach_part(local: Vector2) -> Dictionary:
	if _body_parts == null:
		return {}
	var dir3 := Vector3(local.x, 0.0, local.y).normalized()
	var best: MeshInstance3D = null
	var best_score := -INF
	var biggest := 0.0
	for c in _body_parts.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null and not mi.has_meta("inner"):
			var sz := mi.mesh.get_aabb().size
			biggest = maxf(biggest, sz.x * sz.y * sz.z)
	for c in _body_parts.get_children():
		var mi := c as MeshInstance3D
		if mi == null or not mi.visible or mi.mesh == null:
			continue
		if mi.has_meta("inner"):
			continue                              # the engine and the seats are not bodywork
		var sz := mi.mesh.get_aabb().size
		var vol := sz.x * sz.y * sz.z
		if vol >= biggest * 0.6:
			continue                              # the main body shell stays on
		var along := Vector3(mi.position.x, 0.0, mi.position.z).dot(dir3)
		if along < 2.0:
			continue
		var score := along * pow(maxf(vol, 0.1), 0.35)
		if score > best_score:
			best_score = score
			best = mi
	if best == null:
		return {}
	return _lose(best)


## One piece off the car, and whatever it was covering now in plain sight. Returns the debris.
func _lose(best: MeshInstance3D) -> Dictionary:
	best.visible = false
	best.set_meta("lost", true)          # SPEC 68: a crash takes it for good; the garage cannot refit it
	_dirty()
	# The panel is gone, so what it covered is now in plain sight (SPEC 51).
	if best.has_meta("reveals"):
		var shown := String(best.get_meta("reveals"))
		for piece in _inners.get(shown, []):
			(piece as MeshInstance3D).visible = true
		for c in _body_parts.get_children():
			var g := c as MeshInstance3D
			if g != null and g.has_meta("glass_of") and String(g.get_meta("glass_of")) == shown:
				g.visible = false                 # the screen goes with the roof
	var col := Color(0.2, 0.2, 0.22)
	var mat := best.material_override as StandardMaterial3D
	if mat != null:
		col = mat.albedo_color
	var bs := best.mesh.get_aabb().size
	return {"color": col, "size": Vector2(clampf(bs.x, 4.0, 16.0), clampf(bs.z, 3.0, 16.0))}


func set_wheel_scale(scale: float) -> void:
	var s := clampf(scale, 0.5, 2.0)
	for w in _wheels:
		if w != null:
			w.scale = Vector3(1.0, s, s)
	_dirty()


## Marks a panel as the cover over `name`: knocking it off shows what is underneath (SPEC 51).
func _covers(mi: MeshInstance3D, name: String) -> MeshInstance3D:
	mi.set_meta("reveals", name)
	return mi


## Glass over `name`: it goes when whatever covers `name` is knocked off, so the seats underneath are
## actually visible instead of sitting behind a tinted screen (SPEC 51).
func _glass_over(mi: MeshInstance3D, name: String) -> MeshInstance3D:
	mi.set_meta("glass_of", name)
	return mi


## Something inside the car, hidden until its cover comes off (SPEC 51).
func _inner(mi: MeshInstance3D, name: String) -> MeshInstance3D:
	mi.visible = false
	mi.set_meta("inner", name)
	var list: Array = _inners.get(name, [])
	list.append(mi)
	_inners[name] = list
	return mi


## An engine bay: the block, its cam cover and a pair of pipes, at `x` with the block top at `y` (SPEC 51).
func _engine(x: float, y: float, name: String = "engine") -> void:
	var block := _mat(Color(0.20, 0.21, 0.23), 0.75, 0.6)
	var hot := _mat(Color(0.32, 0.20, 0.12), 0.6, 0.5)
	var belt := _mat(Color(0.07, 0.07, 0.08), 0.9)
	var alloy := _mat(Color(0.62, 0.64, 0.68), 0.3, 0.9)
	_inner(_box(Vector3(8, 4.5, 10), Vector3(x, y - 2.0, 0), block), name)
	_inner(_box(Vector3(5.0, 1.4, 4.0), Vector3(x, y + 0.5, 0), alloy), name)      # plenum
	_inner(_box(Vector3(5.5, 1.0, 1.6), Vector3(x, y + 0.4, -3.0), hot), name)     # cam covers
	_inner(_box(Vector3(5.5, 1.0, 1.6), Vector3(x, y + 0.4, 3.0), hot), name)
	_inner(_cylinder(1.0, 6.0, Vector3(x - 3.5, y - 1.0, 0), belt, false), name)
	_inner(_box(Vector3(1.4, 1.4, 9), Vector3(x + 4.0, y - 2.6, 0), belt), name)


## A cockpit: two seats, the wheel and a roll bar behind them, centred at `x`, floor at `y` (SPEC 51).
func _cabin(x: float, y: float, name: String = "cabin") -> void:
	var seat := _mat(Color(0.12, 0.12, 0.14), 0.85)
	var cage := _mat(Color(0.75, 0.76, 0.80), 0.35, 0.8)
	for side in [-1.0, 1.0]:
		_inner(_box(Vector3(4.5, 3.0, 4.0), Vector3(x - 1.0, y + 1.0, side * 3.4), seat), name)
		_inner(_box(Vector3(1.2, 4.0, 4.0), Vector3(x - 3.6, y + 2.2, side * 3.4), seat), name)
	_inner(_cylinder(2.0, 0.5, Vector3(x + 3.6, y + 3.0, -3.4), cage, false), name)
	_inner(_box(Vector3(1.0, 5.0, 12.0), Vector3(x - 5.0, y + 3.0, 0), cage), name)


## Headlights (front) and tail lights (back) at height `y`, front face at x = `front`.
func _lamps(lamp: Material, tail: Material, front: float, y: float) -> void:
	for side in [-1.0, 1.0]:
		_box(Vector3(1.0, 1.6, 3.4), Vector3(front, y, side * 5.5), lamp)
		_box(Vector3(1.0, 1.4, 3.4), Vector3(-front + 0.2, y, side * 5.5), tail)


## Reframes the view: `units` of the world across `pixels`, camera `tilt_deg` from straight down. The
## in-race car uses the defaults; the car select screen uses a big, steeper turntable view.
func set_view(units: float, pixels: int, tilt_deg: float) -> void:
	size = Vector2i(pixels, pixels)
	_camera.size = units
	var t := deg_to_rad(tilt_deg)
	_camera.look_at_from_position(Vector3(0.0, cos(t), sin(t)) * 150.0, Vector3.ZERO, Vector3(0.0, 0.0, -1.0))


## Takes the built model out of this viewport, for use in another 3D scene (the key-art renderer in
## tools/). The returned node is the model's yaw root: +X is the car's nose, +Y up; it is 1 unit per game
## pixel (a car is ~36 long).
func detach_model() -> Node3D:
	var m := _yaw
	remove_child(m)
	_yaw = null
	return m


## The rendered texture.
func get_car_texture() -> Texture2D:
	return get_texture()
