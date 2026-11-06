#!/usr/bin/env python3
"""Build the Android APK(s) for Venera.

Examples:
    python3 build_apk.py
    python3 build_apk.py --debug
    python3 build_apk.py --no-pub-get
    python3 build_apk.py --output dist
"""

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PUBSPEC = ROOT / "pubspec.yaml"
KEY_PROPERTIES = ROOT / "android" / "key.properties"

PUBSPEC_VERSION_RE = re.compile(
    r"^version:[ \t]*(\d+\.\d+\.\d+)(?:\+(\d+))?", re.MULTILINE
)


def read_version():
    content = PUBSPEC.read_text(encoding="utf-8")
    match = PUBSPEC_VERSION_RE.search(content)
    if not match:
        raise SystemExit(f"Could not read 'version:' from {PUBSPEC}")

    version, build = match.groups()
    return version, int(build) if build else None


def warn_if_debug_signed():
    """Warn when a release build would use the debug signing key."""
    if not KEY_PROPERTIES.is_file():
        raise SystemExit(
            f"Missing signing config: {KEY_PROPERTIES}\n"
            "Create it with storeFile/storePassword/keyAlias/keyPassword."
        )

    properties = {}
    for line in KEY_PROPERTIES.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        properties[key.strip()] = value.strip()

    store_file = properties.get("storeFile")
    if not store_file:
        return

    # Gradle resolves storeFile relative to android/app.
    store_path = Path(store_file)
    if not store_path.is_absolute():
        store_path = ROOT / "android" / "app" / store_path

    if "debug" in store_path.name.lower():
        print(
            "warning: release APK will be signed with the debug keystore "
            f"({store_path}); configure a release keystore before publishing.",
            file=sys.stderr,
        )


def run(command):
    printable = " ".join(str(part) for part in command)
    print(f"+ {printable}", flush=True)
    subprocess.run(command, cwd=ROOT, check=True)


def human_size(size):
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.1f} {unit}"
        size /= 1024


def collect_apks(build_type):
    output_dir = ROOT / "build" / "app" / "outputs" / "apk" / build_type
    if not output_dir.is_dir():
        raise SystemExit(f"Build output directory not found: {output_dir}")

    apks = sorted(
        (path for path in output_dir.glob("*.apk") if path.stat().st_size > 0),
        key=lambda path: path.name,
    )
    if not apks:
        raise SystemExit(f"No non-empty APK found in {output_dir}")
    return apks


def copy_apks(apks, destination):
    destination = (ROOT / destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    copied = []
    for apk in apks:
        target = destination / apk.name
        if target != apk.resolve():
            shutil.copy2(apk, target)
        copied.append(target)
    return copied


def main():
    parser = argparse.ArgumentParser(description="Build the Venera Android APK(s).")
    parser.add_argument(
        "--debug",
        action="store_true",
        help="build a debug APK instead of a release APK",
    )
    parser.add_argument(
        "--no-pub-get",
        action="store_true",
        help="skip 'flutter pub get' before building",
    )
    parser.add_argument(
        "--output",
        metavar="DIR",
        help="copy the built APK(s) into DIR",
    )
    args = parser.parse_args()

    if shutil.which("flutter") is None:
        raise SystemExit("flutter was not found in PATH")

    version, build = read_version()
    build_type = "debug" if args.debug else "release"
    print(f"Venera {version}" + (f"+{build}" if build else ""))

    if build_type == "release":
        warn_if_debug_signed()

    if not args.no_pub_get:
        run(["flutter", "pub", "get"])

    command = ["flutter", "build", "apk", f"--{build_type}"]
    run(command)

    apks = collect_apks(build_type)
    if args.output:
        apks = copy_apks(apks, args.output)

    print("\nBuilt APK(s):")
    for apk in apks:
        print(f"  {apk}  ({human_size(apk.stat().st_size)})")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
