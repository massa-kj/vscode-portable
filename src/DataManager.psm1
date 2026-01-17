#requires -Version 5.1
Set-StrictMode -Version Latest

#region DataManager
<#
.SYNOPSIS
    Data management module for VS Code Portable

.DESCRIPTION
    Manages user data protection and extension handling.
    
    Responsibilities:
    - Creates timestamped backups of user data
    - Exports and restores extension lists
    - Handles first-run scenarios appropriately
#>

function Backup-CurrentData {
  <#
  .SYNOPSIS
      Creates a timestamped backup of current user data
  
  .DESCRIPTION
      Backs up current user data and extensions to a timestamped folder.
      Skips backup if no data exists (e.g., first run).
      
  .PARAMETER P
      Hashtable containing path information
      
  .OUTPUTS
      String: Path to backup folder, or $null if no backup was created
      
  .EXAMPLE
      $P = Get-Paths
      $backupPath = Backup-CurrentData -P $P
  #>
  param([Parameter(Mandatory)][hashtable]$P)

  $ud = Join-Path $P.CurrentData "user-data"
  $ext = Join-Path $P.CurrentData "extensions"

  # Check if current data directory exists first
  if (-not (Test-Path $P.CurrentData)) {
    Write-Log INFO "No meaningful current data found; skipping backup (likely first run)."
    return $null
  }

  $hasAny = $false
  
  # Check user-data directory
  if (Test-Path $ud) {
    $udItems = @(Get-ChildItem -LiteralPath $ud -Force -ErrorAction SilentlyContinue)
    if ($udItems.Count -gt 0) {
      $hasAny = $true
    }
  }
  
  # Check extensions directory
  if (-not $hasAny -and (Test-Path $ext)) {
    $extItems = @(Get-ChildItem -LiteralPath $ext -Force -ErrorAction SilentlyContinue)
    if ($extItems.Count -gt 0) {
      $hasAny = $true
    }
  }

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
  <#
  .SYNOPSIS
      Exports installed extensions list to a file
  
  .DESCRIPTION
      Scans extensions directory and extracts extension IDs,
      then saves them to a text file.
      
  .PARAMETER ExtensionsDir
      Path to extensions directory to scan
      
  .PARAMETER OutputFile
      Path to output file for extension IDs
      
  .EXAMPLE
      Export-ExtensionsList -ExtensionsDir "C:\path\to\extensions" -OutputFile "extensions.txt"
  #>
  param(
    [Parameter(Mandatory)][string]$ExtensionsDir,
    [Parameter(Mandatory)][string]$OutputFile
  )

  Write-Log INFO "Exporting extensions list from filesystem: $ExtensionsDir"

  if (-not (Test-Path $ExtensionsDir)) {
    Write-Log WARN "Extensions directory does not exist: $ExtensionsDir"
    Set-Content -LiteralPath $OutputFile -Value "" -NoNewline
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

function Restore-Extensions {
  <#
  .SYNOPSIS
      Reinstalls extensions from a saved list
  
  .DESCRIPTION
      Removes current extensions directory and reinstalls all extensions
      listed in the extensions list file using VS Code CLI.
      
  .PARAMETER CodeExe
      Path to VS Code executable
      
  .PARAMETER ExtensionsListFile
      Path to file containing extension IDs to install
      
  .PARAMETER UserDataDir
      Path to VS Code user data directory
      
  .PARAMETER ExtensionsDir
      Path to extensions directory to rebuild
      
  .EXAMPLE
      Restore-Extensions -CodeExe "code.exe" -ExtensionsListFile "extensions.txt" -UserDataDir "userdata" -ExtensionsDir "extensions"
  #>
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

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.FileName = $CodeExe
    $p.StartInfo.Arguments = "--install-extension $id --user-data-dir `"$UserDataDir`" --extensions-dir `"$ExtensionsDir`""
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.CreateNoWindow = $true

    $p.Start() | Out-Null
    $p.WaitForExit()

    if ($p.ExitCode -ne 0) {
      $stderr = $p.StandardError.ReadToEnd()
      Write-Log WARN "Failed to install extension: $id - $stderr"
    }
  }
}

# Export all functions from this module
Export-ModuleMember -Function Backup-CurrentData, Export-ExtensionsList, Restore-Extensions
#endregion DataManager
