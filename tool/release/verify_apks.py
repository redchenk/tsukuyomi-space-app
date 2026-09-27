#!/usr/bin/env python3
"""Fail release if Cubism is stubbed or any packaged ELF dependency is absent."""
import struct
import sys
import zipfile
from pathlib import Path

SYSTEM_LIBS = {'libc.so', 'libm.so', 'libdl.so', 'liblog.so', 'libandroid.so',
               'libz.so', 'libEGL.so', 'libGLESv2.so', 'libGLESv3.so',
               'libOpenSLES.so', 'libvulkan.so', 'libjnigraphics.so'}

def needed(data):
    if data[:4] != b'\x7fELF':
        raise ValueError('Not an ELF library')
    wide = data[4] == 2
    order = '<' if data[5] == 1 else '>'
    def unpack(fmt, offset):
        return struct.unpack_from(order + fmt, data, offset)
    phoff = unpack('Q' if wide else 'I', 32 if wide else 28)[0]
    size, count = unpack('HH', 54 if wide else 42)
    segments = []
    for i in range(count):
        values = unpack('IIQQQQQQ' if wide else 'IIIIIIII', phoff + i * size)
        segments.append((values[0], values[2] if wide else values[1],
                         values[3] if wide else values[2], values[5] if wide else values[4]))
    strings = None
    names = []
    for kind, offset, address, length in segments:
        if kind != 2:
            continue
        for p in range(offset, offset + length, 16 if wide else 8):
            tag, value = unpack('QQ' if wide else 'II', p)
            if tag == 0:
                break
            if tag == 1:
                names.append(value)
            if tag == 5:
                strings = value
    if not names:
        return []
    for kind, offset, address, length in segments:
        if kind == 1 and address <= strings < address + length:
            start = offset + strings - address
            return [data[start + n:data.index(0, start + n)].decode() for n in names]
    raise ValueError('ELF dynamic string table missing')

def verify(path):
    with zipfile.ZipFile(path) as apk:
        files = apk.namelist()
        assert 'assets/flutter_assets/assets/live2d/character.model3.json' in files
        assert 'assets/flutter_assets/assets/live2d/character.moc3' in files
        libs = [n for n in files if n.startswith('lib/') and n.endswith('.so')]
        bridges = [n for n in libs if n.endswith('/libtsukuyomi_live2d.so')]
        assert len(bridges) == 1, 'Expected one ABI per APK'
        bridge = apk.read(bridges[0])
        assert len(bridge) > 100000 and b'csmGetVersion' in bridge, 'Cubism Core is missing (stub library)'
        for lib in libs:
            prefix = lib.rsplit('/', 1)[0]
            for dependency in needed(apk.read(lib)):
                assert dependency in SYSTEM_LIBS or prefix + '/' + dependency in files, f'{lib} requires missing {dependency}'
    print(f'PASS {path.name}: real Cubism Core, model and native dependencies')

if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit('Usage: verify_apks.py <apk> ...')
    for arg in sys.argv[1:]:
        verify(Path(arg))
