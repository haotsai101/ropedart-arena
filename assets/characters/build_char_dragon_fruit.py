"""
Rope Dart Arena — Dragon Fruit Character Build
===============================================
Paste this entire file into Blender's Script Editor (Text → Run Script).
Requires Blender 4.x. Standard build, no add-ons needed.

What it does
------------
1.  Deletes all existing CharDragonFruit_* objects / orphan data
2.  Rebuilds the character from scratch
3.  Parents everything under CharDragonFruit_Root (Plain Axes empty at origin)
4.  Exports to  assets/characters/char_dragon_fruit.glb

Character dimensions
--------------------
    Total height  : ~1.10 Blender units (feet at Z=0, fin tips ~Z=1.10)
    Body width    : 0.76 units (diameter)
    Forward axis  : -Y (character faces -Y, matching Godot -Z after import)
"""

import bpy
import math
import os
import bmesh
from mathutils import Vector

# ===========================================================================
#  HELPERS
# ===========================================================================

def clear_char():
    """Remove every object / mesh / material starting with 'CharDragonFruit'."""
    bpy.ops.object.select_all(action='DESELECT')
    for o in list(bpy.data.objects):
        if o.name.startswith("CharDragonFruit"):
            o.select_set(True)
    if any(o.select_get() for o in bpy.data.objects):
        bpy.ops.object.delete()
    for m in list(bpy.data.meshes):
        if m.users == 0:
            bpy.data.meshes.remove(m)
    for m in list(bpy.data.materials):
        if m.users == 0 and m.name.startswith("CharDragonFruit"):
            bpy.data.materials.remove(m)


def mk_mat(name, rgba, roughness=0.85, specular=0.04):
    """Matte painted-vinyl Principled BSDF material."""
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
parts = []
print("\n[CharDragonFruit] === BUILD START ===")


# ===========================================================================
#  MATERIALS
# ===========================================================================
M = {}
M['body']    = mk_mat("CharDragonFruit_M_Body",    (0.85, 0.05, 0.45, 1.0))           # bright magenta
M['dark']    = mk_mat("CharDragonFruit_M_Dark",    (0.12, 0.55, 0.10, 1.0))           # fin-green limb accent: arms/legs/feet
M['mitten']  = mk_mat("CharDragonFruit_M_Mitten",  (0.16, 0.60, 0.14, 1.0))           # lighter fin-green for hands
M['fin']     = mk_mat("CharDragonFruit_M_Fin",     (0.10, 0.55, 0.08, 1.0))           # green fins
M['face']    = mk_mat("CharDragonFruit_M_Face",    (0.95, 0.95, 0.92, 1.0),
                       roughness=0.55, specular=0.10)                                   # white face patch
M['seed']    = mk_mat("CharDragonFruit_M_Seed",    (0.05, 0.05, 0.05, 1.0))           # black seed dots
M['white']   = mk_mat("CharDragonFruit_M_White",   (0.95, 0.95, 0.95, 1.0),
                       roughness=0.55, specular=0.12)                                   # eye sclera
M['pupil']   = mk_mat("CharDragonFruit_M_Pupil",   (0.04, 0.04, 0.04, 1.0))           # pupils
M['brow']    = mk_mat("CharDragonFruit_M_Brow",    (0.04, 0.04, 0.04, 1.0))           # eyebrows
M['mouth']   = mk_mat("CharDragonFruit_M_Mouth",   (0.22, 0.04, 0.12, 1.0))           # mouth / grin


# ===========================================================================
#  LAYOUT CONSTANTS
#
#  Z stack (bottom to top)
#    0.000  ground / foot bottom
#    0.048  foot centre
#    0.140  leg centre
#    0.580  body centre         <- BZ
#    0.660  face patch centre
#    0.700  eye centre          <- EZ
#    0.806  brow centre
#    0.940  fin equator base
#    1.060  fin crown tips
# ===========================================================================
BZ  = 0.580   # body Z centre
BR  = 0.380   # body XY radius
BH  = 0.460   # body half-height (slightly taller than strawberry)
EZ  = 0.700   # eye Z
FY  = -0.360  # face front Y


def body_surface_y(x, z):
    """
    Y coordinate of the front face of the body ellipsoid at world (x, z).
    Slightly inset (0.008 units) to avoid z-fighting.
    """
    tz = (z - BZ) / BH
    tx = x / BR
    under = max(0.0, 1.0 - tz * tz - tx * tx)
    return -BR * math.sqrt(under) - 0.008


# ===========================================================================
#  STEP 2 — BODY
#  Rounded oval, slightly wider at bottom. UV sphere scaled (0.38, 0.38, 0.46).
# ===========================================================================
bpy.ops.mesh.primitive_uv_sphere_add(
    radius=1.0, segments=20, ring_count=14,
    location=(0, 0, BZ)
)
body = bpy.context.active_object
body.name = "CharDragonFruit_Body"
body.scale = (BR, BR, BH)
apply_scale(body)
smooth(body)
set_mat(body, M['body'])
parts.append(body)
print("[CharDragonFruit] Body done")


# ===========================================================================
#  STEP 3 — GREEN FIN SCALES (8 fins around the equator)
#
#  Each fin is a flattened, teardrop-like cone:
#    radius1=0.085 (base), radius2=0.005 (tip), depth=0.24
#  Placed at body equator height, angled outward 25 degrees from horizontal,
#  tips curling slightly upward.
#
#  Additionally 4 crown fins on top, angled steeper (55 deg from Z) for the
#  iconic dragon-fruit crown silhouette.
# ===========================================================================

# Equatorial fins — 8 evenly spaced
NUM_EQ_FINS = 8
EQ_FIN_Z    = BZ + 0.05    # slightly above body equator
EQ_TILT     = math.radians(65)   # 65 deg from Z (almost horizontal, tips outward)
EQ_DEPTH    = 0.24
EQ_HALF     = EQ_DEPTH * 0.5

for i in range(NUM_EQ_FINS):
    a = i * (2.0 * math.pi / NUM_EQ_FINS)
    d = Vector((
        math.sin(EQ_TILT) * math.cos(a),
        math.sin(EQ_TILT) * math.sin(a),
        math.cos(EQ_TILT)
    ))
    # Place cone so its base is at the body surface, tip points outward
    base_pt = Vector((math.cos(a) * BR * 0.85, math.sin(a) * BR * 0.85, EQ_FIN_Z))
    centre  = base_pt + d * EQ_HALF

    bpy.ops.mesh.primitive_cone_add(
        radius1=0.085, radius2=0.006, depth=EQ_DEPTH,
        location=(centre.x, centre.y, centre.z)
    )
    fin = bpy.context.active_object
    fin.name = f"CharDragonFruit_Fin_{i}"
    q = Vector((0, 0, 1)).rotation_difference(d)
    fin.rotation_mode = 'QUATERNION'
    fin.rotation_quaternion = q
    # Flatten the fins (squash in the plane perpendicular to d)
    # Apply a local scale after orientation — flatten along local Y
    fin.scale = (1.0, 0.35, 1.0)
    apply_scale(fin)
    smooth(fin)
    set_mat(fin, M['fin'])
    parts.append(fin)

# Crown fins — 5 fins at the top, steeper angle
NUM_CR_FINS = 5
CR_BASE_Z   = BZ + BH - 0.04   # near body top
CR_TILT     = math.radians(42)
CR_DEPTH    = 0.20
CR_HALF     = CR_DEPTH * 0.5

for i in range(NUM_CR_FINS):
    a = i * (2.0 * math.pi / NUM_CR_FINS) + math.pi / NUM_CR_FINS  # offset from equatorial
    d = Vector((
        math.sin(CR_TILT) * math.cos(a),
        math.sin(CR_TILT) * math.sin(a),
        math.cos(CR_TILT)
    ))
    base_pt = Vector((0, 0, CR_BASE_Z))
    centre  = base_pt + d * CR_HALF

    bpy.ops.mesh.primitive_cone_add(
        radius1=0.065, radius2=0.005, depth=CR_DEPTH,
        location=(centre.x, centre.y, centre.z)
    )
    fin = bpy.context.active_object
    fin.name = f"CharDragonFruit_CrownFin_{i}"
    q = Vector((0, 0, 1)).rotation_difference(d)
    fin.rotation_mode = 'QUATERNION'
    fin.rotation_quaternion = q
    fin.scale = (1.0, 0.35, 1.0)
    apply_scale(fin)
    smooth(fin)
    set_mat(fin, M['fin'])
    parts.append(fin)

print("[CharDragonFruit] Fins done")


# ===========================================================================
#  STEP 4 — WHITE FACE PATCH
#  Flattened sphere overlay on the front (-Y side) of the body.
#  Covers the central face area where eyes, mouth, seeds will go.
# ===========================================================================
FACE_Z = BZ + 0.02    # slightly above body centre
FACE_Y = body_surface_y(0, FACE_Z) - 0.005   # sit just in front of body surface

bpy.ops.mesh.primitive_uv_sphere_add(
    radius=1.0, segments=16, ring_count=12,
    location=(0, FACE_Y, FACE_Z)
)
face_patch = bpy.context.active_object
face_patch.name = "CharDragonFruit_FacePatch"
face_patch.scale = (0.26, 0.04, 0.30)
apply_scale(face_patch)
smooth(face_patch)
set_mat(face_patch, M['face'])
parts.append(face_patch)
print("[CharDragonFruit] Face patch done")


# ===========================================================================
#  STEP 5 — SEED DOTS (6 black dots on the face patch)
#  Small flattened spheres scattered across the white face patch.
# ===========================================================================
SEED_CONFIGS = [
    ( 0.000,  0.790),   # top centre
    (-0.110,  0.680),   # upper-left
    ( 0.110,  0.680),   # upper-right
    (-0.145,  0.545),   # mid-left
    ( 0.145,  0.545),   # mid-right
    ( 0.000,  0.460),   # lower centre
]

for i, (sx, sz) in enumerate(SEED_CONFIGS):
    # Only place seeds within the face patch boundary (rough ellipse check)
    if abs(sx) / 0.26 ** 2 + ((sz - FACE_Z) / 0.30) ** 2 > 0.95:
        continue
    sy = body_surface_y(sx, sz) - 0.010   # slightly in front of face patch
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=6, ring_count=4,
        location=(sx, sy, sz)
    )
    seed = bpy.context.active_object
    seed.name = f"CharDragonFruit_Seed_{i}"
    seed.scale = (0.030, 0.010, 0.045)
    apply_scale(seed)
    smooth(seed)
    set_mat(seed, M['seed'])
    parts.append(seed)

print("[CharDragonFruit] Seeds done")


# ===========================================================================
#  STEP 6 — EYES (calm, medium-sized)
#  Sclera (white oval) + pupil (dark oval) + highlight dot.
# ===========================================================================
EYE_X = 0.105
FACE_Y_EYE = body_surface_y(EYE_X, EZ) - 0.012   # in front of face patch

for sx, suf in [(-EYE_X, 'L'), (EYE_X, 'R')]:
    # Sclera
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=14, ring_count=10,
        location=(sx, FACE_Y_EYE, EZ)
    )
    sc = bpy.context.active_object
    sc.name = f"CharDragonFruit_Eye_{suf}"
    sc.scale = (0.080, 0.025, 0.110)
    apply_scale(sc)
    smooth(sc)
    set_mat(sc, M['white'])
    parts.append(sc)

    # Pupil
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(sx, FACE_Y_EYE - 0.007, EZ)
    )
    pu = bpy.context.active_object
    pu.name = f"CharDragonFruit_Pupil_{suf}"
    pu.scale = (0.048, 0.018, 0.072)
    apply_scale(pu)
    smooth(pu)
    set_mat(pu, M['pupil'])
    parts.append(pu)

    # Highlight
    inner_sign = 1 if suf == 'L' else -1
    hl_x = sx + inner_sign * 0.020
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=6, ring_count=4,
        location=(hl_x, FACE_Y_EYE - 0.012, EZ + 0.032)
    )
    hl = bpy.context.active_object
    hl.name = f"CharDragonFruit_EyeHL_{suf}"
    hl.scale = (0.018, 0.010, 0.026)
    apply_scale(hl)
    smooth(hl)
    set_mat(hl, M['white'])
    parts.append(hl)

print("[CharDragonFruit] Eyes done")


# ===========================================================================
#  STEP 7 — EYEBROWS
#  Thin flat cubes angled to suggest curiosity:
#  inner edge raised, outer edge level — gives a slightly intrigued look.
# ===========================================================================
BROW_Z = 0.800
BROW_Y = body_surface_y(EYE_X, BROW_Z) - 0.015

for sx, suf, sign in [(-EYE_X, 'L', -1), (EYE_X, 'R', 1)]:
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(sx, BROW_Y, BROW_Z))
    brow = bpy.context.active_object
    brow.name = f"CharDragonFruit_Brow_{suf}"
    brow.scale = (0.070, 0.011, 0.020)
    apply_scale(brow)
    # Inner edge raised: tilt Z so that inner side is higher (curiosity)
    brow.rotation_euler[0] = math.radians(6)
    brow.rotation_euler[2] = math.radians(12 * sign)   # inner up for curiosity
    set_mat(brow, M['brow'])
    parts.append(brow)

print("[CharDragonFruit] Eyebrows done")


# ===========================================================================
#  STEP 8 — MOUTH (friendly grin — half-torus smile)
#
#  Same technique as char_fruit: full torus rotated pi/2 around X,
#  then delete local Y > 0 vertices to leave the bottom arc (U smile).
# ===========================================================================
MOUTH_Z = 0.628
MOUTH_Y = body_surface_y(0.0, MOUTH_Z) - 0.010

bpy.ops.mesh.primitive_torus_add(
    major_radius=0.048,
    minor_radius=0.012,
    major_segments=24,
    minor_segments=8,
    location=(0, MOUTH_Y, MOUTH_Z),
    rotation=(math.pi / 2, 0, 0)
)
mth = bpy.context.active_object
mth.name = "CharDragonFruit_Mouth"

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
print("[CharDragonFruit] Mouth done")


# ===========================================================================
#  STEP 9 — ARMS (horizontal cylinders + mitten hands)
#  Floating gap between body edge and arm, same pattern as char_fruit.
# ===========================================================================
ARM_Z    = BZ - 0.025
ARM_GAP  = 0.022
ARM_HALF = 0.065

for sign, suf in [(-1, 'L'), (1, 'R')]:
    cx = sign * (BR + ARM_GAP + ARM_HALF)

    bpy.ops.mesh.primitive_cylinder_add(
        radius=0.046, depth=0.130,
        location=(cx, 0, ARM_Z),
        rotation=(0, math.pi / 2, 0)
    )
    arm = bpy.context.active_object
    arm.name = f"CharDragonFruit_Arm_{suf}"
    smooth(arm)
    set_mat(arm, M['dark'])
    parts.append(arm)

    mit_x = sign * (BR + ARM_GAP + ARM_HALF * 2 + 0.024)
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(mit_x, 0, ARM_Z - 0.012)
    )
    mit = bpy.context.active_object
    mit.name = f"CharDragonFruit_Mitten_{suf}"
    mit.scale = (0.078, 0.066, 0.062)
    apply_scale(mit)
    smooth(mit)
    set_mat(mit, M['mitten'])
    parts.append(mit)

print("[CharDragonFruit] Arms done")


# ===========================================================================
#  STEP 10 — LEGS AND FEET
# ===========================================================================
LEG_X  = 0.115
LEG_Z  = 0.140
FOOT_Z = 0.048

for sign, suf in [(-1, 'L'), (1, 'R')]:
    lx = sign * LEG_X

    bpy.ops.mesh.primitive_cylinder_add(
        radius=0.058, depth=0.100,
        location=(lx, 0.010, LEG_Z),
        rotation=(math.radians(4 * sign), 0, 0)
    )
    leg = bpy.context.active_object
    leg.name = f"CharDragonFruit_Leg_{suf}"
    smooth(leg)
    set_mat(leg, M['dark'])
    parts.append(leg)

    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(lx, 0.020, FOOT_Z)
    )
    foot = bpy.context.active_object
    foot.name = f"CharDragonFruit_Foot_{suf}"
    foot.scale = (0.078, 0.058, 0.048)
    apply_scale(foot)
    smooth(foot)
    set_mat(foot, M['dark'])
    parts.append(foot)

print("[CharDragonFruit] Legs done")


# ===========================================================================
#  ARMATURE (replaces plain-empty root) — 5 bones: Hips + 4 limb bones,
#  matching Godot's canonical humanoid names so retargeted UAL locomotion
#  clips apply directly. See assets/characters/build_char_fruit.py for the
#  original prototype and assets/animations/build_character_locomotion.py
#  for the shared retarget bake.
# ===========================================================================
bpy.ops.object.armature_add(enter_editmode=True, location=(0, 0, 0))
root = bpy.context.active_object
root.name = "CharDragonFruit" + "_Root"
arm_data = root.data
arm_data.name = "CharDragonFruit" + "_Skeleton"

eb = arm_data.edit_bones
for b in list(eb):
    eb.remove(b)

hips = eb.new("Hips")
hips.head = Vector((0, 0, BZ - BH * 0.3))
hips.tail = Vector((0, 0, BZ + BH * 0.3))

sign = -1
lua = eb.new("LeftUpperArm")
lua.head = Vector((sign * (BR + ARM_GAP + ARM_HALF), 0, ARM_Z))
lua.tail = Vector((sign * (BR + ARM_GAP + ARM_HALF * 2), 0, ARM_Z))
lua.parent = hips
lua.use_connect = False

lul = eb.new("LeftUpperLeg")
lul.head = Vector((sign * LEG_X, 0, LEG_Z + 0.05))
lul.tail = Vector((sign * LEG_X, 0, FOOT_Z))
lul.parent = hips
lul.use_connect = False

sign = 1
rua = eb.new("RightUpperArm")
rua.head = Vector((sign * (BR + ARM_GAP + ARM_HALF), 0, ARM_Z))
rua.tail = Vector((sign * (BR + ARM_GAP + ARM_HALF * 2), 0, ARM_Z))
rua.parent = hips
rua.use_connect = False

rul = eb.new("RightUpperLeg")
rul.head = Vector((sign * LEG_X, 0, LEG_Z + 0.05))
rul.tail = Vector((sign * LEG_X, 0, FOOT_Z))
rul.parent = hips
rul.use_connect = False

bpy.ops.object.mode_set(mode='OBJECT')
print("[" + "CharDragonFruit" + "] Armature done (Hips, LeftUpperArm, RightUpperArm, LeftUpperLeg, RightUpperLeg)")


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
    "LeftUpperArm":  ["CharDragonFruit" + "_Arm_L", "CharDragonFruit" + "_Mitten_L"],
    "RightUpperArm": ["CharDragonFruit" + "_Arm_R", "CharDragonFruit" + "_Mitten_R"],
    "LeftUpperLeg":  ["CharDragonFruit" + "_Leg_L", "CharDragonFruit" + "_Foot_L"],
    "RightUpperLeg": ["CharDragonFruit" + "_Leg_R", "CharDragonFruit" + "_Foot_R"],
}
limb_parts = set()
for bone_name, names in limb_names.items():
    objs = [by_name[n] for n in names if n in by_name]
    limb_parts.update(objs)
    bone_parent_group(objs, bone_name)

hips_parts = [p for p in parts if p not in limb_parts]
bone_parent_group(hips_parts, "Hips")

print("[" + "CharDragonFruit" + "] Bone-parented " + str(len(parts)) + " parts -> " + "CharDragonFruit" + "_Root skeleton")


# ===========================================================================
#  EXPORT GLB — rig + rest pose only, no animation data (shared locomotion
#  clips are merged onto the AnimationPlayer at runtime by player.gd).
# ===========================================================================
out = "/Users/zhihao/personal_projects/ropedart-arena/assets/characters/char_dragon_fruit.glb"
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

print("[" + "CharDragonFruit" + "] Exported -> " + out)
print("[CharDragonFruit] === BUILD COMPLETE ===\n")
