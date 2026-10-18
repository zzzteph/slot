class_name Race
extends Node2D
## A slot race: you and up to three rivals, a lane each, side by side on the start line. Three, two,
## one, GO -- and from then on all you do is squeeze the trigger.
##
## Reads its setup from GameState unless `config` is filled in before it enters the tree (the tests and
## tools do that). The cars are stepped here, at the physics rate, in a fixed order -- so a race run
## headless is the same race.

const COUNTDOWN := 3.0
const GRID_BACK := 34.0               # px behind the line the guide blades start
const FINISH_CARD_DELAY := 1.4
## The camera: step 0 shows the whole circuit, the others ride with your car.
const ZOOMS := [0.0, 0.7, 0.9, 1.15]
const DEFAULT_ZOOM := 2
const CAMERA_LEAD := 0.32             # s of travel the camera looks ahead of the car
const CAMERA_LEAD_MAX := 280.0
const RIVAL_NAMES := ["Ace", "Dash", "Volt", "Nitro", "Blaze", "Comet"]
## ANALOG CONTROL with the mouse or a finger: take hold of the RED TRIGGER on the hand controller (a
## press anywhere else does nothing), then drag. Right squeezes it harder, left eases it off; this many
## px of drag is the whole range. Taking hold adds no power by itself (PRESS_START), and letting go
## releases the trigger completely, like a real one.
const DRAG_RANGE := 320.0
const PRESS_START := 0.0

## {track, car, colour, lane, rivals, difficulty, laps, seed}. Empty = take it from GameState.
var config: Dictionary = {}

var track_id: String = ""
var laps: int = 5
var track: SlotTrack = null
var fx: SlotFx = null
var hud: SlotHud = null
var camera: Camera2D = null
var cars: Array[SlotCar] = []
var ais: Array[SlotAI] = []
var player: SlotCar = null

var phase: String = "countdown"       # countdown | racing | finished
var countdown_left: float = COUNTDOWN
var race_time: float = 0.0
var pointer_held: bool = false
## How hard the mouse / finger is squeezing, 0..1, while `pointer_held`.
var pointer_demand: float = 0.0
var electric: SlotElectric = null
var _press_at := Vector2.ZERO
## Set by the tests to drive the player without input.
var autopilot: SlotAI = null

var _lap_start: Dictionary = {}       # car -> race time its current lap began
var _laps: Dictionary = {}            # car -> Array of lap times
var _finish: Dictionary = {}          # car -> race time it took the flag
var _finish_card_in: float = -1.0
var _zoom_step: int = DEFAULT_ZOOM
var _last_beep: int = 4
var _headless := false
var _touch := false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	# The race keeps listening while paused (Esc resumes); the simulation itself checks the pause.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if config.is_empty():
		config = {
			"track": GameState.selected_track, "car": GameState.selected_car,
			"colour": GameState.selected_colour, "lane": GameState.selected_lane,
			"rivals": GameState.rivals, "difficulty": GameState.difficulty,
		}
	track_id = TrackData.resolve(String(config.get("track", TrackData.DEFAULT_ID)))
	laps = int(config.get("laps", TrackData.get_laps(track_id)))
	track = SlotTrack.new()
	track.name = "Track"
	add_child(track)
	track.setup(track_id)
	fx = SlotFx.new()
	fx.name = "Fx"
	fx.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(fx)
	_build_field()
	if not _headless:
		electric = SlotElectric.new()
		electric.name = "Electric"
		electric.process_mode = Node.PROCESS_MODE_PAUSABLE
		electric.cars = cars
		add_child(electric)
	_setup_camera()
	if not bool(config.get("no_hud", false)):
		_setup_hud()
	if not _headless:
		Audio.set_engine_active(false)
		Audio.set_background_music(true)


func _build_field() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(config.get("seed", Time.get_ticks_usec()))
	var player_lane := clampi(int(config.get("lane", 1)), 0, SlotTrack.LANE_COUNT - 1)
	var rival_count := clampi(int(config.get("rivals", 3)), 0, SlotTrack.LANE_COUNT - 1)
	var difficulty := String(config.get("difficulty", "medium"))
	var player_car := String(config.get("car", CarCatalog.DEFAULT_ID))
	var player_colour := int(config.get("colour", 0))
	player = _add_car(player_car, player_colour, player_lane, "You", true)
	# The rivals take the other lanes, in a car each that is not yours where possible, and in a colour
	# that is not yours either.
	var lanes_free: Array = []
	for i in SlotTrack.LANE_COUNT:
		if i != player_lane:
			lanes_free.append(i)
	var pool: Array = Array(CarCatalog.ids())
	pool.erase(player_car)
	pool.shuffle()
	var names: Array = RIVAL_NAMES.duplicate()
	for i in rival_count:
		var car_id: String = pool[i % pool.size()] if not pool.is_empty() else player_car
		var colour := 0 if car_id != player_car else posmod(player_colour + 1 + i, CarCatalog.PALETTE_SIZE)
		var who: String = names[rng.randi_range(0, names.size() - 1)]
		names.erase(who)
		var c := _add_car(car_id, colour, int(lanes_free[i]), "%s (%s)" % [who, CarCatalog.display_name(car_id)], false)
		var ai := SlotAI.new()
		ai.setup(c, difficulty, rng.randi())
		ais.append(ai)


func _add_car(car_id: String, colour: int, lane: int, who: String, is_player: bool) -> SlotCar:
	var c := SlotCar.new()
	c.name = "Player" if is_player else "Rival%d" % cars.size()
	c.is_player = is_player
	c.display_name = who
	c.configure(car_id, colour)
	c.place(track.get_lane(lane), -GRID_BACK)
	c.frozen = true
	c.z_index = SlotTrack.Z_CAR_LOW
	c.deslotted.connect(_on_deslotted)
	c.reslotted.connect(_on_reslotted)
	add_child(c)
	cars.append(c)
	_lap_start[c] = 0.0
	_laps[c] = []
	return c


func _setup_camera() -> void:
	camera = Camera2D.new()
	camera.name = "Camera"
	add_child(camera)
	camera.make_current()
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = int(track.world_size.x)
	camera.limit_bottom = int(track.world_size.y + SlotHud.BAR_H)
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 6.0
	_apply_zoom(DEFAULT_ZOOM, true)


func _setup_hud() -> void:
	hud = SlotHud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.set_track(TrackData.display_name(track_id), TrackData.get_accent(track_id))
	hud.mini_map.race = self
	hud.mini_map.set_track(track)
	hud.pause_pressed.connect(pause)
	hud.resume_pressed.connect(resume)
	hud.restart_pressed.connect(restart)
	hud.tracks_pressed.connect(func() -> void: GameState.go_to_track_select())
	hud.menu_pressed.connect(func() -> void: GameState.go_to_menu())
	_touch = DisplayServer.is_touchscreen_available()
	hud.set_touch_hint(_touch)
	hud.set_map_visible(_zoom_step != 0)
	hud.show_message("3", "You are in the %s lane.  Ease off before the bends!" % 			SlotTrack.lane_name(player.lane.index).to_upper())


# ------------------------------------------------------------------ the race

func _physics_process(delta: float) -> void:
	if not get_tree().paused:
		step(delta)


## One fixed step of the whole race. Public so the tests can run a race without a frame loop.
func step(dt: float) -> void:
	match phase:
		"countdown":
			_step_countdown(dt)
		_:
			_step_racing(dt)


func _step_countdown(dt: float) -> void:
	countdown_left -= dt
	_set_triggers(dt)
	for c in cars:
		c.step(dt)
	var n := int(ceil(countdown_left))
	if n != _last_beep and n >= 0:
		_last_beep = n
		if n > 0:
			_beep(false)
			if hud != null and n < 3:
				hud.show_message(str(n), hud.sub_label.text)
	if countdown_left <= 0.0:
		phase = "racing"
		_beep(true)
		for c in cars:
			c.frozen = false
		if hud != null:
			hud.show_message("GO!", "", Color(0.4, 1.0, 0.45))
		if not _headless:
			Audio.set_engine_active(true)


func _step_racing(dt: float) -> void:
	race_time += dt
	_set_triggers(dt)
	for c in cars:
		var before := c.s
		var lap_before := c.laps_done()
		c.step(dt)
		if c.s >= 0.0 and c.laps_done() > lap_before and not c.finished:
			# When, within this step, the line was crossed -- so lap times do not jitter by a frame.
			var line := float(c.laps_done()) * c.lane.length
			var u := clampf((line - before) / maxf(c.s - before, 0.001), 0.0, 1.0)
			_lap_done(c, race_time - dt + dt * u)
	if phase == "racing" and hud != null and race_time > 1.0 and player.is_slotted() \
			and hud.big_label.text == "GO!":
		hud.clear_message()
	if _finish_card_in > 0.0:
		_finish_card_in -= dt
		if _finish_card_in <= 0.0:
			_show_finish()
	_effects(dt)


func _set_triggers(dt: float) -> void:
	for ai in ais:
		if ai.car.finished:
			ai.car.trigger = false
		else:
			ai.drive(dt)
	if player.finished:
		player.trigger = false
		player.demand = -1.0
	elif autopilot != null:
		autopilot.drive(dt)
	else:
		_player_input()


## The player's controller: an analog squeeze (the mouse or a finger being dragged, or a pad's right
## trigger) wins; otherwise the on/off keys, whose throttle climbs the longer they are held.
func _player_input() -> void:
	var pad := Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) if Input.get_connected_joypads().size() > 0 else 0.0
	if pointer_held:
		player.demand = pointer_demand
	elif pad > 0.03:
		player.demand = pad
	else:
		player.demand = -1.0
		player.trigger = Input.is_action_pressed(GameState.THROTTLE_ACTION)


## True while the player is asking for power by any means.
func throttle_held() -> bool:
	return pointer_held or Input.is_action_pressed(GameState.THROTTLE_ACTION) or player.demand > 0.0


func _lap_done(c: SlotCar, at: float) -> void:
	var t := at - float(_lap_start[c])
	(_laps[c] as Array).append(t)
	_lap_start[c] = at
	if (_laps[c] as Array).size() >= laps:
		c.finished = true
		_finish[c] = at
		if c == player:
			phase = "finished"
			release_pointer()
			_finish_card_in = FINISH_CARD_DELAY
			if hud != null:
				var place := place_of(player)
				hud.show_message("%s!" % GameState.ordinal(place).to_upper() if place > 1 else "WINNER!",
						"", Color(1.0, 0.92, 0.3))
	elif c == player and (_laps[c] as Array).size() == laps - 1 and hud != null and player.is_slotted():
		hud.show_message("FINAL LAP", "", Color(1.0, 1.0, 1.0))
		get_tree().create_timer(1.2, false).timeout.connect(func() -> void:
			if hud != null and hud.big_label.text == "FINAL LAP":
				hud.clear_message())


func _show_finish() -> void:
	var broke := {}
	if not bool(config.get("no_records", false)):
		broke = GameState.submit_race(track_id, lap_times_of(player), finish_time_of(player))
	if hud != null:
		hud.clear_message()
		hud.show_finish(self, broke)
	if not _headless:
		Audio.set_engine_active(false)


func _on_deslotted(c: SlotCar) -> void:
	if not _headless:
		fx.burst(c.guide_position(), c.heading)
		var near := 1.0 - clampf(c.position.distance_to(player.position) / 900.0, 0.0, 1.0)
		Audio.impact(0.9 if c == player else 0.5 * near)
	if c == player and hud != null and phase != "finished":
		hud.show_message("OFF!", "The marshal will put you back in the slot", Color(1.0, 0.35, 0.25))


func _on_reslotted(c: SlotCar) -> void:
	if c == player and hud != null and hud.big_label.text == "OFF!":
		hud.clear_message()


# ------------------------------------------------------------------ standings

## Finished cars by finishing time, then the rest by how far round they are.
func standings() -> Array:
	var done: Array = []
	var running: Array = []
	for c in cars:
		(done if c.finished else running).append(c)
	done.sort_custom(func(a, b) -> bool: return float(_finish[a]) < float(_finish[b]))
	running.sort_custom(func(a, b) -> bool: return a.progress() > b.progress())
	return done + running


func place_of(c: SlotCar) -> int:
	return standings().find(c) + 1


func lap_times_of(c: SlotCar) -> Array:
	return _laps.get(c, [])


func best_lap_of(c: SlotCar) -> float:
	var best := INF
	for t in lap_times_of(c):
		best = minf(best, float(t))
	return best


func current_lap_time(c: SlotCar) -> float:
	if phase == "countdown":
		return 0.0
	if c.finished:
		var l := lap_times_of(c)
		return float(l[l.size() - 1]) if not l.is_empty() else 0.0
	return race_time - float(_lap_start.get(c, 0.0))


func finish_time_of(c: SlotCar) -> float:
	return float(_finish.get(c, INF))


# ------------------------------------------------------------------ every frame

func _process(delta: float) -> void:
	for c in cars:
		if not c.is_slotted():
			c.z_index = SlotTrack.Z_CAR_AIR
		elif track.is_index_on_deck(c.lane_index()):
			c.z_index = SlotTrack.Z_CAR_HIGH
		else:
			c.z_index = SlotTrack.Z_CAR_LOW
	_update_camera()
	if hud != null:
		_move_controller(delta)
		hud.update_from(self, delta)
		if player.state != SlotCar.State.SLOTTED and phase != "finished":
			var r := int(round(player.recovery() * 100.0))
			hud.sub_label.text = "The marshal will put you back in the slot  (%d%%)" % r
	if not _headless:
		_audio()


## THE CONTROLLER IS IN YOUR HAND. With a mouse, while the trigger is not squeezed, the controller
## follows the pointer -- the red trigger under it, the system cursor hidden -- so it can be put down
## wherever it is not covering your car; press, and it stays where it is while you squeeze and drag.
## (On a touch screen there is no pointer to follow: it stays in its corner.)
const FOLLOW_RATE := 22.0
## Off for the screenshot tool (no real mouse to follow).
var controller_follows := true


func _move_controller(delta: float) -> void:
	var ctl := hud.controller
	var free := not _headless and not get_tree().paused and phase != "finished"
	var follow := free and controller_follows and not _touch and not pointer_held
	if follow:
		var target := get_viewport().get_mouse_position() - ctl.trigger_offset()
		target.x = clampf(target.x, -ctl.size.x * 0.3, 1280.0 - ctl.size.x * 0.6)
		target.y = clampf(target.y, -ctl.size.y * 0.15, 720.0 - ctl.size.y * 0.35)
		ctl.position = ctl.position.lerp(target, clampf(FOLLOW_RATE * delta, 0.0, 1.0))
	var over := free and not pointer_held and ctl.grab_rect().has_point(get_viewport().get_mouse_position())
	ctl.hover = over
	ctl.held = pointer_held
	if _headless or _touch or pointer_held:
		return
	# The controller is the pointer while racing; the cursor comes back for the cards (pause, results).
	var hide := follow
	if hide and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	elif not hide and Input.mouse_mode == Input.MOUSE_MODE_HIDDEN:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _effects(_dt: float) -> void:
	if _headless:
		return
	for c in cars:
		if not c.is_slotted() or c.speed < 150.0:
			continue
		if c.throttle > 0.55 and randf() < c.throttle * 0.5:
			fx.spark(c.guide_position(), c.heading)
		# The tail is out and the pickups are losing the braids: they arc.
		if c.danger() > 0.75 and randf() < 0.5:
			fx.arc(c.guide_position(), 16.0 + 18.0 * c.danger())


func _audio() -> void:
	var p := player
	Audio.set_engine(p.speed / p.top_speed, p.throttle, p.speed / p.top_speed)
	var squeal := clampf((p.danger() - 0.6) / 0.4, 0.0, 1.0) if p.is_slotted() else 0.0
	Audio.set_tyres(squeal * clampf(p.speed / 400.0, 0.0, 1.0))
	# The motor's electric whine: its note climbs with the speed, and it is there while power flows.
	Audio.set_charge(0.1 + 0.9 * p.speed / p.top_speed, p.is_slotted() and p.throttle > 0.05)


func _beep(high: bool) -> void:
	if not _headless:
		Audio.beep(high)


# ------------------------------------------------------------------ camera

func _apply_zoom(step: int, instant: bool = false) -> void:
	_zoom_step = clampi(step, 0, ZOOMS.size() - 1)
	var z := float(ZOOMS[_zoom_step])
	if _zoom_step == 0:
		var box := track.road_bounds()
		var view := Vector2(1280, 720 - SlotHud.BAR_H)
		z = minf(view.x / box.size.x, view.y / box.size.y)
	camera.zoom = Vector2(z, z)
	if hud != null:
		hud.set_map_visible(_zoom_step != 0)
	if instant:
		_update_camera()
		camera.reset_smoothing()


func _update_camera() -> void:
	if camera == null or player == null:
		return
	var z := camera.zoom.x
	# The bar covers the bottom of the screen; centre the picture on what is left.
	var bar := Vector2(0.0, SlotHud.BAR_H * 0.5 / z)
	if _zoom_step == 0:
		camera.position = track.road_bounds().get_center() + bar
		return
	var lead := Vector2.ZERO
	if player.is_slotted():
		lead = Vector2.from_angle(player.lane.heading_at(player.visual_s())) \
				* minf(player.speed * CAMERA_LEAD, CAMERA_LEAD_MAX)
	camera.position = player.position + lead + bar


# ------------------------------------------------------------------ input

func _unhandled_input(event: InputEvent) -> void:
	if get_tree().paused:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_apply_zoom(_zoom_step + 1)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_apply_zoom(_zoom_step - 1)
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				if can_grab(mb.position):
					press_pointer(mb.position)
			else:
				release_pointer()
		return
	if event is InputEventMouseMotion:
		if pointer_held:
			drag_pointer((event as InputEventMouseMotion).relative.x)
		return
	if not (event is InputEventKey) or not event.pressed or event.is_echo():
		return
	var key := (event as InputEventKey).physical_keycode
	if phase == "finished" and _finish_card_in <= 0.0:
		if key == KEY_ENTER or key == KEY_KP_ENTER or key == KEY_R:
			restart()
		elif key == KEY_ESCAPE:
			GameState.go_to_track_select()
		return
	match key:
		KEY_ESCAPE, KEY_P:
			pause()
		KEY_Z, KEY_TAB:
			_apply_zoom(_zoom_step - 1 if _zoom_step > 0 else ZOOMS.size() - 1)
		KEY_R:
			restart()


## True when a press at `at` lands on the controller's trigger (or there is no HUD: a test or a tool).
func can_grab(at: Vector2) -> bool:
	return hud == null or hud.controller.grab_rect().has_point(at)


## The mouse (or a finger: touches arrive as mouse events) goes down on the trigger: the trigger is squeezed to
## PRESS_START, and on a desktop the cursor is locked so a long drag never runs into the edge of the
## screen.
func press_pointer(at: Vector2) -> void:
	pointer_held = true
	pointer_demand = PRESS_START
	_press_at = at
	if not _headless and not _touch and phase != "finished":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func drag_pointer(dx: float) -> void:
	pointer_demand = clampf(pointer_demand + dx / DRAG_RANGE, 0.0, 1.0)


func release_pointer() -> void:
	if not pointer_held:
		return
	pointer_held = false
	_free_cursor()


func _free_cursor() -> void:
	if not _headless and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		Input.warp_mouse(_press_at)


func _exit_tree() -> void:
	_free_cursor()
	if not _headless:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and phase != "finished" and is_inside_tree():
		pause()


func pause() -> void:
	if phase == "finished" or get_tree().paused:
		return
	get_tree().paused = true
	release_pointer()
	if not _headless:
		Audio.set_engine_active(false)
	if hud != null:
		hud.show_pause()


func resume() -> void:
	get_tree().paused = false
	if hud != null:
		hud.hide_pause()
	if not _headless and phase == "racing":
		Audio.set_engine_active(true)


func restart() -> void:
	get_tree().paused = false
	GameState.start_race()


## Esc while paused resumes (the race itself is paused, so the HUD forwards it).
func _input(event: InputEvent) -> void:
	if get_tree().paused and event is InputEventKey and event.pressed and not event.is_echo() \
			and (event as InputEventKey).physical_keycode in [KEY_ESCAPE, KEY_P]:
		get_viewport().set_input_as_handled()
		resume()
