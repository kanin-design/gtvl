"""GTVL's home screen with a real glass dock, for Blender's Cycles path tracer.

The wallpaper (a still of the video) is a screen some way behind the dock;
the dock is a strip of glass with an etched (frosted) front, a polished back
and rounded, polished top and bottom edges; the apps' tiles are lit screens
floating just in front of it, the one in focus lifted; and behind the glass,
under that tile, a hot light glows. One unit is one dp of GTVL's layout and
the camera looks straight at the screen, so a render lines up with the app.
Nothing is faked: light is traced through the glass, its frosting and its
edges as it physically goes.

Two passes: "glass" shows the wallpaper and tiles through and around the
glass, with the hot light off; "glow" shows only the hot light's light, the
wallpaper and tiles dark but still there. The app adds a glow over its
screen the same way, so the two passes put together are the reference.

Run headless, with parameters as JSON after "--":
  Blender -b --factory-startup --python scene.py -- '{"out": "/tmp/s", "pass": "glow"}'
Writes <out>.exr (linear light), <out>.png (the glass pass as the screen
shows it) and <out>.npy (linear light, top row first).
"""

import json
import math
import sys

import bmesh
import bpy
import numpy as np

# The layout, as on the TV it was measured from (see fake.py).
PAD, GAP = 38.0, 26.0
TILE_W = (960 - 2 * PAD - 7 * 13) / 8
TILE_H = TILE_W * 9 / 16
DOCK_H = TILE_H * (1 + 0.36 * 1.5)
DOCK_TOP = 540 - DOCK_H - 540 * 0.07
TILE_TOP = DOCK_TOP + (DOCK_H - TILE_H) / 2

P = {
    "pass": "glass",
    "wallpaper": "",
    "tiles": "",
    "selected": 1,
    "lift": 1.12,
    "tile_r": 10.0,
    "tile_gap": 2.0,
    # The glass: thickness, refractive index, roughness (GGX) of the etched
    # front, the back and the edges; milkiness (scattering per dp, forward
    # bias); and how far behind it the wallpaper is.
    "glass_t": 6.0,
    "ior": 1.5,
    "front_rough": 0.3,
    "back_rough": 0.0,
    "edge_rough": 0.0,
    "milk": 0.0,
    "milk_g": 0.6,
    "wall_gap": 30.0,
    # The edges: "cut" (flat, with a 45-degree chamfer each side, polished,
    # as cut glass is) or "round" (a full half-round); chamfer size.
    "edge": "cut",
    "chamfer": 1.5,
    # How much of the light falling on the wallpaper it gives back (as a lit
    # surface showing its own colours).
    "wall_albedo": 0.6,
    # A long soft light above the dock, seen only by the glass, as a room's
    # light catches a glass edge: its strength (0 for none) and how far
    # above the dock and in front of the glass it hangs.
    "studio": 0.0,
    "studio_above": 120.0,
    "studio_front": 60.0,
    # A fainter one below, as a fraction of it (0 for none).
    "studio_below": 0.0,
    # The lamps' length and where along the dock they are centred (dp).
    "studio_length": 1600.0,
    "studio_x": 480.0,
    # The hot light behind the glass: its size against the tile's, how far
    # behind the glass, its colour temperature (K) and strength.
    "light_scale": 1.0,
    "light_gap": 12.0,
    "light_temp": 2300.0,
    "light_power": 60.0,
    # The render: pixels per dp, samples per pixel (the most, with
    # adaptive sampling below a noise threshold; 0 for a fixed count), and
    # the part of the screen to render (left, top, right, bottom in dp; the
    # rest stays black), or none for all of it.
    "ppd": 0.5,
    "samples": 256,
    "adaptive": 0.0,
    "region": None,
    # Clean a quick render up with the denoiser (for trying things out, not
    # for the reference itself).
    "denoise": False,
    "out": "/tmp/scene",
}
if "--" in sys.argv:
    P.update(json.loads(sys.argv[sys.argv.index("--") + 1]))
GLOW = P["pass"] == "glow"


def rounded_rect(w, h, r, corner=16):
    """Points around a w by h rectangle with corners of radius r, centred."""
    r = min(r, w / 2, h / 2)
    points = []
    for cx, cy, start in [(w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180), (w / 2 - r, -h / 2 + r, 270)]:
        for i in range(corner + 1):
            a = math.radians(start + 90 * i / corner)
            points.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return points


def flat_shape(name, points, centre, z, material):
    """A flat polygon at depth z, facing the camera, UV-mapped across its bounds."""
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new()
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    face = bm.faces.new([bm.verts.new((centre[0] + x, centre[1] + y, z)) for x, y in points])
    for loop in face.loops:
        x, y = loop.vert.co.x - centre[0], loop.vert.co.y - centre[1]
        loop[uv].uv = ((x - x0) / (x1 - x0), (y - y0) / (y1 - y0))
    bm.to_mesh(mesh)
    bm.free()
    mesh.materials.append(material)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def wallpaper_material(strength, image, albedo):
    """The wallpaper: its picture shining, and a matt surface of the same
    colours that light falling on it lights up."""
    m = bpy.data.materials.new("wallpaper")
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(image)
    tex.extension = "EXTEND"
    tex.interpolation = "Cubic"
    emit = nodes.new("ShaderNodeEmission")
    emit.inputs["Strength"].default_value = strength
    links.new(tex.outputs["Color"], emit.inputs["Color"])
    tint = nodes.new("ShaderNodeMix")
    tint.data_type = "RGBA"
    tint.blend_type = "MULTIPLY"
    tint.inputs["Factor"].default_value = 1.0
    links.new(tex.outputs["Color"], tint.inputs["A"])
    tint.inputs["B"].default_value = (albedo, albedo, albedo, 1)
    matt = nodes.new("ShaderNodeBsdfDiffuse")
    links.new(tint.outputs["Result"], matt.inputs["Color"])
    add = nodes.new("ShaderNodeAddShader")
    links.new(emit.outputs[0], add.inputs[0])
    links.new(matt.outputs[0], add.inputs[1])
    links.new(add.outputs[0], out.inputs["Surface"])
    return m


def emissive(name, strength, image=None, colour=None, temperature=None, one_sided=False):
    """A surface that only gives off light: an image, a colour or a blackbody;
    one-sided gives it off only toward the camera, as a screen does."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    emit = nodes.new("ShaderNodeEmission")
    emit.inputs["Strength"].default_value = strength
    if image:
        tex = nodes.new("ShaderNodeTexImage")
        tex.image = bpy.data.images.load(image)
        tex.extension = "EXTEND"
        tex.interpolation = "Cubic"
        links.new(tex.outputs["Color"], emit.inputs["Color"])
    elif temperature:
        body = nodes.new("ShaderNodeBlackbody")
        body.inputs["Temperature"].default_value = temperature
        links.new(body.outputs[0], emit.inputs["Color"])
    else:
        emit.inputs["Color"].default_value = colour or (0, 0, 0, 1)
    if one_sided:
        geometry = nodes.new("ShaderNodeNewGeometry")
        dark = nodes.new("ShaderNodeBsdfDiffuse")
        dark.inputs["Color"].default_value = (0, 0, 0, 1)
        side = nodes.new("ShaderNodeMixShader")
        links.new(geometry.outputs["Backfacing"], side.inputs["Fac"])
        links.new(emit.outputs[0], side.inputs[1])
        links.new(dark.outputs[0], side.inputs[2])
        links.new(side.outputs[0], out.inputs["Surface"])
    else:
        links.new(emit.outputs[0], out.inputs["Surface"])
    return m


def glass_material(name, rough):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    # A plain dielectric: Fresnel, refraction and total internal reflection,
    # with multiple-scattering GGX microfacets for the etched roughness.
    glass = nodes.new("ShaderNodeBsdfGlass")
    glass.distribution = "MULTI_GGX"
    glass.inputs["Roughness"].default_value = rough
    glass.inputs["IOR"].default_value = P["ior"]
    glass.inputs["Color"].default_value = (1, 1, 1, 1)
    links.new(glass.outputs[0], out.inputs["Surface"])
    if P["milk"] > 0:
        vol = nodes.new("ShaderNodeVolumeScatter")
        vol.inputs["Density"].default_value = P["milk"]
        vol.inputs["Anisotropy"].default_value = P["milk_g"]
        links.new(vol.outputs[0], out.inputs["Volume"])
    return m


def build():
    scene = bpy.context.scene
    for obj in list(scene.objects):
        bpy.data.objects.remove(obj)
    t = P["glass_t"]

    # The wallpaper: a screen behind the glass, larger than the view, its
    # edge pixels carried outward.
    wall = wallpaper_material(0.0 if GLOW else 1.0, P["wallpaper"], P["wall_albedo"])
    flat_shape("wallpaper", [(-480, -270), (480, -270), (480, 270), (-480, 270)], (480, -270), -t - P["wall_gap"], wall)

    # The dock: a strip of glass far wider than the screen, front face at z = 0.
    length = 1600.0
    mesh = bpy.data.meshes.new("glass")
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co.x = v.co.x * length + 480
        v.co.y = v.co.y * DOCK_H - (DOCK_TOP + DOCK_H / 2)
        v.co.z = v.co.z * t - t / 2
    long_edges = [e for e in bm.edges if abs(e.verts[0].co.x - e.verts[1].co.x) > length / 2]
    if P["edge"] == "round":
        bmesh.ops.bevel(bm, geom=long_edges, offset=t / 2 * 0.999, segments=24, profile=0.5, affect="EDGES")
    else:
        bmesh.ops.bevel(bm, geom=long_edges, offset=P["chamfer"], segments=1, profile=0.5, affect="EDGES")
    front, back, edge = (glass_material(n, P[k]) for n, k in [("front", "front_rough"), ("back", "back_rough"), ("edge", "edge_rough")])
    for f in bm.faces:
        n = f.normal
        f.material_index = 0 if n.z > 0.999 else 1 if n.z < -0.999 else 2
    bm.to_mesh(mesh)
    bm.free()
    for m in (front, back, edge):
        mesh.materials.append(m)
    scene.collection.objects.link(bpy.data.objects.new("glass", mesh))

    # The tiles: lit screens in front of the glass, the selected one lifted.
    for i in range(6):
        lifted = i == P["selected"]
        s = P["lift"] if lifted else 1.0
        cx = PAD + i * (TILE_W + GAP) + TILE_W / 2
        cy = -(TILE_TOP + TILE_H / 2)
        mat = emissive(f"tile{i}", 0.0 if GLOW else 1.0, image=f"{P['tiles']}/tile{i}.png", one_sided=True)
        z = P["tile_gap"] + (1.0 if lifted else 0.0)
        flat_shape(f"tile{i}", rounded_rect(TILE_W * s, TILE_H * s, P["tile_r"] * s), (cx, cy), z, mat)

    # The hot light, behind the glass under the selected tile.
    i = P["selected"]
    cx = PAD + i * (TILE_W + GAP) + TILE_W / 2
    cy = -(TILE_TOP + TILE_H / 2)
    s = P["light_scale"]
    light = emissive("light", P["light_power"] if GLOW else 0.0, temperature=P["light_temp"])
    flat_shape("light", rounded_rect(TILE_W * s, TILE_H * s, P["tile_r"] * s), (cx, cy), -t - P["light_gap"], light)

    # The room's light, linked to the glass alone, so it shows only as the
    # glass's reflections and never lights the wallpaper or tiles.
    if P["studio"] > 0 and not GLOW:
        glass_only = bpy.data.collections.new("glass only")
        glass_only.objects.link(bpy.data.objects["glass"])
        lamp = bpy.data.lights.new("studio", type="AREA")
        lamp.shape = "RECTANGLE"
        lamp.size, lamp.size_y = P["studio_length"], 40.0
        lamp.energy = P["studio"]
        lamp_obj = bpy.data.objects.new("studio", lamp)
        lamp_obj.location = (P["studio_x"], -DOCK_TOP + P["studio_above"], P["studio_front"])
        # Facing the glass from above: the light shines along its local -z.
        lamp_obj.rotation_euler = (math.radians(-90) + math.atan2(P["studio_front"], P["studio_above"]), 0, 0)
        lamp_obj.visible_camera = False
        scene.collection.objects.link(lamp_obj)
        lamp_obj.light_linking.receiver_collection = glass_only
        if P["studio_below"] > 0:
            low = bpy.data.lights.new("studio below", type="AREA")
            low.shape = "RECTANGLE"
            low.size, low.size_y = P["studio_length"], 40.0
            low.energy = P["studio"] * P["studio_below"]
            low_obj = bpy.data.objects.new("studio below", low)
            low_obj.location = (P["studio_x"], -(DOCK_TOP + DOCK_H) - P["studio_above"], P["studio_front"])
            low_obj.rotation_euler = (math.radians(90) - math.atan2(P["studio_front"], P["studio_above"]), 0, 0)
            low_obj.visible_camera = False
            scene.collection.objects.link(low_obj)
            low_obj.light_linking.receiver_collection = glass_only

    world = bpy.data.worlds.new("dark")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.0
    scene.world = world

    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 960.0
    cam_data.clip_start, cam_data.clip_end = 1.0, 2000.0
    cam = bpy.data.objects.new("cam", cam_data)
    cam.location = (480, -270, 500)
    scene.collection.objects.link(cam)
    scene.camera = cam

    r = scene.render
    r.engine = "CYCLES"
    r.resolution_x, r.resolution_y = round(960 * P["ppd"]), round(540 * P["ppd"])
    r.resolution_percentage = 100
    c = scene.cycles
    c.device = "GPU"
    c.samples = P["samples"]
    c.use_adaptive_sampling = P["adaptive"] > 0
    if P["adaptive"] > 0:
        c.adaptive_threshold = P["adaptive"]
        c.adaptive_min_samples = 256
    if P["region"]:
        x0, y0, x1, y1 = P["region"]
        r.use_border, r.use_crop_to_border = True, False
        r.border_min_x, r.border_max_x = x0 / 960, x1 / 960
        r.border_min_y, r.border_max_y = 1 - y1 / 540, 1 - y0 / 540
    c.use_denoising = P["denoise"]
    if P["denoise"]:
        c.denoiser = "OPENIMAGEDENOISE"
        c.denoising_input_passes = "RGB_ALBEDO_NORMAL"
    c.max_bounces = 256
    c.transmission_bounces = 256
    c.glossy_bounces = 64
    c.diffuse_bounces = 4
    c.volume_bounces = 64
    c.transparent_max_bounces = 16
    c.caustics_reflective = True
    c.caustics_refractive = True
    c.blur_glossy = 0.0
    c.sample_clamp_direct = 0.0
    c.sample_clamp_indirect = 0.0
    c.seed = 1
    # The wallpaper and tiles are screen images: shown as they are.
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"


def render():
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = d.type == "METAL"
    scene = bpy.context.scene
    bpy.ops.render.render()
    result = bpy.data.images["Render Result"]
    fmt = scene.render.image_settings
    fmt.file_format, fmt.color_depth = "OPEN_EXR", "32"
    result.save_render(P["out"] + ".exr", scene=scene)
    fmt.file_format, fmt.color_depth, fmt.color_mode = "PNG", "8", "RGB"
    result.save_render(P["out"] + ".png", scene=scene)
    img = bpy.data.images.load(P["out"] + ".exr")
    w, h = img.size
    pixels = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(pixels)
    np.save(P["out"] + ".npy", pixels.reshape(h, w, 4)[::-1, :, :3])
    with open(P["out"] + ".json", "w") as f:
        json.dump(P, f, indent=1)


build()
render()
