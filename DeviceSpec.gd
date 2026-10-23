extends Node
## Device spec (autoload "Device"): works out what this device is, applies the
## matching input preset and keeps the screen facts that move with rotation or
## resizing up to date. Owns the safe area: safe_rect() for world layout and
## keep_in_safe_area() for HUD roots.
##   phone / tablet — touch first: safe area (notch, corners, system bars),
##                    orientation, and whether vibration is available and allowed
##   desktop        — mouse first: no safe area or vibration; notes HiDPI scaling
##                    and touchscreens (touch laptops), and sets a minimum window
## Force a class for testing: run with user args `-- --device=phone` (or tablet, desktop).

signal changed   # safe area or orientation moved (rotation, window resize)

enum Kind { PHONE, TABLET, DESKTOP }

const PRESETS := {
	Kind.PHONE: preload("res://Presets/phone.tres"),
	Kind.TABLET: preload("res://Presets/tablet.tres"),
	Kind.DESKTOP: preload("res://Presets/desktop.tres"),
}
const TABLET_INCHES := 7.0   # screen diagonal from which a mobile device counts as a tablet
const MIN_WINDOW := Vector2i(300, 480)   # desktop: smallest window the table stays usable in

var kind := Kind.DESKTOP
var tuning: InputTuning   # the active preset; PlayerControl reads it live
var mobile: bool:
	get: return kind != Kind.DESKTOP

# Spec facts, read once at startup
var model := ""
var dpi := 96
var diagonal_in := 0.0   # physical screen diagonal, inches
var refresh_rate := 60.0
var touchscreen := false
var can_vibrate := false   # motor present and permitted (mobile checks)
var hidpi_scale := 1.0   # OS display scaling (desktop checks)

# Screen facts, re-read on rotation / resize
var portrait := false
var safe_area := Rect2()   # window px the player can see and reach


func _ready() -> void:
	_read_spec()
	_choose_preset()
	_read_screen()
	get_tree().root.size_changed.connect(_on_resized)   # rotation, window resizing
	if OS.is_debug_build():
		print(describe())


# The hardware facts, read once.
func _read_spec() -> void:
	model = OS.get_model_name()
	dpi = DisplayServer.screen_get_dpi()
	diagonal_in = Vector2(DisplayServer.screen_get_size()).length() / dpi
	var hz := DisplayServer.screen_get_refresh_rate()
	refresh_rate = hz if hz > 0 else 60.0
	touchscreen = DisplayServer.is_touchscreen_available()


# Phone, tablet or desktop: its input preset, and the checks that kind needs.
func _choose_preset() -> void:
	kind = _detect_kind()
	tuning = PRESETS[kind]
	if mobile:
		_check_mobile()
	else:
		_check_desktop()


## Vibrates if this device can, the preset uses haptics and the player hasn't
## turned vibration off in Settings.
func vibrate(ms: int) -> void:
	if can_vibrate and tuning.haptics and Settings.is_on("vibration") and ms > 0:
		Input.vibrate_handheld(ms, tuning.haptic_strength)


## The safe area in `item`'s own coordinates (its canvas, after any camera):
## what's visible and reachable there. Falls back to the visible rect if the
## two don't overlap.
func safe_rect(item: CanvasItem) -> Rect2:
	var vp := item.get_viewport()
	var reachable := vp.get_visible_rect().intersection(vp.get_final_transform().affine_inverse() * safe_area)
	if not reachable.has_area():
		reachable = vp.get_visible_rect()
	return item.get_canvas_transform().affine_inverse() * reachable


## Keeps a full-rect `control` (a HUD root) inset to the safe area, now and on
## every rotation / resize, until it leaves the tree. Put HUD controls inside it
## and anchor them as usual; give it mouse_filter Ignore so the table under it
## still takes presses.
func keep_in_safe_area(control: Control) -> void:
	var fit := func() -> void: _fit_to_safe_area(control)   # its own callable: binds of one method count as one connection
	fit.call()
	changed.connect(fit)
	control.tree_exiting.connect(changed.disconnect.bind(fit), CONNECT_ONE_SHOT)


func _fit_to_safe_area(control: Control) -> void:
	var full := control.get_viewport().get_visible_rect()
	var safe := safe_rect(control)
	control.offset_left = safe.position.x - full.position.x
	control.offset_top = safe.position.y - full.position.y
	control.offset_right = safe.end.x - full.end.x
	control.offset_bottom = safe.end.y - full.end.y


func describe() -> String:
	return "Device: %s  %s  %.1f in  %d dpi  %d Hz  %s  touch=%s  vibrate=%s (player %s)  scale=%.2f  safe=%s" % [
		Kind.keys()[kind], model, diagonal_in, dpi, refresh_rate,
		"portrait" if portrait else "landscape", touchscreen, can_vibrate,
		"on" if Settings.is_on("vibration") else "off", hidpi_scale, safe_area]


func _detect_kind() -> Kind:
	for arg in OS.get_cmdline_user_args():
		var forced := arg.trim_prefix("--device=").to_upper()
		if arg.begins_with("--device=") and Kind.has(forced):
			return Kind[forced]
	var on_mobile := OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios")
	if not on_mobile:
		return Kind.DESKTOP
	return Kind.TABLET if model.begins_with("iPad") or diagonal_in >= TABLET_INCHES else Kind.PHONE


# Phones and tablets: is there a vibration motor we're allowed to use?
func _check_mobile() -> void:
	if OS.has_feature("android"):
		can_vibrate = OS.get_granted_permissions().has("android.permission.VIBRATE")
	elif OS.has_feature("ios"):
		can_vibrate = model.begins_with("iPhone")   # iPads have no vibration motor
	else:
		can_vibrate = OS.has_feature("web_android")   # of mobile browsers, only Android's vibrate


# PCs: mouse first. No vibration; HiDPI scaling and touchscreens are noted (finger
# presses on a touch laptop still get touch slop in PlayerControl). Windows are
# resizable, so keep the table from being squashed below usable.
func _check_desktop() -> void:
	can_vibrate = false
	hidpi_scale = DisplayServer.screen_get_scale()
	get_window().min_size = MIN_WINDOW


# Orientation and the reachable area, in window px. With use_safe_area the
# display's unsafe edges (notch, rounded corners, system bars) are cut away.
func _read_screen() -> void:
	var window := Vector2(get_window().size)
	portrait = window.y > window.x
	safe_area = Rect2(Vector2.ZERO, window)
	if tuning.use_safe_area:
		var safe := Rect2(DisplayServer.get_display_safe_area())
		safe.position -= Vector2(DisplayServer.window_get_position())   # screen → window px
		if safe.intersects(safe_area):
			safe_area = safe_area.intersection(safe)


func _on_resized() -> void:
	_read_screen()
	changed.emit()
