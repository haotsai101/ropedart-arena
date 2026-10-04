"""Regenerate the mascot's meshes in mascot.blend (Text Editor -> Run Script).

Rebuilds every part in the "Mascot" collection from the parameters below,
skinned to Rig_Medium, keeping the existing materials. WARNING: this
replaces those meshes -- hand edits to them are lost (export first, or copy
the part you edited out of the collection).

Shape: front-view silhouette traced from the reference (PROFILE), a rounded-
rectangle face mask sitting on the body, dot eyes + a thin mouth, stumpy
legs, floating hand dots on hand.l/hand.r, and the leaf (native headwear).
Detail: RES scales every part's segment counts. RES = 1.0 is the mobile
budget (~1.9k triangles for the whole character).
"""
import math

import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

RES = 1.0

BODY_SEGMENTS = int(24 * RES)
# (z, half-width) of the front-view silhouette; the crown sits at 1.85
PROFILE = [(0.200, 0.0), (0.212, 0.15), (0.245, 0.30), (0.31, 0.405), (0.40, 0.480), (0.50, 0.525),
           (0.634, 0.548), (0.893, 0.530), (1.151, 0.492), (1.410, 0.466), (1.56, 0.445), (1.66, 0.415),
           (1.73, 0.37), (1.785, 0.30), (1.822, 0.215), (1.843, 0.12), (1.850, 0.0)]
CROWN_Z = 1.85
MASK = dict(center_z=1.49, half_w=0.385, half_h=0.30, exponent=2.8, rings=max(3, int(4 * RES)), segments=int(32 * RES), lift=0.018)
EYE = dict(x=0.205, z=1.52, size=(0.052, 0.03, 0.064), segments=int(8 * RES), rings=max(4, int(5 * RES)))
MOUTH = dict(z=1.325, half_w=0.165, thickness=0.011, columns=int(8 * RES))
LEG = dict(x=0.215, size=(0.140, 0.165, 0.30), segments=int(12 * RES), rings=max(6, int(8 * RES)))
HAND = dict(radius=0.115, segments=int(10 * RES), rings=max(5, int(6 * RES)))
LEAF = dict(length=0.30, width=0.36, thickness=0.022, segments=int(10 * RES), rings=max(6, int(8 * RES)), tilt_back_deg=22, tilt_side_deg=12)

arm = bpy.data.objects["Rig_Medium"]
masc_c = bpy.data.collections["Mascot"]
MAT = bpy.data.materials


def depth_k(z):  # side view: nearly as deep as wide at the belly, shallower up top
    return 0.94 - 0.10 * min(max((z - 0.6) / 1.2, 0.0), 1.0)


def back_shift(z):  # the crown sits slightly behind the belly
    return 0.05 * min(max((z - 0.9) / 0.9, 0.0), 1.0)


def new_obj(name, bm, mats, smooth=True):
    old = bpy.data.objects.get(name)
    if old:
        bpy.data.objects.remove(old, do_unlink=True)
    me = bpy.data.meshes.get(name)
    if me:
        bpy.data.meshes.remove(me)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in mats:
        me.materials.append(m)
    for p in me.polygons:
        p.use_smooth = smooth
    o = bpy.data.objects.new(name, me)
    masc_c.objects.link(o)
    return o


def bind(o, weights_fn):
    """Parent to the rig; weights_fn(local co) -> {bone: weight}."""
    o.parent = arm
    o.modifiers.new("Armature", 'ARMATURE').object = arm
    groups = {}
    for v in o.data.vertices:
        for bone, w in weights_fn(v.co).items():
            if w <= 0:
                continue
            g = groups.get(bone) or o.vertex_groups.new(name=bone)
            groups[bone] = g
            g.add([v.index], w, 'REPLACE')


def lerp_w(z, z0, z1, a, b):
    t = min(max((z - z0) / (z1 - z0), 0.0), 1.0)
    return {a: 1 - t, b: t}


def torso_weights(co):
    z = co.z
    if z < 0.62:
        return lerp_w(z, 0.45, 0.62, "hips", "spine")
    if z < 0.95:
        return lerp_w(z, 0.80, 0.95, "spine", "chest")
    return lerp_w(z, 1.15, 1.32, "chest", "head")


def sphere_into(bm, segments, rings, place):
    """UV sphere into bm; place(unit co) -> world co."""
    for v in bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=rings, radius=1.0)["verts"]:
        v.co = place(v.co.copy())


# ---------------------------------------------------------------- body
bm = bmesh.new()
rings = []
bottom = bm.verts.new((0, 0, PROFILE[0][0]))
top = bm.verts.new((0, back_shift(CROWN_Z), PROFILE[-1][0]))
for z, r in PROFILE[1:-1]:
    rings.append([bm.verts.new((math.cos(2 * math.pi * s / BODY_SEGMENTS) * r,
                                math.sin(2 * math.pi * s / BODY_SEGMENTS) * r * depth_k(z) + back_shift(z), z))
                  for s in range(BODY_SEGMENTS)])
for s in range(BODY_SEGMENTS):
    n = (s + 1) % BODY_SEGMENTS
    bm.faces.new((bottom, rings[0][n], rings[0][s]))
    bm.faces.new((top, rings[-1][s], rings[-1][n]))
for a, b in zip(rings, rings[1:]):
    for s in range(BODY_SEGMENTS):
        n = (s + 1) % BODY_SEGMENTS
        bm.faces.new((a[s], a[n], b[n], b[s]))
bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
body = new_obj("Mascot_Body", bm, [MAT["Mascot_Body"]])
bind(body, torso_weights)

body_bvh = BVHTree.FromPolygons([v.co.copy() for v in body.data.vertices], [list(p.vertices) for p in body.data.polygons])


def on_body(x, z, lift):
    loc, nrm, _, _ = body_bvh.ray_cast(Vector((x, -3.0, z)), Vector((0, 1, 0)))
    return (loc + nrm * lift) if loc else Vector((x, 0, z))


# ---------------------------------------------------------------- mask
def superellipse(a, e):
    c, s = math.cos(a), math.sin(a)
    return math.copysign(abs(c) ** (2 / e), c), math.copysign(abs(s) ** (2 / e), s)


M = MASK
uv_w = 2 * M["half_w"]
bm = bmesh.new()
uv = bm.loops.layers.uv.new("UVMap")
center = bm.verts.new(on_body(0, M["center_z"], M["lift"]))
ring_v = []
for r in range(1, M["rings"] + 1):
    t = r / M["rings"]
    ring = []
    for k in range(M["segments"]):
        sx, sz = superellipse(2 * math.pi * k / M["segments"], M["exponent"])
        ring.append(bm.verts.new(on_body(sx * M["half_w"] * t, M["center_z"] + sz * M["half_h"] * t, M["lift"])))
    ring_v.append(ring)
for k in range(M["segments"]):
    bm.faces.new((center, ring_v[0][k], ring_v[0][(k + 1) % M["segments"]]))
for a, b in zip(ring_v, ring_v[1:]):
    for k in range(M["segments"]):
        n = (k + 1) % M["segments"]
        bm.faces.new((a[k], b[k], b[n], a[n]))
for f in bm.faces:
    for loop in f.loops:
        loop[uv].uv = (0.5 + loop.vert.co.x / uv_w, 0.5 + (loop.vert.co.z - M["center_z"]) / uv_w)
bm.normal_update()
if sum(f.normal.y for f in bm.faces) > 0:  # must face the viewer (-Y)
    bmesh.ops.reverse_faces(bm, faces=bm.faces)
mask = new_obj("Mascot_Mask", bm, [MAT["Mascot_Mask"]])
bind(mask, torso_weights)

mask_bvh = BVHTree.FromPolygons([v.co.copy() for v in mask.data.vertices], [list(p.vertices) for p in mask.data.polygons])


def on_mask(x, z, lift):
    loc, _, _, _ = mask_bvh.ray_cast(Vector((x, -3.0, z)), Vector((0, 1, 0)))
    return loc + Vector((0, -lift, 0))


# ---------------------------------------------------------------- face: eyes + mouth
bm = bmesh.new()
for sx in (-1, 1):
    p = on_mask(EYE["x"] * sx, EYE["z"], 0.0)
    sz = EYE["size"]
    sphere_into(bm, EYE["segments"], EYE["rings"], lambda c, p=p, sz=sz: Vector((c.x * sz[0], c.y * sz[1], c.z * sz[2])) + p)
n_eye = len(bm.faces)
cols = []
for i in range(MOUTH["columns"] + 1):
    x = -MOUTH["half_w"] + 2 * MOUTH["half_w"] * i / MOUTH["columns"]
    taper = 1.0 - 0.5 * abs(x / MOUTH["half_w"]) ** 4
    th = MOUTH["thickness"] * taper
    cols.append([bm.verts.new(on_mask(x, MOUTH["z"] + dz * th, lift))
                 for dz, lift in ((-1, 0.003), (1, 0.003), (1, 0.008), (-1, 0.008))])
for a, b in zip(cols, cols[1:]):
    for j in range(4):
        bm.faces.new((a[j], b[j], b[(j + 1) % 4], a[(j + 1) % 4]))
bm.faces.new(cols[0][::-1])
bm.faces.new(cols[-1])
bmesh.ops.recalc_face_normals(bm, faces=bm.faces[n_eye:])
face = new_obj("Mascot_Face", bm, [MAT["Mascot_Eye"], MAT["Mascot_Mouth"]])
for i, poly in enumerate(face.data.polygons):
    poly.material_index = 0 if i < n_eye else 1
bind(face, torso_weights)

# ---------------------------------------------------------------- legs: stumps with flat soles
for side, sx in (("Left", 1), ("Right", -1)):
    s = "l" if sx > 0 else "r"
    bm = bmesh.new()

    def place(c, sx=sx):
        z = c.z * LEG["size"][2] + 0.30
        if z < 0.045:
            z = 0.045 - (0.045 - z) * 0.12  # flatten the sole
        return Vector((c.x * LEG["size"][0] + LEG["x"] * sx, c.y * LEG["size"][1] - 0.025, z))

    sphere_into(bm, LEG["segments"], LEG["rings"], place)
    zmin = min(v.co.z for v in bm.verts)
    for v in bm.verts:
        v.co.z -= zmin
    leg = new_obj("Mascot_Leg" + side, bm, [MAT["Mascot_Body"]])
    bind(leg, lambda co, s=s: lerp_w(co.z, 0.16, 0.34, "lowerleg." + s, "upperleg." + s) if co.z > 0.10 else {"foot." + s: 1.0})

# ---------------------------------------------------------------- floating hand dots (rigid on hand bones)
for side, s in (("Left", "l"), ("Right", "r")):
    head = arm.data.bones["hand." + s].head_local
    bm = bmesh.new()
    sphere_into(bm, HAND["segments"], HAND["rings"], lambda c, head=head: c * HAND["radius"] + head)
    hand = new_obj("Mascot_Hand" + side, bm, [MAT["Mascot_Body"]])
    bind(hand, lambda co, s=s: {"hand." + s: 1.0})

# ---------------------------------------------------------------- leaf (native headwear): stem + a closed leaf lens
L = LEAF
bm = bmesh.new()
for v in bmesh.ops.create_cone(bm, cap_ends=True, segments=6, radius1=0.032, radius2=0.024, depth=0.08)["verts"]:
    v.co += Vector((0, back_shift(CROWN_Z), CROWN_Z + 0.02))
n_stem = len(bm.faces)
# the leaf is a closed sphere bent into shape (pointed outline, thin, cupped
# edges, tip curling back) -- always a clean closed surface with consistent
# normals, unlike a hand-built double sheet
leaf_bm = bmesh.new()
bmesh.ops.create_uvsphere(leaf_bm, u_segments=L["segments"], v_segments=L["rings"], radius=1.0)
for v in leaf_bm.verts:
    c = v.co.copy()
    t = (c.z + 1.0) / 2.0                                   # 0 = base, 1 = tip
    half = L["width"] / 2 * math.sin(math.pi * t ** 0.85) ** 0.7
    ring = math.sqrt(max(1.0 - c.z * c.z, 1e-6))
    x = c.x / ring * half if ring > 1e-3 else 0.0
    across = x / (L["width"] / 2)
    y = c.y / ring * L["thickness"] * (1.0 - 0.6 * abs(across)) if ring > 1e-3 else 0.0
    y += 0.035 * across * across + 0.10 * t * t           # cupped edges, curled tip
    v.co = Vector((x, y, t * L["length"]))
rot = Matrix.Rotation(math.radians(L["tilt_side_deg"]), 4, 'Y') @ Matrix.Rotation(math.radians(-L["tilt_back_deg"]), 4, 'X')
for v in leaf_bm.verts:
    v.co = rot @ v.co + Vector((0.0, back_shift(CROWN_Z), CROWN_Z + 0.04))
tmp = bpy.data.meshes.new("tmp_leaf")
leaf_bm.to_mesh(tmp)
leaf_bm.free()
bm.from_mesh(tmp)
bpy.data.meshes.remove(tmp)
leaf = new_obj("Mascot_Leaf", bm, [MAT["Mascot_Stem"], MAT["Mascot_Leaf"]])
for i, poly in enumerate(leaf.data.polygons):
    poly.material_index = 0 if i < n_stem else 1
bind(leaf, lambda co: {"head": 1.0})

tris = {o.name: sum(len(p.vertices) - 2 for p in o.data.polygons) for o in masc_c.objects if o.type == 'MESH'}
print("mascot rebuilt:", tris, "total", sum(tris.values()))
