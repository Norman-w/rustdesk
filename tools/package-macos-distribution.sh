#!/bin/sh
set -eu

tool_root="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(cd -- "$tool_root/.." && pwd)"
output_directory="${NORMAN_MACOS_OUTPUT_DIR:-$project_root/output}"
version="${NORMAN_MACOS_VERSION:-1.5.4}"
helper_version="${NORMAN_CM_HELPER_VERSION:-1.3.0}"
helper_pkg_name="NormanRemoteDesktop-CMHelper-$helper_version.pkg"
microphone_pkg_name="NormanRemoteDesktop-CMHelper-Microphone-$helper_version.pkg"
audio_output_pkg_name="NormanRemoteDesktop-CMHelper-AudioOutput-$helper_version.pkg"
application_pkg_name="NormanRemoteDesktop-$version-application.pkg"
installer_pkg_name="NormanRemoteDesktop-$version.pkg"
app_path="${NORMAN_MACOS_APP_PATH:-$output_directory/NormanRemoteDesktop.app}"
helper_pkg_path="${NORMAN_CM_HELPER_PKG_PATH:-$output_directory/$helper_pkg_name}"
microphone_pkg_path="$output_directory/$microphone_pkg_name"
audio_output_pkg_path="$output_directory/$audio_output_pkg_name"
installer_pkg_path="$output_directory/$installer_pkg_name"
volume_name="NormanRemoteDesktop-$version"
staging_path="$output_directory/NormanRemoteDesktop-macOS-$version-staging"
dmg_path="$output_directory/NormanRemoteDesktop-macOS-$version.dmg"
readme_path="$staging_path/README.txt"
checksums_path="$staging_path/SHA256SUMS.txt"
installer_scripts_source="$tool_root/macos-installer"
installer_resources="$tool_root/rustdesk-cm-helper/installer-resources"

fail() {
  echo "error: $*" >&2
  exit 2
}

warn() {
  echo "warning: $*" >&2
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

bundle_sodium_dependency() {
  target_app="$1"
  frameworks_dir="$target_app/Contents/Frameworks"
  sodium_dependency=""
  for binary in \
    "$target_app/Contents/MacOS/NormanRemoteDesktop" \
    "$target_app/Contents/MacOS/service" \
    "$frameworks_dir/liblibrustdesk.dylib"; do
    [ -e "$binary" ] || continue
    candidate=$(/usr/bin/otool -L "$binary" 2>/dev/null |
      /usr/bin/awk '/\/(opt\/homebrew|usr\/local)\/opt\/libsodium\/lib\/libsodium.*\.dylib/ { print $1; exit }')
    if [ -n "$candidate" ]; then
      sodium_dependency="$candidate"
      break
    fi
  done

  if [ -z "$sodium_dependency" ]; then
    # A static or already self-contained build does not need a bundled
    # libsodium dylib. Treat that as a valid packaging state.
    return 0
  fi
  require_file "$sodium_dependency"
  /bin/mkdir -p "$frameworks_dir"
  sodium_name="$(/usr/bin/basename "$sodium_dependency")"
  /bin/cp "$sodium_dependency" "$frameworks_dir/$sodium_name"
  /bin/chmod 755 "$frameworks_dir/$sodium_name"
  /usr/bin/install_name_tool -id "@rpath/$sodium_name" "$frameworks_dir/$sodium_name"

  for binary in \
    "$target_app/Contents/MacOS/NormanRemoteDesktop" \
    "$target_app/Contents/MacOS/service" \
    "$frameworks_dir/liblibrustdesk.dylib"; do
    [ -e "$binary" ] || continue
    if /usr/bin/otool -L "$binary" 2>/dev/null | /usr/bin/grep -q "$sodium_dependency"; then
      case "$binary" in
        "$target_app"/Contents/MacOS/*)
          local_dependency="@loader_path/../Frameworks/$sodium_name"
          ;;
        *)
          local_dependency="@loader_path/$sodium_name"
          ;;
      esac
      /usr/bin/install_name_tool -change "$sodium_dependency" "$local_dependency" "$binary"
    fi
  done
}

require_dir "$app_path"
require_file "$app_path/Contents/Info.plist"
require_executable "$app_path/Contents/MacOS/NormanRemoteDesktop"
require_file "$installer_scripts_source/preinstall"
require_file "$installer_scripts_source/postinstall"
require_dir "$app_path/Contents/Resources"

build_component_package() {
  component_name="$1"
  NORMAN_CM_HELPER_OUTPUT_DIR="$output_directory" \
  NORMAN_RUSTDESK_APP_PATH="$app_path" \
  NORMAN_MACOS_VERSION="$version" \
  NORMAN_CM_HELPER_VERSION="$helper_version" \
  NORMAN_CM_HELPER_COMPONENT="$component_name" \
    "$tool_root/build-rustdesk-cm-helper-pkg.sh"
}

if [ "${NORMAN_SKIP_COMPONENT_BUILD:-0}" != 1 ]; then
  build_component_package all
  build_component_package microphone
  build_component_package audio-output
fi
require_file "$helper_pkg_path"
require_file "$microphone_pkg_path"
require_file "$audio_output_pkg_path"

app_signing_identity="${NORMAN_APP_SIGNING_IDENTITY:-}"
if [ -z "$app_signing_identity" ]; then
  app_signing_identity=$(
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null |
      /usr/bin/awk -F '"' '$2 == "Norman Remote Desktop Local Code Signing" { print $2; exit }'
  )
fi
if [ -z "$app_signing_identity" ]; then
  warn "no stable Norman code-signing identity was found; falling back to an ad-hoc signature"
  app_signing_identity="-"
fi
echo "App signing identity: $app_signing_identity"

bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist" 2>/dev/null || true)
bundle_display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app_path/Contents/Info.plist" 2>/dev/null || true)

[ "$bundle_identifier" = "com.carriez.NormanRemoteDesktop" ] ||
  fail "expected bundle id com.carriez.NormanRemoteDesktop; found $bundle_identifier"
[ "$bundle_version" = "$version" ] ||
  fail "expected app version $version; found $bundle_version"
[ "$bundle_display_name" = "Norman Remote Desktop" ] ||
  fail "expected user-visible bundle name Norman Remote Desktop; found $bundle_display_name"

bundle_sodium_dependency "$app_path"

helper_signature=$(/usr/sbin/pkgutil --check-signature "$helper_pkg_path" 2>&1 || true)
embedded_helper_pkg="$app_path/Contents/Resources/$helper_pkg_name"
/bin/cp "$helper_pkg_path" "$embedded_helper_pkg"
/usr/bin/codesign --force --deep --sign "$app_signing_identity" "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path" >/dev/null

tcc_status=$("$app_path/Contents/MacOS/NormanRemoteDesktop" --tcc-status 2>/dev/null || true)
echo "$tcc_status" | /usr/bin/grep -q '"schemaVersion":1' ||
  fail "NormanRemoteDesktop --tcc-status did not return the expected JSON schema"

if [ -e "$staging_path" ]; then
  backup_path="$staging_path.prev-$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mv "$staging_path" "$backup_path"
fi
if [ -e "$dmg_path" ]; then
  backup_dmg="$dmg_path.prev-$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mv "$dmg_path" "$backup_dmg"
fi

/bin/mkdir -p "$staging_path"
/usr/bin/ditto "$app_path" "$staging_path/NormanRemoteDesktop.app"
/bin/ln -s /Applications "$staging_path/Applications"

installer_signing_identity="${NORMAN_INSTALLER_SIGNING_IDENTITY:-}"
if [ -z "$installer_signing_identity" ]; then
  installer_signing_identity=$(
    /usr/bin/security find-identity -v 2>/dev/null |
      /usr/bin/awk -F '"' '$2 ~ /^Developer ID Installer:/ { print $2; exit }'
  )
fi

installer_build_root="$(mktemp -d /tmp/norman-unified-installer.XXXXXX)"
cleanup_installer_build() {
  /bin/rm -rf "$installer_build_root"
}
trap cleanup_installer_build EXIT INT TERM

application_pkg_path="$staging_path/$application_pkg_name"
if [ -n "$installer_signing_identity" ]; then
  echo "Installer signing identity: $installer_signing_identity"
  /usr/bin/pkgbuild \
    --component "$staging_path/NormanRemoteDesktop.app" \
    --scripts "$installer_scripts_source" \
    --ownership recommended \
    --identifier com.norman.remotedesktop.application \
    --version "$version" \
    --install-location /Applications \
    --sign "$installer_signing_identity" \
    "$application_pkg_path"
else
  warn "no Developer ID Installer identity was found; the application component will be unsigned"
  /usr/bin/pkgbuild \
    --component "$staging_path/NormanRemoteDesktop.app" \
    --scripts "$installer_scripts_source" \
    --ownership recommended \
    --identifier com.norman.remotedesktop.application \
    --version "$version" \
    --install-location /Applications \
    "$application_pkg_path"
fi

/bin/cp "$microphone_pkg_path" "$staging_path/$microphone_pkg_name"
/bin/cp "$audio_output_pkg_path" "$staging_path/$audio_output_pkg_name"

finalizer_payload="$installer_build_root/finalizer-payload"
finalizer_scripts="$installer_build_root/finalizer-scripts"
/bin/mkdir -p "$finalizer_payload" "$finalizer_scripts"
/bin/cp "$installer_scripts_source/finalize-postinstall" "$finalizer_scripts/postinstall"
/bin/chmod 755 "$finalizer_scripts/postinstall"
if [ -n "$installer_signing_identity" ]; then
  /usr/bin/pkgbuild \
    --root "$finalizer_payload" \
    --scripts "$finalizer_scripts" \
    --ownership recommended \
    --identifier com.norman.remotedesktop.application.finalize \
    --version "$version" \
    --install-location / \
    --sign "$installer_signing_identity" \
    "$installer_build_root/$version-finalizer.pkg"
else
  /usr/bin/pkgbuild \
    --root "$finalizer_payload" \
    --scripts "$finalizer_scripts" \
    --ownership recommended \
    --identifier com.norman.remotedesktop.application.finalize \
    --version "$version" \
    --install-location / \
    "$installer_build_root/$version-finalizer.pkg"
fi

distribution_path="$installer_build_root/distribution.dist"
/usr/bin/sed \
  -e "s/__VERSION__/$version/g" \
  -e "s/__HELPER_VERSION__/$helper_version/g" \
  -e "s/__APP_PACKAGE__/$application_pkg_name/g" \
  -e "s/__MICROPHONE_PACKAGE__/$microphone_pkg_name/g" \
  -e "s/__AUDIO_OUTPUT_PACKAGE__/$audio_output_pkg_name/g" \
  -e "s/__FINALIZER_PACKAGE__/$version-finalizer.pkg/g" \
  "$installer_scripts_source/unified-distribution.dist" > "$distribution_path"

if [ -e "$installer_pkg_path" ]; then
  backup_installer="$installer_pkg_path.prev-$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mv "$installer_pkg_path" "$backup_installer"
fi
if [ -n "$installer_signing_identity" ]; then
  /usr/bin/productbuild \
    --distribution "$distribution_path" \
    --package-path "$staging_path" \
    --package-path "$installer_build_root" \
    --resources "$installer_resources" \
    --sign "$installer_signing_identity" \
    --timestamp \
    "$installer_pkg_path"
else
  /usr/bin/productbuild \
    --distribution "$distribution_path" \
    --package-path "$staging_path" \
    --package-path "$installer_build_root" \
    --resources "$installer_resources" \
    "$installer_pkg_path"
fi
installer_signature=$(/usr/sbin/pkgutil --check-signature "$installer_pkg_path" 2>&1 || true)
/bin/cp "$installer_pkg_path" "$staging_path/$installer_pkg_name"
/bin/rm -f "$application_pkg_path" "$staging_path/$microphone_pkg_name" "$staging_path/$audio_output_pkg_name"

/bin/cat > "$readme_path" <<README
Norman Remote Desktop $version for macOS

This disk image contains:

1. $installer_pkg_name
   This is the recommended installation path. The installer closes the old app,
   replaces the copy in Applications, and lets you choose optional components:
   Norman 手机麦克风 and Norman Remote Audio virtual output. It opens the
   management UI only after all selected components finish.

2. NormanRemoteDesktop.app
   The app is also available for manual drag-and-drop installation.

The legacy component package is embedded inside the app for repair/compatibility;
normal installation should use the single product PKG above.

Expected first-run flow:

1. Open NormanRemoteDesktop.app.
2. The app checks macOS Screen & System Audio Recording, Accessibility, and Input Monitoring permissions.
3. Use the app's permission / repair flow when prompted.
4. After the permissions are ready, the app restarts itself once so macOS applies TCC permissions to the active process.
5. The selected optional components install only their CoreAudio HAL devices and
   app-managed audio state; the app/service owns connection management and does
   not create a persistent CM LaunchAgent.
6. The mobile client can connect and receive the desktop video stream,
   keyboard/mouse control, and any selected audio features.
7. In NormanRemoteDesktop settings, choose Remote audio output:
   Computer speakers and phone keeps local playback and sends a ScreenCaptureKit
   copy to the phone. Norman Remote Audio virtual output temporarily routes Mac
   playback into the installed virtual output and restores the previous output
   when the remote audio session ends.

The CM Helper installer does not request Screen Recording, Accessibility, or Input
Monitoring. If macOS ever shows Installer in Privacy & Security during this step,
choose Later and use a package built from the current distribution scripts.

Verification notes from packaging:

- Bundle id: $bundle_identifier
- Version: $bundle_version
- TCC API status: $tcc_status
- Unified installer signature:
$installer_signature
- Helper package signature:
$helper_signature

This development build has a locally signed application. If the application
installer signature above says "Status: no signature", macOS may reject the PKG
on another Mac. Normal double-click distribution requires Developer ID
Application, Developer ID Installer, and notarization.

For production distribution, import Developer ID Application and Developer ID Installer
certificates, configure notarytool credentials, then run:

  ./tools/sign-notarize-macos-distribution.sh

That script signs the app, rebuilds the signed helper package, rebuilds the DMG,
submits the DMG to Apple's notary service, staples the ticket, and runs the final
Gatekeeper checks.
README

(
  cd "$staging_path"
  /usr/bin/shasum -a 256 "$installer_pkg_name" > "$checksums_path"
  /usr/bin/shasum -a 256 \
	    NormanRemoteDesktop.app/Contents/MacOS/NormanRemoteDesktop \
	    NormanRemoteDesktop.app/Contents/MacOS/service \
	    NormanRemoteDesktop.app/Contents/Frameworks/liblibrustdesk.dylib \
	    "NormanRemoteDesktop.app/Contents/Resources/$helper_pkg_name" >> "$checksums_path"
	  if [ -f NormanRemoteDesktop.app/Contents/Frameworks/libsodium.26.dylib ]; then
	    /usr/bin/shasum -a 256 \
	      NormanRemoteDesktop.app/Contents/Frameworks/libsodium.26.dylib >> "$checksums_path"
	  fi
)

/usr/bin/hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$staging_path" \
  -format UDZO \
  -ov \
  "$dmg_path"

if [ -n "${NORMAN_DMG_SIGNING_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --sign "$NORMAN_DMG_SIGNING_IDENTITY" "$dmg_path"
fi

/usr/bin/hdiutil verify "$dmg_path"
/usr/bin/shasum -a 256 "$dmg_path"

echo "Built $dmg_path"
echo "Staging directory: $staging_path"
