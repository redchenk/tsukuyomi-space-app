"""Check real Android settings against the installed Flutter support policy."""
import contextlib
import io
from pathlib import Path
import re
import shutil
import tempfile
import unittest

from verify_android_toolchain import ROOT, flutter_sdk, flutter_minimums, verify


class AndroidToolchainTests(unittest.TestCase):
    def setUp(self):
        self.sdk = flutter_sdk()
        self.minimums = flutter_minimums(self.sdk)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('settings.gradle.kts', 'gradle/wrapper/gradle-wrapper.properties', 'app/build.gradle.kts'):
            destination = self.root / 'android' / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / 'android' / name, destination)

    def test_actual_repository_toolchain_satisfies_real_flutter_minimums(self):
        with contextlib.redirect_stdout(io.StringIO()):
            actual, minimums = verify(ROOT, self.sdk, self.minimums['Java'][0])
        self.assertEqual(minimums, self.minimums)
        self.assertTrue(all(actual[name] >= minimum for name, minimum in minimums.items()))

    def test_wrapper_below_real_flutter_floor_is_rejected(self):
        floor = self.minimums['Gradle']
        lower = (floor[0], floor[1] - 1, 0) if floor[1] else (floor[0] - 1, 0, 0)
        wrapper = self.root / 'android/gradle/wrapper/gradle-wrapper.properties'
        wrapper.write_text(re.sub(r'gradle-\d+\.\d+\.\d+-',
                                 'gradle-' + '.'.join(map(str, lower)) + '-',
                                 wrapper.read_text(encoding='utf-8')), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'Gradle.*below.*Flutter'):
            verify(self.root, self.sdk, self.minimums['Java'][0])

    def test_java_below_real_flutter_floor_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Java.*below.*Flutter'):
            verify(self.root, self.sdk, self.minimums['Java'][0] - 1)

    def test_agp_and_kotlin_below_real_flutter_floors_are_rejected(self):
        settings = self.root / 'android/settings.gradle.kts'
        original = settings.read_text(encoding='utf-8')
        for name, plugin in (('AGP', 'com.android.application'), ('KGP', 'org.jetbrains.kotlin.android')):
            with self.subTest(name=name):
                floor = self.minimums[name]
                lower = (floor[0], floor[1], floor[2] - 1) if floor[2] else (floor[0], floor[1] - 1, 0)
                replacement = f'id("{plugin}") version "' + '.'.join(map(str, lower)) + '"'
                settings.write_text(re.sub(rf'id\("{re.escape(plugin)}"\)\s+version\s+"[0-9.]+"',
                                          replacement, original), encoding='utf-8')
                with self.assertRaisesRegex(ValueError, name + '.*below.*Flutter'):
                    verify(self.root, self.sdk, self.minimums['Java'][0])

    def test_min_sdk_below_real_flutter_floor_is_rejected(self):
        app = self.root / 'android/app/build.gradle.kts'
        app.write_text(app.read_text(encoding='utf-8').replace('minSdk = flutter.minSdkVersion',
                       f'minSdk = {self.minimums["minSdk"][0] - 1}'), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'minSdk.*below.*Flutter'):
            verify(self.root, self.sdk, self.minimums['Java'][0])


if __name__ == '__main__':
    unittest.main()
