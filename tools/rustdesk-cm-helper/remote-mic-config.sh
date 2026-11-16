#!/bin/sh

# Explicit, user-facing configuration for the optional NormanRemoteDesktop incoming
# voice-call output route.  This script never captures the Mac microphone,
# changes default devices, installs a driver, or touches RayLink/WeMeet.
set -u

user_home="${NORMAN_CM_HELPER_HOME:-$HOME}"
helper_root="$user_home/Library/Application Support/NormanRemoteDesktop/cm-helper"
config="$helper_root/audio-config.plist"
probe="$helper_root/bin/norman-remote-mic-device-probe"
agent_label="com.norman.remotedesktop-cm-no-ui"
norman_device_name="Norman 手机麦克风"

usage() {
  /usr/bin/printf '%s\n' \
    "用法：" \
    "  $0 list" \
    "  $0 status" \
    "  $0 set-output DEVICE_NAME" \
    "  $0 select-norman-output" \
    "  $0 enable" \
    "  $0 disable" \
    "  $0 mark-loopback-verified" \
    "  $0 restart"
}

if [ ! -f "$config" ] || [ ! -x "$probe" ]; then
  /usr/bin/printf '%s\n' '统一组件尚未安装完整；找不到音频配置或设备探测器。' >&2
  exit 2
fi

command="${1:-}"
case "$command" in
  list)
    if [ "$#" -ne 1 ]; then usage; exit 64; fi
    exec "$probe"
    ;;
  status)
    if [ "$#" -ne 1 ]; then usage; exit 64; fi
    /usr/bin/printf '%s\n' '当前音频配置：'
    /usr/bin/plutil -p "$config"
    status_file="$helper_root/audio-status.json"
    if [ -f "$status_file" ]; then
      /usr/bin/printf '%s\n' '当前运行状态：'
      /bin/cat "$status_file"
    else
      /usr/bin/printf '%s\n' '当前运行状态：等待 CM helper 启动。'
    fi
    ;;
  set-output)
    if [ "$#" -ne 2 ] || [ -z "$2" ]; then usage; exit 64; fi
    device_name="$2"
    probe_output=$("$probe" --check-output "$device_name" 2>/dev/null)
    probe_rc=$?
    if [ "$probe_rc" -ne 0 ]; then
      /usr/bin/printf '%s\n' '找不到可作为输出的精确设备名称；先运行 list 查看设备。' >&2
      exit 3
    fi
    /usr/bin/plutil -replace outputDeviceName -string "$device_name" "$config"
    /usr/bin/plutil -replace enabled -bool YES "$config"
    /usr/bin/plutil -replace loopbackVerified -bool NO "$config"
    /usr/bin/plutil -lint "$config" >/dev/null
    /usr/bin/printf '%s\n' '已选择输出设备；音频默认仍关闭回环确认，重启 CM helper 后生效。'
    ;;
  select-norman-output)
    if [ "$#" -ne 1 ]; then usage; exit 64; fi
    probe_output=$("$probe" --check-input "$norman_device_name" 2>/dev/null)
    probe_rc=$?
    if [ "$probe_rc" -ne 0 ]; then
      /usr/bin/printf '%s\n' 'Norman 手机麦克风输入尚未出现在 CoreAudio 设备列表；先重新登录或重启后再试。' >&2
      exit 3
    fi
    if ! "$probe" --check-output "$norman_device_name" >/dev/null 2>&1; then
      /usr/bin/printf '%s\n' 'Norman 手机麦克风输入已出现，但 RustDesk 接收输出端尚未加载；先重新登录或重启后再试。' >&2
      exit 3
    fi
    /usr/bin/plutil -replace outputDeviceName -string "$norman_device_name" "$config"
    /usr/bin/plutil -replace enabled -bool YES "$config"
    # This device loops its own RustDesk output into its input inside the HAL
    # plug-in; unlike third-party devices, no external loopback claim is made.
    /usr/bin/plutil -replace loopbackVerified -bool YES "$config"
    /usr/bin/plutil -lint "$config" >/dev/null
    /usr/bin/printf '%s\n' '已选择 Norman 手机麦克风并启用；请重启 CM helper 后生效。'
    ;;
  enable)
    if [ "$#" -ne 1 ]; then usage; exit 64; fi
    current_device=$(/usr/libexec/PlistBuddy -c 'Print :outputDeviceName' "$config" 2>/dev/null || true)
    if [ -z "$current_device" ]; then
      /usr/bin/printf '%s\n' '尚未选择输出设备；先运行 set-output DEVICE_NAME。' >&2
      exit 3
    fi
    /usr/bin/plutil -replace enabled -bool YES "$config"
    /usr/bin/plutil -replace loopbackVerified -bool NO "$config"
    /usr/bin/plutil -lint "$config" >/dev/null
    /usr/bin/printf '%s\n' '音频接收已启用；它只影响 NormanRemoteDesktop 来电音频，不会改变系统默认设备。'
    ;;
  disable)
    if [ "$#" -ne 1 ]; then usage; exit 64; fi
    /usr/bin/plutil -replace enabled -bool NO "$config"
    /usr/bin/plutil -replace loopbackVerified -bool NO "$config"
    /usr/bin/plutil -lint "$config" >/dev/null
    /usr/bin/printf '%s\n' '音频接收已关闭。'
    ;;
  mark-loopback-verified)
    if [ "$#" -ne 1 ]; then usage; exit 64; fi
    enabled=$(/usr/libexec/PlistBuddy -c 'Print :enabled' "$config" 2>/dev/null || true)
    current_device=$(/usr/libexec/PlistBuddy -c 'Print :outputDeviceName' "$config" 2>/dev/null || true)
    if [ "$enabled" != "true" ] || [ -z "$current_device" ]; then
      /usr/bin/printf '%s\n' '请先启用音频并选择输出设备。' >&2
      exit 3
    fi
    probe_output=$("$probe" --check-input "$current_device" 2>/dev/null)
    probe_rc=$?
    input_channels=$(printf '%s\n' "$probe_output" | /usr/bin/sed -n 's/.*input_channels=\([0-9][0-9]*\).*/\1/p' | /usr/bin/head -n 1)
    [ -n "$input_channels" ] || input_channels=0
    if [ "$probe_rc" -ne 0 ] || [ "$input_channels" -le 0 ]; then
      /usr/bin/printf '%s\n' '当前设备没有可供其他应用选择的麦克风输入通道，不能标记为可用。' >&2
      exit 3
    fi
    if ! "$probe" --check-output "$current_device" >/dev/null 2>&1; then
      /usr/bin/printf '%s\n' '当前设备没有 RustDesk 接收所需的输出路由，不能标记为可用。' >&2
      exit 3
    fi
    /usr/bin/plutil -replace loopbackVerified -bool YES "$config"
    /usr/bin/plutil -lint "$config" >/dev/null
    /usr/bin/printf '%s\n' '已记录人工回环确认；请重启 CM helper 后重新检查。'
    ;;
  restart)
    if [ "$#" -ne 1 ]; then usage; exit 64; fi
    uid=$(/usr/bin/id -u)
    /bin/launchctl kickstart -k "gui/$uid/$agent_label"
    /usr/bin/printf '%s\n' 'CM helper 已请求重启。'
    ;;
  *)
    usage
    exit 64
    ;;
esac
