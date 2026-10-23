extends Node
## The connection: the only network code. The autoload "Net" (/root/Net, the
## same path on every device). One transport everywhere — WebSocket — so a
## browser, a native build and the headless server all speak it. Nothing is
## ever synced per frame: the Table sends small facts and every device does
## the rest itself.
## A server match: the server (this project run headless with --server) holds
## its one match as the authority, with no seat. A player's Server Match
## connects to it (join) and takes the next seat; the match starts once at
## least two people are seated and every one is ready, and anyone connecting
## after that is refused. When the last player has gone, the server is free
## for the next match.
## A player who drops once the deal has begun keeps their seat for AWAY_TIME:
## their device keeps trying to get back in (with the token it was seated
## with, kept in memory only) and is caught up by one snapshot; after that the
## seat is removed (Table.remove_player). A drop before the deal removes it at
## once. Losing the server ends the match: home, "Server left".
## Leaving sends a goodbye and closes the line LINGER later: closing at once
## drops whatever is still queued.
## Where the server is: SERVER; or --join=URL; in a browser, the page's
## ?server=wss://… address.
## Command line, after `--`: --server [--port=N] [--bots=N] | --join=URL [--ready]
## (Looks State up rather than naming it, and finds the Table by its group:
## this script compiles before the autoloads exist.)

const SERVER := "ws://127.0.0.1:7000"   # the server, unless told otherwise
const PORT := 7000
const MAX_PLAYERS := 6   # people and bots
const AWAY_TIME := 60.0   # s a dropped player's seat waits for them
const RETRY := 2.0   # s between a dropped device's tries to get back in
const LINGER := 0.5   # s a line stays open after leaving, for the goodbye to go out

signal changed   # people, ready_count or status changed (the lobby shows them)

var people := 0   # seated in the match being formed…
var ready_count := 0   # …and how many of them are ready
var status := ""   # what's happening, for the lobby

var _state: Node
var _auto_ready := false   # --ready: ready as soon as seated
var _match_on := false   # a networked match began here (leaving it tells the server)
# Server
var _seats := {}   # peer → seat
var _ready_seats := {}   # seat → true, ready to start
var _tokens := {}   # rejoin token → seat
var _away := {}   # seat → the drop's time (ms), waiting for them to come back
var _bots := 0
var _next_seat := 1
# Player
var _address := ""
var _token := 0   # mine, to get my seat back
var _retry_until := 0.0   # s (engine time) to keep trying to get back in; 0: not trying


func _ready() -> void:
	_state = get_node("/root/State")
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_failed)
	multiplayer.server_disconnected.connect(_on_lost)
	_state.screen_changed.connect(func(screen: int) -> void:
		if screen == GameState.Screen.HOME and _match_on:
			leave())   # back home from a networked match: tell the server
	_from_command_line()


func _from_command_line() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var pair := arg.trim_prefix("--").split("=", true, 1)
		args[pair[0]] = pair[1] if pair.size() > 1 else ""
	_auto_ready = args.has("ready")
	if args.has("server"):
		serve(int(args.get("port", PORT)), int(args.get("bots", 0)))
	elif args.has("join"):
		join(args.join)


# --- connecting ------------------------------------------------------------------

## Runs the server: listens on `port`; `bots` fill seats beside the people.
func serve(port := PORT, bots := 0) -> Error:
	var line := WebSocketMultiplayerPeer.new()
	var error := line.create_server(port)
	if not error:
		multiplayer.multiplayer_peer = line
		_bots = bots
	return error


## Connects to the server at `address` (default: the page's ?server=, or
## SERVER) to be seated in its match.
func join(address := "") -> Error:
	_address = address if address else _server_address()
	var line := WebSocketMultiplayerPeer.new()
	var error := line.create_client(_address)
	if not error:
		multiplayer.multiplayer_peer = line
	_set_status("Searching for a match…" if not error else "Couldn't reach the server")
	return error


## I'm ready: the match starts once every seated person is.
func ready_up() -> void:
	_ready_up.rpc_id(1)


## Leaves the match being formed or played: the server removes my seat at once.
func leave() -> void:
	var line := multiplayer.multiplayer_peer
	if line is OfflineMultiplayerPeer:
		return
	_match_on = false
	_token = 0   # (so the line closing isn't taken for a drop)
	_retry_until = 0.0
	if line.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_leaving.rpc_id(1)
	get_tree().create_timer(LINGER).timeout.connect(_offline)   # the goodbye goes out first


# Back to offline: Godot's offline peer, everything forgotten (the peer first,
# so the old line's closing signals find nothing to act on).
func _offline() -> void:
	var line := multiplayer.multiplayer_peer
	if not line is OfflineMultiplayerPeer:
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
		line.close()
	_match_on = false
	_token = 0
	_retry_until = 0.0
	people = 0
	ready_count = 0
	changed.emit()


# Where the server is: a browser page's ?server= address, else SERVER.
func _server_address() -> String:
	if OS.has_feature("web"):
		var given: Variant = JavaScriptBridge.eval("new URLSearchParams(location.search).get('server') || ''")
		if given is String and given:
			return given
	return SERVER


# Connected (or back): say who I am — my token, if I had a seat.
func _on_connected() -> void:
	_retry_until = 0.0
	_hello.rpc_id(1, _token)


# --- the server: seats and the start ------------------------------------------------

# Someone connected: a token for a seat that's waiting for them gets it back
# (and a snapshot); anyone else gets a new seat, if the match hasn't begun and
# isn't full — otherwise they're refused.
@rpc("any_peer", "reliable")
func _hello(token: int) -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	var seat: int = _tokens.get(token, 0)
	if _away.has(seat):
		_away.erase(seat)
		_seats[peer] = seat
		_table().reseat(seat, peer)
		if _table().send_snapshot(seat):
			return
	if _state.is_on(GameState.Screen.MATCH) or _seats.size() + _bots >= MAX_PLAYERS:
		_refused.rpc_id(peer)   # (it closes its line; a disconnect now would drop this)
		return
	var new_seat := _next_seat
	_next_seat += 1
	_seats[peer] = new_seat
	var new_token := randi() | 1   # never 0 (no token)
	_tokens[new_token] = new_seat
	_seated.rpc_id(peer, new_token)
	_tell_roster()


@rpc("any_peer", "reliable")
func _ready_up() -> void:
	var seat: int = _seats.get(multiplayer.get_remote_sender_id(), 0)
	if not multiplayer.is_server() or seat == 0 or _state.is_on(GameState.Screen.MATCH):
		return
	_ready_seats[seat] = true
	_tell_roster()
	if _seats.size() >= 2 and _seats.values().all(func(s: int) -> bool: return _ready_seats.has(s)):
		_begin.rpc({"seats": _seats.duplicate(), "bots": _bots})


# Someone's connection is gone. Before the match, their seat frees; in a match
# whose deal has begun, it waits AWAY_TIME for them; before that, it's removed.
func _on_peer_disconnected(peer: int) -> void:
	var seat: int = _seats.get(peer, 0)
	_seats.erase(peer)
	if not multiplayer.is_server() or seat == 0:
		return
	_ready_seats.erase(seat)
	if not _state.is_on(GameState.Screen.MATCH):
		_tokens.erase(_tokens.find_key(seat))
		_tell_roster()
	elif _state.sub in [GameState.Sub.DEALING, GameState.Sub.PLAY]:
		var dropped := Time.get_ticks_msec()
		_away[seat] = dropped
		get_tree().create_timer(AWAY_TIME).timeout.connect(_seat_lost.bind(seat, dropped))
	else:
		_remove(seat)


# The wait is over: still away since that drop, the seat goes.
func _seat_lost(seat: int, dropped: int) -> void:
	if _away.get(seat) == dropped:
		_away.erase(seat)
		_remove(seat)


@rpc("any_peer", "reliable")
func _leaving() -> void:
	if not multiplayer.is_server():
		return
	var seat: int = _seats.get(multiplayer.get_remote_sender_id(), 0)
	_seats.erase(multiplayer.get_remote_sender_id())   # (its disconnect then finds no seat)
	_ready_seats.erase(seat)
	if _state.is_on(GameState.Screen.MATCH):
		_remove(seat)
	else:
		_tokens.erase(_tokens.find_key(seat))
		_tell_roster()


# A seat gone for good; the last one ends the match, freeing the server.
func _remove(seat: int) -> void:
	_tokens.erase(_tokens.find_key(seat))
	if _table() and seat:
		_table().remove_player(seat)
	if _seats.is_empty() and _away.is_empty() and _state.is_on(GameState.Screen.MATCH):
		_tokens.clear()
		_ready_seats.clear()
		_next_seat = 1
		_state.enter(GameState.Screen.HOME)


# Everyone's told how many are seated and how many are ready.
func _tell_roster() -> void:
	_roster.rpc(_seats.size(), _ready_seats.size())


# --- every player ------------------------------------------------------------------

@rpc("authority", "reliable")
func _seated(token: int) -> void:
	_token = token
	if _auto_ready:
		ready_up()


@rpc("authority", "reliable")
func _roster(seated: int, readied: int) -> void:
	people = seated
	ready_count = readied
	_set_status("Waiting for players…")


# Everyone's ready: the match's seats and bots, and in we go together.
@rpc("authority", "call_local", "reliable")
func _begin(setup: Dictionary) -> void:
	_state.match_setup = setup
	_match_on = true
	_state.enter(GameState.Screen.MATCH)


@rpc("authority", "reliable")
func _refused() -> void:
	_give_up(&"match_full")


# My line to the server is gone. Mid-match, with a seat: keep trying to get
# back in for AWAY_TIME (the table stays as it is meanwhile); else it's over.
func _on_lost() -> void:
	if _token and _state.is_on(GameState.Screen.MATCH):
		if _retry_until == 0.0:
			_retry_until = Time.get_ticks_msec() / 1000.0 + AWAY_TIME
		get_tree().create_timer(RETRY).timeout.connect(_try_again)
	else:
		_give_up(&"server_left")


func _try_again() -> void:
	if _retry_until > 0.0:
		join(_address)


func _on_failed() -> void:
	if _retry_until > Time.get_ticks_msec() / 1000.0:
		get_tree().create_timer(RETRY).timeout.connect(_try_again)
	else:
		_set_status("Couldn't reach the server")
		_give_up(&"connection_lost")


# Offline again, home, and why.
func _give_up(why: StringName) -> void:
	_offline()
	var settings := get_tree().get_first_node_in_group(&"settings")
	if settings and not _state.is_on(GameState.Screen.HOME):
		settings.do(&"home")
	if settings:
		settings.open(why)


func _set_status(text: String) -> void:
	status = text
	changed.emit()


func _table() -> Node:
	return get_tree().get_first_node_in_group(&"table")
