<#
.SYNOPSIS
  Build, sign and package PdfCraft for Windows.

.DESCRIPTION
  Produces, in $env:DIST (default: dist/release):
    pdfcraft-<version>-windows-<arch>.msi            per-machine installer (WiX v5)
    pdfcraft-<version>-windows-<arch>-portable.zip   pdfcraft.exe + pdfcraft-cli.exe + models\ + portable.txt

  The binaries link the C runtime statically (+crt-static), so neither the MSI nor the portable
  zip needs the Visual C++ redistributable. Signing is delegated to sign.ps1 (skipped with a
  warning when no signing secrets are set).

  Needs: Rust (MSVC toolchain + the target), curl and the network (the OCR models), the Windows SDK (rc.exe, signtool.exe),
  and WiX v5: dotnet tool install --global wix --version 5.0.2

.EXAMPLE
  pwsh packaging/windows/package.ps1 -Arch x64
  pwsh packaging/windows/package.ps1 -Arch x86 -SkipBuild
  pwsh packaging/windows/package.ps1 -Arch arm64     # cross-compiled; needs the MSVC ARM64 build tools
  pwsh packaging/windows/package.ps1 -Arch x64 -SkipBuild -PortableOnly
#>
param(
  [ValidateSet('x64', 'x86', 'arm64')] [string] $Arch = 'x64',
  [switch] $SkipBuild,
  [switch] $PortableOnly
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Invoke-Native([string] $What, [scriptblock] $Block) {
  Write-Output "==> $What"
  & $Block
  if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" }
}

# The version lives in one place: [workspace.package] version in the root Cargo.toml.
$Version = $env:PDFCRAFT_VERSION
if (-not $Version) {
  $inPkg = $false
  foreach ($line in Get-Content (Join-Path $Root 'Cargo.toml')) {
    if ($line -match '^\s*\[') { $inPkg = ($line.Trim() -eq '[workspace.package]'); continue }
    if ($inPkg -and $line -match '^\s*version\s*=\s*"([^"]+)"') { $Version = $Matches[1]; break }
  }
}
if (-not $Version) { throw 'could not read [workspace.package] version from Cargo.toml' }
if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,119}$') { throw 'version must be a safe file-name component' }
$KoreanBuild = ($env:PDFCRAFT_BUILD_LABEL -match '^ko\.') -or ($Version -match 'korean|ko[.-]')
if ($KoreanBuild -and -not $env:CRAFT_FONTS_DIR) { throw 'Korean releases require CRAFT_FONTS_DIR with NanumGothic and its OFL notice' }
if ($KoreanBuild -and -not (Test-Path -LiteralPath (Join-Path $env:CRAFT_FONTS_DIR 'fonts\nanum-gothic\OFL.txt') -PathType Leaf)) { throw 'Korean releases require fonts/nanum-gothic/OFL.txt' }
# MSI ProductVersion is numeric (major.minor.build); pre-release tags are dropped there.
$MsiVersion = ($Version -split '-')[0]

$Target = switch ($Arch) { 'x64' { 'x86_64-pc-windows-msvc' } 'x86' { 'i686-pc-windows-msvc' } 'arm64' { 'aarch64-pc-windows-msvc' } }
$Dist = if ($env:DIST) { $env:DIST } else { Join-Path $Root 'dist\release' }
$TargetDir = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $Root 'target' }
$Dist = [IO.Path]::GetFullPath($Dist)
$TargetDir = [IO.Path]::GetFullPath($TargetDir)
function Assert-PackageChild([string] $Path, [string] $Parent) {
  $full = [IO.Path]::GetFullPath($Path)
  $prefix = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "package path escapes its parent: $Path" }
  $probe = $full
  while ($probe) {
    if (Test-Path -LiteralPath $probe) {
      if ((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "package path contains a link: $probe" }
    }
    $next = [IO.Path]::GetDirectoryName($probe)
    if ($next -eq $probe) { break }
    $probe = $next
  }
}
$Zip = Join-Path $Dist "pdfcraft-$Version-windows-$Arch-portable.zip"
$Msi = Join-Path $Dist "pdfcraft-$Version-windows-$Arch.msi"
Assert-PackageChild $Zip $Dist
Assert-PackageChild $Msi $Dist
if (Test-Path -LiteralPath $Zip) { throw "preserving existing archive; choose another DIST/version: $Zip" }
if (-not $PortableOnly -and (Test-Path -LiteralPath $Msi)) { throw "preserving existing MSI; choose another DIST/version: $Msi" }
New-Item -ItemType Directory -Force -Path $Dist | Out-Null

if (-not $env:PDFCRAFT_BUILD_SHA) { $env:PDFCRAFT_BUILD_SHA = (git -C $Root rev-parse HEAD 2>$null) }
if (-not $env:PDFCRAFT_BUILD_DATE) { $env:PDFCRAFT_BUILD_DATE = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd') }

Write-Output "PdfCraft $Version for Windows $Arch ($Target)"

if (-not $SkipBuild) {
  # Static CRT: no VC++ redistributable needed. Scoped to the target so host build scripts and
  # proc-macros are unaffected.
  $flagVar = 'CARGO_TARGET_' + ($Target.ToUpper() -replace '-', '_') + '_RUSTFLAGS'
  [Environment]::SetEnvironmentVariable($flagVar, '-C target-feature=+crt-static')
  # Fail the build (rather than warn) if the icon/VERSIONINFO can't be embedded.
  $env:PDFCRAFT_REQUIRE_WINRES = '1'
  Invoke-Native "cargo build ($Target)" { cargo build --release --locked -p pdfcraft -p pdfcraft-cli --target $Target }
}

$Bin = Join-Path $TargetDir "$Target\release"

# Check both binaries' PE headers before packaging. Machine (COFF header) must match -Arch, so an
# x64 build can never ship labelled arm64 (#61). Subsystem (optional header): 2 = Windows GUI,
# 3 = console. The app must be GUI (no console window opens with it, #57); the CLI must stay
# console so its output reaches the terminal.
function Get-PeHeader([string] $Path) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $pe = [BitConverter]::ToInt32($bytes, 0x3C)
  return @{ Machine = [BitConverter]::ToUInt16($bytes, $pe + 4); Subsystem = [BitConverter]::ToUInt16($bytes, $pe + 0x5C) }
}
$Machine = switch ($Arch) { 'x64' { 0x8664 } 'x86' { 0x14C } 'arm64' { 0xAA64 } }
foreach ($check in @(@('pdfcraft.exe', 2), @('pdfcraft-cli.exe', 3))) {
  $h = Get-PeHeader (Join-Path $Bin $check[0])
  if ($h.Machine -ne $Machine) { throw "$($check[0]) is for machine 0x$('{0:X}' -f $h.Machine), expected 0x$('{0:X}' -f $Machine) ($Arch)" }
  if ($h.Subsystem -ne $check[1]) { throw "$($check[0]) has PE subsystem $($h.Subsystem), expected $($check[1])" }
  Write-Output "ok $($check[0]): $Arch, PE subsystem $($h.Subsystem)"
}
# Each invocation owns a fresh workspace. Never recursively delete a prior package or a path
# derived from an environment variable; failed workspaces remain available for inspection.
$Work = Join-Path $TargetDir ("windows-package\work-$Version-$Arch-" + [Guid]::NewGuid().ToString('N'))
$Stage = Join-Path $Work 'stage'
Assert-PackageChild $Work $TargetDir
Assert-PackageChild $Stage $Work
New-Item -ItemType Directory -Path $Stage | Out-Null
Copy-Item (Join-Path $Bin 'pdfcraft.exe'), (Join-Path $Bin 'pdfcraft-cli.exe') $Stage
# The document icon embeds Lucide artwork: carry its ISC notice and the project licences
# beside the binaries in both distributions.
foreach ($f in 'LICENSE-MIT', 'LICENSE-APACHE', 'NOTICE', 'ATTRIBUTION.md') {
  Copy-Item (Join-Path $Root $f) $Stage
}
Copy-Item (Join-Path $Root 'assets\app-icon\LICENSE-document.txt') $Stage

& (Join-Path $PSScriptRoot 'sign.ps1') (Join-Path $Stage 'pdfcraft.exe') (Join-Path $Stage 'pdfcraft-cli.exe')

# OCR models (#103): the app looks in models\ beside pdfcraft.exe. `cargo xtask models` fetches every
# ATTRIBUTION.toml `kind = "model"` file (verified by SHA-256) with its licence and ATTRIBUTION.txt;
# the MSI and the portable zip take the whole folder, so new models ship without naming them here.
$Models = Join-Path $Stage 'models'
New-Item -ItemType Directory -Force -Path $Models | Out-Null
Push-Location $Root
try { Invoke-Native 'cargo xtask models' { cargo xtask models $Models } } finally { Pop-Location }
Remove-Item -Force (Join-Path $Models '*.part') -ErrorAction SilentlyContinue
if (-not (Test-Path (Join-Path $Models 'ATTRIBUTION.txt')) -or -not (Get-ChildItem (Join-Path $Models '*.LICENCE.txt'))) {
  throw "no OCR models in $Models after cargo xtask models"
}

# ---- MSI ---------------------------------------------------------------------------------------
if (-not $PortableOnly) {
Invoke-Native 'wix build' {
  wix build (Join-Path $PSScriptRoot 'pdfcraft.wxs') -arch $Arch `
    (Join-Path $PSScriptRoot 'installer-ui.wxs') `
    -d "Version=$MsiVersion" -d "BinDir=$Stage" -d "ModelsDir=$Models" -d "IconPath=$(Join-Path $Root 'assets\app-icon\pdfcraft.ico')" `
    -o $Msi
}
# Inspect the built MSI, not just the XML, before signing/publishing it. In a child process, so
# its Windows Installer database handle is gone before signtool opens the MSI.
Invoke-Native 'test-msi' { & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $PSScriptRoot 'test-msi.ps1') $Msi }
# wix writes its debug symbols (.wixpdb) next to the MSI; keep them out of the release assets.
Remove-Item -Force -ErrorAction SilentlyContinue ([IO.Path]::ChangeExtension($Msi, '.wixpdb'))
& (Join-Path $PSScriptRoot 'sign.ps1') $Msi
}

# ---- portable zip ------------------------------------------------------------------------------
$Portable = Join-Path $Work "pdfcraft-$Version-windows-$Arch-portable"
Assert-PackageChild $Portable $Work
New-Item -ItemType Directory -Path $Portable | Out-Null
Copy-Item (Join-Path $Stage '*.exe') $Portable
foreach ($f in 'NOTICE', 'LICENSE-document.txt', 'ATTRIBUTION.md') {
  Copy-Item (Join-Path $Stage $f) $Portable
}
Copy-Item -Recurse $Models (Join-Path $Portable 'models')
foreach ($f in 'README.md', 'LICENSE', 'LICENSE-MIT', 'LICENSE-APACHE') {
  $p = Join-Path $Root $f
  if (Test-Path $p) { Copy-Item $p $Portable }
}
# Builds made with craft-fonts (CRAFT_FONTS_DIR, set for every release) embed its fonts: ship their
# licences, fonts\<family>\OFL.txt -> OFL-<family>.txt.
if ($env:CRAFT_FONTS_DIR) {
  $fontRoot = [IO.Path]::GetFullPath($env:CRAFT_FONTS_DIR)
  $fontManifest = Join-Path $fontRoot 'fonts\manifest.txt'
  $families = @{}
  $fontInputs = @()
  foreach ($line in Get-Content -LiteralPath $fontManifest) {
    if (-not $line.Trim() -or $line.Trim().StartsWith('#')) { continue }
    $fields = @($line -split '\s+\|\s+')
    if ($fields.Count -lt 6) { throw "malformed craft-fonts manifest: $line" }
    if ($fields[0] -match '^(Source Han|Source Serif|Source Sans|Noto Sans CJK|Noto Serif CJK)') { continue }
    $fontPath = [IO.Path]::GetFullPath((Join-Path $fontRoot $fields[2].Trim()))
    Assert-PackageChild $fontPath $fontRoot
    if ($fields.Count -lt 7 -or $fields[6].Trim() -notmatch '^[A-Fa-f0-9]{64}$') { throw "missing font input SHA-256: $($fields[0])" }
    $fontHash = (Get-FileHash -LiteralPath $fontPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($fontHash -ine $fields[6].Trim()) { throw "font input SHA-256 mismatch: $($fields[2])" }
    $ofl = [IO.Path]::GetFullPath((Join-Path $fontRoot $fields[5].Trim()))
    Assert-PackageChild $ofl $fontRoot
    if (-not (Test-Path -LiteralPath $ofl -PathType Leaf)) { throw "missing embedded font licence: $ofl" }
    $family = Split-Path (Split-Path $ofl -Parent) -Leaf
    if (-not $families.ContainsKey($family)) {
      Copy-Item -LiteralPath $ofl -Destination (Join-Path $Portable "OFL-$family.txt")
      $families[$family] = $true
    }
    $fontInputs += [ordered]@{ family = $fields[0].Trim(); style = $fields[1].Trim(); file = $fields[2].Trim(); scripts = $fields[3].Trim(); sha256 = $fontHash; licence = $fields[4].Trim(); licence_file = "OFL-$family.txt"; licence_sha256 = (Get-FileHash -LiteralPath $ofl -Algorithm SHA256).Hash.ToLowerInvariant() }
  }
  if ($KoreanBuild -and -not $families.ContainsKey('nanum-gothic')) { throw 'Korean releases require the NanumGothic OFL notice' }
  if ($KoreanBuild -and -not @($fontInputs | Where-Object { $_.family -eq 'NanumGothic' -and $_.scripts -match '(^|,)\s*Hang\s*(,|$)' }).Count) { throw 'Korean releases require a verified NanumGothic Hang manifest entry' }
  $fontRecord = [ordered]@{ schema_version = 1; manifest_sha256 = (Get-FileHash -LiteralPath $fontManifest -Algorithm SHA256).Hash.ToLowerInvariant(); fonts = $fontInputs }
  [IO.File]::WriteAllText((Join-Path $Portable 'FONT-INPUTS.json'), ($fontRecord | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}
if ($KoreanBuild -and -not (Test-Path -LiteralPath (Join-Path $Portable 'OFL-nanum-gothic.txt') -PathType Leaf)) { throw 'Korean package is missing its required NanumGothic OFL notice' }
# portable.txt beside pdfcraft.exe switches on portable mode: settings, logs, recovery files and new
# digital IDs go to PdfCraftData\ next to the exe instead of %APPDATA% (#157; see
# crates/ui-egui/src/portable.rs).
Copy-Item (Join-Path $PSScriptRoot 'portable.txt') $Portable
# Only the explicit stage payload enters the archive; no settings, control files or dev profile.
if (Test-Path -LiteralPath (Join-Path $Portable 'PdfCraftData')) { throw 'refusing to package a portable profile' }
Compress-Archive -Path $Portable -DestinationPath $Zip

# Smoke-test the CLI when this machine can run it. An ARM64 build made on an x64 runner can't run
# here; .github/workflows/windows-arm64.yml installs and runs it on ARM64 instead.
$HostArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
if ($Arch -ne 'arm64' -or $HostArch -eq 'arm64') {
  Invoke-Native 'pdfcraft-cli --version' { & (Join-Path $Stage 'pdfcraft-cli.exe') --version }
} else {
  Write-Output "skipping pdfcraft-cli --version: an $Arch build doesn't run on this $HostArch machine"
}
if ($PortableOnly) { Get-Item -LiteralPath $Zip | Format-Table Name, Length }
else { Get-Item -LiteralPath $Msi, $Zip | Format-Table Name, Length }
Write-Output "Portable payload: $Portable"
