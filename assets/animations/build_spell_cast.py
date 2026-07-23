"""
Rope Dart Arena — Spell-Cast (Throw/Recall) Animation Builder
================================================================
Retargets Spell_Simple_Enter / Spell_Simple_Idle_Loop / Spell_Simple_Exit from
Quaternius's Universal Animation Library (UAL1_Standard.glb, UE-mannequin-style
skeleton) onto a bare Rig_Medium armature (KayKit Adventurers' shared rig),
via world-space Copy Rotation constraints -- same technique as
build_character_locomotion.py (fruit rig, 5 bones) and the combat_moves.glb
retarget (Rig_Medium, ~20-bone map per that commit's own description, never
saved to disk), just with the bone map reconstructed fresh for this pass (16
bones: hips/spine/chest/head + both arms + both legs -- see BONE_MAP below).

Exported as a SEPARATE new asset (assets/animations/spell_cast.glb) rather
than appended into the existing combat_moves.glb, to avoid touching a file
whose 5 existing clips were already tested/working -- player.gd's
_setup_animation() already merges every ANIM_SOURCES file into one shared
AnimationLibrary, so a second small file works identically to appending into
the first.

Run headless (this is how it was actually run -- the interactive Blender MCP
bridge crashed with a bpy.context.object AttributeError deep inside Blender's
own glTF importer while loading UAL1_Standard.glb, reproducible outside any
temp_override; headless mode sidesteps that context-dependent code path
entirely):

    blender --background --python build_spell_cast.py

Requires Blender 4.x+ (verified on 5.1). Standard build, no add-ons needed.
"""

import bpy
import os

PROJECT_ROOT = "/Users/zhihao/personal_projects/ropedart-arena"
RIG_PATH = os.path.join(PROJECT_ROOT, "assets/kaykit_adventurers/animations/Rig_Medium_General.glb")
UAL_PATH = os.path.join(PROJECT_ROOT, "assets/animations/UAL1_Standard.glb")
OUT_PATH = os.path.join(PROJECT_ROOT, "assets/animations/spell_cast.glb")

CLIPS = ["Spell_Simple_Enter", "Spell_Simple_Idle_Loop", "Spell_Simple_Exit"]

# target Rig_Medium bone -> source UAL (UE-mannequin) bone
BONE_MAP = {
    "hips": "pelvis",
    "spine": "spine_02",
    "chest": "spine_03",
    "head": "Head",
    "upperarm.l": "upperarm_l",
    "lowerarm.l": "lowerarm_l",
    "hand.l": "hand_l",
    "upperarm.r": "upperarm_r",
    "lowerarm.r": "lowerarm_r",
    "hand.r": "hand_r",
    "upperleg.l": "thigh_l",
    "lowerleg.l": "calf_l",
    "foot.l": "foot_l",
    "upperleg.r": "thigh_r",
    "lowerleg.r": "calf_r",
    "foot.r": "foot_r",
}

bpy.ops.wm.read_homefile(use_empty=True, use_factory_startup=True)
print("\n[SpellCast] === BUILD START ===")

# ---------------------------------------------------------------------------
# STEP 1 -- Import the Rig_Medium armature (strip its mesh, keep skeleton).
# ---------------------------------------------------------------------------
bpy.ops.import_scene.gltf(filepath=RIG_PATH)
rig_arm = None
for o in list(bpy.data.objects):
    if o.type == 'ARMATURE':
        rig_arm = o
    else:
        bpy.data.objects.remove(o, do_unlink=True)
if rig_arm is None:
    raise RuntimeError(f"No armature found in {RIG_PATH}")
if rig_arm.name != "Rig_Medium":
    raise RuntimeError(f"Expected armature named Rig_Medium, got {rig_arm.name!r}")
print(f"[SpellCast] Loaded rig: {rig_arm.name} ({len(rig_arm.data.bones)} bones)")

# Rig_Medium_General.glb is itself a multi-clip animation library (Idle_A,
# Death_A, ...) -- the importer pushes every non-active clip down into NLA
# tracks, which keeps their actions' real user-count above 0 even after
# use_fake_user is cleared, so the later "remove if users == 0" purge below
# would silently miss them and they'd leak into the export. Clearing
# animation_data here severs the NLA tracks/active-action link so every one
# of those pre-existing actions becomes a true orphan and gets swept up by
# that same purge, leaving only the 3 clips this script actually bakes.
rig_arm.animation_data_clear()
for act in list(bpy.data.actions):
    act.use_fake_user = False
    if act.users == 0:
        bpy.data.actions.remove(act)
print(f"[SpellCast] Purged Rig_Medium_General's own clips; {len(bpy.data.actions)} action(s) remain")

# ---------------------------------------------------------------------------
# STEP 2 -- Import the UAL source library.
# ---------------------------------------------------------------------------
bpy.ops.import_scene.gltf(filepath=UAL_PATH)
source_arm = None
for o in bpy.data.objects:
    if o.type == 'ARMATURE' and o != rig_arm:
        source_arm = o
        break
if source_arm is None:
    raise RuntimeError(f"No armature found in {UAL_PATH}")
print(f"[SpellCast] Source armature: {source_arm.name}")

# Free up the plain clip names so baked actions can take them without a
# ".001" collision suffix; drop every other imported action (this UAL file
# has ~50 clips, we only need 3).
for act in list(bpy.data.actions):
    if act.name in CLIPS:
        act.name = "SRC_" + act.name
    else:
        act.use_fake_user = False
        if act.users == 0:
            bpy.data.actions.remove(act)

for clip in CLIPS:
    if bpy.data.actions.get("SRC_" + clip) is None:
        raise RuntimeError(f"Source clip {clip!r} not found in {UAL_PATH}")

# ---------------------------------------------------------------------------
# STEP 3 -- World-space Copy Rotation constraints (retarget), our bone <- UAL bone.
# ---------------------------------------------------------------------------
bpy.context.view_layer.objects.active = rig_arm
bpy.ops.object.mode_set(mode='POSE')
for tgt_bone, src_bone in BONE_MAP.items():
    pb = rig_arm.pose.bones.get(tgt_bone)
    if pb is None:
        raise RuntimeError(f"Target bone {tgt_bone!r} not found on Rig_Medium")
    if src_bone not in source_arm.pose.bones:
        raise RuntimeError(f"Source bone {src_bone!r} not found on {source_arm.name}")
    con = pb.constraints.new('COPY_ROTATION')
    con.name = "RetargetRot"
    con.target = source_arm
    con.subtarget = src_bone
    con.target_space = 'WORLD'
    con.owner_space = 'WORLD'
    con.mix_mode = 'REPLACE'
bpy.ops.object.mode_set(mode='OBJECT')
print(f"[SpellCast] Retarget constraints added for {len(BONE_MAP)} bones (rotation only, world space)")

# ---------------------------------------------------------------------------
# STEP 4 -- Bake each clip.
# ---------------------------------------------------------------------------
baked_actions = {}
for clip in CLIPS:
    src_action = bpy.data.actions.get("SRC_" + clip)
    source_arm.animation_data_create()
    source_arm.animation_data.action = src_action
    frame_start = int(src_action.frame_range[0])
    frame_end = int(round(src_action.frame_range[1]))
    bpy.context.scene.frame_start = frame_start
    bpy.context.scene.frame_end = frame_end

    bpy.ops.object.select_all(action='DESELECT')
    rig_arm.select_set(True)
    bpy.context.view_layer.objects.active = rig_arm

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
    new_action = rig_arm.animation_data.action
    new_action.name = clip
    new_action.use_fake_user = True
    baked_actions[clip] = new_action
    print(f"[SpellCast] Baked {clip}: frames {frame_start}-{frame_end}")

# ---------------------------------------------------------------------------
# STEP 5 -- Clean up: remove constraints + source armature, purge extra actions.
# ---------------------------------------------------------------------------
bpy.context.view_layer.objects.active = rig_arm
bpy.ops.object.mode_set(mode='POSE')
for pb in rig_arm.pose.bones:
    for c in list(pb.constraints):
        pb.constraints.remove(c)
bpy.ops.object.mode_set(mode='OBJECT')

bpy.ops.object.select_all(action='DESELECT')
for o in list(bpy.data.objects):
    if o != rig_arm:
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

rig_arm.animation_data.action = None
print("[SpellCast] Cleanup done")

# ---------------------------------------------------------------------------
# STEP 6 -- Export (armature + all 3 baked actions, no meshes).
# ---------------------------------------------------------------------------
os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
bpy.ops.object.select_all(action='DESELECT')
rig_arm.select_set(True)
bpy.context.view_layer.objects.active = rig_arm
bpy.ops.export_scene.gltf(
    filepath=OUT_PATH,
    export_format='GLB',
    use_selection=True,
    export_materials='NONE',
    export_animations=True,
    export_animation_mode='ACTIONS',
)
print(f"[SpellCast] Exported -> {OUT_PATH}")
print("[SpellCast] === BUILD COMPLETE ===\n")
