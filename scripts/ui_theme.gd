class_name UiTheme
extends RefCounted
## One type scale and one palette for every screen (SPEC 62).
##
## The car screen had eight font sizes, four blocks of prose and three columns competing for the eye;
## you cannot read a screen like that at a glance, and a menu is read at a glance or not at all. The
## rules here are deliberately few:
##
##   * **Four sizes, never five.** TITLE for the screen's name, HEADING for the thing you are choosing,
##     BODY for anything you have to read, CAPTION for labels on top of values.
##   * **Two text colours.** TEXT for what matters, MUTED for the label that tells you what it is.
##     ACCENT (gold) is money and prices; WARN is a real cost; the car's own colour is the only other
##     colour on screen.
##   * **An 8 px grid.** Every rect's position and size is a multiple of GRID, which is what stops two
##     panels ending up 3 px apart or overlapping by 4.
##   * **One line per idea.** A paragraph on a menu is a paragraph nobody reads.
##
## Pure constants and two builders; no scene tree state.

## SPEC 63: bigger. The first scale was set for a desktop monitor at arm's length; the game is played on
## laptops and phones, where 15 px body text is a squint.
const TITLE := 34
const HEADING := 24
const BODY := 18
const CAPTION := 16          # SPEC 97: 14 was a squint on a phone

const TEXT := Color(0.94, 0.95, 0.96)
const MUTED := Color(0.68, 0.72, 0.76)
const ACCENT := Color(1.0, 0.84, 0.30)          # coins, prices
const WARN := Color(0.95, 0.56, 0.36)           # what a part costs you
const PANEL := Color(0.0, 0.0, 0.0, 0.55)
const PANEL_EDGE := Color(1, 1, 1, 0.07)
const ROW_SELECTED := Color(1, 1, 1, 0.14)
const ROW_HOVER := Color(1, 1, 1, 0.06)
const BAR_TRACK := Color(1, 1, 1, 0.12)

const GRID := 8.0
const OUTLINE := 4
## SPEC 120: ONE MARGIN. Every button is inset from the edge of its screen or panel by this, every
## button's own text is inset from its edge by `BUTTON_PAD_X` / `BUTTON_PAD_Y`, and no button is ever
## shorter than `BUTTON_H` -- which is also a thumb's worth on a phone. Screens used to pick 16, 20,
## 24 or 40 px each, and two buttons on the same screen sat at two different distances from the wall.
const MARGIN := 16.0
const BUTTON_PAD_X := 16.0
const BUTTON_PAD_Y := 8.0
const BUTTON_H := 48.0


## The nearest size on the scale. Screens built before SPEC 62 call their label helpers with whatever
## number looked right at the time (34, 22, 20, 19, 18, 16, 15...); snapping inside those helpers pulls
## a whole screen onto the scale without touching fifty call sites.
static func snap_size(size: int) -> int:
	if size >= 28:
		return TITLE
	if size >= 20:
		return HEADING
	if size >= 16:
		return BODY
	return CAPTION


## Snaps a rect to the 8 px grid, so nothing lands 3 px from anything else.
static func snap(r: Rect2) -> Rect2:
	return Rect2((r.position / GRID).round() * GRID, (r.size / GRID).round() * GRID)


## A label built to the scale: `size` is one of the four constants above.
static func label(node_name: String, text: String, size: int, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", OUTLINE if size >= BODY else 3)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


## The four states of a plain menu button, explicitly: the engine default leaves `hover` almost
## transparent, which over the menu's background art reads as the button vanishing under the cursor.
static func style_button(b: Button, accent: Color = ACCENT) -> void:
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var box := StyleBoxFlat.new()
		match state:
			"hover":
				box.bg_color = Color(1, 1, 1, 0.18)
			"pressed":
				box.bg_color = Color(0, 0, 0, 0.75)
			"disabled":
				box.bg_color = Color(0, 0, 0, 0.45)
			_:
				box.bg_color = Color(0, 0, 0, 0.62)
		if state == "focus" or state == "hover":
			box.border_color = accent if state == "focus" else Color(1, 1, 1, 0.55)
			box.set_border_width_all(2)
		box.set_corner_radius_all(4)
		box.content_margin_left = BUTTON_PAD_X
		box.content_margin_right = BUTTON_PAD_X
		box.content_margin_top = BUTTON_PAD_Y
		box.content_margin_bottom = BUTTON_PAD_Y
		b.add_theme_stylebox_override(state, box)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", MUTED)


## SPEC 120: A BUTTON, built the one way: the shared style, the shared padding, and never shorter than
## a thumb. Every screen that makes a button should come through here -- `style_button` is what this
## calls, and is for a Button that something else has already built.
static func button(node_name: String, text: String, size: int = BODY, accent: Color = ACCENT) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.add_theme_font_size_override("font_size", snap_size(size))
	b.custom_minimum_size = Vector2(0.0, BUTTON_H)
	b.focus_mode = Control.FOCUS_ALL
	style_button(b, accent)
	return b


## A panel: the same flat, quiet box everywhere.
static func panel(node_name: String) -> ColorRect:
	var p := ColorRect.new()
	p.name = node_name
	p.color = PANEL
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


# ---------------------------------------------------------------- SPEC 128: modal focus

## WHERE THE KEYBOARD IS WHEN A CARD OPENS, AND WHERE IT GOES BACK TO. A card that covers the screen and
## takes no focus leaves the keyboard on whatever is underneath it: Tab walks through buttons the player
## cannot see and Enter presses one of them. Both of the game's cards -- the feedback card and What's
## new -- did exactly that, and both are read-and-dismiss, which is the one shape a keyboard user has no
## other way through.
##
## `take_focus` is called when the card opens and returns what had the keyboard before, so `give_focus`
## can put it back when the card closes. Nothing here changes what a POINTER does: the game is played
## with one pointer (it is a phone game), and this is the keyboard catching up.
static func take_focus(first: Control) -> Control:
	if first == null or not is_instance_valid(first):
		return null
	var had: Control = first.get_viewport().gui_get_focus_owner() if first.is_inside_tree() else null
	first.focus_mode = Control.FOCUS_ALL
	first.grab_focus()
	return had


## Puts the keyboard back where it was before a card took it. A control that has gone away since is
## simply dropped -- the screen underneath may have been rebuilt while the card was up.
static func give_focus(back: Control) -> void:
	if back != null and is_instance_valid(back) and back.is_inside_tree() \
			and back.focus_mode != Control.FOCUS_NONE:
		back.grab_focus()


## Makes `controls` a keyboard path in the order given, wrapping at both ends -- so Tab walks the screen
## in the order a player reads it instead of the order the code happened to build it.
static func focus_chain(controls: Array) -> void:
	var live: Array = []
	for c in controls:
		var ctl := c as Control
		if ctl != null and is_instance_valid(ctl):
			ctl.focus_mode = Control.FOCUS_ALL
			live.append(ctl)
	for i in live.size():
		var here := live[i] as Control
		var next := live[(i + 1) % live.size()] as Control
		var prev := live[posmod(i - 1, live.size())] as Control
		here.focus_next = here.get_path_to(next)
		here.focus_neighbor_bottom = here.focus_next
		here.focus_previous = here.get_path_to(prev)
		here.focus_neighbor_top = here.focus_previous


## A row in a pick list (a car, a track). The chosen one has to be unmistakable at a glance: a lit
## background and a gold frame; the others are bare until the pointer is over them.
static func style_row(b: Button, selected: bool) -> void:
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var box := StyleBoxFlat.new()
		box.set_corner_radius_all(6)
		if selected:
			box.bg_color = Color(1, 1, 1, 0.16)
			box.border_color = ACCENT
			box.set_border_width_all(3)
		elif state == "hover" or state == "pressed":
			box.bg_color = ROW_HOVER
			box.border_color = Color(1, 1, 1, 0.25)
			box.set_border_width_all(1)
		else:
			box.bg_color = Color(0, 0, 0, 0)
		b.add_theme_stylebox_override(state, box)
