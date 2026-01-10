#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Config
$SCRIPT:Cfg = [ordered]@{
  RepoRoot        = Split-Path -Parent $MyInvocation.MyCommand.Path
  VersionsDirName = "versions"
  DataDirName     = "data"
  CurrentFileName = "current.txt"

  Platform        = "win32-x64-archive"
  Quality         = "stable"

  UpdateApi       = "https://update.code.visualstudio.com/api/update"

  UserAgent       = "vscode-portable-updater/0.1"
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

#region VersionSource
function Get-LatestVersionInfo {
  $url = "$($SCRIPT:Cfg.UpdateApi)/$($SCRIPT:Cfg.Platform)/$($SCRIPT:Cfg.Quality)/latest"

  Write-Log INFO "Fetching latest version info: $url"

  $headers = @{
    "User-Agent" = $SCRIPT:Cfg.UserAgent
  }

  $info = Invoke-RestMethod -Uri $url -Headers $headers -Method Get

  if (-not $info.url -or -not $info.sha256hash -or -not $info.name) {
    throw "Invalid update API response."
  }

  return [ordered]@{
    Version     = [string]$info.name          # e.g. 1.108.0
    DownloadUrl = [string]$info.url           # Actual URL
    Sha256      = [string]$info.sha256hash    # Checksum
  }
}
#endregion VersionSource

#region Downloader
function Download-Zip {
  param(
    [Parameter(Mandatory)][hashtable]$P,
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Version
  )

  $zipPath = Join-Path $P.Downloads "vscode-$Version.zip"
  $zipTmp  = "$zipPath.tmp"

  if (Test-Path $zipPath) {
    Write-Log INFO "Zip already exists, verifying integrity..."

    try {
      # Quick check: try opening as zip
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $fs = [System.IO.File]::OpenRead($zipPath)
      try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs)
        $zip.Dispose()
      } finally {
        $fs.Dispose()
      }

      Write-Log INFO "Existing zip looks valid, reuse: $zipPath"
      return $zipPath
    } catch {
      Write-Log WARN "Existing zip is broken. Redownloading..."
      Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
  }

  Write-Log INFO "Downloading VS Code $Version ..."
  Invoke-WebRequest -Uri $Url -OutFile $zipTmp -UseBasicParsing
  Move-Item -LiteralPath $zipTmp -Destination $zipPath -Force

  return $zipPath
}

function Verify-Checksum {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string]$ExpectedSha256
  )

  Write-Log INFO "Verifying SHA256 checksum..."

  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $FilePath).Hash.ToLower()
  $expected = $ExpectedSha256.ToLower()

  if ($actual -ne $expected) {
    throw "Checksum mismatch! expected=$expected actual=$actual"
  }

  Write-Log INFO "Checksum OK."
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

  # Get latest version info (Step1)
  $latest = Get-LatestVersionInfo
  Write-Log INFO "Latest version: $($latest.Version)"

  # Spec: Check if update needed
  if ($cur -and $cur -eq $latest.Version) {
    Write-Log INFO "No update needed. Already on latest: $cur"
    return
  }

  # Download
  $zip = Download-Zip -P $P -Url $latest.DownloadUrl -Version $latest.Version

  # Verify checksum (mandatory in Step1)
  Verify-Checksum -FilePath $zip -ExpectedSha256 $latest.Sha256

  # Install / inspect
  $result = Install-ZipIfNeeded -P $P -ZipPath $zip
  $newVer = $result.Version

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
  $err = $_ | Out-String
  Write-Log ERROR "Unhandled exception:"
  Write-Log ERROR $err
  Write-Log ERROR "Update aborted. Current version pointer was not changed unless explicitly logged as switched."
  throw
}
#endregion Main
