extends Control
## The home screen (State's HOME): three mode cards along the bottom —
## Tutorial, Online, Bot Player — and the profile placeholder top-left. Online
## and Bot Player each open an option row above the cards (home's ONLINE and
## BOTS steps; one row at a time, tapping again closes it): Server Match, or
## how many bots (1–5). A bot count starts a match with that many bots
## (State.match_setup); Server Match opens the lobby.

@onready var _rows := {GameState.Sub.ONLINE: $SafeArea/Online, GameState.Sub.BOTS: $SafeArea/Bots}


func _ready() -> void:
	Device.keep_in_safe_area($SafeArea)
	$SafeArea/Profile.pressed.connect(State.enter.bind(GameState.Screen.PROFILE))
	$SafeArea/Modes/Tutorial.pressed.connect(_play_bots.bind(1))   # (a one-bot match until the tutorial exists)
	$SafeArea/Modes/Online.pressed.connect(_toggle.bind(GameState.Sub.ONLINE))
	$SafeArea/Modes/BotPlayer.pressed.connect(_toggle.bind(GameState.Sub.BOTS))
	$SafeArea/Online/ServerMatch.pressed.connect(State.enter.bind(GameState.Screen.LOBBY))
	for count in $SafeArea/Bots.get_child_count():
		$SafeArea/Bots.get_child(count).pressed.connect(_play_bots.bind(count + 1))


# Opens `step`'s option row (closing the other one first), or closes it again.
func _toggle(step: GameState.Sub) -> void:
	var was := State.sub
	if _rows.has(was):
		Animations.fade([_rows[was]])
	if was == step:
		State.step(GameState.Sub.MODES)
	else:
		State.step(step)
		Animations.fade([], [_rows[step]])


# A bot match: me and `bots` bots.
func _play_bots(bots: int) -> void:
	State.match_setup = {"bots": bots}
	State.enter(GameState.Screen.MATCH)
