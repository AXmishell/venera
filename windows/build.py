import os
import re
import shutil
import subprocess

import httpx

ISL_URL = "https://cdn.jsdelivr.net/gh/kira-96/Inno-Setup-Chinese-Simplified-Translation@latest/ChineseSimplified.isl"


def read_version(path="pubspec.yaml"):
    with open(path, "r", encoding="utf-8") as file:
        content = file.read()
    match = re.search(r"^version:\s*([^+\s]+)", content, re.MULTILINE)
    if not match:
        raise SystemExit("Could not read version from pubspec.yaml")
    return match.group(1)


def require_non_empty_file(path):
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        raise SystemExit(f"Expected a non-empty file: {path}")


def main():
    version = read_version()

    subprocess.run("flutter build windows", shell=True, check=True)

    release_dir = os.path.join("build", "windows", "x64", "runner", "Release")
    if not os.path.isdir(release_dir) or not os.listdir(release_dir):
        raise SystemExit(f"Missing or empty build output: {release_dir}")

    zip_base = os.path.join("build", "windows", f"veneraGo-{version}-windows")
    zip_path = f"{zip_base}.zip"
    if os.path.exists(zip_path):
        os.remove(zip_path)
    shutil.make_archive(zip_base, "zip", release_dir)
    require_non_empty_file(zip_path)

    iss_path = os.path.join("windows", "build.iss")
    with open(iss_path, "r", encoding="utf-8") as file:
        iss_content = file.read()

    rendered_iss = iss_content.replace("{{version}}", version).replace(
        "{{root_path}}", os.getcwd()
    )
    with open(iss_path, "w", encoding="utf-8") as file:
        file.write(rendered_iss)

    try:
        isl_path = os.path.join("windows", "ChineseSimplified.isl")
        if not os.path.exists(isl_path):
            response = httpx.get(ISL_URL, follow_redirects=True, timeout=30)
            response.raise_for_status()
            with open(isl_path, "wb") as file:
                file.write(response.content)
            require_non_empty_file(isl_path)

        subprocess.run("iscc windows/build.iss", shell=True, check=True)

        installer = os.path.join(
            "build", "windows", f"veneraGo-{version}-windows-installer.exe"
        )
        require_non_empty_file(installer)
    finally:
        with open(iss_path, "w", encoding="utf-8") as file:
            file.write(iss_content)


if __name__ == "__main__":
    main()
