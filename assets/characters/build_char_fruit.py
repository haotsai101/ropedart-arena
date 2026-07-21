"""
Rope Dart Arena — Strawberry Character Rebuild
==============================================
Paste this entire file into Blender's Script Editor (Text → Run Script).
Requires Blender 4.x (tested 4.0-4.4). Standard build, no add-ons needed.

What it does
------------
1.  Deletes all existing CharFruit_* objects / orphan data
2.  Rebuilds the character from scratch following the style guide
3.  Builds a 5-bone Armature named CharFruit_Root (Hips + 4 limb bones) and
    rigidly bone-parents every mesh piece to it (no vertex weights — each
    limb is a single rigid piece). Bone names match Godot's canonical
    humanoid names so retargeted UAL locomotion clips apply directly.
4.  Exports to  assets/characters/char_fruit.glb  (rig + rest pose, no anim)

Character dimensions
--------------------
    Total height  : ~1.08 Blender units (feet at Z=0, leaf tip ~Z=1.08)
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
    """Remove every object / mesh / material starting with 'CharFruit'."""
    bpy.ops.object.select_all(action='DESELECT')
    for o in list(bpy.data.objects):
        if o.name.startswith("CharFruit"):
            o.select_set(True)
    if any(o.select_get() for o in bpy.data.objects):
        bpy.ops.object.delete()
    for m in list(bpy.data.meshes):
        if m.users == 0:
            bpy.data.meshes.remove(m)
    for m in list(bpy.data.materials):
        if m.users == 0 and m.name.startswith("CharFruit"):
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
clear_char()
parts = []   # collect all mesh objects for parenting at the end
print("\n[CharFruit] === BUILD START ===")


# ===========================================================================
#  MATERIALS
# ===========================================================================
M = {}
# Body
M['body']   = mk_mat("CharFruit_M_Body",   (0.85, 0.08, 0.04, 1.0))
M['dark']   = mk_mat("CharFruit_M_Dark",   (0.12, 0.48, 0.10, 1.0))   # vine-green limb accent: arms/legs/feet
M['mitten'] = mk_mat("CharFruit_M_Mitten", (0.16, 0.54, 0.14, 1.0))   # lighter vine-green for hands
# Foliage
M['leaf']   = mk_mat("CharFruit_M_Leaf",   (0.06, 0.55, 0.07, 1.0))
M['stem']   = mk_mat("CharFruit_M_Stem",   (0.02, 0.28, 0.02, 1.0))
# Face
M['white']  = mk_mat("CharFruit_M_White",  (0.95, 0.95, 0.95, 1.0), roughness=0.55, specular=0.12)
M['pupil']  = mk_mat("CharFruit_M_Pupil",  (0.04, 0.04, 0.04, 1.0))
M['brow']   = mk_mat("CharFruit_M_Brow",   (0.08, 0.04, 0.02, 1.0))
M['mouth']  = mk_mat("CharFruit_M_Mouth",  (0.25, 0.05, 0.03, 1.0))
M['blush']  = mk_mat("CharFruit_M_Blush",  (0.94, 0.52, 0.52, 1.0), roughness=0.90)
# Decorative
M['seed']   = mk_mat("CharFruit_M_Seed",   (0.95, 0.88, 0.65, 1.0), roughness=0.90)


# ===========================================================================
#  LAYOUT CONSTANTS
# All positions in world space, character faces -Y.
#
#  Z stack (bottom → top)
#    0.000  ground / foot bottom
#    0.048  foot centre
#    0.140  leg centre
#    0.580  body centre         ← BZ
#    0.700  eye centre          ← EZ
#    0.806  brow centre
#    0.940  leaf petal base
#    1.060  stem centre
# ===========================================================================
BZ   = 0.580   # body Z centre
BR   = 0.380   # body XY radius
BH   = 0.420   # body half-height
EZ   = 0.700   # eye Z
FY   = -0.360  # face front Y at eye height (≈ body surface)


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
#  STEP 2 — BODY
#  UV Sphere, slightly taller than wide, smooth shaded.
# ===========================================================================
bpy.ops.mesh.primitive_uv_sphere_add(
    radius=1.0, segments=20, ring_count=14,
    location=(0, 0, BZ)
)
body = bpy.context.active_object
body.name = "CharFruit_Body"
body.scale = (BR, BR, BH)
apply_scale(body)
smooth(body)
set_mat(body, M['body'])
parts.append(body)
print("[CharFruit] Body ✓")


# ===========================================================================
#  STEP 3 — LEAF CAP (5 petals + stem)
#  Each petal is a cone with its tip pointing outward+upward at 38° from Z.
#  The base (wide end, radius1=0.07) sits near the body top.
# ===========================================================================
LEAF_BASE_Z = BZ + BH - 0.06   # ≈ 0.940

PETAL_DEPTH = 0.20
PETAL_HALF  = PETAL_DEPTH * 0.5

for i in range(5):
    a     = i * (2.0 * math.pi / 5.0)
    tilt  = math.radians(38)
    # Unit vector pointing in the petal's axis direction
    d = Vector((
        math.sin(tilt) * math.cos(a),
        math.sin(tilt) * math.sin(a),
        math.cos(tilt)
    ))
    # Cone centre = base_point + half_depth * d
    base_pt = Vector((0, 0, LEAF_BASE_Z))
    centre  = base_pt + d * PETAL_HALF

    bpy.ops.mesh.primitive_cone_add(
        radius1=0.070, radius2=0.005, depth=PETAL_DEPTH,
        location=(centre.x, centre.y, centre.z)
    )
    petal = bpy.context.active_object
    petal.name = f"CharFruit_Leaf_{i}"

    # Rotate so the cone's local +Z axis aligns with direction d
    q = Vector((0, 0, 1)).rotation_difference(d)
    petal.rotation_mode = 'QUATERNION'
    petal.rotation_quaternion = q

    smooth(petal)
    set_mat(petal, M['leaf'])
    parts.append(petal)

# Stem — thin cylinder rising from petal base
bpy.ops.mesh.primitive_cylinder_add(
    radius=0.025, depth=0.16,
    location=(0, 0, LEAF_BASE_Z + 0.105)
)
stem = bpy.context.active_object
stem.name = "CharFruit_Stem"
smooth(stem)
set_mat(stem, M['stem'])
parts.append(stem)
print("[CharFruit] Leaf cap ✓")


# ===========================================================================
#  STEP 4 — EYES (LARGE oval — dominant facial feature)
#
#  Each eye = sclera (white oval) + pupil (dark oval) + highlight spot.
#  Scale X:0.090 Y:0.028(flat) Z:0.130  →  wide, flat, tall oval.
#  Eyes span ~59% of body width, height ~31% of body height.
# ===========================================================================
EYE_X  =  0.135   # lateral centre of each eye
FACE_Y_EYE = body_surface_y(EYE_X, EZ) + 0.012  # sit on face surface

for sx, suf in [(-EYE_X, 'L'), (EYE_X, 'R')]:
    # ── Sclera (white) ──────────────────────────────────────────────
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=14, ring_count=10,
        location=(sx, FACE_Y_EYE, EZ)
    )
    sc = bpy.context.active_object
    sc.name = f"CharFruit_Eye_{suf}"
    sc.scale = (0.090, 0.028, 0.130)
    apply_scale(sc)
    smooth(sc)
    set_mat(sc, M['white'])
    parts.append(sc)

    # ── Pupil (dark, slightly forward of sclera) ─────────────────────
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(sx, FACE_Y_EYE - 0.008, EZ)
    )
    pu = bpy.context.active_object
    pu.name = f"CharFruit_Pupil_{suf}"
    pu.scale = (0.053, 0.022, 0.084)
    apply_scale(pu)
    smooth(pu)
    set_mat(pu, M['pupil'])
    parts.append(pu)

    # ── Highlight (tiny white spot, upper-inner quadrant of pupil) ────
    # "inner" direction = toward X=0, so for L eye inner is +X, for R eye it's -X
    inner_sign = 1 if suf == 'L' else -1
    hl_x = sx + inner_sign * 0.024
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=6, ring_count=4,
        location=(hl_x, FACE_Y_EYE - 0.013, EZ + 0.038)
    )
    hl = bpy.context.active_object
    hl.name = f"CharFruit_EyeHL_{suf}"
    hl.scale = (0.022, 0.013, 0.032)
    apply_scale(hl)
    smooth(hl)
    set_mat(hl, M['white'])
    parts.append(hl)

print("[CharFruit] Eyes ✓")


# ===========================================================================
#  STEP 5 — EYEBROWS
#  Flat cube arches above each eye.
#  inner edge lower, outer edge higher → friendly-determined look.
# ===========================================================================
BROW_Z = 0.806
BROW_Y = body_surface_y(EYE_X, BROW_Z) + 0.010

for sx, suf, sign in [(-EYE_X, 'L', -1), (EYE_X, 'R', 1)]:
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(sx, BROW_Y, BROW_Z))
    brow = bpy.context.active_object
    brow.name = f"CharFruit_Brow_{suf}"
    brow.scale = (0.077, 0.013, 0.024)
    apply_scale(brow)
    # Arch: inner down, outer up — tilt around Z; slight forward lean around X
    brow.rotation_euler[0] = math.radians(8)
    brow.rotation_euler[2] = math.radians(-15 * sign)
    set_mat(brow, M['brow'])
    parts.append(brow)

print("[CharFruit] Eyebrows ✓")


# ===========================================================================
#  STEP 6 — MOUTH (half-torus ∪ smile)
#
#  Approach: create a full torus with rotation=(π/2, 0, 0) so the ring lies in
#  the XZ world plane (visible as a circle from front / -Y view).
#  Then in edit mode delete the LOCAL top half (local Y > 0), which corresponds
#  to the UPPER world arc (Z > mouth centre), leaving the ∪ bottom smile arc.
#
#  Rotation maths (rotate π/2 around X):
#    local +Y  →  world +Z   (top arc)
#    local -Y  →  world -Z   (bottom arc = ∪ smile we keep)
# ===========================================================================
MOUTH_Z = 0.623
MOUTH_Y = body_surface_y(0.0, MOUTH_Z) + 0.005

bpy.ops.mesh.primitive_torus_add(
    major_radius=0.046,
    minor_radius=0.011,
    major_segments=24,
    minor_segments=8,
    location=(0, MOUTH_Y, MOUTH_Z),
    rotation=(math.pi / 2, 0, 0)
)
mth = bpy.context.active_object
mth.name = "CharFruit_Mouth"

# Delete top-half vertices (local Y > 0 → upper/frown arc in world)
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
print("[CharFruit] Mouth ✓")


# ===========================================================================
#  STEP 7 — BLUSH CIRCLES (cheeks, optional per style guide)
# ===========================================================================
BLUSH_Z = 0.645

for sx, suf in [(-0.220, 'L'), (0.220, 'R')]:
    by = body_surface_y(sx, BLUSH_Z) + 0.004
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=8, ring_count=6,
        location=(sx, by, BLUSH_Z)
    )
    bl = bpy.context.active_object
    bl.name = f"CharFruit_Blush_{suf}"
    bl.scale = (0.055, 0.012, 0.038)
    apply_scale(bl)
    smooth(bl)
    set_mat(bl, M['blush'])
    parts.append(bl)

print("[CharFruit] Blush ✓")


# ===========================================================================
#  STEP 8 — ARMS (floating, mitten hands)
#
#  Arms float: a small gap between body surface (x ≈ ±0.380) and arm end.
#  Cylinder depth=0.130, half=0.065.
#  Arm centre at x = ±(0.380 + gap + half) = ±(0.380 + 0.022 + 0.065) = ±0.467
# ===========================================================================
ARM_Z    = BZ - 0.020   # slightly below body equator for natural hang
ARM_GAP  = 0.022
ARM_HALF = 0.065

for sign, suf in [(-1, 'L'), (1, 'R')]:
    cx = sign * (BR + ARM_GAP + ARM_HALF)

    bpy.ops.mesh.primitive_cylinder_add(
        radius=0.046, depth=0.130,
        location=(cx, 0, ARM_Z),
        rotation=(0, math.pi / 2, 0)   # local Z → world X (horizontal)
    )
    arm = bpy.context.active_object
    arm.name = f"CharFruit_Arm_{suf}"
    smooth(arm)
    set_mat(arm, M['dark'])
    parts.append(arm)

    # Mitten hand — rounded blob, slightly past the arm end
    mit_x = sign * (BR + ARM_GAP + ARM_HALF * 2 + 0.024)
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(mit_x, 0, ARM_Z - 0.012)
    )
    mit = bpy.context.active_object
    mit.name = f"CharFruit_Mitten_{suf}"
    mit.scale = (0.078, 0.066, 0.062)
    apply_scale(mit)
    smooth(mit)
    set_mat(mit, M['mitten'])
    parts.append(mit)

print("[CharFruit] Arms ✓")


# ===========================================================================
#  STEP 9 — LEGS AND FEET
#
#  Two stubby cylinders under the body, angled slightly outward.
#  Foot nubs: flattened spheres, bottom edge at Z=0 (ground).
# ===========================================================================
LEG_X    = 0.115
LEG_Z    = 0.140    # leg centre
FOOT_Z   = 0.048    # foot centre (scale Z=0.048 → bottom at 0)

for sign, suf in [(-1, 'L'), (1, 'R')]:
    lx = sign * LEG_X

    bpy.ops.mesh.primitive_cylinder_add(
        radius=0.058, depth=0.100,
        location=(lx, 0.010, LEG_Z),
        rotation=(math.radians(4 * sign), 0, 0)   # slight outward tilt
    )
    leg = bpy.context.active_object
    leg.name = f"CharFruit_Leg_{suf}"
    smooth(leg)
    set_mat(leg, M['dark'])
    parts.append(leg)

    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(lx, 0.020, FOOT_Z)
    )
    foot = bpy.context.active_object
    foot.name = f"CharFruit_Foot_{suf}"
    foot.scale = (0.078, 0.058, 0.048)
    apply_scale(foot)
    smooth(foot)
    set_mat(foot, M['dark'])
    parts.append(foot)

print("[CharFruit] Legs ✓")


# ===========================================================================
#  STEP 10 — SEEDS
#  5 cream-coloured oval nubs on the front of the body.
#  Positions are solved against the body ellipsoid so they sit flush.
# ===========================================================================
SEED_CONFIGS = [
    ( 0.000, 0.770),   # top centre
    (-0.155, 0.635),   # upper-left
    ( 0.155, 0.635),   # upper-right
    (-0.095, 0.500),   # lower-left
    ( 0.095, 0.500),   # lower-right
]

for i, (sx, sz) in enumerate(SEED_CONFIGS):
    sy = body_surface_y(sx, sz) + 0.002
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=6, ring_count=4,
        location=(sx, sy, sz)
    )
    seed = bpy.context.active_object
    seed.name = f"CharFruit_Seed_{i}"
    seed.scale = (0.038, 0.012, 0.056)
    apply_scale(seed)
    smooth(seed)
    set_mat(seed, M['seed'])
    parts.append(seed)

print("[CharFruit] Seeds ✓")


# ===========================================================================
#  STEP 11 — ARMATURE (CharFruit_Root is now a 5-bone Armature, not an Empty)
#
#  Rigid rig only — no vertex weights. Each limb is a single rigid piece, so
#  we only need one bone per limb (no upper/lower split): Hips (torso pivot,
#  everything except limbs hangs off this), LeftUpperArm/RightUpperArm
#  (shoulder → mitten), LeftUpperLeg/RightUpperLeg (hip → foot). Bone names
#  match Godot's canonical humanoid skeleton names so retargeted UAL
#  (Universal Animation Library) clips apply directly without remapping —
#  see assets/animations/build_character_locomotion.py.
# ===========================================================================
bpy.ops.object.armature_add(enter_editmode=True, location=(0, 0, 0))
root = bpy.context.active_object
root.name = "CharFruit_Root"
arm_data = root.data
arm_data.name = "CharFruit_Skeleton"

eb = arm_data.edit_bones
for b in list(eb):
    eb.remove(b)

hips = eb.new("Hips")
hips.head = Vector((0, 0, BZ - BH * 0.3))
hips.tail = Vector((0, 0, BZ + BH * 0.3))

lua = eb.new("LeftUpperArm")
lua.head = Vector((-(BR + ARM_GAP), 0, ARM_Z))
lua.tail = Vector((-(BR + ARM_GAP + ARM_HALF * 2), 0, ARM_Z))
lua.parent = hips
lua.use_connect = False

rua = eb.new("RightUpperArm")
rua.head = Vector((BR + ARM_GAP, 0, ARM_Z))
rua.tail = Vector((BR + ARM_GAP + ARM_HALF * 2, 0, ARM_Z))
rua.parent = hips
rua.use_connect = False

lul = eb.new("LeftUpperLeg")
lul.head = Vector((-LEG_X, 0, LEG_Z + 0.05))
lul.tail = Vector((-LEG_X, 0, FOOT_Z))
lul.parent = hips
lul.use_connect = False

rul = eb.new("RightUpperLeg")
rul.head = Vector((LEG_X, 0, LEG_Z + 0.05))
rul.tail = Vector((LEG_X, 0, FOOT_Z))
rul.parent = hips
rul.use_connect = False

bpy.ops.object.mode_set(mode='OBJECT')
print("[CharFruit] Armature ✓ (Hips, LeftUpperArm, RightUpperArm, LeftUpperLeg, RightUpperLeg)")


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
    "LeftUpperArm":  ["CharFruit_Arm_L", "CharFruit_Mitten_L"],
    "RightUpperArm": ["CharFruit_Arm_R", "CharFruit_Mitten_R"],
    "LeftUpperLeg":  ["CharFruit_Leg_L", "CharFruit_Foot_L"],
    "RightUpperLeg": ["CharFruit_Leg_R", "CharFruit_Foot_R"],
}
limb_parts = set()
for bone_name, names in limb_names.items():
    objs = [by_name[n] for n in names if n in by_name]
    limb_parts.update(objs)
    bone_parent_group(objs, bone_name)

# Everything else (body, face, decorations) rigidly parents to Hips
hips_parts = [p for p in parts if p not in limb_parts]
bone_parent_group(hips_parts, "Hips")

print(f"[CharFruit] Bone-parented {len(parts)} parts → CharFruit_Root skeleton")


# ===========================================================================
#  STEP 12 — EXPORT GLB
#  No animation data — this file is rig + rest pose only. Locomotion clips
#  live in the shared assets/animations/character_locomotion.glb and are
#  merged onto this character's AnimationPlayer at runtime by player.gd.
# ===========================================================================
out = "/Users/zhihao/personal_projects/ropedart-arena/assets/characters/char_fruit.glb"
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

print(f"[CharFruit] Exported → {out}")
print("[CharFruit] === BUILD COMPLETE ===\n")
