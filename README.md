# Rope Dart Prototype (Godot 4, 2.5D)

A minimal runnable starting point for a Boomerang Fu–style arena brawler with a
rope dart instead of a boomerang. **2.5D visuals, 2D gameplay**: everything
renders in full 3D with real lighting and shadows, but all gameplay logic runs
as cheap 2D math on the ground (XZ) plane.

## How to run

1. Install **Godot 4.3+** (standard build, not .NET).
2. Open Godot → Import → select this folder's `project.godot`.
3. Press **F5** (Play).

## Controls

- **Move**: WASD / left stick
- **Aim**: Arrow keys / right stick (falls back to movement direction)
- **Throw / Recall**: Space / right trigger
  - Press once to throw. The dart extends to full range and anchors (hangs taut).
  - Press again to recall — it flies back and you "catch" it (despawns).

## The architecture (the important part)

The whole project is built around one rule: **logic is 2D, rendering is 3D.**

- `scripts/player.gd` — movement, aim, and position are all `Vector2` (x → world
  X, y → world Z). The 3D transform is just how that 2D state gets drawn. Y is
  visual-only; there is no vertical gameplay.
- `scripts/rope_dart.gd` — a 2D state machine (`EXTENDING → ANCHORED →
  RECALLING`). The dart head is a 2D point. The rope's *physics* is a straight
  2D line; the rope's *render* is a 3D cylinder rebuilt each frame so it catches
  light. Simple logic, good-looking result.

This separation is what keeps a 2.5D game tractable: distance checks, collision,
and rope math stay as fast 2D operations while the screen looks 3D.

## Where to take it next (good next prototypes)

These are the rope-dart-specific mechanics worth trying — each is a small,
contained change to `rope_dart.gd`:

- **Rope as a collision object** — make the taut line trip/clothesline anything
  that crosses it (the most distinctive rope-dart idea; prototype it early).
- **Swing / orbit** — let the player rotate an anchored dart around themselves as
  a melee zone.
- **Yank** — pull the player toward an anchored dart, or pull an enemy toward the
  player.
- **Charged throw** — hold to throw farther/faster.

## What's placeholder

Capsule player, sphere dart, cylinder rope — all programmer art so you can feel
the mechanic immediately. Swap in real models later; the logic doesn't change
because rendering is already decoupled from gameplay.
