# Mac remote audio bridge (used by the unified CM package)

This directory contains the Mac-side CoreAudio probe, the buildable
AudioServerPlugIn virtual microphone/output devices, and the RustDesk
integration used by the unified `NormanRemoteDesktop-CMHelper` package.

The phone already sends RustDesk `AudioFormat`/`AudioFrame` packets after the
controlled side accepts the voice-call request. The official RustDesk 1.4.9
Mac client currently decodes those packets to its default output device. That
is playback, not a microphone that Codex or another Mac application can
select.

The deliverable includes two user-space AudioServerPlugIns:

- `NormanRemoteMic.driver` publishes the duplex device `Norman 手机麦克风`.
  RustDesk writes incoming phone-microphone PCM to its output side, and the
  same samples are exposed on its input side to a selected Mac application.
- `NormanRemoteAudio.driver` publishes `Norman Remote Audio`. Mac system
  playback writes to its output side, and RustDesk reads the paired input side
  to send the computer sound to the phone.

The bounded ring buffers fail closed to silence on underrun. Neither plug-in
opens a physical microphone. The installer does not change default devices;
the app changes the default output only for the opt-in virtual-output mode.

The plug-in is based on Apple's NullAudio sample; the original license is
included in `LICENSE-Apple-NullAudio.txt`. It is built for arm64 and x86_64,
but a production installation still needs a Developer ID-signed/notarized
driver and installer. The repository build is auditable and unsigned when no
signing identity is supplied.

## Probe the current host

```sh
clang -Wall -Wextra -framework CoreAudio -framework CoreFoundation \
  tools/mac-remote-mic/device_probe.c \
  -o /tmp/norman-remote-mic-device-probe
/tmp/norman-remote-mic-device-probe
/tmp/norman-remote-mic-device-probe --check-input "Norman 手机麦克风"
/tmp/norman-remote-mic-device-probe --check-output "RayLinkAudioDriver 2ch"
```

The probe only enumerates device names, UIDs, channel counts, and nominal
sample rates. It does not open a stream, emit audio, select a default device,
or install a driver. `--check-input` is the microphone check used by the Norman
phone path: it succeeds only when the named device exposes an input channel.
`--check-output` is a separate check for the RustDesk receiver sink. A complete
Norman device is duplex, so both checks must pass before incoming phone audio is
reported as fully routed.

The current host inventory includes `RayLinkAudioDriver 2ch` and
`WeMeet Audio Device`, both with two input and two output channels at 48 kHz.
Presence alone does not prove loopback; the RustDesk route must be tested with
an explicit device and a real input meter/application. The unified package
exposes this probe through `remote-mic-config.sh list` and
`remote-mic-config.sh set-output DEVICE_NAME`.

## Build the virtual audio devices

```sh
./tools/mac-remote-mic/build-norman-remote-mic-driver.sh
```

The default output contains both `output/NormanRemoteMic.driver` and
`output/NormanRemoteAudio.driver`. To sign them during the build, provide a
local identity explicitly:

```sh
NORMAN_CODESIGN_IDENTITY="Developer ID Application: ..." \
  ./tools/mac-remote-mic/build-norman-remote-mic-driver.sh
```

The bundles are intended for `/Library/Audio/Plug-Ins/HAL/`. They may require
a user-approved CoreAudio reload, logout, or restart before the devices
appear.

## Remote audio output modes

The NormanRemoteDesktop settings page exposes `Remote audio output`:

- `Computer speakers and phone` uses ScreenCaptureKit system-audio loopback.
  The Mac keeps playing through its current speakers/headphones while the same
  system sound is sent to the phone.
- `Norman Remote Audio virtual output` temporarily saves the current default
  output and system-output devices, selects the Norman virtual output while a
  remote audio subscription is active, and restores the saved devices when the
  session ends.

The second mode requires `NormanRemoteAudio.driver` to be visible to CoreAudio.
The first mode does not change the Mac default output and does not require the
virtual output device.

Run the read-only delivery check before any installation:

```sh
./tools/mac-remote-mic/verify-norman-remote-mic.sh
```

It validates the bundle metadata/signature and reports whether the current
CoreAudio inventory and NormanRemoteDesktop binary expose the two runtime halves. When
run from the installed package support directory it automatically checks the
driver at `/Library/Audio/Plug-Ins/HAL/NormanRemoteMic.driver` and the bundled
probe; when run from the repository, paths can be overridden with
`NORMAN_REMOTE_MIC_DRIVER_PATH` and `NORMAN_REMOTE_MIC_PROBE`. It does not
install, reload, select, or replace anything.

The unified package uses a Chinese welcome page and package title; the
remaining Installer buttons and step labels are supplied by macOS and follow
the host system language.

## Source ownership and builds

All desktop code is in this RustDesk fork. The receiver and routing logic are
normal Rust/Objective-C++ source, not patches applied by the HarmonyOS build.
The complete app build is:

```sh
./tools/build-macos-app.sh
./tools/build-rustdesk-cm-helper-pkg.sh
./tools/package-macos-distribution.sh
```

Default features are `flutter,screencapturekit`; `hwcodec` is rejected.
The native dependencies and Flutter toolchain must already be available.
See [the fork guide](../../docs/NORMAN_FORK_ZH-CN.md) for configuration,
signing and the distinction between build checks and runtime acceptance.

Normal users install the complete PKG and finish permissions in the app's setup
guide. `install-patched-rustdesk.sh` is a legacy developer diagnostic that replaces
a native library and restarts processes; it is not part of packaging or the
normal installation flow. No diagnostic installer is run by build checks.

The old `requires-patched-rustdesk` status string is retained for compatibility
with existing phone clients; it means the selected desktop binary lacks the
receiver feature, not that users should patch source themselves.
