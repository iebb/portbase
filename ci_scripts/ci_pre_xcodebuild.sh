#!/bin/sh
set -eu

# Xcode Cloud owns provisioning, signing, build numbers, export, and upload.
# Version selection changes only the temporary clone's Cloud configuration.
if [ "${CI_XCODEBUILD_ACTION:-}" != 'archive' ]; then
    exit 0
fi
repository_path="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
cd "$repository_path"
python3 ci_scripts/select_cloud_version.py
