"""
Rope Dart Arena — Watermelon Character Build
============================================
Paste this entire file into Blender's Script Editor (Text → Run Script), or
run headless:
    /Applications/Blender.app/Contents/MacOS/Blender --background --python build_char_watermelon.py

Requires Blender 4.x (tested 4.0-4.4). Standard build, no add-ons needed.

What it does
------------
1.  Deletes all existing CharWatermelon_* objects / orphan data
2.  Rebuilds the character from scratch following the style guide
3.  Parents everything under CharWatermelon_Root (Plain Axes empty at origin)
4.  Exports to  assets/characters/char_watermelon.glb

Character dimensions
--------------------
    Total height  : ~1.10 Blender units (feet at Z=0, stem tip ~Z=1.06)
    Body width    : 0.84 units (diameter, nearly round sphere)
    Forward axis  : -Y (character faces -Y, matching Godot -Z after import)

Design notes
------------
- Bright green rind body with 6 dark green vertical stripes
- Pink flesh disc on the -Y front face (the character's face panel)
- 7 black oval seeds arranged on the flesh disc
- Wide excited eyes (larger sclera than CharFruit)
- Big broad smile: major_radius=0.075 (vs. CharFruit's 0.046)
- Simple thin eyebrows angled up for excitement
- Short dark green stem at the top
- Arms/legs/mittens in body green; feet in slightly darker green
"""

import bpy
import math
import os
import bmesh
from mathutils import Vector

PREFIX = "CharWatermelon"

# ===========================================================================
#  HELPERS
# ===========================================================================

def clear_char():
    """Remove every object / mesh / material starting with PREFIX."""
    bpy.ops.object.select_all(action='DESELECT')
    for o in list(bpy.data.objects):
        if o.name.startswith(PREFIX):
            o.select_set(True)
    if any(o.select_get() for o in bpy.data.objects):
        bpy.ops.object.delete()
    for m in list(bpy.data.meshes):
        if m.users == 0:
            bpy.data.meshes.remove(m)
    for m in list(bpy.data.materials):
        if m.users == 0 and m.name.startswith(PREFIX):
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
    """Apply scale transform so mesh data has correct real-world size."""
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
print(f"\n[{PREFIX}] === BUILD START ===")


# ===========================================================================
#  MATERIALS
# ===========================================================================
M = {}
# Rind / body colour (used on body, arms, legs, mittens)
M['body']   = mk_mat(f"{PREFIX}_M_Body",   (0.18, 0.62, 0.18, 1.0))
# Dark green stripes and stem
M['stripe'] = mk_mat(f"{PREFIX}_M_Stripe", (0.08, 0.32, 0.08, 1.0))
M['stem']   = mk_mat(f"{PREFIX}_M_Stem",   (0.08, 0.30, 0.08, 1.0))
# Feet (slightly darker than body)
M['foot']   = mk_mat(f"{PREFIX}_M_Foot",   (0.85, 0.30, 0.40, 1.0))   # watermelon-flesh pink limb accent: arms/legs/feet
# Flesh disc (pink)
M['flesh']  = mk_mat(f"{PREFIX}_M_Flesh",  (0.95, 0.38, 0.50, 1.0))
# Black seeds on flesh
M['seed']   = mk_mat(f"{PREFIX}_M_Seed",   (0.06, 0.06, 0.06, 1.0))
# Face features
M['white']  = mk_mat(f"{PREFIX}_M_White",  (0.95, 0.95, 0.95, 1.0), roughness=0.55, specular=0.12)
M['pupil']  = mk_mat(f"{PREFIX}_M_Pupil",  (0.04, 0.04, 0.04, 1.0))
M['mouth']  = mk_mat(f"{PREFIX}_M_Mouth",  (0.25, 0.05, 0.03, 1.0))
M['brow']   = mk_mat(f"{PREFIX}_M_Brow",   (0.04, 0.18, 0.04, 1.0))


# ===========================================================================
#  LAYOUT CONSTANTS
#
#  Z stack (bottom → top)
#    0.000  ground / foot bottom
#    0.048  foot centre
#    0.140  leg centre
#    0.580  body centre              ← BZ
#    0.700  eye centre               ← EZ
#    0.795  brow centre              ← BROW_Z
#    0.980  stem base
#    1.040  stem centre
# ===========================================================================
BZ = 0.580    # body Z centre
BR = 0.420    # body XY radius  (from spec scale 0.42, 0.42, 0.44)
BH = 0.440    # body Z half-height

EZ     = 0.700   # eye Z
BROW_Z = 0.795   # brow Z

# The flesh disc sits on the front (-Y) face of the body.
# Body surface at x=0, z=BZ  →  y = -BR = -0.420
# We position the disc 0.006 in front of that, centre at FLESH_CENTER_Y.
FLESH_CENTER_Y = -(BR + 0.006)           # -0.426
FLESH_DEPTH    = 0.018
# Front face of flesh disc (the surface features sit on):
FLESH_FACE_Y   = FLESH_CENTER_Y - FLESH_DEPTH * 0.5 - 0.008   # ~ -0.443


def body_surface_y(x, z):
    """
    Y coordinate of the front face of the body ellipsoid at world (x, z).
    Returns a slightly inset value (0.008 units inside) to avoid z-fighting.
    """
    tz = (z - BZ) / BH
    tx = x / BR
    under = max(0.0, 1.0 - tz * tz - tx * tx)
    return -BR * math.sqrt(under) - 0.008


# ===========================================================================
#  STEP 2 — BODY (bright green rind sphere)
# ===========================================================================
bpy.ops.mesh.primitive_uv_sphere_add(
    radius=1.0, segments=20, ring_count=14,
    location=(0, 0, BZ)
)
body = bpy.context.active_object
body.name = f"{PREFIX}_Body"
body.scale = (BR, BR, BH)
apply_scale(body)
smooth(body)
set_mat(body, M['body'])
parts.append(body)
print(f"[{PREFIX}] Body ✓")


# ===========================================================================
#  STEP 3 — DARK GREEN VERTICAL STRIPES (6, evenly spaced)
#
#  Each stripe is a thin cube placed at the body surface and rotated so:
#    local X axis (scale 0.012) = radial direction → thin against body
#    local Y axis (scale 0.048) = tangential direction → visible stripe width
#    local Z axis (scale 0.80)  = height → runs top-to-bottom
#
#  Rotation is applied AFTER apply_scale so euler[2]=a cleanly orients
#  the already-scaled mesh.
# ===========================================================================
for i in range(6):
    a  = i * (2.0 * math.pi / 6.0)
    cx = BR * math.cos(a)
    cy = BR * math.sin(a)

    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(cx, cy, BZ))
    stripe = bpy.context.active_object
    stripe.name = f"{PREFIX}_Stripe_{i}"
    stripe.scale = (0.012, 0.048, 0.80)
    apply_scale(stripe)
    stripe.rotation_euler[2] = a
    set_mat(stripe, M['stripe'])
    parts.append(stripe)

print(f"[{PREFIX}] Stripes ✓")


# ===========================================================================
#  STEP 4 — PINK FLESH DISC (front face panel, faces -Y)
#
#  Cylinder with rotation=(π/2, 0, 0) so its circular faces point ±Y.
#  Radius 0.27 keeps it inside the body cross-section at all heights.
# ===========================================================================
bpy.ops.mesh.primitive_cylinder_add(
    radius=0.27, depth=FLESH_DEPTH,
    location=(0, FLESH_CENTER_Y, BZ),
    rotation=(math.pi / 2, 0, 0)
)
flesh = bpy.context.active_object
flesh.name = f"{PREFIX}_Flesh"
smooth(flesh)
set_mat(flesh, M['flesh'])
parts.append(flesh)
print(f"[{PREFIX}] Flesh disc ✓")


# ===========================================================================
#  STEP 5 — BLACK SEEDS ON FLESH DISC (7 seeds)
#
#  Positions given as (world X, world Z); Y is fixed just in front of the
#  flesh disc face so seeds sit proud of the surface.
# ===========================================================================
SEED_POS = [
    ( 0.000, BZ + 0.110),   # top centre
    (-0.110, BZ + 0.055),   # upper-left
    ( 0.110, BZ + 0.055),   # upper-right
    (-0.145, BZ - 0.010),   # mid-left
    ( 0.145, BZ - 0.010),   # mid-right
    (-0.085, BZ - 0.090),   # lower-left
    ( 0.085, BZ - 0.090),   # lower-right
]

for i, (sx, sz) in enumerate(SEED_POS):
    sy = FLESH_FACE_Y - 0.005
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=6, ring_count=4,
        location=(sx, sy, sz)
    )
    sd = bpy.context.active_object
    sd.name = f"{PREFIX}_Seed_{i}"
    sd.scale = (0.028, 0.010, 0.048)
    apply_scale(sd)
    sd.rotation_euler[0] = math.radians(12)   # slight tilt for naturalness
    smooth(sd)
    set_mat(sd, M['seed'])
    parts.append(sd)

print(f"[{PREFIX}] Seeds ✓")


# ===========================================================================
#  STEP 6 — EYES (large oval — wider and taller than CharFruit)
#
#  Sclera scale: (0.105, 0.026, 0.150) vs. CharFruit's (0.090, 0.028, 0.130)
#  Eyes are positioned on the flesh disc face surface (FLESH_FACE_Y).
# ===========================================================================
EYE_X = 0.118

for sx, suf in [(-EYE_X, 'L'), (EYE_X, 'R')]:
    # ── Sclera (white) ──────────────────────────────────────────────────────
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=14, ring_count=10,
        location=(sx, FLESH_FACE_Y - 0.005, EZ)
    )
    sc = bpy.context.active_object
    sc.name = f"{PREFIX}_Eye_{suf}"
    sc.scale = (0.105, 0.026, 0.150)
    apply_scale(sc)
    smooth(sc)
    set_mat(sc, M['white'])
    parts.append(sc)

    # ── Pupil ───────────────────────────────────────────────────────────────
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(sx, FLESH_FACE_Y - 0.012, EZ)
    )
    pu = bpy.context.active_object
    pu.name = f"{PREFIX}_Pupil_{suf}"
    pu.scale = (0.065, 0.020, 0.098)
    apply_scale(pu)
    smooth(pu)
    set_mat(pu, M['pupil'])
    parts.append(pu)

    # ── Highlight (tiny white dot, upper-inner of pupil) ────────────────────
    inner_sign = 1 if suf == 'L' else -1
    hl_x = sx + inner_sign * 0.028
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=6, ring_count=4,
        location=(hl_x, FLESH_FACE_Y - 0.018, EZ + 0.046)
    )
    hl = bpy.context.active_object
    hl.name = f"{PREFIX}_EyeHL_{suf}"
    hl.scale = (0.026, 0.012, 0.037)
    apply_scale(hl)
    smooth(hl)
    set_mat(hl, M['white'])
    parts.append(hl)

print(f"[{PREFIX}] Eyes ✓")


# ===========================================================================
#  STEP 7 — EYEBROWS (thin, angled up sharply for excited expression)
# ===========================================================================
BROW_Y = FLESH_FACE_Y - 0.004

for sx, suf, sign in [(-EYE_X, 'L', -1), (EYE_X, 'R', 1)]:
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(sx, BROW_Y, BROW_Z))
    brow = bpy.context.active_object
    brow.name = f"{PREFIX}_Brow_{suf}"
    brow.scale = (0.080, 0.012, 0.020)
    apply_scale(brow)
    brow.rotation_euler[0] = math.radians(8)
    brow.rotation_euler[2] = math.radians(-22 * sign)   # steeper angle = more excited
    set_mat(brow, M['brow'])
    parts.append(brow)

print(f"[{PREFIX}] Eyebrows ✓")


# ===========================================================================
#  STEP 8 — MOUTH (broad ∪ smile)
#
#  major_radius=0.075 → significantly wider grin than CharFruit (0.046).
#  Same half-torus technique: full torus with rotation=(π/2, 0, 0), then
#  delete local-Y > 0 verts in edit mode, leaving the bottom-arc ∪ smile.
# ===========================================================================
MOUTH_Z = 0.612
MOUTH_Y = FLESH_FACE_Y - 0.005

bpy.ops.mesh.primitive_torus_add(
    major_radius=0.075,
    minor_radius=0.014,
    major_segments=24,
    minor_segments=8,
    location=(0, MOUTH_Y, MOUTH_Z),
    rotation=(math.pi / 2, 0, 0)
)
mth = bpy.context.active_object
mth.name = f"{PREFIX}_Mouth"

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
print(f"[{PREFIX}] Mouth ✓")


# ===========================================================================
#  STEP 9 — STEM (short dark green stub at top, like a real watermelon)
# ===========================================================================
STEM_BASE_Z = BZ + BH - 0.04   # ≈ 0.980
bpy.ops.mesh.primitive_cylinder_add(
    radius=0.025, depth=0.12,
    location=(0, 0, STEM_BASE_Z + 0.065)
)
stem_obj = bpy.context.active_object
stem_obj.name = f"{PREFIX}_Stem"
smooth(stem_obj)
set_mat(stem_obj, M['stem'])
parts.append(stem_obj)
print(f"[{PREFIX}] Stem ✓")


# ===========================================================================
#  STEP 10 — ARMS (horizontal cylinders + mitten hands, all green)
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
    arm.name = f"{PREFIX}_Arm_{suf}"
    smooth(arm)
    set_mat(arm, M['foot'])
    parts.append(arm)

    mit_x = sign * (BR + ARM_GAP + ARM_HALF * 2 + 0.024)
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(mit_x, 0, ARM_Z - 0.012)
    )
    mit = bpy.context.active_object
    mit.name = f"{PREFIX}_Mitten_{suf}"
    mit.scale = (0.078, 0.066, 0.062)
    apply_scale(mit)
    smooth(mit)
    set_mat(mit, M['foot'])
    parts.append(mit)

print(f"[{PREFIX}] Arms ✓")


# ===========================================================================
#  STEP 11 — LEGS AND FEET
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
    leg.name = f"{PREFIX}_Leg_{suf}"
    smooth(leg)
    set_mat(leg, M['foot'])
    parts.append(leg)

    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(lx, 0.020, FOOT_Z)
    )
    foot = bpy.context.active_object
    foot.name = f"{PREFIX}_Foot_{suf}"
    foot.scale = (0.078, 0.058, 0.048)
    apply_scale(foot)
    smooth(foot)
    set_mat(foot, M['foot'])
    parts.append(foot)

print(f"[{PREFIX}] Legs ✓")


# ===========================================================================
#  ARMATURE (replaces plain-empty root) — 5 bones: Hips + 4 limb bones,
#  matching Godot's canonical humanoid names so retargeted UAL locomotion
#  clips apply directly. See assets/characters/build_char_fruit.py for the
#  original prototype and assets/animations/build_character_locomotion.py
#  for the shared retarget bake.
# ===========================================================================
bpy.ops.object.armature_add(enter_editmode=True, location=(0, 0, 0))
root = bpy.context.active_object
root.name = PREFIX + "_Root"
arm_data = root.data
arm_data.name = PREFIX + "_Skeleton"

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
print(f"[{PREFIX}] Armature done (Hips, LeftUpperArm, RightUpperArm, LeftUpperLeg, RightUpperLeg)")


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
    "LeftUpperArm":  [PREFIX + "_Arm_L", PREFIX + "_Mitten_L"],
    "RightUpperArm": [PREFIX + "_Arm_R", PREFIX + "_Mitten_R"],
    "LeftUpperLeg":  [PREFIX + "_Leg_L", PREFIX + "_Foot_L"],
    "RightUpperLeg": [PREFIX + "_Leg_R", PREFIX + "_Foot_R"],
}
limb_parts = set()
for bone_name, names in limb_names.items():
    objs = [by_name[n] for n in names if n in by_name]
    limb_parts.update(objs)
    bone_parent_group(objs, bone_name)

hips_parts = [p for p in parts if p not in limb_parts]
bone_parent_group(hips_parts, "Hips")

print(f"[{PREFIX}] Bone-parented {len(parts)} parts -> " + PREFIX + "_Root skeleton")


# ===========================================================================
#  EXPORT GLB — rig + rest pose only, no animation data (shared locomotion
#  clips are merged onto the AnimationPlayer at runtime by player.gd).
# ===========================================================================
out = "/Users/zhihao/personal_projects/ropedart-arena/assets/characters/char_watermelon.glb"
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

print(f"[{PREFIX}] Exported -> {out}")
print(f"[{PREFIX}] === BUILD COMPLETE ===\n")
