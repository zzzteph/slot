class_name SlotCar
extends Node2D
## A slot car. There is ONE input: the trigger (Space, a mouse button, a finger on the screen). Hold it
## and the THROTTLE climbs -- the longer you hold, the more power -- let go and it falls away and the
## motor brakes the car. Where the car goes is not your problem: its guide blade is in the slot.
##
## What IS your problem is the bend. The sideways load is speed^2 x curvature; against it the car has
## its `grip`. Below the limit the tail swings out further the nearer you get (that is the warning).
## Past it, the car is sliding: it builds STRESS, faster the further over you are, and scrubs off a
## little speed. Stress reaches 1 -- or the load is wildly over the limit -- and the car leaves the slot:
## it flies off the way it was pointing, spins, maybe barrel-rolls, and a marshal puts it back where it
## came off after a couple of seconds.
##
## The simulation is `step()`, called by the race at a fixed rate; nothing here reads the scene tree,
## so it runs headless in the tests exactly as it does in the game.

signal deslotted(car: SlotCar)
signal reslotted(car: SlotCar)

enum State { SLOTTED, OFF, MARSHAL }

## Throttle per second while the trigger is held, and while it is not.
const THROTTLE_RISE := 0.95
const THROTTLE_FALL := 3.2
## ANALOG control (a dragged mouse, a pad trigger): the throttle follows `demand` this fast -- quick,
## like a real controller's resistor, but not a step.
const ANALOG_RISE := 3.5
const ANALOG_FALL := 6.0
## Above full-throttle speed... below it, a partly open throttle coasts down at this much plus the
## brake's share of what is closed.
const COAST_DECEL := 160.0
## The tail swings out from half the limit, to TAIL_MAX at the limit.
const TAIL_FROM := 0.5
const TAIL_MAX := 0.32
const TAIL_RATE := 9.0
## Past the limit: stress per second = (over x STRESS_GAIN + STRESS_BASE) / forgiveness.
const STRESS_GAIN := 9.0
const STRESS_BASE := 1.2
const STRESS_RELIEF := 2.6
## A load this far over the limit (scaled by forgiveness) is out at once, whatever the stress.
const HARD_OVER := 0.42
## Speed scrubbed per second per unit over the limit, while sliding.
const SLIDE_SCRUB := 520.0

## Off the slot: how fast a sliding car slows on the table, how its spin dies away, how long at least
## before the marshal can reach it, and how long the marshal takes.
const OFF_FRICTION := 950.0
const SPIN_DECAY := 3.0
const OFF_MIN_TIME := 0.9
const MARSHAL_TIME := 0.9
## A car leaving at this share of its top speed or more goes over as well as round.
const ROLL_SHARE := 0.62
const ROLL_TIME := 0.75

## How big a car is drawn, against the Rope Racers model (36 x 18 px). Drawing only: the physics is
## a point on the slot.
const CAR_SCALE := 1.5
## The guide blade is this far ahead of the car's centre: the car pivots on it, so a swinging tail
## really swings.
const GUIDE := 12.0 * CAR_SCALE
const BODY_LENGTH := 36.0 * CAR_SCALE
const BODY_WIDTH := 18.0 * CAR_SCALE

# ---- identity
var car_id: String = CarCatalog.DEFAULT_ID
var display_name: String = "Player"
var is_player: bool = false
var body_color := Color(0.15, 0.42, 0.92)
var stripe_color := Color(1, 1, 1, 0.85)
var style: String = "sport"

# ---- car numbers (from CarCatalog)
var top_speed: float = 900.0
var accel: float = 640.0
var brake: float = 1400.0
var grip: float = 1150.0
var forgiveness: float = 1.0

# ---- state
var lane: SlotLane = null
var state: State = State.SLOTTED
var s: float = 0.0               # arc length travelled along the lane since the start (not wrapped)
var speed: float = 0.0
var throttle: float = 0.0
var load_ratio: float = 0.0      # sideways load / grip, signed by which way the bend goes
var stress: float = 0.0
var tail: float = 0.0            # rad the body is swung from the slot's heading
var heading: float = 0.0         # the body's heading (the simulation's; see `world_pos`)
## WHERE THE CAR REALLY IS, as the simulation moves it, once per physics tick. The node's own
## `position` is where it is DRAWN: every frame it is placed between the last two ticks
## (`Engine.get_physics_interpolation_fraction`), so on a screen faster than the 60 Hz simulation the
## car glides instead of stepping. `interpolate` off (the menu's posed cars) draws `position` as set.
var world_pos := Vector2.ZERO
var interpolate := true
var trigger: bool = false        # what the driver is doing this step (on/off control)
## Analog control: 0..1, how far the trigger is squeezed; negative = not in use (the on/off `trigger`
## drives the throttle instead).
var demand: float = -1.0
var deslots: int = 0
var finished: bool = false
var frozen: bool = false         # held on the grid / after the flag: step() keeps it still

var _off_s: float = 0.0
var _off_vel := Vector2.ZERO
var _spin: float = 0.0
var _off_time: float = 0.0
var _marshal_time: float = 0.0
var _roll_phase: float = -1.0
var _roll_dir: float = 1.0
var _accel_now: float = 0.0
var _travel: float = 0.0
var _model: CarModel3D = null
var _redraw := true
var _prev_pos := Vector2.ZERO
var _prev_heading: float = 0.0
var _prev_s: float = 0.0
var _draw_heading: float = 0.0

static var use_3d_models := true


func configure(id: String, colour_index: int) -> void:
	car_id = CarCatalog.get_car(id)["id"]
	var c := CarCatalog.get_car(car_id)
	top_speed = float(c["top_speed"])
	accel = float(c["accel"])
	brake = float(c["brake"])
	grip = float(c["grip"])
	forgiveness = float(c["forgiveness"])
	style = String(c["style"])
	body_color = CarCatalog.body_color(car_id, colour_index)
	stripe_color = c["stripe"]
	if _model != null:
		_model.build(style, body_color, stripe_color)


## Puts the car in `lane_` at arc length `at` (negative = behind the start line), stopped.
func place(lane_: SlotLane, at: float) -> void:
	lane = lane_
	s = at
	speed = 0.0
	throttle = 0.0
	stress = 0.0
	tail = 0.0
	load_ratio = 0.0
	state = State.SLOTTED
	_roll_phase = -1.0
	_sync_pose()
	_settle()


func _ready() -> void:
	z_as_relative = false
	if use_3d_models and DisplayServer.get_name() != "headless":
		_model = CarModel3D.new()
		_model.name = "Model3D"
		_model.priority = is_player
		_model.set_view(CarModel3D.VIEW_UNITS, model_pixels(), CarModel3D.CAMERA_TILT)
		add_child(_model)
		_model.build(style, body_color, stripe_color)


func is_slotted() -> bool:
	return state == State.SLOTTED


## Laps as a float: 0 on the line at the start, 1.0 one lap later. Negative on the grid.
func progress() -> float:
	if lane == null or lane.length <= 0.0:
		return 0.0
	return s / lane.length


func laps_done() -> int:
	return maxi(int(floor(progress())), 0)


## How close to leaving the slot the car is, 0..1: the load up to the limit, then the stress past it.
func danger() -> float:
	if state != State.SLOTTED:
		return 1.0
	var r := absf(load_ratio)
	if r < 1.0 and stress <= 0.0:
		return r * 0.8
	return clampf(0.8 + 0.2 * maxf(stress, r - 1.0), 0.8, 1.0)


## How much of the marshal's job is done, 0..1 (for the HUD); 0 while slotted.
func recovery() -> float:
	match state:
		State.OFF:
			return clampf(_off_time / (OFF_MIN_TIME + MARSHAL_TIME), 0.0, 0.5)
		State.MARSHAL:
			return 0.5 + 0.5 * clampf(_marshal_time / MARSHAL_TIME, 0.0, 1.0)
	return 0.0


# ------------------------------------------------------------------ simulation

func step(dt: float) -> void:
	if lane == null or dt <= 0.0:
		return
	_prev_pos = world_pos
	_prev_heading = heading
	_prev_s = s
	# Held on the grid, the throttle still answers the trigger (you can wind it up for the start); only
	# the wheels are held.
	if demand >= 0.0:
		var d := clampf(demand, 0.0, 1.0)
		throttle = move_toward(throttle, d, (ANALOG_RISE if d > throttle else ANALOG_FALL) * dt)
	else:
		var want := trigger
		throttle = move_toward(throttle, 1.0 if want else 0.0, (THROTTLE_RISE if want else THROTTLE_FALL) * dt)
	match state:
		State.SLOTTED:
			_step_slotted(dt)
		State.OFF:
			_step_off(dt)
		State.MARSHAL:
			_marshal_time += dt
			if _marshal_time >= MARSHAL_TIME:
				_reslot()
	position = world_pos
	_draw_heading = heading
	_redraw = true


func _step_slotted(dt: float) -> void:
	var before := speed
	if frozen:
		speed = 0.0
	else:
		var target := throttle * top_speed
		if speed < target:
			speed = minf(target, speed + accel * (1.0 - 0.55 * speed / top_speed) * dt)
		else:
			speed = maxf(target, speed - (COAST_DECEL + brake * (1.0 - throttle)) * dt)
	var k := lane.curvature_at(s)
	var ratio := speed * speed * absf(k) / grip
	load_ratio = ratio * signf(k)
	if ratio > 1.0:
		var over := ratio - 1.0
		stress += (over * STRESS_GAIN + STRESS_BASE) * dt / forgiveness
		speed = maxf(speed - over * SLIDE_SCRUB * dt, 0.0)
		if stress >= 1.0 or over > HARD_OVER * forgiveness:
			_deslot(k)
			return
	else:
		stress = maxf(stress - STRESS_RELIEF * dt, 0.0)
	_accel_now = (speed - before) / dt
	var ds := speed * dt
	s += ds
	_travel += ds
	var swing := smoothstep(TAIL_FROM, 1.0, ratio) * TAIL_MAX
	# Sliding past the limit, the tail hunts about -- the car is visibly in trouble.
	if stress > 0.0:
		swing = TAIL_MAX * (1.0 + 0.35 * stress) + sin(Time.get_ticks_msec() * 0.03) * 0.05 * stress
	tail = lerpf(tail, swing * signf(k), clampf(TAIL_RATE * dt, 0.0, 1.0))
	_sync_pose()


func _deslot(k: float) -> void:
	state = State.OFF
	deslots += 1
	_off_s = s
	_off_time = 0.0
	# It leaves along the slot's tangent -- which, on a bend, is OUTWARD -- not along the swung body.
	_off_vel = Vector2.from_angle(lane.heading_at(s)) * speed
	var turn := signf(k) if k != 0.0 else 1.0
	_spin = turn * (2.5 + 9.0 * speed / top_speed)
	_roll_dir = -turn
	_roll_phase = 0.0 if speed > top_speed * ROLL_SHARE else -1.0
	stress = 0.0
	load_ratio = 0.0
	deslotted.emit(self)


func _step_off(dt: float) -> void:
	_off_time += dt
	world_pos += _off_vel * dt
	_off_vel = _off_vel.move_toward(Vector2.ZERO, OFF_FRICTION * dt)
	heading += _spin * dt
	_spin = move_toward(_spin, 0.0, absf(_spin) * SPIN_DECAY * dt + 0.5 * dt)
	if _roll_phase >= 0.0:
		_roll_phase += dt / ROLL_TIME
		if _roll_phase >= 1.0:
			_roll_phase = -1.0
	speed = _off_vel.length()
	_travel += speed * dt
	if _off_time >= OFF_MIN_TIME and speed < 20.0 and _roll_phase < 0.0:
		state = State.MARSHAL
		_marshal_time = 0.0
		speed = 0.0


func _reslot() -> void:
	state = State.SLOTTED
	s = _off_s
	speed = 0.0
	throttle = 0.0
	tail = 0.0
	stress = 0.0
	_spin = 0.0
	_roll_phase = -1.0
	_sync_pose()
	_settle()
	reslotted.emit(self)


## Places the node on the lane: the guide blade is on the slot, the body pivots behind it by `tail`.
func _sync_pose() -> void:
	if lane == null:
		return
	var path_h := lane.heading_at(s)
	heading = path_h + tail
	world_pos = lane.position_at(s) - Vector2.from_angle(heading) * GUIDE


## A jump (placed on the grid, put back by the marshal): nothing to glide from.
func _settle() -> void:
	_prev_pos = world_pos
	_prev_heading = heading
	_prev_s = s
	position = world_pos
	_draw_heading = heading


## Where the guide blade is (on the slot while slotted).
func guide_position() -> Vector2:
	return world_pos + Vector2.from_angle(heading) * GUIDE


## Where along the lane the car is DRAWN this frame (between the last two ticks).
func visual_s() -> float:
	return lerpf(_prev_s, s, _alpha())


func _alpha() -> float:
	if not is_inside_tree() or get_tree().paused:
		return 1.0
	return clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)


func lane_index() -> int:
	return lane.index_at(s) if lane != null else 0


# ------------------------------------------------------------------ drawing

func _process(_delta: float) -> void:
	if not interpolate:
		_draw_heading = heading
	elif lane != null:
		var a := _alpha()
		var was := position
		position = _prev_pos.lerp(world_pos, a)
		_draw_heading = lerp_angle(_prev_heading, heading, a)
		if position != was:
			_redraw = true
	if _redraw or (_model != null and _model.render_pending()):
		_redraw = false
		queue_redraw()


func _request_redraw() -> void:
	_redraw = true


func _draw() -> void:
	var air := _air_height()
	# Shadow on the track, further off the higher the car is.
	var sh := (Vector2(4, 6) + Vector2(10, 12) * air) * CAR_SCALE
	var shadow_pts := PackedVector2Array()
	for k in 12:
		var a := TAU * float(k) / 12.0
		shadow_pts.append(sh + Vector2(cos(a) * BODY_LENGTH * 0.52, sin(a) * BODY_WIDTH * 0.62).rotated(_draw_heading))
	draw_colored_polygon(shadow_pts, Color(0, 0, 0, 0.30 * (1.0 - 0.5 * air)))
	if _model != null:
		_draw_model(air)
	else:
		_draw_flat()
	if is_player and state == State.SLOTTED:
		# A small marker over your car: with four cars in a pack, you should never have to look for it.
		var up := Vector2(0, -26.0 * CAR_SCALE)
		draw_colored_polygon(PackedVector2Array([up + Vector2(-6, -8), up + Vector2(6, -8), up]),
				Color(1, 1, 1, 0.9))


## The model's texture size: 2x supersampled at the drawn size.
static func model_pixels() -> int:
	return int(CarModel3D.VIEW_PIXELS * CAR_SCALE)


func _air_height() -> float:
	if _roll_phase >= 0.0:
		return sin(_roll_phase * PI)
	return 0.0


func _draw_model(air: float) -> void:
	var roll_angle := _roll_phase * TAU * _roll_dir if _roll_phase >= 0.0 else 0.0
	var lean := clampf(load_ratio, -1.2, 1.2) * 0.8 if state == State.SLOTTED else 0.0
	var pitch := clampf(-_accel_now / 1600.0, -1.0, 1.0) * 0.6 if state == State.SLOTTED else 0.0
	_model.pose(_draw_heading, lean, pitch, roll_angle, -tail * 0.8, PackedFloat32Array([0, 0, 0, 0]), _travel, 0.0)
	_travel = 0.0
	var px := float(model_pixels())
	var sc := (CarModel3D.VIEW_UNITS * CAR_SCALE / px) * (1.0 + 0.3 * air)
	draw_set_transform(Vector2(0.0, -air * 22.0 * CAR_SCALE), 0.0, Vector2(sc, sc))
	var half := Vector2(px, px) * 0.5
	draw_texture(_model.get_car_texture(), -half)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## No 3D in this run (headless, or a machine without it): a flat body with a stripe.
func _draw_flat() -> void:
	draw_set_transform(Vector2(0.0, -_air_height() * 22.0 * CAR_SCALE), _draw_heading, Vector2.ONE)
	var r := Rect2(Vector2(-BODY_LENGTH * 0.5, -BODY_WIDTH * 0.5), Vector2(BODY_LENGTH, BODY_WIDTH))
	draw_rect(r, body_color)
	draw_rect(Rect2(Vector2(-BODY_LENGTH * 0.5, -2.5), Vector2(BODY_LENGTH, 5)), stripe_color)
	draw_rect(Rect2(Vector2(4, -BODY_WIDTH * 0.5 + 2), Vector2(7, BODY_WIDTH - 4)), Color(0.1, 0.12, 0.16))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
