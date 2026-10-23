class_name Settings
extends Control
## The player's settings and the pause menu.
## Settings — vibration and card size now; sound, music… later — are saved to
## user://settings.cfg the moment they change; read one anywhere with
## Settings.get_option("card_scale") / Settings.is_on("vibration").
## The menu: the menu button (top-right, in SafeArea, on every screen but the
## profile) opens it — the pause menu in a match, the short menu (Settings,
## Quit) anywhere else. Every screen — a menu, a sub-menu, a confirmation — is
## a few rows of data in SCREENS, built by the same open() and taken down by
## the same close(): a stack of screens over a dim overlay that blocks what's
## under it. Like QUOD, screens are data, built when shown and freed when
## closed — while playing, the menu is just its button. Back (Esc, Android's
## back) closes the top screen, or does what the menu button does.
## Which screen is on (home, a match) is the State autoload's: the menu asks it
## to change screens and follows it. This node lives in Main for the whole run,
## so the menu serves every screen.

signal changed(option: String)   # a setting was changed from the menu

const PATH := "user://settings.cfg"
const DEFAULTS := {"vibration": true,"card_scale": 1.0,   # every card's size on the table
}
const DIM := Color(0, 0, 0, 0.55)   # the overlay over the table while paused
const PANEL := Color("#202027")   # behind each screen's rows
const TEXT_SIZE := 30   # menu text, px in the 720-wide design
# Screens, rows top to bottom: a title; a button that does "close", "quit" or
# opens another screen; a toggle or a slider for a setting.
const SCREENS := {
	&"menu": [   # outside a match
		{"title": "Menu"},
		{"button": "Settings", "do": &"settings"},
		{"button": "Quit", "do": &"confirm_quit"},
		{"button": "Close", "do": &"close"},
	],
	&"pause": [   # in a match
		{"title": "Paused"},
		{"button": "Resume", "do": &"close"},
		{"button": "Settings", "do": &"settings"},
		{"button": "Home", "do": &"confirm_home"},
		{"button": "Quit", "do": &"confirm_quit"},
	],
	&"confirm_home": [
		{"title": "Leave the match?"},
		{"button": "Leave", "do": &"home"},
		{"button": "Cancel", "do": &"close"},
	],
	&"settings": [
		{"title": "Settings"},
		{"toggle": "Vibration", "option": "vibration"},
		{"slider": "Card size", "option": "card_scale", "min": 1.0, "max": 1.7, "step": 0.05},
		{"button": "Back", "do": &"close"},
	],
	&"server_left": [   # (Net: the server's line closed)
		{"title": "Server left"},
		{"button": "OK", "do": &"close"},
	],
	&"connection_lost": [   # (Net: couldn't reach the server, or get back in time)
		{"title": "Connection lost"},
		{"button": "OK", "do": &"close"},
	],
	&"match_full": [   # (Net: the server's match had already begun, or was full)
		{"title": "Match full"},
		{"button": "OK", "do": &"close"},
	],
	&"confirm_quit": [
		{"title": "Quit the game?"},
		{"button": "Quit", "do": &"quit"},
		{"button": "Cancel", "do": &"close"},
	],
}

static var _saved := _load()

# Looked up rather than named: Device's script uses this class, so naming an
# autoload here would make a load cycle (this script compiles before they exist).
@onready var _device: Node = get_node("/root/Device")
@onready var _state: Node = get_node("/root/State")

var _screens: Array[Control] = []   # open screens, the top one last
var _overlay: ColorRect   # exists only while a screen is open


static func get_option(option: String) -> Variant:
	return _saved.get_value("options", option, DEFAULTS[option])


static func is_on(option: String) -> bool:
	return get_option(option)


static func set_option(option: String, value: Variant) -> void:
	_saved.set_value("options", option, value)
	_saved.save(PATH)


func _ready() -> void:
	_set_up_menu()
	_keep_in_slider_ranges()
	_apply_card_scale()   # before any table deals
	_start_game()


# A saved value outside its slider's range (saved under an older range) goes to
# the nearest end and is saved so: the slider and what it sets always agree.
func _keep_in_slider_ranges() -> void:
	for rows in SCREENS.values():
		for row in rows:
			if row.has("slider"):
				var value: float = get_option(row.option)
				var kept := clampf(value, row.min, row.max)
				if kept != value:
					set_option(row.option, kept)


# The menu button in the safe area, shown on every screen but the profile;
# every menu's letters made once the first screen is up.
func _set_up_menu() -> void:
	add_to_group(&"settings")   # how a match finds this menu
	_device.keep_in_safe_area($SafeArea)
	$SafeArea/Menu.pressed.connect(_open_menu)
	_state.screen_changed.connect(func(screen: int) -> void:
		$SafeArea/Menu.visible = screen != GameState.Screen.PROFILE)   # the profile has its own way back
	_state.screen_changed.connect(_warm_menus, CONNECT_ONE_SHOT)


# Hands State Main's stage and opens the home screen.
func _start_game() -> void:
	_state.stage = get_node("../../Stage")   # Main's slot for the active screen
	_state.enter.call_deferred(GameState.Screen.HOME)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_back()
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:   # Android's back
		_back()


func _back() -> void:
	if _screens:
		close()
	elif _state.is_on(GameState.Screen.PROFILE):
		_state.enter(GameState.Screen.HOME)   # the profile has no menu: back goes home
	elif $SafeArea/Menu.visible:
		_open_menu()


# Once the first screen is up: every menu's letters are made in the background,
# so the first menu opened doesn't stall making them.
func _warm_menus(_screen: int) -> void:
	var text := ""
	for rows in SCREENS.values():
		for row in rows:
			for key in ["title", "button", "toggle", "slider"]:
				text += row.get(key, "")
	_state.warm_text(text)


# The menu button: the pause menu in a match, the short menu anywhere else.
func _open_menu() -> void:
	open(&"pause" if _state.is_on(GameState.Screen.MATCH) else &"menu")


# Changes screen through State; any open menu fades out with the old screen.
# (Leaving a networked match will tell the table first.)
func _enter(screen: GameState.Screen) -> void:
	var menu := [_overlay] if _overlay else []
	_overlay = null
	_screens.clear()
	_state.enter(screen, GameState.Sub.NONE, menu)


# --- screens -------------------------------------------------------------------

## Opens `screen` on top of any open one; the first brings up the overlay that
## blocks the table.
func open(screen: StringName) -> void:
	if _overlay == null:
		_overlay = ColorRect.new()
		_overlay.color = DIM
		_overlay.set_anchors_preset(PRESET_FULL_RECT)
		_overlay.theme = Theme.new()
		_overlay.theme.default_font_size = TEXT_SIZE
		var panel := StyleBoxFlat.new()
		panel.bg_color = PANEL
		panel.set_corner_radius_all(TEXT_SIZE / 2)
		panel.set_content_margin_all(TEXT_SIZE * 0.8)
		_overlay.theme.set_stylebox("panel", "PanelContainer", panel)
		add_child(_overlay)
		Animations.fade([], [_overlay])   # it blocks the table at once; the fade is only looks
	if _screens:
		_screens.back().hide()
	_screens.append(_build(screen))
	_overlay.add_child(_screens.back())


## Closes the top screen: the one under it comes back, or — the last one — the
## overlay fades out with it and the game carries on (at once: nothing in the
## fading overlay takes presses; a menu opened meanwhile fades in after it).
func close() -> void:
	var top: Control = _screens.pop_back()
	if _screens:
		top.queue_free()
		_screens.back().show()
	else:
		Animations.fade([_overlay], [], true)
		_overlay = null


## Does a menu action: a row's `do`.
func do(action: StringName) -> void:
	match action:
		&"close":
			close()
		&"quit":
			get_tree().quit()
		&"home":
			_enter(GameState.Screen.HOME)
		_:
			open(action)


# A screen from its rows: a centred panel; rows for settings this device can't
# use are left out.
func _build(screen: StringName) -> Control:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(PRESET_CENTER)
	panel.grow_horizontal = GROW_DIRECTION_BOTH
	panel.grow_vertical = GROW_DIRECTION_BOTH
	var rows := VBoxContainer.new()
	rows.custom_minimum_size.x = TEXT_SIZE * 10
	rows.add_theme_constant_override("separation", TEXT_SIZE / 2)
	panel.add_child(rows)
	for row in SCREENS[screen]:
		if not row.has("option") or _available(row.option):
			rows.add_child(_row(row))
	return panel


func _row(row: Dictionary) -> Control:
	if row.has("title"):
		var title := Label.new()
		title.text = row.title
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		return title
	if row.has("button"):
		var button := Button.new()
		button.text = row.button
		button.focus_mode = FOCUS_NONE
		button.pressed.connect(do.bind(row.do))
		return button
	if row.has("toggle"):
		var toggle := CheckButton.new()
		toggle.text = row.toggle
		toggle.focus_mode = FOCUS_NONE
		toggle.button_pressed = get_option(row.option)
		toggle.toggled.connect(_on_changed.bind(row.option))
		return toggle
	var box := VBoxContainer.new()   # a slider, its label above it
	var label := Label.new()
	label.text = row.slider
	var slider := HSlider.new()
	slider.focus_mode = FOCUS_NONE
	slider.min_value = row.min
	slider.max_value = row.max
	slider.step = row.step
	slider.value = get_option(row.option)
	slider.custom_minimum_size.y = TEXT_SIZE * 1.5
	slider.value_changed.connect(_on_changed.bind(row.option))
	box.add_child(label)
	box.add_child(slider)
	return box


# --- settings ------------------------------------------------------------------

func _on_changed(value: Variant, option: String) -> void:
	set_option(option, value)
	match option:
		"vibration":
			if value:
				_device.vibrate(20)   # a short buzz, so the player feels it work
		"card_scale":
			_apply_card_scale()
	changed.emit(option)


# Sizes every card on the table to the saved scale; faces re-bake at it.
func _apply_card_scale() -> void:
	CardFace.card_scale = get_option("card_scale")
	get_tree().call_group(CardFace.REDRAW_GROUP, "refresh_scale")
	get_tree().call_group(CardFace.REDRAW_GROUP, "queue_redraw")


# Whether this device can use the option at all.
func _available(option: String) -> bool:
	match option:
		"vibration":
			return _device.can_vibrate
	return true


static func _load() -> ConfigFile:
	var saved := ConfigFile.new()
	saved.load(PATH)   # missing on first run: defaults apply
	return saved
