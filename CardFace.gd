@tool
class_name CardFace
extends Node2D
## Draws one playing card from layers, no textures:
##   face up:   body → corner index → pips (or court placeholder)
##   face down: body → inset back panel (the body shows as a white border)
## Only the top half of a face is described; the bottom half is the same
## drawing turned 180° about the card centre, as on a real card.
## It doesn't animate itself: Animations moves it. The card owns its scale —
## table size × size_factor × lift × pose — so what Animations does to any of
## those (a flip squeezes `pose`) composes with the rest; turn_over() swaps sides.
## Baked faces: all 53 faces (the 52 and the back) are rendered together, once,
## into one atlas — an offscreen image in a grid of cells at the card's
## on-screen pixel size — and it stays on the graphics card: nothing is copied
## back, so nothing waits on it. It's never bigger than ATLAS_MAX on a side
## (big cards on dense screens are drawn a little enlarged past that), so it
## fits every GPU and its memory stays capped. Every card then draws its own cell, a single
## texture draw instead of ~57. The atlas is made the first time a card is
## drawn (prebake() makes it sooner) and remade when the screen scale changes;
## until it's ready, cards draw their layers. The editor always draws the layers.

const SIZE := Vector2(88, 123)   # logical px (12% of the 720-wide portrait design, as in the Unity build)
const RECT := Rect2(-SIZE / 2, SIZE)   # card outline, centred on the node
const RANKS := ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
const RED := Color("#c8102e")
const BLACK := Color("#111111")
const BACK := Color("#1f4e9c")
const BACK_MARGIN := 5.0   # white border around the back panel, px
const BACK_KEY := -1   # bake-cache key for the back (fronts use their card_id)
const BAKE_HEADROOM := 1.1   # bake a little larger, so a lifted card stays sharp
const FACES := 53   # the 52 and the back
const ATLAS_COLUMNS := 9   # the atlas grid: 9 × 6 cells
const ATLAS_MAX := 2048   # px, the atlas's longest side: every GPU takes it, and it caps its memory at 16 MB
const BAKES_PER_FRAME := 2   # faces drawn into the atlas each frame (~2-4 ms each), so no frame stalls
const REDRAW_GROUP := &"card_faces"   # every card, told to redraw when the atlas is made

# Pip centres in 0..1 card space, top half only. Pips above the midline get an
# upside-down twin from the turned pass; pips on it (y = 0.5) are drawn once.
const L := 0.32
const C := 0.5
const R := 0.68
const PIPS := {
	1: [Vector2(C, 0.5)],
	2: [Vector2(C, 0.2)],
	3: [Vector2(C, 0.2), Vector2(C, 0.5)],
	4: [Vector2(L, 0.2), Vector2(R, 0.2)],
	5: [Vector2(L, 0.2), Vector2(R, 0.2), Vector2(C, 0.5)],
	6: [Vector2(L, 0.2), Vector2(R, 0.2), Vector2(L, 0.5), Vector2(R, 0.5)],
	7: [Vector2(L, 0.2), Vector2(R, 0.2), Vector2(L, 0.5), Vector2(R, 0.5)],   # + odd pip, see _draw_half
	8: [Vector2(L, 0.2), Vector2(R, 0.2), Vector2(C, 0.35), Vector2(L, 0.5), Vector2(R, 0.5)],
	9: [Vector2(L, 0.2), Vector2(R, 0.2), Vector2(L, 0.4), Vector2(R, 0.4), Vector2(C, 0.5)],
	10: [Vector2(L, 0.2), Vector2(R, 0.2), Vector2(L, 0.4), Vector2(R, 0.4), Vector2(C, 0.3)],
}

@export var font: Font   # rank text; falls back to the engine default font
@export_range(0, 103) var card_id := 0:   # deck * 52 + suit * 13 + rank - 1 (an expanded deck is two 52s; the face is id % 52)
	set(v):
		card_id = v
		queue_redraw()
@export var face_up := true:
	set(v):
		face_up = v
		queue_redraw()
@export var fixed := false   # can be tapped but not dragged (the deck, others' cards)

var rank: int:   # 1 = ace … 13 = king
	get: return card_id % 13 + 1
var suit: int:   # 0 ♠, 1 ♥, 2 ♦, 3 ♣
	get: return floori(card_id % 52 / 13.0)
var lift := 1.0:   # pick-up scale, set by PlayerControl
	set(v):
		lift = v
		refresh_scale()
var size_factor := 1.0:   # this card's size relative to a table card (an opponent's mirror is smaller)
	set(v):
		size_factor = v
		refresh_scale()
var pose := Vector2.ONE:   # a scale Animations may squeeze on top of the rest (a flip)
	set(v):
		pose = v
		refresh_scale()

var _baking := false   # this instance renders a face for the cache: always draw the layers

static var _body := _make_box(Color.WHITE, 6, Color(0, 0, 0, 0.25))
static var _back := _make_box(BACK, 4, Color.TRANSPARENT)
static var _suit_shapes := _make_suit_shapes()   # per suit: polygons, unit height, centred
static var _faces := {}   # face key (card id, or BACK_KEY) → its cell of the atlas
static var _atlas: SubViewport   # the render every face is drawn from, kept (not updated)
static var _atlas_scale := 0.0   # the scale it was made at
static var _baking_atlas := false
static var _baked_scale := 0.0   # screen px per card px faces are wanted at
# The engine's default font as plain glyphs: the menus draw it as a distance
# field (one cache for every size), but faces are baked once each, and in
# distance-field form baking them cost ~5 MB more video memory.
static var _rank_font: Font   # made on first use (the game loop has to exist)
static var card_scale := 1.0   # every card's size on the table (the player's Settings card size); SIZE is the design size


func _ready() -> void:
	if _baking:
		return   # a face render: drawn once, never redrawn or rescaled
	add_to_group(REDRAW_GROUP)
	get_viewport().size_changed.connect(queue_redraw)   # screen scale may have changed
	refresh_scale()


func has_point(world: Vector2) -> bool:
	return RECT.has_point(to_local(world))


func turn_over() -> void:
	face_up = not face_up


## The card's scale: table size × its own size factor × drag lift × pose.
func refresh_scale() -> void:
	if _baking:
		return   # a face being baked keeps its render scale
	scale = pose * lift * card_scale * size_factor


func _draw() -> void:
	if not _baking and not Engine.is_editor_hint():
		var px := minf(snappedf(_pixel_scale(), 0.01), _largest_bake())
		if px != _baked_scale:   # first card, or the screen or card size changed: (re)make the atlas
			_baked_scale = px
			prebake()
		var face: Texture2D = _faces.get(card_id % 52 if face_up else BACK_KEY)
		if face:
			draw_texture_rect(face, RECT, false)   # an old-size face stretches until the atlas is remade
			return
		# no atlas yet (a frame or two): draw the layers meanwhile
	draw_style_box(_body, RECT)
	if not face_up:
		draw_style_box(_back, RECT.grow(-BACK_MARGIN))
		return
	var ink := RED if suit == 1 or suit == 2 else BLACK
	for turn in 2:   # top half, then the same drawing turned 180°
		draw_set_transform(Vector2.ZERO, PI * turn)
		_draw_half(ink, turn == 0)
	draw_set_transform(Vector2.ZERO)


func _draw_half(ink: Color, upright: bool) -> void:
	_text(RANKS[rank - 1], Vector2(0.12, 0.09), 0.12, ink)   # corner index
	_suit(Vector2(0.12, 0.19), 0.08, ink)

	if rank > 10:   # placeholder court art until the J/Q/K SVGs arrive
		if upright:
			draw_rect(Rect2(SIZE * Vector2(-0.3, -0.36), SIZE * Vector2(0.6, 0.72)), ink, false, 1.0)
		_text(RANKS[rank - 1], Vector2(C, 0.27), 0.2, ink)
		_suit(Vector2(C, 0.4), 0.09, ink)
		return

	for p in PIPS[rank]:
		if p.y < 0.5 or upright:
			_suit(p, 0.32 if rank == 1 else 0.13, ink)
	if rank == 7 and upright:
		_suit(Vector2(C, 0.35), 0.13, ink)   # the 7's odd pip has no twin


# Text centred on `at` (0..1 card space), `height` as a fraction of card height.
func _text(t: String, at: Vector2, height: float, ink: Color) -> void:
	if _rank_font == null:
		_rank_font = _make_rank_font()
	var f: Font = font if font else _rank_font
	var px := int(SIZE.y * height)
	var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
	var baseline := Vector2(-w / 2, (f.get_ascent(px) - f.get_descent(px)) / 2)
	draw_string(f, _to_px(at) + baseline, t, HORIZONTAL_ALIGNMENT_LEFT, -1, px, ink)


# This card's suit symbol centred on `at`, `height` as a fraction of card height.
func _suit(at: Vector2, height: float, ink: Color) -> void:
	var xf := Transform2D(0.0, Vector2.ONE * SIZE.y * height, 0.0, _to_px(at))
	for shape in _suit_shapes[suit]:
		var pts: PackedVector2Array = xf * shape
		draw_colored_polygon(pts, ink)
		pts.append(pts[0])
		draw_polyline(pts, ink, 1.0, true)   # soft edge; filled polygons aren't antialiased


# Screen pixels per card pixel: camera zoom × stretch × card scale, with headroom for the lift.
func _pixel_scale() -> float:
	var canvas := get_canvas_transform().get_scale().x
	return canvas * get_viewport().get_final_transform().get_scale().x * card_scale * BAKE_HEADROOM


# The largest pixel scale whose atlas stays within ATLAS_MAX on both sides
# (each cell rounds up a pixel); past it, faces are drawn a little enlarged.
static func _largest_bake() -> float:
	var rows := ceili(FACES / float(ATLAS_COLUMNS))
	var largest := minf((ATLAS_MAX / float(ATLAS_COLUMNS) - 1.0) / SIZE.x, (ATLAS_MAX / float(rows) - 1.0) / SIZE.y)
	return floorf(largest * 100.0) / 100.0   # on the same 0.01 steps as the scale it caps


## Makes the atlas at the scale cards are drawn at (it waits for the first card
## drawn to say what that is). Called by the first card drawn and on any scale
## change; a match calls it as it opens, so faces are ready before they turn up.
static func prebake() -> void:
	if not _baking_atlas and (_atlas == null or _atlas_scale != _baked_scale):   # (none yet, or the wrong size)
		_bake_atlas()


# All 53 faces into one render, in a grid, BAKES_PER_FRAME at a time: the
# render is never cleared, so each frame adds its faces to the ones already
# there, and each face's drawing node goes once it's in. Then it's kept as it
# is (updates off) and every card redraws to pick up its cell. If the scale
# changed meanwhile, it's made again at the new one.
static func _bake_atlas() -> void:
	_baking_atlas = true
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame   # out of whichever _draw() started this: the render joins the tree at once below
	while _baked_scale <= 0.0:   # no card drawn yet to say what size faces are
		await tree.process_frame
	var px := _baked_scale
	var cell := Vector2i((SIZE * px).ceil())
	var atlas := SubViewport.new()
	atlas.transparent_bg = true
	atlas.size = cell * Vector2i(ATLAS_COLUMNS, ceili(FACES / float(ATLAS_COLUMNS)))
	atlas.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE   # cleared at the start, then faces only add up
	atlas.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(atlas)   # in the tree right away, so quitting frees it
	for first in range(0, FACES, BAKES_PER_FRAME):
		for i in range(first, mini(first + BAKES_PER_FRAME, FACES)):
			var baker := CardFace.new()
			baker._baking = true
			baker.face_up = i < FACES - 1   # the last cell is the back
			baker.card_id = i % (FACES - 1)
			baker.position = Vector2(cell * _cell_at(i)) + Vector2(cell) / 2
			baker.scale = Vector2.ONE * px
			atlas.add_child(baker)
		await tree.process_frame   # added this frame (rendered at its end)…
		await tree.process_frame   # …and safely in by the next. (The tree's frames, not the renderer's
		                           # signal: waiting on that at quitting can crash the engine.)
		for baker in atlas.get_children():
			baker.queue_free()   # in the render now; the drawing node isn't needed
	atlas.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if px != _baked_scale:   # the screen changed meanwhile: make it again at the new size
		atlas.queue_free()
		_bake_atlas()
		return
	var image := atlas.get_texture()
	for i in FACES:
		var face := AtlasTexture.new()
		face.atlas = image
		face.region = Rect2(cell * _cell_at(i), cell)
		_faces[i if i < FACES - 1 else BACK_KEY] = face
	tree.call_group(REDRAW_GROUP, "queue_redraw")
	if _atlas:
		var old := _atlas
		tree.process_frame.connect(old.queue_free, CONNECT_ONE_SHOT)   # once no card draws from it any more
	_atlas = atlas
	_atlas_scale = px
	_baking_atlas = false


# Column and row of face `i` in the atlas grid.
static func _cell_at(i: int) -> Vector2i:
	return Vector2i(i % ATLAS_COLUMNS, floori(i / float(ATLAS_COLUMNS)))


static func _to_px(p: Vector2) -> Vector2:
	return (p - Vector2(0.5, 0.5)) * SIZE


static func _make_rank_font() -> Font:
	var plain := ThemeDB.fallback_font.duplicate() as Font
	if plain is FontFile:
		plain.multichannel_signed_distance_field = false
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.tree_exiting.connect(func() -> void: CardFace._rank_font = null)   # its glyphs go before the renderer does
	return plain


static func _make_box(fill: Color, radius: int, outline: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_corner_radius_all(radius)
	box.set_border_width_all(1)
	box.border_color = outline
	return box


static func _make_suit_shapes() -> Array:
	var heart := PackedVector2Array()
	for i in 48:
		var t := TAU * i / 48.0
		heart.append(Vector2(16 * pow(sin(t), 3), -(13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t))))
	var spade := Transform2D.FLIP_Y * heart
	var stem := PackedVector2Array([Vector2(0, 0.05), Vector2(0.16, 0.5), Vector2(-0.16, 0.5)])
	return [
		[_fit(spade, 0.8, Vector2(0, -0.1)), stem],   # ♠
		[_fit(heart, 0.9, Vector2.ZERO)],   # ♥
		[PackedVector2Array([Vector2(0, -0.5), Vector2(0.36, 0), Vector2(0, 0.5), Vector2(-0.36, 0)])],   # ♦
		[_circle(Vector2(0, -0.25), 0.24), _circle(Vector2(-0.25, 0.07), 0.24), _circle(Vector2(0.25, 0.07), 0.24), stem],   # ♣
	]


# Scales and centres `pts` to `height` tall around `centre`.
static func _fit(pts: PackedVector2Array, height: float, centre: Vector2) -> PackedVector2Array:
	var box := Rect2(pts[0], Vector2.ZERO)
	for v in pts:
		box = box.expand(v)
	var out := PackedVector2Array()
	for v in pts:
		out.append((v - box.get_center()) * height / box.size.y + centre)
	return out


static func _circle(c: Vector2, r: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in 24:
		out.append(c + Vector2.from_angle(TAU * i / 24.0) * r)
	return out
