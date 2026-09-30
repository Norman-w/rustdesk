#!/bin/sh
set -eu

tool_root="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(cd -- "$tool_root/../.." && pwd)"
output_directory="${NORMAN_REMOTE_MIC_DRIVER_OUTPUT_DIR:-$project_root/output}"
build_root="$(mktemp -d /tmp/norman-remote-audio-driver-build.XXXXXX)"

cleanup() {
  /bin/rm -rf "$build_root"
}
trap cleanup EXIT INT TERM

/bin/mkdir -p "$build_root" "$output_directory"
source_file="$tool_root/NormanRemoteMic.c"
clang_bin="${NORMAN_CLANG:-/usr/bin/clang}"
common_flags="-std=c11 -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -mmacosx-version-min=11.0 -framework CoreAudio -framework CoreFoundation -framework IOKit -bundle"

build_driver() {
  driver_name="$1"
  info_file="$2"
  output_path="$output_directory/$driver_name.driver"
  driver_contents="$build_root/$driver_name.driver/Contents"
  arm64_binary="$build_root/$driver_name-arm64"
  x86_64_binary="$build_root/$driver_name-x86_64"
  final_binary="$driver_contents/MacOS/$driver_name"

  /bin/mkdir -p "$driver_contents/MacOS" "$driver_contents/Resources"
  case "$driver_name" in
    NormanRemoteMic)
      device_def='-DNORMAN_AUDIO_DEVICE_NAME="Norman 手机麦克风"'
      box_def='-DNORMAN_AUDIO_BOX_NAME="Norman Remote Mic Box"'
      box_uid_def='-DNORMAN_AUDIO_BOX_UID="NormanRemoteMicBox_UID"'
      device_uid_def='-DNORMAN_AUDIO_DEVICE_UID="NormanRemoteMicDevice_UID"'
      model_uid_def='-DNORMAN_AUDIO_DEVICE_MODEL_UID="NormanRemoteMicDevice_ModelUID"'
      direction_defs='-DNORMAN_AUDIO_DEFAULT_INPUT=1 -DNORMAN_AUDIO_DEFAULT_OUTPUT=0 -DNORMAN_AUDIO_DEFAULT_SYSTEM_OUTPUT=0'
      ;;
    NormanRemoteAudio)
      device_def='-DNORMAN_AUDIO_DEVICE_NAME="Norman Remote Audio"'
      box_def='-DNORMAN_AUDIO_BOX_NAME="Norman Remote Audio Box"'
      box_uid_def='-DNORMAN_AUDIO_BOX_UID="NormanRemoteAudioBox_UID"'
      device_uid_def='-DNORMAN_AUDIO_DEVICE_UID="NormanRemoteAudioDevice_UID"'
      model_uid_def='-DNORMAN_AUDIO_DEVICE_MODEL_UID="NormanRemoteAudioDevice_ModelUID"'
      direction_defs='-DNORMAN_AUDIO_DEFAULT_INPUT=0 -DNORMAN_AUDIO_DEFAULT_OUTPUT=1 -DNORMAN_AUDIO_DEFAULT_SYSTEM_OUTPUT=1'
      ;;
    *)
      echo "unknown Norman audio driver: $driver_name" >&2
      exit 2
      ;;
  esac

  # Keep both architectures in every bundle so the same package works on
  # Apple silicon and Intel Macs. The two bundles use independent rings.
  "$clang_bin" -arch arm64 $common_flags "$device_def" "$box_def" "$box_uid_def" \
    "$device_uid_def" "$model_uid_def" $direction_defs "$source_file" -o "$arm64_binary"
  "$clang_bin" -arch x86_64 $common_flags "$device_def" "$box_def" "$box_uid_def" \
    "$device_uid_def" "$model_uid_def" $direction_defs "$source_file" -o "$x86_64_binary"
  /usr/bin/lipo -create "$arm64_binary" "$x86_64_binary" -output "$final_binary"
  /bin/cp "$info_file" "$driver_contents/Info.plist"
  /bin/chmod 755 "$final_binary"

  if [ -n "${NORMAN_CODESIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --deep --timestamp --sign "$NORMAN_CODESIGN_IDENTITY" \
      "$build_root/$driver_name.driver"
    signature_state="signed"
  else
    signature_state="unsigned"
  fi

  /bin/rm -rf "$output_path"
  /bin/mv "$build_root/$driver_name.driver" "$output_path"
  /usr/bin/plutil -lint "$output_path/Contents/Info.plist" >/dev/null
  /usr/bin/file "$output_path/Contents/MacOS/$driver_name"
  /usr/bin/codesign --verify --deep "$output_path" 2>/dev/null || true
  echo "Built $output_path ($signature_state)"
}

build_driver "NormanRemoteMic" "$tool_root/NormanRemoteMic-Info.plist"
build_driver "NormanRemoteAudio" "$tool_root/NormanRemoteAudio-Info.plist"
