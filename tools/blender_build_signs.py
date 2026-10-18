"""Builds the sign models in Blender (run inside Blender, e.g. through the Blender MCP:
exec(open(r"<this file>").read())). One collection per sign; re-running replaces them.

- "TF3 Yield Sign": post + yield triangle (0.9 m sides, apex down, top edge 2.6 m).
- "TF3 Yield Roundabout Sign": post + yield triangle on top + round roundabout sign (0.6 m) below.
- "TF3 Yield Sign NO", "TF3 Yield Roundabout Sign NO": the same with the Norwegian yield artwork.
- "TF3 Priority Sign": post + priority diamond (0.6 m sides, i.e. 0.85 m corner to corner).

Conventions (as the in-game tests confirmed, 2026-10-18): Z up, the face looks along -Y (the
plates sit in front of the post at y = FRONT_Y), the construction's origin is the foot of the
post. Each Blender material names its TF3 material with the custom property "tf3_mtl"; the
exporter (tools/blender_export_tf3.py) writes the files.

The plates follow the user's artwork outlines (see art_plate below), with UVs straight from image
coordinates; the textures (tools/make_sign_textures.py) are the whole artwork images.
"""
import bpy
import bmesh
import json
import math

OUTLINES_FILE = "C:/Users/imsvale/source/Transport Fever 3/mods/road-priority-yield/assets/sign_outlines.json"

FRONT_Y = -0.05      # plate front, just in front of the 6 cm post
THICK = 0.02         # plate thickness
POST = 0.06          # post width


def material(name, rgb, mtl):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.diffuse_color = (*rgb, 1)
    m["tf3_mtl"] = mtl
    return m


MAT = {
    "metal": material("tf_sign_metal", (0.6, 0.6, 0.62), "sign_metal.mtl"),
    "yield": material("tf_yield_face", (0.9, 0.15, 0.15), "yield_face.mtl"),
    "yield_no": material("tf_yield_no_face", (0.9, 0.2, 0.1), "yield_no_face.mtl"),
    "roundabout": material("tf_roundabout_face", (0.0, 0.32, 0.64), "roundabout_face.mtl"),
    "priority": material("tf_priority_face", (0.98, 0.77, 0.0), "priority_face.mtl"),
}


def collection(name):
    coll = bpy.data.collections.get(name)
    if coll is None:
        coll = bpy.data.collections.new(name)
        bpy.context.scene.collection.children.link(coll)
    for ob in list(coll.objects):
        me = ob.data
        bpy.data.objects.remove(ob)
        if me and me.users == 0:
            bpy.data.meshes.remove(me)
    return coll


def link(coll, name, bm, mats, face_index):
    """Mesh from bm; face_index(poly) -> material slot."""
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in mats:
        me.materials.append(m)
    # Material indices set on the mesh: set on the bmesh they didn't survive to_mesh (2026-10-18).
    for poly in me.polygons:
        poly.material_index = face_index(poly)
    me.update()
    ob = bpy.data.objects.new(name, me)
    coll.objects.link(ob)
    return ob


def post(coll, name, height):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co.x *= POST
        v.co.y *= POST
        v.co.z = (v.co.z + 0.5) * height
    uv = bm.loops.layers.uv.new("UVMap")
    for f in bm.faces:
        for loop in f.loops:
            loop[uv].uv = (0.5, 0.5)
    return link(coll, name, bm, [MAT["metal"]], lambda poly: 0)


def plate(coll, name, outline, uvs, face):
    """A flat plate in the x/z plane from `outline` (x, z points), front at FRONT_Y with the
    `face` material and the given per-point UVs, back and rim metal."""
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    fr = [bm.verts.new((x, FRONT_Y, z)) for x, z in outline]
    bk = [bm.verts.new((x, FRONT_Y + THICK, z)) for x, z in outline]
    uv_of = {v: uvs[i] for i, v in enumerate(fr)}
    front = bm.faces.new(fr)
    back = bm.faces.new(list(reversed(bk)))
    n = len(outline)
    rims = [bm.faces.new((fr[(i + 1) % n], fr[i], bk[i], bk[(i + 1) % n])) for i in range(n)]
    bm.normal_update()
    if front.normal.y > 0:          # the front must look along -Y
        bmesh.ops.reverse_faces(bm, faces=[front, back] + rims)
        bm.normal_update()
    for loop in front.loops:
        loop[uv].uv = uv_of[loop.vert]
    for f in [back] + rims:
        for loop in f.loops:
            loop[uv].uv = (0.5, 0.5)
    return link(coll, name, bm, [MAT[face], MAT["metal"]], lambda poly: 0 if poly.normal.y < -0.99 else 1)


# The plates follow the artwork's own outline, traced by tools/trace_sign_outlines.py into
# assets/sign_outlines.json (image coordinates u right, v down, 0..1 across the whole artwork; the
# texture is that whole image). A point (u, v) sits at x = (u - 0.5) * s, z = (0.5 - v) * s, one
# uniform scale s per sign (from the sharp shape's side length or the disc's diameter), and its UV
# is the same image point, (u, 1 - v) in Blender's v-up convention (the exporter flips v back).
# Fitting a rounded shape's bounding box onto a sharp plate misaligned it (2026-10-18).
OUTLINES = json.load(open(OUTLINES_FILE, encoding="utf-8"))


def art_plate(coll, name, sign, face, top=None, centre=None):
    """The sign's plate, placed with its sharp shape's top edge at `top` (the yield triangle's
    straight top edge) or its outline's centre at `centre` (z, metres)."""
    o = OUTLINES[sign]
    s = o["metres_per_unit"]
    xz = [((u - 0.5) * s, (0.5 - v) * s) for u, v in o["outline"]]
    if top is not None:
        dz = top - max((0.5 - v) * s for _, v in o["sharp"])
    else:
        zs = [z for _, z in xz]
        dz = centre - (min(zs) + max(zs)) / 2
    outline = [(x, z + dz) for x, z in xz]
    uvs = [(u, 1 - v) for u, v in o["outline"]]
    return plate(coll, name, outline, uvs, face)


built = {}

c = collection("TF3 Yield Sign")
post(c, "Post", 2.55)
art_plate(c, "Plate", "yield", "yield", top=2.6)
built[c.name] = [o.name for o in c.objects]

c = collection("TF3 Yield Roundabout Sign")
post(c, "RA Post", 3.0)
art_plate(c, "RA Yield Plate", "yield", "yield", top=3.0)             # yield on top (user, 2026-10-18)
art_plate(c, "RA Roundabout Plate", "roundabout", "roundabout", centre=1.85)
built[c.name] = [o.name for o in c.objects]

c = collection("TF3 Priority Sign")
post(c, "P Post", 2.45)
art_plate(c, "P Diamond Plate", "priority", "priority", centre=2.15)
built[c.name] = [o.name for o in c.objects]

# Norwegian variants: the yield artwork with tighter corners (2026-10-18).
c = collection("TF3 Yield Sign NO")
post(c, "NO Post", 2.55)
art_plate(c, "NO Plate", "yield_no", "yield_no", top=2.6)
built[c.name] = [o.name for o in c.objects]

c = collection("TF3 Yield Roundabout Sign NO")
post(c, "NO RA Post", 3.0)
art_plate(c, "NO RA Yield Plate", "yield_no", "yield_no", top=3.0)
art_plate(c, "NO RA Roundabout Plate", "roundabout", "roundabout", centre=1.85)
built[c.name] = [o.name for o in c.objects]

result = {"built": built}
