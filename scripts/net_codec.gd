class_name NetCodec
extends RefCounted
## Hand-packed binary encoding for the three per-tick online messages, sent
## as raw relay frames (NetworkManager.send_game_packet()) instead of RPCs.
## Godot's RPC encoding spends a 4-byte type header on every Variant plus
## 32-bit floats for everything; these layouts use fixed-point int16s sized to
## the game's real ranges, cutting each message to roughly a fifth.
##
## Fixed-point scales (all little-endian):
##   positions  s16 x POS_SCALE  -> 2mm steps, +-65 units (arena is +-15)
##   velocities s16 x VEL_SCALE  -> 1cm/s steps, +-327 u/s
##   directions s16 angle x 10000 rad, DIR_NONE = zero vector
##   timers     u16 x TIME_SCALE -> 0.1ms steps, 0..6.5s
##   inputs     s16 x INPUT_SCALE (stick/aim vectors, |component| <= ~1.5)
## Guests quantize their own input with quantize_input() BEFORE predicting
## with it, so host and guest simulate bit-identical inputs.

const PKT_SNAPSHOT := 1  # host -> all guests: every player's replicated state
const PKT_OWN_STATE := 2  # host -> one guest: its own player's replayable state
const PKT_INPUT := 3  # guest -> host: one tick of input

const POS_SCALE := 500.0
const VEL_SCALE := 100.0
const DIR_SCALE := 10000.0
const DIR_NONE := -32768
const TIME_SCALE := 10000.0
const INPUT_SCALE := 10000.0
const SPEED_SCALE := 100.0
const U16_INF := 65535

const SNAP_ENTRY_SIZE := 23
const SNAP_FLAG_ABSENT := 128  # entry slot whose player node is gone
const OWN_STATE_SIZE := 48
const INPUT_SIZE := 14


static func _s16(v: float) -> int:
	return clampi(roundi(v), -32767, 32767)


static func _u16(v: float) -> int:
	return clampi(roundi(v), 0, 65534)


static func _enc_dir(v: Vector2) -> int:
	if v.length_squared() < 1e-8:
		return DIR_NONE
	return clampi(roundi(v.angle() * DIR_SCALE), -32767, 32767)


static func _dec_dir(a: int) -> Vector2:
	return Vector2.ZERO if a == DIR_NONE else Vector2.from_angle(a / DIR_SCALE)


static func _q_input(v: float) -> float:
	return clampi(roundi(v * INPUT_SCALE), -32767, 32767) / INPUT_SCALE


## The exact value the host will decode from encode_input() for this vector.
static func quantize_input(v: Vector2) -> Vector2:
	return Vector2(_q_input(v.x), _q_input(v.y))


# ---------------------------------------------------------------------------
# Snapshot: [type][count] + count x 23-byte entries, each mirroring
# player.gd get_net_snapshot(): pos, vel, aim, lives, flags, dart state/pos/
# dir/charge. Velocity's y is dropped (players move on the XZ plane).
# ---------------------------------------------------------------------------

static func encode_snapshot(entries: Array) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2 + entries.size() * SNAP_ENTRY_SIZE)
	b[0] = PKT_SNAPSHOT
	b[1] = entries.size()
	var o := 2
	for e: Array in entries:
		if e.is_empty():
			b[o + 13] = SNAP_FLAG_ABSENT
			o += SNAP_ENTRY_SIZE
			continue
		var pos: Vector3 = e[0]
		var vel: Vector3 = e[1]
		var dpos: Vector2 = e[6]
		b.encode_s16(o, _s16(pos.x * POS_SCALE))
		b.encode_s16(o + 2, _s16(pos.y * POS_SCALE))
		b.encode_s16(o + 4, _s16(pos.z * POS_SCALE))
		b.encode_s16(o + 6, _s16(vel.x * VEL_SCALE))
		b.encode_s16(o + 8, _s16(vel.z * VEL_SCALE))
		b.encode_s16(o + 10, _enc_dir(e[2]))
		b[o + 12] = clampi(int(e[3]), 0, 255)
		b[o + 13] = int(e[4]) & 0x7f
		b.encode_s8(o + 14, int(e[5]))
		b.encode_s16(o + 15, _s16(dpos.x * POS_SCALE))
		b.encode_s16(o + 17, _s16(dpos.y * POS_SCALE))
		b.encode_s16(o + 19, _enc_dir(e[7]))
		b.encode_u16(o + 21, _u16(float(e[8]) * TIME_SCALE))
		o += SNAP_ENTRY_SIZE
	return b


## Decodes to the same per-player Array shape get_net_snapshot() returns
## ([] for an absent slot); returns [] if the packet is malformed.
static func decode_snapshot(b: PackedByteArray) -> Array:
	if b.size() < 2:
		return []
	var n: int = b[1]
	if b.size() != 2 + n * SNAP_ENTRY_SIZE:
		return []
	var out: Array = []
	var o := 2
	for i in n:
		if b[o + 13] & SNAP_FLAG_ABSENT:
			out.append([])
			o += SNAP_ENTRY_SIZE
			continue
		out.append([
			Vector3(b.decode_s16(o) / POS_SCALE, b.decode_s16(o + 2) / POS_SCALE, b.decode_s16(o + 4) / POS_SCALE),
			Vector3(b.decode_s16(o + 6) / VEL_SCALE, 0.0, b.decode_s16(o + 8) / VEL_SCALE),
			_dec_dir(b.decode_s16(o + 10)),
			b[o + 12],
			b[o + 13],
			b.decode_s8(o + 14),
			Vector2(b.decode_s16(o + 15) / POS_SCALE, b.decode_s16(o + 17) / POS_SCALE),
			_dec_dir(b.decode_s16(o + 19)),
			b.decode_u16(o + 21) / TIME_SCALE,
		])
		o += SNAP_ENTRY_SIZE
	return out


# ---------------------------------------------------------------------------
# Own-state: mirrors player.gd get_net_own_state() (see its field list).
# ---------------------------------------------------------------------------

static func encode_own_state(s: Array) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(OWN_STATE_SIZE)
	b[0] = PKT_OWN_STATE
	b.encode_u32(1, int(s[0]))
	b[5] = (1 if s[1] else 0) | (2 if s[4] else 0) | (4 if s[9] else 0) \
		| (8 if s[21] else 0) | (16 if s[22] else 0) | (32 if s[23] else 0)
	var pos: Vector3 = s[2]
	var vel: Vector3 = s[3]
	b.encode_s16(6, _s16(pos.x * POS_SCALE))
	b.encode_s16(8, _s16(pos.y * POS_SCALE))
	b.encode_s16(10, _s16(pos.z * POS_SCALE))
	b.encode_s16(12, _s16(vel.x * VEL_SCALE))
	b.encode_s16(14, _s16(vel.z * VEL_SCALE))
	b.encode_u16(16, _u16(float(s[5]) * TIME_SCALE))   # dash timer
	b.encode_u16(18, _u16(float(s[6]) * TIME_SCALE))   # dash cooldown
	b.encode_s16(20, _enc_dir(s[7]))                  # dash dir
	b.encode_u16(22, _u16(float(s[8]) * SPEED_SCALE))  # dash speed
	b.encode_u16(24, _u16(float(s[10]) * TIME_SCALE))  # knockback timer
	b.encode_s16(26, _enc_dir(s[11]))                 # knockback dir
	b.encode_u16(28, _u16(float(s[12]) * TIME_SCALE))  # trip timer
	b.encode_u16(30, _u16(float(s[13]) * TIME_SCALE))  # melee cooldown
	b.encode_s8(32, int(s[14]))                       # dart state
	var dpos: Vector2 = s[15]
	b.encode_s16(33, _s16(dpos.x * POS_SCALE))
	b.encode_s16(35, _s16(dpos.y * POS_SCALE))
	b.encode_s16(37, _enc_dir(s[16]))                 # dart dir
	b.encode_u16(39, _u16(float(s[17]) * SPEED_SCALE)) # dart flight speed
	b.encode_u16(41, _u16(float(s[18]) * TIME_SCALE))  # dart charge time
	b.encode_u16(43, _u16(float(s[19]) * 1000.0))      # dart recall time (ms)
	var swing_range: float = s[20]
	b.encode_u16(45, U16_INF if is_inf(swing_range) else _u16(swing_range * SPEED_SCALE))
	b.encode_s8(47, clampi(int(s[24]), -127, 127))     # dart lead (ticks)
	return b


static func decode_own_state(b: PackedByteArray) -> Array:
	if b.size() != OWN_STATE_SIZE:
		return []
	var bits: int = b[5]
	var swing_raw: int = b.decode_u16(45)
	return [
		b.decode_u32(1),
		(bits & 1) != 0,
		Vector3(b.decode_s16(6) / POS_SCALE, b.decode_s16(8) / POS_SCALE, b.decode_s16(10) / POS_SCALE),
		Vector3(b.decode_s16(12) / VEL_SCALE, 0.0, b.decode_s16(14) / VEL_SCALE),
		(bits & 2) != 0,
		b.decode_u16(16) / TIME_SCALE,
		b.decode_u16(18) / TIME_SCALE,
		_dec_dir(b.decode_s16(20)),
		b.decode_u16(22) / SPEED_SCALE,
		(bits & 4) != 0,
		b.decode_u16(24) / TIME_SCALE,
		_dec_dir(b.decode_s16(26)),
		b.decode_u16(28) / TIME_SCALE,
		b.decode_u16(30) / TIME_SCALE,
		b.decode_s8(32),
		Vector2(b.decode_s16(33) / POS_SCALE, b.decode_s16(35) / POS_SCALE),
		_dec_dir(b.decode_s16(37)),
		b.decode_u16(39) / SPEED_SCALE,
		b.decode_u16(41) / TIME_SCALE,
		b.decode_u16(43) / 1000.0,
		INF if swing_raw == U16_INF else swing_raw / SPEED_SCALE,
		(bits & 8) != 0,
		(bits & 16) != 0,
		(bits & 32) != 0,
		b.decode_s8(47),
	]


# ---------------------------------------------------------------------------
# Input: [type][u32 seq][move s16 x2][aim s16 x2][u8 buttons]
# ---------------------------------------------------------------------------

static func encode_input(seq: int, move: Vector2, aim: Vector2, buttons: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(INPUT_SIZE)
	b[0] = PKT_INPUT
	b.encode_u32(1, seq)
	b.encode_s16(5, clampi(roundi(move.x * INPUT_SCALE), -32767, 32767))
	b.encode_s16(7, clampi(roundi(move.y * INPUT_SCALE), -32767, 32767))
	b.encode_s16(9, clampi(roundi(aim.x * INPUT_SCALE), -32767, 32767))
	b.encode_s16(11, clampi(roundi(aim.y * INPUT_SCALE), -32767, 32767))
	b[13] = buttons & 0xff
	return b


## [seq, move, aim, buttons], or [] if malformed.
static func decode_input(b: PackedByteArray) -> Array:
	if b.size() != INPUT_SIZE:
		return []
	return [
		b.decode_u32(1),
		Vector2(b.decode_s16(5) / INPUT_SCALE, b.decode_s16(7) / INPUT_SCALE),
		Vector2(b.decode_s16(9) / INPUT_SCALE, b.decode_s16(11) / INPUT_SCALE),
		b[13],
	]
