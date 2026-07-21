"""
Rope Dart Arena — Durian Character Build
==========================================
Run headlessly:
  /Applications/Blender.app/Contents/MacOS/Blender --background --python \
    /Users/zhihao/personal_projects/ropedart-arena/assets/characters/build_char_durian.py

What it does
------------
1.  Deletes all existing CharDurian_* objects / orphan data
2.  Rebuilds the character from scratch following the style guide
3.  Parents everything under CharDurian_Root (Plain Axes empty at origin)
4.  Exports to  assets/characters/char_durian.glb

Character dimensions
--------------------
    Total height  : ~1.05 Blender units (feet at Z=0, spike tips ~Z=1.05)
    Body width    : 0.80 units (diameter)
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
    """Remove every object / mesh / material starting with 'CharDurian'."""
    bpy.ops.object.select_all(action='DESELECT')
    for o in list(bpy.data.objects):
        if o.name.startswith("CharDurian"):
            o.select_set(True)
    if any(o.select_get() for o in bpy.data.objects):
        bpy.ops.object.delete()
    for m in list(bpy.data.meshes):
        if m.users == 0:
            bpy.data.meshes.remove(m)
    for m in list(bpy.data.materials):
        if m.users == 0 and m.name.startswith("CharDurian"):
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
#  STEP 1 — CLEAR
# ===========================================================================
# Delete everything in the default scene before building
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)

clear_char()
parts = []
print("\n[CharDurian] === BUILD START ===")


# ===========================================================================
#  MATERIALS
# ===========================================================================
M = {}
# Body — green-yellow durian skin
M['body']   = mk_mat("CharDurian_M_Body",   (0.62, 0.72, 0.15, 1.0))
# Spikes — slightly darker green-yellow
M['spike']  = mk_mat("CharDurian_M_Spike",  (0.45, 0.58, 0.08, 1.0))
# Feet — darker green
M['foot']   = mk_mat("CharDurian_M_Foot",   (0.90, 0.78, 0.50, 1.0))   # pale custard-flesh limb accent: arms/legs/feet
# Face
M['white']  = mk_mat("CharDurian_M_White",  (0.95, 0.95, 0.95, 1.0), roughness=0.55, specular=0.12)
M['pupil']  = mk_mat("CharDurian_M_Pupil",  (0.04, 0.04, 0.04, 1.0))
M['brow']   = mk_mat("CharDurian_M_Brow",   (0.08, 0.05, 0.01, 1.0))
M['mouth']  = mk_mat("CharDurian_M_Mouth",  (0.18, 0.08, 0.02, 1.0))


# ===========================================================================
#  LAYOUT CONSTANTS
#
#  Z stack (bottom -> top)
#    0.000  ground / foot bottom
#    0.048  foot centre
#    0.140  leg centre
#    0.580  body centre          <- BZ
#    0.700  eye centre           <- EZ
#    0.812  brow centre
#    0.624  mouth centre
# ===========================================================================
BZ    = 0.580   # body Z centre
BR    = 0.400   # body XY radius
BH    = 0.440   # body Z half-height
EZ    = 0.700   # eye Z
EYE_X = 0.120   # lateral centre of each eye


def body_surface_y(x, z):
    """
    Y coordinate of the front face of the body ellipsoid at world (x, z).
    Returns slightly inset (0.008 units inside) to avoid z-fighting.
    """
    tz = (z - BZ) / BH
    tx = x / BR
    under = max(0.0, 1.0 - tz * tz - tx * tx)
    return -BR * math.sqrt(under) - 0.008


# ===========================================================================
#  STEP 2 — BODY
#  UV Sphere scaled (0.40, 0.40, 0.44), centre at Z=0.58.
# ===========================================================================
bpy.ops.mesh.primitive_uv_sphere_add(
    radius=1.0, segments=20, ring_count=14,
    location=(0, 0, BZ)
)
body = bpy.context.active_object
body.name = "CharDurian_Body"
body.scale = (BR, BR, BH)
apply_scale(body)
smooth(body)
set_mat(body, M['body'])
parts.append(body)
print("[CharDurian] Body ✓")


# ===========================================================================
#  STEP 3 — SPIKES (rounded bullet / pimple shape)
#
#  Each spike = UV sphere scaled (0.055, 0.055, 0.10) — bullet shape.
#  The total Z extent of the scaled sphere is 0.20 units; half = 0.10.
#  Centre is placed at body_surface + 0.10 * outward_normal, so the base
#  sits flush at the surface and the tip extends 0.20 units outward.
#
#  Distribution: Fibonacci / golden-angle sphere, 90-point pool.
#  Filter: skip any point whose direction is within 55° of -Y (face area).
#  Filter: skip points near the bottom (uz < -0.60) to keep feet clear.
# ===========================================================================
SPIKE_TARGET   = 16
SPIKE_HALF     = 0.10   # half of the bullet's total Z extent (0.20)
N_POOL         = 90
golden_angle   = math.pi * (3.0 - math.sqrt(5.0))   # ~2.3998 rad
cos_face_limit = math.cos(math.radians(55.0))         # ~0.574

spikes_placed = 0
for k in range(N_POOL):
    if spikes_placed >= SPIKE_TARGET:
        break

    # Fibonacci sphere: evenly distributed points on a unit sphere
    cos_phi = 1.0 - (2.0 * k + 1.0) / N_POOL   # latitude, from +1 to -1
    sin_phi = math.sqrt(max(0.0, 1.0 - cos_phi * cos_phi))
    theta   = golden_angle * k                    # azimuth

    # Unit sphere XYZ in Blender space (face direction = -Y)
    ux = sin_phi * math.cos(theta)
    uy = sin_phi * math.sin(theta)
    uz = cos_phi

    # Skip if within 55° of -Y (face area)
    # cos(angle_to_neg_Y) = dot((ux,uy,uz),(0,-1,0)) = -uy
    if -uy > cos_face_limit:
        continue

    # Skip near the feet / bottom pole
    if uz < -0.60:
        continue

    # --- Ellipsoid surface point ---
    px = ux * BR
    py = uy * BR
    pz = BZ + uz * BH

    # --- Outward normal on the ellipsoid ---
    # Gradient of (x/BR)^2 + (y/BR)^2 + ((z-BZ)/BH)^2 = 1
    # is proportional to (ux/BR, uy/BR, uz/BH) — already unit-sphere scaled
    nx = ux / BR
    ny = uy / BR
    nz = uz / BH
    nl = math.sqrt(nx * nx + ny * ny + nz * nz)
    nx, ny, nz = nx / nl, ny / nl, nz / nl

    # Spike centre = surface + half_depth along normal
    cx = px + nx * SPIKE_HALF
    cy = py + ny * SPIKE_HALF
    cz = pz + nz * SPIKE_HALF

    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(cx, cy, cz)
    )
    spike = bpy.context.active_object
    spike.name = f"CharDurian_Spike_{spikes_placed}"
    spike.scale = (0.055, 0.055, 0.10)
    apply_scale(spike)

    # Rotate so local +Z aligns with outward normal (tip points away from body)
    q = Vector((0.0, 0.0, 1.0)).rotation_difference(Vector((nx, ny, nz)))
    spike.rotation_mode = 'QUATERNION'
    spike.rotation_quaternion = q

    smooth(spike)
    set_mat(spike, M['spike'])
    parts.append(spike)
    spikes_placed += 1

print(f"[CharDurian] Spikes ✓  ({spikes_placed} placed)")


# ===========================================================================
#  STEP 4 — EYES (narrowed / squinting — tough, determined look)
#
#  Sclera: scale (0.082, 0.024, 0.095) — slightly shorter/squintier.
#  Pupils: proportionally larger than char_fruit to read as intense.
# ===========================================================================
FACE_Y_EYE = body_surface_y(EYE_X, EZ) + 0.012

for sx, suf in [(-EYE_X, 'L'), (EYE_X, 'R')]:
    # --- Sclera ---
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=14, ring_count=10,
        location=(sx, FACE_Y_EYE, EZ)
    )
    sc = bpy.context.active_object
    sc.name = f"CharDurian_Eye_{suf}"
    sc.scale = (0.082, 0.024, 0.095)
    apply_scale(sc)
    smooth(sc)
    set_mat(sc, M['white'])
    parts.append(sc)

    # --- Pupil (slightly larger relative to sclera for intensity) ---
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(sx, FACE_Y_EYE - 0.008, EZ)
    )
    pu = bpy.context.active_object
    pu.name = f"CharDurian_Pupil_{suf}"
    pu.scale = (0.056, 0.020, 0.072)
    apply_scale(pu)
    smooth(pu)
    set_mat(pu, M['pupil'])
    parts.append(pu)

    # --- Eye highlight (upper-inner quadrant) ---
    inner_sign = 1 if suf == 'L' else -1
    hl_x = sx + inner_sign * 0.020
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=6, ring_count=4,
        location=(hl_x, FACE_Y_EYE - 0.012, EZ + 0.030)
    )
    hl = bpy.context.active_object
    hl.name = f"CharDurian_EyeHL_{suf}"
    hl.scale = (0.020, 0.012, 0.028)
    apply_scale(hl)
    smooth(hl)
    set_mat(hl, M['white'])
    parts.append(hl)

print("[CharDurian] Eyes ✓")


# ===========================================================================
#  STEP 5 — EYEBROWS (thick furrowed — angry / determined)
#
#  Wide flat cubes: scale (0.085, 0.015, 0.028).
#  Tilted -22 * sign degrees around Z so inner edges are LOWER:
#    Left brow  (sign=-1): Z rotation = +22° → inner (+X) side goes down ✓
#    Right brow (sign=+1): Z rotation = -22° → inner (-X) side goes down ✓
#  Placed close above the eye line.
# ===========================================================================
BROW_Z = 0.812
BROW_Y = body_surface_y(EYE_X, BROW_Z) + 0.010

for sx, suf, sign in [(-EYE_X, 'L', -1), (EYE_X, 'R', 1)]:
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(sx, BROW_Y, BROW_Z))
    brow = bpy.context.active_object
    brow.name = f"CharDurian_Brow_{suf}"
    brow.scale = (0.085, 0.015, 0.028)
    apply_scale(brow)
    brow.rotation_euler[0] = math.radians(6)          # slight forward lean
    brow.rotation_euler[2] = math.radians(-22 * sign) # inner edge lower
    set_mat(brow, M['brow'])
    parts.append(brow)

print("[CharDurian] Eyebrows ✓")


# ===========================================================================
#  STEP 6 — MOUTH (tiny grin — small half-torus)
#
#  major_radius=0.032, minor_radius=0.009 — compact, confident smile.
#  Same technique as char_fruit: full torus rotated π/2 around X, then
#  delete local-Y > 0 vertices to leave the lower smile arc.
# ===========================================================================
MOUTH_Z = 0.624
MOUTH_Y = body_surface_y(0.0, MOUTH_Z) + 0.005

bpy.ops.mesh.primitive_torus_add(
    major_radius=0.032,
    minor_radius=0.009,
    major_segments=24,
    minor_segments=8,
    location=(0, MOUTH_Y, MOUTH_Z),
    rotation=(math.pi / 2, 0, 0)
)
mth = bpy.context.active_object
mth.name = "CharDurian_Mouth"

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
print("[CharDurian] Mouth ✓")


# ===========================================================================
#  STEP 7 — ARMS (floating cylinder + mitten hand)
#  Body color (green-yellow) for both arm and mitten.
# ===========================================================================
ARM_Z    = BZ - 0.020   # slightly below body equator
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
    arm.name = f"CharDurian_Arm_{suf}"
    smooth(arm)
    set_mat(arm, M['foot'])
    parts.append(arm)

    # Mitten — rounded blob just past arm end
    mit_x = sign * (BR + ARM_GAP + ARM_HALF * 2 + 0.024)
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(mit_x, 0, ARM_Z - 0.012)
    )
    mit = bpy.context.active_object
    mit.name = f"CharDurian_Mitten_{suf}"
    mit.scale = (0.078, 0.066, 0.062)
    apply_scale(mit)
    smooth(mit)
    set_mat(mit, M['foot'])
    parts.append(mit)

print("[CharDurian] Arms ✓")


# ===========================================================================
#  STEP 8 — LEGS AND FEET
#  Legs: body color (green-yellow). Feet: darker green.
# ===========================================================================
LEG_X  = 0.115
LEG_Z  = 0.140
FOOT_Z = 0.048   # centre; scale Z=0.048 → bottom edge at Z≈0

for sign, suf in [(-1, 'L'), (1, 'R')]:
    lx = sign * LEG_X

    bpy.ops.mesh.primitive_cylinder_add(
        radius=0.058, depth=0.100,
        location=(lx, 0.010, LEG_Z),
        rotation=(math.radians(4 * sign), 0, 0)   # slight outward tilt
    )
    leg = bpy.context.active_object
    leg.name = f"CharDurian_Leg_{suf}"
    smooth(leg)
    set_mat(leg, M['foot'])
    parts.append(leg)

    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=1.0, segments=10, ring_count=8,
        location=(lx, 0.020, FOOT_Z)
    )
    foot = bpy.context.active_object
    foot.name = f"CharDurian_Foot_{suf}"
    foot.scale = (0.078, 0.058, 0.048)
    apply_scale(foot)
    smooth(foot)
    set_mat(foot, M['foot'])
    parts.append(foot)

print("[CharDurian] Legs ✓")


# ===========================================================================
#  ARMATURE (replaces plain-empty root) — 5 bones: Hips + 4 limb bones,
#  matching Godot's canonical humanoid names so retargeted UAL locomotion
#  clips apply directly. See assets/characters/build_char_fruit.py for the
#  original prototype and assets/animations/build_character_locomotion.py
#  for the shared retarget bake.
# ===========================================================================
bpy.ops.object.armature_add(enter_editmode=True, location=(0, 0, 0))
root = bpy.context.active_object
root.name = "CharDurian" + "_Root"
arm_data = root.data
arm_data.name = "CharDurian" + "_Skeleton"

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
print("[" + "CharDurian" + "] Armature done (Hips, LeftUpperArm, RightUpperArm, LeftUpperLeg, RightUpperLeg)")


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
    "LeftUpperArm":  ["CharDurian" + "_Arm_L", "CharDurian" + "_Mitten_L"],
    "RightUpperArm": ["CharDurian" + "_Arm_R", "CharDurian" + "_Mitten_R"],
    "LeftUpperLeg":  ["CharDurian" + "_Leg_L", "CharDurian" + "_Foot_L"],
    "RightUpperLeg": ["CharDurian" + "_Leg_R", "CharDurian" + "_Foot_R"],
}
limb_parts = set()
for bone_name, names in limb_names.items():
    objs = [by_name[n] for n in names if n in by_name]
    limb_parts.update(objs)
    bone_parent_group(objs, bone_name)

hips_parts = [p for p in parts if p not in limb_parts]
bone_parent_group(hips_parts, "Hips")

print("[" + "CharDurian" + "] Bone-parented " + str(len(parts)) + " parts -> " + "CharDurian" + "_Root skeleton")


# ===========================================================================
#  EXPORT GLB — rig + rest pose only, no animation data (shared locomotion
#  clips are merged onto the AnimationPlayer at runtime by player.gd).
# ===========================================================================
out = "/Users/zhihao/personal_projects/ropedart-arena/assets/characters/char_durian.glb"
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

print("[" + "CharDurian" + "] Exported -> " + out)
print("[CharDurian] === BUILD COMPLETE ===\n")
