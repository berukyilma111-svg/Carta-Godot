class_name GameState
extends Node
## The game's master state: the one place that says where the game is. Every
## other script asks it — "are we in a match?", "may the player act yet?" —
## instead of keeping flags of its own.
##
## Two levels:
##   screen   one of SCREENS, and only ever one: entering a screen unloads the
##            last one whole (its scene freed), so only one screen's nodes are
##            ever in memory — light enough for old phones and web browsers.
##   sub      a step inside the active screen (a match's deal, its play, its
##            game over). Changing it keeps the scene; a sub belongs to one
##            screen only.
##
## The autoload "State" (/root/State, the same path on every device, for
## multiplayer). Wired: HOME, PROFILE (placeholder data) and MATCH. The other screens are set up below and
## refused by enter() until each one gets its scene. This is the menu flow
## only: no match set-up or player data lives here.

signal screen_changed(screen: Screen)   # the new screen's scene is in place
signal sub_changed(sub: Sub)

enum Screen { HOME, PROFILE, LOBBY, MATCH, AD }

const WARM_PER_FRAME := 2   # new letters the font makes ahead each frame

enum Sub {
	NONE,   # a screen with no steps
	# HOME
	MODES,   # the three mode cards: Tutorial, Online, Bot Player
	ONLINE,   # Online tapped: Local Match / Server Match showing too
	BOTS,   # Bot Player tapped: how many bots (1–5) showing too
	# PROFILE
	PLAYER_PROFILE,   # the player: ranking, personalisation, details to edit
	TEAM_PROFILE,   # their team or league: ranking, active players, join, leave, add, edit
	# LOBBY
	SEARCHING,   # connected (or connecting) to the server, waiting for the match to fill and be ready
	# MATCH
	STARTER_SELECTION,   # 12 face-down cards: each player picks one (no control once they have)
	STARTER_SELECTED,   # all flipped: the play order shows (highest first, lowest last)
	DEALING,   # no one has control until every hand is dealt
	PLAY,   # the match is on
	GAME_OVER,   # someone won, lost or left: the game over screen
}

## Each screen as data: its scene (empty: not made yet), its steps (the first
## is where it starts), the steps where the player has control, and the
## screens it may go to next.
const SCREENS := {
	Screen.HOME: {"scene": "res://Home.tscn", "subs": [Sub.MODES, Sub.ONLINE, Sub.BOTS], "control": [Sub.MODES, Sub.ONLINE, Sub.BOTS],
			"next": [Screen.PROFILE, Screen.LOBBY, Screen.MATCH]},   # (match: Bot Player, Tutorial for now)
	Screen.PROFILE: {"scene": "res://Profile.tscn", "subs": [Sub.PLAYER_PROFILE, Sub.TEAM_PROFILE],
			"control": [Sub.PLAYER_PROFILE, Sub.TEAM_PROFILE], "next": [Screen.HOME]},
	Screen.LOBBY: {"scene": "res://Lobby.tscn", "subs": [Sub.SEARCHING], "control": [Sub.SEARCHING],
			"next": [Screen.MATCH, Screen.HOME]},
	Screen.MATCH: {"scene": "res://Table.tscn",
			"subs": [Sub.STARTER_SELECTION, Sub.STARTER_SELECTED, Sub.DEALING, Sub.PLAY, Sub.GAME_OVER],
			"control": [Sub.STARTER_SELECTION, Sub.PLAY, Sub.GAME_OVER],   # (Table ignores a second pick)
			"next": [Screen.AD, Screen.HOME]},   # (home: left the match)
	Screen.AD: {"scene": "", "subs": [Sub.NONE], "control": [], "next": [Screen.HOME, Screen.LOBBY]},   # (lobby: play again)
}

## Steps that only go forward, each to the one listed. Steps not listed (a
## profile's tabs, the lobby's modes) switch freely within their screen.
const STEP_NEXT := {
	Sub.STARTER_SELECTION: [Sub.STARTER_SELECTED],
	Sub.STARTER_SELECTED: [Sub.DEALING],
	Sub.DEALING: [Sub.PLAY],
	Sub.PLAY: [Sub.GAME_OVER],
	Sub.GAME_OVER: [],
}

var screen := Screen.HOME
var sub := Sub.MODES   # (home's first step, until the first enter())
var stage: Node   # where the active screen's scene lives (Main's Stage)
## The next match's set-up, written by whichever screen starts it (home now, the
## lobby later) and read by the Table as it opens: {"bots": 0–5, "seats": {peer
## id: seat}} (no "seats": offline, this device in seat 1). A choice
## carried to the match, not game rules.
var match_setup := {}
var _started := false   # the first screen has been entered (it comes from nowhere)
var _arriving: Node   # the screen made ahead, off stage until the fade brings it in
var _warm_queue := ""   # letters waiting to be made ahead
var _warmed := {}   # letters made (or queued)


func _ready() -> void:
	set_process(false)   # runs only while letters are queued


# Quitting while a screen waits off stage to come in: it goes too.
func _exit_tree() -> void:
	if is_instance_valid(_arriving):
		_arriving.free()


# ── Asking ────────────────────────────────────────────────────────────────────

## Whether the game is on `on` (and, if given, at step `at` of it).
func is_on(on: Screen, at := Sub.NONE) -> bool:
	return screen == on and (at == Sub.NONE or sub == at)


## Whether the player may act now (no one can while a match deals, an ad shows…).
func has_control() -> bool:
	return sub in SCREENS[screen].control


# ── Changing ──────────────────────────────────────────────────────────────────

## Enters `next`: the active screen fades out and is freed whole — with `also`,
## anything else leaving with it (an open menu) — then `next`'s scene is made
## and fades in, starting at step `at` (default: its first). The state changes
## at once; the signals come when the new scene is in place. Refused: a screen
## that isn't in the active one's "next", a step that isn't `next`'s, and a
## screen without a scene yet.
func enter(next: Screen, at := Sub.NONE, also: Array = []) -> void:
	if _started and next not in SCREENS[screen].next:
		push_warning("GameState: %s can't go to %s" % [Screen.keys()[screen], Screen.keys()[next]])
		return
	var first: Sub = SCREENS[next].subs[0] if at == Sub.NONE else at
	if first not in SCREENS[next].subs:
		push_warning("GameState: %s isn't a step of %s" % [Sub.keys()[first], Screen.keys()[next]])
		return
	var path: String = SCREENS[next].scene
	if path.is_empty():
		push_warning("GameState: %s has no scene yet" % Screen.keys()[next])
		return
	_started = true
	screen = next
	sub = first
	# Made now, off stage — loaded in the background if it wasn't loaded ahead
	# (the first screen), waiting a frame at a time rather than stalling one —
	# and its letters start being made while the old screen fades out.
	if not ResourceLoader.has_cached(path) \
			and ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		ResourceLoader.load_threaded_request(path)
	while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
	var loaded := ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED
	var scene: Node = (ResourceLoader.load_threaded_get(path) if loaded else load(path)).instantiate()
	_arriving = scene
	warm_text(_text_in(scene))
	var leaving := stage.get_children() + also
	if leaving.is_empty():   # nothing on screen to cover it (the game's start): letters first
		while _warm_queue:
			await get_tree().process_frame
	# (a method, not a lambda: the fade queue outlives this script at quitting,
	# and a lambda left in it then crashes the engine)
	Animations.fade(leaving, _build.bind(scene), true)


# The screen's scene, once the old one has faded out and gone: put on stage,
# announced; then the next screens start loading. Returned for the fade to bring in.
func _build(scene: Node) -> Array:
	_arriving = null
	stage.add_child(scene)
	screen_changed.emit(screen)
	sub_changed.emit(sub)
	_load_ahead()
	return [scene]


## Has the font make `text`'s letters ahead, WARM_PER_FRAME a frame, so none
## is made all at once when it's first shown (~6–9 ms a letter, the first time
## only: one letter serves every size).
func warm_text(text: String) -> void:
	for letter in text:
		if not _warmed.has(letter):
			_warmed[letter] = true
			_warm_queue += letter
	set_process(not _warm_queue.is_empty())


func _process(_delta: float) -> void:
	ThemeDB.fallback_font.get_string_size(_warm_queue.left(WARM_PER_FRAME))   # measuring makes them
	_warm_queue = _warm_queue.substr(WARM_PER_FRAME)
	set_process(not _warm_queue.is_empty())


# Every letter shown in `node` and its children (labels, buttons).
func _text_in(node: Node) -> String:
	var text := ""
	for item in [node] + node.find_children("*", "", true, false):
		if "text" in item and item.text is String:
			text += item.text
	return text


# The scenes of the screens this one can go to start loading in the background
# (scripts compiled too), so entering one doesn't stall while it loads; enter()
# picks the load up (waiting for it if it isn't done yet).
func _load_ahead() -> void:
	for next in SCREENS[screen].next:
		var path: String = SCREENS[next].scene
		if path and not ResourceLoader.has_cached(path) \
				and ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			ResourceLoader.load_threaded_request(path)


## Moves to step `next` of the active screen. Refused: a step of another
## screen, and going out of order where STEP_NEXT sets one.
func step(next: Sub) -> void:
	if next not in SCREENS[screen].subs:
		push_warning("GameState: %s isn't a step of %s" % [Sub.keys()[next], Screen.keys()[screen]])
		return
	if sub in STEP_NEXT and next != sub and next not in STEP_NEXT[sub]:
		push_warning("GameState: %s can't go to %s" % [Sub.keys()[sub], Sub.keys()[next]])
		return
	if next != sub:
		sub = next
		sub_changed.emit(sub)
