class_name SlotHud
extends CanvasLayer
## Everything on the race screen that is not the track. Deliberately little: bottom left, the HAND
## CONTROLLER in your hand (its plunger travels in as you squeeze -- a feel for the pressure, not a
## number to line it up with), and the lap; top right, the map and the race order; top left,
## pause; and the cards in the middle (countdown, "off the slot", the finish and the pause). How close the
## car is to coming off is on the track, not on a meter: the tail swings out, the pickups arc, and it squeals.
##
## Rope Racers' type scale (`UiTheme`); built in code, fed once a frame by `update_from`.

signal pause_pressed
signal resume_pressed
signal restart_pressed
signal tracks_pressed
signal menu_pressed

## Nothing spans the bottom of the screen any more, so the camera has the whole picture.
const BAR_H := 0.0
const SCREEN := Vector2(1280, 720)
const PANEL_Y := 636.0
const PANEL_H := 72.0
## The controller is drawn at `HandController.SCALE`, mirrored: trigger on the LEFT, squeezed towards
## the RIGHT -- the same way the mouse drags for more power.
const CONTROLLER_RECT := Rect2(8, 365, 281, 353)        # 156 x 196 drawn at HandController.SCALE
## Top right, one column: the lap, the map, the race order.
const LAP_RECT := Rect2(1064, 8, 208, 72)
const MAP_RECT := Rect2(1064, 88, 208, 128)
const BOARD_POS := Vector2(1064, 224)
const BOARD_ROW := 28.0
## The control hint over the controller is shown for this long after the start, then gets out of the way.
const HINT_TIME := 6.0

var controller: HandController = null
var cable: HandCable = null
var track_label: Label = null
var lap_label: Label = null
var hint_label: Label = null
var big_label: Label = null
var sub_label: Label = null
var mini_map: MiniMap = null
var board: Control = null
var _board_rows: Array = []
var _board_text: String = ""
var pause_button: Button = null
var finish_card: Control = null
var pause_card: Control = null
var _hint_idle := "SPACE  or  GRAB THE RED TRIGGER"


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_bottom()
	_build_top()
	_build_centre()


# ------------------------------------------------------------------ building

func _panel(r: Rect2, node_name: String) -> ColorRect:
	var p := UiTheme.panel(node_name)
	p.position = r.position
	p.size = r.size
	add_child(p)
	return p


func _label(parent: Node, node_name: String, text: String, size: int, r: Rect2,
		color: Color = UiTheme.TEXT, align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := UiTheme.label(node_name, text, size, color)
	l.position = r.position
	l.size = r.size
	l.horizontal_alignment = align
	parent.add_child(l)
	return l


func _build_bottom() -> void:
	cable = HandCable.new()
	cable.name = "HandCable"
	cable.size = SCREEN
	add_child(cable)
	controller = HandController.new()
	controller.name = "HandController"
	controller.position = CONTROLLER_RECT.position
	controller.size = CONTROLLER_RECT.size
	add_child(controller)
	hint_label = _label(self, "ControlHint", _hint_idle, UiTheme.CAPTION,
			Rect2(CONTROLLER_RECT.position.x, CONTROLLER_RECT.position.y - 28.0, 320, 24), UiTheme.ACCENT)

	var lp := _panel(LAP_RECT, "LapPanel")
	track_label = _label(lp, "TrackName", "", UiTheme.BODY, Rect2(12, 0, 190, 26))
	lap_label = _label(lp, "Lap", "LAP 1/5", UiTheme.TITLE, Rect2(12, 24, 190, 44))


func _build_top() -> void:
	pause_button = UiTheme.button("PauseButton", "II", UiTheme.BODY)
	pause_button.position = Vector2(16, 16)
	pause_button.size = Vector2(56, 48)
	pause_button.focus_mode = Control.FOCUS_NONE
	pause_button.pressed.connect(func() -> void: pause_pressed.emit())
	add_child(pause_button)

	var mp := _panel(MAP_RECT, "MapPanel")
	mini_map = MiniMap.new()
	mini_map.name = "MiniMap"
	mini_map.position = Vector2(6, 6)
	mini_map.size = MAP_RECT.size - Vector2(12, 12)
	mp.add_child(mini_map)

	board = _panel(Rect2(BOARD_POS, Vector2(208, 32)), "RaceOrder")
	_label(board, "Caption", "RACE ORDER", UiTheme.CAPTION, Rect2(10, 2, 190, 26), UiTheme.MUTED)


func _build_centre() -> void:
	big_label = _label(self, "BigMessage", "", 96, Rect2(0, 24, SCREEN.x, 120), Color(1.0, 0.92, 0.3),
			HORIZONTAL_ALIGNMENT_CENTER)
	big_label.add_theme_constant_override("outline_size", 10)
	sub_label = _label(self, "SubMessage", "", UiTheme.HEADING, Rect2(0, 140, SCREEN.x, 40), UiTheme.TEXT,
			HORIZONTAL_ALIGNMENT_CENTER)


# ------------------------------------------------------------------ per frame

func set_track(name_: String, accent: Color) -> void:
	track_label.text = name_
	track_label.add_theme_color_override("font_color", accent)


func set_touch_hint(touch: bool) -> void:
	_hint_idle = "GRAB THE RED TRIGGER" if touch else "SPACE  or  GRAB THE RED TRIGGER"
	hint_label.text = _hint_idle


func update_from(race: Race, delta: float) -> void:
	var p := race.player
	if p == null:
		return
	# The plunger sits where your finger is: the squeeze when it is analog, the throttle when it is a key.
	controller.squeeze = p.demand if p.demand >= 0.0 else p.throttle
	controller.power = p.throttle if p.is_slotted() else 0.0
	controller.advance(delta)
	cable.power = controller.power
	cable.simulate(delta, controller.cable_exit())
	hint_label.position = controller.position + Vector2(0, -28)
	hint_label.text = _hint_idle
	hint_label.visible = not race.pointer_held and (race.phase == "countdown" or race.race_time < HINT_TIME)
	var lap := clampi(p.laps_done() + 1, 1, race.laps)
	lap_label.text = "LAP %d/%d" % [lap, race.laps] if not p.finished else "FINISHED"
	mini_map.queue_redraw()
	_update_board(race)


func _update_board(race: Race) -> void:
	var order := race.standings()
	var key := ""
	for c in order:
		key += "%s:%d:%s;" % [c.display_name, (c as SlotCar).laps_done(), (c as SlotCar).finished]
	if key == _board_text:
		return
	_board_text = key
	for r in _board_rows:
		(r as Node).queue_free()
	_board_rows.clear()
	board.size = Vector2(208, 32 + BOARD_ROW * order.size())
	for i in order.size():
		var c: SlotCar = order[i]
		var y := 30.0 + BOARD_ROW * i
		if c.is_player:
			var hl := ColorRect.new()
			hl.color = UiTheme.ROW_SELECTED
			hl.position = Vector2(4, y)
			hl.size = Vector2(200, BOARD_ROW)
			hl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			board.add_child(hl)
			_board_rows.append(hl)
		var chip := ColorRect.new()
		chip.color = c.body_color
		chip.position = Vector2(30, y + 7)
		chip.size = Vector2(8, 14)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		board.add_child(chip)
		_board_rows.append(chip)
		_board_rows.append(_label(board, "Place%d" % i, str(i + 1), UiTheme.CAPTION, Rect2(10, y, 20, BOARD_ROW)))
		_board_rows.append(_label(board, "Name%d" % i, c.display_name.get_slice(" (", 0).substr(0, 13), UiTheme.CAPTION,
				Rect2(44, y, 116, BOARD_ROW)))
		var lap_text := "DONE" if c.finished else "L%d/%d" % [clampi(c.laps_done() + 1, 1, race.laps), race.laps]
		_board_rows.append(_label(board, "Lap%d" % i, lap_text, UiTheme.CAPTION, Rect2(150, y, 52, BOARD_ROW),
				UiTheme.MUTED, HORIZONTAL_ALIGNMENT_RIGHT))


## The overview camera shows the whole circuit already: the little map would only sit on top of it.
func set_map_visible(on: bool) -> void:
	var p := get_node_or_null("MapPanel") as Control
	if p != null:
		p.visible = on


func show_message(big: String, sub: String = "", color: Color = Color(1.0, 0.92, 0.3)) -> void:
	big_label.text = big
	big_label.add_theme_color_override("font_color", color)
	sub_label.text = sub


func clear_message() -> void:
	big_label.text = ""
	sub_label.text = ""


# ------------------------------------------------------------------ cards

func _card(node_name: String, size: Vector2) -> Control:
	var root := Control.new()
	root.name = node_name
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)
	var box := Panel.new()
	box.name = "Box"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.12, 0.14, 0.96)
	sb.border_color = Color(1, 1, 1, 0.45)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	box.add_theme_stylebox_override("panel", sb)
	box.position = ((SCREEN - Vector2(0, BAR_H)) - size) * 0.5
	box.size = size
	root.add_child(box)
	return root


func _card_buttons(box: Control, specs: Array, y: float) -> void:
	var w := (box.size.x - 32.0 - 16.0 * float(specs.size() - 1)) / float(specs.size())
	for i in specs.size():
		var b := UiTheme.button(String(specs[i][0]), String(specs[i][1]), UiTheme.HEADING)
		b.position = Vector2(16.0 + (w + 16.0) * i, y)
		b.size = Vector2(w, 56)
		b.focus_mode = Control.FOCUS_NONE     # Space is the throttle: it must never press a button
		b.pressed.connect(specs[i][2])
		box.add_child(b)


func show_pause() -> void:
	hide_pause()
	pause_card = _card("PauseCard", Vector2(520, 220))
	var box := pause_card.get_node("Box") as Control
	_label(box, "Title", "Paused", UiTheme.TITLE, Rect2(0, 18, 520, 48), UiTheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	_label(box, "Keys", "Esc to carry on", UiTheme.CAPTION, Rect2(0, 66, 520, 24), UiTheme.MUTED,
			HORIZONTAL_ALIGNMENT_CENTER)
	_card_buttons(box, [
		["ResumeButton", "Resume", func() -> void: resume_pressed.emit()],
		["RestartButton", "Restart", func() -> void: restart_pressed.emit()],
		["MenuButton", "Menu", func() -> void: menu_pressed.emit()],
	], 132.0)
	pause_button.visible = false


func hide_pause() -> void:
	if pause_card != null:
		pause_card.queue_free()
		pause_card = null
	pause_button.visible = finish_card == null


## The results: where you came, the field, your laps and whether you broke a record.
func show_finish(race: Race, broke: Dictionary) -> void:
	if finish_card != null:
		finish_card.queue_free()
	var order := race.standings()
	var h := 300.0 + 26.0 * order.size() + (26.0 if not broke.values().has(true) else 52.0)
	finish_card = _card("FinishCard", Vector2(560, h))
	pause_button.visible = false
	var box := finish_card.get_node("Box") as Control
	var p := race.player
	var place := race.place_of(p)
	_label(box, "Title", "Finished!  -  %s" % TrackData.display_name(race.track_id), UiTheme.HEADING,
			Rect2(0, 14, 560, 36), UiTheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	var verdict := "%s of %d" % [GameState.ordinal(place), order.size()]
	if place == 1 and order.size() > 1:
		verdict += "  -  WINNER!"
	_label(box, "Place", verdict, UiTheme.TITLE, Rect2(0, 52, 560, 48), UiTheme.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	var y := 108.0
	for i in order.size():
		var c: SlotCar = order[i]
		var right := GameState.format_time(race.finish_time_of(c)) if c.finished else "racing..."
		var col := UiTheme.TEXT if c.is_player else UiTheme.MUTED
		_label(box, "Row%d" % i, "%d.  %s" % [i + 1, c.display_name],
				UiTheme.CAPTION, Rect2(60, y, 320, 26), col)
		_label(box, "RowTime%d" % i, right, UiTheme.CAPTION, Rect2(380, y, 120, 26), col, HORIZONTAL_ALIGNMENT_RIGHT)
		y += 26.0
	y += 8.0
	var laps: Array = race.lap_times_of(p)
	var best := race.best_lap_of(p)
	_label(box, "Total", "Total  %s" % GameState.format_time(race.finish_time_of(p)), UiTheme.HEADING,
			Rect2(0, y, 560, 34), UiTheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	y += 36.0
	var parts := PackedStringArray()
	for t in laps:
		parts.append(GameState.format_time(float(t)) + ("*" if float(t) == best else ""))
	var lap_line := "Laps  " + "  ".join(parts)
	if parts.size() > 5:
		lap_line = "Best lap  %s   (%d laps)" % [GameState.format_time(best), parts.size()]
	_label(box, "Laps", lap_line, UiTheme.CAPTION, Rect2(0, y, 560, 24), UiTheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	y += 26.0
	var offs := "Off the slot %d time%s" % [p.deslots, "" if p.deslots == 1 else "s"]
	if p.deslots == 0:
		offs = "A clean race: never off the slot"
	_label(box, "Offs", offs, UiTheme.CAPTION, Rect2(0, y, 560, 24), UiTheme.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	y += 26.0
	var rec := PackedStringArray()
	if bool(broke.get("lap", false)):
		rec.append("NEW LAP RECORD!")
	if bool(broke.get("race", false)):
		rec.append("NEW RACE RECORD!")
	if not rec.is_empty():
		_label(box, "Records", "   ".join(rec), UiTheme.BODY, Rect2(0, y, 560, 26), UiTheme.ACCENT,
				HORIZONTAL_ALIGNMENT_CENTER)
	_card_buttons(box, [
		["AgainButton", "Race again", func() -> void: restart_pressed.emit()],
		["TracksButton", "Tracks", func() -> void: tracks_pressed.emit()],
		["MenuButton", "Menu", func() -> void: menu_pressed.emit()],
	], h - 80.0)
	_label(box, "Keys", "Enter: race again   Esc: tracks", UiTheme.CAPTION, Rect2(0, h - 22.0, 560, 20),
			UiTheme.MUTED, HORIZONTAL_ALIGNMENT_CENTER)


## The circuit in miniature, with a dot for every car.
class MiniMap extends Control:
	var race: Race = null
	var _pts := PackedVector2Array()
	var _xf := Transform2D.IDENTITY

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_track(track: SlotTrack) -> void:
		var box := track.road_bounds()
		var sc := minf(size.x / box.size.x, size.y / box.size.y)
		var off := (size - box.size * sc) * 0.5 - box.position * sc
		_xf = Transform2D(0.0, Vector2(sc, sc), 0.0, off)
		_pts = PackedVector2Array()
		for i in range(0, track.centerline.size(), 4):
			_pts.append(_xf * track.centerline[i])
		if not _pts.is_empty():
			_pts.append(_pts[0])
		queue_redraw()

	func _draw() -> void:
		if _pts.size() < 2:
			return
		draw_polyline(_pts, Color(1, 1, 1, 0.55), 4.0)
		draw_polyline(_pts, Color(0.2, 0.2, 0.22), 2.0)
		if race == null:
			return
		for c in race.cars:
			var car := c as SlotCar
			var at := _xf * car.position
			if car.is_player:
				draw_circle(at, 6.0, Color.WHITE)
			draw_circle(at, 4.0, car.body_color)


## The slot-car hand controller, seen from the side (drawn in its own 156 x 196 frame, then scaled by
## SCALE and mirrored so it faces left): a pistol grip with a red trigger that slides back
## towards the grip as it is squeezed (its return spring squashing as it goes), and the cable out of the
## bottom carrying the current. It shows HOW HARD you are pressing the way your own hand would feel it --
## on purpose there is no scale on it, no number and no mark for "the right amount".
class HandController extends Control:
	const TRAVEL := 32.0                  # px the trigger moves from rest to fully in
	const SCALE := 1.8
	const BODY := Color(0.17, 0.17, 0.19)
	const BODY_EDGE := Color(0.30, 0.30, 0.33)
	const BODY_SHINE := Color(1, 1, 1, 0.10)
	const TRIGGER := Color(0.86, 0.16, 0.12)
	const TRIGGER_SHINE := Color(1.0, 0.45, 0.38)
	const SPRING := Color(0.72, 0.74, 0.78)
	const CABLE := Color(0.07, 0.07, 0.08)
	const CURRENT := Color(0.45, 0.85, 1.0)

	## 0..1, set by the HUD each frame; `_shown` follows it a little softly, as plastic would.
	var squeeze: float = 0.0
	## The pointer is over the trigger (it can be grabbed), or has hold of it.
	var hover: bool = false
	var held: bool = false
	var power: float = 0.0
	var _shown: float = 0.0
	var _t: float = 0.0
	var _rng := RandomNumberGenerator.new()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	## Where the trigger is on screen (the HUD layer's coordinates), with a little extra round it for a
	## finger: the ONLY place a press takes hold of the throttle.
	func grab_rect() -> Rect2:
		var tx := 124.0 - TRAVEL * _shown
		var x0 := size.x - (tx + 22.0) * SCALE
		return Rect2(position + Vector2(x0, 68.0 * SCALE), Vector2(22.0, 66.0) * SCALE).grow(12.0)

	## Where the cable leaves the back of the head, on screen (the drawing is mirrored).
	func cable_exit() -> Vector2:
		return position + Vector2(size.x - 24.0 * SCALE, 52.0 * SCALE)

	## The middle of the trigger, from the controller's corner: what sits under the pointer while the
	## controller follows the mouse.
	func trigger_offset() -> Vector2:
		var r := grab_rect()
		return r.get_center() - position

	func advance(delta: float) -> void:
		_t += delta
		_shown = move_toward(_shown, clampf(squeeze, 0.0, 1.0), 12.0 * delta)
		queue_redraw()

	func _draw() -> void:
		# Mirrored: the drawing below faces right; this flips it to face left, scaled up.
		draw_set_transform(Vector2(size.x, 0.0), 0.0, Vector2(-SCALE, SCALE))
		var shadow := Vector2(-5, 6)      # (mirrored: this lands down and to the right on screen)
		var grip := PackedVector2Array([Vector2(46, 66), Vector2(92, 66), Vector2(86, 176), Vector2(54, 176)])
		var head := Rect2(20, 20, 122, 54)
		# Shadows.
		_box(head, Color(0, 0, 0, 0.35), shadow, 14)
		draw_colored_polygon(_shift(grip, shadow), Color(0, 0, 0, 0.35))
		draw_circle(Vector2(70, 176) + shadow, 18.0, Color(0, 0, 0, 0.35))
		# The grip.
		draw_colored_polygon(grip, BODY)
		draw_circle(Vector2(70, 176), 18.0, BODY)
		for gy in [100.0, 118.0, 136.0, 154.0]:
			draw_line(Vector2(58, gy), Vector2(84, gy), Color(0, 0, 0, 0.35), 3.0)
		# The trigger, in front of the grip: out past the nose at rest, against the grip when fully in.
		var tx := 124.0 - TRAVEL * _shown
		var coils := 6
		var pts := PackedVector2Array()
		for i in coils * 2 + 1:
			var x := lerpf(tx, 90.0, float(i) / float(coils * 2))
			pts.append(Vector2(x, 100.0 + (5.0 if i % 2 == 0 else -5.0)))
		if tx > 92.0:
			draw_polyline(pts, SPRING, 2.0)
		var trig := Rect2(tx, 68, 22, 66)
		_box(trig, Color(0, 0, 0, 0.3), Vector2(-3, 4), 10)
		if hover or held:
			_box(trig.grow(2.5), Color(1, 1, 1, 0.95 if held else 0.7), Vector2.ZERO, 12)
		_box(trig, TRIGGER, Vector2.ZERO, 10)
		draw_rect(Rect2(tx + 14, 76, 4, 50), Color(TRIGGER_SHINE, 0.55))
		for gy in [88.0, 102.0, 116.0]:
			draw_line(Vector2(tx + 3, gy), Vector2(tx + 12, gy), Color(0, 0, 0, 0.25), 2.0)
		# The head over the top of it all, with a small power lamp.
		_box(head, BODY, Vector2.ZERO, 14)
		_box(Rect2(head.position + Vector2(8, 4), Vector2(head.size.x - 16, 10)), BODY_SHINE, Vector2.ZERO, 5)
		draw_line(Vector2(head.position.x + 12, head.end.y - 1), Vector2(head.end.x - 12, head.end.y - 1),
				BODY_EDGE, 2.0)
		var lamp := Vector2(38, 44)
		draw_circle(lamp, 6.0, Color(0.08, 0.10, 0.08))
		if power > 0.02:
			draw_circle(lamp, 9.0, Color(CURRENT, 0.25 * power))
			draw_circle(lamp, 4.5, Color(0.55, 0.9, 1.0, 0.35 + 0.65 * power))
		# Signs of the electricity in it: a bolt on the grip and -- squeezed hard -- sparks jumping at the
		# trigger's contacts.
		var yellow := Color(1.0, 0.82, 0.15)
		draw_colored_polygon(_bolt(Vector2(70, 128), 1.6), Color(yellow, 0.85))
		if power > 0.45 and _rng.randf() < (power - 0.45) * 1.8:
			for k in 2:
				var at := Vector2(tx + _rng.randf_range(-6.0, 2.0), _rng.randf_range(76.0, 128.0))
				var zig := PackedVector2Array([at])
				for z in 3:
					at += Vector2(_rng.randf_range(-6.0, -1.0), _rng.randf_range(-6.0, 6.0))
					zig.append(at)
				draw_polyline(zig, Color(CURRENT, 0.6), 3.0)
				draw_polyline(zig, Color(0.92, 0.98, 1.0), 1.2)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	## A lightning bolt centred on `c`, `k` times its 26 px height.
	static func _bolt(c: Vector2, k: float) -> PackedVector2Array:
		var pts := [Vector2(3, -13), Vector2(-7, 2), Vector2(-1, 2), Vector2(-5, 13), Vector2(8, -3),
				Vector2(1, -3), Vector2(5, -13)]
		var out := PackedVector2Array()
		for p in pts:
			out.append(c + (p as Vector2) * k)
		return out

	func _box(r: Rect2, c: Color, off: Vector2, radius: int) -> void:
		var sb := StyleBoxFlat.new()
		sb.bg_color = c
		sb.set_corner_radius_all(radius)
		draw_style_box(sb, Rect2(r.position + off, r.size))

	static func _shift(pts: PackedVector2Array, off: Vector2) -> PackedVector2Array:
		var out := PackedVector2Array()
		for p in pts:
			out.append(p + off)
		return out


## The controller's cable: a real rope -- a chain of points under gravity, held at one end by the
## controller wherever it is, plugged in at the other at the bottom centre of the screen -- so it hangs,
## swings when the controller is moved, and lies along the bottom edge when there is slack. The current
## glows in it: brighter, wider and busier the harder the trigger is squeezed.
class HandCable extends Control:
	const POINTS := 30
	const PLUG := Vector2(640, 732)          # just below the bottom edge, in the middle
	const LENGTH := 820.0                    # at rest; a controller further away pulls it taut
	const GRAVITY := 2400.0
	const DAMPING := 0.985
	const ITERATIONS := 18
	const FLOOR := 716.0
	const WIDTH := 10.0
	const CABLE := Color(0.07, 0.07, 0.08)
	const CURRENT := Color(0.45, 0.85, 1.0)

	var power: float = 0.0
	var _pts := PackedVector2Array()
	var _old := PackedVector2Array()
	var _t: float = 0.0
	var _rng := RandomNumberGenerator.new()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func simulate(delta: float, exit: Vector2) -> void:
		_t += delta
		if _pts.is_empty():
			for i in POINTS:
				var p := exit.lerp(PLUG, float(i) / float(POINTS - 1))
				_pts.append(p)
				_old.append(p)
		var dt := clampf(delta, 0.0, 1.0 / 30.0)
		var seg := maxf(LENGTH, exit.distance_to(PLUG) * 1.02) / float(POINTS - 1)
		# Verlet: carry on moving, fall.
		for i in range(1, POINTS - 1):
			var v := (_pts[i] - _old[i]) * DAMPING
			_old[i] = _pts[i]
			_pts[i] += v + Vector2(0, GRAVITY) * dt * dt
		# Hold the ends, keep the links their length, keep it off the bottom of the world.
		for it in ITERATIONS:
			_pts[0] = exit
			_pts[POINTS - 1] = PLUG
			for i in POINTS - 1:
				var d := _pts[i + 1] - _pts[i]
				var l := d.length()
				if l < 0.0001:
					continue
				var fix := d * (1.0 - seg / l) * 0.5
				if i > 0:
					_pts[i] += fix
				else:
					_pts[i + 1] -= fix
					continue
				if i + 1 < POINTS - 1:
					_pts[i + 1] -= fix
				else:
					_pts[i] += fix
			for i in range(1, POINTS - 1):
				if _pts[i].y > FLOOR:
					_pts[i].y = FLOOR
		queue_redraw()

	## The point `u` (0..1) of the way along the cable, by length.
	func _along(u: float) -> Vector2:
		var total := 0.0
		for i in POINTS - 1:
			total += _pts[i].distance_to(_pts[i + 1])
		var want := u * total
		for i in POINTS - 1:
			var l := _pts[i].distance_to(_pts[i + 1])
			if want <= l:
				return _pts[i].lerp(_pts[i + 1], want / maxf(l, 0.0001))
			want -= l
		return _pts[POINTS - 1]

	func _draw() -> void:
		if _pts.size() < 2:
			return
		var p := clampf(power, 0.0, 1.0)
		draw_polyline(_pts, Color(0, 0, 0, 0.25), WIDTH + 4.0)
		if p > 0.02:
			draw_polyline(_pts, Color(CURRENT, 0.10 + 0.40 * p), WIDTH + 22.0 * p)    # the glow round it
		draw_polyline(_pts, CABLE, WIDTH)
		if p <= 0.02:
			return
		# The live core: dark at a touch, white-hot at full.
		draw_polyline(_pts, CURRENT.lerp(Color(0.95, 1.0, 1.0), p).darkened(0.6 * (1.0 - p)), 3.0 + 4.0 * p)
		# Pulses of current running down to the track -- more of them, faster and bigger with power.
		var n := 3 + int(round(6.0 * p))
		for k in n:
			var at := _along(fposmod(_t * (0.35 + 1.2 * p) + float(k) / float(n), 1.0))
			draw_circle(at, 5.0 + 7.0 * p, Color(CURRENT, 0.25 + 0.5 * p))
			draw_circle(at, 2.4 + 3.0 * p, Color(1, 1, 1, 0.4 + 0.6 * p))
		# Near full power the wire crackles.
		if p > 0.6 and _rng.randf() < (p - 0.6) * 2.0:
			var at := _along(_rng.randf())
			var zig := PackedVector2Array([at])
			for z in 3:
				at += Vector2(_rng.randf_range(-12, 12), _rng.randf_range(-12, 12))
				zig.append(at)
			draw_polyline(zig, Color(0.85, 0.95, 1.0, 0.9), 2.0)
