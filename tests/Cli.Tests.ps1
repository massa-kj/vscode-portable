#requires -Module Pester

Describe "Cli Module Tests" {
    BeforeAll {
        # Import module with force to ensure clean state
        $ModulePath = Join-Path $PSScriptRoot "..\src\Cli.psm1"
        Import-Module $ModulePath -Force -ErrorAction Stop
    }
    
    Context "Basic Argument Parsing" {
        It "Should return valid structure for empty arguments" {
            $result = ConvertTo-ParsedArgs -Arguments @()
            
            $result | Should -Not -BeNullOrEmpty
            $result | Should -BeOfType [hashtable]
            
            # Check essential properties exist
            $result.Keys | Should -Contain "Platform"
            $result.Keys | Should -Contain "Quality" 
            $result.Keys | Should -Contain "Version"
            $result.Keys | Should -Contain "Help"
            $result.Keys | Should -Contain "ShowPaths"
            $result.Keys | Should -Contain "RebuildExtensions"
        }
        
        It "Should initialize flags to false by default" {
            $result = ConvertTo-ParsedArgs -Arguments @()
            
            $result.Help | Should -Be $false
            $result.ShowPaths | Should -Be $false
            $result.RebuildExtensions | Should -Be $false
        }
        
        It "Should parse string arguments correctly" {
            $result = ConvertTo-ParsedArgs -Arguments @("--platform", "win32-x64-archive")
            
            $result.Platform | Should -Be "win32-x64-archive"
            $result.Quality | Should -Be $null
        }
        
        It "Should parse flag arguments correctly" {
            $result = ConvertTo-ParsedArgs -Arguments @("--rebuild-extensions")
            
            $result.RebuildExtensions | Should -Be $true
            $result.Platform | Should -Be $null
        }
        
        It "Should throw on unknown arguments" {
            { ConvertTo-ParsedArgs -Arguments @("--invalid") } | Should -Throw
        }
    }
    
    Context "Value Validation" {
        It "Should validate string values" {
            $spec = @{ Type = "String"; ValidValues = $null }
            
            $result = Test-ArgumentValue -Spec $spec -Value "test" -ArgName "--test"
            $result | Should -Be "test"
        }
        
        It "Should validate constrained values" {
            $spec = @{ Type = "String"; ValidValues = @("stable", "insider") }
            
            Test-ArgumentValue -Spec $spec -Value "stable" -ArgName "--quality" | Should -Be "stable"
            
            { Test-ArgumentValue -Spec $spec -Value "invalid" -ArgName "--quality" } | Should -Throw
        }
    }
    
    Context "Module Contract" {
        It "Should export expected functions" {
            $functions = Get-Command -Module Cli -CommandType Function | Select-Object -ExpandProperty Name
            
            $functions | Should -Contain "ConvertTo-ParsedArgs"
            $functions | Should -Contain "Test-ArgumentValue"
            $functions | Should -Contain "Show-Help"
        }
    }
    
    AfterAll {
        Remove-Module Cli -Force -ErrorAction SilentlyContinue
    }
}
