#!/usr/bin/env python3
"""Check the repository's Android toolchain against the installed Flutter SDK."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def require_match(pattern, source, description):
    match = re.search(pattern, source, re.M)
    if not match:
        raise ValueError(f"Cannot determine {description}; review the toolchain validator")
    return match


def flutter_sdk(root=ROOT):
    if value := os.environ.get("FLUTTER_ROOT"):
        return Path(value)
    local = root / "android/local.properties"
    if local.is_file():
        match = re.search(r"^flutter\.sdk=(.+)$", local.read_text(encoding="utf-8"), re.M)
        if match:
            return Path(match.group(1).replace(r"\:", ":").replace(r"\\", "\\"))
    if command := shutil.which("flutter"):
        return Path(command).resolve().parents[1]
    raise ValueError("Set FLUTTER_ROOT or pass --flutter-sdk to validate against the real SDK")


def flutter_minimums(sdk):
    checker = sdk / "packages/flutter_tools/gradle/src/main/kotlin/DependencyVersionChecker.kt"
    source = checker.read_text(encoding="utf-8")
    minimums = {}
    for name in ("Gradle", "AGP", "KGP"):
        match = require_match(rf"\berror{name}Version\s*:\s*\w+\s*=\s*\w+\(\s*(\d+),\s*(\d+),\s*(\d+)\s*\)",
                              source, f"Flutter's {name} minimum")
        minimums[name] = tuple(map(int, match.groups()))
    java = require_match(r"\berrorJavaVersion\s*:\s*JavaVersion\s*=\s*JavaVersion\.VERSION_(\d+)",
                         source, "Flutter's Java minimum")
    minimums["Java"] = (int(java.group(1)),)
    sdk_floor = require_match(r"\berrorMinSdkVersion\s*:\s*Int\s*=\s*(\d+)",
                              source, "Flutter's Android minSdk minimum")
    minimums["minSdk"] = (int(sdk_floor.group(1)),)
    return minimums


def project_versions(root, sdk, java_major):
    settings = (root / "android/settings.gradle.kts").read_text(encoding="utf-8")
    wrapper = (root / "android/gradle/wrapper/gradle-wrapper.properties").read_text(encoding="utf-8")
    app = (root / "android/app/build.gradle.kts").read_text(encoding="utf-8")
    versions = {"Java": (java_major,)}
    distribution = require_match(r"gradle-(\d+)\.(\d+)\.(\d+)-(?:all|bin)\.zip", wrapper, "Gradle wrapper version")
    versions["Gradle"] = tuple(map(int, distribution.groups()))
    require_match(r"^distributionSha256Sum=[0-9a-f]{64}$", wrapper, "pinned Gradle distribution checksum")
    for name, plugin in (("AGP", "com.android.application"), ("KGP", "org.jetbrains.kotlin.android")):
        match = require_match(rf'id\("{re.escape(plugin)}"\)\s+version\s+"(\d+)\.(\d+)\.(\d+)"',
                              settings, f"{name} plugin version")
        versions[name] = tuple(map(int, match.groups()))
    require_match(r'id\("org\.jetbrains\.kotlin\.android"\)', app, "explicit Kotlin Android application")
    min_sdk = require_match(r"\bminSdk\s*=\s*(\d+|flutter\.minSdkVersion)", app, "application minSdk")
    if min_sdk.group(1).isdigit():
        value = int(min_sdk.group(1))
    else:
        extension = (sdk / "packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt").read_text(encoding="utf-8")
        value = int(require_match(r"\bminSdkVersion\s*:\s*Int\s*=\s*(\d+)", extension, "Flutter's default minSdk").group(1))
    versions["minSdk"] = (value,)
    return versions


def verify(root, sdk, java_major):
    minimums = flutter_minimums(sdk)
    actual = project_versions(root, sdk, java_major)
    for name, minimum in minimums.items():
        if actual[name] < minimum:
            version = ".".join(map(str, actual[name]))
            required = ".".join(map(str, minimum))
            raise ValueError(f"{name} {version} is below the installed Flutter SDK's minimum {required}")
    print("PASS Android toolchain against real Flutter gates: " + ", ".join(
        f"{name}={'.'.join(map(str, value))}" for name, value in actual.items()))
    return actual, minimums


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-sdk", type=Path)
    args = parser.parse_args()
    java = subprocess.run(["java", "-version"], capture_output=True, text=True, encoding="utf-8", check=True)
    major = int(require_match(r'version\s+"(\d+)', java.stderr + java.stdout, "running Java version").group(1))
    verify(ROOT, args.flutter_sdk or flutter_sdk(), major)
