#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Import Core module for Config, Logger, and Paths functionality
$CoreModulePath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "src\Core.psm1"
Import-Module $CoreModulePath -Force

# Import Cli module for command-line interface functionality
$CliModulePath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "src\Cli.psm1"
Import-Module $CliModulePath -Force

# Import DataManager module for data backup and extension management
$DataManagerModulePath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "src\DataManager.psm1"
Import-Module $DataManagerModulePath -Force

# Get configuration and directory specs from Core module
$SCRIPT:Cfg = Get-Config
$SCRIPT:DirectorySpecs = Get-DirectorySpecs

#region Current Version
# Current version state management module.
# Responsibilities:
# - Manages the current VS Code version pointer (current.txt file)
# - Provides atomic version switching to prevent corruption during updates
# - Reads and validates current version state
# - Resolves executable paths for the current version
# - Ensures safe version transitions using temporary file approach
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

function Get-CurrentCodeCli {
  param([Parameter(Mandatory)][hashtable]$P)

  $cur = Get-CurrentVersion -P $P
  if (-not $cur) {
    throw "No current version is set. Cannot rebuild extensions."
  }

  $codeCli = Join-Path $P.Versions "$cur\bin\code.cmd"
  if (-not (Test-Path $codeCli)) {
    throw "Current Code CLI not found: $codeCli"
  }

  return $codeCli
}
#endregion Current Version

#region VersionSource
# VS Code version information retrieval module.
# Responsibilities:
# - Fetches latest VS Code version information from official update API
# - Constructs version information for specified versions
# - Provides download URLs, checksums, and metadata for VS Code releases
# - Handles both latest-version and specific-version request scenarios
function Get-LatestVersionInfo {
  param(
    [Parameter(Mandatory)][string]$Platform,
    [Parameter(Mandatory)][string]$Quality
  )

  $url = "$($SCRIPT:Cfg.UpdateApi)/$Platform/$Quality/latest"
  Write-Log INFO "Fetching latest version info: $url"

  $headers = @{ "User-Agent" = $SCRIPT:Cfg.UserAgent }
  $info = Invoke-RestMethod -Uri $url -Headers $headers -Method Get

  if (-not $info.url -or -not $info.sha256hash -or -not $info.name) {
    throw "Invalid update API response."
  }

  return [ordered]@{
    Version     = [string]$info.name
    DownloadUrl = [string]$info.url
    Sha256      = [string]$info.sha256hash
    HasChecksum = $true
  }
}

function Get-SpecifiedVersionInfo {
  param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Platform,
    [Parameter(Mandatory)][string]$Quality
  )

  $url = "$($SCRIPT:Cfg.DownloadBase)/$Version/$Platform/$Quality"

  Write-Log INFO "Using specified version: $Version"
  Write-Log INFO "Download URL: $url"

  return [ordered]@{
    Version     = $Version
    DownloadUrl = $url
    Sha256      = $null
    HasChecksum = $false
  }
}
#endregion VersionSource

#region Downloader
# VS Code binary download and verification module.
# Responsibilities:
# - Downloads VS Code ZIP archives from official sources
# - Implements download caching and reuse of existing files
# - Performs integrity verification using SHA256 checksums
# - Handles download failures and corrupted file detection with automatic retry
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
# VS Code installation module.
# Responsibilities:
# - Extracts VS Code ZIP archives to version-specific directories
# - Automatically detects actual version numbers from extracted product.json
# - Prevents duplicate installations and manages version isolation
# - Validates installation completeness and binary integrity
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

#region Main
function Main {
  param([string[]]$Arguments = @())

  # =========================
  # Phase: Parse & setup
  # =========================

  $opts = ConvertTo-ParsedArgs $Arguments

  if ($opts.Platform) { $SCRIPT:Cfg.Platform = $opts.Platform }
  if ($opts.Quality)  { $SCRIPT:Cfg.Quality  = $opts.Quality  }

  Write-Log INFO "Platform: $($SCRIPT:Cfg.Platform)"
  Write-Log INFO "Quality : $($SCRIPT:Cfg.Quality)"

  $P = Get-Paths
  New-Directories -P $P

  $cur = Get-CurrentVersion -P $P
  if ($cur) {
    Write-Log INFO "Current version: $cur"
  } else {
    Write-Log INFO "Current version: (not set yet)"
  }

  # =========================
  # Phase: RebuildExtension-only mode
  # =========================

  if ($opts.RebuildExtensions -and -not $opts.Version) {
    Write-Log WARN "Running in rebuildExtension-only mode (no download, no install)."

    # Export list (from FS)
    Export-ExtensionsList `
      -ExtensionsDir (Join-Path $P.CurrentData "extensions") `
      -OutputFile $P.ExtensionsList

    # Backup
    $backupPath = Backup-CurrentData -P $P
    if ($backupPath) {
      Write-Log INFO "Backup created: $backupPath"
    }

    # Rebuild using current Code
    $codeCli = Get-CurrentCodeCli -P $P

    Restore-Extensions `
      -CodeExe $codeCli `
      -ExtensionsListFile $P.ExtensionsList `
      -UserDataDir (Join-Path $P.CurrentData "user-data") `
      -ExtensionsDir (Join-Path $P.CurrentData "extensions")

    Write-Log INFO "RebuildExtension-only operation completed."
    return
  }

  # =========================
  # Phase: Resolve target version
  # =========================

  if ($opts.Version) {
    $target = Get-SpecifiedVersionInfo `
      -Version $opts.Version `
      -Platform $SCRIPT:Cfg.Platform `
      -Quality $SCRIPT:Cfg.Quality
  } else {
    $target = Get-LatestVersionInfo `
      -Platform $SCRIPT:Cfg.Platform `
      -Quality $SCRIPT:Cfg.Quality
  }

  Write-Log INFO "Target version: $($target.Version)"

  # If same version and no rebuild requested → nothing to do
  if ($cur -and $cur -eq $target.Version -and -not $opts.RebuildExtensions) {
    Write-Log INFO "No update needed. Already on target: $cur"
    return
  }

  # =========================
  # Phase: Ensure target version is installed
  # =========================

  $installedPath = Join-Path $P.Versions $target.Version

  if (Test-Path $installedPath) {
    Write-Log INFO "Target version already installed: $installedPath"
    $newVer = $target.Version
    $codeCli = Join-Path $installedPath "bin\code.cmd"
  }
  else {
    Write-Log INFO "Target version is not installed yet. Installing..."

    $zip = Download-Zip -P $P -Url $target.DownloadUrl -Version $target.Version

    if ($target.HasChecksum) {
      Verify-Checksum -FilePath $zip -ExpectedSha256 $target.Sha256
    } else {
      Write-Log WARN "No checksum available for this download. Skipping verification."
    }

    $result = Install-ZipIfNeeded -P $P -ZipPath $zip
    $newVer = $result.Version
    $codeCli = Join-Path $result.InstalledPath "bin\code.cmd"
  }

  # =========================
  # Phase: Data operations
  # =========================

  # Export extensions list (before touching data)
  Export-ExtensionsList `
    -ExtensionsDir (Join-Path $P.CurrentData "extensions") `
    -OutputFile $P.ExtensionsList

  # Backup
  $backupPath = Backup-CurrentData -P $P
  if ($backupPath) {
    Write-Log INFO "Backup created: $backupPath"
  }

  # Optional rebuild
  if ($opts.RebuildExtensions) {
    Restore-Extensions `
      -CodeExe $codeCli `
      -ExtensionsListFile $P.ExtensionsList `
      -UserDataDir (Join-Path $P.CurrentData "user-data") `
      -ExtensionsDir (Join-Path $P.CurrentData "extensions")
  }

  # =========================
  # Phase: Switch pointer
  # =========================

  Set-CurrentVersionAtomically -P $P -Version $newVer
  Write-Log INFO "Switched current version to: $newVer"

  Write-Log INFO "Done. Launch via launch.cmd"
}

try {
  Main -Arguments $args
} catch {
  $err = $_ | Out-String
  Write-Log ERROR "Unhandled exception:"
  Write-Log ERROR $err
  Write-Log ERROR "Update aborted. Current version pointer was not changed unless explicitly logged as switched."
  throw
}
#endregion Main
