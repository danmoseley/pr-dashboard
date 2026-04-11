BeforeAll {
    Import-Module "$PSScriptRoot/../IncrementalScan.psm1" -Force

    function New-FakePr {
        param(
            [int]$Number = 100,
            [string]$UpdatedAt = '2025-01-15T10:00:00Z',
            [string]$Mergeable = 'MERGEABLE',
            [bool]$IsDraft = $false,
            [string[]]$Labels = @('area-System.Net'),
            [string[]]$Assignees = @('alice'),
            [int]$ChangedFiles = 3,
            [int]$Additions = 10,
            [int]$Deletions = 5
        )
        [PSCustomObject]@{
            number       = $Number
            updatedAt    = $UpdatedAt
            mergeable    = $Mergeable
            isDraft      = $IsDraft
            labels       = @($Labels | ForEach-Object { [PSCustomObject]@{ name = $_ } })
            assignees    = @($Assignees | ForEach-Object { [PSCustomObject]@{ login = $_ } })
            changedFiles = $ChangedFiles
            additions    = $Additions
            deletions    = $Deletions
            createdAt    = '2025-01-01T00:00:00Z'
        }
    }

    function New-FakeScanEntry {
        param(
            [int]$Number = 100,
            [string]$Fingerprint = '',
            [string]$CI = 'SUCCESS',
            [string]$Mergeable = 'MERGEABLE',
            [int]$Score = 50,
            [string]$NextAction = 'needs-review'
        )
        [PSCustomObject]@{
            number       = $Number
            ci           = $CI
            mergeable    = $Mergeable
            score        = $Score
            next_action  = $NextAction
            _fingerprint = $Fingerprint
            age_days     = 14
            days_since_update = 2
        }
    }
}

Describe 'Get-PrFingerprint' {
    It 'Builds a deterministic fingerprint from PR data' {
        $pr = New-FakePr -Number 42
        $fp = Get-PrFingerprint $pr
        $fp | Should -BeLike '2025-01-15T10:00:00Z|*'
    }

    It 'Changes when labels change' {
        $pr1 = New-FakePr -Labels @('area-A')
        $pr2 = New-FakePr -Labels @('area-B')
        (Get-PrFingerprint $pr1) | Should -Not -Be (Get-PrFingerprint $pr2)
    }

    It 'Changes when updatedAt changes' {
        $pr1 = New-FakePr -UpdatedAt '2025-01-15T10:00:00Z'
        $pr2 = New-FakePr -UpdatedAt '2025-01-15T11:00:00Z'
        (Get-PrFingerprint $pr1) | Should -Not -Be (Get-PrFingerprint $pr2)
    }

    It 'Changes when draft status changes' {
        $pr1 = New-FakePr -IsDraft $false
        $pr2 = New-FakePr -IsDraft $true
        (Get-PrFingerprint $pr1) | Should -Not -Be (Get-PrFingerprint $pr2)
    }

    It 'Changes when mergeable changes' {
        $pr1 = New-FakePr -Mergeable 'MERGEABLE'
        $pr2 = New-FakePr -Mergeable 'CONFLICTING'
        (Get-PrFingerprint $pr1) | Should -Not -Be (Get-PrFingerprint $pr2)
    }

    It 'Sorts labels for stable fingerprint' {
        $pr1 = New-FakePr -Labels @('z-label','a-label')
        $pr2 = New-FakePr -Labels @('a-label','z-label')
        (Get-PrFingerprint $pr1) | Should -Be (Get-PrFingerprint $pr2)
    }

    It 'Handles empty labels and assignees' {
        $pr = New-FakePr -Labels @() -Assignees @()
        { Get-PrFingerprint $pr } | Should -Not -Throw
        (Get-PrFingerprint $pr) | Should -BeLike '*||*'
    }
}

Describe 'Get-IncrementalCacheVersion' {
    It 'Returns a positive integer' {
        $v = Get-IncrementalCacheVersion
        $v | Should -BeGreaterThan 0
    }
}

Describe 'Import-PreviousScan' {
    BeforeAll {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "incr-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Returns disabled when path is empty' {
        $r = Import-PreviousScan -Path '' -RequiredCacheVersion 2
        $r.Enabled | Should -BeFalse
    }

    It 'Returns disabled when file does not exist' {
        $r = Import-PreviousScan -Path "$testDir/nope.json" -RequiredCacheVersion 2
        $r.Enabled | Should -BeFalse
    }

    It 'Returns disabled when cache version mismatches' {
        $file = "$testDir/scan-old.json"
        @{ _cache_version = 1; prs = @(@{ number = 1; _fingerprint = 'fp'; score = 10; next_action = 'x' }) } |
            ConvertTo-Json -Depth 5 | Set-Content $file
        $r = Import-PreviousScan -Path $file -RequiredCacheVersion 2
        $r.Enabled | Should -BeFalse
    }

    It 'Returns disabled for corrupt JSON' {
        $file = "$testDir/corrupt.json"
        'this is not json {{' | Set-Content $file
        $r = Import-PreviousScan -Path $file -RequiredCacheVersion 2
        $r.Enabled | Should -BeFalse
    }

    It 'Returns disabled when prs array is missing' {
        $file = "$testDir/no-prs.json"
        @{ _cache_version = 2; timestamp = '2025-01-15T12:00:00Z' } |
            ConvertTo-Json -Depth 5 | Set-Content $file
        $r = Import-PreviousScan -Path $file -RequiredCacheVersion 2
        $r.Enabled | Should -BeFalse
    }

    It 'Loads valid previous scan and builds lookups' {
        $file = "$testDir/valid.json"
        @{
            _cache_version = 2
            timestamp = '2025-01-15T12:00:00Z'
            prs = @(
                @{ number = 42; _fingerprint = 'fp42'; score = 50; next_action = 'review' }
                @{ number = 99; _fingerprint = 'fp99'; score = 30; next_action = 'merge' }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content $file
        $r = Import-PreviousScan -Path $file -RequiredCacheVersion 2
        $r.Enabled | Should -BeTrue
        $r.PrLookup.Count | Should -Be 2
        $r.PrLookup['42'].score | Should -Be 50
        $r.Fingerprints['99'] | Should -Be 'fp99'
        $r.Timestamp | Should -BeOfType [DateTime]
    }

    It 'Uses string keys (not Int64)' {
        $file = "$testDir/keys.json"
        @{
            _cache_version = 2
            timestamp = '2025-01-15T12:00:00Z'
            prs = @(@{ number = 12345; _fingerprint = 'fp'; score = 1; next_action = 'x' })
        } | ConvertTo-Json -Depth 5 | Set-Content $file
        $r = Import-PreviousScan -Path $file -RequiredCacheVersion 2
        $r.PrLookup.ContainsKey('12345') | Should -BeTrue
        $r.PrLookup.ContainsKey([int]12345) | Should -BeFalse
    }
}

Describe 'Get-IncrementalPartition' {
    BeforeAll {
        # Build a valid "previous" state
        $pr1 = New-FakePr -Number 10
        $fp1 = Get-PrFingerprint $pr1
        $entry1 = New-FakeScanEntry -Number 10 -Fingerprint $fp1 -CI 'SUCCESS'
        $pr2 = New-FakePr -Number 20
        $fp2 = Get-PrFingerprint $pr2
        $entry2 = New-FakeScanEntry -Number 20 -Fingerprint $fp2 -CI 'SUCCESS'
    }

    It 'Reuses unchanged PRs' {
        $lookup = @{ '10' = $entry1; '20' = $entry2 }
        $fpMap = @{ '10' = $fp1; '20' = $fp2 }
        $partition = Get-IncrementalPartition -Candidates @($pr1, $pr2) `
            -PreviousPrLookup $lookup -PreviousFingerprints $fpMap `
            -PreviousTimestamp (Get-Date).AddMinutes(-5)
        $partition.RefreshCandidates.Count | Should -Be 0
        $partition.ReusedEntries.Count | Should -Be 2
        $partition.Fallback | Should -BeFalse
    }

    It 'Refreshes new PRs' {
        $newPr = New-FakePr -Number 30
        $lookup = @{ '10' = $entry1 }
        $fpMap = @{ '10' = $fp1 }
        $partition = Get-IncrementalPartition -Candidates @($pr1, $newPr) `
            -PreviousPrLookup $lookup -PreviousFingerprints $fpMap `
            -PreviousTimestamp (Get-Date).AddMinutes(-5)
        $partition.RefreshCandidates.Count | Should -Be 1
        $partition.RefreshCandidates[0].number | Should -Be 30
        $partition.ReusedEntries.Count | Should -Be 1
    }

    It 'Refreshes PRs with changed fingerprint' {
        $modifiedPr = New-FakePr -Number 10 -Labels @('new-label')
        $lookup = @{ '10' = $entry1 }
        $fpMap = @{ '10' = $fp1 }
        $partition = Get-IncrementalPartition -Candidates @($modifiedPr) `
            -PreviousPrLookup $lookup -PreviousFingerprints $fpMap `
            -PreviousTimestamp (Get-Date).AddMinutes(-5)
        $partition.RefreshCandidates.Count | Should -Be 1
    }

    It 'Refreshes PRs with FAILURE CI (can change via rerun)' {
        $failEntry = New-FakeScanEntry -Number 10 -Fingerprint $fp1 -CI 'FAILURE'
        $lookup = @{ '10' = $failEntry }
        $fpMap = @{ '10' = $fp1 }
        $partition = Get-IncrementalPartition -Candidates @($pr1) `
            -PreviousPrLookup $lookup -PreviousFingerprints $fpMap `
            -PreviousTimestamp (Get-Date).AddMinutes(-5)
        $partition.RefreshCandidates.Count | Should -Be 1
    }

    It 'Refreshes PRs with IN_PROGRESS CI' {
        $inProgressEntry = New-FakeScanEntry -Number 10 -Fingerprint $fp1 -CI 'IN_PROGRESS'
        $lookup = @{ '10' = $inProgressEntry }
        $fpMap = @{ '10' = $fp1 }
        $partition = Get-IncrementalPartition -Candidates @($pr1) `
            -PreviousPrLookup $lookup -PreviousFingerprints $fpMap `
            -PreviousTimestamp (Get-Date).AddMinutes(-5)
        $partition.RefreshCandidates.Count | Should -Be 1
    }

    It 'Refreshes PRs with ABSENT CI' {
        $absentEntry = New-FakeScanEntry -Number 10 -Fingerprint $fp1 -CI 'ABSENT'
        $lookup = @{ '10' = $absentEntry }
        $fpMap = @{ '10' = $fp1 }
        $partition = Get-IncrementalPartition -Candidates @($pr1) `
            -PreviousPrLookup $lookup -PreviousFingerprints $fpMap `
            -PreviousTimestamp (Get-Date).AddMinutes(-5)
        $partition.RefreshCandidates.Count | Should -Be 1
    }

    It 'Refreshes PRs with UNKNOWN mergeable' {
        $unknownEntry = New-FakeScanEntry -Number 10 -Fingerprint $fp1 -Mergeable 'UNKNOWN'
        $lookup = @{ '10' = $unknownEntry }
        $fpMap = @{ '10' = $fp1 }
        $partition = Get-IncrementalPartition -Candidates @($pr1) `
            -PreviousPrLookup $lookup -PreviousFingerprints $fpMap `
            -PreviousTimestamp (Get-Date).AddMinutes(-5)
        $partition.RefreshCandidates.Count | Should -Be 1
    }

    It 'Force-refreshes all when TTL expired' {
        $lookup = @{ '10' = $entry1; '20' = $entry2 }
        $fpMap = @{ '10' = $fp1; '20' = $fp2 }
        $partition = Get-IncrementalPartition -Candidates @($pr1, $pr2) `
            -PreviousPrLookup $lookup -PreviousFingerprints $fpMap `
            -PreviousTimestamp (Get-Date).AddHours(-13) -MaxReuseSeconds 43200
        $partition.RefreshCandidates.Count | Should -Be 2
        $partition.ReusedEntries.Count | Should -Be 0
    }

    It 'Force-refreshes all when no timestamp' {
        $lookup = @{ '10' = $entry1 }
        $fpMap = @{ '10' = $fp1 }
        $partition = Get-IncrementalPartition -Candidates @($pr1) `
            -PreviousPrLookup $lookup -PreviousFingerprints $fpMap `
            -PreviousTimestamp $null
        $partition.RefreshCandidates.Count | Should -Be 1
    }

    It 'Refreshes entries with missing score (corrupt cache)' {
        $corruptEntry = [PSCustomObject]@{
            number = 10; ci = 'SUCCESS'; mergeable = 'MERGEABLE'
            score = $null; next_action = 'x'; _fingerprint = $fp1
        }
        $lookup = @{ '10' = $corruptEntry }
        $fpMap = @{ '10' = $fp1 }
        $partition = Get-IncrementalPartition -Candidates @($pr1) `
            -PreviousPrLookup $lookup -PreviousFingerprints $fpMap `
            -PreviousTimestamp (Get-Date).AddMinutes(-5)
        $partition.RefreshCandidates.Count | Should -Be 1
    }

    It 'Refreshes entries with missing next_action (corrupt cache)' {
        $corruptEntry = [PSCustomObject]@{
            number = 10; ci = 'SUCCESS'; mergeable = 'MERGEABLE'
            score = 50; next_action = $null; _fingerprint = $fp1
        }
        $lookup = @{ '10' = $corruptEntry }
        $fpMap = @{ '10' = $fp1 }
        $partition = Get-IncrementalPartition -Candidates @($pr1) `
            -PreviousPrLookup $lookup -PreviousFingerprints $fpMap `
            -PreviousTimestamp (Get-Date).AddMinutes(-5)
        $partition.RefreshCandidates.Count | Should -Be 1
    }

    It 'Returns all candidates on empty previous state' {
        $partition = Get-IncrementalPartition -Candidates @($pr1) `
            -PreviousPrLookup @{} -PreviousFingerprints @{} `
            -PreviousTimestamp (Get-Date).AddMinutes(-5)
        $partition.RefreshCandidates.Count | Should -Be 1
    }
}

Describe 'Merge-ReusedEntries' {
    It 'Returns results unchanged when no reused entries' {
        $existing = @([PSCustomObject]@{ number = 1; score = 10 })
        $merged = Merge-ReusedEntries -ReusedEntries @{} -PrListData @() -Results $existing
        $merged.Count | Should -Be 1
    }

    It 'Merges reused entries and recalculates time fields' {
        $entry = [PSCustomObject]@{
            number = 42; score = 50; _fingerprint = 'old'
            age_days = 999; days_since_update = 999
        }
        $listPr = New-FakePr -Number 42 -UpdatedAt (Get-Date).AddDays(-3).ToString('o')
        $merged = Merge-ReusedEntries -ReusedEntries @{ '42' = $entry } `
            -PrListData @($listPr) -Results @()
        $merged.Count | Should -Be 1
        $merged[0].age_days | Should -Not -Be 999
        $merged[0].days_since_update | Should -Not -Be 999
    }

    It 'Updates fingerprint on reused entries' {
        $listPr = New-FakePr -Number 10
        $expectedFp = Get-PrFingerprint $listPr
        $entry = [PSCustomObject]@{
            number = 10; score = 50; _fingerprint = 'stale'
            age_days = 1; days_since_update = 1
        }
        $merged = Merge-ReusedEntries -ReusedEntries @{ '10' = $entry } `
            -PrListData @($listPr) -Results @()
        $merged[0]._fingerprint | Should -Be $expectedFp
    }

    It 'Preserves existing results array' {
        $existing = @([PSCustomObject]@{ number = 1 })
        $entry = [PSCustomObject]@{
            number = 2; score = 10; _fingerprint = 'fp'
            age_days = 1; days_since_update = 1
        }
        $listPr = New-FakePr -Number 2
        $merged = Merge-ReusedEntries -ReusedEntries @{ '2' = $entry } `
            -PrListData @($listPr) -Results $existing
        $merged.Count | Should -Be 2
    }
}
