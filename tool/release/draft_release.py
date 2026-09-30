#!/usr/bin/env python3
"""Validate a draft's identity and prepare numeric-ID release API requests."""
import argparse
import json
from pathlib import Path
import re


def unwrap(value):
    return value["data"] if isinstance(value, dict) and "data" in value else value


def find_release(value, tag, commit):
    value = unwrap(value)
    releases = [item for page in value for item in page] if value and isinstance(value[0], list) else value
    matches = [item for item in releases if item["tag_name"] == tag]
    if len(matches) > 1:
        raise ValueError("Release tag identifies more than one release")
    if not matches:
        return None
    release = matches[0]
    validate_release(release, tag, commit)
    return release["id"]


def validate_release(value, tag, commit):
    release = unwrap(value)
    if not isinstance(release.get("id"), int) or isinstance(release["id"], bool) or release["id"] <= 0:
        raise ValueError("A positive numeric release ID is required")
    if release.get("draft") is not True:
        raise ValueError("A published release cannot be replaced")
    if release.get("tag_name") != tag or release.get("target_commitish") != commit:
        raise ValueError("Draft release does not match the verified tag and source commit")
    return release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("find", "id", "manifest", "payload"))
    parser.add_argument("--input", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--notes", type=Path)
    parser.add_argument("--prerelease", choices=("true", "false"), default="true")
    parser.add_argument("--require-digests", action="store_true")
    parser.add_argument("--draft", action="store_true")
    args = parser.parse_args()
    if args.command == "find":
        release_id = find_release(json.loads(args.input.read_text(encoding="utf-8")), args.tag, args.commit)
        print(release_id or "")
    elif args.command == "id":
        release = validate_release(json.loads(args.input.read_text(encoding="utf-8")), args.tag, args.commit)
        print(release["id"])
    elif args.command == "manifest":
        release = validate_release(json.loads(args.input.read_text(encoding="utf-8")), args.tag, args.commit)
        if args.require_digests and not all(re.fullmatch(r"sha256:[0-9a-f]{64}", item.get("digest") or "")
                                           for item in release["assets"]):
            raise ValueError("Recovery requires a server SHA-256 digest for every uploaded asset")
        args.output.write_text(json.dumps(release["assets"], ensure_ascii=False), encoding="utf-8")
    else:
        payload = {"draft": args.draft, "prerelease": args.prerelease == "true", "tag_name": args.tag,
                   "target_commitish": args.commit, "name": f"月读空间 {args.tag}",
                   "body": args.notes.read_text(encoding="utf-8")}
        args.output.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()
