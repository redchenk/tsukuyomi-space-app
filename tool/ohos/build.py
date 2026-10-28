#!/usr/bin/env python3
"""Build an unsigned HAP, rejecting stale, missing or incomplete outputs."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = Path('ohos/entry/build/default/outputs/default')


def is_missing_signature(log):
    return bool(re.search(
        r'(?i)(no signing configs|signing config.*(?:not found|not exist)|'
        r'no material.*sign|please.*signing|unsigned.*sign|'
        r'配置调试签名|Automatically generate signature)', log,
    ))


def validate_hap(path, require_studio_motion=False):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError('Corrupt HAP')
        names = archive.namelist()
        required = [
            'libs/arm64-v8a/libflutter.so',
            'libs/arm64-v8a/libapp.so',
            'libs/arm64-v8a/libtsukuyomi_live2d.so',
            'flutter_assets/assets/live2d/character.moc3',
            'flutter_assets/assets/live2d/character.model3.json',
            'flutter_assets/NOTICES.Z',
        ]
        if require_studio_motion:
            required += ['libs/arm64-v8a/libtsukuyomi_studio_motion.so',
                         'flutter_assets/assets/live2d/studio-motion.js']
        for suffix in required:
            if not any(name.endswith(suffix) and archive.getinfo(name).file_size > 0
                       for name in names):
                raise ValueError(f'Missing HAP component: {suffix}')
        model = next(n for n in names if n.endswith('flutter_assets/assets/live2d/character.model3.json'))
        refs = json.loads(archive.read(model))['FileReferences']
        base = model.rsplit('/', 1)[0] + '/'
        for texture in refs['Textures']:
            if base + texture not in names:
                raise ValueError(f'Missing model texture: {texture}')


def build(root):
    output = root / OUTPUT
    # Only remove old HAP files from this precise output folder. Never clean the
    # project's build root (which may be a symlink to shared build caches).
    for old in output.glob('*.hap'):
        old.unlink()
    proc = subprocess.run(
        ['flutter', 'build', 'hap', '--release', '--target-platform', 'ohos-arm64'],
        cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    print(proc.stdout)
    candidates = list(output.glob('*unsigned.hap'))
    # No blanket continue-on-error: only the known absent-signature failure is
    # acceptable, and only with a newly generated, structurally valid HAP.
    signing_failure = is_missing_signature(proc.stdout)
    if proc.returncode and not signing_failure:
        raise RuntimeError(f'HAP build failed ({proc.returncode})')
    if len(candidates) != 1:
        raise ValueError('Expected exactly one newly built unsigned HAP')
    validate_hap(candidates[0], require_studio_motion=(
        root / 'packages/tsukuyomi_studio_motion/pubspec.yaml').is_file())
    version = re.search(r'(?m)^version: (\S+)', (root / 'pubspec.yaml').read_text())[1]
    destination = root / 'dist/ohos'
    destination.mkdir(parents=True, exist_ok=True)
    name = f'tsukuyomi-space-{version.replace("+", "-")}-ohos-arm64-unsigned.hap'
    target = destination / name
    shutil.copyfile(candidates[0], target)
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    (destination / 'SHA256SUMS').write_text(f'{digest}  {name}\n')
    shutil.copyfile(root / 'THIRD_PARTY_NOTICES.md', destination / 'THIRD_PARTY_NOTICES.md')
    provenance = {
        'source': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
        'flutter': 'CPF-Flutter 3ffe70c6280cc6ddf613bffa59dd70611f238f7e',
        'sdk': '26.0.0.821', 'signed': False,
        'file': name, 'sha256': digest,
    }
    (destination / 'build-info.json').write_text(json.dumps(provenance, indent=2) + '\n')
    print(f'Verified unsigned HAP: {name}')


if __name__ == '__main__':
    build(ROOT)
