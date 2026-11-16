#!/bin/sh
set -eu

tool_root="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(cd -- "$tool_root/.." && pwd)"
output_directory="${NORMAN_MACOS_OUTPUT_DIR:-$project_root/output}"
version="${NORMAN_MACOS_VERSION:-1.4.10}"
helper_version="${NORMAN_CM_HELPER_VERSION:-1.3.0}"
helper_pkg_name="NormanRemoteDesktop-CMHelper-$helper_version.pkg"
app_path="${NORMAN_MACOS_APP_PATH:-$output_directory/NormanRemoteDesktop.app}"
pkg_path="${NORMAN_CM_HELPER_PKG_PATH:-$output_directory/$helper_pkg_name}"
dmg_path="${NORMAN_MACOS_DMG_PATH:-$output_directory/NormanRemoteDesktop-macOS-$version.dmg}"

fail() {
  echo "error: $*" >&2
  exit 2
}

find_identity() {
  pattern="$1"
  /usr/bin/security find-identity -v 2>/dev/null |
    /usr/bin/awk -v pat="$pattern" 'index($0, pat) {sub(/^.*"/, ""); sub(/"$/, ""); print; exit}'
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing tool: $1"
}

require_tool /usr/bin/codesign
require_tool /usr/sbin/spctl
require_tool /usr/bin/xcrun

developer_id_application="${NORMAN_DEVELOPER_ID_APPLICATION:-$(find_identity "Developer ID Application")}"
developer_id_installer="${NORMAN_DEVELOPER_ID_INSTALLER:-$(find_identity "Developer ID Installer")}"

[ -n "$developer_id_application" ] ||
  fail "no Developer ID Application identity found. Set NORMAN_DEVELOPER_ID_APPLICATION or import the certificate."
[ -n "$developer_id_installer" ] ||
  fail "no Developer ID Installer identity found. Set NORMAN_DEVELOPER_ID_INSTALLER or import the certificate."

[ -d "$app_path" ] || fail "missing app: $app_path"
[ -f "$app_path/Contents/Info.plist" ] || fail "missing app Info.plist: $app_path"

bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist" 2>/dev/null || true)
[ "$bundle_identifier" = "com.carriez.NormanRemoteDesktop" ] ||
  fail "expected bundle id com.carriez.NormanRemoteDesktop; found $bundle_identifier"
[ "$bundle_version" = "$version" ] ||
  fail "expected app version $version; found $bundle_version"

echo "Signing app with: $developer_id_application"
/usr/bin/codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --sign "$developer_id_application" \
  "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

echo "Rebuilding signed CM Helper pkg with: $developer_id_installer"
NORMAN_RUSTDESK_APP_PATH="$app_path" \
NORMAN_INSTALLER_SIGNING_IDENTITY="$developer_id_installer" \
  "$tool_root/build-rustdesk-cm-helper-pkg.sh"
/usr/sbin/pkgutil --check-signature "$pkg_path"

echo "Rebuilding signed DMG with: $developer_id_application"
NORMAN_MACOS_APP_PATH="$app_path" \
NORMAN_CM_HELPER_PKG_PATH="$pkg_path" \
NORMAN_APP_SIGNING_IDENTITY="$developer_id_application" \
NORMAN_INSTALLER_SIGNING_IDENTITY="$developer_id_installer" \
NORMAN_DMG_SIGNING_IDENTITY="$developer_id_application" \
  "$tool_root/package-macos-distribution.sh"
/usr/bin/codesign --verify --verbose=2 "$dmg_path"

notary_profile="${NORMAN_NOTARY_PROFILE:-}"
if [ -n "$notary_profile" ]; then
  notary_mode="profile"
elif [ -n "${NORMAN_NOTARY_APPLE_ID:-}" ] &&
    [ -n "${NORMAN_NOTARY_TEAM_ID:-}" ] &&
    [ -n "${NORMAN_NOTARY_PASSWORD:-}" ]; then
  notary_mode="credentials"
else
  echo "Notarization credentials were not provided; signed artifacts were produced but not notarized." >&2
  echo "Set NORMAN_NOTARY_PROFILE, or NORMAN_NOTARY_APPLE_ID/NORMAN_NOTARY_TEAM_ID/NORMAN_NOTARY_PASSWORD, then rerun." >&2
  exit 3
fi

echo "Submitting DMG for notarization..."
if [ "$notary_mode" = "profile" ]; then
  /usr/bin/xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
else
  /usr/bin/xcrun notarytool submit "$dmg_path" \
    --apple-id "$NORMAN_NOTARY_APPLE_ID" \
    --team-id "$NORMAN_NOTARY_TEAM_ID" \
    --password "$NORMAN_NOTARY_PASSWORD" \
    --wait
fi
/usr/bin/xcrun stapler staple "$dmg_path"
/usr/bin/xcrun stapler validate "$dmg_path"
/usr/sbin/spctl --assess --type open --context context:primary-signature -vv "$dmg_path"
/usr/bin/shasum -a 256 "$pkg_path" "$dmg_path"

echo "Signed and notarized $dmg_path"
