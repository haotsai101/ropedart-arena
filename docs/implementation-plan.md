# Rope Dart Arena — Implementation Plan

Companion to `docs/project.md` (the GDD). This is the build order for rebuilding
the rope dart / combat system, which was intentionally stripped down to bare
movement in the `remove-weapon-system` branch ahead of the GDD rewrite.

Each phase ends in a state you can launch and manually play. Later phases
build strictly on earlier ones — don't start a phase until the previous one's
test passes.

## Target platforms

**Desktop and mobile**, both first-class — every phase's manual test should
be run on both, not just whichever is convenient at the time.

- **Desktop** (Windows/macOS/Linux): keyboard+mouse (`player_index == 0`)
  and gamepad (`player_index >= 1`) are both already wired in `player.gd`.
- **Mobile** (iOS/Android): `virtual_controls.gd` provides an on-screen
  Move stick, Aim stick, and two action buttons (Throw, and a "Slash"
  button that Phase 3 repoints to Kick). Confirmed gaps against the full
  control scheme:
  - **No touch Dash button.** `player.gd`'s `_get_dash_pressed()` only
    checks `KEY_SHIFT` or a gamepad shoulder button for `player_index == 0`
    — there's no `_virtual_controls` path at all, so Dash is currently
    unusable on a touch build.
  - Recall shares the Throw button (context-sensitive on dart state — see
    Phase 2), so it needs no separate touch binding.
  - No dedicated input for the Phase 4 swing-redirect (Throw + aim
    direction while `EMBEDDED`) has been designed for touch — on desktop
    it's just the existing Throw button read in a different dart state, but
    on a touch device the same tap-target needs to feel deliberate, not
    accidental, given how often it'll be tapped mid-fight.
  - **No export presets configured** — `export_presets.cfg` doesn't exist
    in the repo yet, so there's no iOS/Android/Windows/macOS export target
    set up at all. This is packaging work, independent of any gameplay
    phase, and should happen early enough that on-device testing isn't
    blocked until the end.
  - `project.godot` already sets `stretch/mode="canvas_items"` and
    `stretch/aspect="expand"`, a reasonable baseline for multi-resolution/
    multi-aspect-ratio UI — `lobby.gd` and `hud.gd`'s code-built layouts
    should still be spot-checked at phone aspect ratios, not just desktop
    16:9.

Each phase below now calls out the specific touch-control work it needs to
stay in parity with its desktop input, where relevant.

## Current baseline (already playable today)

Confirmed by reading the code, not assumed:

- `player.gd`: movement, dash, aim direction, ring-out fall (teleport to
  spawn, no life cost). No dart, no melee, no `is_dead`/`lives`.
- `game_manager.gd`: `RoundState` is just `LOBBY -> COUNTDOWN -> PLAYING`,
  no win condition — a sandbox, not a match.
- `hud.gd`: life dots / round-win pips / end overlays removed.
- `bot_controller.gd`: **left untouched and currently broken** — it still
  calls `get_desired_throw()`, `get_desired_slash()`, and reads `player.dart`
  / `player.is_dead` / `player.lives`, none of which exist on `player.gd`
  any more.
- `arena_obstacle.gd` already exposes `get_rect_2d()` / `get_outline_2d()`
  for pillars and scattered trees — this is exactly the API the wrap-around
  rope needs, so Phase 4 queries it rather than building obstacle detection
  from scratch.
- `arena_camera.gd` is already `PROJECTION_ORTHOGONAL` — going isometric is
  an angle/rotation change, not a projection rewrite.

---

## Phase 0 — Lobby, character select & outfit customization (already complete)

Unlike combat, this system was **never touched** by the weapon-system
removal and is fully built today. Included here so the plan gives the
complete picture, not just the combat rebuild — no work is needed unless a
later phase (e.g. Phase 5's round/match restoration) needs to hook into it.

- `lobby.gd`: multi-screen flow — `username → browser → waiting` (online)
  or `username → local_config → char_select_local` (offline vs bots). All
  UI built in code, no scene-editor layout.
- **Character select**: 6 KayKit Adventurers base characters
  (`GameManager.CHARACTER_DEFS`), each with a distinct color and native
  headwear/cloth. Base-character picks are enforced unique across players
  in a room (`_is_char_taken_by_other`).
- **Outfit customization**: independent headwear (5 options) and cloth/cape
  (6 options) pools (`HEADWEAR_DEFS`/`CLOTH_DEFS`), mix-and-matchable across
  *any* base character — e.g. Barbarian wearing the Knight's cape — via
  `character_builder.gd` reparenting the source glb's mesh nodes onto the
  chosen base's shared `Rig_Medium` skeleton. Live 3D preview
  (`_make_character_preview`) updates as the player cycles each of the
  three rows (character/headwear/cloth).
- Both the online waiting-room screen and the offline `char_select_local`
  screen use the same picker; online picks are synced to all peers via
  `sync_characters_rpc`/`sync_accessories_rpc`.
- Local config screen (`_build_local_config_screen`) sets bot count/
  difficulty for offline play.
- Username persisted locally at `user://prefs.cfg` via `username_manager.gd`.

**Manual test (already passing):** from a fresh launch, set a username, go
either route — online: create/join a room, pick a base character + headwear
+ cloth, see them reflected live in the preview and synced to other
players in the room; offline: configure bot count/difficulty, then pick
your fighter's character/headwear/cloth on the local customize screen.

---

## Phase 1 — Isometric camera + throw/embed (no combat yet)

**Goal:** get a dart physically leaving the player's hand and sticking into
the world, at the new camera angle, before any damage exists.

- `arena_camera.gd`: adjust rotation to isometric (currently top-down-ish).
- New `scripts/rope_dart.gd` (recreates the file deleted in the weapon
  removal). State enum from the start: `HOLSTERED, CHARGING, FLYING,
  EMBEDDED, SWINGING, RETURNING` — using the GDD's renamed vocabulary
  directly, not the old `EXTENDING/ANCHORED/RECALLING` names.
- `player.gd`: wire Throw input — hold to charge, release to throw.
- `FLYING`: dart travels as a physics body; simple **straight-line**
  distance constraint to the player capped at max rope length (segmented/
  wrap-around constraint is Phase 4, not here).
- `EMBEDDED`: dart sticks in the first valid surface it hits — wall,
  `ArenaObstacle` (pillar/tree), or ground.
- No damage, no Kick, no Recall yet.

**Manual test:** move around, aim, hold-to-charge, release — dart flies and
embeds in a wall/pillar/tree/ground; rope renders as a line between player
and dart; player's movement is constrained once the rope goes taut. Run on
desktop (keyboard) **and** a touch build (existing Throw button already
covers charge/release, no new touch work needed for this phase).

---

## Phase 2 — Returning + dart lethality (straight-line combat loop)

**Goal:** close the core kill loop from the GDD's Combat section, still on
the simple straight-line rope.

- `RETURNING`: Recall pulls the dart back at increasing speed; transitions
  to `HOLSTERED` on arrival. **Recall shares the same button as Throw** —
  context-sensitive on `dart.state` (dart in hand → hold-to-charge/release-
  to-throw; dart away → press to recall), not a separate binding. No new
  input path needed on any platform as a result.
- **Dart contact = always lethal**, in every away-state (`FLYING`,
  `EMBEDDED`, `RETURNING`). **Rope contact = trip + slow, never lethal.**
- `player.gd` needs a minimal `is_dead` + respawn-on-hit added back (just
  enough to represent a kill — full lives/round tracking is Phase 5, not
  here).
- `bot_controller.gd`: patch just enough to stop erroring against the new
  dart shape (its dodge/throw logic can stay rough — full bot rework is
  Phase 6).

**Manual test:** vs a bot or second player — landing the dart kills and
respawns the target instantly; missing and recalling *through* a target on
the way back also kills them; brushing the rope on a bystander trips/slows
them without killing. Confirm the same button reliably does both jobs —
throw when the dart's in hand, recall when it's away — on desktop and touch.

---

## Phase 3 — Slash / Kick

**Goal:** give the player a melee option at close range regardless of dart
state (Pillar #1 — "your attack options change"), not just while the dart
is away.

- **Same button** for both, context-sensitive on `dart.state` — same
  pattern as the Throw/Recall unification:
  - Dart in hand (`HOLSTERED`/`CHARGING`): **Slash** — melee with the dart
    itself. Always lethal on contact, same rule as the thrown dart.
  - Dart away (`FLYING`/`EMBEDDED`/`SWINGING`/`RETURNING`): **Kick** —
    unarmed melee. Knockback only, never lethal.
- Remove the dead `SLASH_RANGE` / `get_desired_slash()` melee-slash remnants
  in `bot_controller.gd` and replace with real Slash/Kick bot logic (bots
  should threaten a kill at melee range when the human still has their dart
  holstered, not just when it's away).
- `virtual_controls.gd`: repoint the existing Slash button to this unified
  Slash/Kick input rather than adding a new button — the touch layout
  already has a correctly-placed action button here.

**Manual test:** with the dart still holstered, walk up to an opponent and
Slash — it kills them, same as a thrown-dart hit. Throw your dart away,
walk up to an opponent, and use the same button — now it Kicks them
(shoved back, not killed). Run on desktop **and** touch.

---

## Phase 4 — Weapon-swing + wrap-around (DONE)

**Goal:** the highest-risk phase — the `SWINGING` state exactly as scoped
in the GDD, in isolation from round/bot complexity so it's easy to iterate
on.

**Wrap-around: DONE**, pulled forward ahead of schedule and built out far
more thoroughly than originally scoped here, across several follow-on
fixes:
- Segmented player → wrap-point(s) → dart constraint, replacing the
  straight-line one, driven by `ArenaObstacle` rect/outline geometry.
- Wrap tracking is **stateful/incremental** (not a fresh shortest-path
  search every frame) so it doesn't snap to the opposite side of an
  obstacle as the player walks around it.
- Chain link visuals interlock properly and terminate at a tail ring on
  the dart, following the same wrap-aware path.
- `RETURNING`/Recall retraces the wrap path point by point (unwinding
  around the obstacle) instead of beelining through it, including a fix
  for recall's wrap memory starting blank and briefly picking the wrong
  side on the very first tick after a long walk around an obstacle.

**`SWINGING` mechanic: DONE.** Final input design (resolved after the
Throw/Recall unification made the GDD's original "Throw + aim direction
while Embedded" trigger ambiguous with Recall on the same button): while
`EMBEDDED`, a **quick tap** still means Recall (no regression); a **hold,
then release aiming a direction** means Redirect — the same hold-to-aim/
release-to-throw gesture as the original throw, just triggered from the
dart's current anchor. Chainable indefinitely; a quick-tap Recall is the
only way out into `RETURNING`. Touch gets its own color-coded affordance
once a hold crosses the redirect threshold, so a touch player can tell
"release now = redirect" from "release now = recall."

**Manual test:** embed the dart in a wall, stand near a pillar, trigger a
swing-redirect that arcs past it — the rope should visibly bend around the
pillar's edge instead of clipping through. Chain 2–3 redirects in a row,
then Recall to end the swing. Run on desktop **and** touch — the redirect
should feel equally reliable to trigger on both.

---

## Phase 4.5 — Touch parity: Dash button (DONE)

**Goal:** close the one input gap that isn't tied to a new combat mechanic —
Dash currently has no touch binding at all (see Target Platforms), so it's
unusable on mobile even though it's a core baseline ability today.

- `virtual_controls.gd`: add a Dash button and `get_dash_held()`.
- `player.gd`'s `_get_dash_pressed()`: add the `_virtual_controls` path,
  matching the pattern already used by `_get_move_input()`/`_get_aim_input()`.

**Manual test:** on a touch build, Dash works identically to the desktop
Shift/shoulder-button binding — dodge, gap-close, and escape all work
without a keyboard or gamepad attached.

---

## Phase 5 — Round/match loop restoration (DONE)

**Goal:** now that death means something, turn the sandbox `PLAYING` state
back into a real match.

- `game_manager.gd`: restore `ROUND_END`/`MATCH_END`, `lives_per_round`,
  `rounds_to_win`, and the win-check.
- `hud.gd`: restore life dots, round-win pips, round/match-end overlays.
- Wire dart-kill (from Phase 2) to decrement lives and trigger the win
  check.

**Manual test:** play a full round to completion — last player standing
triggers a round win, HUD life dots stay accurate throughout, playing
multiple rounds reaches a match win.

---

## Phase 6 — Bots at full parity (DONE)

**Goal:** `bot_controller.gd` predates Kick and Swinging entirely — bring it
up to the full new kit so solo/local-vs-bots is a real test environment
again.

- Update dodge logic: every away-state is now lethal (not just `FLYING`),
  so bots need to treat `EMBEDDED`/`SWINGING`/`RETURNING` darts as threats
  too.
- Add Kick usage to bot AI at melee range.
- Decide swing-redirect usage per difficulty (e.g. Hard bots attempt
  redirects, Easy/Medium don't) — flag as a judgment call, not a hard
  requirement, since bot swing-aim may need its own tuning pass.

**Manual test:** play a full local match vs 3 bots at each difficulty;
confirm they throw, dodge, and kick sensibly with no errors in the debug
output.

---

## Phase 7 (bonus / stretch) — Mobility pendulum-swing

**Goal:** the mechanic explicitly deferred during design review — the
player's own body swings around a fixed anchor, distinct from Phase 4's
dart-swings-around-player weapon mechanic. Only start this once Phases 1–6
are stable.

- While `EMBEDDED`, an alternate input lets the player pendulum-swing their
  own body around the anchor point (Grapple / Pendulum Swing / Slingshot
  from the GDD's Mobility section) instead of unanchoring the dart.
- Release to launch off with retained momentum.

**Manual test:** anchor the dart, swing your own body around the anchor to
cross a gap or dodge an attack, then release and confirm you keep the
swing's momentum on landing.
