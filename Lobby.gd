extends Control
## The lobby (State's LOBBY, SEARCHING): Server Match connects to the server
## (Net.join) and waits here — how many are seated, how many are ready, and
## Ready; Net starts the match once everyone is. Back leaves and goes home.

const TEXT_SIZE := 34
const ROW_HEIGHT := 80

var _info: Label
var _ready_button: Button


# Built as soon as the scene is made (before it's shown), so State makes its
# letters ahead along with the rest of the screen's.
func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		_info = Label.new()
		_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_info.autowrap_mode = TextServer.AUTOWRAP_WORD
		_ready_button = Button.new()
		_ready_button.text = "Ready"
		_ready_button.focus_mode = FOCUS_NONE
		for row: Control in [_info, _ready_button]:
			row.custom_minimum_size.y = ROW_HEIGHT
			row.add_theme_font_size_override("font_size", TEXT_SIZE)
			$SafeArea/Rows.add_child(row)


func _ready() -> void:
	Device.keep_in_safe_area($SafeArea)
	$SafeArea/Back.pressed.connect(_back)
	_ready_button.pressed.connect(_ready_up)
	Net.changed.connect(_refresh)
	Net.join()
	_refresh()


func _ready_up() -> void:
	_ready_button.disabled = true
	Net.ready_up()


func _back() -> void:
	Net.leave()
	State.enter(GameState.Screen.HOME)


func _refresh() -> void:
	_ready_button.visible = Net.people > 0
	_info.text = "%s\n%d players, %d ready" % [Net.status, Net.people, Net.ready_count] if Net.people else Net.status
