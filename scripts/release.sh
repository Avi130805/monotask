#!/bin/zsh
# Builds Monotask.app and zips it for a GitHub release: dist/Monotask-<version>.zip, a copy named
# Monotask.zip for the "latest release" link, and the zip's SHA-256.
set -euo pipefail
cd "${0:A:h}/.."

./scripts/build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Monotask.app/Contents/Info.plist)
mkdir -p dist
zip="dist/Monotask-$version.zip"
rm -f "$zip" dist/Monotask.zip
ditto -c -k --keepParent build/Monotask.app "$zip"
cp "$zip" dist/Monotask.zip
(cd dist && shasum -a 256 "${zip:t}" | tee "${zip:t}.sha256")
echo "Attach $zip and dist/Monotask.zip to the GitHub release v$version."
