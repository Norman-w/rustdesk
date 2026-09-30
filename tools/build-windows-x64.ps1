$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
if (-not $IsWindows -or [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'This build requires a Windows x64 host.'
}

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$version = [regex]::Match((Get-Content Cargo.toml -Raw), '(?m)^version = "([^"]+)"').Groups[1].Value
if (-not $version -or (Get-Content flutter/pubspec.yaml -Raw) -notmatch "(?m)^version: $([regex]::Escape($version))\+") {
    throw 'Rust and Flutter versions must agree.'
}
$out = Join-Path $root 'output/windows-x64'
$bundle = Join-Path $root 'output/windows-bundle'
if ((Test-Path $out) -or (Test-Path $bundle)) {
    throw 'Use a clean build directory; existing packages are not overwritten.'
}
New-Item -ItemType Directory -Force $out | Out-Null
$prefix = "NormanRemoteDesktop-Windows-$version-x64"

Push-Location flutter
try { flutter pub get --enforce-lockfile } finally { Pop-Location }
$metadata = cargo metadata --locked --format-version 1 --features flutter --filter-platform x86_64-pc-windows-msvc | ConvertFrom-Json
$enabled = @($metadata.resolve.nodes | Where-Object { $_.id -eq $metadata.resolve.root })[0].features
if ('hwcodec' -in $enabled -or 'vram' -in $enabled) { throw 'Hardware codec features are forbidden in this build.' }
cargo build --locked --features flutter --lib --release
Push-Location flutter
try { flutter build windows --release --no-pub } finally { Pop-Location }
Copy-Item flutter/build/windows/x64/runner/Release $bundle -Recurse
Copy-Item target/release/deps/dylib_virtual_display.dll $bundle

function Assert-X64PE([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or [System.BitConverter]::ToUInt16($bytes, 0) -ne 0x5a4d) { throw "Invalid PE: $Path" }
    $offset = [System.BitConverter]::ToInt32($bytes, 0x3c)
    if ($offset -lt 0 -or $offset + 6 -gt $bytes.Length -or
        [System.BitConverter]::ToUInt32($bytes, $offset) -ne 0x4550 -or
        [System.BitConverter]::ToUInt16($bytes, $offset + 4) -ne 0x8664) { throw "Not an x64 PE: $Path" }
}

function Read-AppOutput([string]$Exe, [string]$Argument) {
    $stdout = Join-Path $out 'probe.stdout'
    $stderr = Join-Path $out 'probe.stderr'
    $process = Start-Process $Exe -ArgumentList $Argument -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (-not $process.WaitForExit(30000)) {
        $process.Kill()
        throw "$Argument probe timed out."
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "$Argument probe failed with $($process.ExitCode)" }
    $text = ([string](Get-Content $stdout -Raw)).Trim()
    Remove-Item $stdout, $stderr
    return $text
}

Assert-X64PE "$bundle/rustdesk.exe"
Assert-X64PE "$bundle/librustdesk.dll"
$reportedVersion = Read-AppOutput "$bundle/rustdesk.exe" '--version'
if ($reportedVersion -ne $version) { throw "Executable reports $reportedVersion, expected $version" }
$buildDate = Read-AppOutput "$bundle/rustdesk.exe" '--build-date'

# Keep upstream Windows installation identity until a separate migration is validated.
Copy-Item LICENSE "$bundle/LICENSE"
Copy-Item docs/WINDOWS_X64_ZH-CN.md "$bundle/README-Norman.md"
Compress-Archive "$bundle/*" "$out/$prefix-portable.zip"
python -m pip install -r libs/portable/requirements.txt
Push-Location libs/portable
try { python generate.py -f $bundle -o . -e "$bundle/rustdesk.exe" -l 5 } finally { Pop-Location }
Copy-Item target/release/rustdesk-portable-packer.exe "$out/$prefix.exe"
Assert-X64PE "$out/$prefix.exe"

Push-Location res/msi
try {
    python preprocess.py -d $bundle --version $version --revision-version 1
    nuget restore msi.sln
    msbuild msi.sln -p:Configuration=Release -p:Platform=x64 /p:TargetVersion=Windows10
    $msi = @(Get-ChildItem Package/bin/x64/Release/en-us/Package.msi)
    if ($msi.Count -ne 1) { throw 'Expected exactly one x64 MSI.' }
    Copy-Item $msi[0].FullName "$out/$prefix.msi"
} finally { Pop-Location }

$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.OpenDatabase("$out/$prefix.msi", 0)
$view = $database.OpenView('SELECT `Value` FROM `Property` WHERE `Property` = ''ProductVersion''')
$view.Execute()
$msiVersion = $view.Fetch().StringData(1)
$view.Close()
if ($msiVersion -ne "$version.1") { throw "MSI version mismatch: $msiVersion" }
$signatures = @('rustdesk.exe', 'librustdesk.dll') | ForEach-Object {
    @{ file = $_; status = (Get-AuthenticodeSignature "$bundle/$_").Status.ToString() }
}
[ordered]@{
    version = $version
    architecture = 'x86_64-pc-windows-msvc'
    sourceCommit = (git rev-parse HEAD)
    cargoFeatures = $enabled
    buildDate = $buildDate
    msiVersion = $msiVersion
    signatures = $signatures
    codeSigning = 'unsigned'
    validation = @('x64 PE headers', 'native DLL load and version command', 'MSI database version')
    liveRemoteSessionTested = $false
    macOSVirtualAudioFeaturesIncluded = $false
} | ConvertTo-Json -Depth 5 | Set-Content "$out/build-info.json" -Encoding utf8NoBOM
Copy-Item docs/WINDOWS_X64_ZH-CN.md "$out/README-Windows.md"
Get-ChildItem $out -File | Sort-Object Name | ForEach-Object {
    "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower())  $($_.Name)"
} | Set-Content "$out/SHA256SUMS.txt" -Encoding ascii
Write-Host "Built Windows x64 packages: $out. Nothing was installed."
