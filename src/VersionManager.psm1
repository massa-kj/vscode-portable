#requires -Version 5.1
Set-StrictMode -Version Latest

#region VersionManager
<#
.SYNOPSIS
    Version management module for VS Code Portable

.DESCRIPTION
    Manages VS Code version information and current version state.
    
    Responsibilities:
    - Retrieves version information from official API or constructs for specified versions
    - Manages current version pointer with atomic updates
    - Resolves executable paths for active version
#>

function Get-LatestVersionInfo {
  <#
  .SYNOPSIS
      Retrieves latest VS Code version information from official API
  
  .DESCRIPTION
      Fetches version metadata including download URL, SHA256 checksum,
      and version number from Microsoft VS Code update API.
      
  .PARAMETER Platform
      Target platform for VS Code download
      
  .PARAMETER Quality
      Release quality: "stable" or "insider"
      
  .OUTPUTS
      Hashtable: Version, DownloadUrl, Sha256, HasChecksum properties
      
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
      Constructs version information for a specified VS Code version
  
  .DESCRIPTION
      Creates version metadata for a specific version without API lookup.
      Checksum verification is not available for specified versions.
      
  .PARAMETER Version
      Specific VS Code version to target
      
  .PARAMETER Platform
      Target platform for VS Code download
      
  .PARAMETER Quality
      Release quality: "stable" or "insider"
      
  .OUTPUTS
      Hashtable: Version, DownloadUrl, Sha256, HasChecksum properties
      
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
      Retrieves currently active VS Code version
  
  .DESCRIPTION
      Reads current version from version pointer file.
      Returns null if no version is set or file doesn't exist.
      
  .PARAMETER P
      Resolved paths hashtable from Get-Paths
      
  .OUTPUTS
      String: Current version, or $null if not set
      
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
      Atomically updates current version pointer
  
  .DESCRIPTION
      Updates current version using temporary file approach to prevent
      corruption during update process.
      
  .PARAMETER P
      Resolved paths hashtable from Get-Paths
      
  .PARAMETER Version
      Version string to set as current
      
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
      Resolves path to current VS Code CLI executable
  
  .DESCRIPTION
      Returns full path to code.cmd CLI for currently active VS Code version.
      Throws error if no version is set or CLI not found.
      
  .PARAMETER P
      Resolved paths hashtable from Get-Paths
      
  .OUTPUTS
      String: Full path to code.cmd
      
  .THROWS
      Exception when no current version or CLI not found
      
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
