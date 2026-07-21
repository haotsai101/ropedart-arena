"""
Rope Dart Arena — Shared Locomotion Animation Builder
======================================================
Paste this entire file into Blender's Script Editor (Text -> Run Script), or
run headless:  blender --background --python build_character_locomotion.py
Requires Blender 4.x+ (verified on 5.1). Standard build, no add-ons needed.

What it does
------------
Retargets 4 clips (Idle_Loop, Walk_Loop, Jog_Fwd_Loop, Sprint_Loop) from
Quaternius's Universal Animation Library onto our characters' lightweight
5-bone rig (Hips, LeftUpperArm, RightUpperArm, LeftUpperLeg, RightUpperLeg),
and exports the result as a shared, mesh-free animation resource that every
character glb reuses at runtime (see player.gd) — so the retarget only has
to happen once, not per-character.

How the retarget works
-----------------------
1. Import assets/characters/char_fruit.glb, strip its meshes, keep only the
   CharFruit_Root armature (any character's armature works interchangeably
   here — only the 5 bone NAMES matter, not their exact rest length/position,
   because we only bake ROTATION per bone. Rotation-only world-space
   Copy Rotation constraint bakes are independent of the target bone's rest
   orientation and length; that's the entire point of world-space
   retargeting).
2. Import assets/animations/UAL1_Standard.glb (the source library, root
   motion NOT baked in). Its skeleton is UE-mannequin-style and already in a
   T-pose matching our rig's convention (arms horizontal along +/-X, legs
   hanging along -Z, character facing -Y) — confirmed by inspecting rest
   bone directions before writing this script.
3. Add a world-space Copy Rotation constraint from each of our 5 bones to
   its UE-named counterpart (pelvis, upperarm_l/r, thigh_l/r).
4. For each of the 4 desired clips: play it on the source armature, bake our
   armature's pose over that frame range (visual_keying=True so the
   constraint solve is baked into real keyframes), rename the resulting
   action to the clip name.
5. Deliberately do NOT bake Hips translation (no Copy Location constraint) —
   only rotation is retargeted. The source mannequin is ~1.65 Blender units
   tall vs. our ~1 unit fruit characters; copying its raw hip-bob offset
   verbatim would be wildly over-scaled for our characters. Losing the
   subtle hip-height bob is an acceptable trade for a stylized rigid-limb
   character — player.gd keeps a small procedural bob for extra juice
   instead of trying to rescale the mocap translation.
6. Remove the source armature + constraints, purge every action except the
   4 baked ones, and export ONLY the armature (no meshes) with all 4 actions
   to assets/animations/character_locomotion.glb.

In Godot, this file imports as a PackedScene with an AnimationPlayer holding
one AnimationLibrary with all 4 clips, keyed by bone NAME ("Hips",
"LeftUpperArm", ...). Because every character's own skeleton uses those same
5 bone names (see build_char_fruit.py and its 6 siblings), player.gd loads
this shared resource once and merges its AnimationLibrary onto each
character's own AnimationPlayer via add_animation_library() — no per-
character animation data duplicated in the individual char_*.glb files.
"""

import bpy
import os
from mathutils import Vector

PROJECT_ROOT = "/Users/zhihao/personal_projects/ropedart-arena"
CHAR_GLB = os.path.join(PROJECT_ROOT, "assets/characters/char_fruit.glb")
UAL_PATH = os.path.join(PROJECT_ROOT, "assets/animations/UAL1_Standard.glb")
OUT_PATH = os.path.join(PROJECT_ROOT, "assets/animations/character_locomotion.glb")

CLIPS = ["Idle_Loop", "Walk_Loop", "Jog_Fwd_Loop", "Sprint_Loop"]
BONE_MAP = {
    "Hips": "pelvis",
    "LeftUpperArm": "upperarm_l",
    "RightUpperArm": "upperarm_r",
    "LeftUpperLeg": "thigh_l",
    "RightUpperLeg": "thigh_r",
}

bpy.ops.wm.read_factory_settings(use_empty=True)
print("\n[Locomotion] === BUILD START ===")

# ---------------------------------------------------------------------------
# STEP 1 — Import a character rig, strip its meshes, keep the armature only.
# ---------------------------------------------------------------------------
bpy.ops.import_scene.gltf(filepath=CHAR_GLB)
armature_obj = None
for o in list(bpy.data.objects):
    if o.type == 'ARMATURE':
        armature_obj = o
        armature_obj.name = "CharFruit_Root"
    else:
        bpy.data.objects.remove(o, do_unlink=True)
if armature_obj is None:
    raise RuntimeError(f"No armature found in {CHAR_GLB}")
print(f"[Locomotion] Loaded rig from {CHAR_GLB}: "
      f"{[b.name for b in armature_obj.data.bones]}")

# ---------------------------------------------------------------------------
# STEP 2 — Import the UAL source library.
# ---------------------------------------------------------------------------
bpy.ops.import_scene.gltf(filepath=UAL_PATH)
source_arm = None
for o in bpy.data.objects:
    if o.type == 'ARMATURE' and o.name != "CharFruit_Root":
        source_arm = o
        break
if source_arm is None:
    raise RuntimeError(f"No armature found in {UAL_PATH}")
print(f"[Locomotion] Source armature: {source_arm.name}")

# Free up the plain clip names so baked actions can take them without a
# ".001" collision suffix; delete every other imported clip (39 of them —
# combat/sitting/swimming/etc — we don't need them).
for act in list(bpy.data.actions):
    if act.name in CLIPS:
        act.name = "SRC_" + act.name
    else:
        act.use_fake_user = False
        if act.users == 0:
            bpy.data.actions.remove(act)

# ---------------------------------------------------------------------------
# STEP 3 — World-space Copy Rotation constraints (retarget), our bone <- UAL bone.
# ---------------------------------------------------------------------------
bpy.context.view_layer.objects.active = armature_obj
bpy.ops.object.mode_set(mode='POSE')
for tgt_bone, src_bone in BONE_MAP.items():
    pb = armature_obj.pose.bones[tgt_bone]
    con = pb.constraints.new('COPY_ROTATION')
    con.name = "RetargetRot"
    con.target = source_arm
    con.subtarget = src_bone
    con.target_space = 'WORLD'
    con.owner_space = 'WORLD'
    con.mix_mode = 'REPLACE'
bpy.ops.object.mode_set(mode='OBJECT')
print("[Locomotion] Retarget constraints added (rotation only, world space)")

# ---------------------------------------------------------------------------
# STEP 4 — Bake each clip.
# ---------------------------------------------------------------------------
baked_actions = {}
for clip in CLIPS:
    src_action = bpy.data.actions.get("SRC_" + clip)
    if src_action is None:
        print(f"[Locomotion] WARNING: clip {clip!r} not found in source, skipping")
        continue
    source_arm.animation_data_create()
    source_arm.animation_data.action = src_action
    frame_start = int(src_action.frame_range[0])
    frame_end = int(round(src_action.frame_range[1]))
    bpy.context.scene.frame_start = frame_start
    bpy.context.scene.frame_end = frame_end

    bpy.ops.object.select_all(action='DESELECT')
    armature_obj.select_set(True)
    bpy.context.view_layer.objects.active = armature_obj

    bpy.ops.nla.bake(
        frame_start=frame_start,
        frame_end=frame_end,
        only_selected=False,
        visual_keying=True,
        clear_constraints=False,
        clear_parents=False,
        use_current_action=False,
        clean_curves=False,
        bake_types={'POSE'},
    )
    new_action = armature_obj.animation_data.action
    new_action.name = clip
    new_action.use_fake_user = True
    baked_actions[clip] = new_action
    print(f"[Locomotion] Baked {clip}: frames {frame_start}-{frame_end}")

# ---------------------------------------------------------------------------
# STEP 5 — Clean up: remove constraints + source armature, purge extra actions.
# ---------------------------------------------------------------------------
bpy.context.view_layer.objects.active = armature_obj
bpy.ops.object.mode_set(mode='POSE')
for pb in armature_obj.pose.bones:
    for c in list(pb.constraints):
        pb.constraints.remove(c)
bpy.ops.object.mode_set(mode='OBJECT')

bpy.ops.object.select_all(action='DESELECT')
for o in list(bpy.data.objects):
    if o != armature_obj:
        o.select_set(True)
if any(o.select_get() for o in bpy.data.objects):
    bpy.ops.object.delete()

kept_names = set(baked_actions[c].name for c in baked_actions)
for act in list(bpy.data.actions):
    if act.name in kept_names:
        continue
    act.use_fake_user = False
    if act.users == 0:
        bpy.data.actions.remove(act)

armature_obj.animation_data.action = None
print("[Locomotion] Cleanup done")

# ---------------------------------------------------------------------------
# STEP 6 — Export (armature + all 4 baked actions, no meshes).
# ---------------------------------------------------------------------------
os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
bpy.ops.object.select_all(action='DESELECT')
armature_obj.select_set(True)
bpy.context.view_layer.objects.active = armature_obj
bpy.ops.export_scene.gltf(
    filepath=OUT_PATH,
    export_format='GLB',
    use_selection=True,
    export_materials='NONE',
    export_animations=True,
    export_animation_mode='ACTIONS',
)
print(f"[Locomotion] Exported -> {OUT_PATH}")
print("[Locomotion] === BUILD COMPLETE ===\n")
