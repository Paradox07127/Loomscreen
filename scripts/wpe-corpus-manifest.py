#!/usr/bin/env python3
"""Build a deterministic, path-redacted inventory for a local WPE corpus.

The scanner only enumerates immediate child directories, reads the small loose
``project.json`` manifest, and checks whether the declared entry/``scene.pkg``
exists. It never reads or copies ``scene.pkg`` or other wallpaper assets.

The corpus root is deliberately absent from the JSON output. This makes the
result suitable for review/version control while the source remains in an app
container or any user-authorized external directory.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any


SCHEMA = "wpe.corpus-manifest.v1"
DEFAULT_MAX_PROJECT_JSON_BYTES = 2 * 1024 * 1024
ROOT_LABEL_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


class CorpusManifestError(RuntimeError):
    """An actionable corpus discovery/configuration error."""


def _safe_component(value: str) -> bool:
    return bool(value) and value not in {".", ".."} and "/" not in value and "\\" not in value and ".." not in value


def _safe_relative_path(value: str) -> bool:
    if not value or value.startswith("/") or "\\" in value:
        return False
    parts = value.split("/")
    return all(part not in {"", ".", ".."} for part in parts)


def _flexible_string(value: Any) -> str | None:
    if isinstance(value, str):
        stripped = value.strip()
        return stripped or None
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    return None


def _regular_readable_file(path: Path) -> bool:
    """Check without following symlinks or opening large payloads."""
    try:
        mode = path.lstat().st_mode
    except OSError:
        return False
    return stat.S_ISREG(mode) and os.access(path, os.R_OK)


def _scan_project(folder: Path, folder_id: str, max_bytes: int) -> dict[str, Any]:
    project_path = folder / "project.json"
    issues: list[str] = []
    manifest_state = "missing"
    workshop_id: str | None = folder_id if _safe_component(folder_id) else None
    project_type = "unknown"
    entry_file: str | None = None

    try:
        project_stat = project_path.lstat()
    except FileNotFoundError:
        project_stat = None
    except OSError:
        project_stat = None
        manifest_state = "unreadable"

    if project_stat is not None:
        if not stat.S_ISREG(project_stat.st_mode):
            manifest_state = "unreadable"
            issues.append("projectJSONNotRegularFile")
        elif project_stat.st_size > max_bytes:
            manifest_state = "tooLarge"
            issues.append("projectJSONExceedsReadLimit")
        else:
            try:
                flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
                descriptor = os.open(project_path, flags)
                with os.fdopen(descriptor, "rb") as handle:
                    opened_stat = os.fstat(handle.fileno())
                    if not stat.S_ISREG(opened_stat.st_mode):
                        raise CorpusManifestError("project.json changed to a non-regular file during scan")
                    raw = handle.read(max_bytes + 1)
            except OSError:
                manifest_state = "unreadable"
            except CorpusManifestError:
                manifest_state = "unreadable"
            else:
                if len(raw) > max_bytes:
                    manifest_state = "tooLarge"
                    issues.append("projectJSONExceedsReadLimit")
                else:
                    try:
                        decoded = json.loads(raw)
                    except (UnicodeDecodeError, json.JSONDecodeError):
                        manifest_state = "malformed"
                    else:
                        if not isinstance(decoded, dict):
                            manifest_state = "malformed"
                        else:
                            manifest_state = "readable"
                            declared_id = _flexible_string(decoded.get("workshopid"))
                            if declared_id is not None:
                                if _safe_component(declared_id):
                                    workshop_id = declared_id
                                    if declared_id != folder_id:
                                        issues.append("workshopIDDiffersFromFolder")
                                else:
                                    issues.append("unsafeWorkshopID")

                            declared_type = _flexible_string(decoded.get("type"))
                            if declared_type is not None:
                                normalized_type = declared_type.lower()
                                project_type = normalized_type if normalized_type in {
                                    "scene", "web", "video", "application"
                                } else "unknown"

                            declared_entry = _flexible_string(decoded.get("file"))
                            if declared_entry is None:
                                issues.append("missingEntryFile")
                            elif _safe_relative_path(declared_entry):
                                entry_file = declared_entry
                            else:
                                issues.append("unsafeEntryFile")

    if manifest_state != "readable":
        issues.append(f"projectJSON{manifest_state[0].upper()}{manifest_state[1:]}")

    entry_readable = bool(entry_file and _regular_readable_file(folder / entry_file))
    scene_json_readable = _regular_readable_file(folder / "scene.json")
    scene_package_readable = _regular_readable_file(folder / "scene.pkg")
    capture_candidate = (
        manifest_state == "readable"
        and project_type == "scene"
        and entry_file is not None
        and (entry_readable or scene_package_readable)
    )

    return {
        "folderID": folder_id,
        "workshopID": workshop_id,
        "projectType": project_type,
        "entryFile": entry_file,
        "accessibility": {
            "projectJSON": manifest_state,
            "entryFileReadable": entry_readable,
            "sceneJSONReadable": scene_json_readable,
            "scenePackageReadable": scene_package_readable,
        },
        "captureCandidate": capture_candidate,
        "issues": sorted(set(issues)),
    }


def build_manifest(root: Path, *, root_label: str, max_bytes: int) -> dict[str, Any]:
    if not ROOT_LABEL_RE.fullmatch(root_label):
        raise CorpusManifestError("root label must match [A-Za-z0-9._-]{1,64}")
    if max_bytes < 1:
        raise CorpusManifestError("project.json read limit must be positive")
    try:
        root_stat = root.lstat()
    except FileNotFoundError as error:
        raise CorpusManifestError(f"corpus root does not exist: {root}") from error
    except PermissionError as error:
        raise CorpusManifestError(f"permission denied reading corpus root: {root}") from error
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        raise CorpusManifestError("corpus root must be a real directory, not a symlink")

    try:
        children = sorted(root.iterdir(), key=lambda child: child.name)
    except PermissionError as error:
        raise CorpusManifestError(f"permission denied enumerating corpus root: {root}") from error

    entries: list[dict[str, Any]] = []
    for child in children:
        if child.name.startswith("."):
            continue
        try:
            child_mode = child.lstat().st_mode
        except OSError:
            continue
        if stat.S_ISLNK(child_mode) or not stat.S_ISDIR(child_mode):
            continue
        entries.append(_scan_project(child, child.name, max_bytes))

    type_counts = Counter(entry["projectType"] for entry in entries)
    state_counts = Counter(entry["accessibility"]["projectJSON"] for entry in entries)
    return {
        "schema": SCHEMA,
        "rootLabel": root_label,
        "summary": {
            "directories": len(entries),
            "captureCandidates": sum(bool(entry["captureCandidate"]) for entry in entries),
            "projectTypes": dict(sorted(type_counts.items())),
            "projectJSONStates": dict(sorted(state_counts.items())),
        },
        "entries": entries,
    }


def encode_manifest(manifest: dict[str, Any]) -> bytes:
    return (json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    try:
        temporary.replace(path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="wpe-corpus-manifest-") as temporary:
        root = Path(temporary) / "private-user-corpus"
        root.mkdir()

        scene = root / "10"
        scene.mkdir()
        (scene / "project.json").write_text(
            json.dumps({"workshopid": 10, "type": "scene", "file": "scene.json"}),
            encoding="utf-8",
        )
        (scene / "scene.pkg").write_bytes(b"not-read-by-the-scanner")

        web = root / "2"
        web.mkdir()
        (web / "project.json").write_text(
            json.dumps({"workshopid": "2", "type": "web", "file": "index.html"}),
            encoding="utf-8",
        )
        (web / "index.html").write_text("ok", encoding="utf-8")

        malformed = root / "3"
        malformed.mkdir()
        (malformed / "project.json").write_text("{", encoding="utf-8")

        oversized = root / "4"
        oversized.mkdir()
        (oversized / "project.json").write_bytes(b" " * 1025)

        unsafe = root / "5"
        unsafe.mkdir()
        (unsafe / "project.json").write_text(
            json.dumps({"workshopid": "5", "type": "scene", "file": "../private/scene.json"}),
            encoding="utf-8",
        )

        outside = Path(temporary) / "must-not-be-followed"
        outside.mkdir()
        (root / "999").symlink_to(outside, target_is_directory=True)

        first = encode_manifest(build_manifest(root, root_label="self-test", max_bytes=1024))
        second = encode_manifest(build_manifest(root, root_label="self-test", max_bytes=1024))
        assert first == second, "identical scans must be byte-identical"
        assert str(root).encode() not in first, "manifest must not contain the corpus root"
        decoded = json.loads(first)
        assert [entry["folderID"] for entry in decoded["entries"]] == ["10", "2", "3", "4", "5"]
        assert decoded["summary"]["directories"] == 5
        assert decoded["summary"]["captureCandidates"] == 1
        assert decoded["entries"][0]["accessibility"]["scenePackageReadable"] is True
        assert decoded["entries"][2]["accessibility"]["projectJSON"] == "malformed"
        assert decoded["entries"][3]["accessibility"]["projectJSON"] == "tooLarge"
        assert decoded["entries"][4]["entryFile"] is None
        assert "unsafeEntryFile" in decoded["entries"][4]["issues"]
        try:
            build_manifest(root, root_label="../../leak", max_bytes=1024)
        except CorpusManifestError:
            pass
        else:
            raise AssertionError("unsafe root label must be rejected")
    print("wpe-corpus-manifest self-test: PASS")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus_root", nargs="?", type=Path, help="workshop content/431960 directory")
    parser.add_argument("--output", type=Path, help="write JSON atomically instead of stdout")
    parser.add_argument("--root-label", default="workshop-431960", help="path-free corpus label")
    parser.add_argument(
        "--max-project-json-bytes",
        type=int,
        default=DEFAULT_MAX_PROJECT_JSON_BYTES,
        help="maximum bytes read from any project.json (default: 2 MiB)",
    )
    parser.add_argument(
        "--check-repeatability",
        action="store_true",
        help="scan twice and fail if the byte output changes",
    )
    parser.add_argument("--self-test", action="store_true", help="run synthetic determinism/privacy checks")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.self_test:
        self_test()
        return 0
    if args.corpus_root is None:
        print("error: corpus_root is required unless --self-test is used", file=sys.stderr)
        return 2
    try:
        first = encode_manifest(build_manifest(
            args.corpus_root,
            root_label=args.root_label,
            max_bytes=args.max_project_json_bytes,
        ))
        if args.check_repeatability:
            second = encode_manifest(build_manifest(
                args.corpus_root,
                root_label=args.root_label,
                max_bytes=args.max_project_json_bytes,
            ))
            if first != second:
                print("error: corpus changed between repeatability scans", file=sys.stderr)
                return 3
    except (CorpusManifestError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    if args.output is None:
        sys.stdout.buffer.write(first)
    else:
        _write_atomic(args.output, first)
        print(f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
