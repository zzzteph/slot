extends RefCounted
## Marina Bay Street Circuit, Singapore — simplified for Rope Racers (SPEC 15).
## Character: streets. Twelve corners, never a moment off the wheel — a long pit straight into the
## T1-T2-T3 left-right-left chicane, a two-stage sweep up the east end, a tight out-and-back around the
## lap's slowest corner (the Anderson Bridge hairpin), the Raffles Avenue straight, two square street
## corners and the flat-out kinks past the Flyer back onto the pit straight. Anticlockwise, as the real one.
##
## The real circuit (2023 layout) is 4.927 km, 19 turns, anticlockwise. This is a 12-corner abstraction of
## its rhythm, not its survey: the opening chicane, the slow hairpin sector, the long post-T14 straight and
## the fast kinks onto the pit straight are all in the right order and the right relative severity.
##
## AUTHORING NOTE (SPEC 15.1, "arc_points() to write an explicit long curve into the control points").
## Every corner here is an EXPLICIT circular arc, written into `control_points()` with
## `TrackShape.arc_points()`. It has to be: `smooth_corners()` caps a fillet's tangent at 45 % of the
## shorter adjacent edge, and the 120 deg hairpin needs a tangent of 1.7x its radius — a filleted version of
## this control polygon would collapse that corner to ~105 px. Because the corners are already exact arcs,
## `build()` runs the mandated `smooth_corners_varied()` stage with a radius of 0 (documented as "leaves
## that vertex sharp"), i.e. as an identity pass, and the remaining three stages unchanged and in order.

## Road width in px — must match TrackRegistry's `width` for "singapore".
const WIDTH := 102.0
## Reference corner radius in authoring units. `fit_to_view()` scales the whole shape by ~0.423, so this
## lands at ~159 px on screen; the tightest corner of the lap (the hairpin) measures 151 px.
const CORNER_RADIUS := 375.0
## Angular resolution of the generated arcs (~6 deg per segment).
const ARC_STEP := 0.105
## The view the centerline is fitted into: the full screen minus the dashboard strip (SPEC 18.6).
const FIT_SCREEN := Vector2(1280.0, 636.0)
const FIT_MARGIN := 26.0

## The lap as a turtle programme, in the direction of travel: `[turn_deg, radius, straight_after_px]`.
## A NEGATIVE turn is a left-hander (anticlockwise on screen, y down); positive is a right-hander.
## The turtle starts at the origin heading screen-right; the programme closes on itself to < 0.01 px.
## Lengths are authoring units (~0.423 px on screen).
const LAP := [
	# --- the two flat-out kinks past the Flyer, then the pit straight (start/finish lands here)
	[-18.0, 476.25, 98.0],     # T11  left kink
	[18.0, 476.25, 830.86],    # T12  right kink -> PIT STRAIGHT (longest of the lap, 336 px on screen)
	# --- the opening chicane: left, right, sharp left (Marina Bay T1-T2-T3)
	[-35.0, 386.25, 70.0],     # T1   left
	[25.0, 412.50, 84.0],      # T2   right, quick
	[-35.0, 375.0, 84.0],      # T3   left, the chicane's exit
	# --- the two-stage sweep up the east end of the circuit
	[-67.0, 375.0, 70.0],      # T4   long left
	[-68.0, 375.0, 230.0],     # T5   long left -> the short Republic Boulevard run
	# --- the slow sector: out, round the hairpin, back (Anderson Bridge / the old T13)
	[-60.0, 386.25, 112.0],    # T6   turn-in off the straight
	[120.0, 363.75, 112.0],    # T7   THE HAIRPIN — slowest corner of the lap (151 px radius)
	[-60.0, 386.25, 240.0],    # T8   back out -> RAFFLES AVENUE straight (160 px on screen)
	# --- two square street corners onto the run to the kinks
	[-90.0, 375.0, 388.43],    # T9   90 deg left
	[-90.0, 375.0, 168.0],     # T10  90 deg left
]


## Control points: the circuit's centerline as straights joined by explicit circular arcs, in the
## direction of travel, closed (the last point does not repeat the first). Authored in an arbitrary local
## space; `fit_to_view()` places and scales it.
static func control_points() -> PackedVector2Array:
	var pts := PackedVector2Array()
	var pos := Vector2.ZERO
	var heading := 0.0
	pts.append(pos)
	for entry in LAP:
		var turn := deg_to_rad(float(entry[0]))
		var radius := float(entry[1])
		var run := float(entry[2])
		# Centre of the corner: 90 deg to the left of the heading for a left-hander, right for a right.
		var center := pos + Vector2.from_angle(heading + signf(turn) * PI * 0.5) * radius
		var a0 := (pos - center).angle()
		var arc := TrackShape.arc_points(center, radius, a0, a0 + turn, ARC_STEP)
		for i in range(1, arc.size()):
			pts.append(arc[i])
		heading += turn
		pos = pts[pts.size() - 1]
		if run > 0.0:
			pos += Vector2.from_angle(heading) * run
			pts.append(pos)
	# The programme closes on itself; drop the wrap point so the loop is implicit (SPEC 15.1).
	pts.remove_at(pts.size() - 1)
	return pts


## The finished centerline. THIS IS THE ONLY FUNCTION TrackData CALLS.
static func build() -> PackedVector2Array:
	# Stage 1 (smooth): the corners are already exact arcs, so every vertex keeps its position.
	var pts := TrackShape.smooth_corners_varied(control_points(), PackedFloat32Array([0.0]))
	pts = TrackShape.ensure_direction(pts, false)   # Marina Bay runs anticlockwise
	# Stage 2 (fit), 3 (resample), 4 (rotate the start onto the pit straight).
	pts = TrackShape.fit_to_view(pts, WIDTH, FIT_MARGIN, FIT_SCREEN)
	pts = TrackShape.resample(pts, TrackData.SAMPLE_SPACING)
	return TrackShape.rotate_start(pts, TrackShape.best_start_index(pts))
