#!/usr/bin/env python3
"""Permit recovery only of a complete release whose publisher alone failed."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess

from metadata import ROOT, VERSION, read_version

REPOSITORY = "redchenk/tsukuyomi-space-app"
JOBS = {"metadata", "quality", "build (macos-15, macos)", "build (macos-15, ios)",
        "build (windows-2022, windows)", "build (ubuntu-22.04, linux)",
        "build (ubuntu-22.04, android)", "native-smoke / android", "publish"}
INSTALLERS = {f"installers-{platform}" for platform in ("macos", "ios", "windows", "linux", "android")}
HOOK = "packages/tsukuyomi_live2d/hook/build.dart"
HOOK_LEGACY = """      libraries: enabled
          ? [
              os == OS.windows ? 'Live2DCubismCore_MD' : 'Live2DCubismCore',
              if (os == OS.android) ...['m', 'log'],
            ]
          : [],"""
HOOK_MATH_FIX = """      libraries: [
        if (enabled)
          os == OS.windows ? 'Live2DCubismCore_MD' : 'Live2DCubismCore',
        // PCM decoding needs libm even in development builds without Cubism.
        if (os == OS.android) ...['m', 'log'],
      ],"""


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_hook_change(source, current):
    # Only the SDK-disabled Android math-library fix preserves release inputs.
    require(source.count(HOOK_LEGACY) == 1 and
            source.replace(HOOK_LEGACY, HOOK_MATH_FIX, 1) == current,
            "Native hook changed beyond the SDK-disabled Android math-library fix")


def unwrap(value):
    if isinstance(value, list):
        require(value, "GitHub API pagination returned no pages")
        pages = [unwrap(page) for page in value]
        kinds = {key for page in pages for key in ("jobs", "artifacts") if key in page}
        require(len(kinds) == 1, "Unexpected paginated GitHub response")
        kind = kinds.pop()
        total = pages[0].get("total_count")
        require(all(page.get("total_count") == total and isinstance(page.get(kind), list)
                    for page in pages), "Inconsistent GitHub API pagination")
        return {"total_count": total, kind: [row for page in pages for row in page[kind]]}
    require(isinstance(value, dict), "Unexpected GitHub API response")
    if "data" in value:
        require(value.get("status") == 200, "GitHub API response was not successful")
        return unwrap(value["data"])
    return value


def validate(run, jobs, artifacts, tag, *, version=None, build_number=None, now=None, check_tag=True):
    run, jobs, artifacts = map(unwrap, (run, jobs, artifacts))
    now = now or datetime.now(timezone.utc)
    run_id, sha = run.get("id"), run.get("head_sha")
    require(isinstance(run_id, int) and run_id > 0, "Invalid source run ID")
    require(isinstance(run.get("run_attempt"), int) and run["run_attempt"] > 0,
            "Invalid source run attempt")
    require(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha), "Invalid source commit")
    require(run.get("head_commit", {}).get("id") == sha, "Run commit provenance differs")
    repository = run.get("repository", {})
    head_repository = run.get("head_repository", {})
    require(repository.get("full_name") == REPOSITORY and
            head_repository.get("full_name") == REPOSITORY and
            isinstance(repository.get("id"), int) and
            repository.get("id") == head_repository.get("id"), "Unexpected source repository")
    require(run.get("path") == ".github/workflows/release.yml" and
            run.get("name") == "Release installers", "Unexpected source workflow")
    require(run.get("event") == "workflow_dispatch" and run.get("head_branch") == "main",
            "Recovery requires a release dispatched from main")
    require(run.get("status") == "completed" and run.get("conclusion") == "failure",
            "Source run must be completed with only publication failed")
    expected_url = f"https://api.github.com/repos/{REPOSITORY}/actions/runs/{run_id}"
    require(run.get("url") == expected_url, "Source run URL differs")
    rows = jobs.get("jobs", [])
    require(jobs.get("total_count") == len(rows) == len(JOBS), "Incomplete source job listing")
    require({job.get("name") for job in rows} == JOBS, "Unexpected or missing release jobs")
    for job in rows:
        require(job.get("run_id") == run_id and job.get("head_sha") == sha and
                job.get("head_branch") == "main" and job.get("run_url") == expected_url and
                job.get("run_attempt") == run.get("run_attempt"), "Job provenance differs")
        expected = "failure" if job["name"] == "publish" else "success"
        require(job.get("status") == "completed" and job.get("conclusion") == expected,
                f"Release prerequisite failed or incomplete: {job['name']}")
    rows = artifacts.get("artifacts", [])
    require(artifacts.get("total_count") == len(rows), "Incomplete source artifact listing")
    installers = [item for item in rows if item.get("name", "").startswith("installers-")]
    require(len(installers) == len(INSTALLERS) and
            {item.get("name") for item in installers} == INSTALLERS,
            "Missing, duplicate or unexpected platform installers")
    for item in rows:
        owner = item.get("workflow_run", {})
        require(owner.get("id") == run_id and owner.get("head_sha") == sha and
                owner.get("head_branch") == "main" and
                owner.get("repository_id") == repository["id"] and
                owner.get("head_repository_id") == repository["id"], "Artifact provenance differs")
        if item not in installers:
            continue
        require(item.get("expired") is False and item.get("size_in_bytes", 0) > 1024,
                "Platform installer is expired or empty")
        expires = datetime.fromisoformat(item.get("expires_at", "").replace("Z", "+00:00"))
        require(expires.tzinfo is not None and expires > now, "Platform installer has expired")
        require(isinstance(item.get("digest"), str) and
                re.fullmatch(r"sha256:[0-9a-f]{64}", item["digest"]), "Missing artifact SHA-256 provenance")
    values = {"source_sha": sha, "run_id": str(run_id)}
    if not check_tag:
        return values
    if version is None:
        version, build_number = read_version()
    pattern = re.escape(f"v{version}")
    if "-" not in version:
        pattern += r"(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"
    require(re.fullmatch(pattern, tag), "Recovery tag differs from the source version")
    require(isinstance(build_number, int) and build_number > 0, "Invalid source build number")
    return {**values, "version": version,
            "build_number": str(build_number), "prerelease": str("-" in tag).lower()}


def source_metadata(sha, root=ROOT):
    text = subprocess.check_output(["git", "show", f"{sha}:pubspec.yaml"], cwd=root, text=True, encoding="utf-8")
    match = VERSION.search(text)
    require(match, "Source commit lacks a valid version and build number")
    changed = subprocess.check_output(["git", "diff", "--name-only", sha, "HEAD"], cwd=root, text=True, encoding="utf-8").splitlines()
    allowed = (".github/workflows/", "tool/release/", "docs/")
    approved = {"README.md", HOOK}
    require(all(name in approved or name.startswith(allowed) for name in changed),
            "Application or licensed assets changed after the verified build; rebuild instead")
    if HOOK in changed:
        source = subprocess.check_output(["git", "show", f"{sha}:{HOOK}"], cwd=root, text=True, encoding="utf-8")
        current = subprocess.check_output(["git", "show", f"HEAD:{HOOK}"], cwd=root, text=True, encoding="utf-8")
        verify_hook_change(source, current)
    return match.group(1), int(match.group(2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("run", "jobs", "artifacts"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    documents = [json.loads(getattr(args, name).read_text(encoding="utf-8")) for name in ("run", "jobs", "artifacts")]
    # Validate API provenance before using its commit in local Git operations.
    values = validate(*documents, args.tag, check_tag=False)
    version, build_number = source_metadata(values["source_sha"])
    values = validate(*documents, args.tag, version=version, build_number=build_number)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8") as handle:
            for key, value in values.items():
                handle.write(f"{key}={value}\n")
    print(json.dumps(values, sort_keys=True))


if __name__ == "__main__":
    main()
