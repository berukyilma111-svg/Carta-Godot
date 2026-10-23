extends Node2D
## The match: everything on the table, shared by every player, the same locally
## and online. The table authority — multiplayer peer 1: this device offline,
## the host on a hotspot, the server online — holds the match's data (the deck's
## and the pile's order, who has which card) and tells everyone what happened;
## every network message is here. Each player's own side — input, their hand,
## dragging, the ghost — is their PlayerControl, which asks the Table for things
## and takes what it hands back. Laid out inside the safe area (Device.safe_rect).
##   - the starter selection, as the match opens (State's MATCH starts at
##     STARTER_SELECTION): one suit's A to Q, shuffled by the authority, face
##     down in a 3 × 4 grid. Each player taps one (a request, like a draw; one
##     pick each) and it flips. Once all have picked (STARTER_SELECTED) the rest
##     flip, the picks lift and the others dim: highest plays first, lowest last
##     (_turn_order, kept for the turn rules). Then the 12 gather into one stack
##     at the grid's middle, turn face down, are reshuffled and slide over to
##     become the deck; as it lands the deal starts (DEALING). A table run on
##     its own (tests) skips it and deals at once.
##   - drawing and dealing: the deck is one face-down card standing in for the
##     whole stack; its ids live only on the authority (_deck_ids), everyone
##     else asks for cards and is told what they got — the same code in all three.
##       tap deck  → request_draw(): my PlayerControl slides a face-down card into
##                   a new slot at once (predicted) while the authority is asked
##       authority → _give(player): takes the top card and tells every player;
##                   only the receiver learns its id, the rest see its back
##       everyone  → _card_given(): mine goes to my PlayerControl (receive),
##                   anyone else's face down into their seat's mirror
##     Dealing is the authority calling _give() round the players.
##   - the discard pile, right of centre: like the deck, one card node (the top,
##     face up), its ids kept by the authority. My PlayerControl hands a card over
##     with discard(); everyone else is told through the authority (as draws are).
##     When the deck runs out, the authority shuffles everything under the pile's
##     top back into it (_reshuffle) and tells every player.
##   - opponents (up to 5): the Opponent hand display along the top shows one
##     opponent's hand at a time, as card backs — the one who acted last (the
##     turn rules will make it whoever's turn it is); every other hand is a count.
##     Seats run clockwise from me, in the starter selection's turn order. In a
##     bot match the authority also plays the bots on this device (State's
##     match_setup "bots" of them, in _bots, with negative ids −1… so they
##     never clash with seats) — and, for testing, keys 1–5 show a bot,
##     H/D make it draw/discard.
##   - players are SEATS (people 1, 2…; bots −1, −2…), fixed for the match;
##     a connection (peer id) only says which device plays a seat right now
##     (match_setup "seats", reseat() on a reconnect), so every check and every
##     record is by seat.
##   - every hand, bots' and people's alike, is held by the authority alone
##     (_hands): what it dealt and gave, less what was discarded. A discard of a
##     card the player doesn't hold is refused (ignored, for now).
##   - the deck is expanded: DECKS × 52 cards (ids 0–103; the face is id % 52).
##   - when the safe area moves (rotation, resize) or the cards change size, every
##     card is carried to the same relative spot and the rows re-seat.

const DECKS := 2   # an expanded deck: two 52-card decks shuffled together
const DECK_SIZE := 52 * DECKS
const HIDDEN := -1   # the card id sent to players who mustn't see the card
const NO_CARD := 255   # in a snapshot: no card (an empty pile)
const START_HAND := 7   # cards dealt to each player when the game starts
const DEAL_INTERVAL := 0.25   # s between cards while dealing (one card at a time, round the table)
const SHUFFLE_SPLIT := 0.45   # card widths each half of the deck moves out while riffling
const STARTER_RANKS := 12   # A to Q: no King, so no two picks tie
const STARTER_GAP := 1.4   # grid spacing, centre to centre, in card sizes (so it scales with the cards)
const STARTER_THINK := Vector2(1.0, 1.8)   # s a seat played here takes to pick (min, max), from the grid's arrival
const STARTER_HOLD := 1.0   # s the picks stay shown before the cards gather
const STARTER_GATHER := 0.35   # s the 12 take to come together into one stack
const STARTER_LIFT := 1.15   # picked cards' size while the order shows
const STARTER_DIM := 0.45   # the unpicked cards' alpha meanwhile

@export_group("Layout")   # px in the 720×1280 design; defaults match the Unity build's proportions
@export var deck_offset := Vector2(-110, 0)   # deck position from the table centre (left of it)
@export var discard_offset := Vector2(120, 0)   # discard pile position from the table centre (right of it)

@onready var _table_data: Node2D = $TableData   # every card on the table
@onready var _control: PlayerControl = $PlayerControl   # this player's input and hand

# Layout — read by PlayerControl too
var area := Rect2()   # where card centres can go, world px, as last laid out
var deck_position := Vector2.ZERO   # where the deck sits (kept after it's gone, for cards sent back)
var discard_pile_position := Vector2.ZERO   # where the pile sits
var slide_time := 0.0   # s a card takes across the felt (this device's table friction)
var landed := Callable()   # the tick when one of my cards lands
# The deck and the pile
var _deck: CardFace   # the one card drawn for the whole stack
var _deck_left := DECK_SIZE   # what every player knows: how many are still in the deck
var _deck_ids: Array = []   # authority only: card ids still in the deck, the last on top
var _discard_top: CardFace   # the one card drawn for the pile
var _pile_ids: Array = []   # authority only: card ids on the discard pile, the last on top
# The players
var _opponents: Opponent   # the opponent hand display (every opponent's count; one hand shown)
var my_seat := 0   # this device's player (0: a dedicated server, no player)
var _seat_of := {}   # connection (peer id) → seat; from State's match_setup "seats" (offline: {1: 1})
var _hands := {}   # authority only: player id → the card ids they hold — every player, bot or person
var _bots: Array = []   # authority only: seats played on this device (bot N has id −N)
var _tables_ready := {}   # authority only: screens whose table is set up
var _match_started := false   # authority only: every table was ready, the match began
var _turn_order: Array = []   # player ids, first to play first (no turn rules yet)
var _gone: Array = []   # authority only: players removed from the match (remove_player)
# The starter selection
var _starter_cards: Array[CardFace] = []   # the grid, slot order
var _starter_picked: Array = []   # slots picked so far
var _picked := false   # I've picked (no second pick)
var _starter_ids: Array = []   # authority only: the card id in each slot
var _picks := {}   # authority only: player id → slot picked
var _stack: Array = []   # the gathered stack's two cards (its top, the riffle's other half)
var _gathered := false   # the starter cards have become the deck


# --- setting up ------------------------------------------------------------------

func _ready() -> void:
	_listen()
	_lay_out()
	_make_cards()
	_start_match()


# Taps on table cards, the screen turning or resizing, the card size setting;
# and how cards move on this device (its table friction, its landing tick).
func _listen() -> void:
	slide_time = 4.0 / Device.tuning.table_friction
	landed = Device.vibrate.bind(Device.tuning.land_haptic_ms)
	_control.card_tapped.connect(_on_card_tapped)
	add_to_group(&"table")   # how the connection (Net) finds the match
	Device.changed.connect(_refit)
	var settings := get_tree().get_first_node_in_group(&"settings")
	if settings:   # (none when the table runs on its own, as in tests)
		settings.changed.connect(func(option: String) -> void:
			if option == "card_scale":
				_refit())   # the cards changed size: re-lay the table for it


# Where cards can go, and the deck's and the pile's spots.
func _lay_out() -> void:
	area = _centre_area()
	deck_position = area.get_center() + deck_offset
	discard_pile_position = area.get_center() + discard_offset


# The deck, the opponent hand display, and every face baked ahead.
func _make_cards() -> void:
	_make_deck()
	_opponents = Opponent.new()
	add_child(_opponents)
	_lay_out_display()
	CardFace.prebake()   # every face, in one go, before any turns up


# The authority orders the deck and, in a local match, seats the bots played on
# this device; then every table tells it it's set up (_table_ready), and once
# all are, it starts the match.
func _start_match() -> void:
	if State.is_on(GameState.Screen.MATCH):
		_deck.hide()   # it appears as the starter stack lands on it
	_seat_of = State.match_setup.get("seats", {} if _headless() else {multiplayer.get_unique_id(): 1}).duplicate()
	my_seat = _seat_of.get(multiplayer.get_unique_id(), 0)
	if multiplayer.is_server():   # the table authority
		_deck_ids = range(DECK_SIZE)
		_deck_ids.shuffle()
		for bot in State.match_setup.get("bots", 1):   # played by the authority, online or not
			_bots.append(-1 - bot)   # bot 1 → −1, bot 2 → −2…
		_report_ready.rpc()   # tables built before this one: report again (theirs reached no table)
	_table_ready.rpc_id(1)


# From the authority, whose table is now up: report that mine is.
@rpc("authority", "call_remote", "reliable")
func _report_ready() -> void:
	_table_ready.rpc_id(1)


# To the authority: a table is set up. Once every screen's is (bots need none),
# the match starts — so no device misses its first messages. A match opens with
# the starter selection (the deck arrives as its reshuffled stack); a table on
# its own just deals.
@rpc("any_peer", "call_local", "reliable")
func _table_ready() -> void:
	if not multiplayer.is_server() or _match_started:
		return
	_tables_ready[_sender()] = true
	_start_if_ready()


# Authority: once every screen's table is set up, the match starts.
func _start_if_ready() -> void:
	if _match_started or not _screens().all(func(screen: int) -> bool: return _tables_ready.has(screen)):
		return   # (a screen that never reports is removed by remove_player)
	_match_started = true
	if State.is_on(GameState.Screen.MATCH):
		_start_selection()   # seats come with its turn order
	else:
		_opponents.seat(_clockwise_from_me(_players()))
		_deal(START_HAND)


# --- taps on table cards ---------------------------------------------------------

# My PlayerControl hands over taps on cards that aren't mine: a starter card is
# my pick, the deck is a draw.
func _on_card_tapped(card: CardFace) -> void:
	if card in _starter_cards:
		if not _picked:
			_pick_requested.rpc_id(1, _starter_cards.find(card))
	elif card == _deck:
		request_draw()


# Debug, until the game rules drive the bots: 1–5 — show that bot's hand (the
# display slides clockwise or back the other way); H — the shown bot draws a
# card; D — it discards its last card.
func _unhandled_key_input(event: InputEvent) -> void:
	if not OS.is_debug_build() or _bots.is_empty():
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var bot: int = KEY_0 - event.keycode   # key 1 → bot 1 (id −1)…
	if event.keycode >= KEY_1 and event.keycode <= KEY_5 and bot in _bots:
		var seats: Array = _opponents.order
		_opponents.show_hand(bot, seats.find(bot) < seats.find(_opponents.shown))   # an earlier seat: slides back
	elif _opponents.shown in _bots:
		match event.keycode:
			KEY_H:
				_give(_opponents.shown)
			KEY_D:
				_local_discard(_opponents.shown)
			KEY_L:
				remove_player(_opponents.shown)   # as if it left


# --- starter selection -----------------------------------------------------------

# Authority: one random suit's A to Q, shuffled into the grid on every screen;
# seats played on this device pick a free card after a moment.
func _start_selection() -> void:
	var suit := randi() % 4
	_starter_ids = range(STARTER_RANKS).map(func(rank: int) -> int: return suit * 13 + rank)
	_starter_ids.shuffle()
	for seat in _reachable():
		_selection_started.rpc_id(_peer_of(seat))
	for seat in _bots:
		create_tween().tween_callback(func() -> void:
			var free := range(STARTER_RANKS).filter(func(slot: int) -> bool: return slot not in _picks.values())
			_picked_by(seat, free.pick_random())).set_delay(randf_range(STARTER_THINK.x, STARTER_THINK.y))


# From the authority: the 12 cards, face down in a 3 × 4 grid at the table's
# centre, STARTER_GAP card sizes apart — less only if that wouldn't fit.
@rpc("authority", "call_local", "reliable")
func _selection_started() -> void:
	var size := card_size()
	var gap := minf(STARTER_GAP, minf(area.size.x / (2.0 * size.x), area.size.y / (3.0 * size.y)))
	for slot in STARTER_RANKS:
		var card := CardFace.new()
		card.face_up = false
		card.fixed = true   # taps only
		card.global_position = area.get_center() + Vector2(slot % 3 - 1, floori(slot / 3.0) - 1.5) * size * gap
		_table_data.add_child(card)
		_starter_cards.append(card)
	Animations.fade([], _starter_cards.duplicate())


@rpc("any_peer", "call_local", "reliable")
func _pick_requested(slot: int) -> void:
	if multiplayer.is_server():
		_picked_by(_sender(), slot)


# Authority: `player` takes the card in `slot` — if they haven't picked yet and
# it's free — and everyone is told. Once every player has picked, the order is
# set (highest card first) and the deal follows the reveal.
func _picked_by(player: int, slot: int) -> void:
	if player not in _players() or _picks.has(player) or slot in _picks.values() or slot < 0 or slot >= STARTER_RANKS:
		return
	_picks[player] = slot
	for seat in _reachable():
		_card_picked.rpc_id(_peer_of(seat), player, slot, _starter_ids[slot])
	_order_if_all_picked()


# Authority: once every player has picked, the order is set (highest card
# first) and everyone is told; the deal follows the reveal.
func _order_if_all_picked() -> void:
	if _turn_order or _picks.is_empty() or _picks.size() < _players().size():
		return
	var order := _picks.keys()
	order.sort_custom(func(a: int, b: int) -> bool: return _starter_ids[_picks[a]] % 13 > _starter_ids[_picks[b]] % 13)
	_turn_order = order   # (the authority's too, even with no screen)
	for seat in _reachable():
		_starter_selected.rpc_id(_peer_of(seat), order, _starter_ids)
	if my_seat not in _screens():   # a server with no screen deals by the clock; otherwise as its stack lands
		var into_deck := STARTER_HOLD + STARTER_GATHER + Animations.FLIP_TIME + Animations.SHUFFLE_TIME + slide_time
		create_tween().tween_callback(_announce_deal).set_delay(into_deck)


# From the authority: `player` picked the card in `slot` (`id`): it turns up.
@rpc("authority", "call_local", "reliable")
func _card_picked(player: int, slot: int, id: int) -> void:
	_picked = _picked or player == my_seat
	_starter_picked.append(slot)
	var card := _starter_cards[slot]
	card.card_id = id
	Animations.flip(card, card.turn_over)


# From the authority: everyone has picked. The rest turn up, the picks lift and
# the others dim; then the grid becomes the deck.
@rpc("authority", "call_local", "reliable")
func _starter_selected(order: Array, ids: Array) -> void:
	_turn_order = order
	_opponents.seat(_clockwise_from_me(order))
	State.step(GameState.Sub.STARTER_SELECTED)
	for slot in STARTER_RANKS:
		var card := _starter_cards[slot]
		if slot in _starter_picked:
			Animations.lerp(card, {"lift": STARTER_LIFT}, Animations.FADE_TIME)
		else:
			card.card_id = ids[slot]
			Animations.flip(card, card.turn_over)
			Animations.lerp(card, {"modulate:a": STARTER_DIM}, Animations.FADE_TIME, Callable(), &"fade")
	_gather_into_deck()


# After the hold, the 12 come back to full and gather into one stack at the
# grid's middle; the rest vanish under its top, which turns face down alone,
# is reshuffled, and slides over to become the deck. When the authority's lands
# it announces the deal (_dealing); a device still gathering then (a slower
# one) finishes at once, so the gather stops where it is after each step.
# Each wait is the table's own, so leaving the match ends it.
func _gather_into_deck() -> void:
	await create_tween().tween_interval(STARTER_HOLD).finished
	if _gathered:
		return
	var top: CardFace = _starter_cards.back()
	var under: CardFace = _starter_cards[0]   # the stack's other half in the riffle
	_stack = [top, under]
	_table_data.move_child(top, -1)
	for card in _starter_cards:
		Animations.lerp(card, {"global_position": area.get_center(), "lift": 1.0, "modulate:a": 1.0}, STARTER_GATHER)
	await create_tween().tween_interval(STARTER_GATHER).finished
	if _gathered:
		return
	for card in _starter_cards:
		if card not in _stack:
			card.queue_free()
	_starter_cards.clear()
	under.hide()   # gone with the rest: nothing under the top as it turns
	under.face_up = false
	await Animations.flip(top, top.turn_over).finished
	if _gathered:
		return
	under.show()   # back, face down, as the riffle's other half
	await Animations.shuffle(under, top, Vector2(card_size().x * SHUFFLE_SPLIT, 0)).finished
	if _gathered:
		return
	under.queue_free()
	await Animations.lerp(top, {"global_position": deck_position}, slide_time, landed).finished
	if _gathered:
		return
	_finish_gather()   # the stack becomes the deck
	if multiplayer.is_server():
		_announce_deal()


# The starter cards are gone and the deck shows (the same card back, so the
# swap from the stack doesn't show) — at the gather's end, or at once.
func _finish_gather() -> void:
	if _gathered:
		return
	_gathered = true
	for card in _starter_cards + _stack:
		if is_instance_valid(card):
			card.queue_free()
	_starter_cards.clear()
	_stack.clear()
	_deck.show()


# Authority: the deal is about to begin — every device is told (and catches up).
func _announce_deal() -> void:
	_dealing.rpc()


# From the authority: the deal begins. A device still gathering finishes at
# once, so no dealt card arrives before its deck shows; every device moves to
# DEALING together, and the authority deals.
@rpc("authority", "call_local", "reliable")
func _dealing() -> void:
	_finish_gather()
	_step_to(GameState.Sub.DEALING)
	if multiplayer.is_server():
		_deal(START_HAND)


# --- dealing and drawing ---------------------------------------------------------

## I draw: my PlayerControl slides a face-down card into a new slot at once,
## while the authority is asked which card it is.
func request_draw() -> void:
	if _deck_left - _control.draws_awaited() <= 0:
		return   # every card left is already on its way
	_control.predict_draw()
	_draw_requested.rpc_id(1)


@rpc("any_peer", "call_local", "reliable")
func _draw_requested() -> void:
	if multiplayer.is_server():
		_give(_sender(), true)


# Authority: deals `count` cards to every player as the game starts, one card at
# a time round the table in the turn order the starter selection set (a table
# run on its own: its players' order) — so every display moves on round the
# table with each card, on every device. Once the last card
# has landed, play begins for everyone. The waits are the table's own, so
# leaving the match mid-deal ends it.
func _deal(count: int) -> void:
	var order := (_turn_order if _turn_order else _players()).duplicate()
	for _i in count:
		for player in order:
			if player in _gone:
				continue   # left mid-deal
			_give(player)
			await create_tween().tween_interval(DEAL_INTERVAL).finished
	await create_tween().tween_interval(slide_time).finished
	_dealt.rpc()


# Authority: takes the top card for `player` and tells every player who got
# one; only `player` is told which. `answer`: this replies to their draw request.
func _give(player: int, answer := false) -> void:
	if player not in _players():   # gone, or not seated
		return
	if _deck_ids.is_empty():
		if answer:
			_draw_refused.rpc_id(_peer_of(player))
		return
	var id: int = _deck_ids.pop_back()
	_hands[player] = _hands.get(player, []) + [id]
	if _deck_ids.is_empty():
		_reshuffle()   # refill straight away, so the deck never sits empty with cards on the pile
	for seat in _reachable():
		_card_given.rpc_id(_peer_of(seat), player, id if seat == player else HIDDEN, _deck_ids.size(), answer)


# From the authority: `player` got a card. Mine goes to my hand (it shows its id
# once it has landed); anyone else's goes face down into their mirror.
@rpc("authority", "call_local", "reliable")
func _card_given(player: int, id: int, left: int, answer: bool) -> void:
	_deck_left = left
	if player == my_seat:
		_control.receive(id, answer)
	else:   # the display goes to them and a back flies in — a carousel switch while dealing
		_opponents.receive(player, deck_position, State.is_on(GameState.Screen.MATCH, GameState.Sub.DEALING))
	if _deck_left == 0 and _deck:
		_deck.queue_free()
		_deck = null


# From the authority: no card for my oldest draw.
@rpc("authority", "call_local", "reliable")
func _draw_refused() -> void:
	_control.draw_refused()


# From the authority: the deal is over — the match moves from dealing to play
# (players get control). Only for the match screen (not a table run on its own).
@rpc("authority", "call_local", "reliable")
func _dealt() -> void:
	_step_to(GameState.Sub.PLAY)


# The match's step forward to `to`, through any in between — for a device that
# missed them (a server shows no starter selection; a rejoin missed the deal).
# Only for the match screen (not a table run on its own).
func _step_to(to: GameState.Sub) -> void:
	while State.is_on(GameState.Screen.MATCH) and State.sub != to and GameState.STEP_NEXT.get(State.sub, []):
		State.step(GameState.STEP_NEXT[State.sub][0])


# --- the deck ----------------------------------------------------------------------

func _make_deck() -> void:
	_deck = CardFace.new()
	_deck.face_up = false
	_deck.fixed = true
	_deck.global_position = deck_position
	_table_data.add_child(_deck)
	_table_data.move_child(_deck, 0)   # under every drawn card


# Authority: the deck ran out — every pile card but the face-up top is shuffled
# back into it, and every player is told how many it holds. Needs at least one
# card under the top.
func _reshuffle() -> void:
	if _pile_ids.size() < 2:
		return
	var top: int = _pile_ids.pop_back()
	_deck_ids = _pile_ids
	_deck_ids.shuffle()
	_pile_ids = [top]
	for seat in _reachable():
		_deck_restocked.rpc_id(_peer_of(seat), _deck_ids.size())


# From the authority: the deck was refilled (reshuffled from the pile) and now
# holds `left` cards — it comes back if it had run out.
@rpc("authority", "call_local", "reliable")
func _deck_restocked(left: int) -> void:
	_deck_left = left
	if _deck == null:
		_make_deck()
	_play_shuffle()


# The pile going back into the deck: a card back sweeps from the pile onto it,
# then the deck splits in two and riffles back together twice.
func _play_shuffle() -> void:
	var other_half := CardFace.new()
	other_half.face_up = false
	other_half.fixed = true
	other_half.global_position = discard_pile_position
	_table_data.add_child(other_half)
	_table_data.move_child(other_half, _deck.get_index() + 1)
	await Animations.lerp(other_half, {"global_position": deck_position}, slide_time, landed).finished
	Animations.shuffle(_deck, other_half, Vector2(card_size().x * SHUFFLE_SPLIT, 0), other_half.queue_free)


# --- the discard pile ------------------------------------------------------------

## My PlayerControl hands over a card I've discarded (it has left my hand): it
## goes on the pile now, and the others are told through the authority.
func discard(card: CardFace) -> void:
	_put_on_pile(card)
	_discard_requested.rpc_id(1, card.card_id)


@rpc("any_peer", "call_local", "reliable")
func _discard_requested(id: int) -> void:
	if multiplayer.is_server():
		_discarded(_sender(), id)   # (whose turn it is comes with the rules)


# Authority: `player` discarded card `id` — refused (ignored, for now) unless
# they hold it; else out of their hand onto the pile's record, every screen but
# theirs is told, and the deck refills if it had run out.
func _discarded(player: int, id: int) -> void:
	var hand: Array = _hands.get(player, [])
	if id not in hand:
		push_warning("Table: player %d discarded card %d, which they don't hold — refused" % [player, id])
		return
	hand.erase(id)
	_pile_ids.append(id)
	for seat in _reachable():
		if seat != player:
			_card_discarded.rpc_id(_peer_of(seat), player, id)
	if _deck_ids.is_empty():
		_reshuffle()


# Authority: a seat played on this device discards its last card.
func _local_discard(player: int) -> void:
	var hand: Array = _hands.get(player, [])
	if not hand.is_empty():
		_discarded(player, hand.back())


# From the authority: `player` discarded card `id` — it leaves their hand
# mirror, turning up and growing to full size on its way onto the pile.
@rpc("authority", "call_local", "reliable")
func _card_discarded(player: int, id: int) -> void:
	var card := _opponents.discard(player, id)
	if card:
		card.reparent(_table_data)
		_put_on_pile(card)


# Slides `card` onto the pile face up and full size as its new top; the old top
# is freed once it's covered, so the pile stays one card node however tall it gets.
func _put_on_pile(card: CardFace) -> void:
	card.fixed = true
	if not card.face_up:
		Animations.flip(card, card.turn_over)
	var below := _discard_top
	_discard_top = card
	_table_data.move_child(card, below.get_index() + 1 if below else _deck.get_index() + 1 if _deck else 0)
	Animations.lerp(card, {"global_position": discard_pile_position, "size_factor": 1.0, "lift": 1.0}, slide_time, landed) \
			.finished.connect(func() -> void:
				if is_instance_valid(below):
					below.queue_free())


# --- opponents -----------------------------------------------------------------------

# The opponent hand display along the top: its half-size backs the hand's
# hand_bottom off the safe edge, half my hand's step apart.
func _lay_out_display() -> void:
	var top := area.position.y - card_size().y / 2 * (1.0 - Opponent.MIRROR) + _control.hand_bottom
	_opponents.lay_out(Vector2(area.get_center().x, top), area.size.x,
			_control.slot_step * CardFace.card_scale * Opponent.MIRROR, slide_time)


# The players in `order` other than me, clockwise from me: the one after me
# first, wrapping round (all of them on a server with no player of its own).
func _clockwise_from_me(order: Array) -> Array:
	var me := order.find(my_seat)
	return order.slice(me + 1) + order.slice(0, maxi(me, 0))


# --- leaving -------------------------------------------------------------------------

## Authority: `player` is gone from the match for good — called by the
## connection layer (once its reconnection window runs out, or on Leave), or by
## debug key L. Their hand is shuffled back into the deck and they leave the
## turn order; every screen is told and closes their seat. A match still
## starting goes on without them: the ready check and the starter picks are
## counted again.
func remove_player(player: int) -> void:
	if not multiplayer.is_server() or player in _gone or player not in _players():
		return
	_gone.append(player)
	_bots.erase(player)
	_tables_ready.erase(player)
	_picks.erase(player)
	_turn_order.erase(player)
	_deck_ids += _hands.get(player, [])
	_deck_ids.shuffle()
	_hands.erase(player)
	for seat in _reachable():
		_player_removed.rpc_id(_peer_of(seat), player, _deck_ids.size())
	if _match_started:
		_order_if_all_picked()
	elif _tables_ready:
		_start_if_ready()


# From the authority: `player` left — out of the turn order, their seat closes,
# and the deck holds `left` (their cards went back into it).
@rpc("authority", "call_local", "reliable")
func _player_removed(player: int, left: int) -> void:
	_turn_order.erase(player)
	_opponents.remove(player)
	_deck_left = left
	if _deck == null and left > 0 and _gathered:
		_make_deck()


## Authority: `seat` is back on a new connection (Net calls this after
## reseat): one snapshot catches its device up — the deck's and every hand's
## size, the pile top, its own cards, the turn order, the step — and the facts
## after it carry on as usual. Only once the deal has begun (a drop before that
## removes the player); false if it hasn't.
func send_snapshot(seat: int) -> bool:
	if State.sub not in [GameState.Sub.DEALING, GameState.Sub.PLAY]:
		return false
	var hand: Array = _hands.get(seat, [])
	var order := _turn_order if _turn_order else _players()
	var bytes := PackedByteArray([State.sub, _deck_ids.size(), _pile_ids.back() if _pile_ids else NO_CARD, hand.size()])
	bytes.append_array(hand)
	bytes.append(order.size())
	for player in order:   # each seat (−5…6 fits a byte) and its card count
		bytes.append(player & 0xFF)
		bytes.append(_hands.get(player, []).size())
	_snapshot.rpc_id(_peer_of(seat), bytes)
	return true


# From the authority: the table as it is now (send_snapshot) — rebuilt at once:
# the grid gone, the deck and the pile top, my cards, every opponent's count.
@rpc("authority", "call_remote", "reliable")
func _snapshot(bytes: PackedByteArray) -> void:
	_deck_left = bytes[1]
	var hand := Array(bytes.slice(4, 4 + bytes[3]))
	var at := 4 + bytes[3]
	_turn_order = []
	var counts := {}
	for i in bytes[at]:
		var player := bytes.decode_s8(at + 1 + 2 * i)
		_turn_order.append(player)
		if player != my_seat:
			counts[player] = bytes[at + 2 + 2 * i]
	_finish_gather()
	if _deck_left == 0 and _deck:
		_deck.queue_free()
		_deck = null
	elif _deck_left > 0 and _deck == null:
		_make_deck()
	if is_instance_valid(_discard_top):
		_discard_top.queue_free()
	_discard_top = null
	if bytes[2] != NO_CARD:
		_discard_top = CardFace.new()
		_discard_top.card_id = bytes[2]
		_discard_top.fixed = true
		_discard_top.global_position = discard_pile_position
		_table_data.add_child(_discard_top)
	_control.restore(hand)
	_opponents.restore(counts, _clockwise_from_me(_turn_order))
	_step_to(bytes[0])


# --- layout ------------------------------------------------------------------------

# Same relative spot in the new area for every card: edges stay edges. Then the
# rows go back onto their slots, which moved with the edges.
func _refit() -> void:
	$Camera2D.force_update_scroll()   # it re-centres next frame; measure the new area from where it will be
	var next := _centre_area()
	for card in _table_data.get_children():
		card.global_position = _carry(card.global_position, next)
	deck_position = _carry(deck_position, next)
	discard_pile_position = _carry(discard_pile_position, next)
	area = next
	_control.refit()
	_lay_out_display()


# Point `p` moved from the current area to the same relative spot in `next`.
func _carry(p: Vector2, next: Rect2) -> Vector2:
	return next.position + (p - area.position) / area.size.max(Vector2.ONE) * next.size


# The safe area shrunk by half a card, so a card centred anywhere in it is fully on the table.
func _centre_area() -> Rect2:
	var half := card_size() / 2
	return Device.safe_rect(_table_data).grow_individual(-half.x, -half.y, -half.x, -half.y)


## A card's size on the table.
func card_size() -> Vector2:
	return CardFace.SIZE * CardFace.card_scale


# --- the players ---------------------------------------------------------------------

# Everyone dealt in: every screen's player, plus seats played on this device.
func _players() -> Array:
	return _screens() + _bots


# Every seat played on a device — people, in seat order — less those gone.
# (A dropped player keeps their seat until remove_player.)
func _screens() -> Array:
	var seats := _seat_of.values()
	seats.sort()
	return seats.filter(func(seat: int) -> bool: return seat not in _gone)


# The seats whose device is connected now: the ones sent to. A seat whose
# player dropped keeps its cards; the snapshot catches it up if they come back.
func _reachable() -> Array:
	var online := Array(multiplayer.get_peers()) + [multiplayer.get_unique_id()]
	return _screens().filter(func(seat: int) -> bool: return _peer_of(seat) in online)


## The connection layer: `seat`'s player is back on a new connection, `peer`
## (within the reconnection window). Catching that device up is its job.
func reseat(seat: int, peer: int) -> void:
	_seat_of.erase(_peer_of(seat))
	_seat_of[peer] = seat


# The connection a seat is played from.
func _peer_of(seat: int) -> int:
	var peer: Variant = _seat_of.find_key(seat)
	return peer if peer != null else 0


# The seat of whoever sent the RPC being run (this device's, when it called
# itself); 0 for a connection with no seat.
func _sender() -> int:
	var peer := multiplayer.get_remote_sender_id()
	return _seat_of.get(peer if peer != 0 else multiplayer.get_unique_id(), 0)


# A dedicated server — a dedicated-server export, or any build running without
# a display (`--headless`) — holds the deck but has no seat.
func _headless() -> bool:
	return OS.has_feature("dedicated_server") or DisplayServer.get_name() == "headless"
