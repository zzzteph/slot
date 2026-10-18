extends SceneTree
## Shoots the How to play screen's pictures from the real game, into res://art/help/:
##   trigger.png  the hand controller, half squeezed, its cable alight
##   tail.png     your car in a bend with its tail swung out -- the warning
##   off.png      a car that has just left the slot
##   lanes.png    four cars on the grid, one in each lane
## Needs a window (not --headless):  godot --path . --script res://tools/make_help_art.gd

const DT := 1.0 / 60.0
const CROP := Vector2i(640, 440)
const OUT := "res://art/help/"


func _init() -> void:
	await process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var gs: Node = root.get_node("GameState")
	gs.records_path = "user://tool_records.cfg"
	gs.settings_path = "user://tool_settings.cfg"
	await _trigger()
	await _tail()
	await _off()
	await _lanes()
	print("help art: wrote trigger.png, tail.png, off.png, lanes.png")
	quit()


func _frames(n: int) -> void:
	for i in n:
		await process_frame
	await RenderingServer.frame_post_draw


## The viewport image cut to CROP around `center` (in viewport pixels), kept inside the picture.
func _save_around(center: Vector2, file: String) -> void:
	var img := root.get_viewport().get_texture().get_image()
	var size := img.get_size()
	var k := float(size.x) / 1280.0          # the window may be bigger than the game's 1280x720
	var crop := Vector2i(Vector2(CROP) * k)
	var at := Vector2i((center * k) - Vector2(crop) * 0.5)
	at.x = clampi(at.x, 0, size.x - crop.x)
	at.y = clampi(at.y, 0, size.y - crop.y)
	var cut := img.get_region(Rect2i(at, crop))
	cut.resize(CROP.x, CROP.y, Image.INTERPOLATE_LANCZOS)
	cut.save_png(ProjectSettings.globalize_path(OUT + file))
	print("wrote ", OUT + file)


func _trigger() -> void:
	var hud_script: Script = load("res://scripts/slot_hud.gd")
	var bg := ColorRect.new()
	bg.color = Color(0.23, 0.48, 0.2)
	bg.size = Vector2(1280, 720)
	root.add_child(bg)
	var cable: Control = hud_script.HandCable.new()
	cable.size = Vector2(1280, 720)
	root.add_child(cable)
	var ctl: Control = hud_script.HandController.new()
	ctl.position = Vector2(470, 210)
	ctl.size = Vector2(156, 196) * float(hud_script.HandController.SCALE)
	ctl.squeeze = 0.6
	ctl.power = 0.7
	ctl.hover = true
	root.add_child(ctl)
	for i in 90:
		ctl.advance(DT)
		cable.power = 0.7
		cable.simulate(DT, ctl.cable_exit())
		await process_frame
	await _frames(2)
	_save_around(Vector2(640, 440), "trigger.png")
	for n in [bg, cable, ctl]:
		n.queue_free()
	await process_frame


func _race(track: String, lane: int) -> Node:
	var race: Node = load("res://scenes/race.tscn").instantiate()
	race.config = {"track": track, "car": "sport", "colour": 0, "lane": lane, "rivals": 3,
			"difficulty": "medium", "seed": 4, "no_records": true, "no_hud": true}
	root.add_child(race)
	race.set_physics_process(false)
	race._apply_zoom(3, true)
	return race


func _player_on_screen(race: Node) -> Vector2:
	return (race.player as Node2D).get_global_transform_with_canvas().origin


## Your car hanging its tail out in a bend, just short of letting go.
func _tail() -> void:
	var race := _race("circle", 1)
	while race.phase == "countdown":
		race.step(DT)
	var t := 0.0
	while t < 60.0:
		var p: SlotCar = race.player
		race.pointer_held = true
		race.pointer_demand = 1.0
		race.step(DT)
		race._process(DT)
		t += DT
		if p.is_slotted() and p.danger() > 0.72 and p.stress <= 0.0:
			break
	race.pointer_held = false
	for i in 4:
		race._process(DT)
	await _frames(8)
	_save_around(_player_on_screen(race), "tail.png")
	race.queue_free()
	await process_frame


## A car that has just left the slot: spinning, smoke and sparks.
func _off() -> void:
	var race := _race("serpent", 2)
	while race.phase == "countdown":
		race.step(DT)
	var t := 0.0
	while t < 60.0:
		race.pointer_held = true
		race.pointer_demand = 1.0
		race.step(DT)
		race._process(DT)
		t += DT
		if not race.player.is_slotted() and race.player.recovery() > 0.08:
			break
	race.pointer_held = false
	for i in 4:
		race._process(DT)
	await _frames(8)
	_save_around(_player_on_screen(race), "off.png")
	race.queue_free()
	await process_frame


## The grid: four cars, four lanes, before the lights.
func _lanes() -> void:
	var race := _race("circle", 1)
	for i in 30:
		race.step(DT)
		race._process(DT)
	await _frames(8)
	_save_around(_player_on_screen(race) + Vector2(0, 40), "lanes.png")
	race.queue_free()
	await process_frame
