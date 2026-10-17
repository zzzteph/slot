class_name SlotLane
extends RefCounted
## One slot: the closed path a car's guide blade runs in. Built by offsetting the track centreline
## sideways point for point, so point `i` of every lane sits on the same cross-section of the track
## (that is what lets the bridge, the start line and the race order speak in centreline indices).
##
## Everything the physics asks is here: where the slot is at arc length `s`, which way it points, and
## how hard it is bending there (curvature, 1/px, positive = turning clockwise on screen).

## Curvature is averaged over this many points either side: the generators' fillets are polylines, and
## a slot car does not feel a 10 px facet -- it feels the bend.
const SMOOTH := 4

var index: int = 0
var offset: float = 0.0
var points := PackedVector2Array()
var arc := PackedFloat32Array()       # arc length at each point; arc[0] = 0
var headings := PackedFloat32Array()  # direction of the segment leaving each point
var curvature := PackedFloat32Array() # smoothed signed curvature at each point
var length: float = 0.0


static func build(centerline: PackedVector2Array, normals: PackedVector2Array, lane_offset: float,
		lane_index: int) -> SlotLane:
	var lane := SlotLane.new()
	lane.index = lane_index
	lane.offset = lane_offset
	var n := centerline.size()
	lane.points.resize(n)
	for i in n:
		lane.points[i] = centerline[i] + normals[i] * lane_offset
	lane._measure()
	return lane


func _measure() -> void:
	var n := points.size()
	arc.resize(n)
	headings.resize(n)
	var s := 0.0
	for i in n:
		arc[i] = s
		var d := points[(i + 1) % n] - points[i]
		headings[i] = d.angle()
		s += d.length()
	length = s
	var raw := PackedFloat32Array()
	raw.resize(n)
	for i in n:
		var turn := wrapf(headings[i] - headings[posmod(i - 1, n)], -PI, PI)
		var ds := (points[(i + 1) % n].distance_to(points[posmod(i - 1, n)])) * 0.5
		raw[i] = turn / maxf(ds, 0.001)
	curvature.resize(n)
	for i in n:
		var acc := 0.0
		for k in range(-SMOOTH, SMOOTH + 1):
			acc += raw[posmod(i + k, n)]
		curvature[i] = acc / float(SMOOTH * 2 + 1)


func point_count() -> int:
	return points.size()


## The point index whose segment contains arc length `s` (wrapped onto the lap).
func index_at(s: float) -> int:
	var w := fposmod(s, length)
	var i := arc.bsearch(w, false) - 1
	return clampi(i, 0, points.size() - 1)


func position_at(s: float) -> Vector2:
	var w := fposmod(s, length)
	var i := index_at(w)
	var j := (i + 1) % points.size()
	var seg := (arc[j] if j != 0 else length) - arc[i]
	var u := clampf((w - arc[i]) / seg, 0.0, 1.0) if seg > 0.0 else 0.0
	return points[i].lerp(points[j], u)


## The slot's direction at `s`, blended between neighbouring segments so a car turns smoothly instead
## of snapping 4 degrees at every point.
func heading_at(s: float) -> float:
	var w := fposmod(s, length)
	var i := index_at(w)
	var j := (i + 1) % points.size()
	var seg := (arc[j] if j != 0 else length) - arc[i]
	var u := clampf((w - arc[i]) / seg, 0.0, 1.0) if seg > 0.0 else 0.0
	var h0 := headings[posmod(i - 1, points.size())]
	var h1 := headings[i]
	# The heading of point i's segment is reached at its middle; before that, blend from the last one.
	if u < 0.5:
		return lerp_angle(h0, h1, u + 0.5)
	return lerp_angle(h1, headings[j], u - 0.5)


func curvature_at(s: float) -> float:
	var w := fposmod(s, length)
	var i := index_at(w)
	var j := (i + 1) % points.size()
	var seg := (arc[j] if j != 0 else length) - arc[i]
	var u := clampf((w - arc[i]) / seg, 0.0, 1.0) if seg > 0.0 else 0.0
	return lerpf(curvature[i], curvature[j], u)


## The tightest radius anywhere on this lane, in px.
func min_radius() -> float:
	var k := 0.0
	for c in curvature:
		k = maxf(k, absf(c))
	return 1.0 / k if k > 0.0 else INF
