#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import subprocess
root = Path(__file__).resolve().parents[2]
version = os.environ.get('APP_VERSION', '0.2.0')
dist = root / 'dist'
dist.mkdir(exist_ok=True)
pkg = root / 'build/deb'
bundle = root / 'build/linux/x64/release/bundle'
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
Depends: libgtk-3-0, libsecret-1-0, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-libav, libstdc++6, libgl1, libayatana-appindicator3-1
Recommends: gnome-keyring, fonts-noto-cjk
Description: Tsukuyomi Space native Live2D chat client
 OpenAI-compatible LLM and TTS with local secure key storage.
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
