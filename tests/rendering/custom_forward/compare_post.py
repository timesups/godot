"""Compare GPU reconstruction readbacks to MCP DDS exports (requires numpy)."""
import argparse
import json
from pathlib import Path
import struct

import numpy as np


def read_dds(path):
    data = path.read_bytes()
    height, width = struct.unpack_from("<II", data, 12)
    dx10 = data[84:88] == b"DX10"
    return data[148 if dx10 else 128:], width, height


def unpack_r11(data):
    packed = np.frombuffer(data, dtype="<u4")
    channels = []
    for shift, bits in [(0, 6), (11, 6), (22, 5)]:
        value = (packed >> shift) & ((1 << (bits + 5)) - 1)
        exp = (value >> bits).astype(np.int32)
        mantissa = (value & ((1 << bits) - 1)).astype(np.float64)
        channels.append(np.where(exp == 0, mantissa * 2.0 ** (-14 - bits),
                                 (1 + mantissa / (1 << bits)) * np.exp2(exp - 15)))
    return np.stack(channels, axis=-1)


def compare(directory):
    results = {}
    for candidate, reference, floating in [
        ("candidate-prefilter", "prefilter-reference", True),
        ("candidate-down", "down-reference", True),
        ("candidate-bloom", "bloom-reference", True),
        ("candidate-grade-only", "post-reference", False),
        ("candidate-post", "post-reference", False),
    ]:
        ref, width, height = read_dds(directory / (reference + ".dds"))
        actual = (directory / (candidate + ".bin")).read_bytes()
        if floating:
            a, b = unpack_r11(actual), unpack_r11(ref)
        else:
            a = np.frombuffer(actual, dtype=np.uint8).reshape(-1, 4)[:, :3].astype(float)
            b = np.frombuffer(ref, dtype=np.uint8).reshape(-1, 4)[:, :3].astype(float)
        assert a.shape == b.shape == (width * height, 3)
        assert np.isfinite(a).all()
        delta = np.abs(a - b)
        results[candidate] = {
            "size": [width, height],
            "units": "linear HDR" if floating else "8-bit code values",
            "mae": float(delta.mean()),
            "rmse": float(np.sqrt((delta ** 2).mean())),
            "max": float(delta.max()),
            "p99": float(np.percentile(delta, 99)),
            "exact_fraction": float((delta == 0).mean()),
        }
    (directory / "comparison.json").write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))
    # Accept a first reconstruction only if final RGB stays close to the captured
    # output. These compare captured data, not a duplicate CPU implementation.
    assert results["candidate-prefilter"]["mae"] < 1e-6
    assert results["candidate-bloom"]["mae"] < 1e-4
    assert results["candidate-post"]["mae"] < 1.0
    assert results["candidate-post"]["p99"] <= 3.0
    assert results["candidate-post"]["max"] <= 1.0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    compare(parser.parse_args().evidence)
