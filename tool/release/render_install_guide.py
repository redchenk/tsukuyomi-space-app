#!/usr/bin/env python3
"""Keep the distributed installation title and DEB command on pubspec's version."""
import argparse
from pathlib import Path
import re

from metadata import ROOT, read_version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/INSTALL.md')
    args = parser.parse_args()
    version, _ = read_version()
    text = (ROOT / 'docs/release-guide.md').read_text(encoding='utf-8')
    text, titles = re.subn(r'^(# 月读空间 )\d+\.\d+\.\d+( 测试版)$',
                          lambda m: m[1] + version + m[2], text, flags=re.M)
    text, commands = re.subn(r'(tsukuyomi-space-)\d+\.\d+\.\d+(-linux-x64\.deb)',
                            lambda m: m[1] + version + m[2], text)
    if titles != 1 or commands != 1:
        raise ValueError('Installation guide must have one versioned title and DEB command')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text, encoding='utf-8')
    print(f'Installation guide rendered for {version}')


if __name__ == '__main__':
    main()
