class_name InputTuning
extends Resource
## Input feel for one device class. The presets in Presets/ (phone, tablet,
## desktop) are these; Device picks one at startup and PlayerControl reads it
## live, so edits made while running apply on the next press.
## Defaults are the phone values (iOS touch conventions).

@export_group("Tap & Hold")
@export_range(2, 30, 0.5, "suffix:pt") var touch_slop := 10.0   # finger movement still counted as a tap (1 pt = 1/163 inch)
@export_range(1, 20, 1, "suffix:px") var mouse_slop := 4.0   # the same for a mouse (Windows default)
@export_range(0.2, 1.5, 0.05, "suffix:s") var hold_time := 0.5   # press-and-hold before a drag starts

@export_group("Drag")
@export_range(1.0, 1.3, 0.01) var lift_scale := 1.06   # dragged card, so it reads as picked up

@export_group("Flick & Slide")
@export_range(100, 2000, 10, "suffix:pt/s") var flick_speed_pt := 500.0   # a release faster than this is a flick
@export_range(0.03, 0.3, 0.01, "suffix:s") var velocity_window := 0.1   # recent drag history that sets the release speed
@export_range(1, 20, 0.1, "suffix:1/s") var table_friction := 6.5   # higher = snappier: a card's slide takes 4 ÷ friction s

@export_group("Screen")
@export var use_safe_area := true   # keep the table clear of notches, rounded corners and system bars

@export_group("Haptics")
@export var haptics := true   # only where Device finds a vibration motor it may use
@export_range(0, 1, 0.05) var haptic_strength := 0.5   # amplitude, Android 8+; ignored elsewhere
@export_range(0, 50, 1, "suffix:ms") var hold_haptic_ms := 15   # a hold lifts the card
@export_range(0, 50, 1, "suffix:ms") var land_haptic_ms := 10   # a card settles into its place
