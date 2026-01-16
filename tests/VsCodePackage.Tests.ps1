#requires -Module Pester

Describe "VsCodePackage Module Tests" {
    BeforeAll {
        # Import required modules
        $CoreModulePath = Join-Path $PSScriptRoot "..\src\Core.psm1"
        $VsCodePackageModulePath = Join-Path $PSScriptRoot "..\src\VsCodePackage.psm1"
        
        Import-Module $CoreModulePath -Force -ErrorAction Stop
        Import-Module $VsCodePackageModulePath -Force -ErrorAction Stop
        
        # Create test directory structure
        $script:TestRoot = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([Guid]::NewGuid())) -Force
        $script:TestPaths = @{
            Root = $script:TestRoot.FullName
            Downloads = Join-Path $script:TestRoot "downloads"
            Versions = Join-Path $script:TestRoot "versions"
            Tmp = Join-Path $script:TestRoot "tmp"
        }
        
        # Create test directories
        foreach ($path in $script:TestPaths.Values) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
        
        # Create mock ZIP file for testing
        $script:MockZipPath = Join-Path $script:TestPaths.Downloads "vscode-test.zip"
        Set-Content -Path $script:MockZipPath -Value "Mock ZIP Content" -NoNewline
    }
    
    Context "VS Code Download Functionality" {
        It "Invoke-VsCodeDownload should download file when not cached" {
            # Mock web download
            Mock Invoke-WebRequest -ModuleName VsCodePackage {
                param($Uri, $OutFile, $UseBasicParsing)
                # Simulate download by creating the file
                Set-Content -Path $OutFile -Value "Downloaded ZIP Content" -NoNewline
            }
            
            # Ensure no existing file
            $testZipPath = Join-Path $script:TestPaths.Downloads "vscode-1.107.1.zip"
            if (Test-Path $testZipPath) {
                Remove-Item $testZipPath -Force
            }
            
            $result = Invoke-VsCodeDownload -P $script:TestPaths -Url "https://example.com/vscode.zip" -Version "1.107.1"
            
            # Verify download was called and file was created
            Should -Invoke Invoke-WebRequest -ModuleName VsCodePackage -Exactly 1
            Test-Path $result | Should -Be $true
            $result | Should -Match "vscode-1\.107\.1\.zip"
        }
        
        It "Invoke-VsCodeDownload should reuse existing valid ZIP" {
            # Create a valid ZIP file structure for testing
            $testZipPath = Join-Path $script:TestPaths.Downloads "vscode-1.108.0.zip"
            
            # Create a simple ZIP file that won't fail integrity check
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            if (Test-Path $testZipPath) { Remove-Item $testZipPath -Force }
            
            $zip = [System.IO.Compression.ZipFile]::Open($testZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
            $entry = $zip.CreateEntry("test.txt")
            $writer = New-Object System.IO.StreamWriter($entry.Open())
            $writer.WriteLine("test content")
            $writer.Dispose()
            $zip.Dispose()
            
            Mock Invoke-WebRequest -ModuleName VsCodePackage {
                throw "Should not download when file exists"
            }
            
            $result = Invoke-VsCodeDownload -P $script:TestPaths -Url "https://example.com/vscode.zip" -Version "1.108.0"
            
            # Should not call download and should return existing file
            Should -Invoke Invoke-WebRequest -ModuleName VsCodePackage -Exactly 0
            $result | Should -Be $testZipPath
        }
        
        It "Invoke-VsCodeDownload should re-download corrupted ZIP" {
            # Create corrupted ZIP file
            $testZipPath = Join-Path $script:TestPaths.Downloads "vscode-1.109.0.zip"
            Set-Content -Path $testZipPath -Value "corrupted content" -NoNewline
            
            Mock Invoke-WebRequest -ModuleName VsCodePackage {
                param($Uri, $OutFile, $UseBasicParsing)
                Set-Content -Path $OutFile -Value "New downloaded content" -NoNewline
            }
            
            $result = Invoke-VsCodeDownload -P $script:TestPaths -Url "https://example.com/vscode.zip" -Version "1.109.0"
            
            # Should detect corruption and re-download
            Should -Invoke Invoke-WebRequest -ModuleName VsCodePackage -Exactly 1
            Test-Path $result | Should -Be $true
        }
        
        It "Invoke-VsCodeDownload should return correct file path structure" {
            Mock Invoke-WebRequest -ModuleName VsCodePackage {
                param($Uri, $OutFile, $UseBasicParsing)
                Set-Content -Path $OutFile -Value "Test content" -NoNewline
            }
            
            $result = Invoke-VsCodeDownload -P $script:TestPaths -Url "https://example.com/vscode.zip" -Version "1.110.0"
            
            # Verify path structure
            $result | Should -Match ([regex]::Escape($script:TestPaths.Downloads))
            $result | Should -Match "vscode-1\.110\.0\.zip$"
        }
    }
    
    Context "Package Checksum Verification" {
        BeforeEach {
            # Create test file with known content for checksum testing
            $script:TestFile = Join-Path $script:TestRoot "test-checksum.txt"
            Set-Content -Path $script:TestFile -Value "test content for checksum" -NoNewline
            
            # Calculate actual SHA256 for the test content
            $script:ActualHash = (Get-FileHash -Algorithm SHA256 -Path $script:TestFile).Hash
        }
        
        AfterEach {
            if (Test-Path $script:TestFile) {
                Remove-Item $script:TestFile -Force
            }
        }
        
        It "Test-PackageChecksum should pass with correct checksum" {
            { Test-PackageChecksum -FilePath $script:TestFile -ExpectedSha256 $script:ActualHash } | Should -Not -Throw
        }
        
        It "Test-PackageChecksum should handle case-insensitive checksums" {
            # Test with lowercase expected hash
            { Test-PackageChecksum -FilePath $script:TestFile -ExpectedSha256 $script:ActualHash.ToLower() } | Should -Not -Throw
            
            # Test with uppercase expected hash  
            { Test-PackageChecksum -FilePath $script:TestFile -ExpectedSha256 $script:ActualHash.ToUpper() } | Should -Not -Throw
        }
        
        It "Test-PackageChecksum should throw with incorrect checksum" {
            $wrongHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            
            { Test-PackageChecksum -FilePath $script:TestFile -ExpectedSha256 $wrongHash } | Should -Throw -ExpectedMessage "*Checksum mismatch*"
        }
        
        It "Test-PackageChecksum should throw with non-existent file" {
            $nonExistentFile = Join-Path $script:TestRoot "nonexistent.txt"
            
            { Test-PackageChecksum -FilePath $nonExistentFile -ExpectedSha256 $script:ActualHash } | Should -Throw
        }
    }
    
    Context "Version Extraction from Installation" {
        BeforeEach {
            # Create mock VS Code directory structure
            $script:MockVsCodeDir = Join-Path $script:TestRoot "mock-vscode"
            $script:ResourcesDir = Join-Path $script:MockVsCodeDir "resources"
            $script:AppDir = Join-Path $script:ResourcesDir "app"
            $script:ProductJsonPath = Join-Path $script:AppDir "product.json"
            
            New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        }
        
        AfterEach {
            if (Test-Path $script:MockVsCodeDir) {
                Remove-Item $script:MockVsCodeDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        
        It "Get-ExtractedVersion should return version from product.json" {
            # Create valid product.json
            $productContent = @{
                version = "1.107.1"
                name = "Visual Studio Code"
            } | ConvertTo-Json
            
            Set-Content -Path $script:ProductJsonPath -Value $productContent
            
            $result = Get-ExtractedVersion -ExtractDir $script:MockVsCodeDir
            $result | Should -Be "1.107.1"
        }
        
        It "Get-ExtractedVersion should handle different version formats" {
            $versions = @("1.108.0", "1.50.1", "2.0.0-insider", "1.107.1-20240115")
            
            foreach ($version in $versions) {
                $productContent = @{ version = $version } | ConvertTo-Json
                Set-Content -Path $script:ProductJsonPath -Value $productContent
                
                $result = Get-ExtractedVersion -ExtractDir $script:MockVsCodeDir
                $result | Should -Be $version
            }
        }
        
        It "Get-ExtractedVersion should throw when product.json missing" {
            # Don't create product.json
            { Get-ExtractedVersion -ExtractDir $script:MockVsCodeDir } | Should -Throw -ExpectedMessage "*product.json not found*"
        }
        
        It "Get-ExtractedVersion should throw when version missing in product.json" {
            # Create product.json without version
            $productContent = @{ name = "Visual Studio Code" } | ConvertTo-Json
            Set-Content -Path $script:ProductJsonPath -Value $productContent
            
            { Get-ExtractedVersion -ExtractDir $script:MockVsCodeDir } | Should -Throw -ExpectedMessage "*version not found*"
        }
        
        It "Get-ExtractedVersion should handle invalid JSON" {
            # Create invalid JSON
            Set-Content -Path $script:ProductJsonPath -Value "{ invalid json"
            
            { Get-ExtractedVersion -ExtractDir $script:MockVsCodeDir } | Should -Throw
        }
    }
    
    Context "VS Code Package Installation" {
        BeforeEach {
            # Create a proper test ZIP file for installation testing
            $script:TestInstallZip = Join-Path $script:TestPaths.Downloads "install-test.zip"
            $script:ZipContentDir = Join-Path $script:TestRoot "zip-content"
            
            # Clean up if exists
            if (Test-Path $script:ZipContentDir) {
                Remove-Item $script:ZipContentDir -Recurse -Force
            }
            
            # Clean up version directories to ensure clean test state
            if (Test-Path $script:TestPaths.Versions) {
                Get-ChildItem -Path $script:TestPaths.Versions | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
            
            # Create mock VS Code structure inside ZIP content
            $vscodeDir = Join-Path $script:ZipContentDir "VSCode-win32-x64"
            $resourcesDir = Join-Path $vscodeDir "resources"
            $appDir = Join-Path $resourcesDir "app"
            New-Item -ItemType Directory -Path $appDir -Force | Out-Null
            
            # Create Code.exe
            Set-Content -Path (Join-Path $vscodeDir "Code.exe") -Value "mock exe" -NoNewline
            
            # Create product.json
            $productJson = @{ version = "1.107.1" } | ConvertTo-Json
            Set-Content -Path (Join-Path $appDir "product.json") -Value $productJson -NoNewline
            
            # Ensure the ZIP content directory has content before creating ZIP
            $contentItems = Get-ChildItem -Path $script:ZipContentDir -Recurse
            if ($contentItems.Count -eq 0) {
                throw "Test setup failed: No content in ZIP directory"
            }
            
            # Create ZIP file from content
            if (Test-Path $script:TestInstallZip) { Remove-Item $script:TestInstallZip -Force }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::CreateFromDirectory($script:ZipContentDir, $script:TestInstallZip)
        }
        
        AfterEach {
            # Clean up
            @($script:TestInstallZip, $script:ZipContentDir) | ForEach-Object {
                if ($_ -and (Test-Path $_)) {
                    Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        
        It "Install-VsCodePackage should extract and install new version" {
            $result = Install-VsCodePackage -P $script:TestPaths -ZipPath $script:TestInstallZip
            
            # Verify result structure
            $result | Should -Not -BeNullOrEmpty
            $result.Keys | Should -Contain "Version"
            $result.Keys | Should -Contain "InstalledPath"
            $result.Keys | Should -Contain "IsNew"
            
            # Verify values
            $result.Version | Should -Be "1.107.1"
            $result.IsNew | Should -Be $true
            Test-Path $result.InstalledPath | Should -Be $true
            
            # Verify Code.exe exists in installed location
            $codeExe = Join-Path $result.InstalledPath "Code.exe"
            Test-Path $codeExe | Should -Be $true
        }
        
        It "Install-VsCodePackage should skip installation if version exists" {
            # First installation
            $result1 = Install-VsCodePackage -P $script:TestPaths -ZipPath $script:TestInstallZip
            $result1.IsNew | Should -Be $true
            
            # Second installation of same version
            $result2 = Install-VsCodePackage -P $script:TestPaths -ZipPath $script:TestInstallZip
            $result2.IsNew | Should -Be $false
            $result2.Version | Should -Be "1.107.1"
            $result2.InstalledPath | Should -Be $result1.InstalledPath
        }
        
        It "Install-VsCodePackage should handle ZIP with direct content (no wrapper folder)" {
            # Create ZIP without wrapper folder
            $directZip = Join-Path $script:TestPaths.Downloads "direct-test.zip"
            $directContentDir = Join-Path $script:TestRoot "direct-content"
            
            # Create content directly (not in subfolder)
            $resourcesDir = Join-Path $directContentDir "resources"
            $appDir = Join-Path $resourcesDir "app"
            New-Item -ItemType Directory -Path $appDir -Force | Out-Null
            
            Set-Content -Path (Join-Path $directContentDir "Code.exe") -Value "mock exe"
            $productJson = @{ version = "1.108.0" } | ConvertTo-Json
            Set-Content -Path (Join-Path $appDir "product.json") -Value $productJson
            
            [System.IO.Compression.ZipFile]::CreateFromDirectory($directContentDir, $directZip)
            
            try {
                $result = Install-VsCodePackage -P $script:TestPaths -ZipPath $directZip
                $result.Version | Should -Be "1.108.0"
                Test-Path (Join-Path $result.InstalledPath "Code.exe") | Should -Be $true
            } finally {
                Remove-Item $directZip -Force -ErrorAction SilentlyContinue
                Remove-Item $directContentDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        
        It "Install-VsCodePackage should throw when Code.exe missing after installation" {
            # Create ZIP without Code.exe
            $incompleteZip = Join-Path $script:TestPaths.Downloads "incomplete-test.zip"
            $incompleteDir = Join-Path $script:TestRoot "incomplete-content"
            
            $vscodeDir = Join-Path $incompleteDir "VSCode-win32-x64"
            $resourcesDir = Join-Path $vscodeDir "resources"
            $appDir = Join-Path $resourcesDir "app"
            New-Item -ItemType Directory -Path $appDir -Force | Out-Null
            
            # Create product.json but no Code.exe
            $productJson = @{ version = "1.109.0" } | ConvertTo-Json
            Set-Content -Path (Join-Path $appDir "product.json") -Value $productJson
            
            [System.IO.Compression.ZipFile]::CreateFromDirectory($incompleteDir, $incompleteZip)
            
            try {
                { Install-VsCodePackage -P $script:TestPaths -ZipPath $incompleteZip } | Should -Throw -ExpectedMessage "*Code.exe not found*"
            } finally {
                Remove-Item $incompleteZip -Force -ErrorAction SilentlyContinue
                Remove-Item $incompleteDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    Context "Module Contract Verification" {
        It "Should export all expected functions" {
            $exportedFunctions = Get-Command -Module VsCodePackage -CommandType Function | Select-Object -ExpandProperty Name
            
            # Verify all expected functions are exported
            $expectedFunctions = @(
                "Invoke-VsCodeDownload",
                "Test-PackageChecksum",
                "Get-ExtractedVersion",
                "Install-VsCodePackage"
            )
            
            foreach ($func in $expectedFunctions) {
                $exportedFunctions | Should -Contain $func
            }
        }
        
        It "Should not export unexpected functions" {
            $exportedCommands = Get-Command -Module VsCodePackage
            
            # Should only export functions, not variables or aliases
            $exportedCommands | Where-Object CommandType -ne "Function" | Should -BeNullOrEmpty
            
            # Should only export expected functions
            $exportedFunctions = $exportedCommands | Select-Object -ExpandProperty Name
            $unexpectedFunctions = $exportedFunctions | Where-Object { 
                $_ -notmatch '^(Invoke-VsCodeDownload|Test-PackageChecksum|Get-ExtractedVersion|Install-VsCodePackage)$' 
            }
            
            $unexpectedFunctions | Should -BeNullOrEmpty
        }
    }
    
    AfterAll {
        # Clean up test directory and modules
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        Remove-Module VsCodePackage -Force -ErrorAction SilentlyContinue
        Remove-Module Core -Force -ErrorAction SilentlyContinue
    }
}
