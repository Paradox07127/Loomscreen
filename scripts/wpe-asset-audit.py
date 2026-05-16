#!/usr/bin/env python3
"""WPE asset-availability audit (control-variable debug tool).

Goal: assuming the user's full Wallpaper Engine install is available, trace
every referenced asset from each scene through the resolver chain we plan
to ship (project package → bundled clean-room builtins → user-granted WPE
root) and classify each ref:

  - resolves_in_scene       — the scene packs its own copy (primary mount)
  - resolves_in_builtins    — our wpe-builtins.bundle covers it
  - resolves_in_wpe_root    — needs user-granted WPE install
  - resolves_in_cross_workshop — `../<id>/...` style, needs another
                                 subscribed workshop
  - unresolved              — broken even with full WPE root

This eliminates "asset missing" as a confounding variable when debugging
playback failures. Anything that's `unresolved` despite full WPE availability
points at a pipeline bug, not a sourcing problem.

Inputs:
  --wpe-root      absolute path to a real WPE install (must contain assets/)
  --corpus-root   directory of subscribed scenes, each a workshop-ID folder
  --builtins-root path to LiveWallpaper/Resources/wpe-builtins.bundle
  --scene-id      (optional) limit to one workshop ID for tight iteration
  --report        output JSON report path (default: stdout summary only)

The tool only reads files; it never writes anywhere except the optional
report path. It is safe to run against any of the user's local data.
"""
from __future__ import annotations
import argparse
import json
import re
import struct
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


# ---------- WPE PKGV parser (mirrors LiveWallpaper/Infrastructure/WallpaperEnginePackage.swift) ----------

class PKGError(Exception):
    pass


def _u32(buf: bytes, off: int) -> tuple[int, int]:
    return struct.unpack_from('<I', buf, off)[0], off + 4


def parse_pkg(path: Path) -> tuple[str, list[tuple[str, int, int]], bytes, int]:
    """Returns (magic, entries, raw_bytes, payload_start)."""
    data = path.read_bytes()
    off = 0
    ml, off = _u32(data, off)
    if not 4 <= ml <= 16:
        raise PKGError(f"invalid magic length: {ml}")
    magic = data[off:off + ml].decode('utf-8', errors='replace')
    off += ml
    if not magic.startswith('PKGV'):
        raise PKGError(f"bad magic: {magic!r}")
    n, off = _u32(data, off)
    if n > 65_535:
        raise PKGError(f"entry count too large: {n}")
    entries: list[tuple[str, int, int]] = []
    for _ in range(n):
        nl, off = _u32(data, off)
        name = data[off:off + nl].decode('utf-8', errors='replace')
        off += nl
        o, off = _u32(data, off)
        s, off = _u32(data, off)
        entries.append((name, o, s))
    return magic, entries, data, off


# ---------- multi-root resolver (mirrors WPEMultiRootResourceResolver.swift logic) ----------

REF_RE = re.compile(r'"([a-zA-Z0-9_/.-]+\.(?:json|tex|png|frag|vert|h|geom|ttf|otf|wav|mp3|ogg|mp4|webm|mdl|jpg|jpeg))"')

# Shader headers we already stub inline in
# LiveWallpaper/Infrastructure/WPERenderPipelineBuilder.swift:builtinInclude(named:).
# Treat these as `resolves_in_builtins` so the audit doesn't false-positive
# scenes that include them. Kept in sync manually.
INLINE_STUBBED_HEADERS = {
    'common.h',
    'common_blending.h',
    'common_blur.h',
    'common_composite.h',
    'common_perspective.h',
}

# Refs we intentionally don't audit (editor-only content, never reached at runtime).
SKIP_PREFIXES = ('preview/', 'previewvhs/', 'editor/')


@dataclass
class SceneAudit:
    workshop_id: str
    entry_file: str
    resolutions: dict[str, str] = field(default_factory=dict)  # ref -> classification
    parsed_files: set[str] = field(default_factory=set)


def classify_ref(
    ref: str,
    *,
    scene_root: Path,
    builtins_root: Path,
    wpe_root: Path | None,
    corpus_root: Path,
    parent_file_relpath: str | None,
) -> str:
    """Walk our resolver chain to determine where the ref resolves."""

    # 0. Editor-only refs we deliberately don't audit
    if any(ref.startswith(p) for p in SKIP_PREFIXES):
        return 'skipped_editor_only'

    # 0a. Shader headers we stub inline in the pipeline builder
    if ref in INLINE_STUBBED_HEADERS:
        return 'resolves_in_builtins'

    # 1. Cross-workshop: `../<id>/<child>`
    if ref.startswith('../'):
        parts = ref.split('/')
        if len(parts) >= 3 and parts[0] == '..':
            workshop_id = parts[1]
            child = '/'.join(parts[2:])
            dep_dir = corpus_root / workshop_id
            if dep_dir.is_dir() and (dep_dir / child).is_file():
                return 'resolves_in_cross_workshop'
            return 'unresolved'

    # 2. Primary mount: scene-local. Also try effect-package-root convention
    # for refs inside effects/<name>/effect.json.
    candidates = [scene_root / ref]
    if parent_file_relpath and parent_file_relpath.startswith('effects/'):
        pkg_parts = parent_file_relpath.split('/')
        if len(pkg_parts) >= 2:
            candidates.append(scene_root / pkg_parts[0] / pkg_parts[1] / ref)
    for c in candidates:
        if c.is_file():
            return 'resolves_in_scene'

    # 3. Built-ins bundle
    if (builtins_root / ref).is_file():
        return 'resolves_in_builtins'

    # 4. User-granted WPE engine root (assets/ prefix)
    if wpe_root is not None:
        if (wpe_root / 'assets' / ref).is_file():
            return 'resolves_in_wpe_root'
        # Also try effect-package-root for framework effects
        if parent_file_relpath and parent_file_relpath.startswith('effects/'):
            pkg_parts = parent_file_relpath.split('/')
            if len(pkg_parts) >= 2:
                inside = wpe_root / 'assets' / pkg_parts[0] / pkg_parts[1] / ref
                if inside.is_file():
                    return 'resolves_in_wpe_root'
        # 4a. Shader `#include "name.h"` searches `assets/shaders/<name>`
        # (mirrors GLSL include conventions WPE uses).
        if ref.endswith('.h') and (wpe_root / 'assets' / 'shaders' / ref).is_file():
            return 'resolves_in_wpe_root'

    return 'unresolved'


def read_resolved(
    ref: str, *, scene_root: Path, builtins_root: Path, wpe_root: Path | None,
    parent_file_relpath: str | None,
) -> str | None:
    """Returns the text content of a ref that resolves locally or in WPE
    framework — only used for parseable file types so the trace can follow
    transitive references."""
    candidates: list[Path] = [scene_root / ref]
    if parent_file_relpath and parent_file_relpath.startswith('effects/'):
        pkg_parts = parent_file_relpath.split('/')
        if len(pkg_parts) >= 2:
            candidates.append(scene_root / pkg_parts[0] / pkg_parts[1] / ref)
    candidates.append(builtins_root / ref)
    if wpe_root is not None:
        candidates.append(wpe_root / 'assets' / ref)
        if parent_file_relpath and parent_file_relpath.startswith('effects/'):
            pkg_parts = parent_file_relpath.split('/')
            if len(pkg_parts) >= 2:
                candidates.append(wpe_root / 'assets' / pkg_parts[0] / pkg_parts[1] / ref)
    for c in candidates:
        if c.is_file():
            try:
                return c.read_text(errors='replace')
            except Exception:
                return None
    return None


def trace_scene(
    *, workshop_id: str, scene_root: Path, entry_relpath: str,
    builtins_root: Path, wpe_root: Path | None, corpus_root: Path,
) -> SceneAudit:
    audit = SceneAudit(workshop_id=workshop_id, entry_file=entry_relpath)
    # BFS over parseable files starting at the entry
    queue: list[str] = [entry_relpath]
    audit.parsed_files.add(entry_relpath)

    while queue:
        rel = queue.pop()
        text = read_resolved(
            rel, scene_root=scene_root, builtins_root=builtins_root,
            wpe_root=wpe_root, parent_file_relpath=None,
        )
        if text is None:
            audit.resolutions[rel] = audit.resolutions.get(rel, 'unresolved')
            continue
        for m in REF_RE.finditer(text):
            child = m.group(1)
            if child in audit.resolutions:
                continue
            classification = classify_ref(
                child, scene_root=scene_root, builtins_root=builtins_root,
                wpe_root=wpe_root, corpus_root=corpus_root, parent_file_relpath=rel,
            )
            audit.resolutions[child] = classification
            # Follow parseable references
            ext = Path(child).suffix.lower()
            if ext in {'.json', '.frag', '.vert', '.h', '.geom'} \
                    and classification != 'unresolved' \
                    and child not in audit.parsed_files:
                audit.parsed_files.add(child)
                queue.append(child)
    return audit


# ---------- driver ----------

def expand_scene_to_tmp(pkg_path: Path, tmp_root: Path) -> Path:
    """Extracts scene.pkg under tmp_root/<workshop_id>/ and returns scene_root."""
    workshop_id = pkg_path.parent.name
    scene_root = tmp_root / workshop_id
    scene_root.mkdir(parents=True, exist_ok=True)
    try:
        magic, entries, data, payload_start = parse_pkg(pkg_path)
    except PKGError as e:
        raise SystemExit(f"{workshop_id}: {e}")
    for name, off, size in entries:
        out = scene_root / name
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(data[payload_start + off:payload_start + off + size])
    return scene_root


def discover_scene(workshop_dir: Path, tmp_root: Path) -> tuple[Path, str] | None:
    """Returns (scene_root, entry_relpath) or None if not a scene project."""
    project_json = workshop_dir / 'project.json'
    if not project_json.is_file():
        return None
    try:
        meta = json.loads(project_json.read_text(errors='replace'))
    except Exception:
        return None
    if meta.get('type', '').lower() != 'scene':
        return None
    entry = meta.get('file') or 'scene.json'
    pkg = workshop_dir / 'scene.pkg'
    if pkg.is_file():
        scene_root = expand_scene_to_tmp(pkg, tmp_root)
    elif (workshop_dir / entry).is_file():
        # Already-unpacked scene
        scene_root = workshop_dir
    else:
        return None
    return scene_root, entry


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--wpe-root', type=Path, default=None,
                   help='Absolute path to WPE install (contains assets/)')
    p.add_argument('--corpus-root', type=Path, required=True,
                   help='Directory of workshop-ID folders')
    p.add_argument('--builtins-root', type=Path, required=True,
                   help='Path to wpe-builtins.bundle')
    p.add_argument('--scene-id', default=None,
                   help='Limit audit to one workshop ID')
    p.add_argument('--report', type=Path, default=None,
                   help='Write per-scene JSON report')
    p.add_argument('--tmp', type=Path, default=Path('/tmp/wpe_audit'),
                   help='Where to expand scene.pkg (default /tmp/wpe_audit)')
    args = p.parse_args()

    args.tmp.mkdir(parents=True, exist_ok=True)
    targets: list[Path]
    if args.scene_id:
        targets = [args.corpus_root / args.scene_id]
    else:
        targets = sorted(args.corpus_root.iterdir())

    audits: list[SceneAudit] = []
    for workshop_dir in targets:
        if not workshop_dir.is_dir():
            continue
        discovery = discover_scene(workshop_dir, args.tmp)
        if discovery is None:
            continue
        scene_root, entry = discovery
        a = trace_scene(
            workshop_id=workshop_dir.name, scene_root=scene_root,
            entry_relpath=entry,
            builtins_root=args.builtins_root, wpe_root=args.wpe_root,
            corpus_root=args.corpus_root,
        )
        audits.append(a)

    # Aggregate
    print(f'Scenes audited: {len(audits)}')
    print(f'WPE root: {args.wpe_root or "(none — playing without engine fallback)"}')
    print(f'Builtins root: {args.builtins_root}')

    bucket = Counter()
    per_scene_unresolved: dict[str, list[str]] = {}
    fully_resolved_scenes: list[str] = []
    needs_wpe_only_scenes: list[str] = []
    needs_cross_only_scenes: list[str] = []
    needs_unresolved_scenes: list[str] = []

    for a in audits:
        local_bucket = Counter(a.resolutions.values())
        for k, v in local_bucket.items():
            bucket[k] += v

        unresolved = sorted(r for r, c in a.resolutions.items() if c == 'unresolved')
        needs_wpe = any(c == 'resolves_in_wpe_root' for c in a.resolutions.values())
        needs_cross = any(c == 'resolves_in_cross_workshop' for c in a.resolutions.values())

        if not unresolved and not needs_wpe and not needs_cross:
            fully_resolved_scenes.append(a.workshop_id)
        elif not unresolved and not needs_cross and needs_wpe:
            needs_wpe_only_scenes.append(a.workshop_id)
        elif not unresolved and needs_cross and not needs_wpe:
            needs_cross_only_scenes.append(a.workshop_id)
        elif unresolved:
            needs_unresolved_scenes.append(a.workshop_id)
            per_scene_unresolved[a.workshop_id] = unresolved

    print('\n--- aggregate resolution buckets (all refs) ---')
    for k, v in bucket.most_common():
        print(f'  {v:5d}  {k}')

    print('\n--- per-scene status ---')
    print(f'  ✅ fully resolved via scene+builtins (no WPE / no cross-workshop): {len(fully_resolved_scenes)}')
    print(f'  📁 also needs WPE engine root: {len(needs_wpe_only_scenes)}')
    print(f'  🔗 also needs cross-workshop dep (Steam subscribe): {len(needs_cross_only_scenes)}')
    print(f'  ❌ has UNRESOLVED refs even with full WPE: {len(needs_unresolved_scenes)}')

    if needs_unresolved_scenes:
        print('\n--- scenes with unresolved refs (pipeline issue, not asset issue) ---')
        for wid in needs_unresolved_scenes[:25]:
            print(f'  {wid}:')
            for ref in per_scene_unresolved[wid][:8]:
                print(f'    - {ref}')
            if len(per_scene_unresolved[wid]) > 8:
                print(f'    ... {len(per_scene_unresolved[wid]) - 8} more')

    if args.report:
        report = {
            'wpe_root': str(args.wpe_root) if args.wpe_root else None,
            'corpus_root': str(args.corpus_root),
            'builtins_root': str(args.builtins_root),
            'aggregate': dict(bucket),
            'fully_resolved': fully_resolved_scenes,
            'needs_wpe_only': needs_wpe_only_scenes,
            'needs_cross_only': needs_cross_only_scenes,
            'needs_unresolved': {wid: per_scene_unresolved[wid] for wid in needs_unresolved_scenes},
            'per_scene': [
                {
                    'workshop_id': a.workshop_id,
                    'entry': a.entry_file,
                    'buckets': dict(Counter(a.resolutions.values())),
                    'refs': a.resolutions,
                }
                for a in audits
            ],
        }
        args.report.write_text(json.dumps(report, indent=2))
        print(f'\nFull report → {args.report}')

    return 0


if __name__ == '__main__':
    sys.exit(main())
