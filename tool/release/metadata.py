#!/usr/bin/env python3
"""Read a release version from pubspec and reject mismatched release tags."""
import argparse
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)\+([1-9][0-9]*)\s*$", re.M)


def read_version(root=ROOT):
    match = VERSION.search((root / "pubspec.yaml").read_text(encoding='utf-8'))
    if not match:
        raise ValueError("pubspec.yaml needs a semantic version and positive build number")
    return match.group(1), int(match.group(2))


def release_metadata(root=ROOT, tag="", publish=False, prerelease=True):
    version, build_number = read_version(root)
    tag_pattern = re.escape(f"v{version}")
    if "-" not in version:
        tag_pattern += r"(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"
    if tag and not re.fullmatch(tag_pattern, tag):
        raise ValueError(f"Release tag {tag!r} does not match pubspec version v{version}")
    if publish and not tag:
        raise ValueError("Publishing requires a v<pubspec-version> tag")
    if not prerelease and "-" in tag:
        raise ValueError("A prerelease tag cannot be published as a stable release")
    return {"version": version, "build_number": str(build_number), "tag": tag,
            "publish": str(publish).lower(), "prerelease": str(prerelease).lower()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default="")
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--stable", action="store_true")
    args = parser.parse_args()
    values = release_metadata(tag=args.tag, publish=args.publish, prerelease=not args.stable)
    values["ref"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, encoding='utf-8').strip()
    if values["publish"] == "true":
        existing_tag = subprocess.run(["git", "rev-parse", "--verify", f"refs/tags/{args.tag}^{{commit}}"],
                                      cwd=ROOT, capture_output=True, text=True, encoding='utf-8')
        if existing_tag.returncode == 0 and existing_tag.stdout.strip() != values["ref"]:
            raise ValueError("Existing release tag points at a different commit; it cannot be rewritten")
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a", encoding='utf-8') as handle:
            for key, value in values.items():
                handle.write(f"{key}={value}\n")
    print(f"Release {values['version']}+{values['build_number']}, commit {values['ref']}, publish={values['publish']}")


if __name__ == "__main__":
    main()
