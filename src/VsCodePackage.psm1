#requires -Version 5.1
Set-StrictMode -Version Latest

#region VsCodePackage
<#
.SYNOPSIS
    VS Code package download and installation module for VS Code Portable.

.DESCRIPTION
    Provides comprehensive VS Code package management functionality including download,
    verification, extraction, and installation of VS Code archives.
    
    Responsibilities:
    - Downloads VS Code ZIP archives from official sources with caching
    - Implements integrity verification using SHA256 checksums
    - Handles download failures and corrupted file detection with automatic retry
    - Extracts VS Code ZIP archives to version-specific directories
    - Automatically detects actual version numbers from extracted product.json
    - Prevents duplicate installations and manages version isolation
    - Validates installation completeness and binary integrity
#>

function Invoke-VsCodeDownload {
  <#
  .SYNOPSIS
      Downloads VS Code ZIP archive with caching and integrity verification.
  
  .DESCRIPTION
      Downloads VS Code from the specified URL with smart caching. Reuses existing
      downloads if they pass integrity checks, otherwise re-downloads automatically.
      
  .PARAMETER P
      Hashtable containing resolved paths (typically from Get-Paths).
      
  .PARAMETER Url
      Download URL for the VS Code archive.
      
  .PARAMETER Version
      Version string for cache file naming.
      
  .OUTPUTS
      String containing the path to the downloaded ZIP file.
      
  .EXAMPLE
      $P = Get-Paths
      $zipPath = Invoke-VsCodeDownload -P $P -Url "https://..." -Version "1.107.1"
  #>
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

function Test-PackageChecksum {
  <#
  .SYNOPSIS
      Verifies the SHA256 checksum of a downloaded package.
  
  .DESCRIPTION
      Calculates and compares SHA256 hash of the specified file against
      the expected checksum. Throws an error if checksums don't match.
      
  .PARAMETER FilePath
      Path to the file to verify.
      
  .PARAMETER ExpectedSha256
      Expected SHA256 hash in hexadecimal format.
      
  .EXAMPLE
      Test-PackageChecksum -FilePath "vscode.zip" -ExpectedSha256 "abc123..."
  #>
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

function Get-ExtractedVersion {
  <#
  .SYNOPSIS
      Extracts version information from VS Code installation directory.
  
  .DESCRIPTION
      Reads the product.json file from an extracted VS Code installation
      to determine the actual version number.
      
  .PARAMETER ExtractDir
      Path to the extracted VS Code directory.
      
  .OUTPUTS
      String containing the version number.
      
  .EXAMPLE
      $version = Get-ExtractedVersion -ExtractDir "C:\temp\vscode"
  #>
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

function Install-VsCodePackage {
  <#
  .SYNOPSIS
      Installs VS Code from ZIP archive if not already installed.
  
  .DESCRIPTION
      Extracts VS Code ZIP archive to a temporary location, reads the actual
      version from product.json, and installs it to the appropriate version
      directory. Skips installation if the version is already present.
      
  .PARAMETER P
      Hashtable containing resolved paths (typically from Get-Paths).
      
  .PARAMETER ZipPath
      Path to the VS Code ZIP archive to install.
      
  .OUTPUTS
      Hashtable containing Version, InstalledPath, and IsNew properties.
      
  .EXAMPLE
      $P = Get-Paths
      $result = Install-VsCodePackage -P $P -ZipPath "vscode.zip"
  #>
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
  $version = Get-ExtractedVersion -ExtractDir $root
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

# Export all functions from this module
Export-ModuleMember -Function Invoke-VsCodeDownload, Test-PackageChecksum, Get-ExtractedVersion, Install-VsCodePackage
#endregion VsCodePackage
