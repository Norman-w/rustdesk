const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
function filesIn(directory) {
  return fs.readdirSync(path.join(root, directory), { withFileTypes: true })
    .flatMap((entry) => entry.isDirectory()
      ? filesIn(`${directory}/${entry.name}`) : [`${directory}/${entry.name}`]);
}

test('macOS implementation is compiled source, not a packaging patch', () => {
  assert.match(read('src/client.rs'), /start_audio_thread_with_output_device/);
  assert.match(read('src/client.rs'), /drop\(self\.audio_stream\.take\(\)\)/);
  assert.match(read('src/server/connection.rs'), /drop\(std::mem::replace\(&mut self\.audio_sender, None\)\)/);
  assert.match(read('src/server/audio_service.rs'), /pub fn refresh_remote_audio_route/);
  assert.match(read('src/server/audio_service.rs'), /HOST_SCREEN_CAPTURE_KIT/);
  assert.match(read('src/platform/macos.mm'), /MacBeginRemoteAudioRoute/);
  assert.match(read('src/platform/macos.mm'), /MacEndRemoteAudioRoute/);
  assert.equal(filesIn('tools').filter((file) => file.endsWith('.patch')).length, 0);
});

test('setup guide, fullscreen setting and native APIs are checked in together', () => {
  const guide = read('flutter/lib/desktop/pages/macos_setup_guide_page.dart');
  const settings = read('flutter/lib/desktop/pages/desktop_setting_page.dart');
  const home = read('flutter/lib/desktop/pages/desktop_home_page.dart');
  assert.match(settings, /children\.add\(const MacosSetupGuidePage\(\)\)/);
  assert.match(settings, /Widget fullScreenSpaceInterruption/);
  assert.match(home, /DesktopSettingPage\.switch2page\(SettingsTabKey\.normanGuide\)/);
  assert.match(guide, /await _showPermissionFlow\(\)/);
  for (const method of ['main_get_tcc_status_json', 'main_repair_tcc_json', 'main_is_norman_virtual_mic_installed']) {
    assert.ok(read('src/flutter_ffi.rs').includes(`pub fn ${method}(`), method);
  }
  for (const language of ['en', 'cn']) {
    const translations = read(`src/lang/${language}.rs`);
    for (const [, key] of guide.matchAll(/translate\('([^']+)'\)/g)) {
      assert.ok(translations.includes(`("${key}",`), `${language}: ${key}`);
    }
  }
});

test('build and packaging have no HarmonyOS checkout or installed app dependency', () => {
  const build = read('tools/build-macos-app.sh');
  assert.match(build, /flutter_rust_bridge_codegen/);
  assert.match(build, /cargo build --locked/);
  assert.match(build, /flutter,screencapturekit/);
  assert.doesNotMatch(build, /\/Applications\/|git\s+.*apply|patch\s+-p/);
  for (const file of filesIn('tools').filter((name) => name.endsWith('.sh'))) {
    assert.doesNotMatch(read(file), /CodexProjects\/NormanRemoteDesktop-HarmonyOS/);
    assert.doesNotMatch(read(file), /rustdesk-1\.4\.9-.*\.patch/);
  }
  assert.doesNotMatch(read('tools/build-rustdesk-cm-helper-pkg.sh'), /build-patched-rustdesk/);
});

test('installer and build verification never request TCC permissions', () => {
  for (const file of ['tools/rustdesk-cm-helper/postinstall', 'tools/rustdesk-cm-helper/run-cm-helper.sh',
    'tools/macos-installer/preinstall', 'tools/macos-installer/postinstall']) {
    const code = read(file).split('\n').filter((line) => !/^\s*#/.test(line)).join('\n');
    assert.doesNotMatch(code, /--repair-tcc|--tcc-status|tccutil|TCC\.db/);
  }
  assert.doesNotMatch(read('tools/verify-macos-distribution.sh'), /tcc_repair=|--repair-tcc 2>/);
});

test('application version agrees with distribution scripts', () => {
  const version = read('Cargo.toml').match(/^version = "([^"]+)"/m)[1];
  assert.match(read('Cargo.lock'), new RegExp(`name = "rustdesk"\\nversion = "${version.replaceAll('.', '\\.')}"`));
  assert.ok(read('flutter/pubspec.yaml').includes(`version: ${version}+`));
  for (const file of ['tools/package-macos-distribution.sh', 'tools/build-rustdesk-cm-helper-pkg.sh',
    'tools/sign-notarize-macos-distribution.sh', 'tools/verify-macos-distribution.sh']) {
    assert.ok(read(file).includes(`NORMAN_MACOS_VERSION:-${version}`), file);
  }
});

test('macOS scripts parse without executing installation actions', () => {
  for (const file of filesIn('tools').filter((file) => /\.sh$|\/(preinstall|postinstall|postinstall-reload-coreaudio)$/.test(file))) {
    execFileSync('/bin/sh', ['-n', path.join(root, file)]);
  }
});
