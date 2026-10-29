#!/usr/bin/env bash
# Builds GTVL's release APKs into dist/:
#   gtvl-<version>.apk              every TV (32- and 64-bit ARM)
#   gtvl-<version>-armeabi-v7a.apk  32-bit Android: most Google TV sticks and TVs,
#                                   the Chromecast with Google TV among them
#   gtvl-<version>-arm64-v8a.apk    64-bit Android: the NVIDIA Shield and newer boxes
# Google TV runs on ARM only, so there is no x86 build.
# And gtvl-update.json, which GTVL on a TV reads from the latest release to
# update itself: the version, and each split APK's name, size, SHA-256 and
# Android version code.
#
# --upload also puts them on the GitHub release v<version>, as a draft if that
# release doesn't exist yet, so nothing is public until it is published. TVs
# update from the latest published release; drafts and pre-releases they skip.
# --notes FILE: the release notes in Markdown, for GitHub; About on the TVs
# shows their bold headlines.
set -euo pipefail
cd "$(dirname "$0")/.."

upload=false
notes=
while (($#)); do
  case $1 in
    --upload) upload=true ;;
    --notes) notes=$2; shift ;;
    *) echo "Usage: tool/build.sh [--upload] [--notes FILE]" >&2; exit 2 ;;
  esac
  shift
done

# Updates must carry the same signature: never let a debug-signed build out.
[[ -f android/key.properties ]] || { echo "android/key.properties is missing; the APKs would be signed with the debug key." >&2; exit 1; }

# The version name, pre-release part included (0.2.1-alpha), and the build number after the +.
version=$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' pubspec.yaml)
build=$(sed -n 's/^version: *[^+]*+\([0-9]*\).*/\1/p' pubspec.yaml)
[[ -n $build ]] || { echo "pubspec.yaml's version needs a build number, as in 0.2.2+4." >&2; exit 1; }

if $upload; then
  # A TV takes only a higher version code: the build number must beat the latest release's.
  latest=$(curl -fsSL https://github.com/kanin-design/gtvl/releases/latest/download/gtvl-update.json 2> /dev/null |
    python3 -c 'import json, sys; print(max(f["versionCode"] for f in json.load(sys.stdin)["files"].values()) % 1000)' 2> /dev/null ||
    echo 0)
  ((build > latest)) || { echo "Build $build is not newer than the latest release's ($latest): raise it in pubspec.yaml." >&2; exit 1; }
fi

out=build/app/outputs/flutter-apk
rm -rf dist && mkdir dist

flutter build apk --release --target-platform android-arm,android-arm64
cp "$out/app-release.apk" "dist/gtvl-$version.apk"
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
cp "$out/app-armeabi-v7a-release.apk" "dist/gtvl-$version-armeabi-v7a.apk"
cp "$out/app-arm64-v8a-release.apk" "dist/gtvl-$version-arm64-v8a.apk"

# Version codes as the APKs carry them; aapt2 reads them, where the SDK has it.
aapt2=$(ls -d "$(sed -n 's/^sdk.dir=//p' android/local.properties)"/build-tools/*/aapt2 2> /dev/null | tail -1 || true)
python3 - "$version" "$build" "$notes" "$aapt2" > dist/gtvl-update.json << 'EOF'
import hashlib, json, re, subprocess, sys

version, build, notes_file, aapt2 = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
files = {}
# Flutter numbers a split APK 1000 x its ABI's number plus the build number.
for abi, base in (("arm64-v8a", 2000), ("armeabi-v7a", 1000)):
    name = f"gtvl-{version}-{abi}.apk"
    data = open(f"dist/{name}", "rb").read()
    code = base + build
    if aapt2:
        badging = subprocess.run([aapt2, "dump", "badging", f"dist/{name}"], capture_output=True, text=True).stdout
        found = re.search(r"versionCode='(\d+)'", badging)
        if found:
            code = int(found.group(1))
    files[abi] = {"name": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "versionCode": code}
notes = None
if notes_file:
    source = open(notes_file, encoding="utf-8").read()
    # For About on the TV: the bold headlines ("Updates by themselves · Rows of shows"),
    # else the text without Markdown marks or blank lines; at most 400 characters.
    heads = [head.strip().rstrip(":") for head in re.findall(r"\*\*(.+?)\*\*", source)]
    text = " · ".join(heads) if heads else re.sub(r"\n\s*\n+", "\n", re.sub(r"[*_`#>]", "", source)).strip()
    notes = text if len(text) <= 400 else text[:399].rstrip() + "…"
manifest = {"schema": 1, "app": "kanin.gtvl", "version": version, "tag": f"v{version}", "notes": notes, "files": files}
print(json.dumps(manifest, indent=2, ensure_ascii=False))
EOF
ls -lh dist
cat dist/gtvl-update.json

if $upload; then
  note_args=(--notes "Write the release notes, then publish.")
  [[ -n $notes ]] && note_args=(--notes-file "$notes")
  if gh release view "v$version" > /dev/null 2>&1; then
    gh release upload "v$version" dist/*.apk dist/gtvl-update.json --clobber
    if [[ -n $notes ]]; then gh release edit "v$version" "${note_args[@]}"; fi
  else
    gh release create "v$version" dist/*.apk dist/gtvl-update.json --draft --title "GTVL $version" "${note_args[@]}"
  fi
fi
