#!/bin/bash
# Builds the .deb from packaging/. Bump the Version field in
# packaging/DEBIAN/control before rebuilding a new release.
set -e
cd "$(dirname "$0")"
chmod 755 packaging/opt/lightning-l2/*.sh packaging/DEBIAN/postinst
find packaging -type d -exec chmod 755 {} \;
VERSION=$(grep '^Version:' packaging/DEBIAN/control | cut -d' ' -f2)
dpkg-deb --build --root-owner-group packaging "lightning-l2-launcher_${VERSION}_amd64.deb"
echo "Built lightning-l2-launcher_${VERSION}_amd64.deb"
