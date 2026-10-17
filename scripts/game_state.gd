extends Node
## Global game state (autoload "GameState"): what the player picked, the settings, the records, and
## the way between screens. Only the screens use it; the track, the cars and the AI never do, so they
## run in `--script` tests without it.

const MENU_SCENE := "res://scenes/main_menu.tscn"
const CAR_SELECT_SCENE := "res://scenes/car_select.tscn"
const TRACK_SELECT_SCENE := "res://scenes/track_select.tscn"
const RACE_SCENE := "res://scenes/race.tscn"
const HELP_SCENE := "res://scenes/help.tscn"
const SETTINGS_SCENE := "res://scenes/settings.tscn"

const MAX_RIVALS := SlotTrack.LANE_COUNT - 1
const DIFFICULTIES := ["easy", "medium", "hard"]
const DEFAULT_SETTINGS := {
	"music_volume": 0.6,
	"sfx_volume": 0.9,
	"fullscreen": false,
	"rivals": 3,
	"difficulty": "medium",
	"car": CarCatalog.DEFAULT_ID,
	"colour": 0,
	"track": TrackData.DEFAULT_ID,
	"lane": 1,
}

## The one input. Every key here, a mouse button anywhere on the track, or a finger on the screen.
const THROTTLE_ACTION := "throttle"
const THROTTLE_KEYS := [KEY_SPACE, KEY_UP, KEY_W, KEY_SHIFT]

var settings_path := "user://settings.cfg"
var records_path := "user://records.cfg"
var settings: Dictionary = {}
## track -> {"lap": float, "race": {laps: float}}
var records: Dictionary = {}

var selected_car: String = CarCatalog.DEFAULT_ID
var selected_colour: int = 0
var selected_track: String = TrackData.DEFAULT_ID
var selected_lane: int = 1
var rivals: int = 3
var difficulty: String = "medium"


func _ready() -> void:
	_ensure_input()
	load_settings()
	load_records()
	_apply_window()


static func _ensure_input() -> void:
	if not InputMap.has_action(THROTTLE_ACTION):
		InputMap.add_action(THROTTLE_ACTION)
		for k in THROTTLE_KEYS:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(THROTTLE_ACTION, ev)
		var pad := InputEventJoypadButton.new()
		pad.button_index = JOY_BUTTON_A
		InputMap.action_add_event(THROTTLE_ACTION, pad)
		var trig := InputEventJoypadMotion.new()
		trig.axis = JOY_AXIS_TRIGGER_RIGHT
		trig.axis_value = 1.0
		InputMap.action_add_event(THROTTLE_ACTION, trig)


# ------------------------------------------------------------------ settings

func load_settings() -> void:
	settings = DEFAULT_SETTINGS.duplicate()
	var cfg := ConfigFile.new()
	if cfg.load(settings_path) == OK:
		for key in DEFAULT_SETTINGS.keys():
			settings[key] = cfg.get_value("settings", key, DEFAULT_SETTINGS[key])
	selected_car = String(settings["car"]) if CarCatalog.has(String(settings["car"])) else CarCatalog.DEFAULT_ID
	selected_colour = posmod(int(settings["colour"]), CarCatalog.PALETTE_SIZE)
	selected_track = TrackData.resolve(String(settings["track"]))
	selected_lane = clampi(int(settings["lane"]), 0, SlotTrack.LANE_COUNT - 1)
	rivals = clampi(int(settings["rivals"]), 0, MAX_RIVALS)
	difficulty = String(settings["difficulty"]) if DIFFICULTIES.has(String(settings["difficulty"])) else "medium"


func save_settings() -> void:
	settings["car"] = selected_car
	settings["colour"] = selected_colour
	settings["track"] = selected_track
	settings["lane"] = selected_lane
	settings["rivals"] = rivals
	settings["difficulty"] = difficulty
	var cfg := ConfigFile.new()
	for key in settings.keys():
		cfg.set_value("settings", key, settings[key])
	cfg.save(settings_path)


## Read by Audio at start-up.
func get_setting(key: String) -> Variant:
	return settings.get(key, DEFAULT_SETTINGS.get(key))


func set_setting(key: String, value: Variant) -> void:
	settings[key] = value
	if key == "music_volume" or key == "sfx_volume":
		Audio.set_volumes(float(settings["music_volume"]), float(settings["sfx_volume"]))
	if key == "fullscreen":
		_apply_window()
	save_settings()


func _apply_window() -> void:
	if DisplayServer.get_name() == "headless" or OS.has_feature("web"):
		return
	var full := bool(settings.get("fullscreen", false))
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if full
			else DisplayServer.WINDOW_MODE_WINDOWED)


# ------------------------------------------------------------------ records

func load_records() -> void:
	records = {}
	var cfg := ConfigFile.new()
	if cfg.load(records_path) != OK:
		return
	for key in cfg.get_section_keys("records") if cfg.has_section("records") else PackedStringArray():
		var v: Variant = cfg.get_value("records", key, {})
		if v is Dictionary:
			records[key] = v


func save_records() -> void:
	var cfg := ConfigFile.new()
	for key in records.keys():
		cfg.set_value("records", key, records[key])
	cfg.save(records_path)


## Records are per TRACK: every car drives the same, so the car is only what the record was set in.
## Best lap on `track`, or INF.
func best_lap(track: String) -> float:
	var r: Dictionary = records.get(track, {})
	var v := float(r.get("lap", INF))
	return v if v > 0.0 and is_finite(v) else INF


## Best whole race of `laps` laps on `track`, or INF.
func best_race(track: String, laps: int) -> float:
	var r: Dictionary = records.get(track, {})
	var races: Dictionary = r.get("race", {})
	var v := float(races.get(str(laps), INF))
	return v if v > 0.0 and is_finite(v) else INF


## Records a finished race; returns {"lap": bool, "race": bool} -- which records it broke.
func submit_race(track: String, lap_times: Array, total: float) -> Dictionary:
	var r: Dictionary = records.get(track, {})
	var out := {"lap": false, "race": false}
	var best := INF
	for t in lap_times:
		if float(t) > 0.0:
			best = minf(best, float(t))
	if is_finite(best) and best < best_lap(track):
		r["lap"] = best
		out["lap"] = true
	var laps := lap_times.size()
	if total > 0.0 and total < best_race(track, laps):
		var races: Dictionary = r.get("race", {})
		races[str(laps)] = total
		r["race"] = races
		out["race"] = true
	records[track] = r
	save_records()
	return out


# ------------------------------------------------------------------ screens

func go_to_menu() -> void:
	_change(MENU_SCENE)


func go_to_car_select() -> void:
	_change(CAR_SELECT_SCENE)


func go_to_track_select() -> void:
	_change(TRACK_SELECT_SCENE)


func go_to_help() -> void:
	_change(HELP_SCENE)


func go_to_settings() -> void:
	_change(SETTINGS_SCENE)


func start_race() -> void:
	save_settings()
	_change(RACE_SCENE)


func quit_game() -> void:
	get_tree().quit()


func _change(path: String) -> void:
	get_tree().paused = false
	Audio.set_engine_active(false)
	get_tree().change_scene_to_file(path)


## "1:02.345" / "0:59.120", or "-:--.---" for no time.
static func format_time(t: float) -> String:
	if not is_finite(t) or t <= 0.0:
		return "-:--.---"
	var minutes := int(t / 60.0)
	var secs := t - float(minutes) * 60.0
	return "%d:%06.3f" % [minutes, secs]


static func ordinal(n: int) -> String:
	match n:
		1:
			return "1st"
		2:
			return "2nd"
		3:
			return "3rd"
	return "%dth" % n
