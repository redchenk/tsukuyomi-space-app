import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

HERE = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PreparationTests(unittest.TestCase):
    def test_uses_main_version_and_isolates_overrides(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            shutil.copytree(HERE, root / 'tool/ohos')
            manifests = ['pubspec.yaml', 'packages/tsukuyomi_live2d/pubspec.yaml',
                         'packages/tsukuyomi_studio_motion/pubspec.yaml']
            for relative in manifests:
                p = root / relative
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text('version: 0.7.0+42\nenvironment:\n  sdk: ^3.13.4\ndependencies:\n')
            (root / 'lib/core').mkdir(parents=True)
            (root / 'lib/core/storage.dart').write_text('MacOsOptions(usesDataProtectionKeychain: false)')
            (root / 'ohos/AppScope').mkdir(parents=True)
            app = root / 'ohos/AppScope/app.json5'
            app.write_text('{"app": {"bundleName": "example.test"}}')
            with contextlib.redirect_stdout(io.StringIO()):
                load('prepare').prepare(root)
            self.assertEqual(json.loads(app.read_text())['app']['versionCode'], 42)
            self.assertEqual(json.loads(app.read_text())['app']['versionName'], '0.7.0')
            for relative in manifests:
                self.assertIn('sdk: ^3.12.2', (root / relative).read_text())
            self.assertIn('  flutter_geolocator_ohos: any', (root / 'pubspec.yaml').read_text())
            self.assertIn('MacOsOptions()', (root / 'lib/core/storage.dart').read_text())
            self.assertTrue((root / 'packages/flutter_secure_storage/lib/flutter_secure_storage.dart').is_file())
            overrides = json.loads((root / 'pubspec_overrides.yaml').read_text())['dependency_overrides']
            for item in overrides.values():
                if isinstance(item, dict) and 'git' in item:
                    self.assertRegex(item['git']['ref'], r'^[0-9a-f]{40}$')

    def test_incomplete_hap_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'incomplete.hap'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('module.json', '{}')
            with self.assertRaisesRegex(ValueError, 'Missing HAP component'):
                load('build').validate_hap(path)

    def test_studio_release_requires_both_native_runtime_and_motion_bundle(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'studio.hap'
            with zipfile.ZipFile(path, 'w') as archive:
                for library in ['flutter', 'app', 'tsukuyomi_live2d']:
                    archive.writestr(f'libs/arm64-v8a/lib{library}.so', b'native')
                archive.writestr('flutter_assets/assets/live2d/character.moc3', b'model')
                archive.writestr('flutter_assets/assets/live2d/character.model3.json',
                                 '{"FileReferences":{"Textures":[]}}')
                archive.writestr('flutter_assets/NOTICES.Z', b'notices')
            builder = load('build')
            builder.validate_hap(path)  # Historical packages remain eligible.
            with self.assertRaisesRegex(ValueError, 'libtsukuyomi_studio_motion'):
                builder.validate_hap(path, require_studio_motion=True)
            with zipfile.ZipFile(path, 'a') as archive:
                archive.writestr('libs/arm64-v8a/libtsukuyomi_studio_motion.so', b'native')
            with self.assertRaisesRegex(ValueError, 'studio-motion.js'):
                builder.validate_hap(path, require_studio_motion=True)
            with zipfile.ZipFile(path, 'a') as archive:
                archive.writestr('flutter_assets/assets/live2d/studio-motion.js', b'motion')
            builder.validate_hap(path, require_studio_motion=True)

    def test_accepts_only_known_missing_signature_messages(self):
        builder = load('build')
        self.assertTrue(builder.is_missing_signature('请通过DevEco Studio打开ohos工程后配置调试签名(File -> Project Structure -> Signing Configs 勾选Automatically generate signature)'))
        self.assertFalse(builder.is_missing_signature('Native compilation failed: undefined symbol'))

    def test_build_failure_cannot_reuse_stale_hap(self):
        builder = load('build')
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            output = root / builder.OUTPUT
            output.mkdir(parents=True)
            stale = output / 'old-unsigned.hap'
            stale.write_bytes(b'old')
            with patch.object(builder.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, 'Compiler error')):
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, 'HAP build failed'):
                        builder.build(root)
            self.assertFalse(stale.exists())


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.remote = self.root / 'remote.git'
        self.work = self.root / 'work'
        subprocess.run(['git', 'init', '--bare', str(self.remote)], check=True, capture_output=True)
        subprocess.run(['git', 'clone', str(self.remote), str(self.work)], check=True, capture_output=True)
        self.previous = Path.cwd()
        os.chdir(self.work)
        self.addCleanup(os.chdir, self.previous)
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.com')
        self.git('checkout', '-b', 'main')
        self.commit('shared', 'base')
        self.git('push', 'origin', 'main')
        self.git('checkout', '-b', 'ohos')
        self.commit('platform', 'ohos')
        self.git('push', 'origin', 'ohos')
        self.git('checkout', 'main')

    def git(self, *args):
        return subprocess.check_output(['git', *args], stderr=subprocess.DEVNULL, text=True).strip()

    def commit(self, name, text):
        Path(name).write_text(text)
        self.git('add', name)
        self.git('commit', '-m', name)

    def test_sync_keeps_platform_files_and_is_idempotent(self):
        self.commit('new-feature', 'main update')
        self.git('push', 'origin', 'main')
        sync = load('sync_branch')
        with contextlib.redirect_stdout(io.StringIO()), patch.dict(os.environ, {'GITHUB_OUTPUT': ''}):
            self.assertTrue(sync.sync())
            self.assertEqual(Path('platform').read_text(), 'ohos')
            self.assertEqual(Path('new-feature').read_text(), 'main update')
            self.assertFalse(sync.sync())

    def test_conflict_preserves_remote_and_aborts_merge(self):
        self.git('checkout', 'ohos')
        self.commit('shared', 'platform change')
        self.git('push', 'origin', 'ohos')
        before = self.git('rev-parse', 'origin/ohos')
        self.git('checkout', 'main')
        self.commit('shared', 'upstream change')
        self.git('push', 'origin', 'main')
        with self.assertRaisesRegex(RuntimeError, 'Remote ohos was not changed'):
            load('sync_branch').sync()
        self.assertEqual(before, self.git('rev-parse', 'origin/ohos'))
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_dirty_checkout_is_untouched(self):
        Path('shared').write_text('unsaved')
        with self.assertRaisesRegex(RuntimeError, 'dirty checkout'):
            load('sync_branch').sync()
        self.assertEqual(Path('shared').read_text(), 'unsaved')


if __name__ == '__main__':
    unittest.main()
