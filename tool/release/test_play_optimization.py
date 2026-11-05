import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from verify_play_optimization import inspect_bundle, MAPPING, R8_METADATA


class PlayOptimizationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.metadata = {
            'version': 'fixture',
            'options': dict(isOptimizationsEnabled=True, isShrinkingEnabled=True,
                            isObfuscationEnabled=True),
            'stats': dict(noOptimizationPercentage=20, noShrinkingPercentage=20,
                          noObfuscationPercentage=20),
        }

    def bundle(self):
        path = self.root / 'app.aab'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr(R8_METADATA, json.dumps(self.metadata))
            archive.writestr('base/dex/classes.dex', b'fixture dex')
            names = ('com.tencent.tauth.Tencent', 'com.tencent.tauth.IUiListener',
                     'com.alipay.sdk.app.PayTask', 'com.alipay.sdk.app.AuthTask',
                     'space.tsukuyomi.live2d.Live2DGpu')
            archive.writestr(MAPPING, '\n'.join(f'{n} -> {n}:' for n in names))
        return path

    def test_disabled_shrinking_is_rejected_even_with_plausible_stats(self):
        self.metadata['options']['isShrinkingEnabled'] = False
        with self.assertRaisesRegex(ValueError, 'shrinking is disabled'):
            inspect_bundle(self.bundle())

    def test_old_bundle_zero_optimization_is_rejected(self):
        self.metadata['stats']['noOptimizationPercentage'] = 100
        with self.assertRaisesRegex(ValueError, 'below 25%'):
            inspect_bundle(self.bundle())

    def test_threshold_uses_unrounded_coverage(self):
        self.metadata['stats']['noOptimizationPercentage'] = 75.001
        with self.assertRaisesRegex(ValueError, 'below 25%'):
            inspect_bundle(self.bundle())
        self.metadata['stats']['noOptimizationPercentage'] = 75
        self.assertTrue(inspect_bundle(self.bundle())['all_thresholds_pass'])

    def test_nonfinite_metadata_cannot_pass(self):
        self.metadata['stats']['noOptimizationPercentage'] = float('nan')
        with self.assertRaisesRegex(ValueError, 'Invalid'):
            inspect_bundle(self.bundle())

    def test_device_apk_must_contain_identical_dex(self):
        apk = self.root / 'test.apk'
        with zipfile.ZipFile(apk, 'w') as archive:
            archive.writestr('classes.dex', b'other dex')
        with self.assertRaisesRegex(ValueError, 'DEX differs'):
            inspect_bundle(self.bundle(), apk)
        with zipfile.ZipFile(apk, 'w') as archive:
            archive.writestr('classes.dex', b'fixture dex')
        self.assertTrue(inspect_bundle(self.bundle(), apk)['device_apk_same_dex'])


if __name__ == '__main__':
    unittest.main()
