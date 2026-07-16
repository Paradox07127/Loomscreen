#!/usr/bin/env python3
"""Canonical, structural entitlement fingerprints and signing metadata policy.

The shell release gate deliberately delegates plist parsing to Foundation's
binary/XML-compatible plist format through Python's plistlib.  Entitlement
strings may contain tabs or newlines (SBPL commonly does), so a line-oriented
XML parser is not safe here.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import math
import plistlib
import sys
from pathlib import Path
from typing import Any, Optional


APPLICATION_IDENTIFIER = "com.apple.application-identifier"
TEAM_IDENTIFIER = "com.apple.developer.team-identifier"
KEYCHAIN_ACCESS_GROUPS = "keychain-access-groups"
GET_TASK_ALLOW = "com.apple.security.get-task-allow"


class EntitlementError(ValueError):
    pass


def escaped(value: str) -> str:
    """Keep one record per physical line without creating value collisions."""

    return (
        value.replace("\\", "\\\\")
        .replace("\t", "\\t")
        .replace("\r", "\\r")
        .replace("\n", "\\n")
    )


def load_entitlements(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as stream:
            value = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise EntitlementError(f"could not read entitlement plist {path}: {error}") from error

    if not isinstance(value, dict):
        raise EntitlementError(f"entitlement plist root must be a dictionary: {path}")
    if not all(isinstance(key, str) for key in value):
        raise EntitlementError(f"entitlement plist contains a non-string key: {path}")
    return value


def scalar_record(key: str, value: Any, *, array: bool) -> str:
    prefix = "array-" if array else ""
    safe_key = escaped(key)

    if isinstance(value, bool):
        return f"{prefix}bool\t{safe_key}\t{'true' if value else 'false'}"
    if isinstance(value, str):
        return f"{prefix}string\t{safe_key}\t{escaped(value)}"
    if isinstance(value, int):
        return f"{prefix}integer\t{safe_key}\t{value}"
    if isinstance(value, float):
        if not math.isfinite(value):
            raise EntitlementError(f"non-finite real is unsupported for entitlement {key}")
        return f"{prefix}real\t{safe_key}\t{repr(value)}"
    if isinstance(value, bytes):
        encoded = base64.b64encode(value).decode("ascii")
        return f"{prefix}data\t{safe_key}\t{encoded}"
    if isinstance(value, dt.datetime):
        return f"{prefix}date\t{safe_key}\t{value.isoformat()}"

    raise EntitlementError(
        f"unsupported {'array member' if array else 'value'} type "
        f"{type(value).__name__} for entitlement {key}"
    )


def fingerprint(values: dict[str, Any]) -> list[str]:
    records: list[str] = []
    for key, value in values.items():
        if isinstance(value, dict):
            # Entitlement dictionaries are not part of this product contract.
            # Failing is safer than flattening a future privilege incorrectly.
            raise EntitlementError(f"dictionary value is unsupported for entitlement {key}")
        if isinstance(value, list):
            if not value:
                records.append(f"array-empty\t{escaped(key)}\t-")
                continue
            records.extend(scalar_record(key, member, array=True) for member in value)
            continue
        records.append(scalar_record(key, value, array=False))
    return sorted(records)


def normalized_app_entitlements(
    values: dict[str, Any],
    *,
    bundle_id: str,
    team_id: Optional[str],
    expected_team_id: str,
) -> dict[str, Any]:
    """Validate and remove only known Xcode signing-derived metadata.

    Every signing-derived field is optional because ad-hoc, Developer ID and
    provisioned Xcode archives do not necessarily synthesize the same subset.
    Presence never means "ignore": each value has to be exactly derivable from
    the code signature's TeamIdentifier and the app's CFBundleIdentifier.
    """

    if team_id and team_id != expected_team_id:
        raise EntitlementError(
            f"signed TeamIdentifier must be {expected_team_id!r}, got {team_id!r}"
        )

    normalized = dict(values)
    expected_application_id = f"{team_id}.{bundle_id}" if team_id else None

    if APPLICATION_IDENTIFIER in normalized:
        actual = normalized.pop(APPLICATION_IDENTIFIER)
        if not team_id:
            raise EntitlementError(
                f"ad-hoc signature must not claim {APPLICATION_IDENTIFIER}"
            )
        if actual != expected_application_id:
            raise EntitlementError(
                f"{APPLICATION_IDENTIFIER} must be {expected_application_id!r}, got {actual!r}"
            )

    if TEAM_IDENTIFIER in normalized:
        actual = normalized.pop(TEAM_IDENTIFIER)
        if not team_id:
            raise EntitlementError(f"ad-hoc signature must not claim {TEAM_IDENTIFIER}")
        if actual != team_id:
            raise EntitlementError(
                f"{TEAM_IDENTIFIER} must match signed TeamIdentifier {team_id!r}, got {actual!r}"
            )

    if KEYCHAIN_ACCESS_GROUPS in normalized:
        actual = normalized.pop(KEYCHAIN_ACCESS_GROUPS)
        expected = [expected_application_id] if expected_application_id else None
        if not team_id:
            raise EntitlementError(
                f"ad-hoc signature must not claim {KEYCHAIN_ACCESS_GROUPS}"
            )
        if actual != expected:
            raise EntitlementError(
                f"{KEYCHAIN_ACCESS_GROUPS} must be the exact default group {expected!r}, got {actual!r}"
            )

    if GET_TASK_ALLOW in normalized:
        actual = normalized.pop(GET_TASK_ALLOW)
        if actual is not False:
            raise EntitlementError(
                f"shipping app requires {GET_TASK_ALLOW}=false when present, got {actual!r}"
            )

    return normalized


def print_fingerprint(values: dict[str, Any]) -> None:
    for record in fingerprint(values):
        print(record)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    source = subparsers.add_parser("fingerprint")
    source.add_argument("plist", type=Path)

    app = subparsers.add_parser("app-fingerprint")
    app.add_argument("plist", type=Path)
    app.add_argument("--bundle-id", required=True)
    app.add_argument("--team-id")
    app.add_argument("--expected-team-id", required=True)

    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        values = load_entitlements(arguments.plist)
        if arguments.command == "app-fingerprint":
            values = normalized_app_entitlements(
                values,
                bundle_id=arguments.bundle_id,
                team_id=arguments.team_id,
                expected_team_id=arguments.expected_team_id,
            )
        print_fingerprint(values)
    except EntitlementError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
