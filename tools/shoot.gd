extends SceneTree
## Screenshots of every screen and a few race moments, into build/shots/. Needs a window (no --headless):
##   godot --path . --script res://tools/shoot.gd

const DT := 1.0 / 60.0
const OUT := "build/shots"


func _init() -> void:
	await process_frame
	DirAccess.make_dir_recursive_absolute(OUT)
	var gs: Node = root.get_node("GameState")
	gs.records_path = "user://tool_records.cfg"
	gs.settings_path = "user://tool_settings.cfg"
	for s in ["main_menu", "car_select", "track_select", "help", "settings"]:
		var node: Node = load("res://scenes/%s.tscn" % s).instantiate()
		root.add_child(node)
		await _frames(40)
		_save(s)
		node.queue_free()
		await process_frame
	await _race_shot("circle", "race_circle", 7.0, false, 2)
	await _race_shot("circle", "race_closeup", 3.5, false, 3)
	await _race_shot("figure8", "race_figure8_bridge", 0.0, false, 2)
	await _race_shot("singapore", "race_singapore_overview", 9.0, false, 0)
	await _race_shot("serpent", "race_serpent_deslot", 0.0, true, 2)
	await _race_shot("circle", "race_countdown", -1.0, false, 2)
	await _race_shot("figure8", "race_figure8_grid", -1.0, false, 2)
	await _finish_shot()
	quit()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _save(name_: String) -> void:
	root.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [OUT, name_])
	print("wrote %s/%s.png" % [OUT, name_])


func _new_race(track: String) -> Node:
	var race: Node = load("res://scenes/race.tscn").instantiate()
	race.config = {"track": track, "car": "sport", "colour": 0, "lane": 1, "rivals": 3,
			"difficulty": "medium", "seed": 9, "no_records": true}
	race.controller_follows = false
	root.add_child(race)
	race.autopilot = SlotAI.new()
	race.autopilot.setup(race.player, "hard", 2)
	return race


## `secs` of racing (negative: stay in the countdown). `crash`: floor it until the player de-slots.
## `bridge` (secs == 0, no crash): run until the player is on the deck.
func _race_shot(track: String, name_: String, secs: float, crash: bool, zoom: int) -> void:
	var race := _new_race(track)
	race.set_physics_process(false)
	race._apply_zoom(zoom, true)
	if secs < 0.0:
		for i in 50:
			race.step(DT)
	else:
		while race.phase == "countdown":
			race.step(DT)
		var t := 0.0
		while t < 120.0:
			if crash:
				race.autopilot = null
				race.pointer_held = true
				race.pointer_demand = 1.0
			race.step(DT)
			race._process(DT)
			t += DT
			if crash and not race.player.is_slotted() and race.player.recovery() > 0.12:
				break
			if secs == 0.0 and not crash and race.track.is_index_on_deck(race.player.lane_index()) \
					and race.player.progress() > 0.5:
				break
			if secs > 0.0 and t >= secs:
				break
		race.pointer_held = false
	for i in 30:
		race._process(DT)
		await process_frame
	_save(name_)
	race.queue_free()
	await process_frame


func _finish_shot() -> void:
	var race := _new_race("circle")
	race.config["laps"] = 2
	race.laps = 2
	race.set_physics_process(false)
	var steps := 0
	while not (race.hud.finish_card != null) and steps < 60 * 120:
		race.step(DT)
		race._process(DT)
		steps += 1
	await _frames(30)
	_save("race_finish")
	race.queue_free()
	await process_frame
