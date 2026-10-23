class_name Animations
extends RefCounted
## The animation manager: everything that moves on screen moves through here,
## and nothing outside knows how. Every method is blind — it animates whatever
## object it's handed and knows nothing about cards or tables:
##   lerp()      any properties from where they are to new values — positions,
##               rotations, colours, scale, alpha, any property. The engine the
##               others run on.
##   flip()      turns an object over: edge-on, its other side, open again
##   fade()      elements out, then elements in, in tandem: never crossing
##   shuffle()   two objects split apart and riffle back together
## Each plays on a channel of its object: a new animation on a channel replaces
## the one running there. is_playing() and stop() ask about and stop a channel.
## The running animation is kept on the object itself, so it goes when the object does.
## An animation here is a Godot Tween: the engine runs it frame by frame. `Tween`,
## create_tween(), tween_property() and tween_callback() are the engine's own names.

const LERP_TIME := 0.3   # s, when the caller names no time
const FLIP_TIME := 0.25   # s, the whole turn
const FLIP_LIFT := 0.08   # extra height while edge-on, so it reads as lifted
const FLIP_EDGE := 0.02   # width when edge-on: never quite 0, so the object's transform stays invertible
const FADE_TIME := 0.2   # s, each half: out, then in
const SHUFFLE_TIME := 0.48   # s, every riffle together
const SHUFFLE_RIFFLES := 2


# ── Lerp ──────────────────────────────────────────────────────────────────────

## Takes `target`'s properties from where they are now to the values in `to`
## ({"global_position": p, "rotation": r, "modulate": c, "scale": s, …}), all
## together over `time` s, fast at first and settling gently. An Array value is
## a series of stops reached one after another, evenly spaced; `smooth` eases
## in and out instead, for there-and-back motion. `on_done` runs at the end.
static func lerp(target: Object, to: Dictionary, time := LERP_TIME, on_done := Callable(),
		channel := &"move", smooth := false) -> Tween:
	# 1. Whatever runs on this channel gives way
	stop(target, channel)

	# 2. The motion: one animation with all its steps running together, gone with the target if it's a node
	var motion := (Engine.get_main_loop() as SceneTree).create_tween().set_parallel()
	if smooth:
		motion.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	else:
		motion.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	if target is Node:
		motion.bind_node(target)

	# 3. One leg per stop of every property
	for property in to:
		var stops: Array = to[property] if to[property] is Array else [to[property]]
		var step := time / stops.size()
		for i in stops.size():
			var leg := motion.tween_property(target, property, stops[i], step).set_delay(step * i)
			if i > 0:
				leg.from(stops[i - 1])   # each leg starts where the last one ended

	# 4. The end, and remembered on the object's channel
	if on_done.is_valid():
		motion.finished.connect(on_done)
	target.set_meta(_channel_key(channel), motion)
	return motion


# ── Flip ──────────────────────────────────────────────────────────────────────

## Turns `target` over in FLIP_TIME: it narrows to edge-on, lifting a little,
## `swap` runs at the midpoint (show the other side — the target's own business),
## and it opens out again. It squeezes the target's `pose` if it has one (an
## object that composes its own scale from several parts, as a card does), else
## its `scale`. A press can check is_playing(target, &"flip").
static func flip(target: Node, swap: Callable, on_done := Callable()) -> Tween:
	var property := "pose" if "pose" in target else "scale"
	var rest: Vector2 = Vector2.ONE if property == "pose" else target.scale
	var edge_on := rest * Vector2(FLIP_EDGE, 1.0 + FLIP_LIFT)
	var squeeze := Animations.lerp(target, {property: [edge_on, rest]}, FLIP_TIME, on_done, &"flip", true)
	squeeze.tween_callback(swap).set_delay(FLIP_TIME / 2)
	return squeeze


# ── Fade ──────────────────────────────────────────────────────────────────────

static var _fades: Array = []   # fades asked for, the running one first: [leaving, arriving, free_leaving]


## Fades elements (anything drawn: a scene, a menu, a label) in tandem: all of
## `leaving` fade out together, and only once they're gone do all of `arriving`
## fade in together. Either side may be empty:
##   open a menu        fade([], [menu])
##   close a menu       fade([menu], [], true)
##   switch scenes      fade([old_scene], make_new_scene, true)
## `leaving` stop taking input at once, and at the end are hidden — or freed,
## with `free_leaving`. `arriving` is the elements, or a Callable that makes and
## returns them once the leaving ones are gone (a scene not built yet); they wait
## invisible until their turn. A fade asked for while another runs waits for
## it, so fades never cross over.
static func fade(leaving: Array, arriving: Variant = [], free_leaving := false) -> void:
	for element in leaving:
		_stop_input(element)
	if arriving is Array:
		for element in arriving:
			element.modulate.a = 0.0
	_fades.append([leaving, arriving, free_leaving])
	if _fades.size() == 1:
		_run_fades()


# Plays the queued fades one after another: out, then in.
static func _run_fades() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var alive := Animations._alive   # (a method, not a lambda: this may be left waiting at quitting)
	while _fades:
		var leaving: Array = _fades[0][0].filter(alive)
		var arriving: Variant = _fades[0][1]
		var free_leaving: bool = _fades[0][2]
		if leaving:
			for element in leaving:
				Animations.lerp(element, {"modulate:a": 0.0}, FADE_TIME, Callable(), &"fade")
			await tree.create_timer(FADE_TIME).timeout   # a timer, not the animation: an element freed meanwhile can't stall the queue
			for element in leaving.filter(alive):
				if free_leaving:
					if element.get_parent():
						element.get_parent().remove_child(element)   # gone now, so what arrives can take its name
					element.queue_free()
				else:
					element.hide()
		if arriving is Callable:
			arriving = arriving.call()
			for element in arriving:
				element.modulate.a = 0.0
			await tree.process_frame   # its first (heavier) frame passes unseen, not as a jump in the fade
		arriving = arriving.filter(alive)
		if arriving:
			for element in arriving:
				_restore_input(element)
				element.show()
				Animations.lerp(element, {"modulate:a": 1.0}, FADE_TIME, Callable(), &"fade")
			await tree.create_timer(FADE_TIME).timeout
		_fades.pop_front()


static func _alive(element: Object) -> bool:
	return is_instance_valid(element)


# A leaving element stops taking presses and keys, all through; what it took
# is kept on each node, for if it comes back (hidden, not freed).
static func _stop_input(element: Node) -> void:
	for node in [element] + element.find_children("*", "", true, false):
		if not node.has_meta(&"fade_input"):
			node.set_meta(&"fade_input", [node.is_processing_input(), node.is_processing_unhandled_input(),
					node.is_processing_unhandled_key_input(), node.mouse_filter if node is Control else 0,
					node.focus_mode if node is Control else 0])
		node.set_process_input(false)
		node.set_process_unhandled_input(false)
		node.set_process_unhandled_key_input(false)
		if node is Control:
			node.mouse_filter = Control.MOUSE_FILTER_IGNORE
			node.focus_mode = Control.FOCUS_NONE   # nor Enter on a focused button


# An element arriving again takes input as it did before it left.
static func _restore_input(element: Node) -> void:
	for node in [element] + element.find_children("*", "", true, false):
		if node.has_meta(&"fade_input"):
			var took: Array = node.get_meta(&"fade_input")
			node.set_process_input(took[0])
			node.set_process_unhandled_input(took[1])
			node.set_process_unhandled_key_input(took[2])
			if node is Control:
				node.mouse_filter = took[3]
				node.focus_mode = took[4]
			node.remove_meta(&"fade_input")


# ── Shuffle ───────────────────────────────────────────────────────────────────

## Riffles two objects: `a` swings `apart` to one side of where it is, `b` to the
## other side of where it is, and both come back, SHUFFLE_RIFFLES times. `a` may
## be gone already (then only `b` moves). Returns `b`'s animation.
static func shuffle(a: Node2D, b: Node2D, apart: Vector2, on_done := Callable()) -> Tween:
	var riffle: Tween   # each half's in turn; `b`'s is the one returned
	for side in [a, b]:
		if is_instance_valid(side):
			var home: Vector2 = side.global_position
			var out: Vector2 = home + (-apart if side == a else apart)
			var stops := []
			for i in SHUFFLE_RIFFLES:
				stops += [out, home]
			riffle = Animations.lerp(side, {"global_position": stops}, SHUFFLE_TIME, on_done if side == b else Callable(), &"move", true)
	return riffle


# ── Channels ──────────────────────────────────────────────────────────────────

## Whether something is still running on `target`'s `channel`.
static func is_playing(target: Object, channel: StringName) -> bool:
	var attached := _attached(target, channel)
	return attached != null and attached.is_valid() and attached.is_running()


## Stops `target`'s `channel` where it is.
static func stop(target: Object, channel: StringName) -> void:
	var attached := _attached(target, channel)
	if attached and attached.is_valid():
		attached.kill()
	target.remove_meta(_channel_key(channel))


# ── Internals ─────────────────────────────────────────────────────────────────

# The animation attached to `target` on `channel` (it may have finished already), or null.
static func _attached(target: Object, channel: StringName) -> Tween:
	return target.get_meta(_channel_key(channel)) if target.has_meta(_channel_key(channel)) else null


static func _channel_key(channel: StringName) -> StringName:
	return StringName("anim_" + channel)
