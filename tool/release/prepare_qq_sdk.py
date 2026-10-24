#!/usr/bin/env python3
"""Fetch the official, checksum-pinned QQ Android SDK without vendoring it."""
import hashlib
from pathlib import Path
import urllib.request
import zipfile
import io

ROOT = Path(__file__).resolve().parents[2]
URL = 'https://tangram-1251316161.file.myqcloud.com/files/20260414/143310b667ece8922594fbe866dabdef.zip'
SHA256 = '6272d4123d8327400a655c48f1fb7eb24b83fd5beeb527951ed100b219192b9b'
MEMBER = 'open_sdk_3.5.19_r9483ffc7_lite.jar'

def main():
    cache = ROOT / 'build/release-inputs/qq-sdk-3.5.19.zip'
    cache.parent.mkdir(parents=True, exist_ok=True)
    data = cache.read_bytes() if cache.exists() else b''
    if hashlib.sha256(data).hexdigest() != SHA256:
        with urllib.request.urlopen(URL, timeout=60) as response:
            data = response.read(8 * 1024 * 1024)
        if hashlib.sha256(data).hexdigest() != SHA256:
            raise ValueError('QQ SDK checksum mismatch')
        cache.write_bytes(data)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        jar = archive.read(MEMBER)
    target = ROOT / 'android/app/libs/qq-open-sdk.jar'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(jar)
    print('Verified official QQ Android SDK 3.5.19.')

if __name__ == '__main__':
    main()
