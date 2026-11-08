extends SceneTree
# Bakes the deterministic procedural backdrop textures of main.gd into PNGs (res://space/).
func _init() -> void:
	var M = load("res://main.gd").new()
	var jobs := {
		"planet_lava": M._planet_tex("rock", 3, Color(0.42, 0.16, 0.08), Color(0.85, 0.5, 0.25), Color(1.0, 0.55, 0.1)),
		"planet_ringed": M._planet_tex("gas", 11, Color(0.32, 0.26, 0.72), Color(0.82, 0.7, 1.0), Color(1.0, 0.75, 0.9)),
		"planet_earth": M._planet_tex("earth", 17, Color(0.06, 0.2, 0.5), Color(0.2, 0.55, 0.3), Color(0.92, 0.95, 1.0)),
		"planet_ice": M._planet_tex("gas", 29, Color(0.55, 0.85, 0.9), Color(0.85, 0.97, 1.0), Color(0.4, 0.7, 0.95)),
		"planet_moon": M._planet_tex("moon", 41, Color(0.42, 0.42, 0.46), Color(0.78, 0.78, 0.82), Color(0.25, 0.25, 0.28)),
		"nebula_a": M._nebula_tex(7),
		"nebula_b": M._nebula_tex(21),
		"radial": M._radial_tex(),
		"ring": M._ring_tex(5),
	}
	for k in jobs:
		var img: Image = jobs[k].get_image()
		img.clear_mipmaps()
		img.save_png("res://space/%s.png" % k)
		print(k, " ", img.get_size(), " ", img.get_format())
	M.free()
	quit()
