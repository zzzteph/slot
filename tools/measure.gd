extends SceneTree
## Prints, for every track: its size, lane lengths and tightest lane radius; then, for every car, the
## lap time and de-slot count of an AI driver at each difficulty (lane 2, three laps).
##   godot --headless --path . --script res://tools/measure.gd [-- --laps 3]

const DT := 1.0 / 60.0


func _init() -> void:
	var laps := 3
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--laps" and i + 1 < args.size():
			laps = int(args[i + 1])
	for id in TrackData.ids():
		var track := SlotTrack.new()
		track.setup(id)
		var radii := []
		var lens := []
		for l in track.lanes:
			radii.append(int(l.min_radius()))
			lens.append(int(l.length))
		print("== %s  world %s  lane lengths %s  min radius %s  bridge %s" % [id, track.world_size, lens,
				radii, track.has_bridge])
		for car_id in CarCatalog.ids():
			var line := "  %-6s" % car_id
			for diff in SlotAI.DIFFICULTIES:
				var r := run(track, car_id, diff, laps, 1)
				line += "  %s %6.2fs/lap %d off" % [diff.substr(0, 1), r["lap"], r["offs"]]
			print(line)
		track.free()
	quit()


static func run(track: SlotTrack, car_id: String, diff: String, laps: int, lane: int) -> Dictionary:
	var car := SlotCar.new()
	car.configure(car_id, 0)
	car.place(track.get_lane(lane), 0.0)
	var ai := SlotAI.new()
	ai.setup(car, diff, 7)
	var t := 0.0
	while car.progress() < float(laps) and t < 600.0:
		ai.drive(DT)
		car.step(DT)
		t += DT
	var offs := car.deslots
	car.free()
	return {"lap": t / float(laps), "offs": offs}
