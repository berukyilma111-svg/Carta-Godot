class_name PlayerControl
extends Node
## This player: their input and their hand. It lives on this device only, and
## it's the go-between for the hand and the match: the Table is the match
## (shared by every player, through the authority) — this script asks it for
## things (a draw, a discard; taps on its cards, such as the deck or the starter
## grid, are its to decide) and takes what it hands back (my cards).
##   input — modelled on iPhone touch handling (UIKit's tap / pan / long press):
##     tap     — released before hold_time without moving past the slop. On one
##               of my cards: it flips (testing); on a table card → card_tapped.
##     drag    — past the slop (pan), or held still for hold_time (long press:
##               the card lifts with a haptic tick); my cards only, following
##               the finger
##     release — with the release velocity if it was a flick (faster than
##               flick_speed_pt), else zero
##   my hand — a row of slots along the bottom, hand_bottom off the safe edge. A
##     slot is an index into _hand_cards (slot 1 = index 0, leftmost); its spot
##     comes from that index and the hand size, so the row stays centred and
##     overlaps as it grows. Slot order is draw order (slot 1 lowest), the order
##     presses pick in, so they land on the card you see on top. Dragging opens
##     the slot nearest the card (the others shift aside), with a faint ghost of
##     it there while it's within reach; letting go drops it in — or onto the
##     pile, if it would come to rest there (Table.discard). Out of reach, or
##     flicked anywhere but the pile, it goes back to its own slot: cards can't
##     be left loose.
##   draws — predict_draw() puts a face-down card in a new slot at once while the
##     Table asks the authority; receive() gives it its id (or a dealt card
##     arrives), and it turns up once it has landed; draw_refused() sends it back.
##   rows — slot_position() / seat_row() lay out any row of cards: my hand here,
##     the opponents' mirrors on the Table.
## Tuning comes from the device's preset (Device.tuning), read live; the
## "device" section turns it into this screen's units (pointer type, pixel
## density, frame rate). Reads mouse events only — touch devices turn the first
## finger into these ("Emulate Mouse From Touch", on by default).

signal card_tapped(card: CardFace)   # a tap on a table card (the deck, the starter grid…): the Table's call

const GHOST_ALPHA := 0.35   # how solid the ghost in the open slot is

@export var table_data: Node2D   # every card on the table; its CardFace children take input
@export var table: Node2D   # the match: where requests go, and its layout (area, deck and pile spots)
@export_group("Hand")   # px in the 720×1280 design; defaults match the Unity build's proportions
@export var hand_bottom := 50.0   # gap between a row and the bottom (or top) of the safe area
@export var slot_step := 55.0   # between slot centres at card size 1 (grows with it), so cards overlap; less if the row won't fit

var tuning: InputTuning:
	get: return Device.tuning

# Input
var _card: CardFace   # card under the pointer, from press to release
var _touch := false   # this press came from a finger, not a mouse
var _press_pos := Vector2.ZERO   # viewport px at press
var _held_for := 0.0   # s since press, while it's still undecided
var _dragging := false
var _grab := Vector2.ZERO   # card centre minus the press point, world space
var _trail: Array[Vector3] = []   # recent drag points: x, y (world), time (s)
# My hand
var _hand_cards: Array[CardFace] = []   # index = slot (0 = slot 1, leftmost)
var _held: CardFace   # my card being dragged; seating leaves it to the finger
var _held_from := 0   # the slot it was picked up from
var _hover_slot := -1   # the slot the held card is over (within reach), else -1
var _ghost: CardFace   # faint copy of the held card in the slot it will land in
var _predicted: Array = []   # my draws awaiting the authority, oldest first: [card, lands_at]


func _ready() -> void:
	set_process(false)   # only runs while a press could still become a hold
	_ghost = CardFace.new()
	_ghost.modulate.a = GHOST_ALPHA
	_ghost.hide()
	table_data.add_child.call_deferred(_ghost)   # (the table is still setting up its children)


func _unhandled_input(event: InputEvent) -> void:
	if table_data == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press(event.position, event.device == InputEvent.DEVICE_ID_EMULATION)
		elif _card:
			_release()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _card:
		_move(event.position)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_held_for += delta
	if _held_for >= tuning.hold_time:   # long press: lift in place, follow once moved
		if _card.fixed:
			_clear()   # a fixed card only takes taps: a hold on it does nothing
			return
		Device.vibrate(tuning.hold_haptic_ms)
		_begin_drag()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _card:
		if _dragging:
			_let_go(_card, Vector2.ZERO)   # app backgrounded mid-drag: let go
		_clear()


# --- press lifecycle: decides between tap and drag ---------------------------

func _press(pos: Vector2, touch: bool) -> void:
	if not State.has_control():
		return   # e.g. while the match deals
	var card := _card_at(_world(pos))
	if card == null:
		return
	get_viewport().set_input_as_handled()
	if Animations.is_playing(card, &"flip"):
		return   # a mid-flip card blocks the press but can't be taken
	_card = card
	_touch = touch
	_press_pos = pos
	_held_for = 0.0
	set_process(true)


func _move(pos: Vector2) -> void:
	if not _dragging and _past_slop(pos):
		if _card.fixed:
			_clear()   # a fixed card only takes taps: a swipe on it does nothing
			return
		_begin_drag()   # pan
	if _dragging:
		_drag_to(pos)


func _release() -> void:
	if _dragging:
		_end_drag()
	else:
		_tap()
	_clear()


func _clear() -> void:
	_card = null
	_dragging = false
	set_process(false)


# --- tap -----------------------------------------------------------------------

func _tap() -> void:
	if _card in _hand_cards:
		Animations.flip(_card, _card.turn_over)   # (testing)
	else:
		card_tapped.emit(_card)


# --- drag ----------------------------------------------------------------------

func _begin_drag() -> void:
	_dragging = true
	set_process(false)
	Animations.stop(_card, &"move")   # in the hand now, not on its way somewhere
	_grab = _card.global_position - _world(_press_pos)   # keep the pressed spot under the finger
	_card.lift = tuning.lift_scale
	table_data.move_child(_card, -1)
	_trail.clear()
	_record(_world(_press_pos))


func _drag_to(pos: Vector2) -> void:
	var at := _world(pos)
	_card.global_position = at + _grab
	_record(at)
	_drag_over(_card)


func _end_drag() -> void:
	var v := _release_velocity()
	var flicked := v.length() * _pt_per_world() >= tuning.flick_speed_pt
	_let_go(_card, v if flicked else Vector2.ZERO)


func _record(at: Vector2) -> void:
	var now := _now()
	_trail.append(Vector3(at.x, at.y, now))
	while now - _trail[0].z > _velocity_window() * 2:
		_trail.pop_front()


# Pointer velocity (world px/s) over the recent window, measured up to now: a
# pointer that stopped before letting go releases at about 0 — not a flick.
func _release_velocity() -> Vector2:
	var now := _now()
	var window := _velocity_window()
	var last: Vector3 = _trail[-1]
	for s in _trail:
		if now - s.z <= window:
			return Vector2(last.x - s.x, last.y - s.y) / maxf(now - s.z, 0.001)
	return Vector2.ZERO


# --- my hand: dragging and letting go -----------------------------------------

# Dragging one of my cards: the slot nearest it opens, the others shifting
# aside, with the ghost in it; out of reach, its own slot stays open, plainly.
func _drag_over(card: CardFace) -> void:
	if card not in _hand_cards:
		return
	if _held != card:
		_held = card
		_held_from = _hand_cards.find(card)
	var over := _slot_under(card.global_position, -1)
	var slot := over if over >= 0 else _held_from
	if over == _hover_slot and _hand_cards.find(card) == slot:
		return   # still over the same slot
	_hover_slot = over
	_move_in_row(card, slot)
	_show_ghost()
	_seat()


# Let go: onto the discard pile if it would come to rest there (the Table puts
# it there), else into the open slot. Any other flick goes back to its own
# slot — rearranging the hand takes precision.
func _let_go(card: CardFace, fling: Vector2) -> void:
	if card not in _hand_cards:
		return
	var awaiting_id := _predicted.any(func(draw: Array) -> bool: return draw[0] == card)
	var discard := _lands_on_pile(card.global_position, fling) and not awaiting_id
	if fling != Vector2.ZERO and _held == card and not discard:
		_move_in_row(card, _held_from)
	_held = null
	_hover_slot = -1
	_show_ghost()
	if discard:
		_hand_cards.erase(card)
		table.discard(card)
	_seat()


# Whether a card let go at `from` moving at `fling` would end up on the pile:
# its slide (the distance a card travels at that speed on this table's
# friction) crosses the pile card's outline. A drop is a slide of zero.
func _lands_on_pile(from: Vector2, fling: Vector2) -> bool:
	var pile_at: Vector2 = table.discard_pile_position
	var rest := from + fling / tuning.table_friction
	var pile := Rect2(pile_at - table.card_size() / 2, table.card_size())
	return pile.has_point(Geometry2D.get_closest_point_to_segment(pile_at, from, rest))


# The ghost: the held card, faint, in the slot it's hovering over (or hidden).
func _show_ghost() -> void:
	_ghost.visible = _hover_slot >= 0
	if _ghost.visible:
		_ghost.card_id = _held.card_id
		_ghost.face_up = _held.face_up
		_ghost.global_position = _slot(_hover_slot)


# --- my hand: cards coming and going ------------------------------------------

## A draw: a face-down card slides off the deck into a new slot at once, while
## the Table asks the authority which card it is.
func predict_draw() -> void:
	_predicted.append([_add_card(), _now() + table.slide_time])


## How many of my draws are still waiting for their card.
func draws_awaited() -> int:
	return _predicted.size()


## My card `id`, from the authority: the answer to my oldest draw (`answer`),
## or a card dealt to me. It turns up once it has landed.
func receive(id: int, answer: bool) -> void:
	var draw: Array = _predicted.pop_front() if answer and _predicted else [_add_card(), _now() + table.slide_time]
	var card: CardFace = draw[0]
	card.card_id = id
	card.create_tween().tween_callback(Animations.flip.bind(card, card.turn_over)) \
			.set_delay(maxf(draw[1] - _now(), 0.0))   # the card's own timer: it goes if the card does


## No card for my oldest draw: it slides back to the deck and goes.
func draw_refused() -> void:
	var card: CardFace = _predicted.pop_front()[0]
	_hand_cards.erase(card)
	_seat()
	Animations.lerp(card, {"global_position": table.deck_position, "lift": 1.0}, table.slide_time, card.queue_free)


## My hand as the authority holds it (a rejoin's snapshot): the row is dealt
## again from the deck, face up, replacing whatever it showed.
func restore(ids: Array) -> void:
	_clear()
	_held = null   # (a card being dragged goes with the rest)
	_hover_slot = -1
	_show_ghost()
	for card in _hand_cards:
		card.queue_free()
	_hand_cards.clear()
	_predicted.clear()
	for id in ids:
		var card := _add_card()
		card.card_id = id
		card.face_up = true


## The table was re-laid (rotation, resize, card size): my row and the ghost follow.
func refit() -> void:
	_show_ghost()
	_seat()


# A face-down card off the deck into a new slot at the right end of my hand;
# the cards already there move over to make room.
func _add_card() -> CardFace:
	var card := CardFace.new()
	card.face_up = false
	card.global_position = table.deck_position
	card.lift = tuning.lift_scale   # picked up off the deck; the slide settles it
	table_data.add_child(card)
	_hand_cards.append(card)
	_seat()
	return card


# --- my hand: the row ----------------------------------------------------------

# My row onto its slots; the card being dragged is left to the finger, on top,
# with the ghost in its place.
func _seat() -> void:
	seat_row(_hand_cards, _hand_y(), _step(), table.area, table.slide_time, table.landed, _held, _ghost)


# Moves `card` to slot `index`; the cards between shift a slot over. Seat the
# row afterwards to show it.
func _move_in_row(card: CardFace, index: int) -> void:
	_hand_cards.erase(card)
	_hand_cards.insert(index, card)


# The slot of my row nearest to `p`, or `fallback` when none is within a card's height.
func _slot_under(p: Vector2, fallback: int) -> int:
	var nearest := fallback
	var reach: float = table.card_size().y
	for i in _hand_cards.size():
		var d := p.distance_to(_slot(i))
		if d < reach:
			nearest = i
			reach = d
	return nearest


# Where my slot `i` is, for the hand as it is now.
func _slot(i: int) -> Vector2:
	return slot_position(i, _hand_cards.size(), _hand_y(), _step(), table.area)


func _hand_y() -> float:
	return table.area.end.y - hand_bottom


func _step() -> float:
	return slot_step * CardFace.card_scale


# --- rows: my hand here, the opponents' mirrors on the Table -------------------

## Where slot `i` sits in a row of `count` at height `y`, `step` apart, in
## `area`: centred, overlapping, narrower if it won't fit.
static func slot_position(i: int, count: int, y: float, step: float, area: Rect2) -> Vector2:
	step = minf(step, area.size.x / maxf(count - 1, 1))
	return Vector2(area.get_center().x + (i - (count - 1) / 2.0) * step, y)


## Slides every card in `row` that isn't settled on its spot (off it, lifted, or
## still sliding somewhere else) onto it over `time`, and stacks them in slot
## order (slot 1 lowest). `held` is left where it is, on top, with `stand_in`
## (if showing) at its depth in the row.
static func seat_row(row: Array, y: float, step: float, area: Rect2, time: float, landed := Callable(),
		held: CardFace = null, stand_in: CardFace = null) -> void:
	for i in row.size():
		var card: CardFace = row[i]
		if card == held:
			if stand_in and stand_in.visible:
				stand_in.get_parent().move_child(stand_in, -1)
			continue
		var to := slot_position(i, row.size(), y, step, area)
		if Animations.is_playing(card, &"move") or card.lift != 1.0 or not card.global_position.is_equal_approx(to):
			Animations.lerp(card, {"global_position": to, "lift": 1.0}, time, landed)
		card.get_parent().move_child(card, -1)
	if held:
		held.get_parent().move_child(held, -1)


# --- device: the tuning in this screen's and pointer's units ------------------

# Touch slop is physical (a fingertip is the same size on every screen); mouse
# slop is in window px (a mouse is precise and moves in pixels).
func _past_slop(pos: Vector2) -> bool:
	var moved := pos.distance_to(_press_pos)   # viewport px
	if _touch:
		return moved * _pt_per_px() > tuning.touch_slop
	return moved * get_viewport().get_final_transform().get_scale().x > tuning.mouse_slop


# Physical points per viewport px: viewport → window px (stretch) → inches (dpi).
func _pt_per_px() -> float:
	var window_px := get_viewport().get_final_transform().get_scale().x
	return window_px * 163.0 / Device.dpi


func _pt_per_world() -> float:
	return table_data.get_canvas_transform().get_scale().x * _pt_per_px()


# At least 3 frames of samples, so low-frame-rate devices still read a steady speed.
func _velocity_window() -> float:
	var fps := Engine.get_frames_per_second()
	return maxf(tuning.velocity_window, 3.0 / fps) if fps > 0 else tuning.velocity_window


# --- helpers -------------------------------------------------------------------

# Top-most card under `at`, except that a press on a fixed card (the deck) goes
# through cards still sliding over it — rapid taps on the deck keep drawing.
func _card_at(at: Vector2) -> CardFace:
	var sliding: CardFace = null
	var cards := table_data.get_children()
	for i in range(cards.size() - 1, -1, -1):   # last child draws on top
		var card := cards[i] as CardFace
		if card == null or not card.visible or not card.has_point(at):
			continue
		if Animations.is_playing(card, &"move"):
			sliding = sliding if sliding else card
		elif sliding == null or card.fixed:
			return card
		else:
			return sliding
	return sliding


func _world(pos: Vector2) -> Vector2:
	return table_data.get_canvas_transform().affine_inverse() * pos


func _now() -> float:
	return Time.get_ticks_usec() / 1e6
