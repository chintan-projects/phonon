#!/bin/bash
# Build our local Speech Lab app, retaining the original verified release alongside it.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd "$script_dir/.." && pwd)
release_app=${PHONON_LAB_ENGINE_APP:-$project_dir/../verification/Phonon.app}
engine_dir=$(mktemp -d "${TMPDIR:-/tmp}/phonon-lab-engine.XXXXXX")
trap 'rm -rf "$engine_dir"' EXIT

# These are the verified 1.0 release's native Metal helpers, not model weights.
# Building them from source is also supported through scripts/build-engine.sh.
codesign --verify --deep --strict "$release_app"
mkdir -p "$engine_dir/asr"
cp "$release_app/Contents/Helpers/pe" "$release_app/Contents/Helpers/pa" "$engine_dir/"
cp "$release_app/Contents/Resources/engine/"*.metal "$engine_dir/"
cp "$release_app/Contents/Resources/asr/pa.metal" \
   "$release_app/Contents/Resources/asr/melfb.npy" "$engine_dir/asr/"
PHONON_ENGINE_DIR="$engine_dir" PHONON_REQUIRE_ENGINE=1 PHONON_CODESIGN_IDENTITY=- \
    PHONON_UV_BIN="$release_app/Contents/Helpers/uv" \
    bash "$script_dir/package-bar.sh"

app="$project_dir/bar/dist/Phonon.app"
lab=${PHONON_LAB_OUTPUT:-$project_dir/bar/dist/Murmur Lab.app}
mkdir -p "$app/Contents/Resources/docs"
cp "$project_dir/docs/subvocal-research.md" "$app/Contents/Resources/docs/"
PHONON_ICON_RENDERER="$script_dir/make-murmur-icon.swift" \
    bash "$script_dir/make-app-icon.sh" "$app/Contents/Resources/Murmur.icns"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile Murmur.icns' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.chintan.phononlab' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Murmur Lab' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Murmur Lab' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :NSMicrophoneUsageDescription Murmur Lab records speech when you start dictation or a Speech Lab experiment.' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :NSScreenCaptureUsageDescription Murmur Lab reads visible technical terms locally when screen context is enabled.' "$app/Contents/Info.plist"
# A local build must not suggest replacing itself with an official stock release.
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0.0-lab' "$app/Contents/Info.plist"
codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$project_dir/bar/Resources/Phonon.entitlements" "$app"
codesign --verify --deep --strict "$app"
if [[ -e "$lab" ]]; then
    printf 'A previous lab build exists at %s; move it aside before rebuilding.\n' "$lab" >&2
    exit 1
fi
mv "$app" "$lab"
printf 'Built %s\nQuit Phonon before opening this build; they share the single-instance lock.\n' "$lab"
