# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Default Agent

**Always use the `godot-engineer` agent** for any implementation task in this repo — bug fixes, new features, refactors, scene work, GDScript authoring, and architecture decisions. Invoke it via the Agent tool before writing any code yourself.

## Running the game

Open Godot 4.7 (standard build, not .NET) → Import → select `project.godot` → F5.

There is no CLI build or test runner. All iteration happens in the Godot editor. The Godot MCP server (`godot` tool) is configured and can be used to inspect the scene tree and node properties without switching to the editor.

## Architecture: 2D logic, 3D rendering

**The invariant that governs every script**: all gameplay math (movement, collision, kill detection, rope physics) runs as `Vector2` on the XZ plane. `x` maps to world X, `y` maps to world Z. The 3D transform is purely for rendering. Never introduce vertical (Y-axis) gameplay.

`get_pos_2d() -> Vector2` on `player.gd` is the canonical way to read any player's gameplay position. All kill checks, clothesline math, and bot targeting use this.

## Game systems and their wiring

**`GameManager` (autoload)** — `scripts/game_manager.gd`
- Singleton accessible as `GameManager` from any script.
- Owns the round state machine: `LOBBY → COUNTDOWN → PLAYING → ROUND_END → MATCH_END`.
- Spawns all player instances at startup via `call_deferred("_init_game")` (must defer so the main scene is ready). Players are added as children of `get_tree().current_scene`.
- Key exports: `total_players`, `human_count`, `bot_difficulty`, `lives_per_round`, `rounds_to_win`.

**`player.gd`** — `CharacterBody3D`, one instance per player
- Input: `player_index == 0` → keyboard (WASD/arrows/Space); `player_index >= 1` → gamepad `player_index - 1`. When `is_bot == true`, input is delegated to `bot_controller` via `get_desired_move()` / `get_desired_aim()` / `get_desired_throw()`.
- Movement is blocked (velocity zeroed) when `GameManager.current_state != PLAYING`.
- Signals: `player_killed(player)`, `player_eliminated(player)`. Both HUD and GameManager connect to these.
- `reset_for_round(lives, pos)` is the only way to restore a player between rounds.

**`rope_dart.gd`** — `Node3D`, spawned by player on throw
- State machine: `EXTENDING → ANCHORED → RECALLING`.
- All kill logic is pure 2D math — no physics collision shapes needed:
  - Head hits: `_check_head_hits()` checks distance from `head_2d` to each player's `get_pos_2d()`.
  - Clothesline: in `ANCHORED`, checks `_seg_dist(player_pos, owner_pos, head_2d) < hit_radius` for every non-owner player each frame.
- Anchors at arena boundary (`arena_half = 14.5`) or when `_hits_obstacle()` returns true.
- Adds itself to the `"darts"` group in `launch()` so `bot_controller.gd` can find incoming darts.

**`bot_controller.gd`** — `Node`, attached as child `"BotController"` under bot players by GameManager
- Sets `parent.bot_controller = self` in `_ready()`.
- State machine: `CHASE → AIM → RETREAT`. Medium/Hard bots also dodge incoming darts via `_get_dodge_dir()`.
- `get_desired_throw()` consumes a one-shot `_throw_pending` flag; the player's `_prev_throw` tracking handles just-pressed detection correctly.

**`hud.gd`** — `CanvasLayer`, instanced from `scenes/hud.tscn` in main scene
- All UI nodes are created in code (no scene editor layout). `_build_skeleton()` creates the panel structure; `_setup_player_panels()` (deferred one frame) populates them after GameManager has spawned players.
- Connects to `GameManager.state_changed`, `round_ended`, `match_ended`, and each player's `player_killed` / `player_eliminated`.

**`arena_camera.gd`** — script on `Camera3D` in main scene
- Orthographic projection. Computes AABB of all alive players (by `lives > 0`) each frame and lerps `size` and position to keep them in frame.

**`arena_obstacle.gd`** — `StaticBody3D` script on pillar nodes
- Adds node to `"obstacles"` group. Exposes `get_rect_2d() -> Rect2` for dart anchoring checks.

## Node groups

| Group | Members | Used by |
|---|---|---|
| `"players"` | All player CharacterBody3D nodes | `rope_dart.gd`, `bot_controller.gd`, `arena_camera.gd`, `hud.gd` |
| `"darts"` | All active rope dart Node3D instances | `bot_controller.gd` (dodge detection) |
| `"obstacles"` | Pillar StaticBody3D nodes | `rope_dart.gd` (anchor check) |
| `"spawn_points"` | Node3D markers in main.tscn | `game_manager.gd` (spawn positions) |

## Duck typing convention

Player script properties (`player_index`, `is_dead`, `lives`, `get_pos_2d()`, `kill()`, etc.) are accessed from other scripts via duck typing on untyped variables. Use `for p in array:` (not `for p: Node in array:`) when iterating players, and `Variant` for signal callback parameters that receive player nodes, to avoid GDScript strict-mode type errors.
