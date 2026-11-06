#!/usr/bin/env python3
"""Validate the app version and build number before building or releasing.

The build number is derived from the semantic version:

    major * 10000 + minor * 100 + patch

Examples:
    python3 check_version.py
    python3 check_version.py --tag v1.7.9
    python3 check_version.py --skip-tags
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PUBSPEC = ROOT / "pubspec.yaml"
APP_DART = ROOT / "lib" / "foundation" / "app.dart"

VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
PUBSPEC_RE = re.compile(
    r"(?m)^version:[ \t]*(\d+\.\d+\.\d+)(?:\+(\d+))?[ \t]*$"
)
APP_VERSION_RE = re.compile(r'final version = "([^"]*)"')
APP_BUILD_RE = re.compile(r'final buildNumber = "([^"]*)"')


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    return 1


def parse_semver(value):
    match = VERSION_RE.fullmatch(value)
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


def derive_build(semver):
    major, minor, patch = semver
    if minor >= 100 or patch >= 100:
        raise ValueError("minor and patch must be less than 100")
    return major * 10000 + minor * 100 + patch


def read_pubspec():
    content = PUBSPEC.read_text(encoding="utf-8")
    match = PUBSPEC_RE.search(content)
    if not match:
        raise ValueError("could not parse 'version: X.Y.Z+N' from pubspec.yaml")
    version, build = match.group(1), match.group(2)
    if build is None:
        raise ValueError(
            "pubspec.yaml version must include a build number, "
            "for example 'version: 1.7.9+10709'"
        )
    return version, int(build)


def read_app_dart():
    content = APP_DART.read_text(encoding="utf-8")
    version_match = APP_VERSION_RE.search(content)
    build_match = APP_BUILD_RE.search(content)
    if not version_match:
        raise ValueError("could not find 'final version = \"...\"' in app.dart")
    if not build_match:
        raise ValueError(
            "could not find 'final buildNumber = \"...\"' in app.dart"
        )
    try:
        build = int(build_match.group(1))
    except ValueError as exc:
        raise ValueError("app.dart buildNumber must be an integer") from exc
    return version_match.group(1), build


def is_shallow_repository():
    result = subprocess.run(
        ["git", "rev-parse", "--is-shallow-repository"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0 and result.stdout.strip() == "true"


def list_version_tags(exclude):
    result = subprocess.run(
        ["git", "tag", "--list"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ValueError(f"could not list git tags:\n{result.stderr.strip()}")

    tags = []
    for tag in result.stdout.splitlines():
        tag = tag.strip()
        if not tag or tag == exclude:
            continue
        candidate = tag[1:] if tag.startswith("v") else tag
        semver = parse_semver(candidate)
        if semver is None:
            continue
        try:
            derive_build(semver)
        except ValueError:
            # Ignore tags whose version cannot be mapped to a build number.
            continue
        tags.append((tag, semver))
    return tags


def main():
    parser = argparse.ArgumentParser(
        description="Validate veneraGo version and build number."
    )
    parser.add_argument(
        "--tag",
        help="release tag to validate, e.g. v1.7.9",
    )
    parser.add_argument(
        "--skip-tags",
        action="store_true",
        help="only check pubspec/app.dart consistency (for manual builds)",
    )
    args = parser.parse_args()

    try:
        version, build = read_pubspec()
        app_version, app_build = read_app_dart()
    except ValueError as exc:
        return fail(str(exc))

    semver = parse_semver(version)
    if semver is None:
        return fail(f"invalid version in pubspec.yaml: {version}")

    try:
        derived_build = derive_build(semver)
    except ValueError as exc:
        return fail(f"invalid version in pubspec.yaml: {exc}")

    if app_version != version:
        return fail(
            f"app.dart version ({app_version}) does not match "
            f"pubspec.yaml ({version})"
        )
    if app_build != build:
        return fail(
            f"app.dart buildNumber ({app_build}) does not match "
            f"pubspec.yaml (+{build})"
        )
    if build < derived_build:
        return fail(
            f"build number {build} is lower than the minimum {derived_build} "
            f"derived from version {version}"
        )
    if build > (2_100_000_000 - 9) // 10:
        return fail(f"build number {build} exceeds the Google Play limit")

    if args.tag:
        tag_version = args.tag[1:] if args.tag.startswith("v") else args.tag
        if tag_version != version:
            return fail(
                f"tag {args.tag} does not match pubspec.yaml version {version}"
            )

    if args.skip_tags:
        print(f"version check passed: {version}+{build}")
        return 0

    if is_shallow_repository():
        return fail(
            "repository is a shallow clone; fetch full history and tags "
            "(actions/checkout fetch-depth: 0)"
        )

    try:
        tags = list_version_tags(args.tag)
    except ValueError as exc:
        return fail(str(exc))

    if not tags:
        print(f"version check passed: {version}+{build} (no previous tags)")
        return 0

    max_tag, max_semver = max(tags, key=lambda item: derive_build(item[1]))
    max_build = derive_build(max_semver)
    if build <= max_build:
        return fail(
            f"build number {build} must be greater than build {max_build} "
            f"from tag {max_tag}"
        )

    max_version = ".".join(str(part) for part in max_semver)
    if semver <= max_semver:
        print(
            f"warning: version {version} is not greater than {max_version} "
            f"from tag {max_tag}; the in-app updater will not offer it",
            file=sys.stderr,
        )

    print(
        f"version check passed: {version}+{build} "
        f"(previous build {max_build} from {max_tag})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
