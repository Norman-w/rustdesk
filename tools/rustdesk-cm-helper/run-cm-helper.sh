#!/bin/sh

# User-level NormanRemoteDesktop connection-manager runner.  It keeps the CM no-UI
# process independent from the optional incoming voice-call output route.
# It never opens the Mac microphone, changes default devices, or records.
set -u

user_home="${NORMAN_CM_HELPER_HOME:-$HOME}"
helper_relative="Library/Application Support/NormanRemoteDesktop/cm-helper"
helper_root="$user_home/$helper_relative"
rustdesk_app_path="${NORMAN_RUSTDESK_APP_PATH:-}"
if [ -z "$rustdesk_app_path" ]; then
  for candidate in \
    "/Applications/NormanRemoteDesktop.app" \
    "/Applications/NormanRemoteDesktop-RustDesk-Test.app"; do
    if [ -f "$candidate/Contents/Info.plist" ]; then
      rustdesk_app_path="$candidate"
      break
    fi
  done
fi
if [ -n "${NORMAN_RUSTDESK_BIN:-}" ]; then
  rustdesk="$NORMAN_RUSTDESK_BIN"
else
  rustdesk=""
  for candidate in \
    "$rustdesk_app_path/Contents/MacOS/NormanRemoteDesktop"; do
    if [ -x "$candidate" ]; then
      rustdesk="$candidate"
      break
    fi
  done
fi
rustdesk_library="${NORMAN_RUSTDESK_LIBRARY:-$rustdesk_app_path/Contents/Frameworks/liblibrustdesk.dylib}"
probe="$helper_root/bin/norman-remote-mic-device-probe"
config="$helper_root/audio-config.plist"
heartbeat="$helper_root/heartbeat.json"
manifest="$helper_root/manifest.json"
audio_status_file="$helper_root/audio-status.json"
tcc_status_file="$helper_root/tcc-status.json"
agent_label="com.norman.remotedesktop-cm-no-ui"
helper_version="1.3.0"
virtual_input_driver="/Library/Audio/Plug-Ins/HAL/NormanRemoteMic.driver"
virtual_input_state="missing"

/bin/mkdir -p "$helper_root"

audio_state="disabled"
audio_route="speaker-only"
other_apps_input="not-available"
audio_enabled="false"
audio_device=""
loopback_verified="false"
tcc_state="unknown"
tcc_screen_recording="false"
tcc_accessibility="false"
tcc_input_monitoring="false"
cm_state="starting"
child=""

read_audio_config() {
  audio_enabled="false"
  audio_device=""
  loopback_verified="false"
  if [ ! -f "$config" ]; then
    return
  fi
  audio_enabled=$(/usr/libexec/PlistBuddy -c 'Print :enabled' "$config" 2>/dev/null || true)
  audio_device=$(/usr/libexec/PlistBuddy -c 'Print :outputDeviceName' "$config" 2>/dev/null || true)
  loopback_verified=$(/usr/libexec/PlistBuddy -c 'Print :loopbackVerified' "$config" 2>/dev/null || true)
  [ "$audio_enabled" = "true" ] || audio_enabled="false"
  [ "$loopback_verified" = "true" ] || loopback_verified="false"
}

has_routing_patch() {
  if [ ! -x "$rustdesk" ] || [ ! -f "$rustdesk_library" ]; then
    return 1
  fi
  if { /usr/bin/strings -a "$rustdesk" 2>/dev/null; /usr/bin/strings -a "$rustdesk_library" 2>/dev/null; } |
      /usr/bin/grep -q -- 'NORMAN_REMOTE_MIC_OUTPUT_DEVICE'; then
    return 0
  fi
  return 1
}

write_audio_marker() {
  marker="$1"
  for old_marker in "$helper_root"/audio-state-*; do
    if [ -f "$old_marker" ]; then
      /bin/rm -f "$old_marker"
    fi
  done
  : > "$helper_root/audio-state-$marker"
}

write_virtual_input_marker() {
  marker="$1"
  for old_marker in "$helper_root"/virtual-input-*; do
    if [ -f "$old_marker" ]; then
      /bin/rm -f "$old_marker"
    fi
  done
  : > "$helper_root/virtual-input-$marker"
}

write_audio_status() {
  now=$(/bin/date +%s)
  temporary="$audio_status_file.tmp.$$"
  /usr/bin/printf '%s\n' \
    "{\"schemaVersion\":3,\"state\":\"$audio_state\",\"route\":\"$audio_route\",\"virtualInput\":\"$virtual_input_state\",\"otherAppsInput\":\"$other_apps_input\",\"updatedAt\":$now}" \
    > "$temporary"
  /bin/mv -f "$temporary" "$audio_status_file"
  write_audio_marker "$audio_state"
  # Keep the CoreAudio virtual-input state separate from the RustDesk audio
  # route state; the phone uses this marker to distinguish a loaded HAL
  # device from an output route that merely happens to be ready.
  write_virtual_input_marker "$virtual_input_state"
}

probe_check() {
  probe_mode="$1"
  requested_device="$2"
  output_file="$helper_root/probe-output.tmp.$$"
  status_file="$helper_root/probe-status.tmp.$$"
  rm -f "$output_file" "$status_file"
  "$probe" "$probe_mode" "$requested_device" >"$output_file" 2>/dev/null &
  probe_pid=$!
  for _attempt in 1 2 3 4 5; do
    if ! /bin/kill -0 "$probe_pid" 2>/dev/null; then
      wait "$probe_pid"
      probe_rc=$?
      /bin/cat "$output_file" 2>/dev/null || true
      /bin/rm -f "$output_file" "$status_file"
      return "$probe_rc"
    fi
    /bin/sleep 1
  done
  /bin/kill "$probe_pid" 2>/dev/null || true
  wait "$probe_pid" 2>/dev/null || true
  /bin/rm -f "$output_file" "$status_file"
  return 124
}

refresh_audio_status() {
  audio_state="disabled"
  audio_route="speaker-only"
  other_apps_input="not-available"
  virtual_input_state="missing"
  if [ -f "$virtual_input_driver/Contents/Info.plist" ] &&
      [ -x "$virtual_input_driver/Contents/MacOS/NormanRemoteMic" ]; then
    virtual_input_state="bundle-installed"
    if [ -x "$probe" ]; then
      virtual_probe_output=$(probe_check --check-input "Norman 手机麦克风")
      virtual_probe_rc=$?
      if [ "$virtual_probe_rc" -eq 0 ]; then
        virtual_input_state="available"
      else
        virtual_input_state="pending-reload"
      fi
    fi
  fi
  read_audio_config

  if [ "$audio_enabled" != "true" ]; then
    write_audio_status
    return
  fi
  if ! has_routing_patch; then
    audio_state="requires-patched-rustdesk"
    write_audio_status
    return
  fi
  if [ -z "$audio_device" ]; then
    audio_state="not-configured"
    write_audio_status
    return
  fi
  if [ ! -x "$probe" ]; then
    audio_state="unavailable"
    write_audio_status
    return
  fi

  # The phone audio is exposed to Mac applications through the device input
  # stream. Its output stream is the separate RustDesk receiver sink.
  probe_output=$(probe_check --check-input "$audio_device")
  probe_rc=$?
  input_channels=$(printf '%s\n' "$probe_output" | /usr/bin/sed -n 's/.*input_channels=\([0-9][0-9]*\).*/\1/p' | /usr/bin/head -n 1)
  output_channels=$(printf '%s\n' "$probe_output" | /usr/bin/sed -n 's/.*output_channels=\([0-9][0-9]*\).*/\1/p' | /usr/bin/head -n 1)
  [ -n "$input_channels" ] || input_channels=0
  [ -n "$output_channels" ] || output_channels=0

  if [ "$input_channels" -le 0 ]; then
    if [ "$output_channels" -gt 0 ]; then
      audio_state="output-only"
    else
      audio_state="unavailable"
    fi
    write_audio_status
    return
  fi

  audio_route="virtual-output"
  if [ "$output_channels" -le 0 ]; then
    audio_state="input-only"
  elif [ "$loopback_verified" = "true" ]; then
    audio_state="ready"
    other_apps_input="available"
  else
    audio_state="candidate"
    other_apps_input="needs-loopback-test"
  fi
  write_audio_status
}

write_tcc_markers() {
  for old_marker in "$helper_root"/tcc-state-* "$helper_root"/tcc-missing-*; do
    if [ -e "$old_marker" ]; then
      /bin/rm -f "$old_marker"
    fi
  done
  : > "$helper_root/tcc-state-$tcc_state"
  if [ "$tcc_screen_recording" != "true" ]; then
    [ "$tcc_state" = "needs-attention" ] && : > "$helper_root/tcc-missing-screen-recording"
  fi
  if [ "$tcc_accessibility" != "true" ]; then
    [ "$tcc_state" = "needs-attention" ] && : > "$helper_root/tcc-missing-accessibility"
  fi
  if [ "$tcc_input_monitoring" != "true" ]; then
    [ "$tcc_state" = "needs-attention" ] && : > "$helper_root/tcc-missing-input-monitoring"
  fi
}

refresh_tcc_status() {
  # TCC grants belong to the visible NormanRemoteDesktop.app process. A
  # LaunchAgent cannot reliably represent that foreground identity, and
  # probing from here risks making PackageKit/Installer the permission owner
  # during installation. Keep the helper's published state explicitly
  # unknown; the app's public --tcc-status/--repair-tcc flow is authoritative.
  tcc_state="unknown"
  tcc_screen_recording="false"
  tcc_accessibility="false"
  tcc_input_monitoring="false"
  temporary="$tcc_status_file.tmp.$$"
  /usr/bin/printf '%s\n' \
    "{\"schemaVersion\":1,\"state\":\"$tcc_state\",\"screenRecording\":$tcc_screen_recording,\"accessibility\":$tcc_accessibility,\"inputMonitoring\":$tcc_input_monitoring,\"updatedAt\":$(/bin/date +%s)}" \
    > "$temporary"
  /bin/mv -f "$temporary" "$tcc_status_file"
  write_tcc_markers
}

write_state() {
  cm_state="$1"
  now=$(/bin/date +%s)
  temporary="$heartbeat.tmp.$$"
  /usr/bin/printf '%s\n' \
    "{\"schemaVersion\":3,\"state\":\"$cm_state\",\"updatedAt\":$now,\"helperKind\":\"norman-remotedesktop-cm-no-ui\",\"components\":{\"cm\":{\"state\":\"$cm_state\"},\"audio\":{\"state\":\"$audio_state\",\"route\":\"$audio_route\",\"virtualInput\":\"$virtual_input_state\",\"otherAppsInput\":\"$other_apps_input\"},\"tcc\":{\"state\":\"$tcc_state\",\"screenRecording\":$tcc_screen_recording,\"accessibility\":$tcc_accessibility,\"inputMonitoring\":$tcc_input_monitoring}}}" \
    > "$temporary"
  /bin/mv -f "$temporary" "$heartbeat"
  temporary="$manifest.tmp.$$"
  /usr/bin/printf '%s\n' \
    "{\"schemaVersion\":3,\"state\":\"$cm_state\",\"helperKind\":\"norman-remotedesktop-cm-no-ui\",\"helperVersion\":\"$helper_version\",\"baseBundleIdentifier\":\"com.carriez.NormanRemoteDesktop\",\"baseVersion\":\"1.4.10\",\"launchAgentLabel\":\"$agent_label\",\"purpose\":\"Keep NormanRemoteDesktop connection management headless so full-screen applications and Spaces keep focus.\",\"components\":{\"cm\":{\"state\":\"$cm_state\"},\"audio\":{\"state\":\"$audio_state\",\"route\":\"$audio_route\",\"virtualInput\":\"$virtual_input_state\",\"otherAppsInput\":\"$other_apps_input\"},\"tcc\":{\"state\":\"$tcc_state\",\"screenRecording\":$tcc_screen_recording,\"accessibility\":$tcc_accessibility,\"inputMonitoring\":$tcc_input_monitoring}}}" \
    > "$temporary"
  /bin/mv -f "$temporary" "$manifest"
}

on_signal() {
  if [ -n "$child" ] && /bin/kill -0 "$child" 2>/dev/null; then
    /bin/kill "$child" 2>/dev/null || true
  fi
  refresh_audio_status || true
  write_state stopped || true
  exit 0
}

trap on_signal INT TERM HUP

while :; do
  refresh_audio_status
  refresh_tcc_status
  if [ ! -x "$rustdesk" ]; then
    write_state missing
    /bin/sleep 5
    continue
  fi

  write_state starting
  if [ "$audio_route" = "virtual-output" ] && [ -n "$audio_device" ]; then
    NORMAN_REMOTE_MIC_OUTPUT_DEVICE="$audio_device" "$rustdesk" --cm-no-ui &
  else
    "$rustdesk" --cm-no-ui &
  fi
  child=$!
  while /bin/kill -0 "$child" 2>/dev/null; do
    refresh_audio_status
    refresh_tcc_status
    write_state ready
    /bin/sleep 5
  done
  /bin/wait "$child" 2>/dev/null || true
  child=""
  write_state stopped
  /bin/sleep 2
done
