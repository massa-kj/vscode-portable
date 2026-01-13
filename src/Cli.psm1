#requires -Version 5.1
Set-StrictMode -Version Latest

#region Cli
<#
.SYNOPSIS
    Command-line interface module for VS Code Portable.

.DESCRIPTION
    Provides comprehensive CLI functionality including argument parsing, validation,
    and help generation. Uses a configuration-driven approach for extensibility.
    
    Responsibilities:
    - Command-line argument parsing with type validation
    - Extensible argument specification system
    - Automated help message generation
    - User input validation and error reporting
#>

# Argument specification configuration
$script:ArgSpecs = @{
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

function Test-ArgumentValue {
  <#
  .SYNOPSIS
      Validates an argument value against its specification.
  
  .DESCRIPTION
      Performs type validation and value validation for command-line arguments
      based on the argument specification.
      
  .PARAMETER Spec
      The argument specification hashtable.
      
  .PARAMETER Value
      The value to validate.
      
  .PARAMETER ArgName
      The argument name for error reporting.
      
  .OUTPUTS
      String containing the validated value.
  #>
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

function ConvertTo-ParsedArgs {
  <#
  .SYNOPSIS
      Parses command-line arguments based on specifications.
  
  .DESCRIPTION
      Converts raw command-line arguments into a structured hashtable
      with validation and type checking.
      
  .PARAMETER Arguments
      Array of command-line arguments to parse.
      
  .OUTPUTS
      Hashtable containing parsed and validated arguments.
  #>
  param([string[]]$Arguments)

  # Initialize result with all possible properties set to null/false
  $result = @{}
  foreach ($spec in $script:ArgSpecs.Values) {
    if ($spec.Type -eq "Flag") {
      $result[$spec.PropertyName] = $false
    } else {
      $result[$spec.PropertyName] = $null
    }
  }

  for ($i = 0; $i -lt $Arguments.Length; $i++) {
    $arg = $Arguments[$i]
    
    if (-not $script:ArgSpecs.ContainsKey($arg)) {
      throw "Unknown argument: $arg. Use --help to see available options."
    }

    $spec = $script:ArgSpecs[$arg]
    
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
      $validatedValue = Test-ArgumentValue -Spec $spec -Value $value -ArgName $arg
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
    # Import Core module to access Get-DirectoryInfo
    $coreModulePath = Join-Path $PSScriptRoot "Core.psm1"
    Import-Module $coreModulePath -Force
    Get-DirectoryInfo
    exit 0
  }

  # Check required arguments
  foreach ($argName in $script:ArgSpecs.Keys) {
    $spec = $script:ArgSpecs[$argName]
    if ($spec.Required -and $null -eq $result[$spec.PropertyName]) {
      throw "Required argument $argName is missing. Use --help for more information."
    }
  }

  return $result
}

function Show-Help {
  <#
  .SYNOPSIS
      Displays help information for the CLI.
  
  .DESCRIPTION
      Generates and displays formatted help text including usage,
      options, and examples based on the argument specifications.
  #>
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
  $maxArgWidth = ($script:ArgSpecs.Keys | Measure-Object -Property Length -Maximum).Maximum
  
  foreach ($argName in $script:ArgSpecs.Keys | Sort-Object) {
    $spec = $script:ArgSpecs[$argName]
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

# Export all functions from this module
Export-ModuleMember -Function ConvertTo-ParsedArgs, Test-ArgumentValue, Show-Help
#endregion Cli
