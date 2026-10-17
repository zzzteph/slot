extends Node
## Global audio (autoload "Audio"). Everything is still synthesised by this script -- the project ships no
## asset files -- but no longer sample by sample in GDScript every frame. Each sound is rendered ONCE into
## an AudioStreamWAV (deterministically, spread over the first frames at a few ms a frame, and cached under
## user:// so every later launch loads it in a few ms) and then played by ordinary AudioStreamPlayers:
## C++ mixing, the same on the web export (where AudioStreamGenerator is the fragile path), and nothing
## measurable left in the frame.
##
##   music      one prebuilt loop on the "Music" bus; the slider in Settings is the
##              only way to turn it down (SPEC 118: `M` used to mute it, which nobody asked for and
##              everybody found by accident while typing).
##   engine     a looping two-saw wavetable: pitch_scale follows the rpm, volume the throttle.
##   beds       tyres, rough ground, over-pull drag, rim scrape, rope creak: looping noise/tone beds whose
##              volume (and, for the creak, pitch) follow the amounts the race feeds every physics frame.
##   one-shots  impacts, explosion, countdown beeps, boost, boost-ready chime, tyre pop, rope snap, part
##              crack, the car screen's per-car rev: prebuilt samples through a small pool of players;
##              strength -> volume, a touch of random pitch so no two impacts are quite the same.
##
## The API is unchanged (`set_engine`, `impact`, `set_music_mode`, ...). In a headless run (the test
## suite, the smoke test) nothing is rendered or played: the API still works, it just costs nothing.

const MIX_RATE := 22050
const MUSIC_DB := -15.0
const SFX_DB := -7.0
## The renderer's share of a frame while the sounds are still being built (the first launch, or after the
## synth changed): the menus are on screen then. A chunk overshoots this by a millisecond at most.
const RENDER_BUDGET_USEC := 4000
const CACHE_PATH := "user://audio_cache.bin"
## Bump when the synthesis changes, so a cached render is thrown away. The cache key also carries the game
## version and a hash of this script's source (where the export keeps it), so a dev edit invalidates too.
const CACHE_VERSION := 1
const ENGINE_REF_HZ := 88.2     # the engine loop is rendered at this pitch; pitch_scale does the rest
const CREAK_REF_HZ := 38.0
## The tune's voices sum past 1.0 on their loudest beats; it is rendered at this gain so 16-bit never
## clips, and the music player gives the same gain back (the old synth summed in float before -15 dB).
const MUSIC_HEADROOM := 0.8
const POOL_SIZE := 10           # one-shot voices at once (the old synth stopped at 13)

# --- music -----------------------------------------------------------------------------------------
const BPM := 112.0
const STEPS_PER_BAR := 16
## Am - F - C - G, one bar each; notes are MIDI numbers (root, third, fifth).
const CHORDS := [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]
const BASS_STEPS := [0, 3, 6, 8, 11, 14]
const KICK_STEPS := [0, 8]
const SNARE_STEPS := [4, 12]
## A short lead phrase over the 4 bars (step -> MIDI note), resting elsewhere.
const LEAD := {0: 76, 6: 74, 8: 72, 12: 71, 16: 72, 22: 69, 24: 72, 28: 76,
		32: 79, 38: 76, 40: 72, 44: 74, 48: 74, 52: 71, 56: 67, 60: 71}

## Engine character per car for the rev on the car screen: [base Hz, grit 0..1, rev range multiplier].
const REV_PROFILES := {
	"sport": [55.0, 0.30, 2.2],
	"f1": [92.0, 0.15, 3.0],      # a screamer
	"gt": [36.0, 0.50, 2.0],      # a V8 growl
	"rally": [62.0, 0.65, 2.3],   # raspy
	"kart": [115.0, 0.75, 1.8],   # a buzzing two-stroke
}

enum Kind { TONE, IMPACT, EXPLOSION, BOOST, TYRE_POP, ROPE_SNAP, PART_CRACK, REV,
		ENGINE, TYRES, ROUGH, DRAG, SCRAPE, CREAK, CHARGE, MUSIC }
## SPEC 110: the drift charge's tone is rendered at this pitch; `pitch_scale` climbs with the charge.
const CHARGE_REF_HZ := 220.0

var music_enabled: bool = true
## SPEC 140: there is one tune. Kept as a field so the old API still reads sensibly.
var music_mode: String = "race"
var music_volume: float = 0.7
var sfx_volume: float = 0.9

var _silent: bool = false
var _live: bool = false           # players exist and may be playing
var _music_bus: int = -1
var _sfx_bus: int = -1
var _music_player: AudioStreamPlayer = null
var _engine_p: AudioStreamPlayer = null
var _tyre_p: AudioStreamPlayer = null
var _rough_p: AudioStreamPlayer = null
var _drag_p: AudioStreamPlayer = null
var _scrape_p: AudioStreamPlayer = null
var _creak_p: AudioStreamPlayer = null
var _charge_p: AudioStreamPlayer = null      # SPEC 110: the rising tone of the drift charge
var _pool: Array = []             # one-shot players
var _pool_next: int = 0
var _players: Array = []
## One-shot players currently sounding (pruned every frame).
var _shots: Array = []
var _rev_p: AudioStreamPlayer = null
var _rev_id: String = ""
var _pending_rev: String = ""

## Rendered sounds by id -> AudioStreamWAV; the render queue; what to write to the cache.
var _wav: Dictionary = {}
var _jobs: Array = []
var _done: Array = []
var _cache_key: String = ""
var _cache_saved: bool = false

# --- sfx targets (fed by the race) and their smoothed values ------------------------------------------
var _engine_active: bool = false
var _engine_rpm: float = 0.0      # 0..1 target
var _engine_thr: float = 0.0
var _tyres: float = 0.0
var _rough: float = 0.0
var _drag: float = 0.0
var _scrape: float = 0.0      # metal rims on the road (SPEC 46)
var _creak: float = 0.0       # the rope straining
var _charge: float = 0.0      # SPEC 110: the drift charge being built, 0..1 (0 = silent)
var _engine_spd: float = -1.0  # SPEC 110: the car's speed share, blended into the pitch (-1: rpm only)
var _s_rpm: float = 0.0
var _s_amp: float = 0.0
var _s_tyres: float = 0.0
var _s_rough: float = 0.0
var _s_drag: float = 0.0
var _s_scrape: float = 0.0
var _s_creak: float = 0.0
var _s_charge: float = 0.0
var _s_charge_amp: float = 0.0
var _s_speed: float = 0.0


## One sound being rendered: `pos` of `frames` frames are done, into `buf` (16-bit mono PCM).
class Job:
	var id: String
	var kind: int
	var frames: int = 0
	var pos: int = 0
	var rate: int = 22050
	var loop_len: int = 0        # > 0: a loop of this many frames (rendered `xfade` frames past it)
	var xfade: int = 0           # frames blended across the seam (the noise beds)
	var chunk: int = 1024
	var p: Array = []            # per-kind parameters
	var st: PackedFloat64Array   # per-kind synthesis state (phases, envelopes, filters)
	var seed: int = 1
	var buf: PackedByteArray

	func _init(id_: String, kind_: int, frames_: int) -> void:
		id = id_
		kind = kind_
		frames = frames_
		st = PackedFloat64Array()
		st.resize(16)
		seed = (id_.hash() | 1) & 0x7fffffff
		buf = PackedByteArray()
		buf.resize(frames_ * 2)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_silent = DisplayServer.get_name() == "headless"
	if _silent:
		return
	_music_bus = _ensure_bus("Music")
	_sfx_bus = _ensure_bus("Sfx")
	# The old synth clamped its mix at +-1 before the bus gain; a limiter on the bus does the same job
	# for stacked explosions and impacts without the crunch.
	if AudioServer.get_bus_effect_count(_sfx_bus) == 0 and ClassDB.class_exists("AudioEffectHardLimiter"):
		var lim: AudioEffect = ClassDB.instantiate("AudioEffectHardLimiter")
		lim.set("ceiling_db", -0.1)
		AudioServer.add_bus_effect(_sfx_bus, lim)
	_music_player = _make_player("Music", "Music")
	_music_player.volume_db = linear_to_db(1.0 / MUSIC_HEADROOM)
	_engine_p = _make_player("Engine", "Sfx")
	_tyre_p = _make_player("Tyres", "Sfx")
	_rough_p = _make_player("Rough", "Sfx")
	_drag_p = _make_player("Drag", "Sfx")
	_scrape_p = _make_player("Scrape", "Sfx")
	_creak_p = _make_player("Creak", "Sfx")
	_charge_p = _make_player("Charge", "Sfx")
	for i in POOL_SIZE:
		_pool.append(_make_player("Shot%d" % i, "Sfx"))
	_live = true
	# GameState (an earlier autoload) already loaded the settings; take the saved volumes from it.
	var gs := get_node_or_null("/root/GameState")
	if gs != null and gs.has_method("get_setting"):
		set_volumes(float(gs.get_setting("music_volume")), float(gs.get_setting("sfx_volume")))
	else:
		set_volumes(music_volume, sfx_volume)
	_apply_music_mute()
	var plan := _plan()
	_cache_key = _make_cache_key(plan)
	if _load_cache(plan):
		_cache_saved = true
	else:
		_wav.clear()
		_jobs = plan


func _ensure_bus(bus_name: String) -> int:
	var i := AudioServer.get_bus_index(bus_name)
	if i >= 0:
		return i
	i = AudioServer.bus_count
	AudioServer.add_bus(i)
	AudioServer.set_bus_name(i, bus_name)
	AudioServer.set_bus_send(i, "Master")
	return i


func _make_player(node_name: String, bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = node_name
	p.bus = bus
	add_child(p)
	_players.append(p)
	return p


func _process(delta: float) -> void:
	if _silent:
		if _live:
			_hush()
		return
	if not _jobs.is_empty():
		_render_slice()
	_update_beds(delta)
	if not _shots.is_empty():
		for i in range(_shots.size() - 1, -1, -1):
			if not (_shots[i] as AudioStreamPlayer).playing:
				_shots.remove_at(i)


## Silenced after start-up (a tool's `--noaudio`): stop everything, render nothing more.
func _hush() -> void:
	_live = false
	_jobs.clear()
	_shots.clear()
	for p in _players:
		(p as AudioStreamPlayer).stop()


# ---------------------------------------------------------------- public API

## 0..1 volumes from the settings screen (0 = silent).
func set_volumes(music: float, sfx: float) -> void:
	music_volume = clampf(music, 0.0, 1.0)
	sfx_volume = clampf(sfx, 0.0, 1.0)
	if _music_bus >= 0:
		AudioServer.set_bus_volume_db(_music_bus, MUSIC_DB + linear_to_db(maxf(music_volume, 0.0001)))
	if _sfx_bus >= 0:
		AudioServer.set_bus_volume_db(_sfx_bus, SFX_DB + linear_to_db(maxf(sfx_volume, 0.0001)))


func set_engine_active(active: bool) -> void:
	_engine_active = active
	if not active:
		_tyres = 0.0
		_rough = 0.0
		_drag = 0.0
		_scrape = 0.0
		_creak = 0.0
		_charge = 0.0


## `rpm_fraction` 0..1 of the engine's range, `throttle` 0..1. SPEC 110: `speed_fraction` (0..1 of the
## top speed) is blended into the pitch, so the note climbs with the speed you see and not only with
## the gearbox; -1 keeps the rpm alone.
func set_engine(rpm_fraction: float, throttle: float, speed_fraction: float = -1.0) -> void:
	_engine_rpm = clampf(rpm_fraction, 0.0, 1.0)
	_engine_thr = clampf(throttle, 0.0, 1.0)
	_engine_spd = clampf(speed_fraction, 0.0, 1.0) if speed_fraction >= 0.0 else -1.0


## SPEC 110: the drift charge, as a tone that climbs a fifth and a half as the meter fills. `active`
## while the car is drifting and not already boosting; otherwise silent.
func set_charge(level: float, active: bool) -> void:
	_charge = clampf(level, 0.0, 1.0) if active and level > 0.02 else 0.0


func set_tyres(amount: float) -> void:
	_tyres = clampf(amount, 0.0, 1.0)


func set_rough(amount: float) -> void:
	_rough = clampf(amount, 0.0, 1.0)


func set_drag(amount: float) -> void:
	_drag = clampf(amount, 0.0, 1.0)


## Metal rims on the road: `amount` 0..1 (burst tyres x speed).
func set_scrape(amount: float) -> void:
	_scrape = clampf(amount, 0.0, 1.0)


## The rope straining: `amount` 0..1 (rises toward the snap).
func set_creak(amount: float) -> void:
	_creak = clampf(amount, 0.0, 1.0)


## The rope breaks: a whip crack.
func rope_snap() -> void:
	_shoot("rope_snap", 0.0, randf_range(0.95, 1.05))


## A piece comes off a car: a short crack of plastic and metal.
func part_crack() -> void:
	_shoot("part_crack", 0.0, randf_range(0.92, 1.08))


func impact(strength: float) -> void:
	var st := clampf(strength, 0.0, 1.0)
	if st <= 0.01:
		return
	_shoot("impact", linear_to_db(st), randf_range(0.94, 1.06))


func explosion() -> void:
	_shoot("explosion", 0.0, randf_range(0.95, 1.05))


## Boost fired: a rising whoosh.
func boost() -> void:
	_shoot("boost", 0.0, 1.0)


## A tyre bursts: a sharp bang.
func tyre_pop() -> void:
	_shoot("tyre_pop", 0.0, randf_range(0.95, 1.05))


## The boost meter is full: a short two-tone chime.
func boost_ready() -> void:
	_shoot("boost_ready", 0.0, 1.0)


## Countdown beep: `high` for GO.
func beep(high: bool) -> void:
	_shoot("beep_hi" if high else "beep_lo", 0.0, 1.0)


## A short throttle blip -- "WRRRRR" -- in the character of car `car_id` (the car select screen).
func rev(car_id: String) -> void:
	if _silent:
		return
	var id := car_id if REV_PROFILES.has(car_id) else "sport"
	# Only one rev at a time: clicking through the cars cuts the previous one off.
	if _rev_p != null and _rev_p.playing and _rev_p.stream == _wav.get(_rev_id):
		_rev_p.stop()
	_rev_id = "rev_" + id
	_rev_p = _shoot(_rev_id, 0.0, 1.0)
	if _rev_p == null and _live:
		# Not rendered yet (the first seconds of a first launch): next in the queue, played when done.
		_pending_rev = id
		_promote(_rev_id)


## Switches the tune. The clock is left running, so it changes on the next step rather than restarting.
## SPEC 140: there is one tune, because there is one mode. Kept so callers do not have to care.
func set_music_mode(_mode: String) -> void:
	music_mode = "race"
	_apply_music_mode()


# ---------------------------------------------------------------- playing

## Fires a rendered one-shot through the pool; null while that sound is not rendered yet.
func _shoot(id: String, db: float, pitch: float) -> AudioStreamPlayer:
	if not _live:
		return null
	var wav: AudioStreamWAV = _wav.get(id)
	if wav == null:
		return null
	var p: AudioStreamPlayer = null
	for q in _pool:
		if not (q as AudioStreamPlayer).playing:
			p = q
			break
	if p == null:
		p = _pool[_pool_next]        # all busy: steal one in turn
		_pool_next = (_pool_next + 1) % _pool.size()
	p.stream = wav
	p.volume_db = db
	p.pitch_scale = pitch
	p.play()
	if not _shots.has(p):
		_shots.append(p)
	return p


## The continuous voices: the same 55 ms lag the old per-sample smoothing had, applied per frame, then a
## volume (and a pitch) on each looping player. Below the floor a bed is stopped, not left whispering.
func _update_beds(delta: float) -> void:
	if not _live:
		return
	var k := 1.0 - exp(-delta * 18.0)
	var amp_target := (0.10 + 0.14 * _engine_thr) if _engine_active else 0.0
	_s_rpm += (_engine_rpm - _s_rpm) * k
	_s_amp += (amp_target - _s_amp) * k
	_s_tyres += (_tyres - _s_tyres) * k
	_s_rough += (_rough - _s_rough) * k
	_s_drag += (_drag - _s_drag) * k
	_s_scrape += (_scrape - _s_scrape) * k
	_s_creak += (_creak - _s_creak) * k
	if _engine_spd >= 0.0:
		_s_speed += (_engine_spd - _s_speed) * k
	_s_charge += (_charge - _s_charge) * k
	_s_charge_amp += ((0.13 if _charge > 0.0 else 0.0) - _s_charge_amp) * k
	# Engine: two detuned saws an octave apart, pitch from the rpm (38..208 Hz) -- SPEC 110: blended
	# with the speed, so the note you hear is the speed you see.
	var pitch_mix := _s_rpm if _engine_spd < 0.0 else (0.55 * _s_rpm + 0.45 * _s_speed)
	_drive(_engine_p, _s_amp, 0.0005, (38.0 + 170.0 * pitch_mix) / ENGINE_REF_HZ)
	# SPEC 110: the drift charge, climbing.
	_drive(_charge_p, _s_charge_amp, 0.001, 0.7 + 1.3 * _s_charge)
	_drive(_tyre_p, _s_tyres, 0.001, 1.0)
	_drive(_rough_p, _s_rough, 0.001, 1.0)
	_drive(_drag_p, _s_drag, 0.001, 1.0)
	_drive(_scrape_p, _s_scrape, 0.001, 1.0)
	# The rope: a low groan whose pitch rises with the strain (38..98 Hz).
	_drive(_creak_p, _s_creak, 0.001, (CREAK_REF_HZ + 60.0 * _s_creak) / CREAK_REF_HZ)


func _drive(p: AudioStreamPlayer, amp: float, floor_amp: float, pitch: float) -> void:
	if p == null or p.stream == null:
		return
	if amp <= floor_amp:
		if p.playing:
			p.stop()
		return
	p.volume_db = linear_to_db(amp)
	p.pitch_scale = pitch
	if not p.playing:
		p.play()


## SPEC 138: the delivery radio takes the Music bus over. This stops the BACKGROUND TUNE only -- the
## bus is left alone, so the player's Music volume still applies to the radio, which is what the brief
## asks for. Muting the bus instead would have silenced the radio along with the soundtrack.
func set_background_music(on: bool) -> void:
	if _music_player == null:
		return
	if on:
		_apply_music_mode()
	elif _music_player.playing:
		_music_player.stop()


func _apply_music_mute() -> void:
	if _music_bus >= 0:
		AudioServer.set_bus_mute(_music_bus, not music_enabled)


## Puts the wanted tune on the music player. Both loops are 64 steps, so the same fraction of the loop
## is the same step: the other tune takes over where this one was, not from the top.
func _apply_music_mode() -> void:
	if _music_player == null or not _live:
		return
	var wav: AudioStreamWAV = _wav.get("music_race")
	if wav == null or _music_player.stream == wav:
		return
	var pos := 0.0
	var cur := _music_player.stream as AudioStreamWAV
	if _music_player.playing and cur != null and cur.get_length() > 0.0:
		pos = fmod(_music_player.get_playback_position() / cur.get_length(), 1.0) * wav.get_length()
	_music_player.stream = wav
	_music_player.play(pos)


## A rendered (or cached) sound arrives: keep it, and hand it to whoever plays it.
func _install(id: String, wav: AudioStreamWAV) -> void:
	_wav[id] = wav
	match id:
		"engine": _engine_p.stream = wav
		"tyres": _tyre_p.stream = wav
		"rough": _rough_p.stream = wav
		"drag": _drag_p.stream = wav
		"scrape": _scrape_p.stream = wav
		"creak": _creak_p.stream = wav
		"charge": _charge_p.stream = wav
		"music_race": _apply_music_mode()
		_:
			if _pending_rev != "" and id == "rev_" + _pending_rev:
				var car := _pending_rev
				_pending_rev = ""
				rev(car)


func _promote(id: String) -> void:
	for i in range(1, _jobs.size()):
		if (_jobs[i] as Job).id == id:
			var j: Job = _jobs[i]
			_jobs.remove_at(i)
			_jobs.insert(0, j)
			return


# ---------------------------------------------------------------- the render plan and its cache

## Every sound, in the order it is needed: menu beeps, the menu's tune, then the race's voices, the arena's
## tune and the car screen's revs last.
func _plan() -> Array:
	var jobs: Array = []
	jobs.append(_tone_job("beep_lo", 660.0, 660.0, 0.0, 0.16, 0.22))
	jobs.append(_tone_job("beep_hi", 1320.0, 1320.0, 0.0, 0.42, 0.22))
	jobs.append(_music_job("music_race", "race"))
	jobs.append(_shot_job("impact", Kind.IMPACT, 0.5))
	jobs.append(_loop_job("engine", Kind.ENGINE, 50000, 0))     # 200 cycles of the saw, 101 of its octave
	jobs.append(_tone_job("boost_ready", 880.0, 1320.0, 0.09, 0.22, 0.12))
	jobs.append(_loop_job("tyres", Kind.TYRES, 22050, 1024))
	jobs.append(_loop_job("rough", Kind.ROUGH, 44100, 2048))
	jobs.append(_loop_job("drag", Kind.DRAG, 22050, 1024))
	jobs.append(_shot_job("explosion", Kind.EXPLOSION, 1.6))
	jobs.append(_shot_job("boost", Kind.BOOST, 1.6))
	jobs.append(_shot_job("tyre_pop", Kind.TYRE_POP, 0.6))
	jobs.append(_shot_job("rope_snap", Kind.ROPE_SNAP, 0.4))
	jobs.append(_shot_job("part_crack", Kind.PART_CRACK, 0.35))
	jobs.append(_loop_job("scrape", Kind.SCRAPE, 22050, 1024))
	jobs.append(_loop_job("creak", Kind.CREAK, 44100, 1024))
	jobs.append(_loop_job("charge", Kind.CHARGE, 22050, 1024))      # SPEC 110: 220 whole cycles
	for car_id in REV_PROFILES:
		var prof: Array = REV_PROFILES[car_id]
		var j := _shot_job("rev_" + String(car_id), Kind.REV, 1.15)
		j.p = [float(prof[0]), float(prof[1]), float(prof[2])]
		jobs.append(j)
	return jobs


func _shot_job(id: String, kind: int, seconds: float) -> Job:
	return Job.new(id, kind, int(round(seconds * MIX_RATE)))


func _tone_job(id: String, hz1: float, hz2: float, t_switch: float, t_end: float, amp: float) -> Job:
	var j := Job.new(id, Kind.TONE, int(ceil(t_end * MIX_RATE)))
	j.p = [hz1, hz2, t_switch, t_end, amp]
	return j


func _loop_job(id: String, kind: int, loop_len: int, xfade: int) -> Job:
	var j := Job.new(id, kind, loop_len + xfade)
	j.loop_len = loop_len
	j.xfade = xfade
	return j


## The whole tune as one loop (64 steps, 8.6 s), sequenced from per-step tables.
func _music_job(id: String, _mode: String) -> Job:
	var chords: Array = CHORDS
	var bass_steps: Array = BASS_STEPS
	var kick_steps: Array = KICK_STEPS
	var snare_steps: Array = SNARE_STEPS
	var lead: Dictionary = LEAD
	var steps := STEPS_PER_BAR * chords.size()
	var frames_per_step := 60.0 / BPM / 4.0 * float(MIX_RATE)
	var j := Job.new(id, Kind.MUSIC, int(round(frames_per_step * float(steps))))
	j.loop_len = j.frames
	j.chunk = 512
	var tb := PackedFloat64Array()
	var ta := PackedFloat64Array()
	var tl := PackedFloat64Array()
	var tk := PackedByteArray()
	var ts := PackedByteArray()
	var th := PackedByteArray()
	tb.resize(steps)
	ta.resize(steps)
	tl.resize(steps)
	tk.resize(steps)
	ts.resize(steps)
	th.resize(steps)
	for step in steps:
		var bar := (step / STEPS_PER_BAR) % chords.size()
		var s := step % STEPS_PER_BAR
		var chord: Array = chords[bar]
		tb[step] = _midi(float(chord[0]) - 12.0) if bass_steps.has(s) else 0.0
		ta[step] = _midi(float(chord[s % 3]) + (12.0 if (s / 3) % 2 == 1 else 0.0))
		tl[step] = _midi(float(lead[step])) if lead.has(step) else 0.0
		tk[step] = 1 if kick_steps.has(s) else 0
		ts[step] = 1 if snare_steps.has(s) else 0
		th[step] = 1 if s % 2 == 1 else 0
	j.p = [frames_per_step, tb, ta, tl, tk, ts, th]
	j.st[0] = -1.0       # step
	j.st[1] = 110.0      # bass Hz
	j.st[3] = 440.0      # arp Hz
	j.st[5] = 440.0      # lead Hz
	j.st[7] = 10.0       # kick time (idle)
	return j


func _make_cache_key(plan: Array) -> String:
	var src := 0
	var scr := get_script() as GDScript
	if scr != null:
		src = scr.source_code.hash()
	var shape := ""
	for j in plan:
		shape += "%s:%d:%d;" % [(j as Job).id, (j as Job).frames, (j as Job).loop_len]
	return "%s|%d|%d|%d|%d" % [str(ProjectSettings.get_setting("application/config/version", "?")),
			CACHE_VERSION, MIX_RATE, src, shape.hash()]


## A cache is the whole plan, rendered earlier by this same script (same key): load it and skip the render.
func _load_cache(plan: Array) -> bool:
	if not FileAccess.file_exists(CACHE_PATH):
		return false
	var f := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if f == null:
		return false
	if f.get_buffer(4).get_string_from_ascii() != "RRAU" or f.get_pascal_string() != _cache_key:
		return false
	var n := int(f.get_32())
	if n != plan.size():
		return false
	var got := {}
	for i in n:
		var id := f.get_pascal_string()
		var rate := int(f.get_32())
		var loop_len := int(f.get_32())
		var nbytes := int(f.get_32())
		var data := f.get_buffer(nbytes)
		if nbytes <= 0 or data.size() != nbytes:
			return false
		got[id] = [rate, loop_len, data]
	for j in plan:
		if not got.has((j as Job).id):
			return false
	for j in plan:
		var e: Array = got[(j as Job).id]
		_install((j as Job).id, _wav_from(e[2], int(e[0]), int(e[1])))
	return true


func _save_cache() -> void:
	if _cache_saved:
		return
	_cache_saved = true
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer("RRAU".to_ascii_buffer())
	f.store_pascal_string(_cache_key)
	f.store_32(_done.size())
	for e in _done:
		f.store_pascal_string(String(e[0]))
		f.store_32(int(e[1]))
		f.store_32(int(e[2]))
		f.store_32((e[3] as PackedByteArray).size())
		f.store_buffer(e[3])
	f.close()
	_done.clear()


func _wav_from(data: PackedByteArray, rate: int, loop_len: int) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	if loop_len > 0:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = loop_len
	return w


# ---------------------------------------------------------------- rendering (spread over frames)

## Renders for at most RENDER_BUDGET_USEC (half that during a race), a chunk at a time, front job first.
func _render_slice() -> void:
	var t0 := Time.get_ticks_usec()
	var budget := RENDER_BUDGET_USEC / 2 if _engine_active else RENDER_BUDGET_USEC
	while not _jobs.is_empty():
		var j: Job = _jobs[0]
		_render_chunk(j, mini(j.frames - j.pos, j.chunk))
		if j.pos >= j.frames:
			_jobs.pop_front()
			_finish_job(j)
		if Time.get_ticks_usec() - t0 >= budget:
			break
	if _jobs.is_empty():
		_save_cache()


## A noise bed loops through a short crossfade of its tail into its head; then the stream is built.
func _finish_job(j: Job) -> void:
	var data := j.buf
	if j.loop_len > 0 and j.xfade > 0:
		var x := j.xfade
		var l := j.loop_len
		for i in x:
			var w := float(i) / float(x)
			var head := float(data.decode_s16(i * 2))
			var tail := float(data.decode_s16((l + i) * 2))
			data.encode_s16(i * 2, int(head * w + tail * (1.0 - w)))
		data.resize(l * 2)
	_done.append([j.id, j.rate, j.loop_len, data])
	_install(j.id, _wav_from(data, j.rate, j.loop_len))


func _render_chunk(j: Job, n: int) -> void:
	if n <= 0:
		return
	match j.kind:
		Kind.TONE: _r_tone(j, n)
		Kind.IMPACT: _r_impact(j, n)
		Kind.EXPLOSION: _r_explosion(j, n)
		Kind.BOOST: _r_boost(j, n)
		Kind.TYRE_POP: _r_tyre_pop(j, n)
		Kind.ROPE_SNAP: _r_rope_snap(j, n)
		Kind.PART_CRACK: _r_part_crack(j, n)
		Kind.REV: _r_rev(j, n)
		Kind.ENGINE: _r_engine(j, n)
		Kind.TYRES: _r_tyres(j, n)
		Kind.ROUGH: _r_rough(j, n)
		Kind.DRAG: _r_drag(j, n)
		Kind.SCRAPE: _r_scrape(j, n)
		Kind.CREAK: _r_creak(j, n)
		Kind.CHARGE: _r_charge(j, n)
		Kind.MUSIC: _r_music(j, n)
	j.pos += n


static func _midi(n: float) -> float:
	return 440.0 * pow(2.0, (n - 69.0) / 12.0)


## Beeps and the boost chime: a sine at `hz1` until `t_switch`, then `hz2`, cut at `t_end`.
func _r_tone(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var hz1: float = j.p[0]
	var hz2: float = j.p[1]
	var t_switch: float = j.p[2]
	var t_end: float = j.p[3]
	var amp: float = j.p[4]
	for i in range(j.pos, j.pos + n):
		var t := float(i) * dt
		var v := 0.0
		if t < t_end:
			v = sin(t * TAU * (hz1 if t < t_switch else hz2)) * amp
		buf.encode_s16(i * 2, int(v * 32767.0))
	j.buf = buf


## Impact: a 60 Hz thud under a burst of noise; the hit's strength is the player's volume.
func _r_impact(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var s := j.seed
	for i in range(j.pos, j.pos + n):
		var t := float(i) * dt
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var nz := float(s) / 1073741823.5 - 1.0
		var v := (nz * 0.5 + sin(t * TAU * 60.0) * 0.6) * exp(-t * 14.0) * 0.5
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	j.seed = s
	j.buf = buf


## Explosion: a low boom of filtered noise with a bright crack on top, dying over a second and a half.
func _r_explosion(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var s := j.seed
	var lp := j.st[0]
	for i in range(j.pos, j.pos + n):
		var t := float(i) * dt
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var nz := float(s) / 1073741823.5 - 1.0
		lp += (nz - lp) * 0.06
		var v := (lp * 2.2 + nz * 0.3 * exp(-t * 8.0)) * exp(-t * 2.2) * 0.8
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	j.seed = s
	j.st[0] = lp
	j.buf = buf


## Boost: filtered noise swelling in, and a tone sweeping up.
func _r_boost(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var s := j.seed
	var lp := j.st[0]
	var ph := j.st[1]
	for i in range(j.pos, j.pos + n):
		var t := float(i) * dt
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var nz := float(s) / 1073741823.5 - 1.0
		lp += (nz - lp) * 0.12
		var wenv := minf(t / 0.06, 1.0) * exp(-t * 2.6)
		ph = fmod(ph + (180.0 + 420.0 * minf(t / 0.5, 1.0)) * dt, 1.0)
		var v := (lp * 1.4 + sin(ph * TAU) * 0.10) * wenv
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	j.seed = s
	j.st[0] = lp
	j.st[1] = ph
	j.buf = buf


## Tyre burst: a crack of noise with a low thump under it.
func _r_tyre_pop(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var s := j.seed
	for i in range(j.pos, j.pos + n):
		var t := float(i) * dt
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var nz := float(s) / 1073741823.5 - 1.0
		var v := (nz * 0.9 * exp(-t * 30.0) + sin(t * TAU * 70.0) * 0.5 * exp(-t * 12.0)) * 0.9
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	j.seed = s
	j.buf = buf


## Rope snap: a sharp whip crack -- a noise spike and a falling chirp.
func _r_rope_snap(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var s := j.seed
	for i in range(j.pos, j.pos + n):
		var t := float(i) * dt
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var nz := float(s) / 1073741823.5 - 1.0
		var v := nz * exp(-t * 45.0) * 1.1 + sin(t * TAU * 1800.0 * exp(-t * 8.0)) * 0.25 * exp(-t * 20.0)
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	j.seed = s
	j.buf = buf


## A part comes off: a short, bright crack.
func _r_part_crack(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var s := j.seed
	for i in range(j.pos, j.pos + n):
		var t := float(i) * dt
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var nz := float(s) / 1073741823.5 - 1.0
		var v := nz * 0.7 * exp(-t * 38.0) + sin(t * TAU * 420.0) * 0.2 * exp(-t * 25.0)
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	j.seed = s
	j.buf = buf


## The car screen's rev: revs up fast, holds, falls back; saw-to-square by the car's grit.
func _r_rev(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var base: float = j.p[0]
	var grit: float = j.p[1]
	var rise: float = j.p[2]
	var s := j.seed
	var ph := j.st[0]
	for i in range(j.pos, j.pos + n):
		var t := float(i) * dt
		var r := 0.0
		if t < 0.32:
			r = t / 0.32
		elif t < 0.5:
			r = 1.0
		else:
			r = maxf(0.15, 1.0 - (t - 0.5) / 0.6)
		ph = fmod(ph + base * (1.0 + (rise - 1.0) * r) * dt, 1.0)
		var wave := (ph * 2.0 - 1.0) * (1.0 - grit) + (1.0 if ph < 0.5 else -1.0) * grit * 0.7
		var env := minf(t / 0.03, 1.0) * clampf((1.15 - t) / 0.15, 0.0, 1.0)
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var nz := float(s) / 1073741823.5 - 1.0
		var v := (wave * (0.18 + 0.14 * r) + nz * grit * 0.05 * r) * env
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	j.seed = s
	j.st[0] = ph
	j.buf = buf


## Engine: two detuned saws an octave apart at ENGINE_REF_HZ; a whole number of cycles of both.
func _r_engine(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var f1 := ENGINE_REF_HZ
	var f2 := ENGINE_REF_HZ * 0.5 * 1.01
	var p1 := j.st[0]
	var p2 := j.st[1]
	for i in range(j.pos, j.pos + n):
		p1 = fmod(p1 + f1 * dt, 1.0)
		p2 = fmod(p2 + f2 * dt, 1.0)
		var v := (p1 * 2.0 - 1.0) * 0.6 + (p2 * 2.0 - 1.0) * 0.4
		buf.encode_s16(i * 2, int(v * 32767.0))
	j.st[0] = p1
	j.st[1] = p2
	j.buf = buf


## Tyres: band-ish noise plus a 980 Hz squeal wobbled at 90 Hz (the old one wobbled at engine rate).
func _r_tyres(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var s := j.seed
	var lp := j.st[0]
	var ph := j.st[1]
	for i in range(j.pos, j.pos + n):
		var t := float(i) * dt
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var nz := float(s) / 1073741823.5 - 1.0
		lp += (nz - lp) * 0.35
		ph = fmod(ph + (980.0 + 60.0 * sin(TAU * 90.0 * t)) * dt, 1.0)
		var v := (nz - lp) * 0.25 + sin(ph * TAU) * 0.10
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	j.seed = s
	j.st[0] = lp
	j.st[1] = ph
	j.buf = buf


## Rough ground: a low rumble of heavily low-passed noise.
func _r_rough(j: Job, n: int) -> void:
	var buf := j.buf
	var s := j.seed
	var lp := j.st[0]
	for i in range(j.pos, j.pos + n):
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var nz := float(s) / 1073741823.5 - 1.0
		lp += (nz - lp) * 0.02
		buf.encode_s16(i * 2, int(clampf(lp * 1.6, -1.0, 1.0) * 32767.0))
	j.seed = s
	j.st[0] = lp
	j.buf = buf


## Over-pull: a harsh 72 Hz buzz with noise -- the wheels are being dragged.
func _r_drag(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var s := j.seed
	var ph := j.st[0]
	for i in range(j.pos, j.pos + n):
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var nz := float(s) / 1073741823.5 - 1.0
		ph = fmod(ph + 72.0 * dt, 1.0)
		var v := (1.0 if ph < 0.5 else -1.0) * 0.12 + nz * 0.10
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	j.seed = s
	j.st[0] = ph
	j.buf = buf


## Rims: a hissing grind of metal on tarmac, rough and bright, with a faint whine in it.
func _r_scrape(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var s := j.seed
	var lp := j.st[0]
	for i in range(j.pos, j.pos + n):
		var t := float(i) * dt
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var nz := float(s) / 1073741823.5 - 1.0
		lp += (nz - lp) * 0.55
		var v := (nz - lp) * 0.35 + sin(t * TAU * 620.0) * 0.04
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	j.seed = s
	j.st[0] = lp
	j.buf = buf


## The rope: a low creaking groan -- a saw at CREAK_REF_HZ, stuttered at a quarter of its pitch with a
## jittered pulse; the player's pitch_scale raises both with the strain.
## SPEC 110: the drift charge's tone -- a warm three-harmonic note at CHARGE_REF_HZ; the pitch climbs
## with the meter through `pitch_scale`.
func _r_charge(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	for i in range(j.pos, j.pos + n):
		var t := float(i) * dt
		var v := 0.16 * sin(TAU * CHARGE_REF_HZ * t) + 0.06 * sin(TAU * CHARGE_REF_HZ * 2.0 * t) \
				+ 0.03 * sin(TAU * CHARGE_REF_HZ * 3.0 * t)
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	j.buf = buf


func _r_creak(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var s := j.seed
	var ph := j.st[0]
	for i in range(j.pos, j.pos + n):
		var t := float(i) * dt
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var nz := float(s) / 1073741823.5 - 1.0
		ph = fmod(ph + CREAK_REF_HZ * dt, 1.0)
		var pulse := 0.5 + 0.5 * sin(TAU * CREAK_REF_HZ * 0.25 * t + nz * 0.3)
		var v := (ph * 2.0 - 1.0) * 0.10 * pulse + nz * 0.03
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	j.seed = s
	j.st[0] = ph
	j.buf = buf


## The tune: square bass, 25 % pulse arpeggio, triangle lead, a falling-sine kick, noise snare and hat --
## the same voices and envelopes the live synth had, driven by the per-step tables of `_music_job`.
func _r_music(j: Job, n: int) -> void:
	var buf := j.buf
	var dt := 1.0 / float(j.rate)
	var frames_per_step: float = j.p[0]
	var tb: PackedFloat64Array = j.p[1]
	var ta: PackedFloat64Array = j.p[2]
	var tl: PackedFloat64Array = j.p[3]
	var tk: PackedByteArray = j.p[4]
	var ts: PackedByteArray = j.p[5]
	var th: PackedByteArray = j.p[6]
	var steps := tb.size()
	var st := j.st
	var step := int(st[0])
	var bass_freq := st[1]
	var bass_env := st[2]
	var arp_freq := st[3]
	var arp_env := st[4]
	var lead_freq := st[5]
	var lead_env := st[6]
	var kick_t := st[7]
	var snare_env := st[8]
	var hat_env := st[9]
	var ph_bass := st[10]
	var ph_arp := st[11]
	var ph_lead := st[12]
	var ph_kick := st[13]
	var s := j.seed
	for i in range(j.pos, j.pos + n):
		var stp := int(float(i) / frames_per_step) % steps
		if stp != step:
			step = stp
			if tb[stp] > 0.0:
				bass_freq = tb[stp]
				bass_env = 1.0
			arp_freq = ta[stp]
			arp_env = 1.0
			if tl[stp] > 0.0:
				lead_freq = tl[stp]
				lead_env = 1.0
			if tk[stp] == 1:
				kick_t = 0.0
				ph_kick = 0.0
			if ts[stp] == 1:
				snare_env = 1.0
			if th[stp] == 1:
				hat_env = 1.0
		# bass: square, decaying
		ph_bass = fmod(ph_bass + bass_freq * dt, 1.0)
		var bass := (1.0 if ph_bass < 0.5 else -1.0) * bass_env * 0.22
		bass_env *= 0.99985
		# arpeggio: 25 % pulse, short
		ph_arp = fmod(ph_arp + arp_freq * dt, 1.0)
		var arp := (1.0 if ph_arp < 0.25 else -0.35) * arp_env * 0.07
		arp_env *= 0.9992
		# lead: triangle
		ph_lead = fmod(ph_lead + lead_freq * dt, 1.0)
		var lead := (absf(ph_lead * 4.0 - 2.0) - 1.0) * lead_env * 0.16
		lead_env *= 0.99975
		# kick: falling sine
		var kick := 0.0
		if kick_t < 0.18:
			kick_t += dt
			ph_kick += (45.0 + 110.0 * exp(-kick_t * 30.0)) * dt
			kick = sin(ph_kick * TAU) * exp(-kick_t * 18.0) * 0.45
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var nz := float(s) / 1073741823.5 - 1.0
		var snare := nz * snare_env * 0.16
		snare_env *= 0.9991
		var hat := nz * hat_env * 0.05
		hat_env *= 0.996
		var v := (bass + arp + lead + kick + snare + hat) * MUSIC_HEADROOM
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	st[0] = float(step)
	st[1] = bass_freq
	st[2] = bass_env
	st[3] = arp_freq
	st[4] = arp_env
	st[5] = lead_freq
	st[6] = lead_env
	st[7] = kick_t
	st[8] = snare_env
	st[9] = hat_env
	st[10] = ph_bass
	st[11] = ph_arp
	st[12] = ph_lead
	st[13] = ph_kick
	j.st = st
	j.seed = s
	j.buf = buf
