class_name Opponent
extends Node2D
## The opponent hand display: ONE opponent's hand at a time, as half-size card
## backs along the top — for a match of up to 6 players. Which one is shown is
## Table's call: whoever's turn it is, once the turn rules exist; until then,
## whoever acted last — and during the deal, whoever is being dealt to.
## Every opponent's hand is only a count here — no card ids, ever: draws reach
## this device as HIDDEN, and a card gets its id only as it leaves for the pile,
## where everyone sees it anyway. Only the shown hand has card nodes.
## Switching hands: moving on round the table (clockwise — including from the
## last seat back to the first, as a dealer does), the shown one slides out to
## the left, fading, and the next slides in from the right; going `back`, or in
## `reversed` play, the other way round. A `carousel` switch moves both at
## once (the deal: one card a beat); otherwise out, then in.
## The same for bots played on this device and for players online.

const MIRROR := 0.5   # the backs' size relative to a table card
const SLIDE := 0.25   # s each way when the display switches hands
const CAROUSEL := 0.2   # s for a carousel switch: out and in together

var counts := {}   # player id → cards they hold
var order: Array = []   # the opponents, clockwise from me
var shown := 0   # whose hand is on the display (0: nobody yet)
var reversed := false   # play runs the other way: switches slide the other way
var _row: Node2D   # the shown hand's backs, left to right
var _width := 0.0   # px the row may spread over
var _step := 0.0   # px between backs' centres (less if the row won't fit)
var _time := 0.0   # s a back takes to slide into place


## The opponents, clockwise from me: each gets a seat (a count), and the first
## shows until someone acts.
func seat(opponents: Array) -> void:
	order = opponents
	for player in opponents:
		counts[player] = counts.get(player, 0)
	if shown == 0 and opponents:
		show_hand(opponents[0])


## Where the display sits (top centre, in Table's space) and how its row spreads.
func lay_out(centre: Vector2, width: float, step: float, time: float) -> void:
	position = centre
	_width = width
	_step = step
	_time = time
	if _row:
		_seat_row(false)


## `player` got a card: the display shows their hand (a `carousel` switch
## while dealing) and a back slides from `from` (the deck) into it.
func receive(player: int, from: Vector2, carousel := false) -> void:
	show_hand(player, false, carousel)   # built without the new card…
	counts[player] = counts.get(player, 0) + 1
	var card := _add_back()   # …which flies in
	card.global_position = from
	_seat_row(false)


## `player` discards card `id`: the display shows their hand, its last back
## leaves the row with the id, and is returned for Table to send to the pile.
## Null if they hold nothing.
func discard(player: int, id: int) -> CardFace:
	if counts.get(player, 0) == 0:
		return null
	show_hand(player)
	counts[player] -= 1
	var card: CardFace = _row.get_child(-1)
	card.reparent(self)   # out of the row (keeping its place), so the row's slide doesn't carry it
	card.card_id = id
	_seat_row(false)
	return card


## Every opponent's count at once (a rejoin's snapshot), clockwise from me; the
## first seat's hand shows.
func restore(hands: Dictionary, opponents: Array) -> void:
	counts = hands
	if _row:
		_row.queue_free()
		_row = null
	shown = 0
	seat(opponents)


## `player` left the match: their seat closes. If their hand was shown, the next
## seat's slides in — or the display empties if nobody's left.
func remove(player: int) -> void:
	var seat := order.find(player)
	counts.erase(player)
	order.erase(player)
	if player != shown:
		return
	if order:
		show_hand(order[seat % order.size()])
	else:
		Animations.lerp(_row, {"modulate:a": 0.0}, SLIDE, _row.queue_free)
		_row = null
		shown = 0


## Puts `player`'s hand on the display: the shown one slides out, fading, and
## theirs — built now at its count — slides in (after it, or with it in a
## `carousel`). Out to the left moving on round the table; right going `back`.
func show_hand(player: int, back := false, carousel := false) -> void:
	if player == shown:
		return
	var leaving := _row
	shown = player
	_row = Node2D.new()
	add_child(_row)
	for i in counts.get(player, 0):
		_add_back()
	_seat_row(true)
	if leaving == null:
		return   # the first hand shown: no slide
	var out := -1.0 if back == reversed else 1.0   # left — or right going back, or when play is reversed
	var time := CAROUSEL if carousel else SLIDE
	Animations.lerp(leaving, {"position": Vector2(out * _width / 2, 0), "modulate:a": 0.0}, time, leaving.queue_free)
	_row.position.x = -out * _width / 2
	_row.modulate.a = 0.0
	if carousel:
		_slide_in(_row, time)   # in as the other goes out
	else:
		create_tween().tween_callback(_slide_in.bind(_row, time)).set_delay(time)


# The next hand comes in over `time` — unless it was replaced meanwhile.
func _slide_in(row: Node2D, time: float) -> void:
	if row == _row:
		Animations.lerp(row, {"position": Vector2.ZERO, "modulate:a": 1.0}, time)


func _add_back() -> CardFace:
	var card := CardFace.new()
	card.face_up = false
	card.size_factor = MIRROR
	_row.add_child(card)
	return card


# The row's backs onto their slots, centred on the display; `snap`: at once.
func _seat_row(snap: bool) -> void:
	var backs := _row.get_children()
	var spread := Rect2(-_width / 2, 0, _width, 0)
	for i in backs.size():
		var to := PlayerControl.slot_position(i, backs.size(), 0.0, _step, spread)
		if snap:
			backs[i].position = to
		elif not backs[i].position.is_equal_approx(to):
			Animations.lerp(backs[i], {"position": to}, _time)
