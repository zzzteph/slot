class_name SlotAI
extends RefCounted
## A rival's thumb. It has exactly the input the player has -- the trigger, held or not -- and the same
## car physics, so it can only be as fast as the throttle lets it be.
##
## Before the race it works out a SPEED PROFILE for its own car in its own lane: at every point, the
## fastest the car can go round that bend with `margin` of its grip (sqrt(margin x grip / curvature)),
## then brought down by a backwards pass so every bend is reached slowly enough to brake for. During the
## race it holds the trigger while it is under the profile a short way ahead, and lets go when it is over.
##
## Its mistakes are greed: now and then it decides it can carry `GREED` more speed for a couple of
## seconds. A careful driver has enough margin to get away with that; a fast one may not.

const DIFFICULTIES := ["easy", "medium", "hard"]
const MARGIN := {"easy": 0.62, "medium": 0.80, "hard": 0.93}
## The most of its top speed it ever asks for: a beginner never quite floors it on a straight.
const TOP_SHARE := {"easy": 0.86, "medium": 0.95, "hard": 1.0}
## Greedy moments per second, and how long one lasts.
const GREED_RATE := {"easy": 0.04, "medium": 0.06, "hard": 0.05}
const GREED_TIME := 2.0
const GREED := 1.13
## How far ahead it looks, in seconds at its current speed: the throttle takes time to close.
const LOOKAHEAD := 0.2
## The motor brake a released trigger really delivers, once the throttle has closed, as a share of the
## car's `brake` -- the profile plans on this.
const BRAKE_SHARE := 0.72

var car: SlotCar = null
var difficulty: String = "medium"
var profile := PackedFloat32Array()
var _rng := RandomNumberGenerator.new()
var _greed_left: float = 0.0


func setup(car_: SlotCar, difficulty_: String, seed_value: int) -> void:
	car = car_
	difficulty = difficulty_ if MARGIN.has(difficulty_) else "medium"
	_rng.seed = seed_value
	profile = build_profile(car.lane, car.grip * float(MARGIN[difficulty]), car.top_speed * float(TOP_SHARE[difficulty]),
			car.brake * BRAKE_SHARE)


## The fastest safe speed at every point of `lane` for a car with `grip`, `top` and `decel`.
static func build_profile(lane: SlotLane, grip: float, top: float, decel: float) -> PackedFloat32Array:
	var n := lane.point_count()
	var v := PackedFloat32Array()
	v.resize(n)
	for i in n:
		var k := absf(lane.curvature[i])
		v[i] = minf(top, sqrt(grip / k)) if k > 0.000001 else top
	# Backwards, twice round so the wrap is settled: no point may be faster than the next one allows
	# with the brakes on.
	for pass_ in 2:
		for step in n:
			var i := n - 1 - step
			var j := (i + 1) % n
			var ds := lane.arc[j] - lane.arc[i] if j != 0 else lane.length - lane.arc[i]
			v[i] = minf(v[i], sqrt(v[j] * v[j] + 2.0 * decel * ds))
	return v


func target_speed() -> float:
	if car == null or profile.is_empty():
		return 0.0
	var ahead := car.s + maxf(car.speed, 60.0) * LOOKAHEAD
	var t := profile[car.lane.index_at(ahead)]
	t = minf(t, profile[car.lane.index_at(car.s)])
	if _greed_left > 0.0:
		t *= GREED
	return t


## Sets the car's trigger for this step.
func drive(dt: float) -> void:
	if car == null:
		return
	if _greed_left > 0.0:
		_greed_left -= dt
	elif _rng.randf() < float(GREED_RATE[difficulty]) * dt:
		_greed_left = GREED_TIME
	if not car.is_slotted():
		car.trigger = false
		return
	# Hold the trigger while under the line; a touch of hysteresis so it is not flickering 60 times a
	# second on a straight.
	var target := target_speed()
	if car.speed < target - 6.0:
		car.trigger = true
	elif car.speed > target:
		car.trigger = false
