class_name TrackData
extends RefCounted
## The circuits. The four layouts are Rope Racers' own -- the oval, the figure of eight with its bridge,
## Neon Harbour and the Serpent -- built by the same generators, then SCALED UP for slot racing: a slot
## car carries four lanes side by side and never brakes by steering, so it needs room.
##
## Pure data + static lookups; no scene tree, so the tests and tools can read it.
##
## A centreline here is a closed loop (the last point is not a copy of the first), evenly resampled,
## index 0 = the start/finish line, direction of travel = increasing index. It is already in WORLD
## coordinates: scaled, and moved so the world has `WORLD_PAD` of ground round the road.

## The rope game's generators resample at this spacing (they read it from here).
const SAMPLE_SPACING := 16.0
## After scaling, the centreline is resampled this fine: the lanes are offset from it point for point,
## and the slot physics reads curvature off them, so it wants a short, even step.
const SLOT_SPACING := 10.0
## Ground kept round the road, in px: room for a car that flies off a bend to tumble to a stop.
const WORLD_PAD := 300.0
const DEFAULT_ID := "circle"
## The speedo's scale, as in Rope Racers: 1 px/s = 0.2 km/h, i.e. 5.6 cm per px.
const KMH_PER_PX := 0.2
const METRES_PER_PX := KMH_PER_PX / 3.6

const CENTER := Vector2(640, 360)
const CIRCLE_RADII := Vector2(520, 265)
const FIGURE8_A := 530.0
const FIGURE8_B := 540.0
const DENSE_SAMPLES := 4000

## `scale` is how much bigger than the rope game's layout the slot circuit is. Lap counts are short: a
## slot race is a sprint, and a de-slot costs seconds.
const ENTRIES := [
	{
		"id": "circle",
		"name": "Circle",
		"location": "The oval",
		"accent": Color(0.247, 0.639, 0.302),
		"scale": 2.0,
		"laps": 8,
		"description": "Two straights and two long bends. Learn how late you can lift.",
		"has_bridge": false,
		"generator": "",
	},
	{
		"id": "figure8",
		"name": "Figure 8",
		"location": "The crossover",
		"accent": Color(0.247, 0.498, 0.639),
		"scale": 2.0,
		"laps": 6,
		"description": "Every lane crosses every other one on the bridge -- the fairest track there is.",
		"has_bridge": true,
		"generator": "",
		# The straightest stretch of a figure of eight is the crossing itself, so the automatic start
		# would put the grid under the bridge. A sixth of a lap round from the right-hand tip is the
		# long diagonal of the lobe, well clear of it.
		"start_at": 0.17,
	},
	{
		"id": "singapore",
		"name": "Neon Harbour",
		"location": "Night Streets",
		"accent": Color(0.878, 0.541, 0.118),
		"scale": 2.2,
		"laps": 5,
		"description": "Corner after corner. Short bursts of throttle, and a lot of lifting.",
		"has_bridge": false,
		"generator": "res://scripts/tracks/singapore.gd",
	},
	{
		"id": "serpent",
		"name": "Serpent",
		"location": "Six screens of bends",
		"accent": Color(0.55, 0.38, 0.82),
		"scale": 1.6,
		"laps": 3,
		"description": "Long and winding. Two flat-out straights, then the plunges.",
		"has_bridge": false,
		"generator": "res://scripts/tracks/serpent.gd",
	},
]

static var _built: Dictionary = {}


static func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for e in ENTRIES:
		out.append(String(e["id"]))
	return out


static func has(id: String) -> bool:
	return not get_entry(id).is_empty()


static func resolve(id: String) -> String:
	return id if has(id) else DEFAULT_ID


static func get_entry(id: String) -> Dictionary:
	for e in ENTRIES:
		if e["id"] == id:
			return e
	return {}


static func _field(id: String, key: String, fallback: Variant) -> Variant:
	var e := get_entry(id)
	return e[key] if e.has(key) else fallback


static func display_name(id: String) -> String:
	return String(_field(id, "name", id))


static func get_location(id: String) -> String:
	return String(_field(id, "location", ""))


static func get_accent(id: String) -> Color:
	return _field(id, "accent", Color(0.35, 0.72, 1.0)) as Color


static func get_laps(id: String) -> int:
	return int(_field(id, "laps", 5))


static func get_description(id: String) -> String:
	return String(_field(id, "description", ""))


static func has_bridge(id: String) -> bool:
	return bool(_field(id, "has_bridge", false))


## The world-space centreline (see the header). Built once per id.
static func get_centerline(id: String) -> PackedVector2Array:
	var rid := resolve(id)
	if not _built.has(rid):
		_built[rid] = _build(rid)
	return (_built[rid] as Dictionary)["points"]


## The size of the world the track lives in: the road's bounding box plus `WORLD_PAD` all round.
static func get_world_size(id: String) -> Vector2:
	get_centerline(id)
	return (_built[resolve(id)] as Dictionary)["world"]


static func clear_cache() -> void:
	_built.clear()


static func _build(id: String) -> Dictionary:
	var raw: PackedVector2Array
	match id:
		"circle":
			raw = circle()
		"figure8":
			raw = figure8()
		_:
			raw = _from_generator(String(_field(id, "generator", "")))
	if raw.size() < 16:
		raw = circle()
	var scale := float(_field(id, "scale", 1.0))
	var pts := PackedVector2Array()
	pts.resize(raw.size())
	for i in raw.size():
		pts[i] = raw[i] * scale
	pts = resample_closed(pts, SLOT_SPACING)
	# The start line goes on the straightest stretch of the lap (a grid on a bend is a grid that cannot
	# all go at once) -- unless the track says where, as a share of the lap from where it was drawn.
	var start_at := float(_field(id, "start_at", -1.0))
	var first := TrackShape.best_start_index(pts)
	if start_at >= 0.0:
		first = posmod(int(round(start_at * pts.size())), pts.size())
	pts = TrackShape.rotate_start(pts, first)
	var box := TrackShape.bounds_of(pts)
	var shift := Vector2(WORLD_PAD, WORLD_PAD) - box.position
	for i in pts.size():
		pts[i] += shift
	return {"points": pts, "world": box.size + Vector2(WORLD_PAD, WORLD_PAD) * 2.0}


static func _from_generator(path: String) -> PackedVector2Array:
	if path.is_empty() or not ResourceLoader.exists(path):
		return PackedVector2Array()
	var script := load(path) as Script
	if script == null or not script.has_method("build"):
		return PackedVector2Array()
	return script.call("build")


## Ellipse, starting bottom middle, clockwise on screen.
static func circle() -> PackedVector2Array:
	var dense := PackedVector2Array()
	dense.resize(DENSE_SAMPLES)
	for k in DENSE_SAMPLES:
		var th := PI * 0.5 + TAU * float(k) / float(DENSE_SAMPLES)
		dense[k] = CENTER + Vector2(CIRCLE_RADII.x * cos(th), CIRCLE_RADII.y * sin(th))
	return resample_closed(dense, SAMPLE_SPACING)


## Lemniscate of Gerono: crosses itself once, in the middle.
static func figure8() -> PackedVector2Array:
	var dense := PackedVector2Array()
	dense.resize(DENSE_SAMPLES)
	for k in DENSE_SAMPLES:
		var t := PI * 0.5 + TAU * float(k) / float(DENSE_SAMPLES)
		dense[k] = CENTER + Vector2(FIGURE8_A * sin(t), FIGURE8_B * sin(t) * cos(t))
	return resample_closed(dense, SAMPLE_SPACING)


## Resamples a closed polyline to evenly spaced points (the first output point is the first input one).
static func resample_closed(points: PackedVector2Array, spacing: float) -> PackedVector2Array:
	var n_in := points.size()
	if n_in < 2 or spacing <= 0.0:
		return points.duplicate()
	var total := 0.0
	for i in n_in:
		total += points[i].distance_to(points[(i + 1) % n_in])
	if total <= 0.0:
		return points.duplicate()
	var count: int = maxi(3, roundi(total / spacing))
	var step := total / float(count)
	var out := PackedVector2Array()
	out.resize(count)
	var seg := 0
	var seg_start := 0.0
	var seg_len := points[0].distance_to(points[1 % n_in])
	for k in count:
		var s := step * float(k)
		while s > seg_start + seg_len and seg < n_in - 1:
			seg_start += seg_len
			seg += 1
			seg_len = points[seg].distance_to(points[(seg + 1) % n_in])
		var u := 0.0
		if seg_len > 0.0:
			u = clampf((s - seg_start) / seg_len, 0.0, 1.0)
		out[k] = points[seg].lerp(points[(seg + 1) % n_in], u)
	return out
