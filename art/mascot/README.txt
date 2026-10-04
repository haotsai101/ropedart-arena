MASCOT SCENE -- quick guide
===========================
Collections
  Mascot      the character that gets exported: Rig_Medium (shared KayKit
              skeleton -- do not rename bones) + parts. Edit these.
                Mascot_Body       bean body          -> recolored in game (8 colors)
                Mascot_Mask       face plate         -> pattern texture (UVMap)
                Mascot_Face       eyes + mouth
                Mascot_LegLeft/Right
                Mascot_HandLeft/Right   floating dots, 100% on hand.l / hand.r
                Mascot_Leaf       HAT ACCESSORY (stem + leaf, on "head")
  Reference   KayKit Barbarian, for scale. Not exported.
  Cameras & Lights
              Cam_Game          the in-game view (iso, ortho 14 tall)
              Cam_Game_Closeup  same angle, close -- judge the silhouette here
              Cam_Front
Animation preview: select Rig_Medium -> Action editor -> pick Idle_A,
  Walking_A, Running_A, Throw ... (the game's real clips).
Colors: ONE model; the game recolors Mascot_Body at runtime. The 8
  values are custom properties on the Mascot_Body material (color_*);
  preview one by pasting it into Mascot_Body's Base Color.
    Orange  (1.0, 0.33, 0.04)
    Red     (0.85, 0.05, 0.06)
    Yellow  (1.0, 0.7, 0.05)
    Green   (0.2, 0.62, 0.06)
    Teal    (0.03, 0.55, 0.55)
    Blue    (0.06, 0.2, 0.95)
    Purple  (0.36, 0.08, 0.85)
    Pink    (1.0, 0.25, 0.5)
Mask patterns: assets/characters/mascot/mask_patterns/mask_*.png (512px,
  square, mapped across the mask's width). Add more PNGs there; preview by
  picking the image in Mascot_Mask's "Mask Pattern" node.
Rules that keep it working in game
  - keep it skinned to Rig_Medium; new parts: parent to the rig with an
    Armature modifier + vertex groups named after bones
  - face -Y in Blender (= +Z in Godot); feet at Z=0
  - stay within ~0.45 of the center line (the hit capsule is 0.4)
  - keep the body material named Mascot_Body and the mask Mascot_Mask
Scripts (Text Editor -> Run Script; copies live next to this file):
  build_mascot.py    regenerates the Mascot parts from parameters (RES =
                     detail level; 1.0 = ~1.8k triangles, the mobile budget)
  build_headwear.py  regenerates the 10 hats (Mascot_Headwear collection)
  export_mascot.py   writes Mascot.glb + MascotHeadwear.glb into
                     assets/characters/mascot/
  The build scripts REPLACE those meshes -- hand edits are lost.
Headwear: Hat_Cap, Hat_BirdNest, Hat_Pirate, Hat_TopHat, Hat_Beanie,
  Hat_Crown, Hat_Chef, Hat_Propeller, Hat_Viking, Hat_Party -- all rigid on
  "head", hidden in the viewport (unhide one to preview it; hide the leaf).
  New hat: add a Hat_* object skinned to "head" in that collection, export,
  and add an entry to GameManager.HEADWEAR_DEFS.
