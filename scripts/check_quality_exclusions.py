#!/usr/bin/env python3
"""Offline AF-10 gate for lint/format hotspot exclusions.

The gate intentionally does not invoke SwiftLint or SwiftFormat. It validates
their excluded Swift-source inventory, time-bounds every exception, ratchets
physical lines by component, and rejects newly added high-risk lines.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Iterable, NamedTuple


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "scripts/quality-baselines/exclusions.json"
DEFAULT_BASELINE = ROOT / "scripts/quality-baselines/component-loc.json"

RISK_PATTERNS = (
    ("try!", re.compile(r"\btry\s*!")),
    ("as!", re.compile(r"\bas\s*!")),
    ("fatalError", re.compile(r"\bfatalError\s*\(")),
    ("main.sync", re.compile(r"\bmain\s*\.\s*sync\b")),
    ("waitUntilCompleted", re.compile(r"\bwaitUntilCompleted\s*\(")),
)
HUNK_HEADER = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


class Component(NamedTuple):
    component_id: str
    owner: str
    reason: str
    expires_on: dt.date
    paths: tuple[str, ...]


class ChangedLineViolation(NamedTuple):
    path: str
    line: int
    rule: str
    source: str


def load_json(path: Path, errors: list[str]) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        errors.append(f"missing required file: {path.relative_to(ROOT)}")
        return {}
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"cannot read {path.relative_to(ROOT)}: {error}")
        return {}
    if not isinstance(value, dict):
        errors.append(f"{path.relative_to(ROOT)} must contain a JSON object")
        return {}
    return value


def parse_manifest(path: Path, today: dt.date, errors: list[str]) -> list[Component]:
    document = load_json(path, errors)
    if document.get("schema_version") != 1:
        errors.append("exclusions manifest schema_version must be 1")
    raw_components = document.get("components")
    if not isinstance(raw_components, list) or not raw_components:
        errors.append("exclusions manifest must define a non-empty components array")
        return []

    components: list[Component] = []
    seen_ids: set[str] = set()
    seen_paths: set[str] = set()
    for offset, raw in enumerate(raw_components):
        label = f"components[{offset}]"
        if not isinstance(raw, dict):
            errors.append(f"{label} must be an object")
            continue
        component_id = raw.get("id")
        owner = raw.get("owner")
        reason = raw.get("reason")
        expiry_text = raw.get("expires_on")
        raw_paths = raw.get("paths")
        if not isinstance(component_id, str) or not re.fullmatch(r"[a-z0-9-]+", component_id):
            errors.append(f"{label}.id must be a lowercase slug")
            continue
        if component_id in seen_ids:
            errors.append(f"duplicate component id: {component_id}")
            continue
        seen_ids.add(component_id)
        if not isinstance(owner, str) or not owner.strip():
            errors.append(f"{component_id}: owner is required")
        if not isinstance(reason, str) or len(reason.strip()) < 24:
            errors.append(f"{component_id}: reason must explain the exception")
        try:
            expiry = dt.date.fromisoformat(expiry_text) if isinstance(expiry_text, str) else None
        except ValueError:
            expiry = None
        if expiry is None:
            errors.append(f"{component_id}: expires_on must be an ISO date")
            expiry = dt.date.min
        elif expiry < today:
            errors.append(f"{component_id}: exclusion expired on {expiry.isoformat()} (today {today.isoformat()})")
        if not isinstance(raw_paths, list) or not raw_paths:
            errors.append(f"{component_id}: paths must be a non-empty array")
            raw_paths = []

        paths: list[str] = []
        for raw_path in raw_paths:
            if not isinstance(raw_path, str):
                errors.append(f"{component_id}: every path must be a string")
                continue
            candidate = Path(raw_path)
            if candidate.is_absolute() or ".." in candidate.parts or not raw_path.endswith(".swift"):
                errors.append(f"{component_id}: invalid hotspot path {raw_path!r}")
                continue
            if raw_path in seen_paths:
                errors.append(f"hotspot path belongs to multiple components: {raw_path}")
                continue
            seen_paths.add(raw_path)
            if not (ROOT / raw_path).is_file():
                errors.append(f"{component_id}: hotspot path does not exist: {raw_path}")
            paths.append(raw_path)
        components.append(Component(component_id, str(owner or ""), str(reason or ""), expiry, tuple(paths)))
    return components


def parse_baseline(path: Path, component_ids: set[str], errors: list[str]) -> dict[str, int]:
    document = load_json(path, errors)
    if document.get("schema_version") != 1:
        errors.append("component LoC baseline schema_version must be 1")
    if document.get("metric") != "physical_lines":
        errors.append("component LoC baseline metric must be physical_lines")
    raw_caps = document.get("component_max_loc")
    if not isinstance(raw_caps, dict):
        errors.append("component LoC baseline must define component_max_loc")
        return {}
    caps: dict[str, int] = {}
    for component_id, raw_cap in raw_caps.items():
        if not isinstance(component_id, str) or not isinstance(raw_cap, int) or isinstance(raw_cap, bool) or raw_cap < 1:
            errors.append(f"invalid component LoC cap: {component_id!r}={raw_cap!r}")
            continue
        caps[component_id] = raw_cap
    missing = sorted(component_ids - set(caps))
    stale = sorted(set(caps) - component_ids)
    if missing:
        errors.append(f"components missing LoC baselines: {', '.join(missing)}")
    if stale:
        errors.append(f"LoC baselines without manifest components: {', '.join(stale)}")
    return caps


def swiftlint_exclusions(path: Path, errors: list[str]) -> set[str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        errors.append(f"cannot read .swiftlint.yml: {error}")
        return set()
    try:
        start = lines.index("excluded:") + 1
    except ValueError:
        errors.append(".swiftlint.yml is missing the excluded block")
        return set()
    values: set[str] = set()
    for line in lines[start:]:
        if line and not line[0].isspace():
            break
        match = re.match(r"^\s+-\s+(.+?)\s*$", line)
        if match:
            values.add(match.group(1).strip("\"'"))
    return {value for value in values if value.endswith(".swift")}


def swiftformat_exclusions(path: Path, errors: list[str]) -> set[str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        errors.append(f"cannot read .swiftformat: {error}")
        return set()
    values: set[str] = set()
    for line in lines:
        stripped = line.strip()
        if not stripped.startswith("--exclude "):
            continue
        values.update(value.strip() for value in stripped.removeprefix("--exclude ").split(","))
    if not values:
        errors.append(".swiftformat is missing --exclude")
    return {value for value in values if value.endswith(".swift")}


def compare_inventory(label: str, actual: set[str], expected: set[str], errors: list[str]) -> None:
    added = sorted(actual - expected)
    missing = sorted(expected - actual)
    if added:
        errors.append(f"{label} has unowned hotspot exclusions: {', '.join(added)}")
    if missing:
        errors.append(f"{label} omits manifest hotspots: {', '.join(missing)}")


def physical_lines(path: Path) -> int:
    data = path.read_bytes()
    return len(data.splitlines())


def validate_component_loc(
    components: Iterable[Component], caps: dict[str, int], errors: list[str]
) -> dict[str, int]:
    actual: dict[str, int] = {}
    for component in components:
        count = sum(physical_lines(ROOT / path) for path in component.paths if (ROOT / path).is_file())
        actual[component.component_id] = count
        cap = caps.get(component.component_id)
        if cap is not None and count > cap:
            errors.append(
                f"{component.component_id}: component LoC grew from cap {cap} to {count}; "
                "split/move within the component or reduce debt instead"
            )
    return actual


def git_output(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *arguments],
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def normalized_base(raw_base: str | None, errors: list[str]) -> str | None:
    if not raw_base or not raw_base.strip() or set(raw_base.strip()) == {"0"}:
        return None
    base = raw_base.strip()
    result = git_output(["cat-file", "-e", f"{base}^{{commit}}"])
    if result.returncode != 0:
        errors.append(f"quality comparison base is unavailable: {base}: {result.stderr.strip()}")
        return None
    return base


def json_at_revision(base: str, relative_path: str, errors: list[str]) -> dict[str, Any] | None:
    result = git_output(["show", f"{base}:{relative_path}"])
    if result.returncode != 0:
        # The first AF-10 adoption has no historical baseline; later failures
        # must not silently disable comparison.
        if "exists on disk, but not in" in result.stderr or "does not exist" in result.stderr:
            return None
        errors.append(f"cannot read historical {relative_path}: {result.stderr.strip()}")
        return None
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        errors.append(f"historical {relative_path} is invalid JSON: {error}")
        return None
    return value if isinstance(value, dict) else None


def validate_historical_ratchet(
    base: str | None,
    caps: dict[str, int],
    components: list[Component],
    errors: list[str],
) -> None:
    if base is None:
        return
    baseline_path = str(DEFAULT_BASELINE.relative_to(ROOT))
    old_baseline = json_at_revision(base, baseline_path, errors)
    if old_baseline is not None:
        old_caps = old_baseline.get("component_max_loc")
        if isinstance(old_caps, dict):
            for component_id, cap in caps.items():
                old_cap = old_caps.get(component_id)
                if old_cap is None:
                    errors.append(f"new excluded component is forbidden by the no-growth ratchet: {component_id}")
                elif isinstance(old_cap, int) and cap > old_cap:
                    errors.append(f"{component_id}: LoC cap increased from {old_cap} to {cap}")
        else:
            errors.append("historical component LoC baseline is missing component_max_loc")

    manifest_path = str(DEFAULT_MANIFEST.relative_to(ROOT))
    old_manifest = json_at_revision(base, manifest_path, errors)
    if old_manifest is None:
        return
    old_by_id = {
        raw.get("id"): set(raw.get("paths", []))
        for raw in old_manifest.get("components", [])
        if isinstance(raw, dict) and isinstance(raw.get("id"), str) and isinstance(raw.get("paths"), list)
    }
    for component in components:
        old_paths = old_by_id.get(component.component_id, set())
        added = sorted(set(component.paths) - old_paths)
        removed = sorted(old_paths - set(component.paths))
        if added or removed:
            print(
                f"inventory change {component.component_id}: "
                f"+{len(added)} / -{len(removed)} paths (component LoC cap still ratcheted)"
            )


def parse_added_risky_lines(diff_text: str, excluded_paths: set[str]) -> list[ChangedLineViolation]:
    violations: list[ChangedLineViolation] = []
    current_path: str | None = None
    new_line: int | None = None
    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            value = line[4:]
            current_path = value[2:] if value.startswith("b/") else value
            if current_path == "/dev/null":
                current_path = None
            new_line = None
            continue
        hunk = HUNK_HEADER.match(line)
        if hunk:
            new_line = int(hunk.group(1))
            continue
        if current_path is None or new_line is None:
            continue
        if line.startswith("+") and not line.startswith("+++"):
            source = line[1:]
            if current_path in excluded_paths:
                for rule, pattern in RISK_PATTERNS:
                    if pattern.search(source):
                        violations.append(ChangedLineViolation(current_path, new_line, rule, source.strip()))
            new_line += 1
        elif line.startswith("-") and not line.startswith("---"):
            continue
        elif not line.startswith("\\"):
            new_line += 1
    return violations


def changed_line_violations(base: str | None, paths: set[str], errors: list[str]) -> list[ChangedLineViolation]:
    comparison = base or "HEAD"
    result = git_output(
        [
            "diff",
            "--unified=0",
            "--no-color",
            "--no-ext-diff",
            "--find-renames",
            comparison,
            "--",
            *sorted(paths),
        ]
    )
    if result.returncode != 0:
        errors.append(f"cannot inspect changed hotspot lines: {result.stderr.strip()}")
        return []
    violations = parse_added_risky_lines(result.stdout, paths)

    # `git diff` omits untracked files. Treat an untracked hotspot as wholly
    # added so a local pre-commit run cannot bypass the changed-line gate.
    for path in sorted(paths):
        tracked = git_output(["ls-files", "--error-unmatch", "--", path])
        if tracked.returncode == 0 or not (ROOT / path).is_file():
            continue
        for line_number, source in enumerate((ROOT / path).read_text(encoding="utf-8").splitlines(), start=1):
            for rule, pattern in RISK_PATTERNS:
                if pattern.search(source):
                    violations.append(ChangedLineViolation(path, line_number, rule, source.strip()))
    return violations


def run_negative_self_test() -> int:
    injected = """diff --git a/Hotspot.swift b/Hotspot.swift
--- a/Hotspot.swift
+++ b/Hotspot.swift
@@ -0,0 +1,6 @@
+let decoded = try! decode()
+let model = value as! Model
+fatalError("injected")
+DispatchQueue.main.sync { render() }
+commandBuffer.waitUntilCompleted()
+let safe = try? decode()
diff --git a/Regular.swift b/Regular.swift
--- a/Regular.swift
+++ b/Regular.swift
@@ -0,0 +1 @@
+fatalError("outside excluded inventory")
"""
    violations = parse_added_risky_lines(injected, {"Hotspot.swift"})
    caught = {violation.rule for violation in violations}
    expected = {rule for rule, _ in RISK_PATTERNS}
    simulated_gate_exit = 1 if violations else 0
    if caught != expected or len(violations) != len(expected) or simulated_gate_exit != 1:
        print(
            f"ERROR: negative self-test did not reject every injected rule; caught={sorted(caught)}",
            file=sys.stderr,
        )
        return 1
    print(f"Negative self-test passed: {len(violations)} injected high-risk lines made the gate red.")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--base", help="Git revision used for historical and changed-line comparison")
    parser.add_argument("--today", help="ISO date override for deterministic expiry checks")
    parser.add_argument("--self-test", action="store_true", help="prove injected high-risk lines fail the gate")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_negative_self_test()
    try:
        today = dt.date.fromisoformat(args.today) if args.today else dt.date.today()
    except ValueError:
        print("ERROR: --today must be an ISO date", file=sys.stderr)
        return 2

    errors: list[str] = []
    components = parse_manifest(args.manifest, today, errors)
    component_ids = {component.component_id for component in components}
    caps = parse_baseline(args.baseline, component_ids, errors)
    manifest_paths = {path for component in components for path in component.paths}
    compare_inventory(".swiftlint.yml", swiftlint_exclusions(ROOT / ".swiftlint.yml", errors), manifest_paths, errors)
    compare_inventory(".swiftformat", swiftformat_exclusions(ROOT / ".swiftformat", errors), manifest_paths, errors)
    actual_loc = validate_component_loc(components, caps, errors)

    requested_base = args.base if args.base is not None else os.environ.get("QUALITY_GATE_BASE")
    base = normalized_base(requested_base, errors)
    validate_historical_ratchet(base, caps, components, errors)
    risky_lines = changed_line_violations(base, manifest_paths, errors)
    for violation in risky_lines:
        errors.append(
            f"{violation.path}:{violation.line}: added {violation.rule} in excluded hotspot: {violation.source}"
        )

    for component in components:
        cap = caps.get(component.component_id, 0)
        actual = actual_loc.get(component.component_id, 0)
        print(
            f"{component.component_id}: {actual}/{cap} physical lines, "
            f"owner={component.owner}, expires={component.expires_on.isoformat()}"
        )
    print(f"hotspot inventory: {len(manifest_paths)} Swift files across {len(components)} components")

    if errors:
        print("Quality exclusion gate failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("Quality exclusion gate passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
