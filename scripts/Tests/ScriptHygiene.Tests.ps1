Describe 'Script hygiene' {
    It 'Get-PrTriageData.ps1 must not use Write-Output (stdout is JSON data)' {
        $script = Join-Path $PSScriptRoot '../Get-PrTriageData.ps1'
        $hits = Select-String -Path $script -Pattern '\bWrite-Output\b'
        $hits | Should -BeNullOrEmpty -Because 'Write-Output sends to stdout which is redirected to scan.json; use Write-Host for diagnostics'
    }

    It 'Get-PrTriageData.ps1 must not use Write-Warning (can leak to stdout with ANSI codes)' {
        $script = Join-Path $PSScriptRoot '../Get-PrTriageData.ps1'
        $hits = Select-String -Path $script -Pattern '\bWrite-Warning\b'
        $hits | Should -BeNullOrEmpty -Because 'Write-Warning (stream 3) can leak ANSI-colored text to stdout in CI; use Write-Host for diagnostics'
    }

    It 'Workflow pwsh -Command in if-conditions must use explicit exit codes' {
        # pwsh -Command "expr" always exits 0 regardless of expr's boolean value.
        # Only exceptions cause non-zero exit. Any bash if-check that relies on
        # the expression result as an exit code is silently broken.
        $workflow = Join-Path $PSScriptRoot '../../.github/workflows/generate-reports.yml'
        $content = Get-Content $workflow -Raw

        # Find pwsh -Command invocations inside bash if-conditions
        # Pattern: "if" ... "pwsh -Command" on the same logical line
        $lines = $content -split "`n"
        $violations = @()
        $inPwshBlock = $false
        $blockLines = @()
        $blockStartLine = 0

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i].Trim()

            # Detect: if ... pwsh -Command (single-line or start of multi-line)
            if ($line -match '^\s*if\b.*pwsh\s+(-NoProfile\s+)?-Command\b') {
                $inPwshBlock = $true
                $blockLines = @($line)
                $blockStartLine = $i + 1
            }
            elseif ($inPwshBlock) {
                $blockLines += $line
            }

            # End of the pwsh -Command block (the "; then" in bash)
            if ($inPwshBlock -and $line -match ';\s*then\s*$') {
                $block = $blockLines -join "`n"
                if ($block -notmatch '\bexit\b') {
                    $violations += "Line $blockStartLine : pwsh -Command in if-condition without explicit exit"
                }
                $inPwshBlock = $false
                $blockLines = @()
            }
        }

        $violations | Should -BeNullOrEmpty -Because 'pwsh -Command "expr" always exits 0; use explicit exit 0/exit 1 inside try/catch for reliable bash if-checks'
    }
}
