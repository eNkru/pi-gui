#!/bin/bash
set -euo pipefail

verify_only=0
if [[ "${1:-}" == "--verify-only" ]]; then
  verify_only=1
  shift
fi

if [[ "$#" -ne 2 ]]; then
  echo "Usage: finalize-macos-release.sh [--verify-only] <release-dir> <version>" >&2
  exit 2
fi

release_dir="$(cd "$1" && pwd)"
version="$2"

if [[ "$verify_only" -eq 0 ]]; then
  for variable in APPLE_API_KEY APPLE_API_KEY_ID APPLE_API_ISSUER; do
    if [[ -z "${!variable:-}" ]]; then
      echo "Missing required notarization credential: $variable" >&2
      exit 1
    fi
  done
  if [[ ! -f "$APPLE_API_KEY" ]]; then
    echo "APPLE_API_KEY must point to the App Store Connect API key file" >&2
    exit 1
  fi
fi

verify_app() {
  local app_path="$1"
  local expected_arch="$2"
  if [[ ! -d "$app_path" ]]; then
    echo "Missing app bundle: $app_path" >&2
    exit 1
  fi
  codesign --verify --deep --strict --verbose=4 "$app_path"
  xcrun stapler validate "$app_path"
  spctl --assess --type execute --verbose=4 "$app_path"

  local architectures
  architectures="$(lipo -archs "$app_path/Contents/MacOS/pi-gui")"
  if [[ "$architectures" != "$expected_arch" ]]; then
    echo "Expected a $expected_arch app, found: $architectures" >&2
    exit 1
  fi
}

# lipo reports Intel slices as x86_64 while archive names use the x64 label.
lipo_arch_for() {
  case "$1" in
    arm64) echo "arm64" ;;
    x64) echo "x86_64" ;;
    *) echo "Unsupported macOS architecture: $1" >&2
       exit 2 ;;
  esac
}

# electron-builder names the arm64 bundle mac-arm64 but keeps x64 at plain mac.
app_dir_for() {
  case "$1" in
    arm64) echo "mac-arm64" ;;
    x64) echo "mac" ;;
    *) echo "Unsupported macOS architecture: $1" >&2
       exit 2 ;;
  esac
}

temporary_root="$(mktemp -d)"
mount_point="$temporary_root/dmg"
zip_root="$temporary_root/zip"
mounted=0
cleanup() {
  if [[ "$mounted" -eq 1 ]]; then
    hdiutil detach "$mount_point" >/dev/null
  fi
  rm -rf "$temporary_root"
}
trap cleanup EXIT

mkdir "$mount_point" "$zip_root"

for arch in arm64 x64; do
  dmg="$release_dir/pi-gui-$version-$arch.dmg"
  zip="$release_dir/pi-gui-$version-$arch.zip"
  packaged_app="$release_dir/$(app_dir_for "$arch")/pi-gui.app"
  expected_arch="$(lipo_arch_for "$arch")"

  for artifact in "$dmg" "$zip"; do
    if [[ ! -f "$artifact" ]]; then
      echo "Missing macOS release artifact: $artifact" >&2
      exit 1
    fi
  done

  if [[ "$verify_only" -eq 0 ]]; then
    xcrun notarytool submit "$dmg" \
      --key "$APPLE_API_KEY" \
      --key-id "$APPLE_API_KEY_ID" \
      --issuer "$APPLE_API_ISSUER" \
      --wait
    xcrun stapler staple "$dmg"
  fi

  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
  hdiutil verify "$dmg"

  rm -rf "$zip_root"
  mkdir "$zip_root"
  ditto -x -k "$zip" "$zip_root"
  verify_app "$zip_root/pi-gui.app" "$expected_arch"

  hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_point"
  mounted=1
  verify_app "$mount_point/pi-gui.app" "$expected_arch"
  hdiutil detach "$mount_point" >/dev/null
  mounted=0

  if [[ "$verify_only" -eq 0 ]]; then
    verify_app "$packaged_app" "$expected_arch"
  fi
done

echo "Verified notarization, stapling, Gatekeeper, signatures, and architecture for macOS $version (arm64 + x64)"
