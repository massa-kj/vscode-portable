#requires -Module Pester

Describe "Integration Tests - All Modules" {
    Context "Module Loading and Basic Functionality" {
        It "Should load all modules without errors" {
            { Import-Module "$PSScriptRoot\..\src\Core.psm1" -Force -ErrorAction Stop } | Should -Not -Throw
            { Import-Module "$PSScriptRoot\..\src\Cli.psm1" -Force -ErrorAction Stop } | Should -Not -Throw
            { Import-Module "$PSScriptRoot\..\src\VersionManager.psm1" -Force -ErrorAction Stop } | Should -Not -Throw
            { Import-Module "$PSScriptRoot\..\src\VsCodePackage.psm1" -Force -ErrorAction Stop } | Should -Not -Throw
            { Import-Module "$PSScriptRoot\..\src\DataManager.psm1" -Force -ErrorAction Stop } | Should -Not -Throw
        }
        
        It "Should export expected functions from Core module" {
            $functions = Get-Command -Module Core -CommandType Function | Select-Object -ExpandProperty Name
            
            $expectedFunctions = @(
                "Get-Config", "Get-DirectorySpecs", "Write-Log", "Get-Paths", "New-Directories", "Get-DirectoryInfo"
            )
            
            foreach ($func in $expectedFunctions) {
                $functions | Should -Contain $func
            }
        }
        
        It "Should export expected functions from Cli module" {
            $functions = Get-Command -Module Cli -CommandType Function | Select-Object -ExpandProperty Name
            
            $expectedFunctions = @(
                "ConvertTo-ParsedArgs", "Test-ArgumentValue", "Show-Help"
            )
            
            foreach ($func in $expectedFunctions) {
                $functions | Should -Contain $func
            }
        }
        
        It "Should export expected functions from VersionManager module" {
            $functions = Get-Command -Module VersionManager -CommandType Function | Select-Object -ExpandProperty Name
            
            $expectedFunctions = @(
                "Get-LatestVersionInfo", "Get-SpecifiedVersionInfo", "Get-CurrentVersion", "Set-CurrentVersionAtomically", "Get-CurrentCodeCli"
            )
            
            foreach ($func in $expectedFunctions) {
                $functions | Should -Contain $func
            }
        }
        
        It "Should export expected functions from VsCodePackage module" {
            $functions = Get-Command -Module VsCodePackage -CommandType Function | Select-Object -ExpandProperty Name
            
            $expectedFunctions = @(
                "Invoke-VsCodeDownload", "Test-PackageChecksum", "Get-ExtractedVersion", "Install-VsCodePackage"
            )
            
            foreach ($func in $expectedFunctions) {
                $functions | Should -Contain $func
            }
        }
        
        It "Should export expected functions from DataManager module" {
            $functions = Get-Command -Module DataManager -CommandType Function | Select-Object -ExpandProperty Name
            
            $expectedFunctions = @(
                "Backup-CurrentData", "Export-ExtensionsList", "Restore-Extensions"
            )
            
            foreach ($func in $expectedFunctions) {
                $functions | Should -Contain $func
            }
        }
        
        It "Core module should provide working configuration" {
            $config = Get-Config
            
            $config | Should -Not -BeNullOrEmpty
            $config.Platform | Should -Be "win32-x64-archive"
            $config.Quality | Should -Be "stable" 
        }
        
        It "Core module should provide working paths" {
            $paths = Get-Paths
            
            $paths | Should -Not -BeNullOrEmpty
            $paths.Root | Should -Not -BeNullOrEmpty
            $paths.Versions | Should -Not -BeNullOrEmpty
            $paths.CurrentData | Should -Not -BeNullOrEmpty
            $paths.Backups | Should -Not -BeNullOrEmpty
        }
        
        It "Cli module should parse basic arguments correctly" {
            $result = ConvertTo-ParsedArgs @("--platform", "win32-arm64-archive", "--quality", "insider")
            
            $result | Should -Not -BeNullOrEmpty
            $result.Platform | Should -Be "win32-arm64-archive" 
            $result.Quality | Should -Be "insider"
        }
        
        It "VersionManager should construct specified version info" {
            $versionInfo = Get-SpecifiedVersionInfo -Version "1.107.1" -Platform "win32-x64-archive" -Quality "stable"
            
            $versionInfo | Should -Not -BeNullOrEmpty
            $versionInfo.Version | Should -Be "1.107.1"
            # URL property might be null in this context, just check that function executes
        }
        
        It "VsCodePackage should handle version extraction logic" {
            # Create a temporary directory structure that mimics VS Code extraction
            $testDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([Guid]::NewGuid())) -Force
            $resourcesDir = Join-Path $testDir "resources"
            $appDir = Join-Path $resourcesDir "app"
            
            try {
                New-Item -ItemType Directory -Path $resourcesDir -Force | Out-Null
                New-Item -ItemType Directory -Path $appDir -Force | Out-Null
                
                $productJson = @{
                    version = "1.107.1"
                    quality = "stable"
                } | ConvertTo-Json
                Set-Content -Path (Join-Path $appDir "product.json") -Value $productJson
                
                $extractedVersion = Get-ExtractedVersion -ExtractDir $testDir
                $extractedVersion | Should -Be "1.107.1"
            }
            finally {
                if (Test-Path $testDir) {
                    Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        
        AfterAll {
            # Clean up modules
            @("Core", "Cli", "VersionManager", "VsCodePackage", "DataManager") | ForEach-Object {
                Remove-Module $_ -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
