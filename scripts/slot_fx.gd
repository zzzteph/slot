class_name SlotFx
extends Node2D
## The race's few effects, in one node with one fixed pool: electric SPARKS off the braids under a
## car's guide blade when the motor is pulling hard (real slot cars do this), and SMOKE when a tail is
## ## hanging out or a car leaves the slot. The current in the braids is `SlotElectric`. A capped pool
## and plain draw calls -- nothing here allocates during a race.

const MAX := 160
const SPARK := 0
const SMOKE := 1

var _pos := PackedVector2Array()
var _vel := PackedVector2Array()
var _life := PackedFloat32Array()
var _max := PackedFloat32Array()
var _kind := PackedByteArray()
var _next: int = 0
var _alive: int = 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	z_index = SlotTrack.Z_CAR_AIR + 1
	z_as_relative = false
	_pos.resize(MAX)
	_vel.resize(MAX)
	_life.resize(MAX)
	_max.resize(MAX)
	_kind.resize(MAX)
	_rng.randomize()


func spark(at: Vector2, heading: float) -> void:
	var dir := Vector2.from_angle(heading + PI + _rng.randf_range(-0.7, 0.7))
	_add(at, dir * _rng.randf_range(60.0, 180.0), _rng.randf_range(0.10, 0.22), SPARK)


func smoke(at: Vector2, drift: Vector2 = Vector2.ZERO) -> void:
	var v := drift * 0.25 + Vector2(_rng.randf_range(-20, 20), _rng.randf_range(-20, 20))
	_add(at, v, _rng.randf_range(0.5, 0.9), SMOKE)


func burst(at: Vector2, heading: float) -> void:
	for i in 10:
		spark(at, heading + PI + _rng.randf_range(-1.2, 1.2))
	for i in 8:
		smoke(at + Vector2(_rng.randf_range(-10, 10), _rng.randf_range(-10, 10)))


func _add(at: Vector2, vel: Vector2, life: float, kind: int) -> void:
	var i := _next
	_next = (_next + 1) % MAX
	if _life[i] <= 0.0:
		_alive += 1
	_pos[i] = at
	_vel[i] = vel
	_life[i] = life
	_max[i] = life
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
		if _kind[i] == SPARK:
			var tail := _vel[i] * 0.03
			draw_line(_pos[i], _pos[i] - tail, Color(0.70, 0.90, 1.0, t), 2.0)
		else:
			draw_circle(_pos[i], 6.0 + (1.0 - t) * 12.0, Color(0.85, 0.85, 0.85, 0.35 * t))
