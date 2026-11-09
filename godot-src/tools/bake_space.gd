extends SceneTree
# Bakes the deterministic procedural backdrop textures of main.gd into PNGs (res://space/).
# NOTE: planet/sun/ring textures are REAL maps (Solar System Scope / NASA), NOT
# procedural — they live in res://space/ as planet_*.png + ring.png and must
# never be baked here. Only nebula + radial are baked by this script.
func _init() -> void:
	var M = load("res://main.gd").new()
	var jobs := {
		"nebula_a": M._nebula_tex(7),
		"nebula_b": M._nebula_tex(21),
		"radial": M._radial_tex(),
	}
	for k in jobs:
		var img: Image = jobs[k].get_image()
		img.clear_mipmaps()
		img.save_png("res://space/%s.png" % k)
		print(k, " ", img.get_size(), " ", img.get_format())
	M.free()
	quit()
