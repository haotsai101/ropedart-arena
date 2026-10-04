"""Regenerate the mascot's headwear in mascot.blend (Text Editor -> Run Script).

Builds every hat into the "Mascot_Headwear" collection as Hat_<Name>,
rigidly skinned to Rig_Medium's "head" bone and fitted to the mascot's crown
(see build_mascot.py: crown top at z=1.85, sitting 0.05 behind center; the
face mask reaches up to ~1.79 at the front, so hats sit back on the head).
Exported to assets/characters/mascot/MascotHeadwear.glb by export_mascot.py;
the game lists them in GameManager.HEADWEAR_DEFS. WARNING: replaces the
Hat_* meshes -- hand edits to them are lost.
"""
import math
import random

import bmesh
import bpy
from mathutils import Matrix, Vector

CROWN = Vector((0.0, 0.05, 1.85))   # top of the head
arm = bpy.data.objects["Rig_Medium"]

coll = bpy.data.collections.get("Mascot_Headwear")
if coll is None:
    coll = bpy.data.collections.new("Mascot_Headwear")
    bpy.context.scene.collection.children.link(coll)


def mat(name, rgb, rough=0.6, metal=0.0):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    p = m.node_tree.nodes["Principled BSDF"]
    p.inputs["Base Color"].default_value = (*rgb, 1)
    p.inputs["Roughness"].default_value = rough
    p.inputs["Metallic"].default_value = metal
    m.diffuse_color = (*rgb, 1)
    return m


M = {
    "red": mat("Hat_Red", (0.80, 0.04, 0.04)),
    "white": mat("Hat_White", (0.92, 0.92, 0.90)),
    "black": mat("Hat_Black", (0.02, 0.02, 0.025), 0.45),
    "gold": mat("Hat_Gold", (1.0, 0.60, 0.08), 0.3, 0.9),
    "twig": mat("Hat_Twig", (0.22, 0.11, 0.04), 0.9),
    "twig_light": mat("Hat_TwigLight", (0.40, 0.22, 0.08), 0.9),
    "egg": mat("Hat_Egg", (0.55, 0.80, 0.85), 0.4),
    "blue": mat("Hat_Blue", (0.05, 0.18, 0.75)),
    "yellow": mat("Hat_Yellow", (1.0, 0.72, 0.03)),
    "green": mat("Hat_Green", (0.10, 0.50, 0.08)),
    "pink": mat("Hat_Pink", (1.0, 0.30, 0.55)),
    "steel": mat("Hat_Steel", (0.55, 0.56, 0.60), 0.35, 0.8),
    "ivory": mat("Hat_Ivory", (0.90, 0.84, 0.66), 0.5),
    "leather": mat("Hat_Leather", (0.30, 0.15, 0.05), 0.7),
}


class Hat:
    """Collects parts (bmesh + material) into one object."""

    def __init__(self, name):
        self.name = name
        self.bm = bmesh.new()
        self.mats = []
        self.face_mat = []

    def add(self, part_bm, material, smooth=True):
        if material not in self.mats:
            self.mats.append(material)
        idx = self.mats.index(material)
        tmp = bpy.data.meshes.new("tmp_hat")
        part_bm.to_mesh(tmp)
        part_bm.free()
        for p in tmp.polygons:
            p.use_smooth = smooth
        before = len(self.bm.faces)
        self.bm.from_mesh(tmp)
        bpy.data.meshes.remove(tmp)
        self.face_mat += [idx] * (len(self.bm.faces) - before)

    def finish(self, tilt_back_deg=0.0, tilt_side_deg=0.0, pivot=None):
        pivot = pivot or CROWN
        rot = Matrix.Rotation(math.radians(tilt_side_deg), 4, 'Y') @ Matrix.Rotation(math.radians(-tilt_back_deg), 4, 'X')
        for v in self.bm.verts:
            v.co = rot @ (v.co - pivot) + pivot
        old = bpy.data.objects.get(self.name)
        if old:
            bpy.data.objects.remove(old, do_unlink=True)
        me = bpy.data.meshes.get(self.name)
        if me:
            bpy.data.meshes.remove(me)
        me = bpy.data.meshes.new(self.name)
        self.bm.to_mesh(me)
        self.bm.free()
        for m in self.mats:
            me.materials.append(m)
        for i, p in enumerate(me.polygons):
            p.material_index = self.face_mat[i]
        o = bpy.data.objects.new(self.name, me)
        coll.objects.link(o)
        o.parent = arm
        o.modifiers.new("Armature", 'ARMATURE').object = arm
        o.vertex_groups.new(name="head").add(list(range(len(me.vertices))), 1.0, 'REPLACE')
        return o


# ------------------------------------------------------------------ primitives
def ellipsoid(center, radii, seg=12, rings=8):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * radii[0], v.co.y * radii[1], v.co.z * radii[2])) + Vector(center)
    return bm


def dome(base_z, rx, ry, height, seg=16, rings=6):
    """Upper half-ellipsoid (open bottom) centered over the crown."""
    bm = ellipsoid((0, 0, 0), (1, 1, 1), seg, rings * 2)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z < -1e-4], context='VERTS')
    for v in bm.verts:
        v.co = Vector((v.co.x * rx, v.co.y * ry + CROWN.y, base_z + v.co.z * height))
    return bm


def cylinder(center, r_bottom, r_top, height, seg=16, caps=True, ry_scale=1.0):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=caps, segments=seg, radius1=r_bottom, radius2=r_top, depth=height)
    for v in bm.verts:
        v.co = Vector((v.co.x, v.co.y * ry_scale, v.co.z + height / 2)) + Vector(center)
    return bm


def ring(center, r_outer, r_inner, height, seg=20, ry_scale=1.0):
    """Flat annulus with thickness (a brim / band)."""
    bm = bmesh.new()
    rows = []
    for (r, z) in ((r_inner, 0), (r_outer, 0), (r_outer, height), (r_inner, height)):
        rows.append([bm.verts.new(Vector((math.cos(2 * math.pi * k / seg) * r, math.sin(2 * math.pi * k / seg) * r * ry_scale, z)) + Vector(center))
                     for k in range(seg)])
    for a, b in zip(rows, rows[1:] + rows[:1]):
        for k in range(seg):
            n = (k + 1) % seg
            bm.faces.new((a[k], a[n], b[n], b[k]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def tube_along(points, radii, seg=8):
    """Swept tube through points (horns, twigs); radius per point, capped tip."""
    bm = bmesh.new()
    rings_v = []
    for i, (p, r) in enumerate(zip(points, radii)):
        p = Vector(p)
        d = (Vector(points[min(i + 1, len(points) - 1)]) - Vector(points[max(i - 1, 0)])).normalized()
        side = d.cross(Vector((0, 1, 0)))
        if side.length < 1e-4:
            side = d.cross(Vector((1, 0, 0)))
        side.normalize()
        up = side.cross(d).normalized()
        rings_v.append([bm.verts.new(p + (side * math.cos(2 * math.pi * k / seg) + up * math.sin(2 * math.pi * k / seg)) * r) for k in range(seg)])
    for a, b in zip(rings_v, rings_v[1:]):
        for k in range(seg):
            n = (k + 1) % seg
            bm.faces.new((a[k], a[n], b[n], b[k]))
    bm.faces.new(rings_v[0][::-1])
    bm.faces.new(rings_v[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


# ------------------------------------------------------------------ the hats
built = []

# 1. Baseball cap: crown-hugging dome, front brim, top button
h = Hat("Hat_Cap")
h.add(dome(1.66, 0.455, 0.405, 0.27, 16, 5), M["red"])
brim = bmesh.new()
inner, outer = [], []
for k in range(9):
    a = math.pi + math.pi * k / 8  # front half (-Y)
    c, s = math.cos(a), math.sin(a)
    inner.append(brim.verts.new((c * 0.44, s * 0.39 + CROWN.y, 1.665)))
    outer.append(brim.verts.new((c * 0.50, s * 0.66 + CROWN.y, 1.62 - 0.02 * abs(c))))
top_i = [brim.verts.new(v.co + Vector((0, 0, 0.025))) for v in inner]
top_o = [brim.verts.new(v.co + Vector((0, 0, 0.025))) for v in outer]
for k in range(8):
    brim.faces.new((inner[k], inner[k + 1], outer[k + 1], outer[k]))
    brim.faces.new((top_o[k], top_o[k + 1], top_i[k + 1], top_i[k]))
    brim.faces.new((outer[k], outer[k + 1], top_o[k + 1], top_o[k]))
bmesh.ops.recalc_face_normals(brim, faces=brim.faces)
h.add(brim, M["red"])
h.add(ellipsoid((0, CROWN.y, 1.66 + 0.265), (0.05, 0.05, 0.025), 8, 5), M["white"])
built.append(h.finish(tilt_back_deg=8))

# 2. Bird's nest: messy twig ring, bowl, three eggs
random.seed(7)
h = Hat("Hat_BirdNest")
nest = bmesh.new()
bmesh.ops.create_circle(nest, cap_ends=False, segments=18, radius=1.0)
torus = bmesh.new()
seg_u, seg_v, R, r = 18, 6, 0.27, 0.085
grid = []
for i in range(seg_u):
    a = 2 * math.pi * i / seg_u
    row = []
    for j in range(seg_v):
        b = 2 * math.pi * j / seg_v
        rr = r * (1 + random.uniform(-0.25, 0.25))
        p = Vector(((R + rr * math.cos(b)) * math.cos(a), (R + rr * math.cos(b)) * math.sin(a), rr * math.sin(b) * 0.7))
        row.append(torus.verts.new(p + CROWN + Vector((0, 0, 0.03))))
    grid.append(row)
for i in range(seg_u):
    for j in range(seg_v):
        torus.faces.new((grid[i][j], grid[(i + 1) % seg_u][j], grid[(i + 1) % seg_u][(j + 1) % seg_v], grid[i][(j + 1) % seg_v]))
bmesh.ops.recalc_face_normals(torus, faces=torus.faces)
nest.free()
h.add(torus, M["twig"], smooth=False)
h.add(cylinder((0, CROWN.y, CROWN.z - 0.02), 0.2, 0.24, 0.06, 12), M["twig_light"], smooth=False)
for k in range(10):  # stray twigs poking out
    a = random.uniform(0, 2 * math.pi)
    p0 = CROWN + Vector((math.cos(a) * 0.25, math.sin(a) * 0.25, 0.04))
    p1 = p0 + Vector((math.cos(a + random.uniform(-0.6, 0.6)) * 0.14, math.sin(a + random.uniform(-0.6, 0.6)) * 0.14, random.uniform(-0.02, 0.06)))
    h.add(tube_along([p0, p1], [0.012, 0.006], 4), M["twig_light"], smooth=False)
for k, (dx, dy) in enumerate(((-0.07, 0.0), (0.07, 0.03), (0.0, -0.06))):
    h.add(ellipsoid(CROWN + Vector((dx, dy, 0.09)), (0.05, 0.05, 0.065), 10, 6), M["egg"])
built.append(h.finish())

# 3. Pirate hat: black bicorn (points left/right), gold rim, white skull badge
h = Hat("Hat_Pirate")
bic = bmesh.new()
N = 16
front, back = [], []
for side_y, lst in ((-0.13, front), (0.13, back)):
    for k in range(N + 1):
        a = math.pi * k / N
        x = math.cos(a) * 0.58
        lst.append((bic.verts.new((x, CROWN.y + side_y * (0.6 + 0.4 * math.sin(a)), 1.76 + math.sin(a) * 0.36)),
                    bic.verts.new((x, CROWN.y + side_y * 0.35, 1.76 + math.sin(a) * 0.06 + 0.02))))
for k in range(N):
    fo, fi = front[k]; fo2, fi2 = front[k + 1]
    bo, bi = back[k]; bo2, bi2 = back[k + 1]
    bic.faces.new((fi, fi2, fo2, fo))      # front face
    bic.faces.new((bo, bo2, bi2, bi))      # back face
    bic.faces.new((fo, fo2, bo2, bo))      # top rim
    bic.faces.new((bi, bi2, fi2, fi))      # bottom
bic.faces.new((front[0][0], back[0][0], back[0][1], front[0][1]))
bic.faces.new((front[N][1], back[N][1], back[N][0], front[N][0]))
bmesh.ops.recalc_face_normals(bic, faces=bic.faces)
h.add(bic, M["black"], smooth=False)
h.add(tube_along([(math.cos(math.pi * k / N) * 0.58, CROWN.y - 0.131 * (0.6 + 0.4 * math.sin(math.pi * k / N)) - 0.004,
                    1.76 + math.sin(math.pi * k / N) * 0.36 - 0.01) for k in range(1, N)], [0.012] * (N - 1), 4), M["gold"])
skull_c = Vector((0, CROWN.y - 0.135, 1.94))
h.add(ellipsoid(skull_c, (0.075, 0.02, 0.07), 10, 6), M["white"])
for sx in (-1, 1):
    h.add(ellipsoid(skull_c + Vector((0.028 * sx, -0.018, 0.01)), (0.018, 0.008, 0.02), 6, 4), M["black"])
built.append(h.finish(tilt_back_deg=6))

# 4. Top hat: black cylinder, brim, red band
h = Hat("Hat_TopHat")
base = 1.80
h.add(cylinder((0, CROWN.y, base), 0.23, 0.24, 0.44, 16), M["black"])
h.add(ring((0, CROWN.y, base - 0.005), 0.38, 0.2, 0.03, 20, 0.92), M["black"])
h.add(cylinder((0, CROWN.y, base + 0.025), 0.236, 0.238, 0.08, 16, caps=False), M["red"])
built.append(h.finish(tilt_back_deg=8, tilt_side_deg=-6, pivot=Vector((0, CROWN.y, base))))

# 5. Beanie: snug knit dome, folded cuff, pompom
h = Hat("Hat_Beanie")
h.add(dome(1.64, 0.465, 0.415, 0.36, 16, 6), M["blue"])
h.add(ring((0, CROWN.y, 1.62), 0.48, 0.44, 0.10, 18, 0.89), M["white"])
h.add(ellipsoid((0, CROWN.y, 1.64 + 0.36 + 0.06), (0.1, 0.1, 0.09), 10, 6), M["white"])
built.append(h.finish(tilt_back_deg=12))

# 6. Crown: gold band with five points, red gems
h = Hat("Hat_Crown")
band = bmesh.new()
segs, base, hb, pts = 20, 1.79, 0.10, 5
low, high = [], []
for k in range(segs):
    a = 2 * math.pi * k / segs
    c, s = math.cos(a), math.sin(a)
    spike = 0.12 if k % (segs // pts) == 0 else 0.0
    low.append(band.verts.new((c * 0.25, s * 0.23 + CROWN.y, base)))
    high.append(band.verts.new((c * 0.26, s * 0.24 + CROWN.y, base + hb + spike)))
inner_low = [band.verts.new(v.co * Vector((0.9, 0.9, 1)) + Vector((0, CROWN.y * 0.1, 0))) for v in low]
for k in range(segs):
    n = (k + 1) % segs
    band.faces.new((low[k], low[n], high[n], high[k]))
    band.faces.new((inner_low[n], inner_low[k], high[k], high[n]))
bmesh.ops.recalc_face_normals(band, faces=band.faces)
h.add(band, M["gold"], smooth=False)
for k in range(pts):
    a = 2 * math.pi * k * (segs // pts) / segs
    h.add(ellipsoid((math.cos(a) * 0.27, math.sin(a) * 0.25 + CROWN.y, base + hb + 0.13), (0.035, 0.035, 0.035), 8, 5), M["red"])
built.append(h.finish(tilt_back_deg=6, pivot=Vector((0, CROWN.y, base))))

# 7. Chef hat: band + big puffy top
h = Hat("Hat_Chef")
base = 1.79
h.add(cylinder((0, CROWN.y, base), 0.25, 0.26, 0.14, 16), M["white"])
puff = ellipsoid((0, CROWN.y, base + 0.14 + 0.15), (0.33, 0.31, 0.21), 16, 8)
for v in puff.verts:  # gentle lumps
    a = math.atan2(v.co.y - CROWN.y, v.co.x)
    v.co.x *= 1 + 0.06 * math.cos(6 * a)
    v.co.y = (v.co.y - CROWN.y) * (1 + 0.06 * math.cos(6 * a)) + CROWN.y
h.add(puff, M["white"])
built.append(h.finish(tilt_back_deg=10, pivot=Vector((0, CROWN.y, base))))

# 8. Propeller cap: four-color dome, stem, two blades
h = Hat("Hat_Propeller")
d = dome(1.66, 0.455, 0.405, 0.27, 16, 5)
wedges = {"red": [], "yellow": [], "blue": [], "green": []}
keys = list(wedges)
for f in d.faces:
    c = f.calc_center_median()
    a = math.atan2(c.y - CROWN.y, c.x) % (2 * math.pi)
    wedges[keys[int(a / (math.pi / 2)) % 4]].append(f)
for key in keys:  # split the dome into four colored quarters
    part = d.copy()
    keep = {tuple(round(x, 5) for x in f.calc_center_median()) for f in wedges[key]}
    bmesh.ops.delete(part, geom=[f for f in part.faces if tuple(round(x, 5) for x in f.calc_center_median()) not in keep], context='FACES')
    h.add(part, M[key])
d.free()
top = 1.66 + 0.27
h.add(cylinder((0, CROWN.y, top - 0.01), 0.018, 0.018, 0.09, 6), M["yellow"])
h.add(ellipsoid((0, CROWN.y, top + 0.085), (0.03, 0.03, 0.02), 6, 4), M["yellow"])
for sgn in (-1, 1):
    blade = ellipsoid((sgn * 0.17, CROWN.y, top + 0.085), (0.16, 0.045, 0.008), 10, 4)
    for v in blade.verts:  # pitch the blades
        v.co.z += 0.25 * (v.co.y - CROWN.y) * sgn
    h.add(blade, M["red"])
built.append(h.finish(tilt_back_deg=8))

# 9. Viking helmet: steel dome, leather band, curved ivory horns
h = Hat("Hat_Viking")
h.add(dome(1.64, 0.465, 0.415, 0.32, 16, 6), M["steel"])
h.add(ring((0, CROWN.y, 1.625), 0.48, 0.45, 0.07, 18, 0.89), M["leather"])
h.add(cylinder((0, CROWN.y - 0.02, 1.70), 0.03, 0.03, 0.24, 6, ry_scale=1.0), M["leather"])
for sx in (-1, 1):
    pts = [(sx * (0.40 + 0.20 * t + 0.05 * math.sin(math.pi * t)), CROWN.y + 0.02, 1.76 + 0.30 * t * t + 0.12 * t) for t in [i / 6 for i in range(7)]]
    h.add(tube_along(pts, [0.075 * (1 - i / 6) + 0.006 for i in range(7)], 8), M["ivory"])
built.append(h.finish(tilt_back_deg=10))

# 10. Party hat: tilted striped cone, pompom
h = Hat("Hat_Party")
base, height, r0, bands = 1.80, 0.46, 0.18, 5
for i in range(bands):
    z0, z1 = height * i / bands, height * (i + 1) / bands
    rr0, rr1 = r0 * (1 - z0 / height), r0 * (1 - z1 / height)
    h.add(cylinder((0, CROWN.y, base + z0), rr0, max(rr1, 0.002), z1 - z0, 14, caps=(i == 0)), M["pink" if i % 2 == 0 else "yellow"])
h.add(ellipsoid((0, CROWN.y, base + height + 0.03), (0.055, 0.055, 0.05), 8, 5), M["white"])
built.append(h.finish(tilt_back_deg=6, tilt_side_deg=-16, pivot=Vector((0, CROWN.y, base))))

print("headwear built:", {o.name: sum(len(p.vertices) - 2 for p in o.data.polygons) for o in built})
