#!/bin/sh
# iCloud/FileProvider can attach Finder metadata to newly copied bundles.
# codesign rejects these two attributes; remove them only from the build product.
set -eu
case "$1" in
  */Build/Products/*.app)
    /usr/bin/xattr -r -d com.apple.FinderInfo "$1" 2>/dev/null || true
    /usr/bin/xattr -r -d com.apple.ResourceFork "$1" 2>/dev/null || true
    ;;
  *) echo 'Refusing to modify a path outside an Xcode build product.' >&2; exit 1 ;;
esac
