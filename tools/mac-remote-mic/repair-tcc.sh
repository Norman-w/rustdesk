#!/bin/sh

# Check and request the macOS permissions needed by the controlled-side app.
# This intentionally uses the NormanRemoteDesktop executable's public API;
# it never edits the private TCC database and cannot silently grant access.
set -u

app_path="${NORMAN_RUSTDESK_APP_PATH:-}"
if [ -z "$app_path" ]; then
  for candidate in \
    "/Applications/NormanRemoteDesktop.app" \
    "/Applications/NormanRemoteDesktop-RustDesk-Test.app"; do
    if [ -f "$candidate/Contents/Info.plist" ]; then
      app_path="$candidate"
      break
    fi
  done
fi

app_executable=""
for candidate in \
  "$app_path/Contents/MacOS/NormanRemoteDesktop"; do
  if [ -x "$candidate" ]; then
    app_executable="$candidate"
    break
  fi
done

if [ ! -x "$app_executable" ]; then
  echo "未找到 NormanRemoteDesktop.app。" >&2
  exit 1
fi
if ! "$app_executable" --tcc-status 2>/dev/null | /usr/bin/grep -q '"schemaVersion":1'; then
  echo "当前应用不包含 TCC 检查功能，请先安装最新的 NormanRemoteDesktop。" >&2
  exit 1
fi

echo "当前 macOS TCC 状态："
"$app_executable" --tcc-status

case "${1:-repair}" in
  status|--status)
    exit 0
    ;;
  repair|--repair)
    echo "正在请求下一项缺失权限；请按 macOS 系统设置提示确认。"
    "$app_executable" --repair-tcc
    echo "本次请求已结束。若仍有缺失项，再运行一次本脚本继续处理下一项。"
    ;;
  *)
    echo "用法：$0 [status|repair]" >&2
    exit 2
    ;;
esac
