<#
.SYNOPSIS
  Verify, publish and activate a custom Korean PdfCraft portable release on this PC.
.DESCRIPTION
  Run only for an authorized deployment. No application is stopped and no registry association,
  server, scheduled task or upstream installation is changed. Existing releases are retained.
  See docs/windows-korean-deployment.md for the manifest contract and rollback instructions.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $PackageDirectory,
  [Parameter(Mandatory)] [string] $PackageZip,
  [Parameter(Mandatory)] [ValidatePattern('^[A-Fa-f0-9]{64}$')] [string] $ExpectedZipSha256,
  [string] $InstallRoot = 'D:\Codex\ArtCraft\PDFCraft',
  [string] $ReleaseId,
  [string] $OriginalProfileDirectory,
  [string] $OriginalPackageRoot = 'D:\Codex\ArtCraft\ARTCRAFT-Windows',
  [string] $PublicEvidenceDirectory,
  [string[]] $PublicEvidenceFiles = @(),
  [switch] $NoShortcuts
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Full-Path([string] $Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
function Assert-Child([string] $Path, [string] $Parent) {
  $full = Full-Path $Path
  $prefix = (Full-Path $Parent) + [IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "path escapes its parent: $Path" }
}
function Assert-NoLink([string] $Path) {
  $probe = [IO.Path]::GetFullPath($Path)
  while ($probe) {
    $item = Get-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "refusing linked path: $probe" }
    $next = [IO.Path]::GetDirectoryName($probe)
    if ($next -eq $probe) { break }
    $probe = $next
  }
}
function Safe-Relative([string] $Path) {
  if (-not $Path -or $Path -match '[\x00-\x1f:<>"|?*]' -or [IO.Path]::IsPathRooted($Path)) { throw "invalid relative path: $Path" }
  $parts = @($Path.Replace('\', '/').Split('/'))
  foreach ($part in $parts) {
    if (-not $part -or $part -in @('.', '..') -or $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw "unsafe path component: $Path" }
  }
  $parts -join '/'
}
function Assert-PayloadName([string] $Relative) {
  if ($Relative -match '(?i)(^|/)(PdfCraftData|profile|\.git|\.env|recovery|autosaves?)(/|$)' -or
      $Relative -match '(?i)(^|/)(control[^/]*|[^/]*token[^/]*|credentials?[^/]*)(/|$)' -or
      $Relative -match '(?i)\.(pfx|p12|key|pem)$') { throw "private/runtime data is forbidden in a package: $Relative" }
}
function Get-PlainFiles([string] $Directory, [switch] $InstalledRelease) {
  Assert-NoLink $Directory
  $pending = [Collections.Generic.Queue[string]]::new()
  $pending.Enqueue($Directory)
  while ($pending.Count) {
    $dir = $pending.Dequeue()
    foreach ($entry in Get-ChildItem -LiteralPath $dir -Force) {
      if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $relative = $entry.FullName.Substring($Directory.Length + 1).Replace('\', '/')
        if ($InstalledRelease -and $relative -ceq 'PdfCraftData' -and $entry.PSIsContainer) {
          $targets = @($entry.Target)
          if ($targets.Count -ne 1 -or (Full-Path $targets[0]) -ine $script:Profile) { throw 'installed profile junction has an unexpected target' }
          continue
        }
        throw "refusing linked entry: $($entry.FullName)"
      }
      if ($entry.PSIsContainer) { $pending.Enqueue($entry.FullName) }
      else { $entry }
    }
  }
}
function Copy-PlainTree([string] $Source, [string] $Destination) {
  Assert-NoLink $Source
  Assert-NoLink $Destination
  # Enumerate and check the entire tree before copying any private profile data.
  $files = @(Get-PlainFiles $Source)
  if (Test-Path -LiteralPath $Destination) {
    if (@(Get-ChildItem -LiteralPath $Destination -Force).Count) { throw "refusing to overwrite a nonempty directory: $Destination" }
  } else { New-Item -ItemType Directory -Path $Destination | Out-Null }
  $pending = [Collections.Generic.Queue[string]]::new()
  $pending.Enqueue($Source)
  while ($pending.Count) {
    foreach ($directory in Get-ChildItem -LiteralPath $pending.Dequeue() -Directory -Force) {
      if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "profile directory changed to a link: $($directory.FullName)" }
      $relative = Safe-Relative $directory.FullName.Substring($Source.Length + 1)
      $target = Join-Path $Destination $relative
      Assert-Child $target $Destination
      New-Item -ItemType Directory -Force -Path $target | Out-Null
      $pending.Enqueue($directory.FullName)
    }
  }
  foreach ($file in $files) {
    $relative = Safe-Relative $file.FullName.Substring($Source.Length + 1)
    $target = Join-Path $Destination $relative
    Assert-Child $target $Destination
    $parent = Split-Path $target -Parent
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [IO.File]::Copy($file.FullName, $target, $false)
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) { throw "profile backup readback mismatch: $relative" }
  }
}
function Protect-PrivateDirectory([string] $Path) {
  # New local backup/profile folders may hold digital IDs. Do not inherit broad workspace ACLs.
  $acl = [Security.AccessControl.DirectorySecurity]::new()
  $acl.SetAccessRuleProtection($true, $false)
  $identities = @([Security.Principal.WindowsIdentity]::GetCurrent().User,
                   [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
                   [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
  foreach ($identity in $identities) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
  }
  Set-Acl -LiteralPath $Path -AclObject $acl
}
function Write-Atomic([string] $Path, [string] $Text, [Text.Encoding] $Encoding = [Text.UTF8Encoding]::new($false)) {
  Assert-NoLink $Path
  $temp = Join-Path (Split-Path $Path -Parent) ('.write-' + [Guid]::NewGuid().ToString('N'))
  [IO.File]::WriteAllText($temp, $Text, $Encoding)
  # PowerShell otherwise converts $null to an empty string for the backup-file argument.
  if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
  else { [IO.File]::Move($temp, $Path) }
}
function Assert-AppClosed {
  $running = @(Get-Process -Name pdfcraft -ErrorAction SilentlyContinue)
  if ($running.Count) {
    $ids = ($running | ForEach-Object { $_.Id }) -join ', '
    throw "PdfCraft is running (PID $ids). Save your work and close every PdfCraft window normally, then rerun. No process was stopped."
  }
}
function Assert-Inventory([string] $Directory, [switch] $InstalledRelease) {
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($file in @(Get-PlainFiles $Directory -InstalledRelease:$InstalledRelease)) {
    $relative = Safe-Relative $file.FullName.Substring($Directory.Length + 1)
    if (-not $seen.Add($relative)) { throw "duplicate package file: $relative" }
    if ($relative -ceq 'release-manifest.json') {
      if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ine $script:ManifestHash) { throw 'release manifest differs from the verified source' }
      continue
    }
    if (-not $script:Inventory.ContainsKey($relative)) { throw "unexpected file: $relative" }
    $expected = $script:Inventory[$relative]
    if ($file.Length -ne [long]$expected.length -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ine $expected.sha256) { throw "package file size/hash mismatch: $relative" }
  }
  if ($seen.Count -ne $script:Inventory.Count + 1) { throw 'package is missing inventoried files or its manifest' }
}
function Assert-ZipInventory([string] $ZipPath) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $manifests = @($archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -match '(^|/)release-manifest\.json$' })
    if ($manifests.Count -ne 1) { throw 'ZIP must contain exactly one release-manifest.json' }
    $manifestName = $manifests[0].FullName.Replace('\', '/')
    $prefix = $manifestName.Substring(0, $manifestName.Length - 'release-manifest.json'.Length)
    if ($prefix) { [void](Safe-Relative $prefix.TrimEnd('/')) }
    $files = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $archive.Entries) {
      $name = $entry.FullName.Replace('\', '/')
      $isDirectory = $name.EndsWith('/')
      [void](Safe-Relative $name.TrimEnd('/'))
      if (-not $names.Add($name.TrimEnd('/'))) { throw "duplicate ZIP entry: $name" }
      $unixKind = ($entry.ExternalAttributes -shr 16) -band 0xF000
      if ($unixKind -eq 0xA000 -or ($entry.ExternalAttributes -band 0x400)) { throw "linked ZIP entry: $name" }
      if (-not $name.StartsWith($prefix, [StringComparison]::Ordinal)) { throw "ZIP entry is outside its package root: $name" }
      $relative = $name.Substring($prefix.Length).TrimEnd('/')
      if (-not $relative) { if ($isDirectory) { continue }; throw 'invalid ZIP root entry' }
      [void](Safe-Relative $relative)
      if ($isDirectory) { continue }
      Assert-PayloadName $relative
      if (-not $files.Add($relative)) { throw "duplicate ZIP payload: $relative" }
      if ($relative -ceq 'release-manifest.json') {
        $expectedHash = $script:ManifestHash
        $expectedLength = (Get-Item -LiteralPath $script:ManifestPath).Length
      } elseif ($script:Inventory.ContainsKey($relative)) {
        $expectedHash = $script:Inventory[$relative].sha256
        $expectedLength = [long]$script:Inventory[$relative].length
      } else { throw "unexpected ZIP file: $relative" }
      if ($entry.Length -ne $expectedLength) { throw "ZIP file length mismatch: $relative" }
      $stream = $entry.Open()
      $sha = [Security.Cryptography.SHA256]::Create()
      try { $actualHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
      finally { $stream.Dispose(); $sha.Dispose() }
      if ($actualHash -ine $expectedHash) { throw "ZIP payload hash mismatch: $relative" }
    }
    if ($files.Count -ne $script:Inventory.Count + 1) { throw 'ZIP is missing inventoried files' }
  } finally { $archive.Dispose() }
}

$PackageDirectory = Full-Path $PackageDirectory
$PackageZip = [IO.Path]::GetFullPath($PackageZip)
$InstallRoot = Full-Path $InstallRoot
$OriginalPackageRoot = Full-Path $OriginalPackageRoot
if ($InstallRoot -match '[\r\n%!]') { throw 'install root contains unsupported launcher characters' }
if ($InstallRoot -eq [IO.Path]::GetPathRoot($InstallRoot).TrimEnd('\', '/')) { throw 'installation at a drive root is forbidden' }
if ($InstallRoot -ieq $OriginalPackageRoot -or
    $InstallRoot.StartsWith($OriginalPackageRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $OriginalPackageRoot.StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'installation root must be separate from the protected original package tree' }
Assert-NoLink $PackageDirectory
Assert-NoLink $PackageZip
Assert-NoLink $InstallRoot
if (-not (Test-Path -LiteralPath $PackageDirectory -PathType Container)) { throw 'package directory does not exist' }
if (-not (Test-Path -LiteralPath $PackageZip -PathType Leaf)) { throw 'package ZIP does not exist' }
if ((Get-FileHash -LiteralPath $PackageZip -Algorithm SHA256).Hash -ine $ExpectedZipSha256) { throw 'ZIP SHA-256 does not match the approved package' }
$script:ManifestPath = Join-Path $PackageDirectory 'release-manifest.json'
$manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
if ($manifest.schema_version -ne 1) { throw 'unsupported release manifest schema_version' }
if (-not $ReleaseId) { $ReleaseId = [string]$manifest.release_id }
if ($ReleaseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,119}$' -or $ReleaseId -cne $manifest.release_id) { throw 'release ID is invalid or differs from the package manifest' }
$script:ManifestHash = (Get-FileHash -LiteralPath $script:ManifestPath -Algorithm SHA256).Hash
$script:Inventory = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in @($manifest.files)) {
  $relative = Safe-Relative ([string]$file.path)
  Assert-PayloadName $relative
  if ($relative -ieq 'release-manifest.json' -or $file.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or [long]$file.length -lt 0) { throw "invalid inventory entry: $relative" }
  if ($script:Inventory.ContainsKey($relative)) { throw "duplicate manifest entry: $relative" }
  $script:Inventory.Add($relative, $file)
}
if (-not $script:Inventory.Count -or $script:Inventory.Count -gt 100000) { throw 'invalid inventory size' }
foreach ($required in @('pdfcraft.exe', 'pdfcraft-cli.exe', 'portable.txt', 'ATTRIBUTION.md', 'NOTICE', 'LICENSE-MIT', 'LICENSE-APACHE', 'OFL-nanum-gothic.txt', 'README-KOREAN.md')) {
  if (-not $script:Inventory.ContainsKey($required)) { throw "required release file is missing: $required" }
}
Assert-Inventory $PackageDirectory
Assert-ZipInventory $PackageZip

$script:Profile = Join-Path $InstallRoot 'profile'
$releaseRoot = Join-Path $InstallRoot 'releases'
$releasePath = Join-Path $releaseRoot $ReleaseId
$publicationRoot = Join-Path $InstallRoot 'updates'
$publicationPath = Join-Path $publicationRoot $ReleaseId
foreach ($path in @($script:Profile, $releaseRoot, $releasePath, $publicationRoot, $publicationPath)) { Assert-Child $path $InstallRoot; Assert-NoLink $path }
if ($PackageDirectory.StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or $PackageDirectory -ieq $InstallRoot) { throw 'package source must be outside the installation root' }
if (Test-Path -LiteralPath $releasePath) { Assert-Inventory $releasePath -InstalledRelease }

$evidence = @()
if ($PublicEvidenceFiles.Count -and -not $PublicEvidenceDirectory) { throw 'PublicEvidenceDirectory is required for an evidence allowlist' }
if ($PublicEvidenceDirectory) {
  $PublicEvidenceDirectory = Full-Path $PublicEvidenceDirectory
  Assert-NoLink $PublicEvidenceDirectory
  $evidenceSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($name in $PublicEvidenceFiles) {
    $relative = Safe-Relative $name
    Assert-PayloadName $relative
    if ($relative -match '/' -or [IO.Path]::GetExtension($relative) -notin @('.json', '.png', '.txt', '.md') -or -not $evidenceSeen.Add($relative)) { throw "invalid or duplicate public evidence name: $name" }
    $source = Join-Path $PublicEvidenceDirectory $relative
    Assert-Child $source $PublicEvidenceDirectory
    Assert-NoLink $source
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "missing allowlisted evidence: $name" }
    $evidence += [pscustomobject]@{ source = $source; name = $relative; sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash }
  }
}
if ($OriginalProfileDirectory) {
  $OriginalProfileDirectory = Full-Path $OriginalProfileDirectory
  Assert-Child $OriginalProfileDirectory $OriginalPackageRoot
  Assert-NoLink $OriginalProfileDirectory
  if ((Split-Path $OriginalProfileDirectory -Leaf) -cne 'PdfCraftData' -or -not (Test-Path -LiteralPath $OriginalProfileDirectory -PathType Container)) { throw 'original profile must be an existing PdfCraftData directory under OriginalPackageRoot' }
  [void]@(Get-PlainFiles $OriginalProfileDirectory)
}
if (Test-Path -LiteralPath $script:Profile) { [void]@(Get-PlainFiles $script:Profile) }
Assert-AppClosed

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
$lockPath = Join-Path $InstallRoot '.install.lock'
Assert-NoLink $lockPath
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
  Assert-AppClosed
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $backup = Join-Path $InstallRoot "backups\$stamp"
  Assert-Child $backup $InstallRoot
  Assert-NoLink $backup
  New-Item -ItemType Directory -Path $backup | Out-Null
  Protect-PrivateDirectory $backup
  $launcherPath = Join-Path $InstallRoot 'Run-PDFCraft.cmd'
  $psLauncherPath = Join-Path $InstallRoot 'Run-PDFCraft.ps1'
  $pointerPath = Join-Path $InstallRoot 'current.json'
  foreach ($path in @($launcherPath, $psLauncherPath, $pointerPath)) {
    Assert-NoLink $path
    if (Test-Path -LiteralPath $path) { [IO.File]::Copy($path, (Join-Path $backup (Split-Path $path -Leaf)), $false) }
  }
  if (Test-Path -LiteralPath $pointerPath) {
    $oldPointer = Get-Content -LiteralPath $pointerPath -Raw | ConvertFrom-Json
    if ($oldPointer.release_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,119}$') { throw 'existing current.json is not a compatible release pointer' }
  } elseif ((Test-Path -LiteralPath $launcherPath) -or (Test-Path -LiteralPath $psLauncherPath)) { throw 'launcher exists without an owned current.json; refusing to overwrite it' }
  $shell = $null
  $shortcutPaths = @()
  if (-not $NoShortcuts) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcutPaths = @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'PDFCraft (한국어).lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'PDFCraft (한국어).lnk'))
  }
  $shortcutIndex = 0
  foreach ($path in $shortcutPaths) {
    Assert-NoLink $path
    if (Test-Path -LiteralPath $path) {
      $existing = $shell.CreateShortcut($path)
      if ($existing.TargetPath -ine $launcherPath) { throw "shortcut name conflicts with an unrelated target: $path" }
      [IO.File]::Copy($path, (Join-Path $backup "shortcut-$shortcutIndex.lnk"), $false)
    }
    $shortcutIndex++
  }
  if (Test-Path -LiteralPath $script:Profile) { Copy-PlainTree $script:Profile (Join-Path $backup 'profile') }
  if ($OriginalProfileDirectory) { Copy-PlainTree $OriginalProfileDirectory (Join-Path $backup 'original-PdfCraftData') }
  if (-not (Test-Path -LiteralPath $script:Profile)) {
    New-Item -ItemType Directory -Path $script:Profile | Out-Null
    Protect-PrivateDirectory $script:Profile
    if ($OriginalProfileDirectory) { Copy-PlainTree $OriginalProfileDirectory $script:Profile }
  }
  New-Item -ItemType Directory -Force -Path $releaseRoot, $publicationRoot | Out-Null
  if (-not (Test-Path -LiteralPath $releasePath)) {
    $stage = Join-Path $releaseRoot ('.staging-' + $ReleaseId + '-' + [Guid]::NewGuid().ToString('N'))
    Assert-Child $stage $releaseRoot
    Assert-NoLink $stage
    New-Item -ItemType Directory -Path $stage | Out-Null
    foreach ($relative in @($script:Inventory.Keys) + @('release-manifest.json')) {
      $target = Join-Path $stage $relative
      Assert-Child $target $stage
      New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
      [IO.File]::Copy((Join-Path $PackageDirectory $relative), $target, $false)
    }
    Assert-Inventory $stage
    New-Item -ItemType Junction -Path (Join-Path $stage 'PdfCraftData') -Target $script:Profile | Out-Null
    Assert-Inventory $stage -InstalledRelease
    Assert-Child $releasePath $releaseRoot
    [IO.Directory]::Move($stage, $releasePath)
  }
  Assert-Inventory $releasePath -InstalledRelease
  $installedProfile = Join-Path $releasePath 'PdfCraftData'
  if (-not (Test-Path -LiteralPath $installedProfile)) { throw 'installed release is missing its persistent profile junction' }

  # Publication uses a caller-provided evidence allowlist. Profiles, input PDFs and control
  # credentials are never walked or copied into updates/. Existing conflicting files stop work.
  New-Item -ItemType Directory -Force -Path $publicationPath | Out-Null
  $publishFiles = @([pscustomobject]@{ source = $PackageZip; name = (Split-Path $PackageZip -Leaf); sha256 = $ExpectedZipSha256 },
                    [pscustomobject]@{ source = (Join-Path $PackageDirectory 'README-KOREAN.md'); name = 'README-KOREAN.md'; sha256 = $script:Inventory['README-KOREAN.md'].sha256 },
                    [pscustomobject]@{ source = $script:ManifestPath; name = 'release-manifest.json'; sha256 = $script:ManifestHash }) + $evidence
  $allowedPublication = @($publishFiles | ForEach-Object name) + @((Split-Path $PackageZip -Leaf) + '.sha256')
  foreach ($file in @(Get-PlainFiles $publicationPath)) {
    $relative = Safe-Relative $file.FullName.Substring($publicationPath.Length + 1)
    if ($relative -notin $allowedPublication) { throw "unexpected existing publication file; preserving it: $relative" }
  }
  foreach ($item in $publishFiles) {
    $target = Join-Path $publicationPath $item.name
    Assert-Child $target $publicationPath
    Assert-NoLink $target
    if (Test-Path -LiteralPath $target) {
      if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $item.sha256) { throw "publication conflict; preserving existing file: $target" }
    } else { [IO.File]::Copy($item.source, $target, $false) }
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $item.sha256) { throw "publication readback mismatch: $target" }
  }
  $hashPath = Join-Path $publicationPath ((Split-Path $PackageZip -Leaf) + '.sha256')
  $hashText = $ExpectedZipSha256.ToLowerInvariant() + '  ' + (Split-Path $PackageZip -Leaf) + "`r`n"
  if (Test-Path -LiteralPath $hashPath) {
    if ([IO.File]::ReadAllText($hashPath) -cne $hashText) { throw 'existing ZIP hash sidecar conflicts' }
  } else { Write-Atomic $hashPath $hashText }

  $psLauncher = @'
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$pointer = Get-Content -LiteralPath (Join-Path $root 'current.json') -Raw | ConvertFrom-Json
if ($pointer.release_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,119}$') { throw 'Invalid PDFCraft release pointer' }
$release = Join-Path (Join-Path $root 'releases') $pointer.release_id
$exe = Join-Path $release 'pdfcraft.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'The active PDFCraft executable is missing' }
$quoted = foreach ($arg in $args) {
  '"' + [regex]::Replace([regex]::Replace([string]$arg, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
if (@($quoted).Count) { Start-Process -FilePath $exe -WorkingDirectory $release -ArgumentList ($quoted -join ' ') }
else { Start-Process -FilePath $exe -WorkingDirectory $release }
'@
  $cmdLauncher = "@echo off`r`nsetlocal`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Run-PDFCraft.ps1`" %*`r`n"
  Assert-AppClosed
  Write-Atomic $psLauncherPath $psLauncher
  Write-Atomic $launcherPath $cmdLauncher ([Text.Encoding]::ASCII)
  foreach ($path in $shortcutPaths) {
    New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
    $tempShortcut = Join-Path (Split-Path $path -Parent) ('.pdfcraft-' + [Guid]::NewGuid().ToString('N') + '.lnk')
    $shortcut = $shell.CreateShortcut($tempShortcut)
    $shortcut.TargetPath = $launcherPath
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.IconLocation = (Join-Path $releasePath 'pdfcraft.exe') + ',0'
    $shortcut.Description = 'PDFCraft 한국어'
    $shortcut.WindowStyle = 7
    $shortcut.Save()
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tempShortcut, $path, [NullString]::Value) }
    else { [IO.File]::Move($tempShortcut, $path) }
  }
  $pointer = [ordered]@{ schema_version = 1; release_id = $ReleaseId; version = $manifest.version; executable = "releases/$ReleaseId/pdfcraft.exe"; manifest_sha256 = $script:ManifestHash.ToLowerInvariant(); zip_sha256 = $ExpectedZipSha256.ToLowerInvariant(); installed_utc = [DateTime]::UtcNow.ToString('o'); backup = $backup; verification = 'payload-and-publication-readback; UI verification is required separately' }
  $receipt = [ordered]@{ release_id = $ReleaseId; package_zip = $PackageZip; install_root = $InstallRoot; profile = $script:Profile; publication = $publicationPath; backup = $backup; shortcuts = $shortcutPaths; public_evidence = @($evidence | ForEach-Object name); application_stopped = $false; previous_releases_preserved = $true; pointer_activation = 'last atomic operation; verify current.json after this command' }
  Write-Atomic (Join-Path $backup 'install-receipt.json') ($receipt | ConvertTo-Json -Depth 6)
  Assert-AppClosed
  Write-Atomic $pointerPath ($pointer | ConvertTo-Json -Depth 6)
  [pscustomobject]@{ release_id = $ReleaseId; executable = (Join-Path $releasePath 'pdfcraft.exe'); launcher = $launcherPath; profile = $script:Profile; current_json = $pointerPath; publication = $publicationPath; backup = $backup; status = 'activated; launch and live UI verification still required' }
} finally { $lock.Dispose() }
