"""Validate release gates without running Flutter or touching GitHub."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

from metadata import release_metadata
from verify_assets import verify as verify_assets
from verify_dist import SUFFIXES, verify as verify_dist, verify_uploaded


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'pubspec.yaml').write_text('name: test\nversion: 0.5.0+5\n')

    def test_pubspec_version_and_preview_tag(self):
        result = release_metadata(self.root, 'v0.5.0-beta.1', publish=True)
        self.assertEqual(result['version'], '0.5.0')
        self.assertEqual(result['build_number'], '5')
        self.assertEqual(result['publish'], 'true')
        self.assertEqual(result['prerelease'], 'true')

    def test_mismatched_missing_and_unsafe_tags_are_rejected(self):
        for tag in ('v0.4.0', '', 'v0.5.0\nref=main', 'v0.5.0-beta.1/../main'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release_metadata(self.root, tag, publish=True)

    def test_preview_cannot_be_promoted_as_stable(self):
        with self.assertRaises(ValueError):
            release_metadata(self.root, 'v0.5.0-beta.1', publish=True, prerelease=False)
        self.assertEqual(release_metadata(self.root, 'v0.5.0', publish=True, prerelease=False)['prerelease'], 'false')

    def test_workflow_gate_distinguishes_stable_and_preview_tag_pushes(self):
        # Execute the real workflow shell block with local stand-ins so a
        # workflow edit cannot silently change release classification.
        workflow = Path(__file__).resolve().parents[2] / '.github/workflows/release.yml'
        section = workflow.read_text().split('- name: Validate version, tag and publication mode', 1)[1]
        block = section.split('        run: |\n', 1)[1]
        script_lines = []
        for line in block.splitlines():
            if line.strip() and not line.startswith('          '):
                break
            script_lines.append(line[10:])
        script = '\n'.join(script_lines)
        captured = self.root / 'workflow-args'
        stand_ins = 'python() { printf "%s\\0" "$@" > "$RELEASE_TEST_ARGS"; }; gh() { return 1; };\n'
        for tag, stable in (('v0.5.0', True), ('v0.5.0-beta.1', False)):
            with self.subTest(tag=tag):
                env = os.environ.copy()
                env.update({'GITHUB_REF': f'refs/tags/{tag}', 'GITHUB_REF_NAME': tag,
                            'INPUT_TAG': '', 'INPUT_PUBLISH': '', 'INPUT_PRERELEASE': '',
                            'RELEASE_TEST_ARGS': str(captured)})
                subprocess.run(['bash', '-c', 'set -euo pipefail\n' + stand_ins + script],
                               env=env, check=True, capture_output=True, text=True)
                args = captured.read_bytes().decode().strip('\0').split('\0')
                self.assertEqual(args[:4], ['tool/release/metadata.py', '--tag', tag, '--publish'])
                self.assertEqual('--stable' in args, stable)

    def _release_files(self):
        for suffix in SUFFIXES:
            (self.root / f'tsukuyomi-space-0.5.0-{suffix}').write_bytes(b'x' * 1024)
        for name in ('INSTALL.md', 'THIRD_PARTY_NOTICES.md'):
            (self.root / name).write_text('Release documentation\n')

    def test_complete_release_creates_exact_checksums(self):
        self._release_files()
        with contextlib.redirect_stdout(io.StringIO()):
            verify_dist(self.root, '0.5.0')
        lines = (self.root / 'SHA256SUMS.txt').read_text().splitlines()
        self.assertEqual(len(lines), 10)
        self.assertNotIn('SHA256SUMS.txt', '\n'.join(lines))
        self.assertTrue(all(len(line.split()[0]) == 64 for line in lines))

    def test_missing_or_previous_version_archive_blocks_release(self):
        self._release_files()
        missing = self.root / 'tsukuyomi-space-0.5.0-windows-x64.zip'
        missing.unlink()
        with self.assertRaises(ValueError):
            verify_dist(self.root, '0.5.0')
        missing.write_bytes(b'x' * 1024)
        (self.root / 'tsukuyomi-space-0.4.0-macos-universal.dmg').write_bytes(b'x' * 1024)
        with self.assertRaises(ValueError):
            verify_dist(self.root, '0.5.0')

    def test_remote_upload_is_checked_before_draft_publication(self):
        self._release_files()
        with contextlib.redirect_stdout(io.StringIO()):
            verify_dist(self.root, '0.5.0')
        manifest = self.root / 'remote.json'
        assets = [{'name': path.name, 'size': path.stat().st_size}
                  for path in self.root.iterdir() if path.name != 'pubspec.yaml']
        manifest.write_text(json.dumps(assets))
        with contextlib.redirect_stdout(io.StringIO()):
            verify_uploaded(self.root, '0.5.0', manifest)
        assets[0]['size'] += 1
        manifest.write_text(json.dumps(assets))
        with self.assertRaises(ValueError):
            verify_uploaded(self.root, '0.5.0', manifest)
        assets[0]['size'] -= 1
        assets[0]['digest'] = 'sha256:invalid'
        manifest.write_text(json.dumps(assets))
        with self.assertRaises(ValueError):
            verify_uploaded(self.root, '0.5.0', manifest)

    def _site_assets(self):
        source = self.root / 'assets'
        for folder in ('images', 'game', 'live2d', 'shaders'):
            (source / folder).mkdir(parents=True)
        (source / 'images/wiki.webp').write_bytes(b'wiki-image')
        (source / 'game/costume.png').write_bytes(b'costume')
        (source / 'game/sound.wav').write_bytes(b'sound')
        (source / 'game/font.ttf').write_bytes(b'font')
        (source / 'game/project.json').write_text(json.dumps({
            'targets': [{'costumes': [{'file': 'costume.png'}], 'sounds': [{'file': 'sound.wav'}]}],
            'customFonts': [{'system': False, 'md5ext': 'font.ttf'}]}))
        (source / 'live2d/character.moc3').write_bytes(b'cubism')
        (source / 'live2d/texture.webp').write_bytes(b'texture')
        (source / 'live2d/character.model3.json').write_text(json.dumps({
            'FileReferences': {'Moc': 'character.moc3', 'Textures': ['texture.webp']}}))
        (source / 'shaders/kaguya_effect.frag').write_bytes(b'compiled-shader')
        target = self.root / 'flutter_assets'
        shutil.copytree(source, target / 'assets')
        return target

    def test_folder_and_apk_contain_all_site_game_and_model_assets(self):
        target = self._site_assets()
        with contextlib.redirect_stdout(io.StringIO()):
            verify_assets(target, self.root)
            apk = self.root / 'release.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                for path in target.rglob('*'):
                    if path.is_file():
                        archive.write(path, 'assets/flutter_assets/' + path.relative_to(target).as_posix())
            verify_assets(apk, self.root)

    def test_missing_game_sound_and_modified_wiki_image_block_packaging(self):
        target = self._site_assets()
        sound = target / 'assets/game/sound.wav'
        sound.unlink()
        with self.assertRaises(FileNotFoundError):
            verify_assets(target, self.root)
        sound.write_bytes(b'sound')
        (target / 'assets/images/wiki.webp').write_bytes(b'wrong-image')
        with self.assertRaises(ValueError):
            verify_assets(target, self.root)


if __name__ == '__main__':
    unittest.main()
