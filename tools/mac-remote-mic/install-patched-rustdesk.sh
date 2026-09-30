#!/bin/sh
# ===== 分区：导入/依赖 =====
# Installs a freshly built librustdesk.dylib into NormanRemoteDesktop.app,
# adhoc-resigns the bundle, asks the app's public TCC repair API, and restarts
# the controlled-side processes. Developer diagnostic only; normal users install
# the complete PKG and use the app's setup guide instead.

# ===== 分区：常量/配置 =====
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_PATH="${NORMAN_APP_PATH:-/Applications/NormanRemoteDesktop.app}"
DYLIB_SRC="${1:-${NORMAN_DYLIB_SRC:-}}"
OUTPUT_DIR="${NORMAN_RUSTDESK_OUTPUT_DIR:-$SCRIPT_DIR/../../target/release}"
CODESIGN_IDENTITY="${NORMAN_CODESIGN_IDENTITY:--}"
REPAIR_TCC="${NORMAN_REPAIR_TCC:-1}"
RESTART="${NORMAN_RESTART_AFTER_INSTALL:-1}"

# ===== 分区：私有成员 =====
die() {
  printf '%s\n' "$*" >&2
  exit 1
}

resolve_dylib() {
  if [ -n "$DYLIB_SRC" ]; then
    printf '%s\n' "$DYLIB_SRC"
    return 0
  fi
  for candidate in \
    "$OUTPUT_DIR/liblibrustdesk-aarch64-apple-darwin.dylib" \
    "$OUTPUT_DIR/liblibrustdesk.dylib"
  do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  die "No dylib found. Pass path as \$1 or set NORMAN_DYLIB_SRC / NORMAN_RUSTDESK_OUTPUT_DIR."
}

stop_rustdesk() {
  /usr/bin/pkill -x NormanRemoteDesktop 2>/dev/null || true
  /bin/sleep 2
}

start_rustdesk() {
  /bin/launchctl kickstart -k "system/com.carriez.NormanRemoteDesktop_service" 2>/dev/null || true
  /bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/com.carriez.NormanRemoteDesktop_server" 2>/dev/null || true
  /bin/sleep 1
  /usr/bin/open -n "$APP_PATH" 2>/dev/null || true
  /bin/sleep 2
  /bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/com.norman.remotedesktop-cm-no-ui" 2>/dev/null || true
}

main_executable() {
  for candidate in \
    "$APP_PATH/Contents/MacOS/NormanRemoteDesktop"
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  die "Executable not found in $APP_PATH (expected NormanRemoteDesktop)"
}

ensure_soft_codec_defaults() {
  # Service (--server as root) syncs config from /var/root; patch both.
  /usr/bin/osascript -e 'do shell script "/bin/sh '"$SCRIPT_DIR"'/force-soft-codec.sh" with administrator privileges' \
    2>/dev/null || /bin/sh "$SCRIPT_DIR/force-soft-codec.sh" || true
}

# ===== 分区：公开 API =====
main() {
  [ -d "$APP_PATH" ] || die "App not found: $APP_PATH"
  dylib="$(resolve_dylib)"
  [ -f "$dylib" ] || die "Dylib missing: $dylib"

  if ! /usr/bin/strings -a "$dylib" | /usr/bin/grep -q -- 'NORMAN_REMOTE_MIC_OUTPUT_DEVICE'; then
    die "Refusing to install: dylib lacks Norman virtual-mic route marker."
  fi

  printf 'Installing %s -> %s\n' "$dylib" "$APP_PATH"
  stop_rustdesk

  /bin/cp "$dylib" "$APP_PATH/Contents/Frameworks/liblibrustdesk.dylib"
  /usr/bin/codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_PATH"
  /usr/bin/codesign --verify --deep "$APP_PATH" >/dev/null

  exe="$(main_executable)"
  hash="$(/usr/bin/codesign -d -vvvv "$exe" 2>&1 |
    /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
  printf 'Resigned CDHash=%s\n' "$hash"

  if [ "$REPAIR_TCC" = "1" ]; then
    "$exe" --repair-tcc || true
  else
    printf 'Skipped TCC repair request (NORMAN_REPAIR_TCC=0)\n'
  fi

  ensure_soft_codec_defaults

  if [ "$RESTART" = "1" ]; then
    start_rustdesk
  fi

  printf 'Install complete. If permissions are missing, approve them in System Settings and relaunch NormanRemoteDesktop.\n'
}

main "$@"
