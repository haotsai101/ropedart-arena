"""
Rope Dart Arena — Kiwi Character Build
=======================================
Run headlessly:
  /Applications/Blender.app/Contents/MacOS/Blender --background --python \
    /Users/zhihao/personal_projects/ropedart-arena/assets/characters/build_char_kiwi.py

What it does
------------
1.  Deletes all existing CharKiwi_* objects / orphan data
2.  Builds a compact kiwi character with brown fuzzy body and green cross-section face
3.  Parents everything under CharKiwi_Root (Plain Axes empty at origin)
4.  Exports to  assets/characters/char_kiwi.glb

Character dimensions
--------------------
    Total height  : ~0.95 Blender units (feet at Z=0, body top ~Z=0.95)
    Body width    : 0.68 units (diameter in X, scale 0.34)
    Forward axis  : -Y (character faces -Y, matching Godot -Z after import)

Layout constants (Z stack, bottom → top)
-----------------------------------------
    0.000  ground / foot bottom
    0.048  foot centre
    0.140  leg centre
    0.550  body centre                        ← BZ
    0.515  mouth centre
    0.600  eye centre                         ← EZ
    0.670  brow centre
    0.950  body top  (BZ + BH = 0.55 + 0.40)

Face disc sits at Y = -(BY + 0.005) = -0.325
Expression layer (eyes, mouth, brows) at Y ≈ -0.341 (in front of disc)
"""

import bpy
import math
import os
import bmesh
from mathutils import Vector

# ===========================================================================
#  HELPERS  (identical pattern to build_char_fruit.py)
# ===========================================================================

def clear_char():
    """Remove every object / mesh / material starting with 'CharKiwi'."""
    bpy.ops.object.select_all(action='DESELECT')
    for o in list(bpy.data.objects):
        if o.name.startswith("CharKiwi"):
            o.select_set(True)
    if any(o.select_get() for o in bpy.data.objects):
        bpy.ops.object.delete()
    for m in list(bpy.data.meshes):
        if m.users == 0:
            bpy.data.meshes.remove(m)
    for m in list(bpy.data.materials):
        if m.users == 0 and m.name.startswith("CharKiwi"):
            bpy.data.materials.remove(m)


def mk_mat(name, rgba, roughness=0.85, specular=0.04):
    """Matte Principled BSDF material."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = rgba
    bsdf.inputs["Roughness"].default_value = roughness
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = specular
    elif "Specular" in bsdf.inputs:
        bsdf.inputs["Specular"].default_value = specular
    return mat


def set_mat(obj, mat):
    obj.data.materials.clear()
    obj.data.materials.append(mat)


def apply_scale(obj):
    """Bake scale into mesh data so mesh has correct real-world size."""
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)


def smooth(obj):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.shade_smooth()


# ===========================================================================
#  STEP 1 — CLEAR
# ===========================================================================
# Delete everything in the default scene before building
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)

clear_char()
parts = []   # all mesh/curve objects; parented to Root at end
print("\n[CharKiwi] === BUILD START ===")


# ===========================================================================
#  MATERIALS
# ===========================================================================
M = {}
# Body shell — brown fuzzy exterior
M['body']   = mk_mat("CharKiwi_M_Body",   (0.42, 0.26, 0.12, 1.0), roughness=0.95, specular=0.01)
M['dark']   = mk_mat("CharKiwi_M_Dark",   (0.28, 0.68, 0.16, 1.0), roughness=0.85, specular=0.01)   # bright flesh-green limb accent: arms/legs/feet
M['mitten'] = mk_mat("CharKiwi_M_Mitten", (0.34, 0.74, 0.20, 1.0), roughness=0.85, specular=0.01)   # lighter flesh-green for hands
# Face disc layers
M['flesh']  = mk_mat("CharKiwi_M_Flesh",  (0.30, 0.72, 0.18, 1.0), roughness=0.80)   # bright green
M['center'] = mk_mat("CharKiwi_M_Center", (0.94, 0.94, 0.90, 1.0), roughness=0.75, specular=0.05)   # white center
M['seed']   = mk_mat("CharKiwi_M_Seed",   (0.06, 0.06, 0.06, 1.0), roughness=0.90)   # black seeds
# Expression (on green face)
M['white']  = mk_mat("CharKiwi_M_White",  (0.95, 0.95, 0.95, 1.0), roughness=0.55, specular=0.12)   # sclera
M['pupil']  = mk_mat("CharKiwi_M_Pupil",  (0.04, 0.04, 0.04, 1.0))
M['brow']   = mk_mat("CharKiwi_M_Brow",   (0.08, 0.04, 0.02, 1.0))   # dark brown eyebrow
M['mouth']  = mk_mat("CharKiwi_M_Mouth",  (0.06, 0.34, 0.04, 1.0), roughness=0.85)   # dark green smile


# ===========================================================================
#  LAYOUT CONSTANTS
# ===========================================================================
BZ  = 0.550   # body Z centre
BRX = 0.340   # body X half-extent  (scale X)
BY  = 0.320   # body Y half-extent  (scale Y)
BH  = 0.400   # body Z half-height  (scale Z)

EYE_X = 0.110   # lateral eye centre — closer together → sweet, cute look
EZ    = 0.600   # eye Z centre
BEZ   = 0.670   # brow Z centre

# Face disc geometry
FACE_DISC_DEPTH = 0.016
FACE_DISC_Y     = -(BY + 0.005)                    # = -0.325  disc centre Y
FACE_FRONT_Y    = FACE_DISC_Y - FACE_DISC_DEPTH / 2  # = -0.333  front face of disc

# Expression layer — slightly proud of disc face so elements appear in front
EXPR_Y = FACE_FRONT_Y - 0.006   # ≈ -0.339


# ===========================================================================
#  STEP 2 — BODY
#  Compact oval: slightly taller than wide.
#  The 'CharKiwi_Body' name is the one player.gd color-tints.
# ===========================================================================
bpy.ops.mesh.primitive_uv_sphere_add(
    radius=1.0, segments=20, ring_count=14,
    location=(0, 0, BZ)
)
body = bpy.context.active_object
body.name = "CharKiwi_Body"
body.scale = (BRX, BY, BH)
apply_scale(body)
smooth(body)
set_mat(body, M['body'])
parts.append(body)
print("[CharKiwi] Body ✓")


# ===========================================================================
#  STEP 3 — FACE DISC  (kiwi cross-section, facing -Y)
#
#  Cylinder rotated pi/2 around X:
#    local +Z (top) → world -Y  ← this becomes the visible front face
#    local -Z (bot) → world +Y
#  Disc centre at FACE_DISC_Y; front face at FACE_FRONT_Y = FACE_DISC_Y - depth/2.
#  Radius 0.22 fills the kiwi body face width comfortably.
# ===========================================================================
bpy.ops.mesh.primitive_cylinder_add(
    radius=0.22, depth=FACE_DISC_DEPTH,
    location=(0, FACE_DISC_Y, BZ),
    rotation=(math.pi / 2, 0, 0)
)
face_disc = bpy.context.active_object
face_disc.name = "CharKiwi_FaceDisc"
smooth(face_disc)
set_mat(face_disc, M['flesh'])
parts.append(face_disc)
print("[CharKiwi] Face disc ✓")


# ===========================================================================
#  STEP 4 — WHITE CENTER DISC
#  Tiny cylinder at same orientation, offset slightly forward so it sits
#  on top of the green flesh.
# ===========================================================================
WHITE_Y = FACE_DISC_Y - 0.010   # = -0.335, clearly in front of disc back face

bpy.ops.mesh.primitive_cylinder_add(
    radius=0.045, depth=0.018,
    location=(0, WHITE_Y, BZ),
    rotation=(math.pi / 2, 0, 0)
)
center_disc = bpy.context.active_object
center_disc.name = "CharKiwi_CenterDisc"
smooth(center_disc)
set_mat(center_disc, M['center'])
parts.append(center_disc)
print("[CharKiwi] Center disc ✓")


# ===========================================================================
#  STEP 5 — SEEDS  (10 black ovals in a ring at radius 0.14)
#
#  Seed ring lives on the XZ plane centred at (0, SEED_Y, BZ).
#  Each seed is a flattened UV sphere: scale (0.018, 0.008, 0.032).
#    x=0.018  narrow perpendicular width
#    y=0.008  thin  → flat against disc face
#    z=0.032  elongated axis
#  After rotation_euler[1] = a the elongated axis points radially outward:
#    Rotation around world Y by a maps local +Z to (sin a, 0, cos a).
# ===========================================================================
N_SEEDS    = 10
SEED_RING_R = 0.140
SEED_Y      = FACE_DISC_Y - 0.008   # = -0.333, flush with disc front face

for i in range(N_SEEDS):
    a  = i * (2.0 * math.pi / N_SEEDS)
    sx = SEED_RING_R * math.sin(a)
    sz = BZ + SEED_RING_R * math.cos(a)

    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=6, ring_count=4,
        location=(sx, SEED_Y, sz)
    )
    sd = bpy.context.active_object
    sd.name = f"CharKiwi_Seed_{i}"
    sd.scale = (0.018, 0.008, 0.032)
    apply_scale(sd)
    # Tilt so elongation (was Z) now points radially outward in XZ plane
    sd.rotation_euler[1] = a
    smooth(sd)
    set_mat(sd, M['seed'])
    parts.append(sd)

print("[CharKiwi] Seeds ✓")


# ===========================================================================
#  STEP 6 — EYES  (on the green flesh, curious wide ovals)
#
#  Sclera scale: (0.078, 0.022, 0.115) — slightly rounder than char_fruit
#  EYE_X = 0.110 (closer together than char_fruit's 0.135 → sweeter look)
#  Expression layer sits at EXPR_Y ≈ -0.339, clearly in front of disc.
# ===========================================================================
for sx, suf in [(-EYE_X, 'L'), (EYE_X, 'R')]:

    # Sclera (white)
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=14, ring_count=10,
        location=(sx, EXPR_Y, EZ)
    )
    sc = bpy.context.active_object
    sc.name = f"CharKiwi_Eye_{suf}"
    sc.scale = (0.078, 0.022, 0.115)
    apply_scale(sc)
    smooth(sc)
    set_mat(sc, M['white'])
    parts.append(sc)

    # Pupil (dark, slightly proud of sclera)
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(sx, EXPR_Y - 0.006, EZ)
    )
    pu = bpy.context.active_object
    pu.name = f"CharKiwi_Pupil_{suf}"
    pu.scale = (0.046, 0.018, 0.072)
    apply_scale(pu)
    smooth(pu)
    set_mat(pu, M['pupil'])
    parts.append(pu)

    # Highlight dot (upper-inner quadrant of pupil — toward centre X)
    inner_sign = 1 if suf == 'L' else -1
    hl_x = sx + inner_sign * 0.018
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=6, ring_count=4,
        location=(hl_x, EXPR_Y - 0.010, EZ + 0.028)
    )
    hl = bpy.context.active_object
    hl.name = f"CharKiwi_EyeHL_{suf}"
    hl.scale = (0.018, 0.010, 0.026)
    apply_scale(hl)
    smooth(hl)
    set_mat(hl, M['white'])
    parts.append(hl)

print("[CharKiwi] Eyes ✓")


# ===========================================================================
#  STEP 7 — EYEBROWS  (thin cubes, 10° outward tilt → curious/gentle)
#
#  "Outward" tilt: outer end rises, inner end dips → curious look.
#  sign = -1 (L) or +1 (R); rotation_euler[2] = -10 * sign gives:
#    L brow: +10° (counterclockwise)  outer(-X) end up
#    R brow: -10° (clockwise)         outer(+X) end up
#  rotation_euler[0] = 6° → slight forward lean so brow reads cleanly from front.
# ===========================================================================
for sx, suf, sign in [(-EYE_X, 'L', -1), (EYE_X, 'R', 1)]:
    bpy.ops.mesh.primitive_cube_add(
        size=1.0,
        location=(sx, EXPR_Y - 0.002, BEZ)
    )
    brow = bpy.context.active_object
    brow.name = f"CharKiwi_Brow_{suf}"
    brow.scale = (0.064, 0.011, 0.018)
    apply_scale(brow)
    brow.rotation_euler[0] = math.radians(6)           # forward lean
    brow.rotation_euler[2] = math.radians(-10 * sign)  # outward tilt
    set_mat(brow, M['brow'])
    parts.append(brow)

print("[CharKiwi] Eyebrows ✓")


# ===========================================================================
#  STEP 8 — MOUTH  (gentle smile — half-torus ∪)
#
#  Smaller/softer than char_fruit: major_radius=0.042, minor_radius=0.010.
#  Full torus, rotation=(pi/2,0,0) so ring lies in world XZ plane.
#  Delete local Y > 0 vertices to keep the bottom arc (∪ smile).
#
#  Rotation maths (rotate pi/2 around X):
#    local +Y → world +Z   (upper arc, deleted)
#    local -Y → world -Z   (lower arc = ∪ smile, kept)
# ===========================================================================
MOUTH_Z = 0.515   # slightly below body / disc centre
MOUTH_Y = EXPR_Y - 0.002

bpy.ops.mesh.primitive_torus_add(
    major_radius=0.042,
    minor_radius=0.010,
    major_segments=24,
    minor_segments=8,
    location=(0, MOUTH_Y, MOUTH_Z),
    rotation=(math.pi / 2, 0, 0)
)
mth = bpy.context.active_object
mth.name = "CharKiwi_Mouth"

bpy.context.view_layer.objects.active = mth
bpy.ops.object.mode_set(mode='EDIT')
bm2 = bmesh.from_edit_mesh(mth.data)
to_del = [v for v in bm2.verts if v.co.y > 0.002]
bmesh.ops.delete(bm2, geom=to_del, context='VERTS')
bmesh.update_edit_mesh(mth.data)
bpy.ops.object.mode_set(mode='OBJECT')

smooth(mth)
set_mat(mth, M['mouth'])
parts.append(mth)
print("[CharKiwi] Mouth ✓")


# ===========================================================================
#  STEP 9 — ARMS  (floating cylinder + mitten, brown tones)
#
#  Arms float just clear of the body edge (gap = 0.018).
#  Cylinder orientation: rotation=(0, pi/2, 0) → local Z becomes world X,
#  so the cylinder extends horizontally in X (arm pointing outward).
#  Mitten hand: rounded blob slightly past the arm end.
# ===========================================================================
ARM_Z    = BZ - 0.030   # slightly below body equator for natural hang
ARM_GAP  = 0.018
ARM_HALF = 0.058        # half the arm cylinder depth

for sign, suf in [(-1, 'L'), (1, 'R')]:
    cx = sign * (BRX + ARM_GAP + ARM_HALF)

    bpy.ops.mesh.primitive_cylinder_add(
        radius=0.040, depth=0.116,
        location=(cx, 0, ARM_Z),
        rotation=(0, math.pi / 2, 0)
    )
    arm = bpy.context.active_object
    arm.name = f"CharKiwi_Arm_{suf}"
    smooth(arm)
    set_mat(arm, M['dark'])
    parts.append(arm)

    mit_x = sign * (BRX + ARM_GAP + ARM_HALF * 2 + 0.020)
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(mit_x, 0, ARM_Z - 0.010)
    )
    mit = bpy.context.active_object
    mit.name = f"CharKiwi_Mitten_{suf}"
    mit.scale = (0.070, 0.058, 0.055)
    apply_scale(mit)
    smooth(mit)
    set_mat(mit, M['mitten'])
    parts.append(mit)

print("[CharKiwi] Arms ✓")


# ===========================================================================
#  STEP 10 — LEGS AND FEET
#
#  Two stubby cylinders under the body, angled slightly outward.
#  Foot nubs: flattened spheres, bottom at Z=0 (ground level).
# ===========================================================================
LEG_X  = 0.100   # lateral offset (body narrower than fruit, so smaller)
LEG_Z  = 0.140   # leg centre Z
FOOT_Z = 0.048   # foot centre (scale Z=0.048 → bottom at 0)

for sign, suf in [(-1, 'L'), (1, 'R')]:
    lx = sign * LEG_X

    bpy.ops.mesh.primitive_cylinder_add(
        radius=0.052, depth=0.090,
        location=(lx, 0.008, LEG_Z),
        rotation=(math.radians(4 * sign), 0, 0)   # slight outward tilt
    )
    leg = bpy.context.active_object
    leg.name = f"CharKiwi_Leg_{suf}"
    smooth(leg)
    set_mat(leg, M['dark'])
    parts.append(leg)

    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(lx, 0.018, FOOT_Z)
    )
    foot = bpy.context.active_object
    foot.name = f"CharKiwi_Foot_{suf}"
    foot.scale = (0.072, 0.054, 0.048)
    apply_scale(foot)
    smooth(foot)
    set_mat(foot, M['dark'])
    parts.append(foot)

print("[CharKiwi] Legs ✓")


# ===========================================================================
#  ARMATURE (replaces plain-empty root) — 5 bones: Hips + 4 limb bones,
#  matching Godot's canonical humanoid names so retargeted UAL locomotion
#  clips apply directly. See assets/characters/build_char_fruit.py for the
#  original prototype and assets/animations/build_character_locomotion.py
#  for the shared retarget bake.
# ===========================================================================
bpy.ops.object.armature_add(enter_editmode=True, location=(0, 0, 0))
root = bpy.context.active_object
root.name = "CharKiwi" + "_Root"
arm_data = root.data
arm_data.name = "CharKiwi" + "_Skeleton"

eb = arm_data.edit_bones
for b in list(eb):
    eb.remove(b)

hips = eb.new("Hips")
hips.head = Vector((0, 0, BZ - BH * 0.3))
hips.tail = Vector((0, 0, BZ + BH * 0.3))

sign = -1
lua = eb.new("LeftUpperArm")
lua.head = Vector((sign * (BRX + ARM_GAP + ARM_HALF), 0, ARM_Z))
lua.tail = Vector((sign * (BRX + ARM_GAP + ARM_HALF * 2), 0, ARM_Z))
lua.parent = hips
lua.use_connect = False

lul = eb.new("LeftUpperLeg")
lul.head = Vector((sign * LEG_X, 0, LEG_Z + 0.05))
lul.tail = Vector((sign * LEG_X, 0, FOOT_Z))
lul.parent = hips
lul.use_connect = False

sign = 1
rua = eb.new("RightUpperArm")
rua.head = Vector((sign * (BRX + ARM_GAP + ARM_HALF), 0, ARM_Z))
rua.tail = Vector((sign * (BRX + ARM_GAP + ARM_HALF * 2), 0, ARM_Z))
rua.parent = hips
rua.use_connect = False

rul = eb.new("RightUpperLeg")
rul.head = Vector((sign * LEG_X, 0, LEG_Z + 0.05))
rul.tail = Vector((sign * LEG_X, 0, FOOT_Z))
rul.parent = hips
rul.use_connect = False

bpy.ops.object.mode_set(mode='OBJECT')
print("[" + "CharKiwi" + "] Armature done (Hips, LeftUpperArm, RightUpperArm, LeftUpperLeg, RightUpperLeg)")


def bone_parent_group(objs, bone_name):
    """Rigidly bone-parent (Object > Parent > Bone) — NOT an Armature modifier
    or vertex groups, since every limb here is a single rigid mesh piece."""
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    root.select_set(True)
    bpy.context.view_layer.objects.active = root
    root.data.bones.active = root.data.bones[bone_name]
    bpy.ops.object.parent_set(type='BONE', keep_transform=True)


by_name = {p.name: p for p in parts}
limb_names = {
    "LeftUpperArm":  ["CharKiwi" + "_Arm_L", "CharKiwi" + "_Mitten_L"],
    "RightUpperArm": ["CharKiwi" + "_Arm_R", "CharKiwi" + "_Mitten_R"],
    "LeftUpperLeg":  ["CharKiwi" + "_Leg_L", "CharKiwi" + "_Foot_L"],
    "RightUpperLeg": ["CharKiwi" + "_Leg_R", "CharKiwi" + "_Foot_R"],
}
limb_parts = set()
for bone_name, names in limb_names.items():
    objs = [by_name[n] for n in names if n in by_name]
    limb_parts.update(objs)
    bone_parent_group(objs, bone_name)

hips_parts = [p for p in parts if p not in limb_parts]
bone_parent_group(hips_parts, "Hips")

print("[" + "CharKiwi" + "] Bone-parented " + str(len(parts)) + " parts -> " + "CharKiwi" + "_Root skeleton")


# ===========================================================================
#  EXPORT GLB — rig + rest pose only, no animation data (shared locomotion
#  clips are merged onto the AnimationPlayer at runtime by player.gd).
# ===========================================================================
out = "/Users/zhihao/personal_projects/ropedart-arena/assets/characters/char_kiwi.glb"
os.makedirs(os.path.dirname(out), exist_ok=True)

bpy.ops.object.select_all(action='DESELECT')
for p in parts:
    p.select_set(True)
root.select_set(True)

bpy.ops.export_scene.gltf(
    filepath=out,
    export_format='GLB',
    use_selection=True,
    export_materials='EXPORT',
    export_animations=False,
)

print("[" + "CharKiwi" + "] Exported -> " + out)
