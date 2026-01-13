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

# Export functions
Export-ModuleMember -Function Get-Config, Get-DirectorySpecs
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

# Export functions
Export-ModuleMember -Function Write-Log
#endregion Logger
