"""Run with qrenderdoc --python, using a separate hidden process (RenderDoc 1.46).

Set MAIN_SHADOW_CAPTURE and MAIN_SHADOW_EVIDENCE to absolute paths first.
This exports captured inputs, not reconstructed results. No installed bridge edits.
"""

import hashlib
import json
import os
from pathlib import Path
import traceback

import renderdoc as rd


CAPTURE_SHA256 = "def7b7a19baed8b9dc89aada3b84c396897b78bb483bfb220cafcf85901d8143"
EVENTS = [281, 286, 291, 296, 301, 306, 311, 316, 321, 637, 641,
          669, 674, 679, 684, 689, 694, 699, 704]


def serialize(value):
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    # RenderDoc SWIG arrays implement the sequence protocol, not __iter__.
    if hasattr(value, "__len__") and hasattr(value, "__getitem__"):
        return [serialize(item) for item in value]
    fields = {}
    for name in dir(value):
        if name.startswith("_") or name in ("this", "thisown", "rawBytes", "reflection"):
            continue
        item = getattr(value, name)
        if not callable(item):
            fields[name] = serialize(item)
    return fields or str(value)


def export(capture, out):
    digest = hashlib.sha256()
    with capture.open("rb") as file:
        for block in iter(lambda: file.read(8 * 1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != CAPTURE_SHA256:
        raise ValueError("This exporter describes EndField frame37917 only")
    handle = rd.OpenCaptureFile()
    controller = None
    try:
        status = handle.OpenFile(str(capture), "", None)
        if status != rd.ResultCode.Succeeded:
            raise RuntimeError(str(status))
        status, controller = handle.OpenCapture(rd.ReplayOptions(), None)
        if status != rd.ResultCode.Succeeded:
            raise RuntimeError(str(status))
        actions = {}

        def walk(items):
            for item in items:
                if item.eventId in EVENTS:
                    actions[item.eventId] = {k: getattr(item, k) for k in (
                        "eventId", "numIndices", "numInstances", "indexOffset", "baseVertex", "instanceOffset")}
                walk(item.children)

        walk(controller.GetRootActions())
        states = {}
        for event in EVENTS:
            controller.SetFrameEvent(event, True)
            pipeline = controller.GetPipelineState()
            vk = controller.GetVulkanPipelineState()
            states[event] = {key: serialize(getattr(vk, key)) for key in (
                "depthStencil", "rasterizer", "colorBlend", "viewportScissor", "inputAssembly", "vertexInput")}
            states[event]["action"] = actions[event]
            states[event]["pixel_inputs"] = serialize(pipeline.GetReadOnlyResources(rd.ShaderStage.Pixel))
            if event in (637, 641):
                states[event]["samplers"] = serialize(pipeline.GetSamplers(rd.ShaderStage.Pixel))
            for stage in (rd.ShaderStage.Vertex, rd.ShaderStage.Pixel):
                reflection = pipeline.GetShaderReflection(stage)
                if reflection:
                    (out / ("e%d-%s.spv" % (event, str(stage)))).write_bytes(bytes(reflection.rawBytes))
            if event == 641:
                textures = {str(t.resourceId): t for t in controller.GetTextures()}
                for number in (173767, 173776, 173782, 173764, 187141, 173794, 7594):
                    tex = textures["ResourceId::%d" % number]
                    (out / ("e641-texture-%d.bin" % number)).write_bytes(
                        bytes(controller.GetTextureData(tex.resourceId, rd.Subresource())))
                buffer = next(b.resourceId for b in controller.GetBuffers() if str(b.resourceId) == "ResourceId::452")
                for name, offset, size in (("global", 39808, 32864), ("shadow", 148480, 11440), ("camera", 75328, 4512)):
                    (out / (name + ".bin")).write_bytes(bytes(controller.GetBufferData(buffer, offset, size)))
        (out / "pipeline-evidence.json").write_text(json.dumps(states, indent=2), encoding="utf-8")
        (out / "export-success.json").write_text(json.dumps({"capture_sha256": digest.hexdigest(), "events": EVENTS}), encoding="utf-8")
    finally:
        if controller:
            controller.Shutdown()
        handle.Shutdown()


if __name__ == "__main__":
    output = Path(os.environ["MAIN_SHADOW_EVIDENCE"])
    output.mkdir(parents=True, exist_ok=True)
    for marker in ("export-success.json", "export-error.txt"):
        if (output / marker).exists():
            (output / marker).unlink()
    exit_code = 0
    try:
        export(Path(os.environ["MAIN_SHADOW_CAPTURE"]), output)
    except Exception:
        (output / "export-error.txt").write_text(traceback.format_exc(), encoding="utf-8")
        exit_code = 1
    # Exit only this dedicated qrenderdoc process, before its interactive UI opens.
    os._exit(exit_code)
