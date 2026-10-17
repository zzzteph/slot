class_name TrackShape
extends RefCounted
## Shared geometry toolkit for authoring track centerlines (SPEC section 15).
##
## A circuit author writes ONE file (`scripts/tracks/<id>.gd`) whose `static func build()` returns a closed
## `PackedVector2Array` of **control points** — the corner vertices of the circuit, in the direction of
## travel, with no duplicated end point. The pipeline every circuit runs is always the same four calls:
##
## [codeblock]
## var pts := TrackShape.smooth_corners(control_points, 150.0)   # 1. round the corners
## pts = TrackShape.fit_to_view(pts, 105.0, 26.0)                # 2. fit 1280x720 incl. half the road
## pts = TrackShape.resample(pts, TrackData.SAMPLE_SPACING)      # 3. ~16 px even spacing
## pts = TrackShape.rotate_start(pts, TrackShape.best_start_index(pts))  # 4. index 0 on a straight
## [/codeblock]
##
## ... and the author then has to make `TrackShape.validate(pts, width)` return `ok == true` before the
## file is considered done (SPEC 15.4).
##
## Everything here is **pure**: static, allocation-light, no scene tree, no randomness, no engine
## singletons, and every division is guarded, so *degenerate* input (empty, one point, duplicated points,
## a spike that doubles back, a collinear or sub-millipixel loop) returns something finite rather than NaN.
## A control point that is **itself** NaN or INF is a different matter: it is rejected, not absorbed —
## `smooth_corners_varied()`, `resample()` and `fit_to_view()` drop non-finite points on entry
## (`_finite_only()`), and `validate()` reports "point N is not finite" if one somehow reaches it.
## Nothing in this file may reference `GameState` (SPEC decision 10): it is used from `--script` test runs.

const SCREEN := Vector2(1280, 720)
## Target arc-length spacing of the finished centerline. Mirrors `TrackData.SAMPLE_SPACING`; duplicated
## rather than imported so this file has no dependencies at all.
const DEFAULT_SPACING := 16.0
## Arc length over which a local radius is measured. Three points 48 px apart give the exact radius on a
## circular arc and are far enough apart not to amplify the ~16 px sampling noise on a straight.
const RADIUS_WINDOW := 48.0
## Local radius above which the centerline counts as "straight" for `longest_straight` / `count_corners`.
const STRAIGHT_RADIUS := 420.0
## Local radius below which the centerline counts as "in a corner" for `count_corners`.
const CORNER_RADIUS := 350.0
## Default acceptance thresholds of `validate()` (override per circuit through its `opts` dictionary).
const MIN_CORNER_RADIUS := 125.0
const MIN_SCREEN_MARGIN := 22.0      # == Track.BARRIER_MARGIN: the road may not touch the barrier
const MIN_TOTAL_LENGTH := 2200.0
const MAX_TOTAL_LENGTH := 4200.0
const MIN_STRAIGHT_LENGTH := 160.0
## Speed (px/s) of the reference "careful driver" autopilot (96 px of rope -> (96-24)*2 px/s). Used only to
## turn a track length into an indicative 3-lap time in the validation report.
const REFERENCE_PACE := 144.0


# ------------------------------------------------------------------ basic measurements

## Total arc length of a polyline. `closed` includes the wrap segment (last -> first).
static func total_length(points: PackedVector2Array, closed: bool = true) -> float:
	var n := points.size()
	if n < 2:
		return 0.0
	var s := 0.0
	var last := n if closed else n - 1
	for i in last:
		s += points[i].distance_to(points[(i + 1) % n])
	return s


## Axis-aligned bounding box of the points (an empty Rect2 for empty input).
static func bounds_of(points: PackedVector2Array) -> Rect2:
	var n := points.size()
	if n == 0:
		return Rect2()
	var mn := points[0]
	var mx := points[0]
	for i in n:
		mn.x = minf(mn.x, points[i].x)
		mn.y = minf(mn.y, points[i].y)
		mx.x = maxf(mx.x, points[i].x)
		mx.y = maxf(mx.y, points[i].y)
	return Rect2(mn, mx - mn)


## Shoelace area of the closed polygon. In Godot's screen coordinates (y down) a **positive** area means
## the loop is traversed **clockwise on screen**.
static func signed_area(points: PackedVector2Array) -> float:
	var n := points.size()
	if n < 3:
		return 0.0
	var a := 0.0
	for i in n:
		var p := points[i]
		var q := points[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


static func is_clockwise(points: PackedVector2Array) -> bool:
	return signed_area(points) > 0.0


## Returns the loop travelled in the requested direction, reversing it (keeping point 0 first) if needed.
static func ensure_direction(points: PackedVector2Array, clockwise: bool) -> PackedVector2Array:
	if points.size() < 3 or is_clockwise(points) == clockwise:
		return points.duplicate()
	var out := PackedVector2Array()
	out.resize(points.size())
	out[0] = points[0]
	for i in range(1, points.size()):
		out[i] = points[points.size() - i]
	return out


# ------------------------------------------------------------------ resampling and smoothing

## Resamples a **closed** polyline to evenly spaced points (spacing adjusted so the loop divides evenly).
## The first output point equals the first input point; the last point is NOT a duplicate of the first.
## Same contract and same result as `TrackData.resample_closed()` — duplicated here so an author can build
## and check a shape without pulling in TrackData.
static func resample(raw: PackedVector2Array, spacing: float = DEFAULT_SPACING) -> PackedVector2Array:
	var points := _finite_only(raw)
	var n_in := points.size()
	if n_in < 2 or not (spacing > 0.0):
		return points.duplicate()
	var total := total_length(points, true)
	if total <= 0.0:
		return points.duplicate()
	var count: int = maxi(3, roundi(total / spacing))
	var step := total / float(count)
	var out := PackedVector2Array()
	out.resize(count)
	var seg := 0
	var seg_start := 0.0
	var seg_len := points[0].distance_to(points[1 % n_in])
	for k in count:
		var s := step * float(k)
		while s > seg_start + seg_len and seg < n_in - 1:
			seg_start += seg_len
			seg += 1
			seg_len = points[seg].distance_to(points[(seg + 1) % n_in])
		var u := 0.0
		if seg_len > 0.0:
			u = clampf((s - seg_start) / seg_len, 0.0, 1.0)
		out[k] = points[seg].lerp(points[(seg + 1) % n_in], u)
	return out


## Rounds every vertex of a closed control polygon with a circular fillet of `radius`.
##
## The fillet at a vertex is the largest circular arc of `radius` that fits between the two adjacent edges;
## when the edges are too short for it the radius is reduced automatically (the tangent length is capped at
## `edge_fraction` of the shorter edge), so an author never has to solve for it by hand. A vertex that is
## already nearly straight keeps almost its own position, and a degenerate vertex (a spike that doubles
## exactly back on itself, or a duplicated point) is passed through untouched.
##
## `arc_step_rad` is the angular resolution of the generated arc (0.12 rad ~ 7 deg per segment).
static func smooth_corners(points: PackedVector2Array, radius: float, arc_step_rad: float = 0.12,
		edge_fraction: float = 0.45) -> PackedVector2Array:
	var radii := PackedFloat32Array()
	radii.resize(points.size())
	radii.fill(maxf(radius, 0.0))
	return smooth_corners_varied(points, radii, arc_step_rad, edge_fraction)


## `smooth_corners()` with one radius per control point (index-aligned; a radius <= 0 leaves that vertex
## sharp). Short arrays are padded with the last entry, so `[200.0]` rounds everything at 200 px.
static func smooth_corners_varied(raw: PackedVector2Array, radii: PackedFloat32Array,
		arc_step_rad: float = 0.12, edge_fraction: float = 0.45) -> PackedVector2Array:
	var points := _finite_only(raw)
	var n := points.size()
	if n < 3:
		return points.duplicate()
	var step := clampf(arc_step_rad, 0.01, 0.6)
	var frac := clampf(edge_fraction, 0.05, 0.5)
	var out := PackedVector2Array()
	for i in n:
		var v := points[i]
		var prev := points[posmod(i - 1, n)]
		var next := points[(i + 1) % n]
		var r := 0.0
		if radii.size() > 0:
			r = maxf(radii[mini(i, radii.size() - 1)], 0.0)
		var to_prev := prev - v
		var to_next := next - v
		var len_prev := to_prev.length()
		var len_next := to_next.length()
		if r <= 0.0 or len_prev < 0.001 or len_next < 0.001:
			out.append(v)
			continue
		var d_prev := to_prev / len_prev
		var d_next := to_next / len_next
		# Interior angle at the vertex: PI = straight through, 0 = doubles back on itself.
		var theta := acos(clampf(d_prev.dot(d_next), -1.0, 1.0))
		var turn := PI - theta
		var bisector := d_prev + d_next
		if turn < 0.02 or bisector.length() < 0.001:
			out.append(v)          # already straight, or a degenerate spike: nothing to round
			continue
		bisector = bisector.normalized()
		var half := theta * 0.5
		var tan_half := tan(clampf(half, 0.005, PI * 0.5 - 0.005))
		var t := r / maxf(tan_half, 0.0001)
		t = minf(t, frac * minf(len_prev, len_next))
		var r_eff := t * tan_half
		if r_eff < 0.5:
			out.append(v)
			continue
		var a := v + d_prev * t
		var b := v + d_next * t
		var center := v + bisector * (r_eff / maxf(sin(maxf(half, 0.005)), 0.0001))
		var a0 := (a - center).angle()
		var a1 := (b - center).angle()
		var sweep := wrapf(a1 - a0, -PI, PI)
		var steps: int = maxi(2, ceili(absf(sweep) / step))
		for k in range(steps + 1):
			var ang := a0 + sweep * float(k) / float(steps)
			out.append(center + Vector2.from_angle(ang) * r_eff)
	return out


## Chaikin corner cutting on a closed polyline: each iteration replaces every point with two points at
## 1/4 and 3/4 of each edge. Useful for a flowing, radius-less section (Lusail's sweeps, Jeddah's walls)
## where a circular fillet would read as a sequence of constant-radius bends. Two iterations are usually
## enough; more than three flattens the shape noticeably.
static func chaikin(points: PackedVector2Array, iterations: int = 1) -> PackedVector2Array:
	var cur := points.duplicate()
	for _it in maxi(iterations, 0):
		var n := cur.size()
		if n < 3:
			return cur
		var out := PackedVector2Array()
		out.resize(n * 2)
		for i in n:
			var p := cur[i]
			var q := cur[(i + 1) % n]
			out[i * 2] = p.lerp(q, 0.25)
			out[i * 2 + 1] = p.lerp(q, 0.75)
		cur = out
	return cur


## Points along a circular arc (inclusive of both ends). `a1` may be less than `a0` for a clockwise arc;
## the sweep is taken as written, so multi-turn values are allowed.
static func arc_points(center: Vector2, radius: float, a0: float, a1: float,
		arc_step_rad: float = 0.12) -> PackedVector2Array:
	var sweep := a1 - a0
	var steps: int = maxi(1, ceili(absf(sweep) / clampf(arc_step_rad, 0.01, 0.6)))
	var out := PackedVector2Array()
	out.resize(steps + 1)
	for k in range(steps + 1):
		out[k] = center + Vector2.from_angle(a0 + sweep * float(k) / float(steps)) * radius
	return out


# ------------------------------------------------------------------ fitting to the view

## Uniformly scales and centres a shape so the whole **road** (the centerline grown by half `width`) fits
## inside `screen` with at least `margin` px of grass around it. The aspect ratio is preserved, so a
## circuit keeps its proportions; `max_scale` (default: no limit) stops a small shape being blown up.
##
## `margin` should be at least `Track.BARRIER_MARGIN` (22 px), otherwise the road runs into the drawn
## barrier; the circuit contract (SPEC 15.4) asks for 26.
static func fit_to_view(raw: PackedVector2Array, width: float, margin: float,
		screen: Vector2 = SCREEN, max_scale: float = INF) -> PackedVector2Array:
	var points := _finite_only(raw)
	var n := points.size()
	if n == 0:
		return points.duplicate()
	var pad := maxf(margin, 0.0) + maxf(width, 0.0) * 0.5
	var box := bounds_of(points)
	var avail := Vector2(maxf(screen.x - pad * 2.0, 1.0), maxf(screen.y - pad * 2.0, 1.0))
	var sx := avail.x / maxf(box.size.x, 0.001)
	var sy := avail.y / maxf(box.size.y, 0.001)
	var scale := minf(minf(sx, sy), maxf(max_scale, 0.001))
	if not is_finite(scale) or scale <= 0.0:
		scale = 1.0
	var center := box.position + box.size * 0.5
	var target := screen * 0.5
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		out[i] = target + (points[i] - center) * scale
	return out


## Rotates the loop so `index` becomes point 0 (direction of travel unchanged).
static func rotate_start(points: PackedVector2Array, index: int) -> PackedVector2Array:
	var n := points.size()
	if n < 2:
		return points.duplicate()
	var k := posmod(index, n)
	if k == 0:
		return points.duplicate()
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		out[i] = points[(k + i) % n]
	return out


## Index of the best start/finish point: the middle of the longest run of points whose local radius is
## above `STRAIGHT_RADIUS` (i.e. the main straight). Falls back to the flattest single point when the
## circuit has no straight at all.
static func best_start_index(points: PackedVector2Array, window: float = RADIUS_WINDOW) -> int:
	var n := points.size()
	if n < 3:
		return 0
	var kw := radius_window_k(points, window)
	var straight := []
	straight.resize(n)
	var any := false
	for i in n:
		straight[i] = _curvature_radius_k(points, i, kw) >= STRAIGHT_RADIUS
		any = any or bool(straight[i])
	if not any:
		var best_r := -1.0
		var best_i := 0
		for i in n:
			var r := _curvature_radius_k(points, i, kw)
			if r > best_r:
				best_r = r
				best_i = i
		return best_i
	# Longest cyclic run of straight points. Scanning 2n covers a run that wraps through index 0.
	var best_len := 0
	var best_end := 0
	var run := 0
	for k in n * 2:
		var i := k % n
		if bool(straight[i]):
			run += 1
			if run > best_len:
				best_len = run
				best_end = i
		else:
			run = 0
	best_len = mini(best_len, n)
	return posmod(best_end - best_len / 2, n)


## Index of the middle of the straight NEAREST `hint`, rather than of the longest straight. A circuit
## whose main straight is not its longest one (a simplification often shortens the pit straight and keeps
## the back straight at full length) would otherwise put its start/finish line somewhere the player does
## not recognise — Yas Marina's landed on the back straight and Jeddah's on a run of kinks. Falls back to
## `best_start_index()` when the loop has no straight at all.
static func start_index_near(points: PackedVector2Array, hint: Vector2,
		min_share: float = 0.4, window: float = RADIUS_WINDOW) -> int:
	var n := points.size()
	if n < 3:
		return 0
	var kw := radius_window_k(points, window)
	var straight := []
	straight.resize(n)
	var any := false
	for i in n:
		straight[i] = _curvature_radius_k(points, i, kw) >= STRAIGHT_RADIUS
		any = any or bool(straight[i])
	if not any:
		return best_start_index(points, window)
	# Every cyclic run of straight points, as (middle index, length). Scanning 2n catches the run that
	# wraps through index 0; a run longer than n means the whole loop is straight.
	var runs: Array = []
	var longest := 0
	var run := 0
	for k in n * 2:
		var i := k % n
		if bool(straight[i]):
			run += 1
			continue
		if run > 0 and k >= n:
			runs.append([posmod(k - 1 - run / 2, n), mini(run, n)])
			longest = maxi(longest, mini(run, n))
		run = 0
	if runs.is_empty():
		return best_start_index(points, window)
	# Only runs at least `min_share` as long as the longest are eligible, THEN the nearest wins. Without
	# that floor a two-point blip of straightness next to the hint beats the real straight 200 px away.
	var floor_len: int = maxi(1, int(round(float(longest) * clampf(min_share, 0.0, 1.0))))
	var best_i := int(runs[0][0])
	var best_d := INF
	for r in runs:
		if int(r[1]) < floor_len:
			continue
		var d := points[int(r[0])].distance_to(hint)
		if d < best_d:
			best_d = d
			best_i = int(r[0])
	return best_i


# ------------------------------------------------------------------ curvature and corners

## Local radius of curvature at point `i`, measured as the circumradius of the three points roughly
## `window` px of arc apart. Exact on a circular arc, `INF` on a straight, always positive and finite-or-INF.
##
## It is a **window average**, so on a shape whose radius varies (an ellipse end, the entry of a fillet) it
## reads a few percent high — measured 139 px on the circle track, whose true minimum is `b^2/a` = 135 px,
## and 150.2 px on a `smooth_corners(..., 150.0)` fillet. Budget ~5 % when tuning against a limit, and feed
## it a polyline whose chords are no longer than `window / 2` (i.e. resample before measuring): a coarse
## polygon inscribed in a circle reads its chords, not its curve.
##
## `spacing` is the mean arc-length step of `points`; pass it (or reuse `radius_window_k()`) when calling
## this in a loop, otherwise every call re-measures the whole loop and the loop becomes O(n^2).
static func curvature_radius(points: PackedVector2Array, i: int, window: float = RADIUS_WINDOW,
		spacing: float = 0.0) -> float:
	var n := points.size()
	if n < 3:
		return INF
	var sp := spacing if spacing > 0.0 else total_length(points, true) / float(n)
	var k: int = clampi(roundi(maxf(window, 1.0) / maxf(sp, 0.001)), 1, n / 3)
	return _curvature_radius_k(points, i, k)


## Half-width (in points) of the curvature window for a loop of `points` — computed once by the callers
## that walk the whole loop, so `_curvature_radius_k()` can skip the `total_length()` pass per point.
static func radius_window_k(points: PackedVector2Array, window: float = RADIUS_WINDOW) -> int:
	var n := points.size()
	if n < 3:
		return 1
	var spacing := total_length(points, true) / float(n)
	return clampi(roundi(maxf(window, 1.0) / maxf(spacing, 0.001)), 1, n / 3)


## `curvature_radius()` with the window already resolved to a point count (see `radius_window_k()`).
static func _curvature_radius_k(points: PackedVector2Array, i: int, k: int) -> float:
	var n := points.size()
	if n < 3:
		return INF
	var a := points[posmod(i - k, n)]
	var b := points[posmod(i, n)]
	var c := points[posmod(i + k, n)]
	var ab := a.distance_to(b)
	var bc := b.distance_to(c)
	var ca := c.distance_to(a)
	# Circumradius = (abc) / (4 * area); a zero area means the three points are collinear.
	var area2 := absf((b - a).cross(c - a))
	if area2 < 0.000001:
		return INF
	var r := (ab * bc * ca) / (2.0 * area2)
	return r if is_finite(r) else INF


## `{"radius": float, "index": int, "point": Vector2}` for the tightest point of the loop.
static func min_corner_radius(points: PackedVector2Array, window: float = RADIUS_WINDOW) -> Dictionary:
	var n := points.size()
	if n < 3:
		return {"radius": INF, "index": 0, "point": Vector2.ZERO}
	var kw := radius_window_k(points, window)
	var best := INF
	var best_i := 0
	for i in n:
		var r := _curvature_radius_k(points, i, kw)
		if r < best:
			best = r
			best_i = i
	return {"radius": best, "index": best_i, "point": points[best_i]}


## Number of distinct corners: contiguous runs of points whose local radius is below `threshold`,
## separated by at least one point above it. This is the number written into the track registry.
static func count_corners(points: PackedVector2Array, threshold: float = CORNER_RADIUS,
		window: float = RADIUS_WINDOW) -> int:
	var n := points.size()
	if n < 3:
		return 0
	var kw := radius_window_k(points, window)
	var tight := []
	tight.resize(n)
	var all_tight := true
	for i in n:
		tight[i] = _curvature_radius_k(points, i, kw) < threshold
		all_tight = all_tight and bool(tight[i])
	if all_tight:
		return 1          # a constant-radius loop (the "circle" track) is one long corner
	var corners := 0
	for i in n:
		if bool(tight[i]) and not bool(tight[posmod(i - 1, n)]):
			corners += 1
	return corners


## Longest run of "straight" centerline (local radius >= `STRAIGHT_RADIUS`), in px.
static func longest_straight(points: PackedVector2Array, window: float = RADIUS_WINDOW) -> float:
	var n := points.size()
	if n < 3:
		return 0.0
	var spacing := total_length(points, true) / float(n)
	var kw := radius_window_k(points, window)
	var best := 0
	var run := 0
	for k in n * 2:
		var i := k % n
		if _curvature_radius_k(points, i, kw) >= STRAIGHT_RADIUS:
			run += 1
			best = maxi(best, run)
		else:
			run = 0
	return float(mini(best, n)) * spacing


# ------------------------------------------------------------------ self-intersection

## `[[i, j, point], ...]` for every pair of non-adjacent segments of the closed polyline that cross.
## Same definition (and the same `merge_px` de-duplication) the test suite already uses for the figure-8
## bridge: one crossing of two ~16 px-sampled branches produces up to four raw segment hits within a couple
## of pixels of each other, and the answer that matters is "how many places does the track cross itself".
static func self_intersections(points: PackedVector2Array, merge_px: float = 2.0) -> Array:
	var n := points.size()
	var hits: Array = []
	if n < 4:
		return hits
	for i in n:
		var a1 := points[i]
		var a2 := points[(i + 1) % n]
		for j in range(i + 2, n):
			if i == 0 and j == n - 1:
				continue          # adjacent through the wrap
			var b1 := points[j]
			var b2 := points[(j + 1) % n]
			var hit: Variant = Geometry2D.segment_intersects_segment(a1, a2, b1, b2)
			if hit == null:
				continue
			var p := hit as Vector2
			var dup := false
			for h in hits:
				if (h[2] as Vector2).distance_to(p) < merge_px:
					dup = true
					break
			if not dup:
				hits.append([i, j, p])
	return hits


# ------------------------------------------------------------------ validation

## Full acceptance report for a finished centerline. A circuit file is only done when `ok` is true.
##
## `opts` overrides (all optional): `min_radius`, `min_margin`, `min_length`, `max_length`,
## `min_straight`, `spacing`, `screen`, `allow_self_intersection` (bool), `clockwise` (bool — when set,
## the direction of travel is asserted too).
##
## The report is a Dictionary of plain values so a test or a probe can print it verbatim:
## `ok, errors, warnings, point_count, length, spacing_min/avg/max, bounds, outer_bounds,
## screen_margin, min_radius, min_radius_at, min_radius_point, corners, longest_straight,
## self_intersections, clockwise, reference_3lap`.
static func validate(points: PackedVector2Array, width: float, opts: Dictionary = {}) -> Dictionary:
	var min_radius := float(opts.get("min_radius", MIN_CORNER_RADIUS))
	var min_margin := float(opts.get("min_margin", MIN_SCREEN_MARGIN))
	var min_length := float(opts.get("min_length", MIN_TOTAL_LENGTH))
	var max_length := float(opts.get("max_length", MAX_TOTAL_LENGTH))
	var min_straight := float(opts.get("min_straight", MIN_STRAIGHT_LENGTH))
	var spacing := float(opts.get("spacing", DEFAULT_SPACING))
	var screen: Vector2 = opts.get("screen", SCREEN)
	var allow_cross := bool(opts.get("allow_self_intersection", false))

	var errors: Array[String] = []
	var warnings: Array[String] = []
	var n := points.size()
	var report := {
		"ok": false, "errors": errors, "warnings": warnings, "point_count": n,
		"length": 0.0, "spacing_min": 0.0, "spacing_avg": 0.0, "spacing_max": 0.0,
		"bounds": Rect2(), "outer_bounds": Rect2(), "screen_margin": 0.0,
		"min_radius": INF, "min_radius_at": 0, "min_radius_point": Vector2.ZERO,
		"corners": 0, "longest_straight": 0.0, "self_intersections": [] as Array,
		"clockwise": false, "reference_3lap": 0.0,
	}
	if n < 16:
		errors.append("only %d points: not a resampled centerline" % n)
		return report

	# --- finite, non-duplicated, evenly spaced, closed
	var s_min := INF
	var s_max := 0.0
	var total := 0.0
	for i in n:
		var p := points[i]
		if not (is_finite(p.x) and is_finite(p.y)):
			errors.append("point %d is not finite (%s)" % [i, p])
			return report
		var d := p.distance_to(points[(i + 1) % n])
		s_min = minf(s_min, d)
		s_max = maxf(s_max, d)
		total += d
	report["length"] = total
	report["spacing_min"] = s_min
	report["spacing_avg"] = total / float(n)
	report["spacing_max"] = s_max
	report["reference_3lap"] = total * 3.0 / REFERENCE_PACE
	if s_min < spacing * 0.5 or s_max > spacing * 1.6:
		errors.append("spacing %.1f..%.1f px is not ~%.0f px: resample() was not run last"
				% [s_min, s_max, spacing])
	if points[0].distance_to(points[n - 1]) < spacing * 0.25:
		errors.append("the last point duplicates the first (the loop must wrap implicitly)")

	# --- length
	if total < min_length:
		errors.append("total length %.0f px is under the %.0f px minimum (a lap would be over too fast)"
				% [total, min_length])
	elif total > max_length:
		errors.append("total length %.0f px is over the %.0f px maximum (3 laps would drag)"
				% [total, max_length])

	# --- fits the screen with the road and a grass margin
	var box := bounds_of(points)
	var outer := box.grow(maxf(width, 0.0) * 0.5)
	report["bounds"] = box
	report["outer_bounds"] = outer
	var margin := minf(minf(outer.position.x, outer.position.y),
			minf(screen.x - outer.end.x, screen.y - outer.end.y))
	report["screen_margin"] = margin
	if margin < min_margin:
		errors.append("the road reaches %.1f px from the screen edge (minimum %.0f px): run fit_to_view()"
				% [margin, min_margin])

	# --- no self-intersection (unless the circuit is deliberately a bridge, like figure8)
	var hits := self_intersections(points)
	report["self_intersections"] = hits
	if hits.size() > 0 and not allow_cross:
		errors.append("%d self-intersection(s), first at %s (segments %d/%d)"
				% [hits.size(), hits[0][2], hits[0][0], hits[0][1]])

	# --- drivable corners
	var tight: Dictionary = min_corner_radius(points)
	report["min_radius"] = tight["radius"]
	report["min_radius_at"] = tight["index"]
	report["min_radius_point"] = tight["point"]
	if float(tight["radius"]) < min_radius:
		errors.append("tightest radius %.0f px at index %d is under the %.0f px minimum"
				% [float(tight["radius"]), int(tight["index"]), min_radius])

	# --- rhythm
	report["corners"] = count_corners(points)
	var straight := longest_straight(points)
	report["longest_straight"] = straight
	if straight < min_straight:
		errors.append("longest straight %.0f px is under the %.0f px minimum (no rhythm)"
				% [straight, min_straight])
	if int(report["corners"]) < 4:
		warnings.append("only %d corners: the circuit may not read as itself" % int(report["corners"]))

	# --- direction of travel (only checked when the caller asks for one)
	report["clockwise"] = is_clockwise(points)
	if opts.has("clockwise") and bool(report["clockwise"]) != bool(opts["clockwise"]):
		errors.append("travelled %s; the circuit is defined %s"
				% ["clockwise" if report["clockwise"] else "anticlockwise",
				"clockwise" if bool(opts["clockwise"]) else "anticlockwise"])

	report["ok"] = errors.is_empty()
	return report


## One-line human summary of a `validate()` report, for probes and test failure details.
static func format_report(report: Dictionary) -> String:
	var head := "ok" if bool(report.get("ok", false)) else "FAIL"
	var line := "%s  n=%d  len=%.0f px  bbox=%s  margin=%.1f  rmin=%.0f@%d  corners=%d  straight=%.0f  3laps~%.0f s" % [
		head, int(report.get("point_count", 0)), float(report.get("length", 0.0)),
		report.get("bounds", Rect2()), float(report.get("screen_margin", 0.0)),
		float(report.get("min_radius", 0.0)), int(report.get("min_radius_at", 0)),
		int(report.get("corners", 0)), float(report.get("longest_straight", 0.0)),
		float(report.get("reference_3lap", 0.0)),
	]
	for e in report.get("errors", []):
		line += "\n    ERROR: %s" % e
	for w in report.get("warnings", []):
		line += "\n    warn:  %s" % w
	return line


# ------------------------------------------------------------------ input hygiene

## The input with every non-finite point removed. A NaN or INF control point would otherwise propagate
## through the fillet, the resample and the fit into the finished centerline (and log
## "Vector2 cannot be normalized" on the way), so the three entry points that an author calls all filter
## first. When nothing is dropped the original array is returned unchanged (no allocation).
static func _finite_only(points: PackedVector2Array) -> PackedVector2Array:
	var n := points.size()
	var bad := false
	for i in n:
		var p := points[i]
		if not (is_finite(p.x) and is_finite(p.y)):
			bad = true
			break
	if not bad:
		return points
	var out := PackedVector2Array()
	for i in n:
		var p := points[i]
		if is_finite(p.x) and is_finite(p.y):
			out.append(p)
	return out
