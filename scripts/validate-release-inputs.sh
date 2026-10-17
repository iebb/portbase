#!/bin/sh
set -eu

repository_path="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repository_path"

# Build the committed project and lockfile; do not regenerate or upgrade packages.
test -s PortSQL.xcodeproj/project.pbxproj
test -s PortSQL.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
test -s Packages/mysql-nio/Package.swift
test -s PortSQL/PortSQL-Bridging-Header.h
/usr/bin/plutil -lint PortSQL.xcodeproj/project.pbxproj >/dev/null
/usr/bin/plutil -lint PortSQL/PortSQL.entitlements PortbaseMac/PortbaseMac.entitlements >/dev/null
find PortSQL -type f \( -name '*.strings' -o -name '*.stringsdict' \) \
    -exec /usr/bin/plutil -lint {} + >/dev/null

echo 'Portbase project, pinned packages, entitlements, and localization catalogs are ready.'
