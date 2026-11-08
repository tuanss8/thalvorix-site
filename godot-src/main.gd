extends Node3D
## THALVORIX Duel Arena 3D - playable prototype.
## Player vs bot, 5 slots per side, 1000 LP each (LP damage = ATK/DEF gap x DMG_SCALE).
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
const LP_MAX := 1000
const DMG_SCALE := 0.25        # ATK/DEF gap -> LP damage (stats stay in the thousands)
const LpHud := preload("res://lp_hud.gd")
const DECK_SIZE := 8
const RARITIES := ["Common", "Uncommon", "Rare", "Epic", "Legendary"]
const RARITY_W := [40, 27, 18, 10, 5]
const RARITY_POW := {"Common": 1.0, "Uncommon": 1.07, "Rare": 1.14, "Epic": 1.22, "Legendary": 1.32}

var cam: Camera3D
var cam_base := Transform3D()
var shake := 0.0
# zoom / pan (pinch, wheel, magnify, on-screen buttons). zoom = distance multiplier.
const ZOOM_MIN := 0.6
const ZOOM_MAX := 2.2
const CAM_TARGET := Vector3(0, 0, 0.55)
const DRAG_PX := 18.0
var cam_dir := Vector3.UP
var cam_dist := 10.0
var zoom := 1.0
var zoom_t := 1.0
var pan := Vector2.ZERO        # x / z offset of the look-at point on the table
var pan_t := Vector2.ZERO
# orbit: camera yaw around the table (one-finger horizontal drag, mouse drag, arrow keys)
const ORBIT_MAX := deg_to_rad(70.0)
const ORBIT_PER_SCREEN := PI          # yaw for a drag across the full screen width
const ORBIT_KEY_STEP := deg_to_rad(12.0)
var orbit := 0.0
var orbit_t := 0.0
var touches := {}              # touch index -> position
var pinch_prev := 0.0
var pinch_mid_prev := Vector2.ZERO
var multi := false             # a 2+ finger gesture happened since the last first-finger press
var press_active := false
var press_pos := Vector2.ZERO
var last_drag := Vector2.ZERO
var dragging := false
var zoom_ui: Control
var zoom_btns := []
var zoom_ui_mode := -1         # 0 landscape, 1 portrait
var star_layers := []          # [node, follow factor] parallax layers
var _js_cam_sent := Vector3(-1, -1, -1)
var _js_orbit_sent := -999.0
var spin_nodes := []          # [node, axis, speed]
var orbit_pivots := []        # [node, speed]
var stars: MultiMeshInstance3D
var textures := {}
var _rim_shader: Shader

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


# Startup timing marks: window.THX_T[name] = performance.now() on the web (for load-time tests).
func _mark(n: String) -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("(window.THX_T=window.THX_T||{})['%s']=Math.round(performance.now())" % n)
	else:
		print("THXT ", n, " ", Time.get_ticks_msec())


func _ready() -> void:
	_mark("ready")
	randomize()
	var args := OS.get_cmdline_user_args()
	autoplay = args.has("--autoplay")
	shots = args.has("--shots")
	_read_wallet_deck()
	# Keep the first frame light: on the web, startGame() only resolves (and the
	# loading overlay only hides) after _ready + the first frame have run
	# synchronously. Build the scene over the next frames instead.
	# Order: lights/camera -> table + title UI -> (title on screen) -> space backdrop.
	# The backdrop is built progressively *after* the title is visible; its
	# textures are pre-baked PNGs (res://space/), not generated per pixel here.
	_build_env()
	await get_tree().process_frame
	_build_table()
	_build_ui()
	_build_audio()
	_mark("ui_built")
	await get_tree().process_frame
	_mark("title_frame")
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.THX_onTitle&&window.THX_onTitle()")
	await get_tree().process_frame
	_build_space()           # coroutine: builds the backdrop over the next frames
	if shots:
		get_tree().create_timer(0.5).timeout.connect(func(): _shot("title"))
	if autoplay:
		get_tree().create_timer(1.0).timeout.connect(_on_play_pressed)


# ---------------------------------------------------------------- wallet deck
# index.html may set window.THX_DECK = {wallet, heroes:[{token, hero, rar}]}
# after a read-only scan of the player's THALVORIX Hero NFTs on BNB Chain.
var my_deck := []            # hero dicts (with "token" and "rar") owned by the player
var my_wallet := ""


func _read_wallet_deck() -> void:
	if not OS.has_feature("web"):
		return
	var raw = JavaScriptBridge.eval("JSON.stringify(window.THX_DECK || null)", true)
	if typeof(raw) != TYPE_STRING:
		return
	var d = JSON.parse_string(raw)
	if not (d is Dictionary):
		return
	my_wallet = str(d.get("wallet", ""))
	var list = d.get("heroes", [])
	if not (list is Array):
		return
	for n in list:
		if not (n is Dictionary):
			continue
		var base := HeroData.by_id(int(n.get("hero", -1)))
		if base.is_empty():
			continue
		var h: Dictionary = base.duplicate()
		h["token"] = int(n.get("token", 0))
		var r := str(n.get("rar", ""))
		if RARITIES.has(r):
			h["rar"] = r
		my_deck.append(h)


func _deck_line() -> String:
	if my_deck.size() > 0:
		var w := my_wallet
		if w.length() > 10:
			w = w.substr(0, 6) + "…" + w.substr(w.length() - 4)
		return "Your deck: %d of your Hero NFTs (%s)" % [my_deck.size(), w]
	if my_wallet != "":
		return "No Hero NFTs found in this wallet: playing with random heroes"
	return "Random heroes (no wallet connected)"


func _tex(id: int) -> Texture2D:
	if not textures.has(id):
		textures[id] = load("res://heroes/h%d.jpg" % id)
	return textures[id]


# ---------------------------------------------------------------- scene
func _build_env() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.008, 0.035)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.42, 0.36, 0.6)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# No glow: in the Compatibility renderer on WebGL2 the glow pass crashed the
	# browser GPU process (WebGL context lost) during the first frame, which left
	# the loading screen stuck. Emission materials carry the look instead.
	env.glow_enabled = false
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
	cam_dir = (cam.position - CAM_TARGET).normalized()
	cam_dist = (cam.position - CAM_TARGET).length()
	cam.far = 400.0
	cam.current = true


# Glass board slot: see-through tinted fill, brighter toward the edges, with a
# thin bright rim drawn in the same pass (unshaded, alpha blend, no depth write,
# so cards resting on top always win the depth test; no glow pass needed).
const SLOT_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
uniform vec4 tint : source_color = vec4(0.3, 0.6, 1.0, 1.0);
void fragment() {
	vec2 q = abs(UV - 0.5) * 2.0;              // 0 center .. 1 edge
	float sx = 1.66, sz = 2.3;                 // plate size, to keep the rim width even
	float ex = (1.0 - q.x) * sx * 0.5, ez = (1.0 - q.y) * sz * 0.5;
	float e = min(ex, ez);                     // distance to edge in world units
	float rim = 1.0 - smoothstep(0.012, 0.03, e);
	float inner = 1.0 - smoothstep(0.07, 0.09, e);
	float inner_line = inner * smoothstep(0.05, 0.07, e);
	float fade = smoothstep(0.15, 1.0, length(q) * 0.7071);   // soft radial, no diagonal seams
	float diag = UV.x * 0.82 + UV.y * 0.57;
	float sheen = smoothstep(0.30, 0.42, diag) * (1.0 - smoothstep(0.42, 0.60, diag));  // glass reflection streak
	float corner = step(min(ex, ez), 0.2) * step(max(ex, ez), 0.2) * (1.0 - smoothstep(0.0, 0.03, e));
	float a = 0.10 + 0.16 * fade + 0.07 * sheen + 0.55 * inner_line + 0.9 * rim + corner * 0.5;
	ALBEDO = mix(tint.rgb * 0.9, vec3(1.0), rim * 0.45 + corner * 0.3 + sheen * 0.35) * (1.0 + rim * 0.6);
	ALPHA = clamp(a, 0.0, 1.0) * 0.95;
}
"""
var _slot_shader: Shader
func _slot_shader_get() -> Shader:
	if _slot_shader == null:
		_slot_shader = Shader.new()
		_slot_shader.code = SLOT_SHADER
	return _slot_shader


func _unshaded(color: Color, energy := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color * energy
	return m


# ---------------------------------------------------------------- 3D space backdrop
# Everything is generated in code: small procedural textures (<=128 px), low-poly
# spheres, unshaded/additive materials for stars and nebula. No glow pass.
const STAR_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform float twinkle = 1.0;
varying float phase;
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	phase = INSTANCE_CUSTOM.x * 6.2831;
}
void fragment() {
	vec2 d = UV * 2.0 - 1.0;
	float r = dot(d, d);
	float a = exp(-r * 10.0) + exp(-r * 3.0) * 0.28;
	float tw = 1.0 - twinkle * 0.4 * (0.5 + 0.5 * sin(TIME * (1.2 + phase * 0.4) + phase * 5.0));
	ALBEDO = COLOR.rgb * tw;
	ALPHA = clamp(a, 0.0, 1.0);
}
"""
const RIM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;
uniform vec4 rim_color : source_color = vec4(0.4, 0.6, 1.0, 1.0);
uniform float power = 3.0;
void fragment() {
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), power);
	ALBEDO = rim_color.rgb;
	ALPHA = clamp(f * rim_color.a, 0.0, 1.0);
}
"""


func _build_space() -> void:
	# --- starfield: 3 layers. Far layers follow the camera (skybox-like), the near
	# layer stays put, so zooming / panning gives visible depth parallax.
	var star_mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = STAR_SHADER
	star_mat.shader = sh
	var tints := [Color(1, 1, 1), Color(0.72, 0.82, 1.0), Color(1.0, 0.86, 0.68), Color(0.9, 0.74, 1.0), Color(0.7, 1.0, 0.95)]
	# [count, radius min, radius max, size min, size max, follow]
	for L in [[620, 85.0, 110.0, 0.55, 1.2, 1.0], [300, 48.0, 62.0, 0.4, 0.9, 0.55], [110, 22.0, 32.0, 0.22, 0.5, 0.0]]:
		var q := QuadMesh.new()
		q.size = Vector2.ONE
		q.material = star_mat
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = q
		mm.instance_count = L[0]
		for i in mm.instance_count:
			var dir := Vector3(randf_range(-1, 1), randf_range(-1, 0.35), randf_range(-1, 1)).normalized()
			if L[5] == 0.0 and dir.y > -0.12:
				dir.y = -randf_range(0.12, 0.9)      # near layer only below the table plane
				dir = dir.normalized()
			var sz := randf_range(L[3], L[4]) * (2.2 if randf() < 0.04 else 1.0)
			mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(sz, sz, sz)), dir * randf_range(L[1], L[2])))
			mm.set_instance_color(i, tints[i % tints.size()] * randf_range(0.55, 1.5))
			mm.set_instance_custom_data(i, Color(randf(), 0, 0, 0))
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		star_layers.append([mi, L[5]])
		if stars == null:
			stars = mi
	_mark("sp_stars")
	await get_tree().process_frame

	# --- nebula: big additive billboards with a soft procedural cloud texture
	var neb_root := Node3D.new()
	add_child(neb_root)
	star_layers.append([neb_root, 0.85])
	var neb_tex := _space_tex("nebula_a")
	var neb_tex2 := _space_tex("nebula_b")
	# [pos, size, color]
	for nb in [[Vector3(-24, -34, -60), 70.0, Color(0.55, 0.18, 0.75, 0.55)],
			[Vector3(28, -30, -55), 60.0, Color(0.12, 0.42, 0.75, 0.5)],
			[Vector3(2, -55, -40), 80.0, Color(0.7, 0.16, 0.42, 0.38)],
			[Vector3(-48, -40, -8), 60.0, Color(0.2, 0.5, 0.7, 0.4)],
			[Vector3(48, -42, -2), 64.0, Color(0.5, 0.2, 0.8, 0.42)],
			[Vector3(0, -60, 20), 80.0, Color(0.3, 0.12, 0.55, 0.4)]]:
		var m := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(nb[1], nb[1])
		m.mesh = qm
		var nm := StandardMaterial3D.new()
		nm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		nm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		nm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		nm.no_depth_test = false
		nm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		nm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		nm.albedo_texture = neb_tex if randf() < 0.5 else neb_tex2
		nm.albedo_color = nb[2]
		nm.disable_receive_shadows = true
		m.material_override = nm
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.position = nb[0]
		m.rotation.z = randf() * TAU
		neb_root.add_child(m)
	_mark("sp_nebula")
	await get_tree().process_frame

	# --- planets (lit by the sun, procedural equirectangular textures)
	var lava := _planet(Vector3(-13.5, -12.0, -21.0), 4.6,
		_space_tex("planet_lava"), 0.06, Color(1.0, 0.45, 0.2, 0.9))
	await get_tree().process_frame
	var ringed := _planet(Vector3(14.0, -9.0, -17.0), 2.8,
		_space_tex("planet_ringed"), -0.1, Color(0.65, 0.5, 1.0, 0.8))
	ringed.rotation_degrees = Vector3(22, 0, -18)
	var ring := MeshInstance3D.new()
	ring.mesh = _ring_mesh(3.7, 6.3, 72)
	var rmat := StandardMaterial3D.new()
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	rmat.albedo_texture = _space_tex("ring")
	rmat.albedo_color = Color(1.0, 0.92, 1.0, 0.9)
	ring.material_override = rmat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ring_pivot := Node3D.new()
	ring_pivot.position = ringed.position
	ring_pivot.rotation_degrees = Vector3(22, 0, -18)
	add_child(ring_pivot)
	ring_pivot.add_child(ring)
	spin_nodes.append([ring, Vector3.UP, 0.03])
	await get_tree().process_frame
	_planet(Vector3(9.5, -21.0, -33.0), 3.3,
		_space_tex("planet_earth"), 0.09, Color(0.35, 0.7, 1.0, 1.0))
	await get_tree().process_frame
	_planet(Vector3(-7.0, -27.0, -42.0), 2.1,
		_space_tex("planet_ice"), 0.14, Color(0.5, 0.9, 1.0, 0.7))
	await get_tree().process_frame

	# moon orbiting the big planet
	var pivot := Node3D.new()
	pivot.position = lava.position
	pivot.rotation_degrees.z = 12
	add_child(pivot)
	var moon := _planet(Vector3(7.8, 1.5, 0), 0.95,
		_space_tex("planet_moon"), 0.2, Color(0, 0, 0, 0), pivot)
	moon.rotation_degrees.z = 0
	orbit_pivots.append([pivot, 0.16])
	_mark("sp_planets")

	# distant sun: unshaded core + additive corona billboard
	var sun := MeshInstance3D.new()
	var ss := SphereMesh.new()
	ss.radius = 2.0
	ss.height = 4.0
	ss.radial_segments = 16
	ss.rings = 8
	sun.mesh = ss
	sun.material_override = _unshaded(Color(1.0, 0.86, 0.55), 1.3)
	sun.position = Vector3(30.0, -24.0, -70.0)
	add_child(sun)
	var cor := MeshInstance3D.new()
	var cq := QuadMesh.new()
	cq.size = Vector2(16, 16)
	cor.mesh = cq
	var cm := StandardMaterial3D.new()
	cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	cm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	cm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	cm.albedo_texture = _space_tex("radial")
	cm.albedo_color = Color(1.0, 0.7, 0.35, 0.9)
	cor.material_override = cm
	cor.position = sun.position
	add_child(cor)
	await get_tree().process_frame

	# small asteroid field drifting between the planets
	var rock := SphereMesh.new()
	rock.radius = 0.5
	rock.height = 1.0
	rock.radial_segments = 6
	rock.rings = 3
	var rkm := StandardMaterial3D.new()
	rkm.albedo_color = Color(0.45, 0.38, 0.42)
	rkm.roughness = 1.0
	rock.material = rkm
	var amm := MultiMesh.new()
	amm.transform_format = MultiMesh.TRANSFORM_3D
	amm.mesh = rock
	amm.instance_count = 46
	for i in amm.instance_count:
		var ang := randf() * TAU
		var rr := randf_range(15.0, 22.0)
		var b := Basis(Vector3(randf(), randf(), randf()).normalized(), randf() * TAU)
		b = b.scaled(Vector3(randf_range(0.3, 1.0), randf_range(0.25, 0.7), randf_range(0.3, 0.9)))
		amm.set_instance_transform(i, Transform3D(b, Vector3(cos(ang) * rr, randf_range(-1.2, 1.2), sin(ang) * rr)))
	var belt := MultiMeshInstance3D.new()
	belt.multimesh = amm
	belt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	belt.position = Vector3(0, -14.0, -6.0)
	belt.rotation_degrees.x = 8
	add_child(belt)
	spin_nodes.append([belt, Vector3.UP, 0.02])
	_mark("space_built")
	await get_tree().process_frame
	await get_tree().process_frame
	_mark("space_done")
	_prewarm_card()


# Draw one card hidden under the table for a couple of frames while the title is
# up, so its materials / Label3D shaders are compiled before Play (no hitch when
# the first cards fly in).
func _prewarm_card() -> void:
	var pool: Array = HeroData.default_pool()
	if pool.is_empty():
		return
	var c := _make_card(pool[0], 0)
	c.visible = true
	c.position = Vector3(0, -0.9, 0.5)
	c.rotation = Vector3.ZERO
	await get_tree().process_frame
	c.rotation = Vector3(0, 0, PI)     # back face too
	await get_tree().process_frame
	await get_tree().process_frame
	c.queue_free()
	_mark("prewarm_done")


func _planet(pos: Vector3, radius: float, tex: Texture2D, spin: float, rim := Color(0, 0, 0, 0), parent: Node = null) -> MeshInstance3D:
	var p := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = radius
	s.height = radius * 2.0
	s.radial_segments = 28 if radius > 2.0 else 18
	s.rings = 14 if radius > 2.0 else 9
	p.mesh = s
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.roughness = 1.0
	m.metallic_specular = 0.1
	m.emission_enabled = true          # faint night side so planets never go black
	m.emission_texture = tex
	m.emission = Color.WHITE
	m.emission_energy_multiplier = 0.22
	p.material_override = m
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = pos
	p.rotation_degrees.z = 15
	(parent if parent != null else self).add_child(p)
	if spin != 0.0:
		spin_nodes.append([p, Vector3.UP, spin])
	if rim.a > 0.0:
		var at := MeshInstance3D.new()
		var as_ := SphereMesh.new()
		as_.radius = radius * 1.07
		as_.height = radius * 2.14
		as_.radial_segments = 24
		as_.rings = 12
		at.mesh = as_
		var am := ShaderMaterial.new()
		if _rim_shader == null:            # one shared Shader = one GPU program compile
			_rim_shader = Shader.new()
			_rim_shader.code = RIM_SHADER
		am.shader = _rim_shader
		am.set_shader_parameter("rim_color", rim)
		at.material_override = am
		at.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		at.position = pos
		(parent if parent != null else self).add_child(at)
	return p


# Backdrop textures are baked from the generators below (same seeds, same output)
# into res://space/*.png, so startup does no per-pixel GDScript work. Re-bake with
# `godot --headless --path godot-src -s res://tools/bake_space.gd` after changing them.
func _space_tex(n: String) -> Texture2D:
	return load("res://space/%s.png" % n)


# equirectangular planet texture, sampled on the sphere so it wraps seamlessly
func _planet_tex(kind: String, seed_: int, c1: Color, c2: Color, c3: Color) -> ImageTexture:
	var w := 128
	var h := 64
	var n := FastNoiseLite.new()
	n.seed = seed_
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 4
	n.frequency = 0.9
	var craters := []
	if kind == "moon":
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_
		for i in 16:
			craters.append([Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.08, 0.32)])
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in h:
		var lat := (float(y) + 0.5) / h * PI - PI * 0.5
		var cl := cos(lat)
		for x in w:
			var lon := float(x) / w * TAU
			var p := Vector3(cl * cos(lon), sin(lat), cl * sin(lon))
			var col: Color
			match kind:
				"gas":
					var t := n.get_noise_3dv(p * 1.6)
					var v := 0.5 + 0.5 * sin(lat * 14.0 + t * 4.0)
					col = c1.lerp(c2, v)
					var storm := p.distance_to(Vector3(0.75, -0.35, 0.56))
					if storm < 0.28:
						col = col.lerp(c3, (1.0 - storm / 0.28) * 0.8)
				"rock":
					var v := n.get_noise_3dv(p * 1.3) * 0.5 + 0.5
					col = c1.lerp(c2, smoothstep(0.3, 0.75, v))
					var crack := absf(n.get_noise_3dv(p * 3.1 + Vector3(9, 4, 2)))
					if crack < 0.05:
						col = col.lerp(c3, 1.0 - crack / 0.05)
				"earth":
					var v := n.get_noise_3dv(p * 1.2) * 0.5 + 0.5
					col = c1.lerp(c1 * 1.5, v) if v < 0.53 else c2.lerp(Color(0.55, 0.45, 0.25), smoothstep(0.6, 0.8, v))
					if absf(lat) > 1.2:
						col = col.lerp(c3, smoothstep(1.2, 1.35, absf(lat)))
					var cloud := n.get_noise_3dv(p * 2.4 + Vector3(5, 0, 3))
					if cloud > 0.15:
						col = col.lerp(c3, clampf((cloud - 0.15) * 2.5, 0.0, 0.75))
				_:  # moon
					var v := n.get_noise_3dv(p * 2.0) * 0.5 + 0.5
					col = c1.lerp(c2, v)
					for c in craters:
						var dd: float = p.distance_to(c[0]) / c[1]
						if dd < 1.0:
							col = col.lerp(c3, 0.45) if dd < 0.8 else col.lerp(c2 * 1.15, 0.5)
			img.set_pixel(x, y, col)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _nebula_tex(seed_: int) -> ImageTexture:
	var sz := 96
	var n := FastNoiseLite.new()
	n.seed = seed_
	n.fractal_octaves = 4
	n.frequency = 0.035
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	for y in sz:
		for x in sz:
			var d := Vector2(x - sz * 0.5, y - sz * 0.5).length() / (sz * 0.5)
			var fall := clampf(1.0 - d, 0.0, 1.0)
			fall = fall * fall * (3.0 - 2.0 * fall)
			var v := n.get_noise_2d(x, y) * 0.5 + 0.5
			var a := clampf(fall * (0.25 + v * 1.1), 0.0, 1.0)
			img.set_pixel(x, y, Color(0.75 + v * 0.25, 0.75 + v * 0.25, 1.0, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _radial_tex() -> ImageTexture:
	var sz := 64
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	for y in sz:
		for x in sz:
			var d := Vector2(x - sz * 0.5 + 0.5, y - sz * 0.5 + 0.5).length() / (sz * 0.5)
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _ring_tex(seed_: int) -> ImageTexture:
	var w := 128
	var n := FastNoiseLite.new()
	n.seed = seed_
	n.frequency = 0.09
	var img := Image.create(w, 2, false, Image.FORMAT_RGBA8)
	for x in w:
		var t := float(x) / (w - 1)
		var v := n.get_noise_1d(x) * 0.5 + 0.5
		var edge := smoothstep(0.0, 0.08, t) * (1.0 - smoothstep(0.9, 1.0, t))
		var gap := 0.25 if absf(t - 0.62) < 0.035 else 1.0
		var col := Color(0.75, 0.6, 0.95).lerp(Color(1.0, 0.88, 0.75), v)
		col.a = clampf(edge * gap * (0.25 + v * 0.75), 0.0, 1.0)
		img.set_pixel(x, 0, col)
		img.set_pixel(x, 1, col)
	return ImageTexture.create_from_image(img)


# flat annulus in the XZ plane, UV.x = radial position (inner 0 -> outer 1)
func _ring_mesh(r0: float, r1: float, seg: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in seg:
		var a0 := float(i) / seg * TAU
		var a1 := float(i + 1) / seg * TAU
		var p00 := Vector3(cos(a0) * r0, 0, sin(a0) * r0)
		var p01 := Vector3(cos(a0) * r1, 0, sin(a0) * r1)
		var p10 := Vector3(cos(a1) * r0, 0, sin(a1) * r0)
		var p11 := Vector3(cos(a1) * r1, 0, sin(a1) * r1)
		for v in [[p00, 0.0], [p01, 1.0], [p11, 1.0], [p00, 0.0], [p11, 1.0], [p10, 0.0]]:
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(v[1], 0.5))
			st.add_vertex(v[0])
	return st.commit()


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
			var m := ShaderMaterial.new()
			m.shader = _slot_shader_get()
			m.set_shader_parameter("tint", c)
			sl.material_override = m
			sl.position = Vector3(SLOT_X[i], 0.004, ROW_Z[side])
			add_child(sl)
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
		var ptop := MeshInstance3D.new()
		var ptm := PlaneMesh.new()
		ptm.size = Vector2(1.4, 2.0)
		ptop.mesh = ptm
		ptop.material_override = CardScript._back_material()
		ptop.position = DECK_POS[side] + Vector3(0, 0.502, 0)
		add_child(ptop)
		var pl := Label3D.new()
		pl.font_size = 64
		pl.pixel_size = 0.005
		pl.outline_size = 10
		pl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		pl.modulate = Color(1, 0.85, 0.4)
		pl.position = DECK_POS[side] + Vector3(0, 0.9, 0)
		add_child(pl)
		piles.append([pile, pl, ptop])
	_update_piles()


func _update_piles() -> void:
	for side in 2:
		var n: int = reserve[side].size()
		var pile: MeshInstance3D = piles[side][0]
		var h := maxf(0.02, n * 0.045)
		pile.scale = Vector3(1, h, 1)
		pile.position.y = h * 0.5
		pile.visible = n > 0
		var ptop: MeshInstance3D = piles[side][2]
		ptop.visible = n > 0
		ptop.position.y = h + 0.004
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

	# LP panels: enemy top-left, player bottom-left (custom-drawn pill, see lp_hud.gd)
	for side in 2:
		var hud: Control = LpHud.new()
		hud.setup(side, LP_MAX)
		if side == 1:
			hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
			hud.position = Vector2(16, 12)
		else:
			hud.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
			hud.offset_left = 16
			hud.offset_top = -76
			hud.offset_right = 16 + 340
			hud.offset_bottom = -14
		root.add_child(hud)
		lp_bar.append(hud)

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

	# zoom buttons: right edge, vertically centred, thumb-sized
	var zb := VBoxContainer.new()
	zb.add_theme_constant_override("separation", 12)
	zb.alignment = BoxContainer.ALIGNMENT_CENTER
	zb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for spec in [["+", 44, func(): _zoom_by(0.8)], ["−", 44, func(): _zoom_by(1.25)], ["Reset", 20, _zoom_reset]]:
		var b := _button(spec[0], spec[1])
		b.custom_minimum_size = Vector2(94, 84)
		b.focus_mode = Control.FOCUS_NONE
		b.modulate = Color(1, 1, 1, 0.82)
		b.pressed.connect(spec[2])
		zb.add_child(b)
		zoom_btns.append([b, spec[1]])
	root.add_child(zb)
	zoom_ui = zb
	_layout_zoom_ui(false)



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
	var deck_lbl := _label(_deck_line(), 22, Color(0.6, 0.95, 0.7) if my_deck.size() > 0 else Color(0.7, 0.7, 0.8))
	deck_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tv.add_child(deck_lbl)
	var how := _label("Tap one of your cards, then tap an enemy card to attack.\nATK beats DEF: a quarter of the gap hits Life Points (1000 LP).", 24, Color(0.9, 0.9, 0.95))
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


# The UI is laid out on a 1280-wide base, so in portrait it is drawn ~3x smaller:
# make the zoom buttons bigger there and move them to the empty area under the table.
func _layout_zoom_ui(portrait: bool) -> void:
	zoom_ui_mode = 1 if portrait else 0
	var bs := Vector2(170, 150) if portrait else Vector2(94, 84)
	for e in zoom_btns:
		var b: Button = e[0]
		b.custom_minimum_size = bs
		b.add_theme_font_size_override("font_size", int(e[1] * (1.7 if portrait else 1.0)))
	if portrait:
		zoom_ui.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		zoom_ui.offset_left = -200
		zoom_ui.offset_right = -24
		zoom_ui.offset_top = -760
		zoom_ui.offset_bottom = -230
	else:
		zoom_ui.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
		zoom_ui.offset_left = -112
		zoom_ui.offset_right = -18
		zoom_ui.offset_top = -150
		zoom_ui.offset_bottom = 150


func _toggle_mute() -> void:
	muted = not muted
	AudioServer.set_bus_mute(0, muted)
	mute_btn.text = "Sound: OFF" if muted else "Sound: ON"


func _set_status(t: String) -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.THX_STATUS=" + JSON.stringify(t))
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
	var rar := str(h.get("rar", ""))
	if not RARITIES.has(rar):
		rar = _pick_rarity()
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
	c.setup(h, _tex(int(h.id)), a, d, rar, side)
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
		# Cards are drawn with pop_back(), so the player's own NFTs go last
		# (drawn first); random heroes only pad a wallet with fewer than 8.
		var mine := []
		if side == 0 and my_deck.size() > 0:
			mine = my_deck.duplicate()
			mine.shuffle()
			mine = mine.slice(0, DECK_SIZE)
		var pool: Array = HeroData.default_pool()
		pool.shuffle()
		var deck := []
		var k := 0
		while deck.size() + mine.size() < DECK_SIZE:
			deck.append(pool[k % pool.size()])
			k += 1
		deck.append_array(mine)
		for h in deck:
			reserve[side].append(_make_card(h, side))
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


# ---------------------------------------------------------------- input: taps, zoom, pan
# Touch tracking runs in _input so a finger lifted over a UI control is never
# missed (a stale finger would make every later tap look like a pinch).
func _input(event: InputEvent) -> void:
	# arrow keys orbit (handled here, before GUI focus navigation can eat them)
	if event is InputEventKey and event.pressed and state != "title" and cam != null:
		if event.keycode == KEY_LEFT or event.keycode == KEY_RIGHT:
			var dir := 1.0 if event.keycode == KEY_LEFT else -1.0
			orbit_t = clampf(orbit_t + dir * ORBIT_KEY_STEP, -ORBIT_MAX, ORBIT_MAX)
			get_viewport().set_input_as_handled()
			return
	if event is InputEventScreenTouch:
		if event.pressed:
			touches[event.index] = event.position
		else:
			touches.erase(event.index)
		if touches.size() >= 2:
			multi = true
			_pinch_reset()
	elif event is InputEventScreenDrag:
		touches[event.index] = event.position
		if touches.size() >= 2:
			_pinch_update()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_MOUSE_EXIT:
		touches.clear()
		press_active = false
		dragging = false


func _unhandled_input(event: InputEvent) -> void:
	if cam == null:
		return
	if event is InputEventMagnifyGesture:
		if event.factor > 0.0:
			_zoom_by(1.0 / event.factor)
		return
	if event is InputEventMouseButton:
		var f: float = event.factor if event.factor > 0.0 else 1.0
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_by(pow(0.9, f))
			return
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_by(pow(1.0 / 0.9, f))
			return
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		if event.pressed:
			if touches.size() <= 1:
				multi = false        # a new gesture starts with the first finger
			press_active = true
			press_pos = event.position
			last_drag = event.position
			dragging = false
		else:
			var was_tap := press_active and not dragging and not multi
			press_active = false
			dragging = false
			if was_tap:
				_tap(event.position)
		return
	if event is InputEventMouseMotion and press_active and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		if multi or touches.size() >= 2:
			return
		if not dragging:
			# a press becomes a drag once the finger moved more than DRAG_PX; from then
			# on it is no longer a tap. Horizontal movement orbits the camera (two-finger
			# drag pans, see _pinch_update).
			if event.position.distance_to(press_pos) > DRAG_PX:
				dragging = true
				last_drag = event.position
			return
		_orbit_drag(event.position.x - last_drag.x)
		last_drag = event.position


func _orbit_drag(dx: float) -> void:
	if state == "title":
		return
	var w := maxf(get_viewport().get_visible_rect().size.x, 1.0)
	orbit_t = clampf(orbit_t - dx / w * ORBIT_PER_SCREEN, -ORBIT_MAX, ORBIT_MAX)


func _tap(pos: Vector2) -> void:
	if state != "player" or autoplay:
		return
	var c = _pick(pos)
	if c == null:
		return
	if c.side == 0:
		_select(null if c == selected else c)
	elif selected != null:
		var a = selected
		_attack(a, c)
	else:
		_set_status("First select one of YOUR cards (bottom row)")


func _zoom_by(f: float) -> void:
	if state == "title":
		return
	zoom_t = clampf(zoom_t * f, ZOOM_MIN, ZOOM_MAX)


func _zoom_reset() -> void:
	zoom_t = 1.0
	pan_t = Vector2.ZERO
	orbit_t = 0.0


func _pan_limit(z: float) -> Vector2:
	# a little two-finger pan is allowed at normal zoom too; more when zoomed in
	var k := clampf((1.0 - z) / (1.0 - ZOOM_MIN), 0.0, 1.0)
	var base := clampf((1.5 - z) / 0.5, 0.0, 1.0)
	return Vector2(5.0, 2.4) * k + Vector2(1.6, 0.9) * base


func _cam_transform(z: float, p: Vector2) -> Transform3D:
	var target := CAM_TARGET + Vector3(p.x, 0.0, p.y)
	var yaw := Basis(Vector3.UP, orbit)          # orbit around the (panned) look-at point
	return Transform3D(yaw * cam_base.basis, target + yaw * (cam_dir * cam_dist * z))


# point on the table plane (y = 0) under a screen position, for the current zoom/pan
func _ground_at(screen_pos: Vector2, z: float, p: Vector2) -> Vector3:
	var o := _cam_transform(z, p).origin
	var d := cam.project_ray_normal(screen_pos)   # direction only depends on the basis
	if d.y > -0.01:
		d.y = -0.01
	return o + d * (-o.y / d.y)


func _pan_drag(from: Vector2, to: Vector2) -> void:
	if state == "title":
		return
	var h0 := _ground_at(from, zoom, pan)
	var h1 := _ground_at(to, zoom, pan)
	pan_t -= Vector2(h1.x - h0.x, h1.z - h0.z)
	var lim := _pan_limit(zoom_t)
	pan_t = pan_t.clamp(-lim, lim)
	pan = pan_t                                  # 1:1 under the finger


func _two_touches() -> Array:
	var k := touches.keys()
	k.sort()
	return [touches[k[0]], touches[k[1]]]


func _pinch_reset() -> void:
	var t := _two_touches()
	pinch_prev = (t[0] as Vector2).distance_to(t[1])
	pinch_mid_prev = ((t[0] as Vector2) + t[1]) * 0.5
	press_active = false
	dragging = false


func _pinch_update() -> void:
	var t := _two_touches()
	var d := (t[0] as Vector2).distance_to(t[1])
	var mid: Vector2 = ((t[0] as Vector2) + t[1]) * 0.5
	if pinch_prev > 8.0 and d > 8.0:
		_zoom_by(pinch_prev / d)
	if _pan_limit(zoom_t).x > 0.05:
		_pan_drag(pinch_mid_prev, mid)
	pinch_prev = d
	pinch_mid_prev = mid


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
	var dmg: int = maxi(10, int(round(absf(diff) * DMG_SCALE / 10.0)) * 10)
	if diff > 0:
		diff = dmg
		lp[tgt.side] -= diff
		_float_text("-%d" % diff, tgt.position + Vector3(0, 0.8, 0), Color(1, 0.45, 0.4))
		await get_tree().create_timer(0.12).timeout
		_shatter(tgt)
		_set_status("%s destroys %s! %d damage to %s LP." % [a_name, t_name, diff, "enemy" if tgt.side == 1 else "your"])
	elif diff < 0:
		lp[att.side] -= dmg
		_float_text("-%d" % dmg, start + Vector3(0, 0.8, 0), Color(1, 0.45, 0.4))
		_set_status("%s blocks! DEF %d > ATK %d. %d recoil to %s LP." % [t_name, tgt.def, att.atk, dmg, "your" if att.side == 0 else "enemy"])
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
		lp_bar[side].set_lp(float(max(lp[side], 0)), instant)


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
var _lf_t := 0.0
func _process(delta: float) -> void:
	if _lf_t < 40.0:   # startup long-frame log (web tests): window.THX_T.long = [[t_ms, frame_ms], ...]
		_lf_t += delta
		if delta > 0.1 and OS.has_feature("web"):
			JavaScriptBridge.eval("(window.THX_T=window.THX_T||{});(THX_T.long=THX_T.long||[]).push([Math.round(performance.now()),%d])" % int(delta * 1000.0))
	if rotate_hint == null:
		return   # scene is still being built over the first frames
	for s in spin_nodes:
		s[0].rotate(s[1], s[2] * delta)
	for o in orbit_pivots:
		o[0].rotate_y(o[1] * delta)
	if stars != null:
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

	# smooth zoom / pan, then screen shake on top of the zoomed transform
	var k := 1.0 - exp(-12.0 * delta)
	zoom = lerpf(zoom, zoom_t, k)
	if absf(zoom - zoom_t) < 0.0005:
		zoom = zoom_t
	var lim := _pan_limit(zoom_t)
	pan_t = pan_t.clamp(-lim, lim)
	pan = pan.lerp(pan_t, k)
	orbit = lerpf(orbit, orbit_t, 1.0 - exp(-9.0 * delta))
	if absf(orbit - orbit_t) < 0.0005:
		orbit = orbit_t
	var tr := _cam_transform(zoom, pan)
	var cam_off := tr.origin - cam_base.origin
	for l in star_layers:
		(l[0] as Node3D).position = cam_off * float(l[1])
	if zoom_ui != null:
		zoom_ui.visible = state != "title"
		if zoom_ui_mode != (1 if aspect < 1.0 else 0):
			_layout_zoom_ui(aspect < 1.0)
	if shake > 0.0:
		shake = maxf(0.0, shake - delta)
		tr.origin += Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * shake * 0.35
	cam.transform = tr
	_publish_cam()


# window.THX_CAM = {zoom, panX, panZ} on the web, for automated tests (only when it changes)
func _publish_cam() -> void:
	if not OS.has_feature("web"):
		return
	var v := Vector3(snappedf(zoom_t, 0.01), snappedf(pan_t.x, 0.01), snappedf(pan_t.y, 0.01))
	var o := snappedf(rad_to_deg(orbit), 0.1)
	if v == _js_cam_sent and o == _js_orbit_sent:
		return
	_js_cam_sent = v
	_js_orbit_sent = o
	JavaScriptBridge.eval("window.THX_CAM={zoom:%s,panX:%s,panZ:%s,orbit:%s,orbitT:%s,state:'%s'}" % [v.x, v.y, v.z, o, snappedf(rad_to_deg(orbit_t), 0.1), state])


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("user://shot_%s.png" % name)
	print("SHOT ", ProjectSettings.globalize_path("user://shot_%s.png" % name))
