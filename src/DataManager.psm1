#requires -Version 5.1
Set-StrictMode -Version Latest

#region DataManager
<#
.SYNOPSIS
    User data backup and extension management module for VS Code Portable.

.DESCRIPTION
    Provides comprehensive data management functionality including timestamped backups,
    extension list management, and clean extension rebuilds.
    
    Responsibilities:
    - Creates timestamped backups of current user data before updates
    - Manages user-data and extensions directories preservation
    - Handles first-run scenarios where no existing data exists
    - Provides rollback capability through snapshot management
    - Exports and imports extension lists for reproducible environments
    - Performs clean extension rebuilds from saved extension lists
#>

function Backup-CurrentData {
  <#
  .SYNOPSIS
      Creates a timestamped backup of current user data.
  
  .DESCRIPTION
      Backs up the current user data and extensions to a timestamped folder
      in the backups directory. Skips backup if no meaningful data exists.
      
  .PARAMETER P
      Hashtable containing resolved paths (typically from Get-Paths).
      
  .OUTPUTS
      String containing the backup directory path, or $null if no backup was created.
      
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
      Exports the list of installed extensions to a file.
  
  .DESCRIPTION
      Scans the extensions directory and extracts extension IDs from folder names,
      then saves them to a text file for later restoration.
      
  .PARAMETER ExtensionsDir
      Path to the extensions directory to scan.
      
  .PARAMETER OutputFile
      Path to the output file where extension IDs will be saved.
      
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
      Performs a clean rebuild of extensions from a saved list.
  
  .DESCRIPTION
      Removes the current extensions directory and reinstalls all extensions
      listed in the extensions list file using VS Code CLI.
      
  .PARAMETER CodeExe
      Path to the VS Code executable for installing extensions.
      
  .PARAMETER ExtensionsListFile
      Path to the file containing the list of extension IDs to install.
      
  .PARAMETER UserDataDir
      Path to the VS Code user data directory.
      
  .PARAMETER ExtensionsDir
      Path to the extensions directory to rebuild.
      
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
