#!/usr/bin/env python3
"""Package an unsigned, arm64 iPhoneOS build for user-side signing."""
import os
import pathlib
import plistlib
import stat
import subprocess
import zipfile
from metadata import read_version

root = pathlib.Path(__file__).resolve().parents[2]
app = root / 'build/ios/iphoneos/Runner.app'
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert 'iPhoneOS' in info['CFBundleSupportedPlatforms'], 'Simulator builds cannot be self-signed for a phone'
for required in ['Frameworks/App.framework/App', 'Frameworks/Flutter.framework/Flutter', 'Frameworks/tsukuyomi_live2d.framework/tsukuyomi_live2d', 'Frameworks/App.framework/flutter_assets/assets/live2d/character.model3.json']:
    assert (app / required).is_file(), f'Missing {required}'
for binary in [app / info['CFBundleExecutable'], *app.glob('Frameworks/*.framework/*')]:
    if not binary.is_file() or binary.suffix or binary.name in ['Info', 'Resources']:
        continue
    if binary.read_bytes()[:4] not in [b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe']:
        continue
    arches = subprocess.check_output(['lipo', '-archs', str(binary)], text=True, encoding='utf-8').strip()
    assert 'arm64' in arches, f'{binary}: {arches}'
version = os.environ.get('APP_VERSION', info['CFBundleShortVersionString'])
assert version == info['CFBundleShortVersionString'] == read_version()[0], 'IPA version must match pubspec.yaml'
assert info['CFBundleVersion'] == str(read_version()[1]), 'IPA build number must match pubspec.yaml'
output = root / 'dist' / f'tsukuyomi-space-{version}-ios-arm64-unsigned.ipa'
output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob('*')):
        if '_CodeSignature' in path.parts or path.name == 'embedded.mobileprovision':
            continue
        name = 'Payload/Runner.app/' + path.relative_to(app).as_posix()
        if path.is_symlink():
            item = zipfile.ZipInfo(name)
            item.create_system = 3
            item.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(item, os.readlink(path))
        elif path.is_file():
            archive.write(path, name)
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
print(f'Created {output.name}: {output.stat().st_size} bytes (unsigned iPhoneOS arm64)')
