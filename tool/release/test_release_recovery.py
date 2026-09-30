"""Regression fixtures from release run 36683413524 (2026-09-30)."""
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from validate_release_run import (HOOK, HOOK_LEGACY, HOOK_MATH_FIX, INSTALLERS, JOBS,
                                  REPOSITORY, source_metadata, validate, verify_hook_change)

SHA = "3e56fecce7a4dc7193d84eeadc78c0420d72bb8d"
RUN_ID = 36683413524
NOW = datetime(2026, 9, 30, 8, tzinfo=timezone.utc)


def fixture():
    repository = {"id": 1390459493, "full_name": REPOSITORY}
    url = f"https://api.github.com/repos/{REPOSITORY}/actions/runs/{RUN_ID}"
    run = {"id": RUN_ID, "head_sha": SHA, "head_commit": {"id": SHA}, "run_attempt": 1,
           "repository": repository, "head_repository": dict(repository), "url": url,
           "path": ".github/workflows/release.yml", "name": "Release installers",
           "event": "workflow_dispatch", "head_branch": "main",
           "status": "completed", "conclusion": "failure"}
    jobs = {"total_count": 9, "jobs": [
        {"name": name, "run_id": RUN_ID, "head_sha": SHA, "head_branch": "main",
         "run_url": url, "run_attempt": 1, "status": "completed",
         "conclusion": "failure" if name == "publish" else "success"} for name in sorted(JOBS)]}
    artifacts = {"total_count": 5, "artifacts": [
        {"name": name, "size_in_bytes": 1000000, "expired": False,
         "expires_at": "2026-10-14T07:37:42Z", "digest": "sha256:" + "a" * 64,
         "workflow_run": {"id": RUN_ID, "head_sha": SHA, "head_branch": "main",
                          "repository_id": repository["id"], "head_repository_id": repository["id"]}}
        for name in sorted(INSTALLERS)]}
    return run, jobs, artifacts


class RecoveryTests(unittest.TestCase):
    def check(self, data):
        return validate(*data, "v0.5.0-beta.1", version="0.5.0", build_number=5, now=NOW)

    def test_verified_real_release_fixture_is_accepted(self):
        values = self.check(fixture())
        self.assertEqual(values["source_sha"], SHA)
        self.assertEqual(values["run_id"], str(RUN_ID))
        self.assertEqual(values["version"], "0.5.0")
        self.assertEqual(values["prerelease"], "true")
        root = Path(__file__).resolve().parents[2]
        paths = [root / "artifacts" / name for name in
                 ("github-release-run-final.json", "release-recovery-jobs.json", "github-release-artifacts.json")]
        if all(path.exists() for path in paths):
            self.assertEqual(self.check([json.loads(path.read_text(encoding="utf-8")) for path in paths]), values)

    def test_all_release_prerequisites_must_have_succeeded(self):
        for name in JOBS - {"publish"}:
            data = fixture()
            next(job for job in data[1]["jobs"] if job["name"] == name)["conclusion"] = "failure"
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.check(data)

    def test_missing_platform_artifact_is_rejected(self):
        data = fixture()
        data[2]["artifacts"].pop()
        data[2]["total_count"] -= 1
        with self.assertRaises(ValueError):
            self.check(data)

    def test_wrong_commit_job_or_artifact_provenance_is_rejected(self):
        for group in ("run", "job", "artifact", "artifact_run_id"):
            data = fixture()
            if group == "run":
                data[0]["head_commit"]["id"] = "b" * 40
            elif group == "job":
                data[1]["jobs"][0]["head_sha"] = "b" * 40
            else:
                owner = data[2]["artifacts"][0]["workflow_run"]
                owner["head_sha" if group == "artifact" else "id"] = "b" * 40
            with self.subTest(group=group), self.assertRaises(ValueError):
                self.check(data)

    def test_expired_platform_artifact_is_rejected_even_before_api_flag_updates(self):
        for field, value in (("expired", True), ("expires_at", "2026-09-29T00:00:00Z")):
            data = fixture()
            data[2]["artifacts"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check(data)

    def test_running_or_successful_or_wrong_workflow_run_is_rejected(self):
        for field, value in (("status", "in_progress"), ("conclusion", "success"),
                             ("path", ".github/workflows/flutter.yml"), ("event", "pull_request"),
                             ("head_branch", "feature")):
            data = fixture()
            data[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check(data)

    def test_foreign_repository_and_incomplete_job_list_are_rejected(self):
        data = fixture()
        data[0]["repository"]["full_name"] = "other/app"
        with self.assertRaises(ValueError):
            self.check(data)
        data = fixture()
        data[1]["jobs"].pop()
        with self.assertRaises(ValueError):
            self.check(data)

    def test_duplicate_or_unknown_installers_and_wrong_tag_are_rejected(self):
        data = fixture()
        data[2]["artifacts"].append(copy.deepcopy(data[2]["artifacts"][0]))
        data[2]["total_count"] += 1
        with self.assertRaises(ValueError):
            self.check(data)
        with self.assertRaises(ValueError):
            validate(*fixture(), "v0.6.0-beta.1", version="0.5.0", build_number=5, now=NOW)

    def test_source_version_and_publisher_only_changes_are_accepted(self):
        with patch("validate_release_run.subprocess.check_output", side_effect=[
            "name: test\nversion: 0.5.0+5\n",
            "tool/release/publish.sh\n.github/workflows/recovery.yml\ndocs/release-notes.md\nREADME.md\n",
        ]):
            self.assertEqual(source_metadata(SHA), ("0.5.0", 5))

    def test_paginated_slurp_api_payloads_are_merged_and_checked(self):
        run, jobs, artifacts = fixture()
        single = self.check((run, [jobs], [artifacts]))
        job_pages = [{"total_count": 9, "jobs": jobs["jobs"][:4]},
                     {"total_count": 9, "jobs": jobs["jobs"][4:]}]
        artifact_pages = [{"total_count": 5, "artifacts": artifacts["artifacts"][:2]},
                          {"total_count": 5, "artifacts": artifacts["artifacts"][2:]}]
        self.assertEqual(self.check((run, job_pages, artifact_pages)), single)
        artifact_pages[1]["total_count"] = 6
        with self.assertRaises(ValueError):
            self.check((run, job_pages, artifact_pages))

    def test_provenance_validation_does_not_read_current_pubspec(self):
        with patch("validate_release_run.read_version", side_effect=AssertionError("Current HEAD is not the source")):
            values = validate(*fixture(), "v0.5.0-beta.1", now=NOW, check_tag=False)
            self.assertEqual(values, {"source_sha": SHA, "run_id": str(RUN_ID)})

    def test_application_or_asset_changes_require_a_fresh_build(self):
        for path in ("lib/main.dart", "assets/game/project.json", "packages/tsukuyomi_live2d/src/bridge.cpp"):
            with patch("validate_release_run.subprocess.check_output", side_effect=[
                "version: 0.5.0+5\n", path + "\n",
            ]), self.subTest(path=path), self.assertRaises(ValueError):
                source_metadata(SHA)

    def test_exact_sdk_disabled_math_hook_fix_preserves_release_inputs(self):
        source = "flags: unchanged\n" + HOOK_LEGACY + "\nsource: unchanged\n"
        current = source.replace(HOOK_LEGACY, HOOK_MATH_FIX)
        with patch("validate_release_run.subprocess.check_output", side_effect=[
            "version: 0.5.0+5\n", HOOK + "\n", source, current,
        ]):
            self.assertEqual(source_metadata(SHA), ("0.5.0", 5))

    def test_any_other_native_hook_change_is_rejected(self):
        source = "flags: unchanged\n" + HOOK_LEGACY + "\nsource: unchanged\n"
        current = source.replace(HOOK_LEGACY, HOOK_MATH_FIX)
        for altered in (current.replace("flags: unchanged", "flags: changed"),
                        current.replace("'Live2DCubismCore'", "'OtherLibrary'"),
                        source + "\nextraHook();"):
            with self.subTest(altered=altered), self.assertRaises(ValueError):
                verify_hook_change(source, altered)


if __name__ == "__main__":
    unittest.main()
