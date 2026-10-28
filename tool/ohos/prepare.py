#!/usr/bin/env python3
"""Enable OHOS dependencies in a disposable checkout, preserving main manifests."""
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[2]


def prepare(root):
    source = root / 'tool/ohos'
    # Standard Flutter can still analyze/test the unprepared branch. Only the
    # dedicated CPF-Flutter build lowers its minimum to that SDK's Dart 3.12.2.
    for relative in ['pubspec.yaml', 'packages/tsukuyomi_live2d/pubspec.yaml',
                     'packages/tsukuyomi_studio_motion/pubspec.yaml']:
        path = root / relative
        text = path.read_text()
        text, count = re.subn(r'(?m)^  sdk: \^3\.\d+\.\d+$', '  sdk: ^3.12.2', text)
        if count != 1:
            raise ValueError(f'Unsupported SDK declaration in {relative}')
        if relative == 'pubspec.yaml' and '  flutter_geolocator_ohos:' not in text:
            # The pinned facade mistakenly endorses geolocator_ohos, but the
            # implementation package is named flutter_geolocator_ohos. Flutter
            # selects a direct implementation over an invalid default package.
            text = text.replace('dependencies:\n',
                                'dependencies:\n  flutter_geolocator_ohos: any\n', 1)
        path.write_text(text)
    adapter = root / 'packages/flutter_secure_storage'
    (adapter / 'lib').mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source / 'secure_storage/pubspec.yaml', adapter / 'pubspec.yaml')
    shutil.copyfile(source / 'secure_storage/flutter_secure_storage.dart.template',
                    adapter / 'lib/flutter_secure_storage.dart')
    overrides = json.loads((source / 'dependency_overrides.json').read_text())
    for name, item in overrides['dependency_overrides'].items():
        if isinstance(item, dict) and 'git' in item:
            if not re.fullmatch('[0-9a-f]{40}', item['git']['ref']):
                raise ValueError(f'Unpinned dependency: {name}')
    (root / 'pubspec_overrides.yaml').write_text(json.dumps(overrides, indent=2) + '\n')
    shutil.copyfile(source / 'pubspec.lock', root / 'pubspec.lock')
    # The OHOS-only storage plugin predates the macOS v10 option. Its OHOS
    # implementation is used here; standard Flutter retains its original Keychain option.
    storage = root / 'lib/core/storage.dart'
    text = storage.read_text()
    text = text.replace('MacOsOptions(usesDataProtectionKeychain: false)', 'MacOsOptions()')
    storage.write_text(text)
    manifest = (root / 'pubspec.yaml').read_text()
    version = re.search(r'(?m)^version: (\d+\.\d+\.\d+)\+(\d+)$', manifest)
    if not version:
        raise ValueError('Version must match main x.y.z+build')
    app = root / 'ohos/AppScope/app.json5'
    data = json.loads(app.read_text())
    data['app'].update(versionName=version[1], versionCode=int(version[2]))
    app.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    print(f'Prepared OHOS {version[1]}+{version[2]}; use CPF-Flutter, not standard Flutter.')


if __name__ == '__main__':
    prepare(ROOT)
