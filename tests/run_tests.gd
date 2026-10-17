extends SceneTree
## Headless test runner:
##   godot --headless --path . --script res://tests/run_tests.gd
## One PASS/FAIL line per check, a summary, exit code 0 when everything passed.

const DT := 1.0 / 60.0

var passed := 0
var failed := 0


func _init() -> void:
	await process_frame
	var gs: Node = root.get_node("GameState")
	gs.records_path = "user://test_records.cfg"
	gs.settings_path = "user://test_settings.cfg"
	gs.records = {}
	test_tracks()
	test_bridge()
	test_throttle()
	test_analog()
	await test_pointer_drag()
	test_deslot_and_marshal()
	test_cars_are_equal()
	test_careful_driver_stays_in()
	test_frame_rate()
	test_ai_profiles()
	test_records(gs)
	await test_race_scene(gs)
	await test_screens()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_records.cfg"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_settings.cfg"))
	print("=== Summary: %d passed, %d failed ===" % [passed, failed])
	quit(0 if failed == 0 else 1)


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
		print("PASS  ", what)
	else:
		failed += 1
		print("FAIL  ", what)


# ------------------------------------------------------------------ geometry

func test_tracks() -> void:
	for id in TrackData.ids():
		var t := SlotTrack.new()
		t.setup(id)
		check(t.lanes.size() == SlotTrack.LANE_COUNT, "%s: four lanes" % id)
		var finite := true
		for l in t.lanes:
			for p in l.points:
				finite = finite and is_finite(p.x) and is_finite(p.y)
			for k in l.curvature:
				finite = finite and is_finite(k)
		check(finite, "%s: every lane point and curvature is finite" % id)
		var tight := INF
		for l in t.lanes:
			tight = minf(tight, l.min_radius())
		check(tight > SlotTrack.LANE_GAP * 2.0, "%s: the tightest lane radius (%d px) leaves room for the lanes" % [id, int(tight)])
		# Adjacent lanes stay LANE_GAP apart all the way round (offsetting never folds a lane).
		var worst := 0.0
		for i in t.centerline.size():
			for l in range(1, t.lanes.size()):
				var d := t.lanes[l].points[i].distance_to(t.lanes[l - 1].points[i])
				worst = maxf(worst, absf(d - SlotTrack.LANE_GAP))
		check(worst < 0.5, "%s: lanes are %d px apart everywhere (worst error %.2f)" % [id, SlotTrack.LANE_GAP, worst])
		var inside := Rect2(Vector2.ZERO, t.world_size).encloses(t.road_bounds())
		check(inside, "%s: the road is inside the world" % id)
		check(t.get_ground_mesh() != null, "%s: the ground is baked into a mesh" % id)
		var lane := t.lanes[0]
		var back := lane.position_at(lane.length + 5.0).distance_to(lane.position_at(5.0))
		check(back < 0.01, "%s: a lane wraps round onto itself" % id)
		t.free()


func test_bridge() -> void:
	var t := SlotTrack.new()
	t.setup("figure8")
	check(t.has_bridge and t.get_deck_mesh() != null, "figure8: has a bridge deck")
	var on_deck := 0
	for i in t.centerline.size():
		if t.is_index_on_deck(i):
			on_deck += 1
	check(on_deck > 10 and on_deck < t.centerline.size() / 4, "figure8: the deck carries a short stretch (%d points)" % on_deck)
	var lens := []
	for l in t.lanes:
		lens.append(l.length)
	check(absf(float(lens.max()) - float(lens.min())) < 2.0, "figure8: every lane is the same length")
	# The grid -- the start line and the boxes behind it -- is out in the open, nowhere near the bridge.
	var clear := true
	for i in range(-8, 8):
		clear = clear and not t.is_index_on_deck(posmod(i, t.centerline.size()))
	var gap := t.centerline[0].distance_to(t.bridge_center)
	check(clear and gap > SlotTrack.ROAD_HALF * 4.0, "figure8: the grid is clear of the bridge (%d px from it)" % int(gap))
	t.free()
	var c := SlotTrack.new()
	c.setup("circle")
	check(not c.has_bridge and not c.is_index_on_deck(0), "circle: no bridge")
	c.free()


# ------------------------------------------------------------------ physics

func _car(track: SlotTrack, id: String = "sport", lane: int = 1) -> SlotCar:
	var c := SlotCar.new()
	c.configure(id, 0)
	c.place(track.get_lane(lane), 0.0)
	return c


func test_throttle() -> void:
	var t := SlotTrack.new()
	t.setup("circle")
	var c := _car(t)
	c.trigger = true
	for i in 30:
		c.step(DT)
	check(c.throttle > 0.4 and c.throttle < 0.6, "throttle climbs while held (%.2f after 0.5 s)" % c.throttle)
	for i in 40:
		c.step(DT)
	check(is_equal_approx(c.throttle, 1.0), "throttle reaches full after ~1 s")
	check(c.speed > 0.0 and c.speed <= c.top_speed, "the car is moving, no faster than its top speed")
	var before := c.s
	c.step(DT)
	check(c.visual_s() >= before - 0.001 and c.visual_s() <= c.s + 0.001 and c.position == c.world_pos,
			"the car is drawn between its last two ticks, never ahead of or behind them")
	var v := c.speed
	c.trigger = false
	for i in 12:
		c.step(DT)
	check(c.throttle < 0.4, "throttle falls quickly when released (%.2f)" % c.throttle)
	check(c.speed < v, "the motor brakes when the trigger is released")
	c.frozen = true
	c.trigger = true
	var s0 := c.s
	c.speed = 0.0
	for i in 60:
		c.step(DT)
	check(c.s == s0 and c.throttle > 0.9, "held on the grid: the throttle winds up, the car does not move")
	c.free()
	t.free()


func test_analog() -> void:
	var t := SlotTrack.new()
	t.setup("circle")
	var c := _car(t)
	c.demand = 0.6
	for i in 18:
		c.step(DT)
	check(absf(c.throttle - 0.6) < 0.01, "analog: the throttle follows the squeeze quickly (%.2f after 0.3 s)" % c.throttle)
	for i in 240:
		c.step(DT)
	check(absf(c.speed - 0.6 * c.top_speed) < 30.0, "analog: a steady squeeze holds a steady speed (%d of %d)" % [int(c.speed), int(0.6 * c.top_speed)])
	c.demand = 0.2
	for i in 6:
		c.step(DT)
	check(c.throttle < 0.5, "analog: easing off closes the throttle fast")
	c.demand = -1.0
	c.trigger = false
	for i in 30:
		c.step(DT)
	check(c.throttle == 0.0, "analog off again: the on/off trigger is back in charge")
	c.free()
	t.free()


func test_pointer_drag() -> void:
	var race: Node = load("res://scenes/race.tscn").instantiate()
	race.config = {"track": "circle", "rivals": 0, "laps": 1, "seed": 1, "no_records": true}
	root.add_child(race)
	check(not race.can_grab(Vector2(900, 100)), "a click away from the red trigger takes no hold")
	var grip_at: Vector2 = race.hud.controller.grab_rect().get_center()
	check(race.can_grab(grip_at), "a click on the red trigger takes hold")
	race.press_pointer(grip_at)
	check(race.pointer_held and race.pointer_demand == race.PRESS_START, "taking hold adds no power by itself")
	race.drag_pointer(race.DRAG_RANGE * 0.75)
	check(is_equal_approx(race.pointer_demand, race.PRESS_START + 0.75), "drag right: more power")
	race.drag_pointer(-race.DRAG_RANGE * 0.5)
	check(is_equal_approx(race.pointer_demand, race.PRESS_START + 0.25), "drag left: less power")
	race.drag_pointer(race.DRAG_RANGE * 5.0)
	check(race.pointer_demand == 1.0, "a long drag stops at full -- and does not have to be unwound")
	race.step(DT)
	check(race.player.demand == 1.0, "the squeeze reaches the car")
	race.release_pointer()
	race.step(DT)
	check(not race.pointer_held and race.player.demand < 0.0, "let go: the trigger is released")
	race.queue_free()
	await process_frame


func test_deslot_and_marshal() -> void:
	var t := SlotTrack.new()
	t.setup("circle")
	var c := _car(t, "f1", 0)
	var got := [0, 0]
	c.deslotted.connect(func(_c: SlotCar) -> void: got[0] += 1)
	c.reslotted.connect(func(_c: SlotCar) -> void: got[1] += 1)
	c.trigger = true
	var steps := 0
	while c.is_slotted() and steps < 60 * 20:
		c.step(DT)
		steps += 1
	check(not c.is_slotted() and got[0] == 1 and c.deslots == 1, "flat out into the bend: the car leaves the slot")
	var off_s := c.s
	var off_pos := c.position
	var marshal := 0
	while not c.is_slotted() and marshal < 60 * 10:
		c.step(DT)
		marshal += 1
	check(c.is_slotted() and got[1] == 1, "the marshal puts it back")
	var secs := float(marshal) * DT
	check(secs >= SlotCar.OFF_MIN_TIME + SlotCar.MARSHAL_TIME - 0.05 and secs < 5.0,
			"a de-slot costs %.1f s" % secs)
	check(is_equal_approx(c.s, off_s) and c.speed == 0.0, "back in the slot where it came off, stopped")
	check(off_pos.distance_to(c.lane.position_at(c.s)) < 60.0, "it came off where the lane is")
	c.free()
	t.free()


func test_cars_are_equal() -> void:
	var first := CarCatalog.get_car(CarCatalog.ids()[0])
	var same := true
	for id in CarCatalog.ids():
		var c := CarCatalog.get_car(id)
		for key in CarCatalog.STATS.keys():
			same = same and float(c[key]) == float(first[key])
	check(same, "every car drives the same; only the models differ")
	var styles := {}
	for id in CarCatalog.ids():
		styles[String(CarCatalog.get_car(id)["style"])] = true
	check(styles.size() == CarCatalog.ids().size(), "every car has its own model")


func test_careful_driver_stays_in() -> void:
	# Half throttle the whole way round the oval is well inside every car's limit.
	var t := SlotTrack.new()
	t.setup("circle")
	for id in CarCatalog.ids():
		var c := _car(t, id, 0)
		var steps := 0
		while c.progress() < 2.0 and steps < 60 * 120:
			c.trigger = c.throttle < 0.45
			c.step(DT)
			steps += 1
		check(c.deslots == 0 and c.progress() >= 2.0, "%s: two gentle laps without coming off" % id)
		c.free()
	t.free()


func test_frame_rate() -> void:
	var t := SlotTrack.new()
	t.setup("singapore")
	var times := []
	for dt in [1.0 / 60.0, 1.0 / 120.0, 1.0 / 30.0]:
		var c := _car(t, "sport", 1)
		var ai := SlotAI.new()
		ai.setup(c, "medium", 3)
		var time := 0.0
		while c.progress() < 1.0 and time < 120.0:
			ai.drive(dt)
			c.step(dt)
			time += dt
		times.append(time)
		c.free()
	var spread := (float(times.max()) - float(times.min())) / float(times.min())
	check(spread < 0.03, "a lap takes the same time at 60, 120 and 30 Hz (%s, spread %.1f%%)" % [str(times), spread * 100.0])
	t.free()


func test_ai_profiles() -> void:
	for id in TrackData.ids():
		var t := SlotTrack.new()
		t.setup(id)
		var lap_by_diff := {}
		var offs := 0
		for diff in SlotAI.DIFFICULTIES:
			var c := _car(t, "sport", 2)
			var ai := SlotAI.new()
			ai.setup(c, diff, 11)
			var time := 0.0
			while c.progress() < 2.0 and time < 300.0:
				ai.drive(DT)
				c.step(DT)
				time += DT
			lap_by_diff[diff] = time / 2.0
			offs += c.deslots
			c.free()
		check(float(lap_by_diff["hard"]) < float(lap_by_diff["medium"]) and float(lap_by_diff["medium"]) < float(lap_by_diff["easy"]),
				"%s: hard rivals are faster than medium, medium than easy (%s)" % [id, str(lap_by_diff)])
		check(offs <= 2, "%s: the rivals finish without spending the race off the track (%d offs)" % [id, offs])
		t.free()


func test_records(gs: Node) -> void:
	gs.records = {}
	var broke: Dictionary = gs.submit_race("circle", [8.0, 7.5, 7.8], 23.3)
	check(bool(broke["lap"]) and bool(broke["race"]), "a first race sets both records")
	check(is_equal_approx(gs.best_lap("circle"), 7.5), "the best lap is the fastest of the race")
	broke = gs.submit_race("circle", [9.0, 9.0, 9.0], 27.0)
	check(not bool(broke["lap"]) and not bool(broke["race"]), "a slower race breaks nothing")
	check(not is_finite(gs.best_lap("figure8")), "records are per track")
	check(gs.format_time(65.25) == "1:05.250" and gs.format_time(INF) == "-:--.---", "times read m:ss.mmm")
	gs.records = {}


# ------------------------------------------------------------------ scenes

func test_race_scene(gs: Node) -> void:
	for id in TrackData.ids():
		var race: Node = load("res://scenes/race.tscn").instantiate()
		race.config = {"track": id, "car": "sport", "colour": 0, "lane": 1, "rivals": 3,
				"difficulty": "medium", "laps": 2, "seed": 5}
		root.add_child(race)
		check(race.cars.size() == 4 and race.player.is_player, "%s: four cars on the grid" % id)
		var lanes := {}
		for c in race.cars:
			lanes[c.lane.index] = true
		check(lanes.size() == 4, "%s: one car per lane" % id)
		race.autopilot = SlotAI.new()
		race.autopilot.setup(race.player, "hard", 1)
		var steps := 0
		while race.phase == "countdown" and steps < 600:
			race.step(DT)
			steps += 1
		check(race.player.throttle > 0.9 and race.player.s < 0.0, "%s: revving on the grid, not rolling" % id)
		while not race.player.finished and steps < 60 * 300:
			race.step(DT)
			race._process(DT)
			steps += 1
		check(race.player.finished, "%s: the player finishes" % id)
		var laps: Array = race.lap_times_of(race.player)
		var total := 0.0
		for l in laps:
			total += float(l)
		check(laps.size() == 2 and absf(total - race.finish_time_of(race.player)) < 0.01,
				"%s: two laps, and they add up to the race time" % id)
		check(race.place_of(race.player) >= 1 and race.standings().size() == 4, "%s: a place in a field of four" % id)
		for i in 200:
			race.step(DT)
			race._process(DT)
		check(race.hud.finish_card != null, "%s: the results come up" % id)
		check(is_finite(gs.best_lap(id)), "%s: the race set a record" % id)
		race.queue_free()
		await process_frame


func test_screens() -> void:
	for s in ["main_menu", "car_select", "track_select", "help", "settings"]:
		var node: Node = load("res://scenes/%s.tscn" % s).instantiate()
		root.add_child(node)
		for i in 3:
			await process_frame
		check(node.is_inside_tree() and node.get_child_count() > 0, "%s builds" % s)
		node.queue_free()
		await process_frame
