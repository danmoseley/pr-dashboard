Describe 'Script hygiene' {
    It 'Get-PrTriageData.ps1 must not use Write-Output (stdout is JSON data)' {
        $script = Join-Path $PSScriptRoot '../Get-PrTriageData.ps1'
        $hits = Select-String -Path $script -Pattern '\bWrite-Output\b'
        $hits | Should -BeNullOrEmpty -Because 'Write-Output pollutes stdout (used as JSON output without -OutputFile); use Write-Warning for diagnostics'
    }

    It 'Get-PrTriageData.ps1 must not redirect stdout to scan.json (use -OutputFile instead)' {
        $workflow = Join-Path $PSScriptRoot '../../.github/workflows/generate-reports.yml'
        $lines = Get-Content $workflow
        # Find lines that invoke the scan script and redirect stdout (> or 1>)
        $scanLines = $lines | Where-Object { $_ -match 'Get-PrTriageData\.ps1' }
        # Reject stdout redirect: "> file" or "1> file" but not "2> file"
        $violations = $scanLines | Where-Object { $_ -match '(?<![2-9])>\s*"' }
        $violations | Should -BeNullOrEmpty -Because 'stdout redirection causes PowerShell stream leaking; use -OutputFile parameter instead'
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
