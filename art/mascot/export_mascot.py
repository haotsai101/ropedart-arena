"""Export the mascot to the game (Text Editor -> Run Script).

  assets/characters/mascot/Mascot.glb          Rig_Medium + every mesh in the
                                               "Mascot" collection (body, mask,
                                               face, legs, hands, native leaf)
  assets/characters/mascot/MascotHeadwear.glb  Rig_Medium + every Hat_* in the
                                               "Mascot_Headwear" collection

Both in rest pose, no animations (the game plays the shared KayKit Rig_Medium
clips). Body color and mask pattern are swapped by the game at runtime; hats
are pulled out of MascotHeadwear.glb by name (GameManager.HEADWEAR_DEFS).
Run build_mascot.py / build_headwear.py first if you changed their settings.
"""
import os

import bpy

OUT_DIR = bpy.path.abspath("//../../assets/characters/mascot/")
arm = bpy.data.objects["Rig_Medium"]


def export(collection_name, filename):
    objs = [arm] + [o for o in bpy.data.collections[collection_name].objects if o is not arm]
    view_layer = bpy.context.view_layer
    hidden = [o for o in objs if o.hide_get()]
    for o in view_layer.objects:
        o.select_set(False)
    for o in objs:
        o.hide_set(False)
        o.hide_select = False
        o.select_set(True)
    view_layer.objects.active = arm
    bpy.ops.export_scene.gltf(
        filepath=os.path.join(OUT_DIR, filename), export_format="GLB", use_selection=True,
        export_animations=False, export_skins=True, export_yup=True,
        export_apply=False, export_materials="EXPORT",
    )
    for o in hidden:
        o.hide_set(True)
    print("exported", filename, "(%d objects)" % len(objs))


ad = arm.animation_data
saved = (ad.action, getattr(ad, "action_slot", None)) if ad else (None, None)
if ad:
    ad.action = None
for pb in arm.pose.bones:
    pb.matrix_basis.identity()
os.makedirs(OUT_DIR, exist_ok=True)
export("Mascot", "Mascot.glb")
export("Mascot_Headwear", "MascotHeadwear.glb")
if ad and saved[0]:
    ad.action = saved[0]
    if saved[1] is not None:
        ad.action_slot = saved[1]
