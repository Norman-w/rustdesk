#!/bin/sh
set -eu

# Build this checkout only. No source patches, installed app templates, or installation.
tool_root="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(cd -- "$tool_root/.." && pwd)"
output_directory="${NORMAN_MACOS_OUTPUT_DIR:-$project_root/output}"
target_directory="${NORMAN_RUSTDESK_TARGET_DIR:-$project_root/target}"
features="${NORMAN_RUSTDESK_FEATURES:-flutter,screencapturekit}"
configuration="${NORMAN_XCODE_CONFIGURATION:-Release}"
deployment_target="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
export PATH="${NORMAN_FLUTTER_BIN:+$NORMAN_FLUTTER_BIN:}$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

fail() { echo "error: $*" >&2; exit 2; }
case ",$features," in *,hwcodec,*) fail "hwcodec is disabled for the Norman macOS distribution" ;; esac
case "$configuration" in Release|Debug) ;; *) fail "configuration must be Release or Debug" ;; esac
for tool in cargo flutter flutter_rust_bridge_codegen pod xcodebuild rsync; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing build tool: $tool"
done
[ "$(uname -s)" = Darwin ] || fail "macOS is required"
case "$(uname -m)" in arm64) architecture=arm64 ;; x86_64) architecture=x86_64 ;; *) fail "unsupported host architecture" ;; esac
[ -f "$project_root/libs/hbb_common/Cargo.toml" ] || fail "initialize the Git submodules first"

mkdir -p "$output_directory" "$target_directory"
output_directory="$(cd "$output_directory" && pwd)"
target_directory="$(cd "$target_directory" && pwd)"
export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
export CARGO_TARGET_DIR="$target_directory"
# Prefer the host's existing libsodium over the old vendored autotools build.
if [ -z "${SODIUM_LIB_DIR:-}" ] && [ -z "${SODIUM_USE_PKG_CONFIG:-}" ] &&
    command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libsodium; then
  export SODIUM_USE_PKG_CONFIG=1
fi
cd "$project_root"
pub_flags="--enforce-lockfile"
if [ "${NORMAN_PUB_OFFLINE:-0}" = 1 ]; then
  pub_flags="$pub_flags --offline"
fi

# Bindings must be regenerated from the same source as the native library.
(cd flutter && flutter pub get $pub_flags)
RUST_LOG=info flutter_rust_bridge_codegen \
  --rust-input "$project_root/src/flutter_ffi.rs" \
  --dart-output "$project_root/flutter/lib/generated_bridge.dart" \
  --c-output "$project_root/flutter/macos/Runner/bridge_generated.h" \
  --skip-add-mod-to-lib
cargo build --locked --features "$features" --lib --bins --release

library="$target_directory/release/liblibrustdesk.dylib"
service="$target_directory/release/service"
[ -f "$library" ] && [ -x "$service" ] || fail "native artifacts are incomplete"

# Keep CocoaPods/Xcode generated state out of the source checkout.
build_root="$(mktemp -d "$output_directory/macos-build.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT INT TERM
mkdir -p "$build_root/flutter" "$build_root/res" "$build_root/target/release"
rsync -a --exclude build --exclude Pods --exclude .dart_tool --exclude ephemeral \
  "$project_root/flutter/" "$build_root/flutter/"
rsync -a "$project_root/res/" "$build_root/res/"
# The upstream Xcode project links ../../target/release/liblibrustdesk.dylib.
cp "$library" "$build_root/target/release/liblibrustdesk.dylib"
(cd "$build_root/flutter" && flutter pub get $pub_flags)
case "$configuration" in Release) flutter_mode=release ;; Debug) flutter_mode=debug ;; esac
(cd "$build_root/flutter" && flutter build macos --config-only --no-pub "--$flutter_mode")
(
  cd "$build_root/flutter/macos"
  pod install
  xcodebuild -workspace Runner.xcworkspace -scheme Runner \
    -configuration "$configuration" -destination "platform=macOS,arch=$architecture" \
    -derivedDataPath "$build_root/DerivedData" ARCHS="$architecture" ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET="$deployment_target" build
)
built_app="$build_root/DerivedData/Build/Products/$configuration/NormanRemoteDesktop.app"
[ -d "$built_app" ] || fail "Xcode did not produce the expected app"
cp "$library" "$built_app/Contents/Frameworks/liblibrustdesk.dylib"
cp "$service" "$built_app/Contents/MacOS/service"

# libsodium can be static or a Homebrew dylib. Bundle only the latter.
for binary in "$built_app/Contents/MacOS/NormanRemoteDesktop" \
  "$built_app/Contents/MacOS/service" "$built_app/Contents/Frameworks/liblibrustdesk.dylib"; do
  dependency=$(/usr/bin/otool -L "$binary" | /usr/bin/awk '/\/(opt\/homebrew|usr\/local)\/opt\/libsodium\/lib\/libsodium.*\.dylib/ {print $1; exit}')
  [ -n "$dependency" ] || continue
  [ -f "$dependency" ] || fail "missing libsodium dependency: $dependency"
  name="$(basename "$dependency")"
  cp "$dependency" "$built_app/Contents/Frameworks/$name"
  chmod 755 "$built_app/Contents/Frameworks/$name"
  /usr/bin/install_name_tool -id "@rpath/$name" "$built_app/Contents/Frameworks/$name"
  case "$binary" in
    */Contents/MacOS/*) local_dependency="@loader_path/../Frameworks/$name" ;;
    *) local_dependency="@loader_path/$name" ;;
  esac
  /usr/bin/install_name_tool -change "$dependency" "$local_dependency" "$binary"
done

# A local ad-hoc build is not a distributable, notarized release.
identity="${NORMAN_APP_SIGNING_IDENTITY:--}"
/usr/bin/codesign --force --deep --sign "$identity" "$built_app"
/usr/bin/codesign --verify --deep --strict "$built_app"
app_output="$output_directory/NormanRemoteDesktop.app"
if [ -e "$app_output" ]; then
  mv "$app_output" "$app_output.prev-$(date +%Y%m%d-%H%M%S)"
fi
/usr/bin/ditto "$built_app" "$app_output"
git rev-parse HEAD > "$output_directory/macos-source-commit.txt"
git diff --binary HEAD > "$output_directory/macos-source-changes.patch"
echo "Built $app_output from $project_root; nothing was installed or restarted."
