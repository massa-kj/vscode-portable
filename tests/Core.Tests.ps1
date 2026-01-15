#requires -Module Pester

Describe "Core Module Tests" {
    BeforeAll {
        # Import module with force to ensure clean state
        $ModulePath = Join-Path $PSScriptRoot "..\src\Core.psm1"
        Import-Module $ModulePath -Force -ErrorAction Stop
    }
    
    Context "Configuration Management" {
        It "Get-Config should return a valid configuration object" {
            $config = Get-Config
            
            # Verify return type and structure
            $config | Should -Not -BeNullOrEmpty
            $config | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
            
            # Verify essential configuration keys exist
            $config.Keys | Should -Contain "RepoRoot"
            $config.Keys | Should -Contain "Platform" 
            $config.Keys | Should -Contain "Quality"
            $config.Keys | Should -Contain "UpdateApi"
        }
        
        It "Get-Config should return immutable configuration (defensive copy)" {
            $config1 = Get-Config
            $config2 = Get-Config
            
            # Modify first copy
            $config1["TestKey"] = "TestValue"
            
            # Second copy should be unaffected
            $config2.Keys | Should -Not -Contain "TestKey"
        }
        
        It "Get-Config should have expected default values" {
            $config = Get-Config
            
            # Verify critical default values
            $config.Platform | Should -Be "win32-x64-archive"
            $config.Quality | Should -Be "stable"
            $config.UpdateApi | Should -Match "^https://update\.code\.visualstudio\.com"
        }
        
        It "Get-DirectorySpecs should return valid directory specifications" {
            $specs = Get-DirectorySpecs
            
            # Verify return type and structure
            $specs | Should -Not -BeNullOrEmpty
            $specs | Should -BeOfType [hashtable]
            
            # Verify essential directory specs exist
            $specs.Keys | Should -Contain "Versions"
            $specs.Keys | Should -Contain "Data"
            $specs.Keys | Should -Contain "CurrentData"
            $specs.Keys | Should -Contain "Tmp"
        }
        
        It "Get-DirectorySpecs should return immutable specifications (deep copy)" {
            $specs1 = Get-DirectorySpecs
            $specs2 = Get-DirectorySpecs
            
            # Modify first copy
            $specs1["TestDir"] = @{ TestProp = "TestValue" }
            
            # Second copy should be unaffected
            $specs2.Keys | Should -Not -Contain "TestDir"
        }
        
        It "Directory specifications should have required properties" {
            $specs = Get-DirectorySpecs
            
            foreach ($specName in $specs.Keys) {
                $spec = $specs[$specName]
                
                # Every spec should have AutoCreate and Description
                $spec.Keys | Should -Contain "AutoCreate"
                $spec.Keys | Should -Contain "Description"
                
                # AutoCreate should be boolean
                $spec.AutoCreate | Should -BeOfType [bool]
                
                # Description should be non-empty string
                $spec.Description | Should -Not -BeNullOrEmpty
                $spec.Description | Should -BeOfType [string]
            }
        }
    }
    
    Context "Logging Functionality" {
        It "Write-Log should accept valid log levels" {
            # Test each valid level without throwing
            { Write-Log -Level "INFO" -Message "Test message" } | Should -Not -Throw
            { Write-Log -Level "WARN" -Message "Test message" } | Should -Not -Throw  
            { Write-Log -Level "ERROR" -Message "Test message" } | Should -Not -Throw
        }
        
        It "Write-Log should reject invalid log levels" {
            { Write-Log -Level "INVALID" -Message "Test message" } | Should -Throw
            { Write-Log -Level "DEBUG" -Message "Test message" } | Should -Throw
        }
        
        It "Write-Log should require both Level and Message parameters" {
            # PowerShell parameter validation behaves differently in different contexts
            # This test verifies the function has mandatory parameters defined correctly
            $function = Get-Command Write-Log -Module Core
            $levelParam = $function.Parameters['Level']
            $messageParam = $function.Parameters['Message']
            
            # Verify parameters are mandatory
            $levelParam.Attributes.Mandatory | Should -Contain $true
            $messageParam.Attributes.Mandatory | Should -Contain $true
        }
        
        # Note: Output testing is intentionally minimal to avoid brittleness
        # The log format might change, but the core functionality should remain
    }
    
    Context "Path Management" {
        It "Get-Paths should return valid path structure" {
            $paths = Get-Paths
            
            # Verify return type and structure
            $paths | Should -Not -BeNullOrEmpty
            $paths | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
            
            # Verify essential paths exist
            $paths.Keys | Should -Contain "Root"
            $paths.Keys | Should -Contain "Versions"
            $paths.Keys | Should -Contain "Data"
            $paths.Keys | Should -Contain "CurrentData"
        }
        
        It "All paths should be absolute and valid" {
            $paths = Get-Paths
            
            foreach ($pathName in $paths.Keys) {
                $path = $paths[$pathName]
                
                # Path should be non-empty string
                $path | Should -Not -BeNullOrEmpty
                $path | Should -BeOfType [string]
                
                # Path should be absolute (contains drive letter or UNC)
                $path | Should -Match '^([A-Za-z]:|\\\\)'
            }
        }
        
        It "Root path should be consistent with configuration" {
            $config = Get-Config
            $paths = Get-Paths
            
            $paths.Root | Should -Be $config.RepoRoot
        }
        
        It "Resolve-DirectoryPath should handle special cases correctly" {
            $config = Get-Config
            $specs = Get-DirectorySpecs
            
            # Test special cases that reference config values
            $versionsPath = Resolve-DirectoryPath -Name "Versions" -Spec $specs.Versions
            $versionsPath | Should -Match ([regex]::Escape($config.VersionsDirName))
            
            $dataPath = Resolve-DirectoryPath -Name "Data" -Spec $specs.Data  
            $dataPath | Should -Match ([regex]::Escape($config.DataDirName))
        }
        
        It "Resolve-DirectoryPath should handle relative paths correctly" {
            $config = Get-Config
            $specs = Get-DirectorySpecs
            
            # Test relative path resolution
            $currentDataPath = Resolve-DirectoryPath -Name "CurrentData" -Spec $specs.CurrentData
            $currentDataPath | Should -Match "data[/\\]current"
            $currentDataPath | Should -Match ([regex]::Escape($config.RepoRoot))
        }
    }
    
    Context "Directory Creation" {
        BeforeEach {
            # Create isolated test directory for each test
            $script:TestRoot = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([Guid]::NewGuid())) -Force
        }
        
        AfterEach {
            # Clean up test directory
            if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
                Remove-Item $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        
        It "New-Directories should create directories marked for auto-creation" {
            # Create test paths based on TestRoot
            $testPaths = @{
                "TestAutoDir" = Join-Path $script:TestRoot "auto-created"
                "TestManualDir" = Join-Path $script:TestRoot "manual-created"  
                "TestFile" = Join-Path $script:TestRoot "test-file.txt"
            }
            
            # Mock Get-DirectorySpecs within the Core module scope
            Mock Get-DirectorySpecs -ModuleName Core {
                return @{
                    "TestAutoDir" = @{
                        AutoCreate = $true
                        Description = "Test auto-created directory"
                    }
                    "TestManualDir" = @{
                        AutoCreate = $false
                        Description = "Test manual directory"  
                    }
                    "TestFile" = @{
                        AutoCreate = $true
                        IsFile = $true
                        Description = "Test file"
                    }
                }
            }
            
            # Run New-Directories
            New-Directories -P $testPaths
            
            # Verify auto-created directory exists
            Test-Path $testPaths.TestAutoDir | Should -Be $true
            
            # Verify manual directory was not created
            Test-Path $testPaths.TestManualDir | Should -Be $false
            
            # Verify files are not created (even if AutoCreate is true)
            Test-Path $testPaths.TestFile | Should -Be $false
        }
    }
    
    Context "Directory Information Display" {
        It "Get-DirectoryInfo should execute without errors" {
            # This is mainly a smoke test since output formatting might change
            { Get-DirectoryInfo } | Should -Not -Throw
        }
    }
    
    Context "Module Contract Verification" {
        It "Should export all expected functions" {
            $exportedFunctions = Get-Command -Module Core -CommandType Function | Select-Object -ExpandProperty Name
            
            # Verify all expected functions are exported
            $expectedFunctions = @(
                "Get-Config",
                "Get-DirectorySpecs", 
                "Write-Log",
                "Resolve-DirectoryPath",
                "Get-Paths",
                "New-Directories",
                "Get-DirectoryInfo"
            )
            
            foreach ($func in $expectedFunctions) {
                $exportedFunctions | Should -Contain $func
            }
        }
        
        It "Should not export internal variables or unexpected functions" {
            $exportedCommands = Get-Command -Module Core
            
            # Should only export functions, not variables or aliases
            $exportedCommands | Where-Object CommandType -ne "Function" | Should -BeNullOrEmpty
            
            # Check for any leaked variables (this is less critical and might be environment-specific)
            # We'll focus on ensuring no unwanted commands are exported
            $exportedFunctions = $exportedCommands | Select-Object -ExpandProperty Name
            $unexpectedFunctions = $exportedFunctions | Where-Object { $_ -notmatch '^(Get-Config|Get-DirectorySpecs|Write-Log|Resolve-DirectoryPath|Get-Paths|New-Directories|Get-DirectoryInfo)$' }
            
            $unexpectedFunctions | Should -BeNullOrEmpty
        }
    }
    
    AfterAll {
        # Clean up module import
        Remove-Module Core -Force -ErrorAction SilentlyContinue
    }
}
