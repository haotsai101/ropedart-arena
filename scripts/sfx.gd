extends Node
## Procedural SFX synthesis + playback pool (Task #34 -- see docs/project.md's
## Audio section, "Every rope action has a satisfying sound" / "Heavy impacts
## have stronger feedback"). Confirmed before this task: there are ZERO audio
## assets anywhere in this project and no tool available to fetch/download
## real recorded audio -- every sound below is therefore synthesized in code,
## not sampled from any external file.
##
## Deliberately pre-rendered ONCE per distinct sound at _ready() (a small
## fixed library of AudioStreamWAV clips built from hand-written waveform
## math -- sine sweeps + one-pole-filtered white noise, hand-enveloped), not
## a live AudioStreamGenerator fed every _process tick. A generator needs a
## continuously-refilled ring buffer for the whole time it's playing, which
## is real complexity this project has no precedent for and doesn't need for
## short (<0.4s) one-shot combat cues -- rendering each clip's samples once
## into an AudioStreamWAV and replaying it through a pooled AudioStreamPlayer
## with per-call pitch_scale/volume_db variation is simpler, cheaper per call,
## and just as "genuinely synthesized in code" (nothing here is ever loaded
## from disk). Per-call pitch/volume variation stands in for "charge level"/
## "severity" scaling (see play_throw/play_swing/play_recall's own ratio
## params, and play_kill()'s flat louder/lower mix vs. play_trip()'s flat
## quiet one) -- the same shape rope_dart.gd's own charge_ratio -> speed lerp
## already uses elsewhere in this codebase.
##
## Pool sizing / voice stealing: POOL_SIZE AudioStreamPlayers are round-robined
## across every call site in the whole game -- fine for this game's small
## player counts (2-8) and short clip lengths; a sound that's still playing
## when its player slot comes back around just gets cut off and restarted, an
## acceptable trade for zero per-call node allocation (matches this project's
## established "avoid per-frame/per-call allocation" discipline -- see
## rope_dart.gd's own header comment on the rope-chain MultiMesh for the same
## principle applied to VFX).
##
## Registered as an autoload (see project.godot's [autoload] section) so every
## script in the game can call Sfx.play_*() directly, the same access pattern
## GameManager already established for this project's other singletons.

const SAMPLE_RATE: int = 44100
const POOL_SIZE: int = 12

var _pool: Array[AudioStreamPlayer] = []
var _pool_i: int = 0
var _clips: Dictionary = {}


func _ready() -> void:
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_pool.append(p)
	_build_clips()


func _build_clips() -> void:
	# Throw vs. Swing/Redirect deliberately use different sweep directions/
	# durations/noise brightness (see _build_whoosh()'s own header comment) so
	# the two read as related (both "dart in motion" whooshes) but distinct --
	# per this task's own spec ("a whoosh distinct from the initial throw").
	_clips["throw"] = _build_whoosh(0.18, 900.0, 320.0, 0.55)
	_clips["swing"] = _build_whoosh(0.24, 500.0, 1300.0, 0.4)
	_clips["impact"] = _build_impact()
	_clips["recall"] = _build_recall_whip()
	_clips["kick"] = _build_kick()
	_clips["slash"] = _build_slash()
	_clips["dash"] = _build_dash()
	_clips["kill"] = _build_kill()
	_clips["trip"] = _build_trip()


func _next_player() -> AudioStreamPlayer:
	var p: AudioStreamPlayer = _pool[_pool_i]
	_pool_i = (_pool_i + 1) % _pool.size()
	return p


func _play(clip_key: String, volume_db: float = 0.0, pitch_scale: float = 1.0) -> void:
	var stream: AudioStreamWAV = _clips.get(clip_key)
	if stream == null:
		return
	var p: AudioStreamPlayer = _next_player()
	p.stream = stream
	p.volume_db = volume_db
	p.pitch_scale = maxf(pitch_scale, 0.05)
	p.play()


## --- Public API -------------------------------------------------------
## Every play_* call below is fire-and-forget -- callers never hold a
## reference back to the AudioStreamPlayer that ends up playing it, matching
## this project's existing "one-shot procedural VFX" call shape (see
## player.gd's _flash_materials()/_play_lunge_tween(), which are likewise
## fire-and-forget from their own call sites).

## Throw (rope_dart.gd's release_throw()): charge_ratio (0-1, the SAME
## charge_ratio release_throw() already computes for its own speed lerp)
## scales pitch/volume -- a fuller charge reads as a sharper, louder whoosh.
func play_throw(charge_ratio: float = 0.0) -> void:
	var c: float = clampf(charge_ratio, 0.0, 1.0)
	_play("throw", lerp(-8.0, -2.0, c), lerp(0.9, 1.3, c) * _jitter())


## Redirect/Swing (rope_dart.gd's begin_swing_redirect()): charge_ratio is the
## same hold-duration-derived speed-scaling ratio that function already
## computes for _flight_speed -- see that function's own header comment.
func play_swing(charge_ratio: float = 0.0) -> void:
	var c: float = clampf(charge_ratio, 0.0, 1.0)
	_play("swing", lerp(-7.0, -2.0, c), lerp(0.9, 1.2, c) * _jitter())


## Impact/Anchor (rope_dart.gd's _embed_in_place()) -- the dart embeds into a
## surface. Small per-call pitch jitter only (no severity axis available at
## this call site) so repeated embeds don't sound like the exact same sample
## looping.
func play_impact() -> void:
	_play("impact", -3.0, _jitter())


## Recall (rope_dart.gd's begin_recall()/_process_returning()) -- played once
## immediately on begin_recall() and then periodically while RETURNING (see
## _process_returning()'s own _recall_sfx_timer). ramp_ratio (0-1) tracks how
## far into the speed ramp this call is (GDD: "Recall speed increases over
## time") and raises both pitch and volume, plus the CALLER shortens its own
## repeat interval as ramp_ratio grows -- so the whip-crack cadence itself
## visibly (audibly) accelerates alongside the dart's real increasing pull
## speed, not just each individual crack's pitch.
func play_recall(ramp_ratio: float = 0.0) -> void:
	var r: float = clampf(ramp_ratio, 0.0, 1.0)
	_play("recall", lerp(-10.0, -4.0, r), lerp(0.85, 1.25, r) * _jitter())


## Kick (player.gd's _perform_kick()/_trigger_kick_vfx()) -- unarmed melee,
## knockback only, never lethal. A clean punchy thump.
func play_kick() -> void:
	_play("kick", -3.0, _jitter())


## Slash (player.gd's _perform_slash()/_trigger_slash_vfx()) -- melee with the
## dart itself, always lethal on contact. A brighter, sharper blade-whoosh
## than Kick's own thump.
func play_slash() -> void:
	_play("slash", -2.0, _jitter())


## Dash (player.gd's dash-activation block in _physics_process()) -- a quick
## directional burst.
func play_dash() -> void:
	_play("dash", -6.0, _jitter())


## Lethal hit / kill confirmation (player.gd's take_dart_hit()) -- fires
## whenever a dart-contact hit actually lands (every take_dart_hit() call is
## a real lethal hit per the GDD's Combat "Dart Contact" section -- it always
## costs the target a life, whether or not it results in full elimination
## this time), distinct from and noticeably stronger/lower/louder than
## play_trip() below (GDD Audio: "heavy impacts have stronger feedback").
func play_kill() -> void:
	_play("kill", 0.0, _jitter(0.06))


## Rope trip (player.gd's apply_rope_trip()) -- rope-LINE contact, never
## lethal, just a brief movement debuff. Small and quiet on purpose --
## deliberately the weakest cue in this whole library so it reads as
## unmistakably minor next to play_kill()'s much heavier hit.
func play_trip() -> void:
	_play("trip", -14.0, _jitter())


func _jitter(amount: float = 0.04) -> float:
	return 1.0 + randf_range(-amount, amount)


## --- Synthesis -----------------------------------------------------------
## Every _build_*() function below returns a small in-memory AudioStreamWAV,
## rendered once at _ready() time from hand-written sample math -- no file
## I/O, no external asset. All are mono 16-bit PCM at SAMPLE_RATE.

static func _samples_to_wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		var s: float = clampf(samples[i], -1.0, 1.0)
		bytes.encode_s16(i * 2, int(round(s * 32767.0)))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = bytes
	return wav


## One-pole lowpass-filtered white noise -- softens harsh full-spectrum noise
## into a breathier "whoosh"/"thud"/"shhk" texture depending on `alpha`
## (closer to 1.0 keeps more high-frequency content/brighter; closer to 0.0
## is darker/duller). Standard single-coefficient IIR smoothing, the cheapest
## noise-coloring technique that still reads as "air" rather than harsh
## static.
static func _noise_sample(prev: float, alpha: float, rng: RandomNumberGenerator) -> float:
	return alpha * rng.randf_range(-1.0, 1.0) + (1.0 - alpha) * prev


## Generic envelope: linear attack over `attack_time`, then exponential decay
## (rate `decay_rate`) for the remainder of the clip. Shared shape across
## every _build_*() function below, just with different attack/decay/duration
## constants per sound.
static func _env(t: float, attack_time: float, decay_rate: float) -> float:
	if t < attack_time:
		return t / maxf(attack_time, 0.0001)
	return exp(-decay_rate * (t - attack_time))


## Throw/Swing whoosh: a filtered-noise "air" layer plus a tonal sine sweep
## from freq_start -> freq_end, both under one shared envelope. Reused for
## both Throw and Swing (see _build_clips()) with different
## duration/sweep-direction/noise-brightness so the two read as related (both
## "dart in motion") but distinct.
static func _build_whoosh(duration: float, freq_start: float, freq_end: float, noise_alpha: float) -> AudioStreamWAV:
	var n: int = int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var noise_prev := 0.0
	var phase := 0.0
	for i in n:
		var t: float = float(i) / SAMPLE_RATE
		var progress: float = t / duration
		var freq: float = lerp(freq_start, freq_end, progress)
		phase += freq / SAMPLE_RATE * TAU
		var tone: float = sin(phase)
		noise_prev = _noise_sample(noise_prev, noise_alpha, rng)
		var env: float = _env(t, 0.01, 9.0)
		samples[i] = (tone * 0.4 + noise_prev * 0.6) * env
	return _samples_to_wav(samples)


## Impact/Anchor thud: a low sine sweep (150 -> 55 Hz, "the dart striking
## something solid") plus a touch of dark filtered noise for a bit of
## texture, sharp attack, fast decay so it reads as a single solid strike, not
## a ringing tone.
static func _build_impact() -> AudioStreamWAV:
	var duration := 0.14
	var n: int = int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2
	var noise_prev := 0.0
	var phase := 0.0
	for i in n:
		var t: float = float(i) / SAMPLE_RATE
		var freq: float = lerp(150.0, 55.0, t / duration)
		phase += freq / SAMPLE_RATE * TAU
		var tone: float = sin(phase)
		noise_prev = _noise_sample(noise_prev, 0.25, rng)
		var env: float = _env(t, 0.004, 22.0)
		samples[i] = (tone * 0.75 + noise_prev * 0.35) * env
	return _samples_to_wav(samples)


## Recall whip-crack: a quick RISE (500->950Hz over the first third) then FALL
## (950->220Hz over the rest) sine, mixed with brighter filtered noise than
## Impact's own -- a "crack", not a thud, matching the GDD's "Whip" cue.
static func _build_recall_whip() -> AudioStreamWAV:
	var duration := 0.16
	var n: int = int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var noise_prev := 0.0
	var phase := 0.0
	for i in n:
		var t: float = float(i) / SAMPLE_RATE
		var progress: float = t / duration
		var freq: float
		if progress < 0.33:
			freq = lerp(500.0, 950.0, progress / 0.33)
		else:
			freq = lerp(950.0, 220.0, (progress - 0.33) / 0.67)
		phase += freq / SAMPLE_RATE * TAU
		var tone: float = sin(phase)
		noise_prev = _noise_sample(noise_prev, 0.5, rng)
		var env: float = _env(t, 0.008, 14.0)
		samples[i] = (tone * 0.5 + noise_prev * 0.5) * env
	return _samples_to_wav(samples)


## Kick thump: a clean low-mid sine sweep (220->85Hz), no noise layer at all
## -- a punchy unarmed hit, deliberately "cleaner"/simpler than the
## noise-textured dart sounds around it (this is a body blow, not a weapon).
static func _build_kick() -> AudioStreamWAV:
	var duration := 0.11
	var n: int = int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var phase := 0.0
	for i in n:
		var t: float = float(i) / SAMPLE_RATE
		var freq: float = lerp(220.0, 85.0, t / duration)
		phase += freq / SAMPLE_RATE * TAU
		var tone: float = sin(phase)
		var env: float = _env(t, 0.003, 26.0)
		samples[i] = tone * env
	return _samples_to_wav(samples)


## Slash "shhk": a bright descending sweep (1100->380Hz) dominated by bright
## filtered noise (alpha=0.7, the brightest noise mix in this whole library)
## for a blade-slice read, distinct from Kick's clean low thump.
static func _build_slash() -> AudioStreamWAV:
	var duration := 0.16
	var n: int = int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var noise_prev := 0.0
	var phase := 0.0
	for i in n:
		var t: float = float(i) / SAMPLE_RATE
		var freq: float = lerp(1100.0, 380.0, t / duration)
		phase += freq / SAMPLE_RATE * TAU
		var tone: float = sin(phase)
		noise_prev = _noise_sample(noise_prev, 0.7, rng)
		var env: float = _env(t, 0.005, 15.0)
		samples[i] = (tone * 0.3 + noise_prev * 0.7) * env
	return _samples_to_wav(samples)


## Dash burst: a short punchy rising sweep (700->1400Hz) plus bright noise --
## a quick "snap" read distinct from every other whoosh in this library
## (much shorter, much faster decay).
static func _build_dash() -> AudioStreamWAV:
	var duration := 0.12
	var n: int = int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var noise_prev := 0.0
	var phase := 0.0
	for i in n:
		var t: float = float(i) / SAMPLE_RATE
		var freq: float = lerp(700.0, 1400.0, t / duration)
		phase += freq / SAMPLE_RATE * TAU
		var tone: float = sin(phase)
		noise_prev = _noise_sample(noise_prev, 0.6, rng)
		var env: float = _env(t, 0.004, 20.0)
		samples[i] = (tone * 0.35 + noise_prev * 0.65) * env
	return _samples_to_wav(samples)


## Kill confirmation: the heaviest, longest (0.38s vs. every other clip's
## <=0.24s), loudest-mixed clip in this library, per the GDD's "heavy impacts
## have stronger feedback" -- three layers: a low sine thud (180->45Hz, longer
## decay than Impact's own), a square-ish "crunch" harmonic (sign(sin(...)),
## the cheapest way to add odd-harmonic buzz without a second oscillator
## table), and dark filtered noise, all under one slow-decaying envelope so it
## reads as a single weighty hit rather than a quick tap.
static func _build_kill() -> AudioStreamWAV:
	var duration := 0.38
	var n: int = int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 6
	var noise_prev := 0.0
	var phase_low := 0.0
	var phase_crunch := 0.0
	for i in n:
		var t: float = float(i) / SAMPLE_RATE
		var freq_low: float = lerp(180.0, 45.0, minf(t / 0.2, 1.0))
		phase_low += freq_low / SAMPLE_RATE * TAU
		var low_tone: float = sin(phase_low)
		var crunch_freq: float = lerp(90.0, 60.0, t / duration)
		phase_crunch += crunch_freq / SAMPLE_RATE * TAU
		var crunch: float = signf(sin(phase_crunch)) * 0.5
		noise_prev = _noise_sample(noise_prev, 0.35, rng)
		var env: float = _env(t, 0.006, 7.0)
		samples[i] = (low_tone * 0.55 + crunch * 0.25 + noise_prev * 0.3) * env
	return _samples_to_wav(samples)


## Rope trip "pop": the shortest, smallest clip in this library (0.08s, no
## noise layer, quiet mix at the play_trip() call site above too) -- a tiny
## descending blip, deliberately the weakest cue here so it can never be
## mistaken for a kill.
static func _build_trip() -> AudioStreamWAV:
	var duration := 0.08
	var n: int = int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var phase := 0.0
	for i in n:
		var t: float = float(i) / SAMPLE_RATE
		var freq: float = lerp(650.0, 320.0, t / duration)
		phase += freq / SAMPLE_RATE * TAU
		var tone: float = sin(phase)
		var env: float = _env(t, 0.003, 24.0)
		samples[i] = tone * env * 0.6
	return _samples_to_wav(samples)
