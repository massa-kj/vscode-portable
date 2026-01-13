#requires -Version 5.1
Set-StrictMode -Version Latest

#region Config
<#
.SYNOPSIS
    Configuration management module for VS Code Portable.

.DESCRIPTION
    Provides centralized configuration values and directory specifications.
    Manages application-wide settings, API endpoints, and workspace layout definitions.
    
    Responsibilities:
    - Application-wide configuration values (paths, defaults, API endpoints)
    - Directory structure specification for workspace layout
    - Immutable configuration access
#>

# Application-wide configuration values
$script:Cfg = [ordered]@{
  # Application-wide configuration values
  RepoRoot        = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
  VersionsDirName = "versions"
  DataDirName     = "data"
  CurrentFileName = "current.txt"

  # Defaults (can be overridden by CLI args)
  Platform        = "win32-x64-archive"
  Quality         = "stable"

  # Maintains VS Code download API endpoints and settings
  UpdateApi       = "https://update.code.visualstudio.com/api/update"
  DownloadBase    = "https://update.code.visualstudio.com"

  UserAgent       = "vscode-portable"
}

# Directory structure specification - defines workspace layout
$script:DirectorySpecs = @{
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

function Get-Config {
  <#
  .SYNOPSIS
      Returns the application configuration.
  
  .DESCRIPTION
      Provides read-only access to the application-wide configuration values.
      
  .OUTPUTS
      Hashtable containing configuration values.
  #>
  # Create a copy to prevent external modification
  $copy = [ordered]@{}
  foreach ($key in $script:Cfg.Keys) {
    $copy[$key] = $script:Cfg[$key]
  }
  return $copy
}

function Get-DirectorySpecs {
  <#
  .SYNOPSIS
      Returns the directory structure specifications.
  
  .DESCRIPTION
      Provides read-only access to the directory specifications that define
      the workspace layout and directory creation behavior.
      
  .OUTPUTS
      Hashtable containing directory specifications.
  #>
  # Create a deep copy to prevent external modification
  $copy = @{}
  foreach ($key in $script:DirectorySpecs.Keys) {
    $copy[$key] = $script:DirectorySpecs[$key].Clone()
  }
  return $copy
}

#endregion Config

#region Logger
<#
.SYNOPSIS
    Logging module for unified message output.

.DESCRIPTION
    Provides consistent logging functionality across the application.
    Handles message formatting with timestamps and severity levels.
#>

function Write-Log {
  <#
  .SYNOPSIS
      Writes a log message with timestamp and level.
  
  .DESCRIPTION
      Outputs a formatted log message to the console with timestamp and severity level.
      
  .PARAMETER Level
      The severity level of the message (INFO, WARN, ERROR).
      
  .PARAMETER Message
      The message to log.
      
  .EXAMPLE
      Write-Log INFO "Starting application"
      Write-Log WARN "Configuration file not found, using defaults"
      Write-Log ERROR "Failed to connect to server"
  #>
  param(
    [Parameter(Mandatory)][ValidateSet("INFO","WARN","ERROR")][string]$Level,
    [Parameter(Mandatory)][string]$Message
  )
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  Write-Host "[$ts][$Level] $Message"
}

#endregion Logger

#region Paths
<#
.SYNOPSIS
    File path management and directory initialization module.

.DESCRIPTION
    Provides standardized path resolution and directory structure management.
    Handles workspace layout through configuration-driven approach.
    
    Responsibilities:
    - Calculates and provides standardized paths based on DirectorySpecs configuration
    - Ensures required directory structure exists according to AutoCreate settings
    - Manages workspace layout through configuration-driven approach
    - Provides consistent file placement strategy that can be easily modified
#>

function Resolve-DirectoryPath {
  <#
  .SYNOPSIS
      Resolves a directory path based on configuration and specifications.
  
  .DESCRIPTION
      Calculates the absolute path for a directory based on its specification
      and the application configuration.
      
  .PARAMETER Name
      The name of the directory as defined in DirectorySpecs.
      
  .PARAMETER Spec
      The directory specification hashtable.
      
  .OUTPUTS
      String containing the resolved absolute path.
  #>
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][hashtable]$Spec
  )
  
  $cfg = Get-Config
  $root = $cfg.RepoRoot
  
  # Handle special cases that reference config values
  if ($null -eq $Spec.RelativePath) {
    switch ($Name) {
      "Versions" { return Join-Path $root $cfg.VersionsDirName }
      "Data" { return Join-Path $root $cfg.DataDirName }
      "CurrentTxt" { return Join-Path $root $cfg.CurrentFileName }
      default { throw "No RelativePath specified for directory '$Name'" }
    }
  }
  
  return Join-Path $root $Spec.RelativePath
}

function Get-Paths {
  <#
  .SYNOPSIS
      Returns all resolved directory paths.
  
  .DESCRIPTION
      Calculates and returns a hashtable containing all directory paths
      based on the directory specifications.
      
  .OUTPUTS
      Hashtable containing directory names as keys and absolute paths as values.
  #>
  $paths = [ordered]@{}
  $directorySpecs = Get-DirectorySpecs
  
  foreach ($name in $directorySpecs.Keys) {
    $spec = $directorySpecs[$name]
    $path = Resolve-DirectoryPath -Name $name -Spec $spec
    $paths[$name] = $path
  }
  
  # Add Root for backward compatibility
  $cfg = Get-Config
  $paths["Root"] = $cfg.RepoRoot
  
  return $paths
}

function New-Directories {
  <#
  .SYNOPSIS
      Creates required directories based on specifications.
  
  .DESCRIPTION
      Creates directories that are marked for auto-creation in the directory
      specifications. Skips files and manually managed directories.
      
  .PARAMETER P
      Hashtable containing resolved paths (typically from Get-Paths).
  #>
  param([Parameter(Mandatory)][hashtable]$P)

  $directorySpecs = Get-DirectorySpecs
  
  foreach ($name in $directorySpecs.Keys) {
    $spec = $directorySpecs[$name]
    
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
  <#
  .SYNOPSIS
      Displays current directory configuration.
  
  .DESCRIPTION
      Utility function to show the current directory configuration with
      paths, creation status, and descriptions in a formatted output.
  #>
  # Utility function to show current directory configuration
  Write-Host "Directory Configuration:" -ForegroundColor Green
  Write-Host "=======================" -ForegroundColor Green
  
  $paths = Get-Paths
  $directorySpecs = Get-DirectorySpecs
  $maxNameWidth = ($directorySpecs.Keys | Measure-Object -Property Length -Maximum).Maximum
  
  foreach ($name in $directorySpecs.Keys | Sort-Object) {
    $spec = $directorySpecs[$name]
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

#endregion Paths

# Export all functions from this module
Export-ModuleMember -Function Get-Config, Get-DirectorySpecs, Write-Log, Resolve-DirectoryPath, Get-Paths, New-Directories, Get-DirectoryInfo
