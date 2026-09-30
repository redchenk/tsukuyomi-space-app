#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import subprocess
from metadata import read_version
root = Path(__file__).resolve().parents[2]
version = os.environ.get('APP_VERSION', read_version()[0])
assert version == read_version()[0], 'Package version must match pubspec.yaml'
dist = root / 'dist'
dist.mkdir(exist_ok=True)
pkg = root / 'build/deb'
bundle = root / 'build/linux/x64/release/bundle'
if pkg.exists():
    shutil.rmtree(pkg)
libraries = [bundle / 'tsukuyomi_space_app', *list((bundle / 'lib').glob('*.so*'))]
assert libraries[0].is_file(), 'Release executable is missing'
dependency_env = os.environ.copy()
dependency_env['LD_LIBRARY_PATH'] = str(bundle / 'lib')
for binary in libraries:
    result = subprocess.run(['ldd', str(binary)], check=True, capture_output=True, text=True,
                            env=dependency_env)
    assert 'not found' not in result.stdout, f'Native dependency missing for {binary}:\n{result.stdout}'
metadata = root / 'build/deb-metadata'
(metadata / 'debian').mkdir(parents=True, exist_ok=True)
(metadata / 'debian/control').write_text('''Source: tsukuyomi-space
Section: utils
Priority: optional
Maintainer: Tsukuyomi Space <codex@users.noreply.github.com>

Package: tsukuyomi-space
Architecture: amd64
Depends: ${shlibs:Depends}
Description: Tsukuyomi Space native client
''')
dependency_result = subprocess.check_output(
    ['dpkg-shlibdeps', '--ignore-missing-info', '--warnings=0', '-O',
     f'-l{bundle / "lib"}', *[f'-e{binary}' for binary in libraries]],
    cwd=metadata, text=True)
linked_dependencies = dependency_result.strip().removeprefix('shlibs:Depends=')
assert linked_dependencies and linked_dependencies != dependency_result.strip(), 'Cannot determine native runtime dependencies'
# GStreamer loads codec plugins dynamically, so ELF inspection cannot infer these.
dependencies = linked_dependencies + ', gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-libav'
app = pkg / 'opt/tsukuyomi-space'
shutil.copytree(bundle, app, dirs_exist_ok=True)
shutil.copyfile(root / 'THIRD_PARTY_NOTICES.md', app / 'THIRD_PARTY_NOTICES.md')
shutil.copyfile(root / 'docs/release-guide.md', app / 'release-guide.md')
(pkg / 'DEBIAN').mkdir(parents=True, exist_ok=True)
(pkg / 'DEBIAN/control').write_text(f'''Package: tsukuyomi-space
Version: {version}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Tsukuyomi Space <codex@users.noreply.github.com>
Depends: {dependencies}
Recommends: gnome-keyring, fonts-noto-cjk
Description: Tsukuyomi Space native site and Live2D client
 Native articles, wiki, gallery, game, account and Live2D room.
''')
applications = pkg / 'usr/share/applications'
applications.mkdir(parents=True, exist_ok=True)
(applications / 'tsukuyomi-space.desktop').write_text('''[Desktop Entry]
Name=Tsukuyomi Space
Name[zh_CN]=月读空间
Comment=Live2D companion with OpenAI-compatible chat and voice
Exec=/opt/tsukuyomi-space/tsukuyomi_space_app
Icon=tsukuyomi-space
Terminal=false
Type=Application
Categories=Utility;Network;
StartupWMClass=space.tsukuyomi.tsukuyomi_space_app
''')
icons = pkg / 'usr/share/icons/hicolor/256x256/apps'
icons.mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / 'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png', icons / 'tsukuyomi-space.png')
subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(pkg), str(dist / f'tsukuyomi-space-{version}-linux-x64.deb')], check=True)
subprocess.run(['tar', '-czf', str(dist / f'tsukuyomi-space-{version}-linux-x64.tar.gz'), '-C', str(pkg / 'opt'), 'tsukuyomi-space'], check=True)
