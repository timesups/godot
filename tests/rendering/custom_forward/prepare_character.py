"""Validate RenderDoc exports and prepare the static character scene manifest.

The exports must come from the same capture/event. No game assets are committed.
Usage: python prepare_character.py <gbuffer-materials-directory>
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np


PARTS = [
    (669, 468, "skin", 185721, "skin_normal_mapped", [185726]),
    (674, 457, "face_details", 185716, "validated_e674", []),
    (679, 462, "iris", 186177, "iris", []),
    (684, 473, "accessories", 187399, "accessory_normal_mapped", [187429]),
    (689, 478, "face", 185716, "e689_sdf_face", []),
    (694, 483, "clothes", 187399, "clothes_normal_mapped", [187429]),
    (699, 488, "ears", 185700, "ear_specialized", []),
    (704, 493, "hair", 185700, "hair_specialized", [186605]),
]


def prepare(root):
    parts = []
    files = {}

    def retain(name):
        data = (root / name).read_bytes()
        files[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        return data

    for event, gbuffer, name, texture, variant, auxiliary in PARTS:
        metadata = json.loads(retain(f"e{event}-mesh.json"))
        assert metadata["event"] == event
        m = metadata["post_vs"]
        assert m["vertexByteStride"] in (128, 144)
        assert m["indexByteStride"] in (2, 4)
        assert m["baseVertex"] == 0
        # Position, UV, world position, normal are the first four padded slots.
        assert [(o["name"], o["components"]) for o in metadata["outputs"][:4]] == [
            ("_Position", 4), ("_output0", 2), ("_output1", 3), ("_output2", 3)]
        vb = retain(f"e{event}-postvs-vertex.bin")
        ib = retain(f"e{event}-postvs-index.bin")
        vertices = np.frombuffer(vb, "<f4", offset=m["vertexByteOffset"]).reshape(-1, m["vertexByteStride"] // 4)
        indices = np.frombuffer(ib, f'<u{m["indexByteStride"]}', count=m["numIndices"], offset=m["indexByteOffset"])
        assert np.isfinite(vertices).all()
        assert len(indices) % 3 == 0 and indices.max() < len(vertices)
        assert np.allclose(np.linalg.norm(vertices[:, 12:15], axis=1), 1, atol=1e-5)
        dossier = json.loads(retain(f"e{event}-dossier.json"))
        assert dossier["action"]["num_indices"] == len(indices)
        bound = {int(i["descriptor"]["resource_id"].split("::")[-1])
                 for i in dossier["bindings"]["read_only_resources"]["items"] if i["stage"] == "Pixel"}
        assert {texture, *auxiliary} <= bound
        for tid in [texture, *auxiliary]:
            retain(f"texture-{tid}.dds")
        pixel_shader = next(s["shader_id"] for s in dossier["pipeline"]["shaders"] if s["stage"] == "Pixel")
        retain(f"e{event}-fragment.spv")
        parts.append({"event": event, "gbuffer_event": gbuffer, "name": name,
                      "variant": variant, "pixel_shader": pixel_shader, "base_texture": texture,
                      "auxiliary_textures": auxiliary,
                      "material_status": "validated_lighting" if event == 674 else ("reconstructed_e689_measured" if event == 689 else ("reconstructed_e694_measured" if event == 694 else ("reconstructed_e704_measured" if event == 704 else "base_color_diagnostic_only"))),
                      "vertex_count": len(vertices), "index_count": len(indices),
                      "vertex_stride": m["vertexByteStride"], "vertex_offset": m["vertexByteOffset"],
                      "index_stride": m["indexByteStride"], "index_offset": m["indexByteOffset"],
                      "bounds_min": vertices[:, 8:11].min(axis=0).tolist(),
                      "bounds_max": vertices[:, 8:11].max(axis=0).tolist()})
    for name in ["texture-172496.dds", "texture-186593.dds"]:
        retain(name)
    retain("e674-record0-transform.bin")
    retain("e689-record0-transform.bin")
    for tid, levels in [(37722, 9), (4874, 1), (37745, 10), (53468, 1)]:
        retain(f"e689-texture-{tid}.dds")
        for mip in range(1, levels):
            retain(f"e689-texture-{tid}-mip{mip}.dds")
    for mip in range(1, 11):
        retain(f"texture-185716-mip{mip}.dds")
    for tid, levels in [(187399, 12), (187402, 12), (187429, 12), (185914, 11), (118829, 1), (39217, 1)]:
        for mip in range(levels):
            suffix = f"-mip{mip}" if mip else ""
            retain(f"e694-texture-{tid}{suffix}.dds")
    retain("e704-record0-transform.bin")
    for tid, levels in [(185700,11), (186605,11), (187392,11), (173100,11), (37600,10), (188148,1), (186747,1)]:
        for mip in range(levels):
            suffix = f"-mip{mip}" if mip else ""
            retain(f"e704-texture-{tid}{suffix}.dds")
    for face in range(6):
        for mip in range(8):
            retain(f"e694-cube8600-face{face}-mip{mip}.dds")
    manifest = {"capture": "EndField-frame37917.rdc", "frame": 37917,
                "coordinate_origin": [-300.0, 300.0, -300.0], "parts": parts, "files": files,
                "scope": "Eight paired character draws, captured posed mesh; not recovered rig or full material parity."}
    (root / "character-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f'CHARACTER_MANIFEST_OK parts={len(parts)} vertices={sum(p["vertex_count"] for p in parts)} triangles={sum(p["index_count"] // 3 for p in parts)}')


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    prepare(parser.parse_args().evidence)
