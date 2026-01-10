#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Config
$SCRIPT:Cfg = [ordered]@{
  RepoRoot        = Split-Path -Parent $MyInvocation.MyCommand.Path
  VersionsDirName = "versions"
  DataDirName     = "data"
  CurrentFileName = "current.txt"

  # Official VS Code download endpoint (always latest)
  DownloadUrl     = "https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-archive"

  UserAgent       = "vscode-portable-updater/0.1"

  # Feature flags (future)
  EnableChecksumVerification = $false
}
#endregion Config

#region Logger
function Write-Log {
  param(
    [Parameter(Mandatory)][ValidateSet("INFO","WARN","ERROR")][string]$Level,
    [Parameter(Mandatory)][string]$Message
  )
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  Write-Host "[$ts][$Level] $Message"
}
#endregion Logger

#region Paths / Environment
function Get-Paths {
  $root = $SCRIPT:Cfg.RepoRoot
  $versions = Join-Path $root $SCRIPT:Cfg.VersionsDirName
  $data = Join-Path $root $SCRIPT:Cfg.DataDirName
  $currentData = Join-Path $data "current"
  $backups = Join-Path $data "backups"
  $currentFile = Join-Path $root $SCRIPT:Cfg.CurrentFileName
  $tmp = Join-Path $root "_tmp"
  $downloads = Join-Path $root "_downloads"

  [ordered]@{
    Root       = $root
    Versions   = $versions
    Data       = $data
    CurrentData= $currentData
    Backups    = $backups
    CurrentTxt = $currentFile
    Tmp        = $tmp
    Downloads  = $downloads
  }
}

function Ensure-Directories {
  param([Parameter(Mandatory)][hashtable]$P)

  foreach ($d in @($P.Versions, $P.Data, $P.CurrentData, $P.Backups, $P.Tmp, $P.Downloads)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
  }

  New-Item -ItemType Directory -Force -Path (Join-Path $P.CurrentData "user-data") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $P.CurrentData "extensions") | Out-Null
}
#endregion Paths / Environment

#region Current Version
function Get-CurrentVersion {
  param([Parameter(Mandatory)][hashtable]$P)

  if (-not (Test-Path $P.CurrentTxt)) { return $null }
  $v = (Get-Content -LiteralPath $P.CurrentTxt -ErrorAction Stop | Select-Object -First 1).Trim()
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  return $v
}

function Set-CurrentVersionAtomically {
  param(
    [Parameter(Mandatory)][hashtable]$P,
    [Parameter(Mandatory)][string]$Version
  )
  $tmpFile = "$($P.CurrentTxt).tmp"
  Set-Content -LiteralPath $tmpFile -Value $Version -NoNewline
  Move-Item -LiteralPath $tmpFile -Destination $P.CurrentTxt -Force
}
#endregion Current Version

#region Downloader
function Download-LatestZip {
  param(
    [Parameter(Mandatory)][hashtable]$P
  )

  $zipPath = Join-Path $P.Downloads "vscode-latest.zip"
  $zipTmp  = "$zipPath.tmp"

  Write-Log INFO "Downloading latest VS Code from official endpoint..."
  Invoke-WebRequest -Uri $SCRIPT:Cfg.DownloadUrl -OutFile $zipTmp -UseBasicParsing

  Move-Item -LiteralPath $zipTmp -Destination $zipPath -Force
  return $zipPath
}

function Verify-ChecksumIfEnabled {
  param([Parameter(Mandatory)][string]$FilePath)

  if (-not $SCRIPT:Cfg.EnableChecksumVerification) { return }

  # Spec hook only (not implemented yet)
  throw "Checksum verification is enabled but not implemented."
}
#endregion Downloader

#region Installer
function Get-VersionFromExtracted {
  param([Parameter(Mandatory)][string]$ExtractDir)

  $productJson = Join-Path $ExtractDir "resources\app\product.json"
  if (-not (Test-Path $productJson)) {
    throw "product.json not found in extracted archive."
  }

  $product = Get-Content $productJson | ConvertFrom-Json
  if (-not $product.version) {
    throw "version not found in product.json"
  }
  return [string]$product.version
}

function Install-ZipIfNeeded {
  param(
    [Parameter(Mandatory)][hashtable]$P,
    [Parameter(Mandatory)][string]$ZipPath
  )

  # Extract to temp
  $extractTmp = Join-Path $P.Tmp ("extract_" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $extractTmp | Out-Null

  Write-Log INFO "Extracting zip to temp: $extractTmp"
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractTmp -Force

  # Normalize root
  $items = Get-ChildItem -LiteralPath $extractTmp
  $root = $extractTmp
  if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
    $root = $items[0].FullName
  }

  # Read version
  $version = Get-VersionFromExtracted -ExtractDir $root
  Write-Log INFO "Extracted version: $version"

  $dest = Join-Path $P.Versions $version
  if (Test-Path $dest) {
    Write-Log INFO "Version $version already installed: $dest"
    Remove-Item -LiteralPath $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
    return [ordered]@{ Version = $version; InstalledPath = $dest; IsNew = $false }
  }

  Write-Log INFO "Installing version $version into: $dest"
  New-Item -ItemType Directory -Force -Path $dest | Out-Null

  Get-ChildItem -LiteralPath $root | ForEach-Object {
    Move-Item -LiteralPath $_.FullName -Destination $dest -Force
  }

  Remove-Item -LiteralPath $extractTmp -Recurse -Force -ErrorAction SilentlyContinue

  $codeExe = Join-Path $dest "Code.exe"
  if (-not (Test-Path $codeExe)) {
    throw "Install seems incomplete: Code.exe not found in $dest"
  }

  return [ordered]@{ Version = $version; InstalledPath = $dest; IsNew = $true }
}
#endregion Installer

#region DataManager
function Backup-CurrentData {
  param([Parameter(Mandatory)][hashtable]$P)

  $ud = Join-Path $P.CurrentData "user-data"
  $ext = Join-Path $P.CurrentData "extensions"

  $hasAny =
    (Test-Path $ud) -and ((Get-ChildItem -LiteralPath $ud -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) `
    -or (Test-Path $ext) -and ((Get-ChildItem -LiteralPath $ext -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)

  if (-not $hasAny) {
    Write-Log INFO "No meaningful current data found; skipping backup (likely first run)."
    return $null
  }

  $stamp = (Get-Date).ToString("yyyy-MM-dd_HHmmss")
  $dest = Join-Path $P.Backups $stamp
  New-Item -ItemType Directory -Force -Path $dest | Out-Null

  Write-Log INFO "Backing up data/current -> $dest"
  Copy-Item -LiteralPath $P.CurrentData\* -Destination $dest -Recurse -Force

  return $dest
}
#endregion DataManager

#region Main
function Main {
  $P = Get-Paths
  Ensure-Directories -P $P

  $cur = Get-CurrentVersion -P $P
  if ($cur) {
    Write-Log INFO "Current version: $cur"
  } else {
    Write-Log INFO "Current version: (not set yet)"
  }

  # Download
  $zip = Download-LatestZip -P $P
  Verify-ChecksumIfEnabled -FilePath $zip

  # Install / inspect
  $result = Install-ZipIfNeeded -P $P -ZipPath $zip
  $newVer = $result.Version

  # Spec: "最新版と同じなら何もしない"
  if ($cur -and $cur -eq $newVer) {
    Write-Log INFO "No update needed. Already on latest: $cur"
    return
  }

  # Backup current data
  $backupPath = Backup-CurrentData -P $P
  if ($backupPath) {
    Write-Log INFO "Backup created: $backupPath"
  }

  # Switch
  Set-CurrentVersionAtomically -P $P -Version $newVer
  Write-Log INFO "Switched current version to: $newVer"

  Write-Log INFO "Done. Launch via launch.cmd"
}

try {
  Main
} catch {
  Write-Log ERROR $_.Exception.Message
  Write-Log ERROR "Update aborted. Current version pointer was not changed unless explicitly logged as switched."
  throw
}
#endregion Main
