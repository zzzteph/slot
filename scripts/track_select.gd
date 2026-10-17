extends Control
## Pick the circuit and your lane. The list is on the left; on the right, the real track (its baked mesh,
## scaled down), what it asks of you, and your records on it in the car you picked.
##
##   Up / Down    track          Left / Right   lane
##   Enter        race           Esc            back to the cars

const ROW_H := 84.0
const LIST := Rect2(24, 88, 360, 552)
const MAIN := Rect2(400, 88, 856, 552)
const PREVIEW := Rect2(16, 16, 520, 300)

var _ids := TrackData.ids()
var _index: int = 0
var _rows: Array = []
var _lane_buttons: Array = []
var _preview: TrackPreview = null
var _name: Label = null
var _desc: Label = null
var _facts: Label = null
var _records: Label = null
var _lane_note: Label = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_index = maxi(Array(_ids).find(GameState.selected_track), 0)
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	BackgroundArt.add(self, "res://art/bg_tracks.png", 0.45)
	var head := UiTheme.panel("Header")
	head.size = Vector2(1280, 72)
	add_child(head)
	var title := UiTheme.label("Title", "SELECT TRACK", UiTheme.TITLE, UiTheme.ACCENT)
	title.position = Vector2(24, 12)
	title.size = Vector2(600, 48)
	add_child(title)
	var car := UiTheme.label("CarNote", "%s  -  %d rival%s, %s" % [CarCatalog.display_name(GameState.selected_car),
			GameState.rivals, "" if GameState.rivals == 1 else "s", GameState.difficulty], UiTheme.BODY, UiTheme.MUTED)
	car.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	car.position = Vector2(656, 12)
	car.size = Vector2(600, 48)
	add_child(car)
	_build_list()
	_build_main()
	var back := UiTheme.button("BackButton", "<  Cars", UiTheme.HEADING)
	back.position = Vector2(16, 656)
	back.size = Vector2(200, 52)
	back.pressed.connect(func() -> void:
		GameState.save_settings()
		GameState.go_to_car_select())
	add_child(back)
	var go := UiTheme.button("RaceButton", "RACE  >", UiTheme.HEADING)
	go.position = Vector2(1064, 656)
	go.size = Vector2(200, 52)
	go.pressed.connect(func() -> void: GameState.start_race())
	add_child(go)
	go.grab_focus.call_deferred()
	_select(_index)


func _build_list() -> void:
	var panel := UiTheme.panel("TrackList")
	panel.position = LIST.position
	panel.size = LIST.size
	add_child(panel)
	for i in _ids.size():
		var id := String(_ids[i])
		var row := Button.new()
		row.name = "Track_%s" % id
		row.flat = false           # a flat button draws no stylebox -- and the selection IS the stylebox
		row.focus_mode = Control.FOCUS_NONE
		row.position = LIST.position + Vector2(8, 8 + ROW_H * i)
		row.size = Vector2(LIST.size.x - 16, ROW_H - 8)
		row.pressed.connect(_select.bind(i))
		row.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and (e as InputEventMouseButton).double_click:
				GameState.start_race())
		add_child(row)
		var chip := ColorRect.new()
		chip.color = TrackData.get_accent(id)
		chip.position = Vector2(10, 12)
		chip.size = Vector2(8, ROW_H - 32)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(chip)
		var n := UiTheme.label("Name", TrackData.display_name(id), UiTheme.HEADING)
		n.position = Vector2(30, 6)
		n.size = Vector2(300, 34)
		row.add_child(n)
		var best := GameState.best_lap(id)
		var sub := UiTheme.label("Sub", "%s  -  %d laps  -  best %s" % [TrackData.get_location(id),
				TrackData.get_laps(id), GameState.format_time(best)], UiTheme.CAPTION, UiTheme.MUTED)
		sub.position = Vector2(30, 40)
		sub.size = Vector2(310, 24)
		row.add_child(sub)
		_rows.append(row)


func _build_main() -> void:
	var panel := UiTheme.panel("Main")
	panel.position = MAIN.position
	panel.size = MAIN.size
	add_child(panel)
	_preview = TrackPreview.new()
	_preview.name = "Preview"
	_preview.position = MAIN.position + PREVIEW.position
	_preview.size = PREVIEW.size
	add_child(_preview)
	var x := PREVIEW.end.x + 16.0
	_name = _lbl("TrackName", "", UiTheme.TITLE, Rect2(x, 12, 288, 48))
	_facts = _lbl("Facts", "", UiTheme.BODY, Rect2(x, 64, 288, 120))
	_facts.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_records = _lbl("Records", "", UiTheme.BODY, Rect2(x, 196, 288, 120))
	_records.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_desc = _lbl("Description", "", UiTheme.BODY, Rect2(16, 328, 824, 56))
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc.size = Vector2(824, 56)
	_lbl("LaneCaption", "YOUR LANE", UiTheme.CAPTION, Rect2(16, 400, 200, 24), UiTheme.MUTED)
	for i in SlotTrack.LANE_COUNT:
		var b := UiTheme.button("Lane%d" % i, SlotTrack.lane_name(i), UiTheme.BODY)
		b.focus_mode = Control.FOCUS_NONE
		b.position = MAIN.position + Vector2(16 + 136 * i, 428)
		b.size = Vector2(128, 48)
		b.pressed.connect(_set_lane.bind(i))
		add_child(b)
		_lane_buttons.append(b)
	_lane_note = _lbl("LaneNote", "", UiTheme.CAPTION, Rect2(16, 484, 824, 48), UiTheme.MUTED)
	_lane_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lane_note.size = Vector2(824, 48)
	_set_lane(GameState.selected_lane)


func _lbl(node_name: String, text: String, size_: int, r: Rect2, color := UiTheme.TEXT) -> Label:
	var l := UiTheme.label(node_name, text, size_, color)
	l.position = MAIN.position + r.position
	l.size = r.size
	add_child(l)
	return l


func _select(i: int) -> void:
	_index = posmod(i, _ids.size())
	var id := String(_ids[_index])
	GameState.selected_track = id
	for k in _rows.size():
		UiTheme.style_row(_rows[k] as Button, k == _index)
	_preview.show_track(id, GameState.selected_lane)
	_name.text = TrackData.display_name(id)
	_name.add_theme_color_override("font_color", TrackData.get_accent(id).lightened(0.2))
	var t := _preview.track
	var mid := (t.lanes[1].length + t.lanes[2].length) * 0.5
	var tight := INF
	for l in t.lanes:
		tight = minf(tight, l.min_radius())
	_facts.text = "Lap  %d m\nLaps  %d\nTightest bend  %.1f m radius\n%s" % [
		int(mid * TrackData.METRES_PER_PX), TrackData.get_laps(id), tight * TrackData.METRES_PER_PX,
		"Lanes cross on a bridge" if t.has_bridge else "Four lanes"]
	_records.text = "YOUR RECORDS\nBest lap  %s\nBest race  %s" % [
		GameState.format_time(GameState.best_lap(id)),
		GameState.format_time(GameState.best_race(id, TrackData.get_laps(id)))]
	_desc.text = TrackData.get_description(id)
	_set_lane(GameState.selected_lane)


func _set_lane(i: int) -> void:
	GameState.selected_lane = posmod(i, SlotTrack.LANE_COUNT)
	for k in _lane_buttons.size():
		var b := _lane_buttons[k] as Button
		var on := k == GameState.selected_lane
		var box := StyleBoxFlat.new()
		box.bg_color = SlotTrack.lane_color(k).darkened(0.25 if on else 0.65)
		box.border_color = Color.WHITE if on else Color(0, 0, 0, 0)
		box.set_border_width_all(3)
		box.set_corner_radius_all(4)
		b.add_theme_stylebox_override("normal", box)
		b.add_theme_stylebox_override("hover", box)
	if _preview != null and _preview.track != null:
		_preview.lane = GameState.selected_lane
		_preview.queue_redraw()
		var t := _preview.track
		var name_ := SlotTrack.lane_name(GameState.selected_lane)
		var mine := t.lanes[GameState.selected_lane].length
		var shortest := INF
		var longest := 0.0
		for l in t.lanes:
			shortest = minf(shortest, l.length)
			longest = maxf(longest, l.length)
		if t.has_bridge or longest - shortest < 1.0:
			_lane_note.text = "Every lane is the same length here: they all cross on the bridge."
		elif mine - shortest < 1.0:
			_lane_note.text = "%s is the shortest way round -- and has the tightest bends." % name_
		elif longest - mine < 1.0:
			_lane_note.text = "%s is the longest way round (+%d m a lap) -- and has the widest bends." % [
					name_, int((mine - shortest) * TrackData.METRES_PER_PX)]
		else:
			_lane_note.text = "%s is %d m a lap longer than the shortest lane, with wider bends." % [
					name_, int((mine - shortest) * TrackData.METRES_PER_PX)]


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	match (event as InputEventKey).physical_keycode:
		KEY_UP, KEY_W:
			_select(_index - 1)
		KEY_DOWN, KEY_S:
			_select(_index + 1)
		KEY_LEFT, KEY_A:
			_set_lane(GameState.selected_lane - 1)
		KEY_RIGHT, KEY_D:
			_set_lane(GameState.selected_lane + 1)
		KEY_ESCAPE:
			GameState.save_settings()
			GameState.go_to_car_select()
		_:
			return
	get_viewport().set_input_as_handled()


## The real circuit, scaled to fit: the same baked mesh the race draws, plus a marker on your grid slot.
class TrackPreview extends Control:
	var track: SlotTrack = null
	var lane: int = 0
	var _cache: Dictionary = {}

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true

	func show_track(id: String, lane_: int) -> void:
		lane = lane_
		if not _cache.has(id):
			var t := SlotTrack.new()
			t.setup(id)
			_cache[id] = t
		track = _cache[id]
		queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.1, 0.2, 0.1))
		if track == null:
			return
		var box := track.road_bounds()
		var sc := minf(size.x / box.size.x, size.y / box.size.y)
		var off := (size - box.size * sc) * 0.5 - box.position * sc
		draw_set_transform(off, 0.0, Vector2(sc, sc))
		if track.get_ground_mesh() != null:
			draw_mesh(track.get_ground_mesh(), null)
		if track.get_deck_mesh() != null:
			draw_mesh(track.get_deck_mesh(), null)
		var l := track.get_lane(lane)
		var at := l.position_at(-34.0)
		draw_circle(at, 9.0 / sc, Color.WHITE)
		draw_circle(at, 6.0 / sc, SlotTrack.lane_color(lane))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	func _exit_tree() -> void:
		for t in _cache.values():
			(t as Node).free()
		_cache.clear()
