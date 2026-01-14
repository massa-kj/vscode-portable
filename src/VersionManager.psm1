#requires -Version 5.1
Set-StrictMode -Version Latest

#region VersionManager
<#
.SYNOPSIS
    Version management module for VS Code Portable.

.DESCRIPTION
    Provides comprehensive version management functionality including version information
    retrieval from official APIs and current version state management.
    
    Responsibilities:
    - Fetches latest VS Code version information from official update API
    - Constructs version information for specified versions
    - Provides download URLs, checksums, and metadata for VS Code releases
    - Manages the current VS Code version pointer (current.txt file)
    - Provides atomic version switching to prevent corruption during updates
    - Resolves executable paths for the current version
#>

function Get-LatestVersionInfo {
  <#
  .SYNOPSIS
      Retrieves the latest VS Code version information from the official API.
  
  .DESCRIPTION
      Fetches version metadata including download URL, SHA256 checksum, and version
      number from the Microsoft VS Code update API.
      
  .PARAMETER Platform
      Target platform for VS Code download (e.g., "win32-x64-archive").
      
  .PARAMETER Quality
      Release quality ("stable" or "insider").
      
  .OUTPUTS
      Hashtable containing Version, DownloadUrl, Sha256, and HasChecksum properties.
      
  .EXAMPLE
      $info = Get-LatestVersionInfo -Platform "win32-x64-archive" -Quality "stable"
  #>
  param(
    [Parameter(Mandatory)][string]$Platform,
    [Parameter(Mandatory)][string]$Quality
  )

  $cfg = Get-Config
  $url = "$($cfg.UpdateApi)/$Platform/$Quality/latest"
  Write-Log INFO "Fetching latest version info: $url"

  $headers = @{ "User-Agent" = $cfg.UserAgent }
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
  <#
  .SYNOPSIS
      Constructs version information for a specified VS Code version.
  
  .DESCRIPTION
      Creates version metadata for a specific version without API lookup.
      Note that checksum verification is not available for specified versions.
      
  .PARAMETER Version
      Specific VS Code version to target.
      
  .PARAMETER Platform
      Target platform for VS Code download.
      
  .PARAMETER Quality
      Release quality ("stable" or "insider").
      
  .OUTPUTS
      Hashtable containing Version, DownloadUrl, Sha256, and HasChecksum properties.
      
  .EXAMPLE
      $info = Get-SpecifiedVersionInfo -Version "1.107.1" -Platform "win32-x64-archive" -Quality "stable"
  #>
  param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Platform,
    [Parameter(Mandatory)][string]$Quality
  )

  $cfg = Get-Config
  $url = "$($cfg.DownloadBase)/$Version/$Platform/$Quality"

  Write-Log INFO "Using specified version: $Version"
  Write-Log INFO "Download URL: $url"

  return [ordered]@{
    Version     = $Version
    DownloadUrl = $url
    Sha256      = $null
    HasChecksum = $false
  }
}

function Get-CurrentVersion {
  <#
  .SYNOPSIS
      Retrieves the currently active VS Code version.
  
  .DESCRIPTION
      Reads the current version from the version pointer file (current.txt).
      Returns null if no version is set or file doesn't exist.
      
  .PARAMETER P
      Hashtable containing resolved paths (typically from Get-Paths).
      
  .OUTPUTS
      String containing the current version, or $null if not set.
      
  .EXAMPLE
      $P = Get-Paths
      $currentVersion = Get-CurrentVersion -P $P
  #>
  param([Parameter(Mandatory)][hashtable]$P)

  if (-not (Test-Path $P.CurrentTxt)) { return $null }
  $v = (Get-Content -LiteralPath $P.CurrentTxt -ErrorAction Stop | Select-Object -First 1).Trim()
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  return $v
}

function Set-CurrentVersionAtomically {
  <#
  .SYNOPSIS
      Atomically updates the current version pointer.
  
  .DESCRIPTION
      Updates the current version using a temporary file approach to prevent
      corruption during the update process. Ensures safe version transitions.
      
  .PARAMETER P
      Hashtable containing resolved paths (typically from Get-Paths).
      
  .PARAMETER Version
      Version string to set as current.
      
  .EXAMPLE
      $P = Get-Paths
      Set-CurrentVersionAtomically -P $P -Version "1.107.1"
  #>
  param(
    [Parameter(Mandatory)][hashtable]$P,
    [Parameter(Mandatory)][string]$Version
  )
  $tmpFile = "$($P.CurrentTxt).tmp"
  Set-Content -LiteralPath $tmpFile -Value $Version -NoNewline
  Move-Item -LiteralPath $tmpFile -Destination $P.CurrentTxt -Force
}

function Get-CurrentCodeCli {
  <#
  .SYNOPSIS
      Resolves the path to the current VS Code CLI executable.
  
  .DESCRIPTION
      Returns the full path to the code.cmd CLI for the currently active
      VS Code version. Throws an error if no version is set or CLI not found.
      
  .PARAMETER P
      Hashtable containing resolved paths (typically from Get-Paths).
      
  .OUTPUTS
      String containing the full path to code.cmd.
      
  .EXAMPLE
      $P = Get-Paths
      $codeCli = Get-CurrentCodeCli -P $P
  #>
  param([Parameter(Mandatory)][hashtable]$P)

  $cur = Get-CurrentVersion -P $P
  if (-not $cur) {
    throw "No current version is set. Cannot locate Code CLI."
  }

  $codeCli = Join-Path $P.Versions "$cur\bin\code.cmd"
  if (-not (Test-Path $codeCli)) {
    throw "Current Code CLI not found: $codeCli"
  }

  return $codeCli
}

# Export all functions from this module
Export-ModuleMember -Function Get-LatestVersionInfo, Get-SpecifiedVersionInfo, Get-CurrentVersion, Set-CurrentVersionAtomically, Get-CurrentCodeCli
#endregion VersionManager
