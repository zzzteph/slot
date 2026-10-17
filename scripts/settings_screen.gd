extends Control
## Settings: one thing, done big -- full screen, on or off. (The volumes keep their defaults.)

var _on: Button = null
var _off: Button = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	BackgroundArt.add(self, "res://art/menu_bg.png", 0.35)
	var title := UiTheme.label("Title", "SETTINGS", UiTheme.TITLE, UiTheme.ACCENT)
	title.position = Vector2(24, 12)
	title.size = Vector2(600, 48)
	add_child(title)
	var panel := UiTheme.panel("Panel")
	panel.position = Vector2(240, 200)
	panel.size = Vector2(800, 240)
	add_child(panel)
	var caption := UiTheme.label("Caption", "FULL SCREEN", UiTheme.TITLE, UiTheme.TEXT)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.position = Vector2(240, 224)
	caption.size = Vector2(800, 56)
	add_child(caption)
	_on = _choice("FullscreenOn", "ON", 440.0, true)
	_off = _choice("FullscreenOff", "OFF", 648.0, false)
	if OS.has_feature("web"):
		_on.disabled = true
		_off.disabled = true
		caption.text = "FULL SCREEN  (use the browser's)"
	var back := UiTheme.button("BackButton", "Back", UiTheme.HEADING)
	back.position = Vector2(16, 656)
	back.size = Vector2(200, 52)
	back.pressed.connect(func() -> void: GameState.go_to_menu())
	add_child(back)
	UiTheme.focus_chain([_on, _off, back])
	(_on if bool(GameState.get_setting("fullscreen")) else _off).grab_focus.call_deferred()
	_refresh()


## One of the two big choices; the chosen one is lit and framed in gold.
func _choice(node_name: String, text: String, x: float, value: bool) -> Button:
	var b := UiTheme.button(node_name, text, UiTheme.TITLE)
	b.position = Vector2(x, 304)
	b.size = Vector2(192, 96)
	b.pressed.connect(func() -> void:
		GameState.set_setting("fullscreen", value)
		_refresh())
	add_child(b)
	return b


func _refresh() -> void:
	var on := bool(GameState.get_setting("fullscreen"))
	for pair in [[_on, on], [_off, not on]]:
		var b: Button = pair[0]
		if bool(pair[1]):
			UiTheme.style_row(b, true)
			b.add_theme_color_override("font_color", UiTheme.ACCENT)
		else:
			UiTheme.style_button(b)
			b.add_theme_color_override("font_color", UiTheme.MUTED)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		GameState.go_to_menu()
