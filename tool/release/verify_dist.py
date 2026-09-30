#!/usr/bin/env python3
"""Require the complete, correctly versioned five-platform download set."""
import argparse
import hashlib
import json
from pathlib import Path

from metadata import read_version

SUFFIXES = ("android-arm64-v8a.apk", "android-x86_64.apk", "macos-universal.dmg",
            "ios-arm64-unsigned.ipa", "windows-x64-setup.exe", "windows-x64.zip",
            "linux-x64.deb", "linux-x64.tar.gz")


def verify(dist, version):
    expected = {f"tsukuyomi-space-{version}-{suffix}" for suffix in SUFFIXES}
    files = {path.name for path in dist.iterdir() if path.is_file()}
    missing = expected - files
    unexpected = {name for name in files if name.startswith("tsukuyomi-space-")} - expected
    if missing or unexpected:
        raise ValueError(f"Incomplete or mixed release: missing={sorted(missing)}, unexpected={sorted(unexpected)}")
    for name in expected:
        if (dist / name).stat().st_size < 1024:
            raise ValueError(f"Empty or invalid package: {name}")
    for name in ("INSTALL.md", "THIRD_PARTY_NOTICES.md"):
        if not (dist / name).is_file() or not (dist / name).stat().st_size:
            raise ValueError(f"Missing release documentation: {name}")
    checksums = []
    for name in sorted(expected | {"INSTALL.md", "THIRD_PARTY_NOTICES.md"}):
        with (dist / name).open("rb") as handle:
            hasher = hashlib.sha256()
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                hasher.update(chunk)
            digest = hasher.hexdigest()
        checksums.append(f"{digest}  {name}\n")
    (dist / "SHA256SUMS.txt").write_text("".join(checksums), encoding='utf-8')
    print(f"PASS release {version}: 8 installers/archives, installation guide, notices and SHA-256 checksums")


def verify_uploaded(dist, version, manifest):
    expected = {f"tsukuyomi-space-{version}-{suffix}" for suffix in SUFFIXES}
    expected.update(("INSTALL.md", "THIRD_PARTY_NOTICES.md", "SHA256SUMS.txt"))
    assets = json.loads(manifest.read_text(encoding='utf-8'))
    remote = {item["name"]: item for item in assets}
    if len(assets) != len(remote) or set(remote) != expected:
        raise ValueError("Draft release download names do not match the verified complete set")
    hashes = {}
    for line in (dist / "SHA256SUMS.txt").read_text(encoding='utf-8').splitlines():
        digest, name = line.split("  ", 1)
        hashes[name] = digest
    hashes["SHA256SUMS.txt"] = hashlib.sha256((dist / "SHA256SUMS.txt").read_bytes()).hexdigest()
    for name, item in remote.items():
        if item["size"] != (dist / name).stat().st_size:
            raise ValueError(f"Uploaded asset size differs: {name}")
        if item.get("digest") and item["digest"] != f"sha256:{hashes[name]}":
            raise ValueError(f"Uploaded asset checksum differs: {name}")
    print("PASS draft release: all 11 uploaded downloads have the expected names, sizes and available SHA-256 digests")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dist", type=Path)
    parser.add_argument("--version", default=read_version()[0])
    parser.add_argument("--remote-manifest", type=Path)
    args = parser.parse_args()
    if args.remote_manifest:
        verify_uploaded(args.dist, args.version, args.remote_manifest)
    else:
        verify(args.dist, args.version)
