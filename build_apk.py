#!/usr/bin/env python3
"""Build the Android APK(s) for Venera.

Examples:
    python3 build_apk.py
    python3 build_apk.py --debug
    python3 build_apk.py --no-pub-get
    python3 build_apk.py --output dist
"""

import argparse
import os
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


def read_key_properties():
    properties = {}
    for line in KEY_PROPERTIES.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        properties[key.strip()] = value.strip()
    return properties


def find_keytool():
    keytool = shutil.which("keytool")
    if keytool:
        return keytool

    java_home = os.environ.get("JAVA_HOME")
    if java_home:
        name = "keytool.exe" if os.name == "nt" else "keytool"
        candidate = Path(java_home) / "bin" / name
        if candidate.is_file():
            return str(candidate)

    raise SystemExit("keytool was not found; install a JDK or set JAVA_HOME")


def validate_signing():
    """Fail early if Gradle would not be able to sign the release APK."""
    if not KEY_PROPERTIES.is_file():
        raise SystemExit(
            f"Missing signing config: {KEY_PROPERTIES}\n"
            "Create it with storeFile/storePassword/keyAlias/keyPassword."
        )

    properties = read_key_properties()
    missing = [
        name
        for name in ("storeFile", "storePassword", "keyAlias", "keyPassword")
        if not properties.get(name)
    ]
    if missing:
        raise SystemExit(f"Missing {', '.join(missing)} in {KEY_PROPERTIES}")

    store_password = properties["storePassword"]
    key_password = properties["keyPassword"]
    key_alias = properties["keyAlias"]

    # Gradle resolves storeFile relative to android/app.
    store_path = Path(properties["storeFile"])
    if not store_path.is_absolute():
        store_path = ROOT / "android" / "app" / store_path
    if not store_path.is_file() or store_path.stat().st_size == 0:
        raise SystemExit(f"Keystore not found or empty: {store_path}")

    keytool = find_keytool()
    listing = subprocess.run(
        [keytool, "-list", "-keystore", str(store_path), "-storepass", store_password],
        capture_output=True,
        text=True,
    )
    output = f"{listing.stdout}\n{listing.stderr}"
    if listing.returncode != 0:
        raise SystemExit(
            f"Cannot open keystore {store_path} with the configured "
            f"storePassword:\n{output.strip()}"
        )

    # PKCS12 keystores cannot store a key password different from the store
    # password, and keytool silently ignores -keypass for them. Without this
    # check a wrong keyPassword only fails later in :app:packageRelease with
    # "Get Key failed: Given final block not properly padded".
    if "PKCS12" in output and key_password != store_password:
        raise SystemExit(
            "PKCS12 keystore does not support keyPassword != storePassword.\n"
            f"Set keyPassword equal to storePassword in {KEY_PROPERTIES}, "
            "or convert the keystore to JKS."
        )

    alias_check = subprocess.run(
        [
            keytool,
            "-list",
            "-keystore",
            str(store_path),
            "-storepass",
            store_password,
            "-alias",
            key_alias,
        ],
        capture_output=True,
        text=True,
    )
    if alias_check.returncode != 0:
        detail = f"{alias_check.stdout}\n{alias_check.stderr}".strip()
        raise SystemExit(f"Alias {key_alias} not found in {store_path}:\n{detail}")

    if "debug" in store_path.name.lower():
        print(
            "warning: release APK will be signed with the debug keystore "
            f"({store_path}); configure a release keystore before publishing.",
            file=sys.stderr,
        )

    print(f"Signing configuration validated: {store_path.name} (alias {key_alias})")


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
        validate_signing()

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
