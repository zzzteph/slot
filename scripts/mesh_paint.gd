class_name MeshPaint
extends RefCounted
## Builds one coloured triangle mesh out of many flat shapes (SPEC 54), so a canvas item that used to
## issue hundreds of `draw_rect` / `draw_polygon` / `draw_circle` calls every frame issues one
## `draw_mesh` instead.
##
## Why: the track was costing ~2280 draw calls a frame (a quad per centerline segment for the road, a
## line per centre dash, a pair of circles per tyre in the tyre walls, a dot per grain of sand) and the
## town another ~411. That is nothing on a desktop GPU and it is the whole frame on a weak one -- the
## game showed 5 fps on an integrated chip. None of it moves during a race, so all of it can be baked
## into meshes once and replayed as a handful of draw calls.
##
## Pure geometry: no scene tree, no engine singletons. `build()` returns null when nothing was added, so
## a caller can keep a plain `if mesh != null` guard.

## The arrays are grown in doublings and written by index, never appended to: a full skid-mark buffer is
## 1600 segments, i.e. ~9600 vertices in one rebuild, and per-append reallocation turned that into a
## 44 ms frame (the perf pin is 16.6). Written this way it is a fraction of a millisecond.
var _verts := PackedVector3Array()
var _colors := PackedColorArray()
var _n: int = 0


## Room for `triangles` more triangles, so a caller that knows its size pays for one allocation.
func reserve(triangles: int) -> void:
	_grow(_n + triangles * 3)


func _grow(want: int) -> void:
	if want <= _verts.size():
		return
	var size := maxi(64, _verts.size())
	while size < want:
		size *= 2
	_verts.resize(size)
	_colors.resize(size)


func add_triangle(a: Vector2, b: Vector2, c: Vector2, color: Color) -> void:
	_grow(_n + 3)
	_verts[_n] = Vector3(a.x, a.y, 0.0)
	_verts[_n + 1] = Vector3(b.x, b.y, 0.0)
	_verts[_n + 2] = Vector3(c.x, c.y, 0.0)
	_colors[_n] = color
	_colors[_n + 1] = color
	_colors[_n + 2] = color
	_n += 3


## A quad given in order (any convex four points): two triangles.
func add_quad(a: Vector2, b: Vector2, c: Vector2, d: Vector2, color: Color) -> void:
	add_triangle(a, b, c, color)
	add_triangle(a, c, d, color)


func add_rect(r: Rect2, color: Color) -> void:
	add_quad(r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y), color)


## An unfilled rectangle of `width` px, drawn inward from the edges.
func add_rect_outline(r: Rect2, color: Color, width: float = 1.0) -> void:
	add_rect(Rect2(r.position, Vector2(r.size.x, width)), color)
	add_rect(Rect2(Vector2(r.position.x, r.end.y - width), Vector2(r.size.x, width)), color)
	add_rect(Rect2(Vector2(r.position.x, r.position.y + width), Vector2(width, r.size.y - width * 2.0)), color)
	add_rect(Rect2(Vector2(r.end.x - width, r.position.y + width), Vector2(width, r.size.y - width * 2.0)), color)


func add_circle(center: Vector2, radius: float, color: Color, segments: int = 10) -> void:
	var prev := center + Vector2(radius, 0.0)
	for i in range(1, segments + 1):
		var a := TAU * float(i) / float(segments)
		var p := center + Vector2.from_angle(a) * radius
		add_triangle(center, prev, p, color)
		prev = p


## A thick line from `a` to `b` (square ends), as one quad.
func add_line(a: Vector2, b: Vector2, width: float, color: Color) -> void:
	var d := b - a
	if d.length_squared() < 0.0001:
		return
	var n := Vector2(-d.y, d.x).normalized() * width * 0.5
	add_quad(a + n, b + n, b - n, a - n, color)


## A band of `half_width` either side of a polyline: the road, its white edging, a kerb.
func add_strip(points: PackedVector2Array, normals: PackedVector2Array, closed: bool, half_width: float,
		color: Color, offset: Vector2 = Vector2.ZERO) -> void:
	var n := points.size()
	if n < 2 or normals.size() != n:
		return
	var segs := n if closed else n - 1
	for i in segs:
		var j := (i + 1) % n
		add_quad(points[i] + normals[i] * half_width + offset,
				points[j] + normals[j] * half_width + offset,
				points[j] - normals[j] * half_width + offset,
				points[i] - normals[i] * half_width + offset, color)


## A ring of `width` px centred on `radius` -- what `draw_arc` over a full turn used to paint.
func add_ring(center: Vector2, radius: float, width: float, color: Color, segments: int = 10) -> void:
	var outer := radius + width * 0.5
	var inner := maxf(radius - width * 0.5, 0.0)
	var prev_a := 0.0
	for i in range(1, segments + 1):
		var ang := TAU * float(i) / float(segments)
		add_quad(center + Vector2.from_angle(prev_a) * outer, center + Vector2.from_angle(ang) * outer,
				center + Vector2.from_angle(ang) * inner, center + Vector2.from_angle(prev_a) * inner, color)
		prev_a = ang


## A convex polygon, as a fan from its first point.
func add_polygon(points: PackedVector2Array, color: Color) -> void:
	if points.size() < 3:
		return
	for i in range(1, points.size() - 1):
		add_triangle(points[0], points[i], points[i + 1], color)


## A star-shaped polygon (every point visible from `center`: a jagged hole, an oil blob), as a fan from
## that centre -- a fan from the first point would fold over itself where the outline dips in.
func add_fan(center: Vector2, points: PackedVector2Array, color: Color) -> void:
	var n := points.size()
	if n < 3:
		return
	for i in n:
		add_triangle(center, points[i], points[(i + 1) % n], color)


## An ellipse with semi-axes `rx` / `ry`, turned by `angle` -- what `draw_circle` under a rotated,
## stretched `draw_set_transform` painted.
func add_ellipse(center: Vector2, rx: float, ry: float, angle: float, color: Color, segments: int = 10) -> void:
	var prev := center + Vector2(rx, 0.0).rotated(angle)
	for i in range(1, segments + 1):
		var a := TAU * float(i) / float(segments)
		var p := center + Vector2(cos(a) * rx, sin(a) * ry).rotated(angle)
		add_triangle(center, prev, p, color)
		prev = p


## A rectangle rotated about its own centre: a car part lying on the road at an angle.
func add_rotated_rect(center: Vector2, size: Vector2, angle: float, color: Color) -> void:
	var h := size * 0.5
	add_quad(center + Vector2(-h.x, -h.y).rotated(angle), center + Vector2(h.x, -h.y).rotated(angle),
			center + Vector2(h.x, h.y).rotated(angle), center + Vector2(-h.x, h.y).rotated(angle), color)


## The outline of a rotated rectangle, `width` px thick, drawn inward.
func add_rotated_rect_outline(center: Vector2, size: Vector2, angle: float, color: Color,
		width: float = 1.0) -> void:
	var h := size * 0.5
	var a := center + Vector2(-h.x, -h.y).rotated(angle)
	var b := center + Vector2(h.x, -h.y).rotated(angle)
	var c := center + Vector2(h.x, h.y).rotated(angle)
	var d := center + Vector2(-h.x, h.y).rotated(angle)
	add_line(a, b, width, color)
	add_line(b, c, width, color)
	add_line(c, d, width, color)
	add_line(d, a, width, color)


func is_empty() -> bool:
	return _n == 0


func vertex_count() -> int:
	return _n


## Forgets everything added so far but KEEPS the capacity, so a painter that is rebuilt every frame (a
## particle layer, the moving props) never reallocates once it has seen its biggest frame.
func reset() -> void:
	_n = 0


func _arrays() -> Array:
	# Trimmed to what was actually written: the spare capacity must not reach the mesh.
	var verts := _verts
	var colors := _colors
	if _n != _verts.size():
		verts = _verts.slice(0, _n)
		colors = _colors.slice(0, _n)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	return arrays


## One ArrayMesh with everything added so far, or null if nothing was.
func build() -> ArrayMesh:
	if _n == 0:
		return null
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays())
	return mesh


## Replaces the surface of an existing mesh with everything added so far (nothing, if nothing was), and
## says whether there is anything to draw. A mesh reused this way costs one buffer upload per rebuild
## instead of a new RenderingServer object (and the freeing of the old one) every time.
func build_into(mesh: ArrayMesh) -> bool:
	mesh.clear_surfaces()
	if _n == 0:
		return false
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays())
	return true
