# NormanRemoteDesktop app-managed components + incoming audio

This package is the single macOS-side component for the two related remote
control needs:

- the NormanRemoteDesktop 1.4.10 app-managed connection manager, which uses the
  official on-demand `--cm` path and the app's hidden-window setting so a
  full-screen application or Space is not pulled away when a session starts;
- two user-space CoreAudio HAL plug-ins: `Norman 手机麦克风` for the phone
  microphone input path and `Norman Remote Audio` for the optional
  system-output routing path.

It does not replace NormanRemoteDesktop, install a second desktop application, execute
commands received from the phone, capture the Mac microphone, record audio,
or modify RayLink/WeMeet settings. The installer itself does not change the
system default input/output. The app's opt-in virtual-output mode temporarily
selects `Norman Remote Audio` during an active remote-audio subscription and
restores the previous output devices when the subscription ends.
The virtual device's output is a NormanRemoteDesktop sink and its input is the same
bounded-buffered stream for a Mac application to select manually; the input side is
the microphone presented to other Mac applications. It does not
mix physical microphone or speaker audio.

The package is deliberately limited to the existing NormanRemoteDesktop bundle:

- Bundle ID: `com.carriez.NormanRemoteDesktop`
- Version: `1.4.10`
- Entry point: `/Applications/NormanRemoteDesktop.app/Contents/MacOS/NormanRemoteDesktop`
- Persistent LaunchAgent: none; the app/service owns CM lifecycle
- Package version: `1.3.0`

CM and audio are independent. CM can be ready while audio is disabled,
unconfigured, unavailable, or waiting for a patched NormanRemoteDesktop binary. The
first-install audio configuration selects `Norman 手机麦克风` and enables the
explicit incoming voice-call route. The stock official 1.4.9 binary
must contain the opt-in `NORMAN_REMOTE_MIC_OUTPUT_DEVICE` routing hook, so
installing this package alone must not be reported as a system microphone.

## Build

Build on the Mac that already has the official RustDesk app installed:

```sh
./tools/build-rustdesk-cm-helper-pkg.sh
```

The package is written to:

```text
output/NormanRemoteDesktop-CMHelper-1.3.0.pkg
```

The payload contains the `NormanRemoteMic.driver` and
`NormanRemoteAudio.driver` AudioServerPlugIns, their auditable C
source/license, a read-only CoreAudio device probe,
and user-level configuration scripts. The installer places both drivers at:

```text
/Library/Audio/Plug-Ins/HAL/NormanRemoteMic.driver
/Library/Audio/Plug-Ins/HAL/NormanRemoteAudio.driver
```

and copies only app-managed configuration/probe data to:

```text
~/Library/Application Support/NormanRemoteDesktop/cm-helper/
```

It does not create or start a user LaunchAgent, open NormanRemoteDesktop,
inspect TCC, or request macOS privacy permissions. Upgrading also removes the
older `com.norman.remotedesktop-cm-no-ui` LaunchAgent if one is present.
CoreAudio may need a user-approved reload,
logout, or restart before the devices appear. The phone checks the manifest,
app-managed state, and virtual-input marker; a directory existing by itself is
not enough to report the component package as installed.

## Remote audio output modes

Choose the mode in the NormanRemoteDesktop settings page:

- `Computer speakers and phone` uses ScreenCaptureKit to capture Mac system
  audio while the current speakers/headphones continue to play normally.
- `Norman Remote Audio virtual output` temporarily routes the Mac default
  output and system-output devices to the installed virtual output. The app
  restores the saved devices when the remote audio subscription ends.

The installer does not select either default device. The second mode requires
CoreAudio to have loaded `NormanRemoteAudio.driver`.

Older installations may also contain a legacy local TCC repair script:

```sh
HELPER="$HOME/Library/Application Support/NormanRemoteDesktop/cm-helper"
"$HELPER/repair-tcc.sh" status
"$HELPER/repair-tcc.sh" repair
```

## Explicit audio configuration

Run these commands locally on the controlled Mac after installation:

```sh
HELPER="$HOME/Library/Application Support/NormanRemoteDesktop/cm-helper"
"$HELPER/remote-mic-config.sh" list
"$HELPER/remote-mic-config.sh" select-norman-output
"$HELPER/remote-mic-config.sh" restart
"$HELPER/remote-mic-config.sh" status
```

The `select-norman-output` command is retained as a repair/diagnostic option.
The normal installer already chooses the plug-in's output side for the patched
NormanRemoteDesktop voice-call receiver and records the plug-in's built-in
output-to-input route. In Codex or another Mac application, separately select
`Norman 手机麦克风` as the input. Neither path changes the system default
input/output.

For an existing third-party loopback device, the older explicit candidate
flow remains available:

```sh
"$HELPER/remote-mic-config.sh" set-output "RayLinkAudioDriver 2ch"
"$HELPER/remote-mic-config.sh" restart
"$HELPER/remote-mic-config.sh" status
```

`set-output` enables the opt-in route but clears the loopback confirmation.
The selected device must have an output channel. A device with both input and
output channels is only a candidate: the user must verify with a real input
meter or application that its output is actually looped into its input, then
run:

```sh
"$HELPER/remote-mic-config.sh" mark-loopback-verified
```

That command records the user's explicit confirmation; it does not claim that
CoreAudio device presence proves loopback. `disable` is always available to
return to speaker-only behavior. No system default device is changed.

## State meanings

Older helper installations write fixed audio markers and JSON status under the
helper directory; the app-managed package writes a manifest there instead:

- `disabled`: optional audio route is off after an explicit user disable;
- `requires-patched-rustdesk`: a device was enabled but the installed RustDesk
  binary has no explicit output-routing hook;
- `not-configured`: a patched binary is present but no device was selected;
- `output-only`: the selected device has an output sink but no microphone input channel;
- `input-only`: the microphone input is visible but the RustDesk receiver output sink is not;
- `candidate`: input/output channels exist, but loopback is not user-confirmed;
- `ready`: the user confirmed the loopback configuration;
- `unavailable`: the selected device is no longer present or usable.

Virtual-input markers are independent of the audio route:

- `virtual-input-missing`: the HAL plug-in is not installed;
- `virtual-input-bundle-installed`: the bundle is installed but not visible
  in CoreAudio yet;
- `virtual-input-pending-reload`: CoreAudio has not reloaded the bundle;
- `virtual-input-available`: `Norman 手机麦克风` is visible and selectable.

The package intentionally does not claim that an unsigned development bundle
is production-ready. Supply `NORMAN_CODESIGN_IDENTITY` when building the HAL
plug-in and `NORMAN_INSTALLER_SIGNING_IDENTITY` when building the package, then
notarize the resulting artifacts through the normal Apple distribution
process. A build without `NORMAN_REMOTE_MIC_OUTPUT_DEVICE` still reports
`requires-patched-rustdesk`; install a separately built and signed
NormanRemoteDesktop binary containing the virtual-output route before enabling
the route.

The NormanRemoteDesktop executable also exposes two macOS TCC commands:

```sh
APP="/Applications/NormanRemoteDesktop.app/Contents/MacOS/NormanRemoteDesktop"
"$APP" --tcc-status
"$APP" --repair-tcc
```

The first command only reports Screen Recording, Accessibility, and Input
Monitoring. The second requests the next missing permission through Apple's
public APIs; the user must still confirm it in System Settings. Only the visible
NormanRemoteDesktop.app runs this flow; no package script or background process
requests TCC.

The read-only verifier is also included in the package source payload as
`verify-norman-remote-mic.sh`; it reports bundle, CoreAudio, and NormanRemoteDesktop
receiver status without installing or changing system state.

The runner only passes `NORMAN_REMOTE_MIC_OUTPUT_DEVICE` to NormanRemoteDesktop for an
explicitly configured device when the patched binary and an output channel are
present. Incoming voice-call audio is the only stream routed to the virtual
microphone this way. Computer system audio is a separate ScreenCaptureKit stream
in `Computer speakers and phone` mode. In `Norman Remote Audio virtual output`
mode, the patched app reads the Norman virtual output's input side instead.
