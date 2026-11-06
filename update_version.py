#!/usr/bin/env python3
"""Update the app version in pubspec.yaml and lib/foundation/app.dart.

Examples:
    python3 update_version.py 1.7.5
    python3 update_version.py v1.7.5 --dry-run
    python3 update_version.py 1.7.5 --build 176
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PUBSPEC = ROOT / "pubspec.yaml"
APP_DART = ROOT / "lib" / "foundation" / "app.dart"

PUBSPEC_VERSION_RE = re.compile(r"^version:[ \t]*([^\r\n]+)", re.MULTILINE)
APP_VERSION_RE = re.compile(r'(final version = ")([^"]*)(";)')

VERSION_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$")


def parse_version(value):
    match = VERSION_RE.fullmatch(value.strip())
    if not match:
        raise ValueError(
            "invalid version: expected 1.7.5, v1.7.5, or 1.7.5+175"
        )

    major, minor, patch, build = match.groups()
    version = f"{int(major)}.{int(minor)}.{int(patch)}"
    # Keep the repository convention: 1.7.5 -> 175.
    build = int(build) if build is not None else int(f"{major}{minor}{patch}")
    if build < 1:
        raise ValueError("build number must be greater than 0")
    return version, build


def replace_once(pattern, replacement, content, path):
    updated, count = pattern.subn(replacement, content, count=1)
    if count != 1:
        raise SystemExit(f"Could not find the version field in {path}")
    return updated


def main():
    parser = argparse.ArgumentParser(
        description="Update the veneraGo app version."
    )
    parser.add_argument(
        "version",
        help="new version, e.g. 1.7.5, v1.7.5, or 1.7.5+175",
    )
    parser.add_argument(
        "--build",
        type=int,
        help="explicit build number (default: digits of the version, 1.7.5 -> 175)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show the changes without writing files",
    )
    args = parser.parse_args()

    try:
        version, derived_build = parse_version(args.version)
    except ValueError as exc:
        parser.error(str(exc))

    build = args.build if args.build is not None else derived_build
    if build < 1:
        parser.error("--build must be greater than 0")

    if not PUBSPEC.is_file():
        raise SystemExit(f"File not found: {PUBSPEC}")
    if not APP_DART.is_file():
        raise SystemExit(f"File not found: {APP_DART}")

    pubspec_content = PUBSPEC.read_text(encoding="utf-8")
    app_content = APP_DART.read_text(encoding="utf-8")

    pubspec_match = PUBSPEC_VERSION_RE.search(pubspec_content)
    if not pubspec_match:
        raise SystemExit(f"Could not find 'version:' in {PUBSPEC}")
    old_pubspec_version = pubspec_match.group(1).strip()

    app_match = APP_VERSION_RE.search(app_content)
    if not app_match:
        raise SystemExit(f"Could not find the version constant in {APP_DART}")
    old_app_version = app_match.group(2)

    new_pubspec_version = f"{version}+{build}"

    pubspec_updated = replace_once(
        PUBSPEC_VERSION_RE,
        f"version: {new_pubspec_version}",
        pubspec_content,
        PUBSPEC,
    )
    app_updated = replace_once(
        APP_VERSION_RE,
        rf'\g<1>{version}\g<3>',
        app_content,
        APP_DART,
    )

    print(f"pubspec.yaml:       {old_pubspec_version} -> {new_pubspec_version}")
    print(f"lib/foundation/app.dart: {old_app_version} -> {version}")

    current_build = old_pubspec_version.rsplit("+", 1)[-1]
    if current_build.isdigit() and build <= int(current_build):
        print(
            f"warning: build number {build} is not greater than "
            f"the current build number {current_build}",
            file=sys.stderr,
        )

    if args.dry_run:
        print("dry-run: no files changed")
        return 0

    # newline="" keeps the file's existing LF/CRLF line endings.
    with PUBSPEC.open("w", encoding="utf-8", newline="") as file:
        file.write(pubspec_updated)
    with APP_DART.open("w", encoding="utf-8", newline="") as file:
        file.write(app_updated)

    print("version updated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
