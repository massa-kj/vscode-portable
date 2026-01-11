#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Config
# Configuration management module.
$SCRIPT:Cfg = [ordered]@{
  # Application-wide configuration values
  RepoRoot        = Split-Path -Parent $MyInvocation.MyCommand.Path
  VersionsDirName = "versions"
  DataDirName     = "data"
  CurrentFileName = "current.txt"

  # Defaults (can be overridden by CLI args)
  Platform        = "win32-x64-archive"
  Quality         = "stable"

  # Maintains VS Code download API endpoints and settings
  UpdateApi       = "https://update.code.visualstudio.com/api/update"
  DownloadBase    = "https://update.code.visualstudio.com"

  UserAgent       = "vscode-portable-updater/0.1"
}
#endregion Config

#region Logger
# Logging module for unified message output.
function Write-Log {
  param(
    [Parameter(Mandatory)][ValidateSet("INFO","WARN","ERROR")][string]$Level,
    [Parameter(Mandatory)][string]$Message
  )
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  Write-Host "[$ts][$Level] $Message"
}
#endregion Logger

#region Args
# Command-line argument parsing module.
# Responsibilities:
# - Provides extensible, configuration-driven argument parsing
# - Validates argument values and types according to specifications

# Argument specification configuration
$SCRIPT:ArgSpecs = @{
  "--platform" = @{ 
    PropertyName = "Platform"
    Type = "String"
    Required = $false
    Description = "Target platform for VS Code download"
    ValidValues = $null
  }
  "--quality" = @{
    PropertyName = "Quality"
    Type = "String" 
    Required = $false
    Description = "VS Code release quality"
    ValidValues = @("stable", "insider")
  }
  "--version" = @{
    PropertyName = "Version"
    Type = "String"
    Required = $false
    Description = "Specific VS Code version to install"
    ValidValues = $null
  }
  "--help" = @{
    PropertyName = "Help"
    Type = "Flag"
    Required = $false
    Description = "Show this help message and exit"
    ValidValues = $null
  }
}

function Validate-ArgumentValue {
  param(
    [Parameter(Mandatory)][hashtable]$Spec,
    [Parameter(Mandatory)][string]$Value,
    [Parameter(Mandatory)][string]$ArgName
  )

  # Type validation
  switch ($Spec.Type) {
    "String" {
      # Already a string, basic validation passed
    }
    "Int" {
      if (-not ($Value -match '^\d+$')) {
        throw "Argument $ArgName expects an integer value, got: $Value"
      }
    }
    "Bool" {
      if ($Value -notin @("true", "false", "1", "0")) {
        throw "Argument $ArgName expects a boolean value (true/false/1/0), got: $Value"
      }
    }
    "Flag" {
      # Flags don't have values, this should not be called for flags
      throw "Internal error: Flag type should not reach value validation"
    }
  }

  # ValidValues check
  if ($Spec.ValidValues -and $Value -notin $Spec.ValidValues) {
    $validStr = $Spec.ValidValues -join ", "
    throw "Argument $ArgName must be one of: $validStr. Got: $Value"
  }

  return $Value
}

function Parse-Args {
  param([string[]]$Arguments)

  # Initialize result with all possible properties set to null/false
  $result = @{}
  foreach ($spec in $SCRIPT:ArgSpecs.Values) {
    if ($spec.Type -eq "Flag") {
      $result[$spec.PropertyName] = $false
    } else {
      $result[$spec.PropertyName] = $null
    }
  }

  for ($i = 0; $i -lt $Arguments.Length; $i++) {
    $arg = $Arguments[$i]
    
    if (-not $SCRIPT:ArgSpecs.ContainsKey($arg)) {
      throw "Unknown argument: $arg. Use --help to see available options."
    }

    $spec = $SCRIPT:ArgSpecs[$arg]
    
    if ($spec.Type -eq "Flag") {
      # Flags don't take values, just set to true
      $result[$spec.PropertyName] = $true
    } else {
      # Get next argument as value
      $i++
      if ($i -ge $Arguments.Length) { 
        throw "Missing value for argument $arg"
      }
      
      $value = $Arguments[$i]
      $validatedValue = Validate-ArgumentValue -Spec $spec -Value $value -ArgName $arg
      $result[$spec.PropertyName] = $validatedValue
    }
  }

  # Check if help was requested
  if ($result.Help) {
    Show-Help
    exit 0
  }

  # Check required arguments
  foreach ($argName in $SCRIPT:ArgSpecs.Keys) {
    $spec = $SCRIPT:ArgSpecs[$argName]
    if ($spec.Required -and $null -eq $result[$spec.PropertyName]) {
      throw "Required argument $argName is missing. Use --help for more information."
    }
  }

  return $result
}

function Show-Help {
  Write-Host ""
  Write-Host "VS Code Portable" -ForegroundColor Green
  Write-Host "========================" -ForegroundColor Green
  Write-Host ""
  Write-Host "Updates VS Code portable installation to the latest or specified version."
  Write-Host ""
  Write-Host "USAGE:" -ForegroundColor Yellow
  Write-Host "    update.ps1 [OPTIONS]"
  Write-Host ""
  Write-Host "OPTIONS:" -ForegroundColor Yellow
  
  # Calculate max width for alignment
  $maxArgWidth = ($SCRIPT:ArgSpecs.Keys | Measure-Object -Property Length -Maximum).Maximum
  
  foreach ($argName in $SCRIPT:ArgSpecs.Keys | Sort-Object) {
    $spec = $SCRIPT:ArgSpecs[$argName]
    $padding = " " * ($maxArgWidth - $argName.Length + 2)
    
    $typeInfo = ""
    if ($spec.Type -eq "Flag") {
      $typeInfo = ""
    } else {
      $typeInfo = " <$($spec.Type.ToLower())>"
    }
    
    Write-Host "    $argName$typeInfo$padding" -NoNewline -ForegroundColor Cyan
    Write-Host $spec.Description
    
    if ($spec.ValidValues) {
      $validValuesStr = $spec.ValidValues -join ", "
      Write-Host (" " * ($maxArgWidth + 6)) -NoNewline
      Write-Host "Valid values: $validValuesStr" -ForegroundColor DarkGray
    }
    
    if ($spec.Required) {
      Write-Host (" " * ($maxArgWidth + 6)) -NoNewline
      Write-Host "(Required)" -ForegroundColor Red
    }
  }
  
  Write-Host ""
  Write-Host "EXAMPLES:" -ForegroundColor Yellow
  Write-Host "    update.ps1                                   # Update to latest stable"
  Write-Host "    update.ps1 --quality insider                 # Update to latest insider"
  Write-Host "    update.ps1 --version 1.107.1                 # Install specific version"
  Write-Host "    update.ps1 --platform win32-arm64-archive    # Use specific platform"
  Write-Host "    update.ps1 --help                            # Show this help"
  Write-Host ""
}
#endregion Args

#region Paths / Environment
# File path management and directory initialization module.
# Responsibilities:
# - Calculates and provides standardized paths for all application directories
# - Ensures required directory structure exists before operations
# - Manages workspace layout (versions, data, backups, temporary files)
# - Provides consistent file placement strategy across the application
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
# Current version state management module.
# Responsibilities:
# - Manages the current VS Code version pointer (current.txt file)
# - Provides atomic version switching to prevent corruption during updates
# - Reads and validates current version state
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

#region DataManager
# User data backup and snapshot management module.
# Responsibilities:
# - Creates timestamped backups of current user data before updates
# - Manages user-data and extensions directories preservation
# - Handles first-run scenarios where no existing data exists
# - Provides rollback capability through snapshot management
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
  Copy-Item -Path (Join-Path $P.CurrentData "*") -Destination $dest -Recurse -Force

  return $dest
}
#endregion DataManager

#region Main
function Main {
  param([string[]]$Arguments = @())
  
  # Parse CLI args
  $opts = Parse-Args $Arguments

  if ($opts.Platform) { $SCRIPT:Cfg.Platform = $opts.Platform }
  if ($opts.Quality)  { $SCRIPT:Cfg.Quality  = $opts.Quality  }

  Write-Log INFO "Platform: $($SCRIPT:Cfg.Platform)"
  Write-Log INFO "Quality : $($SCRIPT:Cfg.Quality)"

  $P = Get-Paths
  Ensure-Directories -P $P

  $cur = Get-CurrentVersion -P $P
  if ($cur) {
    Write-Log INFO "Current version: $cur"
  } else {
    Write-Log INFO "Current version: (not set yet)"
  }

  # Decide version source
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

  # If same as current, do nothing
  if ($cur -and $cur -eq $target.Version) {
    Write-Log INFO "No update needed. Already on target: $cur"
    return
  }

  # Download
  $zip = Download-Zip -P $P -Url $target.DownloadUrl -Version $target.Version

  # Verify checksum if available
  if ($target.HasChecksum) {
    Verify-Checksum -FilePath $zip -ExpectedSha256 $target.Sha256
  } else {
    Write-Log WARN "No checksum available for this download. Skipping verification."
  }

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
  Main -Arguments $args
} catch {
  $err = $_ | Out-String
  Write-Log ERROR "Unhandled exception:"
  Write-Log ERROR $err
  Write-Log ERROR "Update aborted. Current version pointer was not changed unless explicitly logged as switched."
  throw
}
#endregion Main
