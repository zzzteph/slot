extends Control
## The title screen: Rope Racers' key art and title band, with slot cars running along two slots across
## the band behind the name. Built in code.

const BG_COLOR := Color(0.13, 0.32, 0.14)
const TITLE_COLOR := Color(1.0, 0.92, 0.3)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.color = BG_COLOR
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	BackgroundArt.add(self, "res://art/menu_bg.png", 0.5)

	var stripe := ColorRect.new()
	stripe.name = "Stripe"
	stripe.color = Color(0.13, 0.13, 0.15, 0.85)
	stripe.position = Vector2(0, 64)
	stripe.size = Vector2(1280, 136)
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(stripe)

	var slots := MenuSlots.new()
	slots.name = "Slots"
	add_child(slots)

	var title := UiTheme.label("Title", "SLOT", 96, TITLE_COLOR)
	title.add_theme_color_override("font_outline_color", Color.BLACK)
	title.add_theme_constant_override("outline_size", 10)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.position = Vector2(0, 64)
	title.size = Vector2(1280, 136)
	add_child(title)

	var tag := UiTheme.label("Tagline", "One trigger. Four lanes. Don't come off.", UiTheme.BODY, UiTheme.TEXT)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.position = Vector2(0, 208)
	tag.size = Vector2(1280, 32)
	add_child(tag)

	var buttons := VBoxContainer.new()
	buttons.name = "Buttons"
	buttons.add_theme_constant_override("separation", 14)
	buttons.position = Vector2(490, 264)
	buttons.size = Vector2(300, 300)
	add_child(buttons)
	var race_btn := _button("RaceButton", "Race")
	race_btn.pressed.connect(func() -> void: GameState.go_to_car_select())
	buttons.add_child(race_btn)
	var help_btn := _button("HelpButton", "How to play")
	help_btn.pressed.connect(func() -> void: GameState.go_to_help())
	buttons.add_child(help_btn)
	var set_btn := _button("SettingsButton", "Settings")
	set_btn.pressed.connect(func() -> void: GameState.go_to_settings())
	buttons.add_child(set_btn)
	var quit_btn := _button("QuitButton", "Quit")
	quit_btn.pressed.connect(func() -> void: GameState.quit_game())
	quit_btn.visible = not (OS.has_feature("mobile") or OS.has_feature("web"))
	buttons.add_child(quit_btn)
	UiTheme.focus_chain([race_btn, help_btn, set_btn, quit_btn])
	race_btn.grab_focus.call_deferred()

	var build := UiTheme.label("BuildLabel", "v%s" % ProjectSettings.get_setting("application/config/version", "?"),
			UiTheme.CAPTION, UiTheme.MUTED)
	build.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	build.position = Vector2(880, 680)
	build.size = Vector2(384, 28)
	add_child(build)


func _button(node_name: String, text: String) -> Button:
	var b := UiTheme.button(node_name, text, UiTheme.TITLE)
	b.custom_minimum_size = Vector2(300, 56)
	return b


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		GameState.quit_game()


## Two slots across the title band and four cars running in them, left to right. Decoration: the cars
## are posed directly, never simulated.
class MenuSlots extends Node2D:
	const LANES := [98.0, 166.0]
	const SPEEDS := [520.0, 380.0]
	const PER_LANE := 2
	const SPAN := 1280.0 + 160.0

	var _cars: Array = []      # [{car, lane, x}]

	func _ready() -> void:
		var ids := CarCatalog.ids()
		var k := 0
		for lane in LANES.size():
			for i in PER_LANE:
				var c := SlotCar.new()
				c.interpolate = false          # posed by hand below, never simulated
				c.configure(ids[k % ids.size()], 0)
				k += 1
				add_child(c)
				_cars.append({"car": c, "lane": lane, "x": -80.0 + SPAN * (float(i) / PER_LANE + 0.25 * lane)})

	func _process(delta: float) -> void:
		for e in _cars:
			var c: SlotCar = e["car"]
			var x := fposmod(float(e["x"]) + float(SPEEDS[e["lane"]]) * delta + 80.0, SPAN) - 80.0
			e["x"] = x
			c.position = Vector2(x, float(LANES[e["lane"]]))
			c.heading = 0.0
			c.speed = SPEEDS[e["lane"]]
			c._request_redraw()

	func _draw() -> void:
		for y in LANES:
			draw_rect(Rect2(0, y - 22.0, 1280, 44), Color(0.19, 0.19, 0.21, 0.9))
			draw_line(Vector2(0, y - SlotTrack.RAIL_OFFSET), Vector2(1280, y - SlotTrack.RAIL_OFFSET), SlotTrack.RAIL, 2.0)
			draw_line(Vector2(0, y + SlotTrack.RAIL_OFFSET), Vector2(1280, y + SlotTrack.RAIL_OFFSET), SlotTrack.RAIL, 2.0)
			draw_line(Vector2(0, y), Vector2(1280, y), SlotTrack.SLOT, 3.0)
