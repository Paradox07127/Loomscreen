#!/usr/bin/env python3
"""Extract WPE's per-frame GLOBAL conditions from a windows wpe.trace.v1 into a
compact `replay.json` (wpe.replay.v1) that the Mac renderer's constant-replay
override (Phase D-1) feeds back into its uniform packing for a controlled
re-render.

The goal is to eliminate the dynamic NOISE that otherwise dominates a diff —
capture time, pointer, render resolution — so a re-rendered Mac frame differs
from WPE only by genuine shader/texture/RT logic. Scope is the frame globals our
fragment path actually consumes: g_Time, render resolution (drives both the
render size and g_Texture*Resolution), pointer anchors (g_Point0..3), daytime.
Per-material statics (g_Speed, g_Strength, ...) come from scene.pkg and are NOT
replayed here; MVP is moot for our fragment-only fixed-fullscreen-vertex path.

    python3 extract_replay.py --windows windows/trace.json --out replay.json

Only D3D_SVF_USED variables with decoded values are read (the parser marks
unused reflection slots, which carry no real value).
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Optional

# Names that vary per capture (time/pointer) — the whole point of replay is to
# pin these. Resolution is handled separately (it also drives the render size).
FRAME_TIME_NAMES = {"g_time", "time", "u_time", "itime"}
DAYTIME_NAMES = {"g_daytime", "daytime"}
POINT_PREFIX = "g_point"  # g_Point0..3 — pointer/parallax anchors


def load(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def used_variables(trace: dict[str, Any]):
    """Yield (pass_ordinal, shader_name, var) for every USED, decoded variable."""
    for p in trace.get("passes", []) or []:
        shader = p.get("shaderName")
        ordinal = p.get("ordinal")
        for cb in p.get("constantBuffers", []) or []:
            for var in cb.get("variables", []) or []:
                if var.get("value") is None:
                    continue
                if var.get("usedByShader") is False:
                    continue
                yield ordinal, shader, var


def first_value(trace: dict[str, Any], predicate) -> Optional[Any]:
    for _, _, var in used_variables(trace):
        if predicate(var.get("name", "")):
            return var.get("value")
    return None


def extract_resolution(trace: dict[str, Any]) -> dict[str, int]:
    cap = (trace.get("capture") or {}).get("resolution") or {}
    width, height = cap.get("width"), cap.get("height")
    if width and height:
        return {"width": int(width), "height": int(height)}
    # Fall back to g_Texture0Resolution (xy = render-target dimensions).
    res = first_value(trace, lambda n: n.lower() == "g_texture0resolution")
    if isinstance(res, list) and len(res) >= 2 and res[0] and res[1]:
        return {"width": int(res[0]), "height": int(res[1])}
    return {}


def build_replay(trace: dict[str, Any]) -> dict[str, Any]:
    scene = trace.get("scene") or {}
    determinism = (trace.get("capture") or {}).get("determinism") or {}

    time_value = first_value(trace, lambda n: n.lower() in FRAME_TIME_NAMES)
    daytime_value = first_value(trace, lambda n: n.lower() in DAYTIME_NAMES)
    if daytime_value is None:
        daytime_value = determinism.get("daytime")

    # Pointer anchors (g_Point0..3) if WPE decoded them; the override applies them
    # by name, falling back to the capture pointer for the cursor position.
    points: dict[str, Any] = {}
    for _, _, var in used_variables(trace):
        name = var.get("name", "")
        if name.lower().startswith(POINT_PREFIX):
            points.setdefault(name, var.get("value"))

    return {
        "schema": "wpe.replay.v1",
        "sceneId": str(scene.get("workshopId") or ""),
        "resolution": extract_resolution(trace),
        "frame": {
            "time": time_value,
            "daytime": daytime_value,
            "pointer": determinism.get("pointer") or [0.5, 0.5],
            "points": points or None,
        },
        "source": {
            "producer": (trace.get("producer") or {}).get("side"),
            "wpeVersion": (trace.get("producer") or {}).get("wpeVersion"),
        },
    }


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--windows", type=Path, required=True, help="Windows WPE wpe.trace.v1 JSON.")
    parser.add_argument("--out", type=Path, required=True, help="Output replay.json (wpe.replay.v1).")
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv)
    replay = build_replay(load(args.windows))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(replay, handle, indent=2, sort_keys=True)
        handle.write("\n")
    frame = replay["frame"]
    res = replay["resolution"]
    print(f"wrote {args.out}")
    print(f"  scene={replay['sceneId']} resolution={res.get('width')}x{res.get('height')} "
          f"time={frame['time']} daytime={frame['daytime']} pointer={frame['pointer']}")
    print(f"  point anchors: {sorted((frame.get('points') or {}).keys()) or 'none'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
