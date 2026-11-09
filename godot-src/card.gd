extends Node3D
## One duel card: a thin 3D box with hero art, name and ATK/DEF on the front,
## a THALVORIX back, and a glow plate used for selection / target hints.

const W := 1.3
const D := 1.85
const T := 0.05
const REST_Y := 0.03

const RARITY_COL := {
	"Common": Color(0.62, 0.64, 0.72),
	"Uncommon": Color(0.30, 0.85, 0.45),
	"Rare": Color(0.30, 0.58, 1.0),
	"Epic": Color(0.75, 0.38, 1.0),
	"Legendary": Color(1.0, 0.76, 0.22),
}

var hero: Dictionary = {}
var tex: Texture2D
var atk := 0
var def := 0
var rarity := "Common"
var side := 0          # 0 = player, 1 = bot
var slot := -1
var face_up := false
var alive := true

var _glow: MeshInstance3D
var _glow_mat: StandardMaterial3D
var _pulse := 0.0
var _glow_on := false


func setup(h: Dictionary, t: Texture2D, a: int, d: int, r: String, s: int) -> void:
	hero = h
	tex = t
	atk = a
	def = d
	rarity = r
	side = s
	var col: Color = RARITY_COL.get(r, Color.WHITE)

	# glow plate (under the card, slightly larger)
	_glow = MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(W + 0.22, 0.01, D + 0.22)
	_glow.mesh = gm
	_glow_mat = StandardMaterial3D.new()
	_glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glow_mat.albedo_color = Color(0.5, 0.9, 1.0, 0.0)
	_glow.material_override = _glow_mat
	_glow.position.y = 0.0  # centred in the body so only the rim shows, face up or down
	_glow.visible = false
	add_child(_glow)

	# body
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(W, T, D)
	body.mesh = bm
	var mm := StandardMaterial3D.new()
	mm.albedo_color = Color(0.10, 0.07, 0.16)
	mm.metallic = 0.5
	mm.roughness = 0.4
	body.material_override = mm
	add_child(body)

	# rarity frame on the front
	var frame := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(W - 0.03, 0.004, D - 0.03)
	frame.mesh = fm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = col * 0.7
	fmat.emission_enabled = true
	fmat.emission = col
	fmat.emission_energy_multiplier = 0.45
	frame.material_override = fmat
	frame.position.y = T * 0.5 + 0.002
	add_child(frame)

	var inner := MeshInstance3D.new()
	var inm := BoxMesh.new()
	inm.size = Vector3(W - 0.12, 0.004, D - 0.12)
	inner.mesh = inm
	var inmat := StandardMaterial3D.new()
	inmat.albedo_color = Color(0.05, 0.035, 0.09)
	inner.material_override = inmat
	inner.position.y = T * 0.5 + 0.005
	add_child(inner)

	# Dark stat strip behind ATK/DEF (like the 2D duel cards: bold stats on
	# a solid dark band, so the enemy's power is readable at a glance).
	var strip := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(W - 0.12, 0.004, 0.22)
	strip.mesh = sm
	var smat := StandardMaterial3D.new()
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smat.albedo_color = Color(0.02, 0.02, 0.05)
	strip.material_override = smat
	strip.position = Vector3(0, T * 0.5 + 0.007, D * 0.5 - 0.155)
	add_child(strip)

	# hero art
	var art_size := W - 0.16
	var art := MeshInstance3D.new()
	var q := PlaneMesh.new()
	q.size = Vector2(art_size, art_size)
	art.mesh = q
	var am := StandardMaterial3D.new()
	am.albedo_texture = t
	am.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	am.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	art.material_override = am
	art.position = Vector3(0, T * 0.5 + 0.009, -D * 0.5 + 0.08 + art_size * 0.5)
	add_child(art)

	var text_y := T * 0.5 + 0.012
	var name_lbl := _flat_label(String(h.get("name", "?")).to_upper(), 44, Color(1, 0.95, 0.85))
	name_lbl.position = Vector3(0, text_y, -D * 0.5 + 0.08 + art_size + 0.13)
	add_child(name_lbl)

	var role_txt := "%s · %s" % [h.get("role", ""), h.get("el", "")]
	if h.has("token"):
		role_txt = "#%d · %s" % [int(h.token), h.get("role", "")]
	var role_lbl := _flat_label(role_txt, 28, col.lightened(0.55))
	role_lbl.position = Vector3(0, text_y, name_lbl.position.z + 0.195)
	add_child(role_lbl)

	var atk_lbl := _flat_label("ATK %d" % a, 32, Color(1.0, 0.85, 0.7), 0.0042, 0.62)
	atk_lbl.position = Vector3(-W * 0.27, text_y, D * 0.5 - 0.155)
	add_child(atk_lbl)
	var def_lbl := _flat_label("DEF %d" % d, 32, Color(0.85, 0.95, 1.0), 0.0042, 0.62)
	def_lbl.position = Vector3(W * 0.27, text_y, D * 0.5 - 0.155)
	add_child(def_lbl)

	# back side (faces -Y; visible when the card lies face down)
	var back := MeshInstance3D.new()
	var bq := PlaneMesh.new()
	bq.size = Vector2(W - 0.08, D - 0.08)
	back.mesh = bq
	back.material_override = _back_material()
	back.rotation.z = PI
	back.position.y = -T * 0.5 - 0.002
	add_child(back)

# One shared material for every card back (baked texture, see tools/make_cardback.py).
static var _back_mat: StandardMaterial3D
static func _back_material() -> StandardMaterial3D:
	if _back_mat == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_texture = preload("res://cardback.png")
		m.albedo_color = Color(1.05, 1.05, 1.05)
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		_back_mat = m
	return _back_mat


func _flat_label(txt: String, size: int, color: Color, base_ps := 0.0045, max_w := 1.10) -> Label3D:
	var l := Label3D.new()
	l.text = txt
	# Render glyphs at 2x font size and halve pixel_size: same world size,
	# but much smoother letters (low-res glyph textures looked pixelated).
	var rs := size * 2
	l.font_size = rs
	var sw := ThemeDB.fallback_font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, rs).x
	l.pixel_size = minf(base_ps * 0.5, max_w / maxf(1.0, sw)) if sw > 0.0 else base_ps * 0.5
	l.outline_size = 20
	l.outline_modulate = Color(0, 0, 0, 0.9)
	l.modulate = color
	l.rotation.x = -PI * 0.5
	# No hard alpha cut: blend the glyph edges smoothly instead of the
	# jagged discard threshold.
	l.alpha_cut = Label3D.ALPHA_CUT_DISABLED
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	l.double_sided = false
	l.width = 1200
	return l


func set_glow(on: bool, color: Color = Color(0.5, 0.9, 1.0)) -> void:
	_glow_on = on
	_glow.visible = on
	_glow_mat.albedo_color = Color(color.r, color.g, color.b, 0.75)


func _process(delta: float) -> void:
	if _glow_on:
		_pulse += delta * 5.0
		_glow_mat.albedo_color.a = 0.45 + 0.35 * sin(_pulse)
