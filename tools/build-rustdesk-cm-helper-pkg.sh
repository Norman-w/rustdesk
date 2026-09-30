#!/bin/sh
set -eu

tool_root="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(cd -- "$tool_root/.." && pwd)"
output_directory="${NORMAN_CM_HELPER_OUTPUT_DIR:-$project_root/output}"
macos_version="${NORMAN_MACOS_VERSION:-1.4.11}"
package_version="${NORMAN_CM_HELPER_VERSION:-1.3.0}"
package_path="$output_directory/NormanRemoteDesktop-CMHelper-$package_version.pkg"
distribution_template="$tool_root/rustdesk-cm-helper/distribution.dist"
installer_resources="$tool_root/rustdesk-cm-helper/installer-resources"
app_path="${NORMAN_RUSTDESK_APP_PATH:-$project_root/output/NormanRemoteDesktop.app}"

driver_signing_identity="${NORMAN_CODESIGN_IDENTITY:-}"
if [ -z "$driver_signing_identity" ]; then
  driver_signing_identity=$(
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null |
      /usr/bin/awk -F '"' '$2 == "Norman Remote Desktop Local Code Signing" { print $2; exit }'
  )
fi
app_info="$app_path/Contents/Info.plist"
app_library="$app_path/Contents/Frameworks/liblibrustdesk.dylib"
app_executable=""
for candidate in \
  "$app_path/Contents/MacOS/NormanRemoteDesktop"; do
  if [ -x "$candidate" ]; then
    app_executable="$candidate"
    break
  fi
done
build_root="$(mktemp -d /tmp/norman-cm-helper-build.XXXXXX)"
component_package_path="$build_root/NormanRemoteDesktop-CMHelper-component.pkg"
distribution_path="$build_root/distribution.dist"
package_scripts="$build_root/scripts"
payload_root="$build_root/payload"
support_root="$payload_root/Library/Application Support/NormanRemoteDesktop/cm-helper-support"
virtual_input_payload="$payload_root/Library/Audio/Plug-Ins/HAL"
virtual_input_source_payload="$support_root/virtual-mic-source"

cleanup() {
  /bin/rm -rf "$build_root"
}
trap cleanup EXIT INT TERM

if [ ! -f "$app_info" ] || [ ! -x "$app_executable" ] || [ ! -f "$app_library" ]; then
  echo "NormanRemoteDesktop.app $macos_version is required at $app_path" >&2
  exit 2
fi

bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_info" 2>/dev/null || true)
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_info" 2>/dev/null || true)
if [ "$bundle_identifier" != "com.carriez.NormanRemoteDesktop" ] || [ "$bundle_version" != "$macos_version" ]; then
  echo "Expected NormanRemoteDesktop bundle com.carriez.NormanRemoteDesktop version $macos_version; found $bundle_identifier $bundle_version" >&2
  exit 2
fi
if ! { /usr/bin/strings -a "$app_executable"; /usr/bin/strings -a "$app_library"; } |
    /usr/bin/grep -q -- '--cm'; then
  echo "The installed NormanRemoteDesktop binary has no official --cm entry point" >&2
  exit 2
fi
if ! "$app_executable" --tcc-status 2>/dev/null |
    /usr/bin/grep -q '"schemaVersion":1'; then
  echo "The installed NormanRemoteDesktop app has no working --tcc-status TCC check; rebuild/install the current Norman fork first." >&2
  exit 2
fi

/bin/mkdir -p "$package_scripts" "$support_root/bin" "$virtual_input_payload" "$virtual_input_source_payload" "$output_directory"
/bin/cp "$tool_root/rustdesk-cm-helper/postinstall" "$package_scripts/postinstall"
/bin/cp "$tool_root/rustdesk-cm-helper/run-cm-helper.sh" "$support_root/run-cm-helper.sh"
/bin/cp "$tool_root/rustdesk-cm-helper/remote-mic-config.sh" "$support_root/remote-mic-config.sh"
/bin/cp "$tool_root/rustdesk-cm-helper/audio-config-default.plist" "$support_root/audio-config-default.plist"
/bin/cp "$tool_root/mac-remote-mic/repair-tcc.sh" "$support_root/repair-tcc.sh"
/bin/cp "$tool_root/mac-remote-mic/NormanRemoteMic.c" "$virtual_input_source_payload/NormanRemoteMic.c"
/bin/cp "$tool_root/mac-remote-mic/NormanRemoteMic-Info.plist" "$virtual_input_source_payload/NormanRemoteMic-Info.plist"
/bin/cp "$tool_root/mac-remote-mic/NormanRemoteAudio-Info.plist" "$virtual_input_source_payload/NormanRemoteAudio-Info.plist"
/bin/cp "$tool_root/mac-remote-mic/LICENSE-Apple-NullAudio.txt" "$virtual_input_source_payload/LICENSE-Apple-NullAudio.txt"
/bin/cp "$tool_root/mac-remote-mic/build-norman-remote-mic-driver.sh" "$virtual_input_source_payload/build-norman-remote-mic-driver.sh"
/bin/cp "$tool_root/mac-remote-mic/verify-norman-remote-mic.sh" "$virtual_input_source_payload/verify-norman-remote-mic.sh"
/bin/chmod 755 "$package_scripts/postinstall" "$support_root/run-cm-helper.sh" "$support_root/remote-mic-config.sh" \
  "$support_root/repair-tcc.sh" \
  "$virtual_input_source_payload/build-norman-remote-mic-driver.sh" \
  "$virtual_input_source_payload/verify-norman-remote-mic.sh"

if /usr/bin/sed '/^[[:space:]]*#/d' "$package_scripts/postinstall" "$support_root/run-cm-helper.sh" |
    /usr/bin/grep -Eq -- '--tcc-status|--repair-tcc'; then
  echo "The CM Helper installer/startup path must not invoke TCC APIs." >&2
  exit 2
fi

driver_build_output="$build_root/driver-output"
NORMAN_REMOTE_MIC_DRIVER_OUTPUT_DIR="$driver_build_output" \
NORMAN_CODESIGN_IDENTITY="$driver_signing_identity" \
  "$tool_root/mac-remote-mic/build-norman-remote-mic-driver.sh"
/usr/bin/ditto --norsrc "$driver_build_output/NormanRemoteMic.driver" "$virtual_input_payload/NormanRemoteMic.driver"
/usr/bin/ditto --norsrc "$driver_build_output/NormanRemoteAudio.driver" "$virtual_input_payload/NormanRemoteAudio.driver"
/bin/chmod 755 "$virtual_input_payload/NormanRemoteMic.driver/Contents/MacOS/NormanRemoteMic"
/bin/chmod 755 "$virtual_input_payload/NormanRemoteAudio.driver/Contents/MacOS/NormanRemoteAudio"

probe_source="$tool_root/mac-remote-mic/device_probe.c"
probe_arm64="$build_root/device-probe-arm64"
probe_x86_64="$build_root/device-probe-x86_64"
probe_final="$support_root/bin/norman-remote-mic-device-probe"
clang_bin="${NORMAN_CLANG:-/usr/bin/clang}"
probe_common_flags="-Wall -Wextra -framework CoreAudio -framework CoreFoundation"

if "$clang_bin" -arch arm64 $probe_common_flags "$probe_source" -o "$probe_arm64" 2>/dev/null &&
    "$clang_bin" -arch x86_64 $probe_common_flags "$probe_source" -o "$probe_x86_64" 2>/dev/null; then
  /usr/bin/lipo -create "$probe_arm64" "$probe_x86_64" -output "$probe_final"
  probe_arch="arm64+x86_64"
else
  "$clang_bin" $probe_common_flags "$probe_source" -o "$probe_final"
  probe_arch="native"
fi
/bin/chmod 755 "$probe_final"

if { /usr/bin/strings -a "$app_executable"; /usr/bin/strings -a "$app_library"; } |
    /usr/bin/grep -q -- 'NORMAN_REMOTE_MIC_OUTPUT_DEVICE' &&
    { /usr/bin/strings -a "$app_executable"; /usr/bin/strings -a "$app_library"; } |
    /usr/bin/grep -q -- 'Norman Remote Audio'; then
  echo "Detected Norman microphone and remote-audio mode support in NormanRemoteDesktop."
else
  echo "Warning: the installed NormanRemoteDesktop binary has no complete Norman audio-mode patch; the package will keep audio modes disabled until a patched binary is supplied." >&2
fi

if [ -n "${NORMAN_INSTALLER_SIGNING_IDENTITY:-}" ]; then
  /usr/bin/pkgbuild \
    --root "$payload_root" \
    --scripts "$package_scripts" \
    --ownership recommended \
    --identifier com.norman.remotedesktop.cm-helper \
    --version "$package_version" \
    --sign "$NORMAN_INSTALLER_SIGNING_IDENTITY" \
    --install-location / \
    "$component_package_path"
else
  /usr/bin/pkgbuild \
    --root "$payload_root" \
    --scripts "$package_scripts" \
    --ownership recommended \
    --identifier com.norman.remotedesktop.cm-helper \
    --version "$package_version" \
    --install-location / \
    "$component_package_path"
fi

/usr/bin/sed \
  -e "s/__VERSION__/$package_version/g" \
  -e "s/__COMPONENT_PACKAGE__/$(/usr/bin/basename "$component_package_path")/g" \
  "$distribution_template" > "$distribution_path"

if [ -n "${NORMAN_INSTALLER_SIGNING_IDENTITY:-}" ]; then
  /usr/bin/productbuild \
    --distribution "$distribution_path" \
    --package-path "$build_root" \
    --resources "$installer_resources" \
    --sign "$NORMAN_INSTALLER_SIGNING_IDENTITY" \
    --timestamp \
    "$package_path"
  package_signature="signed"
else
  /usr/bin/productbuild \
    --distribution "$distribution_path" \
    --package-path "$build_root" \
    --resources "$installer_resources" \
    "$package_path"
  package_signature="unsigned"
fi

/usr/sbin/pkgutil --check-signature "$package_path" 2>&1 || true
/usr/bin/xar -tf "$package_path" | /usr/bin/sed -n '1,60p'
/usr/bin/shasum -a 256 "$package_path"
echo "Probe architecture: $probe_arch"
echo "Driver signing identity: ${driver_signing_identity:-unsigned}"
echo "Package signature: $package_signature"
echo "Built $package_path"
