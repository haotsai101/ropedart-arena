"""
Rope Dart Arena — Banana Character Build
========================================
Run headlessly:
  /Applications/Blender.app/Contents/MacOS/Blender --background --python \
      /Users/zhihao/personal_projects/ropedart-arena/assets/characters/build_char_banana.py

What it does
------------
1.  Deletes all existing CharBanana_* objects / orphan data
2.  Rebuilds the banana character from scratch
3.  Parents everything under CharBanana_Root (Plain Axes empty at origin)
4.  Exports to assets/characters/char_banana.glb

Character dimensions
--------------------
    Total height  : ~1.22 Blender units (feet at Z=0, stem tip ~Z=1.22)
    Body width    : ~0.56 units (2 * BRX)
    Body offset   : +0.06 X to suggest the banana arc/curve
    Forward axis  : -Y (character faces -Y, matching Godot -Z after import)

Naming
------
    CharBanana_Body   — the mesh player.gd color-tints
    CharBanana_Root   — Plain Axes empty, parent of all parts
"""

import bpy
import math
import os
import bmesh
from mathutils import Vector


# ===========================================================================
#  HELPERS  (same pattern as build_char_fruit.py)
# ===========================================================================

def clear_char():
    """Remove every object / mesh / material starting with 'CharBanana'."""
    bpy.ops.object.select_all(action='DESELECT')
    for o in list(bpy.data.objects):
        if o.name.startswith("CharBanana"):
            o.select_set(True)
    if any(o.select_get() for o in bpy.data.objects):
        bpy.ops.object.delete()
    for m in list(bpy.data.meshes):
        if m.users == 0:
            bpy.data.meshes.remove(m)
    for m in list(bpy.data.materials):
        if m.users == 0 and m.name.startswith("CharBanana"):
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
    """Apply scale transform so mesh data has the correct real-world size."""
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
#  CLEAR
# ===========================================================================
# Delete everything in the default scene before building
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)

clear_char()
parts = []
print("\n[CharBanana] === BUILD START ===")


# ===========================================================================
#  MATERIALS
# ===========================================================================
M = {}
M['body']   = mk_mat("CharBanana_M_Body",   (0.98, 0.88, 0.12, 1.0))   # soft banana yellow
M['peel']   = mk_mat("CharBanana_M_Peel",   (0.92, 0.78, 0.06, 1.0))   # peel exterior (darker)
M['stem']   = mk_mat("CharBanana_M_Stem",   (0.28, 0.14, 0.03, 1.0))   # brown stem nub
M['foot']   = mk_mat("CharBanana_M_Foot",   (0.40, 0.22, 0.05, 1.0))   # stem-brown limb accent: arms/legs/feet
M['white']  = mk_mat("CharBanana_M_White",  (0.95, 0.95, 0.95, 1.0), roughness=0.55, specular=0.12)
M['pupil']  = mk_mat("CharBanana_M_Pupil",  (0.04, 0.04, 0.04, 1.0))
M['brow']   = mk_mat("CharBanana_M_Brow",   (0.15, 0.10, 0.02, 1.0))   # dark yellow-brown brows
M['mouth']  = mk_mat("CharBanana_M_Mouth",  (0.25, 0.05, 0.03, 1.0))   # dark red-brown mouth


# ===========================================================================
#  LAYOUT CONSTANTS
#
#  Body: UV sphere placed at (BX, 0, BZ), scaled (BRX, BRY, BH)
#  BX = +0.06 gives the banana the visual suggestion of an arc/curve.
#
#  Z stack (bottom to top):
#    0.000  ground / foot bottom
#    0.048  foot centre
#    0.140  leg centre
#    0.620  body centre              BZ
#    0.740  eye centre               EZ
#    0.840  brow centre              BROW_Z
#    1.060  peel flap base           PEEL_BASE_Z
#    1.140  body crown / stem base
#    1.186  stem centre
# ===========================================================================
BX  =  0.06    # body X offset — the "banana arc" lean
BZ  =  0.62    # body Z centre
BRX =  0.28    # body X radius
BRY =  0.26    # body Y radius  (slightly narrower, faces -Y)
BH  =  0.52    # body Z half-height

EYE_X  =  0.115   # lateral distance of each eye from body centre X
EZ     =  0.74    # eye Z centre
BROW_Z =  0.84    # brow Z centre


def body_surface_y(world_x, world_z):
    """
    Y coordinate of the -Y facing surface of the banana ellipsoid at
    world position (world_x, world_z).  Inset 0.008 to avoid z-fighting.
    """
    tx = (world_x - BX) / BRX
    tz = (world_z - BZ) / BH
    under = max(0.0, 1.0 - tx * tx - tz * tz)
    return -BRY * math.sqrt(under) - 0.008


# ===========================================================================
#  BODY
#  UV sphere scaled into an elongated, slightly asymmetric banana torso.
#  Named CharBanana_Body so player.gd can find it for color-tinting.
# ===========================================================================
bpy.ops.mesh.primitive_uv_sphere_add(
    radius=1.0, segments=20, ring_count=16,
    location=(BX, 0, BZ)
)
body = bpy.context.active_object
body.name = "CharBanana_Body"
body.scale = (BRX, BRY, BH)
apply_scale(body)
smooth(body)
set_mat(body, M['body'])
parts.append(body)
print("[CharBanana] Body OK")


# ===========================================================================
#  PEEL FLAPS
#  3 slim cone strips splaying from near the crown, like wild banana-peel hair.
#  One flap goes back (-Y direction), the other two fan left and right.
#  Each is a thin tapered cone oriented along its splay direction.
# ===========================================================================
PEEL_BASE_Z = BZ + BH - 0.08   # 1.06 — just below crown at 1.14
PEEL_HALF   = 0.085             # half-depth of each peel cone

# (XY angle from +X axis in radians, tilt from +Z axis in radians)
PEEL_CONFIGS = [
    (math.radians( 90), math.radians(40)),   # back-centre  (+Y then up)
    (math.radians(220), math.radians(44)),   # left-back
    (math.radians(330), math.radians(44)),   # right-back
]

for i, (a, tilt) in enumerate(PEEL_CONFIGS):
    d = Vector((
        math.sin(tilt) * math.cos(a),
        math.sin(tilt) * math.sin(a),
        math.cos(tilt),
    ))
    base_pt = Vector((BX, 0, PEEL_BASE_Z))
    centre  = base_pt + d * PEEL_HALF

    bpy.ops.mesh.primitive_cone_add(
        radius1=0.038, radius2=0.006, depth=PEEL_HALF * 2,
        location=(centre.x, centre.y, centre.z)
    )
    peel = bpy.context.active_object
    peel.name = f"CharBanana_Peel_{i}"

    # Rotate cone's local +Z axis to point along d
    q = Vector((0, 0, 1)).rotation_difference(d)
    peel.rotation_mode = 'QUATERNION'
    peel.rotation_quaternion = q

    smooth(peel)
    set_mat(peel, M['peel'])
    parts.append(peel)

print("[CharBanana] Peel flaps OK")


# ===========================================================================
#  STEM NUB
#  Short brown cylinder at the very top. Slight lean for character.
# ===========================================================================
STEM_BASE_Z = BZ + BH + 0.01   # 1.15 — just above body crown
STEM_HALF   = 0.036

bpy.ops.mesh.primitive_cylinder_add(
    radius=0.018, depth=STEM_HALF * 2,
    location=(BX, 0, STEM_BASE_Z + STEM_HALF)
)
stem = bpy.context.active_object
stem.name = "CharBanana_Stem"
stem.rotation_euler[0] = math.radians(8)   # lean slightly backward
smooth(stem)
set_mat(stem, M['stem'])
parts.append(stem)
print("[CharBanana] Stem OK")


# ===========================================================================
#  EYES — asymmetric sizes for goofy expression
#
#  Left eye  (L) slightly smaller sclera (Z scale 0.095)
#  Right eye (R) slightly larger  sclera (Z scale 0.110)
#  Both share the same face surface Y computed at the eye's world X.
# ===========================================================================
EYE_WORLD_X = BX + EYE_X                            # 0.175 — use for Y depth calc
FACE_Y_EYE  = body_surface_y(EYE_WORLD_X, EZ) + 0.012

for world_x, suf, sz_scale in [
    (BX - EYE_X, 'L', 0.095),   # world x = -0.055
    (BX + EYE_X, 'R', 0.110),   # world x =  0.175
]:
    # -- Sclera (white) --------------------------------------------------
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=14, ring_count=10,
        location=(world_x, FACE_Y_EYE, EZ)
    )
    sc = bpy.context.active_object
    sc.name = f"CharBanana_Eye_{suf}"
    sc.scale = (0.080, 0.025, sz_scale)
    apply_scale(sc)
    smooth(sc)
    set_mat(sc, M['white'])
    parts.append(sc)

    # -- Pupil (dark, slightly forward of sclera) ------------------------
    pupil_sz = sz_scale * 0.65
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(world_x, FACE_Y_EYE - 0.008, EZ)
    )
    pu = bpy.context.active_object
    pu.name = f"CharBanana_Pupil_{suf}"
    pu.scale = (0.048, 0.018, pupil_sz)
    apply_scale(pu)
    smooth(pu)
    set_mat(pu, M['pupil'])
    parts.append(pu)

    # -- Highlight (tiny white dot, upper-inner quadrant) ----------------
    inner_sign = 1 if suf == 'L' else -1
    hl_x = world_x + inner_sign * 0.020
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=6, ring_count=4,
        location=(hl_x, FACE_Y_EYE - 0.012, EZ + 0.030)
    )
    hl = bpy.context.active_object
    hl.name = f"CharBanana_EyeHL_{suf}"
    hl.scale = (0.018, 0.011, 0.026)
    apply_scale(hl)
    smooth(hl)
    set_mat(hl, M['white'])
    parts.append(hl)

print("[CharBanana] Eyes OK")


# ===========================================================================
#  EYEBROWS — deliberately asymmetric for classic goofy expression
#
#  Left (L):  steeply tilted ~25 deg Z rotation — looks raised/surprised
#  Right (R): nearly flat ~5 deg Z rotation     — looks neutral/relaxed
# ===========================================================================
BROW_WORLD_X = BX + EYE_X
BROW_Y = body_surface_y(BROW_WORLD_X, BROW_Z) + 0.010

for world_x, suf, z_rot_deg in [
    (BX - EYE_X, 'L',  25.0),   # steep raise
    (BX + EYE_X, 'R',  -5.0),   # nearly flat
]:
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(world_x, BROW_Y, BROW_Z))
    brow = bpy.context.active_object
    brow.name = f"CharBanana_Brow_{suf}"
    brow.scale = (0.070, 0.012, 0.020)
    apply_scale(brow)
    brow.rotation_euler[0] = math.radians(8)         # slight forward lean
    brow.rotation_euler[2] = math.radians(z_rot_deg) # asymmetric tilt
    set_mat(brow, M['brow'])
    parts.append(brow)

print("[CharBanana] Eyebrows OK")


# ===========================================================================
#  MOUTH — wide lopsided half-torus smile
#
#  major_radius=0.065 (wider than strawberry's 0.046).
#  6 deg Z tilt + 0.02 X offset → lopsided goofy grin.
#  Same edit-mode half-delete trick as build_char_fruit.py:
#    delete local-Y > 0 verts → keeps the lower arc (∪ smile).
# ===========================================================================
MOUTH_Z = 0.640
MOUTH_Y = body_surface_y(BX + 0.02, MOUTH_Z) + 0.005

bpy.ops.mesh.primitive_torus_add(
    major_radius=0.065,
    minor_radius=0.013,
    major_segments=24,
    minor_segments=8,
    location=(BX + 0.02, MOUTH_Y, MOUTH_Z),
    rotation=(math.pi / 2, 0, math.radians(6))   # 90 deg X face, 6 deg Z lopsided tilt
)
mth = bpy.context.active_object
mth.name = "CharBanana_Mouth"

# Delete local top-half (upper arc = frown shape) leaving the ∪ smile
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
print("[CharBanana] Mouth OK")


# ===========================================================================
#  ARMS — floating horizontal cylinders with mitten blobs
#  Positioned symmetrically around the body centre (BX).
# ===========================================================================
ARM_Z    = BZ - 0.05   # slightly below body equator
ARM_GAP  = 0.022       # gap between body edge and arm end
ARM_HALF = 0.060       # half-length of arm cylinder

for sign, suf in [(-1, 'L'), (1, 'R')]:
    cx = BX + sign * (BRX + ARM_GAP + ARM_HALF)

    bpy.ops.mesh.primitive_cylinder_add(
        radius=0.042, depth=ARM_HALF * 2,
        location=(cx, 0, ARM_Z),
        rotation=(0, math.pi / 2, 0)   # local Z -> world X (horizontal)
    )
    arm = bpy.context.active_object
    arm.name = f"CharBanana_Arm_{suf}"
    smooth(arm)
    set_mat(arm, M['foot'])
    parts.append(arm)

    mit_x = BX + sign * (BRX + ARM_GAP + ARM_HALF * 2 + 0.022)
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(mit_x, 0, ARM_Z - 0.010)
    )
    mit = bpy.context.active_object
    mit.name = f"CharBanana_Mitten_{suf}"
    mit.scale = (0.072, 0.060, 0.058)
    apply_scale(mit)
    smooth(mit)
    set_mat(mit, M['foot'])
    parts.append(mit)

print("[CharBanana] Arms OK")


# ===========================================================================
#  LEGS AND FEET
#  Stubby cylinders under the body, feet flatten at Z=0.
#  Slight X lean follows the body offset (BX * 0.3) for a grounded stance.
# ===========================================================================
LEG_X  = 0.100
LEG_Z  = 0.140    # leg centre
FOOT_Z = 0.048    # foot centre (scale Z=0.048 -> bottom at Z=0)

for sign, suf in [(-1, 'L'), (1, 'R')]:
    lx = sign * LEG_X + BX * 0.3   # slight X lean toward banana curve

    bpy.ops.mesh.primitive_cylinder_add(
        radius=0.052, depth=0.095,
        location=(lx, 0.010, LEG_Z),
        rotation=(math.radians(4 * sign), 0, 0)   # slight outward tilt
    )
    leg = bpy.context.active_object
    leg.name = f"CharBanana_Leg_{suf}"
    smooth(leg)
    set_mat(leg, M['foot'])
    parts.append(leg)

    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(lx, 0.020, FOOT_Z)
    )
    foot = bpy.context.active_object
    foot.name = f"CharBanana_Foot_{suf}"
    foot.scale = (0.072, 0.055, 0.048)
    apply_scale(foot)
    smooth(foot)
    set_mat(foot, M['foot'])
    parts.append(foot)

print("[CharBanana] Legs OK")


# ===========================================================================
#  ARMATURE (replaces plain-empty root) — 5 bones: Hips + 4 limb bones,
#  matching Godot's canonical humanoid names so retargeted UAL locomotion
#  clips apply directly. See assets/characters/build_char_fruit.py for the
#  original prototype and assets/animations/build_character_locomotion.py
#  for the shared retarget bake.
# ===========================================================================
bpy.ops.object.armature_add(enter_editmode=True, location=(0, 0, 0))
root = bpy.context.active_object
root.name = "CharBanana" + "_Root"
arm_data = root.data
arm_data.name = "CharBanana" + "_Skeleton"

eb = arm_data.edit_bones
for b in list(eb):
    eb.remove(b)

hips = eb.new("Hips")
hips.head = Vector((0, 0, BZ - BH * 0.3))
hips.tail = Vector((0, 0, BZ + BH * 0.3))

sign = -1
lua = eb.new("LeftUpperArm")
lua.head = Vector((BX + sign * (BRX + ARM_GAP + ARM_HALF), 0, ARM_Z))
lua.tail = Vector((BX + sign * (BRX + ARM_GAP + ARM_HALF * 2), 0, ARM_Z))
lua.parent = hips
lua.use_connect = False

lul = eb.new("LeftUpperLeg")
lul.head = Vector((sign * LEG_X + BX * 0.3, 0, LEG_Z + 0.05))
lul.tail = Vector((sign * LEG_X + BX * 0.3, 0, FOOT_Z))
lul.parent = hips
lul.use_connect = False

sign = 1
rua = eb.new("RightUpperArm")
rua.head = Vector((BX + sign * (BRX + ARM_GAP + ARM_HALF), 0, ARM_Z))
rua.tail = Vector((BX + sign * (BRX + ARM_GAP + ARM_HALF * 2), 0, ARM_Z))
rua.parent = hips
rua.use_connect = False

rul = eb.new("RightUpperLeg")
rul.head = Vector((sign * LEG_X + BX * 0.3, 0, LEG_Z + 0.05))
rul.tail = Vector((sign * LEG_X + BX * 0.3, 0, FOOT_Z))
rul.parent = hips
rul.use_connect = False

bpy.ops.object.mode_set(mode='OBJECT')
print("[" + "CharBanana" + "] Armature done (Hips, LeftUpperArm, RightUpperArm, LeftUpperLeg, RightUpperLeg)")


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
    "LeftUpperArm":  ["CharBanana" + "_Arm_L", "CharBanana" + "_Mitten_L"],
    "RightUpperArm": ["CharBanana" + "_Arm_R", "CharBanana" + "_Mitten_R"],
    "LeftUpperLeg":  ["CharBanana" + "_Leg_L", "CharBanana" + "_Foot_L"],
    "RightUpperLeg": ["CharBanana" + "_Leg_R", "CharBanana" + "_Foot_R"],
}
limb_parts = set()
for bone_name, names in limb_names.items():
    objs = [by_name[n] for n in names if n in by_name]
    limb_parts.update(objs)
    bone_parent_group(objs, bone_name)

hips_parts = [p for p in parts if p not in limb_parts]
bone_parent_group(hips_parts, "Hips")

print("[" + "CharBanana" + "] Bone-parented " + str(len(parts)) + " parts -> " + "CharBanana" + "_Root skeleton")


# ===========================================================================
#  EXPORT GLB — rig + rest pose only, no animation data (shared locomotion
#  clips are merged onto the AnimationPlayer at runtime by player.gd).
# ===========================================================================
out = "/Users/zhihao/personal_projects/ropedart-arena/assets/characters/char_banana.glb"
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

print("[" + "CharBanana" + "] Exported -> " + out)
print("[CharBanana] === BUILD COMPLETE ===\n")
