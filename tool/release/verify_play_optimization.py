#!/usr/bin/env python3
"""Gate the actual Play AAB using the R8 metadata consumed by Android vitals."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import zipfile

R8_METADATA = 'BUNDLE-METADATA/com.android.tools/r8.json'
MAPPING = 'BUNDLE-METADATA/com.android.tools.build.obfuscation/proguard.map'
METRICS = {
    'optimization': ('isOptimizationsEnabled', 'noOptimizationPercentage'),
    'shrinking': ('isShrinkingEnabled', 'noShrinkingPercentage'),
    'obfuscation': ('isObfuscationEnabled', 'noObfuscationPercentage'),
}


def dex_hashes(archive):
    return sorted(hashlib.sha256(archive.read(n)).hexdigest()
                  for n in archive.namelist() if n.endswith('.dex'))


def inspect_bundle(path, apk=None):
    with zipfile.ZipFile(path) as archive:
        metadata = json.loads(archive.read(R8_METADATA))
        dex_bytes = sum(i.file_size for i in archive.infolist()
                        if i.filename.endswith('.dex'))
        if dex_bytes == 0:
            raise ValueError('No DEX code found')
        coverage = {}
        for name, (enabled, excluded) in METRICS.items():
            if metadata['options'].get(enabled) is not True:
                raise ValueError(f'R8 {name} is disabled')
            value = metadata['stats'][excluded]
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise ValueError(f'Invalid {name} metadata')
            if not math.isfinite(value) or not 0 <= value <= 100:
                raise ValueError(f'Invalid {name} percentage: {value}')
            coverage[name] = round(100 - value, 2)
            # Gate even bundles below the 10 MB policy floor to catch regressions.
            if 100 - value < 25:
                raise ValueError(f'{name} coverage {100 - value}% is below 25%')
        mapping = archive.read(MAPPING).decode()
        for name in ('com.tencent.tauth.Tencent', 'com.tencent.tauth.IUiListener',
                     'com.alipay.sdk.app.PayTask', 'com.alipay.sdk.app.AuthTask',
                     'space.tsukuyomi.live2d.Live2DGpu'):
            if f'{name} -> {name}:' not in mapping:
                raise ValueError(f'Required SDK/JNI class not preserved: {name}')
        bundle_dex = dex_hashes(archive)
    result = {
        'aab_sha256': hashlib.sha256(Path(path).read_bytes()).hexdigest(),
        'r8_version': metadata['version'],
        'dex_uncompressed_bytes': dex_bytes,
        'coverage_percent': coverage,
        'minimum_percent': 25,
        'all_thresholds_pass': True,
        'sdk_entry_points_preserved': True,
        'device_acceptance': 'not_established_by_static_analysis',
    }
    if apk is not None:
        with zipfile.ZipFile(apk) as archive:
            if dex_hashes(archive) != bundle_dex:
                raise ValueError('Device-test APK DEX differs from the Play AAB')
        result['device_apk_same_dex'] = True
        result['device_apk_sha256'] = hashlib.sha256(Path(apk).read_bytes()).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--apk', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = inspect_bundle(args.bundle, args.apk)
    text = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding='utf-8')
    print(text, end='')


if __name__ == '__main__':
    main()
