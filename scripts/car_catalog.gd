class_name CarCatalog
extends RefCounted
## The cars. Every car in the box DRIVES THE SAME -- one set of numbers, `STATS` -- so a race is decided
## by the driver and the lane, never by the car. What differs is how it looks: five of Rope Racers'
## low-poly 3D models (`CarModel3D` styles), each in its own colours.
##
##   top_speed    px/s at full throttle on a straight
##   accel        px/s^2 pulling away (it fades as the car nears its top speed)
##   brake        px/s^2 of motor braking with the trigger fully released
##   grip         px/s^2 of sideways load the guide and the magnet hold before the tail lets go
##   forgiveness  how long the tail can hang out past the limit before the car leaves the slot

const DEFAULT_ID := "sport"

const STATS := {
	"top_speed": 900.0, "accel": 1200.0, "brake": 1400.0, "grip": 1300.0, "forgiveness": 1.5,
}

const CARS := [
	{
		"id": "sport", "name": "Sport", "style": "sport",
		"description": "A little coupe with a racing stripe.",
		"body": Color(0.15, 0.42, 0.92), "stripe": Color(1, 1, 1, 0.85),
	},
	{
		"id": "f1", "name": "Formula", "style": "f1",
		"description": "Open wheels, wings front and back.",
		"body": Color(0.86, 0.12, 0.12), "stripe": Color(1, 1, 1, 0.9),
	},
	{
		"id": "gt", "name": "Grand Tourer", "style": "gt",
		"description": "Long bonnet, low roof, gold stripes.",
		"body": Color(0.12, 0.40, 0.26), "stripe": Color(0.95, 0.80, 0.25, 0.9),
	},
	{
		"id": "rally", "name": "Rally", "style": "rally",
		"description": "A boxy hatch on tall springs, in rally livery.",
		"body": Color(0.95, 0.95, 0.95), "stripe": Color(0.10, 0.45, 0.85, 0.95),
	},
	{
		"id": "kart", "name": "Kart", "style": "kart",
		"description": "A bare frame, four wheels and a driver.",
		"body": Color(0.35, 0.78, 0.22), "stripe": Color(0.10, 0.10, 0.10, 0.85),
	},
]

## The colours a car can be painted. Index 0 is "the car's own colour" (its `body`).
const PALETTE := [
	{"name": "Own", "color": Color(0, 0, 0, 0)},
	{"name": "Red", "color": Color(0.88, 0.14, 0.18)},
	{"name": "Yellow", "color": Color(0.95, 0.82, 0.16)},
	{"name": "Purple", "color": Color(0.62, 0.18, 0.86)},
	{"name": "Orange", "color": Color(0.98, 0.52, 0.12)},
	{"name": "Black", "color": Color(0.12, 0.12, 0.14)},
]
const PALETTE_SIZE := 6

static func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for c in CARS:
		out.append(String(c["id"]))
	return out


static func has(id: String) -> bool:
	return not _find(id).is_empty()


static func _find(id: String) -> Dictionary:
	for c in CARS:
		if c["id"] == id:
			return c
	return {}


## The car's entry -- its look, plus the shared `STATS` -- or the default car's for an unknown id.
static func get_car(id: String) -> Dictionary:
	var c := _find(id)
	if c.is_empty():
		c = _find(DEFAULT_ID)
	var out := c.duplicate()
	out.merge(STATS)
	return out


static func display_name(id: String) -> String:
	return String(get_car(id)["name"])


## The body colour for palette entry `index` (0 = the car's own).
static func body_color(id: String, index: int) -> Color:
	var i := posmod(index, PALETTE_SIZE)
	if i == 0:
		return get_car(id)["body"]
	return PALETTE[i]["color"]


static func color_name(id: String, index: int) -> String:
	var i := posmod(index, PALETTE_SIZE)
	if i == 0:
		return _own_colour_name(get_car(id)["body"])
	return String(PALETTE[i]["name"])


static func _own_colour_name(c: Color) -> String:
	if c.s < 0.2:
		return "White" if c.v > 0.6 else "Black"
	var h := c.h * 360.0
	if h < 20.0 or h >= 340.0:
		return "Red"
	if h < 70.0:
		return "Yellow"
	if h < 170.0:
		return "Green"
	if h < 260.0:
		return "Blue"
	return "Purple"


## The speed on a bend of radius `r` px that this car can hold flat: sqrt(grip * r).
static func corner_speed(id: String, r: float) -> float:
	return sqrt(float(get_car(id)["grip"]) * r)
