extends Control
## Pick a car and its colour, and set up the rivals. Every car drives exactly the same (`CarCatalog.STATS`),
## so there are no numbers here: the screen is the model, turning, and what it looks like.
##
##   Up / Down     car            Left / Right   colour
##   Enter         next: track    Esc            back to the menu

const ROW_H := 76.0
const LIST := Rect2(24, 88, 296, 552)
const MAIN := Rect2(336, 88, 920, 552)
## The right-hand column of the main panel: colour, then the rivals.
const SIDE_X := 520.0
const MODEL_RECT := Rect2(24, 96, 448, 448)

var _ids := CarCatalog.ids()
var _index: int = 0
var _rows: Array = []
var _swatches: Array = []
var _rival_buttons: Array = []
var _diff_buttons: Array = []
var _name: Label = null
var _desc: Label = null
var _colour_name: Label = null
var _model: CarModel3D = null
var _model_rect: TextureRect = null
var _spin: float = 0.6


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_index = maxi(Array(_ids).find(GameState.selected_car), 0)
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	BackgroundArt.add(self, "res://art/bg_garage.png", 0.45)
	var head := UiTheme.panel("Header")
	head.size = Vector2(1280, 72)
	add_child(head)
	var title := UiTheme.label("Title", "SELECT CAR", UiTheme.TITLE, UiTheme.ACCENT)
	title.position = Vector2(24, 12)
	title.size = Vector2(600, 48)
	add_child(title)
	var note := UiTheme.label("Note", "Every car drives the same -- pick the one you like", UiTheme.BODY, UiTheme.MUTED)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	note.position = Vector2(656, 12)
	note.size = Vector2(600, 48)
	add_child(note)
	_build_list()
	_build_main()
	_build_side()
	var back := UiTheme.button("MenuButton", "Menu", UiTheme.HEADING)
	back.position = Vector2(16, 656)
	back.size = Vector2(200, 52)
	back.pressed.connect(func() -> void: _leave(false))
	add_child(back)
	var next := UiTheme.button("NextButton", "NEXT:  TRACK  >", UiTheme.HEADING)
	next.position = Vector2(1016, 656)
	next.size = Vector2(248, 52)
	next.pressed.connect(func() -> void: _leave(true))
	add_child(next)
	next.grab_focus.call_deferred()
	_select(_index, false)


func _build_list() -> void:
	var panel := UiTheme.panel("CarList")
	panel.position = LIST.position
	panel.size = LIST.size
	add_child(panel)
	for i in _ids.size():
		var id := String(_ids[i])
		var c := CarCatalog.get_car(id)
		var row := Button.new()
		row.name = "Car_%s" % id
		row.flat = false           # a flat button draws no stylebox -- and the selection IS the stylebox
		row.focus_mode = Control.FOCUS_NONE
		row.position = LIST.position + Vector2(8, 8 + ROW_H * i)
		row.size = Vector2(LIST.size.x - 16, ROW_H - 8)
		row.pressed.connect(_select.bind(i, true))
		add_child(row)
		var chip := ColorRect.new()
		chip.color = c["body"]
		chip.position = Vector2(10, 14)
		chip.size = Vector2(8, ROW_H - 36)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(chip)
		var n := UiTheme.label("Name", String(c["name"]), UiTheme.HEADING)
		n.position = Vector2(30, 0)
		n.size = Vector2(240, ROW_H - 8)
		row.add_child(n)
		_rows.append(row)


func _build_main() -> void:
	var panel := UiTheme.panel("Main")
	panel.position = MAIN.position
	panel.size = MAIN.size
	add_child(panel)
	_name = _lbl("CarName", "", UiTheme.TITLE, Rect2(24, 8, 470, 48))
	_desc = _lbl("Description", "", UiTheme.BODY, Rect2(24, 56, 470, 28), UiTheme.MUTED)
	if DisplayServer.get_name() != "headless":
		_model = CarModel3D.new()
		_model.name = "Turntable"
		_model.priority = true
		_model.set_view(60.0, int(MODEL_RECT.size.x), 40.0)
		add_child(_model)
		_model_rect = TextureRect.new()
		_model_rect.name = "ModelView"
		_model_rect.texture = _model.get_texture()
		_model_rect.position = MAIN.position + MODEL_RECT.position
		_model_rect.size = MODEL_RECT.size
		_model_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_model_rect)


func _build_side() -> void:
	_lbl("ColourCaption", "COLOUR", UiTheme.CAPTION, Rect2(SIDE_X, 24, 200, 24), UiTheme.MUTED)
	for i in CarCatalog.PALETTE_SIZE:
		var sw := Button.new()
		sw.name = "Swatch%d" % i
		sw.focus_mode = Control.FOCUS_NONE
		sw.position = MAIN.position + Vector2(SIDE_X + 64 * i, 50)
		sw.size = Vector2(52, 48)
		sw.pressed.connect(_set_colour.bind(i))
		add_child(sw)
		_swatches.append(sw)
	_colour_name = _lbl("ColourName", "", UiTheme.BODY, Rect2(SIDE_X, 104, 384, 28))

	_lbl("RivalsCaption", "RIVALS", UiTheme.CAPTION, Rect2(SIDE_X, 176, 200, 24), UiTheme.MUTED)
	for n in GameState.MAX_RIVALS + 1:
		var b := _toggle("Rivals%d" % n, str(n), MAIN.position + Vector2(SIDE_X + 96 * n, 202), Vector2(88, 52))
		b.pressed.connect(func() -> void:
			GameState.rivals = n
			_refresh_toggles())
		_rival_buttons.append(b)
	_lbl("DifficultyCaption", "RIVALS DRIVE", UiTheme.CAPTION, Rect2(SIDE_X, 280, 200, 24), UiTheme.MUTED)
	for i in GameState.DIFFICULTIES.size():
		var d: String = GameState.DIFFICULTIES[i]
		var b := _toggle("Diff_%s" % d, d.capitalize(), MAIN.position + Vector2(SIDE_X + 128 * i, 306), Vector2(120, 52))
		b.pressed.connect(func() -> void:
			GameState.difficulty = d
			_refresh_toggles())
		_diff_buttons.append(b)
	_refresh_toggles()


func _toggle(node_name: String, text: String, at: Vector2, size_: Vector2) -> Button:
	var b := UiTheme.button(node_name, text, UiTheme.BODY)
	b.focus_mode = Control.FOCUS_NONE
	b.position = at
	b.size = size_
	add_child(b)
	return b


func _refresh_toggles() -> void:
	for n in _rival_buttons.size():
		_mark(_rival_buttons[n], n == GameState.rivals)
	for i in _diff_buttons.size():
		_mark(_diff_buttons[i], GameState.DIFFICULTIES[i] == GameState.difficulty)


static func _mark(b: Button, on: bool) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(1, 1, 1, 0.22) if on else Color(0, 0, 0, 0.62)
	box.border_color = UiTheme.ACCENT if on else Color(1, 1, 1, 0.1)
	box.set_border_width_all(2)
	box.set_corner_radius_all(4)
	b.add_theme_stylebox_override("normal", box)


func _lbl(node_name: String, text: String, size_: int, r: Rect2, color := UiTheme.TEXT) -> Label:
	var l := UiTheme.label(node_name, text, size_, color)
	l.position = MAIN.position + r.position
	l.size = r.size
	add_child(l)
	return l


func _select(i: int, rev: bool) -> void:
	_index = posmod(i, _ids.size())
	var id := String(_ids[_index])
	if GameState.selected_car != id:
		GameState.selected_colour = 0
	GameState.selected_car = id
	var c := CarCatalog.get_car(id)
	for k in _rows.size():
		UiTheme.style_row(_rows[k] as Button, k == _index)
	_name.text = String(c["name"])
	_desc.text = String(c["description"])
	if rev:
		Audio.rev(id)
	_set_colour(GameState.selected_colour)


func _set_colour(i: int) -> void:
	GameState.selected_colour = posmod(i, CarCatalog.PALETTE_SIZE)
	var id := GameState.selected_car
	var col := CarCatalog.body_color(id, GameState.selected_colour)
	for k in _swatches.size():
		var box := StyleBoxFlat.new()
		box.bg_color = CarCatalog.body_color(id, k)
		box.border_color = Color.WHITE if k == GameState.selected_colour else Color(0, 0, 0, 0.5)
		box.set_border_width_all(3 if k == GameState.selected_colour else 1)
		box.set_corner_radius_all(4)
		for st in ["normal", "hover", "pressed"]:
			(_swatches[k] as Button).add_theme_stylebox_override(st, box)
	_colour_name.text = CarCatalog.color_name(id, GameState.selected_colour)
	_name.add_theme_color_override("font_color", col.lightened(0.25))
	if _model != null:
		_model.build(String(CarCatalog.get_car(id)["style"]), col, CarCatalog.get_car(id)["stripe"])


func _process(delta: float) -> void:
	_spin += delta * 0.7
	if _model != null:
		_model.pose(_spin, 0.0, 0.0, 0.0, 0.0, PackedFloat32Array([0, 0, 0, 0]), delta * 120.0, 0.0)


func _leave(forward: bool) -> void:
	GameState.save_settings()
	if forward:
		GameState.go_to_track_select()
	else:
		GameState.go_to_menu()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	match (event as InputEventKey).physical_keycode:
		KEY_UP, KEY_W:
			_select(_index - 1, true)
		KEY_DOWN, KEY_S:
			_select(_index + 1, true)
		KEY_LEFT, KEY_A:
			_set_colour(GameState.selected_colour - 1)
		KEY_RIGHT, KEY_D:
			_set_colour(GameState.selected_colour + 1)
		KEY_ESCAPE:
			_leave(false)
		_:
			return
	get_viewport().set_input_as_handled()
