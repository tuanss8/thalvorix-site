extends Node3D
## THALVORIX Duel Arena 3D - playable prototype.
## Player vs bot, 5 slots per side, 4000 LP each.
## Attack rule (simplified from the 2D Duel Arena): attacker ATK vs target DEF.
##   ATK > DEF : target destroyed, its owner loses (ATK - DEF) LP.
##   ATK < DEF : attack bounces, attacker's owner loses (DEF - ATK) LP.
##   ATK = DEF : both cards destroyed.
## Win when enemy LP hits 0 or the enemy has no cards left (field + deck).

const HeroData = preload("res://hero_data.gd")
const CardScript = preload("res://card.gd")

const SLOT_X := [-3.7, -1.85, 0.0, 1.85, 3.7]
const CARD_SCALE := 1.15
const ROW_Z := [1.72, -1.72]                       # player row, bot row
const DECK_POS := [Vector3(5.85, 0.0, 2.4), Vector3(-5.85, 0.0, -2.4)]
const LP_MAX := 4000
const DECK_SIZE := 8
const RARITIES := ["Common", "Uncommon", "Rare", "Epic", "Legendary"]
const RARITY_W := [40, 27, 18, 10, 5]
const RARITY_POW := {"Common": 1.0, "Uncommon": 1.07, "Rare": 1.14, "Epic": 1.22, "Legendary": 1.32}

var cam: Camera3D
var cam_base := Transform3D()
var shake := 0.0
var spin_nodes := []          # [node, axis, speed]
var orbit_pivots := []        # [node, speed]
var stars: MultiMeshInstance3D
var textures := {}

var field := [[null, null, null, null, null], [null, null, null, null, null]]
var reserve := [[], []]
var lp := [LP_MAX, LP_MAX]
var lp_shown := [float(LP_MAX), float(LP_MAX)]
var state := "title"          # title | anim | player | bot | over
var selected = null
var game_id := 0
var fragments := []           # {n, v, s, life}
var piles := []               # [mesh, label] per side

# UI
var lp_bar := []
var lp_text := []
var status_lbl: Label
var banner_lbl: Label
var result_panel: Control
var result_title: Label
var result_sub: Label
var title_panel: Control
var mute_btn: Button
var rotate_hint: Label

# audio
var music: AudioStreamPlayer
var sfx := {}
var sfx_pool := []
var sfx_i := 0
var muted := false

# debug / headless verification: `-- --autoplay --shots`
var _shot_shatter := false
var autoplay := false
var shots := false


func _ready() -> void:
	randomize()
	var args := OS.get_cmdline_user_args()
	autoplay = args.has("--autoplay")
	shots = args.has("--shots")
	for h in HeroData.HEROES:
		textures[h.id] = load("res://heroes/h%d.jpg" % h.id)
	_build_env()
	_build_space()
	_build_table()
	_build_ui()
	_build_audio()
	if shots:
		get_tree().create_timer(0.5).timeout.connect(func(): _shot("title"))
	if autoplay:
		get_tree().create_timer(1.0).timeout.connect(_on_play_pressed)


# ---------------------------------------------------------------- scene
func _build_env() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.008, 0.035)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.42, 0.36, 0.6)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, -25, 0)
	sun.light_energy = 0.85
	sun.light_color = Color(1.0, 0.94, 0.88)
	add_child(sun)
	var o1 := OmniLight3D.new()
	o1.position = Vector3(-6.5, 3.5, -3.5)
	o1.light_color = Color(0.65, 0.3, 1.0)
	o1.light_energy = 1.6
	o1.omni_range = 13.0
	add_child(o1)
	var o2 := OmniLight3D.new()
	o2.position = Vector3(6.5, 3.0, 3.5)
	o2.light_color = Color(0.25, 0.65, 1.0)
	o2.light_energy = 1.3
	o2.omni_range = 13.0
	add_child(o2)

	cam = Camera3D.new()
	cam.position = Vector3(0, 8.4, 6.3)
	add_child(cam)
	cam.look_at(Vector3(0, 0, 0.55), Vector3.UP)
	cam_base = cam.transform
	cam.current = true


func _unshaded(color: Color, energy := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color * energy
	return m


func _build_space() -> void:
	# star field
	var sm := SphereMesh.new()
	sm.radius = 0.09
	sm.height = 0.18
	sm.radial_segments = 6
	sm.rings = 3
	var smat := _unshaded(Color.WHITE)
	smat.vertex_color_use_as_albedo = true
	sm.material = smat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = sm
	mm.instance_count = 520
	for i in mm.instance_count:
		var dir := Vector3(randf_range(-1, 1), randf_range(-1, 0.6), randf_range(-1, 1)).normalized()
		var r := randf_range(38.0, 60.0)
		var s := randf_range(0.5, 1.7)
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(s, s, s)), dir * r))
		var tint: Color = [Color(1, 1, 1), Color(0.75, 0.82, 1.0), Color(1.0, 0.85, 0.7), Color(0.9, 0.75, 1.0)][i % 4]
		mm.set_instance_color(i, tint * randf_range(0.6, 1.4))
	stars = MultiMeshInstance3D.new()
	stars.multimesh = mm
	add_child(stars)

	# planets
	_planet(Vector3(-13.5, -12.0, -21.0), 4.6, Color(0.85, 0.42, 0.25), Color(0.5, 0.12, 0.05), 0.08)
	var ringed := _planet(Vector3(14.0, -9.0, -17.0), 2.8, Color(0.45, 0.4, 0.95), Color(0.12, 0.08, 0.4), -0.12)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 3.6
	tm.outer_radius = 5.4
	tm.rings = 48
	tm.ring_segments = 6
	ring.mesh = tm
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(0.9, 0.75, 1.0, 0.55)
	rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.emission_enabled = true
	rmat.emission = Color(0.55, 0.35, 0.9)
	rmat.emission_energy_multiplier = 0.6
	ring.material_override = rmat
	ring.scale = Vector3(1, 0.04, 1)
	ring.position = ringed.position
	ring.rotation_degrees = Vector3(22, 0, -18)
	add_child(ring)
	spin_nodes.append([ring, Vector3.UP, 0.05])
	# small moon orbiting the big planet
	var pivot := Node3D.new()
	pivot.position = Vector3(-13.5, -12.0, -21.0)
	add_child(pivot)
	var moon := MeshInstance3D.new()
	var ms := SphereMesh.new()
	ms.radius = 0.9
	ms.height = 1.8
	moon.mesh = ms
	var mmat := StandardMaterial3D.new()
	mmat.albedo_color = Color(0.7, 0.85, 1.0)
	mmat.emission_enabled = true
	mmat.emission = Color(0.2, 0.35, 0.6)
	moon.material_override = mmat
	moon.position = Vector3(7.5, 2.0, 0)
	pivot.add_child(moon)
	orbit_pivots.append([pivot, 0.18])
	# distant glowing star
	_planet(Vector3(4.0, -16.0, -34.0), 2.2, Color(1.0, 0.85, 0.5), Color(1.0, 0.6, 0.2), 0.0, true)


func _planet(pos: Vector3, radius: float, col: Color, emis: Color, spin: float, glow := false) -> MeshInstance3D:
	var p := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = radius
	s.height = radius * 2.0
	s.radial_segments = 32
	s.rings = 16
	p.mesh = s
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.8
	m.emission_enabled = true
	m.emission = emis
	m.emission_energy_multiplier = 2.5 if glow else 0.5
	p.material_override = m
	p.position = pos
	p.rotation_degrees.z = 15
	add_child(p)
	if spin != 0.0:
		spin_nodes.append([p, Vector3.UP, spin])
	return p


func _build_table() -> void:
	var table := MeshInstance3D.new()
	var tb := BoxMesh.new()
	tb.size = Vector3(13.6, 0.3, 7.8)
	table.mesh = tb
	var tmat := StandardMaterial3D.new()
	tmat.albedo_color = Color(0.075, 0.05, 0.13)
	tmat.metallic = 0.35
	tmat.roughness = 0.45
	table.material_override = tmat
	table.position.y = -0.15
	add_child(table)

	var rim := MeshInstance3D.new()
	var rb := BoxMesh.new()
	rb.size = Vector3(13.9, 0.12, 8.1)
	rim.mesh = rb
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(0.5, 0.35, 0.12)
	rmat.emission_enabled = true
	rmat.emission = Color(0.85, 0.6, 0.2)
	rmat.emission_energy_multiplier = 0.7
	rim.material_override = rmat
	rim.position.y = -0.24
	add_child(rim)

	var mid := MeshInstance3D.new()
	var mb := BoxMesh.new()
	mb.size = Vector3(11.4, 0.01, 0.05)
	mid.mesh = mb
	mid.material_override = _unshaded(Color(0.8, 0.6, 1.0), 1.0)
	mid.position.y = 0.005
	add_child(mid)

	for side in 2:
		var c := Color(0.3, 0.6, 1.0) if side == 0 else Color(1.0, 0.3, 0.4)
		for i in 5:
			var sl := MeshInstance3D.new()
			var pm := PlaneMesh.new()
			pm.size = Vector2(1.66, 2.3)
			sl.mesh = pm
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_color = Color(c.r, c.g, c.b, 0.16)
			sl.material_override = m
			sl.position = Vector3(SLOT_X[i], 0.003, ROW_Z[side])
			add_child(sl)
			# slot outline strips
			for e in [[Vector3(0, 0, -1.15), Vector3(1.66, 0.01, 0.03)], [Vector3(0, 0, 1.15), Vector3(1.66, 0.01, 0.03)],
					[Vector3(-0.83, 0, 0), Vector3(0.03, 0.01, 2.3)], [Vector3(0.83, 0, 0), Vector3(0.03, 0.01, 2.3)]]:
				var st := MeshInstance3D.new()
				var sb := BoxMesh.new()
				sb.size = e[1]
				st.mesh = sb
				st.material_override = _unshaded(c, 1.3)
				st.position = sl.position + e[0]
				add_child(st)
		# deck pile
		var pile := MeshInstance3D.new()
		var pb := BoxMesh.new()
		pb.size = Vector3(1.5, 1.0, 2.1)
		pile.mesh = pb
		var pmat := StandardMaterial3D.new()
		pmat.albedo_color = Color(0.22, 0.08, 0.36)
		pmat.emission_enabled = true
		pmat.emission = Color(0.3, 0.1, 0.5)
		pmat.emission_energy_multiplier = 0.4
		pile.material_override = pmat
		pile.position = DECK_POS[side]
		add_child(pile)
		var pl := Label3D.new()
		pl.font_size = 64
		pl.pixel_size = 0.005
		pl.outline_size = 10
		pl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		pl.modulate = Color(1, 0.85, 0.4)
		pl.position = DECK_POS[side] + Vector3(0, 0.9, 0)
		add_child(pl)
		piles.append([pile, pl])
	_update_piles()


func _update_piles() -> void:
	for side in 2:
		var n: int = reserve[side].size()
		var pile: MeshInstance3D = piles[side][0]
		var h := maxf(0.02, n * 0.045)
		pile.scale = Vector3(1, h, 1)
		pile.position.y = h * 0.5
		pile.visible = n > 0
		var lbl: Label3D = piles[side][1]
		lbl.text = "Deck %d" % n
		lbl.position.y = h + 0.45


# ---------------------------------------------------------------- UI
func _style(col: Color, radius := 8) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = col
	s.set_corner_radius_all(radius)
	return s


func _label(txt: String, size: int, col := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 8)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _button(txt: String, size: int) -> Button:
	var b := Button.new()
	b.text = txt
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_stylebox_override("normal", _style(Color(0.55, 0.25, 0.9), 14))
	b.add_theme_stylebox_override("hover", _style(Color(0.65, 0.35, 1.0), 14))
	b.add_theme_stylebox_override("pressed", _style(Color(0.4, 0.15, 0.7), 14))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", Color.WHITE)
	b.custom_minimum_size = Vector2(260, 70)
	return b


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	# LP panels: enemy top-left, player bottom-left
	for side in 2:
		var box := VBoxContainer.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if side == 1:
			box.set_anchors_preset(Control.PRESET_TOP_LEFT)
			box.position = Vector2(20, 14)
		else:
			box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
			box.offset_top = -96
			box.offset_left = 20
		var head := HBoxContainer.new()
		head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		head.add_child(_label("ENEMY" if side == 1 else "YOU", 26, Color(1, 0.55, 0.6) if side == 1 else Color(0.55, 0.8, 1)))
		var t := _label("LP 4000", 26, Color(1, 0.88, 0.35))
		head.add_child(t)
		head.add_theme_constant_override("separation", 16)
		box.add_child(head)
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(330, 22)
		bar.max_value = LP_MAX
		bar.value = LP_MAX
		bar.show_percentage = false
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.add_theme_stylebox_override("background", _style(Color(0.1, 0.08, 0.15, 0.9), 6))
		bar.add_theme_stylebox_override("fill", _style(Color(0.95, 0.3, 0.38) if side == 1 else Color(0.3, 0.62, 1.0), 6))
		box.add_child(bar)
		root.add_child(box)
		lp_bar.append(bar)
		lp_text.append(t)

	status_lbl = _label("", 24, Color(1, 1, 1))
	status_lbl.set_anchors_preset(Control.PRESET_CENTER_TOP)
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_lbl.offset_left = -420
	status_lbl.offset_right = 420
	status_lbl.offset_top = 16
	status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(status_lbl)

	banner_lbl = _label("", 64, Color(1, 0.85, 0.4))
	banner_lbl.set_anchors_preset(Control.PRESET_CENTER)
	banner_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner_lbl.offset_left = -400
	banner_lbl.offset_right = 400
	banner_lbl.offset_top = -50
	banner_lbl.offset_bottom = 50
	banner_lbl.pivot_offset = Vector2(400, 50)
	banner_lbl.modulate.a = 0.0
	root.add_child(banner_lbl)

	mute_btn = _button("Sound: ON", 22)
	mute_btn.custom_minimum_size = Vector2(170, 52)
	mute_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	mute_btn.offset_left = -190
	mute_btn.offset_right = -20
	mute_btn.offset_top = 14
	mute_btn.offset_bottom = 66
	mute_btn.pressed.connect(_toggle_mute)
	root.add_child(mute_btn)

	# result panel
	result_panel = ColorRect.new()
	(result_panel as ColorRect).color = Color(0, 0, 0, 0.55)
	result_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	result_panel.visible = false
	root.add_child(result_panel)
	var rc := CenterContainer.new()
	rc.set_anchors_preset(Control.PRESET_FULL_RECT)
	result_panel.add_child(rc)
	var rv := VBoxContainer.new()
	rv.alignment = BoxContainer.ALIGNMENT_CENTER
	rv.add_theme_constant_override("separation", 18)
	rc.add_child(rv)
	result_title = _label("VICTORY", 96, Color(1, 0.85, 0.35))
	result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rv.add_child(result_title)
	result_sub = _label("", 28)
	result_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rv.add_child(result_sub)
	var again := _button("Play again", 34)
	again.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	again.pressed.connect(_on_play_pressed)
	rv.add_child(again)

	# title panel
	title_panel = ColorRect.new()
	(title_panel as ColorRect).color = Color(0.02, 0.0, 0.05, 0.72)
	title_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(title_panel)
	var tc := CenterContainer.new()
	tc.set_anchors_preset(Control.PRESET_FULL_RECT)
	title_panel.add_child(tc)
	var tv := VBoxContainer.new()
	tv.alignment = BoxContainer.ALIGNMENT_CENTER
	tv.add_theme_constant_override("separation", 14)
	tc.add_child(tv)
	for row in [["THALVORIX", 92, Color(1, 0.82, 0.35)], ["DUEL ARENA 3D", 44, Color(0.85, 0.75, 1.0)],
			["Prototype · Player vs Bot", 24, Color(0.75, 0.75, 0.85)]]:
		var l := _label(row[0], row[1], row[2])
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tv.add_child(l)
	var how := _label("Tap one of your cards, then tap an enemy card to attack.\nATK beats DEF: the difference is taken from Life Points.", 24, Color(0.9, 0.9, 0.95))
	how.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tv.add_child(how)
	var play := _button("Play", 38)
	play.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	play.pressed.connect(_on_play_pressed)
	tv.add_child(play)

	rotate_hint = _label("Rotate your phone to landscape for the best view", 24, Color(1, 0.85, 0.5))
	rotate_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	rotate_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rotate_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rotate_hint.offset_left = -300
	rotate_hint.offset_right = 300
	rotate_hint.offset_top = -150
	rotate_hint.visible = false
	root.add_child(rotate_hint)


func _toggle_mute() -> void:
	muted = not muted
	AudioServer.set_bus_mute(0, muted)
	mute_btn.text = "Sound: OFF" if muted else "Sound: ON"


func _set_status(t: String) -> void:
	status_lbl.text = t


func _banner(t: String, col := Color(1, 0.85, 0.4)) -> void:
	banner_lbl.text = t
	banner_lbl.add_theme_color_override("font_color", col)
	banner_lbl.scale = Vector2(0.6, 0.6)
	banner_lbl.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(banner_lbl, "modulate:a", 1.0, 0.18)
	tw.parallel().tween_property(banner_lbl, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.6)
	tw.tween_property(banner_lbl, "modulate:a", 0.0, 0.3)


# ---------------------------------------------------------------- audio
func _build_audio() -> void:
	music = AudioStreamPlayer.new()
	var ms: AudioStream = load("res://audio/music.ogg")
	if ms is AudioStreamOggVorbis:
		(ms as AudioStreamOggVorbis).loop = true
	music.stream = ms
	music.volume_db = -9.0
	add_child(music)
	for n in ["hit", "deal", "flip", "shatter", "win", "lose", "select"]:
		sfx[n] = load("res://audio/%s.wav" % n)
	for i in 6:
		var p := AudioStreamPlayer.new()
		p.volume_db = -4.0
		add_child(p)
		sfx_pool.append(p)


func _sfx(n: String, pitch := 1.0) -> void:
	if not sfx.has(n):
		return
	var p: AudioStreamPlayer = sfx_pool[sfx_i]
	sfx_i = (sfx_i + 1) % sfx_pool.size()
	p.stream = sfx[n]
	p.pitch_scale = pitch * randf_range(0.95, 1.05)
	p.play()


# ---------------------------------------------------------------- game setup
func _on_play_pressed() -> void:
	title_panel.visible = false
	result_panel.visible = false
	if not music.playing:
		music.play()
	_start_game()


func _pick_rarity() -> String:
	var r := randi() % 100
	var acc := 0
	for i in RARITIES.size():
		acc += RARITY_W[i]
		if r < acc:
			return RARITIES[i]
	return "Common"


func _make_card(h: Dictionary, side: int) -> Node3D:
	var rar := _pick_rarity()
	var a := randi_range(900, 1800)
	var d := randi_range(600, 1500)
	match String(h.role):
		"Tank":
			a -= 200; d += 450
		"Assassin":
			a += 350; d -= 250
		"Fighter":
			a += 150; d += 150
		"Mage":
			a += 250; d -= 100
		"Marksman":
			a += 200; d -= 150
		"Support":
			a -= 100; d += 250
	var pw: float = RARITY_POW[rar]
	a = int(round(a * pw / 50.0) * 50)
	d = int(round(maxf(300, d) * pw / 50.0) * 50)
	var c: Node3D = CardScript.new()
	c.setup(h, textures[h.id], a, d, rar, side)
	c.visible = false
	c.scale = Vector3.ONE * CARD_SCALE
	c.position = DECK_POS[side] + Vector3(0, 0.6, 0)
	c.rotation = Vector3(0, 0, PI)
	add_child(c)
	return c


func _clear_board() -> void:
	for side in 2:
		for i in 5:
			if field[side][i] != null:
				field[side][i].queue_free()
				field[side][i] = null
		for c in reserve[side]:
			c.queue_free()
		reserve[side] = []
	for f in fragments:
		f.n.queue_free()
	fragments = []
	selected = null


func _start_game() -> void:
	game_id += 1
	_clear_board()
	lp = [LP_MAX, LP_MAX]
	for side in 2:
		var pool: Array = HeroData.HEROES.duplicate()
		pool.shuffle()
		for k in DECK_SIZE:
			reserve[side].append(_make_card(pool[k], side))
	_update_piles()
	_update_lp(true)
	state = "anim"
	_set_status("Dealing cards…")
	_banner("DUEL START!")
	if shots and game_id == 1:
		get_tree().create_timer(1.0).timeout.connect(func(): _shot("deal"))
	await _refill_both()
	_player_turn()


# Fill empty slots of both sides from their decks. Cards fly in, then player cards flip.
func _refill_both() -> void:
	var gid := game_id
	var n := 0
	var flips := []
	for i in 5:
		for side in 2:
			if field[side][i] == null and reserve[side].size() > 0:
				var c = reserve[side].pop_back()
				field[side][i] = c
				c.slot = i
				_fly_in(c, Vector3(SLOT_X[i], CardScript.REST_Y, ROW_Z[side]), n * 0.15)
				n += 1
				if side == 0:
					flips.append(c)
	if n == 0:
		return
	_update_piles()
	await get_tree().create_timer((n - 1) * 0.15 + 0.6).timeout
	if gid != game_id:
		return
	var k := 0
	for c in flips:
		_flip(c, k * 0.08)
		k += 1
	if k > 0:
		await get_tree().create_timer((k - 1) * 0.08 + 0.45).timeout


func _fly_in(c: Node3D, to: Vector3, delay: float) -> void:
	var tw := create_tween()
	tw.tween_interval(delay)
	tw.tween_callback(func():
		c.position = DECK_POS[c.side] + Vector3(0, 0.6, 0)
		c.rotation = Vector3(0, -0.7 if c.side == 0 else 0.7, PI)
		c.visible = true
		_sfx("deal"))
	var from: Vector3 = DECK_POS[c.side] + Vector3(0, 0.6, 0)
	tw.tween_method(func(t: float):
		c.position = from.lerp(to, t) + Vector3(0, sin(t * PI) * 1.8, 0)
		c.rotation.y = lerpf(-0.7 if c.side == 0 else 0.7, 0.0, t), 0.0, 1.0, 0.55).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _flip(c: Node3D, delay := 0.0) -> void:
	if c.face_up:
		return
	c.face_up = true
	var base_y: float = c.position.y
	var tw := create_tween()
	tw.tween_interval(delay)
	tw.tween_callback(func(): _sfx("flip"))
	tw.tween_method(func(t: float):
		if is_instance_valid(c):
			c.rotation.z = lerpf(PI, 0.0, t)
			c.position.y = base_y + sin(t * PI) * 0.7, 0.0, 1.0, 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)


# ---------------------------------------------------------------- turns
func _count(side: int) -> int:
	var n: int = reserve[side].size()
	for c in field[side]:
		if c != null:
			n += 1
	return n


func _field_cards(side: int) -> Array:
	var out := []
	for c in field[side]:
		if c != null:
			out.append(c)
	return out


func _check_end() -> bool:
	var p_out: bool = lp[0] <= 0 or _count(0) == 0
	var b_out: bool = lp[1] <= 0 or _count(1) == 0
	if not p_out and not b_out:
		return false
	var win: bool = b_out and not p_out
	if p_out and b_out:
		win = lp[0] > lp[1]
	state = "over"
	_select(null)
	var why := ""
	if win:
		why = "Enemy Life Points reached 0." if lp[1] <= 0 else "The enemy has no cards left."
	else:
		why = "Your Life Points reached 0." if lp[0] <= 0 else "You have no cards left."
	_sfx("win" if win else "lose")
	_set_status("")
	_show_result(win, why)
	return true


func _show_result(win: bool, why: String) -> void:
	await get_tree().create_timer(0.7).timeout
	result_title.text = "VICTORY" if win else "DEFEAT"
	result_title.add_theme_color_override("font_color", Color(1, 0.85, 0.35) if win else Color(1, 0.4, 0.45))
	result_sub.text = "%s\nYour LP %d  ·  Enemy LP %d" % [why, max(lp[0], 0), max(lp[1], 0)]
	result_panel.visible = true
	result_panel.modulate.a = 0.0
	create_tween().tween_property(result_panel, "modulate:a", 1.0, 0.35)
	if autoplay:
		print("RESULT: ", "VICTORY" if win else "DEFEAT", " LP ", lp)
		if shots:
			await get_tree().create_timer(0.6).timeout
			_shot("result")
		get_tree().quit()


func _player_turn() -> void:
	var gid := game_id
	state = "anim"
	await _refill_both()
	if gid != game_id:
		return
	if _check_end():
		return
	state = "player"
	_banner("YOUR TURN", Color(0.55, 0.85, 1.0))
	_set_status("Select one of your cards")
	if autoplay:
		await get_tree().create_timer(0.9).timeout
		var pair := _best_pair(0)
		_select(pair[0])
		if shots and not FileAccess.file_exists("user://shot_select.png"):
			await get_tree().create_timer(0.5).timeout
			_shot("select")
		await get_tree().create_timer(0.4).timeout
		_attack(pair[0], pair[1])


func _bot_turn() -> void:
	var gid := game_id
	state = "bot"
	await _refill_both()
	if gid != game_id:
		return
	if _check_end():
		return
	_banner("ENEMY TURN", Color(1, 0.5, 0.55))
	_set_status("Enemy is thinking…")
	await get_tree().create_timer(1.1).timeout
	if gid != game_id or state == "over":
		return
	var pair := _best_pair(1)
	if pair.is_empty():
		_player_turn()
		return
	pair[0].set_glow(true, Color(1, 0.35, 0.4))
	await get_tree().create_timer(0.45).timeout
	if gid != game_id:
		return
	_attack(pair[0], pair[1])


# Bot logic: prefer kills with the biggest LP damage; 25% of the time a random move.
func _best_pair(side: int) -> Array:
	var atts := _field_cards(side)
	var tgts := _field_cards(1 - side)
	if atts.is_empty() or tgts.is_empty():
		return []
	if randf() < 0.25:
		return [atts.pick_random(), tgts.pick_random()]
	var best := []
	var best_s := -INF
	for a in atts:
		for t in tgts:
			var known_def: int = t.def if (t.face_up or side == 1) else 1050
			var diff: int = a.atk - known_def
			var s := float(diff) + (1500.0 if diff > 0 else (300.0 if diff == 0 else 0.0))
			if s > best_s:
				best_s = s
				best = [a, t]
	return best


func _select(c) -> void:
	if selected != null and is_instance_valid(selected):
		selected.set_glow(false)
		var s = selected
		create_tween().tween_property(s, "position:y", CardScript.REST_Y, 0.15)
	for e in _field_cards(1):
		e.set_glow(false)
	selected = c
	if c != null:
		c.set_glow(true, Color(0.5, 0.9, 1.0))
		create_tween().tween_property(c, "position:y", 0.35, 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		for e in _field_cards(1):
			e.set_glow(true, Color(1, 0.35, 0.4))
		_sfx("select")
		_set_status("%s selected (ATK %d) · now tap an enemy card" % [c.hero.name, c.atk])


func _unhandled_input(event: InputEvent) -> void:
	if state != "player" or autoplay:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var c = _pick(event.position)
		if c == null:
			return
		if c.side == 0:
			_select(null if c == selected else c)
		elif selected != null:
			var a = selected
			_attack(a, c)
		else:
			_set_status("First select one of YOUR cards (bottom row)")


func _pick(screen_pos: Vector2):
	var o := cam.project_ray_origin(screen_pos)
	var d := cam.project_ray_normal(screen_pos)
	if absf(d.y) < 0.0001:
		return null
	var best = null
	var best_d := INF
	for plane_y in [0.35, 0.03]:
		var t: float = (plane_y - o.y) / d.y
		var hit: Vector3 = o + d * t
		for side in 2:
			for c in field[side]:
				if c == null:
					continue
				var dx := absf(hit.x - c.position.x)
				var dz := absf(hit.z - c.position.z)
				if dx < 0.9 and dz < 1.2:
					var dist := dx + dz
					if dist < best_d:
						best_d = dist
						best = c
		if best != null:
			return best
	return null


# ---------------------------------------------------------------- combat
func _attack(att: Node3D, tgt: Node3D) -> void:
	var gid := game_id
	var att_side: int = att.side
	state = "anim"
	_select(null)
	att.set_glow(false)
	await get_tree().create_timer(0.16).timeout
	if not tgt.face_up or not att.face_up:
		_flip(tgt)
		_flip(att)
		await get_tree().create_timer(0.55).timeout
	if gid != game_id:
		return
	var start: Vector3 = Vector3(att.position.x, CardScript.REST_Y, att.position.z)
	var dir: Vector3 = (tgt.position - start).normalized()
	var hit_pos: Vector3 = tgt.position - dir * 1.0 + Vector3(0, 0.45, 0)
	_set_status("%s attacks %s!" % [att.hero.name, tgt.hero.name])
	var tw := create_tween()
	tw.tween_property(att, "position", start - dir * 0.35 + Vector3(0, 0.5, 0), 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(att, "rotation:x", -0.35 * (1 if att.side == 0 else -1), 0.18)
	tw.tween_property(att, "position", hit_pos, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tw.finished
	if gid != game_id:
		return
	_sfx("hit")
	shake = 0.28
	_impact_flash(tgt.position + Vector3(0, 0.4, 0), Color(1, 0.7, 0.35))
	var tw2 := create_tween()
	tw2.tween_property(att, "position", start, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw2.parallel().tween_property(att, "rotation:x", 0.0, 0.3)
	var kn := create_tween()
	kn.tween_property(tgt, "position", tgt.position + dir * 0.18, 0.06)
	kn.tween_property(tgt, "position", tgt.position, 0.15)

	var diff: int = att.atk - tgt.def
	var a_name: String = att.hero.name
	var t_name: String = tgt.hero.name
	if diff > 0:
		lp[tgt.side] -= diff
		_float_text("-%d" % diff, tgt.position + Vector3(0, 0.8, 0), Color(1, 0.45, 0.4))
		await get_tree().create_timer(0.12).timeout
		_shatter(tgt)
		_set_status("%s destroys %s! %d damage to %s LP." % [a_name, t_name, diff, "enemy" if tgt.side == 1 else "your"])
	elif diff < 0:
		lp[att.side] += diff
		_float_text("-%d" % -diff, start + Vector3(0, 0.8, 0), Color(1, 0.45, 0.4))
		_set_status("%s blocks! DEF %d > ATK %d. %d recoil to %s LP." % [t_name, tgt.def, att.atk, -diff, "your" if att.side == 0 else "enemy"])
	else:
		await get_tree().create_timer(0.12).timeout
		_shatter(tgt)
		_shatter(att)
		_set_status("Equal power! %s and %s destroy each other." % [a_name, t_name])
	_update_lp()
	await get_tree().create_timer(1.1).timeout
	if gid != game_id:
		return
	if _check_end():
		return
	if att_side == 0:
		_bot_turn()
	else:
		_player_turn()


func _update_lp(instant := false) -> void:
	for side in 2:
		var v := float(max(lp[side], 0))
		lp_text[side].text = "LP %d" % int(v)
		if instant:
			lp_bar[side].value = v
		else:
			create_tween().tween_property(lp_bar[side], "value", v, 0.5).set_trans(Tween.TRANS_SINE)


func _shatter(c: Node3D) -> void:
	if not c.alive:
		return
	c.alive = false
	if field[c.side][c.slot] == c:
		field[c.side][c.slot] = null
	_sfx("shatter")
	shake = maxf(shake, 0.2)
	var origin: Vector3 = c.global_position
	var cols := 4
	var rows := 5
	var pw: float = CardScript.W / cols
	var ph: float = CardScript.D / rows
	for ix in cols:
		for iz in rows:
			var piece := MeshInstance3D.new()
			var pm := BoxMesh.new()
			pm.size = Vector3(pw * 0.94, 0.04, ph * 0.94)
			piece.mesh = pm
			var m := StandardMaterial3D.new()
			m.albedo_texture = c.tex
			m.uv1_scale = Vector3(1.0 / cols, 1.0 / rows, 1)
			m.uv1_offset = Vector3(float(ix) / cols, float(iz) / rows, 0)
			m.emission_enabled = true
			m.emission = CardScript.RARITY_COL.get(c.rarity, Color.WHITE)
			m.emission_energy_multiplier = 0.25
			piece.material_override = m
			var local := Vector3(-CardScript.W * 0.5 + pw * (ix + 0.5), 0.05, -CardScript.D * 0.5 + ph * (iz + 0.5)) * CARD_SCALE
			piece.scale = Vector3.ONE * CARD_SCALE
			piece.position = origin + local
			add_child(piece)
			var v := Vector3(local.x * 2.2, randf_range(2.5, 5.0), local.z * 1.6) + Vector3(randf_range(-0.6, 0.6), 0, randf_range(-0.6, 0.6))
			fragments.append({"n": piece, "v": v, "s": Vector3(randf_range(-9, 9), randf_range(-9, 9), randf_range(-9, 9)), "life": 1.6})
	_impact_flash(origin + Vector3(0, 0.3, 0), CardScript.RARITY_COL.get(c.rarity, Color.WHITE))
	c.queue_free()
	if shots and not _shot_shatter:
		_shot_shatter = true
		get_tree().create_timer(0.25).timeout.connect(func(): _shot("shatter"))


func _impact_flash(pos: Vector3, col: Color) -> void:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = col
	l.light_energy = 4.0
	l.omni_range = 3.5
	add_child(l)
	var tw := create_tween()
	tw.tween_property(l, "light_energy", 0.0, 0.45)
	tw.tween_callback(l.queue_free)


func _float_text(t: String, pos: Vector3, col: Color) -> void:
	var l := Label3D.new()
	l.text = t
	l.font_size = 120
	l.pixel_size = 0.006
	l.outline_size = 16
	l.modulate = col
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.position = pos
	add_child(l)
	var tw := create_tween()
	tw.tween_property(l, "position", pos + Vector3(0, 1.4, 0), 1.1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(l, "modulate:a", 0.0, 1.1).set_delay(0.35)
	tw.parallel().tween_property(l, "outline_modulate:a", 0.0, 1.1).set_delay(0.35)
	tw.tween_callback(l.queue_free)


# ---------------------------------------------------------------- per frame
func _process(delta: float) -> void:
	for s in spin_nodes:
		s[0].rotate(s[1], s[2] * delta)
	for o in orbit_pivots:
		o[0].rotate_y(o[1] * delta)
	stars.rotate_y(0.004 * delta)

	# fragments fall through the table and fade
	var keep := []
	for f in fragments:
		f.life -= delta
		f.v.y -= 11.0 * delta
		var n: MeshInstance3D = f.n
		n.position += f.v * delta
		n.rotation += f.s * delta
		if f.life < 0.5:
			n.scale = Vector3.ONE * maxf(f.life / 0.5, 0.01)
		if f.life > 0.0:
			keep.append(f)
		else:
			n.queue_free()
	fragments = keep

	# camera framing: keep the whole board visible on any landscape/portrait aspect
	var vs := get_viewport().get_visible_rect().size
	var aspect := vs.x / maxf(vs.y, 1.0)
	if aspect >= 1.7:
		cam.keep_aspect = Camera3D.KEEP_HEIGHT
		cam.fov = 50.0
	else:
		cam.keep_aspect = Camera3D.KEEP_WIDTH
		cam.fov = 76.0
	rotate_hint.visible = aspect < 1.0 and state != "title"

	var tr := cam_base
	if shake > 0.0:
		shake = maxf(0.0, shake - delta)
		tr.origin += Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * shake * 0.35
	cam.transform = tr


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("user://shot_%s.png" % name)
	print("SHOT ", ProjectSettings.globalize_path("user://shot_%s.png" % name))
