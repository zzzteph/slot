class_name SlotFx
extends Node2D
## The race's few effects, all of them ELECTRIC -- a slot car has no exhaust and its tyres hardly smoke;
## what it does is arc. SPARKS fly off the braids under a guide blade pulling hard; when a tail hangs out
## and the pickups start to lose the braids, little ARCS of lightning crackle at the guide; and a car
## leaving the slot goes in a BURST of sparks, forked arcs and a blue FLASH. (The current in the braids
## themselves is `SlotElectric`.) One fixed pool, plain draw calls -- nothing allocates during a race.

const MAX := 180
const SPARK := 0
const ARC := 1
const FLASH := 2
const GLOW := Color(0.45, 0.85, 1.0)
const CORE := Color(0.92, 0.98, 1.0)

var _pos := PackedVector2Array()
var _vel := PackedVector2Array()
var _life := PackedFloat32Array()
var _max := PackedFloat32Array()
var _size := PackedFloat32Array()
var _kind := PackedByteArray()
var _next: int = 0
var _alive: int = 0
var _rng := RandomNumberGenerator.new()
var _bolt := PackedVector2Array()


func _ready() -> void:
	z_index = SlotTrack.Z_CAR_AIR + 1
	z_as_relative = false
	_pos.resize(MAX)
	_vel.resize(MAX)
	_life.resize(MAX)
	_max.resize(MAX)
	_size.resize(MAX)
	_kind.resize(MAX)
	_bolt.resize(5)
	_rng.randomize()


func spark(at: Vector2, heading: float) -> void:
	var dir := Vector2.from_angle(heading + PI + _rng.randf_range(-0.7, 0.7))
	_add(at, dir * _rng.randf_range(60.0, 180.0), _rng.randf_range(0.10, 0.22), SPARK, 1.0)


## A short fork of lightning at `at`, about `length` px long. It flickers into a new shape every frame.
func arc(at: Vector2, length: float = 22.0) -> void:
	_add(at, Vector2.ZERO, _rng.randf_range(0.08, 0.18), ARC, length * _rng.randf_range(0.6, 1.0))


## A car leaves the slot: sparks everywhere, forked arcs and a blue flash.
func burst(at: Vector2, heading: float) -> void:
	for i in 18:
		var dir := Vector2.from_angle(heading + PI + _rng.randf_range(-1.6, 1.6))
		_add(at, dir * _rng.randf_range(90.0, 260.0), _rng.randf_range(0.2, 0.45), SPARK, 1.0)
	for i in 8:
		_add(at + Vector2(_rng.randf_range(-12, 12), _rng.randf_range(-12, 12)), Vector2.ZERO,
				_rng.randf_range(0.3, 0.6), ARC, _rng.randf_range(30.0, 52.0))
	_add(at, Vector2.ZERO, 0.5, FLASH, 60.0)


func _add(at: Vector2, vel: Vector2, life: float, kind: int, size: float) -> void:
	var i := _next
	_next = (_next + 1) % MAX
	if _life[i] <= 0.0:
		_alive += 1
	_pos[i] = at
	_vel[i] = vel
	_life[i] = life
	_max[i] = life
	_size[i] = size
	_kind[i] = kind


func live_count() -> int:
	return _alive


func _process(delta: float) -> void:
	if _alive == 0:
		return
	for i in MAX:
		if _life[i] <= 0.0:
			continue
		_life[i] -= delta
		if _life[i] <= 0.0:
			_alive -= 1
			continue
		_pos[i] += _vel[i] * delta
		_vel[i] *= 1.0 - minf(3.0 * delta, 1.0)
	queue_redraw()


func _draw() -> void:
	for i in MAX:
		if _life[i] <= 0.0:
			continue
		var t := _life[i] / _max[i]
		match _kind[i]:
			SPARK:
				draw_line(_pos[i], _pos[i] - _vel[i] * 0.03, Color(0.70, 0.90, 1.0, t), 2.0)
			ARC:
				# A jagged bolt in a random direction, a new shape every frame: that is the flicker.
				var dir := Vector2.from_angle(_rng.randf() * TAU)
				var side := Vector2(-dir.y, dir.x)
				var n := _bolt.size()
				for k in n:
					var u := float(k) / float(n - 1)
					var jag := 0.0 if k == 0 else _rng.randf_range(-0.35, 0.35) * _size[i]
					_bolt[k] = _pos[i] + dir * _size[i] * u + side * jag
				draw_polyline(_bolt, Color(GLOW, 0.5 * t), 4.0)
				draw_polyline(_bolt, Color(CORE, t), 1.6)
			FLASH:
				var r := _size[i] * (1.0 - t * 0.6)
				draw_circle(_pos[i], r, Color(GLOW, 0.22 * t))
				draw_arc(_pos[i], r, 0.0, TAU, 24, Color(CORE, 0.7 * t), 2.0)
