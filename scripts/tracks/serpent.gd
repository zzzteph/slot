extends RefCounted
## SERPENT (SPEC 110): a long, winding circuit in a world six times the screen, for the camera that
## rides with the car -- "you never see more than the next bend". A wavy loop: a start straight with a
## chicane along the bottom, esses climbing the east side, a top edge that PLUNGES into the middle
## twice, and esses coming down the west side. Eighteen corners, no two the same way round twice in a
## row.
##
## SPEC 121: THE TOP EDGE GOES ALL THE WAY DOWN NOW. It used to dip three times by 300 px, which kept
## the whole circuit within a ring round the outside of its world and left a 2320 x 470 px band across
## the middle that no part of the road ever entered -- 19 % of the world, the largest empty patch of any
## circuit in the game (`tools/track_table.gd`), and exactly the "bit of non-occupied space in the
## middle" it looked like. The three shallow dips are two deep plunges instead: 760 px down to the
## middle of the world and back up, twice, so the map is used from edge to edge. They are the two
## slowest corners on the circuit and they arrive after the fastest part of the lap, which the top edge
## badly needed.

const WIDTH := 112.0                  ## must equal TrackRegistry's `width` for "serpent"
const VIEW := Vector2(3200.0, 1800.0) ## the world, not the screen (SPEC 52)
const FIT_MARGIN := 90.0
## The validator's own numbers for this world (the tests pass the same): a 1280x720 track may not be
## longer than 4200 px; six screens of bends, with SPEC 121's two plunges, are 9800.
const MAX_LENGTH := 10400.0


static func corner_radii() -> PackedFloat32Array:
	return PackedFloat32Array([
		140.0,                       # T1  -- south-west corner, onto the start straight
		170.0, 170.0,                # T2-T3 -- the chicane on the start straight
		150.0,                       # T4' -- south-east corner (T4, the chicane's exit, shares it)
		160.0, 160.0, 160.0,         # T5-T7 -- esses up the east side
		170.0,                       # T8  -- north-east corner
		190.0,                       # T9  -- off the top edge into the first plunge
		170.0,                       # T10 -- the bottom of it, in the middle of the world
		170.0,                       # T11 -- back at the top, straight into the second
		170.0,                       # T12 -- the bottom of the second plunge
		190.0,                       # T13 -- back onto the top edge
		135.0,                       # T14 -- north-west corner
		150.0, 150.0, 150.0,         # T15-T17 -- esses down the west side
	])


static func control_points() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(320, 1560),          # T1  -- south-west; the start straight runs east from here
		Vector2(1150, 1560),         # T2  -- chicane in
		Vector2(1450, 1300),         # T3  -- chicane out
		Vector2(1750, 1560),         # T4  -- back on the bottom edge, then the long straight east
		Vector2(2960, 1560),         # T4' -- south-east corner, turning north
		Vector2(2960, 1230),         # T5  -- esses up the east side
		Vector2(2640, 920),          # T6
		Vector2(2960, 600),          # T7
		Vector2(2900, 240),          # T8  -- north-east corner
		Vector2(2400, 240),          # T9  -- the top edge plunges (SPEC 121)...
		Vector2(2050, 1000),         # T10 -- ... all the way to the middle of the world
		Vector2(1700, 240),          # T11 -- ... back to the top, and again
		Vector2(1350, 1000),         # T12
		Vector2(1000, 240),          # T13 -- back on the top edge
		Vector2(320, 240),           # T14 -- north-west corner
		Vector2(420, 600),           # T15 -- esses down the west side
		Vector2(260, 900),           # T16
		Vector2(400, 1200),          # T17
	])


static func build() -> PackedVector2Array:
	var pts := control_points()
	var radii := corner_radii()
	# One radius per control point: T4 (the chicane's exit onto the bottom edge) shares the south-east
	# corner's, so the list above names sixteen corners for seventeen points.
	var per_point := PackedFloat32Array()
	per_point.resize(pts.size())
	var k := 0
	for i in pts.size():
		per_point[i] = radii[mini(k, radii.size() - 1)]
		if i != 3:
			k += 1
	var out := TrackShape.smooth_corners_varied(pts, per_point)
	out = TrackShape.fit_to_view(out, WIDTH, FIT_MARGIN, VIEW)
	out = TrackShape.resample(out, TrackData.SAMPLE_SPACING)
	return TrackShape.rotate_start(out, TrackShape.best_start_index(out))
