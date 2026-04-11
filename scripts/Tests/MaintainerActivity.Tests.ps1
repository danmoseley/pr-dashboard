#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for MaintainerActivity.psm1 – Select-FallbackReviewers scoring function.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../MaintainerActivity.psm1" -Force
}

Describe 'Select-FallbackReviewers' {
    BeforeAll {
        # Helper: build a PSCustomObject activity data structure (as ConvertFrom-Json would produce)
        function New-ActivityData {
            param([hashtable]$RepoData)
            $repoObj = [ordered]@{}
            foreach ($repo in $RepoData.Keys) {
                $maintainerObj = [ordered]@{}
                foreach ($m in $RepoData[$repo].Keys) {
                    $entry = $RepoData[$repo][$m]
                    $maintainerObj[$m] = [PSCustomObject]@{
                        merge_count      = $entry.merge_count
                        top_paths        = @($entry.top_paths)
                        top_area_labels  = @($entry.top_area_labels)
                    }
                }
                $repoObj[$repo] = [PSCustomObject]$maintainerObj
            }
            return [PSCustomObject]$repoObj
        }
    }

    It 'Returns top 2 when path matches score higher' {
        $activity = New-ActivityData @{
            'test/repo' = @{
                'alice'  = @{ merge_count = 10; top_paths = @('src/networking'); top_area_labels = @() }
                'bob'    = @{ merge_count = 5;  top_paths = @('src/other');      top_area_labels = @() }
                'carol'  = @{ merge_count = 3;  top_paths = @('src/networking'); top_area_labels = @() }
            }
        }
        $result = Select-FallbackReviewers `
            -Maintainers @('alice', 'bob', 'carol') `
            -ExcludeLogin '' `
            -Repo 'test/repo' `
            -ActivityData $activity `
            -ChangedFilePaths @('src/networking/foo.cs') `
            -AreaLabels @()

        # alice and carol both match path (+3), alice has higher merge_count so comes first
        $result | Should -HaveCount 2
        $result[0] | Should -Be 'alice'
        $result[1] | Should -Be 'carol'
    }

    It 'Returns label-matching maintainer above non-matching' {
        $activity = New-ActivityData @{
            'test/repo' = @{
                'alice' = @{ merge_count = 2;  top_paths = @('src/other'); top_area_labels = @('area-networking') }
                'bob'   = @{ merge_count = 20; top_paths = @('src/other'); top_area_labels = @('area-other') }
            }
        }
        $result = Select-FallbackReviewers `
            -Maintainers @('alice', 'bob') `
            -ExcludeLogin '' `
            -Repo 'test/repo' `
            -ActivityData $activity `
            -ChangedFilePaths @('src/unrelated/foo.cs') `
            -AreaLabels @('area-networking')

        # alice matches label (+2), bob does not — alice should come first despite fewer merges
        $result[0] | Should -Be 'alice'
    }

    It 'Uses merge_count as tiebreaker when scores are equal' {
        $activity = New-ActivityData @{
            'test/repo' = @{
                'alice' = @{ merge_count = 5;  top_paths = @('src/foo'); top_area_labels = @() }
                'bob'   = @{ merge_count = 15; top_paths = @('src/foo'); top_area_labels = @() }
            }
        }
        $result = Select-FallbackReviewers `
            -Maintainers @('alice', 'bob') `
            -ExcludeLogin '' `
            -Repo 'test/repo' `
            -ActivityData $activity `
            -ChangedFilePaths @('src/foo/bar.cs') `
            -AreaLabels @()

        # Both match path (+3); bob has higher merge_count, so comes first
        $result[0] | Should -Be 'bob'
        $result[1] | Should -Be 'alice'
    }

    It 'Falls back to merge_count order when all scores are 0' {
        $activity = New-ActivityData @{
            'test/repo' = @{
                'alice' = @{ merge_count = 2;  top_paths = @('src/other'); top_area_labels = @() }
                'bob'   = @{ merge_count = 10; top_paths = @('src/other'); top_area_labels = @() }
                'carol' = @{ merge_count = 7;  top_paths = @('src/other'); top_area_labels = @() }
            }
        }
        $result = Select-FallbackReviewers `
            -Maintainers @('alice', 'bob', 'carol') `
            -ExcludeLogin '' `
            -Repo 'test/repo' `
            -ActivityData $activity `
            -ChangedFilePaths @('completely/different/path.cs') `
            -AreaLabels @()

        # No path or label matches → all scores = 0 → fall back to merge_count desc
        $result[0] | Should -Be 'bob'
        $result[1] | Should -Be 'carol'
    }

    It 'Uses alphabetical tiebreaker when scores and merge_counts are equal' {
        $activity = New-ActivityData @{
            'test/repo' = @{
                'zebra' = @{ merge_count = 5; top_paths = @('src/foo'); top_area_labels = @() }
                'alice' = @{ merge_count = 5; top_paths = @('src/foo'); top_area_labels = @() }
                'mike'  = @{ merge_count = 5; top_paths = @('src/foo'); top_area_labels = @() }
            }
        }
        $result = Select-FallbackReviewers `
            -Maintainers @('zebra', 'alice', 'mike') `
            -ExcludeLogin '' `
            -Repo 'test/repo' `
            -ActivityData $activity `
            -ChangedFilePaths @('src/foo/bar.cs') `
            -AreaLabels @()

        # All match path (+3) and have same merge_count → alphabetical
        $result[0] | Should -Be 'alice'
        $result[1] | Should -Be 'mike'
    }

    It 'Excludes the PR author from candidates' {
        $activity = New-ActivityData @{
            'test/repo' = @{
                'author' = @{ merge_count = 100; top_paths = @('src/foo'); top_area_labels = @() }
                'alice'  = @{ merge_count = 1;   top_paths = @('src/foo'); top_area_labels = @() }
                'bob'    = @{ merge_count = 1;   top_paths = @('src/foo'); top_area_labels = @() }
            }
        }
        $result = Select-FallbackReviewers `
            -Maintainers @('author', 'alice', 'bob') `
            -ExcludeLogin 'author' `
            -Repo 'test/repo' `
            -ActivityData $activity `
            -ChangedFilePaths @('src/foo/bar.cs') `
            -AreaLabels @()

        $result | Should -Not -Contain 'author'
        $result | Should -HaveCount 2
    }

    It 'Falls back gracefully when no activity data is provided' {
        $result = Select-FallbackReviewers `
            -Maintainers @('alice', 'bob', 'carol') `
            -ExcludeLogin '' `
            -Repo 'test/repo' `
            -ActivityData $null `
            -ChangedFilePaths @('src/foo/bar.cs') `
            -AreaLabels @()

        # No data → all scores 0, all merge_counts 0 → alphabetical
        $result | Should -HaveCount 2
        $result[0] | Should -Be 'alice'
        $result[1] | Should -Be 'bob'
    }

    It 'Caps merge_count activity bonus at 1.0' {
        # Maintainer with 100 merges should not score higher than merge_count/10 capped at 1
        $activity = New-ActivityData @{
            'test/repo' = @{
                'alice' = @{ merge_count = 100; top_paths = @('src/other'); top_area_labels = @() }
                'bob'   = @{ merge_count = 10;  top_paths = @('src/other'); top_area_labels = @() }
            }
        }
        # No path/label matches → all scores = 0 (cap doesn't affect 0-base case)
        # With path match, alice should still beat bob via merge_count bonus (both capped at 1.0)
        $activity2 = New-ActivityData @{
            'test/repo' = @{
                'alice' = @{ merge_count = 100; top_paths = @('src/foo'); top_area_labels = @() }
                'bob'   = @{ merge_count = 10;  top_paths = @('src/foo'); top_area_labels = @() }
            }
        }
        $result = Select-FallbackReviewers `
            -Maintainers @('alice', 'bob') `
            -ExcludeLogin '' `
            -Repo 'test/repo' `
            -ActivityData $activity2 `
            -ChangedFilePaths @('src/foo/bar.cs') `
            -AreaLabels @()

        # Both get +3 (path) + 1.0 (capped) = 4.0 → tie → merge_count desc → alice first
        $result[0] | Should -Be 'alice'
    }

    It 'Returns at most 2 reviewers even with many maintainers' {
        $activity = New-ActivityData @{
            'test/repo' = @{
                'a' = @{ merge_count = 5; top_paths = @('src/foo'); top_area_labels = @() }
                'b' = @{ merge_count = 4; top_paths = @('src/foo'); top_area_labels = @() }
                'c' = @{ merge_count = 3; top_paths = @('src/foo'); top_area_labels = @() }
                'd' = @{ merge_count = 2; top_paths = @('src/foo'); top_area_labels = @() }
            }
        }
        $result = Select-FallbackReviewers `
            -Maintainers @('a', 'b', 'c', 'd') `
            -ExcludeLogin '' `
            -Repo 'test/repo' `
            -ActivityData $activity `
            -ChangedFilePaths @('src/foo/bar.cs') `
            -AreaLabels @()

        $result | Should -HaveCount 2
    }

    It 'Returns empty when all maintainers are the excluded author' {
        $result = Select-FallbackReviewers `
            -Maintainers @('author') `
            -ExcludeLogin 'author' `
            -Repo 'test/repo' `
            -ActivityData $null `
            -ChangedFilePaths @() `
            -AreaLabels @()

        $result | Should -HaveCount 0
    }

    It 'Handles repo not present in activity data gracefully' {
        $activity = New-ActivityData @{
            'other/repo' = @{
                'alice' = @{ merge_count = 10; top_paths = @('src/foo'); top_area_labels = @() }
            }
        }
        $result = Select-FallbackReviewers `
            -Maintainers @('alice', 'bob') `
            -ExcludeLogin '' `
            -Repo 'test/repo' `
            -ActivityData $activity `
            -ChangedFilePaths @('src/foo/bar.cs') `
            -AreaLabels @()

        # No data for this repo → all scores 0, merge_counts 0 → alphabetical
        $result[0] | Should -Be 'alice'
        $result[1] | Should -Be 'bob'
    }

    It 'Combines path and label bonuses correctly' {
        $activity = New-ActivityData @{
            'test/repo' = @{
                'alice' = @{ merge_count = 5; top_paths = @('src/net'); top_area_labels = @('area-net') }
                'bob'   = @{ merge_count = 5; top_paths = @('src/net'); top_area_labels = @('area-other') }
            }
        }
        $result = Select-FallbackReviewers `
            -Maintainers @('alice', 'bob') `
            -ExcludeLogin '' `
            -Repo 'test/repo' `
            -ActivityData $activity `
            -ChangedFilePaths @('src/net/Socket.cs') `
            -AreaLabels @('area-net')

        # alice: +3 (path) + 2 (label) + 0.5 (merge_count/10) = 5.5
        # bob:   +3 (path) + 0 (no label) + 0.5 = 3.5
        $result[0] | Should -Be 'alice'
        $result[1] | Should -Be 'bob'
    }
}
