const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const workflow = read('.github/workflows/norman-windows-x64.yml');
const build = read('tools/build-windows-x64.ps1');

test('Windows build is isolated, read-only on GitHub, and software-codec only', () => {
  assert.match(workflow, /branches: \[codex\/windows-x64-release\]/);
  assert.match(workflow, /runs-on: windows-2022/);
  assert.match(workflow, /contents: read/);
  assert.match(workflow, /components: rustfmt/);
  assert.doesNotMatch(workflow, /secrets\.|contents: write|action-gh-release|--hwcodec|--vram/);
  assert.match(workflow, /install --classic .*aom libjpeg-turbo libvpx libyuv opus/);
  assert.doesNotMatch(workflow, /libvmaf|ffmpeg/);
  assert.match(build, /cargo build --locked --features flutter --lib --release/);
  assert.match(build, /'hwcodec' -in \$enabled -or 'vram' -in \$enabled/);
});

test('package versions agree across Rust, Flutter and the portable wrapper', () => {
  const version = read('Cargo.toml').match(/^version = "([^"]+)"/m)[1];
  assert.ok(read('flutter/pubspec.yaml').includes(`version: ${version}+`));
  assert.ok(read('libs/portable/Cargo.toml').includes(`version = "${version}"`));
  for (const name of ['rustdesk', 'rustdesk-portable-packer']) {
    assert.ok(read('Cargo.lock').includes(`name = "${name}"\nversion = "${version}"`));
  }
});

test('packages include dependencies and preserve upstream license and identity', () => {
  assert.match(build, /cargo build --locked --package dylib_virtual_display --release/);
  assert.match(build, /Copy-Item target\/release\/deps\/dylib_virtual_display\.dll \$bundle/);
  assert.match(build, /Copy-Item LICENSE "\$bundle\/LICENSE"/);
  assert.match(build, /Compress-Archive "\$bundle\/\*"/);
  assert.match(build, /python generate\.py/);
  assert.match(build, /python preprocess\.py --arp/);
  assert.doesNotMatch(build, /--app-name|msiexec|\/Applications\//);
});

test('validation checks architecture, DLL loading, MSI version and checksums without installing', () => {
  assert.match(build, /-ne 0x8664/);
  assert.match(build, /Read-AppOutput "\$bundle\/rustdesk\.exe" '--version'/);
  assert.match(build, /WaitForExit\(30000\)/);
  assert.match(build, /MSI version mismatch/);
  assert.match(build, /Get-FileHash .* -Algorithm SHA256/);
  assert.match(build, /liveRemoteSessionTested = \$false/);
  assert.match(build, /codeSigning = 'unsigned'/);
});
