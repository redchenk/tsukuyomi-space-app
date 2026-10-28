#!/usr/bin/env python3
"""Add a verified unsigned HAP to an existing release, without clobbering assets."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from build import validate_hap

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = 'redchenk/tsukuyomi-space-app'
TAG = re.compile(r'v([0-9]+\.[0-9]+\.[0-9]+)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?')
SHA = re.compile(r'[0-9a-f]{40}')
CHECKSUMS = 'OHOS-SHA256SUMS.txt'
BEGIN = '<!-- tsukuyomi-ohos-download -->'
END = '<!-- /tsukuyomi-ohos-download -->'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            hasher.update(chunk)
    return hasher.hexdigest()


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True, encoding='utf-8').strip()


def version_at(source):
    require(SHA.fullmatch(source), 'Expected immutable source SHA')
    text = git('show', f'{source}:pubspec.yaml')
    match = re.search(r'(?m)^version:\s*(\d+\.\d+\.\d+)\+([1-9][0-9]*)\s*$', text)
    require(match, 'Source has no valid app version')
    return match[1], int(match[2])


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class GitHub:
    def __init__(self, token):
        require(token, 'GH_TOKEN is required')
        self.token = token

    def request(self, path, method='GET', payload=None, file=None):
        # Never forward authorization to artifact storage or arbitrary URLs.
        require(not path.startswith('/') and '://' not in path, 'Expected repository API path')
        host = 'uploads.github.com' if file else 'api.github.com'
        url = f'https://{host}/repos/{REPOSITORY}/{path}'
        headers = {'Authorization': f'Bearer {self.token}',
                   'Accept': 'application/vnd.github+json',
                   'User-Agent': 'tsukuyomi-ohos-release',
                   'X-GitHub-Api-Version': '2022-11-28'}
        if file:
            data = file.read_bytes()
            headers['Content-Type'] = 'application/octet-stream'
        else:
            data = json.dumps(payload).encode('utf-8') if payload is not None else None
            if data is not None:
                headers['Content-Type'] = 'application/json'
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.build_opener(NoRedirect).open(request, timeout=600 if file else 60) as response:
            return json.load(response)

    def tag_commit(self, tag):
        require(TAG.fullmatch(tag), 'Invalid release tag')
        ref = self.request('git/ref/tags/' + urllib.parse.quote(tag, safe=''))['object']
        for _ in range(5):
            if ref['type'] == 'commit':
                require(SHA.fullmatch(ref['sha']), 'Invalid remote tag commit')
                return ref['sha']
            require(ref['type'] == 'tag' and SHA.fullmatch(ref['sha']), 'Invalid remote tag')
            ref = self.request('git/tags/' + ref['sha'])['object']
        raise ValueError('Tag nesting limit exceeded')


def verified_artifact(api, run_id, tag_source):
    require(re.fullmatch(r'[1-9][0-9]*', run_id), 'Invalid artifact run ID')
    run = api.request(f'actions/runs/{run_id}')
    source = run.get('head_sha', '')
    require(SHA.fullmatch(source) and run.get('id') == int(run_id) and
            run.get('repository', {}).get('full_name') == REPOSITORY and
            run.get('head_repository', {}).get('full_name') == REPOSITORY and
            type(run['repository'].get('id')) is int and run['repository']['id'] > 0 and
            run['head_repository'].get('id') == run['repository']['id'] and
            run.get('path') == '.github/workflows/ohos.yml' and
            run.get('name') == 'HarmonyOS adaptation' and run.get('head_branch') == 'ohos' and
            run.get('event') in ('push', 'workflow_dispatch') and
            run.get('status') == 'completed' and run.get('conclusion') == 'success',
            'Expected successful official ohos build')
    jobs = api.request(f'actions/runs/{run_id}/jobs?filter=latest&per_page=100')
    require(jobs.get('total_count') == len(jobs.get('jobs', [])) == 2 and
            {j.get('name') for j in jobs['jobs']} == {'quality', 'build'}, 'Incomplete OHOS checks')
    require(all(j.get('run_id') == int(run_id) and j.get('head_sha') == source and
                j.get('run_attempt') == run.get('run_attempt') and
                j.get('status') == 'completed' and j.get('conclusion') == 'success'
                for j in jobs['jobs']), 'OHOS prerequisite failed or provenance differs')
    artifacts = api.request(f'actions/runs/{run_id}/artifacts?per_page=100')
    require(artifacts.get('total_count') == len(artifacts.get('artifacts', [])), 'Incomplete artifact listing')
    rows = [a for a in artifacts['artifacts'] if a.get('name') == 'tsukuyomi-space-ohos-unsigned']
    require(len(rows) == 1, 'Expected one OHOS artifact')
    artifact = rows[0]
    owner = artifact.get('workflow_run', {})
    require(type(artifact.get('id')) is int and artifact['id'] > 0 and
            artifact.get('expired') is False and artifact.get('size_in_bytes', 0) > 1024 and
            re.fullmatch(r'sha256:[0-9a-f]{64}', artifact.get('digest', '')) and
            owner.get('id') == int(run_id) and owner.get('head_sha') == source and
            owner.get('head_branch') == 'ohos' and
            owner.get('repository_id') == run['repository'].get('id') and
            owner.get('head_repository_id') == run['head_repository'].get('id'),
            'Artifact provenance differs')
    expires = datetime.fromisoformat(artifact.get('expires_at', '').replace('Z', '+00:00'))
    require(expires.tzinfo is not None and expires > datetime.now(timezone.utc), 'Artifact expired')
    require(version_at(source) == version_at(tag_source), 'Artifact source version differs from release')
    return {'ref': source, 'artifact_id': str(artifact['id']), 'run_id': run_id}


def resolve(api, event_name, event, input_tag='', input_run_id=''):
    """Only successful first-party release runs or an explicit tag may build."""
    require(event.get('repository', {}).get('full_name') == REPOSITORY, 'Foreign repository')
    require(not input_run_id or event_name == 'workflow_dispatch', 'Artifact reuse requires explicit dispatch')
    run_source = None
    if event_name == 'workflow_run':
        run = event['workflow_run']
        require(run.get('name') == 'Release installers' and
                run.get('path') == '.github/workflows/release.yml' and
                run.get('conclusion') == 'success' and run.get('status') == 'completed' and
                run.get('head_repository', {}).get('full_name') == REPOSITORY and
                run.get('event') in ('push', 'workflow_dispatch'), 'Untrusted source run')
        run_source = run['head_sha']
        require(SHA.fullmatch(run_source), 'Invalid run source')
        text = git('show', f'{run_source}:lib/core/app_release.dart')
        match = re.search(r"const appReleaseTag = '([^']+)';", text)
        require(match, 'Source has no release identity')
        tag = match[1]
    else:
        require(event_name == 'workflow_dispatch', 'Unsupported release event')
        tag = input_tag
    require(TAG.fullmatch(tag), 'Invalid release tag')
    try:
        release = api.request('releases/tags/' + urllib.parse.quote(tag, safe=''))
    except urllib.error.HTTPError as error:
        if event_name == 'workflow_run' and error.code == 404:
            return {'ready': 'false'}  # A successful build-only run has no release.
        raise
    if event_name == 'workflow_run' and release.get('draft'):
        return {'ready': 'false'}
    require(release.get('tag_name') == tag and release.get('draft') is False,
            'An existing published release is required')
    source = api.tag_commit(tag)
    require(run_source is None or run_source == source, 'Release tag differs from source run')
    require(git('rev-parse', f'refs/tags/{tag}^{{commit}}') == source, 'Local tag differs')
    version, _ = version_at(source)
    require(TAG.fullmatch(tag)[1] == version, 'Release version differs from source')
    if input_run_id:
        return {'ready': 'true', 'tag': tag, **verified_artifact(api, input_run_id, source)}
    # Historical tags before the port cannot produce a HAP. Their one-time
    # supplemental builds must record their actual source, never rewrite tags.
    git('cat-file', '-e', f'{source}:tool/ohos/build.py')
    return {'ready': 'true', 'ref': source, 'tag': tag}


def prepare(artifact, output, tag, source):
    require(TAG.fullmatch(tag) and SHA.fullmatch(source), 'Invalid release identity')
    release_commit = git('rev-parse', f'refs/tags/{tag}^{{commit}}')
    version, build_number = version_at(release_commit)
    require(TAG.fullmatch(tag)[1] == version and version_at(source) == (version, build_number),
            'HAP source version/build differs from the release')
    info = json.loads((artifact / 'build-info.json').read_text(encoding='utf-8'))
    name = f'tsukuyomi-space-{version}-{build_number}-ohos-arm64-unsigned.hap'
    require(info.get('source') == source and info.get('file') == name and
            info.get('signed') is False, 'HAP provenance differs')
    hap = artifact / name
    require(not hap.is_symlink() and digest(hap) == info['sha256'], 'HAP checksum differs')
    require((artifact / 'SHA256SUMS').read_text(encoding='utf-8').strip() ==
            f"{info['sha256']}  {name}", 'Artifact checksum manifest differs')
    validate_hap(hap, require_studio_motion=tuple(map(int, version.split('.'))) >= (0, 6, 33))
    with zipfile.ZipFile(hap) as archive:
        app = json.loads(archive.read('module.json'))['app']
        require(app.get('versionName') == version and app.get('versionCode') == build_number and
                app.get('bundleName') == 'space.tsukuyomi.tsukuyomi_space_app' and
                app.get('buildMode') == 'release' and app.get('debug') is False and
                app.get('minAPIVersion') == 60002022, 'HAP app identity or minimum SDK differs')
    require(not output.exists() or not any(output.iterdir()), 'Output folder must be empty')
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(hap, output / name)
    shutil.copyfile(artifact / 'THIRD_PARTY_NOTICES.md', output / 'OHOS-THIRD-PARTY-NOTICES.md')
    info.update(release_tag=tag, release_commit=release_commit, version=version,
                build_number=build_number, minimum_os='HarmonyOS 6.0.2 / API 22',
                architecture='arm64', compile_sdk=app.get('compileSdkVersion'))
    (output / 'OHOS-BUILD-INFO.json').write_text(json.dumps(info, indent=2) + '\n', encoding='utf-8')
    guide = f'''# 月读空间 {version}+{build_number} 鸿蒙安装说明

适用 HarmonyOS 6.0.2（API 22）及以上的 ARM64 设备，下载 `{name}`。
这是 **未签名 HAP**，不能像 Android APK 一样点击直接安装，也不适用于 Android 或旧版兼容 Android 的系统。

1. 在电脑安装华为 DevEco Studio，登录开发者账号并连接自己的鸿蒙设备。
2. 在 Signing Configs 中为包名 `space.tsukuyomi.tsukuyomi_space_app` 配置开发签名；证书和 profile 必须匹配包名并包含目标设备。
3. 使用 DevEco Studio 的 HAP 签名工具或 SDK 的 hap-sign-tool，给下载的 unsigned HAP 签名。
4. 启用设备开发者模式与 USB 调试，通过 `hdc install <签名后的.hap>` 安装。

后续覆盖安装需要相同包名、签名身份与兼容版本号；不要为了更新而卸载已有应用，卸载会清除本地数据。
当前没有 HAP 应用内安装器。普通用户若尚无开发证书，需要等待签名发行版。
签名说明：[DevEco Studio 自动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto)。

校验下载文件请使用 `OHOS-SHA256SUMS.txt`；构建来源见 `OHOS-BUILD-INFO.json`，许可及贡献者见 `OHOS-THIRD-PARTY-NOTICES.md`。
发行 tag `{tag}` 指向 `{release_commit}`；HAP 实际构建源码为 `{source}`。
两者版本均为 {version}+{build_number}；历史版本补包不移动既有 tag。
官方已验证构建及包完整性，尚未完成鸿蒙真机安装、输入法、音频、游戏或 Live2D 性能验收。
不含桌面 Agent；QQ 快捷授权回调暂不支持，使用密码或邮箱登录。
感谢 [HelloZeroNick](https://github.com/HelloZeroNick/tsukuyomi-space-app/tree/ohos) 贡献鸿蒙移植。
'''
    (output / 'OHOS-INSTALL.md').write_text(guide, encoding='utf-8')
    names = sorted(path.name for path in output.iterdir())
    (output / CHECKSUMS).write_text(''.join(f'{digest(output / name)}  {name}\n' for name in names), encoding='utf-8')
    return info


def release_files(output, tag):
    info = json.loads((output / 'OHOS-BUILD-INFO.json').read_text(encoding='utf-8'))
    require(TAG.fullmatch(tag) and info.get('release_tag') == tag and
            SHA.fullmatch(info.get('source', '')) and SHA.fullmatch(info.get('release_commit', '')),
            'Release manifest identity differs')
    name = f"tsukuyomi-space-{info['version']}-{info['build_number']}-ohos-arm64-unsigned.hap"
    require(info.get('file') == name and TAG.fullmatch(tag)[1] == info['version'] and
            info.get('signed') is False, 'Release HAP identity differs')
    expected = {name, 'OHOS-INSTALL.md', 'OHOS-BUILD-INFO.json', 'OHOS-THIRD-PARTY-NOTICES.md'}
    hashes = {}
    for line in (output / CHECKSUMS).read_text(encoding='utf-8').splitlines():
        value, filename = line.split('  ', 1)
        require(filename in expected and filename not in hashes and re.fullmatch(r'[0-9a-f]{64}', value),
                'Invalid checksum manifest')
        hashes[filename] = value
    require(set(hashes) == expected and {path.name for path in output.iterdir()} == expected | {CHECKSUMS},
            'Incomplete or mixed HAP release files')
    for filename, value in hashes.items():
        path = output / filename
        require(not path.is_symlink() and path.stat().st_size > 0 and digest(path) == value,
                f'Checksum differs: {filename}')
    require(hashes[name] == info.get('sha256'), 'HAP provenance digest differs')
    validate_hap(output / name)
    hashes[CHECKSUMS] = digest(output / CHECKSUMS)
    return info, hashes


def note(body, tag, filename):
    require(body.count(BEGIN) == body.count(END) and body.count(BEGIN) <= 1,
            'Ambiguous existing HarmonyOS release note')
    section = f'''{BEGIN}
鸿蒙补包：[{filename}](https://github.com/{REPOSITORY}/releases/download/{tag}/{filename})，适用于 HarmonyOS 6.0.2 / API 22 及以上 ARM64 设备。**未签名，须自行签名后安装**；步骤与校验见 Release 附件 `OHOS-INSTALL.md`、`OHOS-SHA256SUMS.txt`。感谢 [HelloZeroNick](https://github.com/HelloZeroNick/tsukuyomi-space-app/tree/ohos) 贡献移植。
{END}'''
    if BEGIN in body:
        require(body.index(BEGIN) < body.index(END), 'Reversed HarmonyOS release markers')
        return body[:body.index(BEGIN)] + section + body[body.index(END) + len(END):]
    return body.rstrip() + '\n\n' + section + '\n'


def publish(api, output, tag):
    info, hashes = release_files(output, tag)
    require(api.tag_commit(tag) == info['release_commit'], 'Remote release tag moved')
    release = api.request('releases/tags/' + urllib.parse.quote(tag, safe=''))
    require(release.get('tag_name') == tag and release.get('draft') is False,
            'Expected existing published release')
    release_id = release['id']
    require(type(release_id) is int and release_id > 0, 'Invalid release ID')
    path = f'releases/{release_id}'
    before = {asset['name']: asset for asset in release['assets']}
    require(len(before) == len(release['assets']), 'Duplicate remote assets')

    def matches(asset, filename):
        return (asset.get('state') == 'uploaded' and
                asset.get('size') == (output / filename).stat().st_size and
                asset.get('digest') == 'sha256:' + hashes[filename])

    # Validate every collision before writing anything. Never delete or clobber.
    for filename in hashes:
        require(filename not in before or matches(before[filename], filename),
                f'Existing release asset differs; preserved: {filename}')
    updated_body = note(release.get('body') or '', tag, info['file'])
    for filename in hashes:
        if filename not in before:
            asset = api.request(path + '/assets?name=' + urllib.parse.quote(filename, safe=''),
                                'POST', file=output / filename)
            require(matches(asset, filename), f'Uploaded asset digest differs: {filename}')
    after = api.request(path)
    assets = {asset['name']: asset for asset in after['assets']}
    require(len(assets) == len(after['assets']) and all(name in assets and matches(assets[name], name)
            for name in hashes), 'Remote HAP downloads incomplete')
    for name, original in before.items():
        require(name in assets and all(assets[name].get(key) == original.get(key)
                for key in ('id', 'size', 'digest')), f'Existing asset changed: {name}')
    require(after.get('body') == release.get('body'), 'Release notes changed concurrently; rerun to preserve edits')
    require(api.tag_commit(tag) == info['release_commit'], 'Remote release tag moved during upload')
    if after.get('body') != updated_body:
        api.request(path, 'PATCH', payload={'body': updated_body})
    print(f'Verified {len(hashes)} HarmonyOS downloads: {release["html_url"]}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('resolve', 'prepare', 'publish'))
    parser.add_argument('--artifact', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    tag = os.environ.get('RELEASE_TAG', '')
    if args.command == 'prepare':
        require(args.artifact is not None and args.output is not None, 'Artifact and output folders required')
        info = prepare(args.artifact, args.output, tag, os.environ.get('SOURCE_SHA', ''))
        print(f"Prepared {info['file']} ({info['sha256']})")
    else:
        api = GitHub(os.environ.get('GH_TOKEN', ''))
        if args.command == 'publish':
            require(args.output is not None, 'Output folder required')
            publish(api, args.output, tag)
        else:
            event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
            values = resolve(api, os.environ['GITHUB_EVENT_NAME'], event,
                             os.environ.get('INPUT_TAG', ''), os.environ.get('INPUT_RUN_ID', ''))
            with Path(os.environ['GITHUB_OUTPUT']).open('a', encoding='utf-8') as handle:
                for key, value in values.items():
                    handle.write(f'{key}={value}\n')
            print(json.dumps(values))


if __name__ == '__main__':
    main()
