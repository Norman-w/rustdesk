# macOS Source Ownership

## Single Source of Truth

The Norman RustDesk fork owns every desktop implementation and its release tools.
The HarmonyOS repository only owns the controller and peer protocol integration.

The 2026-09-30 migration moves the existing working files, including uncommitted
HAL and packaging changes. It does not discard either repository's unrelated work,
install software, change TCC grants, or publish a release.

## Migration Map

| Previous HarmonyOS location | RustDesk fork location |
| --- | --- |
| tools/mac-remote-mic/NormanRemoteMic.c and Info.plists | tools/mac-remote-mic/ |
| tools/mac-remote-mic probes, driver builder and diagnostics | tools/mac-remote-mic/ |
| tools/rustdesk-cm-helper/ | tools/rustdesk-cm-helper/ |
| tools/macos-installer/ | tools/macos-installer/ |
| tools/build-rustdesk-cm-helper-pkg.sh | tools/build-rustdesk-cm-helper-pkg.sh |
| tools/package-macos-distribution.sh | tools/package-macos-distribution.sh |
| tools/sign-notarize-macos-distribution.sh | tools/sign-notarize-macos-distribution.sh |
| tools/verify-macos-distribution.sh | tools/verify-macos-distribution.sh |
| build-macos-app-from-rustdesk.sh and build-patched-rustdesk.sh | tools/build-macos-app.sh |

The virtual-output patch was already partly present in the fork. Its remaining
app-managed voice acceptance/stream lifecycle, system-audio subscription and
virtual-output routing changes are integrated in src/client.rs, src/server.rs,
src/server/connection.rs, src/server/audio_service.rs, src/platform/macos.rs,
src/platform/macos.mm and src/ui_interface.rs. Settings/translations are in Flutter
and src/lang. All four source patches are retired, not copied into the installer.

The setup guide, full-screen setting, related FFI methods, macOS service/IPC
compatibility and audio readiness refresh previously existed only in temporary
build trees. Their successful file-change records were recovered from this
task's history and integrated into the corresponding normal source files.
Temporary build paths and historical logs are not build dependencies.

## Compatibility

- Keep the existing app identifier and component package/receipt names.
- Keep the phone's existing readiness-marker protocol and mobile UI.
- Keep diagnostic scripts separate from the normal GUI installer.
- Do not revive the removed private TCC repair script.
- Historical ignored output directories are not build inputs and are not migrated
  into Git. Existing downloaded packages and running applications remain untouched.

## Release Discipline

Build App and HAL from this repository, package them here, and publish the macOS
artifacts to this fork. Build and publish HAPs from the HarmonyOS repository.
Run both repositories' boundary tests before release. A Mac build does not establish
Windows feature parity or substitute for on-device acceptance.

## Migration Verification (2026-09-30)

- Built the release App with Flutter 3.24.5 from this checkout using
  `tools/build-macos-app.sh`, without `hwcodec` or an installed App template.
- Built component PKG 1.3.0, application PKG 1.4.10 and DMG 1.4.10 entirely with
  this repository's tools. Outputs are in `output/macos-migration-check/`.
- Verified bundle identity/version, ad-hoc code-signature integrity, portable
  Mach-O dependencies, read-only TCC status JSON, compiled setup-guide/native
  API markers, identical embedded/standalone component packages and DMG checksum.
- Expanded the component package: both HAL drivers contain arm64 and x86_64;
  no desktop source patch or patch-applying build script is included.
- Passed six desktop source/packaging checks, fourteen phone layout/ownership
  checks and four native-render regression groups with ASan/UBSan. Flutter
  analysis of the changed pages/model reports no errors or warnings, only nine
  informational deprecated/unused-code diagnostics.
- Compared the phone's pre-existing `entry/` diff with the migration backup:
  unchanged. HAL implementation, probe and installer actions were moved intact.

These outputs are development validation artifacts, not a new release. The App
is ad-hoc signed and the PKGs are unsigned; no Developer ID notarization,
installation, TCC grant changes or live remote-session acceptance was performed.
Source commits and pushes are separate from binary release publication.
