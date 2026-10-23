extends Control
## The profile screen (State's PROFILE): the central place for solo players,
## teams and leagues — the player's own details and their team's, as two tabs
## (State's PLAYER_PROFILE and TEAM_PROFILE). Back (the button, Esc, Android's
## back) returns home.
## PLACEHOLDER: there are no accounts or server yet. The details come from
## PLACEHOLDER below and the actions are shown but switched off; once profiles
## are real, only where the details come from changes — the screen stays.

const PLACEHOLDER := {
	"player": {
		"details": {"Name": "Player", "Rank": "Unranked", "Games played": 0, "Wins": 0},
		"actions": ["Edit details", "Personalise"],
	},
	"team": {
		"details": {"Team": "No team yet", "League": "None", "Rank": "-", "Active players": 0},
		"actions": ["Join a team", "Create a team", "Add a player", "Leave team"],
	},
}

@onready var _tabs := {
	GameState.Sub.PLAYER_PROFILE: [$SafeArea/Tabs/Player, $SafeArea/Player],
	GameState.Sub.TEAM_PROFILE: [$SafeArea/Tabs/Team, $SafeArea/Team],
}


# Filled as soon as the scene is made (before it's shown), so State makes its
# letters ahead along with the rest of the screen's.
func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		_fill($SafeArea/Player, PLACEHOLDER.player)
		_fill($SafeArea/Team, PLACEHOLDER.team)


func _ready() -> void:
	Device.keep_in_safe_area($SafeArea)
	$SafeArea/Back.pressed.connect(State.enter.bind(GameState.Screen.HOME))
	for tab in _tabs:
		_tabs[tab][0].pressed.connect(_show.bind(tab))


# Switches tab: its button stays down, its panel fades in after the other's out.
func _show(tab: GameState.Sub) -> void:
	for each in _tabs:
		_tabs[each][0].set_pressed_no_signal(each == tab)
	if State.is_on(GameState.Screen.PROFILE, tab):
		return
	var leaving: Control = _tabs[State.sub][1]
	State.step(tab)
	Animations.fade([leaving], [_tabs[tab][1]])


# A tab's details, one line each, and its actions — off until profiles are real.
func _fill(panel: Control, section: Dictionary) -> void:
	for detail in section.details:
		var line := Label.new()
		line.text = "%s: %s" % [detail, section.details[detail]]
		line.add_theme_font_size_override("font_size", 30)
		panel.get_node("Details").add_child(line)
	for action in section.actions:
		var button := Button.new()
		button.text = action
		button.disabled = true
		button.focus_mode = FOCUS_NONE
		button.custom_minimum_size.y = 64
		button.add_theme_font_size_override("font_size", 30)
		panel.get_node("Actions").add_child(button)
