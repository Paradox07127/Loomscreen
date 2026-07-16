#!/usr/bin/env python3
"""Ratchet the app target away from blanket package re-exports.

AF-01 is an incremental migration: the legacy umbrella remains until every
consumer has an explicit import. This offline gate freezes that umbrella,
checks the files already migrated, and reports reproducible repository-wide
import statistics. It deliberately does not infer module ownership from symbol
spelling; the Swift compiler remains the authority for that during later
directory-by-directory migrations.
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys
import tempfile
from typing import Any


DEFAULT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BASELINE = Path("scripts/quality-baselines/module-imports.json")
EXPORTED_IMPORT = re.compile(r"^\s*@_exported\s+import\s+([A-Za-z_]\w*)\s*$", re.MULTILINE)
EXPLICIT_IMPORT = re.compile(r"^\s*import\s+([A-Za-z_]\w*)\s*$", re.MULTILINE)


def load_document(path: Path, errors: list[str]) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        errors.append(f"missing baseline: {path}")
        return {}
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"cannot read baseline {path}: {error}")
        return {}
    if not isinstance(document, dict):
        errors.append("module import baseline must contain a JSON object")
        return {}
    return document


def swift_sources(root: Path) -> list[Path]:
    source_root = root / "LiveWallpaper"
    return sorted(path for path in source_root.rglob("*.swift") if path.is_file())


def relative(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def inventory(root: Path, modules: set[str]) -> dict[str, Any]:
    files = swift_sources(root)
    occurrences: Counter[str] = Counter()
    files_with_imports = 0
    imported_files_by_area: Counter[str] = Counter()

    for path in files:
        source = path.read_text(encoding="utf-8")
        imports = [module for module in EXPLICIT_IMPORT.findall(source) if module in modules]
        if not imports:
            continue
        files_with_imports += 1
        occurrences.update(imports)
        parts = path.relative_to(root / "LiveWallpaper").parts
        area = parts[0] if len(parts) < 3 else "/".join(parts[:2])
        imported_files_by_area[area] += 1

    return {
        "swift_file_count": len(files),
        "files_with_explicit_local_package_imports": files_with_imports,
        "local_package_import_occurrences": {
            module: occurrences[module] for module in sorted(modules)
        },
        "explicit_import_files_by_area": dict(sorted(imported_files_by_area.items())),
    }


def validate(root: Path, baseline_path: Path) -> tuple[list[str], dict[str, Any]]:
    errors: list[str] = []
    document = load_document(baseline_path, errors)
    if document.get("schema_version") != 1:
        errors.append("module import baseline schema_version must be 1")

    raw_modules = document.get("local_package_modules")
    if not isinstance(raw_modules, list) or not raw_modules or not all(
        isinstance(module, str) and module for module in raw_modules
    ):
        errors.append("local_package_modules must be a non-empty string array")
        raw_modules = []
    modules = set(raw_modules)

    raw_exports = document.get("allowed_exported_imports")
    expected_exports: dict[str, list[str]] = {}
    if not isinstance(raw_exports, dict) or not raw_exports:
        errors.append("allowed_exported_imports must be a non-empty object")
    else:
        for path, raw_values in raw_exports.items():
            if not isinstance(path, str) or not isinstance(raw_values, list) or not all(
                isinstance(value, str) for value in raw_values
            ):
                errors.append(f"invalid allowed_exported_imports entry: {path!r}")
                continue
            expected_exports[path] = sorted(raw_values)

    actual_exports: dict[str, list[str]] = {}
    for path in swift_sources(root):
        source = path.read_text(encoding="utf-8")
        exported = sorted(EXPORTED_IMPORT.findall(source))
        if exported:
            actual_exports[relative(root, path)] = exported
    if actual_exports != expected_exports:
        errors.append(
            "@_exported import inventory changed; expected "
            f"{expected_exports}, found {actual_exports}"
        )

    raw_migrated = document.get("migrated_file_requirements")
    if not isinstance(raw_migrated, dict) or not raw_migrated:
        errors.append("migrated_file_requirements must be a non-empty object")
        raw_migrated = {}
    for path, raw_required in raw_migrated.items():
        if not isinstance(path, str) or not isinstance(raw_required, list) or not all(
            isinstance(module, str) for module in raw_required
        ):
            errors.append(f"invalid migrated_file_requirements entry: {path!r}")
            continue
        source_path = root / path
        if not source_path.is_file():
            errors.append(f"migrated source is missing: {path}")
            continue
        explicit = set(EXPLICIT_IMPORT.findall(source_path.read_text(encoding="utf-8")))
        missing = sorted(set(raw_required) - explicit)
        if missing:
            errors.append(f"{path} lost explicit imports: {', '.join(missing)}")

    current = inventory(root, modules)
    minimum_files = document.get("minimum_explicit_import_files")
    if not isinstance(minimum_files, int) or isinstance(minimum_files, bool) or minimum_files < 1:
        errors.append("minimum_explicit_import_files must be a positive integer")
    elif current["files_with_explicit_local_package_imports"] < minimum_files:
        errors.append(
            "explicit-import file count regressed from "
            f"{minimum_files} to {current['files_with_explicit_local_package_imports']}"
        )

    raw_minimums = document.get("minimum_import_occurrences")
    if not isinstance(raw_minimums, dict):
        errors.append("minimum_import_occurrences must be an object")
    else:
        current_occurrences = current["local_package_import_occurrences"]
        for module in sorted(modules):
            minimum = raw_minimums.get(module)
            if not isinstance(minimum, int) or isinstance(minimum, bool) or minimum < 0:
                errors.append(f"missing or invalid occurrence minimum for {module}")
            elif current_occurrences[module] < minimum:
                errors.append(
                    f"{module} explicit imports regressed from {minimum} "
                    f"to {current_occurrences[module]}"
                )

    return errors, current


def print_inventory(current: dict[str, Any]) -> None:
    explicit = current["files_with_explicit_local_package_imports"]
    total = current["swift_file_count"]
    percentage = (explicit / total * 100) if total else 0
    print(f"explicit local-package imports: {explicit}/{total} app Swift files ({percentage:.1f}%)")
    for module, count in current["local_package_import_occurrences"].items():
        print(f"  {module}: {count}")


def self_test() -> int:
    baseline = {
        "schema_version": 1,
        "local_package_modules": ["PackageA", "PackageB"],
        "allowed_exported_imports": {"LiveWallpaper/App/CoreExports.swift": ["PackageA"]},
        "migrated_file_requirements": {"LiveWallpaper/Leaf.swift": ["PackageA"]},
        "minimum_explicit_import_files": 1,
        "minimum_import_occurrences": {"PackageA": 1, "PackageB": 0},
    }
    with tempfile.TemporaryDirectory(prefix="module-import-gate-") as directory:
        root = Path(directory)
        (root / "LiveWallpaper/App").mkdir(parents=True)
        (root / "scripts/quality-baselines").mkdir(parents=True)
        baseline_path = root / DEFAULT_BASELINE
        baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
        umbrella = root / "LiveWallpaper/App/CoreExports.swift"
        leaf = root / "LiveWallpaper/Leaf.swift"
        umbrella.write_text("@_exported import PackageA\n", encoding="utf-8")
        leaf.write_text("import PackageA\n", encoding="utf-8")

        checks = 0
        failures = 0
        errors, _ = validate(root, baseline_path)
        checks += 1
        if errors:
            failures += 1
            print(f"self-test control failed: {errors}", file=sys.stderr)

        umbrella.write_text("@_exported import PackageA\n@_exported import PackageB\n", encoding="utf-8")
        errors, _ = validate(root, baseline_path)
        checks += 1
        if not any("@_exported import inventory changed" in error for error in errors):
            failures += 1
            print("self-test did not reject an added re-export", file=sys.stderr)

        umbrella.write_text("@_exported import PackageA\n", encoding="utf-8")
        leaf.write_text("import Foundation\n", encoding="utf-8")
        errors, _ = validate(root, baseline_path)
        checks += 1
        if not any("lost explicit imports" in error for error in errors):
            failures += 1
            print("self-test did not reject a migrated-file regression", file=sys.stderr)

    if failures:
        print(f"module import gate self-test: FAIL ({failures}/{checks})", file=sys.stderr)
        return 1
    print(f"module import gate self-test: PASS ({checks}/{checks})")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="repository root")
    parser.add_argument("--baseline", type=Path, help="baseline path (relative paths resolve under root)")
    parser.add_argument("--json", action="store_true", help="print current inventory as JSON")
    parser.add_argument("--self-test", action="store_true", help="run control and negative probes")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    root = args.root.resolve()
    baseline_path = args.baseline or DEFAULT_BASELINE
    if not baseline_path.is_absolute():
        baseline_path = root / baseline_path
    errors, current = validate(root, baseline_path)
    if args.json:
        print(json.dumps(current, indent=2, sort_keys=True))
    else:
        print_inventory(current)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("module import boundary: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
