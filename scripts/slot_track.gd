class_name SlotTrack
extends Node2D
## A slot-car circuit: four lanes, each a slot with a copper braid either side, on a plastic road. The
## whole thing never changes during a race, so it is baked into ONE mesh and drawn with one call (and
## the figure of eight's bridge deck into a second one) -- no grass physics, no sand, no props: the
## only surface in this game is the slot.

const LANE_COUNT := 4
const LANE_GAP := 40.0
## Road half-width: the outside lanes sit at +-60, so this leaves 24 px of plastic past them.
const ROAD_HALF := 84.0
const BORDER := 10.0

## z layers: the ground, cars under the bridge, the deck, cars on the deck, cars in the air.
const Z_CAR_LOW := 5
const Z_DECK := 10
const Z_CAR_HIGH := 15
const Z_CAR_AIR := 20

const GROUND_A := Color(0.22, 0.46, 0.20)
const GROUND_B := Color(0.235, 0.485, 0.21)
const GROUND_BAND := 160.0
const SHADOW := Color(0, 0, 0, 0.22)
const ROAD := Color(0.19, 0.19, 0.21)
const ROAD_DECK := Color(0.23, 0.23, 0.25)
const EDGE := Color(0.92, 0.92, 0.92)
const KERB_RED := Color(0.85, 0.18, 0.14)
const JOINT := Color(0.12, 0.12, 0.13)
const RAIL := Color(0.74, 0.64, 0.52)
const SLOT := Color(0.03, 0.03, 0.035)
const DECK_WALL := Color(0.55, 0.55, 0.58)
## The lane colours, left to right in the direction of travel -- as on a real slot set.
const LANE_COLORS := [
	Color(0.92, 0.22, 0.20), Color(0.25, 0.52, 0.96), Color(0.96, 0.82, 0.20), Color(0.30, 0.80, 0.36),
]
const LANE_NAMES := ["Red", "Blue", "Yellow", "Green"]

## A curve this tight (1/px) or tighter gets red-and-white kerbs on its outside.
const KERB_CURVATURE := 1.0 / 900.0
## One "piece" of the plastic set every this many points -- the joints are what make it read as a slot
## track and not a road.
const PIECE_POINTS := 24
const RAIL_OFFSET := 4.0
const RAIL_WIDTH := 1.3
const SLOT_WIDTH := 2.0

var track_id: String = ""
var centerline := PackedVector2Array()
var normals := PackedVector2Array()
var lanes: Array[SlotLane] = []
var world_size := Vector2(1280, 720)

var has_bridge: bool = false
var bridge_center := Vector2.ZERO
var _deck_from: int = -1        # centreline index range carried by the deck (inclusive, may wrap)
var _deck_to: int = -1
var _ground: ArrayMesh = null
var _deck: Node2D = null


func setup(id: String) -> void:
	track_id = TrackData.resolve(id)
	centerline = TrackData.get_centerline(track_id)
	world_size = TrackData.get_world_size(track_id)
	normals = compute_normals(centerline)
	lanes.clear()
	for i in LANE_COUNT:
		lanes.append(SlotLane.build(centerline, normals, lane_offset(i), i))
	_setup_bridge()
	_bake()
	queue_redraw()


static func lane_offset(i: int) -> float:
	return (float(i) - float(LANE_COUNT - 1) * 0.5) * LANE_GAP


static func lane_color(i: int) -> Color:
	return LANE_COLORS[posmod(i, LANE_COLORS.size())]


static func lane_name(i: int) -> String:
	return LANE_NAMES[posmod(i, LANE_NAMES.size())]


## Unit normals, rotated +90 degrees from the direction of travel (on screen: to the car's RIGHT).
static func compute_normals(points: PackedVector2Array) -> PackedVector2Array:
	var n := points.size()
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		var dir := (points[(i + 1) % n] - points[posmod(i - 1, n)]).normalized()
		out[i] = Vector2(-dir.y, dir.x)
	return out


func get_lane(i: int) -> SlotLane:
	return lanes[clampi(i, 0, lanes.size() - 1)]


## The box the road occupies, plus a little air: what a preview or the overview camera frames.
func road_bounds() -> Rect2:
	return TrackShape.bounds_of(centerline).grow(ROAD_HALF + BORDER + 40.0)


func is_index_on_deck(i: int) -> bool:
	if not has_bridge:
		return false
	if _deck_from <= _deck_to:
		return i >= _deck_from and i <= _deck_to
	return i >= _deck_from or i <= _deck_to


# ------------------------------------------------------------------ bridge

func _setup_bridge() -> void:
	has_bridge = false
	_deck_from = -1
	_deck_to = -1
	if not TrackData.has_bridge(track_id):
		return
	var n := centerline.size()
	for i in n:
		var a1 := centerline[i]
		var a2 := centerline[(i + 1) % n]
		for j in range(i + 2, n):
			if i == 0 and j == n - 1:
				continue
			var hit: Variant = Geometry2D.segment_intersects_segment(a1, a2, centerline[j],
					centerline[(j + 1) % n])
			if hit == null:
				continue
			# The branch driven second is the one that goes over.
			has_bridge = true
			bridge_center = hit
			var half := int(ceil(ROAD_HALF * 2.6 / TrackData.SLOT_SPACING))
			_deck_from = posmod(j - half, n)
			_deck_to = posmod(j + half, n)
			return


func _deck_indices() -> PackedInt32Array:
	var out := PackedInt32Array()
	if not has_bridge:
		return out
	var n := centerline.size()
	var i := _deck_from
	while true:
		out.append(i)
		if i == _deck_to:
			break
		i = (i + 1) % n
	return out


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	if _ground != null:
		draw_mesh(_ground, null)


func get_ground_mesh() -> ArrayMesh:
	return _ground


func get_deck_mesh() -> ArrayMesh:
	return (_deck as DeckLayer).mesh if _deck != null else null


func _bake() -> void:
	var m := MeshPaint.new()
	var x := 0.0
	var band := 0
	while x < world_size.x:
		m.add_rect(Rect2(x, 0.0, minf(GROUND_BAND, world_size.x - x), world_size.y),
				GROUND_A if band % 2 == 0 else GROUND_B)
		x += GROUND_BAND
		band += 1
	_paint_road(m, centerline, normals, true, ROAD, Vector2(8, 10))
	_paint_start(m)
	_ground = m.build()
	if _deck != null:
		_deck.queue_free()
		_deck = null
	if has_bridge:
		_deck = _make_deck()
		add_child(_deck)


## The road along `pts` -- shadow, kerbs and edging, plastic, piece joints, braids and slots -- as one
## run of strips. Used for the whole circuit and again for the deck (an open run).
func _paint_road(m: MeshPaint, pts: PackedVector2Array, nrm: PackedVector2Array, closed: bool,
		road: Color, shadow_off: Vector2) -> void:
	var n := pts.size()
	m.add_strip(pts, nrm, closed, ROAD_HALF + BORDER, SHADOW, shadow_off)
	m.add_strip(pts, nrm, closed, ROAD_HALF + BORDER, EDGE)
	if closed:
		_paint_kerbs(m, pts, nrm)
	m.add_strip(pts, nrm, closed, ROAD_HALF, road)
	for i in range(0, n, PIECE_POINTS):
		if not closed and (i == 0 or i >= n - 1):
			continue
		m.add_line(pts[i] + nrm[i] * ROAD_HALF, pts[i] - nrm[i] * ROAD_HALF, 2.0, JOINT)
	for lane in LANE_COUNT:
		var off := lane_offset(lane)
		_strip_at(m, pts, nrm, closed, off - RAIL_OFFSET, RAIL_WIDTH, RAIL)
		_strip_at(m, pts, nrm, closed, off + RAIL_OFFSET, RAIL_WIDTH, RAIL)
		_strip_at(m, pts, nrm, closed, off, SLOT_WIDTH, SLOT)


## A band `width` wide, `off` px along the normal from the polyline.
func _strip_at(m: MeshPaint, pts: PackedVector2Array, nrm: PackedVector2Array, closed: bool, off: float,
		width: float, color: Color) -> void:
	var n := pts.size()
	var segs := n if closed else n - 1
	var h := width * 0.5
	for i in segs:
		var j := (i + 1) % n
		m.add_quad(pts[i] + nrm[i] * (off + h), pts[j] + nrm[j] * (off + h),
				pts[j] + nrm[j] * (off - h), pts[i] + nrm[i] * (off - h), color)


## Red over the white edging on the OUTSIDE of every real bend, in blocks, like painted kerbs.
func _paint_kerbs(m: MeshPaint, pts: PackedVector2Array, nrm: PackedVector2Array) -> void:
	var n := pts.size()
	var curv := SlotLane.build(pts, nrm, 0.0, -1).curvature
	for i in n:
		if absf(curv[i]) < KERB_CURVATURE or (i / 3) % 2 == 1:
			continue
		# Positive curvature turns clockwise (to the right), so the outside is to the left (-normal).
		var side := -1.0 if curv[i] > 0.0 else 1.0
		var j := (i + 1) % n
		var a := ROAD_HALF
		var b := ROAD_HALF + BORDER
		m.add_quad(pts[i] + nrm[i] * a * side, pts[j] + nrm[j] * a * side,
				pts[j] + nrm[j] * b * side, pts[i] + nrm[i] * b * side, KERB_RED)


## The start/finish line (a chequered band across the road) and a grid box for each lane behind it.
func _paint_start(m: MeshPaint) -> void:
	var n := centerline.size()
	var p := centerline[0]
	var ang := (centerline[1] - centerline[n - 1]).angle()
	var cols := 14
	var cell := ROAD_HALF * 2.0 / float(cols)
	for r in 2:
		for c in cols:
			var col := Color.WHITE if (r + c) % 2 == 0 else Color(0.06, 0.06, 0.06)
			var x0 := -cell + cell * r
			var y0 := -ROAD_HALF + cell * c
			m.add_quad(p + Vector2(x0, y0).rotated(ang), p + Vector2(x0 + cell, y0).rotated(ang),
					p + Vector2(x0 + cell, y0 + cell).rotated(ang), p + Vector2(x0, y0 + cell).rotated(ang), col)
	for lane in LANE_COUNT:
		var off := lane_offset(lane)
		var centre := p + Vector2(-34.0, off).rotated(ang)
		m.add_rotated_rect_outline(centre, Vector2(50, 30), ang, Color(1, 1, 1, 0.55), 2.0)
		m.add_rotated_rect(p + Vector2(-64.0, off).rotated(ang), Vector2(8, 26), ang, lane_color(lane))


func _make_deck() -> Node2D:
	var idx := _deck_indices()
	var pts := PackedVector2Array()
	var nrm := PackedVector2Array()
	for i in idx:
		pts.append(centerline[i])
		nrm.append(normals[i])
	var m := MeshPaint.new()
	m.add_strip(pts, nrm, false, ROAD_HALF + BORDER + 8.0, Color(0, 0, 0, 0.35), Vector2(14, 18))
	m.add_strip(pts, nrm, false, ROAD_HALF + BORDER + 8.0, DECK_WALL)
	_paint_road(m, pts, nrm, false, ROAD_DECK, Vector2.ZERO)
	# End beams, so the edges of the bridge read.
	for k in [0, pts.size() - 1]:
		var w := ROAD_HALF + BORDER + 8.0
		m.add_line(pts[k] + nrm[k] * w, pts[k] - nrm[k] * w, 4.0, Color(0.2, 0.2, 0.22))
	var deck := DeckLayer.new()
	deck.name = "BridgeDeck"
	deck.mesh = m.build()
	deck.z_index = Z_DECK
	deck.z_as_relative = false
	return deck


## The bridge's mesh, drawn on its own z layer between the cars under it and the cars on it.
class DeckLayer extends Node2D:
	var mesh: ArrayMesh = null

	func _draw() -> void:
		if mesh != null:
			draw_mesh(mesh, null)
