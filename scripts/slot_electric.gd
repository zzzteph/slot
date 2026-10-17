class_name SlotElectric
extends Node2D
## The power in the track. A slot car runs on the current in the two braids either side of its slot, so
## that is what shows when you squeeze the trigger: a WAVE of current rippling back along your lane's
## braids from the guide blade (longer and brighter the harder the motor pulls), and a small ARC jumping
## between the braids under the guide where the pickups touch them.
##
## Drawn on the track, under the cars, every frame: a few short polylines per car, nothing allocated.

const WAVE_POINTS := 14
const WAVE_BASE := 50.0          # px of wave behind the guide at a whisper of throttle
const WAVE_PER_SPEED := 0.16     # ... plus this many px per px/s of speed
const WAVE_AMP := 2.2            # px the braid's light swings either side of it
const WAVE_FREQ := 0.22          # rad per px along the braid
const WAVE_SPEED := 30.0         # rad per second: how fast the ripples run back
const ARC_POINTS := 5
const CORE := Color(0.85, 0.95, 1.0)
const GLOW := Color(0.35, 0.75, 1.0)

var cars: Array = []
var _t: float = 0.0
var _rng := RandomNumberGenerator.new()
var _line := PackedVector2Array()


func _ready() -> void:
	z_index = SlotTrack.Z_CAR_LOW - 1
	z_as_relative = false
	_line.resize(WAVE_POINTS)
	_rng.randomize()


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	for c in cars:
		var car := c as SlotCar
		if car == null or not car.is_slotted() or car.lane == null or car.throttle < 0.04:
			continue
		var power := car.throttle
		var length := WAVE_BASE + car.speed * WAVE_PER_SPEED * power
		var guide_s := car.visual_s()      # where the car is drawn this frame, not the last tick
		for side in [-1.0, 1.0]:
			for i in WAVE_POINTS:
				var d := length * float(i) / float(WAVE_POINTS - 1)
				var at := guide_s - d
				var h := car.lane.heading_at(at)
				var n := Vector2(-sin(h), cos(h))
				var fade := 1.0 - d / length
				var wobble := sin(d * WAVE_FREQ - _t * WAVE_SPEED) * WAVE_AMP * fade * power
				_line[i] = car.lane.position_at(at) + n * (side * SlotTrack.RAIL_OFFSET + wobble)
			draw_polyline(_line, Color(GLOW, 0.35 * power), 4.0)
			draw_polyline(_line, Color(CORE, 0.75 * power), 1.4)
		# The arc under the guide: re-drawn jagged every frame, there most of the time at full power.
		if _rng.randf() < 0.35 + 0.6 * power:
			var g := car.lane.position_at(guide_s)
			var h := car.lane.heading_at(guide_s)
			var n := Vector2(-sin(h), cos(h))
			var f := Vector2(cos(h), sin(h))
			var arc := PackedVector2Array()
			for i in ARC_POINTS:
				var u := float(i) / float(ARC_POINTS - 1)
				var jag := 0.0 if i == 0 or i == ARC_POINTS - 1 else _rng.randf_range(-3.0, 3.0)
				arc.append(g + n * lerpf(-SlotTrack.RAIL_OFFSET, SlotTrack.RAIL_OFFSET, u) + f * jag)
			draw_polyline(arc, Color(GLOW, 0.6), 3.0)
			draw_polyline(arc, CORE, 1.2)
