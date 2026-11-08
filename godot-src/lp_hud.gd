extends Control
## Compact LP pill: dark glass panel, thin gold border, emblem, gradient fill,
## lighter "damage trail" that drains after the main bar, low-HP pulse.

var side := 0                 # 0 = player, 1 = enemy
var max_lp := 1000.0
var target := 1000.0
var shown := 1000.0           # main fill (fast)
var trail := 1000.0           # damage trail (slow, delayed)
var trail_wait := 0.0
var t := 0.0
var flash := 0.0

const W := 340.0
const H := 62.0


func setup(s: int, m: float) -> void:
	side = s
	max_lp = m
	target = m
	shown = m
	trail = m
	custom_minimum_size = Vector2(W, H)
	size = Vector2(W, H)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_lp(v: float, instant := false) -> void:
	v = clampf(v, 0.0, max_lp)
	if v < target:
		trail_wait = 0.45
		flash = 1.0
	target = v
	if instant:
		shown = v
		trail = v
		trail_wait = 0.0
		flash = 0.0
	queue_redraw()


func _process(delta: float) -> void:
	t += delta
	shown = move_toward(shown, target, maxf(80.0, absf(target - shown) * 6.0) * delta)
	if trail_wait > 0.0:
		trail_wait -= delta
	elif trail > shown:
		trail = move_toward(trail, shown, maxf(60.0, (trail - shown) * 2.2) * delta)
	if trail < shown:
		trail = shown
	flash = maxf(0.0, flash - delta * 2.5)
	queue_redraw()


func _cols() -> Array:
	if side == 0:
		return [Color(0.25, 0.95, 1.0), Color(0.18, 0.42, 1.0)]
	return [Color(1.0, 0.25, 0.55), Color(1.0, 0.58, 0.28)]


func _rrect(r: Rect2, rad: float, c0: Color, c1: Color) -> void:
	if r.size.x <= 0.5:
		return
	rad = minf(rad, minf(r.size.x, r.size.y) * 0.5)
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var centers := [
		Vector2(r.end.x - rad, r.position.y + rad), Vector2(r.end.x - rad, r.end.y - rad),
		Vector2(r.position.x + rad, r.end.y - rad), Vector2(r.position.x + rad, r.position.y + rad)]
	var starts := [-PI * 0.5, 0.0, PI * 0.5, PI]
	for k in 4:
		for i in 7:
			var a: float = starts[k] + PI * 0.5 * i / 6.0
			var p: Vector2 = centers[k] + Vector2(cos(a), sin(a)) * rad
			pts.append(p)
			var f := clampf((p.x - r.position.x) / maxf(1.0, r.size.x), 0.0, 1.0)
			cols.append(c0.lerp(c1, f))
	draw_polygon(pts, cols)


func _draw() -> void:
	var frac := shown / max_lp
	var low := frac < 0.25 and target > 0.0
	var pulse := 0.5 + 0.5 * sin(t * 7.0) if low else 0.0
	var gold := Color(0.95, 0.78, 0.38)
	var font := ThemeDB.fallback_font

	# panel
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.04, 0.1, 0.72)
	sb.set_corner_radius_all(int(H * 0.5))
	sb.set_border_width_all(2)
	sb.border_color = gold.lerp(Color(1, 0.25, 0.3), pulse * 0.8) * Color(1, 1, 1, 0.85)
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 6
	draw_style_box(sb, Rect2(Vector2.ZERO, Vector2(W, H)))

	# emblem
	var c := Vector2(H * 0.5, H * 0.5)
	var cc: Array = _cols()
	draw_circle(c, H * 0.5 - 6, Color(0.08, 0.06, 0.14, 1.0))
	draw_arc(c, H * 0.5 - 6, 0, TAU, 40, gold, 2.0, true)
	var ec: Color = cc[0] if side == 0 else cc[0]
	var r := H * 0.22
	if side == 0:
		# shield
		var sh := PackedVector2Array([c + Vector2(-r, -r * 0.9), c + Vector2(r, -r * 0.9), c + Vector2(r, 0.1 * r), c + Vector2(0, r * 1.1), c + Vector2(-r, 0.1 * r)])
		draw_colored_polygon(sh, ec)
		draw_polyline(sh + PackedVector2Array([sh[0]]), Color(1, 1, 1, 0.6), 1.2, true)
	else:
		# horned diamond
		var dm := PackedVector2Array([c + Vector2(0, -r * 1.1), c + Vector2(r * 0.8, 0), c + Vector2(0, r * 1.1), c + Vector2(-r * 0.8, 0)])
		draw_colored_polygon(dm, ec)
		draw_colored_polygon(PackedVector2Array([c + Vector2(-r * 0.5, -r * 0.4), c + Vector2(-r * 1.2, -r * 1.1), c + Vector2(-r * 0.15, -r * 0.75)]), cc[1])
		draw_colored_polygon(PackedVector2Array([c + Vector2(r * 0.5, -r * 0.4), c + Vector2(r * 1.2, -r * 1.1), c + Vector2(r * 0.15, -r * 0.75)]), cc[1])
	# text row
	var x0 := H + 2.0
	var name_txt := "YOU" if side == 0 else "ENEMY"
	draw_string(font, Vector2(x0, 23), name_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(cc[0].lightened(0.35), 0.95))
	var num := "%d" % int(round(shown))
	var tail := " / %d" % int(max_lp)
	var fs := 22
	var tw := font.get_string_size(tail, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	var nw := font.get_string_size(num, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var right := W - 22.0
	var numcol := Color.WHITE.lerp(Color(1, 0.4, 0.4), pulse * 0.7 + flash * 0.4)
	draw_string(font, Vector2(right - tw, 25), tail, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.8, 0.78, 0.9, 0.75))
	draw_string_outline(font, Vector2(right - tw - nw, 26), num, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.6))
	draw_string(font, Vector2(right - tw - nw, 26), num, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, numcol)
	var lpw := font.get_string_size("LP ", HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	draw_string(font, Vector2(right - tw - nw - lpw, 25), "LP ", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, gold)

	# bar
	var br := Rect2(Vector2(x0, 34), Vector2(right - x0, 14))
	_rrect(br, 7, Color(0.02, 0.02, 0.05, 0.9), Color(0.02, 0.02, 0.05, 0.9))
	var inner := br.grow(-2)
	var tf := clampf(trail / max_lp, 0, 1)
	_rrect(Rect2(inner.position, Vector2(inner.size.x * tf, inner.size.y)), 5, Color(1, 0.95, 0.85, 0.85), Color(1, 0.85, 0.6, 0.85))
	var c0: Color = cc[0]
	var c1: Color = cc[1]
	if low:
		var red := Color(1, 0.18, 0.2)
		c0 = c0.lerp(red, 0.55 + 0.3 * pulse)
		c1 = c1.lerp(red, 0.55 + 0.3 * pulse)
		c0 = c0.lightened(0.25 * pulse)
	var ff := clampf(frac, 0, 1)
	var fr := Rect2(inner.position, Vector2(inner.size.x * ff, inner.size.y))
	_rrect(fr, 5, c0, c1)
	# gloss line
	if fr.size.x > 8:
		draw_line(fr.position + Vector2(5, 2.5), Vector2(fr.end.x - 5, fr.position.y + 2.5), Color(1, 1, 1, 0.35), 1.5, true)
