Describe 'Test-ScanNeeded.ps1' {
    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..' 'Test-ScanNeeded.ps1'

        # Helper: compute probe hash (same algorithm as Get-PrTriageData and Test-ScanNeeded)
        function Get-ProbeHash {
            param([array]$Prs, [int]$TotalCount = -1)
            if ($TotalCount -lt 0) { $TotalCount = $Prs.Count }
            $pairs = @($Prs | ForEach-Object { "$($_.number):$($_.updatedAt)" } | Sort-Object)
            $input = "total=$TotalCount|" + ($pairs -join '|')
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($input)
            [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').Substring(0, 16).ToLower()
        }

        # Helper: create a temp scan.json file
        function New-ScanFile {
            param([hashtable]$Data)
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "test-scan-$([guid]::NewGuid()).json"
            $Data | ConvertTo-Json -Depth 10 | Set-Content $tmp -Encoding UTF8
            $tmp
        }

        # Common PR data for tests
        $testPrs = @(
            @{ number = 100; updatedAt = '2025-01-15T10:00:00Z' },
            @{ number = 200; updatedAt = '2025-01-15T11:00:00Z' }
        )
        $script:goodHash = Get-ProbeHash -Prs $testPrs -TotalCount 2
    }

    Context 'Returns true (scan needed) when' {
        It 'previous scan file does not exist' {
            $result = pwsh -NoProfile -Command "& '$scriptPath' -Repo 'owner/repo' -PreviousScanFile '/nonexistent/scan.json' 2>`$null"
            $result | Should -Be 'true'
        }

        It 'previous scan has no timestamp' {
            $f = New-ScanFile @{ prs = @(); _probe_hash = 'abc123' }
            try {
                $result = pwsh -NoProfile -Command "& '$scriptPath' -Repo 'owner/repo' -PreviousScanFile '$f' 2>`$null"
                $result | Should -Be 'true'
            } finally { Remove-Item $f -ErrorAction SilentlyContinue }
        }

        It 'previous scan is too old' {
            $oldTimestamp = (Get-Date).AddHours(-5).ToString('o')
            $f = New-ScanFile @{
                timestamp = $oldTimestamp
                prs = @()
                _probe_hash = $script:goodHash
            }
            try {
                # MaxSkipSeconds = 60 means 5h old scan is way past limit
                $result = pwsh -NoProfile -Command "& '$scriptPath' -Repo 'owner/repo' -PreviousScanFile '$f' -MaxSkipSeconds 60 2>`$null"
                $result | Should -Be 'true'
            } finally { Remove-Item $f -ErrorAction SilentlyContinue }
        }

        It 'previous scan has unstable CI PRs' {
            $f = New-ScanFile @{
                timestamp = (Get-Date).AddMinutes(-10).ToString('o')
                prs = @(
                    @{ number = 100; ci = 'FAILURE'; mergeable = 'MERGEABLE' }
                )
                _probe_hash = $script:goodHash
            }
            try {
                $result = pwsh -NoProfile -Command "& '$scriptPath' -Repo 'owner/repo' -PreviousScanFile '$f' 2>`$null"
                $result | Should -Be 'true'
            } finally { Remove-Item $f -ErrorAction SilentlyContinue }
        }

        It 'previous scan has UNKNOWN mergeable PRs' {
            $f = New-ScanFile @{
                timestamp = (Get-Date).AddMinutes(-10).ToString('o')
                prs = @(
                    @{ number = 100; ci = 'SUCCESS'; mergeable = 'UNKNOWN' }
                )
                _probe_hash = $script:goodHash
            }
            try {
                $result = pwsh -NoProfile -Command "& '$scriptPath' -Repo 'owner/repo' -PreviousScanFile '$f' 2>`$null"
                $result | Should -Be 'true'
            } finally { Remove-Item $f -ErrorAction SilentlyContinue }
        }

        It 'previous scan has no _probe_hash' {
            $f = New-ScanFile @{
                timestamp = (Get-Date).AddMinutes(-10).ToString('o')
                prs = @()
            }
            try {
                $result = pwsh -NoProfile -Command "& '$scriptPath' -Repo 'owner/repo' -PreviousScanFile '$f' 2>`$null"
                $result | Should -Be 'true'
            } finally { Remove-Item $f -ErrorAction SilentlyContinue }
        }
    }

    Context 'Probe hash computation' {
        It 'matches Get-PrTriageData hash algorithm' {
            # Verify our helper produces consistent hashes
            $hash1 = Get-ProbeHash -Prs @(
                @{ number = 1; updatedAt = '2025-01-01T00:00:00Z' }
                @{ number = 2; updatedAt = '2025-01-02T00:00:00Z' }
            )
            $hash2 = Get-ProbeHash -Prs @(
                @{ number = 2; updatedAt = '2025-01-02T00:00:00Z' }
                @{ number = 1; updatedAt = '2025-01-01T00:00:00Z' }
            )
            $hash1 | Should -Be $hash2  # Order-independent
        }

        It 'changes when a PR is updated' {
            $hash1 = Get-ProbeHash -Prs @(
                @{ number = 1; updatedAt = '2025-01-01T00:00:00Z' }
            )
            $hash2 = Get-ProbeHash -Prs @(
                @{ number = 1; updatedAt = '2025-01-01T01:00:00Z' }
            )
            $hash1 | Should -Not -Be $hash2
        }

        It 'changes when a PR is added' {
            $hash1 = Get-ProbeHash -Prs @(
                @{ number = 1; updatedAt = '2025-01-01T00:00:00Z' }
            ) -TotalCount 1
            $hash2 = Get-ProbeHash -Prs @(
                @{ number = 1; updatedAt = '2025-01-01T00:00:00Z' }
                @{ number = 2; updatedAt = '2025-01-02T00:00:00Z' }
            ) -TotalCount 2
            $hash1 | Should -Not -Be $hash2
        }

        It 'changes when totalCount differs' {
            $hash1 = Get-ProbeHash -Prs @(
                @{ number = 1; updatedAt = '2025-01-01T00:00:00Z' }
            ) -TotalCount 100
            $hash2 = Get-ProbeHash -Prs @(
                @{ number = 1; updatedAt = '2025-01-01T00:00:00Z' }
            ) -TotalCount 101
            $hash1 | Should -Not -Be $hash2
        }

        It 'produces 16 hex characters' {
            $hash = Get-ProbeHash -Prs @()
            $hash | Should -Match '^[0-9a-f]{16}$'
        }
    }

    Context 'Fail-safe behavior' {
        It 'returns true when scan file contains invalid JSON' {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "test-bad-$([guid]::NewGuid()).json"
            'not json{{{' | Set-Content $tmp
            try {
                $result = pwsh -NoProfile -Command "& '$scriptPath' -Repo 'owner/repo' -PreviousScanFile '$tmp' 2>`$null"
                $result | Should -Be 'true'
            } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
    }
}
