#!/bin/sh
set -eu

tool_root="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(cd -- "$tool_root/.." && pwd)"
rustdesk_root="$project_root"
output_directory="${NORMAN_MACOS_OUTPUT_DIR:-$project_root/output}"
version="${NORMAN_MACOS_VERSION:-1.4.10}"
helper_version="${NORMAN_CM_HELPER_VERSION:-1.3.0}"
helper_pkg_name="NormanRemoteDesktop-CMHelper-$helper_version.pkg"
app_path="${NORMAN_MACOS_APP_PATH:-$output_directory/NormanRemoteDesktop.app}"
pkg_path="${NORMAN_CM_HELPER_PKG_PATH:-$output_directory/$helper_pkg_name}"
dmg_path="${NORMAN_MACOS_DMG_PATH:-$output_directory/NormanRemoteDesktop-macOS-$version.dmg}"
strict="${NORMAN_STRICT_DISTRIBUTION:-0}"

fail() {
  echo "FAIL: $*" >&2
  exit 2
}

warn() {
  echo "WARN: $*" >&2
}

pass() {
  echo "PASS: $*"
}

require_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

require_dir() {
  [ -d "$1" ] || fail "missing directory: $1"
}

require_executable() {
  [ -x "$1" ] || fail "missing executable: $1"
}

require_dir "$app_path"
require_file "$app_path/Contents/Info.plist"
require_executable "$app_path/Contents/MacOS/NormanRemoteDesktop"
require_executable "$app_path/Contents/MacOS/service"
require_file "$app_path/Contents/Frameworks/liblibrustdesk.dylib"
require_file "$app_path/Contents/Resources/$helper_pkg_name"
require_file "$pkg_path"
require_file "$dmg_path"
if ! /usr/bin/cmp -s "$pkg_path" "$app_path/Contents/Resources/$helper_pkg_name"; then
  fail "embedded CM Helper pkg does not match the top-level helper package"
fi

postinstall_script="$tool_root/rustdesk-cm-helper/postinstall"
helper_runner_script="$tool_root/rustdesk-cm-helper/run-cm-helper.sh"
if /usr/bin/sed '/^[[:space:]]*#/d' "$postinstall_script" "$helper_runner_script" |
    /usr/bin/grep -Eq -- '--tcc-status|--repair-tcc'; then
  fail "CM Helper installation/startup path must not invoke TCC APIs"
fi
if /usr/bin/sed '/^[[:space:]]*#/d' "$postinstall_script" |
    /usr/bin/grep -Eq 'launchctl[[:space:]]+(bootstrap|kickstart|enable)'; then
  fail "component installer must not create or start a persistent CM LaunchAgent"
fi
pass "component installer does not invoke TCC APIs or create a CM LaunchAgent"

bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)
bundle_display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app_path/Contents/Info.plist" 2>/dev/null || true)
bundle_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist" 2>/dev/null || true)
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist" 2>/dev/null || true)

[ "$bundle_identifier" = "com.carriez.NormanRemoteDesktop" ] ||
  fail "expected bundle id com.carriez.NormanRemoteDesktop; found $bundle_identifier"
[ "$bundle_display_name" = "Norman Remote Desktop" ] ||
  fail "expected user-visible bundle name Norman Remote Desktop; found $bundle_display_name"
[ "$bundle_executable" = "NormanRemoteDesktop" ] ||
  fail "expected executable NormanRemoteDesktop; found $bundle_executable"
[ "$bundle_version" = "$version" ] ||
  fail "expected version $version; found $bundle_version"
pass "app identity is NormanRemoteDesktop $version ($bundle_identifier)"

daemon_plist="$rustdesk_root/src/platform/privileges_scripts/daemon.plist"
require_file "$daemon_plist"
if ! /usr/bin/grep -q '<string>com.carriez.NormanRemoteDesktop_service</string>' "$daemon_plist" ||
    ! /usr/bin/grep -q '<string>/Applications/NormanRemoteDesktop.app/Contents/MacOS/service</string>' "$daemon_plist"; then
  fail "launch daemon must use the Norman label and the dedicated Contents/MacOS/service binary"
fi
pass "launch daemon uses the dedicated service binary"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path" >/dev/null 2>&1
app_signature=$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1 || true)
if echo "$app_signature" | /usr/bin/grep -q 'Signature=adhoc'; then
  fail "app uses an ad-hoc signature; rebuild with Norman Remote Desktop Local Code Signing or Developer ID"
fi
pass "app codesign verifies with a stable identity"

dependency_scan=$(
  for binary in \
    "$app_path/Contents/MacOS/NormanRemoteDesktop" \
    "$app_path/Contents/MacOS/service" \
    "$app_path/Contents/Frameworks/liblibrustdesk.dylib" \
    "$app_path/Contents/Frameworks/libsodium.26.dylib"; do
    [ -f "$binary" ] || continue
    /usr/bin/otool -L "$binary" 2>/dev/null |
      /usr/bin/awk -v binary="$binary" '
        /^[[:space:]]*\/.*(\/opt\/homebrew|\/usr\/local|\/Users\/norman|vcpkg)/ {
          print binary ": " $1
        }'
  done
)
[ -z "$dependency_scan" ] || fail "non-portable local dylib dependencies remain:
$dependency_scan"
pass "app Mach-O dependencies are portable"

tcc_status=$("$app_path/Contents/MacOS/NormanRemoteDesktop" --tcc-status 2>/dev/null || true)
echo "$tcc_status" | /usr/bin/grep -q '"schemaVersion":1' ||
  fail "--tcc-status did not return schemaVersion 1 JSON"
pass "TCC public status API responds: $tcc_status"
# Build validation is not permission repair or end-to-end remote acceptance.
# The user-facing setup guide owns requests and any required restart.

pkg_signature=$(/usr/sbin/pkgutil --check-signature "$pkg_path" 2>&1 || true)
if echo "$pkg_signature" | /usr/bin/grep -Eq 'Status: signed|Developer ID Installer'; then
  pass "helper pkg is signed"
else
  if [ "$strict" = "1" ]; then
    fail "helper pkg is not Developer ID signed"
  fi
  warn "helper pkg is not Developer ID signed in this local build"
fi

/usr/bin/hdiutil verify "$dmg_path" >/dev/null
pass "DMG verifies"

spctl_app=$(/usr/sbin/spctl --assess --type execute -vv "$app_path" 2>&1 || true)
if echo "$spctl_app" | /usr/bin/grep -q 'accepted'; then
  pass "Gatekeeper accepts app"
else
  if [ "$strict" = "1" ]; then
    fail "Gatekeeper rejected app: $spctl_app"
  fi
  warn "Gatekeeper rejects app until Developer ID signing/notarization is done: $spctl_app"
fi

spctl_dmg=$(/usr/sbin/spctl --assess --type open --context context:primary-signature -vv "$dmg_path" 2>&1 || true)
if echo "$spctl_dmg" | /usr/bin/grep -q 'accepted'; then
  pass "Gatekeeper accepts DMG"
else
  if [ "$strict" = "1" ]; then
    fail "Gatekeeper rejected DMG: $spctl_dmg"
  fi
  warn "Gatekeeper rejects DMG until Developer ID signing/notarization is done: $spctl_dmg"
fi

scan_roots="
$tool_root/build-rustdesk-cm-helper-pkg.sh
$tool_root/rustdesk-cm-helper
$tool_root/mac-remote-mic/install-patched-rustdesk.sh
$tool_root/mac-remote-mic/repair-tcc.sh
$tool_root/mac-remote-mic/verify-norman-remote-mic.sh
$rustdesk_root/src/platform/privileges_scripts
$rustdesk_root/flutter/macos/Runner/Configs/AppInfo.xcconfig
$rustdesk_root/flutter/macos/Runner/Info.plist
"
old_identity_hits=$(/usr/bin/grep -R -n -E 'com\.carriez\.rustdesk|com\.carriez\.flutterHbb|RustDesk_server|RustDesk_service|com\.norman\.rustdesk-cm-no-ui|/Applications/RustDesk\.app' $scan_roots 2>/dev/null || true)
[ -z "$old_identity_hits" ] || fail "old RustDesk identity remains:
$old_identity_hits"
pass "old RustDesk launchd/app identity is absent from distribution paths"

private_tcc_hits=$(/usr/bin/grep -R -n -E 'TCC\.db|sqlite3 .*TCC|sync-tcc|csreq' $scan_roots 2>/dev/null || true)
[ -z "$private_tcc_hits" ] || fail "private TCC database repair remains:
$private_tcc_hits"
pass "private TCC database repair is absent from distribution paths"

if /usr/bin/grep -q 'NORMAN_RUSTDESK_FEATURES:-flutter,hwcodec' "$tool_root/build-macos-app.sh"; then
  fail "hwcodec is still enabled by default in build-macos-app.sh"
fi
pass "hwcodec is not enabled by default"

echo
echo "SHA256:"
/usr/bin/shasum -a 256 \
  "$app_path/Contents/MacOS/NormanRemoteDesktop" \
  "$app_path/Contents/MacOS/service" \
  "$app_path/Contents/Resources/$helper_pkg_name" \
  "$pkg_path" \
  "$dmg_path"

echo
echo "Current running installed NormanRemoteDesktop processes, if any:"
/usr/bin/pgrep -alf 'NormanRemoteDesktop|/Contents/MacOS/service' || true

echo
echo "Local distribution verification finished."
if [ "$strict" != "1" ]; then
  echo "Run with NORMAN_STRICT_DISTRIBUTION=1 after Developer ID signing/notarization for production release gating."
fi
