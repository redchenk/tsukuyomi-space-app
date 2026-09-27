#!/usr/bin/env python3
"""Fetch pinned build inputs directly from Live2D and the original project."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
CACHE = Path(os.environ.get('RUNNER_TEMP', ROOT / 'build')) / 'release-inputs'
SDK_NAME = 'CubismSdkForNative-5-r.5'
SDK_SHA256 = '7ff3a4bbc19c0a8728965aa522ab77eb11b252916453e68a8a78d3b71188bb12'
SDK_URL = f'https://cubism.live2d.com/sdk-native/bin/{SDK_NAME}.zip'
MODEL_BASE = 'https://raw.githubusercontent.com/redchenk/tsukuyomi-space/c9709bdacc069b622b993cc5b92f533cba4fac09/models/tsukimi-yachiyo/'

def fetch(url, path, expected):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == expected:
        return
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={
                'User-Agent': 'Mozilla/5.0', 'Referer': 'https://www.live2d.com/'})
            with urllib.request.urlopen(request, timeout=120) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != expected:
                raise ValueError(f'Checksum mismatch: {path.name}')
            path.write_bytes(data)
            return
        except Exception:
            if attempt == 2:
                raise
            time.sleep(3 * (attempt + 1))

def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = CACHE / f'{SDK_NAME}.zip'
    fetch(SDK_URL, archive, SDK_SHA256)
    with zipfile.ZipFile(archive) as z:
        for member in z.infolist():
            dest = (CACHE / member.filename).resolve()
            if not dest.is_relative_to(CACHE.resolve()):
                raise ValueError('Unsafe archive path')
        z.extractall(CACHE)
    model = CACHE / 'model'
    for name, checksum in json.loads((ROOT / 'tool/release/model-inputs.json').read_text()).items():
        fetch(MODEL_BASE + name, model / name, checksum)
    subprocess.run([sys.executable, str(ROOT / 'tool/setup_live2d.py'),
                    '--sdk', str(CACHE / SDK_NAME),
                    '--model', str(model / 'tsukimi-yachiyo.model3.json')], check=True)
    (ROOT / 'packages/tsukuyomi_live2d/vendor/cubism/REQUIRE_CORE').write_text('Release builds must include Cubism Core.\n')
    print('Verified Cubism SDK and character assets are ready for release.')

if __name__ == '__main__':
    main()
