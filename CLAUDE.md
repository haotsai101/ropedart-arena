# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Agent roster

Three agents are available. Pick the right tier — over-spending on the senior agent for a string fix wastes tokens.

| Agent | Model | Use for |
|---|---|---|
| `godot-engineer` | Sonnet | New systems, multi-file features, bug diagnosis, anything needing `run_project` verification |
| `godot-junior` | Haiku | Mechanical single-file edits: string fixes, constant tweaks, adding a key handler, renaming a property. No run-verify. |
| `game-ui-designer` | Sonnet | HUD layout, menus, Tween animations, particle VFX, screen shake, visual polish |

**Decision rule:**
- Can you specify the exact file + line + change? → `godot-junior`
- Does it touch UI feel, animations, or visual feedback? → `game-ui-designer`
- Everything else → `godot-engineer`

**Fork instead of spawning** when the relevant files are already loaded in the conversation context and the task is diagnosis-only (no code changes needed). A fork shares the prompt cache and avoids re-reading files already in context.

## Running the game

Open Godot 4.7 (standard build, not .NET) → Import → select `project.godot` → F5.

There is no CLI build or test runner. All iteration happens in the Godot editor. The Godot MCP server (`godot` tool) is configured and can be used to inspect the scene tree and node properties without switching to the editor.

## Architecture: 2D logic, 3D rendering

**The invariant that governs every script**: all gameplay math (movement, collision, kill detection, rope dart flight) runs as `Vector2` on the XZ plane. `x` maps to world X, `y` maps to world Z. The 3D transform is purely for rendering. Never introduce vertical (Y-axis) gameplay.

`get_pos_2d() -> Vector2` on `player.gd` is the canonical way to read any player's gameplay position. All kill checks and bot targeting use this.

## Game systems and their wiring

**`GameManager` (autoload)** — `scripts/game_manager.gd`
- Singleton accessible as `GameManager` from any script.
- Owns the round state machine: `LOBBY → COUNTDOWN → PLAYING → ROUND_END → MATCH_END`.
- Spawns all player instances at startup via a 0-second `SceneTreeTimer` (fires next frame, after `change_scene_to_file` has fully applied). Players are added as children of `get_tree().current_scene`.
- Key exports: `total_players`, `human_count`, `bot_difficulty`, `lives_per_round`, `rounds_to_win`.

**`player.gd`** — `CharacterBody3D`, one instance per player
- Input: `player_index == 0` → keyboard (WASD/arrows/Space); `player_index >= 1` → gamepad `player_index - 1`. When `is_bot == true`, input is delegated to `bot_controller` via `get_desired_move()` / `get_desired_aim()` / `get_desired_throw()`.
- Movement is blocked (velocity zeroed) when `GameManager.current_state != PLAYING`.
- Signals: `player_killed(player)`, `player_eliminated(player)`. Both HUD and GameManager connect to these.
- `reset_for_round(lives, pos)` is the only way to restore a player between rounds.

**`rope_dart.gd`** — `Node3D`, spawned by player on throw
- State machine: `FLYING → ANCHORED → RECALLING`. Thrown, it flies in a straight line until it hits a player, an obstacle, the arena boundary, or its own max range, then anchors there. Unlike a plain thrown weapon it stays tethered — a rope mesh is drawn from the owner's hand to the dart head every frame in every state — and pressing throw again while it's out (`dart != null`) calls `recall()` to pull it back toward the owner's current position instead of doing nothing; walking up to it (`pickup_radius`) still also retrieves it.
- Hit detection is pure 2D math — no physics collision shapes needed: `_check_hits()` checks distance from `head_2d` to each non-owner player's capsule (`_seg_dist(head_2d, base, _capsule_top(base)) < hit_radius`), then distinguishes a tight `head_hit_radius` at the top of the capsule (instant `kill()`) from anywhere else along it (non-lethal `trip()` "clothesline" stagger). Either kind anchors the dart at the point of contact.
- Obstacle/boundary stopping: swept segment-vs-rect test each frame (`_get_swept_hit_obstacle`) against every `"obstacles"` member's `get_rect_2d()`, plus a hard clamp at `arena_half`.
- A player can only have one rope dart out (in flight, anchored, or recalling) at a time — `player.gd` only lets `_throw()` fire while its own `dart == null`.
- Adds itself to the `"darts"` group in `launch()` so `bot_controller.gd` can find incoming darts to dodge.
- Animations (see `player.gd`'s `ANIM_SOURCES`/`combat_moves.glb`, retargeted from Quaternius's Universal Animation Library via Blender): `Spell_Simple_Shoot` on throw, `Sword_Attack` on a lethal melee slash (rope dart in hand), `Punch_Jab` on a non-lethal melee kick (rope dart thrown), `Push` looped for the duration of an active recall.

### Rope dart move design reference

Three named moves, from design notes — current code implements Throw (Linear Strike) and Retrieval (Reel In) as described; the Wrap (Grapple/Bind) is not yet implemented (no bind/wrap mechanic exists today — a body hit currently applies `trip()`'s stagger, not a spiral bind).

- **The Throw (Linear Strike)**: The character delivers a directional thrust. The metal dart fires straight from the hand. The rope uncoils rapidly into a taut line. The asset maintains absolute linear rigidity at peak extension. Upon impact, the dart freezes briefly in place. The rope sags slightly to indicate lost momentum.
- **The Wrap (Grapple/Bind)**: The character initiates a wide, circular pivot spin. The dart follows a curved, high-velocity arc. The weapon makes contact with the target geometry. The dart rotates tightly around the impact point. The rope wraps around the object in spiral layers. The line snaps completely taut to lock the bind.
- **The Retrieval (Reel In)**: The character snaps their anchor hand backward. The dart dislodges instantly from the target. The weapon flies backward along the original trajectory line. The rope retracts dynamically toward the character's hand. The loose slack forms smooth, looping folds during recovery. The dart snaps back into the idle hand position.

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
- Adds node to `"obstacles"` group. Exposes `get_rect_2d() -> Rect2` for the rope dart's swept-rect stop test — a plain 2D check, no physics-engine query needed.

## Node groups

| Group | Members | Used by |
|---|---|---|
| `"players"` | All player CharacterBody3D nodes | `rope_dart.gd`, `bot_controller.gd`, `arena_camera.gd`, `hud.gd` |
| `"darts"` | All active thrown-rope-dart Node3D instances (flying, anchored, or recalling, until picked up) | `bot_controller.gd` (dodge detection), `arena_camera.gd` (keep in frame) |
| `"obstacles"` | Pillar StaticBody3D nodes | `rope_dart.gd` (swept-rect stop check) |
| `"spawn_points"` | Node3D markers in main.tscn | `game_manager.gd` (spawn positions) |

## Duck typing convention

Player script properties (`player_index`, `is_dead`, `lives`, `get_pos_2d()`, `kill()`, etc.) are accessed from other scripts via duck typing on untyped variables. Use `for p in array:` (not `for p: Node in array:`) when iterating players, and `Variant` for signal callback parameters that receive player nodes, to avoid GDScript strict-mode type errors.
