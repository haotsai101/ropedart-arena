# Rope Dart Arena

## Game Design Document (GDD)

---

# High Concept

A fast-paced multiplayer arena combat game where every player wields a rope dart.

Players throw, swing, recall, and anchor their rope darts to eliminate opponents while using momentum and rope mechanics for mobility and positioning.

The game emphasizes:

* Precision
* Momentum
* Positioning
* Mobility
* Quick rounds
* Easy controls
* High skill ceiling

Target Match Length:
**1–3 minutes**

Players:
**2–8**

Perspective:
**Isometric 3D**

---

# Design Pillars

## 1. Every Throw Matters

Throwing the dart commits the player.

While the dart is away:

* Your attack options change.
* Your movement is affected.
* Your positioning changes.

---

## 2. Momentum Is A Weapon

The dart becomes stronger as it gains speed.

Players create momentum by:

* Running
* Swinging
* Recalling
* Redirecting the rope

---

## 3. Mobility Through Combat

The rope is not only a weapon.

It is also:

* Grappling hook
* Swing
* Escape tool
* Gap closer

*(Player-mobility swinging — pendulum around a fixed anchor — is a bonus/stretch feature, built after the v1 weapon-swing below is proven out.)*

---

## 4. Easy To Learn

Only a few actions:

* Move
* Aim
* Throw
* Recall
* Dash

Everything else emerges naturally.

---

# Core Gameplay Loop

1. Move around arena.
2. Throw dart.
3. Build momentum.
4. Strike opponents.
5. Recall dart.
6. Repeat.

Rounds are short and intense.

---

# Controls

## Movement

Left Stick / WASD

---

## Aim

Right Stick / Mouse

---

## Throw / Recall

**Same button** — Right Trigger / Left Mouse — context-sensitive on the dart's current state:

* Dart in hand (Holstered/Charging): hold to charge, release to throw.
* Dart away (Flying/Embedded): press to recall — pulls the dart back, speed increasing over time. Can damage enemies during recall.

One input covers the whole throw-and-retrieve loop; there is no separate Recall binding.

---

## Dash

Face Button / Space

Short cooldown.

Used for:

* Dodging
* Momentum generation
* Escaping

---

## Kick

Face Button (Secondary) / E

Melee knockback.

Only usable while the dart is not in hand (unavailable Holstered or Charging; available Flying, Embedded, Swinging, Returning).

Replaces the old melee-slash mechanic.

---

# Player Abilities

Each player always has:

* Rope Dart
* Dash
* Kick

No weapon pickups required.

---

# Rope Dart

## States

Holstered

↓

Charging

↓

Flying

↓

Embedded

↓

Swinging

↓

Returning

↓

Holstered

---

## Flying

The dart travels using physics.

Connected to player by rope.

Cannot exceed rope length.

---

## Swinging

**v1 mechanic — weapon-swing.**

Triggered by Throw + aim direction while Embedded.

The dart unanchors, swings/arcs toward the new aimed direction, and re-anchors into valid map geometry when it lands.

The swing path wraps around map obstacles (pillars, trees) via the segmented rope chain.

Chainable: Throw + direction again redirects into another swing. Recall is the only way to exit into Returning.

The dart is always lethal on contact, regardless of swing speed.

*(Player-mobility pendulum-swinging around a fixed anchor is a separate, bonus mechanic — see Mobility.)*

---

## Returning

Player recalls the dart.

Recall speed increases over time.

The dart is always lethal on contact while returning.

---

## Embedded

The dart sticks into valid surfaces.

Player may:

* Unanchor and swing (see Swinging)
* Recall

*(Grapple / pull-against-rope for player mobility is a bonus mechanic — see Mobility.)*

---

# Rope Mechanics

The rope has:

Maximum Length (fixed, no stretching)

Wraps around map obstacles (pillars, trees) — v1 requirement

Gameplay uses a segmented distance constraint: player → wrap point(s) → dart.

---

# Combat

Damage is determined by **hit type**, not speed or hit location.

## Dart Contact

Always lethal.

Applies in every dart state: Flying, Embedded landing, Swinging, Returning.

---

## Rope Contact

The rope itself trips and slows — never lethal.

---

## Kick

Knockback only. Only usable while the dart is not in hand.

---

## Recall Danger

Returning dart is always lethal on contact.

Encourages:

Throw

↓

Miss

↓

Recall through enemies

---

# Mobility

*(Everything in this section is bonus/stretch — built after the v1 weapon-swing mechanic is proven out. The player's own body swings on the rope here, distinct from the v1 weapon-swing where the dart swings around the player.)*

## Grapple

Anchor dart.

Swing.

Release.

Maintain momentum.

---

## Pendulum Swing

Use rope to:

* Build speed
* Cross hazards
* Dodge attacks

---

## Slingshot

Run opposite rope direction.

Release.

Launch player.

---

# Arena Design

Small arenas.

Lots of:

* Corners
* Pillars
* Walls
* Elevation

Good arenas encourage:

Swinging

Bank shots

Creative recalls

Momentum routes

---

# Hazards

Examples:

Spikes

Lava

Moving saws

Collapse floors

Wind

Rotating obstacles

Hazards interact with rope movement.

---

# Powerups

Temporary only.

Examples:

## Longer Rope

+25% length

---

## Heavy Dart

Higher knockback

More damage

Lower speed

---

## Lightning Rope

Recall is faster

---

## Explosive Recall

Explosion when caught

---

## Triple Recall

Dart returns in arcs

---

## Sticky Rope

Enemies briefly slowed after impact

---

## Ghost Rope

Passes through walls

*(Flagged for later: this conflicts with the v1 wrap-around-map mechanic — a rope that passes through walls can't also wrap around them. Needs resolving when this powerup is actually built.)*

---

# Game Modes

## Free For All

Last survivor wins.

---

## Team Battle

Two teams.

Shared lives.

---

## Stock Mode

Each player has multiple lives.

---

## King of the Hill

Control objective.

Rope movement becomes valuable.

---

## Capture the Core

Retrieve an object.

Use rope for mobility.

---

# Progression

Unlock:

Characters

Rope skins

Dart skins

Victory poses

Emotes

No gameplay advantages.

---

# Character Design

Characters are expressive and readable.

Large silhouettes.

Simple animations.

Readable during fast combat.

---

# Visual Style

Bright colors.

Clean arenas.

Minimal visual clutter.

Strong rope visibility.

Player colors remain visible at all times.

---

# Audio

Every rope action has a satisfying sound.

Examples:

Throw

Whip

Swing

Impact

Recall

Anchor

Heavy impacts have stronger feedback.

---

# Technical Design

Player

* CharacterBody3D

Dart

* RigidBody3D

Rope

* Procedural mesh

Constraint

* Segmented distance constraint: player → wrap point(s) → dart

* Wrap points computed dynamically against map obstacle geometry

---

# Update Order

Every physics frame:

1. Read input.
2. Update player.
3. Simulate dart.
4. Detect impacts.
5. Apply rope constraint.
6. Update rope mesh.
7. Resolve combat.
8. Update animations.

---

# Winning Strategy

Good players:

Manage momentum.

Control space.

Punish recalls.

Use movement creatively.

Master swinging.

Predict opponent movement.

---

# Long-Term Skill Ceiling

Players improve by learning:

Optimal throw timing.

Swing routes.

Momentum conservation.

Recall trajectories.

Arena geometry.

Dash timing.

Spacing.

Mind games.

Every mechanic reinforces the core fantasy:

**Mastering a rope dart as both a deadly weapon and a movement tool.**
