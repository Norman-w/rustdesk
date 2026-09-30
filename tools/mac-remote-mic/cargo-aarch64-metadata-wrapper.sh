#!/bin/sh
set -eu

# flutter_rust_bridge_codegen 1.80 asks Cargo for all target platforms. The
# RustDesk lockfile also contains Linux-only packages that are not needed for
# this macOS bridge scan, so limit metadata resolution to the host target.
if [ "${1:-}" = "metadata" ]; then
    exec /opt/homebrew/opt/rust/bin/cargo "$@" --filter-platform aarch64-apple-darwin
fi
exec /opt/homebrew/opt/rust/bin/cargo "$@"
