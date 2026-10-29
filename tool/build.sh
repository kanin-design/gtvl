#!/usr/bin/env bash
# Builds GTVL's release APKs into dist/:
#   gtvl-<version>.apk              every TV (32- and 64-bit ARM)
#   gtvl-<version>-armeabi-v7a.apk  32-bit Android: most Google TV sticks and TVs,
#                                   the Chromecast with Google TV among them
#   gtvl-<version>-arm64-v8a.apk    64-bit Android: the NVIDIA Shield and newer boxes
# Google TV runs on ARM only, so there is no x86 build.
#
# --upload also puts them on the GitHub release v<version>, as a draft if that
# release doesn't exist yet, so nothing is public until it is published.
set -euo pipefail
cd "$(dirname "$0")/.."

# Updates must carry the same signature: never let a debug-signed build out.
[[ -f android/key.properties ]] || { echo "android/key.properties is missing; the APKs would be signed with the debug key." >&2; exit 1; }

# The version name, pre-release part included (0.2.1-alpha), without the build number.
version=$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' pubspec.yaml)
out=build/app/outputs/flutter-apk
rm -rf dist && mkdir dist

flutter build apk --release --target-platform android-arm,android-arm64
cp "$out/app-release.apk" "dist/gtvl-$version.apk"
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
cp "$out/app-armeabi-v7a-release.apk" "dist/gtvl-$version-armeabi-v7a.apk"
cp "$out/app-arm64-v8a-release.apk" "dist/gtvl-$version-arm64-v8a.apk"
ls -lh dist

if [[ ${1:-} == --upload ]]; then
  if gh release view "v$version" > /dev/null 2>&1; then
    gh release upload "v$version" dist/*.apk --clobber
  else
    gh release create "v$version" dist/*.apk --draft --title "GTVL $version" --notes "Write the release notes, then publish."
  fi
fi
