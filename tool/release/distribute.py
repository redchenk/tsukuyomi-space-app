#!/usr/bin/env python3
"""Send the newest published installers to the restricted distribution receiver."""
import hashlib
import datetime
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

REPO = 'redchenk/tsukuyomi-space-app'
HOST = '39.105.82.189'
TAG = re.compile(r'^v(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:-([A-Za-z0-9][A-Za-z0-9.-]{0,59}))?$')
BASE_SUFFIXES = ('android-arm64-v8a.apk', 'android-x86_64.apk', 'macos-universal.dmg',
                 'ios-arm64-unsigned.ipa', 'windows-x64-setup.exe', 'windows-x64.zip',
                 'linux-x64.deb', 'linux-x64.tar.gz')
DOCS = {'INSTALL.md', 'THIRD_PARTY_NOTICES.md', 'SHA256SUMS.txt'}
OHOS_DOCS = {'OHOS-INSTALL.md', 'OHOS-THIRD-PARTY-NOTICES.md', 'OHOS-SHA256SUMS.txt', 'OHOS-BUILD-INFO.json'}


def version_key(release):
    match = TAG.fullmatch(release['tag_name'])
    pre = match[4]
    return (*map(int, match.group(1, 2, 3)), not bool(pre),
            tuple((0, int(x)) if x.isdigit() else (1, x) for x in (pre or '').split('.')))


def selected_assets(release):
    match = TAG.fullmatch(str(release.get('tag_name', '')))
    if not match or release.get('draft') is not False:
        return None
    tag = release['tag_name']
    if release.get('html_url') != f'https://github.com/{REPO}/releases/tag/{tag}':
        return None
    version = '.'.join(match.group(1, 2, 3))
    required = {f'tsukuyomi-space-{version}-{suffix}' for suffix in BASE_SUFFIXES} | DOCS
    hap = re.compile(r'^tsukuyomi-space-' + re.escape(version) + r'-[1-9]\d{0,8}-ohos-arm64-unsigned\.hap$')
    assets = {}
    for asset in release.get('assets', []):
        name = asset.get('name', '')
        if not isinstance(name, str) or not (name in required | OHOS_DOCS or hap.fullmatch(name)):
            continue
        if name in assets or asset.get('state') != 'uploaded' or type(asset.get('size')) is not int or not 0 < asset['size'] <= 2 * 1024**3:
            return None
        if not re.fullmatch(r'sha256:[a-f0-9]{64}', str(asset.get('digest', ''))):
            return None
        if asset.get('browser_download_url') != f'https://github.com/{REPO}/releases/download/{tag}/{name}':
            return None
        assets[name] = asset
    if not required <= assets.keys():
        return None
    haps = [name for name in assets if hap.fullmatch(name)]
    selected = required | OHOS_DOCS | set(haps) if len(haps) == 1 and OHOS_DOCS <= assets.keys() else required
    result = [assets[name] for name in sorted(selected)]
    return result if sum(a['size'] for a in result) <= 8 * 1024**3 else None


def main():
    if not all(os.environ.get(name, '').strip() for name in ['APP_DISTRIBUTION_SSH_KEY', 'APP_DISTRIBUTION_KNOWN_HOSTS']):
        raise RuntimeError('Dedicated distribution credentials are not configured')
    releases = json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/releases?per_page=20']))
    ready = [(r, selected_assets(r)) for r in releases]
    ready = [(r, assets) for r, assets in ready if assets]
    if not ready:
        raise RuntimeError('No complete public release')
    release, assets = max(ready, key=lambda pair: version_key(pair[0]))
    release['assets'] = assets
    with tempfile.TemporaryDirectory(prefix='app-distribution-') as temp:
        root = Path(temp)
        args = ['gh', 'release', 'download', release['tag_name'], '--repo', REPO, '--dir', temp]
        for asset in assets:
            args.extend(['--pattern', asset['name']])
        subprocess.run(args, check=True, timeout=1200)
        for asset in assets:
            file = root / asset['name']
            if file.is_symlink() or file.stat().st_size != asset['size']:
                raise ValueError('Download size mismatch')
            with file.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            if 'sha256:' + digest != asset['digest']:
                raise ValueError('Download digest mismatch')
        key, known = root / 'push-key', root / 'known-hosts'
        key.write_text(os.environ['APP_DISTRIBUTION_SSH_KEY'].strip() + '\n', encoding='utf-8'); key.chmod(0o600)
        known.write_text(os.environ['APP_DISTRIBUTION_KNOWN_HOSTS'].strip() + '\n', encoding='utf-8'); known.chmod(0o600)
        process = subprocess.Popen(['ssh', '-i', str(key), '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}', '-o', 'ConnectTimeout=15',
            '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3', '-T', f'tsukuyomi-download@{HOST}'], stdin=subprocess.PIPE)
        try:
            with tarfile.open(fileobj=process.stdin, mode='w|') as archive:
                metadata = json.dumps(release).encode()
                member = tarfile.TarInfo('release.json'); member.size = len(metadata)
                archive.addfile(member, io.BytesIO(metadata))
                for asset in assets:
                    archive.add(root / asset['name'], arcname=asset['name'], recursive=False)
            process.stdin.close()
            if process.wait(timeout=120):
                raise RuntimeError('Distribution receiver rejected the release')
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
        report = {'tag': release['tag_name'], 'release_url': release['html_url'],
                  'verified_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'public_release_downloads_verified': len(assets), 'receiver_accepted': True,
                  'assets': [{'name': a['name'], 'size': a['size'], 'sha256': a['digest'][7:]} for a in assets]}
        Path('distribution-validation.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print(f"Distributed {release['tag_name']}: {len(assets)} verified files")


if __name__ == '__main__':
    main()
