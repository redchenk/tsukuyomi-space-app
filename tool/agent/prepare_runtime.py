#!/usr/bin/env python3
"""Fetch pinned desktop runtimes; mobiles never include these binaries."""
import argparse, hashlib, json, os, shutil, stat, subprocess, tarfile, urllib.request, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASES = json.loads((Path(__file__).with_name('upstream-releases.json')).read_text())
TARGETS = {
    'macos-arm64': ('opencode-darwin-arm64.zip', 'codex-package-aarch64-apple-darwin.tar.gz'),
    'macos-x64': ('opencode-darwin-x64-baseline.zip', 'codex-package-x86_64-apple-darwin.tar.gz'),
    'windows-x64': ('opencode-windows-x64-baseline.zip', 'codex-package-x86_64-pc-windows-msvc.tar.gz'),
    'linux-x64': ('opencode-linux-x64-baseline.tar.gz', 'codex-package-x86_64-unknown-linux-musl.tar.gz'),
}

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()

def fetch(runtime, name, cache):
    entry = RELEASES[runtime]['assets'][name]
    if len(entry['sha256']) != 64: raise ValueError('Missing pinned checksum: ' + name)
    archive = cache / name
    if not archive.exists() or digest(archive) != entry['sha256']:
        request = urllib.request.Request(entry['url'], headers={'User-Agent': 'tsukuyomi-runtime'})
        with urllib.request.urlopen(request, timeout=120) as r, archive.open('wb') as f:
            shutil.copyfileobj(r, f)
    if digest(archive) != entry['sha256']: raise ValueError('Runtime checksum mismatch: ' + name)
    return archive

def extract(archive, dest):
    dest.mkdir(parents=True, exist_ok=True)
    if archive.suffix == '.zip':
        with zipfile.ZipFile(archive) as z:
            for info in z.infolist():
                target = (dest / info.filename).resolve()
                if not target.is_relative_to(dest.resolve()): raise ValueError('Unsafe archive path')
            z.extractall(dest)
    else:
        with tarfile.open(archive, 'r:gz') as t:
            for member in t.getmembers():
                target = (dest / member.name).resolve()
                if not target.is_relative_to(dest.resolve()) or member.issym() or member.islnk():
                    raise ValueError('Unsafe tar entry: ' + member.name)
                if member.isdir(): target.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with t.extractfile(member) as source, target.open('wb') as output:
                        shutil.copyfileobj(source, output)
                    target.chmod(member.mode & 0o777)

def prepare(target, output, cache):
    dest = output / target
    temp = cache / ('extract-' + target)
    if temp.exists(): shutil.rmtree(temp)
    temp.mkdir()
    opencode, codex = TARGETS[target]
    extract(fetch('opencode', opencode, cache), temp / 'opencode')
    extract(fetch('codex', codex, cache), temp / 'codex')
    if dest.exists(): shutil.rmtree(dest)
    dest.mkdir(parents=True)
    extension = '.exe' if target.startswith('windows') else ''
    op = next(p for p in (temp / 'opencode').rglob('opencode' + extension) if p.is_file())
    shutil.copy2(op, dest / ('opencode' + extension))
    # Codex's package includes bwrap/command runners and platform sandbox helpers.
    for p in (temp / 'codex').iterdir():
        target_path = dest / p.name
        if p.is_dir():
            shutil.copytree(p, target_path, ignore=shutil.ignore_patterns('voice'))
        else: shutil.copy2(p, target_path)
    if not (dest / 'bin' / ('codex' + extension)).exists():
        raise ValueError('Codex package entrypoint is missing')
    for p in dest.rglob('*'):
        if p.is_file() and (p.name.startswith(('codex', 'opencode', 'bwrap'))):
            p.chmod(p.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    if not target.startswith('windows'):
        compile_args = ['cc', '-O2', str(ROOT / 'tool/agent/command_supervisor.c'), '-o', str(dest / 'command-supervisor')]
        if target.startswith('macos'): compile_args += ['-arch', 'arm64' if target.endswith('arm64') else 'x86_64']
        subprocess.run(compile_args, check=True)
    shutil.copytree(ROOT / 'tool/agent/licenses', dest / 'licenses')
    checksums = {str(p.relative_to(dest)).replace(os.sep, '/'): digest(p)
                 for p in sorted(dest.rglob('*')) if p.is_file()}
    (dest / 'runtime-manifest.json').write_text(json.dumps({
        'target': target, 'opencode': '1.18.33', 'codex': '0.159.0',
        'files': checksums,
    }, indent=2) + '\n')
    shutil.rmtree(temp)
    print('Verified runtime bundle:', target, flush=True)

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--target', choices=list(TARGETS) + ['macos', 'windows', 'linux'], required=True)
    p.add_argument('--output', type=Path, default=ROOT / 'build/agent-runtime')
    args = p.parse_args()
    cache = ROOT / 'build/agent-downloads'
    cache.mkdir(parents=True, exist_ok=True)
    targets = [t for t in TARGETS if t.startswith(args.target)] if args.target in ('macos','windows','linux') else [args.target]
    for target in targets: prepare(target, args.output, cache)

if __name__ == '__main__': main()
