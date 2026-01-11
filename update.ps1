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

# Directory structure specification - defines workspace layout
$SCRIPT:DirectorySpecs = @{
  "Versions" = @{
    RelativePath = $null  # Will use VersionsDirName from Cfg
    AutoCreate = $true
    Description = "VS Code version installations"
  }
  "Data" = @{
    RelativePath = $null  # Will use DataDirName from Cfg  
    AutoCreate = $true
    Description = "User data and settings storage"
  }
  "CurrentData" = @{
    RelativePath = "data/current"
    AutoCreate = $true
    Description = "Active user data and extensions"
  }
  "Backups" = @{
    RelativePath = "data/backups"
    AutoCreate = $true
    Description = "Timestamped user data backups"
  }
  "Tmp" = @{
    RelativePath = "_tmp"
    AutoCreate = $true
    Description = "Temporary files during operations"
  }
  "Downloads" = @{
    RelativePath = "_downloads"
    AutoCreate = $true
    Description = "Downloaded VS Code archives cache"
  }
  "CurrentTxt" = @{
    RelativePath = $null  # Will use CurrentFileName from Cfg
    AutoCreate = $false
    Description = "Current version pointer file"
    IsFile = $true
  }
  # Sub-directories that need special handling
  "UserData" = @{
    RelativePath = "data/current/user-data"
    AutoCreate = $true
    Description = "VS Code user configuration and settings"
  }
  "Extensions" = @{
    RelativePath = "data/current/extensions"
    AutoCreate = $true
    Description = "VS Code extensions storage"
  }
  "ExtensionsList" = @{
    RelativePath = "data/current/extension-list.txt"
    AutoCreate = $false
    Description = "Snapshot of installed extension IDs"
    IsFile = $true
  }
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
  "--show-paths" = @{
    PropertyName = "ShowPaths"
    Type = "Flag"
    Required = $false
    Description = "Show directory configuration and exit"
    ValidValues = $null
  }
  "--rebuild-extensions" = @{
    PropertyName = "RebuildExtensions"
    Type = "Flag"
    Required = $false
    Description = "Rebuild extensions directory from extension list (clean reinstall)"
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

  # Check if show-paths was requested  
  if ($result.ShowPaths) {
    Get-DirectoryInfo
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
  Write-Host "    update.ps1 --rebuild-extensions              # Rebuild extensions from list"
  Write-Host "    update.ps1 --show-paths                      # Show all relevant paths"
  Write-Host "    update.ps1 --help                            # Show this help"
  Write-Host ""
}
#endregion Args

#region Paths / Environment
# File path management and directory initialization module.
# Responsibilities:
# - Calculates and provides standardized paths based on DirectorySpecs configuration
# - Ensures required directory structure exists according to AutoCreate settings
# - Manages workspace layout through configuration-driven approach
# - Provides consistent file placement strategy that can be easily modified

function Resolve-DirectoryPath {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][hashtable]$Spec
  )
  
  $root = $SCRIPT:Cfg.RepoRoot
  
  # Handle special cases that reference config values
  if ($null -eq $Spec.RelativePath) {
    switch ($Name) {
      "Versions" { return Join-Path $root $SCRIPT:Cfg.VersionsDirName }
      "Data" { return Join-Path $root $SCRIPT:Cfg.DataDirName }
      "CurrentTxt" { return Join-Path $root $SCRIPT:Cfg.CurrentFileName }
      default { throw "No RelativePath specified for directory '$Name'" }
    }
  }
  
  return Join-Path $root $Spec.RelativePath
}

function Get-Paths {
  $paths = [ordered]@{}
  
  foreach ($name in $SCRIPT:DirectorySpecs.Keys) {
    $spec = $SCRIPT:DirectorySpecs[$name]
    $path = Resolve-DirectoryPath -Name $name -Spec $spec
    $paths[$name] = $path
  }
  
  # Add Root for backward compatibility
  $paths["Root"] = $SCRIPT:Cfg.RepoRoot
  
  return $paths
}

function Ensure-Directories {
  param([Parameter(Mandatory)][hashtable]$P)

  foreach ($name in $SCRIPT:DirectorySpecs.Keys) {
    $spec = $SCRIPT:DirectorySpecs[$name]
    
    # Skip files and directories that shouldn't be auto-created
    if (-not $spec.AutoCreate) { continue }
    if ($spec.ContainsKey("IsFile") -and $spec.IsFile) { continue }
    
    $path = $P[$name]
    if ($path) {
      Write-Log INFO "Ensuring directory exists: $name -> $path"
      New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
  }
}

function Get-DirectoryInfo {
  # Utility function to show current directory configuration
  Write-Host "Directory Configuration:" -ForegroundColor Green
  Write-Host "=======================" -ForegroundColor Green
  
  $paths = Get-Paths
  $maxNameWidth = ($SCRIPT:DirectorySpecs.Keys | Measure-Object -Property Length -Maximum).Maximum
  
  foreach ($name in $SCRIPT:DirectorySpecs.Keys | Sort-Object) {
    $spec = $SCRIPT:DirectorySpecs[$name]
    $path = $paths[$name]
    $padding = " " * ($maxNameWidth - $name.Length + 2)
    
    $status = ""
    if ($spec.ContainsKey("IsFile") -and $spec.IsFile) {
      $status = "[FILE]"
    } elseif ($spec.AutoCreate) {
      $status = "[AUTO]"
    } else {
      $status = "[MANUAL]"
    }
    
    Write-Host "$name$padding$status " -NoNewline -ForegroundColor Cyan
    Write-Host $path -ForegroundColor White
    Write-Host (" " * ($maxNameWidth + 8)) -NoNewline
    Write-Host $spec.Description -ForegroundColor DarkGray
  }
}
#endregion Paths / Environment

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

#region DataManager
# User data backup and extension management module.
# Responsibilities:
# - Creates timestamped backups of current user data before updates
# - Manages user-data and extensions directories preservation
# - Handles first-run scenarios where no existing data exists
# - Provides rollback capability through snapshot management
# - Exports and imports extension lists for reproducible environments
# - Performs clean extension rebuilds from saved extension lists
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

function Export-ExtensionsList {
  param(
    [Parameter(Mandatory)][string]$ExtensionsDir,
    [Parameter(Mandatory)][string]$OutputFile
  )

  Write-Log INFO "Exporting extensions list from filesystem: $ExtensionsDir"

  if (-not (Test-Path $ExtensionsDir)) {
    Write-Log WARN "Extensions directory does not exist: $ExtensionsDir"
    Set-Content -LiteralPath $OutputFile -Value ""
    return
  }

  $ids = @()

  Get-ChildItem -LiteralPath $ExtensionsDir -Directory | ForEach-Object {
    # Folder name example: ms-python.python-2025.1.0
    # We want: ms-python.python
    if ($_.Name -match '^(.+)-\d') {
      $ids += $Matches[1]
    } else {
      # Fallback: take whole name
      $ids += $_.Name
    }
  }

  $ids = @($ids | Sort-Object -Unique)

  Write-Log INFO "Found $($ids.Count) extensions."

  Set-Content -LiteralPath $OutputFile -Value ($ids -join "`n")
}

function Rebuild-Extensions {
  param(
    [Parameter(Mandatory)][string]$CodeExe,
    [Parameter(Mandatory)][string]$ExtensionsListFile,
    [Parameter(Mandatory)][string]$UserDataDir,
    [Parameter(Mandatory)][string]$ExtensionsDir
  )

  if (-not (Test-Path $ExtensionsListFile)) {
    throw "Extensions list file not found: $ExtensionsListFile"
  }

  Write-Log WARN "Rebuilding extensions from list: $ExtensionsListFile"

  if (Test-Path $ExtensionsDir) {
    Remove-Item -LiteralPath $ExtensionsDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $ExtensionsDir | Out-Null

  $ids = Get-Content -LiteralPath $ExtensionsListFile | Where-Object { $_.Trim() -ne "" }

  foreach ($id in $ids) {
    Write-Log INFO "Installing extension: $id"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $CodeExe
    $psi.Arguments = "--install-extension $id --user-data-dir `"$UserDataDir`" --extensions-dir `"$ExtensionsDir`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit()

    if ($p.ExitCode -ne 0) {
      $stderr = $p.StandardError.ReadToEnd()
      Write-Log WARN "Failed to install extension: $id - $stderr"
    }
  }
}
#endregion DataManager

#region Main
function Main {
  param([string[]]$Arguments = @())

  # =========================
  # Phase: Parse & setup
  # =========================

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

    Rebuild-Extensions `
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
    Rebuild-Extensions `
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
