"""OpenGorky models in Blender: File > Import / Export > OpenGorky model (.glb).

The editor's "Export model (.glb)" writes a model as the game has it: a flat skeleton
(each bone a world matrix, no parents), animations sampled at the game's 30 ticks a
second, textures inside, and `gorky` extras (height, centre, attach points) the editor
reads back. Blender's own glTF import defaults suit none of that: a 24 fps scene puts
the keys between frames, and bone shapes sized by guessed bone lengths cover the model
in spheres. These two operators wrap Blender's glTF import/export with the settings
that keep a round trip exact; the sidebar's OpenGorky tab picks the animation shown.

Install: Edit > Preferences > Add-ons > Install from Disk… > this file, then enable it.
Headless: blender -b --python scripts/blender_opengorky.py -- in.glb out.glb (round trip).
"""

bl_info = {
    "name": "OpenGorky models (.glb)",
    "author": "OpenGorky",
    "version": (1, 0, 0),
    "blender": (4, 2, 0),
    "location": "File > Import/Export, 3D View > Sidebar > OpenGorky",
    "description": "Gorky 17 models from and to the OpenGorky editor's .glb",
    "category": "Import-Export",
}

import json
import struct
import sys

import bpy
from bpy.props import StringProperty
from bpy_extras.io_utils import ExportHelper, ImportHelper

# The game plays one .bfr frame per 30 Hz tick (src/compose/gltf.zig `fps`).
GAME_FPS = 30


def game_fps(scene):
    scene.render.fps = GAME_FPS
    scene.render.fps_base = 1.0


def armature(context):
    obj = context.active_object
    if obj and obj.type == "ARMATURE":
        return obj
    return next((o for o in context.scene.objects if o.type == "ARMATURE"), None)


def show_action(scene, arm, action):
    """`action` on the armature, the timeline over its frames."""
    if arm.animation_data is None:
        arm.animation_data_create()
    arm.animation_data.action = action
    start, end = action.frame_range
    scene.frame_start, scene.frame_end = int(round(start)), int(round(end))
    scene.frame_set(scene.frame_start)


def short_bones(context, arm):
    """The game's skeleton is flat (no parents), so Blender guesses bone ends and draws
    them long, from the body out. A bone's length is not in its matrix (head and
    rotation are): shortened along itself, the poses and animations stay the same."""
    meshes = [o for o in context.scene.objects if o.type == "MESH" and o.parent == arm]
    tall = max((max(o.dimensions) for o in meshes), default=0.0)
    size = 0.04 * tall if tall > 0 else 1.0
    # Children of a bone (attach points) hang from its tail: kept where they are.
    held = [(o, o.matrix_world.copy()) for o in context.scene.objects if o.parent == arm and o.parent_type == "BONE"]
    prev = context.view_layer.objects.active
    context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for b in arm.data.edit_bones:
        d = b.tail - b.head
        if d.length > 0:
            roll = b.roll
            b.tail = b.head + d.normalized() * size
            b.roll = roll
    bpy.ops.object.mode_set(mode="OBJECT")
    context.view_layer.update()
    for o, w in held:
        o.matrix_world = w
    context.view_layer.objects.active = prev
    arm.data.display_type = "STICK"


def read_glb(path):
    data = open(path, "rb").read()
    n = struct.unpack_from("<I", data, 12)[0]
    return json.loads(data[20 : 20 + n]), data[20 + n :]


def write_glb(path, doc, rest):
    js = json.dumps(doc, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    body = struct.pack("<II", len(js), 0x4E4F534A) + js + rest
    open(path, "wb").write(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)


# Each animation's extras (its place in the .bfr, speed, frame sounds): Blender's glTF
# import and export drop them, so they ride on the action as this property.
ANIM_EXTRAS = "gorky_anim"


def import_model(context, path):
    game_fps(context.scene)
    bpy.ops.import_scene.gltf(filepath=path, disable_bone_shape=True, import_scene_extras=True)
    doc, _ = read_glb(path)
    for an in doc.get("animations", []):
        act = bpy.data.actions.get(an.get("name", ""))
        if act is not None and an.get("extras"):
            act[ANIM_EXTRAS] = json.dumps(an["extras"])
    arm = armature(context)
    if arm:
        short_bones(context, arm)
    if arm and bpy.data.actions:
        show_action(context.scene, arm, bpy.data.actions[0])
    # Textures are inside the file; the solid view just doesn't show them.
    for area in context.screen.areas if context.screen else ():
        if area.type == "VIEW_3D":
            area.spaces.active.shading.type = "MATERIAL"
            # Game units are large (a hero is ~25 tall): see the whole model.
            area.spaces.active.clip_end = 10000


def export_model(context, path):
    if context.scene.render.fps != GAME_FPS or context.scene.render.fps_base != 1.0:
        # Sampled at the scene's rate: anything else changes the animations' speed in game.
        game_fps(context.scene)
    # Only the model: its skeleton and the parts on it (not the scene's cube, camera, light).
    arm = armature(context)
    was = [o for o in context.scene.objects if o.select_get()]
    if arm is not None:
        for o in context.scene.objects:
            o.select_set(o == arm or o.parent == arm)
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        use_selection=arm is not None,
        # The game has no normals; with them a flat-shaded part splits every corner.
        export_normals=False,
        export_tangents=False,
        # height, centre, attach points: the editor's model fields
        export_extras=True,
        export_animations=True,
        export_animation_mode="ACTIONS",
        export_force_sampling=True,
        export_frame_step=1,
        # every frame kept: the game's .bfr has one per tick
        export_optimize_animation_size=False,
        export_anim_slide_to_zero=True,
        export_reset_pose_bones=True,
        export_def_bones=False,
        export_yup=True,
    )
    for o in context.scene.objects:
        o.select_set(o in was)
    doc, rest = read_glb(path)
    for an in doc.get("animations", []):
        act = bpy.data.actions.get(an.get("name", ""))
        if act is not None and ANIM_EXTRAS in act:
            an["extras"] = json.loads(act[ANIM_EXTRAS])
    write_glb(path, doc, rest)


class OPENGORKY_OT_import(bpy.types.Operator, ImportHelper):
    """A model exported by the OpenGorky editor"""

    bl_idname = "opengorky.import_glb"
    bl_label = "Import OpenGorky model"
    bl_options = {"REGISTER", "UNDO"}
    filename_ext = ".glb"
    filter_glob: StringProperty(default="*.glb", options={"HIDDEN"})

    def execute(self, context):
        import_model(context, self.filepath)
        return {"FINISHED"}


class OPENGORKY_OT_export(bpy.types.Operator, ExportHelper):
    """A model for the OpenGorky editor's Import model / Import animations"""

    bl_idname = "opengorky.export_glb"
    bl_label = "Export OpenGorky model"
    filename_ext = ".glb"
    filter_glob: StringProperty(default="*.glb", options={"HIDDEN"})

    def execute(self, context):
        export_model(context, self.filepath)
        return {"FINISHED"}


class OPENGORKY_OT_show_action(bpy.types.Operator):
    """Show this animation on the model"""

    bl_idname = "opengorky.show_action"
    bl_label = "Show animation"
    action: StringProperty()

    def execute(self, context):
        arm = armature(context)
        act = bpy.data.actions.get(self.action)
        if arm is None or act is None:
            return {"CANCELLED"}
        show_action(context.scene, arm, act)
        return {"FINISHED"}


class OPENGORKY_PT_panel(bpy.types.Panel):
    bl_label = "OpenGorky"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "OpenGorky"

    def draw(self, context):
        col = self.layout.column(align=True)
        if context.scene.render.fps != GAME_FPS:
            col.label(text=f"Scene at {context.scene.render.fps} fps, the game plays {GAME_FPS}", icon="ERROR")
        arm = armature(context)
        if arm is None:
            col.label(text="No model: File > Import > OpenGorky model")
            return
        shown = arm.animation_data.action if arm.animation_data else None
        for act in sorted(bpy.data.actions, key=lambda a: a.name.lower()):
            start, end = act.frame_range
            op = col.operator("opengorky.show_action", text=f"{act.name}  ({int(end - start) + 1})", depress=act == shown)
            op.action = act.name


def menu_import(self, context):
    self.layout.operator(OPENGORKY_OT_import.bl_idname, text="OpenGorky model (.glb)")


def menu_export(self, context):
    self.layout.operator(OPENGORKY_OT_export.bl_idname, text="OpenGorky model (.glb)")


classes = (OPENGORKY_OT_import, OPENGORKY_OT_export, OPENGORKY_OT_show_action, OPENGORKY_PT_panel)


def register():
    for c in classes:
        bpy.utils.register_class(c)
    bpy.types.TOPBAR_MT_file_import.append(menu_import)
    bpy.types.TOPBAR_MT_file_export.append(menu_export)


def unregister():
    bpy.types.TOPBAR_MT_file_export.remove(menu_export)
    bpy.types.TOPBAR_MT_file_import.remove(menu_import)
    for c in reversed(classes):
        bpy.utils.unregister_class(c)


if __name__ == "__main__":
    # Headless round trip: import IN with these settings, export OUT.
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if len(args) == 2:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        import_model(bpy.context, args[0])
        export_model(bpy.context, args[1])
    else:
        register()
