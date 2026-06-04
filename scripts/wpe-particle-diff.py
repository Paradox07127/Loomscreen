#!/usr/bin/env python3
"""WPE particle-fidelity gap auditor (control-variable debug tool).

Goal: for every scene's particle systems, list each WPE field / emitter
attribute / initializer / operator that our Swift parser
(`WPEParticleDefinition.swift`) does NOT consume — i.e. the things WPE
authored that we silently drop, which is exactly why a preset mis-renders
on device (the leaf animates when it should freeze, the smoke is too thick,
the fire plays too fast, …).

This is the static half of the three-way diff that found the
`animationmode` / `colorchange` gaps:

    WPE source JSON   vs   our supported-key allowlist (below, kept in sync
                           with WPEParticleDefinition.swift by hand)

The dynamic half — comparing on-device output against the scene's own
`preview.gif` — has to be done by eye; this tool eliminates "we never
parsed that field" as a confounding variable first.

Usage:
    # one scene, tight iteration
    python3 scripts/wpe-particle-diff.py --corpus-root <dir> --scene-id 3460973721

    # whole corpus, ranked by how many particles hit each gap
    python3 scripts/wpe-particle-diff.py --corpus-root <dir> --report /tmp/gaps.json

`--corpus-root` is a directory of workshop-ID folders, each containing a
`scene.pkg` (read in place — particle JSONs are tiny, we never extract the
55 MB payload) or an already-unpacked `particles/` tree.

The tool only reads files; it writes only the optional --report path.
"""
from __future__ import annotations
import argparse
import json
import re
import struct
import sys
from collections import Counter, defaultdict
from pathlib import Path


# ---------- PKGV index reader (mirrors WallpaperEnginePackage.swift) ----------

def _u32(buf: bytes, off: int) -> tuple[int, int]:
    return struct.unpack_from("<I", buf, off)[0], off + 4


def pkg_particle_entries(pkg: Path):
    """Yield (name, bytes) for every `particles/*.json` entry in a scene.pkg,
    reading only those entries' payloads (not the whole 55 MB package)."""
    data = pkg.read_bytes()
    off = 0
    ml, off = _u32(data, off)
    if not 4 <= ml <= 16:
        return
    magic = data[off:off + ml].decode("utf-8", "replace")
    off += ml
    if not magic.startswith("PKGV"):
        return
    n, off = _u32(data, off)
    if n > 65_535:
        return
    entries = []
    for _ in range(n):
        nl, off = _u32(data, off)
        name = data[off:off + nl].decode("utf-8", "replace")
        off += nl
        o, off = _u32(data, off)
        s, off = _u32(data, off)
        entries.append((name, o, s))
    payload_start = off
    for name, o, s in entries:
        if re.fullmatch(r"particles/.*\.json", name):
            yield name, data[payload_start + o:payload_start + o + s]


# ---------- supported-key allowlists (sync with WPEParticleDefinition.swift) ----------
# Anything WPE writes that is NOT in these sets is a gap we report.

# Top-level particle JSON keys the parser reacts to. The "ignored-OK" ones
# are structural/cosmetic and safe to drop; everything else is impactful.
SUPPORTED_TOP_KEYS = {
    "material", "children", "maxcount", "starttime", "sequencemultiplier",
    "animationmode", "emitter", "initializer", "operator", "controlpoint",
}
IGNORED_TOP_OK = {"name", "id", "flags", "renderer"}

# Emitter attributes the parser reads (rate / origin / distance / directions).
SUPPORTED_EMITTER = {"rate", "origin", "distancemin", "distancemax", "directions"}
IGNORED_EMITTER_OK = {"name", "id"}

# Initializer `name`s the parser handles.
SUPPORTED_INITIALIZERS = {
    "lifetimerandom", "lifetime", "sizerandom", "size",
    "velocityrandom", "velocity", "colorrandom", "color",
    "alpharandom", "alpha", "rotationrandom", "angularvelocityrandom",
    "turbulentvelocityrandom",
}

# Operator `name`s the parser handles.
SUPPORTED_OPERATORS = {
    "controlpointattract", "alphafade", "movement", "angularmovement",
    "turbulence",
}

# Sub-parameters we read incompletely even though the parent IS supported —
# surfaced as "partial" so they're visible without being scored as hard gaps.
PARTIAL_NOTES = {
    "emitter.directions": "read as an abs() per-axis mask, not a biased emission cone",
    "initializer.exponent": "distribution exponent ignored (uniform sampling only)",
}


def audit_particle(name: str, doc: dict) -> dict:
    gaps = {
        "file": name,
        "animationmode": doc.get("animationmode", "(default: sequence)"),
        "unsupported_top_keys": [],
        "unsupported_emitter_fields": [],
        "unsupported_initializers": [],
        "unsupported_operators": [],
        "partial": [],
    }

    for k in doc:
        if k not in SUPPORTED_TOP_KEYS and k not in IGNORED_TOP_OK:
            gaps["unsupported_top_keys"].append(k)

    emitters = doc.get("emitter") or []
    if isinstance(emitters, list):
        for em in emitters:
            if not isinstance(em, dict):
                continue
            for k in em:
                if k not in SUPPORTED_EMITTER and k not in IGNORED_EMITTER_OK:
                    gaps["unsupported_emitter_fields"].append(k)
            if "directions" in em:
                gaps["partial"].append("emitter.directions")

    for ini in doc.get("initializer") or []:
        if isinstance(ini, dict):
            nm = (ini.get("name") or "").lower()
            if nm and nm not in SUPPORTED_INITIALIZERS:
                gaps["unsupported_initializers"].append(nm)
            if "exponent" in ini:
                gaps["partial"].append("initializer.exponent")

    for op in doc.get("operator") or []:
        if isinstance(op, dict):
            nm = (op.get("name") or "").lower()
            if nm and nm not in SUPPORTED_OPERATORS:
                gaps["unsupported_operators"].append(nm)

    # dedup, keep order-insensitive but stable
    for key in ("unsupported_top_keys", "unsupported_emitter_fields",
                "unsupported_initializers", "unsupported_operators", "partial"):
        gaps[key] = sorted(set(gaps[key]))
    return gaps


def has_gaps(g: dict) -> bool:
    return any(g[k] for k in (
        "unsupported_top_keys", "unsupported_emitter_fields",
        "unsupported_initializers", "unsupported_operators"))


def iter_scene_particles(workshop_dir: Path):
    """Yield (relpath, parsed_json) for each particle in a scene dir,
    from scene.pkg in place or an already-unpacked particles/ tree."""
    pkg = workshop_dir / "scene.pkg"
    if pkg.is_file():
        for name, raw in pkg_particle_entries(pkg):
            try:
                yield name, json.loads(raw)
            except Exception:
                continue
        return
    for jp in sorted((workshop_dir / "particles").rglob("*.json")) \
            if (workshop_dir / "particles").is_dir() else []:
        try:
            yield str(jp.relative_to(workshop_dir)), json.loads(jp.read_text(errors="replace"))
        except Exception:
            continue


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--corpus-root", type=Path, required=True)
    p.add_argument("--scene-id", default=None, help="limit to one workshop ID")
    p.add_argument("--report", type=Path, default=None, help="write JSON report")
    p.add_argument("--all", action="store_true",
                   help="list every particle, even fully-supported ones")
    args = p.parse_args()

    targets = ([args.corpus_root / args.scene_id] if args.scene_id
               else sorted(d for d in args.corpus_root.iterdir() if d.is_dir()))

    feature_hits: Counter = Counter()          # "operator:colorchange" -> #particles
    scenes_with_gaps: dict[str, list] = {}
    scanned_scenes = 0
    scanned_particles = 0

    for wd in targets:
        if not wd.is_dir():
            continue
        per_scene = []
        for relpath, doc in iter_scene_particles(wd):
            if not isinstance(doc, dict):
                continue
            scanned_particles += 1
            g = audit_particle(relpath, doc)
            if has_gaps(g) or args.all:
                per_scene.append(g)
            for k in g["unsupported_top_keys"]:
                feature_hits[f"top:{k}"] += 1
            for k in g["unsupported_emitter_fields"]:
                feature_hits[f"emitter:{k}"] += 1
            for k in g["unsupported_initializers"]:
                feature_hits[f"initializer:{k}"] += 1
            for k in g["unsupported_operators"]:
                feature_hits[f"operator:{k}"] += 1
        if per_scene:
            scanned_scenes += 1
            scenes_with_gaps[wd.name] = per_scene

    print(f"Scenes scanned: {len(targets)}   particles scanned: {scanned_particles}")
    print(f"Scenes with at least one particle gap: {len(scenes_with_gaps)}\n")

    print("--- most common unsupported features (particle count) ---")
    if not feature_hits:
        print("  (none — every particle's fields are fully consumed)")
    for feat, cnt in feature_hits.most_common():
        print(f"  {cnt:5d}  {feat}")

    # Per-scene detail (capped for readability unless --report)
    print("\n--- per-scene particle gaps ---")
    for sid, particles in list(scenes_with_gaps.items())[:40]:
        print(f"\n  {sid}:")
        for g in particles:
            bits = []
            if g["unsupported_operators"]:
                bits.append(f"op={g['unsupported_operators']}")
            if g["unsupported_initializers"]:
                bits.append(f"init={g['unsupported_initializers']}")
            if g["unsupported_emitter_fields"]:
                bits.append(f"emitter={g['unsupported_emitter_fields']}")
            if g["unsupported_top_keys"]:
                bits.append(f"top={g['unsupported_top_keys']}")
            print(f"    - {g['file']}  [mode={g['animationmode']}]  " + "  ".join(bits))

    if args.report:
        args.report.write_text(json.dumps({
            "feature_hits": dict(feature_hits),
            "scenes": scenes_with_gaps,
            "partial_notes": PARTIAL_NOTES,
        }, indent=2, ensure_ascii=False))
        print(f"\nFull report → {args.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
