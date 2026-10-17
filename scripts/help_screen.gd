extends Control
## How to play: four cards, each a picture from the real game (tools/make_help_art.gd) and a few lines.

const CARDS := [
	["res://art/help/trigger.png", "1  SQUEEZE THE TRIGGER",
		"Grab the red trigger with the mouse and drag: right for more power, left for less. Let go and the motor brakes. Or just hold SPACE. The cable glows brighter the harder you squeeze."],
	["res://art/help/tail.png", "2  WATCH THE TAIL",
		"You never steer: the car follows its slot. Near a bend's limit the tail swings out -- that is your warning. Ease off BEFORE the bend, power on as it opens."],
	["res://art/help/off.png", "3  DON'T COME OFF",
		"Too fast and the car slides, smokes and flies off the track. The marshal puts it back where it left -- two seconds you never get back."],
	["res://art/help/lanes.png", "4  PICK YOUR LANE",
		"Four lanes, one car each. Inside: shorter, but tighter bends. Outside: longer, but faster through the bends. On the Figure 8 they all cross."],
]
const KEYS := "Move the mouse to move the controller out of the way     Esc / P  pause     Z / wheel  camera     R  restart"
const CARD_SIZE := Vector2(608, 272)
const PICTURE := Vector2(352, 242)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	BackgroundArt.add(self, "res://art/menu_bg.png", 0.3)
	var title := UiTheme.label("Title", "HOW TO PLAY", UiTheme.TITLE, UiTheme.ACCENT)
	title.position = Vector2(24, 12)
	title.size = Vector2(600, 48)
	add_child(title)
	for i in CARDS.size():
		var at := Vector2(24.0 + (CARD_SIZE.x + 16.0) * (i % 2), 80.0 + (CARD_SIZE.y + 16.0) * (i / 2))
		_card(i, at)
	var keys := UiTheme.label("Keys", KEYS, UiTheme.CAPTION, UiTheme.MUTED)
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	keys.position = Vector2(232, 668)
	keys.size = Vector2(1024, 28)
	add_child(keys)
	var back := UiTheme.button("BackButton", "Back", UiTheme.HEADING)
	back.position = Vector2(16, 656)
	back.size = Vector2(200, 52)
	back.pressed.connect(func() -> void: GameState.go_to_menu())
	add_child(back)
	back.grab_focus.call_deferred()


func _card(i: int, at: Vector2) -> void:
	var spec: Array = CARDS[i]
	var panel := UiTheme.panel("Card%d" % i)
	panel.position = at
	panel.size = CARD_SIZE
	add_child(panel)
	var pic := TextureRect.new()
	pic.name = "Picture%d" % i
	if ResourceLoader.exists(String(spec[0])):
		pic.texture = load(String(spec[0]))
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	pic.position = at + Vector2(14, 15)
	pic.size = PICTURE
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(pic)
	var frame := ReferenceRect.new()
	frame.border_color = Color(1, 1, 1, 0.25)
	frame.editor_only = false
	frame.position = pic.position
	frame.size = PICTURE
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frame)
	var x := at.x + 14.0 + PICTURE.x + 16.0
	var w := CARD_SIZE.x - (x - at.x) - 14.0
	var head := UiTheme.label("Heading%d" % i, String(spec[1]), UiTheme.BODY, UiTheme.ACCENT)
	head.position = Vector2(x, at.y + 12)
	head.size = Vector2(w, 28)
	add_child(head)
	var body := UiTheme.label("Body%d" % i, String(spec[2]), UiTheme.CAPTION, UiTheme.TEXT)
	# Wrap first, then size: a label sized before it wraps keeps the width of its one long line.
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	body.position = Vector2(x, at.y + 46)
	body.size = Vector2(w, CARD_SIZE.y - 58)
	add_child(body)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		GameState.go_to_menu()
