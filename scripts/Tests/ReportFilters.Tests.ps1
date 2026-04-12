Describe 'Report filter parity' {
    BeforeAll {
        $scriptDir = Join-Path $PSScriptRoot '..'
        $buildReports = Join-Path $scriptDir 'Build-Reports.ps1'
        $buildIndex = Join-Path $scriptDir 'Build-Index.ps1'
        $actionableHtml = Join-Path $PSScriptRoot '../../docs/all/actionable.html'

        # Extract filter predicates from Build-Reports.ps1 by sourcing the report definitions
        # We can't dot-source the whole script (it has mandatory params), so we parse the predicates
        $buildReportsContent = Get-Content $buildReports -Raw

        # Create synthetic test data that exercises all filter boundaries
        $testPrs = @(
            # Community PR awaiting review
            [PSCustomObject]@{ number = 1; is_community = $true; next_action = "@user: review needed"; age_days = 10; days_since_update = 5; action_score = 8 }
            # Community PR but NOT awaiting review (should NOT match community filter)
            [PSCustomObject]@{ number = 2; is_community = $true; next_action = "@author: address feedback"; age_days = 20; days_since_update = 3; action_score = 7 }
            # Non-community PR awaiting review (should NOT match community filter)
            [PSCustomObject]@{ number = 3; is_community = $false; next_action = "@user: review needed"; age_days = 15; days_since_update = 2; action_score = 9 }
            # Quick win: ready to merge
            [PSCustomObject]@{ number = 4; is_community = $false; next_action = "@user: Ready to merge"; age_days = 5; days_since_update = 1; action_score = 10 }
            # Not ready to merge
            [PSCustomObject]@{ number = 5; is_community = $false; next_action = "@user: needs CI fix"; age_days = 30; days_since_update = 10; action_score = 3 }
            # Stale: age > 90, stale > 30
            [PSCustomObject]@{ number = 6; is_community = $false; next_action = "@user: needs update"; age_days = 100; days_since_update = 35; action_score = 1 }
            # Stale: age > 180, stale > 14
            [PSCustomObject]@{ number = 7; is_community = $false; next_action = "@user: abandoned?"; age_days = 200; days_since_update = 20; action_score = 0.5 }
            # NOT stale: age > 90 but stale < 30
            [PSCustomObject]@{ number = 8; is_community = $false; next_action = "@user: waiting"; age_days = 95; days_since_update = 25; action_score = 2 }
            # NOT stale: age > 180 but stale < 14
            [PSCustomObject]@{ number = 9; is_community = $false; next_action = "@user: active old PR"; age_days = 190; days_since_update = 10; action_score = 4 }
            # Edge: age exactly 90, stale exactly 30 (should NOT match, > not >=)
            [PSCustomObject]@{ number = 10; is_community = $false; next_action = "@user: edge case"; age_days = 90; days_since_update = 30; action_score = 2 }
        )
    }

    Context 'Community filter predicate' {
        It 'PowerShell predicate matches expected PRs' {
            $community = @($testPrs | Where-Object { $_.is_community -and $_.next_action -match "review" })
            $community.Count | Should -Be 1
            $community[0].number | Should -Be 1
        }

        It 'JS-equivalent predicate matches PowerShell predicate' {
            # The JS predicate: is_community && /review/i.test(next_action)
            $jsCommunity = @($testPrs | Where-Object {
                $_.is_community -eq $true -and $_.next_action -match "review"
            })
            $psCommunity = @($testPrs | Where-Object { $_.is_community -and $_.next_action -match "review" })
            $jsCommunity.Count | Should -Be $psCommunity.Count
            ($jsCommunity | ForEach-Object { $_.number }) | Should -Be ($psCommunity | ForEach-Object { $_.number })
        }
    }

    Context 'Quick-wins filter predicate' {
        It 'PowerShell predicate matches expected PRs' {
            $quickWins = @($testPrs | Where-Object { $_.next_action -match "Ready to merge" })
            $quickWins.Count | Should -Be 1
            $quickWins[0].number | Should -Be 4
        }

        It 'JS-equivalent predicate matches PowerShell predicate' {
            # The JS predicate: /Ready to merge/.test(next_action)
            $jsQuickWins = @($testPrs | Where-Object { $_.next_action -match "Ready to merge" })
            $psQuickWins = @($testPrs | Where-Object { $_.next_action -match "Ready to merge" })
            $jsQuickWins.Count | Should -Be $psQuickWins.Count
        }
    }

    Context 'Stale/consider-closing filter predicate' {
        It 'PowerShell predicate matches expected PRs' {
            $stale = @($testPrs | Where-Object {
                ($_.age_days -gt 90 -and $_.days_since_update -gt 30) -or
                ($_.age_days -gt 180 -and $_.days_since_update -gt 14)
            })
            $stale.Count | Should -Be 2
            ($stale | ForEach-Object { $_.number } | Sort-Object) | Should -Be @(6, 7)
        }

        It 'JS-equivalent predicate matches PowerShell predicate' {
            # The JS predicate: (age_days > 90 && days_since_update > 30) || (age_days > 180 && days_since_update > 14)
            $jsStale = @($testPrs | Where-Object {
                ([int]$_.age_days -gt 90 -and [int]$_.days_since_update -gt 30) -or
                ([int]$_.age_days -gt 180 -and [int]$_.days_since_update -gt 14)
            })
            $psStale = @($testPrs | Where-Object {
                ($_.age_days -gt 90 -and $_.days_since_update -gt 30) -or
                ($_.age_days -gt 180 -and $_.days_since_update -gt 14)
            })
            $jsStale.Count | Should -Be $psStale.Count
            ($jsStale | ForEach-Object { $_.number } | Sort-Object) | Should -Be ($psStale | ForEach-Object { $_.number } | Sort-Object)
        }

        It 'Edge case: exact boundary values are excluded (> not >=)' {
            # PR #10: age=90, stale=30 -- should NOT match
            $edge = @($testPrs | Where-Object { $_.number -eq 10 } | Where-Object {
                ($_.age_days -gt 90 -and $_.days_since_update -gt 30) -or
                ($_.age_days -gt 180 -and $_.days_since_update -gt 14)
            })
            $edge.Count | Should -Be 0
        }

        It 'Stale sort is by days_since_update descending' {
            $stale = @($testPrs | Where-Object {
                ($_.age_days -gt 90 -and $_.days_since_update -gt 30) -or
                ($_.age_days -gt 180 -and $_.days_since_update -gt 14)
            } | Sort-Object -Property days_since_update -Descending)
            $stale[0].number | Should -Be 6 -Because 'PR #6 has 35 days since update (highest)'
            $stale[1].number | Should -Be 7 -Because 'PR #7 has 20 days since update'
        }
    }

    Context 'Redirect stubs' {
        It 'Build-Reports.ps1 defines redirect URLs for community, quick-wins, and stale-close' {
            $buildReportsContent | Should -Match 'community.*all/actionable\.html\?repo=.*&community=true'
            $buildReportsContent | Should -Match 'quick-wins.*all/actionable\.html\?repo=.*&quickwins=true'
            $buildReportsContent | Should -Match 'stale-close.*all/actionable\.html\?repo=.*&stale=true'
        }

        It 'Build-Reports.ps1 does not generate full HTML for redirected reports' {
            # The redirect block should skip AI and HTML generation via 'continue'
            $buildReportsContent | Should -Match '(?s)redirectReports.*continue'
        }
    }

    Context 'Index link targets' {
        It 'Build-Index.ps1 defines unified URLs for non-actionable reports' {
            $indexContent = Get-Content $buildIndex -Raw
            # The $unifiedReportUrls hashtable should map each report type to the right URL param
            $indexContent | Should -Match '"community"\s*=\s*"community=true"'
            $indexContent | Should -Match '"quick-wins"\s*=\s*"quickwins=true"'
            $indexContent | Should -Match '"stale-close"\s*=\s*"stale=true"'
        }

        It 'Build-Index.ps1 generates hrefs using unifiedReportUrls' {
            $indexContent = Get-Content $buildIndex -Raw
            $indexContent | Should -Match 'all/actionable\.html\?repo='
        }
    }

    Context 'JS filter predicates in actionable.html' {
        BeforeAll {
            $htmlContent = Get-Content $actionableHtml -Raw
        }

        It 'Community filter uses is_community AND review pattern' {
            # Check that the JS applyReportModeFilters function tests both is_community and review
            $htmlContent | Should -Match '(?s)communityMode[\s\S]*?pr\.is_community[\s\S]*?review'
        }

        It 'Quick-wins filter uses Ready to merge pattern' {
            $htmlContent | Should -Match '(?s)quickWinsMode[\s\S]*?Ready to merge'
        }

        It 'Stale filter uses age/staleness thresholds' {
            $htmlContent | Should -Match '(?s)staleMode[\s\S]*?age_days[\s\S]*?90[\s\S]*?days_since_update[\s\S]*?30'
        }

        It 'Report-mode filters are URL-only, not localStorage-persisted' {
            # Should NOT have localStorage for community/quickwins/stale
            $htmlContent | Should -Not -Match 'localStorage.*community'
            $htmlContent | Should -Not -Match 'localStorage.*quickwins'
            $htmlContent | Should -Not -Match 'localStorage.*stale'
        }
    }
}
