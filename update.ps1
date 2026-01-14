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

# Import VersionManager module for version information and current version management
$VersionManagerModulePath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "src\VersionManager.psm1"
Import-Module $VersionManagerModulePath -Force

# Import VsCodePackage module for VS Code download and installation
$VsCodePackageModulePath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "src\VsCodePackage.psm1"
Import-Module $VsCodePackageModulePath -Force

# Get configuration and directory specs from Core module
$SCRIPT:Cfg = Get-Config
$SCRIPT:DirectorySpecs = Get-DirectorySpecs

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

    $zip = Invoke-VsCodeDownload -P $P -Url $target.DownloadUrl -Version $target.Version

    if ($target.HasChecksum) {
      Test-PackageChecksum -FilePath $zip -ExpectedSha256 $target.Sha256
    } else {
      Write-Log WARN "No checksum available for this download. Skipping verification."
    }

    $result = Install-VsCodePackage -P $P -ZipPath $zip
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
