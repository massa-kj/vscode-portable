#requires -Version 5.1
Set-StrictMode -Version Latest

#region Config
<#
.SYNOPSIS
    Configuration management module for VS Code Portable

.DESCRIPTION
    Provides centralized configuration and directory structure definitions.
    
    Responsibilities:
    - Application-wide configuration values access
    - Directory structure specification
    - Immutable configuration interface
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
      Returns application configuration
  
  .DESCRIPTION
      Provides read-only access to application-wide configuration values.
      Returns a defensive copy to prevent external modifications.
      
  .OUTPUTS
      Hashtable: Configuration with RepoRoot, Platform, Quality, UpdateApi, etc.
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
      Returns directory structure specifications
  
  .DESCRIPTION
      Provides read-only access to directory specifications that define
      workspace layout and auto-creation behavior.
      
  .OUTPUTS
      Hashtable: Directory specifications with RelativePath, AutoCreate, Description properties
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
    Logging module for unified message output

.DESCRIPTION
    Provides consistent logging functionality across the application.
    
    Responsibilities:
    - Timestamped message output with severity levels
    - Centralized logging interface
#>

function Write-Log {
  <#
  .SYNOPSIS
      Writes timestamped log message with severity level
  
  .DESCRIPTION
      Outputs formatted log messages to console with timestamp and level.
      
  .PARAMETER Level
      Message severity level: INFO, WARN, or ERROR
      
  .PARAMETER Message
      Message content to log
      
  .EXAMPLE
      Write-Log INFO "Starting application"
      Write-Log WARN "Configuration file not found"
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
    File path management and directory initialization module

.DESCRIPTION
    Provides standardized path resolution and directory structure management.
    
    Responsibilities:
    - Resolves absolute paths based on configuration
    - Ensures required directory structure exists
    - Provides consistent workspace layout management
#>

function Resolve-DirectoryPath {
  <#
  .SYNOPSIS
      Resolves directory name to absolute path
  
  .DESCRIPTION
      Calculates absolute path for a directory based on configuration.
      Handles special cases that reference configuration values.
      
  .PARAMETER Name
      Directory name as defined in DirectorySpecs
      
  .PARAMETER Spec
      Directory specification hashtable
      
  .OUTPUTS
      String: Absolute path to the directory
      
  .THROWS
      Exception when RelativePath is null and Name is not recognized
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
      Returns all resolved absolute directory paths
  
  .DESCRIPTION
      Calculates absolute paths for all directories defined in DirectorySpecs.
      Provides consistent path resolution interface for the application.
      
  .OUTPUTS
      Hashtable: Directory names mapped to absolute path strings
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
      Creates required directories according to configuration
  
  .DESCRIPTION
      Creates directories marked with AutoCreate=true in DirectorySpecs.
      Ensures workspace structure exists before operations.
      
  .PARAMETER P
      Resolved paths hashtable from Get-Paths
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
      Displays formatted directory configuration information
  
  .DESCRIPTION
      Outputs current directory configuration including paths,
      creation behavior, and descriptions in formatted table.
      Used for troubleshooting and documentation.
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
