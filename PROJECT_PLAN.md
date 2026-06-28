# Dartrope Arena — Project Plan

**Game concept**: Local-multiplayer arena brawler (Boomerang Fu–style) using a rope dart instead of a boomerang. 2.5D: gameplay logic is 2D on the XZ plane, rendering is full 3D. 1–6 players (keyboard + up to 5 gamepads), remaining slots filled by AI bots. No power-ups in v1.

---

## Current status: Playable prototype

Everything below is implemented and in the repo.

### Done
- **Player system** — per-device input (keyboard player 0, gamepads 1–5), distinct colors, WASD/arrow/Space for keyboard, left-stick/right-stick/A-button for gamepad
- **Rope dart** — EXTENDING → ANCHORED → RECALLING state machine; 2D hit detection (dart head radius check + clothesline segment-distance check); anchors at arena walls and pillars
- **Combat** — one-hit kills, 3-life respawn system, eliminated players frozen
- **Bot AI** — CHASE → AIM → THROW → RETREAT; 3 difficulty levels (Easy/Medium/Hard); Medium+ bots dodge incoming darts
- **GameManager autoload** — round state machine (COUNTDOWN → PLAYING → ROUND_END → MATCH_END); configurable `total_players`, `human_count`, `bot_difficulty`, `lives_per_round`, `rounds_to_win`
- **HUD** — life dots, round-win pips, countdown overlay, round-end/match-end overlays; all built in code (no scene editor)
- **Dynamic camera** — orthographic, pans/zooms to frame all alive players
- **Arena** — 30×30 ground, 4 boundary walls, 2 center pillars as cover obstacles, 6 spawn points
- **Godot MCP** configured (`godot` tool available for scene inspection)

### Known issues fixed this session
- Strict-mode type errors: `for p: Node in array` → `for p in array`; explicit `: float` / `: Vector2` annotations where `:=` would infer Variant; signal callbacks changed from `Node` to `Variant` parameter type

---

## Configuration knobs (in `scripts/game_manager.gd` exports)

| Export | Default | Notes |
|---|---|---|
| `total_players` | 4 | 2–6 |
| `human_count` | 1 | Remaining slots are bots |
| `bot_difficulty` | 0 | 0=Easy 1=Medium 2=Hard (all bots same level) |
| `lives_per_round` | 3 | |
| `rounds_to_win` | 3 | |
| `countdown_duration` | 3.0s | |
| `round_end_delay` | 3.5s | |

---

## Next up (prioritized)

### 1. Lobby / player-count selection screen
Right now the game starts immediately with hardcoded config. A simple lobby scene where the host picks player count and bot difficulty before the first round. Could be a separate `scenes/lobby.tscn` that transitions to `main.tscn`.

### 3. Death VFX + screen shake
On `player.kill()`: spawn a `GPUParticles3D` burst tinted to `player_color`, trigger a small camera shake (add `shake(intensity, duration)` to `arena_camera.gd`). Blink-in animation on `_respawn()` via a Tween.

### 4. Rope clothesline visual feedback
The clothesline is deadly but invisible. Consider changing the rope material to a bright/warning color when ANCHORED (e.g., red/orange pulse via material `emission` property toggled each frame).

### 5. Sound effects
No audio yet. Priority order: dart throw whoosh, hit/kill impact, countdown beeps, round-end sting. Use `AudioStreamPlayer3D` on the player/dart for spatial audio.

### 7. Quit / restart input
Currently `GameManager.RoundState.MATCH_END` shows "Thanks for playing — press Escape to quit" but Escape isn't wired. Add `Input.is_action_just_pressed("ui_cancel")` → `get_tree().quit()` in GameManager's `_process`, and a restart option that calls `get_tree().reload_current_scene()`.

---

## Deferred / out of scope for v1
- Power-ups
- Multiple arena maps
- Network multiplayer
- Rope swing/orbit mechanic (dart orbiting player as melee zone)
- Yank mechanic (pull player toward anchored dart)
- Charged throw (hold to extend max range)
