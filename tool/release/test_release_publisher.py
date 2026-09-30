"""Exercise the actual publication shell against a local GitHub API stand-in."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from verify_dist import SUFFIXES, verify

ROOT = Path(__file__).resolve().parents[2]
TAG = 'v0.5.0-beta.1'
COMMIT = '3e56fecce7a4dc7193d84eeadc78c0420d72bb8d'


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dist = self.root / 'dist'
        self.dist.mkdir()
        for suffix in SUFFIXES:
            (self.dist / f'tsukuyomi-space-0.5.0-{suffix}').write_bytes(b'package' * 200)
        for name in ('INSTALL.md', 'THIRD_PARTY_NOTICES.md'):
            (self.dist / name).write_text('月读空间发布说明\n', encoding='utf-8')
        with contextlib.redirect_stdout(io.StringIO()):
            verify(self.dist, '0.5.0')
        self.notes = self.root / 'notes.md'
        self.notes.write_text('月读空间\n\n完整发布说明\n', encoding='utf-8')
        self.release = {'id': 399814152, 'draft': True, 'tag_name': TAG, 'target_commitish': COMMIT,
                        'assets': [{'name': path.name, 'size': path.stat().st_size,
                                    'digest': 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()}
                                   for path in self.dist.iterdir()]}
        self.release_path = self.root / 'release.json'
        self.complete_path = self.root / 'complete-release.json'
        self._save_release()
        self.complete_path.write_text(json.dumps(self.release), encoding='utf-8')
        self.log = self.root / 'gh-log.jsonl'
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        git = bin_dir / 'git'
        git.write_text('#!/usr/bin/env bash\nexit 2\n', encoding='utf-8')
        git.chmod(0o755)
        gh = bin_dir / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
args=sys.argv[1:]
with pathlib.Path(os.environ['GH_TEST_LOG']).open('a', encoding='utf-8') as log:
    log.write(json.dumps(args)+'\\n')
path=pathlib.Path(os.environ['GH_TEST_RELEASE'])
release=json.loads(path.read_text(encoding='utf-8'))
if args[0]=='api' and '/releases/tags/' in ' '.join(args):
    raise SystemExit('HTTP 404: drafts cannot be read by tag')
if args[:3]==['api','--method','POST']:
    payload=pathlib.Path(args[args.index('--input')+1])
    pathlib.Path(os.environ['GH_TEST_CREATE']).write_bytes(payload.read_bytes())
    print(json.dumps(release))
elif args[:3]==['api','--method','PATCH']:
    payload=pathlib.Path(args[args.index('--input')+1])
    pathlib.Path(os.environ['GH_TEST_PATCH']).write_bytes(payload.read_bytes())
    print('https://github.com/example/repository/releases/tag/'+release['tag_name'])
elif args[0]=='api' and '--paginate' in args:
    print(json.dumps([[]] if os.environ.get('GH_TEST_HIDE_LIST')=='true' else [[release]]))
elif args[0]=='api' and args[1].endswith('/releases/399814152'):
    print(json.dumps(release))
elif args[:2]==['release','upload']:
    shutil.copyfile(os.environ['GH_TEST_COMPLETE'], path)
else:
    raise SystemExit('Unexpected GitHub call: '+repr(args))
''', encoding='utf-8')
        gh.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update({'PATH': str(bin_dir) + os.pathsep + self.env['PATH'],
                         'GITHUB_REPOSITORY': 'example/repository', 'RELEASE_TAG': TAG,
                         'RELEASE_COMMIT': COMMIT, 'APP_VERSION': '0.5.0', 'PRERELEASE': 'true',
                         'REQUIRE_EXISTING_DRAFT': 'true', 'RUNNER_TEMP': str(self.root),
                         'DIST_DIR': str(self.dist), 'RELEASE_NOTES': str(self.notes),
                         'GH_TEST_LOG': str(self.log), 'GH_TEST_RELEASE': str(self.release_path),
                         'GH_TEST_COMPLETE': str(self.complete_path), 'GH_TEST_PATCH': str(self.root / 'patch.json'),
                         'GH_TEST_CREATE': str(self.root / 'create.json')})
        # Some macOS shells have only python3; the publisher uses the CI's
        # setup-python executable. Point the local stand-in at this interpreter.
        (bin_dir / 'python').symlink_to(sys.executable)

    def _save_release(self):
        self.release_path.write_text(json.dumps(self.release), encoding='utf-8')

    def _run(self):
        result = subprocess.run(['bash', str(ROOT / 'tool/release/publish.sh')], cwd=ROOT,
                                env=self.env, capture_output=True, text=True, encoding='utf-8')
        calls = [json.loads(line) for line in self.log.read_text(encoding='utf-8').splitlines()]
        return result, calls

    def test_actual_shell_publishes_complete_draft_by_numeric_id_without_upload(self):
        result, calls = self._run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(call[:2] == ['release', 'upload'] for call in calls))
        self.assertFalse(any('/releases/tags/' in ' '.join(call) for call in calls))
        self.assertTrue(any(call[:2] == ['api', 'repos/example/repository/releases/399814152'] for call in calls))
        self.assertEqual(calls[-1][:4], ['api', '--method', 'PATCH', 'repos/example/repository/releases/399814152'])
        payload = json.loads((self.root / 'patch.json').read_text(encoding='utf-8'))
        self.assertIs(payload['draft'], False)
        self.assertEqual(payload['target_commitish'], COMMIT)
        self.assertEqual(payload['body'], self.notes.read_text(encoding='utf-8'))

    def test_recovery_preserves_draft_if_any_uploaded_digest_differs(self):
        self.release['assets'][0]['digest'] = 'sha256:' + '0' * 64
        self._save_release()
        result, calls = self._run()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[:2] == ['release', 'upload'] or 'PATCH' in call for call in calls))
        self.assertFalse((self.root / 'patch.json').exists())

    def test_recovery_requires_server_digest_for_every_uploaded_asset(self):
        self.release['assets'][0].pop('digest')
        self._save_release()
        result, calls = self._run()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[:2] == ['release', 'upload'] or 'PATCH' in call for call in calls))

    def test_normal_publisher_uploads_missing_assets_before_numeric_id_validation(self):
        self.env['REQUIRE_EXISTING_DRAFT'] = 'false'
        self.release['assets'] = []
        self._save_release()
        result, calls = self._run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        upload = next(index for index, call in enumerate(calls) if call[:2] == ['release', 'upload'])
        patch = next(index for index, call in enumerate(calls) if 'PATCH' in call)
        self.assertLess(upload, patch)
        self.assertFalse(any('/releases/tags/' in ' '.join(call) for call in calls))

    def test_actual_shell_refuses_to_overwrite_published_release(self):
        self.release['draft'] = False
        self._save_release()
        result, calls = self._run()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[:2] == ['release', 'upload'] or 'PATCH' in call for call in calls))

    def test_new_draft_uses_creation_response_when_release_list_remains_stale(self):
        self.env.update({'REQUIRE_EXISTING_DRAFT': 'false', 'GH_TEST_HIDE_LIST': 'true'})
        self.release['assets'] = []
        self._save_release()
        result, calls = self._run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sum('--paginate' in call for call in calls), 1)
        self.assertTrue(any(call[:3] == ['api', '--method', 'POST'] for call in calls))
        self.assertTrue(any(call[:2] == ['release', 'upload'] for call in calls))
        payload = json.loads((self.root / 'create.json').read_text(encoding='utf-8'))
        self.assertIs(payload['draft'], True)
        self.assertIs(payload['prerelease'], True)
        self.assertEqual(payload['tag_name'], TAG)
        self.assertEqual(payload['target_commitish'], COMMIT)

    def test_new_draft_rejects_mismatched_creation_response_before_upload(self):
        self.env.update({'REQUIRE_EXISTING_DRAFT': 'false', 'GH_TEST_HIDE_LIST': 'true'})
        self.release['target_commitish'] = '0' * 40
        self._save_release()
        result, calls = self._run()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[:2] == ['release', 'upload'] or 'PATCH' in call for call in calls))


if __name__ == '__main__':
    unittest.main()
