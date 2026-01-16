#requires -Module Pester

Describe "DataManager Module Tests" {
    BeforeAll {
        # Import required modules
        $CoreModulePath = Join-Path $PSScriptRoot "..\src\Core.psm1"
        $DataManagerModulePath = Join-Path $PSScriptRoot "..\src\DataManager.psm1"
        
        Import-Module $CoreModulePath -Force -ErrorAction Stop
        Import-Module $DataManagerModulePath -Force -ErrorAction Stop
        
        # Create test directory structure
        $script:TestRoot = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([Guid]::NewGuid())) -Force
        $script:TestPaths = @{
            Root = $script:TestRoot.FullName
            CurrentData = Join-Path $script:TestRoot "current"
            Backups = Join-Path $script:TestRoot "backups"
        }
        
        # Create test directories
        foreach ($path in $script:TestPaths.Values) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
        
        # Helper function to create mock extension structure
        function New-MockExtensionStructure {
            param(
                [string]$ExtensionsDir,
                [string[]]$ExtensionIds
            )
            
            New-Item -ItemType Directory -Path $ExtensionsDir -Force | Out-Null
            
            foreach ($id in $ExtensionIds) {
                # Create extension folder with version suffix (realistic structure)
                $folderName = "$id-1.0.0"
                $extPath = Join-Path $ExtensionsDir $folderName
                New-Item -ItemType Directory -Path $extPath -Force | Out-Null
                
                # Create package.json file
                $packageJson = @{
                    name = $id.Split('.')[1]
                    publisher = $id.Split('.')[0]
                    version = "1.0.0"
                } | ConvertTo-Json
                Set-Content -Path (Join-Path $extPath "package.json") -Value $packageJson
            }
        }
    }
    
    Context "Current Data Backup Functionality" {
        BeforeEach {
            # Clean up directories for each test
            if (Test-Path $script:TestPaths.CurrentData) {
                Remove-Item $script:TestPaths.CurrentData -Recurse -Force
            }
            if (Test-Path $script:TestPaths.Backups) {
                Remove-Item $script:TestPaths.Backups -Recurse -Force
            }
            New-Item -ItemType Directory -Path $script:TestPaths.CurrentData -Force | Out-Null
            New-Item -ItemType Directory -Path $script:TestPaths.Backups -Force | Out-Null
        }
        
        It "Backup-CurrentData should return null when no meaningful data exists" {
            # Create empty current data directory
            $userDataDir = Join-Path $script:TestPaths.CurrentData "user-data"
            $extensionsDir = Join-Path $script:TestPaths.CurrentData "extensions"
            New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
            New-Item -ItemType Directory -Path $extensionsDir -Force | Out-Null
            
            $result = Backup-CurrentData -P $script:TestPaths
            
            $result | Should -Be $null
        }
        
        It "Backup-CurrentData should return null when current data directory doesn't exist" {
            # Don't create current data directory
            $result = Backup-CurrentData -P $script:TestPaths
            
            $result | Should -Be $null
        }
        
        It "Backup-CurrentData should create backup when user-data has content" {
            # Create user-data with content  
            $userDataDir = Join-Path $script:TestPaths.CurrentData "user-data"
            New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
            Set-Content -Path (Join-Path $userDataDir "settings.json") -Value '{"test": "value"}'
            
            # Also need to create extensions directory for current data to exist
            $extensionsDir = Join-Path $script:TestPaths.CurrentData "extensions"
            New-Item -ItemType Directory -Path $extensionsDir -Force | Out-Null
            
            $result = Backup-CurrentData -P $script:TestPaths
            
            # Should return backup path
            $result | Should -Not -BeNullOrEmpty
            $result | Should -Match ([regex]::Escape($script:TestPaths.Backups))
            $result | Should -Match "\d{4}-\d{2}-\d{2}_\d{6}"
            
            # Backup directory should exist
            Test-Path $result | Should -Be $true
            
            # Backup should contain the user-data
            $backupUserData = Join-Path $result "user-data"
            Test-Path $backupUserData | Should -Be $true
            Test-Path (Join-Path $backupUserData "settings.json") | Should -Be $true
        }
        
        It "Backup-CurrentData should create backup when extensions has content" {
            # Create extensions with content
            $extensionsDir = Join-Path $script:TestPaths.CurrentData "extensions"
            New-MockExtensionStructure -ExtensionsDir $extensionsDir -ExtensionIds @("ms-python.python")
            
            $result = Backup-CurrentData -P $script:TestPaths
            
            # Should return backup path
            $result | Should -Not -BeNullOrEmpty
            Test-Path $result | Should -Be $true
            
            # Backup should contain the extensions
            $backupExtensions = Join-Path $result "extensions"
            Test-Path $backupExtensions | Should -Be $true
            Test-Path (Join-Path $backupExtensions "ms-python.python-1.0.0") | Should -Be $true
        }
        
        It "Backup-CurrentData should create backup with both user-data and extensions" {
            # Create both user-data and extensions with content
            $userDataDir = Join-Path $script:TestPaths.CurrentData "user-data"
            $extensionsDir = Join-Path $script:TestPaths.CurrentData "extensions"
            
            New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
            Set-Content -Path (Join-Path $userDataDir "settings.json") -Value '{"test": "value"}'
            
            New-MockExtensionStructure -ExtensionsDir $extensionsDir -ExtensionIds @("ms-python.python", "ms-vscode.cpptools")
            
            $result = Backup-CurrentData -P $script:TestPaths
            
            # Verify backup contains both
            $backupUserData = Join-Path $result "user-data"
            $backupExtensions = Join-Path $result "extensions"
            
            Test-Path $backupUserData | Should -Be $true
            Test-Path $backupExtensions | Should -Be $true
            Test-Path (Join-Path $backupUserData "settings.json") | Should -Be $true
            Test-Path (Join-Path $backupExtensions "ms-python.python-1.0.0") | Should -Be $true
            Test-Path (Join-Path $backupExtensions "ms-vscode.cpptools-1.0.0") | Should -Be $true
        }
        
        It "Backup-CurrentData should generate unique timestamp-based directory names" {
            # Create content for backup
            $userDataDir = Join-Path $script:TestPaths.CurrentData "user-data"
            New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
            Set-Content -Path (Join-Path $userDataDir "test.txt") -Value "test"
            
            # Create first backup
            $result1 = Backup-CurrentData -P $script:TestPaths
            
            # Wait until we're in a different second for timestamp differentiation
            $currentSecond = (Get-Date).Second
            do {
                Start-Sleep -Milliseconds 100
            } while ((Get-Date).Second -eq $currentSecond)
            
            # Create second content to trigger another backup
            Set-Content -Path (Join-Path $userDataDir "test2.txt") -Value "test2"
            $result2 = Backup-CurrentData -P $script:TestPaths
            
            # Should be different paths
            $result1 | Should -Not -Be $result2
            Test-Path $result1 | Should -Be $true
            Test-Path $result2 | Should -Be $true
        }
    }
    
    Context "Extensions List Export Functionality" {
        BeforeEach {
            # Create test extensions directory
            $script:TestExtensionsDir = Join-Path $script:TestRoot "test-extensions"
            $script:TestExtensionsFile = Join-Path $script:TestRoot "test-extensions.txt"
            
            if (Test-Path $script:TestExtensionsDir) {
                Remove-Item $script:TestExtensionsDir -Recurse -Force
            }
            if (Test-Path $script:TestExtensionsFile) {
                Remove-Item $script:TestExtensionsFile -Force
            }
        }
        
        AfterEach {
            # Clean up
            @($script:TestExtensionsDir, $script:TestExtensionsFile) | ForEach-Object {
                if ($_ -and (Test-Path $_)) {
                    Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        
        It "Export-ExtensionsList should create empty file when extensions directory doesn't exist" {
            Export-ExtensionsList -ExtensionsDir $script:TestExtensionsDir -OutputFile $script:TestExtensionsFile
            
            Test-Path $script:TestExtensionsFile | Should -Be $true
            $content = Get-Content $script:TestExtensionsFile -Raw
            $content | Should -BeNullOrEmpty -Because "Empty file should have no content"
        }
        
        It "Export-ExtensionsList should extract extension IDs correctly" {
            # Create mock extensions with version suffixes
            $extensionIds = @("ms-python.python", "ms-vscode.cpptools", "github.copilot")
            New-MockExtensionStructure -ExtensionsDir $script:TestExtensionsDir -ExtensionIds $extensionIds
            
            Export-ExtensionsList -ExtensionsDir $script:TestExtensionsDir -OutputFile $script:TestExtensionsFile
            
            Test-Path $script:TestExtensionsFile | Should -Be $true
            $exportedIds = Get-Content $script:TestExtensionsFile | Where-Object { $_ -ne "" }
            
            # Should extract IDs without version suffixes
            $exportedIds | Should -Contain "ms-python.python"
            $exportedIds | Should -Contain "ms-vscode.cpptools"
            $exportedIds | Should -Contain "github.copilot"
            $exportedIds.Count | Should -Be 3
        }
        
        It "Export-ExtensionsList should handle extensions with complex version patterns" {
            # Create extensions with different version patterns
            New-Item -ItemType Directory -Path $script:TestExtensionsDir -Force | Out-Null
            
            $complexExtensions = @(
                "ms-python.python-2024.1.0",
                "ms-vscode.cpptools-1.18.5",
                "github.copilot-1.157.0",
                "extension-without-version"  # Edge case
            )
            
            foreach ($ext in $complexExtensions) {
                $extPath = Join-Path $script:TestExtensionsDir $ext
                New-Item -ItemType Directory -Path $extPath -Force | Out-Null
            }
            
            Export-ExtensionsList -ExtensionsDir $script:TestExtensionsDir -OutputFile $script:TestExtensionsFile
            
            $exportedIds = Get-Content $script:TestExtensionsFile | Where-Object { $_ -ne "" }
            
            # Should extract base IDs correctly
            $exportedIds | Should -Contain "ms-python.python"
            $exportedIds | Should -Contain "ms-vscode.cpptools"
            $exportedIds | Should -Contain "github.copilot"
            $exportedIds | Should -Contain "extension-without-version"  # Fallback case
        }
        
        It "Export-ExtensionsList should sort and deduplicate extension IDs" {
            New-Item -ItemType Directory -Path $script:TestExtensionsDir -Force | Out-Null
            
            # Create duplicate extensions (different versions)
            $duplicateExtensions = @(
                "ms-python.python-1.0.0",
                "ms-python.python-2.0.0",
                "github.copilot-1.0.0",
                "ms-vscode.cpptools-1.0.0"
            )
            
            foreach ($ext in $duplicateExtensions) {
                $extPath = Join-Path $script:TestExtensionsDir $ext
                New-Item -ItemType Directory -Path $extPath -Force | Out-Null
            }
            
            Export-ExtensionsList -ExtensionsDir $script:TestExtensionsDir -OutputFile $script:TestExtensionsFile
            
            $exportedIds = Get-Content $script:TestExtensionsFile | Where-Object { $_ -ne "" }
            
            # Should have unique IDs only
            $exportedIds | Should -Contain "ms-python.python"
            $exportedIds | Should -Contain "github.copilot"
            $exportedIds | Should -Contain "ms-vscode.cpptools"
            $exportedIds.Count | Should -Be 3  # No duplicates
            
            # Should be sorted
            $sortedIds = $exportedIds | Sort-Object
            for ($i = 0; $i -lt $exportedIds.Count; $i++) {
                $exportedIds[$i] | Should -Be $sortedIds[$i]
            }
        }
        
        It "Export-ExtensionsList should handle empty extensions directory" {
            New-Item -ItemType Directory -Path $script:TestExtensionsDir -Force | Out-Null
            
            Export-ExtensionsList -ExtensionsDir $script:TestExtensionsDir -OutputFile $script:TestExtensionsFile
            
            Test-Path $script:TestExtensionsFile | Should -Be $true
            $content = Get-Content $script:TestExtensionsFile -Raw
            $content.Trim() | Should -BeNullOrEmpty
        }
    }
    
    Context "Extensions Restoration Functionality" {
        BeforeEach {
            # Create test files
            $script:MockCodeExe = Join-Path $script:TestRoot "mock-code.exe"
            $script:TestExtensionsListFile = Join-Path $script:TestRoot "extensions-list.txt"
            $script:TestUserDataDir = Join-Path $script:TestRoot "user-data"
            $script:TestExtensionsDir = Join-Path $script:TestRoot "extensions"
            
            # Create mock VS Code executable
            Set-Content -Path $script:MockCodeExe -Value "@echo Mock VS Code CLI"
            
            # Create test directories
            New-Item -ItemType Directory -Path $script:TestUserDataDir -Force | Out-Null
            New-Item -ItemType Directory -Path $script:TestExtensionsDir -Force | Out-Null
        }
        
        AfterEach {
            # Clean up
            @($script:MockCodeExe, $script:TestExtensionsListFile, $script:TestUserDataDir, $script:TestExtensionsDir) | ForEach-Object {
                if ($_ -and (Test-Path $_)) {
                    Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        
        It "Restore-Extensions should throw when extensions list file doesn't exist" {
            { Restore-Extensions -CodeExe $script:MockCodeExe -ExtensionsListFile "nonexistent.txt" -UserDataDir $script:TestUserDataDir -ExtensionsDir $script:TestExtensionsDir } | Should -Throw -ExpectedMessage "*Extensions list file not found*"
        }
        
        It "Restore-Extensions should recreate extensions directory" {
            # Create extensions list
            $extensions = @("ms-python.python", "github.copilot")
            Set-Content -Path $script:TestExtensionsListFile -Value ($extensions -join "`n")
            
            # Put some existing content in extensions directory
            Set-Content -Path (Join-Path $script:TestExtensionsDir "old-extension") -Value "old content"
            
            # Mock the process class instead of Start-Process cmdlet
            Mock -CommandName "New-Object" -ModuleName DataManager -ParameterFilter { $TypeName -eq "System.Diagnostics.Process" } -MockWith {
                $mockProcess = New-Object PSObject
                $mockProcess | Add-Member -Type NoteProperty -Name ExitCode -Value 0
                $mockProcess | Add-Member -Type NoteProperty -Name StartInfo -Value (New-Object PSObject)
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name FileName -Value ""
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name Arguments -Value ""
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name UseShellExecute -Value $false
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name RedirectStandardOutput -Value $true
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name RedirectStandardError -Value $true
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name CreateNoWindow -Value $true
                
                $mockProcess | Add-Member -Type ScriptMethod -Name Start -Value { return $true }
                $mockProcess | Add-Member -Type ScriptMethod -Name WaitForExit -Value { }
                $mockProcess | Add-Member -Type NoteProperty -Name StandardError -Value (New-Object PSObject)
                $mockProcess.StandardError | Add-Member -Type ScriptMethod -Name ReadToEnd -Value { return "" }
                
                return $mockProcess
            }
            
            Restore-Extensions -CodeExe $script:MockCodeExe -ExtensionsListFile $script:TestExtensionsListFile -UserDataDir $script:TestUserDataDir -ExtensionsDir $script:TestExtensionsDir
            
            # Extensions directory should be recreated (old content removed)
            Test-Path $script:TestExtensionsDir | Should -Be $true
            Test-Path (Join-Path $script:TestExtensionsDir "old-extension") | Should -Be $false
        }
        
        It "Restore-Extensions should process each extension in the list" {
            $extensions = @("ms-python.python", "github.copilot", "ms-vscode.cpptools")
            Set-Content -Path $script:TestExtensionsListFile -Value ($extensions -join "`n")
            
            $script:processCallCount = 0
            Mock -CommandName "New-Object" -ModuleName DataManager -ParameterFilter { $TypeName -eq "System.Diagnostics.Process" } -MockWith {
                $script:processCallCount++
                $mockProcess = New-Object PSObject
                $mockProcess | Add-Member -Type NoteProperty -Name ExitCode -Value 0
                $mockProcess | Add-Member -Type NoteProperty -Name StartInfo -Value (New-Object PSObject)
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name FileName -Value ""
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name Arguments -Value ""
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name UseShellExecute -Value $false
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name RedirectStandardOutput -Value $true
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name RedirectStandardError -Value $true
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name CreateNoWindow -Value $true
                
                $mockProcess | Add-Member -Type ScriptMethod -Name Start -Value { return $true }
                $mockProcess | Add-Member -Type ScriptMethod -Name WaitForExit -Value { }
                $mockProcess | Add-Member -Type NoteProperty -Name StandardError -Value (New-Object PSObject)
                $mockProcess.StandardError | Add-Member -Type ScriptMethod -Name ReadToEnd -Value { return "" }
                
                return $mockProcess
            }
            
            Restore-Extensions -CodeExe $script:MockCodeExe -ExtensionsListFile $script:TestExtensionsListFile -UserDataDir $script:TestUserDataDir -ExtensionsDir $script:TestExtensionsDir
            
            # Should call New-Object once for each extension
            $script:processCallCount | Should -Be 3
        }
        
        It "Restore-Extensions should handle empty lines in extensions list" {
            # Create list with empty lines and whitespace
            $listContent = @(
                "ms-python.python",
                "",
                "  ",
                "github.copilot",
                "",
                "ms-vscode.cpptools"
            )
            Set-Content -Path $script:TestExtensionsListFile -Value ($listContent -join "`n")
            
            $script:processCallCount = 0
            Mock -CommandName "New-Object" -ModuleName DataManager -ParameterFilter { $TypeName -eq "System.Diagnostics.Process" } -MockWith {
                $script:processCallCount++
                $mockProcess = New-Object PSObject
                $mockProcess | Add-Member -Type NoteProperty -Name ExitCode -Value 0
                $mockProcess | Add-Member -Type NoteProperty -Name StartInfo -Value (New-Object PSObject)
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name FileName -Value ""
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name Arguments -Value ""
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name UseShellExecute -Value $false
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name RedirectStandardOutput -Value $true
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name RedirectStandardError -Value $true
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name CreateNoWindow -Value $true
                
                $mockProcess | Add-Member -Type ScriptMethod -Name Start -Value { return $true }
                $mockProcess | Add-Member -Type ScriptMethod -Name WaitForExit -Value { }
                $mockProcess | Add-Member -Type NoteProperty -Name StandardError -Value (New-Object PSObject)
                $mockProcess.StandardError | Add-Member -Type ScriptMethod -Name ReadToEnd -Value { return "" }
                
                return $mockProcess
            }
            
            Restore-Extensions -CodeExe $script:MockCodeExe -ExtensionsListFile $script:TestExtensionsListFile -UserDataDir $script:TestUserDataDir -ExtensionsDir $script:TestExtensionsDir
            
            # Should only process non-empty lines (3 extensions)
            $script:processCallCount | Should -Be 3
        }
        
        It "Restore-Extensions should handle extension installation failures gracefully" {
            $extensions = @("valid.extension", "invalid.extension")
            Set-Content -Path $script:TestExtensionsListFile -Value ($extensions -join "`n")
            
            $script:callCount = 0
            Mock -CommandName "New-Object" -ModuleName DataManager -ParameterFilter { $TypeName -eq "System.Diagnostics.Process" } -MockWith {
                $script:callCount++
                $mockProcess = New-Object PSObject
                
                # First extension succeeds, second fails
                if ($script:callCount -eq 1) {
                    $mockProcess | Add-Member -Type NoteProperty -Name ExitCode -Value 0
                } else {
                    $mockProcess | Add-Member -Type NoteProperty -Name ExitCode -Value 1
                }
                
                $mockProcess | Add-Member -Type NoteProperty -Name StartInfo -Value (New-Object PSObject)
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name FileName -Value ""
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name Arguments -Value ""
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name UseShellExecute -Value $false
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name RedirectStandardOutput -Value $true
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name RedirectStandardError -Value $true
                $mockProcess.StartInfo | Add-Member -Type NoteProperty -Name CreateNoWindow -Value $true
                
                $mockProcess | Add-Member -Type ScriptMethod -Name Start -Value { return $true }
                $mockProcess | Add-Member -Type ScriptMethod -Name WaitForExit -Value { }
                $mockProcess | Add-Member -Type NoteProperty -Name StandardError -Value (New-Object PSObject)
                $mockProcess.StandardError | Add-Member -Type ScriptMethod -Name ReadToEnd -Value { return "Extension installation failed" }
                
                return $mockProcess
            }
            
            # Should not throw even if some extensions fail
            { Restore-Extensions -CodeExe $script:MockCodeExe -ExtensionsListFile $script:TestExtensionsListFile -UserDataDir $script:TestUserDataDir -ExtensionsDir $script:TestExtensionsDir } | Should -Not -Throw
            
            # Should attempt to install both extensions
            $script:callCount | Should -Be 2
        }
    }
    
    Context "Module Contract Verification" {
        It "Should export all expected functions" {
            $exportedFunctions = Get-Command -Module DataManager -CommandType Function | Select-Object -ExpandProperty Name
            
            # Verify all expected functions are exported
            $expectedFunctions = @(
                "Backup-CurrentData",
                "Export-ExtensionsList",
                "Restore-Extensions"
            )
            
            foreach ($func in $expectedFunctions) {
                $exportedFunctions | Should -Contain $func
            }
        }
        
        It "Should not export unexpected functions" {
            $exportedCommands = Get-Command -Module DataManager
            
            # Should only export functions, not variables or aliases
            $exportedCommands | Where-Object CommandType -ne "Function" | Should -BeNullOrEmpty
            
            # Should only export expected functions
            $exportedFunctions = $exportedCommands | Select-Object -ExpandProperty Name
            $unexpectedFunctions = $exportedFunctions | Where-Object { 
                $_ -notmatch '^(Backup-CurrentData|Export-ExtensionsList|Restore-Extensions)$' 
            }
            
            $unexpectedFunctions | Should -BeNullOrEmpty
        }
    }
    
    AfterAll {
        # Clean up test directory and modules
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        Remove-Module DataManager -Force -ErrorAction SilentlyContinue
        Remove-Module Core -Force -ErrorAction SilentlyContinue
    }
}
