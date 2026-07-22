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
- `_clamp_to_rope_leash()`, called right after `move_and_slide()` every physics tick: once the owner's rope dart is `ANCHORED`, clamps the player onto the circle of radius `DART_ROPE_LENGTH` around the dart's anchor point rather than letting them walk further away — a real tether limit, not just a visual one. `DART_STATE_ANCHORED` / `DART_ROPE_LENGTH` mirror rope_dart.gd's `State.ANCHORED` ordinal and `ROPE_LENGTH` by hand (no shared constant between the two scripts, same as `HITBOX_DEBUG_RADIUS`).
- Owns the rope itself, in two entirely different forms depending on `dart == null`, both driven from `_update_persistent_rope()` (called from `_process()`/`_physics_process()`):
  - **Idle** (`dart == null`): the old cheap look — `_rope_segments` (`ROPE_SEGMENTS` = 16 `MeshInstance3D` cylinders, built once in `_setup_dagger_in_hand()`) redrawn every frame as a tight coil around the forearm (`_render_rope_coiled()`, anchored at a `lowerarm.r` `BoneAttachment3D`). Purely kinematic/procedural — there's no obstacle to avoid while the rope is just sitting on the character's own arm.
  - **Thrown** (`dart != null`): a **real physics-simulated rope**, not scripted geometry. `_spawn_physics_rope()` builds a chain of `ROPE_PHYSICS_SEGMENTS` (8) `RigidBody3D` links (capsule `CollisionShape3D` + a child `CylinderMesh` for rendering — the mesh needs no per-frame code, it just rides along with whatever the physics solver does to its parent body) connected end-to-end by `PinJoint3D`s, between two kinematic (`freeze_mode = FREEZE_MODE_KINEMATIC`) endpoint bodies: a hand anchor and a tip anchor. `_update_physics_rope_anchors()`, called every `_physics_process()` tick, drives the hand anchor to `get_hand_world_position()` and the tip anchor to the dart's actual rendered pommel position — so Godot's own solver, not any script, is what keeps the rope off pillars/trees/cacti and makes it drape/rest against them when the owner ends up on the far side of an obstacle from an anchored dart. `_free_physics_rope()` tears the whole chain down once `dart` goes back to `null` (recall complete, kill, round reset).
  - **This replaced three earlier scripted-line attempts** (plain straight+sag line; straight line + one whole-span raycast truncation; per-segment raycast truncation along the sag curve) that each looked correct in this agent's own positional verification but were all reported by the user as still visibly drawing/clipping through obstacles, and — after a truncation-based fix did technically work — were still rejected because truncating short of the obstacle isn't what a real rope does; the user explicitly asked for a literally-simulated physics rope instead. See `ROPE_PHYSICS_SEGMENTS`'s doc comment in `player.gd` for the full reasoning and the collision-layer setup that keeps this simulated chain from ever pushing a player or interfering with the dart's own flight raycast (see `arena_obstacle.gd` below).
  - **Known, disclosed limitation**: the chain is simulated for the dart's *entire* time out (FLYING/ANCHORED/RECALLING alike), including while the tip anchor is being dragged at up to 18–36 units/sec during a fast throw or recall — a scenario physics joint solvers are generally not well-suited to, and this was stress-tested only for numerical stability (no NaN/exploding positions, confirmed via a temporary probe removed before commit), never for how it visually reads on screen (no screenshot access in this session). If the user reports jitter specifically during the brief FLYING/RECALLING window, that's the known risk area to revisit first.
- Signals: `player_killed(player)`, `player_eliminated(player)`. Both HUD and GameManager connect to these.
- `reset_for_round(lives, pos)` is the only way to restore a player between rounds.

**`rope_dart.gd`** — `Node3D`, spawned by player on throw
- The rope+dart system lives in one fixed horizontal plane at the owner's hand height: `plane_y` is computed once in `launch()` from `owner_player.get_hand_world_position().y` and held constant for the dart's whole lifetime, regardless of state or the owner's later movement. This is what lets its obstacle detection use *real* Godot physics (see below) while staying compatible with the rest of the game's flat-XZ-plane gameplay math.
- State machine: `FLYING → ANCHORED → RECALLING`. The rope has a fixed length (`ROPE_LENGTH`, 4× a character's height, ~8.0 units) rather than one that scales with charge — charge now scales `travel_speed` only. Thrown, it flies in a straight line until it hits a player, a real obstacle, or the arena boundary (anchors there — stuck until the owner recalls it or walks over it), or reaches `ROPE_LENGTH` without hitting anything (auto-triggers `recall()` — a "yank back" snap-taut, not an anchor). Pressing throw again while it's out (`dart != null`) also calls `recall()` manually; walking up to it (`pickup_radius`) retrieves it in any state.
- Player hit detection is pure 2D math — no physics collision shapes involved: `_check_hits()` checks distance from `head_2d` to each non-owner player's capsule (`_seg_dist(head_2d, base, _capsule_top(base)) < hit_radius`), then distinguishes a tight `head_hit_radius` at the top of the capsule (instant `kill()`) from anywhere else along it (non-lethal `trip()` "clothesline" stagger). Either kind anchors the dart at the point of contact.
- Obstacle stopping during FLYING uses a **real physics raycast** each frame (`_raycast_obstacle`, at the fixed `plane_y`, over the frame's swept motion) against the map's actual `CollisionShape3D` geometry — the same collision pillars/trees/cacti already use against players — via `PhysicsDirectSpaceState3D.intersect_ray`, with every player body excluded by RID so the rope dart never anchors on a character. Plus a hard clamp at `arena_half` for the arena boundary. `plane_y` (see above) is clamped to `[MIN_PLANE_Y, MAX_PLANE_Y]` = `[0.5, 1.6]`, comfortably inside the `[0.0, 2.0]` Y-range every obstacle's collision box shares — the raw hand-bone sample can otherwise land outside that band mid-animation-swing and make the raycast miss real obstacles entirely. On a real-obstacle hit, `head_2d` is offset by `ANCHOR_EMBED_DEPTH` (-0.1175, i.e. pulled back, not pushed in) from the raycast's surface point — the dagger's own origin sits much closer to its pommel (local Z=+0.315) than its tip (local Z=-0.55), so for the dagger's true midpoint to land on the surface (half embedded, half visible) the origin has to sit slightly outside it, not past it.
- `_anchor()` freezes `_anchor_dir_2d` (a copy of `dir_2d` at that instant) — `_render()` uses it for the blade's orientation for the rest of `ANCHORED`, instead of continuously re-deriving it from the owner's current position (which made an anchored/embedded dart visibly swivel as the owner walked around it).
- `launch()` calls `_render()` once immediately at the end, synchronously — without it, `head_mesh` sits at its scene-default transform (world origin, the map's center) for the one render frame between `add_child()` and this dart's first `_physics_process()` tick.
- The rope itself is no longer this script's — see `player.gd`'s `_update_persistent_rope()` and its physics-chain doc comment above. This script's own `_raycast_obstacle()` (below) is still what stops the *dart head's* flight; the rope trailing behind it is now a fully separate, really-simulated `RigidBody3D` chain that reacts to obstacles on its own via Godot's physics solver, not anything this script computes.
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
- Also tags itself with an additional collision layer bit, `layer 2` (named `"rope_obstacles"` in `project.godot`'s `[layer_names]`), on top of whatever layer it already had (normally the default layer 1, left untouched) — this is the dedicated bit `player.gd`'s physics rope chain uses as its `collision_mask`, so the chain reacts to real obstacle geometry without ever being able to detect/collide with players, the ground, or the dart head (none of which carry this bit). One-directional by design: the chain's own `collision_layer` is left at `0`, so nothing else's mask can ever detect the chain back — this is what keeps a literally-simulated rope from leaking into gameplay (pushing a player, blocking movement, or interfering with the dart's own flight raycast).

## Node groups

| Group | Members | Used by |
|---|---|---|
| `"players"` | All player CharacterBody3D nodes | `rope_dart.gd`, `bot_controller.gd`, `arena_camera.gd`, `hud.gd` |
| `"darts"` | All active thrown-rope-dart Node3D instances (flying, anchored, or recalling, until picked up) | `bot_controller.gd` (dodge detection), `arena_camera.gd` (keep in frame) |
| `"obstacles"` | Pillar StaticBody3D nodes | `rope_dart.gd` (swept-rect stop check) |
| `"spawn_points"` | Node3D markers in main.tscn | `game_manager.gd` (spawn positions) |

## Duck typing convention

Player script properties (`player_index`, `is_dead`, `lives`, `get_pos_2d()`, `kill()`, etc.) are accessed from other scripts via duck typing on untyped variables. Use `for p in array:` (not `for p: Node in array:`) when iterating players, and `Variant` for signal callback parameters that receive player nodes, to avoid GDScript strict-mode type errors.
