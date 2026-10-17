class_name BackgroundArt
extends RefCounted
## The screens' painted backgrounds (rendered by tools/render_art.gd into res://art/): a full-screen
## picture, covered (cropped to fill, never stretched) and dimmed so the screen's panels read over it.
##
##   menu_bg.png    title menu        bg_garage.png  car select      bg_tracks.png  track select
##   bg_grid.png    multiplayer       bg_wreck.png   settings

## Adds the picture at `path` to `parent` (call it right after the plain background colour, so it sits
## behind everything else). `dim` multiplies its colour: 1.0 = as rendered. Returns null (and the plain
## colour shows) if the picture is missing.
static func add(parent: Control, path: String, dim: float = 1.0) -> TextureRect:
	if not ResourceLoader.exists(path):
		return null
	var art := TextureRect.new()
	art.name = "BackgroundArt"
	art.texture = load(path)
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.modulate = Color(dim, dim, dim * 1.08)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(art)
	return art
