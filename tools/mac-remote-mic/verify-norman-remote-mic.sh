#!/bin/sh
set -u

# Read-only verification for the virtual microphone delivery. It does not
# install the HAL plug-in, restart coreaudiod, select an audio device, or
# modify the NormanRemoteDesktop app. Use --strict in a controlled post-install test.

tool_root="$(cd -- "$(dirname -- "$0")" && pwd)"
repository_driver_path="$tool_root/../../output/NormanRemoteMic.driver"
repository_probe="$tool_root/../../output/norman-remote-mic-device-probe"
installed_driver_path="/Library/Audio/Plug-Ins/HAL/NormanRemoteMic.driver"
installed_probe="$tool_root/../bin/norman-remote-mic-device-probe"
if [ -n "${NORMAN_REMOTE_MIC_DRIVER_PATH:-}" ]; then
  driver_path="$NORMAN_REMOTE_MIC_DRIVER_PATH"
elif [ -d "$repository_driver_path" ]; then
  driver_path="$repository_driver_path"
else
  driver_path="$installed_driver_path"
fi
if [ -n "${NORMAN_REMOTE_MIC_PROBE:-}" ]; then
  probe="$NORMAN_REMOTE_MIC_PROBE"
elif [ -x "$repository_probe" ]; then
  probe="$repository_probe"
else
  probe="$installed_probe"
fi
rustdesk="${NORMAN_RUSTDESK_APP_PATH:-}"
if [ -z "$rustdesk" ]; then
  for candidate in \
    "/Applications/NormanRemoteDesktop.app" \
    "/Applications/NormanRemoteDesktop-RustDesk-Test.app"; do
    if [ -f "$candidate/Contents/Info.plist" ]; then
      rustdesk="$candidate"
      break
    fi
  done
fi
strict=false
if [ "${1:-}" = "--strict" ]; then
  strict=true
fi

failures=0
warnings=0
pass() { echo "PASS: $1"; }
warn() { echo "WARN: $1"; warnings=$((warnings + 1)); }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

driver_info="$driver_path/Contents/Info.plist"
driver_executable="$driver_path/Contents/MacOS/NormanRemoteMic"
if [ ! -f "$driver_info" ] || [ ! -x "$driver_executable" ]; then
  fail "NormanRemoteMic.driver is missing or incomplete at $driver_path"
else
  if /usr/bin/plutil -lint "$driver_info" >/dev/null 2>&1; then
    pass "virtual microphone Info.plist is valid"
  else
    fail "virtual microphone Info.plist is invalid"
  fi
  driver_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$driver_info" 2>/dev/null || true)
  if [ "$driver_identifier" = "com.norman.remotedesktop.virtual-mic" ]; then
    pass "virtual microphone bundle identifier is correct"
  else
    fail "unexpected virtual microphone bundle identifier: $driver_identifier"
  fi
  if /usr/bin/codesign --verify --deep "$driver_path" >/dev/null 2>&1; then
    pass "virtual microphone bundle is code signed"
  else
    warn "virtual microphone bundle is unsigned; production installation needs Developer ID signing/notarization"
  fi
fi

if [ -x "$probe" ]; then
  probe_output=$("$probe" --check-input "Norman 手机麦克风" 2>/dev/null || true)
  if echo "$probe_output" | /usr/bin/grep -q 'found=1.*input_channels=[1-9]'; then
    pass "CoreAudio exposes Norman 手机麦克风 with an input channel"
  else
    warn "Norman 手机麦克风 input is not visible in the current CoreAudio device list; reload CoreAudio after installation"
  fi
  if echo "$probe_output" | /usr/bin/grep -q 'found=1.*output_channels=[1-9]'; then
    pass "NormanRemoteDesktop receiver output is available on the same duplex device"
  else
    warn "NormanRemoteDesktop receiver output is not available on the virtual device yet"
  fi
else
  warn "device probe is not available, so CoreAudio enumeration was not checked"
fi

rustdesk_executable=""
for candidate in \
  "$rustdesk/Contents/MacOS/NormanRemoteDesktop"; do
  if [ -x "$candidate" ]; then
    rustdesk_executable="$candidate"
    break
  fi
done
rustdesk_library="$rustdesk/Contents/Frameworks/liblibrustdesk.dylib"
if [ -x "$rustdesk_executable" ] && [ -f "$rustdesk_library" ]; then
  if { /usr/bin/strings -a "$rustdesk_executable"; /usr/bin/strings -a "$rustdesk_library"; } |
      /usr/bin/grep -q -- 'NORMAN_REMOTE_MIC_OUTPUT_DEVICE'; then
    pass "NormanRemoteDesktop contains the explicit incoming-audio output route"
  else
    warn "installed NormanRemoteDesktop does not contain the Norman receiver route; it remains speaker-only"
  fi
else
  warn "NormanRemoteDesktop 1.4.10 was not found at $rustdesk"
fi

if [ "$strict" = true ] && [ "$failures" -eq 0 ] && [ "$warnings" -gt 0 ]; then
  failures=1
fi
if [ "$failures" -gt 0 ]; then
  echo "Verification failed ($failures failure(s), $warnings warning(s))."
  exit 1
fi
echo "Verification completed ($warnings warning(s)); no system state was changed."
