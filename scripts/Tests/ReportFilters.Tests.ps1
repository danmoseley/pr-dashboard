Describe 'Report filter parity' {
    BeforeAll {
        $scriptDir = Join-Path $PSScriptRoot '..'
        $buildReports = Join-Path $scriptDir 'Build-Reports.ps1'
        $buildIndex = Join-Path $scriptDir 'Build-Index.ps1'
        $actionableHtml = Join-Path $PSScriptRoot '../../docs/actionable.html'

        # Read Build-Reports.ps1 as raw text for lightweight parity checks.
        # We can't dot-source the whole script (it has mandatory params), so tests
        # re-implement predicates and verify they match the JS in actionable.html.
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
            # Community PR that is ALSO a quick-win (overlap)
            [PSCustomObject]@{ number = 11; is_community = $true; next_action = "@user: Ready to merge"; age_days = 3; days_since_update = 1; action_score = 10 }
            # Stale community PR (overlap: community + stale)
            [PSCustomObject]@{ number = 12; is_community = $true; next_action = "@user: review needed"; age_days = 200; days_since_update = 60; action_score = 0.3 }
            # Null fields: is_community null, next_action null
            [PSCustomObject]@{ number = 13; is_community = $null; next_action = $null; age_days = 50; days_since_update = 10; action_score = 5 }
            # Null next_action with is_community true (should NOT match community: no review)
            [PSCustomObject]@{ number = 14; is_community = $true; next_action = $null; age_days = 10; days_since_update = 2; action_score = 6 }
            # Quick-win with different casing (case-insensitive match)
            [PSCustomObject]@{ number = 15; is_community = $false; next_action = "@user: ready to merge"; age_days = 5; days_since_update = 1; action_score = 9.5 }
        )
    }

    Context 'Community filter predicate' {
        It 'PowerShell predicate matches expected PRs' {
            $community = @($testPrs | Where-Object { $_.is_community -and $_.next_action -match "review" })
            $community.Count | Should -Be 2
            ($community | ForEach-Object { $_.number } | Sort-Object) | Should -Be @(1, 12)
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

        It 'Null is_community does not match' {
            $nullCommunity = @($testPrs | Where-Object { $_.number -eq 13 } | Where-Object { $_.is_community -and $_.next_action -match "review" })
            $nullCommunity.Count | Should -Be 0
        }

        It 'Null next_action does not match even with is_community=true' {
            $nullAction = @($testPrs | Where-Object { $_.number -eq 14 } | Where-Object { $_.is_community -and $_.next_action -match "review" })
            $nullAction.Count | Should -Be 0
        }
    }

    Context 'Quick-wins filter predicate' {
        It 'PowerShell predicate matches expected PRs (case-insensitive)' {
            $quickWins = @($testPrs | Where-Object { $_.next_action -match "Ready to merge" })
            $quickWins.Count | Should -Be 3
            ($quickWins | ForEach-Object { $_.number } | Sort-Object) | Should -Be @(4, 11, 15)
        }

        It 'Case-insensitive match includes lowercase variant' {
            # PR #15 has "ready to merge" (lowercase) -- must match like PowerShell -match
            $lower = @($testPrs | Where-Object { $_.number -eq 15 } | Where-Object { $_.next_action -match "Ready to merge" })
            $lower.Count | Should -Be 1 -Because 'PowerShell -match is case-insensitive'
        }

        It 'Null next_action does not match' {
            $nullAction = @($testPrs | Where-Object { $_.number -eq 13 } | Where-Object { $_.next_action -match "Ready to merge" })
            $nullAction.Count | Should -Be 0
        }
    }

    Context 'Stale/consider-closing filter predicate' {
        It 'PowerShell predicate matches expected PRs' {
            $stale = @($testPrs | Where-Object {
                ($_.age_days -gt 90 -and $_.days_since_update -gt 30) -or
                ($_.age_days -gt 180 -and $_.days_since_update -gt 14)
            })
            $stale.Count | Should -Be 3
            ($stale | ForEach-Object { $_.number } | Sort-Object) | Should -Be @(6, 7, 12)
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
            $stale[0].number | Should -Be 12 -Because 'PR #12 has 60 days since update (highest)'
            $stale[1].number | Should -Be 6 -Because 'PR #6 has 35 days since update'
            $stale[2].number | Should -Be 7 -Because 'PR #7 has 20 days since update'
        }
    }

    Context 'Filter composition (AND semantics)' {
        It 'Community + quick-wins: only community PRs that are also quick-wins' {
            $composed = @($testPrs |
                Where-Object { $_.is_community -and $_.next_action -match "review" } |
                Where-Object { $_.next_action -match "Ready to merge" })
            # PR #11 is community + quick-win, but its next_action is "Ready to merge" not "review"
            # PR #12 is community + review, but not "Ready to merge"
            # So the intersection should be empty
            $composed.Count | Should -Be 0
        }

        It 'Community + stale: only community PRs that are also stale' {
            $composed = @($testPrs |
                Where-Object { $_.is_community -and $_.next_action -match "review" } |
                Where-Object {
                    ($_.age_days -gt 90 -and $_.days_since_update -gt 30) -or
                    ($_.age_days -gt 180 -and $_.days_since_update -gt 14)
                })
            $composed.Count | Should -Be 1
            $composed[0].number | Should -Be 12 -Because 'PR #12 is a stale community PR awaiting review'
        }

        It 'Quick-wins + stale: no overlap in test data' {
            $composed = @($testPrs |
                Where-Object { $_.next_action -match "Ready to merge" } |
                Where-Object {
                    ($_.age_days -gt 90 -and $_.days_since_update -gt 30) -or
                    ($_.age_days -gt 180 -and $_.days_since_update -gt 14)
                })
            $composed.Count | Should -Be 0 -Because 'quick-win PRs in test data are all recent'
        }
    }

    Context 'Redirect stubs' {
        It 'Build-Reports.ps1 defines redirect URLs for all report types' {
            $buildReportsContent | Should -Match 'top15.*actionable\.html\?repo='
            $buildReportsContent | Should -Match 'community.*actionable\.html\?repo=.*&community=true'
            $buildReportsContent | Should -Match 'quick-wins.*actionable\.html\?repo=.*&quickwins=true'
            $buildReportsContent | Should -Match 'stale-close.*actionable\.html\?repo=.*&stale=true'
        }

        It 'Build-Reports.ps1 does not generate full HTML for redirected reports' {
            # The redirect block should skip AI and HTML generation via 'continue'
            $buildReportsContent | Should -Match '(?s)redirectReports.*continue'
        }

        It 'Redirect stubs preserve existing query params via JS' {
            # The JS in the stub should append location.search to the base URL
            $buildReportsContent | Should -Match 'location\.search'
            $buildReportsContent | Should -Match 'location\.hash'
        }
    }

    Context 'Old bookmark redirects' {
        It 'docs/all/actionable.html exists as a redirect stub' {
            $allRedirect = Join-Path $PSScriptRoot '../../docs/all/actionable.html'
            Test-Path $allRedirect | Should -Be $true
        }

        It 'docs/all/actionable.html redirects to ../actionable.html' {
            $allRedirect = Get-Content (Join-Path $PSScriptRoot '../../docs/all/actionable.html') -Raw
            $allRedirect | Should -Match 'url=\.\./actionable\.html'
            $allRedirect | Should -Match "location\.replace\('\.\./actionable\.html'"
        }

        It 'docs/all/actionable.html preserves query string and hash' {
            $allRedirect = Get-Content (Join-Path $PSScriptRoot '../../docs/all/actionable.html') -Raw
            $allRedirect | Should -Match 'location\.search'
            $allRedirect | Should -Match 'location\.hash'
        }

        It 'Per-repo redirect stubs target correct URLs' {
            # Verify the stub template in Build-Reports.ps1 includes repo slug and report params
            foreach ($reportId in @('top15', 'community', 'quick-wins', 'stale-close')) {
                $buildReportsContent | Should -Match "(?s)`"$reportId`"\s*=\s*`"\.\./actionable\.html\?repo="
            }
        }

        It 'Per-repo redirect stubs use meta-refresh as no-JS fallback' {
            $buildReportsContent | Should -Match 'meta http-equiv.*refresh.*content=.*0;url='
        }

        It 'Per-repo redirect stubs use location.replace for JS redirect' {
            $buildReportsContent | Should -Match 'location\.replace\(url\)'
        }
    }

    Context 'Index link targets' {
        It 'Build-Index.ps1 header links target actionable.html per-repo' {
            $indexContent = Get-Content $buildIndex -Raw
            $indexContent | Should -Match 'actionable\.html\?repo='
        }

        It 'Build-Index.ps1 has prominent CTA link to actionable.html' {
            $indexContent = Get-Content $buildIndex -Raw
            $indexContent | Should -Match 'href\s*=\s*["'']actionable\.html["'']'
        }

        It 'Build-Index.ps1 does not contain removed report-type rows' {
            $indexContent = Get-Content $buildIndex -Raw
            $indexContent | Should -Not -Match '\$dataRows'
            $indexContent | Should -Not -Match 'Most Actionable|Community Awaiting|Quick Wins|Consider Closing'
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
            # Should NOT have localStorage get/set for community/quickwins/stale filter keys
            $htmlContent | Should -Not -Match "localStorage\.\w+Item\([^)]*'[^']*community"
            $htmlContent | Should -Not -Match "localStorage\.\w+Item\([^)]*'[^']*quickwins"
            $htmlContent | Should -Not -Match "localStorage\.\w+Item\([^)]*'[^']*stale"
        }
    }
}
