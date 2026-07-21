"""
Rope Dart Arena — Mango Character Build
========================================
Paste this entire file into Blender's Script Editor (Text -> Run Script).
Requires Blender 4.x or later (tested 5.1). Standard build, no add-ons needed.

What it does
------------
1.  Deletes all existing CharMango_* objects / orphan data
2.  Rebuilds the character from scratch following the style guide
3.  Parents everything under CharMango_Root (Plain Axes empty at origin)
4.  Exports to  assets/characters/char_mango.glb

Character dimensions
--------------------
    Total height  : ~1.18 Blender units (feet at Z=0, leaf tip ~Z=1.18)
    Body width    : ~0.72 units (X diameter)
    Forward axis  : -Y (character faces -Y, matching Godot -Z after import)
    Asymmetry     : body offset +0.04 in X for kidney/bean shape

Design notes
------------
    Body    : golden yellow UV sphere scaled (0.36, 0.32, 0.45) — elongated
              kidney/bean shape via X offset of +0.04
    Blush   : orange overlay sphere (right side) + red patch (left cheek)
    Leaves  : 3 cone leaves at 48 deg tilt, fewer and flatter than strawberry
    Eyes    : sclera + pupil (shifted low) + dark eyelid cube = half-lidded
    Mouth   : half-torus offset +0.03 in X, tilted 8 deg Z = asymmetric smirk
    Arms    : golden yellow horizontal cylinders + rounded mittens
    Feet    : darker orange-brown flattened spheres
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
    """Remove every object / mesh / material starting with 'CharMango'."""
    bpy.ops.object.select_all(action='DESELECT')
    for o in list(bpy.data.objects):
        if o.name.startswith("CharMango"):
            o.select_set(True)
    if any(o.select_get() for o in bpy.data.objects):
        bpy.ops.object.delete()
    for m in list(bpy.data.meshes):
        if m.users == 0:
            bpy.data.meshes.remove(m)
    for m in list(bpy.data.materials):
        if m.users == 0 and m.name.startswith("CharMango"):
            bpy.data.materials.remove(m)


def mk_mat(name, rgba, roughness=0.85, specular=0.04):
    """Matte painted-vinyl Principled BSDF material."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = rgba
    bsdf.inputs["Roughness"].default_value = roughness
    # Blender 4.x uses "Specular IOR Level"; fall back silently for older builds
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
#  STEP 1 — CLEAR
# ===========================================================================
# Delete everything in the default scene before building
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)

clear_char()
parts = []   # collect all mesh objects for parenting at the end
print("\n[CharMango] === BUILD START ===")


# ===========================================================================
#  MATERIALS
# ===========================================================================
M = {}
# Body / skin
M['body']     = mk_mat("CharMango_M_Body",     (0.98, 0.78, 0.08, 1.0))         # golden yellow
M['orange']   = mk_mat("CharMango_M_Orange",   (0.95, 0.45, 0.05, 1.0))         # orange blush overlay
M['redblush'] = mk_mat("CharMango_M_RedBlush", (0.80, 0.10, 0.08, 1.0))         # red blush patch
M['feet']     = mk_mat("CharMango_M_Feet",     (0.62, 0.28, 0.04, 1.0))         # dark orange-brown feet
# Foliage
M['leaf']     = mk_mat("CharMango_M_Leaf",     (0.10, 0.52, 0.08, 1.0))         # green leaf
M['stem']     = mk_mat("CharMango_M_Stem",     (0.28, 0.14, 0.04, 1.0))         # brown stem
# Face
M['white']    = mk_mat("CharMango_M_White",    (0.95, 0.95, 0.95, 1.0), roughness=0.55, specular=0.12)
M['pupil']    = mk_mat("CharMango_M_Pupil",    (0.04, 0.04, 0.04, 1.0))
M['eyelid']   = mk_mat("CharMango_M_Eyelid",   (0.06, 0.04, 0.03, 1.0))         # near-black drooping lid
M['mouth']    = mk_mat("CharMango_M_Mouth",    (0.22, 0.05, 0.03, 1.0))


# ===========================================================================
#  LAYOUT CONSTANTS
#  All positions in world space, character faces -Y.
#
#  Z stack (bottom -> top)
#    0.000  ground / foot bottom
#    0.048  foot centre
#    0.130  leg centre
#    0.180  body bottom  (BZ - BH)
#    0.630  body centre            <- BZ
#    0.720  eye centre             <- EZ
#    1.020  leaf base              <- BZ + BH - 0.06
#    1.080  body top               <- BZ + BH
# ===========================================================================
BZ   = 0.63    # body Z centre
BX   = 0.04    # body X offset (kidney asymmetry)
BR_X = 0.36    # body X half-radius
BR_Y = 0.32    # body Y half-radius (front-to-back depth)
BH   = 0.45    # body Z half-height
EZ   = 0.720   # eye Z centre
EYE_X = 0.128  # lateral eye centre (distance from X=0)


def body_surface_y(x, z):
    """
    Y coordinate of the front face of the mango body ellipsoid at world (x, z).
    Accounts for the X offset (kidney asymmetry) and separate X/Y radii.
    Returns slightly inset (0.008 inside) to avoid z-fighting.
    """
    tz = (z - BZ) / BH
    tx = (x - BX) / BR_X
    under = max(0.0, 1.0 - tz * tz - tx * tx)
    return -(BR_Y * math.sqrt(under)) - 0.008


# ===========================================================================
#  STEP 2 — BODY
#  UV Sphere scaled as an elongated bean/kidney. Slightly offset in X.
# ===========================================================================
bpy.ops.mesh.primitive_uv_sphere_add(
    radius=1.0, segments=20, ring_count=14,
    location=(BX, 0, BZ)
)
body = bpy.context.active_object
body.name = "CharMango_Body"
body.scale = (BR_X, BR_Y, BH)
apply_scale(body)
smooth(body)
set_mat(body, M['body'])
parts.append(body)
print("[CharMango] Body OK")


# ===========================================================================
#  STEP 3 — ORANGE BLUSH OVERLAY
#  Smaller flattened sphere on the right (+X) side, slightly inset into body.
#  Suggests the characteristic orange-red gradient of a ripe mango.
# ===========================================================================
bpy.ops.mesh.primitive_uv_sphere_add(
    radius=1.0, segments=14, ring_count=10,
    location=(BX + 0.20, -0.06, BZ + 0.06)
)
overlay = bpy.context.active_object
overlay.name = "CharMango_OrangeOverlay"
overlay.scale = (0.24, 0.16, 0.30)
apply_scale(overlay)
smooth(overlay)
set_mat(overlay, M['orange'])
parts.append(overlay)
print("[CharMango] Orange overlay OK")


# ===========================================================================
#  STEP 4 — RED BLUSH PATCH
#  Small flattened sphere on the left cheek, flush with body surface.
# ===========================================================================
RBLUSH_X = BX - 0.18   # left cheek (opposite side from orange overlay)
RBLUSH_Z = BZ + 0.04
rblush_y = body_surface_y(RBLUSH_X, RBLUSH_Z) + 0.004

bpy.ops.mesh.primitive_uv_sphere_add(
    radius=1.0, segments=8, ring_count=6,
    location=(RBLUSH_X, rblush_y, RBLUSH_Z)
)
rbl = bpy.context.active_object
rbl.name = "CharMango_RedBlush"
rbl.scale = (0.058, 0.012, 0.040)
apply_scale(rbl)
smooth(rbl)
set_mat(rbl, M['redblush'])
parts.append(rbl)
print("[CharMango] Red blush OK")


# ===========================================================================
#  STEP 5 — LEAF CLUSTER (3 cone leaves) + STEM
#  Fewer, wider, flatter leaves than strawberry's 5-petal cap.
#  Tilt angle 48 deg (vs strawberry's 38 deg) for a more splayed look.
# ===========================================================================
LEAF_BASE_Z = BZ + BH - 0.06   # approx 1.02
LEAF_DEPTH  = 0.22
LEAF_HALF   = LEAF_DEPTH * 0.5
LEAF_TILT   = math.radians(48)

# Three leaves: front-centre, rear-right, rear-left
LEAF_ANGLES = [
    math.radians(-10),   # centre-left (main leaf angled slightly toward viewer)
    math.radians(110),   # right leaf
    math.radians(230),   # left-back leaf
]

for i, angle in enumerate(LEAF_ANGLES):
    d = Vector((
        math.sin(LEAF_TILT) * math.cos(angle),
        math.sin(LEAF_TILT) * math.sin(angle),
        math.cos(LEAF_TILT)
    ))
    base_pt = Vector((BX * 0.3, 0, LEAF_BASE_Z))
    centre  = base_pt + d * LEAF_HALF

    bpy.ops.mesh.primitive_cone_add(
        radius1=0.062, radius2=0.005, depth=LEAF_DEPTH,
        location=(centre.x, centre.y, centre.z)
    )
    leaf = bpy.context.active_object
    leaf.name = f"CharMango_Leaf_{i}"
    q = Vector((0, 0, 1)).rotation_difference(d)
    leaf.rotation_mode = 'QUATERNION'
    leaf.rotation_quaternion = q
    smooth(leaf)
    set_mat(leaf, M['leaf'])
    parts.append(leaf)

# Short brown stem at very top
bpy.ops.mesh.primitive_cylinder_add(
    radius=0.022, depth=0.14,
    location=(BX * 0.3, 0, LEAF_BASE_Z + 0.09)
)
stem_obj = bpy.context.active_object
stem_obj.name = "CharMango_Stem"
smooth(stem_obj)
set_mat(stem_obj, M['stem'])
parts.append(stem_obj)
print("[CharMango] Leaf cluster + stem OK")


# ===========================================================================
#  STEP 6 — EYES (half-lidded confident look)
#
#  Each eye = sclera (white oval)
#            + pupil shifted DOWN (relaxed downward gaze)
#            + small white highlight spot (below the lid line)
#            + dark thin cube covering the UPPER half = drooping eyelid
#
#  Sclera scale Z = 0.120 -> half_z = 0.060
#  Eyelid centre at EZ + 0.030 (mid-point of upper sclera half)
#  Eyelid Z-scale = 0.030 (covers from EZ to EZ+0.060)
# ===========================================================================
EYE_HALF_Z = 0.060   # sclera Z half-extent (matches scale_z below)

for sx, suf in [(-EYE_X, 'L'), (EYE_X, 'R')]:
    face_y = body_surface_y(sx, EZ) + 0.012   # sit on face surface

    # Sclera (white)
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=14, ring_count=10,
        location=(sx, face_y, EZ)
    )
    sc = bpy.context.active_object
    sc.name = f"CharMango_Eye_{suf}"
    sc.scale = (0.085, 0.026, 0.120)
    apply_scale(sc)
    smooth(sc)
    set_mat(sc, M['white'])
    parts.append(sc)

    # Pupil — shifted downward for relaxed gaze (pupils low in sclera)
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(sx, face_y - 0.009, EZ - 0.020)
    )
    pu = bpy.context.active_object
    pu.name = f"CharMango_Pupil_{suf}"
    pu.scale = (0.050, 0.020, 0.074)
    apply_scale(pu)
    smooth(pu)
    set_mat(pu, M['pupil'])
    parts.append(pu)

    # Highlight spot — small, sits below the lid line
    inner_sign = 1 if suf == 'L' else -1
    hl_x = sx + inner_sign * 0.020
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=6, ring_count=4,
        location=(hl_x, face_y - 0.014, EZ + 0.006)
    )
    hl = bpy.context.active_object
    hl.name = f"CharMango_EyeHL_{suf}"
    hl.scale = (0.016, 0.009, 0.022)
    apply_scale(hl)
    smooth(hl)
    set_mat(hl, M['white'])
    parts.append(hl)

    # Eyelid: dark cube covering the upper half of the sclera
    # Sclera spans EZ-0.060 to EZ+0.060; lid covers EZ to EZ+0.060
    lid_z = EZ + EYE_HALF_Z * 0.5   # centre of upper half = EZ + 0.030
    bpy.ops.mesh.primitive_cube_add(
        size=1.0,
        location=(sx, face_y - 0.012, lid_z)
    )
    lid = bpy.context.active_object
    lid.name = f"CharMango_Eyelid_{suf}"
    lid.scale = (0.090, 0.030, EYE_HALF_Z * 0.5)  # Z = 0.030 covers upper half
    apply_scale(lid)
    set_mat(lid, M['eyelid'])
    parts.append(lid)

print("[CharMango] Eyes + eyelids OK")


# ===========================================================================
#  STEP 7 — SMIRK MOUTH
#
#  Half-torus (bottom U arc = smile), but asymmetric:
#    - Centre offset +0.03 in X so arc isn't centred on the face
#    - 8 deg Z rotation tilt so one corner is higher than the other
#
#  Build order:
#  1. Create torus with rotation=(pi/2, 0, 0) -> ring lies in world XZ plane
#  2. Edit mode: delete local Y > 0 (upper arc), leaving bottom U smile
#  3. Object mode: set rotation=(pi/2, 0, 8 deg) for the smirk tilt
# ===========================================================================
MOUTH_Z = 0.662
MOUTH_Y = body_surface_y(0.0, MOUTH_Z) + 0.005
SMIRK_X = 0.030   # shift arc right so left corner sits lower

bpy.ops.mesh.primitive_torus_add(
    major_radius=0.043,
    minor_radius=0.010,
    major_segments=24,
    minor_segments=8,
    location=(SMIRK_X, MOUTH_Y, MOUTH_Z),
    rotation=(math.pi / 2, 0, 0)
)
mth = bpy.context.active_object
mth.name = "CharMango_Mouth"

# Delete top-half vertices (local Y > 0 -> upper/frown arc in world)
bpy.context.view_layer.objects.active = mth
bpy.ops.object.mode_set(mode='EDIT')
bm2 = bmesh.from_edit_mesh(mth.data)
to_del = [v for v in bm2.verts if v.co.y > 0.002]
bmesh.ops.delete(bm2, geom=to_del, context='VERTS')
bmesh.update_edit_mesh(mth.data)
bpy.ops.object.mode_set(mode='OBJECT')

# Apply smirk tilt: 8 deg Z added to existing 90 deg X
mth.rotation_euler = (math.pi / 2, 0, math.radians(8))

smooth(mth)
set_mat(mth, M['mouth'])
parts.append(mth)
print("[CharMango] Smirk mouth OK")


# ===========================================================================
#  STEP 8 — ARMS (golden yellow, floating off body sides)
#  Horizontal cylinders + rounded mitten hands, body-color throughout.
# ===========================================================================
ARM_Z    = BZ - 0.020   # slightly below body equator for natural hang
ARM_GAP  = 0.022
ARM_HALF = 0.065

for sign, suf in [(-1, 'L'), (1, 'R')]:
    cx = sign * (BR_X + ARM_GAP + ARM_HALF) + BX

    bpy.ops.mesh.primitive_cylinder_add(
        radius=0.044, depth=0.130,
        location=(cx, 0, ARM_Z),
        rotation=(0, math.pi / 2, 0)
    )
    arm = bpy.context.active_object
    arm.name = f"CharMango_Arm_{suf}"
    smooth(arm)
    set_mat(arm, M['feet'])   # dark orange-brown limb accent
    parts.append(arm)

    # Mitten hand — rounded blob just past the arm end
    mit_x = sign * (BR_X + ARM_GAP + ARM_HALF * 2 + 0.024) + BX
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(mit_x, 0, ARM_Z - 0.012)
    )
    mit = bpy.context.active_object
    mit.name = f"CharMango_Mitten_{suf}"
    mit.scale = (0.076, 0.064, 0.060)
    apply_scale(mit)
    smooth(mit)
    set_mat(mit, M['feet'])   # dark orange-brown limb accent
    parts.append(mit)

print("[CharMango] Arms OK")


# ===========================================================================
#  STEP 9 — LEGS AND FEET
#  Stubby cylinders, slightly outward angle. Feet: flattened spheres, Z=0 bottom.
#  Legs use golden yellow; feet use darker orange-brown.
# ===========================================================================
LEG_X  = 0.110
LEG_Z  = 0.130
FOOT_Z = 0.048   # centre; scale_z=0.048 -> bottom exactly at Z=0

for sign, suf in [(-1, 'L'), (1, 'R')]:
    lx = sign * LEG_X

    bpy.ops.mesh.primitive_cylinder_add(
        radius=0.055, depth=0.095,
        location=(lx, 0.010, LEG_Z),
        rotation=(math.radians(4 * sign), 0, 0)
    )
    leg = bpy.context.active_object
    leg.name = f"CharMango_Leg_{suf}"
    smooth(leg)
    set_mat(leg, M['feet'])   # dark orange-brown limb accent
    parts.append(leg)

    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(lx, 0.020, FOOT_Z)
    )
    foot = bpy.context.active_object
    foot.name = f"CharMango_Foot_{suf}"
    foot.scale = (0.075, 0.056, 0.048)
    apply_scale(foot)
    smooth(foot)
    set_mat(foot, M['feet'])   # darker orange-brown
    parts.append(foot)

print("[CharMango] Legs + feet OK")


# ===========================================================================
#  ARMATURE (replaces plain-empty root) — 5 bones: Hips + 4 limb bones,
#  matching Godot's canonical humanoid names so retargeted UAL locomotion
#  clips apply directly. See assets/characters/build_char_fruit.py for the
#  original prototype and assets/animations/build_character_locomotion.py
#  for the shared retarget bake.
# ===========================================================================
bpy.ops.object.armature_add(enter_editmode=True, location=(0, 0, 0))
root = bpy.context.active_object
root.name = "CharMango" + "_Root"
arm_data = root.data
arm_data.name = "CharMango" + "_Skeleton"

eb = arm_data.edit_bones
for b in list(eb):
    eb.remove(b)

hips = eb.new("Hips")
hips.head = Vector((0, 0, BZ - BH * 0.3))
hips.tail = Vector((0, 0, BZ + BH * 0.3))

sign = -1
lua = eb.new("LeftUpperArm")
lua.head = Vector((sign * (BR_X + ARM_GAP + ARM_HALF) + BX, 0, ARM_Z))
lua.tail = Vector((sign * (BR_X + ARM_GAP + ARM_HALF * 2) + BX, 0, ARM_Z))
lua.parent = hips
lua.use_connect = False

lul = eb.new("LeftUpperLeg")
lul.head = Vector((sign * LEG_X, 0, LEG_Z + 0.05))
lul.tail = Vector((sign * LEG_X, 0, FOOT_Z))
lul.parent = hips
lul.use_connect = False

sign = 1
rua = eb.new("RightUpperArm")
rua.head = Vector((sign * (BR_X + ARM_GAP + ARM_HALF) + BX, 0, ARM_Z))
rua.tail = Vector((sign * (BR_X + ARM_GAP + ARM_HALF * 2) + BX, 0, ARM_Z))
rua.parent = hips
rua.use_connect = False

rul = eb.new("RightUpperLeg")
rul.head = Vector((sign * LEG_X, 0, LEG_Z + 0.05))
rul.tail = Vector((sign * LEG_X, 0, FOOT_Z))
rul.parent = hips
rul.use_connect = False

bpy.ops.object.mode_set(mode='OBJECT')
print("[" + "CharMango" + "] Armature done (Hips, LeftUpperArm, RightUpperArm, LeftUpperLeg, RightUpperLeg)")


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
    "LeftUpperArm":  ["CharMango" + "_Arm_L", "CharMango" + "_Mitten_L"],
    "RightUpperArm": ["CharMango" + "_Arm_R", "CharMango" + "_Mitten_R"],
    "LeftUpperLeg":  ["CharMango" + "_Leg_L", "CharMango" + "_Foot_L"],
    "RightUpperLeg": ["CharMango" + "_Leg_R", "CharMango" + "_Foot_R"],
}
limb_parts = set()
for bone_name, names in limb_names.items():
    objs = [by_name[n] for n in names if n in by_name]
    limb_parts.update(objs)
    bone_parent_group(objs, bone_name)

hips_parts = [p for p in parts if p not in limb_parts]
bone_parent_group(hips_parts, "Hips")

print("[" + "CharMango" + "] Bone-parented " + str(len(parts)) + " parts -> " + "CharMango" + "_Root skeleton")


# ===========================================================================
#  EXPORT GLB — rig + rest pose only, no animation data (shared locomotion
#  clips are merged onto the AnimationPlayer at runtime by player.gd).
# ===========================================================================
out = "/Users/zhihao/personal_projects/ropedart-arena/assets/characters/char_mango.glb"
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

print("[" + "CharMango" + "] Exported -> " + out)
print("[CharMango] === BUILD COMPLETE ===\n")
