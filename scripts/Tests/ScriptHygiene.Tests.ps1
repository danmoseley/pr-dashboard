Describe 'Script hygiene' {
    It 'Get-PrTriageData.ps1 must not use Write-Output (stdout is JSON data)' {
        $script = Join-Path $PSScriptRoot '../Get-PrTriageData.ps1'
        $hits = Select-String -Path $script -Pattern '\bWrite-Output\b'
        $hits | Should -BeNullOrEmpty -Because 'Write-Output sends to stdout which is redirected to scan.json; use Write-Host or Write-Warning for diagnostics'
    }
}
