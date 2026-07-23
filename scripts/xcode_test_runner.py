#!/usr/bin/env python3
"""Run xcodebuild tests while keeping verbose output out of agent context."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any, Iterable


ERROR_PATTERN = re.compile(
    r"(error:|fatal error:|expectation failed|recorded an issue|issue recorded|"
    r"test case .* failed|failed on |\*\* (?:test|build) .*failed \*\*)",
    re.IGNORECASE,
)


def walk_nodes(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk_nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_nodes(child)


def required_suites_missing(tests: dict[str, Any], required: Iterable[str]) -> list[str]:
    identifiers = {
        str(node.get("nodeIdentifier", "")).split("/", 1)[0]
        for node in walk_nodes(tests)
        if node.get("nodeType") == "Test Case"
    }
    return sorted(set(required) - identifiers)


def slowest_tests(tests: dict[str, Any], limit: int) -> list[tuple[float, str]]:
    candidates: list[tuple[float, str]] = []
    for node in walk_nodes(tests):
        if node.get("nodeType") != "Test Case":
            continue
        duration = node.get("durationInSeconds")
        identifier = node.get("nodeIdentifier") or node.get("name")
        if isinstance(duration, (int, float)) and isinstance(identifier, str):
            candidates.append((float(duration), identifier))
    return sorted(candidates, reverse=True)[:limit]


def validate_summary(
    summary: dict[str, Any], minimum_test_count: int
) -> list[str]:
    errors: list[str] = []
    total = summary.get("totalTestCount")
    failed = summary.get("failedTests")
    result = summary.get("result")
    if not isinstance(total, int):
        errors.append("xcresult summary has no integer totalTestCount")
    elif total < minimum_test_count:
        errors.append(f"test count {total} is below required minimum {minimum_test_count}")
    if result != "Passed":
        errors.append(f"xcresult status is {result!r}, expected 'Passed'")
    if not isinstance(failed, int) or failed != 0:
        errors.append(f"xcresult reports {failed!r} failed tests")
    return errors


def xcresult_json(result_bundle: Path, report: str) -> dict[str, Any]:
    command = [
        "xcrun",
        "xcresulttool",
        "get",
        "test-results",
        report,
        "--path",
        str(result_bundle),
    ]
    if report == "summary":
        command.extend(["--format", "json"])
    else:
        command.append("--compact")
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    value = json.loads(completed.stdout)
    if not isinstance(value, dict):
        raise ValueError(f"xcresult {report} is not a JSON object")
    return value


def failure_excerpt(log_path: Path, maximum_lines: int = 80) -> list[str]:
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as error:
        return [f"Unable to read raw log: {error}"]
    anchors = [index for index, line in enumerate(lines) if ERROR_PATTERN.search(line)]
    if anchors:
        selected: set[int] = set()
        for anchor in anchors:
            selected.update(range(max(0, anchor - 2), min(len(lines), anchor + 5)))
        rendered: list[str] = []
        previous: int | None = None
        for index in sorted(selected):
            if previous is not None and index > previous + 1:
                rendered.append("…")
            rendered.append(lines[index])
            previous = index
        return rendered[-maximum_lines:]
    return lines[-maximum_lines:]


def print_test_failures(summary: dict[str, Any]) -> None:
    for failure in summary.get("testFailures", []):
        if not isinstance(failure, dict):
            continue
        identifier = failure.get("testIdentifierString") or failure.get("testName")
        target = failure.get("targetName")
        heading = f"FAIL: {identifier}"
        if target:
            heading += f" [{target}]"
        print(heading)
        failure_text = str(failure.get("failureText", "")).strip()
        for line in failure_text.splitlines() or ["No assertion text in xcresult."]:
            print(f"  {line}")


def print_summary(
    label: str,
    summary: dict[str, Any],
    command_returncode: int,
    elapsed: float,
    result_bundle: Path,
    log_path: Path,
) -> None:
    total = summary.get("totalTestCount", "?")
    passed = summary.get("passedTests", "?")
    failed = summary.get("failedTests", "?")
    skipped = summary.get("skippedTests", "?")
    test_duration = "?"
    start = summary.get("startTime")
    finish = summary.get("finishTime")
    if isinstance(start, (int, float)) and isinstance(finish, (int, float)):
        test_duration = f"{finish - start:.1f}s"
    reported_result = summary.get("result", "Unknown")
    displayed_result = (
        str(reported_result)
        if command_returncode == 0
        else f"Command failed (xcresult: {reported_result})"
    )
    print(
        f"{label}: {displayed_result} — {total} total, "
        f"{passed} passed, {failed} failed, {skipped} skipped; "
        f"test {test_duration}, command {elapsed:.1f}s",
        flush=True,
    )
    print(f"Result bundle: {result_bundle}", flush=True)
    print(f"Raw log: {log_path}", flush=True)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run xcodebuild tests and emit a concise xcresult summary."
    )
    parser.add_argument("--label", required=True)
    parser.add_argument("--result-bundle", type=Path, required=True)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--minimum-test-count", type=int, default=1)
    parser.add_argument("--require-suite", action="append", default=[])
    parser.add_argument("--slowest", type=int, default=0)
    parser.add_argument("xcodebuild_args", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.xcodebuild_args[:1] == ["--"]:
        arguments.xcodebuild_args = arguments.xcodebuild_args[1:]
    if not arguments.xcodebuild_args:
        parser.error("xcodebuild arguments are required after --")
    if arguments.minimum_test_count < 1:
        parser.error("--minimum-test-count must be positive")
    if arguments.slowest < 0:
        parser.error("--slowest cannot be negative")
    return arguments


def main() -> int:
    arguments = parse_arguments()
    result_bundle = arguments.result_bundle.resolve()
    if result_bundle.suffix != ".xcresult":
        print("ERROR: --result-bundle must end in .xcresult", file=sys.stderr)
        return 64
    if result_bundle.exists():
        print(f"ERROR: result bundle already exists: {result_bundle}", file=sys.stderr)
        return 64
    result_bundle.parent.mkdir(parents=True, exist_ok=True)
    log_path = (arguments.log or result_bundle.with_suffix(".log")).resolve()
    log_path.parent.mkdir(parents=True, exist_ok=True)

    command = [
        "xcodebuild",
        "-resultBundlePath",
        str(result_bundle),
        *arguments.xcodebuild_args,
    ]
    print(f"Running {arguments.label}; verbose output → {log_path}", flush=True)
    started = time.monotonic()
    with log_path.open("w", encoding="utf-8") as log:
        completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    elapsed = time.monotonic() - started

    summary: dict[str, Any] | None = None
    tests: dict[str, Any] | None = None
    validation_errors: list[str] = []
    try:
        summary = xcresult_json(result_bundle, "summary")
        validation_errors.extend(
            validate_summary(summary, arguments.minimum_test_count)
        )
        if arguments.require_suite or arguments.slowest:
            tests = xcresult_json(result_bundle, "tests")
        if tests is not None and arguments.require_suite:
            missing = required_suites_missing(tests, arguments.require_suite)
            if missing:
                validation_errors.append(
                    f"required suites absent from xcresult: {', '.join(missing)}"
                )
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, ValueError) as error:
        validation_errors.append(f"could not read xcresult: {error}")

    if summary is not None:
        print_summary(
            arguments.label,
            summary,
            completed.returncode,
            elapsed,
            result_bundle,
            log_path,
        )
        print_test_failures(summary)
        if tests is not None and arguments.slowest:
            print(f"Slowest {arguments.slowest} tests:")
            for duration, identifier in slowest_tests(tests, arguments.slowest):
                print(f"  {duration:7.3f}s  {identifier}")

    if completed.returncode != 0:
        validation_errors.insert(0, f"xcodebuild exited with status {completed.returncode}")
    if validation_errors:
        for error in validation_errors:
            print(f"ERROR: {error}", file=sys.stderr)
        should_show_excerpt = (
            completed.returncode != 0
            or summary is None
            or summary.get("failedTests", 0) != 0
        )
        if should_show_excerpt:
            print(f"Diagnostic excerpt from {log_path}:", file=sys.stderr)
            for line in failure_excerpt(log_path):
                print(line, file=sys.stderr)
        return completed.returncode or 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
